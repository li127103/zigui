//! zigui gallery - 数据视图与窗格 (Data Views & Panes)
//!
//! 演示 (均为真正的可交互控件):
//!   - TreeView    树形视图 (addRoot / addChild)
//!   - Table       表格视图 (addColumn / addRow)
//!   - SplitView   可拖拽分隔的双向窗格 (setPanes)
//!   - Paned       传统分隔面板 (new / setStartChild / setEndChild)
//!
//! 运行:  zig build run-gallery-data

const std = @import("std");
const zigui = @import("zigui");
const math = zigui.math;
const styled_text = zigui.styled_text;
const widget = zigui.widget;

const Container = zigui.container.Container;
const Label = zigui.label.Label;
const TreeView = zigui.tree_view.TreeView;
const Table = zigui.table.Table;
const SplitView = zigui.split_view.SplitView;
const Paned = zigui.paned.Paned;

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
        .title = "zigui Gallery - Data Views & Panes",
        .width = 820,
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
        .gap = .{ .width = 0, .height = 16 },
    });
    errdefer root.destroy(alloc);

    const title = try Label.create(alloc, "Data Views & Panes", .{ .font_size = 26, .font_weight = 700, .color = math.Color.hex(0xF8FAFCFF) });
    try root.base.addChild(alloc, &title.base);

    // TreeView
    try addCard(alloc, root, "TreeView", try buildTreeView(alloc));

    // Table
    try addCard(alloc, root, "Table", try buildTable(alloc));

    // SplitView
    try addCard(alloc, root, "SplitView (drag divider)", try buildSplitView(alloc));

    // Paned
    try addCard(alloc, root, "Paned", try buildPaned(alloc));

    g_root = root;
    g_tree_alloc = alloc;
}

fn cardContainer(alloc: std.mem.Allocator, label: []const u8) !*Container {
    const card = try Container.create(alloc, .{
        .bg_color = math.Color.hex(0x1E293BFF), .corner_radius = 14, .direction = .column,
        .padding = .{ .left = 16, .top = 14, .right = 16, .bottom = 16 },
    });
    const lbl = try Label.create(alloc, label, .{ .font_size = 14, .font_weight = 600, .color = math.Color.hex(0x60A5FAFF) });
    try card.base.addChild(alloc, &lbl.base);
    return card;
}

fn addCard(alloc: std.mem.Allocator, parent: *Container, comptime label: []const u8, content: anytype) !void {
    const card = try cardContainer(alloc, label);
    content.base.layout_style.margin.top = 12;
    try card.base.addChild(alloc, &content.base);
    try parent.base.addChild(alloc, &card.base);
}

fn panel(alloc: std.mem.Allocator, text: []const u8, color: u32) !*Container {
    const c = try Container.create(alloc, .{
        .bg_color = math.Color.hex(color), .corner_radius = 8, .direction = .column,
        .padding = .{ .left = 12, .top = 12, .right = 12, .bottom = 12 },
    });
    const l = try Label.create(alloc, text, .{ .font_size = 14, .color = math.Color.hex(0xF8FAFCFF) });
    try c.base.addChild(alloc, &l.base);
    return c;
}

fn buildTreeView(alloc: std.mem.Allocator) !*TreeView {
    const tv = try TreeView.create(alloc, .{ .on_select = onTreeSelect });
    tv.base.layout_style.height = .{ .px = 200 };
    const root_node = try tv.addRoot("Project");
    const src = try tv.addChild(root_node, "src");
    _ = try tv.addChild(src, "main.zig");
    _ = try tv.addChild(src, "root.zig");
    const docs = try tv.addChild(root_node, "docs");
    _ = try tv.addChild(docs, "README.md");
    _ = try tv.addChild(root_node, "build.zig");
    return tv;
}

fn buildTable(alloc: std.mem.Allocator) !*Table {
    const t = try Table.create(alloc, .{});
    t.base.layout_style.height = .{ .px = 200 };
    try t.addColumn("Name", 160);
    try t.addColumn("Role", 140);
    try t.addColumn("Year", 80);
    try t.addRow(&[_][]const u8{ "Alice", "Engineer", "2023" });
    try t.addRow(&[_][]const u8{ "Bob", "Designer", "2024" });
    try t.addRow(&[_][]const u8{ "Carol", "Manager", "2022" });
    try t.addRow(&[_][]const u8{ "Dave", "Engineer", "2025" });
    return t;
}

fn buildSplitView(alloc: std.mem.Allocator) !*SplitView {
    const sv = try SplitView.create(alloc, .{ .orientation = .horizontal, .split_ratio = 0.5 });
    sv.base.layout_style.height = .{ .px = 160 };
    const a = try panel(alloc, "Left pane", 0x334155FF);
    const b = try panel(alloc, "Right pane", 0x475569FF);
    sv.setPanes(&a.base, &b.base);
    return sv;
}

fn buildPaned(alloc: std.mem.Allocator) !*Paned {
    const p = try Paned.new(alloc, .vertical);
    p.base.layout_style.height = .{ .px = 160 };
    const top = try panel(alloc, "Top pane", 0x334155FF);
    const bottom = try panel(alloc, "Bottom pane", 0x475569FF);
    p.setStartChild(&top.base);
    p.setEndChild(&bottom.base);
    return p;
}

fn destroyTree() void {
    if (g_root) |root| {
        root.destroy(g_tree_alloc orelse return);
        g_root = null;
    }
}

// ── 回调 ──
fn onTreeSelect(_: *TreeView, node: *zigui.tree_view.Node) void {
    _ = node;
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
