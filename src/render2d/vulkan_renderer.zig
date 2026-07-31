//! 基础 2D 渲染器 (Linux Vulkan 路径)

const std = @import("std");
const builtin = @import("builtin");
const is_windows = builtin.os.tag == .windows;
const is_linux = builtin.os.tag == .linux;
const vulkan = @import("../gpu/vulkan.zig");
const math = @import("../math.zig");
const atlas_mod = if (is_windows) @import("../text/atlas_vulkan_win32.zig") else @import("../text/atlas_vulkan.zig");
const text_layout_ft = if (is_linux) @import("../text/layout_ft.zig") else void;
const png = @import("../image/png.zig");

const Vertex2D = vulkan.Vertex2D;
const TextVertex = vulkan.TextVertex;

pub const Renderer2D = struct {
    device: *vulkan.VulkanDevice,
    vertices: std.ArrayListUnmanaged(Vertex2D) = .{ .items = &.{}, .capacity = 0 },
    text_vertices: std.ArrayListUnmanaged(TextVertex) = .{ .items = &.{}, .capacity = 0 },
    allocator: std.mem.Allocator,
    glyph_atlas: ?*atlas_mod.GlyphAtlas = null,
    /// 当前裁剪矩形 (null = 全屏; 由 pushClip/popClip 管理, 供 ScrollView 裁剪溢出子控件)
    clip: ?math.Rect(f32) = null,

    pub fn init(allocator: std.mem.Allocator, device: *vulkan.VulkanDevice) Renderer2D {
        return .{ .device = device, .allocator = allocator };
    }

    pub fn deinit(self: *Renderer2D) void {
        self.vertices.deinit(self.allocator);
        self.text_vertices.deinit(self.allocator);
    }

    pub fn beginFrame(self: *Renderer2D) void {
        self.vertices.clearRetainingCapacity();
        self.text_vertices.clearRetainingCapacity();
        self.clip = null;
        self.device.setScissor(null);
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

        var points: std.ArrayListUnmanaged([2]f32) = .{ .items = &.{}, .capacity = 0 };
        defer points.deinit(self.allocator);

        const segments: u32 = 8;
        const corners = [_][2]f32{
            .{ rect.x + rect.width - r, rect.y + r },
            .{ rect.x + rect.width - r, rect.y + rect.height - r },
            .{ rect.x + r, rect.y + rect.height - r },
            .{ rect.x + r, rect.y + r },
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

    /// 填充圆形 (中心扇形三角化)
    pub fn fillCircle(self: *Renderer2D, cx: f32, cy: f32, radius: f32, color: math.Color) !void {
        if (radius <= 0) return;
        const c = colorToFloat(color);
        const center = Vertex2D{ .pos = .{ cx, cy }, .color = c };
        const segments: u32 = 24;
        var i: u32 = 0;
        while (i < segments) : (i += 1) {
            const a0 = @as(f32, @floatFromInt(i)) / @as(f32, @floatFromInt(segments)) * 2.0 * std.math.pi;
            const a1 = @as(f32, @floatFromInt(i + 1)) / @as(f32, @floatFromInt(segments)) * 2.0 * std.math.pi;
            try self.vertices.appendSlice(self.allocator, &.{
                center,
                .{ .pos = .{ cx + radius * @cos(a0), cy + radius * @sin(a0) }, .color = c },
                .{ .pos = .{ cx + radius * @cos(a1), cy + radius * @sin(a1) }, .color = c },
            });
        }
    }

    /// 填充圆环 (描边圆: 外半径 r_outer 减内半径 r_inner 的环形区域)
    pub fn fillRing(self: *Renderer2D, cx: f32, cy: f32, r_outer: f32, r_inner: f32, color: math.Color) !void {
        if (r_outer <= 0) return;
        const ro = r_outer;
        const ri = @max(0.0, r_inner);
        if (ri >= ro) return;
        const c = colorToFloat(color);
        const segments: u32 = 24;
        var i: u32 = 0;
        while (i < segments) : (i += 1) {
            const a0 = @as(f32, @floatFromInt(i)) / @as(f32, @floatFromInt(segments)) * 2.0 * std.math.pi;
            const a1 = @as(f32, @floatFromInt(i + 1)) / @as(f32, @floatFromInt(segments)) * 2.0 * std.math.pi;
            const ox0 = cx + ro * @cos(a0);
            const oy0 = cy + ro * @sin(a0);
            const ox1 = cx + ro * @cos(a1);
            const oy1 = cy + ro * @sin(a1);
            const ix0 = cx + ri * @cos(a0);
            const iy0 = cy + ri * @sin(a0);
            const ix1 = cx + ri * @cos(a1);
            const iy1 = cy + ri * @sin(a1);
            try self.vertices.appendSlice(self.allocator, &.{
                .{ .pos = .{ ox0, oy0 }, .color = c },
                .{ .pos = .{ ox1, oy1 }, .color = c },
                .{ .pos = .{ ix0, iy0 }, .color = c },
                .{ .pos = .{ ox1, oy1 }, .color = c },
                .{ .pos = .{ ix1, iy1 }, .color = c },
                .{ .pos = .{ ix0, iy0 }, .color = c },
            });
        }
    }

    /// 填充凸多边形 (从首点扇形三角化; 调用者保证凸性)
    pub fn fillConvexPolygon(self: *Renderer2D, points: []const [2]f32, color: math.Color) !void {
        if (points.len < 3) return;
        const c = colorToFloat(color);
        const p0 = Vertex2D{ .pos = points[0], .color = c };
        var i: usize = 1;
        while (i + 1 < points.len) : (i += 1) {
            try self.vertices.appendSlice(self.allocator, &.{
                p0,
                .{ .pos = points[i], .color = c },
                .{ .pos = points[i + 1], .color = c },
            });
        }
    }

    /// 阴影样式
    pub const ShadowStyle = struct {
        color: math.Color = math.Color.rgba(0, 0, 0, 140),
        blur_radius: f32 = 16.0,
        offset_x: f32 = 0.0,
        offset_y: f32 = 6.0,
        spread: f32 = 0.0,
        layers: u32 = 10,
    };

    /// 绘制柔和阴影
    pub fn drawShadow(self: *Renderer2D, rect: math.Rect(f32), radius: f32, style: ShadowStyle) !void {
        const steps = @max(@as(u32, 2), style.layers);
        var s: u32 = steps;
        while (s >= 1) : (s -= 1) {
            const f = @as(f32, @floatFromInt(s)) / @as(f32, @floatFromInt(steps));
            const expand = style.spread + style.blur_radius * f;
            const alpha_scale = (1.0 - f) * (1.0 - f);
            const layer_color = scaleAlpha(style.color, alpha_scale);
            if (layer_color.a == 0) continue;

            const layer_rect = math.Rect(f32){
                .x = rect.x - expand + style.offset_x,
                .y = rect.y - expand + style.offset_y,
                .width = rect.width + expand * 2.0,
                .height = rect.height + expand * 2.0,
            };
            const layer_radius = @min(radius + expand, @min(layer_rect.width, layer_rect.height) / 2.0);
            try self.fillRoundedRect(layer_rect, layer_radius, layer_color);
        }
    }

    /// 绘制文本 (使用 glyph atlas + 纹理管线)
    /// glyphs: 任意具有 .x/.y/.atlas_entry 字段的 glyph 切片 (duck typing),
    ///         兼容本模块 PlacedGlyph 与 text/layout_ft.zig 的 PlacedGlyph
    pub fn drawText(self: *Renderer2D, glyphs: anytype, origin_x: f32, origin_y: f32, color: math.Color) !void {
        const c = colorToFloat(color);

        for (glyphs) |glyph| {
            const entry = glyph.atlas_entry;
            if (entry.width == 0 or entry.height == 0) continue;

            const gx = origin_x + glyph.x + @as(f32, @floatFromInt(entry.bearing_x));
            const gy = origin_y + glyph.y - @as(f32, @floatFromInt(entry.bearing_y));
            const gw: f32 = @floatFromInt(entry.width);
            const gh: f32 = @floatFromInt(entry.height);

            const uv_x0 = entry.uv_rect.x;
            const uv_y0 = entry.uv_rect.y;
            const uv_x1 = entry.uv_rect.x + entry.uv_rect.width;
            const uv_y1 = entry.uv_rect.y + entry.uv_rect.height;

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

    /// 提交所有绘制到 GPU
    pub fn submit(self: *Renderer2D) void {
        // 1. 纯色几何
        if (self.vertices.items.len > 0) {
            const offset = self.device.updateVertices(self.vertices.items);
            self.device.drawTriangles(@intCast(self.vertices.items.len), offset);
        }

        // 2. 文本 (纹理管线)
        if (self.text_vertices.items.len > 0) {
            if (self.glyph_atlas) |atlas| {
                atlas.flush(self.device);
                if (atlas.texture) |tex| {
                    const offset = self.device.updateTextVertices(self.text_vertices.items);
                    self.device.drawTextured(@intCast(self.text_vertices.items.len), tex.view, offset);
                }
            }
        }
    }

    /// 立即提交当前累积的几何 (帧内可多次调用, 保持绘制顺序)
    pub fn flush(self: *Renderer2D) void {
        // 1. 纯色几何
        if (self.vertices.items.len > 0) {
            const offset = self.device.updateVertices(self.vertices.items);
            self.device.drawTriangles(@intCast(self.vertices.items.len), offset);
            self.vertices.clearRetainingCapacity();
        }

        // 2. 文本 (纹理管线)
        if (self.text_vertices.items.len > 0) {
            if (self.glyph_atlas) |atlas| {
                atlas.flush(self.device);
                if (atlas.texture) |tex| {
                    const offset = self.device.updateTextVertices(self.text_vertices.items);
                    self.device.drawTextured(@intCast(self.text_vertices.items.len), tex.view, offset);
                }
            }
            self.text_vertices.clearRetainingCapacity();
        }
    }

    /// 压入裁剪矩形 (先 flush 已累积几何以保持 z 序, 再设 scissor)。
    /// 嵌套时与当前裁剪取交集。返回之前的裁剪供 popClip 恢复。
    pub fn pushClip(self: *Renderer2D, rect: math.Rect(f32)) ?math.Rect(f32) {
        self.flush();
        const prev = self.clip;
        const new_clip = if (prev) |p| (p.intersection(rect) orelse emptyRect(rect)) else rect;
        self.clip = new_clip;
        self.device.setScissor(new_clip);
        return prev;
    }

    /// 弹出裁剪 (恢复 prev; 先 flush 再设 scissor)
    pub fn popClip(self: *Renderer2D, prev: ?math.Rect(f32)) void {
        self.flush();
        self.clip = prev;
        self.device.setScissor(prev);
    }

    /// 描边圆角矩形边框 (内外轮廓环形三角化)
    pub fn strokeRect(self: *Renderer2D, rect: math.Rect(f32), border_width: f32, color: math.Color) !void {
        return self.strokeRoundedRect(rect, 0, border_width, color);
    }

    pub fn strokeRoundedRect(self: *Renderer2D, rect: math.Rect(f32), radius: f32, border_width: f32, color: math.Color) !void {
        if (border_width <= 0 or rect.width <= 0 or rect.height <= 0) return;

        // 直角情况: 4 条边框矩形
        if (radius <= 0) {
            const bw = @min(border_width, @min(rect.width, rect.height) / 2.0);
            try self.fillRect(.{ .x = rect.x, .y = rect.y, .width = rect.width, .height = bw }, color);
            try self.fillRect(.{ .x = rect.x, .y = rect.y + rect.height - bw, .width = rect.width, .height = bw }, color);
            try self.fillRect(.{ .x = rect.x, .y = rect.y + bw, .width = bw, .height = rect.height - bw * 2.0 }, color);
            try self.fillRect(.{ .x = rect.x + rect.width - bw, .y = rect.y + bw, .width = bw, .height = rect.height - bw * 2.0 }, color);
            return;
        }

        const r_out = @min(radius, @min(rect.width, rect.height) / 2.0);
        const inner = math.Rect(f32){
            .x = rect.x + border_width,
            .y = rect.y + border_width,
            .width = rect.width - border_width * 2.0,
            .height = rect.height - border_width * 2.0,
        };
        if (inner.width <= 0 or inner.height <= 0) {
            return self.fillRoundedRect(rect, r_out, color);
        }
        const r_in = @max(0.0, r_out - border_width);

        var outer: std.ArrayListUnmanaged([2]f32) = .{ .items = &.{}, .capacity = 0 };
        defer outer.deinit(self.allocator);
        var inner_pts: std.ArrayListUnmanaged([2]f32) = .{ .items = &.{}, .capacity = 0 };
        defer inner_pts.deinit(self.allocator);
        try self.appendRoundedContour(&outer, rect, r_out, 8);
        try self.appendRoundedContour(&inner_pts, inner, r_in, 8);

        const c = colorToFloat(color);
        const n = outer.items.len;
        var i: usize = 0;
        while (i < n) : (i += 1) {
            const j = (i + 1) % n;
            const o0 = Vertex2D{ .pos = outer.items[i], .color = c };
            const o1 = Vertex2D{ .pos = outer.items[j], .color = c };
            const n0 = Vertex2D{ .pos = inner_pts.items[i], .color = c };
            const n1 = Vertex2D{ .pos = inner_pts.items[j], .color = c };
            try self.vertices.appendSlice(self.allocator, &.{ o0, o1, n0, o1, n1, n0 });
        }
    }

    /// 生成圆角矩形轮廓点
    fn appendRoundedContour(self: *Renderer2D, points: *std.ArrayListUnmanaged([2]f32), rect: math.Rect(f32), radius: f32, segments: u32) !void {
        const r = @min(radius, @min(rect.width, rect.height) / 2.0);
        const corners = [_][2]f32{
            .{ rect.x + rect.width - r, rect.y + r },
            .{ rect.x + rect.width - r, rect.y + rect.height - r },
            .{ rect.x + r, rect.y + rect.height - r },
            .{ rect.x + r, rect.y + r },
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
    }

    /// 绘制文本布局 (多行, 镜像 Metal renderer.drawText)
    /// tl 在 Linux 上为 *const text_layout_ft.TextLayout; 其他平台 (Windows) 暂未实现多行布局。
    pub fn drawTextLayout(self: *Renderer2D, tl: *const anyopaque, origin_x: f32, origin_y: f32, color: math.Color) !void {
        if (comptime is_linux) {
            const real = @as(*const text_layout_ft.TextLayout, @alignCast(@ptrCast(tl)));
            for (real.lines.items) |line| {
                const baseline_y = origin_y + line.baseline_y;
                try self.drawText(line.glyphs.items, origin_x, baseline_y, color);
            }
            return;
        }
        return;
    }

    // ── 纹理 (RGBA 图片) ───────────────────────────────────────────────

    /// 从 RGBA 像素数据创建纹理 (堆装箱 TextureHandle 为 *anyopaque)
    pub fn createTextureFromRgba(self: *Renderer2D, width: u32, height: u32, pixels: []const u8) !*anyopaque {
        const handle = self.device.createTextureRGBA(width, height) orelse
            return error.TextureCreateFailed;
        self.device.updateTextureRegionRGBA(handle, 0, 0, width, height, pixels, width * 4);
        self.device.prepareTextureForSampling(handle);
        // 堆装箱: TextureHandle 值类型 → *anyopaque
        const boxed = try self.allocator.create(vulkan.TextureHandle);
        boxed.* = handle;
        return @ptrCast(boxed);
    }

    /// 从 PNG 数据解码并创建 RGBA 纹理
    pub fn createTextureFromPng(self: *Renderer2D, png_data: []const u8) !*anyopaque {
        var img = try png.decode(self.allocator, png_data);
        defer img.deinit(self.allocator);
        return self.createTextureFromRgba(img.width, img.height, img.pixels);
    }

    /// 销毁纹理 (解箱 *anyopaque → TextureHandle)
    pub fn destroyTexture(self: *Renderer2D, texture: *anyopaque) void {
        const boxed: *vulkan.TextureHandle = @ptrCast(@alignCast(texture));
        self.device.destroyTexture(boxed.*);
        self.allocator.destroy(boxed);
    }

    /// 立即绘制图片四边形 (不进入批处理, 经 flush + drawImage 直接提交)
    pub fn drawImageImmediate(self: *Renderer2D, texture: *anyopaque, dst: math.Rect(f32), src: math.Rect(f32), tint: math.Color) void {
        const boxed: *vulkan.TextureHandle = @ptrCast(@alignCast(texture));
        const c = colorToFloatStraight(tint);
        const x0 = dst.x;
        const y0 = dst.y;
        const x1 = dst.x + dst.width;
        const y1 = dst.y + dst.height;
        const su0 = src.x;
        const sv0 = src.y;
        const su1 = src.x + src.width;
        const sv1 = src.y + src.height;

        const verts = [6]vulkan.TextVertex{
            .{ .pos = .{ x0, y0 }, .uv = .{ su0, sv0 }, .color = c },
            .{ .pos = .{ x1, y0 }, .uv = .{ su1, sv0 }, .color = c },
            .{ .pos = .{ x0, y1 }, .uv = .{ su0, sv1 }, .color = c },
            .{ .pos = .{ x1, y0 }, .uv = .{ su1, sv0 }, .color = c },
            .{ .pos = .{ x1, y1 }, .uv = .{ su1, sv1 }, .color = c },
            .{ .pos = .{ x0, y1 }, .uv = .{ su0, sv1 }, .color = c },
        };
        self.device.drawImage(&verts, boxed.view);
    }

    /// 绘制图片 (整张纹理 → 目标矩形)
    pub fn drawImage(self: *Renderer2D, texture: *anyopaque, dst: math.Rect(f32), tint: math.Color) !void {
        self.drawImageImmediate(texture, dst, .{ .x = 0, .y = 0, .width = 1, .height = 1 }, tint);
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

    /// 直色转换 (不预乘), 供 image 管线使用 (shader 内部预乘)
    fn colorToFloatStraight(color: math.Color) [4]f32 {
        return .{
            @as(f32, @floatFromInt(color.r)) / 255.0,
            @as(f32, @floatFromInt(color.g)) / 255.0,
            @as(f32, @floatFromInt(color.b)) / 255.0,
            @as(f32, @floatFromInt(color.a)) / 255.0,
        };
    }

    fn scaleAlpha(color: math.Color, scale: f32) math.Color {
        const a = @as(f32, @floatFromInt(color.a)) * std.math.clamp(scale, 0.0, 1.0);
        return .{
            .r = color.r,
            .g = color.g,
            .b = color.b,
            .a = @intFromFloat(@min(255.0, @round(a))),
        };
    }
};

/// 空裁剪矩形 (不相交时裁剪一切, 保留位置于参考 rect 内)
fn emptyRect(ref: math.Rect(f32)) math.Rect(f32) {
    return .{ .x = ref.x, .y = ref.y, .width = 0, .height = 0 };
}

/// 放置的 glyph (用于文本渲染)
pub const PlacedGlyph = struct {
    glyph_id: u32,
    x: f32,
    y: f32,
    advance: f32,
    atlas_entry: atlas_mod.GlyphAtlas.AtlasEntry,
};
