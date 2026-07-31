//! zigui gallery - 对话框 / 选择器 (More 4)
//!
//! 演示:
//!   - MessageDialog   消息对话框 (info/warning/error/question)
//!   - AppChooser      选择应用对话框
//!   - PrintDialog     打印对话框
//!
//! 运行:  zig build run-gallery-more4
//! 说明: 点击按钮触发对应的 show() 弹出顶层对话框。

const std = @import("std");
const zigui = @import("zigui");
const math = zigui.math;
const styled_text = zigui.styled_text;
const widget = zigui.widget;

const Container = zigui.container.Container;
const MessageDialog = zigui.message_dialog.MessageDialog;
const AppChooserDialog = zigui.app_chooser.AppChooserDialog;
const PrintDialog = zigui.print_dialog.PrintDialog;
const Label = zigui.label.Label;
const Button = zigui.button.Button;

const pal = zigui.pal;

const theme_dark: zigui.theme.Theme = zigui.theme.dark;

var g_root: ?*Container = null;
var g_tree_alloc: ?std.mem.Allocator = null;
var g_prev_mouse_down: bool = false;
var g_msg: ?*MessageDialog = null;
var g_app: ?*AppChooserDialog = null;
var g_print: ?*PrintDialog = null;

pub fn main() !void {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var app = try zigui.app.App.init(allocator, .{
        .title = "zigui Gallery - More (4)",
        .width = 520,
        .height = 420,
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

    const title = try Label.create(alloc, "More (4)", .{ .font_size = 26, .font_weight = 700, .color = math.Color.hex(0xF8FAFCFF) });
    try root.base.addChild(alloc, &title.base);

    const sub = try Label.create(alloc, "MessageDialog / AppChooser / PrintDialog", .{ .font_size = 13, .color = math.Color.hex(0x64748BFF) });
    try root.base.addChild(alloc, &sub.base);

    g_msg = try MessageDialog.create(alloc, .{
        .kind = .question,
        .message = "Do you want to save your changes?",
    });
    const b_msg = try Button.create(alloc, "Show MessageDialog", .{ .on_click = onShowMsg });
    try addRow(alloc, root, "Message", b_msg);

    g_app = try AppChooserDialog.create(alloc, .{
        .content_type = "image/png",
        .on_app_selected = onAppSelected,
    });
    const b_app = try Button.create(alloc, "Show AppChooser", .{ .on_click = onShowApp });
    try addRow(alloc, root, "App", b_app);

    g_print = try PrintDialog.create(alloc, .{
        .on_print = onPrint,
    });
    const b_print = try Button.create(alloc, "Show PrintDialog", .{ .on_click = onShowPrint });
    try addRow(alloc, root, "Print", b_print);

    g_root = root;
    g_tree_alloc = alloc;
}

fn onShowMsg(_: *Button) void {
    if (g_msg) |d| d.show();
}
fn onShowApp(_: *Button) void {
    if (g_app) |d| d.show();
}
fn onShowPrint(_: *Button) void {
    if (g_print) |d| d.show();
}
fn onAppSelected(_: *AppChooserDialog, _: zigui.app_chooser.AppInfo) void {}
fn onPrint(_: *PrintDialog, _: *const zigui.print_dialog.PrintSettings) void {}

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
