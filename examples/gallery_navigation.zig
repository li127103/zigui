//! zigui gallery - 导航与容器控件 (Navigation & Containers)
//!
//! 演示 (均为真正的可交互控件):
//!   - HeaderBar   标题栏 (左按钮 | 居中标题 | 右按钮)
//!   - Toolbar     工具栏 (图标+文字按钮 + 分隔线)
//!   - InfoBar     信息栏 (info/warning/error/question)
//!   - SearchBar   搜索栏 (Ctrl+F 切换, Esc 清空/关闭)
//!   - Notebook   多标签页容器
//!   - Stack       堆叠页面容器 (可切换)
//!   - Popover     气泡弹出层
//!   - Revealer    可展开/收起容器 (每帧 tick)
//!   - Expander    可折叠面板 (每帧 tick)
//!
//! 运行:  zig build run-gallery-navigation

const std = @import("std");
const zigui = @import("zigui");
const math = zigui.math;
const styled_text = zigui.styled_text;
const widget = zigui.widget;

const Container = zigui.container.Container;
const Label = zigui.label.Label;
const Button = zigui.button.Button;
const HeaderBar = zigui.header_bar.HeaderBar;
const Toolbar = zigui.toolbar.Toolbar;
const InfoBar = zigui.info_bar.InfoBar;
const SearchBar = zigui.search_bar.SearchBar;
const Notebook = zigui.notebook.Notebook;
const Stack = zigui.stack.Stack;
const Popover = zigui.popover.Popover;
const Revealer = zigui.revealer.Revealer;
const Expander = zigui.expander.Expander;

const pal = zigui.pal;

const theme_dark: zigui.theme.Theme = zigui.theme.dark;

var g_root: ?*Container = null;
var g_tree_alloc: ?std.mem.Allocator = null;
var g_prev_mouse_down: bool = false;

// 需要每帧 tick 的动画控件
var g_revealer: ?*Revealer = null;
var g_expander: ?*Expander = null;

pub fn main() !void {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var app = try zigui.app.App.init(allocator, .{
        .title = "zigui Gallery - Navigation & Containers",
        .width = 680,
        .height = 860,
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
        .padding = .{ .left = 20, .top = 16, .right = 20, .bottom = 16 },
        .gap = .{ .width = 0, .height = 16 },
    });
    errdefer root.destroy(alloc);

    const title = try Label.create(alloc, "Navigation & Containers", .{ .font_size = 24, .font_weight = 700, .color = math.Color.hex(0xF8FAFCFF) });
    try root.base.addChild(alloc, &title.base);

    const sub = try Label.create(alloc, "Header bars, toolbars, tabs, popovers and animated reveal containers.", .{ .font_size = 13, .color = math.Color.hex(0x64748BFF) });
    try root.base.addChild(alloc, &sub.base);

    // HeaderBar
    try section(alloc, root, "HeaderBar");
    const hb = try HeaderBar.create(alloc, .{ .title = "Document", .bg_color = math.Color.hex(0x1E293BFF), .height = 44 });
    const hb_left = try Button.create(alloc, "≡", .{ .min_width = 36, .height = 30 });
    try hb.addChild(&hb_left.base);
    const hb_right = try Button.create(alloc, "＋", .{ .min_width = 36, .height = 30 });
    try hb.addChild(&hb_right.base);
    try root.base.addChild(alloc, &hb.base);

    // Toolbar
    try section(alloc, root, "Toolbar");
    const tb = try Toolbar.create(alloc, .{});
    try tb.addButton("New", "document-new", null, null);
    try tb.addButton("Open", "folder", null, null);
    try tb.addSeparator();
    try tb.addButton("Copy", "edit-copy", null, null);
    try tb.addButton("Paste", "edit-paste", null, null);
    try root.base.addChild(alloc, &tb.base);

    // InfoBar
    try section(alloc, root, "InfoBar");
    const ib = try InfoBar.create(alloc, .{ .message_type = .info, .text = "Operation completed successfully.", .show_close = true });
    _ = try ib.addButton("Undo", 1);
    try root.base.addChild(alloc, &ib.base);

    // SearchBar
    try section(alloc, root, "SearchBar");
    const sb = try SearchBar.create(alloc, .{ .placeholder = "Search items…", .on_search_changed = onSearch });
    sb.setRevealChild(true);
    try root.base.addChild(alloc, &sb.base);

    // Notebook
    try section(alloc, root, "Notebook");
    const nb = try Notebook.create(alloc, .{ .on_change = null });
    const page1 = try Label.create(alloc, "Content of the first tab.", .{ .font_size = 14, .color = math.Color.hex(0xE2E8F0FF) });
    const page2 = try Label.create(alloc, "Content of the second tab.", .{ .font_size = 14, .color = math.Color.hex(0xE2E8F0FF) });
    _ = try nb.appendPage("General", &page1.base);
    _ = try nb.appendPage("Advanced", &page2.base);
    try root.base.addChild(alloc, &nb.base);

    // Stack
    try section(alloc, root, "Stack (click to switch)");
    const stack = try Stack.create(alloc, .{ .bg_color = math.Color.hex(0x1E293BFF), .corner_radius = 8, .height = .{ .px = 80 } });
    const sp1 = try Label.create(alloc, "Page One", .{ .font_size = 16, .color = math.Color.hex(0xF8FAFCFF) });
    const sp2 = try Label.create(alloc, "Page Two", .{ .font_size = 16, .color = math.Color.hex(0xF8FAFCFF) });
    try stack.addChild(&sp1.base);
    try stack.addChild(&sp2.base);
    try root.base.addChild(alloc, &stack.base);
    const stack_btn = try Button.create(alloc, "Switch Page", .{ .on_click = onSwitchStack });
    stack_btn.base.layout_style.margin.top = 8;
    stack_btn.base.user_data = stack;
    try root.base.addChild(alloc, &stack_btn.base);

    // Popover
    try section(alloc, root, "Popover (click to toggle)");
    const pop_btn = try Button.create(alloc, "Open Popover", .{ .on_click = onTogglePopover });
    const pop = try Popover.create(alloc, .{ .relative_to = &pop_btn.base, .width = .{ .px = 220 }, .height = .{ .auto = {} } });
    const pop_label = try Label.create(alloc, "This is a popover bubble with an arrow.", .{ .font_size = 13, .color = math.Color.hex(0xF8FAFCFF), .wrap = true });
    try pop.addChild(&pop_label.base);
    pop_btn.base.user_data = pop;
    try root.base.addChild(alloc, &pop_btn.base);
    try root.base.addChild(alloc, &pop.base);

    // Revealer
    try section(alloc, root, "Revealer");
    const rev = try Revealer.create(alloc, .{ .transition_type = .slide_down, .transition_duration_ms = 200, .reveal_child = true, .bg_color = math.Color.hex(0x1E293BFF), .corner_radius = 8 });
    const rev_label = try Label.create(alloc, "Revealed content (animated).", .{ .font_size = 14, .color = math.Color.hex(0xE2E8F0FF) });
    try rev.setChild(&rev_label.base);
    try root.base.addChild(alloc, &rev.base);
    g_revealer = rev;

    // Expander
    try section(alloc, root, "Expander");
    const exp = try Expander.create(alloc, "Click the header to expand", .{ .expanded = true, .transition_duration_ms = 200 });
    const exp_label = try Label.create(alloc, "Hidden details shown when expanded.", .{ .font_size = 14, .color = math.Color.hex(0x334155FF) });
    try exp.base.addChild(alloc, &exp_label.base);
    try root.base.addChild(alloc, &exp.base);
    g_expander = exp;

    g_root = root;
    g_tree_alloc = alloc;
}

fn section(alloc: std.mem.Allocator, parent: *Container, title: []const u8) !void {
    const l = try Label.create(alloc, title, .{ .font_size = 15, .font_weight = 600, .color = math.Color.hex(0xCBD5E1FF) });
    l.base.layout_style.margin.top = 6;
    try parent.base.addChild(alloc, &l.base);
}

fn destroyTree() void {
    if (g_root) |root| {
        root.destroy(g_tree_alloc orelse return);
        g_root = null;
    }
}

// ── 回调 ──
fn onSearch(_: *SearchBar, text: []const u8) void {
    _ = text;
}

fn onSwitchStack(b: *Button) void {
    const stack: *Stack = @ptrCast(@alignCast(b.base.user_data orelse return));
    stack.next();
}

fn onTogglePopover(b: *Button) void {
    const pop: *Popover = @ptrCast(@alignCast(b.base.user_data orelse return));
    if (pop.is_open) pop.popdown() else pop.popup();
}

fn drawFrame(app: *zigui.app.App) void {
    const root = g_root orelse return;
    const fb = app.getFramebufferSize();
    const w: f32 = @floatFromInt(fb.width);
    const h: f32 = @floatFromInt(fb.height);

    root.base.layout_style.width = .{ .px = w };
    root.base.layout_style.height = .{ .px = h };

    // 每帧推进动画
    if (g_revealer) |r| r.tick(16);
    if (g_expander) |e| e.tick(16);

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
