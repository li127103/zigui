//! zigui gallery - 显示与杂项控件 (Display & Misc)
//!
//! 演示 (均为真正的可交互控件):
//!   - ProgressBar   进度条 (每帧动画)
//!   - Spinner       加载指示器 (每帧 tick 动画)
//!   - LevelBar      分级指示条
//!   - Separator     分隔线
//!   - Statusbar     状态栏
//!   - DropDown      下拉选择 (addItem)
//!   - Calendar      日历选择
//!
//! 运行:  zig build run-gallery-advanced

const std = @import("std");
const zigui = @import("zigui");
const math = zigui.math;
const styled_text = zigui.styled_text;
const widget = zigui.widget;

const Container = zigui.container.Container;
const Label = zigui.label.Label;
const ProgressBar = zigui.progress_bar.ProgressBar;
const Spinner = zigui.spinner.Spinner;
const LevelBar = zigui.level_bar.LevelBar;
const Separator = zigui.separator.Separator;
const Statusbar = zigui.statusbar.Statusbar;
const DropDown = zigui.drop_down.DropDown;
const Calendar = zigui.calendar.Calendar;

const pal = zigui.pal;

const theme_dark: zigui.theme.Theme = zigui.theme.dark;

var g_root: ?*Container = null;
var g_tree_alloc: ?std.mem.Allocator = null;
var g_frame: u32 = 0;
var g_prev_mouse_down: bool = false;

// 需每帧更新的控件
var g_progress: ?*ProgressBar = null;
var g_spinner: ?*Spinner = null;
var g_status: ?*Statusbar = null;

// 状态显示
var g_status_label: ?*Label = null;
var g_status_buf: [128]u8 = undefined;

pub fn main() !void {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var app = try zigui.app.App.init(allocator, .{
        .title = "zigui Gallery - Display & Misc",
        .width = 640,
        .height = 720,
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

    const title = try Label.create(alloc, "Display & Misc", .{ .font_size = 26, .font_weight = 700, .color = math.Color.hex(0xF8FAFCFF) });
    try root.base.addChild(alloc, &title.base);

    const sub = try Label.create(alloc, "Animated widgets update every frame; pickers are interactive.", .{ .font_size = 13, .color = math.Color.hex(0x64748BFF) });
    try root.base.addChild(alloc, &sub.base);

    // 进度条 (动画)
    const pb = try ProgressBar.create(alloc, .{ .show_text = true, .text = "Loading…" });
    g_progress = pb;
    try addRow(alloc, root, "ProgressBar", &pb.base);

    // 加载指示器 (动画)
    const sp = try Spinner.create(alloc, .{ .active = true, .size = 28 });
    g_spinner = sp;
    try addRow(alloc, root, "Spinner", &sp.base);

    // 分级条
    const lb = try LevelBar.create(alloc, .{ .value = 0.7, .mode = .continuous });
    try addRow(alloc, root, "LevelBar", &lb.base);

    // 分隔线
    try addRow(alloc, root, "Separator", &(try Separator.create(alloc, .{ .orientation = .horizontal })).base);

    // 下拉选择
    const dd = try DropDown.create(alloc, .{ .on_change = onDropDown });
    try dd.addItem("Apple", 1);
    try dd.addItem("Banana", 2);
    try dd.addItem("Cherry", 3);
    dd.setSelected(0);
    try addRow(alloc, root, "DropDown", &dd.base);

    // 日历
    const cal = try Calendar.create(alloc, .{ .year = 2026, .month = 7, .on_change = onCalendar });
    try addRow(alloc, root, "Calendar", &cal.base);

    // 状态栏
    const sb = try Statusbar.create(alloc, .{ .initial_text = "Ready." });
    g_status = sb;
    sb.base.layout_style.margin.top = 8;
    try root.base.addChild(alloc, &sb.base);

    // 状态文本 (调试用)
    const status = try Label.create(alloc, "Status: idle", .{ .font_size = 13, .color = math.Color.hex(0x94A3B8FF) });
    status.base.layout_style.margin.top = 8;
    try root.base.addChild(alloc, &status.base);
    g_status_label = status;

    g_root = root;
    g_tree_alloc = alloc;
}

fn rowContainer(alloc: std.mem.Allocator) !*Container {
    const row = try Container.create(alloc, .{
        .direction = .row,
        .gap = .{ .width = 12, .height = 0 },
    });
    row.base.layout_style.align_items = .center;
    return row;
}

fn caption(alloc: std.mem.Allocator, text: []const u8) !*Label {
    const l = try Label.create(alloc, text, .{ .font_size = 13, .color = math.Color.hex(0x94A3B8FF) });
    l.base.layout_style.width = .{ .px = 110 };
    return l;
}

fn addRow(alloc: std.mem.Allocator, parent: *Container, cap: []const u8, ctrl: anytype) !void {
    const row = try rowContainer(alloc);
    try row.base.addChild(alloc, &(try caption(alloc, cap)).base);
    try row.base.addChild(alloc, ctrl);
    try parent.base.addChild(alloc, &row.base);
}

fn destroyTree() void {
    if (g_root) |root| {
        root.destroy(g_tree_alloc orelse return);
        g_root = null;
    }
}

// ── 回调 ──
fn onDropDown(_: *DropDown, index: usize) void {
    setStatus("DropDown selected index:");
    _ = index;
    if (g_status) |s| s.setText("DropDown changed");
}

fn onCalendar(_: *Calendar, year: u16, month: u4, day: u8) void {
    _ = year;
    _ = month;
    _ = day;
    if (g_status) |s| s.setText("Calendar date changed");
    setStatus("Calendar changed");
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

    // 每帧更新动画控件
    if (g_progress) |pb| {
        const p: f32 = @sin(@as(f32, @floatFromInt(g_frame)) * 0.02) * 0.5 + 0.5;
        pb.setFraction(p);
    }
    if (g_spinner) |sp| {
        sp.tick(16);
    }

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
