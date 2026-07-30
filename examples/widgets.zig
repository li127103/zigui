//! zigui widgets 示例 - 控件与布局演示 (跨平台)
//!
//! 演示:
//!   - Container 作为布局容器, 支持 row/column 方向与 gap/flex_grow/margin
//!   - Label 文本; Canvas 自绘; 真正的 Button 控件 (on_click 回调)
//!   - 背景色 / 圆角 / 阴影 均为 Widget 背景属性, 框架自动绘制
//!   - 事件分发: 在 drawFrame 中把 App 的鼠标/键盘状态翻译成 pal.Event 派发给控件树
//!
//! 运行:  zig build run-widgets

const std = @import("std");
const zigui = @import("zigui");
const math = zigui.math;
const styled_text = zigui.styled_text;

const widget = zigui.widget;
const Container = zigui.container.Container;
const Label = zigui.label.Label;
const Canvas = zigui.canvas.Canvas;
const Button = zigui.button.Button;
const pal = zigui.pal;

const theme_dark: zigui.theme.Theme = zigui.theme.dark;

var g_root: ?*Container = null;
var g_tree_alloc: ?std.mem.Allocator = null;

// 动态状态
var g_frame: u32 = 0;
var g_click_count: u32 = 0;
var g_click_label: ?*Label = null;
var g_click_buf: [32]u8 = undefined;
var g_prev_mouse_down: bool = false;

pub fn main() !void {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var app = try zigui.app.App.init(allocator, .{
        .title = "zigui - Widgets",
        .width = 820,
        .height = 600,
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
        .font_size = 20, .font_weight = 700, .color = math.Color.hex(0xF8FAFCFF),
    });
    title_label.base.layout_style.margin.top = 12;
    try title_bar.base.addChild(alloc, &title_label.base);

    const spacer = try Container.create(alloc, .{});
    spacer.base.layout_style.flex_grow = 1;
    try title_bar.base.addChild(alloc, &spacer.base);

    const dots = [_]u32{ 0xFF5F57FF, 0xFEBC2EFF, 0x28C840FF };
    for (dots) |dc| {
        const dot = try Container.create(alloc, .{
            .bg_color = math.Color.hex(dc), .corner_radius = 7,
            .width = .{ .px = 14 }, .height = .{ .px = 14 },
        });
        dot.base.layout_style.margin.top = 17;
        try title_bar.base.addChild(alloc, &dot.base);
    }

    // ── 主体: 左面板 + 右列 ──
    const body = try Container.create(alloc, .{
        .direction = .row,
        .gap = .{ .width = 24, .height = 0 },
        .padding = .{ .left = 24, .top = 24, .right = 24, .bottom = 0 },
    });
    body.base.layout_style.flex_grow = 1;
    try root.base.addChild(alloc, &body.base);

    // 左面板
    const left = try Container.create(alloc, .{
        .bg_color = math.Color.hex(0x1E293BFF), .corner_radius = 12,
        .direction = .column, .width = .{ .px = 220 },
        .padding = math.EdgeInsets.all(16), .gap = .{ .width = 0, .height = 12 },
    });
    try body.base.addChild(alloc, &left.base);

    const bl = try Label.create(alloc, "Buttons", .{ .font_size = 14, .font_weight = 600, .color = math.Color.hex(0x94A3B8FF) });
    try left.base.addChild(alloc, &bl.base);

    // 真正的 Button 控件: 点击后回调里自增计数
    const counter_btn = try Button.create(alloc, "Click me!", .{ .on_click = onButtonClick });
    counter_btn.base.layout_style.height = .{ .px = 40 };
    try left.base.addChild(alloc, &counter_btn.base);

    // Container 风格按钮 (仅作视觉展示, 非交互)
    try addSwatch(left, alloc, "Primary", 0x3B82F6FF);
    try addSwatch(left, alloc, "Success", 0x22C55EFF);
    try addSwatch(left, alloc, "Warning", 0xF59E0BFF);
    try addSwatch(left, alloc, "Danger", 0xEF4444FF);

    // 右列
    const right = try Container.create(alloc, .{
        .direction = .column, .gap = .{ .width = 0, .height = 20 },
    });
    right.base.layout_style.flex_grow = 1;
    try body.base.addChild(alloc, &right.base);

    // 信息卡
    const info = try Container.create(alloc, .{
        .bg_color = math.Color.hex(0x1E293BFF), .corner_radius = 12,
        .direction = .column, .height = .{ .px = 150 },
        .padding = .{ .left = 20, .top = 16, .right = 20, .bottom = 0 },
    });
    try right.base.addChild(alloc, &info.base);
    try addLine(info, alloc, "Retained-mode widget tree", 18, 700, 0xF8FAFCFF);
    try addLine(info, alloc, "Flexbox layout (row / column / gap)", 13, 400, 0x94A3B8FF);
    try addLine(info, alloc, "Event bubbling + hit-test", 13, 400, 0x94A3B8FF);
    try addLine(info, alloc, "GPU glyph atlas text", 13, 400, 0x94A3B8FF);

    // 两个统计卡 (Frame / Clicks)
    const stat_row = try Container.create(alloc, .{ .direction = .row, .gap = .{ .width = 16, .height = 0 } });
    try right.base.addChild(alloc, &stat_row.base);
    g_click_label = try addStat(stat_row, alloc, "Clicks", 0x22C55EFF);
    _ = try addStat(stat_row, alloc, "Frame", 0x38BDF8FF);

    // 进度卡 (Canvas 动画)
    const prog = try Container.create(alloc, .{
        .bg_color = math.Color.hex(0x1E293BFF), .corner_radius = 10,
        .direction = .column, .height = .{ .px = 70 },
        .padding = .{ .left = 16, .top = 12, .right = 16, .bottom = 0 },
    });
    try right.base.addChild(alloc, &prog.base);
    try addLine(prog, alloc, "Progress", 12, 400, 0x64748BFF);
    const bar = try Canvas.create(alloc, .{ .paint_fn = paintProgress });
    bar.base.layout_style.margin.top = 12;
    bar.base.layout_style.height = .{ .px = 8 };
    bar.base.layout_style.width = .{ .auto = {} };
    try prog.base.addChild(alloc, &bar.base);

    g_root = root;
    g_tree_alloc = alloc;
}

fn onButtonClick(_: *Button) void {
    g_click_count += 1;
}

fn addSwatch(parent: *Container, alloc: std.mem.Allocator, text: []const u8, color: u32) !void {
    const btn = try Container.create(alloc, .{
        .bg_color = math.Color.hex(color), .corner_radius = 8,
        .direction = .column, .height = .{ .px = 36 },
    });
    const lbl = try Label.create(alloc, text, .{
        .font_size = 14, .font_weight = 500, .color = math.Color.hex(0xFFFFFFFF),
        .text_align = .center,
    });
    lbl.base.layout_style.margin.top = 9;
    try btn.base.addChild(alloc, &lbl.base);
    try parent.base.addChild(alloc, &btn.base);
}

fn addLine(parent: *Container, alloc: std.mem.Allocator, text: []const u8, size: f32, weight: u16, color: u32) !void {
    const lbl = try Label.create(alloc, text, .{ .font_size = size, .font_weight = weight, .color = math.Color.hex(color) });
    lbl.base.layout_style.margin.top = 8;
    try parent.base.addChild(alloc, &lbl.base);
}

fn addStat(parent: *Container, alloc: std.mem.Allocator, label: []const u8, color: u32) !*Label {
    const card = try Container.create(alloc, .{
        .bg_color = math.Color.hex(0x1E293BFF), .corner_radius = 10,
        .direction = .column, .height = .{ .px = 90 },
        .padding = .{ .left = 16, .top = 14, .right = 16, .bottom = 0 },
    });
    card.base.layout_style.flex_grow = 1;
    try parent.base.addChild(alloc, &card.base);
    try addLine(card, alloc, label, 12, 400, 0x64748BFF);
    const val = try Label.create(alloc, "0", .{ .font_size = 26, .font_weight = 700, .color = math.Color.hex(color) });
    val.base.layout_style.margin.top = 8;
    try card.base.addChild(alloc, &val.base);
    return val;
}

fn destroyTree() void {
    if (g_root) |root| {
        root.destroy(g_tree_alloc orelse return);
        g_root = null;
    }
}

fn drawFrame(app: *zigui.app.App) void {
    g_frame += 1;
    const root = g_root orelse return;
    const fb = app.getFramebufferSize();
    const w: f32 = @floatFromInt(fb.width);
    const h: f32 = @floatFromInt(fb.height);

    // 每帧更新动态 Label
    if (g_click_label) |cl| {
        cl.text = std.fmt.bufPrint(&g_click_buf, "{d}", .{g_click_count}) catch "0";
    }

    root.base.layout_style.width = .{ .px = w };
    root.base.layout_style.height = .{ .px = h };

    var ctx = widget.PaintContext{ .renderer = app.getRenderer(), .theme = &theme_dark, .allocator = app.allocator };
    root.base.performLayout(&ctx, .{ .max_width = w, .max_height = h });

    dispatchInput(app);

    root.base.paintTree(&ctx);
}

// 把 App 的鼠标/键盘状态派发为事件给控件树 (Button 据此触发 on_click)
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

fn paintProgress(w: *widget.Widget, ctx: *widget.PaintContext) void {
    const ax = ctx.offset_x + w.rect.x;
    const ay = ctx.offset_y + w.rect.y;
    const bw = w.rect.width;
    ctx.renderer.fillRoundedRect(.{ .x = ax, .y = ay, .width = bw, .height = 8 }, 4, math.Color.hex(0x334155FF)) catch {};
    const p: f32 = @sin(@as(f32, @floatFromInt(g_frame)) * 0.03) * 0.5 + 0.5;
    const fw = bw * p;
    if (fw > 4) {
        ctx.renderer.fillRoundedRect(.{ .x = ax, .y = ay, .width = fw, .height = 8 }, 4, math.Color.hex(0x8B5CF6FF)) catch {};
    }
}
