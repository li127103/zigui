//! zigui hello 示例 - 文本渲染演示 (跨平台: macOS Metal / Linux Vulkan)

const std = @import("std");
const builtin = @import("builtin");
const zigui = @import("zigui");
const math = zigui.math;

const is_linux = builtin.os.tag == .linux;
const is_macos = builtin.os.tag == .macos;

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

    try app.run(&drawFrame);
}

fn drawFrame(app: *zigui.app.App) void {
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
    drawText(app, "zigui Text Engine", 90, 24, 28.0, 700, 0xF8FAFCFF);

    // 大标题
    drawText(app, "Hello, Zigui!", 40, 100, 48.0, 800, 0x38BDF8FF);

    // 正文段落
    drawText(app, "Cross-platform GPU-accelerated GUI framework written in Zig 0.16.", 40, 170, 16.0, 400, 0xCBD5E1FF);

    // 特性卡片
    const cards = [_]struct { title: []const u8, desc: []const u8, color: u32 }{
        .{ .title = "GPU Rendering", .desc = "Metal / Vulkan pipeline", .color = 0x3B82F6FF },
        .{ .title = "Font Shaping", .desc = "CoreText / FreeType", .color = 0x8B5CF6FF },
        .{ .title = "Glyph Atlas", .desc = "Shelf-packing R8 texture", .color = 0x10B981FF },
        .{ .title = "Text Layout", .desc = "Line break + alignment", .color = 0xF59E0BFF },
    };

    const card_w: f32 = (w - 40 * 2 - 16 * 3) / 4.0;
    const card_y: f32 = 220;
    const card_h: f32 = 120;

    for (cards, 0..) |card, i| {
        const cx: f32 = 40 + @as(f32, @floatFromInt(i)) * (card_w + 16);
        r.fillRoundedRect(.{ .x = cx, .y = card_y, .width = card_w, .height = card_h }, 10, math.Color.hex(0x1E293BFF)) catch {};
        r.fillRoundedRect(.{ .x = cx, .y = card_y, .width = card_w, .height = 4 }, 2, math.Color.hex(card.color)) catch {};
        drawText(app, card.title, cx + 14, card_y + 30, 15.0, 600, 0xF8FAFCFF);
        drawText(app, card.desc, cx + 14, card_y + 60, 12.0, 400, 0x94A3B8FF);
    }

    // 代码区域
    const code_y: f32 = 370;
    r.fillRoundedRect(.{ .x = 40, .y = code_y, .width = w - 80, .height = 180 }, 10, math.Color.hex(0x1E293BFF)) catch {};

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
        const color: u32 = if (std.mem.startsWith(u8, line_text, "const") or
            std.mem.startsWith(u8, line_text, "pub"))
            0xC792EAFF
        else if (std.mem.indexOfScalar(u8, line_text, '"') != null)
            0xC3E88DFF
        else if (std.mem.indexOfScalar(u8, line_text, '(') != null)
            0x82AAFFFF
        else
            0xA6ACCDFF;

        const ly: f32 = code_y + 24 + @as(f32, @floatFromInt(li)) * 17.0;
        drawText(app, line_text, 60, ly, 13.0, 400, color);
    }

    // 底部状态栏
    r.fillRect(.{ .x = 0, .y = h - 32, .width = w, .height = 32 }, math.Color.hex(0x1E293BFF)) catch {};
    if (comptime is_linux) {
        drawText(app, "zigui v0.1.0  |  Linux Vulkan  |  FreeType  |  60 FPS", 16, h - 22, 12.0, 400, 0x64748BFF);
    } else if (comptime is_macos) {
        drawText(app, "zigui v0.1.0  |  macOS Metal  |  CoreText  |  60 FPS", 16, h - 22, 12.0, 400, 0x64748BFF);
    }
}

// ── 跨平台文本绘制 ──────────────────────────────────────────────────────────

fn drawText(app: *zigui.app.App, text: []const u8, x: f32, y: f32, size: f32, weight: u16, color: u32) void {
    if (is_linux) {
        drawTextLinux(app, text, x, y, size, weight, color);
    } else if (is_macos) {
        drawTextMacos(app, text, x, y, size, weight, color);
    }
}

fn drawTextLinux(app: *zigui.app.App, text: []const u8, x: f32, y: f32, size: f32, weight: u16, color: u32) void {
    comptime if (!is_linux) return;

    const freetype = zigui.freetype;
    const vulkan_renderer = zigui.vulkan_renderer;

    const font_path = freetype.findSystemFont(app.allocator, null) catch return;
    defer app.allocator.free(font_path);

    var font = freetype.FtFont.createFromFile(app.allocator, font_path.ptr, size, weight) catch return;
    defer font.destroy();

    var shaped: [512]freetype.ShapedGlyph = undefined;
    const glyph_count = font.shapeText(text, &shaped);
    if (glyph_count == 0) return;

    var placed: [512]vulkan_renderer.PlacedGlyph = undefined;
    var pen_x: f32 = 0;
    var placed_count: usize = 0;

    const atlas = app.getGlyphAtlas();
    const device = app.getVulkanDevice();

    for (0..glyph_count) |i| {
        const sg = shaped[i];
        const entry = atlas.getOrRasterize(device, &font, sg.glyph_id, size) catch continue;
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

    if (placed_count == 0) return;
    app.getRenderer().drawText(placed[0..placed_count], x, y, math.Color.hex(color)) catch {};
}

fn drawTextMacos(app: *zigui.app.App, text: []const u8, x: f32, y: f32, size: f32, weight: u16, color: u32) void {
    comptime if (!is_macos) return;

    const coretext = zigui.coretext;
    const text_layout = zigui.text_layout;

    var font = coretext.CtFont.create(null, size, weight) catch return;
    defer font.destroy();

    var tl = text_layout.TextLayout.layout(
        app.allocator,
        app.getGlyphAtlas(),
        app.getMetalDevice(),
        text,
        .{ .font = &font, .font_size = size },
    ) catch return;
    defer tl.deinit();

    app.getRenderer().drawText(&tl, x, y, math.Color.hex(color)) catch {};
}
