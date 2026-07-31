//! zigui gallery - 列表类控件 (Lists)
//!
//! 演示 (均为真正的可交互控件):
//!   - ListBox    行列表 (可选中/可激活, 行内可放任意控件)
//!   - ListView   单列字符串列表 (旧 API addItem)
//!   - ComboBox   下拉选择
//!   - IconView   图标网格 (emoji 图标 + 标签)
//!
//! 运行:  zig build run-gallery-lists

const std = @import("std");
const zigui = @import("zigui");
const math = zigui.math;
const styled_text = zigui.styled_text;
const widget = zigui.widget;

const Container = zigui.container.Container;
const Label = zigui.label.Label;
const ListBox = zigui.list_box.ListBox;
const ListView = zigui.list_view.ListView;
const ComboBox = zigui.combo_box.ComboBox;
const IconView = zigui.icon_view.IconView;

const pal = zigui.pal;

const theme_dark: zigui.theme.Theme = zigui.theme.dark;

var g_root: ?*Container = null;
var g_tree_alloc: ?std.mem.Allocator = null;
var g_prev_mouse_down: bool = false;

var g_status_label: ?*Label = null;
var g_status_buf: [128]u8 = undefined;

pub fn main() !void {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var app = try zigui.app.App.init(allocator, .{
        .title = "zigui Gallery - Lists",
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

    const title = try Label.create(alloc, "Lists", .{ .font_size = 26, .font_weight = 700, .color = math.Color.hex(0xF8FAFCFF) });
    try root.base.addChild(alloc, &title.base);

    const sub = try Label.create(alloc, "Click rows to select. Status shown at the bottom.", .{ .font_size = 13, .color = math.Color.hex(0x64748BFF) });
    try root.base.addChild(alloc, &sub.base);

    // ListBox: 行内可放任意控件
    const lb = try ListBox.create(alloc, .{
        .selection_mode = .single,
    });
    lb.on_row_selected = onListBoxRow;
    lb.base.layout_style.width = .{ .px = 260 };
    lb.base.layout_style.height = .{ .px = 170 };
    const fruits = [_][]const u8{ "Apple", "Banana", "Cherry", "Date", "Elderberry", "Fig" };
    for (fruits) |f| {
        const row = try Label.create(alloc, f, .{ .font_size = 14, .color = math.Color.hex(0xE2E8F0FF) });
        try lb.append(&row.base);
    }
    try addRow(alloc, root, "ListBox", lb);

    // ListView: 纯字符串列表
    const lv = try ListView.create(alloc, .{ .on_select = onListView });
    lv.base.layout_style.width = .{ .px = 260 };
    lv.base.layout_style.height = .{ .px = 170 };
    try lv.addItem("First item");
    try lv.addItem("Second item");
    try lv.addItem("Third item");
    try lv.addItem("Fourth item");
    try lv.addItem("Fifth item");
    try addRow(alloc, root, "ListView", lv);

    // ComboBox: 下拉选择
    const cb = try ComboBox.create(alloc, .{ .on_change = onCombo });
    try cb.addItem("Red");
    try cb.addItem("Green");
    try cb.addItem("Blue");
    try cb.addItem("Yellow");
    try addRow(alloc, root, "ComboBox", cb);

    // IconView: 图标网格
    const iv = try IconView.create(alloc, .{ .columns = 4, .on_select = onIcon });
    iv.base.layout_style.width = .{ .px = 440 };
    iv.base.layout_style.height = .{ .px = 200 };
    try iv.addItem("📁", "Documents");
    try iv.addItem("🖼️", "Pictures");
    try iv.addItem("🎵", "Music");
    try iv.addItem("🎬", "Videos");
    try iv.addItem("⚙️", "Settings");
    try iv.addItem("📥", "Downloads");
    try iv.addItem("🗑️", "Trash");
    try iv.addItem("💾", "Backup");
    try addRow(alloc, root, "IconView", iv);

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
fn onListBoxRow(_: *ListBox, row: usize, _widget: *widget.Widget) void {
    _ = _widget;
    setStatusBuf("ListBox row selected: {d}", .{row});
}
fn onListView(_: *ListView, index: usize) void {
    setStatusBuf("ListView select: {d}", .{index});
}
fn onCombo(_: *ComboBox, index: usize) void {
    setStatusBuf("Combo index: {d}", .{index});
}
fn onIcon(_: *IconView, index: usize) void {
    setStatusBuf("IconView select: {d}", .{index});
}

fn setStatusBuf(comptime fmt: []const u8, args: anytype) void {
    if (g_status_label) |s| {
        s.text = std.fmt.bufPrint(&g_status_buf, fmt, args) catch "?";
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
