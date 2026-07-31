//! zigui gallery - 按钮类控件 (Buttons)
//!
//! 演示 (均为真正的可交互控件):
//!   - Button            普通按钮 (可带图标)
//!   - ToggleButton      切换按钮 (按下保持)
//!   - CheckButton       复选框
//!   - RadioButton       单选按钮 (配合 RadioGroup 互斥)
//!   - Switch            开关
//!   - LinkButton        链接按钮
//!   - MenuButton        菜单按钮
//!   - ColorButton       颜色选择按钮
//!   - FontButton        字体选择按钮
//!   - VolumeButton      音量按钮
//!   - LockButton        锁按钮
//!   - ScaleButton       刻度按钮
//!   - ColorDialogButton / FontDialogButton / FileChooserButton / AppChooserButton
//!
//! 运行:  zig build run-gallery-buttons

const std = @import("std");
const zigui = @import("zigui");
const math = zigui.math;
const styled_text = zigui.styled_text;
const widget = zigui.widget;

const Container = zigui.container.Container;
const Label = zigui.label.Label;
const Button = zigui.button.Button;
const ToggleButton = zigui.toggle_button.ToggleButton;
const CheckButton = zigui.check_button.CheckButton;
const RadioButton = zigui.radio_button.RadioButton;
const RadioGroup = zigui.radio_button.RadioGroup;
const Switch = zigui.switch_widget.Switch;
const LinkButton = zigui.link_button.LinkButton;
const MenuButton = zigui.menu_button.MenuButton;
const ColorButton = zigui.color_button.ColorButton;
const FontButton = zigui.font_button.FontButton;
const VolumeButton = zigui.volume_button.VolumeButton;
const LockButton = zigui.lock_button.LockButton;
const ScaleButton = zigui.scale_button.ScaleButton;
const ColorDialogButton = zigui.color_dialog_button.ColorDialogButton;
const FontDialogButton = zigui.font_dialog_button.FontDialogButton;
const FileChooserButton = zigui.file_chooser_button.FileChooserButton;
const AppChooserButton = zigui.app_chooser_button.AppChooserButton;
const IconName = zigui.icons.IconName;

const pal = zigui.pal;

const theme_dark: zigui.theme.Theme = zigui.theme.dark;

var g_root: ?*Container = null;
var g_tree_alloc: ?std.mem.Allocator = null;
var g_frame: u32 = 0;
var g_prev_mouse_down: bool = false;

// 单选组 (全局, 供回调与三个 RadioButton 共享)
var g_radio_group: RadioGroup = RadioGroup.init(0, .{ .on_change = onRadio });

// 状态显示
var g_status_label: ?*Label = null;
var g_status_buf: [128]u8 = undefined;

pub fn main() !void {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var app = try zigui.app.App.init(allocator, .{
        .title = "zigui Gallery - Buttons",
        .width = 720,
        .height = 760,
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
        .gap = .{ .width = 0, .height = 14 },
    });
    errdefer root.destroy(alloc);

    const title = try Label.create(alloc, "Buttons", .{ .font_size = 26, .font_weight = 700, .color = math.Color.hex(0xF8FAFCFF) });
    try root.base.addChild(alloc, &title.base);

    const sub = try Label.create(alloc, "Click any control - state is shown at the bottom.", .{ .font_size = 13, .color = math.Color.hex(0x64748BFF) });
    try root.base.addChild(alloc, &sub.base);

    // 普通按钮
    try addRow(alloc, root, "Button", try Button.create(alloc, "Primary", .{
        .on_click = onButton,
        .bg_color = math.Color.hex(0x3B82F6FF),
    }));
    try addRow(alloc, root, "Icon button", try Button.create(alloc, "Save", .{
        .icon = .save,
        .on_click = onButton,
    }));
    try addRow(alloc, root, "Toggle", try ToggleButton.create(alloc, "Enable", .{ .on_toggle = onToggle }));
    try addRow(alloc, root, "Check", try CheckButton.create(alloc, "Subscribe to newsletter", .{ .on_change = onCheck }));

    // 单选组
    const radio_row = try rowContainer(alloc);
    try radio_row.base.addChild(alloc, &(try caption(alloc, "Radio")).base);
    try radio_row.base.addChild(alloc, &((try RadioButton.create(alloc, &g_radio_group, 0, "One", .{})).base));
    try radio_row.base.addChild(alloc, &((try RadioButton.create(alloc, &g_radio_group, 1, "Two", .{})).base));
    try radio_row.base.addChild(alloc, &((try RadioButton.create(alloc, &g_radio_group, 2, "Three", .{})).base));
    try root.base.addChild(alloc, &radio_row.base);

    try addRow(alloc, root, "Switch", try Switch.create(alloc, .{ .label = "Wi-Fi", .on_toggle = onSwitch }));
    try addRow(alloc, root, "Link", try LinkButton.create(alloc, "https://ziglang.org", .{}));
    try addRow(alloc, root, "Menu", try MenuButton.create(alloc, "Open menu", .{}));
    try addRow(alloc, root, "Color", try ColorButton.create(alloc, .{}));
    try addRow(alloc, root, "Font", try FontButton.create(alloc, .{}));
    try addRow(alloc, root, "Volume", try VolumeButton.create(alloc, .{}));
    try addRow(alloc, root, "Lock", try LockButton.create(alloc, .{}));
    try addRow(alloc, root, "Scale", try ScaleButton.create(alloc, .{}));
    try addRow(alloc, root, "Color dialog", try ColorDialogButton.create(alloc, .{}));
    try addRow(alloc, root, "Font dialog", try FontDialogButton.create(alloc, .{}));
    try addRow(alloc, root, "File dialog", try FileChooserButton.create(alloc, .{}));
    try addRow(alloc, root, "App dialog", try AppChooserButton.create(alloc, .{}));

    // 状态栏
    const status = try Label.create(alloc, "Status: idle", .{ .font_size = 13, .color = math.Color.hex(0x94A3B8FF) });
    status.base.layout_style.margin.top = 8;
    try root.base.addChild(alloc, &status.base);
    g_status_label = status;

    g_root = root;
    g_tree_alloc = alloc;
}

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

// ── 回调 ──
fn onButton(_: *Button) void {
    setStatus("Button clicked");
}
fn onToggle(_: *ToggleButton, active: bool) void {
    setStatus(if (active) "Toggle ON" else "Toggle OFF");
}
fn onCheck(_: *CheckButton, checked: bool) void {
    setStatus(if (checked) "Checked" else "Unchecked");
}
fn onSwitch(_: *Switch, active: bool) void {
    setStatus(if (active) "Switch ON" else "Switch OFF");
}
fn onRadio(_: *RadioGroup, index: usize) void {
    if (g_status_label) |s| {
        s.text = std.fmt.bufPrint(&g_status_buf, "Radio selected: {d}", .{index}) catch "?";
    }
}

fn setStatus(msg: []const u8) void {
    if (g_status_label) |s| {
        s.text = msg;
    }
}

fn drawFrame(app: *zigui.app.App) void {
    g_frame += 1;
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
}
