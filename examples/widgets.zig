//! zigui widgets 示例 - 控件系统演示 (跨平台)

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
        .title = "zigui - Widgets Demo",
        .width = 800,
        .height = 600,
    });
    defer app.deinit();

    try app.run(&drawFrame);
}

var g_click_count: u32 = 0;
var g_frame: u32 = 0;

fn drawFrame(app: *zigui.app.App) void {
    g_frame += 1;
    const r = app.getRenderer();
    const fb = app.getFramebufferSize();
    const w: f32 = @floatFromInt(fb.width);
    const h: f32 = @floatFromInt(fb.height);

    // 背景
    r.fillRect(.{ .x = 0, .y = 0, .width = w, .height = h }, math.Color.hex(0x0F172AFF)) catch {};

    // ── 标题栏 ──
    r.fillRect(.{ .x = 0, .y = 0, .width = w, .height = 48 }, math.Color.hex(0x1E293BFF)) catch {};
    drawText(app, "zigui Widgets", 20, 14, 20.0, 700, 0xF8FAFCFF);

    // 窗口装饰点
    const dots = [_]u32{ 0xFF5F57FF, 0xFEBC2EFF, 0x28C840FF };
    for (dots, 0..) |dc, i| {
        const dx: f32 = w - 70 + @as(f32, @floatFromInt(i)) * 22;
        r.fillRoundedRect(.{ .x = dx, .y = 17, .width = 14, .height = 14 }, 7, math.Color.hex(dc)) catch {};
    }

    // ── 左侧面板: 按钮组 ──
    const panel_x: f32 = 24;
    const panel_y: f32 = 72;
    const panel_w: f32 = 220;
    const panel_h: f32 = h - 96;

    r.fillRoundedRect(.{ .x = panel_x, .y = panel_y, .width = panel_w, .height = panel_h }, 12, math.Color.hex(0x1E293BFF)) catch {};
    drawText(app, "Buttons", panel_x + 16, panel_y + 16, 14.0, 600, 0x94A3B8FF);

    // Primary button
    const btn_y = panel_y + 48;
    drawButton(app, "Primary", panel_x + 16, btn_y, panel_w - 32, 38, 0x3B82F6FF, 0xFFFFFFFF);
    drawButton(app, "Success", panel_x + 16, btn_y + 50, panel_w - 32, 38, 0x22C55EFF, 0xFFFFFFFF);
    drawButton(app, "Warning", panel_x + 16, btn_y + 100, panel_w - 32, 38, 0xF59E0BFF, 0x1E293BFF);
    drawButton(app, "Danger", panel_x + 16, btn_y + 150, panel_w - 32, 38, 0xEF4444FF, 0xFFFFFFFF);

    // Outline button
    const outline_y = btn_y + 200;
    r.fillRoundedRect(.{ .x = panel_x + 16, .y = outline_y, .width = panel_w - 32, .height = 38 }, 8, math.Color.hex(0x3B82F6FF)) catch {};
    r.fillRoundedRect(.{ .x = panel_x + 17.5, .y = outline_y + 1.5, .width = panel_w - 35, .height = 35 }, 7, math.Color.hex(0x1E293BFF)) catch {};
    drawTextCentered(app, "Outline", panel_x + 16, outline_y, panel_w - 32, 38, 14.0, 500, 0x3B82F6FF);

    // ── 右侧面板: 卡片 + 文本 ──
    const right_x: f32 = panel_x + panel_w + 24;
    const right_w: f32 = w - right_x - 24;

    r.fillRoundedRect(.{ .x = right_x, .y = panel_y, .width = right_w, .height = 160 }, 12, math.Color.hex(0x1E293BFF)) catch {};
    r.fillRoundedRect(.{ .x = right_x, .y = panel_y, .width = right_w, .height = 4 }, 2, math.Color.hex(0x8B5CF6FF)) catch {};

    drawText(app, "Widget System", right_x + 20, panel_y + 20, 18.0, 700, 0xF8FAFCFF);
    drawText(app, "Retained-mode widget tree with:", right_x + 20, panel_y + 52, 14.0, 400, 0xCBD5E1FF);
    drawText(app, "  - VTable polymorphism (zero-cost)", right_x + 20, panel_y + 76, 13.0, 400, 0x94A3B8FF);
    drawText(app, "  - Flexbox layout (row/column/gap)", right_x + 20, panel_y + 96, 13.0, 400, 0x94A3B8FF);
    drawText(app, "  - Event bubbling + hit-test", right_x + 20, panel_y + 116, 13.0, 400, 0x94A3B8FF);
    drawText(app, "  - GPU glyph atlas rendering", right_x + 20, panel_y + 136, 13.0, 400, 0x94A3B8FF);

    // 统计卡片
    const stat_y = panel_y + 180;
    const stat_w = (right_w - 16) / 2.0;

    r.fillRoundedRect(.{ .x = right_x, .y = stat_y, .width = stat_w, .height = 100 }, 10, math.Color.hex(0x1E293BFF)) catch {};
    drawText(app, "Frame", right_x + 16, stat_y + 16, 12.0, 400, 0x64748BFF);
    var buf: [32]u8 = undefined;
    const frame_str = std.fmt.bufPrint(&buf, "{d}", .{g_frame}) catch "0";
    drawText(app, frame_str, right_x + 16, stat_y + 40, 28.0, 700, 0x38BDF8FF);

    r.fillRoundedRect(.{ .x = right_x + stat_w + 16, .y = stat_y, .width = stat_w, .height = 100 }, 10, math.Color.hex(0x1E293BFF)) catch {};
    drawText(app, "Clicks", right_x + stat_w + 32, stat_y + 16, 12.0, 400, 0x64748BFF);
    const click_str = std.fmt.bufPrint(&buf, "{d}", .{g_click_count}) catch "0";
    drawText(app, click_str, right_x + stat_w + 32, stat_y + 40, 28.0, 700, 0x22C55EFF);

    // 进度条
    const prog_y = stat_y + 120;
    r.fillRoundedRect(.{ .x = right_x, .y = prog_y, .width = right_w, .height = 80 }, 10, math.Color.hex(0x1E293BFF)) catch {};
    drawText(app, "Progress", right_x + 16, prog_y + 12, 12.0, 400, 0x64748BFF);

    const bar_x = right_x + 16;
    const bar_w = right_w - 32;
    const bar_y = prog_y + 40;
    r.fillRoundedRect(.{ .x = bar_x, .y = bar_y, .width = bar_w, .height = 8 }, 4, math.Color.hex(0x334155FF)) catch {};

    const progress: f32 = @sin(@as(f32, @floatFromInt(g_frame)) * 0.02) * 0.5 + 0.5;
    const fill_w = bar_w * progress;
    if (fill_w > 4) {
        r.fillRoundedRect(.{ .x = bar_x, .y = bar_y, .width = fill_w, .height = 8 }, 4, math.Color.hex(0x8B5CF6FF)) catch {};
    }

    // 底部状态栏
    r.fillRect(.{ .x = 0, .y = h - 28, .width = w, .height = 28 }, math.Color.hex(0x1E293BFF)) catch {};
    drawText(app, "zigui v0.1.0  |  Widget Tree: Container > Label + Button  |  Flexbox Layout", 12, h - 21, 11.0, 400, 0x64748BFF);
}

// ── 辅助绘制函数 (跨平台) ────────────────────────────────────────────────────

fn drawText(app: *zigui.app.App, text: []const u8, x: f32, y: f32, size: f32, weight: u16, color: u32) void {
    if (is_linux) {
        drawTextLinux(app, text, x, y, size, weight, color);
    } else if (is_macos) {
        drawTextMacos(app, text, x, y, size, weight, color);
    }
}

fn drawTextCentered(app: *zigui.app.App, text: []const u8, x: f32, y: f32, w: f32, h: f32, size: f32, weight: u16, color: u32) void {
    if (is_linux) {
        drawTextCenteredLinux(app, text, x, y, w, h, size, weight, color);
    } else if (is_macos) {
        drawTextCenteredMacos(app, text, x, y, w, h, size, weight, color);
    }
}

fn drawButton(app: *zigui.app.App, text: []const u8, x: f32, y: f32, w: f32, h: f32, bg: u32, text_color: u32) void {
    app.getRenderer().fillRoundedRect(.{ .x = x, .y = y, .width = w, .height = h }, 8, math.Color.hex(bg)) catch {};
    drawTextCentered(app, text, x, y, w, h, 14.0, 500, text_color);
}

// ── Linux 文本渲染 ──────────────────────────────────────────────────────────

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

fn drawTextCenteredLinux(app: *zigui.app.App, text: []const u8, x: f32, y: f32, w: f32, h: f32, size: f32, weight: u16, color: u32) void {
    comptime if (!is_linux) return;

    const freetype = zigui.freetype;
    const font_path = freetype.findSystemFont(app.allocator, null) catch {
        drawTextLinux(app, text, x, y + (h - size) / 2.0, size, weight, color);
        return;
    };
    defer app.allocator.free(font_path);
    var font = freetype.FtFont.createFromFile(app.allocator, font_path.ptr, size, weight) catch {
        drawTextLinux(app, text, x, y + (h - size) / 2.0, size, weight, color);
        return;
    };
    defer font.destroy();
    const text_w = font.measureText(text);
    const tx = x + (w - text_w) / 2.0;
    const ty = y + (h - size) / 2.0;
    drawTextLinux(app, text, tx, ty, size, weight, color);
}

// ── macOS 文本渲染 ──────────────────────────────────────────────────────────

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

fn drawTextCenteredMacos(app: *zigui.app.App, text: []const u8, x: f32, y: f32, w: f32, h: f32, size: f32, weight: u16, color: u32) void {
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

    const tx = x + (w - tl.total_size.width) / 2.0;
    const ty = y + (h - tl.total_size.height) / 2.0;
    app.getRenderer().drawText(&tl, tx, ty, math.Color.hex(color)) catch {};
}
