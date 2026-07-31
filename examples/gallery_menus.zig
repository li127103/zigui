//! zigui gallery - 菜单类控件 (Menus)
//!
//! 演示:
//!   - MenuButton   带弹出层的菜单按钮 (点击自动弹出 Popover)
//!   - Popover      浮层容器 (承载菜单/任意内容)
//!   - Menu         菜单项列表 (MenuItem)
//!   - ContextMenu  右键/按钮触发的上下文菜单
//!
//! 运行:  zig build run-gallery-menus

const std = @import("std");
const zigui = @import("zigui");
const math = zigui.math;
const styled_text = zigui.styled_text;
const widget = zigui.widget;

const Container = zigui.container.Container;
const MenuButton = zigui.menu_button.MenuButton;
const Popover = zigui.popover.Popover;
const Menu = zigui.menu.Menu;
const ContextMenu = zigui.context_menu.ContextMenu;
const ContextMenuItem = zigui.context_menu.ContextMenuItem;
const Label = zigui.label.Label;
const Button = zigui.button.Button;

const pal = zigui.pal;

const theme_dark: zigui.theme.Theme = zigui.theme.dark;

var g_root: ?*Container = null;
var g_tree_alloc: ?std.mem.Allocator = null;
var g_prev_mouse_down: bool = false;

var g_ctx_menu: ?*ContextMenu = null;

pub fn main() !void {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var app = try zigui.app.App.init(allocator, .{
        .title = "zigui Gallery - Menus",
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

    const title = try Label.create(alloc, "Menus", .{ .font_size = 26, .font_weight = 700, .color = math.Color.hex(0xF8FAFCFF) });
    try root.base.addChild(alloc, &title.base);

    const sub = try Label.create(alloc, "Click the menu button, or press 'Show Context Menu'.", .{ .font_size = 13, .color = math.Color.hex(0x64748BFF) });
    try root.base.addChild(alloc, &sub.base);

    // MenuButton + Popover(内含 Menu)
    const pop = try Popover.create(alloc, .{ .width = .{ .px = 200 } });
    const menu = try Menu.create(alloc, .{});
    try menu.addItem(.{ .label = "New" });
    try menu.addItem(.{ .label = "Open", .shortcut = "Ctrl+O" });
    try menu.addItem(.{ .label = "Save", .shortcut = "Ctrl+S" });
    try menu.addItem(.separator());
    try menu.addItem(.{ .label = "Quit", .disabled = true });
    try pop.addChild(&menu.base);

    const mb = try MenuButton.create(alloc, "File", .{});
    mb.setPopover(pop);
    try addRow(alloc, root, "MenuButton", mb);

    // ContextMenu via button
    const ctx_items = [_]ContextMenuItem{
        .{ .label = "Cut" },
        .{ .label = "Copy" },
        .{ .label = "Paste" },
        .{ .is_separator = true },
        .{ .label = "Delete", .disabled = true },
    };
    const cm = try ContextMenu.create(alloc, &ctx_items);
    g_ctx_menu = cm;
    const show_btn = try Button.create(alloc, "Show Context Menu", .{ .on_click = onShowContext });
    try addRow(alloc, root, "ContextMenu", show_btn);

    g_root = root;
    g_tree_alloc = alloc;
}

fn onShowContext(_: *Button) void {
    if (g_ctx_menu) |cm| {
        cm.popupAt(320, 320);
    }
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
