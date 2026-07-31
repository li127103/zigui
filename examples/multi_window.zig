//! zigui multi_window 示例 - 多窗口 (每个子窗口独立 Vulkan swapchain)
//!
//! 演示:
//!   - App.createSubWindow 创建额外顶层窗口
//!   - 为子窗口设置 on_draw 回调, 在自己的 Canvas 上绘制
//!   - 通过 App 控制子窗口: 显示/隐藏/设置标题/销毁
//!   - 主窗口按钮使用真实 Button 控件 (手动派发事件触发 on_click)
//!
//! 运行:  zig build run-multi-window

const std = @import("std");
const builtin = @import("builtin");
const zigui = @import("zigui");

const is_macos = builtin.os.tag == .macos;
/// 子窗口类型按平台别名: macOS 用 CocoaSubWindow, 其余用 window.Window。
/// 用编译期 if 保证非本平台的类型名不会真正被解析 (避免 macOS 拉入 vulkan.zig)。
const TargetWin = if (is_macos) zigui.app.CocoaSubWindow else zigui.window.Window;
const math = zigui.math;
const widget = zigui.widget;
const pal = zigui.pal;
const Container = zigui.container.Container;
const Button = zigui.button.Button;
const Label = zigui.label.Label;

const theme_dark: zigui.theme.Theme = zigui.theme.dark;

var g_app: *zigui.app.App = undefined;
var g_root: *Container = undefined;
var g_sub_window_id: ?u32 = null;
var g_status_label: *Label = undefined;
var g_window_counter: u32 = 0;
var g_prev_mouse_down: bool = false;

// 全局缓冲 (避免把栈上切片的生命周期交给框架持有)
var g_status_buf: [64]u8 = undefined;
var g_title_buf: [64]u8 = undefined;

fn updateStatus() void {
    if (g_sub_window_id) |wid| {
        const text = std.fmt.bufPrint(&g_status_buf, "Sub-window: OPEN (id={})", .{wid}) catch "Sub-window: OPEN";
        g_status_label.text = text;
    } else {
        g_status_label.text = "Sub-window: CLOSED";
    }
    g_app.invalidate();
}

fn onCreateWindow(_: *Button) void {
    if (g_sub_window_id == null) {
        g_window_counter += 1;
        const title = std.fmt.bufPrint(&g_title_buf, "Sub Window {}", .{g_window_counter}) catch "Sub Window";
        g_sub_window_id = g_app.createSubWindow(title, 420, 320) catch null;
        if (g_sub_window_id) |wid| {
            g_app.setSubWindowTransientFor(wid, g_app.getMainWindowId());
            if (g_app.getSubWindow(wid)) |win| {
                win.on_draw = subWindowDraw;
            }
        }
        updateStatus();
    }
}

fn onDestroyWindow(_: *Button) void {
    if (g_sub_window_id) |wid| {
        g_app.destroySubWindow(wid);
        g_sub_window_id = null;
        updateStatus();
    }
}

fn onShowWindow(_: *Button) void {
    if (g_sub_window_id) |wid| g_app.showSubWindow(wid);
}

fn onHideWindow(_: *Button) void {
    if (g_sub_window_id) |wid| g_app.hideSubWindow(wid);
}

fn onSetTitle(_: *Button) void {
    if (g_sub_window_id) |wid| {
        g_window_counter += 1;
        const title = std.fmt.bufPrint(&g_title_buf, "Updated {}", .{g_window_counter}) catch "Updated";
        g_app.setSubWindowTitle(wid, title);
    }
}

fn subWindowDraw(win: *TargetWin) void {
    const r = win.getRenderer();
    const w: f32 = @floatFromInt(win.getWidth());
    const h: f32 = @floatFromInt(win.getHeight());

    r.fillRect(math.Rect(f32){ .x = 0, .y = 0, .width = w, .height = h }, math.Color.hex(0x1E293BFF)) catch {};

    const box: f32 = 110;
    r.fillRoundedRect(math.Rect(f32){ .x = (w - box) / 2, .y = (h - box) / 2, .width = box, .height = box }, 14, math.Color.hex(0x3B82F6FF)) catch {};

    r.fillCircle(w * 0.2, h * 0.28, 18, math.Color.hex(0x22C55EFF)) catch {};
    r.fillCircle(w * 0.8, h * 0.28, 18, math.Color.hex(0xEF4444FF)) catch {};
    r.fillCircle(w * 0.2, h * 0.72, 18, math.Color.hex(0xF59E0BFF)) catch {};
    r.fillCircle(w * 0.8, h * 0.72, 18, math.Color.hex(0x8B5CF6FF)) catch {};

    zigui.styled_text.drawText(r, win.allocator, "Hello from Sub-Window!", w / 2 - 120, h * 0.86, .{ .font_size = 16, .font_weight = 600, .color = math.Color.hex(0xF1F5FFFF) });
}

fn drawFrame(app: *zigui.app.App) void {
    const fb = app.getFramebufferSize();
    const w: f32 = @floatFromInt(fb.width);
    const h: f32 = @floatFromInt(fb.height);

    dispatchInput(app);

    g_root.base.layout_style.width = .{ .px = w };
    g_root.base.layout_style.height = .{ .px = h };

    var ctx = widget.PaintContext{ .renderer = app.getRenderer(), .theme = &theme_dark, .allocator = app.allocator };
    g_root.base.performLayout(&ctx, .{ .max_width = w, .max_height = h });
    g_root.base.paintTree(&ctx);
}

fn dispatchInput(app: *zigui.app.App) void {
    var ectx = widget.EventContext{ .mouse_x = app.mouse_x, .mouse_y = app.mouse_y };
    const mx: i32 = @intFromFloat(app.mouse_x);
    const my: i32 = @intFromFloat(app.mouse_y);

    var ev_move = pal.Event{ .mouse_move = .{ .window_id = 0, .x = mx, .y = my } };
    _ = g_root.base.dispatchEvent(&ev_move, &ectx);

    if (app.mouse_clicked) {
        var ev = pal.Event{ .mouse_button = .{ .window_id = 0, .button = .left, .state = .pressed, .x = mx, .y = my } };
        _ = g_root.base.dispatchEvent(&ev, &ectx);
    }
    if (!app.mouse_down and g_prev_mouse_down) {
        var ev = pal.Event{ .mouse_button = .{ .window_id = 0, .button = .left, .state = .released, .x = mx, .y = my } };
        _ = g_root.base.dispatchEvent(&ev, &ectx);
    }
    g_prev_mouse_down = app.mouse_down;

    if (app.key_hit) |key| {
        var ev = pal.Event{ .key = .{ .window_id = 0, .state = .pressed, .key = key, .modifiers = app.key_mods } };
        _ = g_root.base.dispatchEvent(&ev, &ectx);
    }
}

pub fn main() !void {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    g_app = try zigui.app.App.init(allocator, .{
        .title = "zigui - Multi-Window",
        .width = 900, .height = 560, .resizable = true, .continuous = true,
    });
    defer g_app.deinit();

    g_root = try Container.create(allocator, .{
        .bg_color = math.Color.hex(0x0F172AFF), .direction = .column,
        .padding = .{ .left = 30, .top = 30, .right = 30, .bottom = 30 }, .gap = .{ .width = 0, .height = 16 },
    });
    defer g_root.destroy(allocator);

    const title = try Label.create(allocator, "ZigUI Multi-Window", .{ .font_size = 24, .font_weight = 700, .color = math.Color.white });
    try g_root.base.addChild(allocator, &title.base);

    const desc = try Label.create(allocator, "Each sub-window has its own Vulkan swapchain. Create one and play with it.", .{ .font_size = 14, .color = math.Color.hex(0x94A3B8FF) });
    try g_root.base.addChild(allocator, &desc.base);

    const row1 = try Container.create(allocator, .{ .direction = .row, .gap = .{ .width = 10, .height = 0 } });
    try g_root.base.addChild(allocator, &row1.base);
    const b_create = try Button.create(allocator, "Create", .{ .on_click = onCreateWindow });
    try row1.base.addChild(allocator, &b_create.base);
    const b_destroy = try Button.create(allocator, "Destroy", .{ .on_click = onDestroyWindow });
    try row1.base.addChild(allocator, &b_destroy.base);

    const row2 = try Container.create(allocator, .{ .direction = .row, .gap = .{ .width = 10, .height = 0 } });
    try g_root.base.addChild(allocator, &row2.base);
    const b_show = try Button.create(allocator, "Show", .{ .on_click = onShowWindow });
    try row2.base.addChild(allocator, &b_show.base);
    const b_hide = try Button.create(allocator, "Hide", .{ .on_click = onHideWindow });
    try row2.base.addChild(allocator, &b_hide.base);

    const row3 = try Container.create(allocator, .{ .direction = .row, .gap = .{ .width = 10, .height = 0 } });
    try g_root.base.addChild(allocator, &row3.base);
    const b_title = try Button.create(allocator, "Set Title", .{ .on_click = onSetTitle });
    try row3.base.addChild(allocator, &b_title.base);

    g_status_label = try Label.create(allocator, "Sub-window: CLOSED", .{ .font_size = 14, .color = math.Color.hex(0x94A3B8FF) });
    try g_root.base.addChild(allocator, &g_status_label.base);

    const hint = try Label.create(allocator, "Tip: click the sub-window's close button to dismiss it.", .{ .font_size = 12, .color = math.Color.hex(0x64748BFF) });
    try g_root.base.addChild(allocator, &hint.base);

    try g_app.run(&drawFrame);
}
