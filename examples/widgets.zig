//! zigui widgets 示例 - 控件系统演示

const std = @import("std");
const zigui = @import("zigui");
const math = zigui.math;

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
    drawText(r, app, "zigui Widgets", 20, 14, 20.0, 700, 0xF8FAFCFF);

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
    drawText(r, app, "Buttons", panel_x + 16, panel_y + 16, 14.0, 600, 0x94A3B8FF);

    // Primary button
    const btn_y = panel_y + 48;
    drawButton(r, app, "Primary", panel_x + 16, btn_y, panel_w - 32, 38, 0x3B82F6FF, 0x60A5FAFF, 0xFFFFFFFF);

    // Success button
    drawButton(r, app, "Success", panel_x + 16, btn_y + 50, panel_w - 32, 38, 0x22C55EFF, 0x4ADE80FF, 0xFFFFFFFF);

    // Warning button
    drawButton(r, app, "Warning", panel_x + 16, btn_y + 100, panel_w - 32, 38, 0xF59E0BFF, 0xFBBF24FF, 0x1E293BFF);

    // Danger button
    drawButton(r, app, "Danger", panel_x + 16, btn_y + 150, panel_w - 32, 38, 0xEF4444FF, 0xF87171FF, 0xFFFFFFFF);

    // Outline button
    const outline_y = btn_y + 200;
    r.fillRoundedRect(.{ .x = panel_x + 16, .y = outline_y, .width = panel_w - 32, .height = 38 }, 8, math.Color.hex(0x00000000)) catch {};
    // 边框模拟
    r.fillRoundedRect(.{ .x = panel_x + 16, .y = outline_y, .width = panel_w - 32, .height = 38 }, 8, math.Color.hex(0x3B82F6FF)) catch {};
    r.fillRoundedRect(.{ .x = panel_x + 17.5, .y = outline_y + 1.5, .width = panel_w - 35, .height = 35 }, 7, math.Color.hex(0x1E293BFF)) catch {};
    drawTextCentered(r, app, "Outline", panel_x + 16, outline_y, panel_w - 32, 38, 14.0, 500, 0x3B82F6FF);

    // ── 右侧面板: 卡片 + 文本 ──
    const right_x: f32 = panel_x + panel_w + 24;
    const right_w: f32 = w - right_x - 24;

    // 信息卡片
    r.fillRoundedRect(.{ .x = right_x, .y = panel_y, .width = right_w, .height = 160 }, 12, math.Color.hex(0x1E293BFF)) catch {};
    r.fillRoundedRect(.{ .x = right_x, .y = panel_y, .width = right_w, .height = 4 }, 2, math.Color.hex(0x8B5CF6FF)) catch {};

    drawText(r, app, "Widget System", right_x + 20, panel_y + 20, 18.0, 700, 0xF8FAFCFF);
    drawText(r, app, "Retained-mode widget tree with:", right_x + 20, panel_y + 52, 14.0, 400, 0xCBD5E1FF);
    drawText(r, app, "  - VTable polymorphism (zero-cost)", right_x + 20, panel_y + 76, 13.0, 400, 0x94A3B8FF);
    drawText(r, app, "  - Flexbox layout (row/column/gap)", right_x + 20, panel_y + 96, 13.0, 400, 0x94A3B8FF);
    drawText(r, app, "  - Event bubbling + hit-test", right_x + 20, panel_y + 116, 13.0, 400, 0x94A3B8FF);
    drawText(r, app, "  - CoreText glyph atlas rendering", right_x + 20, panel_y + 136, 13.0, 400, 0x94A3B8FF);

    // 统计卡片
    const stat_y = panel_y + 180;
    const stat_w = (right_w - 16) / 2.0;

    // 卡片 1: Frame
    r.fillRoundedRect(.{ .x = right_x, .y = stat_y, .width = stat_w, .height = 100 }, 10, math.Color.hex(0x1E293BFF)) catch {};
    drawText(r, app, "Frame", right_x + 16, stat_y + 16, 12.0, 400, 0x64748BFF);
    var buf: [32]u8 = undefined;
    const frame_str = std.fmt.bufPrint(&buf, "{d}", .{g_frame}) catch "0";
    drawText(r, app, frame_str, right_x + 16, stat_y + 40, 28.0, 700, 0x38BDF8FF);

    // 卡片 2: Clicks
    r.fillRoundedRect(.{ .x = right_x + stat_w + 16, .y = stat_y, .width = stat_w, .height = 100 }, 10, math.Color.hex(0x1E293BFF)) catch {};
    drawText(r, app, "Clicks", right_x + stat_w + 32, stat_y + 16, 12.0, 400, 0x64748BFF);
    const click_str = std.fmt.bufPrint(&buf, "{d}", .{g_click_count}) catch "0";
    drawText(r, app, click_str, right_x + stat_w + 32, stat_y + 40, 28.0, 700, 0x22C55EFF);

    // 进度条
    const prog_y = stat_y + 120;
    r.fillRoundedRect(.{ .x = right_x, .y = prog_y, .width = right_w, .height = 80 }, 10, math.Color.hex(0x1E293BFF)) catch {};
    drawText(r, app, "Progress", right_x + 16, prog_y + 12, 12.0, 400, 0x64748BFF);

    // 进度条背景
    const bar_x = right_x + 16;
    const bar_w = right_w - 32;
    const bar_y = prog_y + 40;
    r.fillRoundedRect(.{ .x = bar_x, .y = bar_y, .width = bar_w, .height = 8 }, 4, math.Color.hex(0x334155FF)) catch {};

    // 进度条填充 (动画)
    const progress: f32 = @sin(@as(f32, @floatFromInt(g_frame)) * 0.02) * 0.5 + 0.5;
    const fill_w = bar_w * progress;
    if (fill_w > 4) {
        r.fillRoundedRect(.{ .x = bar_x, .y = bar_y, .width = fill_w, .height = 8 }, 4, math.Color.hex(0x8B5CF6FF)) catch {};
    }

    // 底部状态栏
    r.fillRect(.{ .x = 0, .y = h - 28, .width = w, .height = 28 }, math.Color.hex(0x1E293BFF)) catch {};
    drawText(r, app, "zigui v0.1.0  |  Widget Tree: Container > Label + Button  |  Flexbox Layout", 12, h - 21, 11.0, 400, 0x64748BFF);
}

// ── 辅助绘制函数 ──────────────────────────────────────────────────────────────

fn drawText(r: *zigui.renderer.Renderer2D, app: *zigui.app.App, text: []const u8, x: f32, y: f32, size: f32, weight: u16, color: u32) void {
    var font = zigui.coretext.CtFont.create(null, size, weight) catch return;
    defer font.destroy();

    var tl = zigui.text_layout.TextLayout.layout(
        app.allocator,
        app.getGlyphAtlas(),
        app.getMetalDevice(),
        text,
        .{ .font = &font, .font_size = size },
    ) catch return;
    defer tl.deinit();

    r.drawText(&tl, x, y, math.Color.hex(color)) catch {};
}

fn drawTextCentered(r: *zigui.renderer.Renderer2D, app: *zigui.app.App, text: []const u8, x: f32, y: f32, w: f32, h: f32, size: f32, weight: u16, color: u32) void {
    var font = zigui.coretext.CtFont.create(null, size, weight) catch return;
    defer font.destroy();

    var tl = zigui.text_layout.TextLayout.layout(
        app.allocator,
        app.getGlyphAtlas(),
        app.getMetalDevice(),
        text,
        .{ .font = &font, .font_size = size },
    ) catch return;
    defer tl.deinit();

    const tx = x + (w - tl.total_size.width) / 2.0;
    const ty = y + (h - tl.total_size.height) / 2.0;
    r.drawText(&tl, tx, ty, math.Color.hex(color)) catch {};
}

fn drawButton(r: *zigui.renderer.Renderer2D, app: *zigui.app.App, text: []const u8, x: f32, y: f32, w: f32, h: f32, bg: u32, bg_hover: u32, text_color: u32) void {
    _ = bg_hover;
    r.fillRoundedRect(.{ .x = x, .y = y, .width = w, .height = h }, 8, math.Color.hex(bg)) catch {};
    drawTextCentered(r, app, text, x, y, w, h, 14.0, 500, text_color);
}
