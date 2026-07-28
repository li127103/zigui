//! ZigUI 新控件综合演示 (P2 阶段)
//!
//! 展示: SearchBar / Scale / Assistant / FontButton / ColorButton / InfoBar
//!
//! 交互:
//!   - Ctrl+F 显示/隐藏搜索栏
//!   - Scale 拖动调节数值
//!   - 点击按钮打开 Assistant 向导
//!   - FontButton 点击选择字体
//!   - ColorButton 点击选择颜色
//!   - InfoBar 显示不同类型的提示信息

const std = @import("std");
const zigui = @import("zigui");
const math = zigui.math;
const styled_text = zigui.styled_text;
const widget = zigui.widget;
const pal = zigui.pal;

const Container = zigui.container.Container;
const Label = zigui.label.Label;
const Button = zigui.button.Button;
const SearchBar = zigui.search_bar.SearchBar;
const Scale = zigui.scale.Scale;
const Assistant = zigui.assistant.Assistant;
const FontButton = zigui.font_button.FontButton;
const FontDesc = zigui.font_chooser.FontDesc;
const ColorButton = zigui.color_button.ColorButton;
const InfoBar = zigui.info_bar.InfoBar;
const InfoBarKind = zigui.info_bar.InfoBarKind;
const Switch = zigui.switch_widget.Switch;
const Spinner = zigui.spinner.Spinner;

var gpa: std.heap.DebugAllocator(.{}) = .init;

var g_app: *zigui.app.App = undefined;
var g_root: *Container = undefined;
var g_search_bar: *SearchBar = undefined;
var g_scale_value_label: *Label = undefined;
var g_scale_buf: [32]u8 = undefined;
var g_assistant: *Assistant = undefined;
var g_info_bar: *InfoBar = undefined;
var g_status_label: *Label = undefined;
var g_status_buf: [128]u8 = undefined;
var g_spinner: *Spinner = undefined;
var g_switch_label: *Label = undefined;

pub fn main() !void {
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    g_app = try zigui.app.App.init(allocator, .{
        .title = "ZigUI - New Widgets Showcase",
        .width = 900,
        .height = 640,
    });
    defer g_app.deinit();

    try buildTree(allocator);

    // 注册全局快捷键 Ctrl+F 切换搜索栏
    try g_app.shortcuts.add(
        .f,
        .{ .ctrl = true },
        onToggleSearchShortcut,
        null,
    );

    try g_app.run(&drawFrame);

    styled_text.deinitFontCache();
}

fn onToggleSearchShortcut(_: ?*anyopaque) void {
    const visible = g_search_bar.getRevealChild();
    g_search_bar.setRevealChild(!visible);
}

// ── 控件树构建 ──────────────────────────────────────────────────────────────

fn buildTree(alloc: std.mem.Allocator) !void {
    const root = try Container.create(alloc, .{
        .bg_color = math.Color.hex(0x0F172AFF),
        .direction = .column,
    });
    g_root = root;

    // 搜索栏 (顶部)
    g_search_bar = try SearchBar.create(alloc, .{
        .placeholder = "搜索控件、功能...",
        .show_close_button = true,
        .on_search_changed = onSearchChanged,
        .on_close = onSearchClose,
    });
    try root.base.addChild(alloc, &g_search_bar.base);

    // 头部
    try buildHeader(root, alloc);

    // 主体
    try buildBody(root, alloc);

    // 状态栏
    try buildStatusBar(root, alloc);

    // InfoBar (默认隐藏)
    g_info_bar = try InfoBar.create(alloc, "提示: 按 Ctrl+F 快速打开搜索栏", .info, .{
        .on_close = onInfoBarClose,
    });
    g_info_bar.visible = false;
    try root.base.addChild(alloc, &g_info_bar.base);

    // Assistant (默认隐藏)
    try buildAssistant(alloc);
    try root.base.addChild(alloc, &g_assistant.base);
}

fn buildHeader(root: *Container, alloc: std.mem.Allocator) !void {
    const header = try Container.create(alloc, .{
        .bg_color = math.Color.hex(0x1E293BFF),
        .direction = .row,
        .height = .{ .px = 56 },
        .padding = .{ .left = 20, .top = 12, .right = 20, .bottom = 12 },
        .gap = .{ .width = 12, .height = 0 },
    });
    try root.base.addChild(alloc, &header.base);

    const title = try Label.create(alloc, "New Widgets Showcase", .{
        .font_size = 20,
        .font_weight = 700,
        .color = math.Color.hex(0xF8FAFCFF),
    });
    title.base.layout_style.flex_grow = 1;
    try header.base.addChild(alloc, &title.base);

    const search_btn = try Button.create(alloc, "🔍 搜索 (Ctrl+F)", .{
        .on_click = onSearchBtnClick,
        .corner_radius = 6,
    });
    try header.base.addChild(alloc, &search_btn.base);
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
        .width = .{ .px = 400 },
        .padding = math.EdgeInsets.all(16),
        .gap = .{ .width = 0, .height = 16 },
    });
    try body.base.addChild(alloc, &col.base);

    // SearchBar 演示
    try addSectionTitle(col, alloc, "SearchBar 搜索栏");
    const search_info = try Label.create(alloc, "点击右上角搜索按钮或按 Ctrl+F 打开搜索栏", .{
        .font_size = 12,
        .color = math.Color.hex(0x94A3B8FF),
    });
    try col.base.addChild(alloc, &search_info.base);

    // Scale 演示
    try addSectionTitle(col, alloc, "Scale 带刻度滑块");
    const scale = try Scale.create(alloc, .{
        .value = 50,
        .min = 0,
        .max = 100,
        .step = 1,
        .tick_count = 11,
        .show_value = true,
        .show_min_max = true,
        .on_change = onScaleChanged,
    });
    try col.base.addChild(alloc, &scale.base);

    g_scale_value_label = try Label.create(alloc, "当前值: 50", .{
        .font_size = 13,
        .color = math.Color.hex(0x94A3B8FF),
    });
    try col.base.addChild(alloc, &g_scale_value_label.base);

    // FontButton 演示
    try addSectionTitle(col, alloc, "FontButton 字体选择");
    const font_row = try Container.create(alloc, .{
        .direction = .row,
        .gap = .{ .width = 12, .height = 0 },
    });
    try col.base.addChild(alloc, &font_row.base);

    const font_btn = try FontButton.create(alloc, .{
        .family = "Sans",
        .size = 14,
        .on_font_changed = onFontChanged,
    });
    try font_row.base.addChild(alloc, &font_btn.base);

    const font_desc = try Label.create(alloc, "点击选择字体", .{
        .font_size = 12,
        .color = math.Color.hex(0x94A3B8FF),
    });
    font_desc.base.layout_style.flex_grow = 1;
    font_desc.base.layout_style.margin.top = 8;
    try font_row.base.addChild(alloc, &font_desc.base);

    // ColorButton 演示
    try addSectionTitle(col, alloc, "ColorButton 颜色选择");
    const color_row = try Container.create(alloc, .{
        .direction = .row,
        .gap = .{ .width = 12, .height = 0 },
    });
    try col.base.addChild(alloc, &color_row.base);

    const color_btn = try ColorButton.create(alloc, .{
        .color = math.Color.hex(0x3B82F6FF),
        .on_color_changed = onColorChanged,
        .button_size = 32,
        .corner_radius = 6,
    });
    try color_row.base.addChild(alloc, &color_btn.base);

    const color_desc = try Label.create(alloc, "点击选择颜色", .{
        .font_size = 12,
        .color = math.Color.hex(0x94A3B8FF),
    });
    color_desc.base.layout_style.flex_grow = 1;
    color_desc.base.layout_style.margin.top = 8;
    try color_row.base.addChild(alloc, &color_desc.base);

    // Switch 演示
    try addSectionTitle(col, alloc, "Switch 开关");
    const switch_row = try Container.create(alloc, .{
        .direction = .row,
        .gap = .{ .width = 12, .height = 0 },
    });
    try col.base.addChild(alloc, &switch_row.base);

    g_switch_label = try Label.create(alloc, "开关状态: 关", .{
        .font_size = 13,
        .color = math.Color.hex(0xE2E8F0FF),
    });
    g_switch_label.base.layout_style.flex_grow = 1;
    g_switch_label.base.layout_style.margin.top = 4;
    try switch_row.base.addChild(alloc, &g_switch_label.base);

    const switch_widget = try Switch.create(alloc, .{
        .on_toggle = onSwitchToggle,
    });
    try switch_row.base.addChild(alloc, &switch_widget.base);

    // Spinner 演示
    try addSectionTitle(col, alloc, "Spinner 加载动画");
    const spinner_row = try Container.create(alloc, .{
        .direction = .row,
        .gap = .{ .width = 12, .height = 0 },
    });
    try col.base.addChild(alloc, &spinner_row.base);

    g_spinner = try Spinner.create(alloc, .{
        .size = 28,
        .active = true,
    });
    try spinner_row.base.addChild(alloc, &g_spinner.base);

    const spinner_toggle_btn = try Button.create(alloc, "暂停/播放", .{
        .on_click = onToggleSpinner,
        .corner_radius = 6,
        .padding_v = 6,
    });
    spinner_toggle_btn.base.layout_style.flex_grow = 1;
    try spinner_row.base.addChild(alloc, &spinner_toggle_btn.base);
}

fn buildRightColumn(body: *Container, alloc: std.mem.Allocator) !void {
    const col = try Container.create(alloc, .{
        .bg_color = math.Color.hex(0x1E293BFF),
        .corner_radius = 12,
        .direction = .column,
        .padding = math.EdgeInsets.all(16),
        .gap = .{ .width = 0, .height = 16 },
    });
    col.base.layout_style.flex_grow = 1;
    try body.base.addChild(alloc, &col.base);

    // Assistant 演示
    try addSectionTitle(col, alloc, "Assistant 向导对话框");
    const assistant_desc = try Label.create(alloc, "多步骤向导，带前进/后退/完成按钮和进度指示", .{
        .font_size = 12,
        .color = math.Color.hex(0x94A3B8FF),
    });
    try col.base.addChild(alloc, &assistant_desc.base);

    const open_assistant_btn = try Button.create(alloc, "打开向导 (Assistant)", .{
        .on_click = onOpenAssistant,
        .corner_radius = 6,
    });
    try col.base.addChild(alloc, &open_assistant_btn.base);

    // InfoBar 演示
    try addSectionTitle(col, alloc, "InfoBar 信息栏");
    const infobar_desc = try Label.create(alloc, "不同类型的信息提示栏", .{
        .font_size = 12,
        .color = math.Color.hex(0x94A3B8FF),
    });
    try col.base.addChild(alloc, &infobar_desc.base);

    const infobar_btn_row = try Container.create(alloc, .{
        .direction = .row,
        .gap = .{ .width = 8, .height = 0 },
    });
    try col.base.addChild(alloc, &infobar_btn_row.base);

    const info_btn = try Button.create(alloc, "Info", .{
        .on_click = onShowInfo,
        .corner_radius = 6,
        .padding_v = 6,
    });
    try infobar_btn_row.base.addChild(alloc, &info_btn.base);

    const warning_btn = try Button.create(alloc, "Warning", .{
        .on_click = onShowWarning,
        .corner_radius = 6,
        .padding_v = 6,
    });
    try infobar_btn_row.base.addChild(alloc, &warning_btn.base);

    const error_btn = try Button.create(alloc, "Error", .{
        .on_click = onShowError,
        .corner_radius = 6,
        .padding_v = 6,
    });
    try infobar_btn_row.base.addChild(alloc, &error_btn.base);

    const question_btn = try Button.create(alloc, "Question", .{
        .on_click = onShowQuestion,
        .corner_radius = 6,
        .padding_v = 6,
    });
    try infobar_btn_row.base.addChild(alloc, &question_btn.base);

    // 其他选项
    try addSectionTitle(col, alloc, "提示");
    const hint_label = try Label.create(alloc, "按 Ctrl+F 快速打开搜索栏\n按 ESC 关闭搜索栏或对话框", .{
        .font_size = 12,
        .color = math.Color.hex(0x94A3B8FF),
    });
    try col.base.addChild(alloc, &hint_label.base);

    // 占位区域
    const spacer = try Container.create(alloc, .{ .direction = .column });
    spacer.base.layout_style.flex_grow = 1;
    try col.base.addChild(alloc, &spacer.base);
}

fn buildAssistant(alloc: std.mem.Allocator) !void {
    g_assistant = try Assistant.create(alloc, .{
        .title = "设置向导",
        .on_apply = onAssistantApply,
        .on_cancel = onAssistantCancel,
        .on_prepare = onAssistantPrepare,
    });

    // 页面 1: 欢迎
    const page1_content = try Container.create(alloc, .{
        .direction = .column,
        .gap = .{ .width = 0, .height = 12 },
    });
    const p1_title = try Label.create(alloc, "欢迎使用设置向导", .{
        .font_size = 16,
        .font_weight = 600,
        .color = math.Color.hex(0xF1F5FFFF),
    });
    try page1_content.base.addChild(alloc, &p1_title.base);
    const p1_desc = try Label.create(alloc, "这个向导将帮助您完成基本设置。\n点击\"下一步\"继续。", .{
        .font_size = 13,
        .color = math.Color.hex(0x94A3B8FF),
    });
    try page1_content.base.addChild(alloc, &p1_desc.base);
    _ = try g_assistant.addPage("欢迎", &page1_content.base);

    // 页面 2: 外观设置
    const page2_content = try Container.create(alloc, .{
        .direction = .column,
        .gap = .{ .width = 0, .height = 12 },
    });
    const p2_title = try Label.create(alloc, "外观设置", .{
        .font_size = 16,
        .font_weight = 600,
        .color = math.Color.hex(0xF1F5FFFF),
    });
    try page2_content.base.addChild(alloc, &p2_title.base);
    const p2_desc = try Label.create(alloc, "选择您喜欢的主题和配色方案。", .{
        .font_size = 13,
        .color = math.Color.hex(0x94A3B8FF),
    });
    try page2_content.base.addChild(alloc, &p2_desc.base);
    _ = try g_assistant.addPage("外观", &page2_content.base);

    // 页面 3: 完成
    const page3_content = try Container.create(alloc, .{
        .direction = .column,
        .gap = .{ .width = 0, .height = 12 },
    });
    const p3_title = try Label.create(alloc, "设置完成！", .{
        .font_size = 16,
        .font_weight = 600,
        .color = math.Color.hex(0x22C55EFF),
    });
    try page3_content.base.addChild(alloc, &p3_title.base);
    const p3_desc = try Label.create(alloc, "恭喜！您已完成所有设置。\n点击\"完成\"按钮应用更改。", .{
        .font_size = 13,
        .color = math.Color.hex(0x94A3B8FF),
    });
    try page3_content.base.addChild(alloc, &p3_desc.base);
    _ = try g_assistant.addPage("完成", &page3_content.base);
}

fn buildStatusBar(root: *Container, alloc: std.mem.Allocator) !void {
    const bar = try Container.create(alloc, .{
        .bg_color = math.Color.hex(0x0F172AFF),
        .direction = .row,
        .height = .{ .px = 28 },
        .padding = .{ .left = 12, .top = 6, .right = 12, .bottom = 6 },
    });
    try root.base.addChild(alloc, &bar.base);

    g_status_label = try Label.create(alloc, "就绪", .{
        .font_size = 11,
        .color = math.Color.hex(0x64748BFF),
    });
    g_status_label.base.layout_style.flex_grow = 1;
    try bar.base.addChild(alloc, &g_status_label.base);

    const hint = try Label.create(alloc, "Ctrl+F 搜索", .{
        .font_size = 11,
        .color = math.Color.hex(0x64748BFF),
    });
    try bar.base.addChild(alloc, &hint.base);
}

// ── 辅助函数 ────────────────────────────────────────────────────────────────

fn addSectionTitle(parent: *Container, alloc: std.mem.Allocator, text: []const u8) !void {
    const label = try Label.create(alloc, text, .{
        .font_size = 13,
        .font_weight = 600,
        .color = math.Color.hex(0xE2E8F0FF),
    });
    label.base.layout_style.margin.top = 4;
    try parent.base.addChild(alloc, &label.base);
}

fn setStatus(text: []const u8) void {
    g_status_label.setText(text);
    g_app.invalidate();
}

// ── 回调函数 ────────────────────────────────────────────────────────────────

fn onSearchBtnClick(_: *Button) void {
    const visible = g_search_bar.getRevealChild();
    g_search_bar.setRevealChild(!visible);
}

fn onSearchChanged(_: *SearchBar, text: []const u8) void {
    const msg = std.fmt.bufPrint(&g_status_buf, "搜索: {s}", .{text}) catch "搜索";
    setStatus(msg);
}

fn onSearchClose(_: *SearchBar) void {
    setStatus("搜索已关闭");
}

fn onScaleChanged(_: *Scale, value: f32) void {
    const text = std.fmt.bufPrint(&g_scale_buf, "当前值: {d:.0}", .{value}) catch "当前值";
    g_scale_value_label.setText(text);
    const msg = std.fmt.bufPrint(&g_status_buf, "Scale 值: {d:.1}", .{value}) catch "Scale";
    setStatus(msg);
}

fn onFontChanged(btn: *FontButton, _: FontDesc) void {
    _ = btn;
    setStatus("字体已更改");
}

fn onColorChanged(_: *ColorButton, _: math.Color) void {
    setStatus("颜色已更改");
}

fn onSwitchToggle(_: *Switch, active: bool) void {
    if (active) {
        g_switch_label.setText("开关状态: 开");
    } else {
        g_switch_label.setText("开关状态: 关");
    }
    const msg = std.fmt.bufPrint(&g_status_buf, "开关: {s}", .{if (active) "开" else "关"}) catch "开关";
    setStatus(msg);
}

fn onToggleSpinner(_: *Button) void {
    if (g_spinner.active) {
        g_spinner.stop();
        setStatus("Spinner 已暂停");
    } else {
        g_spinner.start();
        setStatus("Spinner 已播放");
    }
}

fn onOpenAssistant(_: *Button) void {
    g_assistant.show();
}

fn onAssistantApply(_: *Assistant) void {
    setStatus("向导已完成 (Apply)");
}

fn onAssistantCancel(_: *Assistant) void {
    setStatus("向导已取消");
}

fn onAssistantPrepare(_: *Assistant, page_index: usize) void {
    const msg = std.fmt.bufPrint(&g_status_buf, "向导页面: {d}", .{page_index + 1}) catch "向导";
    setStatus(msg);
}

fn onShowInfo(_: *Button) void {
    g_info_bar.kind = .info;
    g_info_bar.message = "这是一条信息提示，用于展示普通信息。";
    g_info_bar.visible = true;
    g_info_bar.base.markDirty();
    setStatus("显示 Info 信息栏");
}

fn onShowWarning(_: *Button) void {
    g_info_bar.kind = .warning;
    g_info_bar.message = "警告：此操作可能会影响您的数据。";
    g_info_bar.visible = true;
    g_info_bar.base.markDirty();
    setStatus("显示 Warning 信息栏");
}

fn onShowError(_: *Button) void {
    g_info_bar.kind = .err;
    g_info_bar.message = "错误：操作失败，请重试。";
    g_info_bar.visible = true;
    g_info_bar.base.markDirty();
    setStatus("显示 Error 信息栏");
}

fn onShowQuestion(_: *Button) void {
    g_info_bar.kind = .question;
    g_info_bar.message = "请问您确定要执行此操作吗？";
    g_info_bar.visible = true;
    g_info_bar.base.markDirty();
    setStatus("显示 Question 信息栏");
}

fn onInfoBarClose(_: *InfoBar) void {
    g_info_bar.visible = false;
    g_info_bar.base.markDirty();
    setStatus("信息栏已关闭");
}

// ── 绘制回调 ────────────────────────────────────────────────────────────────

fn drawFrame(app: *zigui.app.App) void {
    _ = app;
    // 主绘制在 widget 树中完成
}
