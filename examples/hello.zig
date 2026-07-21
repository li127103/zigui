//! zigui hello 示例 - 文本渲染演示

const std = @import("std");
const zigui = @import("zigui");
const math = zigui.math;
const coretext = zigui.coretext;
const text_layout = zigui.text_layout;

pub fn main() !void {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var app = try zigui.app.App.init(allocator, .{
        .title = "zigui - Text Rendering",
        .width = 900,
        .height = 640,
    });
    defer app.deinit();

    // 创建字体
    var font_regular = try coretext.CtFont.create("SF Pro Text", 16.0, 400);
    defer font_regular.destroy();
    var font_title = try coretext.CtFont.create("SF Pro Display", 28.0, 700);
    defer font_title.destroy();
    var font_mono = try coretext.CtFont.create("SF Mono", 13.0, 400);
    defer font_mono.destroy();
    var font_large = try coretext.CtFont.create("SF Pro Display", 48.0, 800);
    defer font_large.destroy();

    try app.run(&drawFrame);

    // 静态引用供 drawFrame 使用
    _ = &font_regular;
    _ = &font_title;
    _ = &font_mono;
    _ = &font_large;
}

// 全局字体引用 (简化示例)
var g_font_regular: ?coretext.CtFont = null;
var g_font_title: ?coretext.CtFont = null;
var g_font_mono: ?coretext.CtFont = null;
var g_font_large: ?coretext.CtFont = null;
var g_initialized: bool = false;

fn ensureFonts() void {
    if (g_initialized) return;
    g_font_regular = coretext.CtFont.create("SF Pro Text", 16.0, 400) catch null;
    g_font_title = coretext.CtFont.create("SF Pro Display", 28.0, 700) catch null;
    g_font_mono = coretext.CtFont.create("SF Mono", 13.0, 400) catch null;
    g_font_large = coretext.CtFont.create("SF Pro Display", 48.0, 800) catch null;
    g_initialized = true;
}

fn drawFrame(app: *zigui.app.App) void {
    ensureFonts();
    const r = app.getRenderer();
    const fb = app.getFramebufferSize();
    const w: f32 = @floatFromInt(fb.width);
    const h: f32 = @floatFromInt(fb.height);

    // 背景
    r.fillRect(.{ .x = 0, .y = 0, .width = w, .height = h }, math.Color.hex(0x0F172AFF)) catch {};

    // 标题栏
    r.fillRect(.{ .x = 0, .y = 0, .width = w, .height = 52 }, math.Color.hex(0x1E293BFF)) catch {};

    // 窗口装饰点
    const dot_colors = [_]u32{ 0xFF5F57FF, 0xFEBC2EFF, 0x28C840FF };
    for (dot_colors, 0..) |dc, i| {
        const dx: f32 = 20 + @as(f32, @floatFromInt(i)) * 22;
        r.fillRoundedRect(.{ .x = dx, .y = 18, .width = 14, .height = 14 }, 7, math.Color.hex(dc)) catch {};
    }

    // 标题文本
    if (g_font_title) |*ft| {
        var tl = text_layout.TextLayout.layout(
            app.allocator,
            app.getGlyphAtlas(),
            app.getMetalDevice(),
            "zigui Text Engine",
            .{ .font = ft, .font_size = 28.0 },
        ) catch return;
        defer tl.deinit();
        r.drawText(&tl, 90, 12, math.Color.hex(0xF8FAFCFF)) catch {};
    }

    // 大标题
    if (g_font_large) |*fl| {
        var tl = text_layout.TextLayout.layout(
            app.allocator,
            app.getGlyphAtlas(),
            app.getMetalDevice(),
            "Hello, Zigui!",
            .{ .font = fl, .font_size = 48.0 },
        ) catch return;
        defer tl.deinit();
        r.drawText(&tl, 40, 80, math.Color.hex(0x38BDF8FF)) catch {};
    }

    // 正文段落
    if (g_font_regular) |*fr| {
        var tl = text_layout.TextLayout.layout(
            app.allocator,
            app.getGlyphAtlas(),
            app.getMetalDevice(),
            "Cross-platform GPU-accelerated GUI framework written in Zig 0.16.",
            .{ .font = fr, .font_size = 16.0 },
        ) catch return;
        defer tl.deinit();
        r.drawText(&tl, 40, 155, math.Color.hex(0xCBD5E1FF)) catch {};
    }

    // 特性卡片
    const cards = [_]struct { title: []const u8, desc: []const u8, color: u32 }{
        .{ .title = "Metal Rendering", .desc = "Native macOS GPU pipeline", .color = 0x3B82F6FF },
        .{ .title = "CoreText Shaping", .desc = "System font engine + atlas", .color = 0x8B5CF6FF },
        .{ .title = "Glyph Atlas", .desc = "Shelf-packing R8 texture", .color = 0x10B981FF },
        .{ .title = "Text Layout", .desc = "Line break + alignment", .color = 0xF59E0BFF },
    };

    const card_w: f32 = (w - 40 * 2 - 16 * 3) / 4.0;
    const card_y: f32 = 210;
    const card_h: f32 = 120;

    for (cards, 0..) |card, i| {
        const cx: f32 = 40 + @as(f32, @floatFromInt(i)) * (card_w + 16);

        // 卡片背景
        r.fillRoundedRect(.{ .x = cx, .y = card_y, .width = card_w, .height = card_h }, 10, math.Color.hex(0x1E293BFF)) catch {};

        // 顶部色条
        r.fillRoundedRect(.{ .x = cx, .y = card_y, .width = card_w, .height = 4 }, 2, math.Color.hex(card.color)) catch {};

        // 卡片标题
        if (g_font_regular) |*fr| {
            var tl = text_layout.TextLayout.layout(
                app.allocator,
                app.getGlyphAtlas(),
                app.getMetalDevice(),
                card.title,
                .{ .font = fr, .font_size = 15.0 },
            ) catch continue;
            defer tl.deinit();
            r.drawText(&tl, cx + 14, card_y + 20, math.Color.hex(0xF8FAFCFF)) catch {};
        }

        // 卡片描述
        if (g_font_regular) |*fr| {
            var tl = text_layout.TextLayout.layout(
                app.allocator,
                app.getGlyphAtlas(),
                app.getMetalDevice(),
                card.desc,
                .{ .font = fr, .font_size = 12.0 },
            ) catch continue;
            defer tl.deinit();
            r.drawText(&tl, cx + 14, card_y + 50, math.Color.hex(0x94A3B8FF)) catch {};
        }
    }

    // 代码区域
    const code_y: f32 = 360;
    r.fillRoundedRect(.{ .x = 40, .y = code_y, .width = w - 80, .height = 180 }, 10, math.Color.hex(0x1E293BFF)) catch {};

    if (g_font_mono) |*fm| {
        const code_lines = [_][]const u8{
            "const zigui = @import(\"zigui\");",
            "",
            "pub fn main() !void {",
            "    var app = try zigui.app.App.init(alloc, .{",
            "        .title = \"Hello zigui\",",
            "        .width = 900, .height = 640,",
            "    });",
            "    try app.run(&drawFrame);",
            "}",
        };

        for (code_lines, 0..) |line_text, li| {
            if (line_text.len == 0) continue;
            var tl = text_layout.TextLayout.layout(
                app.allocator,
                app.getGlyphAtlas(),
                app.getMetalDevice(),
                line_text,
                .{ .font = fm, .font_size = 13.0 },
            ) catch continue;
            defer tl.deinit();

            // 简单语法高亮
            const color: u32 = if (std.mem.startsWith(u8, line_text, "const") or
                std.mem.startsWith(u8, line_text, "pub"))
                0xC792EAFF // 紫色关键字
            else if (std.mem.indexOfScalar(u8, line_text, '"') != null)
                0xC3E88DFF // 绿色字符串
            else if (std.mem.indexOfScalar(u8, line_text, '(') != null)
                0x82AAFFFF // 蓝色函数
            else
                0xA6ACCDFF; // 默认灰色

            const ly: f32 = code_y + 16 + @as(f32, @floatFromInt(li)) * 17.0;
            r.drawText(&tl, 60, ly, math.Color.hex(color)) catch {};
        }
    }

    // 底部状态栏
    r.fillRect(.{ .x = 0, .y = h - 32, .width = w, .height = 32 }, math.Color.hex(0x1E293BFF)) catch {};
    if (g_font_regular) |*fr| {
        var tl = text_layout.TextLayout.layout(
            app.allocator,
            app.getGlyphAtlas(),
            app.getMetalDevice(),
            "zigui v0.1.0  |  macOS Metal  |  CoreText  |  60 FPS",
            .{ .font = fr, .font_size = 12.0 },
        ) catch return;
        defer tl.deinit();
        r.drawText(&tl, 16, h - 24, math.Color.hex(0x64748BFF)) catch {};
    }
}
