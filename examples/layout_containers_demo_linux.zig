//! zigui 布局容器示例 - Linux 版本
//!
//! 展示: Stack / Frame / CenterBox / FlowBox / Overlay
//!
//! 交互:
//!   - Stack: 点击按钮切换页面 (上一页/下一页)
//!   - Frame: 带标题的边框分组容器
//!   - CenterBox: 三栏居中布局 (开始/居中/结束)
//!   - FlowBox: 流式自适应网格布局
//!   - Overlay: 叠加层 (点击按钮显示/隐藏浮层)

const std = @import("std");
const zigui = @import("zigui");
const math = zigui.math;
const styled_text = zigui.styled_text;
const widget = zigui.widget;
const pal = zigui.pal;

const Container = zigui.container.Container;
const Label = zigui.label.Label;
const Button = zigui.button.Button;
const Stack = zigui.stack.Stack;
const Frame = zigui.frame.Frame;
const CenterBox = zigui.center_box.CenterBox;
const FlowBox = zigui.flow_box.FlowBox;
const Overlay = zigui.overlay.Overlay;
const Expander = zigui.expander.Expander;
const Revealer = zigui.revealer.Revealer;
const AspectFrame = zigui.aspect_frame.AspectFrame;
const InfoBar = zigui.info_bar.InfoBar;
const SearchEntry = zigui.search_entry.SearchEntry;
const MenuButton = zigui.menu_button.MenuButton;
const Popover = zigui.popover.Popover;
const DropDown = zigui.drop_down.DropDown;
const LevelBar = zigui.level_bar.LevelBar;
const Calendar = zigui.calendar.Calendar;
const ProgressBar = zigui.progress_bar.ProgressBar;
const TextInput = zigui.text_input.TextInput;
const ScrollView = zigui.scroll_view.ScrollView;
const FileChooser = zigui.file_chooser.FileChooser;
const FileChooserMode = zigui.file_chooser.FileChooserMode;
const ColorButton = zigui.color_button.ColorButton;
const FontButton = zigui.font_button.FontButton;
const FontDesc = zigui.font_chooser.FontDesc;

const theme_dark: zigui.theme.Theme = zigui.theme.dark;

var g_root: ?*Container = null;
var g_alloc: ?std.mem.Allocator = null;
var g_stack: ?*Stack = null;
var g_stack_label: ?*Label = null;
var g_stack_buf: [32]u8 = undefined;
var g_overlay: ?*Overlay = null;
var g_overlay_visible: bool = false;
var g_revealer: ?*Revealer = null;
var g_frame: u32 = 0;
var g_prev_mouse_down: bool = false;
var g_right_clicked: bool = false;
var g_prev_right_down: bool = false;
/// 快捷键消息 (由快捷键回调设置, drawFrame 中显示)
var g_shortcut_msg: []const u8 = "按 Ctrl+N/O/S 或 F1 试试快捷键";
/// 全局控件引用 (用于动态更新)
var g_indeterminate_pb: ?*ProgressBar = null;
var g_determinate_pb: ?*ProgressBar = null;
var g_pb_value: f32 = 0.0;
var g_dropdown_label: ?*Label = null;
var g_calendar_label: ?*Label = null;
var g_file_chooser: ?*FileChooser = null;
var g_file_chooser_label: ?*Label = null;
var g_file_chooser_buf: [256]u8 = undefined;
/// Tooltip 支持
var g_tooltip: ?*zigui.tooltip.Tooltip = null;
var g_tooltip_ctrl = zigui.tooltip_controller.TooltipController.init(undefined);
/// 右键菜单
var g_context_menu: ?*zigui.context_menu.ContextMenu = null;
/// FlowBox 数字标签的静态存储 (1-16), 避免堆分配泄漏
var g_flow_num_texts: [16][2]u8 = undefined;
var g_flow_num_slices: [16][]const u8 = undefined;

pub fn main() !void {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var app = try zigui.app.App.init(allocator, .{
        .title = "zigui - Layout Containers Demo (Linux)",
        .width = 1000,
        .height = 720,
    });
    defer app.deinit();

    try buildTree(allocator);
    defer destroyTree();

    // 注册全局快捷键
    try app.addShortcut(.n, .{ .ctrl = true }, onShortcutNew, null);
    try app.addShortcut(.o, .{ .ctrl = true }, onShortcutOpen, null);
    try app.addShortcut(.s, .{ .ctrl = true }, onShortcutSave, null);
    try app.addShortcut(.f1, .{}, onShortcutHelp, null);

    try app.run(&drawFrame);

    styled_text.deinitFontCache();
}

fn onShortcutNew(_: ?*anyopaque) void {
    g_shortcut_msg = "Ctrl+N: 新建";
}
fn onShortcutOpen(_: ?*anyopaque) void {
    g_shortcut_msg = "Ctrl+O: 打开";
}
fn onShortcutSave(_: ?*anyopaque) void {
    g_shortcut_msg = "Ctrl+S: 保存";
}
fn onShortcutHelp(_: ?*anyopaque) void {
    g_shortcut_msg = "F1: 帮助 (快捷键: Ctrl+N/O/S, F1)";
}

fn buildTree(alloc: std.mem.Allocator) !void {
    // 初始化 FlowBox 数字标签的静态存储
    for (0..16) |i| {
        const n: u8 = @intCast(i + 1);
        if (n < 10) {
            g_flow_num_texts[i][0] = '0' + n;
            g_flow_num_slices[i] = g_flow_num_texts[i][0..1];
        } else {
            g_flow_num_texts[i][0] = '0' + (n / 10);
            g_flow_num_texts[i][1] = '0' + (n % 10);
            g_flow_num_slices[i] = g_flow_num_texts[i][0..2];
        }
    }

    const root = try Container.create(alloc, .{
        .bg_color = math.Color.hex(0x0F172AFF),
        .direction = .column,
    });
    errdefer root.destroy(alloc);

    try buildHeader(root, alloc);

    // 右键菜单 (必须先于 buildBody 创建, 因为 ColorButton 会引用它)
    const cm_items = [_]zigui.context_menu.ContextMenuItem{
        .{ .label = "复制颜色值", .on_click = onCtxCopyColor },
        .{ .label = "设为背景色", .on_click = onCtxSetBg },
        .{ .is_separator = true },
        .{ .label = "重置为默认", .on_click = onCtxReset, .disabled = true },
    };
    const ctx_menu = try zigui.context_menu.ContextMenu.create(alloc, &cm_items);
    g_context_menu = ctx_menu;

    try buildBody(root, alloc);

    // Tooltip (必须最后添加, 以在最上层绘制)
    const tip = try zigui.tooltip.Tooltip.create(alloc, "");
    try root.base.addChild(alloc, &tip.base);
    g_tooltip = tip;
    g_tooltip_ctrl = zigui.tooltip_controller.TooltipController.init(tip);

    // 右键菜单加到最上层
    try root.base.addChild(alloc, &ctx_menu.base);

    g_root = root;
    g_alloc = alloc;
}

fn buildHeader(root: *Container, alloc: std.mem.Allocator) !void {
    const header = try Container.create(alloc, .{
        .bg_color = math.Color.hex(0x1E293BFF),
        .direction = .row,
        .height = .{ .px = 64 },
        .padding = .{ .left = 20, .top = 0, .right = 20, .bottom = 0 },
    });
    header.base.layout_style.align_items = .center;
    try root.base.addChild(alloc, &header.base);

    const title = try Label.create(alloc, "Layout Containers Showcase", .{
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

fn buildMinimalTest(body: *Container, alloc: std.mem.Allocator) !void {
    const col = try Container.create(alloc, .{
        .bg_color = math.Color.hex(0xF8FAFCFF),
        .corner_radius = 12,
        .direction = .column,
        .width = .{ .px = 420 },
        .padding = math.EdgeInsets.all(16),
        .gap = .{ .width = 0, .height = 16 },
    });
    col.base.layout_style.flex_shrink = 0;
    try body.base.addChild(alloc, &col.base);

    const label1_bg = try Container.create(alloc, .{
        .bg_color = math.Color.hex(0xE11D4833),
        .corner_radius = 4,
        .padding = math.EdgeInsets.all(8),
    });
    try col.base.addChild(alloc, &label1_bg.base);
    const label1 = try Label.create(alloc, "Expander 上方的标签 (应该可见)", .{
        .font_size = 14,
        .color = math.Color.hex(0xE11D48FF),
    });
    try label1_bg.base.addChild(alloc, &label1.base);

    const expander = try Expander.create(alloc, "测试 Expander (默认收起)", .{
        .expanded = false,
        .header_bg = math.Color.hex(0x334155FF),
        .header_hover_bg = math.Color.hex(0x475569FF),
        .text_color = math.Color.hex(0xF1F5F9FF),
        .border_color = math.Color.hex(0x475569FF),
    });
    try col.base.addChild(alloc, &expander.base);

    const exp_content = try Container.create(alloc, .{
        .direction = .column,
        .gap = .{ .width = 0, .height = 8 },
        .padding = math.EdgeInsets.all(12),
    });
    try expander.base.addChild(alloc, &exp_content.base);

    const opt1 = try Label.create(alloc, "• 选项一: 测试内容", .{
        .font_size = 13,
        .color = math.Color.hex(0x94A3B8FF),
    });
    try exp_content.base.addChild(alloc, &opt1.base);

    const label2_bg = try Container.create(alloc, .{
        .bg_color = math.Color.hex(0x05966933),
        .corner_radius = 4,
        .padding = math.EdgeInsets.all(8),
    });
    try col.base.addChild(alloc, &label2_bg.base);
    const label2 = try Label.create(alloc, "Expander 下方的标签 (应该可见)", .{
        .font_size = 14,
        .color = math.Color.hex(0x059669FF),
    });
    try label2_bg.base.addChild(alloc, &label2.base);
}

fn buildLeftColumn(body: *Container, alloc: std.mem.Allocator) !void {
    const col = try Container.create(alloc, .{
        .direction = .column,
        .width = .{ .px = 420 },
    });
    col.base.layout_style.flex_shrink = 0;
    try body.base.addChild(alloc, &col.base);

    const scroll = try ScrollView.create(alloc, .{
        .bg_color = math.Color.hex(0xF8FAFCFF),
        .corner_radius = 12,
    });
    scroll.base.layout_style.flex_grow = 1;
    try col.base.addChild(alloc, &scroll.base);

    const content = try Container.create(alloc, .{
        .direction = .column,
        .padding = math.EdgeInsets.all(16),
        .gap = .{ .width = 0, .height = 16 },
    });
    try scroll.base.addChild(alloc, &content.base);

    try buildStackDemo(content, alloc);
    try buildFrameDemo(content, alloc);
    try buildExpanderDemo(content, alloc);
    try buildRevealerDemo(content, alloc);
    try buildHexpandDemo(content, alloc);
    try buildAspectFrameDemo(content, alloc);
}

fn buildRightColumn(body: *Container, alloc: std.mem.Allocator) !void {
    const col = try Container.create(alloc, .{
        .direction = .column,
    });
    col.base.layout_style.flex_grow = 1;
    col.base.layout_style.min_width = .{ .px = 0 };
    try body.base.addChild(alloc, &col.base);

    const scroll = try ScrollView.create(alloc, .{
        .bg_color = math.Color.hex(0x0F172AFF),
    });
    scroll.base.layout_style.flex_grow = 1;
    try col.base.addChild(alloc, &scroll.base);

    const content = try Container.create(alloc, .{
        .direction = .column,
        .padding = math.EdgeInsets.all(16),
        .gap = .{ .width = 0, .height = 16 },
    });
    try scroll.base.addChild(alloc, &content.base);

    try buildCenterBoxDemo(content, alloc);
    try buildFlowBoxDemo(content, alloc);
    try buildOverlayDemo(content, alloc);
    try buildInfoBarDemo(content, alloc);
    try buildSearchEntryDemo(content, alloc);
    try buildMenuButtonDemo(content, alloc);
    try buildMarkupDemo(content, alloc);
    try buildIconDemo(content, alloc);
    try buildDropDownDemo(content, alloc);
    try buildLevelBarDemo(content, alloc);
    try buildProgressBarDemo(content, alloc);
    try buildPasswordDemo(content, alloc);
    try buildLabelWrapDemo(content, alloc);
    try buildCalendarDemo(content, alloc);
    try buildFileChooserDemo(content, alloc);
    try buildColorButtonDemo(content, alloc);
    try buildFontButtonDemo(content, alloc);
}

fn addSection(parent: *Container, alloc: std.mem.Allocator, text: []const u8) !void {
    const lbl = try Label.create(alloc, text, .{
        .font_size = 13,
        .font_weight = 700,
        .color = math.Color.hex(0x64748BFF),
    });
    try parent.base.addChild(alloc, &lbl.base);
}

fn buildStackDemo(parent: *Container, alloc: std.mem.Allocator) !void {
    try addSection(parent, alloc, "Stack 多页面堆叠切换");

    const demo = try Container.create(alloc, .{
        .direction = .column,
        .gap = .{ .width = 0, .height = 10 },
    });
    try parent.base.addChild(alloc, &demo.base);

    const stack = try Stack.create(alloc, .{
        .bg_color = math.Color.hex(0x334155FF),
        .corner_radius = 8,
        .height = .{ .px = 160 },
    });
    g_stack = stack;
    try demo.base.addChild(alloc, &stack.base);

    const page1 = try Container.create(alloc, .{
        .direction = .column,
        .padding = math.EdgeInsets.all(16),
        .bg_color = math.Color.hex(0x3B82F6FF),
        .corner_radius = 8,
    });
    const p1_title = try Label.create(alloc, "Page 1 - Welcome", .{
        .font_size = 18,
        .font_weight = 700,
        .color = math.Color.hex(0xFFFFFFFF),
    });
    try page1.base.addChild(alloc, &p1_title.base);
    const p1_desc = try Label.create(alloc, "这是第一页的内容", .{
        .font_size = 13,
        .color = math.Color.hex(0xE0E7FFFF),
    });
    p1_desc.base.layout_style.margin.top = 6;
    try page1.base.addChild(alloc, &p1_desc.base);
    try stack.addChild(&page1.base);

    const page2 = try Container.create(alloc, .{
        .direction = .column,
        .padding = math.EdgeInsets.all(16),
        .bg_color = math.Color.hex(0x10B981FF),
        .corner_radius = 8,
    });
    const p2_title = try Label.create(alloc, "Page 2 - Settings", .{
        .font_size = 18,
        .font_weight = 700,
        .color = math.Color.hex(0xFFFFFFFF),
    });
    try page2.base.addChild(alloc, &p2_title.base);
    const p2_desc = try Label.create(alloc, "这是第二页的内容", .{
        .font_size = 13,
        .color = math.Color.hex(0xD1FAE5FF),
    });
    p2_desc.base.layout_style.margin.top = 6;
    try page2.base.addChild(alloc, &p2_desc.base);
    try stack.addChild(&page2.base);

    const page3 = try Container.create(alloc, .{
        .direction = .column,
        .padding = math.EdgeInsets.all(16),
        .bg_color = math.Color.hex(0xF59E0BFF),
        .corner_radius = 8,
    });
    const p3_title = try Label.create(alloc, "Page 3 - Profile", .{
        .font_size = 18,
        .font_weight = 700,
        .color = math.Color.hex(0xFFFFFFFF),
    });
    try page3.base.addChild(alloc, &p3_title.base);
    const p3_desc = try Label.create(alloc, "这是第三页的内容", .{
        .font_size = 13,
        .color = math.Color.hex(0xFEF3C7FF),
    });
    p3_desc.base.layout_style.margin.top = 6;
    try page3.base.addChild(alloc, &p3_desc.base);
    try stack.addChild(&page3.base);

    const btn_row = try Container.create(alloc, .{
        .direction = .row,
        .gap = .{ .width = 8, .height = 0 },
    });
    try demo.base.addChild(alloc, &btn_row.base);

    const prev_btn = try Button.create(alloc, "← 上一页", .{
        .on_click = onPrevPage,
    });
    prev_btn.base.layout_style.height = .{ .px = 32 };
    try btn_row.base.addChild(alloc, &prev_btn.base);

    const next_btn = try Button.create(alloc, "下一页 →", .{
        .on_click = onNextPage,
    });
    next_btn.base.layout_style.height = .{ .px = 32 };
    try btn_row.base.addChild(alloc, &next_btn.base);

    const page_label = try Label.create(alloc, "第 1 / 3 页", .{
        .font_size = 13,
        .color = math.Color.hex(0x94A3B8FF),
    });
    page_label.base.layout_style.margin.top = 8;
    g_stack_label = page_label;
    try demo.base.addChild(alloc, &page_label.base);
}

fn buildFrameDemo(parent: *Container, alloc: std.mem.Allocator) !void {
    try addSection(parent, alloc, "Frame 带标题的边框分组");

    const frame = try Frame.create(alloc, "User Information", .{
        .border_color = math.Color.hex(0x475569FF),
        .border_width = 1,
        .corner_radius = 8,
        .padding = .{ .left = 12, .top = 8, .right = 12, .bottom = 12 },
        .bg_color = math.Color.hex(0x1E293BFF),
    });
    try parent.base.addChild(alloc, &frame.base);

    const content = try Container.create(alloc, .{
        .direction = .column,
        .gap = .{ .width = 0, .height = 8 },
    });
    try frame.setChild(&content.base);

    const name_row = try Container.create(alloc, .{ .direction = .row, .gap = .{ .width = 8, .height = 0 } });
    const name_lbl = try Label.create(alloc, "姓名:", .{ .color = math.Color.hex(0x94A3B8FF), .font_size = 13 });
    name_lbl.base.layout_style.width = .{ .px = 50 };
    try name_row.base.addChild(alloc, &name_lbl.base);
    const name_val = try Label.create(alloc, "张三", .{ .color = math.Color.hex(0xF1F5F9FF), .font_size = 13 });
    try name_row.base.addChild(alloc, &name_val.base);
    try content.base.addChild(alloc, &name_row.base);

    const email_row = try Container.create(alloc, .{ .direction = .row, .gap = .{ .width = 8, .height = 0 } });
    const email_lbl = try Label.create(alloc, "邮箱:", .{ .color = math.Color.hex(0x94A3B8FF), .font_size = 13 });
    email_lbl.base.layout_style.width = .{ .px = 50 };
    try email_row.base.addChild(alloc, &email_lbl.base);
    const email_val = try Label.create(alloc, "zhangsan@example.com", .{ .color = math.Color.hex(0xF1F5F9FF), .font_size = 13 });
    try email_row.base.addChild(alloc, &email_val.base);
    try content.base.addChild(alloc, &email_row.base);

    const role_row = try Container.create(alloc, .{ .direction = .row, .gap = .{ .width = 8, .height = 0 } });
    const role_lbl = try Label.create(alloc, "角色:", .{ .color = math.Color.hex(0x94A3B8FF), .font_size = 13 });
    role_lbl.base.layout_style.width = .{ .px = 50 };
    try role_row.base.addChild(alloc, &role_lbl.base);
    const role_val = try Label.create(alloc, "管理员", .{ .color = math.Color.hex(0x34D399FF), .font_size = 13 });
    try role_row.base.addChild(alloc, &role_val.base);
    try content.base.addChild(alloc, &role_row.base);
}

fn buildCenterBoxDemo(parent: *Container, alloc: std.mem.Allocator) !void {
    try addSection(parent, alloc, "CenterBox 三栏居中布局");

    const cb_row = try Container.create(alloc, .{
        .bg_color = math.Color.hex(0x1E293BFF),
        .corner_radius = 12,
        .padding = math.EdgeInsets.all(16),
        .direction = .column,
        .gap = .{ .width = 0, .height = 12 },
    });
    try parent.base.addChild(alloc, &cb_row.base);

    const cb_h = try CenterBox.create(alloc, .{
        .direction = .row,
        .bg_color = math.Color.hex(0x0F172AFF),
        .corner_radius = 8,
        .height = .{ .px = 60 },
    });
    try cb_row.base.addChild(alloc, &cb_h.base);

    const start_h = try Label.create(alloc, "← Start", .{
        .font_size = 14,
        .color = math.Color.hex(0x60A5FAFF),
    });
    start_h.base.layout_style.margin.left = 12;
    start_h.base.layout_style.margin.top = 20;
    try cb_h.setStart(&start_h.base);

    const center_h = try Label.create(alloc, "Center (居中)", .{
        .font_size = 16,
        .font_weight = 700,
        .color = math.Color.hex(0xF8FAFCFF),
    });
    center_h.base.layout_style.margin.top = 18;
    try cb_h.setCenter(&center_h.base);

    const end_h = try Label.create(alloc, "End →", .{
        .font_size = 14,
        .color = math.Color.hex(0x34D399FF),
    });
    end_h.base.layout_style.margin.right = 12;
    end_h.base.layout_style.margin.top = 20;
    try cb_h.setEnd(&end_h.base);

    const cb_v_label = try Label.create(alloc, "垂直方向:", .{
        .font_size = 12,
        .color = math.Color.hex(0x64748BFF),
    });
    try cb_row.base.addChild(alloc, &cb_v_label.base);

    const cb_v = try CenterBox.create(alloc, .{
        .direction = .column,
        .bg_color = math.Color.hex(0x0F172AFF),
        .corner_radius = 8,
        .height = .{ .px = 160 },
    });
    try cb_row.base.addChild(alloc, &cb_v.base);

    const top_v = try Label.create(alloc, "▲ Top", .{
        .font_size = 13,
        .color = math.Color.hex(0x60A5FAFF),
    });
    top_v.base.layout_style.margin.top = 10;
    try cb_v.setStart(&top_v.base);

    const middle_v = try Label.create(alloc, "Middle (垂直居中)", .{
        .font_size = 14,
        .font_weight = 700,
        .color = math.Color.hex(0xF8FAFCFF),
    });
    try cb_v.setCenter(&middle_v.base);

    const bottom_v = try Label.create(alloc, "Bottom ▼", .{
        .font_size = 13,
        .color = math.Color.hex(0x34D399FF),
    });
    bottom_v.base.layout_style.margin.bottom = 10;
    try cb_v.setEnd(&bottom_v.base);
}

fn buildFlowBoxDemo(parent: *Container, alloc: std.mem.Allocator) !void {
    try addSection(parent, alloc, "FlowBox 流式自适应网格");

    const flow_container = try Container.create(alloc, .{
        .bg_color = math.Color.hex(0x1E293BFF),
        .corner_radius = 12,
        .padding = math.EdgeInsets.all(16),
        .direction = .column,
        .gap = .{ .width = 0, .height = 10 },
    });
    try parent.base.addChild(alloc, &flow_container.base);

    const flow = try FlowBox.create(alloc, .{
        .direction = .row,
        .row_gap = 8,
        .col_gap = 8,
    });
    flow.base.layout_style.flex_grow = 1;
    try flow_container.base.addChild(alloc, &flow.base);

    const colors = [_]u32{
        0xEF4444FF, 0xF97316FF, 0xF59E0BFF, 0xEAB308FF,
        0x84CC16FF, 0x22C55EFF, 0x10B981FF, 0x14B8A6FF,
        0x06B6D4FF, 0x0EA5E9FF, 0x3B82F6FF, 0x6366F1FF,
        0x8B5CF6FF, 0xA855F7FF, 0xD946EFF,  0xEC4899FF,
    };

    for (colors, 0..) |c, i| {
        const item = try Container.create(alloc, .{
            .bg_color = math.Color.hex(c),
            .corner_radius = 6,
            .width = .{ .px = 70 },
            .height = .{ .px = 50 },
            .direction = .column,
        });
        const num_lbl = try Label.create(alloc, "", .{ .font_size = 14, .font_weight = 700, .color = math.Color.hex(0xFFFFFFFF) });
        num_lbl.base.layout_style.margin.top = 16;
        num_lbl.base.layout_style.margin.left = 28;
        num_lbl.text = g_flow_num_slices[i];
        try item.base.addChild(alloc, &num_lbl.base);
        try flow.addChild(&item.base);
    }
}

fn buildDropDownDemo(parent: *Container, alloc: std.mem.Allocator) !void {
    try addSection(parent, alloc, "DropDown 下拉选择");

    const demo = try Container.create(alloc, .{
        .direction = .row,
        .gap = .{ .width = 12, .height = 0 },
    });
    demo.base.layout_style.align_items = .center;
    try parent.base.addChild(alloc, &demo.base);

    const dd = try DropDown.create(alloc, .{
        .on_change = onDropDownChange,
    });
    try dd.addItem("选项 A", 1);
    try dd.addItem("选项 B", 2);
    try dd.addItem("选项 C", 3);
    try dd.addItem("选项 D", 4);
    try demo.base.addChild(alloc, &dd.base);

    const lbl = try Label.create(alloc, "选中: 选项 A", .{
        .font_size = 13,
        .color = math.Color.hex(0x64748BFF),
    });
    g_dropdown_label = lbl;
    try demo.base.addChild(alloc, &lbl.base);
}

var g_dropdown_buf: [64]u8 = undefined;
var g_calendar_buf: [64]u8 = undefined;

fn onDropDownChange(dd: *DropDown, _: usize) void {
    if (g_dropdown_label) |lbl| {
        const text = dd.getSelectedText();
        const msg = std.fmt.bufPrint(&g_dropdown_buf, "选中: {s}", .{text}) catch "选中";
        lbl.text = msg;
        lbl.base.markDirty();
    }
}

fn buildLevelBarDemo(parent: *Container, alloc: std.mem.Allocator) !void {
    try addSection(parent, alloc, "LevelBar 等级条");

    const demo = try Container.create(alloc, .{
        .direction = .column,
        .gap = .{ .width = 0, .height = 8 },
    });
    try parent.base.addChild(alloc, &demo.base);

    // 离散模式 - 电量 (5 段)
    const battery_lbl = try Label.create(alloc, "电量 (离散 5 段)", .{
        .font_size = 12,
        .color = math.Color.hex(0x64748BFF),
    });
    try demo.base.addChild(alloc, &battery_lbl.base);

    const battery = try LevelBar.create(alloc, .{
        .value = 0.6,
        .mode = .discrete,
        .segments = 5,
    });
    battery.base.layout_style.width = .{ .px = 200 };
    try demo.base.addChild(alloc, &battery.base);

    // 离散模式 - 信号 (4 段, 低值)
    const signal_lbl = try Label.create(alloc, "信号 (低值红色)", .{
        .font_size = 12,
        .color = math.Color.hex(0x64748BFF),
    });
    try demo.base.addChild(alloc, &signal_lbl.base);

    const signal = try LevelBar.create(alloc, .{
        .value = 0.15,
        .mode = .discrete,
        .segments = 4,
    });
    signal.base.layout_style.width = .{ .px = 160 };
    try demo.base.addChild(alloc, &signal.base);

    // 连续模式
    const cont_lbl = try Label.create(alloc, "连续模式 (高值绿色)", .{
        .font_size = 12,
        .color = math.Color.hex(0x64748BFF),
    });
    try demo.base.addChild(alloc, &cont_lbl.base);

    const cont = try LevelBar.create(alloc, .{
        .value = 0.9,
        .mode = .continuous,
    });
    cont.base.layout_style.width = .{ .px = 200 };
    try demo.base.addChild(alloc, &cont.base);
}

fn buildProgressBarDemo(parent: *Container, alloc: std.mem.Allocator) !void {
    try addSection(parent, alloc, "ProgressBar 进度条");

    const demo = try Container.create(alloc, .{
        .direction = .column,
        .gap = .{ .width = 0, .height = 8 },
    });
    try parent.base.addChild(alloc, &demo.base);

    // 确定模式
    const det_lbl = try Label.create(alloc, "确定模式 (每帧 +1%)", .{
        .font_size = 12,
        .color = math.Color.hex(0x64748BFF),
    });
    try demo.base.addChild(alloc, &det_lbl.base);

    const det_pb = try ProgressBar.create(alloc, .{
        .value = 0,
        .show_label = true,
    });
    det_pb.base.layout_style.width = .{ .px = 250 };
    g_determinate_pb = det_pb;
    try demo.base.addChild(alloc, &det_pb.base);

    // 不确定模式
    const indet_lbl = try Label.create(alloc, "不确定模式 (来回滚动)", .{
        .font_size = 12,
        .color = math.Color.hex(0x64748BFF),
    });
    try demo.base.addChild(alloc, &indet_lbl.base);

    const indet_pb = try ProgressBar.create(alloc, .{
        .indeterminate = true,
    });
    indet_pb.base.layout_style.width = .{ .px = 250 };
    g_indeterminate_pb = indet_pb;
    try demo.base.addChild(alloc, &indet_pb.base);
}

fn buildPasswordDemo(parent: *Container, alloc: std.mem.Allocator) !void {
    try addSection(parent, alloc, "TextInput 密码模式");

    const demo = try Container.create(alloc, .{
        .direction = .column,
        .gap = .{ .width = 0, .height = 8 },
    });
    try parent.base.addChild(alloc, &demo.base);

    // 密码输入
    const pwd_lbl = try Label.create(alloc, "密码 (visibility=false, max=16)", .{
        .font_size = 12,
        .color = math.Color.hex(0x64748BFF),
    });
    try demo.base.addChild(alloc, &pwd_lbl.base);

    const pwd = try TextInput.create(alloc, .{
        .placeholder = "请输入密码",
        .visibility = false,
        .max_length = 16,
    });
    pwd.base.layout_style.width = .{ .px = 250 };
    try demo.base.addChild(alloc, &pwd.base);

    // 普通输入 + max_length
    const limited_lbl = try Label.create(alloc, "限长输入 (max=10)", .{
        .font_size = 12,
        .color = math.Color.hex(0x64748BFF),
    });
    try demo.base.addChild(alloc, &limited_lbl.base);

    const limited = try TextInput.create(alloc, .{
        .placeholder = "最多 10 个字符",
        .max_length = 10,
    });
    limited.base.layout_style.width = .{ .px = 250 };
    try demo.base.addChild(alloc, &limited.base);
}

fn buildLabelWrapDemo(parent: *Container, alloc: std.mem.Allocator) !void {
    try addSection(parent, alloc, "Label 换行与省略号");

    const demo = try Container.create(alloc, .{
        .direction = .column,
        .gap = .{ .width = 0, .height = 8 },
    });
    try parent.base.addChild(alloc, &demo.base);

    // 自动换行
    const wrap_lbl = try Label.create(alloc, "这是自动换行的长文本, 当文本超过容器宽度时会自动折行显示, 适合显示段落内容。", .{
        .font_size = 13,
        .color = math.Color.hex(0xF8FAFCFF),
        .wrap = true,
    });
    wrap_lbl.base.layout_style.width = .{ .px = 300 };
    try demo.base.addChild(alloc, &wrap_lbl.base);

    // 省略号
    const ellip_lbl = try Label.create(alloc, "这是带省略号的文本, 超出宽度的部分会被截断并显示省略号...", .{
        .font_size = 13,
        .color = math.Color.hex(0xF8FAFCFF),
        .ellipsize = .end,
    });
    ellip_lbl.base.layout_style.width = .{ .px = 200 };
    try demo.base.addChild(alloc, &ellip_lbl.base);
}

fn buildCalendarDemo(parent: *Container, alloc: std.mem.Allocator) !void {
    try addSection(parent, alloc, "Calendar 日历");

    const demo = try Container.create(alloc, .{
        .direction = .column,
        .gap = .{ .width = 0, .height = 8 },
    });
    try parent.base.addChild(alloc, &demo.base);

    const cal = try Calendar.create(alloc, .{
        .year = 2026,
        .month = 7,
        .on_change = onCalendarChange,
    });
    try demo.base.addChild(alloc, &cal.base);

    const lbl = try Label.create(alloc, "点击日期选择", .{
        .font_size = 12,
        .color = math.Color.hex(0x64748BFF),
    });
    g_calendar_label = lbl;
    try demo.base.addChild(alloc, &lbl.base);
}

fn onCalendarChange(cal: *Calendar, year: u16, month: u4, day: u8) void {
    _ = cal;
    if (g_calendar_label) |lbl| {
        const msg = std.fmt.bufPrint(&g_calendar_buf, "选中: {d}年{d}月{d}日", .{ year, month, day }) catch "选中";
        lbl.text = msg;
        lbl.base.markDirty();
    }
}

fn buildFileChooserDemo(parent: *Container, alloc: std.mem.Allocator) !void {
    try addSection(parent, alloc, "FileChooser 文件选择对话框");

    const demo = try Container.create(alloc, .{
        .direction = .column,
        .gap = .{ .width = 0, .height = 8 },
    });
    try parent.base.addChild(alloc, &demo.base);

    const btn_row = try Container.create(alloc, .{
        .direction = .row,
        .gap = .{ .width = 8, .height = 0 },
    });
    try demo.base.addChild(alloc, &btn_row.base);

    const open_btn = try Button.create(alloc, "打开文件", .{
        .on_click = onOpenFileClick,
    });
    try btn_row.base.addChild(alloc, &open_btn.base);

    const save_btn = try Button.create(alloc, "保存文件", .{
        .on_click = onSaveFileClick,
        .bg_color = math.Color.hex(0x10B981FF),
        .bg_hover = math.Color.hex(0x34D399FF),
        .bg_pressed = math.Color.hex(0x059669FF),
    });
    try btn_row.base.addChild(alloc, &save_btn.base);

    const lbl = try Label.create(alloc, "未选择文件", .{
        .font_size = 12,
        .color = math.Color.hex(0x64748BFF),
    });
    g_file_chooser_label = lbl;
    try demo.base.addChild(alloc, &lbl.base);
}

fn onOpenFileClick(btn: *Button) void {
    _ = btn;
    const alloc = g_alloc orelse return;
    const root = g_root orelse return;

    // 如果已有文件选择器, 直接显示
    if (g_file_chooser) |fc| {
        fc.mode = .open;
        fc.show();
        return;
    }

    const chooser = FileChooser.create(alloc, .{
        .mode = .open,
        .title = "打开文件",
        .initial_path = "/tmp",
        .on_file_selected = onFileSelected,
        .on_cancel = onFileChooserCancel,
    }) catch return;
    g_file_chooser = chooser;
    root.base.addChild(alloc, &chooser.base) catch return;
    chooser.show();
}

fn onSaveFileClick(btn: *Button) void {
    _ = btn;
    const alloc = g_alloc orelse return;
    const root = g_root orelse return;

    if (g_file_chooser) |fc| {
        fc.mode = .save;
        fc.show();
        return;
    }

    const chooser = FileChooser.create(alloc, .{
        .mode = .save,
        .title = "保存文件",
        .initial_path = "/tmp",
        .on_file_selected = onFileSelected,
        .on_cancel = onFileChooserCancel,
    }) catch return;
    g_file_chooser = chooser;
    root.base.addChild(alloc, &chooser.base) catch return;
    chooser.show();
}

fn onFileSelected(fc: *FileChooser, path: []const u8) void {
    _ = fc;
    if (g_file_chooser_label) |lbl| {
        const buf = &g_file_chooser_buf;
        const prefix = "已选择: ";
        const max_path_len = buf.len - prefix.len - 3;
        if (path.len <= max_path_len) {
            @memcpy(buf[0..prefix.len], prefix);
            @memcpy(buf[prefix.len .. prefix.len + path.len], path);
            lbl.text = buf[0 .. prefix.len + path.len];
        } else {
            @memcpy(buf[0..prefix.len], prefix);
            @memcpy(buf[prefix.len .. prefix.len + max_path_len], path[0..max_path_len]);
            @memcpy(buf[prefix.len + max_path_len .. prefix.len + max_path_len + 3], "...");
            lbl.text = buf[0 .. prefix.len + max_path_len + 3];
        }
        lbl.base.markDirty();
    }
}

fn onFileChooserCancel(fc: *FileChooser) void {
    _ = fc;
}

// ── 右键菜单回调 ──────────────────────────────────────────────────────────

fn onCtxCopyColor(_: ?*anyopaque) void {
    // 演示用: 实际可以复制到剪贴板
}

fn onCtxSetBg(_: ?*anyopaque) void {
    // 演示用: 实际可以设置背景色
}

fn onCtxReset(_: ?*anyopaque) void {
    // 禁用的菜单项
}

fn buildColorButtonDemo(parent: *Container, alloc: std.mem.Allocator) !void {
    try addSection(parent, alloc, "ColorButton 颜色选择按钮");

    const demo = try Container.create(alloc, .{
        .direction = .row,
        .gap = .{ .width = 12, .height = 0 },
    });
    try parent.base.addChild(alloc, &demo.base);

    const colors = [_]struct { color: math.Color, name: []const u8 }{
        .{ .color = math.Color.hex(0x3B82F6FF), .name = "蓝色 (Blue)" },
        .{ .color = math.Color.hex(0xEF4444FF), .name = "红色 (Red)" },
        .{ .color = math.Color.hex(0x22C55EFF), .name = "绿色 (Green)" },
        .{ .color = math.Color.hex(0xF59E0BFF), .name = "橙色 (Orange)" },
        .{ .color = math.Color.hex(0x8B5CF6FF), .name = "紫色 (Purple)" },
    };

    inline for (colors) |c| {
        const btn = try ColorButton.create(alloc, .{
            .color = c.color,
        });
        btn.base.tooltip_text = c.name;
        btn.base.context_menu = g_context_menu;
        try demo.base.addChild(alloc, &btn.base);
    }
}

var g_font_preview_label: *Label = undefined;

fn onFontChanged(_: *FontButton, desc: FontDesc) void {
    g_font_preview_label.font_size = desc.size;
    g_font_preview_label.font_weight = if (desc.bold) 700 else 400;
    g_font_preview_label.text = desc.family;
}

fn buildFontButtonDemo(parent: *Container, alloc: std.mem.Allocator) !void {
    try addSection(parent, alloc, "FontButton 字体选择按钮");

    const demo = try Container.create(alloc, .{
        .direction = .row,
        .gap = .{ .width = 16, .height = 0 },
    });
    try parent.base.addChild(alloc, &demo.base);

    const btn = try FontButton.create(alloc, .{
        .family = "Sans",
        .size = 14,
        .on_font_changed = onFontChanged,
    });
    try demo.base.addChild(alloc, &btn.base);

    g_font_preview_label = try Label.create(alloc, "Sans", .{
        .font_size = 14,
        .color = math.Color.hex(0xF8FAFCFF),
    });
    try demo.base.addChild(alloc, &g_font_preview_label.base);
}

fn buildMarkupDemo(parent: *Container, alloc: std.mem.Allocator) !void {
    try addSection(parent, alloc, "Label 富文本标记");

    const demo = try Container.create(alloc, .{
        .direction = .column,
        .gap = .{ .width = 0, .height = 8 },
    });
    try parent.base.addChild(alloc, &demo.base);

    // 富文本示例
    const lbl1 = try Label.create(alloc, "普通文本 <b>粗体</b> <color=0xEF4444FF>红色</color> <color=0x22C55EFF>绿色</color>", .{
        .font_size = 14,
        .color = math.Color.hex(0xF8FAFCFF),
        .use_markup = true,
    });
    try demo.base.addChild(alloc, &lbl1.base);

    const lbl2 = try Label.create(alloc, "<size=20>大字</size> <size=12>小字</size> <b><color=0x3B82F6FF>蓝色粗体</color></b>", .{
        .font_size = 14,
        .color = math.Color.hex(0xF8FAFCFF),
        .use_markup = true,
    });
    try demo.base.addChild(alloc, &lbl2.base);

    const lbl3 = try Label.create(alloc, "<b>标题</b> <i>斜体</i> <color=0xF59E0BFF>警告色</color> 普通", .{
        .font_size = 16,
        .color = math.Color.hex(0xF8FAFCFF),
        .use_markup = true,
    });
    try demo.base.addChild(alloc, &lbl3.base);

    const lbl4 = try Label.create(alloc, "<u>下划线</u> <s>删除线</s> <b><i>粗斜体</i></b>", .{
        .font_size = 14,
        .color = math.Color.hex(0xF8FAFCFF),
        .use_markup = true,
    });
    try demo.base.addChild(alloc, &lbl4.base);

    const lbl5 = try Label.create(alloc, "<i><u>斜体+下划线</u></i>  <color=0xEF4444FF><s>红色删除线</s></color>", .{
        .font_size = 14,
        .color = math.Color.hex(0xF8FAFCFF),
        .use_markup = true,
    });
    try demo.base.addChild(alloc, &lbl5.base);
}

fn buildIconDemo(parent: *Container, alloc: std.mem.Allocator) !void {
    try addSection(parent, alloc, "Button 图标按钮 (纯图标 / 图标+文本)");

    const demo = try Container.create(alloc, .{
        .direction = .column,
        .gap = .{ .width = 0, .height = 10 },
    });
    try parent.base.addChild(alloc, &demo.base);

    // 第一行: 纯图标按钮 (方形, 浅底深图标)
    const icon_row = try Container.create(alloc, .{
        .direction = .row,
        .gap = .{ .width = 8, .height = 0 },
    });
    try demo.base.addChild(alloc, &icon_row.base);

    const IconName = zigui.icons.IconName;
    const icon_names = [_]IconName{
        .close, .menu, .search, .settings, .plus, .minus, .refresh, .edit, .trash, .save,
    };
    for (icon_names) |ic| {
        const btn = try Button.create(alloc, "", .{
            .icon = ic,
            .icon_size = 16,
            .bg_color = math.Color.hex(0x1E293BFF),
            .bg_hover = math.Color.hex(0x334155FF),
            .bg_pressed = math.Color.hex(0x0F172AFF),
            .text_color = math.Color.hex(0xE2E8F0FF),
            .corner_radius = 6,
            .padding_h = 8,
            .padding_v = 8,
        });
        btn.base.layout_style.width = .{ .px = 32 };
        btn.base.layout_style.height = .{ .px = 32 };
        try icon_row.base.addChild(alloc, &btn.base);
    }

    // 第二行: 图标 + 文本按钮
    const mixed_row = try Container.create(alloc, .{
        .direction = .row,
        .gap = .{ .width = 8, .height = 0 },
    });
    mixed_row.base.layout_style.wrap = .wrap;
    try demo.base.addChild(alloc, &mixed_row.base);

    const save_btn = try Button.create(alloc, "保存", .{
        .icon = .save,
        .bg_color = math.Color.hex(0x10B981FF),
        .bg_hover = math.Color.hex(0x34D399FF),
        .bg_pressed = math.Color.hex(0x059669FF),
    });
    try mixed_row.base.addChild(alloc, &save_btn.base);

    const edit_btn = try Button.create(alloc, "编辑", .{
        .icon = .edit,
        .bg_color = math.Color.hex(0x3B82F6FF),
        .bg_hover = math.Color.hex(0x60A5FAFF),
    });
    try mixed_row.base.addChild(alloc, &edit_btn.base);

    const del_btn = try Button.create(alloc, "删除", .{
        .icon = .trash,
        .bg_color = math.Color.hex(0xEF4444FF),
        .bg_hover = math.Color.hex(0xF87171FF),
    });
    try mixed_row.base.addChild(alloc, &del_btn.base);

    const refresh_btn = try Button.create(alloc, "刷新", .{
        .icon = .refresh,
        .bg_color = math.Color.hex(0x6366F1FF),
        .bg_hover = math.Color.hex(0x818CF8FF),
    });
    try mixed_row.base.addChild(alloc, &refresh_btn.base);

    // 第三行: 更多图标展示 (信息类)
    const more_row = try Container.create(alloc, .{
        .direction = .row,
        .gap = .{ .width = 8, .height = 0 },
    });
    more_row.base.layout_style.wrap = .wrap;
    try demo.base.addChild(alloc, &more_row.base);

    const more_icons = [_]struct { name: IconName, label: []const u8, bg: math.Color }{
        .{ .name = .home, .label = "首页", .bg = math.Color.hex(0xF59E0BFF) },
        .{ .name = .user, .label = "用户", .bg = math.Color.hex(0x8B5CF6FF) },
        .{ .name = .star, .label = "收藏", .bg = math.Color.hex(0xEAB308FF) },
        .{ .name = .heart, .label = "喜欢", .bg = math.Color.hex(0xEC4899FF) },
        .{ .name = .info, .label = "信息", .bg = math.Color.hex(0x06B6D4FF) },
        .{ .name = .warning, .label = "警告", .bg = math.Color.hex(0xF97316FF) },
        .{ .name = .err, .label = "错误", .bg = math.Color.hex(0xDC2626FF) },
        .{ .name = .question, .label = "帮助", .bg = math.Color.hex(0x64748BFF) },
    };
    for (more_icons) |m| {
        const btn = try Button.create(alloc, m.label, .{
            .icon = m.name,
            .bg_color = m.bg,
            .bg_hover = math.Color.hex(0x475569FF),
        });
        try more_row.base.addChild(alloc, &btn.base);
    }

    // 第四行: 箭头 + 勾选
    const arrow_row = try Container.create(alloc, .{
        .direction = .row,
        .gap = .{ .width = 8, .height = 0 },
    });
    try demo.base.addChild(alloc, &arrow_row.base);

    const arrows = [_]struct { name: IconName, bg: math.Color }{
        .{ .name = .arrow_left, .bg = math.Color.hex(0x334155FF) },
        .{ .name = .arrow_up, .bg = math.Color.hex(0x334155FF) },
        .{ .name = .arrow_down, .bg = math.Color.hex(0x334155FF) },
        .{ .name = .arrow_right, .bg = math.Color.hex(0x334155FF) },
        .{ .name = .check, .bg = math.Color.hex(0x22C55EFF) },
        .{ .name = .plus, .bg = math.Color.hex(0x3B82F6FF) },
    };
    for (arrows) |a| {
        const btn = try Button.create(alloc, "", .{
            .icon = a.name,
            .icon_size = 18,
            .bg_color = a.bg,
            .bg_hover = math.Color.hex(0x475569FF),
            .corner_radius = 6,
            .padding_h = 10,
            .padding_v = 10,
        });
        try arrow_row.base.addChild(alloc, &btn.base);
    }
}

fn buildMenuButtonDemo(parent: *Container, alloc: std.mem.Allocator) !void {
    try addSection(parent, alloc, "MenuButton 菜单按钮");

    const demo = try Container.create(alloc, .{
        .direction = .row,
        .gap = .{ .width = 8, .height = 0 },
    });
    try parent.base.addChild(alloc, &demo.base);

    // 菜单按钮 1: 设置
    const popover1 = try Popover.create(alloc, .{ .position = .bottom });
    const menu_content1 = try Container.create(alloc, .{
        .bg_color = math.Color.hex(0x1E293BFF),
        .corner_radius = 8,
        .padding = math.EdgeInsets.all(8),
        .direction = .column,
        .gap = .{ .width = 0, .height = 4 },
    });
    const item1 = try Label.create(alloc, "  设置  ", .{ .font_size = 14, .color = math.Color.hex(0xF8FAFCFF) });
    try menu_content1.base.addChild(alloc, &item1.base);
    const item2 = try Label.create(alloc, "  关于  ", .{ .font_size = 14, .color = math.Color.hex(0xF8FAFCFF) });
    try menu_content1.base.addChild(alloc, &item2.base);
    try popover1.addChild(&menu_content1.base);
    try demo.base.addChild(alloc, &popover1.base);

    const btn1 = try MenuButton.create(alloc, "设置", .{});
    btn1.setPopover(popover1);
    try demo.base.addChild(alloc, &btn1.base);

    // 菜单按钮 2: 文件
    const popover2 = try Popover.create(alloc, .{ .position = .bottom });
    const menu_content2 = try Container.create(alloc, .{
        .bg_color = math.Color.hex(0x1E293BFF),
        .corner_radius = 8,
        .padding = math.EdgeInsets.all(8),
        .direction = .column,
        .gap = .{ .width = 0, .height = 4 },
    });
    const item3 = try Label.create(alloc, "  新建  ", .{ .font_size = 14, .color = math.Color.hex(0xF8FAFCFF) });
    try menu_content2.base.addChild(alloc, &item3.base);
    const item4 = try Label.create(alloc, "  打开  ", .{ .font_size = 14, .color = math.Color.hex(0xF8FAFCFF) });
    try menu_content2.base.addChild(alloc, &item4.base);
    const item5 = try Label.create(alloc, "  保存  ", .{ .font_size = 14, .color = math.Color.hex(0xF8FAFCFF) });
    try menu_content2.base.addChild(alloc, &item5.base);
    try popover2.addChild(&menu_content2.base);
    try demo.base.addChild(alloc, &popover2.base);

    const btn2 = try MenuButton.create(alloc, "文件", .{});
    btn2.setPopover(popover2);
    try demo.base.addChild(alloc, &btn2.base);
}

fn buildSearchEntryDemo(parent: *Container, alloc: std.mem.Allocator) !void {
    try addSection(parent, alloc, "SearchEntry 搜索框");

    const demo = try Container.create(alloc, .{
        .direction = .column,
        .gap = .{ .width = 0, .height = 8 },
    });
    try parent.base.addChild(alloc, &demo.base);

    const search = try SearchEntry.create(alloc, .{
        .placeholder = "输入关键词搜索...",
        .on_search = onSearch,
    });
    search.base.layout_style.width = .{ .px = 300 };
    try demo.base.addChild(alloc, &search.base);

    // 结果标签
    const result_lbl = try Label.create(alloc, "输入文字后按 ESC 清空", .{
        .font_size = 13,
        .color = math.Color.hex(0x64748BFF),
    });
    try demo.base.addChild(alloc, &result_lbl.base);
}

fn onSearch(entry: *SearchEntry, text: []const u8) void {
    _ = entry;
    _ = text;
}

fn buildInfoBarDemo(parent: *Container, alloc: std.mem.Allocator) !void {
    try addSection(parent, alloc, "InfoBar 通知消息条");

    const demo = try Container.create(alloc, .{
        .direction = .column,
        .gap = .{ .width = 0, .height = 8 },
    });
    try parent.base.addChild(alloc, &demo.base);

    // Info
    const info_bar = try InfoBar.create(alloc, "操作已完成, 数据已保存", .info, .{
        .on_response = infoBarResponse,
        .on_close = infoBarClose,
    });
    try info_bar.addAction("查看", 100);
    try info_bar.addAction("撤销", 101);
    try demo.base.addChild(alloc, &info_bar.base);

    // Warning
    const warn_bar = try InfoBar.create(alloc, "您的存储空间不足, 请清理", .warning, .{
        .on_close = infoBarClose,
    });
    try warn_bar.addAction("清理", 200);
    try demo.base.addChild(alloc, &warn_bar.base);

    // Error
    const err_bar = try InfoBar.create(alloc, "网络连接失败, 请检查网络设置", .err, .{
        .on_close = infoBarClose,
    });
    try err_bar.addAction("重试", 300);
    try demo.base.addChild(alloc, &err_bar.base);

    // Question (无关闭按钮)
    const q_bar = try InfoBar.create(alloc, "是否保存更改?", .question, .{
        .on_response = infoBarResponse,
    });
    try q_bar.addAction("保存", 400);
    try q_bar.addAction("不保存", 401);
    try demo.base.addChild(alloc, &q_bar.base);
}

fn infoBarResponse(bar: *InfoBar, response_id: i32) void {
    _ = bar;
    _ = response_id;
}

fn infoBarClose(bar: *InfoBar) void {
    _ = bar;
}

fn buildOverlayDemo(parent: *Container, alloc: std.mem.Allocator) !void {
    try addSection(parent, alloc, "Overlay 叠加层");

    const overlay_container = try Container.create(alloc, .{
        .bg_color = math.Color.hex(0x1E293BFF),
        .corner_radius = 12,
        .padding = math.EdgeInsets.all(16),
        .direction = .column,
        .gap = .{ .width = 0, .height = 10 },
    });
    try parent.base.addChild(alloc, &overlay_container.base);

    const overlay = try Overlay.create(alloc, .{
        .bg_color = math.Color.hex(0x0F172AFF),
        .corner_radius = 8,
        .height = .{ .px = 140 },
    });
    g_overlay = overlay;
    try overlay_container.base.addChild(alloc, &overlay.base);

    const base_content = try Container.create(alloc, .{
        .direction = .column,
        .padding = math.EdgeInsets.all(16),
    });
    const base_title = try Label.create(alloc, "基础内容层", .{
        .font_size = 16,
        .font_weight = 700,
        .color = math.Color.hex(0xF8FAFCFF),
    });
    try base_content.base.addChild(alloc, &base_title.base);
    const base_desc = try Label.create(alloc, "点击下方按钮显示/隐藏浮层", .{
        .font_size = 13,
        .color = math.Color.hex(0x94A3B8FF),
    });
    base_desc.base.layout_style.margin.top = 4;
    try base_content.base.addChild(alloc, &base_desc.base);
    try overlay.setChild(&base_content.base);

    const toggle_btn = try Button.create(alloc, "显示浮层", .{
        .on_click = onToggleOverlay,
    });
    toggle_btn.base.layout_style.height = .{ .px = 32 };
    try overlay_container.base.addChild(alloc, &toggle_btn.base);
}

fn buildExpanderDemo(parent: *Container, alloc: std.mem.Allocator) !void {
    try addSection(parent, alloc, "Expander 折叠面板 (带动画)");

    const expander = try Expander.create(alloc, "高级设置", .{
        .expanded = false,
        .header_bg = math.Color.hex(0x334155FF),
        .header_hover_bg = math.Color.hex(0x475569FF),
        .text_color = math.Color.hex(0xF1F5F9FF),
        .border_color = math.Color.hex(0x475569FF),
    });
    try parent.base.addChild(alloc, &expander.base);

    // 暂时去掉子项, 排查问题
    const content = try Container.create(alloc, .{
        .direction = .column,
        .gap = .{ .width = 0, .height = 8 },
        .padding = math.EdgeInsets.all(12),
    });
    try expander.base.addChild(alloc, &content.base);

    const opt1 = try Label.create(alloc, "• 选项一: 启用深色模式", .{
        .font_size = 13,
        .color = math.Color.hex(0x94A3B8FF),
    });
    try content.base.addChild(alloc, &opt1.base);
}

fn buildRevealerDemo(parent: *Container, alloc: std.mem.Allocator) !void {
    try addSection(parent, alloc, "Revealer 滑入/滑出 (带动画)");

    const demo = try Container.create(alloc, .{
        .direction = .column,
        .gap = .{ .width = 0, .height = 8 },
    });
    try parent.base.addChild(alloc, &demo.base);

    const btn_row = try Container.create(alloc, .{
        .direction = .row,
        .gap = .{ .width = 8, .height = 0 },
    });
    try demo.base.addChild(alloc, &btn_row.base);

    const toggle_btn = try Button.create(alloc, "显示/隐藏", .{
        .on_click = onToggleRevealer,
    });
    toggle_btn.base.layout_style.height = .{ .px = 28 };
    try btn_row.base.addChild(alloc, &toggle_btn.base);

    const revealer = try Revealer.create(alloc, .{
        .transition_type = .slide_down,
        .transition_duration_ms = 250,
    });
    g_revealer = revealer;
    try demo.base.addChild(alloc, &revealer.base);

    const rev_content = try Container.create(alloc, .{
        .bg_color = math.Color.hex(0x7C3AEDFF),
        .corner_radius = 8,
        .padding = math.EdgeInsets.all(12),
        .direction = .column,
    });
    try revealer.base.addChild(alloc, &rev_content.base);

    const rev_title = try Label.create(alloc, "✨ 新功能上线", .{
        .font_size = 14,
        .font_weight = 700,
        .color = math.Color.hex(0xFFFFFFFF),
    });
    try rev_content.base.addChild(alloc, &rev_title.base);

    const rev_desc = try Label.create(alloc, "现在支持平滑动画效果!", .{
        .font_size = 12,
        .color = math.Color.hex(0xE9D5FFFF),
    });
    rev_desc.base.layout_style.margin.top = 4;
    try rev_content.base.addChild(alloc, &rev_desc.base);
}

fn buildHexpandDemo(parent: *Container, alloc: std.mem.Allocator) !void {
    try addSection(parent, alloc, "hexpand / vexpand (GTK 风格扩展)");

    const row = try Container.create(alloc, .{
        .direction = .row,
        .gap = .{ .width = 8, .height = 0 },
        .height = .{ .px = 40 },
    });
    try parent.base.addChild(alloc, &row.base);

    const btn1 = try Container.create(alloc, .{
        .bg_color = math.Color.hex(0x475569FF),
        .corner_radius = 6,
        .direction = .row,
        .width = .{ .px = 60 },
        .height = .{ .px = 40 },
    });
    const lbl1 = try Label.create(alloc, "固定", .{
        .font_size = 13,
        .color = math.Color.hex(0xFFFFFFFF),
    });
    lbl1.base.layout_style.margin.left = 14;
    lbl1.base.layout_style.margin.top = 11;
    try btn1.base.addChild(alloc, &lbl1.base);
    try row.base.addChild(alloc, &btn1.base);

    const btn2 = try Container.create(alloc, .{
        .bg_color = math.Color.hex(0x3B82F6FF),
        .corner_radius = 6,
        .direction = .row,
        .height = .{ .px = 40 },
    });
    btn2.base.layout_style.hexpand = true;
    const lbl2 = try Label.create(alloc, "hexpand 填充", .{
        .font_size = 13,
        .color = math.Color.hex(0xFFFFFFFF),
    });
    lbl2.base.layout_style.margin.left = 14;
    lbl2.base.layout_style.margin.top = 11;
    try btn2.base.addChild(alloc, &lbl2.base);
    try row.base.addChild(alloc, &btn2.base);

    const btn3 = try Container.create(alloc, .{
        .bg_color = math.Color.hex(0x475569FF),
        .corner_radius = 6,
        .direction = .row,
        .width = .{ .px = 60 },
        .height = .{ .px = 40 },
    });
    const lbl3 = try Label.create(alloc, "固定", .{
        .font_size = 13,
        .color = math.Color.hex(0xFFFFFFFF),
    });
    lbl3.base.layout_style.margin.left = 14;
    lbl3.base.layout_style.margin.top = 11;
    try btn3.base.addChild(alloc, &lbl3.base);
    try row.base.addChild(alloc, &btn3.base);
}

fn buildAspectFrameDemo(parent: *Container, alloc: std.mem.Allocator) !void {
    try addSection(parent, alloc, "AspectFrame 保持宽高比 (16:9)");

    const aspect_frame = try AspectFrame.create(alloc, .{
        .ratio = 16.0 / 9.0,
        .xalign = 0.5,
        .yalign = 0.5,
        .bg_color = math.Color.hex(0x1E293BFF),
        .corner_radius = 8,
        .padding = math.EdgeInsets.all(8),
    });
    try parent.base.addChild(alloc, &aspect_frame.base);

    const content = try Container.create(alloc, .{
        .bg_color = math.Color.hex(0x0EA5E9FF),
        .corner_radius = 4,
        .direction = .column,
    });
    try aspect_frame.setChild(&content.base);

    const label = try Label.create(alloc, "16:9 Aspect", .{
        .font_size = 14,
        .font_weight = 700,
        .color = math.Color.hex(0xFFFFFFFF),
    });
    label.base.layout_style.margin.top = 20;
    label.base.layout_style.margin.left = 40;
    try content.base.addChild(alloc, &label.base);
}

fn destroyTree() void {
    if (g_root) |root| {
        root.destroy(g_alloc orelse return);
        g_root = null;
    }
}

fn onPrevPage(btn: *Button) void {
    if (g_stack) |s| {
        s.prev();
        updateStackLabel();
    }
    _ = btn;
}

fn onNextPage(btn: *Button) void {
    if (g_stack) |s| {
        s.next();
        updateStackLabel();
    }
    _ = btn;
}

fn updateStackLabel() void {
    if (g_stack) |s| {
        if (g_stack_label) |lbl| {
            const total = s.base.children.items.len;
            const current = s.getVisibleIndex() + 1;
            lbl.text = std.fmt.bufPrint(&g_stack_buf, "第 {d} / {d} 页", .{ current, total }) catch "?";
        }
    }
}

fn onToggleOverlay(btn: *Button) void {
    g_overlay_visible = !g_overlay_visible;
    if (g_overlay) |o| {
        const alloc = g_alloc orelse return;
        if (g_overlay_visible) {
            const float_layer = createFloatLayer(alloc) catch return;
            float_layer.base.layout_style.left = 20;
            float_layer.base.layout_style.top = 20;
            o.addOverlay(&float_layer.base) catch {};
            btn.label = "隐藏浮层";
        } else {
            if (o.base.children.items.len > 1) {
                const child = o.base.children.items[o.base.children.items.len - 1];
                o.base.removeChild(alloc, child);
                child.vtable.destroy(child, alloc);
            }
            btn.label = "显示浮层";
        }
    }
}

fn onToggleRevealer(btn: *Button) void {
    if (g_revealer) |r| {
        r.setRevealChild(!r.reveal_child);
        if (r.reveal_child) {
            btn.label = "隐藏";
        } else {
            btn.label = "显示";
        }
    }
}

fn createFloatLayer(alloc: std.mem.Allocator) !*Container {
    const layer = try Container.create(alloc, .{
        .bg_color = math.Color.hex(0x7C3AEDFF),
        .corner_radius = 10,
        .width = .{ .px = 200 },
        .height = .{ .px = 80 },
        .direction = .column,
        .padding = math.EdgeInsets.all(12),
    });
    const title = try Label.create(alloc, "浮层提示", .{
        .font_size = 14,
        .font_weight = 700,
        .color = math.Color.hex(0xFFFFFFFF),
    });
    try layer.base.addChild(alloc, &title.base);
    const desc = try Label.create(alloc, "这是一个叠加浮层", .{
        .font_size = 12,
        .color = math.Color.hex(0xE9D5FFFF),
    });
    desc.base.layout_style.margin.top = 4;
    try layer.base.addChild(alloc, &desc.base);
    return layer;
}

fn drawFrame(app: *zigui.app.App) void {
    g_frame += 1;
    const root = g_root orelse return;
    const fb = app.getFramebufferSize();
    const w: f32 = @floatFromInt(fb.width);
    const h: f32 = @floatFromInt(fb.height);

    dispatchInput(app);

    // 驱动动画
    const delta_ms = app.getDeltaMs();
    root.base.tickTree(delta_ms);

    // 更新 Tooltip
    g_tooltip_ctrl.update(&root.base, app.mouse_x, app.mouse_y, delta_ms);

    // 动态更新确定模式进度条
    if (g_determinate_pb) |pb| {
        g_pb_value += @as(f32, @floatFromInt(delta_ms)) / 1000.0 * 0.15; // 15%/秒
        if (g_pb_value > 1.0) g_pb_value = 0.0;
        pb.setValue(g_pb_value);
    }

    root.base.layout_style.width = .{ .px = w };
    root.base.layout_style.height = .{ .px = h };

    var ctx = widget.PaintContext{
        .renderer = app.getRenderer(),
        .theme = &theme_dark,
        .allocator = app.allocator,
    };
    root.base.performLayout(&ctx, .{ .max_width = w, .max_height = h });
    root.base.paintTree(&ctx);
}

fn dispatchInput(app: *zigui.app.App) void {
    const root = g_root orelse return;
    var ectx = widget.EventContext{ .mouse_x = app.mouse_x, .mouse_y = app.mouse_y };
    const mx: i32 = @intFromFloat(app.mouse_x);
    const my: i32 = @intFromFloat(app.mouse_y);

    var ev_move = pal.Event{ .mouse_move = .{ .window_id = 0, .x = mx, .y = my } };
    _ = root.base.dispatchEvent(&ev_move, &ectx);

    // 根据鼠标位置更新光标样式
    if (root.base.hitTest(app.mouse_x, app.mouse_y)) |hit| {
        app.setCursor(hit.resolveCursor());
    } else {
        app.setCursor(.arrow);
    }

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

    // 右键菜单: 点击外部关闭
    if (app.right_clicked) {
        const ctx_menu = g_context_menu orelse return;

        // 先派发右键事件 (Widget 基类会自动弹出有 context_menu 的控件的菜单)
        var ev_right = pal.Event{ .mouse_button = .{ .window_id = 0, .button = .right, .state = .pressed, .x = mx, .y = my } };
        _ = root.base.dispatchEvent(&ev_right, &ectx);

        // 如果菜单已经打开, 点击外部关闭
        if (ctx_menu.open and !ctx_menu.containsPoint(app.mouse_x, app.mouse_y)) {
            ctx_menu.popdown();
        }
    }

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

    // 分发文本输入 (字符)
    for (app.typedCodepoints()) |cp| {
        var ev = pal.Event{ .text_input = .{ .window_id = 0, .codepoint = cp } };
        _ = root.base.dispatchEvent(&ev, &ectx);
    }

    // 分发 IME 提交文本 (拷贝到固定数组, 帧末重置)
    const ime_text = app.imeCommitText();
    if (ime_text.len > 0) {
        var buf: [pal.event.max_ime_text]u8 = undefined;
        const n = @min(ime_text.len, buf.len);
        @memcpy(buf[0..n], ime_text[0..n]);
        var ev = pal.Event{ .ime_commit = .{ .window_id = 0, .text = buf, .len = @intCast(n) } };
        _ = root.base.dispatchEvent(&ev, &ectx);
    }
}
