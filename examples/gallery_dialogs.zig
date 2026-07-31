//! zigui gallery - 对话框类控件 (Dialogs)
//!
//! 演示:
//!   - MessageDialog   消息对话框 (信息/警告/错误 + 按钮)
//!   - FileChooser     文件选择对话框
//!   - ColorChooserDialog  颜色选择对话框
//!   - AboutDialog     关于对话框
//!   - FontChooserDialog   字体选择对话框
//!   - Assistant       向导对话框
//!   - EmojiChooser    表情选择器
//!
//! 运行:  zig build run-gallery-dialogs
//! 点击任意 "Open X" 按钮都会以**真正独立的 OS 子窗口**形式弹出对应对话框
//! (每个子窗口拥有自己的 swapchain, 独立于主窗口, 可拖动/关闭);
//! 在子窗口内点击对话框按钮 (确定/取消/选择等) 会关闭该子窗口并回写状态栏。
//!
//! 实现说明:
//!   - 用 App.createSubWindow 创建子窗口, 把对话框控件作为该窗口的控件树根;
//!   - win.on_draw 里对该控件树做 performLayout + paintTree, 并把手势/键盘事件
//!     派发到该控件树 (子窗口的 mouse/key 状态由框架在 processSubWindowEvents 中更新);
//!   - 关闭采用 "置 should_close + 待关闭队列" 策略: 绝不在框架遍历 sub_windows
//!     映射期间调用 destroySubWindow (会破坏迭代器), 而是把 wid 记入待关闭队列,
//!     由主窗口 drawFrame 安全处理 (框架自身也会按 should_close 销毁 OS 窗口)。

const std = @import("std");
const builtin = @import("builtin");
const zigui = @import("zigui");

const is_macos = builtin.os.tag == .macos;
/// 子窗口类型按平台别名 (与 multi_window 示例一致, 避免非本平台类型被解析)。
const Window = if (is_macos) zigui.app.CocoaSubWindow else zigui.window.Window;

const math = zigui.math;
const styled_text = zigui.styled_text;
const widget = zigui.widget;
const pal = zigui.pal;
const Container = zigui.container.Container;
const MessageDialog = zigui.message_dialog.MessageDialog;
const MessageDialogResult = zigui.message_dialog.MessageDialogResult;
const FileChooser = zigui.file_chooser.FileChooser;
const ColorChooserDialog = zigui.color_chooser.ColorChooserDialog;
const AboutDialog = zigui.about_dialog.AboutDialog;
const FontChooserDialog = zigui.font_chooser.FontChooserDialog;
const FontDesc = zigui.font_chooser.FontDesc;
const Assistant = zigui.assistant.Assistant;
const EmojiChooser = zigui.emoji_chooser.EmojiChooser;
const Label = zigui.label.Label;
const Button = zigui.button.Button;

const theme_dark: zigui.theme.Theme = zigui.theme.dark;

var g_app: *zigui.app.App = undefined;
var g_alloc: ?std.mem.Allocator = null;
var g_root: ?*Container = null;
var g_prev_mouse_down: bool = false;

/// 子窗口注册表: wid -> 该子窗口的控件树根 (用于派发/绘制/销毁)
var g_windows: std.AutoHashMapUnmanaged(u32, *widget.Widget) = .{};
/// 每个子窗口上一帧的 mouse_down, 用于检测 released 事件
var g_prev_down: std.AutoHashMapUnmanaged(u32, bool) = .{};
/// 待关闭队列: 由主窗口 drawFrame 安全处理 (避免在框架遍历 sub_windows 期间销毁)
var g_pending_close: [16]u32 = undefined;
var g_pending_count: usize = 0;

var g_status_label: ?*Label = null;
var g_status_buf: [160]u8 = undefined;

pub fn main() !void {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();
    g_alloc = allocator;

    var app = try zigui.app.App.init(allocator, .{
        .title = "zigui Gallery - Dialogs",
        .width = 720,
        .height = 760,
    });
    defer app.deinit();
    g_app = app;

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

    const sub = try Label.create(alloc, "Click a button to open a dialog in a new OS window.", .{ .font_size = 13, .color = math.Color.hex(0x64748BFF) });
    try root.base.addChild(alloc, &sub.base);

    // 每个 "Open X" 按钮都会打开一个真正独立的子窗口
    const msg_btn = try Button.create(alloc, "Open MessageDialog", .{ .on_click = onOpenMsg });
    try addRow(alloc, root, "MessageDialog", msg_btn);

    const fc_btn = try Button.create(alloc, "Open FileChooser", .{ .on_click = onOpenFile });
    try addRow(alloc, root, "FileChooser", fc_btn);

    const cc_btn = try Button.create(alloc, "Open ColorChooser", .{ .on_click = onOpenColor });
    try addRow(alloc, root, "ColorChooser", cc_btn);

    const about_btn = try Button.create(alloc, "Open AboutDialog", .{ .on_click = onOpenAbout });
    try addRow(alloc, root, "AboutDialog", about_btn);

    const fcd_btn = try Button.create(alloc, "Open FontChooser", .{ .on_click = onOpenFont });
    try addRow(alloc, root, "FontChooser", fcd_btn);

    const asst_btn = try Button.create(alloc, "Open Assistant", .{ .on_click = onOpenAssistant });
    try addRow(alloc, root, "Assistant", asst_btn);

    const emoji_btn = try Button.create(alloc, "Open EmojiChooser", .{ .on_click = onOpenEmoji });
    try addRow(alloc, root, "EmojiChooser", emoji_btn);

    // status
    const status = try Label.create(alloc, "Status: idle", .{ .font_size = 13, .color = math.Color.hex(0x94A3B8FF) });
    status.base.layout_style.margin.top = 8;
    try root.base.addChild(alloc, &status.base);
    g_status_label = status;

    g_root = root;
}

// ── 打开各对话框 (每个都新建一个真实子窗口) ─────────────────────────────

fn onOpenMsg(_: *Button) void {
    const alloc = g_alloc orelse return;
    const d = MessageDialog.create(alloc, .{
        .kind = .info,
        .buttons = .ok_cancel,
        .title = "Confirm",
        .message = "This is a message dialog example.",
        .on_result = onMsgResult,
    }) catch return;
    d.show();
    hostDialog(alloc, "MessageDialog", 440, 240, &d.base);
}

fn onOpenFile(_: *Button) void {
    const alloc = g_alloc orelse return;
    const d = FileChooser.create(alloc, .{
        .mode = .open,
        .title = "Open File",
        .on_file_selected = onFileSelected,
        .on_cancel = onFileCancel,
    }) catch return;
    d.show();
    hostDialog(alloc, "FileChooser", 600, 440, &d.base);
}

fn onOpenColor(_: *Button) void {
    const alloc = g_alloc orelse return;
    const d = ColorChooserDialog.create(alloc, .{
        .title = "Pick a Color",
        .on_color_selected = onColorSelected,
        .on_cancel = onColorCancel,
    }) catch return;
    d.show();
    hostDialog(alloc, "ColorChooser", 560, 480, &d.base);
}

fn onOpenAbout(_: *Button) void {
    const alloc = g_alloc orelse return;
    const d = AboutDialog.create(alloc, .{
        .program_name = "zigui",
        .version = "0.16",
        .copyright = "© 2026 zigui contributors",
        .comments = "Cross-platform GPU-accelerated GUI framework.",
        .website = "https://github.com/zigui/zigui",
        .website_label = "Project Home",
        .authors = &[_][]const u8{"The zigui Team"},
        .on_close = onAboutClose,
    }) catch return;
    d.show();
    hostDialog(alloc, "AboutDialog", 480, 360, &d.base);
}

fn onOpenFont(_: *Button) void {
    const alloc = g_alloc orelse return;
    const d = FontChooserDialog.create(alloc, .{
        .title = "Pick a Font",
        .initial_family = "Sans",
        .initial_size = 14,
        .on_font_selected = onFontSelected,
        .on_cancel = onFontCancel,
    }) catch return;
    d.show();
    hostDialog(alloc, "FontChooser", 560, 480, &d.base);
}

fn onOpenAssistant(_: *Button) void {
    const alloc = g_alloc orelse return;
    const d = Assistant.create(alloc, .{
        .title = "Setup Assistant",
        .on_apply = onAssistantApply,
        .on_cancel = onAssistantCancel,
    }) catch return;
    const asst_page = Label.create(alloc, "Welcome! This assistant demonstrates a multi-page workflow.", .{
        .font_size = 14,
        .color = math.Color.hex(0xF1F5FFFF),
    }) catch return;
    _ = d.addPage("Welcome", &asst_page.base) catch return;
    d.show();
    hostDialog(alloc, "Assistant", 540, 440, &d.base);
}

fn onOpenEmoji(_: *Button) void {
    const alloc = g_alloc orelse return;
    const d = EmojiChooser.create(alloc, .{
        .on_emoji_selected = onEmojiSelected,
        .on_close = onEmojiClose,
    }) catch return;
    d.show();
    hostDialog(alloc, "EmojiChooser", 380, 460, &d.base);
}

/// 把对话框控件作为根, 托管到一个新创建的 OS 子窗口中。
fn hostDialog(alloc: std.mem.Allocator, title: []const u8, w: u32, h: u32, dlg: *widget.Widget) void {
    const wid = g_app.createSubWindow(title, w, h) catch {
        setStatus("无法创建子窗口: {s}", .{title});
        return;
    };
    g_app.setSubWindowTransientFor(wid, g_app.getMainWindowId());
    // 把 wid 存进对话框自身的 user_data (子控件另用 user_data, 不冲突), 供回调关闭本窗口
    dlg.user_data = @as(*anyopaque, @ptrFromInt(wid + 1));
    dlg.state.visible = true;
    g_windows.put(alloc, wid, dlg) catch {};
    if (g_app.getSubWindow(wid)) |win| {
        win.on_draw = subWindowDraw;
        win.on_close = subWindowClose;
    }
    setStatus("Opened: {s} (sub-window {})", .{ title, wid });
}

/// 子窗口绘制回调: 对托管控件树做布局 + 绘制, 并派发输入。
fn subWindowDraw(win: *Window) void {
    const r = win.getRenderer();
    const w: f32 = @floatFromInt(win.getWidth());
    const h: f32 = @floatFromInt(win.getHeight());

    // 兜底背景 (多数对话框会再画一层半透明遮罩 + 居中面板)
    r.fillRect(.{ .x = 0, .y = 0, .width = w, .height = h }, math.Color.hex(0x0F172AFF)) catch {};

    const root = g_windows.get(win.platform_window_id) orelse return;

    dispatchWindowInput(win, root);

    var ctx = widget.PaintContext{ .renderer = r, .theme = &theme_dark, .allocator = g_app.allocator };
    root.layout_style.width = .{ .px = w };
    root.layout_style.height = .{ .px = h };
    root.performLayout(&ctx, .{ .max_width = w, .max_height = h });
    root.paintTree(&ctx);

    // 框架只重置主窗口的瞬态输入标志, 子窗口的需自行重置, 否则点击会每帧重复派发
    win.mouse_clicked = false;
    win.right_clicked = false;
    win.scroll_delta = 0;
    win.key_hit = null;
}

/// 把子窗口的鼠标/键盘状态派发到托管控件树。
fn dispatchWindowInput(win: *Window, root: *widget.Widget) void {
    var ectx = widget.EventContext{ .mouse_x = win.mouse_x, .mouse_y = win.mouse_y };
    const mx: i32 = @intFromFloat(win.mouse_x);
    const my: i32 = @intFromFloat(win.mouse_y);

    var ev_move = pal.Event{ .mouse_move = .{ .window_id = win.platform_window_id, .x = mx, .y = my } };
    _ = root.dispatchEvent(&ev_move, &ectx);

    const prev = g_prev_down.get(win.platform_window_id) orelse false;
    if (win.mouse_clicked) {
        var ev = pal.Event{ .mouse_button = .{ .window_id = win.platform_window_id, .button = .left, .state = .pressed, .x = mx, .y = my } };
        _ = root.dispatchEvent(&ev, &ectx);
    }
    if (!win.mouse_down and prev) {
        var ev = pal.Event{ .mouse_button = .{ .window_id = win.platform_window_id, .button = .left, .state = .released, .x = mx, .y = my } };
        _ = root.dispatchEvent(&ev, &ectx);
    }
    g_prev_down.put(g_app.allocator, win.platform_window_id, win.mouse_down) catch {};

    if (win.key_hit) |key| {
        var ev = pal.Event{ .key = .{ .window_id = win.platform_window_id, .state = .pressed, .key = key, .modifiers = win.key_mods } };
        _ = root.dispatchEvent(&ev, &ectx);
    }
    // 注意: 框架的 Window.processEvents 会丢弃 text_input 事件,
    // 因此子窗口内的文本输入框 (如 EmojiChooser 搜索框) 目前无法接收键盘输入。
}

/// 子窗口被 OS 关闭按钮关闭时触发: 记入待关闭队列, 由主 drawFrame 安全清理。
fn subWindowClose(win: *Window) void {
    if (g_pending_count < g_pending_close.len) {
        g_pending_close[g_pending_count] = win.platform_window_id;
        g_pending_count += 1;
    }
}

/// 对话框自身的回调用它关闭"自己所在的子窗口": 置 should_close 并记入待关闭队列。
fn closeSelfWindow(w: *widget.Widget) void {
    if (w.user_data) |ud| {
        const wid = @as(u32, @intCast(@intFromPtr(ud) - 1));
        if (g_app.getSubWindow(wid)) |win| win.should_close = true;
        if (g_pending_count < g_pending_close.len) {
            g_pending_close[g_pending_count] = wid;
            g_pending_count += 1;
        }
    }
}

// ── 对话框回调: 先关闭子窗口, 再回写状态 ─────────────────────────────

fn onMsgResult(self: *MessageDialog, result: MessageDialogResult) void {
    closeSelfWindow(&self.base);
    setStatus("MessageDialog result: {s}", .{@tagName(result)});
}

fn onFileSelected(self: *FileChooser, path: []const u8) void {
    closeSelfWindow(&self.base);
    setStatus("File selected: {s}", .{path});
}

fn onFileCancel(self: *FileChooser) void {
    closeSelfWindow(&self.base);
    setStatus("File chooser cancelled", .{});
}

fn onColorSelected(self: *ColorChooserDialog, color: math.Color) void {
    closeSelfWindow(&self.base);
    const hex_val: u32 = (@as(u32, color.r) << 24) |
        (@as(u32, color.g) << 16) |
        (@as(u32, color.b) << 8) |
        @as(u32, color.a);
    setStatus("Color selected: #{X:0<8}", .{hex_val});
}

fn onColorCancel(self: *ColorChooserDialog) void {
    closeSelfWindow(&self.base);
    setStatus("Color chooser cancelled", .{});
}

fn onAboutClose(self: *AboutDialog) void {
    closeSelfWindow(&self.base);
    setStatus("AboutDialog closed", .{});
}

fn onFontSelected(self: *FontChooserDialog, desc: FontDesc) void {
    closeSelfWindow(&self.base);
    setStatus("Font: {s} {d}{s}{s}", .{ desc.family, desc.size, if (desc.bold) " bold" else "", if (desc.italic) " italic" else "" });
}

fn onFontCancel(self: *FontChooserDialog) void {
    closeSelfWindow(&self.base);
    setStatus("Font chooser cancelled", .{});
}

fn onAssistantApply(self: *Assistant) void {
    closeSelfWindow(&self.base);
    setStatus("Assistant applied", .{});
}

fn onAssistantCancel(self: *Assistant) void {
    closeSelfWindow(&self.base);
    setStatus("Assistant cancelled", .{});
}

fn onEmojiSelected(self: *EmojiChooser, emoji: []const u8) void {
    closeSelfWindow(&self.base);
    setStatus("Emoji selected: {s}", .{emoji});
}

fn onEmojiClose(self: *EmojiChooser) void {
    closeSelfWindow(&self.base);
    setStatus("EmojiChooser closed", .{});
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
    const alloc = g_alloc orelse return;
    // 销毁所有仍处于打开状态的子窗口控件树 (OS 窗口由 app.deinit 统一回收)
    var it = g_windows.iterator();
    while (it.next()) |entry| {
        entry.value_ptr.*.vtable.destroy(entry.value_ptr.*, alloc);
    }
    g_windows.deinit(alloc);
    g_prev_down.deinit(alloc);
    if (g_root) |root| {
        root.destroy(alloc);
        g_root = null;
    }
}

fn drawFrame(app: *zigui.app.App) void {
    const alloc = g_alloc orelse return;

    // 安全处理待关闭的子窗口 (此刻不在框架遍历 sub_windows 期间, 可自由操作)
    var i: usize = 0;
    while (i < g_pending_count) : (i += 1) {
        const wid = g_pending_close[i];
        if (g_windows.get(wid)) |root| {
            root.vtable.destroy(root, alloc);
            _ = g_windows.remove(wid);
        }
        _ = g_prev_down.remove(wid);
        // 框架会依据 should_close 自行 destroySubWindow (OS 窗口); 此处只清理控件树
    }
    g_pending_count = 0;

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
}
