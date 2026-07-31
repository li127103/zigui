//! zigui gallery - 常见补充控件 (More 1)
//!
//! 演示:
//!   - Switch          开/关切换
//!   - Statusbar       状态栏
//!   - Calendar        日历
//!   - LevelBar        级别条 (进度/容量)
//!   - ScaleButton     带数值的缩放按钮
//!   - VolumeButton    音量按钮
//!   - LockButton      锁定按钮
//!   - EditableLabel   可双击编辑标签
//!
//! 运行:  zig build run-gallery-more1

const std = @import("std");
const zigui = @import("zigui");
const math = zigui.math;
const styled_text = zigui.styled_text;
const widget = zigui.widget;

const Container = zigui.container.Container;
const SwitchWidget = zigui.switch_widget.Switch;
const Statusbar = zigui.statusbar.Statusbar;
const Calendar = zigui.calendar.Calendar;
const LevelBar = zigui.level_bar.LevelBar;
const ScaleButton = zigui.scale_button.ScaleButton;
const VolumeButton = zigui.volume_button.VolumeButton;
const LockButton = zigui.lock_button.LockButton;
const EditableLabel = zigui.editable_label.EditableLabel;
const Label = zigui.label.Label;
const Button = zigui.button.Button;

const pal = zigui.pal;

const theme_dark: zigui.theme.Theme = zigui.theme.dark;

var g_root: ?*Container = null;
var g_tree_alloc: ?std.mem.Allocator = null;
var g_prev_mouse_down: bool = false;

pub fn main() !void {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var app = try zigui.app.App.init(allocator, .{
        .title = "zigui Gallery - More (1)",
        .width = 760,
        .height = 880,
    });
    defer app.deinit();

    try buildTree(allocator);
    defer destroyTree();

    try app.run(&drawFrame);
    styled_text.deinitFontCache();
}

fn buildTree(alloc: std.mem.Allocator) !void {
    const root = try Container.create(alloc, .{
        .bg_color = math.Color.hex(0x0F172AFF),
        .direction = .column,
        .padding = .{ .left = 24, .top = 20, .right = 24, .bottom = 20 },
        .gap = .{ .width = 0, .height = 16 },
    });
    errdefer root.destroy(alloc);

    const title = try Label.create(alloc, "More (1)", .{ .font_size = 26, .font_weight = 700, .color = math.Color.hex(0xF8FAFCFF) });
    try root.base.addChild(alloc, &title.base);

    const sub = try Label.create(alloc, "Switch / Statusbar / Calendar / LevelBar / ScaleButton / VolumeButton / LockButton / EditableLabel", .{ .font_size = 13, .color = math.Color.hex(0x64748BFF) });
    try root.base.addChild(alloc, &sub.base);

    // Switch
    const sw = try SwitchWidget.create(alloc, .{
        .active = true,
        .label = "Enable feature",
        .on_change = onSwitch,
    });
    try addRow(alloc, root, "Switch", sw);

    // Statusbar
    const status = try Statusbar.create(alloc, .{ .initial_text = "Ready" });
    status.base.layout_style.width = .{ .px = 480 };
    try addRow(alloc, root, "Statusbar", status);

    // Calendar
    const cal = try Calendar.create(alloc, .{ .year = 2026, .month = 7, .on_change = onCalendar });
    try addRow(alloc, root, "Calendar", cal);

    // LevelBar
    const lb = try LevelBar.create(alloc, .{ .value = 0.68, .min_value = 0, .max_value = 1 });
    lb.base.layout_style.width = .{ .px = 240 };
    try addRow(alloc, root, "LevelBar", lb);

    // ScaleButton
    const sb = try ScaleButton.create(alloc, .{ .value = 0.5, .on_value_changed = onScale });
    try addRow(alloc, root, "ScaleButton", sb);

    // VolumeButton
    const vb = try VolumeButton.create(alloc, .{ .value = 0.7, .on_value_changed = onVolume });
    try addRow(alloc, root, "VolumeButton", vb);

    // LockButton
    const lb2 = try LockButton.create(alloc, .{ .locked = false, .on_toggle = onLock });
    try addRow(alloc, root, "LockButton", lb2);

    // EditableLabel
    const el = try EditableLabel.create(alloc, "Double-click me to edit");
    try addRow(alloc, root, "EditableLabel", el);

    // 一个普通按钮做交互演示
    const btn = try Button.create(alloc, "Ping", .{ .on_click = onPing });
    try addRow(alloc, root, "Button", btn);

    g_root = root;
    g_tree_alloc = alloc;
}

fn onSwitch(_: *SwitchWidget, active: bool) void {
    _ = active;
}
fn onCalendar(_: *Calendar, _: u16, _: u4, _: u8) void {}
fn onScale(_: *ScaleButton, _: f32) void {}
fn onVolume(_: *VolumeButton, _: f32) void {}
fn onLock(_: *LockButton, _: bool) void {}
fn onPing(_: *Button) void {}

fn rowContainer(alloc: std.mem.Allocator) !*Container {
    return Container.create(alloc, .{
        .direction = .row,
        .gap = .{ .width = 12, .height = 0 },
    });
}

fn caption(alloc: std.mem.Allocator, text: []const u8) !*Label {
    const l = try Label.create(alloc, text, .{ .font_size = 13, .color = math.Color.hex(0x94A3B8FF) });
    l.base.layout_style.width = .{ .px = 110 };
    return l;
}

fn addRow(alloc: std.mem.Allocator, parent: *Container, cap: []const u8, ctrl: anytype) !void {
    const row = try rowContainer(alloc);
    try row.base.addChild(alloc, &(try caption(alloc, cap)).base);
    try row.base.addChild(alloc, &ctrl.base);
    try parent.base.addChild(alloc, &row.base);
}

fn destroyTree() void {
    if (g_root) |root| {
        root.destroy(g_tree_alloc orelse return);
        g_root = null;
    }
}

fn drawFrame(app: *zigui.app.App) void {
    const root = g_root orelse return;
    const fb = app.getFramebufferSize();
    const w: f32 = @floatFromInt(fb.width);
    const h: f32 = @floatFromInt(fb.height);

    root.base.layout_style.width = .{ .px = w };
    root.base.layout_style.height = .{ .px = h };

    var ctx = widget.PaintContext{ .renderer = app.getRenderer(), .theme = &theme_dark, .allocator = app.allocator };
    root.base.performLayout(&ctx, .{ .max_width = w, .max_height = h });
    dispatchInput(app);
    root.base.paintTree(&ctx);
}

fn dispatchInput(app: *zigui.app.App) void {
    var ectx = widget.EventContext{ .mouse_x = app.mouse_x, .mouse_y = app.mouse_y };
    const mx: i32 = @intFromFloat(app.mouse_x);
    const my: i32 = @intFromFloat(app.mouse_y);
    var ev_move = pal.Event{ .mouse_move = .{ .window_id = 0, .x = mx, .y = my } };
    _ = g_root.?.base.dispatchEvent(&ev_move, &ectx);
    if (app.mouse_clicked) {
        var ev = pal.Event{ .mouse_button = .{ .window_id = 0, .button = .left, .state = .pressed, .x = mx, .y = my } };
        _ = g_root.?.base.dispatchEvent(&ev, &ectx);
    }
    if (!app.mouse_down and g_prev_mouse_down) {
        var ev = pal.Event{ .mouse_button = .{ .window_id = 0, .button = .left, .state = .released, .x = mx, .y = my } };
        _ = g_root.?.base.dispatchEvent(&ev, &ectx);
    }
    g_prev_mouse_down = app.mouse_down;

    if (app.key_hit) |key| {
        var ev = pal.Event{ .key = .{ .window_id = 0, .state = .pressed, .key = key, .modifiers = app.key_mods } };
        _ = g_root.?.base.dispatchEvent(&ev, &ectx);
    }

    for (app.typedCodepoints()) |cp| {
        var ev = pal.Event{ .text_input = .{ .window_id = 0, .codepoint = cp } };
        _ = g_root.?.base.dispatchEvent(&ev, &ectx);
    }
}
