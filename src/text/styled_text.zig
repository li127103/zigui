//! 跨平台文本 helper — 封装 "字体创建 + layout + 绘制/测量"
//!
//! comptime 分发:
//! - macOS: CtFont + text/layout.zig (CoreText)
//! - Linux: FtFont + text/layout_ft.zig (FreeType)
//!
//! Widget (label/button 等) 通过本模块实现平台无关文本渲染。

const std = @import("std");
const builtin = @import("builtin");
const math = @import("../math.zig");
const r2d = @import("../render2d/r2d.zig");
const align_mod = @import("align.zig");

pub const TextAlign = align_mod.TextAlign;

const is_macos = builtin.os.tag == .macos;
const is_linux = builtin.os.tag == .linux;

// 平台导入
const coretext = if (is_macos) @import("coretext.zig") else void;
const text_layout_mod = if (is_macos) @import("layout.zig") else void;
const freetype = if (is_linux) @import("freetype.zig") else void;
const text_layout_ft = if (is_linux) @import("layout_ft.zig") else void;
const vulkan_renderer_mod = if (is_linux) @import("../render2d/vulkan_renderer.zig") else void;

/// 文本样式选项
pub const TextStyle = struct {
    font_size: f32 = 14.0,
    font_weight: u16 = 400,
    color: math.Color = math.Color.hex(0xF8FAFCFF),
    text_align: TextAlign = .left,
    /// 最大宽度 (传入时启用自动换行 + 对齐; null 为单行)
    max_width: ?f32 = null,
};

/// 测量文本尺寸 (不生成 glyph 位置, 仅计算宽高)
pub fn measureText(allocator: std.mem.Allocator, text: []const u8, style: TextStyle) math.Size(f32) {
    if (text.len == 0) return .{ .width = 0, .height = style.font_size * 1.2 };

    if (comptime is_macos) {
        var font = coretext.CtFont.create(null, style.font_size, style.font_weight) catch {
            return .{ .width = 0, .height = style.font_size * 1.2 };
        };
        defer font.destroy();
        const text_w = font.measureText(text);
        const metrics = font.getMetrics();
        return .{ .width = text_w, .height = metrics.line_height };
    } else if (comptime is_linux) {
        const font_path = findFont(allocator) orelse {
            return .{ .width = 0, .height = style.font_size * 1.2 };
        };
        var font = freetype.FtFont.createFromFile(allocator, font_path.ptr, style.font_size, style.font_weight) catch {
            return .{ .width = 0, .height = style.font_size * 1.2 };
        };
        defer font.destroy();
        const text_w = font.measureText(text);
        const metrics = font.getMetrics();
        return .{ .width = text_w, .height = metrics.line_height };
    } else {
        return .{ .width = 0, .height = style.font_size * 1.2 };
    }
}

/// 绘制文本 (创建字体 → 布局 → 渲染, 一次性调用)
pub fn drawText(
    renderer: *r2d.Renderer2D,
    allocator: std.mem.Allocator,
    text: []const u8,
    x: f32,
    y: f32,
    style: TextStyle,
) void {
    if (text.len == 0) return;

    if (comptime is_macos) {
        var font = coretext.CtFont.create(null, style.font_size, style.font_weight) catch return;
        defer font.destroy();

        var tl = text_layout_mod.TextLayout.layout(
            allocator,
            renderer.glyph_atlas.?,
            renderer.device,
            text,
            .{ .font = &font, .font_size = style.font_size, .max_width = style.max_width, .text_align = style.text_align },
        ) catch return;
        defer tl.deinit();

        renderer.drawTextLayout(&tl, x, y, style.color) catch {};
    } else if (comptime is_linux) {
        const font_path = findFont(allocator) orelse return;
        var font = freetype.FtFont.createFromFile(allocator, font_path.ptr, style.font_size, style.font_weight) catch return;
        defer font.destroy();

        var tl = text_layout_ft.TextLayout.layout(
            allocator,
            renderer.glyph_atlas.?,
            renderer.device,
            text,
            .{ .font = &font, .font_size = style.font_size, .max_width = style.max_width, .text_align = style.text_align },
        ) catch return;
        defer tl.deinit();

        renderer.drawTextLayout(&tl, x, y, style.color) catch {};
    } else {
        _ = .{ renderer, allocator, x, y };
    }
}

/// 绘制单行文本并裁剪到 max_width (超出部分不绘制); 返回实际绘制宽度
pub fn drawTextClipped(
    renderer: *r2d.Renderer2D,
    allocator: std.mem.Allocator,
    text: []const u8,
    x: f32,
    y: f32,
    style: TextStyle,
    max_width: f32,
) f32 {
    if (text.len == 0) return 0;

    if (comptime is_macos) {
        var font = coretext.CtFont.create(null, style.font_size, style.font_weight) catch return 0;
        defer font.destroy();

        // 先测量总宽
        const total_w = font.measureText(text);
        const drawn_w = @min(total_w, max_width);

        var tl = text_layout_mod.TextLayout.layout(
            allocator,
            renderer.glyph_atlas.?,
            renderer.device,
            text,
            .{ .font = &font, .font_size = style.font_size },
        ) catch return 0;
        defer tl.deinit();

        // 使用 drawTextClipped 裁剪到 max_width
        const clip = math.Rect(f32){ .x = x, .y = y - style.font_size * 2, .width = max_width, .height = style.font_size * 4 };
        renderer.drawTextClipped(&tl, x, y, style.color, clip) catch {};
        return drawn_w;
    } else if (comptime is_linux) {
        const font_path = findFont(allocator) orelse return 0;
        var font = freetype.FtFont.createFromFile(allocator, font_path.ptr, style.font_size, style.font_weight) catch return 0;
        defer font.destroy();

        // 使用 shapeText 逐 glyph 裁剪 (与 input.zig 原逻辑一致)
        var shaped: [512]freetype.ShapedGlyph = undefined;
        const glyph_count = font.shapeText(text, &shaped);
        if (glyph_count == 0) return 0;

        const atlas = renderer.glyph_atlas.?;
        const device = renderer.device;

        var placed: [512]vulkan_renderer_mod.PlacedGlyph = undefined;
        var pen_x: f32 = 0;
        var placed_count: usize = 0;

        for (0..glyph_count) |i| {
            const sg = shaped[i];
            if (pen_x + sg.x_advance > max_width) break;
            const entry = atlas.getOrRasterize(device, &font, sg.glyph_id, style.font_size) catch continue;
            placed[placed_count] = .{
                .glyph_id = sg.glyph_id,
                .x = pen_x,
                .y = 0,
                .advance = sg.x_advance,
                .atlas_entry = entry,
            };
            pen_x += sg.x_advance;
            placed_count += 1;
        }

        if (placed_count > 0) {
            renderer.drawText(placed[0..placed_count], x, y, style.color) catch {};
        }
        return pen_x;
    } else {
        _ = .{ renderer, allocator, x, y, max_width };
        return 0;
    }
}

/// 测量单行文本宽度 (不布局, 仅 shape 并累加 advance)
pub fn measureTextWidth(allocator: std.mem.Allocator, text: []const u8, style: TextStyle) f32 {
    if (text.len == 0) return 0;
    const size = measureText(allocator, text, style);
    return size.width;
}

// ── Linux 字体查找 (优先 CJK, 回退普通系统字体) ──────────────────────────

var g_font_path: ?[:0]u8 = null;
var g_font_allocator: ?std.mem.Allocator = null;

/// 查找系统字体 (缓存结果; 优先 CJK 字体以覆盖中英文)
fn findFont(allocator: std.mem.Allocator) ?[:0]const u8 {
    if (g_font_path) |p| return p;
    if (comptime is_linux) {
        if (freetype.findCjkFont(allocator)) |p| {
            g_font_path = p;
            g_font_allocator = allocator;
            return p;
        } else |_| {}
        if (freetype.findSystemFont(allocator, null)) |p| {
            g_font_path = p;
            g_font_allocator = allocator;
            return p;
        } else |_| {}
    }
    return null;
}

/// 释放字体路径缓存 (应用退出前调用)
pub fn deinitFontCache() void {
    if (g_font_path) |p| {
        if (g_font_allocator) |a| a.free(p);
        g_font_path = null;
        g_font_allocator = null;
    }
}
