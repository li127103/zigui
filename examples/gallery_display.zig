//! zigui gallery - 显示类控件 (Display)
//!
//! 演示 (均为真正的控件):
//!   - Label       文本标签 (含大标题 / 彩色 / 自动换行 / markup)
//!   - Separator   分割线 (水平 / 垂直)
//!   - ProgressBar 进度条 (含脉冲 indeterminate 模式)
//!   - Spinner     加载动画 (旋转)
//!   - LevelBar    层级条 (电量式分段)
//!   - Image       位图 (传入 png_data 即可显示; 此处用占位 alt 文本)
//!   - Picture     图片容器 (同 Image, 支持 contain/fill 等多种缩放)
//!
//! 运行:  zig build run-gallery-display

const std = @import("std");
const zigui = @import("zigui");
const math = zigui.math;
const styled_text = zigui.styled_text;
const widget = zigui.widget;

const Container = zigui.container.Container;
const Label = zigui.label.Label;
const Separator = zigui.separator.Separator;
const ProgressBar = zigui.progress_bar.ProgressBar;
const Spinner = zigui.spinner.Spinner;
const LevelBar = zigui.level_bar.LevelBar;
const Image = zigui.image_widget.Image;
const Picture = zigui.picture.Picture;

const pal = zigui.pal;

const theme_dark: zigui.theme.Theme = zigui.theme.dark;

var g_root: ?*Container = null;
var g_tree_alloc: ?std.mem.Allocator = null;
var g_frame: u32 = 0;
var g_prev_mouse_down: bool = false;

// 随帧动画的进度条 (演示 ProgressBar 实时更新)
var g_progress: ?*ProgressBar = null;

pub fn main() !void {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var app = try zigui.app.App.init(allocator, .{
        .title = "zigui Gallery - Display",
        .width = 720,
        .height = 820,
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
        .padding = .{ .left = 24, .top = 20, .right = 24, .bottom = 20 },
        .gap = .{ .width = 0, .height = 14 },
    });
    errdefer root.destroy(alloc);

    const title = try Label.create(alloc, "Display", .{ .font_size = 26, .font_weight = 700, .color = math.Color.hex(0xF8FAFCFF) });
    try root.base.addChild(alloc, &title.base);

    const sub = try Label.create(alloc, "Static and animated display widgets.", .{ .font_size = 13, .color = math.Color.hex(0x64748BFF) });
    try root.base.addChild(alloc, &sub.base);

    // 大标题
    try addRow(alloc, root, "Heading", try Label.create(alloc, "The quick brown fox", .{ .font_size = 22, .font_weight = 700, .color = math.Color.hex(0x38BDF8FF) }));

    // 彩色文本
    try addRow(alloc, root, "Colored", try Label.create(alloc, "Colored label text", .{ .font_size = 15, .color = math.Color.hex(0xF472B6FF) }));

    // 自动换行 (限制宽度, 长文本)
    const wrap = try Label.create(alloc,
        "This label wraps across multiple lines when the available width is constrained, demonstrating the word-wrap behavior.",
        .{ .font_size = 14, .wrap = true, .color = math.Color.hex(0xE2E8F0FF) },
    );
    wrap.base.layout_style.width = .{ .px = 360 };
    try addRow(alloc, root, "Wrapped", wrap);

    // markup 文本
    try addRow(alloc, root, "Markup", try Label.create(alloc, "<b>Bold</b> and <i>italic</i> via markup", .{ .font_size = 14, .use_markup = true, .color = math.Color.hex(0xE2E8F0FF) }));

    // 水平分割线
    try addRow(alloc, root, "Separator", try Separator.create(alloc, .{ .orientation = .horizontal, .color = math.Color.hex(0x334155FF) }));

    // 进度条 (静态 0.62)
    try addRow(alloc, root, "Progress", try ProgressBar.create(alloc, .{ .fraction = 0.62, .show_text = true, .text = "62%" }));

    // 进度条 (脉冲 / indeterminate)
    try addRow(alloc, root, "Pulse", try ProgressBar.create(alloc, .{ .pulse = true }));

    // 动画进度条 (在 drawFrame 中更新)
    g_progress = try ProgressBar.create(alloc, .{ .show_text = true });
    try addRow(alloc, root, "Animated", g_progress.?);

    // Spinner
    try addRow(alloc, root, "Spinner", try Spinner.create(alloc, .{ .active = true }));

    // LevelBar
    try addRow(alloc, root, "LevelBar", try LevelBar.create(alloc, .{ .value = 0.72, .min_value = 0, .max_value = 1 }));

    // 垂直分割线 (放在单独行, 用固定高度展示)
    const vsep_row = try rowContainer(alloc);
    try vsep_row.base.addChild(alloc, &(try caption(alloc, "Vertical")).base);
    const vsep = try Separator.create(alloc, .{ .orientation = .vertical, .color = math.Color.hex(0x334155FF) });
    vsep.base.layout_style.height = .{ .px = 40 };
    try vsep_row.base.addChild(alloc, &vsep.base);
    try root.base.addChild(alloc, &vsep_row.base);

    // Image 占位 (实际使用时传 png_data: []const u8)
    try addRow(alloc, root, "Image", try Image.create(alloc, .{ .alt = "image placeholder", .width = 120, .height = 80 }));

    // Picture 占位
    try addRow(alloc, root, "Picture", try Picture.create(alloc, .{ .alt = "picture placeholder", .width = 120, .height = 80 }));

    g_root = root;
    g_tree_alloc = alloc;
}

fn rowContainer(alloc: std.mem.Allocator) !*Container {
    return Container.create(alloc, .{
        .direction = .row,
        .gap = .{ .width = 12, .height = 0 },
    });
}

fn caption(alloc: std.mem.Allocator, text: []const u8) !*Label {
    const l = try Label.create(alloc, text, .{ .font_size = 13, .color = math.Color.hex(0x94A3B8FF) });
    l.base.layout_style.width = .{ .px = 110 };
    return l;
}

fn addRow(alloc: std.mem.Allocator, parent: *Container, cap: []const u8, ctrl: anytype) !void {
    const row = try rowContainer(alloc);
    try row.base.addChild(alloc, &(try caption(alloc, cap)).base);
    try row.base.addChild(alloc, &ctrl.base);
    try parent.base.addChild(alloc, &row.base);
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

    root.base.layout_style.width = .{ .px = w };
    root.base.layout_style.height = .{ .px = h };

    // 让第三个进度条来回动画
    if (g_progress) |p| {
        const t = @as(f32, @floatFromInt(g_frame % 200)) / 200.0;
        p.fraction = 0.5 + 0.5 * std.math.sin(t * std.math.pi * 2.0);
        p.base.markDirty();
    }

    var ctx = widget.PaintContext{ .renderer = app.getRenderer(), .theme = &theme_dark, .allocator = app.allocator };
    root.base.performLayout(&ctx, .{ .max_width = w, .max_height = h });
    dispatchInput(app);
    root.base.paintTree(&ctx);
}

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
}
