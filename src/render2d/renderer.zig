//! 基础 2D 渲染器 (macOS Metal 路径)

const std = @import("std");
const metal = @import("../gpu/metal.zig");
const math = @import("../math.zig");
const text_layout = @import("../text/layout.zig");
const atlas_mod = @import("../text/atlas.zig");

const Vertex2D = metal.Vertex2D;
const TextVertex = metal.TextVertex;

pub const Renderer2D = struct {
    device: *metal.MetalDevice,
    vertices: std.ArrayListUnmanaged(Vertex2D) = .{ .items = &.{}, .capacity = 0 },
    text_vertices: std.ArrayListUnmanaged(TextVertex) = .{ .items = &.{}, .capacity = 0 },
    allocator: std.mem.Allocator,
    glyph_atlas: ?*atlas_mod.GlyphAtlas = null,

    pub fn init(allocator: std.mem.Allocator, device: *metal.MetalDevice) Renderer2D {
        return .{ .device = device, .allocator = allocator };
    }

    pub fn deinit(self: *Renderer2D) void {
        self.vertices.deinit(self.allocator);
        self.text_vertices.deinit(self.allocator);
    }

    pub fn beginFrame(self: *Renderer2D) void {
        self.vertices.clearRetainingCapacity();
        self.text_vertices.clearRetainingCapacity();
    }

    /// 填充矩形 (2 三角形)
    pub fn fillRect(self: *Renderer2D, rect: math.Rect(f32), color: math.Color) !void {
        const c = colorToFloat(color);
        const x0 = rect.x;
        const y0 = rect.y;
        const x1 = rect.x + rect.width;
        const y1 = rect.y + rect.height;

        try self.vertices.appendSlice(self.allocator, &.{
            .{ .pos = .{ x0, y0 }, .color = c },
            .{ .pos = .{ x1, y0 }, .color = c },
            .{ .pos = .{ x0, y1 }, .color = c },
            .{ .pos = .{ x1, y0 }, .color = c },
            .{ .pos = .{ x1, y1 }, .color = c },
            .{ .pos = .{ x0, y1 }, .color = c },
        });
    }

    /// 填充圆角矩形 (中心扇形三角化)
    pub fn fillRoundedRect(self: *Renderer2D, rect: math.Rect(f32), radius: f32, color: math.Color) !void {
        if (radius <= 0) {
            return self.fillRect(rect, color);
        }
        const c = colorToFloat(color);
        const r = @min(radius, @min(rect.width, rect.height) / 2.0);
        const cx = rect.x + rect.width / 2.0;
        const cy = rect.y + rect.height / 2.0;

        // 生成圆角矩形轮廓点
        var points: std.ArrayListUnmanaged([2]f32) = .{ .items = &.{}, .capacity = 0 };
        defer points.deinit(self.allocator);

        const segments: u32 = 8; // 每个圆角的段数
        const corners = [_][2]f32{
            .{ rect.x + rect.width - r, rect.y + r }, // top-right
            .{ rect.x + rect.width - r, rect.y + rect.height - r }, // bottom-right
            .{ rect.x + r, rect.y + rect.height - r }, // bottom-left
            .{ rect.x + r, rect.y + r }, // top-left
        };
        const start_angles = [_]f32{ -std.math.pi / 2.0, 0, std.math.pi / 2.0, std.math.pi };

        for (0..4) |corner_idx| {
            const cc = corners[corner_idx];
            const sa = start_angles[corner_idx];
            var s: u32 = 0;
            while (s <= segments) : (s += 1) {
                const angle = sa + @as(f32, @floatFromInt(s)) / @as(f32, @floatFromInt(segments)) * (std.math.pi / 2.0);
                const px = cc[0] + r * @cos(angle);
                const py = cc[1] + r * @sin(angle);
                try points.append(self.allocator, .{ px, py });
            }
        }

        // 中心扇形三角化
        const center = Vertex2D{ .pos = .{ cx, cy }, .color = c };
        const n = points.items.len;
        var i: usize = 0;
        while (i < n) : (i += 1) {
            const next = (i + 1) % n;
            try self.vertices.appendSlice(self.allocator, &.{
                center,
                .{ .pos = points.items[i], .color = c },
                .{ .pos = points.items[next], .color = c },
            });
        }
    }

    /// 绘制文本 (使用 glyph atlas + 纹理管线)
    pub fn drawText(self: *Renderer2D, tl: *const text_layout.TextLayout, origin_x: f32, origin_y: f32, color: math.Color) !void {
        const c = colorToFloat(color);

        for (tl.lines.items) |line| {
            const baseline_y = origin_y + line.baseline_y;

            for (line.glyphs.items) |glyph| {
                const entry = glyph.atlas_entry;
                if (entry.width == 0 or entry.height == 0) continue; // 空格等

                // glyph  quad 位置
                const gx = origin_x + glyph.x + @as(f32, @floatFromInt(entry.bearing_x));
                const gy = baseline_y - @as(f32, @floatFromInt(entry.bearing_y));
                const gw: f32 = @floatFromInt(entry.width);
                const gh: f32 = @floatFromInt(entry.height);

                // UV 坐标
                const uv_x0 = entry.uv_rect.x;
                const uv_y0 = entry.uv_rect.y;
                const uv_x1 = entry.uv_rect.x + entry.uv_rect.width;
                const uv_y1 = entry.uv_rect.y + entry.uv_rect.height;

                // 两个三角形
                try self.text_vertices.appendSlice(self.allocator, &.{
                    .{ .pos = .{ gx, gy }, .uv = .{ uv_x0, uv_y0 }, .color = c },
                    .{ .pos = .{ gx + gw, gy }, .uv = .{ uv_x1, uv_y0 }, .color = c },
                    .{ .pos = .{ gx, gy + gh }, .uv = .{ uv_x0, uv_y1 }, .color = c },
                    .{ .pos = .{ gx + gw, gy }, .uv = .{ uv_x1, uv_y0 }, .color = c },
                    .{ .pos = .{ gx + gw, gy + gh }, .uv = .{ uv_x1, uv_y1 }, .color = c },
                    .{ .pos = .{ gx, gy + gh }, .uv = .{ uv_x0, uv_y1 }, .color = c },
                });
            }
        }
    }

    /// 提交所有绘制到 GPU
    pub fn submit(self: *Renderer2D) void {
        // 1. 纯色几何
        if (self.vertices.items.len > 0) {
            self.device.updateVertices(self.vertices.items);
            self.device.drawTriangles(@intCast(self.vertices.items.len));
        }

        // 2. 文本 (纹理管线)
        if (self.text_vertices.items.len > 0) {
            if (self.glyph_atlas) |atlas| {
                // 先上传脏区域
                atlas.flush(self.device);

                if (atlas.texture) |tex| {
                    self.device.updateTextVertices(self.text_vertices.items);
                    self.device.drawTextured(@intCast(self.text_vertices.items.len), tex);
                }
            }
        }
    }

    fn colorToFloat(color: math.Color) [4]f32 {
        const a: f32 = @as(f32, @floatFromInt(color.a)) / 255.0;
        return .{
            @as(f32, @floatFromInt(color.r)) / 255.0 * a,
            @as(f32, @floatFromInt(color.g)) / 255.0 * a,
            @as(f32, @floatFromInt(color.b)) / 255.0 * a,
            a,
        };
    }
};
