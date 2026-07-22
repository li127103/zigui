//! zigui simple 示例 - 最小可运行 demo (跨平台 Widget 系统)
//!
//! 演示: 根容器背景色 (框架自动绘制) + Label 文本渲染
//! 交互: ESC 退出

const std = @import("std");
const builtin = @import("builtin");
const zigui = @import("zigui");
const math = zigui.math;
const styled_text = zigui.styled_text;

const widget = zigui.widget;
const Container = zigui.container.Container;
const Label = zigui.label.Label;

const is_linux = builtin.os.tag == .linux;
const is_macos = builtin.os.tag == .macos;

/// 主题
const theme_dark: zigui.theme.Theme = zigui.theme.dark;

var g_root: ?*Container = null;
var g_tree_alloc: ?std.mem.Allocator = null;

pub fn main() !void {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var app = try zigui.app.App.init(allocator, .{
        .title = "zigui - Simple",
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

// ── 控件树构建 ──────────────────────────────────────────────────────────────

fn buildTree(alloc: std.mem.Allocator) !void {
    // 根容器: 背景色由框架自动绘制
    const root = try Container.create(alloc, .{
        .bg_color = math.Color.hex(0x0F172AFF),
        .direction = .column,
        .padding = .{ .left = 38, .top = 60, .right = 38, .bottom = 20 },
        .gap = .{ .width = 0, .height = 16 },
    });
    errdefer root.destroy(alloc);

    // 标题
    const title = try Label.create(alloc, "Hello, zigui!", .{
        .font_size = 32,
        .font_weight = 700,
        .color = math.Color.hex(0x38BDF8FF),
    });
    try root.base.addChild(alloc, &title.base);

    // 副标题
    const subtitle = try Label.create(alloc, "Cross-platform GPU-accelerated GUI in Zig.", .{
        .font_size = 16,
        .font_weight = 400,
        .color = math.Color.hex(0xCBD5E1FF),
    });
    try root.base.addChild(alloc, &subtitle.base);

    // 平台信息
    const platform_text: []const u8 = if (comptime is_linux)
        "Linux X11 + Vulkan + FreeType"
    else if (comptime is_macos)
        "macOS Metal + CoreText"
    else
        "Unknown platform";

    const platform = try Label.create(alloc, platform_text, .{
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

// ── 每帧: 布局 + 绘制 ──────────────────────────────────────────────────────

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
