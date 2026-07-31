//! zigui gallery - 输入类控件 (Inputs)
//!
//! 演示 (均为真正的可交互控件; 点击控件后可直接键入):
//!   - Entry          单行文本输入
//!   - SearchEntry    带搜索图标的输入
//!   - PasswordEntry  密码输入 (可切换可见性)
//!   - SpinButton     数值微调 (带上下按钮)
//!   - TextView       多行文本编辑
//!   - ComboBox       下拉选择
//!   - Scale          滑块数值选择
//!
//! 运行:  zig build run-gallery-inputs

const std = @import("std");
const zigui = @import("zigui");
const math = zigui.math;
const styled_text = zigui.styled_text;
const widget = zigui.widget;

const Container = zigui.container.Container;
const Label = zigui.label.Label;
const Entry = zigui.entry.Entry;
const SearchEntry = zigui.search_entry.SearchEntry;
const PasswordEntry = zigui.password_entry.PasswordEntry;
const SpinButton = zigui.spin_button.SpinButton;
const TextView = zigui.text_view.TextView;
const ComboBox = zigui.combo_box.ComboBox;
const Scale = zigui.scale.Scale;

const pal = zigui.pal;

const theme_dark: zigui.theme.Theme = zigui.theme.dark;

var g_root: ?*Container = null;
var g_tree_alloc: ?std.mem.Allocator = null;
var g_frame: u32 = 0;
var g_prev_mouse_down: bool = false;

var g_status_label: ?*Label = null;
var g_status_buf: [128]u8 = undefined;

pub fn main() !void {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var app = try zigui.app.App.init(allocator, .{
        .title = "zigui Gallery - Inputs",
        .width = 720,
        .height = 820,
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

    const title = try Label.create(alloc, "Inputs", .{ .font_size = 26, .font_weight = 700, .color = math.Color.hex(0xF8FAFCFF) });
    try root.base.addChild(alloc, &title.base);

    const sub = try Label.create(alloc, "Click a field, then type. Status shown at the bottom.", .{ .font_size = 13, .color = math.Color.hex(0x64748BFF) });
    try root.base.addChild(alloc, &sub.base);

    // 单行输入
    try addRow(alloc, root, "Entry", try Entry.create(alloc, .{
        .placeholder = "Type something...",
        .on_submit = onEntrySubmit,
    }));

    // 搜索输入
    try addRow(alloc, root, "Search", try SearchEntry.create(alloc, .{
        .placeholder = "Search...",
        .on_search = onSearch,
    }));

    // 密码输入
    try addRow(alloc, root, "Password", try PasswordEntry.create(alloc, .{
        .placeholder = "Password",
        .on_text_changed = onPassword,
    }));

    // 数值微调
    try addRow(alloc, root, "SpinButton", try SpinButton.create(alloc, .{
        .value = 4,
        .min = 0,
        .max = 100,
        .step = 1,
        .on_change = onSpin,
    }));

    // 多行文本
    const tv = try TextView.create(alloc, .{
        .placeholder = "Multi-line text...",
        .on_change = onText,
    });
    tv.base.layout_style.height = .{ .px = 96 };
    try addRow(alloc, root, "TextView", tv);

    // 下拉选择
    const cb = try ComboBox.create(alloc, .{ .on_change = onCombo });
    try cb.addItem("Apple");
    try cb.addItem("Banana");
    try cb.addItem("Cherry");
    try cb.addItem("Date");
    try addRow(alloc, root, "ComboBox", cb);

    // 滑块
    try addRow(alloc, root, "Scale", try Scale.create(alloc, .{
        .value = 0.4,
        .min = 0,
        .max = 1,
        .on_change = onScale,
    }));

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
fn onEntrySubmit(_: *Entry, text: []const u8) void {
    setStatusBuf("Entry submit: {s}", .{text});
}
fn onSearch(_: *SearchEntry, text: []const u8) void {
    setStatusBuf("Search: {s}", .{text});
}
fn onPassword(_: *PasswordEntry, text: []const u8) void {
    setStatusBuf("Password len: {d}", .{text.len});
}
fn onText(_: *TextView, text: []const u8) void {
    setStatusBuf("TextView len: {d}", .{text.len});
}
fn onSpin(_: *SpinButton, value: f64) void {
    setStatusBuf("Spin: {d:.1}", .{value});
}
fn onCombo(_: *ComboBox, index: usize) void {
    setStatusBuf("Combo index: {d}", .{index});
}
fn onScale(_: *Scale, value: f32) void {
    setStatusBuf("Scale: {d:.2}", .{value});
}

fn setStatusBuf(comptime fmt: []const u8, args: anytype) void {
    if (g_status_label) |s| {
        s.text = std.fmt.bufPrint(&g_status_buf, fmt, args) catch "?";
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

    // 键盘: 按下事件
    if (app.key_hit) |key| {
        var ev = pal.Event{ .key = .{ .window_id = 0, .state = .pressed, .key = key, .modifiers = app.key_mods } };
        _ = g_root.?.base.dispatchEvent(&ev, &ectx);
    }

    // 文本输入: 把本帧键入的码点作为 text_input 事件下发, 使输入框真正可输入
    for (app.typedCodepoints()) |cp| {
        var ev = pal.Event{ .text_input = .{ .window_id = 0, .codepoint = cp } };
        _ = g_root.?.base.dispatchEvent(&ev, &ectx);
    }
}
