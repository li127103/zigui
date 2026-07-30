//! zigui text 示例 - 文本渲染与对齐 (字体 / 字号 / 对齐方式)
//!
//! 演示:
//!   - styled_text.drawText 直接绘制, 支持 font_size / font_weight / color
//!   - 四种水平对齐: left / center / right / justify (自动断行 word wrap)
//!   - 中英混排段落
//!
//! 运行:  zig build run-text

const std = @import("std");
const zigui = @import("zigui");
const math = zigui.math;
const styled_text = zigui.styled_text;

const widget = zigui.widget;
const Container = zigui.container.Container;
const Label = zigui.label.Label;
const Canvas = zigui.canvas.Canvas;

const theme_dark: zigui.theme.Theme = zigui.theme.dark;

const paragraph =
    "zigui 是用 Zig 构建的跨平台 GPU 加速 GUI 框架。The text layout engine " ++
    "supports multi-line word wrapping and four alignment modes. " ++
    "文本布局引擎支持多行自动断行，并提供左对齐、居中、右对齐与两端对齐四种排版方式。";

var g_root: ?*Container = null;
var g_tree_alloc: ?std.mem.Allocator = null;

pub fn main() !void {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var app = try zigui.app.App.init(allocator, .{ .title = "zigui - Text", .width = 960, .height = 720 });
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

    const title = try Label.create(alloc, "Text Rendering & Alignment", .{ .font_size = 22, .font_weight = 700, .color = math.Color.hex(0xF8FAFCFF) });
    try root.base.addChild(alloc, &title.base);

    // 字号 / 字重 展示卡
    const font_card = try Canvas.create(alloc, .{ .bg_color = math.Color.hex(0x1E293BFF), .corner_radius = 14, .paint_fn = paintFontShowcase });
    font_card.base.layout_style.height = .{ .px = 150 };
    font_card.base.layout_style.width = .{ .auto = {} };
    try root.base.addChild(alloc, &font_card.base);

    // 2x2 对齐卡
    const row1 = try Container.create(alloc, .{ .direction = .row, .gap = .{ .width = 24, .height = 0 } });
    row1.base.layout_style.flex_grow = 1;
    try root.base.addChild(alloc, &row1.base);
    const row2 = try Container.create(alloc, .{ .direction = .row, .gap = .{ .width = 24, .height = 0 } });
    row2.base.layout_style.flex_grow = 1;
    try root.base.addChild(alloc, &row2.base);

    try addAlignCard(row1, alloc, .left);
    try addAlignCard(row1, alloc, .center);
    try addAlignCard(row2, alloc, .right);
    try addAlignCard(row2, alloc, .justify);

    g_root = root;
    g_tree_alloc = alloc;
}

fn addAlignCard(parent: *Container, alloc: std.mem.Allocator, mode: styled_text.TextAlign) !void {
    const card = try Canvas.create(alloc, .{
        .bg_color = math.Color.hex(0x1E293BFF),
        .corner_radius = 14,
        .paint_fn = switch (mode) {
            .left => paintLeft,
            .center => paintCenter,
            .right => paintRight,
            .justify => paintJustify,
        },
    });
    card.base.background.shadow_color = math.Color.rgba(0, 0, 0, 140);
    card.base.background.shadow_blur = 16;
    card.base.background.shadow_offset_y = 6;
    card.base.layout_style.flex_grow = 1;
    card.base.layout_style.width = .{ .auto = {} };
    card.base.layout_style.height = .{ .auto = {} };
    try parent.base.addChild(alloc, &card.base);
}

fn destroyTree() void {
    if (g_root) |root| { root.destroy(g_tree_alloc orelse return); g_root = null; }
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
    root.base.paintTree(&ctx);
}

// ── 对齐卡绘制 ──

fn paintLeft(w: *widget.Widget, ctx: *widget.PaintContext) void {
    paintAligned(w, ctx, .left, "left · 左对齐");
}
fn paintCenter(w: *widget.Widget, ctx: *widget.PaintContext) void {
    paintAligned(w, ctx, .center, "center · 居中");
}
fn paintRight(w: *widget.Widget, ctx: *widget.PaintContext) void {
    paintAligned(w, ctx, .right, "right · 右对齐");
}
fn paintJustify(w: *widget.Widget, ctx: *widget.PaintContext) void {
    paintAligned(w, ctx, .justify, "justify · 两端对齐");
}

fn paintAligned(w: *widget.Widget, ctx: *widget.PaintContext, mode: styled_text.TextAlign, label: []const u8) void {
    const ax = ctx.offset_x + w.rect.x;
    const ay = ctx.offset_y + w.rect.y;
    const pad: f32 = 18;
    styled_text.drawText(ctx.renderer, ctx.allocator, label, ax + pad, ay + 16, .{ .font_size = 14, .font_weight = 600, .color = math.Color.hex(0x60A5FAFF) });
    const text_w = w.rect.width - pad * 2;
    styled_text.drawText(ctx.renderer, ctx.allocator, paragraph, ax + pad, ay + 48, .{
        .font_size = 14,
        .font_weight = 400,
        .color = math.Color.hex(0xCBD5E1FF),
        .text_align = mode,
        .max_width = text_w,
    });
}

// ── 字号 / 字重 展示 ──

fn paintFontShowcase(w: *widget.Widget, ctx: *widget.PaintContext) void {
    const ax = ctx.offset_x + w.rect.x;
    const ay = ctx.offset_y + w.rect.y;
    const pad: f32 = 18;
    const sizes = [_]f32{ 12, 16, 20, 28 };
    const weights = [_]u16{ 400, 500, 600, 700 };
    var i: usize = 0;
    while (i < sizes.len) : (i += 1) {
        const y = ay + pad + @as(f32, @floatFromInt(i)) * 32;
        const color: u32 = switch (i) {
            0 => 0x94A3B8FF,
            1 => 0xCBD5E1FF,
            2 => 0xE2E8F0FF,
            else => 0xF8FAFCFF,
        };
        styled_text.drawText(ctx.renderer, ctx.allocator, "Aa 字体展示", ax + pad, y, .{ .font_size = sizes[i], .font_weight = weights[i], .color = math.Color.hex(color) });
        styled_text.drawText(ctx.renderer, ctx.allocator, "Color", ax + 220, y, .{ .font_size = sizes[i], .font_weight = weights[i], .color = math.Color.hex(0x38BDF8FF) });
    }
}
