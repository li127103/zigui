//! 多窗口演示 Demo
//! 演示 ZigUI 的多窗口能力，每个窗口独立使用 Vulkan swapchain

const std = @import("std");
const zigui = @import("zigui");
const math = zigui.math;
const widget = zigui.widget;
const pal = zigui.pal;
const Container = zigui.container.Container;
const Button = zigui.button.Button;
const Label = zigui.label.Label;

var gpa: std.heap.DebugAllocator(.{}) = .init;

var g_app: *zigui.app.App = undefined;
var g_root: *Container = undefined;
var g_sub_window_id: ?u32 = null;
var g_status_label: *Label = undefined;
var g_window_counter: u32 = 0;

fn updateStatus() void {
    if (g_sub_window_id) |wid| {
        var buf: [64]u8 = undefined;
        const text = std.fmt.bufPrint(&buf, "Sub-window: OPEN (id={})", .{wid}) catch "Sub-window: OPEN";
        g_status_label.setText(text);
    } else {
        g_status_label.setText("Sub-window: CLOSED");
    }
    g_app.invalidate();
}

fn onCreateWindow(_: *Button) void {
    if (g_sub_window_id == null) {
        g_window_counter += 1;
        var title_buf: [64]u8 = undefined;
        const title = std.fmt.bufPrint(&title_buf, "Sub Window {}", .{g_window_counter}) catch "Sub Window";
        g_sub_window_id = g_app.createSubWindow(title, 400, 300) catch null;
        if (g_sub_window_id) |wid| {
            g_app.setSubWindowTransientFor(wid, g_app.getMainWindowId());
            // 设置子窗口绘制回调
            if (g_app.getSubWindow(wid)) |win| {
                win.on_draw = subWindowDraw;
                win.user_data = null;
            }
        }
        updateStatus();
    }
}

fn subWindowDraw(win: *zigui.window.Window) void {
    const renderer = win.getRenderer();
    const w: f32 = @floatFromInt(win.getWidth());
    const h: f32 = @floatFromInt(win.getHeight());

    // 绘制渐变背景 (用纯色代替)
    renderer.fillRect(math.Rect(f32){ .x = 0, .y = 0, .width = w, .height = h }, math.Color.hex(0x1E293BFF)) catch {};

    // 绘制一个居中的彩色方块
    const box_size: f32 = 100;
    const box_x = (w - box_size) / 2;
    const box_y = (h - box_size) / 2;
    renderer.fillRoundedRect(
        math.Rect(f32){ .x = box_x, .y = box_y, .width = box_size, .height = box_size },
        12,
        math.Color.hex(0x3B82F6FF),
    ) catch {};

    // 绘制一些装饰圆
    renderer.fillCircle(w * 0.2, h * 0.3, 20, math.Color.hex(0x22C55EFF)) catch {};
    renderer.fillCircle(w * 0.8, h * 0.3, 20, math.Color.hex(0xEF4444FF)) catch {};
    renderer.fillCircle(w * 0.2, h * 0.7, 20, math.Color.hex(0xF59E0BFF)) catch {};
    renderer.fillCircle(w * 0.8, h * 0.7, 20, math.Color.hex(0x8B5CF6FF)) catch {};

    // 绘制标题文字 (需要 styled_text)
    const title = "Hello from Sub-Window!";
    zigui.styled_text.drawText(
        renderer,
        win.allocator,
        title,
        w / 2 - 110,
        h * 0.85,
        .{
            .font_size = 16,
            .color = math.Color.hex(0xF1F5FFFF),
            .font_weight = 600,
        },
    );
}

fn onDestroyWindow(_: *Button) void {
    if (g_sub_window_id) |wid| {
        g_app.destroySubWindow(wid);
        g_sub_window_id = null;
        updateStatus();
    }
}

fn onShowWindow(_: *Button) void {
    if (g_sub_window_id) |wid| {
        g_app.showSubWindow(wid);
    }
}

fn onHideWindow(_: *Button) void {
    if (g_sub_window_id) |wid| {
        g_app.hideSubWindow(wid);
    }
}

fn onMaximizeWindow(_: *Button) void {
    if (g_sub_window_id) |wid| {
        g_app.maximizeSubWindow(wid);
    }
}

fn onUnmaximizeWindow(_: *Button) void {
    if (g_sub_window_id) |wid| {
        g_app.unmaximizeSubWindow(wid);
    }
}

fn onIconifyWindow(_: *Button) void {
    if (g_sub_window_id) |wid| {
        g_app.iconifySubWindow(wid);
    }
}

fn onResizeWindow(_: *Button) void {
    if (g_sub_window_id) |wid| {
        g_app.resizeSubWindow(wid, 500, 400);
    }
}

fn onSetTitle(_: *Button) void {
    if (g_sub_window_id) |wid| {
        g_window_counter += 1;
        var title_buf: [64]u8 = undefined;
        const title = std.fmt.bufPrint(&title_buf, "Updated Title {}", .{g_window_counter}) catch "Updated Title";
        g_app.setSubWindowTitle(wid, title);
    }
}

fn drawFrame(app: *zigui.app.App) void {
    const w: f32 = @floatFromInt(app.fb_width);
    const h: f32 = @floatFromInt(app.fb_height);

    dispatchInput(app);

    g_root.base.layout_style.width = .{ .px = w };
    g_root.base.layout_style.height = .{ .px = h };

    var ctx = widget.PaintContext{
        .renderer = app.getRenderer(),
        .theme = &g_theme,
        .allocator = app.allocator,
    };
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
    const md = app.mouse_down;
    if (!md and g_prev_mouse_down) {
        var ev = pal.Event{ .mouse_button = .{ .window_id = 0, .button = .left, .state = .released, .x = mx, .y = my } };
        _ = g_root.base.dispatchEvent(&ev, &ectx);
    }
    g_prev_mouse_down = md;

    if (app.scroll_delta != 0) {
        var ev = pal.Event{ .scroll = .{ .window_id = 0, .axis = .vertical, .delta = app.scroll_delta } };
        _ = g_root.base.dispatchEvent(&ev, &ectx);
    }

    if (app.key_hit) |key| {
        if (key == .tab) {
            if (app.key_mods.shift) {
                _ = g_root.base.focusPrev();
            } else {
                _ = g_root.base.focusNext();
            }
            return;
        }
        var ev = pal.Event{ .key = .{ .window_id = 0, .state = .pressed, .key = key, .modifiers = app.key_mods } };
        _ = g_root.base.dispatchEvent(&ev, &ectx);
    }

    for (app.typedCodepoints()) |cp| {
        var ev = pal.Event{ .text_input = .{ .window_id = 0, .codepoint = cp } };
        _ = g_root.base.dispatchEvent(&ev, &ectx);
    }
}

var g_prev_mouse_down: bool = false;

const g_theme = zigui.theme.dark;

pub fn main() !void {
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    g_app = try zigui.app.App.init(allocator, .{
        .title = "Multi-Window Demo",
        .width = 900,
        .height = 700,
        .resizable = true,
        .continuous = true,
    });
    defer g_app.deinit();

    g_root = try Container.create(allocator, .{
        .bg_color = math.Color.hex(0x0F172AFF),
        .direction = .column,
        .padding = .{ .top = 30, .right = 30, .bottom = 30, .left = 30 },
        .gap = .{ .width = 0, .height = 16 },
    });
    defer g_root.destroy(allocator);

    const title_label = try Label.create(allocator, "ZigUI Multi-Window Demo", .{
        .font_size = 24,
        .font_weight = 700,
        .color = math.Color.white,
    });
    try g_root.base.addChild(allocator, &title_label.base);

    const desc_label = try Label.create(allocator, "Test multi-window capabilities. Each sub-window has its own Vulkan swapchain.", .{
        .font_size = 14,
        .color = math.Color.hex(0x94A3B8FF),
    });
    try g_root.base.addChild(allocator, &desc_label.base);

    // 第一行：创建/销毁
    const row1 = try Container.create(allocator, .{
        .direction = .row,
        .gap = .{ .width = 10, .height = 0 },
    });
    try g_root.base.addChild(allocator, &row1.base);

    const create_btn = try Button.create(allocator, "Create", .{
        .on_click = onCreateWindow,
    });
    try row1.base.addChild(allocator, &create_btn.base);

    const destroy_btn = try Button.create(allocator, "Destroy", .{
        .on_click = onDestroyWindow,
    });
    try row1.base.addChild(allocator, &destroy_btn.base);

    // 第二行：显示/隐藏
    const row2 = try Container.create(allocator, .{
        .direction = .row,
        .gap = .{ .width = 10, .height = 0 },
    });
    try g_root.base.addChild(allocator, &row2.base);

    const show_btn = try Button.create(allocator, "Show", .{
        .on_click = onShowWindow,
    });
    try row2.base.addChild(allocator, &show_btn.base);

    const hide_btn = try Button.create(allocator, "Hide", .{
        .on_click = onHideWindow,
    });
    try row2.base.addChild(allocator, &hide_btn.base);

    // 第三行：最大化/还原/最小化
    const row3 = try Container.create(allocator, .{
        .direction = .row,
        .gap = .{ .width = 10, .height = 0 },
    });
    try g_root.base.addChild(allocator, &row3.base);

    const max_btn = try Button.create(allocator, "Maximize", .{
        .on_click = onMaximizeWindow,
    });
    try row3.base.addChild(allocator, &max_btn.base);

    const unmax_btn = try Button.create(allocator, "Unmaximize", .{
        .on_click = onUnmaximizeWindow,
    });
    try row3.base.addChild(allocator, &unmax_btn.base);

    const iconify_btn = try Button.create(allocator, "Minimize", .{
        .on_click = onIconifyWindow,
    });
    try row3.base.addChild(allocator, &iconify_btn.base);

    // 第四行：调整大小/设置标题
    const row4 = try Container.create(allocator, .{
        .direction = .row,
        .gap = .{ .width = 10, .height = 0 },
    });
    try g_root.base.addChild(allocator, &row4.base);

    const resize_btn = try Button.create(allocator, "Resize 500x400", .{
        .on_click = onResizeWindow,
    });
    try row4.base.addChild(allocator, &resize_btn.base);

    const title_btn = try Button.create(allocator, "Set Title", .{
        .on_click = onSetTitle,
    });
    try row4.base.addChild(allocator, &title_btn.base);

    g_status_label = try Label.create(allocator, "Sub-window: CLOSED", .{
        .font_size = 14,
        .color = math.Color.hex(0x94A3B8FF),
    });
    try g_root.base.addChild(allocator, &g_status_label.base);

    const hint_label = try Label.create(allocator, "Tip: Click the X button on the sub-window to close it (close_requested event)", .{
        .font_size = 12,
        .color = math.Color.hex(0x64748BFF),
    });
    try g_root.base.addChild(allocator, &hint_label.base);

    try g_app.run(&drawFrame);
}
