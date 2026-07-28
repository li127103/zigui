//! zigui 新控件综合示例 - Linux 版本
//!
//! 展示: Separator / StatusBar / Expander / MessageDialog /
//!       SpinButton / ToggleButton / LinkButton / Grid
//!
//! 交互:
//!   - 点击 ToggleButton 切换状态
//!   - 点击 Expander 展开/折叠内容
//!   - SpinButton 上下按钮或键盘调节数值
//!   - LinkButton 点击后显示已访问状态
//!   - 按钮触发不同类型的 MessageDialog
//!   - Grid 展示表单式布局

const std = @import("std");
const zigui = @import("zigui");
const math = zigui.math;
const styled_text = zigui.styled_text;
const widget = zigui.widget;
const pal = zigui.pal;

const Container = zigui.container.Container;
const Label = zigui.label.Label;
const Button = zigui.button.Button;
const Separator = zigui.separator.Separator;
const StatusBar = zigui.status_bar.StatusBar;
const Expander = zigui.expander.Expander;
const MessageDialog = zigui.message_dialog.MessageDialog;
const MessageDialogKind = zigui.message_dialog.MessageDialogKind;
const MessageDialogButtons = zigui.message_dialog.MessageDialogButtons;
const MessageDialogResult = zigui.message_dialog.MessageDialogResult;
const SpinButton = zigui.spin_button.SpinButton;
const ToggleButton = zigui.toggle_button.ToggleButton;
const LinkButton = zigui.link_button.LinkButton;
const Grid = zigui.grid.Grid;

const theme_dark: zigui.theme.Theme = zigui.theme.dark;

// ── 全局状态 ──────────────────────────────────────────────────────────────

var g_root: ?*Container = null;
var g_alloc: ?std.mem.Allocator = null;
var g_status_bar: ?*StatusBar = null;
var g_status_buf: [128]u8 = undefined;
var g_dialog: ?*MessageDialog = null;
var g_spin_value: ?*Label = null;
var g_spin_buf: [32]u8 = undefined;
var g_toggle_label: ?*Label = null;
var g_toggle_buf: [32]u8 = undefined;
var g_frame: u32 = 0;
var g_prev_mouse_down: bool = false;

pub fn main() !void {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var app = try zigui.app.App.init(allocator, .{
        .title = "zigui - New Controls Demo (Linux)",
        .width = 900,
        .height = 640,
    });
    defer app.deinit();

    try buildTree(allocator);
    defer destroyTree();

    try app.run(&drawFrame);

    styled_text.deinitFontCache();
}

// ── 控件树构建 ──────────────────────────────────────────────────────────────

fn buildTree(alloc: std.mem.Allocator) !void {
    const root = try Container.create(alloc, .{
        .bg_color = math.Color.hex(0x0F172AFF),
        .direction = .column,
    });
    errdefer root.destroy(alloc);

    try buildHeader(root, alloc);
    try buildBody(root, alloc);
    try buildStatusBar(root, alloc);

    g_root = root;
    g_alloc = alloc;
}

fn buildHeader(root: *Container, alloc: std.mem.Allocator) !void {
    const header = try Container.create(alloc, .{
        .bg_color = math.Color.hex(0x1E293BFF),
        .direction = .row,
        .height = .{ .px = 52 },
        .padding = .{ .left = 20, .top = 14, .right = 20, .bottom = 0 },
    });
    try root.base.addChild(alloc, &header.base);

    const title = try Label.create(alloc, "New Controls Showcase", .{
        .font_size = 22,
        .font_weight = 700,
        .color = math.Color.hex(0xF8FAFCFF),
    });
    try header.base.addChild(alloc, &title.base);
}

fn buildBody(root: *Container, alloc: std.mem.Allocator) !void {
    const body = try Container.create(alloc, .{
        .direction = .row,
        .gap = .{ .width = 16, .height = 0 },
        .padding = .{ .left = 16, .top = 16, .right = 16, .bottom = 16 },
    });
    body.base.layout_style.flex_grow = 1;
    try root.base.addChild(alloc, &body.base);

    try buildLeftColumn(body, alloc);
    try buildRightColumn(body, alloc);
}

fn buildLeftColumn(body: *Container, alloc: std.mem.Allocator) !void {
    const col = try Container.create(alloc, .{
        .bg_color = math.Color.hex(0x1E293BFF),
        .corner_radius = 12,
        .direction = .column,
        .width = .{ .px = 380 },
        .padding = math.EdgeInsets.all(16),
        .gap = .{ .width = 0, .height = 12 },
    });
    try body.base.addChild(alloc, &col.base);

    try addSection(col, alloc, "Separator 分隔线");
    const sep_h = try Separator.create(alloc, .{ .orientation = .horizontal, .thickness = 1 });
    try col.base.addChild(alloc, &sep_h.base);

    const sep_row = try Container.create(alloc, .{
        .direction = .row,
        .height = .{ .px = 40 },
        .gap = .{ .width = 12, .height = 0 },
    });
    try col.base.addChild(alloc, &sep_row.base);

    const lbl_a = try Label.create(alloc, "Item A", .{ .color = math.Color.hex(0xE2E8F0FF) });
    lbl_a.base.layout_style.margin.top = 10;
    try sep_row.base.addChild(alloc, &lbl_a.base);

    const sep_v = try Separator.create(alloc, .{ .orientation = .vertical, .thickness = 1 });
    sep_v.base.layout_style.height = .{ .px = 24 };
    sep_v.base.layout_style.margin.top = 8;
    try sep_row.base.addChild(alloc, &sep_v.base);

    const lbl_b = try Label.create(alloc, "Item B", .{ .color = math.Color.hex(0xE2E8F0FF) });
    lbl_b.base.layout_style.margin.top = 10;
    try sep_row.base.addChild(alloc, &lbl_b.base);

    try addSection(col, alloc, "ToggleButton 切换按钮");
    const toggle_row = try Container.create(alloc, .{
        .direction = .row,
        .gap = .{ .width = 10, .height = 0 },
    });
    try col.base.addChild(alloc, &toggle_row.base);

    const toggle = try ToggleButton.create(alloc, "Auto Save", .{
        .active = true,
        .on_toggle = onToggleChange,
    });
    try toggle_row.base.addChild(alloc, &toggle.base);

    const toggle_state = try Label.create(alloc, "状态: ON", .{
        .font_size = 13,
        .color = math.Color.hex(0x94A3B8FF),
    });
    toggle_state.base.layout_style.margin.top = 9;
    try toggle_row.base.addChild(alloc, &toggle_state.base);
    g_toggle_label = toggle_state;

    try addSection(col, alloc, "SpinButton 数字步进");
    const spin_row = try Container.create(alloc, .{
        .direction = .row,
        .gap = .{ .width = 12, .height = 0 },
    });
    try col.base.addChild(alloc, &spin_row.base);

    const spin = try SpinButton.create(alloc, .{
        .value = 50,
        .min = 0,
        .max = 100,
        .step = 5,
        .digits = 0,
        .on_change = onSpinChange,
    });
    spin.base.layout_style.width = .{ .px = 140 };
    try spin_row.base.addChild(alloc, &spin.base);

    const spin_val = try Label.create(alloc, "值: 50", .{
        .font_size = 13,
        .color = math.Color.hex(0x94A3B8FF),
    });
    spin_val.base.layout_style.margin.top = 9;
    try spin_row.base.addChild(alloc, &spin_val.base);
    g_spin_value = spin_val;

    try addSection(col, alloc, "LinkButton 链接按钮");
    const link = try LinkButton.create(alloc, "访问 zigui 项目主页", .{
        .url = "https://github.com/zigui/zigui",
        .font_size = 14,
        .on_click = onLinkClick,
    });
    try col.base.addChild(alloc, &link.base);

    const link2 = try LinkButton.create(alloc, "查看文档 (已访问)", .{
        .url = "https://docs.zigui.dev",
        .font_size = 13,
        .underline = true,
    });
    link2.setVisited(true);
    try col.base.addChild(alloc, &link2.base);

    try addSection(col, alloc, "Expander 折叠面板");
    const expander = try Expander.create(alloc, "高级设置", .{
        .expanded = true,
        .header_height = 36,
    });
    try col.base.addChild(alloc, &expander.base);

    const exp_content = try Container.create(alloc, .{
        .direction = .column,
        .gap = .{ .width = 0, .height = 8 },
        .padding = .{ .left = 8, .top = 8, .right = 8, .bottom = 12 },
    });
    try expander.base.addChild(alloc, &exp_content.base);

    const exp_lbl1 = try Label.create(alloc, "• 启用硬件加速", .{
        .font_size = 13,
        .color = math.Color.hex(0x94A3B8FF),
    });
    try exp_content.base.addChild(alloc, &exp_lbl1.base);

    const exp_lbl2 = try Label.create(alloc, "• 自动保存间隔: 30秒", .{
        .font_size = 13,
        .color = math.Color.hex(0x94A3B8FF),
    });
    try exp_content.base.addChild(alloc, &exp_lbl2.base);

    const exp_lbl3 = try Label.create(alloc, "• 显示行号", .{
        .font_size = 13,
        .color = math.Color.hex(0x94A3B8FF),
    });
    try exp_content.base.addChild(alloc, &exp_lbl3.base);
}

fn buildRightColumn(body: *Container, alloc: std.mem.Allocator) !void {
    const col = try Container.create(alloc, .{
        .direction = .column,
        .gap = .{ .width = 0, .height = 12 },
    });
    col.base.layout_style.flex_grow = 1;
    try body.base.addChild(alloc, &col.base);

    try addSection(col, alloc, "Grid 网格布局 (表单示例)");
    const grid_card = try Container.create(alloc, .{
        .bg_color = math.Color.hex(0x1E293BFF),
        .corner_radius = 12,
        .direction = .column,
        .padding = math.EdgeInsets.all(16),
    });
    try col.base.addChild(alloc, &grid_card.base);

    const grid = try Grid.create(alloc, .{
        .rows = 4,
        .cols = 2,
        .row_gap = 10,
        .col_gap = 12,
    });
    grid.base.layout_style.width = .{ .auto = {} };
    try grid_card.base.addChild(alloc, &grid.base);

    const field_labels = [_][]const u8{ "用户名:", "邮箱:", "密码:", "确认密码:" };
    const field_placeholders = [_][]const u8{ "请输入用户名", "user@example.com", "••••••••", "••••••••" };

    for (field_labels, 0..) |lbl_text, i| {
        const row: usize = i;
        const label = try Label.create(alloc, lbl_text, .{
            .font_size = 13,
            .color = math.Color.hex(0xE2E8F0FF),
        });
        label.base.layout_style.margin.top = 7;
        label.base.layout_style.width = .{ .px = 80 };
        try grid.addChild(&label.base, row, 0);

        const field = try Container.create(alloc, .{
            .bg_color = math.Color.hex(0x0F172AFF),
            .corner_radius = 6,
            .height = .{ .px = 32 },
            .padding = .{ .left = 10, .top = 7, .right = 10, .bottom = 0 },
            .border_width = 1,
            .border_color = math.Color.hex(0x334155FF),
        });
        try grid.addChild(&field.base, row, 1);

        const ph = try Label.create(alloc, field_placeholders[i], .{
            .font_size = 13,
            .color = math.Color.hex(0x64748BFF),
        });
        try field.base.addChild(alloc, &ph.base);
    }

    const submit_btn = try Button.create(alloc, "提交", .{
        .bg_color = math.Color.hex(0x3B82F6FF),
        .bg_hover = math.Color.hex(0x2563EBFF),
        .bg_pressed = math.Color.hex(0x1D4ED8FF),
        .corner_radius = 6,
        .on_click = onSubmitClick,
    });
    submit_btn.base.layout_style.margin.top = 8;
    try grid.addChild(&submit_btn.base, 4, 1);

    try addSection(col, alloc, "MessageDialog 消息对话框");
    const dialog_card = try Container.create(alloc, .{
        .bg_color = math.Color.hex(0x1E293BFF),
        .corner_radius = 12,
        .direction = .column,
        .padding = math.EdgeInsets.all(16),
        .gap = .{ .width = 0, .height = 10 },
    });
    try col.base.addChild(alloc, &dialog_card.base);

    const btn_row1 = try Container.create(alloc, .{
        .direction = .row,
        .gap = .{ .width = 8, .height = 0 },
    });
    try dialog_card.base.addChild(alloc, &btn_row1.base);

    const info_btn = try Button.create(alloc, "信息提示", .{
        .bg_color = math.Color.hex(0x3B82F6FF),
        .bg_hover = math.Color.hex(0x2563EBFF),
        .corner_radius = 6,
        .on_click = onInfoDialog,
    });
    info_btn.base.layout_style.flex_grow = 1;
    try btn_row1.base.addChild(alloc, &info_btn.base);

    const warn_btn = try Button.create(alloc, "警告提示", .{
        .bg_color = math.Color.hex(0xF59E0BFF),
        .bg_hover = math.Color.hex(0xD97706FF),
        .corner_radius = 6,
        .on_click = onWarnDialog,
    });
    warn_btn.base.layout_style.flex_grow = 1;
    try btn_row1.base.addChild(alloc, &warn_btn.base);

    const btn_row2 = try Container.create(alloc, .{
        .direction = .row,
        .gap = .{ .width = 8, .height = 0 },
    });
    try dialog_card.base.addChild(alloc, &btn_row2.base);

    const err_btn = try Button.create(alloc, "错误提示", .{
        .bg_color = math.Color.hex(0xEF4444FF),
        .bg_hover = math.Color.hex(0xDC2626FF),
        .corner_radius = 6,
        .on_click = onErrDialog,
    });
    err_btn.base.layout_style.flex_grow = 1;
    try btn_row2.base.addChild(alloc, &err_btn.base);

    const quest_btn = try Button.create(alloc, "确认询问", .{
        .bg_color = math.Color.hex(0x8B5CF6FF),
        .bg_hover = math.Color.hex(0x7C3AEDFF),
        .corner_radius = 6,
        .on_click = onQuestionDialog,
    });
    quest_btn.base.layout_style.flex_grow = 1;
    try btn_row2.base.addChild(alloc, &quest_btn.base);

    const dialog_hint = try Label.create(alloc, "点击按钮测试不同类型的对话框", .{
        .font_size = 12,
        .color = math.Color.hex(0x64748BFF),
    });
    dialog_hint.base.layout_style.margin.top = 4;
    try dialog_card.base.addChild(alloc, &dialog_hint.base);
}

fn buildStatusBar(root: *Container, alloc: std.mem.Allocator) !void {
    const sb = try StatusBar.create(alloc, .{
        .text = "就绪 - 欢迎使用 zigui 新控件演示",
        .height = 28,
    });
    try root.base.addChild(alloc, &sb.base);
    g_status_bar = sb;
}

fn addSection(parent: *Container, alloc: std.mem.Allocator, text: []const u8) !void {
    const lbl = try Label.create(alloc, text, .{
        .font_size = 12,
        .font_weight = 700,
        .color = math.Color.hex(0x64748BFF),
    });
    lbl.base.layout_style.margin.top = 4;
    try parent.base.addChild(alloc, &lbl.base);
}

fn destroyTree() void {
    if (g_root) |root| {
        root.destroy(g_alloc orelse return);
        g_root = null;
    }
}

// ── 回调 ──────────────────────────────────────────────────────────────────

fn onToggleChange(tb: *ToggleButton, active: bool) void {
    if (g_toggle_label) |lbl| {
        lbl.text = std.fmt.bufPrint(&g_toggle_buf, "状态: {s}", .{if (active) "ON" else "OFF"}) catch "状态";
    }
    if (g_status_bar) |sb| {
        sb.setText(if (active) "自动保存: 已开启" else "自动保存: 已关闭") catch {};
    }
    _ = tb;
}

fn onSpinChange(sb: *SpinButton, value: f64) void {
    if (g_spin_value) |lbl| {
        lbl.text = std.fmt.bufPrint(&g_spin_buf, "值: {d}", .{@as(i32, @intFromFloat(value))}) catch "值";
    }
    _ = sb;
}

fn onLinkClick(lb: *LinkButton) void {
    if (g_status_bar) |sb| {
        sb.setText("链接已点击: 正在打开浏览器...") catch {};
    }
    _ = lb;
}

fn onSubmitClick(btn: *Button) void {
    if (g_status_bar) |sb| {
        sb.setText("表单已提交 (演示)") catch {};
    }
    _ = btn;
}

fn onInfoDialog(btn: *Button) void {
    showDialog(.info, "操作成功", "您的更改已成功保存。\n系统将在 3 秒后自动刷新。", .ok);
    _ = btn;
}

fn onWarnDialog(btn: *Button) void {
    showDialog(.warning, "磁盘空间不足", "当前磁盘剩余空间不足 10%。\n建议清理不必要的文件以释放空间。", .ok_cancel);
    _ = btn;
}

fn onErrDialog(btn: *Button) void {
    showDialog(.err, "连接失败", "无法连接到服务器。\n请检查您的网络连接后重试。", .ok);
    _ = btn;
}

fn onQuestionDialog(btn: *Button) void {
    showDialog(.question, "确认删除", "您确定要删除选中的项目吗？\n此操作不可撤销。", .yes_no);
    _ = btn;
}

fn showDialog(kind: MessageDialogKind, title: []const u8, message: []const u8, buttons: MessageDialogButtons) void {
    const alloc = g_alloc orelse return;
    if (g_dialog != null) return;

    const dlg = MessageDialog.create(alloc, .{
        .kind = kind,
        .buttons = buttons,
        .title = title,
        .message = message,
        .dialog_width = 360,
        .on_result = onDialogResult,
    }) catch return;

    g_dialog = dlg;
    if (g_status_bar) |sb| {
        sb.setText("对话框已打开") catch {};
    }
}

fn onDialogResult(dlg: *MessageDialog, result: MessageDialogResult) void {
    if (g_status_bar) |sb| {
        const result_str = switch (result) {
            .ok => "OK",
            .cancel => "Cancel",
            .yes => "Yes",
            .no => "No",
        };
        sb.setText(std.fmt.bufPrint(&g_status_buf, "对话框结果: {s}", .{result_str}) catch "对话框已关闭") catch {};
    }
    g_dialog = null;
    _ = dlg;
}

// ── 每帧: 输入分发 + 布局 + 绘制 ────────────────────────────────────────

fn drawFrame(app: *zigui.app.App) void {
    g_frame += 1;
    const root = g_root orelse return;
    const fb = app.getFramebufferSize();
    const w: f32 = @floatFromInt(fb.width);
    const h: f32 = @floatFromInt(fb.height);

    dispatchInput(app);

    root.base.layout_style.width = .{ .px = w };
    root.base.layout_style.height = .{ .px = h };

    var ctx = widget.PaintContext{
        .renderer = app.getRenderer(),
        .theme = &theme_dark,
        .allocator = app.allocator,
    };
    root.base.performLayout(&ctx, .{ .max_width = w, .max_height = h });
    root.base.paintTree(&ctx);

    if (g_dialog) |dlg| {
        dlg.base.rect.x = (w - 360) / 2.0;
        dlg.base.rect.y = (h - 200) / 2.0;
        dlg.base.performLayout(&ctx, .{ .max_width = 360, .max_height = h });
        dlg.base.paintTree(&ctx);
    }
}

fn dispatchInput(app: *zigui.app.App) void {
    const root = g_root orelse return;
    var ectx = widget.EventContext{ .mouse_x = app.mouse_x, .mouse_y = app.mouse_y };
    const mx: i32 = @intFromFloat(app.mouse_x);
    const my: i32 = @intFromFloat(app.mouse_y);

    if (g_dialog) |dlg| {
        var ev_move = pal.Event{ .mouse_move = .{ .window_id = 0, .x = mx, .y = my } };
        _ = dlg.base.dispatchEvent(&ev_move, &ectx);

        if (app.mouse_clicked) {
            var ev = pal.Event{ .mouse_button = .{ .window_id = 0, .button = .left, .state = .pressed, .x = mx, .y = my } };
            _ = dlg.base.dispatchEvent(&ev, &ectx);
        }
        const md = app.mouse_down;
        if (!md and g_prev_mouse_down) {
            var ev = pal.Event{ .mouse_button = .{ .window_id = 0, .button = .left, .state = .released, .x = mx, .y = my } };
            _ = dlg.base.dispatchEvent(&ev, &ectx);
        }
        g_prev_mouse_down = md;
        return;
    }

    var ev_move = pal.Event{ .mouse_move = .{ .window_id = 0, .x = mx, .y = my } };
    _ = root.base.dispatchEvent(&ev_move, &ectx);

    if (app.mouse_clicked) {
        var ev = pal.Event{ .mouse_button = .{ .window_id = 0, .button = .left, .state = .pressed, .x = mx, .y = my } };
        _ = root.base.dispatchEvent(&ev, &ectx);
    }
    const md = app.mouse_down;
    if (!md and g_prev_mouse_down) {
        var ev = pal.Event{ .mouse_button = .{ .window_id = 0, .button = .left, .state = .released, .x = mx, .y = my } };
        _ = root.base.dispatchEvent(&ev, &ectx);
    }
    g_prev_mouse_down = md;

    if (app.scroll_delta != 0) {
        var ev = pal.Event{ .scroll = .{ .window_id = 0, .axis = .vertical, .delta = app.scroll_delta } };
        _ = root.base.dispatchEvent(&ev, &ectx);
    }

    if (app.key_hit) |key| {
        if (key == .tab) {
            if (app.key_mods.shift) {
                _ = root.base.focusPrev();
            } else {
                _ = root.base.focusNext();
            }
            return;
        }
        var ev = pal.Event{ .key = .{ .window_id = 0, .state = .pressed, .key = key, .modifiers = app.key_mods } };
        _ = root.base.dispatchEvent(&ev, &ectx);
    }
}
