//! Picture 控件 - GTK4 图像控件
//!
//! 对应 GtkPicture: GTK4 新版图像显示控件, 替代 GtkImage。
//! 支持: 从 PNG 数据加载、备用图标 (当图片未加载时显示)、
//! 保持宽高比、可收缩、五种适配模式、颜色滤镜。
//!
//! 与 Image 的区别: GTK4 推荐使用的 API, 内置备用图和更多适配选项。

const std = @import("std");
const math = @import("../math.zig");
const widget_mod = @import("widget.zig");
const layout_mod = @import("../layout/engine.zig");
const pal = @import("../pal/pal.zig");
const background_mod = @import("background.zig");
const icons_mod = @import("icons.zig");

const Widget = widget_mod.Widget;
const PaintContext = widget_mod.PaintContext;
const EventContext = widget_mod.EventContext;
const EventResult = widget_mod.EventResult;
const BackgroundImage = background_mod.BackgroundImage;
pub const PictureSizing = background_mod.BackgroundSizing;

pub const Picture = struct {
    base: Widget,
    allocator: std.mem.Allocator,
    image: BackgroundImage,
    tint: math.Color,
    /// 显式尺寸 (null = 使用图片原始尺寸)
    explicit_w: ?f32,
    explicit_h: ?f32,
    /// 图片未加载时显示的备用图标
    fallback_icon: icons_mod.IconName = .image,
    /// 保持宽高比
    keep_aspect_ratio: bool = true,
    /// 允许收缩到比原始尺寸更小
    can_shrink: bool = true,
    /// 备用图标的大小
    fallback_icon_size: f32 = 48,
    /// 备用图标的颜色
    fallback_color: math.Color = math.Color.hex(0x94A3B8FF),
    /// 备用背景色
    fallback_bg: math.Color = math.Color.hex(0xF1F5F9FF),

    const Self = @This();

    pub fn create(allocator: std.mem.Allocator, opts: struct {
        png_data: ?[]const u8 = null,
        texture: ?*anyopaque = null,
        texture_width: u32 = 0,
        texture_height: u32 = 0,
        sizing: PictureSizing = .contain,
        tint: math.Color = math.Color.hex(0xFFFFFFFF),
        width: ?f32 = null,
        height: ?f32 = null,
        fallback_icon: icons_mod.IconName = .image,
        keep_aspect_ratio: bool = true,
        can_shrink: bool = true,
        fallback_icon_size: f32 = 48,
        fallback_color: math.Color = math.Color.hex(0x94A3B8FF),
        fallback_bg: math.Color = math.Color.hex(0xF1F5F9FF),
        alt: []const u8 = "",
    }) !*Picture {
        const self = try allocator.create(Picture);

        var img: BackgroundImage = .{ .sizing = opts.sizing };
        if (opts.png_data) |data| {
            img = try BackgroundImage.fromPng(allocator, data, opts.sizing);
        } else if (opts.texture) |tex| {
            img = BackgroundImage.fromTexture(tex, opts.texture_width, opts.texture_height, opts.sizing);
        }

        self.* = .{
            .base = .{
                .vtable = &vtable,
                .id = widget_mod.genWidgetId(),
            },
            .allocator = allocator,
            .image = img,
            .tint = opts.tint,
            .explicit_w = opts.width,
            .explicit_h = opts.height,
            .fallback_icon = opts.fallback_icon,
            .keep_aspect_ratio = opts.keep_aspect_ratio,
            .can_shrink = opts.can_shrink,
            .fallback_icon_size = opts.fallback_icon_size,
            .fallback_color = opts.fallback_color,
            .fallback_bg = opts.fallback_bg,
        };
        if (opts.width) |w| self.base.rect.width = w;
        if (opts.height) |h| self.base.rect.height = h;
        self.base.accessibility = .{ .role = .image, .label = opts.alt };
        return self;
    }

    /// 从文件路径加载（GTK4 风格 API）
    pub fn newFromFile(allocator: std.mem.Allocator, file_path: []const u8) !*Picture {
        const png_bytes = @import("std").fs.cwd().readFileAlloc(allocator, file_path, 10 * 1024 * 1024) catch {
            // 加载失败返回带备用图的 Picture
            return try create(allocator, .{});
        };
        defer allocator.free(png_bytes);
        return try create(allocator, .{
            .png_data = png_bytes,
        });
    }

    /// GTK4 风格: new_for_paintable (PNG bytes)
    pub fn newForPaintable(allocator: std.mem.Allocator, png_bytes: []const u8) !*Picture {
        return try create(allocator, .{
            .png_data = png_bytes,
        });
    }

    pub fn destroy(self: *Self, allocator: std.mem.Allocator) void {
        self.image.deinit(allocator);
        self.base.background.deinit(allocator);
        self.base.children.deinit(allocator);
        allocator.destroy(self);
    }

    /// 设置颜色滤镜
    pub fn setTint(self: *Self, tint: math.Color) void {
        self.tint = tint;
        self.base.markDirty();
    }

    /// 重新设置图片 (PNG bytes)
    pub fn setPngBytes(self: *Self, bytes: []const u8) !void {
        self.image.deinit(self.allocator);
        self.image = try BackgroundImage.fromPng(self.allocator, bytes, self.image.sizing);
        self.base.markDirty();
    }

    /// 是否有有效图片
    pub fn hasImage(self: *const Self) bool {
        return self.image.texture != null or (self.image.surface != null and self.image.surface.?.width > 0);
    }

    // ── VTable 实现 ──────────────────────────────────────────────────────────

    const vtable = Widget.VTable{
        .type_name = "picture",
        .measure = measure,
        .paint = paint,
        .on_event = null,
        .focusable = false,
        .destroy = destroyVTable,
    };

    fn destroyVTable(w: *Widget, allocator: std.mem.Allocator) void {
        const self: *Self = @fieldParentPtr("base", w);
        self.destroy(allocator);
    }

    fn measure(w: *Widget, ctx: *PaintContext, constraints: layout_mod.Constraints) math.Size(f32) {
        const self: *Self = @fieldParentPtr("base", w);
        _ = ctx;

        // 有显式尺寸时用显式
        if (self.explicit_w != null and self.explicit_h != null) {
            return .{
                .width = self.explicit_w.?,
                .height = self.explicit_h.?,
            };
        }

        const has_img = self.hasImage();

        // 没有图片时用默认尺寸
        if (!has_img) {
            const default_w = self.explicit_w orelse @max(128, self.fallback_icon_size * 2 + 32);
            const default_h = self.explicit_h orelse @max(128, self.fallback_icon_size * 2 + 32);
            const w_out = if (constraints.max_width < std.math.inf(f32))
                constraints.max_width
            else
                default_w;
            const h_out = if (constraints.max_height < std.math.inf(f32))
                constraints.max_height
            else
                default_h;
            return .{ .width = w_out, .height = h_out };
        }

        const size = self.image.getNaturalSize();

        // 计算输出尺寸
        var w_out = @as(f32, @floatFromInt(size.width));
        var h_out = @as(f32, @floatFromInt(size.height));

        if (self.explicit_w) |ew| {
            w_out = ew;
            if (self.keep_aspect_ratio) {
                const r = ew / @as(f32, @floatFromInt(size.width));
                h_out = @as(f32, @floatFromInt(size.height)) * r;
            }
        }
        if (self.explicit_h) |eh| {
            h_out = eh;
            if (self.keep_aspect_ratio and self.explicit_w == null) {
                const r = eh / @as(f32, @floatFromInt(size.height));
                w_out = @as(f32, @floatFromInt(size.width)) * r;
            }
        }

        if (constraints.max_width < std.math.inf(f32) and w_out > constraints.max_width) {
            if (self.can_shrink or self.keep_aspect_ratio) {
                const r = constraints.max_width / w_out;
                w_out = constraints.max_width;
                h_out *= r;
            } else {
                w_out = constraints.max_width;
            }
        }
        if (constraints.max_height < std.math.inf(f32) and h_out > constraints.max_height) {
            if (self.can_shrink or self.keep_aspect_ratio) {
                const r = constraints.max_height / h_out;
                h_out = constraints.max_height;
                w_out *= r;
            } else {
                h_out = constraints.max_height;
            }
        }

        w_out = @max(w_out, constraints.min_width);
        h_out = @max(h_out, constraints.min_height);
        return .{ .width = w_out, .height = h_out };
    }

    fn paint(w: *Widget, ctx: *PaintContext) void {
        const self: *Self = @fieldParentPtr("base", w);
        const rx = ctx.offset_x + w.rect.x;
        const ry = ctx.offset_y + w.rect.y;

        if (self.hasImage()) {
            background_mod.drawImageWithTint(
                ctx.renderer,
                rx,
                ry,
                w.rect.width,
                w.rect.height,
                &self.image,
                self.tint,
            ) catch {};
        } else {
            // 绘制备用背景
            ctx.renderer.fillRoundedRect(
                .{ .x = rx, .y = ry, .width = w.rect.width, .height = w.rect.height },
                8,
                self.fallback_bg,
            ) catch {};

            // 绘制备用图标
            const ix = rx + (w.rect.width - self.fallback_icon_size) / 2;
            const iy = ry + (w.rect.height - self.fallback_icon_size) / 2;
            icons_mod.drawIcon(ctx.renderer, ix, iy, self.fallback_icon_size, self.fallback_color, self.fallback_icon) catch {};
        }
    }
};
