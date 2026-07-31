//! D3D 2D 渲染器 (Windows) - 统一 D3D12/D3D11 路径
//!
//! 运行时自动选择 D3D12 (优先) 或 D3D11 (回退)。
//! 接口与 Vulkan Renderer2D / Metal Renderer2D 对齐, 供 Widget 系统跨平台使用。
//! 纹理以 *anyopaque 传递, 各后端内部装箱/拆箱 TextureHandle。

const std = @import("std");
const math = @import("../math.zig");
const png = @import("../image/png.zig");

const d3d12_mod = @import("../gpu/d3d12.zig");
const d3d11_mod = @import("../gpu/d3d11.zig");

const Vertex2D = d3d12_mod.Vertex2D;
const TextVertex = d3d12_mod.TextVertex;

/// 运行时 GPU 后端 (D3D12 优先, D3D11 回退)
pub const D3DBackend = union(enum) {
    d3d12: d3d12_mod.D3D12Device,
    d3d11: d3d11_mod.D3D11Device,

    /// 创建设备: 优先 D3D12, 失败回退 D3D11
    pub fn create(allocator: std.mem.Allocator, hwnd: *anyopaque, width: u32, height: u32) !D3DBackend {
        // 尝试 D3D12
        if (d3d12_mod.D3D12Device.init(allocator, hwnd, width, height)) |dev| {
            return .{ .d3d12 = dev };
        } else |_| {
            // D3D12 不可用, 回退 D3D11
            const dev = try d3d11_mod.D3D11Device.init(allocator, hwnd, width, height);
            return .{ .d3d11 = dev };
        }
    }

    pub fn deinit(self: *D3DBackend) void {
        switch (self.*) {
            .d3d12 => |*d| d.deinit(),
            .d3d11 => |*d| d.deinit(),
        }
    }

    pub fn beginFrame(self: *D3DBackend) ?[2]u32 {
        return switch (self.*) {
            .d3d12 => |*d| d.beginFrame(),
            .d3d11 => |*d| d.beginFrame(),
        };
    }

    pub fn endFrame(self: *D3DBackend) void {
        switch (self.*) {
            .d3d12 => |*d| d.endFrame(),
            .d3d11 => |*d| d.endFrame(),
        }
    }

    pub fn updateVertices(self: *D3DBackend, vertices: []const Vertex2D) u64 {
        return switch (self.*) {
            .d3d12 => |*d| d.updateVertices(vertices),
            .d3d11 => |*d| d.updateVertices(vertices),
        };
    }

    pub fn drawTriangles(self: *D3DBackend, vertex_count: u32, vertex_offset: u64) void {
        switch (self.*) {
            .d3d12 => |*d| d.drawTriangles(vertex_count, vertex_offset),
            .d3d11 => |*d| d.drawTriangles(vertex_count, vertex_offset),
        }
    }

    pub fn updateTextVertices(self: *D3DBackend, vertices: []const TextVertex) u64 {
        return switch (self.*) {
            .d3d12 => |*d| d.updateTextVertices(vertices),
            .d3d11 => |*d| d.updateTextVertices(vertices),
        };
    }

    pub fn drawTextured(self: *D3DBackend, vertex_count: u32, texture: *anyopaque, vertex_offset: u64) void {
        switch (self.*) {
            .d3d12 => |*d| {
                const boxed: *d3d12_mod.TextureHandle = @ptrCast(@alignCast(texture));
                d.drawTextured(vertex_count, boxed.*, vertex_offset);
            },
            .d3d11 => |*d| {
                const boxed: *d3d11_mod.TextureHandle = @ptrCast(@alignCast(texture));
                d.drawTextured(vertex_count, boxed.*, vertex_offset);
            },
        }
    }

    pub fn drawImage(self: *D3DBackend, vertices: []const TextVertex, texture: *anyopaque) void {
        switch (self.*) {
            .d3d12 => |*d| {
                const boxed: *d3d12_mod.TextureHandle = @ptrCast(@alignCast(texture));
                d.drawImage(vertices, boxed.*);
            },
            .d3d11 => |*d| {
                const boxed: *d3d11_mod.TextureHandle = @ptrCast(@alignCast(texture));
                d.drawImage(vertices, boxed.*);
            },
        }
    }

    pub fn drawTrianglesImmediate(self: *D3DBackend, vertices: []const Vertex2D) void {
        switch (self.*) {
            .d3d12 => |*d| d.drawTrianglesImmediate(vertices),
            .d3d11 => |*d| d.drawTrianglesImmediate(vertices),
        }
    }

    pub fn drawTexturedImmediate(self: *D3DBackend, vertices: []const TextVertex, texture: *anyopaque) void {
        switch (self.*) {
            .d3d12 => |*d| {
                const boxed: *d3d12_mod.TextureHandle = @ptrCast(@alignCast(texture));
                d.drawTexturedImmediate(vertices, boxed.*);
            },
            .d3d11 => |*d| {
                const boxed: *d3d11_mod.TextureHandle = @ptrCast(@alignCast(texture));
                d.drawTexturedImmediate(vertices, boxed.*);
            },
        }
    }

    pub fn setScissor(self: *D3DBackend, rect: ?math.Rect(f32)) void {
        switch (self.*) {
            .d3d12 => |*d| d.setScissor(rect),
            .d3d11 => |*d| d.setScissor(rect),
        }
    }

    pub fn setDrawableSize(self: *D3DBackend, width: u32, height: u32) void {
        switch (self.*) {
            .d3d12 => |*d| d.setDrawableSize(width, height),
            .d3d11 => |*d| d.setDrawableSize(width, height),
        }
    }

    pub fn setContentScale(self: *D3DBackend, scale: f32) void {
        switch (self.*) {
            .d3d12 => |*d| d.setContentScale(scale),
            .d3d11 => |*d| d.setContentScale(scale),
        }
    }

    // ── Texture (装箱为 *anyopaque) ──────────────────────────────────────────

    pub fn createTexture(self: *D3DBackend, allocator: std.mem.Allocator, width: u32, height: u32) !*anyopaque {
        switch (self.*) {
            .d3d12 => |*d| {
                const handle = d.createTexture(width, height) orelse return error.TextureCreateFailed;
                const boxed = try allocator.create(d3d12_mod.TextureHandle);
                boxed.* = handle;
                return @ptrCast(boxed);
            },
            .d3d11 => |*d| {
                const handle = d.createTexture(width, height) orelse return error.TextureCreateFailed;
                const boxed = try allocator.create(d3d11_mod.TextureHandle);
                boxed.* = handle;
                return @ptrCast(boxed);
            },
        }
    }

    pub fn createTextureRGBA(self: *D3DBackend, allocator: std.mem.Allocator, width: u32, height: u32) !*anyopaque {
        switch (self.*) {
            .d3d12 => |*d| {
                const handle = d.createTextureRGBA(width, height) orelse return error.TextureCreateFailed;
                const boxed = try allocator.create(d3d12_mod.TextureHandle);
                boxed.* = handle;
                return @ptrCast(boxed);
            },
            .d3d11 => |*d| {
                const handle = d.createTextureRGBA(width, height) orelse return error.TextureCreateFailed;
                const boxed = try allocator.create(d3d11_mod.TextureHandle);
                boxed.* = handle;
                return @ptrCast(boxed);
            },
        }
    }

    pub fn destroyTexture(self: *D3DBackend, allocator: std.mem.Allocator, texture: *anyopaque) void {
        switch (self.*) {
            .d3d12 => |*d| {
                const boxed: *d3d12_mod.TextureHandle = @ptrCast(@alignCast(texture));
                d.destroyTexture(boxed.*);
                allocator.destroy(boxed);
            },
            .d3d11 => |*d| {
                const boxed: *d3d11_mod.TextureHandle = @ptrCast(@alignCast(texture));
                d.destroyTexture(boxed.*);
                allocator.destroy(boxed);
            },
        }
    }

    pub fn updateTextureRegion(self: *D3DBackend, texture: *anyopaque, x: u32, y: u32, w: u32, h: u32, data: []const u8, data_stride: u32) void {
        switch (self.*) {
            .d3d12 => |*d| {
                const boxed: *d3d12_mod.TextureHandle = @ptrCast(@alignCast(texture));
                d.updateTextureRegion(boxed.*, x, y, w, h, data, data_stride);
            },
            .d3d11 => |*d| {
                const boxed: *d3d11_mod.TextureHandle = @ptrCast(@alignCast(texture));
                d.updateTextureRegion(boxed.*, x, y, w, h, data, data_stride);
            },
        }
    }

    pub fn updateTextureRegionRGBA(self: *D3DBackend, texture: *anyopaque, x: u32, y: u32, w: u32, h: u32, data: []const u8, data_stride: u32) void {
        switch (self.*) {
            .d3d12 => |*d| {
                const boxed: *d3d12_mod.TextureHandle = @ptrCast(@alignCast(texture));
                d.updateTextureRegionRGBA(boxed.*, x, y, w, h, data, data_stride);
            },
            .d3d11 => |*d| {
                const boxed: *d3d11_mod.TextureHandle = @ptrCast(@alignCast(texture));
                d.updateTextureRegionRGBA(boxed.*, x, y, w, h, data, data_stride);
            },
        }
    }

    pub fn prepareTextureForSampling(self: *D3DBackend, texture: *anyopaque) void {
        switch (self.*) {
            .d3d12 => |*d| {
                const boxed: *d3d12_mod.TextureHandle = @ptrCast(@alignCast(texture));
                d.prepareTextureForSampling(boxed.*);
            },
            .d3d11 => |*d| {
                const boxed: *d3d11_mod.TextureHandle = @ptrCast(@alignCast(texture));
                d.prepareTextureForSampling(boxed.*);
            },
        }
    }

    pub fn initTextureForTransfer(self: *D3DBackend, texture: *anyopaque) void {
        switch (self.*) {
            .d3d12 => |*d| {
                const boxed: *d3d12_mod.TextureHandle = @ptrCast(@alignCast(texture));
                d.initTextureForTransfer(boxed.*);
            },
            .d3d11 => |*d| {
                const boxed: *d3d11_mod.TextureHandle = @ptrCast(@alignCast(texture));
                d.initTextureForTransfer(boxed.*);
            },
        }
    }

    pub fn prepareTextureForTransfer(self: *D3DBackend, texture: *anyopaque) void {
        switch (self.*) {
            .d3d12 => |*d| {
                const boxed: *d3d12_mod.TextureHandle = @ptrCast(@alignCast(texture));
                d.prepareTextureForTransfer(boxed.*);
            },
            .d3d11 => |*d| {
                const boxed: *d3d11_mod.TextureHandle = @ptrCast(@alignCast(texture));
                d.prepareTextureForTransfer(boxed.*);
            },
        }
    }

    /// 返回后端类型字符串 (调试用)
    pub fn backendName(self: D3DBackend) []const u8 {
        return switch (self) {
            .d3d12 => "Direct3D 12",
            .d3d11 => "Direct3D 11",
        };
    }
};

/// 2D 渲染器 (接口与 Vulkan/Metal Renderer2D 对齐)
pub const Renderer2D = struct {
    device: *D3DBackend,
    vertices: std.ArrayListUnmanaged(Vertex2D) = .{ .items = &.{}, .capacity = 0 },
    text_vertices: std.ArrayListUnmanaged(TextVertex) = .{ .items = &.{}, .capacity = 0 },
    allocator: std.mem.Allocator,
    /// 字形图集纹理 (R8, 由外部创建并设置)
    glyph_atlas_texture: ?*anyopaque = null,
    /// 字形图集脏标记回调 (由外部设置, flush 时调用以上传脏区域)
    glyph_atlas_flush_fn: ?*const fn (device: *D3DBackend) void = null,
    /// 当前裁剪矩形 (null = 全屏)
    clip: ?math.Rect(f32) = null,
    /// 图片顶点与批次
    image_vertices: std.ArrayListUnmanaged(TextVertex) = .{ .items = &.{}, .capacity = 0 },
    image_runs: std.ArrayListUnmanaged(ImageRun) = .{ .items = &.{}, .capacity = 0 },

    pub const ImageRun = struct {
        texture: *anyopaque,
        start: usize,
        count: usize,
    };

    pub fn init(allocator: std.mem.Allocator, device: *D3DBackend) Renderer2D {
        return .{ .device = device, .allocator = allocator };
    }

    pub fn deinit(self: *Renderer2D) void {
        self.vertices.deinit(self.allocator);
        self.text_vertices.deinit(self.allocator);
        self.image_vertices.deinit(self.allocator);
        self.image_runs.deinit(self.allocator);
    }

    pub fn beginFrame(self: *Renderer2D) void {
        self.vertices.clearRetainingCapacity();
        self.text_vertices.clearRetainingCapacity();
        self.image_vertices.clearRetainingCapacity();
        self.image_runs.clearRetainingCapacity();
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
        try self.appendRoundedContour(&points, rect, r, 8);

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

    /// 填充圆环 (描边圆)
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
            try self.vertices.appendSlice(self.allocator, &.{
                .{ .pos = .{ cx + ro * @cos(a0), cy + ro * @sin(a0) }, .color = c },
                .{ .pos = .{ cx + ro * @cos(a1), cy + ro * @sin(a1) }, .color = c },
                .{ .pos = .{ cx + ri * @cos(a0), cy + ri * @sin(a0) }, .color = c },
                .{ .pos = .{ cx + ro * @cos(a1), cy + ro * @sin(a1) }, .color = c },
                .{ .pos = .{ cx + ri * @cos(a1), cy + ri * @sin(a1) }, .color = c },
                .{ .pos = .{ cx + ri * @cos(a0), cy + ri * @sin(a0) }, .color = c },
            });
        }
    }

    /// 填充凸多边形
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

    /// 描边圆角矩形边框
    pub fn strokeRect(self: *Renderer2D, rect: math.Rect(f32), border_width: f32, color: math.Color) !void {
        return self.strokeRoundedRect(rect, 0, border_width, color);
    }

    pub fn strokeRoundedRect(self: *Renderer2D, rect: math.Rect(f32), radius: f32, border_width: f32, color: math.Color) !void {
        if (border_width <= 0 or rect.width <= 0 or rect.height <= 0) return;

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

    /// 绘制文本 (使用 glyph atlas + 纹理管线)
    /// glyphs: 任意具有 .x/.y/.atlas_entry 字段的 glyph 切片 (duck typing)
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
            if (self.glyph_atlas_flush_fn) |flush_fn| {
                flush_fn(self.device);
            }
            if (self.glyph_atlas_texture) |tex| {
                const offset = self.device.updateTextVertices(self.text_vertices.items);
                self.device.drawTextured(@intCast(self.text_vertices.items.len), tex, offset);
            }
            self.text_vertices.clearRetainingCapacity();
        }

        // 3. 图片 (RGBA 纹理管线)
        for (self.image_runs.items) |run| {
            self.device.drawImage(
                self.image_vertices.items[run.start .. run.start + run.count],
                run.texture,
            );
        }
        self.image_vertices.clearRetainingCapacity();
        self.image_runs.clearRetainingCapacity();
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
            if (self.glyph_atlas_flush_fn) |flush_fn| {
                flush_fn(self.device);
            }
            if (self.glyph_atlas_texture) |tex| {
                const offset = self.device.updateTextVertices(self.text_vertices.items);
                self.device.drawTextured(@intCast(self.text_vertices.items.len), tex, offset);
            }
        }

        // 3. 图片 (RGBA 纹理管线)
        for (self.image_runs.items) |run| {
            self.device.drawImage(
                self.image_vertices.items[run.start .. run.start + run.count],
                run.texture,
            );
        }
    }

    /// 压入裁剪矩形 (先 flush 已累积几何以保持 z 序, 再设 scissor)
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

    // ── 纹理 (RGBA 图片) ───────────────────────────────────────────────

    /// 从 RGBA 像素数据创建纹理
    pub fn createTextureFromRgba(self: *Renderer2D, width: u32, height: u32, pixels: []const u8) !*anyopaque {
        const tex = try self.device.createTextureRGBA(self.allocator, width, height);
        self.device.updateTextureRegionRGBA(tex, 0, 0, width, height, pixels, width * 4);
        self.device.prepareTextureForSampling(tex);
        return tex;
    }

    /// 从 PNG 数据解码并创建 RGBA 纹理
    pub fn createTextureFromPng(self: *Renderer2D, png_data: []const u8) !*anyopaque {
        var img = try png.decode(self.allocator, png_data);
        defer img.deinit(self.allocator);
        return self.createTextureFromRgba(img.width, img.height, img.pixels);
    }

    /// 销毁纹理
    pub fn destroyTexture(self: *Renderer2D, texture: *anyopaque) void {
        self.device.destroyTexture(self.allocator, texture);
    }

    /// 立即绘制图片四边形 (不进入批处理)
    pub fn drawImageImmediate(self: *Renderer2D, texture: *anyopaque, dst: math.Rect(f32), src: math.Rect(f32), tint: math.Color) void {
        self.flush();
        const c = colorToFloatStraight(tint);
        const x0 = dst.x;
        const y0 = dst.y;
        const x1 = dst.x + dst.width;
        const y1 = dst.y + dst.height;
        const su0 = src.x;
        const sv0 = src.y;
        const su1 = src.x + src.width;
        const sv1 = src.y + src.height;

        const verts = [6]TextVertex{
            .{ .pos = .{ x0, y0 }, .uv = .{ su0, sv0 }, .color = c },
            .{ .pos = .{ x1, y0 }, .uv = .{ su1, sv0 }, .color = c },
            .{ .pos = .{ x0, y1 }, .uv = .{ su0, sv1 }, .color = c },
            .{ .pos = .{ x1, y0 }, .uv = .{ su1, sv0 }, .color = c },
            .{ .pos = .{ x1, y1 }, .uv = .{ su1, sv1 }, .color = c },
            .{ .pos = .{ x0, y1 }, .uv = .{ su0, sv1 }, .color = c },
        };
        self.device.drawImage(&verts, texture);
    }

    /// 绘制图片 (整张纹理 -> 目标矩形)
    pub fn drawImage(self: *Renderer2D, texture: *anyopaque, dst: math.Rect(f32), tint: math.Color) !void {
        self.drawImageImmediate(texture, dst, .{ .x = 0, .y = 0, .width = 1, .height = 1 }, tint);
    }

    /// 绘制图片子区域
    pub fn drawImageRect(self: *Renderer2D, texture: *anyopaque, dst: math.Rect(f32), src: math.Rect(f32), tint: math.Color) !void {
        const c = colorToFloatStraight(tint);
        const x0 = dst.x;
        const y0 = dst.y;
        const x1 = dst.x + dst.width;
        const y1 = dst.y + dst.height;
        const su0 = src.x;
        const sv0 = src.y;
        const su1 = src.x + src.width;
        const sv1 = src.y + src.height;

        try self.image_vertices.appendSlice(self.allocator, &.{
            .{ .pos = .{ x0, y0 }, .uv = .{ su0, sv0 }, .color = c },
            .{ .pos = .{ x1, y0 }, .uv = .{ su1, sv0 }, .color = c },
            .{ .pos = .{ x0, y1 }, .uv = .{ su0, sv1 }, .color = c },
            .{ .pos = .{ x1, y0 }, .uv = .{ su1, sv0 }, .color = c },
            .{ .pos = .{ x1, y1 }, .uv = .{ su1, sv1 }, .color = c },
            .{ .pos = .{ x0, y1 }, .uv = .{ su0, sv1 }, .color = c },
        });

        if (self.image_runs.items.len > 0) {
            const last = &self.image_runs.items[self.image_runs.items.len - 1];
            if (last.texture == texture) {
                last.count += 6;
                return;
            }
        }
        try self.image_runs.append(self.allocator, .{
            .texture = texture,
            .start = self.image_vertices.items.len - 6,
            .count = 6,
        });
    }

    /// 绘制文本布局 (跨平台统一入口)
    pub fn drawTextLayout(self: *Renderer2D, tl: anytype, origin_x: f32, origin_y: f32, color: math.Color) !void {
        for (tl.lines.items) |line| {
            const baseline_y = origin_y + line.baseline_y;
            try self.drawText(line.glyphs.items, origin_x, baseline_y, color);
        }
    }
};

/// 空裁剪矩形
fn emptyRect(ref: math.Rect(f32)) math.Rect(f32) {
    return .{ .x = ref.x, .y = ref.y, .width = 0, .height = 0 };
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
