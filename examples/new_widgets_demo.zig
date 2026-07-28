//! zigui 新控件综合示例 - 演示阶段1补齐的控件 (跨平台)
//!
//! 展示: Checkbox / Radio(+RadioGroup) / Switch / ProgressBar / Spinner /
//!       Image / ScrollView(+内置滚动条与裁剪) / ScrollBar 几何。
//!
//! 交互:
//!   - 点击 Checkbox / Radio / Switch 切换状态
//!   - 拖动 Slider 调节 ProgressBar 进度
//!   - 滚轮 / 方向键 / PageUp/Down 滚动右侧列表 (ScrollView 裁剪溢出内容)
//!   - Spinner 每帧 tick 旋转动画

const std = @import("std");
const zigui = @import("zigui");
const math = zigui.math;
const styled_text = zigui.styled_text;
const widget = zigui.widget;
const pal = zigui.pal;

const Container = zigui.container.Container;
const Label = zigui.label.Label;
const Checkbox = zigui.checkbox.Checkbox;
const Radio = zigui.radio.Radio;
const RadioGroup = zigui.radio.RadioGroup;
const Switch = zigui.switch_widget.Switch;
const ProgressBar = zigui.progress_bar.ProgressBar;
const Spinner = zigui.spinner.Spinner;
const Image = zigui.image_widget.Image;
const ScrollView = zigui.scroll_view.ScrollView;
const Slider = zigui.slider.Slider;

const logo_png = @embedFile("assets/zigui_logo.png");

const theme_dark: zigui.theme.Theme = zigui.theme.dark;

// ── 全局状态 ──────────────────────────────────────────────────────────────

var g_root: ?*Container = null;
var g_alloc: ?std.mem.Allocator = null;
var g_progress: ?*ProgressBar = null;
var g_spinner: ?*Spinner = null;
var g_scroll: ?*ScrollView = null;
var g_status_label: ?*Label = null;
var g_status_buf: [64]u8 = undefined;
var g_frame: u32 = 0;
var g_prev_mouse_down: bool = false;

// 滚动列表卡片标题的持久缓冲区 (Label.text 为借用切片, 需保证文本存活于整个应用生命周期;
// 不能用循环体内的临时栈缓冲区, 否则所有卡片共享同一被覆盖的内存)
const item_count = 30;
var g_item_titles: [item_count][16]u8 = undefined;

var g_radio_group: RadioGroup = RadioGroup.init(0, .{});

pub fn main() !void {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var app = try zigui.app.App.init(allocator, .{
        .title = "zigui - New Widgets Demo",
        .width = 860,
        .height = 600,
    });
    defer app.deinit();

    try buildTree(allocator);
    defer destroyTree();

    // ScrollView 默认获得焦点以支持键盘滚动
    if (g_scroll) |sv| sv.base.state.focused = true;

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

    // 标题栏
    const title_bar = try Container.create(alloc, .{
        .bg_color = math.Color.hex(0x1E293BFF),
        .direction = .row,
        .height = .{ .px = 48 },
        .padding = .{ .left = 20, .top = 12, .right = 12, .bottom = 0 },
    });
    try root.base.addChild(alloc, &title_bar.base);
    const title_label = try Label.create(alloc, "zigui New Widgets", .{
        .font_size = 20,
        .font_weight = 700,
        .color = math.Color.hex(0xF8FAFCFF),
    });
    try title_bar.base.addChild(alloc, &title_label.base);

    // 主体
    const body = try Container.create(alloc, .{
        .direction = .row,
        .gap = .{ .width = 20, .height = 0 },
        .padding = .{ .left = 20, .top = 20, .right = 20, .bottom = 20 },
    });
    body.base.layout_style.flex_grow = 1;
    try root.base.addChild(alloc, &body.base);

    try buildLeftPanel(body, alloc);
    try buildScrollArea(body, alloc);

    g_root = root;
    g_alloc = alloc;
}

fn buildLeftPanel(body: *Container, alloc: std.mem.Allocator) !void {
    const panel = try Container.create(alloc, .{
        .bg_color = math.Color.hex(0x1E293BFF),
        .corner_radius = 12,
        .direction = .column,
        .width = .{ .px = 300 },
        .padding = math.EdgeInsets.all(18),
        .gap = .{ .width = 0, .height = 14 },
    });
    try body.base.addChild(alloc, &panel.base);

    // Image 控件 (logo)
    const img = try Image.create(alloc, .{
        .png_data = logo_png,
        .sizing = .contain,
        .width = 64,
        .height = 64,
    });
    try panel.base.addChild(alloc, &img.base);

    try addSection(panel, alloc, "Checkbox");
    const cb1 = try Checkbox.create(alloc, "Enable notifications", .{ .checked = true });
    try panel.base.addChild(alloc, &cb1.base);
    const cb2 = try Checkbox.create(alloc, "Auto-save documents", .{});
    try panel.base.addChild(alloc, &cb2.base);

    try addSection(panel, alloc, "Radio Group");
    const r0 = try Radio.create(alloc, &g_radio_group, 0, "Small", .{});
    const r1 = try Radio.create(alloc, &g_radio_group, 1, "Medium", .{});
    const r2 = try Radio.create(alloc, &g_radio_group, 2, "Large", .{});
    try panel.base.addChild(alloc, &r0.base);
    try panel.base.addChild(alloc, &r1.base);
    try panel.base.addChild(alloc, &r2.base);

    try addSection(panel, alloc, "Switch");
    const sw = try Switch.create(alloc, .{ .label = "Dark Mode", .on = true, .on_change = onSwitchChange });
    try panel.base.addChild(alloc, &sw.base);

    try addSection(panel, alloc, "Slider -> ProgressBar");
    const slider = try Slider.create(alloc, .{ .value = 0.4, .min = 0, .max = 1, .on_change = onSliderChange });
    slider.base.layout_style.width = .{ .auto = {} };
    try panel.base.addChild(alloc, &slider.base);

    const pb = try ProgressBar.create(alloc, .{ .value = 0.4, .min = 0, .max = 1, .show_label = true });
    pb.base.layout_style.width = .{ .auto = {} };
    try panel.base.addChild(alloc, &pb.base);
    g_progress = pb;

    // 状态行: Spinner + 文本
    const status_row = try Container.create(alloc, .{
        .direction = .row,
        .gap = .{ .width = 10, .height = 0 },
    });
    status_row.base.layout_style.margin.top = 6;
    try panel.base.addChild(alloc, &status_row.base);

    const spinner = try Spinner.create(alloc, .{ .size = 22, .dot_radius = 2.5 });
    try status_row.base.addChild(alloc, &spinner.base);
    g_spinner = spinner;

    const status = try Label.create(alloc, "Loading...", .{
        .font_size = 13,
        .color = math.Color.hex(0x94A3B8FF),
    });
    status.base.layout_style.margin.top = 3;
    try status_row.base.addChild(alloc, &status.base);
    g_status_label = status;
}

fn buildScrollArea(body: *Container, alloc: std.mem.Allocator) !void {
    const sv = try ScrollView.create(alloc, .{
        .bg_color = math.Color.hex(0x1E293BFF),
        .corner_radius = 12,
        .direction = .column,
        .scroll_enabled_y = true,
        .padding = math.EdgeInsets.all(16),
        .gap = .{ .width = 0, .height = 10 },
    });
    sv.base.layout_style.flex_grow = 1;
    try body.base.addChild(alloc, &sv.base);
    g_scroll = sv;

    // 生成卡片内容, 远超视口高度以触发滚动 + 裁剪
    var i: usize = 0;
    while (i < item_count) : (i += 1) {
        const card = try Container.create(alloc, .{
            .bg_color = math.Color.hex(0x334155FF),
            .corner_radius = 8,
            .direction = .column,
            .height = .{ .px = 56 },
            .padding = .{ .left = 14, .top = 10, .right = 14, .bottom = 0 },
        });
        try sv.base.addChild(alloc, &card.base);

        // 每个卡片使用独立的全局缓冲区槽位, 避免临时栈缓冲区被后续迭代覆盖
        const text = std.fmt.bufPrint(&g_item_titles[i], "Item #{d}", .{i + 1}) catch "Item";
        const lbl = try Label.create(alloc, text, .{
            .font_size = 15,
            .font_weight = 600,
            .color = math.Color.hex(0xF8FAFCFF),
        });
        try card.base.addChild(alloc, &lbl.base);

        const sub = try Label.create(alloc, "Scroll to see clipping in action", .{
            .font_size = 11,
            .color = math.Color.hex(0x94A3B8FF),
        });
        sub.base.layout_style.margin.top = 4;
        try card.base.addChild(alloc, &sub.base);
    }
}

fn addSection(parent: *Container, alloc: std.mem.Allocator, text: []const u8) !void {
    const lbl = try Label.create(alloc, text, .{
        .font_size = 12,
        .font_weight = 700,
        .color = math.Color.hex(0x64748BFF),
    });
    lbl.base.layout_style.margin.top = 6;
    try parent.base.addChild(alloc, &lbl.base);
}

fn destroyTree() void {
    if (g_root) |root| {
        root.destroy(g_alloc orelse return);
        g_root = null;
    }
}

// ── 回调 ──────────────────────────────────────────────────────────────────

fn onSliderChange(s: *Slider, value: f32) void {
    if (g_progress) |pb| pb.setValue(value);
    _ = s;
}

fn onSwitchChange(sw: *Switch, on: bool) void {
    if (g_status_label) |lbl| {
        lbl.text = std.fmt.bufPrint(&g_status_buf, "Dark Mode: {s}", .{if (on) "ON" else "OFF"}) catch "Dark Mode";
    }
    _ = sw;
}

// ── 每帧: 输入分发 + 动画 + 布局 + 绘制 ────────────────────────────────────

fn drawFrame(app: *zigui.app.App) void {
    g_frame += 1;
    const root = g_root orelse return;
    const fb = app.getFramebufferSize();
    const w: f32 = @floatFromInt(fb.width);
    const h: f32 = @floatFromInt(fb.height);

    // 输入分发 (从 App 聚合状态合成事件)
    dispatchInput(app);

    // 动画
    if (g_spinner) |sp| sp.tick(16);

    // 布局 + 绘制
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

    // 鼠标移动 (悬停)
    var ev_move = pal.Event{ .mouse_move = .{ .window_id = 0, .x = mx, .y = my } };
    _ = root.base.dispatchEvent(&ev_move, &ectx);

    // 鼠标按下
    if (app.mouse_clicked) {
        var ev = pal.Event{ .mouse_button = .{ .window_id = 0, .button = .left, .state = .pressed, .x = mx, .y = my } };
        _ = root.base.dispatchEvent(&ev, &ectx);
    }
    // 鼠标释放 (经 mouse_down 边沿检测)
    const md = app.mouse_down;
    if (!md and g_prev_mouse_down) {
        var ev = pal.Event{ .mouse_button = .{ .window_id = 0, .button = .left, .state = .released, .x = mx, .y = my } };
        _ = root.base.dispatchEvent(&ev, &ectx);
    }
    g_prev_mouse_down = md;

    // 滚轮
    if (app.scroll_delta != 0) {
        var ev = pal.Event{ .scroll = .{ .window_id = 0, .axis = .vertical, .delta = app.scroll_delta } };
        _ = root.base.dispatchEvent(&ev, &ectx);
    }

    // 键盘 (方向键/PageUp/Down 滚动 ScrollView)
    if (app.key_hit) |key| {
        // Tab 焦点导航 (无障碍): Shift+Tab 后退, Tab 前进
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
