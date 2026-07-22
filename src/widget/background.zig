//! 控件背景类型与布局算法
//!
//! 背景是 Widget 基类属性, 由框架在 paintTree 中自动绘制于控件内容之前:
//! - color: 纯色填充 (支持圆角)
//! - image: PNG 背景图片 (stretch/cover/contain/center/tile 五种适配模式)

const std = @import("std");
const math = @import("../math.zig");
const png = @import("../image/png.zig");
const r2d = @import("../render2d/r2d.zig");

/// 背景图片适配模式
pub const BackgroundSizing = enum {
    /// 拉伸铺满整个区域 (可能变形)
    stretch,
    /// 等比缩放覆盖整个区域, 居中裁切超出部分 (UV 裁切, 无溢出)
    cover,
    /// 等比缩放完整放入, 居中 (可能留白)
    contain,
    /// 原始尺寸居中绘制, 超出部分裁切
    center,
    /// 原始尺寸平铺重复
    tile,
};

/// 背景定义 (无 / 纯色 / 图片)
pub const Background = union(enum) {
    none,
    color: math.Color,
    image: BackgroundImage,
};

/// 背景样式 = 背景 + 圆角半径 + 阴影
pub const BackgroundStyle = struct {
    bg: Background = .none,
    /// 圆角半径 (仅对纯色背景生效; 图片背景暂不支持圆角裁切)
    corner_radius: f32 = 0,
    /// 阴影颜色 (null = 无阴影; 非 null 时框架在背景之前绘制阴影)
    shadow_color: ?math.Color = null,
    /// 阴影模糊半径 (向外扩散像素)
    shadow_blur: f32 = 16.0,
    /// 阴影 X 偏移
    shadow_offset_x: f32 = 0.0,
    /// 阴影 Y 偏移
    shadow_offset_y: f32 = 6.0,

    /// 释放资源 (图片数据与 GPU 纹理), 重置为无背景
    pub fn deinit(self: *BackgroundStyle, allocator: std.mem.Allocator) void {
        switch (self.bg) {
            .image => |*img| img.deinit(allocator),
            else => {},
        }
        self.bg = .none;
    }
};

/// 背景图片 (持有 PNG 数据或已创建纹理, GPU 上传惰性执行)
pub const BackgroundImage = struct {
    /// PNG 文件数据 (所有拷贝, 首次绘制时解码上传)
    png_data: []const u8 = &.{},
    /// GPU 纹理 (惰性创建, 本对象所有, deinit 时销毁)
    texture: ?*anyopaque = null,
    /// 创建纹理所用渲染器 (供销毁; 须在渲染器销毁前 deinit)
    renderer: ?*r2d.Renderer2D = null,
    /// 纹理原始尺寸 (像素, 供适配计算)
    tex_width: u32 = 0,
    tex_height: u32 = 0,
    /// 适配模式
    sizing: BackgroundSizing = .cover,
    /// 不透明度 0..1
    opacity: f32 = 1.0,

    /// 从 PNG 数据构造 (拷贝数据; 释放需调用 deinit)
    pub fn fromPng(allocator: std.mem.Allocator, png_data: []const u8, sizing: BackgroundSizing) !BackgroundImage {
        const owned = try allocator.dupe(u8, png_data);
        return .{ .png_data = owned, .sizing = sizing };
    }

    /// 从已创建的 RGBA 纹理构造 (纹理所有权移交本对象)
    pub fn fromTexture(texture: *anyopaque, width: u32, height: u32, sizing: BackgroundSizing) BackgroundImage {
        return .{ .texture = texture, .tex_width = width, .tex_height = height, .sizing = sizing };
    }

    /// 释放图片数据与 GPU 纹理。
    /// 注意: 必须在渲染器销毁之前调用。
    pub fn deinit(self: *BackgroundImage, allocator: std.mem.Allocator) void {
        if (self.png_data.len > 0) allocator.free(self.png_data);
        if (self.texture) |tex| {
            if (self.renderer) |r| r.destroyTexture(tex);
        }
        self.* = .{};
    }

    /// 确保 GPU 纹理已创建 (惰性: 首次调用时解码 PNG 并上传)
    pub fn ensureTexture(self: *BackgroundImage, renderer: *r2d.Renderer2D) !void {
        if (self.texture != null or self.png_data.len == 0) return;

        var img = try png.decode(renderer.allocator, self.png_data);
        defer img.deinit(renderer.allocator);

        const tex = try renderer.createTextureFromRgba(img.width, img.height, img.pixels);

        self.texture = tex;
        self.renderer = renderer;
        self.tex_width = img.width;
        self.tex_height = img.height;
    }
};

/// 单四边形布局结果: 目标矩形 + 源 UV (归一化 0..1)
pub const Placement = struct {
    dst: math.Rect(f32),
    src: math.Rect(f32),
};

const full_uv = math.Rect(f32){ .x = 0, .y = 0, .width = 1, .height = 1 };

/// 计算 stretch/cover/contain/center 的单四边形布局 (tile 返回 null, 由调用方平铺处理)
pub fn placement(img_w: f32, img_h: f32, dst: math.Rect(f32), sizing: BackgroundSizing) ?Placement {
    if (img_w <= 0 or img_h <= 0 or dst.width <= 0 or dst.height <= 0) return null;
    return switch (sizing) {
        .stretch => .{ .dst = dst, .src = full_uv },
        .cover => blk: {
            // 缩放至覆盖整个目标, UV 居中裁切超出部分
            const scale = @max(dst.width / img_w, dst.height / img_h);
            const uv_w = dst.width / (img_w * scale);
            const uv_h = dst.height / (img_h * scale);
            break :blk .{
                .dst = dst,
                .src = .{ .x = (1.0 - uv_w) / 2.0, .y = (1.0 - uv_h) / 2.0, .width = uv_w, .height = uv_h },
            };
        },
        .contain => blk: {
            // 缩放至完整放入, 目标矩形居中 (留白不绘制)
            const scale = @min(dst.width / img_w, dst.height / img_h);
            const w = img_w * scale;
            const h = img_h * scale;
            break :blk .{
                .dst = .{ .x = dst.x + (dst.width - w) / 2.0, .y = dst.y + (dst.height - h) / 2.0, .width = w, .height = h },
                .src = full_uv,
            };
        },
        .center => blk: {
            // 原始尺寸居中; 超出目标的部分以 UV 裁切
            const w = @min(dst.width, img_w);
            const h = @min(dst.height, img_h);
            break :blk .{
                .dst = .{ .x = dst.x + (dst.width - w) / 2.0, .y = dst.y + (dst.height - h) / 2.0, .width = w, .height = h },
                .src = .{
                    .x = (1.0 - w / img_w) / 2.0,
                    .y = (1.0 - h / img_h) / 2.0,
                    .width = w / img_w,
                    .height = h / img_h,
                },
            };
        },
        .tile => null,
    };
}

/// 绘制背景图片 (调用方须先确保纹理就绪: ensureTexture, 并在之前 flush 累积几何)。
/// 走立即绘制路径 (drawImageImmediate), 保证背景图精确位于之前几何之上、之后几何之下。
pub fn drawImageBackground(renderer: *r2d.Renderer2D, img: *const BackgroundImage, dst: math.Rect(f32)) void {
    const tex = img.texture orelse return;
    const iw: f32 = @floatFromInt(img.tex_width);
    const ih: f32 = @floatFromInt(img.tex_height);
    const tint = math.Color{
        .r = 255,
        .g = 255,
        .b = 255,
        .a = @intFromFloat(std.math.clamp(img.opacity, 0.0, 1.0) * 255.0),
    };

    if (img.sizing == .tile) {
        if (iw <= 0 or ih <= 0) return;
        var ty: f32 = 0;
        while (ty < dst.height) : (ty += ih) {
            var tx: f32 = 0;
            while (tx < dst.width) : (tx += iw) {
                const w = @min(iw, dst.width - tx);
                const h = @min(ih, dst.height - ty);
                renderer.drawImageImmediate(
                    tex,
                    .{ .x = dst.x + tx, .y = dst.y + ty, .width = w, .height = h },
                    .{ .x = 0, .y = 0, .width = w / iw, .height = h / ih },
                    tint,
                );
            }
        }
        return;
    }

    const p = placement(iw, ih, dst, img.sizing) orelse return;
    renderer.drawImageImmediate(tex, p.dst, p.src, tint);
}

// ── Tests ──────────────────────────────────────────────────────────────────

fn expectNear(expected: f32, actual: f32) !void {
    try std.testing.expect(@abs(expected - actual) < 1e-5);
}

test "background placement stretch fills dst" {
    const p = placement(200, 100, .{ .x = 10, .y = 20, .width = 100, .height = 100 }, .stretch).?;
    try expectNear(10, p.dst.x);
    try expectNear(20, p.dst.y);
    try expectNear(100, p.dst.width);
    try expectNear(100, p.dst.height);
    try expectNear(0, p.src.x);
    try expectNear(0, p.src.y);
    try expectNear(1, p.src.width);
    try expectNear(1, p.src.height);
}

test "background placement cover crops wider image" {
    // 200x100 图 → 100x100 目标: scale=max(0.5,1)=1, 水平裁切居中
    const p = placement(200, 100, .{ .x = 0, .y = 0, .width = 100, .height = 100 }, .cover).?;
    try expectNear(100, p.dst.width);
    try expectNear(100, p.dst.height);
    try expectNear(0.25, p.src.x);
    try expectNear(0, p.src.y);
    try expectNear(0.5, p.src.width);
    try expectNear(1, p.src.height);
}

test "background placement cover crops taller image" {
    // 100x200 图 → 100x100 目标: scale=max(1,0.5)=1, 垂直裁切居中
    const p = placement(100, 200, .{ .x = 0, .y = 0, .width = 100, .height = 100 }, .cover).?;
    try expectNear(0, p.src.x);
    try expectNear(0.25, p.src.y);
    try expectNear(1, p.src.width);
    try expectNear(0.5, p.src.height);
}

test "background placement contain letterboxes" {
    // 200x100 图 → 100x100 目标: scale=min(0.5,1)=0.5 → 100x50 垂直居中
    const p = placement(200, 100, .{ .x = 0, .y = 0, .width = 100, .height = 100 }, .contain).?;
    try expectNear(0, p.dst.x);
    try expectNear(25, p.dst.y);
    try expectNear(100, p.dst.width);
    try expectNear(50, p.dst.height);
    try expectNear(1, p.src.width);
    try expectNear(1, p.src.height);
}

test "background placement center small image" {
    // 50x50 图 → 100x100 目标: 原尺寸居中, 不裁切
    const p = placement(50, 50, .{ .x = 0, .y = 0, .width = 100, .height = 100 }, .center).?;
    try expectNear(25, p.dst.x);
    try expectNear(25, p.dst.y);
    try expectNear(50, p.dst.width);
    try expectNear(50, p.dst.height);
    try expectNear(1, p.src.width);
    try expectNear(1, p.src.height);
}

test "background placement center crops large image" {
    // 200x100 图 → 100x100 目标: 垂直方向原尺寸超出, 裁切 UV 居中
    const p = placement(200, 100, .{ .x = 0, .y = 0, .width = 100, .height = 100 }, .center).?;
    try expectNear(0, p.dst.x);
    try expectNear(0, p.dst.y);
    try expectNear(100, p.dst.width);
    try expectNear(100, p.dst.height);
    try expectNear(0.25, p.src.x);
    try expectNear(0, p.src.y);
    try expectNear(0.5, p.src.width);
    try expectNear(1, p.src.height);
}

test "background placement tile returns null" {
    try std.testing.expect(placement(100, 100, .{ .x = 0, .y = 0, .width = 50, .height = 50 }, .tile) == null);
}

test "background placement zero sizes return null" {
    const dst = math.Rect(f32){ .x = 0, .y = 0, .width = 100, .height = 100 };
    try std.testing.expect(placement(0, 100, dst, .cover) == null);
    try std.testing.expect(placement(100, 0, dst, .contain) == null);
    try std.testing.expect(placement(100, 100, .{ .x = 0, .y = 0, .width = 0, .height = 100 }, .stretch) == null);
}

test "background image fromPng owns copied data" {
    const alloc = std.testing.allocator;
    var img = try BackgroundImage.fromPng(alloc, "png-bytes", .tile);
    defer img.deinit(alloc);

    try std.testing.expectEqual(@as(usize, 9), img.png_data.len);
    try std.testing.expectEqualSlices(u8, "png-bytes", img.png_data);
    try std.testing.expectEqual(BackgroundSizing.tile, img.sizing);
    try std.testing.expect(img.texture == null);
}

test "background image deinit resets state" {
    const alloc = std.testing.allocator;
    var img = try BackgroundImage.fromPng(alloc, "data", .tile);
    img.deinit(alloc);
    try std.testing.expectEqual(@as(usize, 0), img.png_data.len);
    try std.testing.expect(img.texture == null);
    try std.testing.expectEqual(BackgroundSizing.cover, img.sizing); // .{} 重置为默认值
}

test "background style deinit clears image" {
    const alloc = std.testing.allocator;
    var style = BackgroundStyle{
        .bg = .{ .image = try BackgroundImage.fromPng(alloc, "x", .stretch) },
        .corner_radius = 8,
    };
    style.deinit(alloc);
    try std.testing.expect(std.meta.activeTag(style.bg) == .none);
    try std.testing.expectEqual(@as(f32, 8), style.corner_radius); // 圆角保留
}
