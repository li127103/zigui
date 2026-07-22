//! zigui widgets 示例 - 控件系统演示 (跨平台)
//!
//! 所有背景 (窗口/标题栏/面板/卡片/按钮/进度条轨道/状态栏) 均为 Widget 背景属性,
//! 由框架在 paintTree 中自动绘制, 示例代码不再手动 fillRect。

const std = @import("std");
const builtin = @import("builtin");
const zigui = @import("zigui");
const math = zigui.math;
const styled_text = zigui.styled_text;

const widget = zigui.widget;
const Container = zigui.container.Container;
const Label = zigui.label.Label;
const Canvas = zigui.canvas.Canvas;

const is_linux = builtin.os.tag == .linux;
const is_macos = builtin.os.tag == .macos;

/// 主题 (PaintContext 需要 *const Theme)
const theme_dark: zigui.theme.Theme = zigui.theme.dark;

var g_root: ?*Container = null;
var g_tree_alloc: ?std.mem.Allocator = null;

// 动态数值 Label (每帧更新文本)
var g_frame_label: ?*Label = null;
var g_click_label: ?*Label = null;
var g_frame_buf: [32]u8 = undefined;
var g_click_buf: [32]u8 = undefined;

var g_click_count: u32 = 0;
var g_frame: u32 = 0;

pub fn main() !void {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var app = try zigui.app.App.init(allocator, .{
        .title = "zigui - Widgets Demo",
        .width = 800,
        .height = 600,
    });
    defer app.deinit();

    try buildTree(allocator);
    defer destroyTree();

    try app.run(&drawFrame);

    styled_text.deinitFontCache();
}

// ── 控件树构建 (背景全部为 Widget 属性) ─────────────────────────────────────

fn buildTree(alloc: std.mem.Allocator) !void {
    // 根容器: 窗口背景色
    const root = try Container.create(alloc, .{
        .bg_color = math.Color.hex(0x0F172AFF),
        .direction = .column,
    });
    errdefer root.destroy(alloc);

    // ── 标题栏 ──
    const title_bar = try Container.create(alloc, .{
        .bg_color = math.Color.hex(0x1E293BFF),
        .direction = .row,
        .height = .{ .px = 48 },
        .padding = .{ .left = 20, .top = 0, .right = 12, .bottom = 0 },
        .gap = .{ .width = 8, .height = 0 },
    });
    try root.base.addChild(alloc, &title_bar.base);

    const title_label = try Label.create(alloc, "zigui Widgets", .{
        .font_size = 20,
        .font_weight = 700,
        .color = math.Color.hex(0xF8FAFCFF),
    });
    title_label.base.layout_style.margin.top = 12;
    try title_bar.base.addChild(alloc, &title_label.base);

    // 弹性占位, 把装饰点推到右侧
    const spacer = try Container.create(alloc, .{});
    spacer.base.layout_style.flex_grow = 1;
    try title_bar.base.addChild(alloc, &spacer.base);

    const dots = [_]u32{ 0xFF5F57FF, 0xFEBC2EFF, 0x28C840FF };
    for (dots) |dc| {
        const dot = try Container.create(alloc, .{
            .bg_color = math.Color.hex(dc),
            .corner_radius = 7,
            .width = .{ .px = 14 },
            .height = .{ .px = 14 },
        });
        dot.base.layout_style.margin.top = 17;
        try title_bar.base.addChild(alloc, &dot.base);
    }

    // ── 主体 (左侧按钮面板 + 右侧卡片列) ──
    const body = try Container.create(alloc, .{
        .direction = .row,
        .gap = .{ .width = 24, .height = 0 },
        .padding = .{ .left = 24, .top = 24, .right = 24, .bottom = 0 },
    });
    body.base.layout_style.flex_grow = 1;
    try root.base.addChild(alloc, &body.base);

    // 左侧面板: 按钮组
    const left_panel = try Container.create(alloc, .{
        .bg_color = math.Color.hex(0x1E293BFF),
        .corner_radius = 12,
        .direction = .column,
        .width = .{ .px = 220 },
        .padding = math.EdgeInsets.all(16),
        .gap = .{ .width = 0, .height = 12 },
    });
    try body.base.addChild(alloc, &left_panel.base);

    const buttons_label = try Label.create(alloc, "Buttons", .{
        .font_size = 14,
        .font_weight = 600,
        .color = math.Color.hex(0x94A3B8FF),
    });
    try left_panel.base.addChild(alloc, &buttons_label.base);

    try addButton(left_panel, alloc, "Primary", 0x3B82F6FF, 0xFFFFFFFF);
    try addButton(left_panel, alloc, "Success", 0x22C55EFF, 0xFFFFFFFF);
    try addButton(left_panel, alloc, "Warning", 0xF59E0BFF, 0x1E293BFF);
    try addButton(left_panel, alloc, "Danger", 0xEF4444FF, 0xFFFFFFFF);
    // Outline 按钮: 边框色背景 + 内层面板色背景
    try addOutlineButton(left_panel, alloc);

    // 右侧列
    const right_col = try Container.create(alloc, .{
        .direction = .column,
        .gap = .{ .width = 0, .height = 20 },
    });
    right_col.base.layout_style.flex_grow = 1;
    try body.base.addChild(alloc, &right_col.base);

    // 信息卡片 (背景 + 顶部强调色条)
    const info_card = try Container.create(alloc, .{
        .bg_color = math.Color.hex(0x1E293BFF),
        .corner_radius = 12,
        .direction = .column,
        .height = .{ .px = 160 },
    });
    try right_col.base.addChild(alloc, &info_card.base);

    const info_strip = try Container.create(alloc, .{
        .bg_color = math.Color.hex(0x8B5CF6FF),
        .corner_radius = 2,
        .height = .{ .px = 4 },
    });
    try info_card.base.addChild(alloc, &info_strip.base);

    try addInfoLabel(info_card, alloc, "Widget System", 18, 700, 0xF8FAFCFF, 20, 16);
    try addInfoLabel(info_card, alloc, "Retained-mode widget tree with:", 14, 400, 0xCBD5E1FF, 20, 10);
    try addInfoLabel(info_card, alloc, "  - VTable polymorphism (zero-cost)", 13, 400, 0x94A3B8FF, 20, 8);
    try addInfoLabel(info_card, alloc, "  - Flexbox layout (row/column/gap)", 13, 400, 0x94A3B8FF, 20, 4);
    try addInfoLabel(info_card, alloc, "  - Event bubbling + hit-test", 13, 400, 0x94A3B8FF, 20, 4);
    try addInfoLabel(info_card, alloc, "  - GPU glyph atlas rendering", 13, 400, 0x94A3B8FF, 20, 4);

    // 统计卡片行
    const stat_row = try Container.create(alloc, .{
        .direction = .row,
        .gap = .{ .width = 16, .height = 0 },
    });
    try right_col.base.addChild(alloc, &stat_row.base);

    const frame_card = try Container.create(alloc, .{
        .bg_color = math.Color.hex(0x1E293BFF),
        .corner_radius = 10,
        .direction = .column,
        .height = .{ .px = 100 },
        .padding = .{ .left = 16, .top = 16, .right = 16, .bottom = 0 },
    });
    frame_card.base.layout_style.flex_grow = 1;
    try stat_row.base.addChild(alloc, &frame_card.base);

    try addInfoLabel(frame_card, alloc, "Frame", 12, 400, 0x64748BFF, 0, 0);
    const frame_value = try Label.create(alloc, "0", .{
        .font_size = 28,
        .font_weight = 700,
        .color = math.Color.hex(0x38BDF8FF),
    });
    frame_value.base.layout_style.margin.top = 8;
    try frame_card.base.addChild(alloc, &frame_value.base);
    g_frame_label = frame_value;

    const click_card = try Container.create(alloc, .{
        .bg_color = math.Color.hex(0x1E293BFF),
        .corner_radius = 10,
        .direction = .column,
        .height = .{ .px = 100 },
        .padding = .{ .left = 16, .top = 16, .right = 16, .bottom = 0 },
    });
    click_card.base.layout_style.flex_grow = 1;
    try stat_row.base.addChild(alloc, &click_card.base);

    try addInfoLabel(click_card, alloc, "Clicks", 12, 400, 0x64748BFF, 0, 0);
    const click_value = try Label.create(alloc, "0", .{
        .font_size = 28,
        .font_weight = 700,
        .color = math.Color.hex(0x22C55EFF),
    });
    click_value.base.layout_style.margin.top = 8;
    try click_card.base.addChild(alloc, &click_value.base);
    g_click_label = click_value;

    // 进度卡片 (背景 + Canvas 绘制动画进度条)
    const progress_card = try Container.create(alloc, .{
        .bg_color = math.Color.hex(0x1E293BFF),
        .corner_radius = 10,
        .direction = .column,
        .height = .{ .px = 80 },
        .padding = .{ .left = 16, .top = 12, .right = 16, .bottom = 0 },
    });
    try right_col.base.addChild(alloc, &progress_card.base);

    try addInfoLabel(progress_card, alloc, "Progress", 12, 400, 0x64748BFF, 0, 0);

    const progress_bar = try Canvas.create(alloc, .{
        .paint_fn = paintProgressBar,
    });
    progress_bar.base.layout_style.margin.top = 12;
    progress_bar.base.layout_style.height = .{ .px = 8 };
    progress_bar.base.layout_style.width = .{ .auto = {} };
    try progress_card.base.addChild(alloc, &progress_bar.base);

    // ── 底部状态栏 ──
    const status_bar = try Container.create(alloc, .{
        .bg_color = math.Color.hex(0x1E293BFF),
        .direction = .row,
        .height = .{ .px = 28 },
    });
    try root.base.addChild(alloc, &status_bar.base);

    const status_label = try Label.create(alloc, "zigui v0.1.0  |  Widget Tree: Container > Label + Button  |  Flexbox Layout", .{
        .font_size = 11,
        .font_weight = 400,
        .color = math.Color.hex(0x64748BFF),
    });
    status_label.base.layout_style.margin.left = 12;
    status_label.base.layout_style.margin.top = 6;
    try status_bar.base.addChild(alloc, &status_label.base);

    g_root = root;
    g_tree_alloc = alloc;
}

/// 实心按钮 (背景色属性 + 居中文本)
fn addButton(parent: *Container, alloc: std.mem.Allocator, text: []const u8, bg: u32, text_color: u32) !void {
    const btn = try Container.create(alloc, .{
        .bg_color = math.Color.hex(bg),
        .corner_radius = 8,
        .direction = .column,
        .height = .{ .px = 38 },
    });
    try parent.base.addChild(alloc, &btn.base);

    const lbl = try Label.create(alloc, text, .{
        .font_size = 14,
        .font_weight = 500,
        .color = math.Color.hex(text_color),
        .text_align = .center,
    });
    lbl.base.layout_style.margin.top = 10;
    try btn.base.addChild(alloc, &lbl.base);
}

/// 描边按钮 (外层边框色背景 + 内层面板色背景 + 居中文本)
fn addOutlineButton(parent: *Container, alloc: std.mem.Allocator) !void {
    const outer = try Container.create(alloc, .{
        .bg_color = math.Color.hex(0x3B82F6FF),
        .corner_radius = 8,
        .direction = .column,
        .height = .{ .px = 38 },
        .padding = math.EdgeInsets.all(1.5),
    });
    try parent.base.addChild(alloc, &outer.base);

    const inner = try Container.create(alloc, .{
        .bg_color = math.Color.hex(0x1E293BFF),
        .corner_radius = 7,
        .direction = .column,
    });
    inner.base.layout_style.flex_grow = 1;
    try outer.base.addChild(alloc, &inner.base);

    const lbl = try Label.create(alloc, "Outline", .{
        .font_size = 14,
        .font_weight = 500,
        .color = math.Color.hex(0x3B82F6FF),
        .text_align = .center,
    });
    lbl.base.layout_style.margin.top = 9;
    try inner.base.addChild(alloc, &lbl.base);
}

/// 信息文本 (带左边距与上边距)
fn addInfoLabel(parent: *Container, alloc: std.mem.Allocator, text: []const u8, size: f32, weight: u16, color: u32, left: f32, top: f32) !void {
    const lbl = try Label.create(alloc, text, .{
        .font_size = size,
        .font_weight = weight,
        .color = math.Color.hex(color),
    });
    lbl.base.layout_style.margin.left = left;
    lbl.base.layout_style.margin.top = top;
    try parent.base.addChild(alloc, &lbl.base);
}

fn destroyTree() void {
    if (g_root) |root| {
        root.destroy(g_tree_alloc orelse return);
        g_root = null;
    }
}

// ── 每帧: 更新动态数值 + 布局 + 绘制 (背景由框架自动绘制) ───────────────────

fn drawFrame(app: *zigui.app.App) void {
    g_frame += 1;
    const root = g_root orelse return;
    const fb = app.getFramebufferSize();
    const w: f32 = @floatFromInt(fb.width);
    const h: f32 = @floatFromInt(fb.height);

    // 更新动态数值 Label
    if (g_frame_label) |fl| {
        fl.text = std.fmt.bufPrint(&g_frame_buf, "{d}", .{g_frame}) catch "0";
    }
    if (g_click_label) |cl| {
        cl.text = std.fmt.bufPrint(&g_click_buf, "{d}", .{g_click_count}) catch "0";
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

// ── 进度条绘制 (Canvas paint_fn, 轨道背景由父卡片属性提供) ──────────────────

fn paintProgressBar(w: *widget.Widget, ctx: *widget.PaintContext) void {
    const ax = ctx.offset_x + w.rect.x;
    const ay = ctx.offset_y + w.rect.y;
    const bar_w = w.rect.width;

    // 轨道
    ctx.renderer.fillRoundedRect(.{ .x = ax, .y = ay, .width = bar_w, .height = 8 }, 4, math.Color.hex(0x334155FF)) catch {};

    // 动画填充
    const progress: f32 = @sin(@as(f32, @floatFromInt(g_frame)) * 0.02) * 0.5 + 0.5;
    const fill_w = bar_w * progress;
    if (fill_w > 4) {
        ctx.renderer.fillRoundedRect(.{ .x = ax, .y = ay, .width = fill_w, .height = 8 }, 4, math.Color.hex(0x8B5CF6FF)) catch {};
    }
}
