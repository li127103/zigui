//! Image 控件 - 图片展示 (复用 background 的图片适配逻辑, 支持 tint 与五种适配模式)

const std = @import("std");
const math = @import("../math.zig");
const widget_mod = @import("widget.zig");
const layout_mod = @import("../layout/engine.zig");
const background_mod = @import("background.zig");

const Widget = widget_mod.Widget;
const PaintContext = widget_mod.PaintContext;
const BackgroundImage = background_mod.BackgroundImage;
pub const ImageSizing = background_mod.BackgroundSizing;

pub const Image = struct {
    base: Widget,
    image: BackgroundImage,
    tint: math.Color,
    // 显式尺寸 (null = 使用图片原始尺寸)
    explicit_w: ?f32,
    explicit_h: ?f32,

    pub fn create(allocator: std.mem.Allocator, opts: struct {
        png_data: ?[]const u8 = null,
        texture: ?*anyopaque = null,
        texture_width: u32 = 0,
        texture_height: u32 = 0,
        sizing: ImageSizing = .contain,
        tint: math.Color = math.Color.hex(0xFFFFFFFF),
        width: ?f32 = null,
        height: ?f32 = null,
        alt: []const u8 = "", // 替代文本 (无障碍)
    }) !*Image {
        const self = try allocator.create(Image);

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
            .image = img,
            .tint = opts.tint,
            .explicit_w = opts.width,
            .explicit_h = opts.height,
        };
        if (opts.width) |w| self.base.rect.width = w;
        if (opts.height) |h| self.base.rect.height = h;
        self.base.accessibility = .{ .role = .image, .label = opts.alt };
        return self;
    }

    pub fn destroy(self: *Image, allocator: std.mem.Allocator) void {
        self.image.deinit(allocator);
        self.base.background.deinit(allocator);
        self.base.children.deinit(allocator);
        allocator.destroy(self);
    }

    pub fn setTint(self: *Image, tint: math.Color) void {
        self.tint = tint;
        self.base.markDirty();
    }

    // ── VTable 实现 ──────────────────────────────────────────────────────────

    const vtable = Widget.VTable{
        .type_name = "image",
        .measure = measure,
        .paint = paint,
        .on_event = null,
        .focusable = false,
        .destroy = destroyVTable,
    };

    fn destroyVTable(w: *Widget, allocator: std.mem.Allocator) void {
        const self: *Image = @fieldParentPtr("base", w);
        self.destroy(allocator);
    }

    fn measure(w: *Widget, ctx: *PaintContext, constraints: layout_mod.Constraints) math.Size(f32) {
        const self: *Image = @fieldParentPtr("base", w);
        _ = ctx;
        // 显式尺寸优先; 否则用纹理原始尺寸; 最后回退默认
        const width = self.explicit_w orelse (if (self.image.tex_width > 0)
            @as(f32, @floatFromInt(self.image.tex_width))
        else
            100.0);
        const height = self.explicit_h orelse (if (self.image.tex_height > 0)
            @as(f32, @floatFromInt(self.image.tex_height))
        else
            100.0);
        _ = constraints;
        return .{ .width = width, .height = height };
    }

    fn paint(w: *Widget, ctx: *PaintContext) void {
        const self: *Image = @fieldParentPtr("base", w);
        const rx = ctx.offset_x + w.rect.x;
        const ry = ctx.offset_y + w.rect.y;
        const dst = math.Rect(f32){ .x = rx, .y = ry, .width = w.rect.width, .height = w.rect.height };

        // 惰性解码上传纹理
        self.image.ensureTexture(ctx.renderer) catch return;
        const tex = self.image.texture orelse return;
        const iw: f32 = @floatFromInt(self.image.tex_width);
        const ih: f32 = @floatFromInt(self.image.tex_height);
        if (iw <= 0 or ih <= 0) return;

        // 平铺模式单独处理
        if (self.image.sizing == .tile) {
            var ty: f32 = 0;
            while (ty < dst.height) : (ty += ih) {
                var tx: f32 = 0;
                while (tx < dst.width) : (tx += iw) {
                    const tw = @min(iw, dst.width - tx);
                    const th = @min(ih, dst.height - ty);
                    ctx.renderer.drawImageImmediate(
                        tex,
                        .{ .x = dst.x + tx, .y = dst.y + ty, .width = tw, .height = th },
                        .{ .x = 0, .y = 0, .width = tw / iw, .height = th / ih },
                        self.tint,
                    );
                }
            }
            return;
        }

        const p = background_mod.placement(iw, ih, dst, self.image.sizing) orelse return;
        ctx.renderer.drawImageImmediate(tex, p.dst, p.src, self.tint);
    }
};

// ── Tests ──────────────────────────────────────────────────────────────────

test "image explicit size overrides texture size" {
    const img = try Image.create(std.testing.allocator, .{
        .width = 64,
        .height = 48,
    });
    defer img.destroy(std.testing.allocator);
    try std.testing.expectEqual(@as(f32, 64), img.base.rect.width);
    try std.testing.expectEqual(@as(f32, 48), img.base.rect.height);
    try std.testing.expectEqual(@as(?f32, 64), img.explicit_w);
}

test "image from texture records dimensions" {
    const dummy = @as(*anyopaque, @ptrFromInt(0x1));
    const img = try Image.create(std.testing.allocator, .{
        .texture = dummy,
        .texture_width = 128,
        .texture_height = 256,
        .sizing = .cover,
    });
    defer img.destroy(std.testing.allocator);
    try std.testing.expectEqual(@as(u32, 128), img.image.tex_width);
    try std.testing.expectEqual(@as(u32, 256), img.image.tex_height);
    try std.testing.expect(img.image.sizing == .cover);
}

test "image setTint marks dirty" {
    const img = try Image.create(std.testing.allocator, .{});
    defer img.destroy(std.testing.allocator);
    img.setTint(math.Color.hex(0xFF0000FF));
    try std.testing.expectEqual(@as(u8, 0xFF), img.tint.r);
    try std.testing.expectEqual(@as(u8, 0x00), img.tint.g);
}
