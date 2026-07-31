//! zigui gallery - 对话框 / 选择器 (More 6)
//!
//! 演示:
//!   - AlertDialog        警告/消息对话框 (可嵌入 Widget 树)
//!   - ShortcutsWindow    快捷键窗口 (可嵌入 Widget 树)
//!   - ColorDialog        GTK4 颜色选择对象 (按钮触发 chooseRgba)
//!   - FontDialog         GTK4 字体选择对象 (按钮触发 chooseFont)
//!   - FileChooserNative  跨平台原生文件选择 (按钮触发 show)
//!
//! 运行:  zig build run-gallery-more6

const std = @import("std");
const zigui = @import("zigui");
const math = zigui.math;
const styled_text = zigui.styled_text;
const widget = zigui.widget;

const Container = zigui.container.Container;
const Label = zigui.label.Label;
const Button = zigui.button.Button;
const AlertDialog = zigui.alert_dialog.AlertDialog;
const AlertButton = zigui.alert_dialog.AlertButton;
const ShortcutsWindow = zigui.shortcuts_window.ShortcutsWindow;
const ShortcutEntry = zigui.shortcuts_window.ShortcutEntry;
const ColorDialog = zigui.color_dialog.ColorDialog;
const ColorDialogResult = zigui.color_dialog.ColorDialogResult;
const FontDialog = zigui.font_dialog.FontDialog;
const FontDialogResult = zigui.font_dialog.FontDialogResult;
const FileChooserNative = zigui.file_chooser_native.FileChooserNative;
const FileChooserResponse = zigui.file_chooser_native.FileChooserResponse;

const pal = zigui.pal;

const theme_dark: zigui.theme.Theme = zigui.theme.dark;

var g_root: ?*Container = null;
var g_tree_alloc: ?std.mem.Allocator = null;
var g_prev_mouse_down: bool = false;

// 选择器对象 (非 Widget, 由按钮触发, 不在树中销毁)
var g_color_dlg: ?*ColorDialog = null;
var g_font_dlg: ?*FontDialog = null;
var g_file_dlg: ?*FileChooserNative = null;

// 结果展示标签
var g_alert_label: ?*Label = null;
var g_color_label: ?*Label = null;
var g_font_label: ?*Label = null;
var g_file_label: ?*Label = null;

// 长生命周期结果缓冲 (Label.text 必须指向稳定内存)
var g_alert_buf: [256]u8 = undefined;
var g_color_buf: [256]u8 = undefined;
var g_font_buf: [256]u8 = undefined;
var g_file_buf: [256]u8 = undefined;

pub fn main() !void {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var app = try zigui.app.App.init(allocator, .{
        .title = "zigui Gallery - More (6)",
        .width = 720,
        .height = 1080,
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

    const title = try Label.create(alloc, "More (6)", .{ .font_size = 26, .font_weight = 700, .color = math.Color.hex(0xF8FAFCFF) });
    try root.base.addChild(alloc, &title.base);

    const sub = try Label.create(alloc, "AlertDialog / ShortcutsWindow / ColorDialog / FontDialog / FileChooserNative", .{ .font_size = 13, .color = math.Color.hex(0x64748BFF) });
    try root.base.addChild(alloc, &sub.base);

    // ── AlertDialog (嵌入 Widget 树) ──────────────────────────────────────────
    const alert_cap = try Label.create(alloc, "AlertDialog", .{ .font_size = 15, .font_weight = 600, .color = math.Color.hex(0x94A3B8FF) });
    try root.base.addChild(alloc, &alert_cap.base);

    const alert = try AlertDialog.create(alloc, .{
        .title = "Delete Items",
        .message = "This will permanently delete the selected items.",
        .detail = "This action cannot be undone.",
        .level = .warning,
        .buttons = &[_]AlertButton{
            .{ .text = "Cancel", .style = .cancel },
            .{ .text = "Delete", .style = .destructive },
        },
        .on_response = onAlertResponse,
    });
    try root.base.addChild(alloc, &alert.base);

    g_alert_label = try Label.create(alloc, "Last response: (none)", .{ .font_size = 13, .color = math.Color.hex(0x94A3B8FF) });
    try root.base.addChild(alloc, &g_alert_label.?.base);

    // ── ShortcutsWindow (嵌入 Widget 树) ──────────────────────────────────────
    const sc_cap = try Label.create(alloc, "ShortcutsWindow", .{ .font_size = 15, .font_weight = 600, .color = math.Color.hex(0x94A3B8FF) });
    try root.base.addChild(alloc, &sc_cap.base);

    const sw = try ShortcutsWindow.create(alloc, .{ .window_title = "Keyboard Shortcuts" });
    try sw.addGroup(.{
        .title = "General",
        .entries = &[_]ShortcutEntry{
            .{ .title = "Open File", .shortcut = "Ctrl+O" },
            .{ .title = "Save", .shortcut = "Ctrl+S" },
            .{ .title = "Quit", .shortcut = "Ctrl+Q", .subtitle = "Exit the application" },
        },
    });
    try sw.addGroup(.{
        .title = "Editing",
        .entries = &[_]ShortcutEntry{
            .{ .title = "Copy", .shortcut = "Ctrl+C" },
            .{ .title = "Paste", .shortcut = "Ctrl+V" },
            .{ .title = "Find", .shortcut = "Ctrl+F", .subtitle = "Search shortcuts" },
        },
    });
    try root.base.addChild(alloc, &sw.base);

    // ── 选择器 (按钮触发) ─────────────────────────────────────────────────────
    const pick_cap = try Label.create(alloc, "Choosers (button-triggered)", .{ .font_size = 15, .font_weight = 600, .color = math.Color.hex(0x94A3B8FF) });
    try root.base.addChild(alloc, &pick_cap.base);

    const pick_row = try Container.create(alloc, .{ .direction = .row, .gap = .{ .width = 12, .height = 0 } });
    const b_color = try Button.create(alloc, "Pick Color", .{ .on_click = onPickColor });
    try pick_row.base.addChild(alloc, &b_color.base);
    const b_font = try Button.create(alloc, "Pick Font", .{ .on_click = onPickFont });
    try pick_row.base.addChild(alloc, &b_font.base);
    const b_file = try Button.create(alloc, "Open File", .{ .on_click = onPickFile });
    try pick_row.base.addChild(alloc, &b_file.base);
    try root.base.addChild(alloc, &pick_row.base);

    g_color_label = try Label.create(alloc, "Color: (not chosen)", .{ .font_size = 13, .color = math.Color.hex(0x94A3B8FF) });
    try root.base.addChild(alloc, &g_color_label.?.base);
    g_font_label = try Label.create(alloc, "Font: (not chosen)", .{ .font_size = 13, .color = math.Color.hex(0x94A3B8FF) });
    try root.base.addChild(alloc, &g_font_label.?.base);
    g_file_label = try Label.create(alloc, "File: (not chosen)", .{ .font_size = 13, .color = math.Color.hex(0x94A3B8FF) });
    try root.base.addChild(alloc, &g_file_label.?.base);

    // 选择器对象 (非 Widget, 生命周期自行管理)
    const cd = try ColorDialog.new(alloc, "Choose Color");
    cd.on_response = onColorResponse;
    g_color_dlg = cd;

    const fd = try FontDialog.new(alloc, "Choose Font");
    fd.on_response = onFontResponse;
    g_font_dlg = fd;

    const fcn = try FileChooserNative.create(alloc, .{
        .action = .open,
        .title = "Open File",
        .accept_label = "Open",
        .cancel_label = "Cancel",
        .on_response = onFileResponse,
    });
    g_file_dlg = fcn;

    g_root = root;
    g_tree_alloc = alloc;
}

// ── 回调 ─────────────────────────────────────────────────────────────────────

fn onAlertResponse(self: *AlertDialog, idx: usize) void {
    _ = self;
    if (g_alert_label) |lbl| {
        lbl.text = std.fmt.bufPrint(&g_alert_buf, "Last response: button index {d}", .{idx}) catch "Last response";
    }
}

fn onPickColor(_: *Button) void {
    if (g_color_dlg) |cd| {
        cd.chooseRgba(math.Color.hex(0x3B82F6FF), null, null);
    }
}

fn onColorResponse(self: *ColorDialog, result: ColorDialogResult) void {
    _ = self;
    if (g_color_label) |lbl| {
        if (result == .ok) {
            const c = result.ok;
            lbl.text = std.fmt.bufPrint(&g_color_buf, "Color: #{X}{X}{X}{X}", .{ c.r, c.g, c.b, c.a }) catch "Color";
        } else {
            lbl.text = "Color: cancelled";
        }
    }
}

fn onPickFont(_: *Button) void {
    if (g_font_dlg) |fd| {
        fd.chooseFont(null, null);
    }
}

fn onFontResponse(self: *FontDialog, result: FontDialogResult) void {
    _ = self;
    if (g_font_label) |lbl| {
        if (result == .ok) {
            const f = result.ok;
            lbl.text = std.fmt.bufPrint(&g_font_buf, "Font: {s} {d}{s}{s}", .{
                f.family,
                f.size,
                if (f.bold) " Bold" else "",
                if (f.italic) " Italic" else "",
            }) catch "Font";
        } else {
            lbl.text = "Font: cancelled";
        }
    }
}

fn onPickFile(_: *Button) void {
    if (g_file_dlg) |d| {
        d.show(null);
    }
}

fn onFileResponse(self: *FileChooserNative, resp: FileChooserResponse) void {
    if (g_file_label) |lbl| {
        if (resp == .accept) {
            if (self.getFile()) |p| {
                lbl.text = std.fmt.bufPrint(&g_file_buf, "File: {s}", .{p}) catch "File";
            } else {
                lbl.text = "File: (none)";
            }
        } else {
            lbl.text = "File: cancelled";
        }
    }
}

fn destroyTree() void {
    if (g_root) |root| {
        root.destroy(g_tree_alloc orelse return);
        g_root = null;
    }
    const alloc = g_tree_alloc orelse return;
    if (g_color_dlg) |d| d.destroy(alloc);
    if (g_font_dlg) |d| d.destroy(alloc);
    if (g_file_dlg) |d| d.destroy();
    g_color_dlg = null;
    g_font_dlg = null;
    g_file_dlg = null;
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
