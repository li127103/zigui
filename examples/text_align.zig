//! zigui 文本对齐示例 - 左/居中/右/两端对齐 (Linux Vulkan + FreeType 多行布局)
//!
//! 演示:
//!   - 四个文本块分别展示 left / center / right / justify 四种水平对齐
//!   - 中英混排长段落, 依赖 max_width 自动断行 (word wrap)
//!   - 两端对齐: 末行保持左对齐, 其余行均匀撑满容器宽度

const std = @import("std");
const zigui = @import("zigui");
const math = zigui.math;

const App = zigui.app.App;
const text_layout = zigui.text_layout_ft;
const TextAlign = text_layout.TextAlign;

// ── 演示数据 ────────────────────────────────────────────────────────────────

const Demo = struct {
    label: []const u8,
    alignment: TextAlign,
};

const demos = [_]Demo{
    .{ .label = "left · 左对齐", .alignment = .left },
    .{ .label = "center · 居中对齐", .alignment = .center },
    .{ .label = "right · 右对齐", .alignment = .right },
    .{ .label = "justify · 两端对齐", .alignment = .justify },
};

/// 中英混排段落 (足够长, 可自动断行为多行)
const paragraph =
    "zigui 是用 Zig 语言构建的跨平台 GPU 加速 GUI 框架。The text layout " ++
    "engine supports multi-line word wrapping and four alignment modes. " ++
    "文本布局引擎支持多行自动断行，并提供左对齐、居中、右对齐与两端对齐四种排版方式，" ++
    "适用于中英文混排的界面场景。";

// ── 入口 ────────────────────────────────────────────────────────────────────

pub fn main() !void {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var app = try App.init(allocator, .{
        .title = "zigui - Text Alignment",
        .width = 960,
        .height = 720,
    });
    defer app.deinit();

    try app.run(&drawFrame);

    deinitFontCache();
}

// ── 每帧: 渲染 ──────────────────────────────────────────────────────────────

fn drawFrame(app: *App) void {
    const fb = app.getFramebufferSize();
    const w: f32 = @floatFromInt(fb.width);
    const h: f32 = @floatFromInt(fb.height);
    const r = app.getRenderer();

    // 背景
    r.fillRect(.{ .x = 0, .y = 0, .width = w, .height = h }, math.Color.hex(0x0F172AFF)) catch {};

    // 主标题
    const pad: f32 = 30.0;
    drawTextBlock(app, "Text Alignment · 文本对齐", pad, 26, null, 22.0, 700, 0xF8FAFCFF, .left);
    drawTextBlock(app, "四种水平对齐方式 (多行自动断行, 中英混排)", pad, 58, null, 13.0, 400, 0x94A3B8FF, .left);

    // 2x2 网格
    const gap: f32 = 24.0;
    const top: f32 = 96.0;
    const cell_w = (w - pad * 2.0 - gap) / 2.0;
    const cell_h = (h - top - pad - gap) / 2.0;

    for (demos, 0..) |demo, idx| {
        const col: f32 = @floatFromInt(idx % 2);
        const row: f32 = @floatFromInt(idx / 2);
        const cx = pad + col * (cell_w + gap);
        const cy = top + row * (cell_h + gap);
        const card = math.Rect(f32){ .x = cx, .y = cy, .width = cell_w, .height = cell_h };

        // 卡片背景
        r.drawShadow(card, 12, .{}) catch {};
        r.fillRoundedRect(card, 14, math.Color.hex(0x1E293BFF)) catch {};

        // 对齐方式标签
        drawTextBlock(app, demo.label, cx + 18, cy + 16, null, 14.0, 600, 0x60A5FAFF, .left);

        // 段落 (在文本区域内按指定对齐方式布局)
        const text_x = cx + 18.0;
        const text_y = cy + 48.0;
        const text_w = cell_w - 36.0;
        drawTextBlock(app, paragraph, text_x, text_y, text_w, 14.0, 400, 0xCBD5E1FF, demo.alignment);
    }
}

// ── 文本渲染 (多行布局 + 对齐) ──────────────────────────────────────────────

/// 布局并绘制文本块。max_width 为 null 时单行不换行; 否则自动断行并按
/// alignment 对齐。y 为文本块顶部 (内部换算为各行基线)。
fn drawTextBlock(
    app: *App,
    text: []const u8,
    x: f32,
    y: f32,
    max_width: ?f32,
    size: f32,
    weight: u16,
    color: u32,
    alignment: TextAlign,
) void {
    if (text.len == 0) return;
    g_font_allocator = app.allocator;
    const font = getFont(app.allocator, size, weight) orelse return;

    var tl = text_layout.TextLayout.layout(
        app.allocator,
        app.getGlyphAtlas(),
        app.getVulkanDevice(),
        text,
        .{
            .font = font,
            .font_size = size,
            .max_width = max_width,
            .text_align = alignment,
            .wrap = .word,
        },
    ) catch return;
    defer tl.deinit();

    const r = app.getRenderer();
    for (tl.lines.items) |*line| {
        // drawText 的 origin_y 是基线; baseline_y 已含 ascent, 相对布局顶部
        r.drawText(line.glyphs.items, x, y + line.baseline_y, math.Color.hex(color)) catch {};
    }
}

// ── 字体缓存 (复用 input.zig 模式: 按 size+weight 缓存, 优先 CJK 字体) ─────

const CachedFont = struct {
    size: f32,
    weight: u16,
    font: zigui.freetype.FtFont,
};

const MAX_CACHED_FONTS = 16;
var g_font_cache: [MAX_CACHED_FONTS]CachedFont = undefined;
var g_font_cache_len: usize = 0;
var g_font_path: ?[:0]u8 = null;
var g_font_allocator: ?std.mem.Allocator = null;

fn resolveFontPath(allocator: std.mem.Allocator) ?[:0]const u8 {
    if (g_font_path) |p| return p;
    const freetype = zigui.freetype;
    if (freetype.findCjkFont(allocator)) |p| {
        g_font_path = p;
        return p;
    } else |_| {}
    if (freetype.findSystemFont(allocator, null)) |p| {
        g_font_path = p;
        return p;
    } else |_| {}
    return null;
}

fn getFont(allocator: std.mem.Allocator, size: f32, weight: u16) ?*zigui.freetype.FtFont {
    for (g_font_cache[0..g_font_cache_len]) |*entry| {
        if (entry.size == size and entry.weight == weight) return &entry.font;
    }
    if (g_font_cache_len >= MAX_CACHED_FONTS) return null;
    const path = resolveFontPath(allocator) orelse return null;
    const font = zigui.freetype.FtFont.createFromFile(allocator, path.ptr, size, weight) catch return null;
    g_font_cache[g_font_cache_len] = .{ .size = size, .weight = weight, .font = font };
    g_font_cache_len += 1;
    return &g_font_cache[g_font_cache_len - 1].font;
}

fn deinitFontCache() void {
    for (g_font_cache[0..g_font_cache_len]) |*entry| {
        entry.font.destroy();
    }
    g_font_cache_len = 0;
    if (g_font_path) |p| {
        if (g_font_allocator) |a| a.free(p);
        g_font_path = null;
    }
}
