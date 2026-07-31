//! zigui gallery - 菜单类控件（二）(Menus part 2)
//!
//! 演示:
//!   - MenuBar       顶部菜单栏 (File / Edit 等下拉菜单)
//!   - PopoverMenu   弹出式菜单 (点击按钮弹出)
//!   - SplitButton   带下拉箭头的主按钮 (setMenu 绑定菜单)
//!
//! 运行:  zig build run-gallery-menus2

const std = @import("std");
const zigui = @import("zigui");
const math = zigui.math;
const styled_text = zigui.styled_text;
const widget = zigui.widget;

const Container = zigui.container.Container;
const MenuBar = zigui.menu_bar.MenuBar;
const PopoverMenu = zigui.popover_menu.PopoverMenu;
const SplitButton = zigui.split_button.SplitButton;
const Menu = zigui.menu.Menu;
const Label = zigui.label.Label;
const Button = zigui.button.Button;

const pal = zigui.pal;

const theme_dark: zigui.theme.Theme = zigui.theme.dark;

var g_root: ?*Container = null;
var g_tree_alloc: ?std.mem.Allocator = null;
var g_prev_mouse_down: bool = false;

var g_popover_menu: ?*PopoverMenu = null;

pub fn main() !void {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var app = try zigui.app.App.init(allocator, .{
        .title = "zigui Gallery - Menus (2)",
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
        .gap = .{ .width = 0, .height = 16 },
    });
    errdefer root.destroy(alloc);

    const title = try Label.create(alloc, "Menus (2)", .{ .font_size = 26, .font_weight = 700, .color = math.Color.hex(0xF8FAFCFF) });
    try root.base.addChild(alloc, &title.base);

    const sub = try Label.create(alloc, "MenuBar / PopoverMenu / SplitButton", .{ .font_size = 13, .color = math.Color.hex(0x64748BFF) });
    try root.base.addChild(alloc, &sub.base);

    // MenuBar
    const mb = try MenuBar.create(alloc, .{});
    const file_menu = try Menu.create(alloc, .{});
    try file_menu.addItem(.{ .label = "New" });
    try file_menu.addItem(.{ .label = "Open" });
    try file_menu.addItem(.separator());
    try file_menu.addItem(.{ .label = "Quit" });
    try mb.addMenu("File", file_menu);

    const edit_menu = try Menu.create(alloc, .{});
    try edit_menu.addItem(.{ .label = "Cut" });
    try edit_menu.addItem(.{ .label = "Copy" });
    try edit_menu.addItem(.{ .label = "Paste" });
    try mb.addMenu("Edit", edit_menu);
    try root.base.addChild(alloc, &mb.base);

    // PopoverMenu
    const pm = try PopoverMenu.create(alloc, .{ .width = .{ .px = 220 } });
    const pm_menu = try Menu.create(alloc, .{});
    try pm_menu.addItem(.{ .label = "Profile" });
    try pm_menu.addItem(.{ .label = "Settings" });
    try pm_menu.addItem(.separator());
    try pm_menu.addItem(.{ .label = "Sign out" });
    pm.setMenu(pm_menu);
    g_popover_menu = pm;
    try root.base.addChild(alloc, &pm.base);
    const pm_btn = try Button.create(alloc, "Open PopoverMenu", .{ .on_click = onOpenPopoverMenu });
    try addRow(alloc, root, "PopoverMenu", pm_btn);

    // SplitButton
    const sb = try SplitButton.newWithLabel(alloc, "Save");
    const sb_menu = try Menu.create(alloc, .{});
    try sb_menu.addItem(.{ .label = "Save" });
    try sb_menu.addItem(.{ .label = "Save As..." });
    try sb_menu.addItem(.{ .label = "Save All" });
    sb.setMenuModel(sb_menu);
    try addRow(alloc, root, "SplitButton", sb);

    g_root = root;
    g_tree_alloc = alloc;
}

fn onOpenPopoverMenu(_: *Button) void {
    if (g_popover_menu) |pm| pm.popup();
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
