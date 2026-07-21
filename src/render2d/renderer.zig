//! 基础 2D 渲染器 (macOS Metal 路径)

const metal = @import("../gpu/metal.zig");
const math = @import("../math.zig");

const Vertex2D = metal.Vertex2D;

pub const Renderer2D = struct {
    device: *metal.MetalDevice,
    vertices: std.ArrayListUnmanaged(Vertex2D) = .{ .items = &.{}, .capacity = 0 },
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator, device: *metal.MetalDevice) Renderer2D {
        return .{ .device = device, .allocator = allocator };
    }

    pub fn deinit(self: *Renderer2D) void {
        self.vertices.deinit(self.allocator);
    }

    pub fn beginFrame(self: *Renderer2D) void {
        self.vertices.clearRetainingCapacity();
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

    /// 提交所有绘制到 GPU
    pub fn submit(self: *Renderer2D) void {
        if (self.vertices.items.len == 0) return;
        self.device.updateVertices(self.vertices.items);
        self.device.drawTriangles(@intCast(self.vertices.items.len));
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

const std = @import("std");
