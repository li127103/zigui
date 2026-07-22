//! zigui 文本对齐示例 - 左/居中/右/两端对齐 (跨平台: macOS Metal / Linux Vulkan)
//!
//! 演示:
//!   - 四个文本块分别展示 left / center / right / justify 四种水平对齐
//!   - 中英混排长段落, 依赖 max_width 自动断行 (word wrap)
//!   - 两端对齐: 末行保持左对齐, 其余行均匀撑满容器宽度
//!
//! 所有背景 (窗口/卡片+阴影) 均为 Widget 背景属性, 由框架在 paintTree 中自动绘制。

const std = @import("std");
const zigui = @import("zigui");
const math = zigui.math;
const styled_text = zigui.styled_text;

const widget = zigui.widget;
const Container = zigui.container.Container;
const Label = zigui.label.Label;
const Canvas = zigui.canvas.Canvas;

const App = zigui.app.App;
const TextAlign = styled_text.TextAlign;

/// 主题 (PaintContext 需要 *const Theme)
const theme_dark: zigui.theme.Theme = zigui.theme.dark;

/// 中英混排段落 (足够长, 可自动断行为多行)
const paragraph =
    "zigui 是用 Zig 语言构建的跨平台 GPU 加速 GUI 框架。The text layout " ++
    "engine supports multi-line word wrapping and four alignment modes. " ++
    "文本布局引擎支持多行自动断行，并提供左对齐、居中、右对齐与两端对齐四种排版方式，" ++
    "适用于中英文混排的界面场景。";

var g_root: ?*Container = null;
var g_tree_alloc: ?std.mem.Allocator = null;

// ── 入口 ────────────────────────────────────────────────────────────────────

pub fn main() !void {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var app = try App.init(allocator, .{
        .title = "zigui - Text Alignment",
        .width = 960,
        .height = 720,
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
        .padding = math.EdgeInsets.all(30),
        .gap = .{ .width = 0, .height = 24 },
    });
    errdefer root.destroy(alloc);

    // 主标题
    const title = try Label.create(alloc, "Text Alignment · 文本对齐", .{
        .font_size = 22,
        .font_weight = 700,
        .color = math.Color.hex(0xF8FAFCFF),
    });
    try root.base.addChild(alloc, &title.base);

    const subtitle = try Label.create(alloc, "四种水平对齐方式 (多行自动断行, 中英混排)", .{
        .font_size = 13,
        .font_weight = 400,
        .color = math.Color.hex(0x94A3B8FF),
    });
    try root.base.addChild(alloc, &subtitle.base);

    // 2x2 网格: 每行一个 row 容器, 各占一半剩余高度
    const row1 = try Container.create(alloc, .{
        .direction = .row,
        .gap = .{ .width = 24, .height = 0 },
    });
    row1.base.layout_style.flex_grow = 1;
    try root.base.addChild(alloc, &row1.base);

    const row2 = try Container.create(alloc, .{
        .direction = .row,
        .gap = .{ .width = 24, .height = 0 },
    });
    row2.base.layout_style.flex_grow = 1;
    try root.base.addChild(alloc, &row2.base);

    try addCard(row1, alloc, .left, "left · 左对齐", paintCardLeft);
    try addCard(row1, alloc, .center, "center · 居中对齐", paintCardCenter);
    try addCard(row2, alloc, .right, "right · 右对齐", paintCardRight);
    try addCard(row2, alloc, .justify, "justify · 两端对齐", paintCardJustify);

    g_root = root;
    g_tree_alloc = alloc;
}

/// 卡片: 背景色 + 圆角 + 阴影均为 Widget 属性; 内容 (对齐标签 + 段落) 由 Canvas 绘制
fn addCard(parent: *Container, alloc: std.mem.Allocator, alignment: TextAlign, label: []const u8, paint_fn: *const fn (w: *widget.Widget, ctx: *widget.PaintContext) void) !void {
    _ = alignment;
    _ = label;
    const card = try Canvas.create(alloc, .{
        .bg_color = math.Color.hex(0x1E293BFF),
        .corner_radius = 14,
        .paint_fn = paint_fn,
    });
    // 阴影 (框架在背景之前自动绘制)
    card.base.background.shadow_color = math.Color.rgba(0, 0, 0, 140);
    card.base.background.shadow_blur = 16;
    card.base.background.shadow_offset_y = 6;
    // 填充网格单元: 宽度 flex 均分, 高度 stretch
    card.base.layout_style.flex_grow = 1;
    card.base.layout_style.width = .{ .auto = {} };
    card.base.layout_style.height = .{ .auto = {} };
    try parent.base.addChild(alloc, &card.base);
}

fn destroyTree() void {
    if (g_root) |root| {
        root.destroy(g_tree_alloc orelse return);
        g_root = null;
    }
}

// ── 每帧: 布局 + 绘制 (背景由框架自动绘制) ──────────────────────────────────

fn drawFrame(app: *App) void {
    const root = g_root orelse return;
    const fb = app.getFramebufferSize();
    const w: f32 = @floatFromInt(fb.width);
    const h: f32 = @floatFromInt(fb.height);

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

// ── 卡片内容绘制 (Canvas paint_fn, 背景由框架自动绘制) ──────────────────────

fn paintCard(w: *widget.Widget, ctx: *widget.PaintContext, alignment: TextAlign, label: []const u8) void {
    const ax = ctx.offset_x + w.rect.x;
    const ay = ctx.offset_y + w.rect.y;
    const pad: f32 = 18.0;

    // 对齐方式标签
    styled_text.drawText(
        ctx.renderer,
        ctx.allocator,
        label,
        ax + pad,
        ay + 16,
        .{ .font_size = 14, .font_weight = 600, .color = math.Color.hex(0x60A5FAFF) },
    );

    // 段落 (在文本区域内按指定对齐方式布局 + 自动断行)
    const text_w = w.rect.width - pad * 2.0;
    styled_text.drawText(
        ctx.renderer,
        ctx.allocator,
        paragraph,
        ax + pad,
        ay + 48,
        .{
            .font_size = 14,
            .font_weight = 400,
            .color = math.Color.hex(0xCBD5E1FF),
            .text_align = alignment,
            .max_width = text_w,
        },
    );
}

fn paintCardLeft(w: *widget.Widget, ctx: *widget.PaintContext) void {
    paintCard(w, ctx, .left, "left · 左对齐");
}
fn paintCardCenter(w: *widget.Widget, ctx: *widget.PaintContext) void {
    paintCard(w, ctx, .center, "center · 居中对齐");
}
fn paintCardRight(w: *widget.Widget, ctx: *widget.PaintContext) void {
    paintCard(w, ctx, .right, "right · 右对齐");
}
fn paintCardJustify(w: *widget.Widget, ctx: *widget.PaintContext) void {
    paintCard(w, ctx, .justify, "justify · 两端对齐");
}
