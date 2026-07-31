//! zigui gallery - 布局/导航控件（三）(Widgets part 3)
//!
//! 演示:
//!   - Fixed           绝对定位容器
//!   - Stack           页面栈 (配合 StackSwitcher / StackSidebar)
//!   - StackSwitcher   栈顶页面切换条
//!   - StackSidebar    栈侧边栏
//!   - PlacesSidebar   常用位置侧边栏 (文件系统位置)
//!   - RecentChooser   最近使用文件选择器
//!
//! 运行:  zig build run-gallery-widgets3

const std = @import("std");
const zigui = @import("zigui");
const math = zigui.math;
const styled_text = zigui.styled_text;
const widget = zigui.widget;

const Container = zigui.container.Container;
const Fixed = zigui.fixed.Fixed;
const Stack = zigui.stack.Stack;
const StackSwitcher = zigui.stack_switcher.StackSwitcher;
const StackSidebar = zigui.stack_sidebar.StackSidebar;
const PlacesSidebar = zigui.places_sidebar.PlacesSidebar;
const RecentChooser = zigui.recent_chooser.RecentChooserWidget;
const Label = zigui.label.Label;
const Button = zigui.button.Button;

const pal = zigui.pal;

const theme_dark: zigui.theme.Theme = zigui.theme.dark;

var g_root: ?*Container = null;
var g_tree_alloc: ?std.mem.Allocator = null;
var g_prev_mouse_down: bool = false;

var g_stack: ?*Stack = null;

pub fn main() !void {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var app = try zigui.app.App.init(allocator, .{
        .title = "zigui Gallery - Widgets (3)",
        .width = 820,
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
        .gap = .{ .width = 0, .height = 16 },
    });
    errdefer root.destroy(alloc);

    const title = try Label.create(alloc, "Widgets (3)", .{ .font_size = 26, .font_weight = 700, .color = math.Color.hex(0xF8FAFCFF) });
    try root.base.addChild(alloc, &title.base);

    const sub = try Label.create(alloc, "Fixed / Stack / StackSwitcher / StackSidebar / PlacesSidebar / RecentChooser", .{ .font_size = 13, .color = math.Color.hex(0x64748BFF) });
    try root.base.addChild(alloc, &sub.base);

    // Fixed
    const fx = try Fixed.create(alloc, .{ .bg_color = math.Color.hex(0x1E293BFF), .corner_radius = 8 });
    fx.base.layout_style.height = .{ .px = 140 };
    const b1 = try Button.create(alloc, "Top-Left", .{});
    try fx.addChild(&b1.base, .{ .left = 12, .top = 12 });
    const b2 = try Button.create(alloc, "Bottom-Right", .{});
    try fx.addChild(&b2.base, .{ .right = 12, .bottom = 12 });
    try root.base.addChild(alloc, &fx.base);

    // Stack + Switcher + Sidebar
    const stack = try Stack.create(alloc, .{ .bg_color = math.Color.hex(0x1E293BFF), .corner_radius = 8 });
    g_stack = stack;

    const p1 = try Label.create(alloc, "Page 1: Overview", .{ .font_size = 16, .color = math.Color.hex(0xF1F5FFFF) });
    try stack.addChild(&p1.base);
    const p2 = try Label.create(alloc, "Page 2: Details", .{ .font_size = 16, .color = math.Color.hex(0xF1F5FFFF) });
    try stack.addChild(&p2.base);
    const p3 = try Label.create(alloc, "Page 3: Settings", .{ .font_size = 16, .color = math.Color.hex(0xF1F5FFFF) });
    try stack.addChild(&p3.base);

    const switcher = try StackSwitcher.create(alloc, .{ .stack = stack });
    try root.base.addChild(alloc, &switcher.base);

    const sidebar = try StackSidebar.create(alloc, .{ .stack = stack });
    try root.base.addChild(alloc, &sidebar.base);

    try root.base.addChild(alloc, &stack.base);

    const next_btn = try Button.create(alloc, "Next Page", .{ .on_click = onNextPage });
    try addRow(alloc, root, "Stack", next_btn);

    // PlacesSidebar
    const places = try PlacesSidebar.create(alloc, .{ .include_defaults = true });
    try root.base.addChild(alloc, &places.base);

    // RecentChooser
    const recent = try RecentChooser.create(alloc, .{});
    try root.base.addChild(alloc, &recent.base);

    g_root = root;
    g_tree_alloc = alloc;
}

fn onNextPage(_: *Button) void {
    if (g_stack) |s| s.next();
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
