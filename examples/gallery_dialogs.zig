//! zigui gallery - 对话框类控件 (Dialogs)
//!
//! 演示:
//!   - MessageDialog   消息对话框 (信息/警告/错误 + 按钮)
//!   - FileChooser     文件选择对话框
//!   - ColorChooserDialog  颜色选择对话框
//!
//! 运行:  zig build run-gallery-dialogs
//! 点击按钮弹出对应对话框; 状态栏显示回调结果。

const std = @import("std");
const zigui = @import("zigui");
const math = zigui.math;
const styled_text = zigui.styled_text;
const widget = zigui.widget;

const Container = zigui.container.Container;
const MessageDialog = zigui.message_dialog.MessageDialog;
const MessageDialogResult = zigui.message_dialog.MessageDialogResult;
const FileChooser = zigui.file_chooser.FileChooser;
const ColorChooserDialog = zigui.color_chooser.ColorChooserDialog;
const Label = zigui.label.Label;
const Button = zigui.button.Button;

const pal = zigui.pal;

const theme_dark: zigui.theme.Theme = zigui.theme.dark;

var g_root: ?*Container = null;
var g_tree_alloc: ?std.mem.Allocator = null;
var g_prev_mouse_down: bool = false;

var g_status_label: ?*Label = null;
var g_status_buf: [160]u8 = undefined;

pub fn main() !void {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var app = try zigui.app.App.init(allocator, .{
        .title = "zigui Gallery - Dialogs",
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

    const title = try Label.create(alloc, "Dialogs", .{ .font_size = 26, .font_weight = 700, .color = math.Color.hex(0xF8FAFCFF) });
    try root.base.addChild(alloc, &title.base);

    const sub = try Label.create(alloc, "Click a button to open a dialog.", .{ .font_size = 13, .color = math.Color.hex(0x64748BFF) });
    try root.base.addChild(alloc, &sub.base);

    // MessageDialog
    const msg = try MessageDialog.create(alloc, .{
        .kind = .info,
        .buttons = .ok_cancel,
        .title = "Confirm",
        .message = "This is a message dialog example.",
        .on_result = onMsgResult,
    });
    msg.base.state.visible = false;
    g_msg = msg;
    try root.base.addChild(alloc, &msg.base);
    const msg_btn = try Button.create(alloc, "Open MessageDialog", .{ .on_click = onOpenMsg });
    try addRow(alloc, root, "MessageDialog", msg_btn);

    // FileChooser
    const fc = try FileChooser.create(alloc, .{
        .mode = .open,
        .title = "Open File",
        .on_file_selected = onFileSelected,
        .on_cancel = onFileCancel,
    });
    fc.base.state.visible = false;
    g_fc = fc;
    try root.base.addChild(alloc, &fc.base);
    const fc_btn = try Button.create(alloc, "Open FileChooser", .{ .on_click = onOpenFile });
    try addRow(alloc, root, "FileChooser", fc_btn);

    // ColorChooserDialog
    const cc = try ColorChooserDialog.create(alloc, .{
        .title = "Pick a Color",
        .on_color_selected = onColorSelected,
        .on_cancel = onColorCancel,
    });
    cc.base.state.visible = false;
    g_cc = cc;
    try root.base.addChild(alloc, &cc.base);
    const cc_btn = try Button.create(alloc, "Open ColorChooser", .{ .on_click = onOpenColor });
    try addRow(alloc, root, "ColorChooser", cc_btn);

    // status
    const status = try Label.create(alloc, "Status: idle", .{ .font_size = 13, .color = math.Color.hex(0x94A3B8FF) });
    status.base.layout_style.margin.top = 8;
    try root.base.addChild(alloc, &status.base);
    g_status_label = status;

    g_root = root;
    g_tree_alloc = alloc;
}

// 对话框实例句柄 (供按钮回调打开)
var g_msg: ?*MessageDialog = null;
var g_fc: ?*FileChooser = null;
var g_cc: ?*ColorChooserDialog = null;

fn onOpenMsg(_: *Button) void {
    if (g_msg) |d| d.show();
}
fn onOpenFile(_: *Button) void {
    if (g_fc) |d| d.show();
}
fn onOpenColor(_: *Button) void {
    if (g_cc) |d| d.show();
}

fn onMsgResult(_: *MessageDialog, result: MessageDialogResult) void {
    setStatus("MessageDialog result: {s}", .{@tagName(result)});
}
fn onFileSelected(_: *FileChooser, path: []const u8) void {
    setStatus("File selected: {s}", .{path});
}
fn onFileCancel(_: *FileChooser) void {
    setStatus("File chooser cancelled", .{});
}
fn onColorSelected(_: *ColorChooserDialog, color: math.Color) void {
    const hex_val: u32 = (@as(u32, color.r) << 24) |
        (@as(u32, color.g) << 16) |
        (@as(u32, color.b) << 8) |
        @as(u32, color.a);
    setStatus("Color selected: #{X:0<8}", .{hex_val});
}
fn onColorCancel(_: *ColorChooserDialog) void {
    setStatus("Color chooser cancelled", .{});
}

fn setStatus(comptime fmt: []const u8, args: anytype) void {
    if (g_status_label) |s| {
        s.text = std.fmt.bufPrint(&g_status_buf, fmt, args) catch "?";
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
