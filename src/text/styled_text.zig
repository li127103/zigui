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
    /// 斜体 (fake italic: 水平错切合成)
    italic: bool = false,
    /// 最大宽度 (传入时启用自动换行 + 对齐; null 为单行)
    max_width: ?f32 = null,
};

// ── 富文本 Span 支持 ──────────────────────────────────────────────────────

/// 带独立样式的文本片段
pub const TextSpan = struct {
    text: []const u8,
    font_size: f32 = 14.0,
    font_weight: u16 = 400,
    color: math.Color = math.Color.hex(0xF8FAFCFF),
    /// 斜体 (fake italic: 水平错切合成)
    italic: bool = false,
    /// 下划线
    underline: bool = false,
    /// 删除线
    strikethrough: bool = false,
};

/// 解析标记文本为 TextSpan 数组
/// 支持的标记:
///   <b>粗体</b>
///   <i>斜体</i>
///   <u>下划线</u>
///   <s>删除线</s>
///   <color=0xRRGGBBAA>彩色</color>
///   <size=18>大字</size>
pub fn parseMarkup(allocator: std.mem.Allocator, text: []const u8, base: TextStyle) ![]TextSpan {
    var spans = std.ArrayListUnmanaged(TextSpan){ .items = &.{}, .capacity = 0 };
    defer spans.deinit(allocator);

    var i: usize = 0;
    var cur_size = base.font_size;
    var cur_weight = base.font_weight;
    var cur_color = base.color;
    var cur_italic: bool = false;
    var cur_underline: bool = false;
    var cur_strikethrough: bool = false;

    while (i < text.len) {
        if (text[i] == '<') {
            const tag_end = std.mem.indexOfScalarPos(u8, text, i, '>') orelse {
                try spans.append(allocator, .{
                    .text = text[i..],
                    .font_size = cur_size,
                    .font_weight = cur_weight,
                    .color = cur_color,
                    .italic = cur_italic,
                    .underline = cur_underline,
                    .strikethrough = cur_strikethrough,
                });
                break;
            };
            const tag = text[i + 1 .. tag_end];

            if (std.mem.eql(u8, tag, "b")) {
                cur_weight = 700;
            } else if (std.mem.eql(u8, tag, "/b")) {
                cur_weight = base.font_weight;
            } else if (std.mem.eql(u8, tag, "i")) {
                cur_italic = true;
            } else if (std.mem.eql(u8, tag, "/i")) {
                cur_italic = false;
            } else if (std.mem.eql(u8, tag, "u")) {
                cur_underline = true;
            } else if (std.mem.eql(u8, tag, "/u")) {
                cur_underline = false;
            } else if (std.mem.eql(u8, tag, "s")) {
                cur_strikethrough = true;
            } else if (std.mem.eql(u8, tag, "/s")) {
                cur_strikethrough = false;
            } else if (std.mem.startsWith(u8, tag, "color=")) {
                const hex_str = tag[6..];
                if (hex_str.len >= 8) {
                    cur_color = parseHexColor(hex_str[0..8]) orelse cur_color;
                } else if (hex_str.len >= 6) {
                    var buf: [8]u8 = undefined;
                    @memcpy(buf[0..6], hex_str[0..6]);
                    buf[6] = 'F';
                    buf[7] = 'F';
                    cur_color = parseHexColor(buf[0..8]) orelse cur_color;
                }
            } else if (std.mem.eql(u8, tag, "/color")) {
                cur_color = base.color;
            } else if (std.mem.startsWith(u8, tag, "size=")) {
                const size_str = tag[5..];
                cur_size = std.fmt.parseFloat(f32, size_str) catch cur_size;
            } else if (std.mem.eql(u8, tag, "/size")) {
                cur_size = base.font_size;
            } else {
                try spans.append(allocator, .{
                    .text = text[i .. tag_end + 1],
                    .font_size = cur_size,
                    .font_weight = cur_weight,
                    .color = cur_color,
                    .italic = cur_italic,
                    .underline = cur_underline,
                    .strikethrough = cur_strikethrough,
                });
                i = tag_end + 1;
                continue;
            }
            i = tag_end + 1;
        } else {
            const next_tag = std.mem.indexOfScalarPos(u8, text, i, '<') orelse text.len;
            if (next_tag > i) {
                try spans.append(allocator, .{
                    .text = text[i..next_tag],
                    .font_size = cur_size,
                    .font_weight = cur_weight,
                    .color = cur_color,
                    .italic = cur_italic,
                    .underline = cur_underline,
                    .strikethrough = cur_strikethrough,
                });
            }
            i = next_tag;
        }
    }

    return try spans.toOwnedSlice(allocator);
}

fn parseHexColor(hex: []const u8) ?math.Color {
    if (hex.len < 6) return null;
    const r = std.fmt.parseInt(u8, hex[0..2], 16) catch return null;
    const g = std.fmt.parseInt(u8, hex[2..4], 16) catch return null;
    const b = std.fmt.parseInt(u8, hex[4..6], 16) catch return null;
    const a: u8 = if (hex.len >= 8) (std.fmt.parseInt(u8, hex[6..8], 16) catch 0xFF) else 0xFF;
    return math.Color{ .r = r, .g = g, .b = b, .a = a };
}

/// 测量 Span 数组的总宽高
pub fn measureSpans(allocator: std.mem.Allocator, spans: []const TextSpan) math.Size(f32) {
    if (spans.len == 0) return .{ .width = 0, .height = 14.0 * 1.2 };
    var total_w: f32 = 0;
    var max_h: f32 = 0;
    for (spans) |span| {
        const size = measureText(allocator, span.text, .{
            .font_size = span.font_size,
            .font_weight = span.font_weight,
        });
        total_w += size.width;
        if (size.height > max_h) max_h = size.height;
    }
    return .{ .width = total_w, .height = max_h };
}

/// 绘制 Span 数组 (从左到右, 统一基线)
pub fn drawSpans(
    renderer: anytype,
    allocator: std.mem.Allocator,
    spans: []const TextSpan,
    x: f32,
    y: f32,
) void {
    var cur_x = x;
    for (spans) |span| {
        const span_w = measureTextWidth(allocator, span.text, .{
            .font_size = span.font_size,
            .font_weight = span.font_weight,
        });

        drawText(renderer, allocator, span.text, cur_x, y, .{
            .font_size = span.font_size,
            .font_weight = span.font_weight,
            .color = span.color,
            .italic = span.italic,
        });

        // 下划线 (基线下方约 1px)
        if (span.underline and span_w > 0) {
            const line_thickness = @max(1.0, span.font_size * 0.08);
            const underline_y = y + line_thickness;
            renderer.fillRect(.{
                .x = cur_x,
                .y = underline_y,
                .width = span_w,
                .height = line_thickness,
            }, span.color) catch {};
        }

        // 删除线 (中线位置, 约 x-height 中部)
        if (span.strikethrough and span_w > 0) {
            const line_thickness = @max(1.0, span.font_size * 0.08);
            const strike_y = y - span.font_size * 0.35;
            renderer.fillRect(.{
                .x = cur_x,
                .y = strike_y,
                .width = span_w,
                .height = line_thickness,
            }, span.color) catch {};
        }

        cur_x += span_w;
    }
}

/// 获取字体的 ascent (从基线到字形顶部的距离)
pub fn getFontAscent(allocator: std.mem.Allocator, font_size: f32, font_weight: u16) f32 {
    if (comptime is_macos) {
        var font = coretext.CtFont.create(null, font_size, font_weight) catch {
            return font_size * 0.8;
        };
        defer font.destroy();
        return font.getMetrics().ascent;
    } else if (comptime is_linux) {
        const font_path = findFont(allocator) orelse {
            return font_size * 0.8;
        };
        var font = freetype.FtFont.createFromFile(allocator, font_path.ptr, font_size, font_weight) catch {
            return font_size * 0.8;
        };
        defer font.destroy();
        return font.getMetrics().ascent;
    } else {
        return font_size * 0.8;
    }
}

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

        // 如果指定了 max_width, 使用 TextLayout 计算多行高度
        if (style.max_width) |max_w| {
            return text_layout_ft.TextLayout.measureMultiline(
                &font,
                text,
                .{
                    .font_size = style.font_size,
                    .max_width = max_w,
                },
            );
        }

        const text_w = font.measureText(text);
        const metrics = font.getMetrics();
        return .{ .width = text_w, .height = metrics.line_height };
    } else {
        return .{ .width = 0, .height = style.font_size * 1.2 };
    }
}

/// 绘制文本 (创建字体 → 布局 → 渲染, 一次性调用)
pub fn drawText(
    renderer: anytype,
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
            .{ .font = &font, .font_size = style.font_size, .max_width = style.max_width, .text_align = style.text_align, .italic = style.italic },
        ) catch return;
        defer tl.deinit();

        renderer.drawTextLayout(&tl, x, y, style.color) catch {};
    } else {
        _ = .{ renderer, allocator, x, y };
    }
}

/// 绘制单行文本并裁剪到 max_width (超出部分不绘制); 返回实际绘制宽度
pub fn drawTextClipped(
    renderer: anytype,
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
            const entry = atlas.getOrRasterizeItalic(device, &font, sg.glyph_id, style.font_size, style.italic) catch continue;
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
