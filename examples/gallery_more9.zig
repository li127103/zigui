//! zigui gallery - 数据视图 / 字体 / 弹出菜单栏 (More 9)
//!
//! 演示:
//!   - ColumnView        多列列表 (表格)
//!   - GridView          图标网格视图
//!   - ToolPalette       工具面板
//!   - FontSelection     字体选择面板
//!   - PopoverMenuBar    弹出式菜单栏
//!
//! 运行:  zig build run-gallery-more9

const std = @import("std");
const zigui = @import("zigui");
const math = zigui.math;
const styled_text = zigui.styled_text;
const widget = zigui.widget;

const Container = zigui.container.Container;
const Label = zigui.label.Label;
const Button = zigui.button.Button;
const ColumnView = zigui.column_view.ColumnView;
const GridView = zigui.grid_view.GridView;
const ToolPalette = zigui.tool_palette.ToolPalette;
const FontSelection = zigui.font_selection.FontSelection;
const FontDesc = zigui.font_selection.FontDesc;
const PopoverMenuBar = zigui.popover_menu_bar.PopoverMenuBar;
const Menu = zigui.menu.Menu;
const MenuItem = zigui.menu.MenuItem;

const pal = zigui.pal;

const theme_dark: zigui.theme.Theme = zigui.theme.dark;

var g_root: ?*Container = null;
var g_tree_alloc: ?std.mem.Allocator = null;
var g_prev_mouse_down: bool = false;

// 控件引用
var g_font_label: ?*Label = null;
var g_font_buf: [128]u8 = undefined;
var g_cv_label: ?*Label = null;
var g_cv_buf: [128]u8 = undefined;
var g_pmb_label: ?*Label = null;
var g_pmb_buf: [128]u8 = undefined;

pub fn main() !void {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var app = try zigui.app.App.init(allocator, .{
        .title = "zigui Gallery - More (9)",
        .width = 760,
        .height = 2600,
    });
    defer app.deinit();

    try buildTree(allocator);
    defer destroyTree();

    try app.run(&drawFrame);
    styled_text.deinitFontCache();
}

fn section(alloc: std.mem.Allocator, root: *Container, name: []const u8) !void {
    const cap = try Label.create(alloc, name, .{ .font_size = 15, .font_weight = 600, .color = math.Color.hex(0x94A3B8FF) });
    try root.base.addChild(alloc, &cap.base);
}

fn buildTree(alloc: std.mem.Allocator) !void {
    const root = try Container.create(alloc, .{
        .bg_color = math.Color.hex(0x0F172AFF),
        .direction = .column,
        .padding = .{ .left = 24, .top = 20, .right = 24, .bottom = 20 },
        .gap = .{ .width = 0, .height = 14 },
    });
    errdefer root.destroy(alloc);

    const title = try Label.create(alloc, "More (9) — 数据视图 / 字体 / 弹出菜单栏", .{ .font_size = 26, .font_weight = 700, .color = math.Color.hex(0xF8FAFCFF) });
    try root.base.addChild(alloc, &title.base);

    // ── ColumnView ──────────────────────────────────────────────────────────
    try section(alloc, root, "ColumnView (多列表格)");
    const cv_tile = try Container.create(alloc, .{ .bg_color = math.Color.hex(0x00000000), .direction = .column });
    cv_tile.base.layout_style.width = .{ .px = 620 };
    cv_tile.base.layout_style.height = .{ .px = 300 };
    const cv = try ColumnView.new(alloc, .{});
    cv.on_row_selected = onCvSelected;
    try cv.appendColumn(.{ .title = "Name", .width = 180 });
    try cv.appendColumn(.{ .title = "Role", .width = 160 });
    try cv.appendColumn(.{ .title = "Score", .width = 100 });
    try cv.addRow(&.{"Alice", "Engineer", "92"});
    try cv.addRow(&.{"Bob", "Designer", "88"});
    try cv.addRow(&.{"Carol", "PM", "95"});
    try cv.addRow(&.{"Dave", "QA", "79"});
    try cv_tile.base.addChild(alloc, &cv.base);
    cv.base.layout_style.hexpand = true;
    cv.base.layout_style.vexpand = true;
    try root.base.addChild(alloc, &cv_tile.base);
    g_cv_label = try Label.create(alloc, "selected row: (none)", .{ .font_size = 13, .color = math.Color.hex(0x94A3B8FF) });
    try root.base.addChild(alloc, &g_cv_label.?.base);

    // ── GridView ────────────────────────────────────────────────────────────
    try section(alloc, root, "GridView (图标网格)");
    const gv_tile = try Container.create(alloc, .{ .bg_color = math.Color.hex(0x00000000), .direction = .column });
    gv_tile.base.layout_style.width = .{ .px = 620 };
    gv_tile.base.layout_style.height = .{ .px = 260 };
    const gv = try GridView.new(alloc, .{});
    try gv.addItem(.{ .title = "Documents", .subtitle = "12 items" });
    try gv.addItem(.{ .title = "Downloads", .subtitle = "48 items" });
    try gv.addItem(.{ .title = "Pictures", .subtitle = "320 items" });
    try gv.addItem(.{ .title = "Music", .subtitle = "1.2k items" });
    try gv.addItem(.{ .title = "Videos", .subtitle = "64 items" });
    try gv.addItem(.{ .title = "Projects", .subtitle = "9 items" });
    try gv_tile.base.addChild(alloc, &gv.base);
    gv.base.layout_style.hexpand = true;
    gv.base.layout_style.vexpand = true;
    try root.base.addChild(alloc, &gv_tile.base);

    // ── ToolPalette ─────────────────────────────────────────────────────────
    try section(alloc, root, "ToolPalette (工具面板)");
    const tp_tile = try Container.create(alloc, .{ .bg_color = math.Color.hex(0x00000000), .direction = .column });
    tp_tile.base.layout_style.width = .{ .px = 320 };
    tp_tile.base.layout_style.height = .{ .px = 240 };
    const tp = try ToolPalette.create(alloc, .{});
    const tp_grp1 = try tp.addGroup("Shapes");
    try tp_grp1.addItem("rect", "Rectangle", null);
    try tp_grp1.addItem("ellipse", "Ellipse", null);
    try tp_grp1.addItem("line", "Line", null);
    const tp_grp2 = try tp.addGroup("Paths");
    try tp_grp2.addItem("pen", "Pen", null);
    try tp_grp2.addItem("brush", "Brush", null);
    try tp_tile.base.addChild(alloc, &tp.base);
    tp.base.layout_style.hexpand = true;
    tp.base.layout_style.vexpand = true;
    try root.base.addChild(alloc, &tp_tile.base);

    // ── FontSelection ───────────────────────────────────────────────────────
    try section(alloc, root, "FontSelection (字体面板)");
    const fs = try FontSelection.create(alloc, .{ .on_font_changed = onFontChanged });
    try root.base.addChild(alloc, &fs.base);
    g_font_label = try Label.create(alloc, "font: Sans 14", .{ .font_size = 13, .color = math.Color.hex(0x94A3B8FF) });
    try root.base.addChild(alloc, &g_font_label.?.base);

    // ── PopoverMenuBar ──────────────────────────────────────────────────────
    try section(alloc, root, "PopoverMenuBar (弹出菜单栏)");
    const pmb_file = try Menu.create(alloc, .{});
    try pmb_file.addItem(MenuItem{ .label = "New" });
    try pmb_file.addItem(MenuItem{ .label = "Open" });
    try pmb_file.addSeparator();
    try pmb_file.addItem(MenuItem{ .label = "Quit" });
    const pmb_edit = try Menu.create(alloc, .{});
    try pmb_edit.addItem(MenuItem{ .label = "Undo" });
    try pmb_edit.addItem(MenuItem{ .label = "Redo" });
    const pmb = try PopoverMenuBar.new(alloc, .{ .on_menu_open = onPmbOpen, .on_menu_close = onPmbClose });
    try pmb.addMenu("File", pmb_file);
    try pmb.addMenu("Edit", pmb_edit);
    try pmb.addMenu("View", pmb_edit);
    try root.base.addChild(alloc, &pmb.base);
    g_pmb_label = try Label.create(alloc, "last opened menu: (none)", .{ .font_size = 13, .color = math.Color.hex(0x94A3B8FF) });
    try root.base.addChild(alloc, &g_pmb_label.?.base);

    g_root = root;
    g_tree_alloc = alloc;
}

// ── 回调 ─────────────────────────────────────────────────────────────────────

fn onCvSelected(self: *ColumnView, row: ?usize) void {
    _ = self;
    if (g_cv_label) |lbl| {
        lbl.text = std.fmt.bufPrint(&g_cv_buf, "selected row: {any}", .{row}) catch "selected row";
    }
}

fn onFontChanged(self: *FontSelection, desc: FontDesc) void {
    _ = self;
    if (g_font_label) |lbl| {
        lbl.text = std.fmt.bufPrint(&g_font_buf, "font: {s} {d}{s}{s}", .{
            desc.family,
            desc.size,
            if (desc.bold) " bold" else "",
            if (desc.italic) " italic" else "",
        }) catch "font";
    }
}

fn onPmbOpen(self: *PopoverMenuBar, index: usize) void {
    _ = self;
    if (g_pmb_label) |lbl| {
        lbl.text = std.fmt.bufPrint(&g_pmb_buf, "last opened menu index: {d}", .{index}) catch "menu";
    }
}

fn onPmbClose(self: *PopoverMenuBar) void {
    _ = self;
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
