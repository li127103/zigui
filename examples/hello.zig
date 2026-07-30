//! zigui hello 示例 - 最简可运行程序 (跨平台; Linux 下为 X11/Wayland + Vulkan)
//!
//! 演示:
//!   - zigui.app.App.init 创建窗口与 GPU 上下文
//!   - Container 作为根容器 (背景色由框架自动绘制)
//!   - Label 文本渲染
//!   - drawFrame 回调里做布局 + 绘制
//!   - App.run 进入主循环, ESC 退出
//!
//! 运行:  zig build run-hello

const std = @import("std");
const zigui = @import("zigui");
const math = zigui.math;
const styled_text = zigui.styled_text;

const widget = zigui.widget;
const Container = zigui.container.Container;
const Label = zigui.label.Label;

const theme_dark: zigui.theme.Theme = zigui.theme.dark;

var g_root: ?*Container = null;
var g_tree_alloc: ?std.mem.Allocator = null;

pub fn main() !void {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var app = try zigui.app.App.init(allocator, .{
        .title = "zigui - Hello",
        .width = 480,
        .height = 320,
        .resizable = false,
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
        .padding = .{ .left = 38, .top = 60, .right = 38, .bottom = 20 },
        .gap = .{ .width = 0, .height = 16 },
    });
    errdefer root.destroy(alloc);

    const title = try Label.create(alloc, "Hello, zigui!", .{
        .font_size = 32,
        .font_weight = 700,
        .color = math.Color.hex(0x38BDF8FF),
    });
    try root.base.addChild(alloc, &title.base);

    const subtitle = try Label.create(alloc, "Cross-platform GPU-accelerated GUI in Zig.", .{
        .font_size = 16,
        .font_weight = 400,
        .color = math.Color.hex(0xCBD5E1FF),
    });
    try root.base.addChild(alloc, &subtitle.base);

    const platform = try Label.create(alloc, "Linux · X11/Wayland + Vulkan + FreeType", .{
        .font_size = 14,
        .font_weight = 400,
        .color = math.Color.hex(0x64748BFF),
    });
    try root.base.addChild(alloc, &platform.base);

    g_root = root;
    g_tree_alloc = alloc;
}

fn destroyTree() void {
    if (g_root) |root| {
        root.destroy(g_tree_alloc orelse return);
        g_root = null;
    }
}

fn drawFrame(app: *zigui.app.App) void {
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
