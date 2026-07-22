//! zigui 背景属性示例 - 控件背景由框架自主绘制 (跨平台 Widget 系统)
//!
//! 演示 Widget 基类的 background 属性 (无需控件自绘, paintTree 自动绘制于内容之前):
//!   - 纯色背景 + 圆角 (setBackgroundColor / setCornerRadius)
//!   - 背景图片五种适配模式 (setBackgroundImage): stretch / cover / contain / center / tile
//!   - 根容器背景色铺满窗口
//!
//! 交互: ESC 退出

const std = @import("std");
const zigui = @import("zigui");
const math = zigui.math;
const styled_text = zigui.styled_text;

const widget = zigui.widget;
const Container = zigui.container.Container;
const Label = zigui.label.Label;
const BackgroundSizing = widget.BackgroundSizing;

const logo_png = @embedFile("assets/zigui_logo.png");
/// @embedFile 返回 *const [N:0]u8, 显式转为切片供 bg_image (?[]const u8) 使用
const logo_bytes: []const u8 = logo_png;

/// 主题 (PaintContext 需要 *const Theme)
const theme_dark: zigui.theme.Theme = zigui.theme.dark;

var g_root: ?*Container = null;
var g_tree_alloc: ?std.mem.Allocator = null;

pub fn main() !void {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var app = try zigui.app.App.init(allocator, .{
        .title = "zigui - Background 背景属性",
        .width = 900,
        .height = 620,
    });
    defer app.deinit();

    // 控件树只需构建一次; 背景纹理惰性创建, 由框架逐帧自主绘制
    try buildTree(allocator);
    defer destroyTree(); // 须在 app.deinit (销毁 GPU 设备) 之前释放背景纹理

    try app.run(&drawFrame);

    styled_text.deinitFontCache();
}

// ── 控件树构建 ──────────────────────────────────────────────────────────────

fn buildTree(alloc: std.mem.Allocator) !void {
    // 根容器: 背景色铺满窗口 (框架自主绘制), 纵向排布
    const root = try Container.create(alloc, .{
        .bg_color = math.Color.hex(0x0F172AFF),
        .direction = .column,
        .padding = math.EdgeInsets.all(28),
        .gap = .{ .width = 20, .height = 20 },
    });
    errdefer root.destroy(alloc);

    // 标题
    const title = try Label.create(alloc, "背景属性 Background", .{
        .font_size = 22,
        .font_weight = 700,
        .color = math.Color.hex(0xF8FAFCFF),
    });
    try root.base.addChild(alloc, &title.base);

    const subtitle = try Label.create(alloc, "Widget 基类属性, 框架在 paintTree 中自动绘制于内容之前 (纯色 / 圆角 / 背景图片)", .{
        .font_size = 13,
        .color = math.Color.hex(0x94A3B8FF),
    });
    try root.base.addChild(alloc, &subtitle.base);

    // ── 第一行: 纯色 + 圆角 ──
    // (Container.measure 按子项内容测量, 不应用子项显式尺寸;
    //  故给行容器显式宽高 = 3×160 + 2×16 gap, 高 90, 保证行间距正确)
    const color_row = try Container.create(alloc, .{
        .direction = .row,
        .gap = .{ .width = 16, .height = 0 },
        .width = .{ .px = 512 },
        .height = .{ .px = 90 },
    });
    try root.base.addChild(alloc, &color_row.base);

    try addColorPanel(color_row, alloc, 0x3B82F6FF, 12, "color · radius 12");
    try addColorPanel(color_row, alloc, 0x8B5CF6FF, 12, "color · radius 12");
    try addColorPanel(color_row, alloc, 0x22C55EFF, 32, "color · radius 32");

    // ── 第二行: 背景图片五种适配模式 ── (5×150 + 4×16 gap, 高 150)
    const image_row = try Container.create(alloc, .{
        .direction = .row,
        .gap = .{ .width = 16, .height = 0 },
        .width = .{ .px = 814 },
        .height = .{ .px = 150 },
    });
    try root.base.addChild(alloc, &image_row.base);

    try addImagePanel(image_row, alloc, .stretch, "stretch");
    try addImagePanel(image_row, alloc, .cover, "cover");
    try addImagePanel(image_row, alloc, .contain, "contain");
    try addImagePanel(image_row, alloc, .center, "center");
    try addImagePanel(image_row, alloc, .tile, "tile");

    g_root = root;
    g_tree_alloc = alloc;
}

/// 纯色背景面板 (bg_color + corner_radius, 框架自动绘制)
fn addColorPanel(parent: *Container, alloc: std.mem.Allocator, color: u32, radius: f32, caption: []const u8) !void {
    const panel = try Container.create(alloc, .{
        .bg_color = math.Color.hex(color),
        .corner_radius = radius,
        .width = .{ .px = 160 },
        .height = .{ .px = 90 },
        .padding = math.EdgeInsets.all(12),
    });
    const lbl = try Label.create(alloc, caption, .{
        .font_size = 13,
        .font_weight = 600,
        .color = math.Color.hex(0xFFFFFFFF),
    });
    try panel.base.addChild(alloc, &lbl.base);
    try parent.base.addChild(alloc, &panel.base);
}

/// 背景图片面板 (bg_image + bg_sizing, PNG 数据拷贝, GPU 纹理惰性创建)
fn addImagePanel(parent: *Container, alloc: std.mem.Allocator, sizing: BackgroundSizing, caption: []const u8) !void {
    const panel = try Container.create(alloc, .{
        .bg_image = logo_bytes,
        .bg_sizing = sizing,
        .corner_radius = 10,
        .width = .{ .px = 150 },
        .height = .{ .px = 150 },
        .padding = math.EdgeInsets.all(8),
    });
    const lbl = try Label.create(alloc, caption, .{
        .font_size = 12,
        .font_weight = 600,
        .color = math.Color.hex(0xFFFFFFFF),
    });
    try panel.base.addChild(alloc, &lbl.base);
    try parent.base.addChild(alloc, &panel.base);
}

fn destroyTree() void {
    if (g_root) |root| {
        root.destroy(g_tree_alloc orelse return);
        g_root = null;
    }
}

// ── 每帧: 布局 + 绘制 (背景由框架自主绘制) ──────────────────────────────────

fn drawFrame(app: *zigui.app.App) void {
    const root = g_root orelse return;
    const fb = app.getFramebufferSize();
    const w: f32 = @floatFromInt(fb.width);
    const h: f32 = @floatFromInt(fb.height);

    // 根容器随窗口尺寸自适应
    root.base.layout_style.width = .{ .px = w };
    root.base.layout_style.height = .{ .px = h };

    var ctx = widget.PaintContext{
        .renderer = app.getRenderer(),
        .theme = &theme_dark,
        .allocator = app.allocator,
    };

    // 布局 + 绘制: paintTree 自动先绘制各控件背景 (纯色/图片), 再绘制内容与子树
    root.base.performLayout(&ctx, .{ .max_width = w, .max_height = h });
    root.base.paintTree(&ctx);
}
