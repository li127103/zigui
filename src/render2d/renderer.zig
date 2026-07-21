//! 基础 2D 渲染器 (macOS Metal 路径)

const std = @import("std");
const metal = @import("../gpu/metal.zig");
const math = @import("../math.zig");
const text_layout = @import("../text/layout.zig");
const atlas_mod = @import("../text/atlas.zig");
const png = @import("../image/png.zig");

const Vertex2D = metal.Vertex2D;
const TextVertex = metal.TextVertex;

pub const Renderer2D = struct {
    device: *metal.MetalDevice,
    vertices: std.ArrayListUnmanaged(Vertex2D) = .{ .items = &.{}, .capacity = 0 },
    text_vertices: std.ArrayListUnmanaged(TextVertex) = .{ .items = &.{}, .capacity = 0 },
    allocator: std.mem.Allocator,
    glyph_atlas: ?*atlas_mod.GlyphAtlas = null,

    /// 图片顶点 (与 text_vertices 同布局，走独立 image 管线)
    image_vertices: std.ArrayListUnmanaged(TextVertex) = .{ .items = &.{}, .capacity = 0 },
    /// 连续同纹理的图片绘制段
    image_runs: std.ArrayListUnmanaged(ImageRun) = .{ .items = &.{}, .capacity = 0 },

    pub const ImageRun = struct {
        texture: *anyopaque,
        start: usize,
        count: usize,
    };

    pub fn init(allocator: std.mem.Allocator, device: *metal.MetalDevice) Renderer2D {
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

    /// 阴影样式
    pub const ShadowStyle = struct {
        /// 阴影颜色 (含基础不透明度)
        color: math.Color = math.Color.rgba(0, 0, 0, 140),
        /// 模糊半径 (向外扩散的像素, 由多层叠加近似)
        blur_radius: f32 = 16.0,
        /// 偏移
        offset_x: f32 = 0.0,
        offset_y: f32 = 6.0,
        /// 额外扩散 (不随模糊衰减)
        spread: f32 = 0.0,
        /// 叠加层数 (越多越平滑)
        layers: u32 = 10,
    };

    /// 绘制柔和阴影 (在目标圆角矩形之下调用)。
    /// 用多层同心圆角矩形由外到内、透明度递增叠加, 近似高斯模糊投影。
    pub fn drawShadow(self: *Renderer2D, rect: math.Rect(f32), radius: f32, style: ShadowStyle) !void {
        const steps = @max(@as(u32, 2), style.layers);
        var s: u32 = steps;
        // 从最外层 (最大最淡) 画到最内层 (最小最浓), 重叠累积形成柔和过渡
        while (s >= 1) : (s -= 1) {
            const f = @as(f32, @floatFromInt(s)) / @as(f32, @floatFromInt(steps)); // 1.0(外) → ~0(内)
            const expand = style.spread + style.blur_radius * f;
            // 外层淡, 内层浓; 平方衰减使过渡更自然
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

    /// 绘制文本并裁剪到矩形 (输入框溢出裁剪 / 横向滚动)。
    /// 对部分可见的 glyph 同时裁剪其位置与 UV, 保证只显示 clip 区域内的部分。
    pub fn drawTextClipped(self: *Renderer2D, tl: *const text_layout.TextLayout, origin_x: f32, origin_y: f32, color: math.Color, clip: math.Rect(f32)) !void {
        const c = colorToFloat(color);
        const cx0 = clip.x;
        const cx1 = clip.x + clip.width;
        const cy0 = clip.y;
        const cy1 = clip.y + clip.height;

        for (tl.lines.items) |line| {
            const baseline_y = origin_y + line.baseline_y;

            for (line.glyphs.items) |glyph| {
                const entry = glyph.atlas_entry;
                if (entry.width == 0 or entry.height == 0) continue; // 空格等

                const gx = origin_x + glyph.x + @as(f32, @floatFromInt(entry.bearing_x));
                const gy = baseline_y - @as(f32, @floatFromInt(entry.bearing_y));
                const gw: f32 = @floatFromInt(entry.width);
                const gh: f32 = @floatFromInt(entry.height);

                // 完全在裁剪区外: 跳过
                if (gx + gw <= cx0 or gx >= cx1 or gy + gh <= cy0 or gy >= cy1) continue;

                // 可见比例 (0..1)
                const vis_x0 = @max(0.0, (cx0 - gx) / gw);
                const vis_x1 = @min(1.0, (cx1 - gx) / gw);
                const vis_y0 = @max(0.0, (cy0 - gy) / gh);
                const vis_y1 = @min(1.0, (cy1 - gy) / gh);
                if (vis_x1 <= vis_x0 or vis_y1 <= vis_y0) continue;

                const uv_w = entry.uv_rect.width;
                const uv_h = entry.uv_rect.height;
                const px0 = gx + vis_x0 * gw;
                const px1 = gx + vis_x1 * gw;
                const py0 = gy + vis_y0 * gh;
                const py1 = gy + vis_y1 * gh;
                const tex_u0 = entry.uv_rect.x + vis_x0 * uv_w;
                const tex_u1 = entry.uv_rect.x + vis_x1 * uv_w;
                const tex_v0 = entry.uv_rect.y + vis_y0 * uv_h;
                const tex_v1 = entry.uv_rect.y + vis_y1 * uv_h;

                try self.text_vertices.appendSlice(self.allocator, &.{
                    .{ .pos = .{ px0, py0 }, .uv = .{ tex_u0, tex_v0 }, .color = c },
                    .{ .pos = .{ px1, py0 }, .uv = .{ tex_u1, tex_v0 }, .color = c },
                    .{ .pos = .{ px0, py1 }, .uv = .{ tex_u0, tex_v1 }, .color = c },
                    .{ .pos = .{ px1, py0 }, .uv = .{ tex_u1, tex_v0 }, .color = c },
                    .{ .pos = .{ px1, py1 }, .uv = .{ tex_u1, tex_v1 }, .color = c },
                    .{ .pos = .{ px0, py1 }, .uv = .{ tex_u0, tex_v1 }, .color = c },
                });
            }
        }
    }

    /// 绘制图片 (整张纹理 → 目标矩形, tint 为叠加色调/透明度)
    pub fn drawImage(self: *Renderer2D, texture: *anyopaque, dst: math.Rect(f32), tint: math.Color) !void {
        try self.drawImageRect(texture, dst, .{ .x = 0, .y = 0, .width = 1, .height = 1 }, tint);
    }

    /// 绘制图片子区域 (src 为归一化 UV 矩形) 到目标矩形
    pub fn drawImageRect(self: *Renderer2D, texture: *anyopaque, dst: math.Rect(f32), src: math.Rect(f32), tint: math.Color) !void {
        // 注意: image shader 内部自行预乘, 这里必须传直色 (非预乘)
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

        // 合并连续同纹理段
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

    /// 从 PNG 数据解码并创建 RGBA 纹理 (调用方负责 destroyTexture)
    pub fn createTextureFromPng(self: *Renderer2D, png_data: []const u8) !*anyopaque {
        var img = try png.decode(self.allocator, png_data);
        defer img.deinit(self.allocator);

        const tex = self.device.createTextureRGBA(img.width, img.height) orelse
            return error.TextureCreateFailed;
        self.device.updateTextureRegion(tex, 0, 0, img.width, img.height, img.pixels, img.width * 4);
        return tex;
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

        // 3. 图片 (RGBA 纹理管线)
        for (self.image_runs.items) |run| {
            self.device.drawImage(
                self.image_vertices.items[run.start .. run.start + run.count],
                run.texture,
            );
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

    /// 直色转换 (不预乘), 供 image 管线使用 (shader 内部预乘)
    fn colorToFloatStraight(color: math.Color) [4]f32 {
        return .{
            @as(f32, @floatFromInt(color.r)) / 255.0,
            @as(f32, @floatFromInt(color.g)) / 255.0,
            @as(f32, @floatFromInt(color.b)) / 255.0,
            @as(f32, @floatFromInt(color.a)) / 255.0,
        };
    }

    /// 按 0..1 比例缩放颜色透明度
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
