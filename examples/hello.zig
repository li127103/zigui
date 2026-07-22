//! zigui hello 示例 - 文本渲染演示 (跨平台: macOS Metal / Linux Vulkan)
//!
//! 展示多种文本样式: 标题/正文/卡片/代码高亮。
//! 所有背景 (窗口/标题栏/卡片/代码区/状态栏) 均为 Widget 背景属性,
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

pub fn main() !void {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var app = try zigui.app.App.init(allocator, .{
        .title = "zigui - Text Rendering",
        .width = 900,
        .height = 640,
        .resizable = false,
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

    // 标题栏 (背景色 + 窗口装饰点 + 标题)
    const title_bar = try Container.create(alloc, .{
        .bg_color = math.Color.hex(0x1E293BFF),
        .direction = .row,
        .height = .{ .px = 52 },
        .padding = .{ .left = 20, .top = 0, .right = 0, .bottom = 0 },
        .gap = .{ .width = 8, .height = 0 },
    });
    try root.base.addChild(alloc, &title_bar.base);

    const dot_colors = [_]u32{ 0xFF5F57FF, 0xFEBC2EFF, 0x28C840FF };
    for (dot_colors) |dc| {
        const dot = try Container.create(alloc, .{
            .bg_color = math.Color.hex(dc),
            .corner_radius = 7,
            .width = .{ .px = 14 },
            .height = .{ .px = 14 },
        });
        dot.base.layout_style.margin.top = 18;
        try title_bar.base.addChild(alloc, &dot.base);
    }

    const title_label = try Label.create(alloc, "zigui Text Engine", .{
        .font_size = 28,
        .font_weight = 700,
        .color = math.Color.hex(0xF8FAFCFF),
    });
    title_label.base.layout_style.margin.left = 4;
    title_label.base.layout_style.margin.top = 12;
    try title_bar.base.addChild(alloc, &title_label.base);

    // 大标题
    const heading = try Label.create(alloc, "Hello, Zigui!", .{
        .font_size = 48,
        .font_weight = 800,
        .color = math.Color.hex(0x38BDF8FF),
    });
    heading.base.layout_style.margin.left = 40;
    heading.base.layout_style.margin.top = 50;
    try root.base.addChild(alloc, &heading.base);

    // 正文段落
    const subtitle = try Label.create(alloc, "Cross-platform GPU-accelerated GUI framework written in Zig 0.16.", .{
        .font_size = 16,
        .font_weight = 400,
        .color = math.Color.hex(0xCBD5E1FF),
    });
    subtitle.base.layout_style.margin.left = 40;
    subtitle.base.layout_style.margin.top = 22;
    try root.base.addChild(alloc, &subtitle.base);

    // 特性卡片行
    const card_row = try Container.create(alloc, .{
        .direction = .row,
        .gap = .{ .width = 16, .height = 0 },
    });
    card_row.base.layout_style.margin.left = 40;
    card_row.base.layout_style.margin.right = 40;
    card_row.base.layout_style.margin.top = 30;
    try root.base.addChild(alloc, &card_row.base);

    const cards = [_]struct { title: []const u8, desc: []const u8, color: u32 }{
        .{ .title = "GPU Rendering", .desc = "Metal / Vulkan pipeline", .color = 0x3B82F6FF },
        .{ .title = "Font Shaping", .desc = "CoreText / FreeType", .color = 0x8B5CF6FF },
        .{ .title = "Glyph Atlas", .desc = "Shelf-packing R8 texture", .color = 0x10B981FF },
        .{ .title = "Text Layout", .desc = "Line break + alignment", .color = 0xF59E0BFF },
    };

    for (cards) |card| {
        const card_w = try Container.create(alloc, .{
            .bg_color = math.Color.hex(0x1E293BFF),
            .corner_radius = 10,
            .direction = .column,
            .height = .{ .px = 122 },
        });
        card_w.base.layout_style.flex_grow = 1;
        try card_row.base.addChild(alloc, &card_w.base);

        // 顶部强调色条 (背景色属性)
        const strip = try Container.create(alloc, .{
            .bg_color = math.Color.hex(card.color),
            .corner_radius = 2,
            .height = .{ .px = 4 },
        });
        try card_w.base.addChild(alloc, &strip.base);

        const ctitle = try Label.create(alloc, card.title, .{
            .font_size = 15,
            .font_weight = 600,
            .color = math.Color.hex(0xF8FAFCFF),
        });
        ctitle.base.layout_style.margin.left = 14;
        ctitle.base.layout_style.margin.top = 26;
        try card_w.base.addChild(alloc, &ctitle.base);

        const cdesc = try Label.create(alloc, card.desc, .{
            .font_size = 12,
            .font_weight = 400,
            .color = math.Color.hex(0x94A3B8FF),
        });
        cdesc.base.layout_style.margin.left = 14;
        cdesc.base.layout_style.margin.top = 12;
        try card_w.base.addChild(alloc, &cdesc.base);
    }

    // 代码区域 (背景色属性 + Canvas 绘制高亮代码)
    const code_area = try Canvas.create(alloc, .{
        .bg_color = math.Color.hex(0x1E293BFF),
        .corner_radius = 10,
        .paint_fn = paintCode,
    });
    code_area.base.layout_style.margin.left = 40;
    code_area.base.layout_style.margin.right = 40;
    code_area.base.layout_style.margin.top = 32;
    code_area.base.layout_style.flex_grow = 1;
    // 宽度 stretch (auto), 高度由 flex_grow 填充剩余空间
    code_area.base.layout_style.width = .{ .auto = {} };
    code_area.base.layout_style.height = .{ .auto = {} };
    try root.base.addChild(alloc, &code_area.base);

    // 底部状态栏
    const status_text: []const u8 = if (comptime is_linux)
        "zigui v0.1.0  |  Linux Vulkan  |  FreeType  |  60 FPS"
    else if (comptime is_macos)
        "zigui v0.1.0  |  macOS Metal  |  CoreText  |  60 FPS"
    else
        "zigui v0.1.0";

    const status_bar = try Container.create(alloc, .{
        .bg_color = math.Color.hex(0x1E293BFF),
        .direction = .row,
        .height = .{ .px = 32 },
    });
    try root.base.addChild(alloc, &status_bar.base);

    const status_label = try Label.create(alloc, status_text, .{
        .font_size = 12,
        .font_weight = 400,
        .color = math.Color.hex(0x64748BFF),
    });
    status_label.base.layout_style.margin.left = 16;
    status_label.base.layout_style.margin.top = 8;
    try status_bar.base.addChild(alloc, &status_label.base);

    g_root = root;
    g_tree_alloc = alloc;
}

fn destroyTree() void {
    if (g_root) |root| {
        root.destroy(g_tree_alloc orelse return);
        g_root = null;
    }
}

// ── 每帧: 布局 + 绘制 (背景由框架自动绘制) ──────────────────────────────────

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

// ── 代码高亮绘制 (Canvas paint_fn, 仅绘制背景之上的内容) ────────────────────

const code_lines = [_][]const u8{
    "const zigui = @import(\"zigui\");",
    "",
    "pub fn main() !void {",
    "    var app = try zigui.app.App.init(alloc, .{",
    "        .title = \"Hello zigui\",",
    "        .width = 900, .height = 640,",
    "    });",
    "    try app.run(&drawFrame);",
    "}",
};

fn paintCode(w: *widget.Widget, ctx: *widget.PaintContext) void {
    const ax = ctx.offset_x + w.rect.x;
    const ay = ctx.offset_y + w.rect.y;

    for (code_lines, 0..) |line_text, li| {
        if (line_text.len == 0) continue;
        const color: u32 = if (std.mem.startsWith(u8, line_text, "const") or
            std.mem.startsWith(u8, line_text, "pub"))
            0xC792EAFF
        else if (std.mem.indexOfScalar(u8, line_text, '"') != null)
            0xC3E88DFF
        else if (std.mem.indexOfScalar(u8, line_text, '(') != null)
            0x82AAFFFF
        else
            0xA6ACCDFF;

        const ly: f32 = ay + 24 + @as(f32, @floatFromInt(li)) * 17.0;
        styled_text.drawText(
            ctx.renderer,
            ctx.allocator,
            line_text,
            ax + 20,
            ly,
            .{ .font_size = 13, .font_weight = 400, .color = math.Color.hex(color) },
        );
    }
}
