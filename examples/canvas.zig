//! zigui canvas 示例 - Canvas 自绘 (进度条 / 柱状图 / 图形)
//!
//! 演示:
//!   - Canvas 控件 + paint_fn 回调, 拿到 Renderer2D 直接绘制
//!   - fillRect / fillRoundedRect / fillCircle 基元
//!   - 用 g_frame 驱动简单动画 (无需外部计时器)
//!
//! 运行:  zig build run-canvas

const std = @import("std");
const zigui = @import("zigui");
const math = zigui.math;
const styled_text = zigui.styled_text;

const widget = zigui.widget;
const Container = zigui.container.Container;
const Label = zigui.label.Label;
const Canvas = zigui.canvas.Canvas;

const theme_dark: zigui.theme.Theme = zigui.theme.dark;

var g_root: ?*Container = null;
var g_tree_alloc: ?std.mem.Allocator = null;
var g_frame: u32 = 0;

// 柱状图数据 (一周)
const bars = [_]f32{ 0.4, 0.7, 0.55, 0.9, 0.35, 0.6, 0.8 };
const bar_colors = [_]u32{ 0x3B82F6FF, 0x22C55EFF, 0xF59E0BFF, 0xEF4444FF, 0x8B5CF6FF, 0x06B6D4FF, 0xF472B6FF };

pub fn main() !void {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var app = try zigui.app.App.init(allocator, .{ .title = "zigui - Canvas", .width = 900, .height = 640 });
    defer app.deinit();

    try buildTree(allocator);
    defer destroyTree();

    try app.run(&drawFrame);
    styled_text.deinitFontCache();
}

fn buildTree(alloc: std.mem.Allocator) !void {
    const root = try Container.create(alloc, .{
        .bg_color = math.Color.hex(0x0F172AFF), .direction = .column,
        .padding = .{ .left = 30, .top = 30, .right = 30, .bottom = 30 }, .gap = .{ .width = 0, .height = 24 },
    });
    errdefer root.destroy(alloc);

    const title = try Label.create(alloc, "Canvas Drawing", .{ .font_size = 22, .font_weight = 700, .color = math.Color.hex(0xF8FAFCFF) });
    try root.base.addChild(alloc, &title.base);

    const row = try Container.create(alloc, .{ .direction = .row, .gap = .{ .width = 24, .height = 0 } });
    row.base.layout_style.flex_grow = 1;
    try root.base.addChild(alloc, &row.base);

    try addCard(row, alloc, "Progress", paintProgress);
    try addCard(row, alloc, "Bar Chart", paintChart);
    try addCard(row, alloc, "Shapes", paintShapes);

    g_root = root;
    g_tree_alloc = alloc;
}

fn addCard(parent: *Container, alloc: std.mem.Allocator, label: []const u8, paint_fn: *const fn (*widget.Widget, *widget.PaintContext) void) !void {
    const card = try Container.create(alloc, .{
        .bg_color = math.Color.hex(0x1E293BFF), .corner_radius = 14, .direction = .column,
        .padding = .{ .left = 16, .top = 14, .right = 16, .bottom = 16 },
    });
    card.base.layout_style.flex_grow = 1;
    card.base.layout_style.width = .{ .auto = {} };
    try parent.base.addChild(alloc, &card.base);

    const lbl = try Label.create(alloc, label, .{ .font_size = 14, .font_weight = 600, .color = math.Color.hex(0x60A5FAFF) });
    try card.base.addChild(alloc, &lbl.base);

    const canvas = try Canvas.create(alloc, .{ .paint_fn = paint_fn });
    canvas.base.layout_style.margin.top = 14;
    canvas.base.layout_style.flex_grow = 1;
    canvas.base.layout_style.width = .{ .auto = {} };
    try card.base.addChild(alloc, &canvas.base);
}

fn destroyTree() void {
    if (g_root) |root| { root.destroy(g_tree_alloc orelse return); g_root = null; }
}

fn drawFrame(app: *zigui.app.App) void {
    g_frame += 1;
    const root = g_root orelse return;
    const fb = app.getFramebufferSize();
    const w: f32 = @floatFromInt(fb.width);
    const h: f32 = @floatFromInt(fb.height);

    root.base.layout_style.width = .{ .px = w };
    root.base.layout_style.height = .{ .px = h };

    var ctx = widget.PaintContext{ .renderer = app.getRenderer(), .theme = &theme_dark, .allocator = app.allocator };
    root.base.performLayout(&ctx, .{ .max_width = w, .max_height = h });
    root.base.paintTree(&ctx);
}

// 动画进度条
fn paintProgress(w: *widget.Widget, ctx: *widget.PaintContext) void {
    const ax = ctx.offset_x + w.rect.x;
    const ay = ctx.offset_y + w.rect.y;
    const bw = w.rect.width;
    const bh = w.rect.height;
    const bar_y = ay + bh * 0.5 - 6;
    ctx.renderer.fillRoundedRect(.{ .x = ax, .y = bar_y, .width = bw, .height = 12 }, 6, math.Color.hex(0x334155FF)) catch {};
    const p: f32 = @sin(@as(f32, @floatFromInt(g_frame)) * 0.03) * 0.5 + 0.5;
    const fw = @max(12, bw * p);
    if (fw > 4) {
        ctx.renderer.fillRoundedRect(.{ .x = ax, .y = bar_y, .width = fw, .height = 12 }, 6, math.Color.hex(0x8B5CF6FF)) catch {};
    }
}

// 柱状图
fn paintChart(w: *widget.Widget, ctx: *widget.PaintContext) void {
    const ax = ctx.offset_x + w.rect.x;
    const ay = ctx.offset_y + w.rect.y;
    const bw = w.rect.width;
    const bh = w.rect.height;
    const n: f32 = @floatFromInt(bars.len);
    const slot = bw / n;
    const bar_w = slot * 0.6;
    const max_h = bh - 30;
    var idx: usize = 0;
    while (idx < bars.len) : (idx += 1) {
        const cx = ax + slot * @as(f32, @floatFromInt(idx)) + (slot - bar_w) / 2;
        const bar_h = max_h * bars[idx];
        const cy = ay + bh - bar_h - 10;
        ctx.renderer.fillRoundedRect(.{ .x = cx, .y = cy, .width = bar_w, .height = bar_h }, 6, math.Color.hex(bar_colors[idx])) catch {};
    }
}

// 图形: 圆 + 圆角矩形 + 文本
fn paintShapes(w: *widget.Widget, ctx: *widget.PaintContext) void {
    const ax = ctx.offset_x + w.rect.x;
    const ay = ctx.offset_y + w.rect.y;
    const bw = w.rect.width;
    const bh = w.rect.height;

    // 背景圆角面板
    ctx.renderer.fillRoundedRect(.{ .x = ax + 10, .y = ay + 10, .width = bw - 20, .height = bh - 20 }, 16, math.Color.hex(0x0F172AFF)) catch {};

    const cx = ax + bw * 0.5;
    const cy = ay + bh * 0.5;
    ctx.renderer.fillCircle(cx - 70, cy, 30, math.Color.hex(0x22C55EFF)) catch {};
    ctx.renderer.fillCircle(cx, cy - 40, 30, math.Color.hex(0xEF4444FF)) catch {};
    ctx.renderer.fillCircle(cx + 70, cy, 30, math.Color.hex(0xF59E0BFF)) catch {};
    ctx.renderer.fillCircle(cx, cy + 40, 30, math.Color.hex(0x8B5CF6FF)) catch {};

    styled_text.drawText(ctx.renderer, ctx.allocator, "shapes", ax + 16, ay + 24, .{ .font_size = 14, .font_weight = 600, .color = math.Color.hex(0xF8FAFCFF) });
}
