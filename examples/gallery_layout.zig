//! zigui gallery - 布局类控件 (Layouts)
//!
//! 演示:
//!   - Container   通用容器 (行/列/内边距/间距/背景)
//!   - Grid        二维网格布局 (按行列放置子控件)
//!   - FlowBox     流式布局 (自动换行)
//!   - Box         GTK 风格盒 (等间距堆叠)
//!   - CenterBox   三段式居中布局
//!
//! 运行:  zig build run-gallery-layout

const std = @import("std");
const zigui = @import("zigui");
const math = zigui.math;
const styled_text = zigui.styled_text;
const widget = zigui.widget;

const Container = zigui.container.Container;
const Grid = zigui.grid.Grid;
const FlowBox = zigui.flow_box.FlowBox;
const Box = zigui.box.Box;
const CenterBox = zigui.center_box.CenterBox;
const Label = zigui.label.Label;
const Button = zigui.button.Button;

const pal = zigui.pal;

const theme_dark: zigui.theme.Theme = zigui.theme.dark;

var g_root: ?*Container = null;
var g_tree_alloc: ?std.mem.Allocator = null;
var g_prev_mouse_down: bool = false;

var g_status_label: ?*Label = null;

pub fn main() !void {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var app = try zigui.app.App.init(allocator, .{
        .title = "zigui Gallery - Layouts",
        .width = 760,
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
        .gap = .{ .width = 0, .height = 16 },
    });
    errdefer root.destroy(alloc);

    const title = try Label.create(alloc, "Layouts", .{ .font_size = 26, .font_weight = 700, .color = math.Color.hex(0xF8FAFCFF) });
    try root.base.addChild(alloc, &title.base);

    const sub = try Label.create(alloc, "Containers arrange their children. Status shown at the bottom.", .{ .font_size = 13, .color = math.Color.hex(0x64748BFF) });
    try root.base.addChild(alloc, &sub.base);

    // Container: 嵌套行容器 + 背景
    const inner = try Container.create(alloc, .{
        .bg_color = math.Color.hex(0x1E293BFF),
        .direction = .row,
        .padding = .{ .left = 12, .top = 10, .right = 12, .bottom = 10 },
        .gap = .{ .width = 12, .height = 0 },
        .corner_radius = 10,
    });
    try inner.base.addChild(alloc, &(try Label.create(alloc, "Container:", .{ .font_size = 13, .color = math.Color.hex(0x94A3B8FF) })).base);
    try inner.base.addChild(alloc, &(try Button.create(alloc, "One", .{})).base);
    try inner.base.addChild(alloc, &(try Button.create(alloc, "Two", .{})).base);
    try inner.base.addChild(alloc, &(try Button.create(alloc, "Three", .{})).base);
    try addRow(alloc, root, "Container", inner);

    // Grid: 2 列 x 3 行
    const grid = try Grid.create(alloc, .{ .rows = 3, .cols = 2, .row_gap = 10, .col_gap = 14, .bg_color = math.Color.hex(0x1E293BFF), .corner_radius = 10 });
    grid.base.layout_style.width = .{ .px = 420 };
    const grid_labels = [_][]const u8{ "R0C0", "R0C1", "R1C0", "R1C1", "R2C0", "R2C1" };
    var gi: usize = 0;
    while (gi < 6) : (gi += 1) {
        const r = gi / 2;
        const c = gi % 2;
        const cell = try Label.create(alloc, grid_labels[gi], .{ .font_size = 14, .color = math.Color.hex(0xE2E8F0FF) });
        try grid.addChild(&cell.base, r, c);
    }
    try addRow(alloc, root, "Grid", grid);

    // FlowBox: 流式换行
    const flow = try FlowBox.create(alloc, .{ .direction = .row, .row_gap = 10, .col_gap = 10, .bg_color = math.Color.hex(0x1E293BFF), .corner_radius = 10, .width = .{ .px = 420 }, .height = .{ .px = 110 } });
    const flow_names = [_][]const u8{ "Alpha", "Beta", "Gamma", "Delta", "Epsilon", "Zeta", "Eta" };
    for (flow_names) |n| {
        try flow.addChild(&(try Button.create(alloc, n, .{})).base);
    }
    try addRow(alloc, root, "FlowBox", flow);

    // Box: 垂直等间距
    const box = try Box.create(alloc, .{ .orientation = .vertical, .spacing = 10 });
    box.base.layout_style.width = .{ .px = 420 };
    const box_items = [_][]const u8{ "First", "Second", "Third", "Fourth" };
    for (box_items) |b| {
        try box.append(&(try Label.create(alloc, b, .{ .font_size = 14, .color = math.Color.hex(0xE2E8F0FF) })).base);
    }
    try addRow(alloc, root, "Box", box);

    // CenterBox: 居中
    const cb = try CenterBox.create(alloc, .{ .bg_color = math.Color.hex(0x1E293BFF), .corner_radius = 10, .width = .{ .px = 420 }, .height = .{ .px = 90 } });
    try cb.setCenter(&(try Label.create(alloc, "Centered", .{ .font_size = 18, .font_weight = 700, .color = math.Color.hex(0xF8FAFCFF) })).base);
    try addRow(alloc, root, "CenterBox", cb);

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
