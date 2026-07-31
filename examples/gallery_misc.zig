//! zigui gallery - 杂项控件 (Misc)
//!
//! 演示尚未被其他 gallery 覆盖的控件:
//!   - ActionBar      操作栏 (水平排列按钮, space-between 布局)
//!   - ScrolledWindow 滚动容器 (内容超出可视区时出现滚动条)
//!   - WindowControls 窗口控制按钮 (最小化 / 最大化 / 关闭)
//!   - Inscription    轻量单行文本 (类似 Label, 支持溢出/换行策略)
//!   - Slider         滑动条
//!
//! 运行:  zig build run-gallery-misc

const std = @import("std");
const zigui = @import("zigui");
const math = zigui.math;
const styled_text = zigui.styled_text;
const widget = zigui.widget;

const Container = zigui.container.Container;
const Label = zigui.label.Label;
const Button = zigui.button.Button;
const ActionBar = zigui.action_bar.ActionBar;
const ScrolledWindow = zigui.scrolled_window.ScrolledWindow;
const WindowControls = zigui.window_controls.WindowControls;
const Inscription = zigui.inscription.Inscription;
const Slider = zigui.slider.Slider;

const pal = zigui.pal;

const theme_dark: zigui.theme.Theme = zigui.theme.dark;

var g_root: ?*Container = null;
var g_tree_alloc: ?std.mem.Allocator = null;
var g_frame: u32 = 0;
var g_prev_mouse_down: bool = false;

pub fn main() !void {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var app = try zigui.app.App.init(allocator, .{
        .title = "zigui Gallery - Misc",
        .width = 720,
        .height = 900,
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

    const title = try Label.create(alloc, "Misc", .{ .font_size = 26, .font_weight = 700, .color = math.Color.hex(0xF8FAFCFF) });
    try root.base.addChild(alloc, &title.base);

    const sub = try Label.create(alloc, "Assorted widgets not covered by other galleries.", .{ .font_size = 13, .color = math.Color.hex(0x64748BFF) });
    try root.base.addChild(alloc, &sub.base);

    // ── ActionBar ──
    try section(alloc, root, "ActionBar");
    const ab = try ActionBar.create(alloc, .{});
    try ab.base.addChild(alloc, &(try Button.create(alloc, "Save", .{})).base);
    try ab.base.addChild(alloc, &(try Button.create(alloc, "Cancel", .{ .bg_color = math.Color.hex(0x475569FF) })).base);
    try ab.base.addChild(alloc, &(try Button.create(alloc, "Help", .{ .bg_color = math.Color.hex(0x475569FF) })).base);
    try root.base.addChild(alloc, &ab.base);

    // ── ScrolledWindow ──
    try section(alloc, root, "ScrolledWindow");
    const sw = try ScrolledWindow.create(alloc, .{ .width = 420, .height = 160, .bg_color = math.Color.hex(0x1E293BFF), .has_frame = true });
    const scroll_content = try Container.create(alloc, .{
        .direction = .column,
        .padding = .{ .left = 12, .top = 8, .right = 12, .bottom = 8 },
        .gap = .{ .width = 0, .height = 6 },
    });
    var i: u32 = 0;
    while (i < 14) : (i += 1) {
        const t = try std.fmt.allocPrint(alloc, "Scrollable item #{d}", .{i + 1});
        const li = try Label.create(alloc, t, .{ .font_size = 14, .color = math.Color.hex(0xE2E8F0FF) });
        try scroll_content.base.addChild(alloc, &li.base);
    }
    sw.setChild(alloc, &scroll_content.base);
    try root.base.addChild(alloc, &sw.base);

    // ── WindowControls ──
    try addRow(alloc, root, "WindowControls", try WindowControls.create(alloc, .{
        .show_minimize = true,
        .show_maximize = true,
        .show_close = true,
    }));

    // ── Inscription ──
    try addRow(alloc, root, "Inscription", try Inscription.create(alloc, .{
        .text = "A lightweight single-line text widget",
        .min_chars = 10,
        .nat_chars = 30,
    }));

    // ── Slider ──
    try addRow(alloc, root, "Slider", try Slider.create(alloc, .{ .value = 0.4, .min = 0, .max = 1, .step = 0.01 }));

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

fn section(alloc: std.mem.Allocator, parent: *Container, name: []const u8) !void {
    const s = try Label.create(alloc, name, .{ .font_size = 17, .font_weight = 600, .color = math.Color.hex(0x38BDF8FF) });
    try parent.base.addChild(alloc, &s.base);
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
