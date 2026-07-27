//! zigui 性能监控示例 - 演示 App.getFrameStats() 帧时间统计 (跨平台)
//!
//! 展示:
//!   - 实时 FPS (指数滑动平均)
//!   - 最近帧 CPU 耗时 / 窗口平均耗时
//!   - P99 帧耗时 (卡顿指标)
//!   - 累计帧数
//!   - 文件拖放: 将文件拖入窗口显示其路径 (Wayland/X11/macOS)
//! 多个 Spinner 持续旋转使窗口连续渲染, 便于观察稳定 FPS。

const std = @import("std");
const zigui = @import("zigui");
const math = zigui.math;
const styled_text = zigui.styled_text;
const widget = zigui.widget;

const Container = zigui.container.Container;
const Label = zigui.label.Label;
const Spinner = zigui.spinner.Spinner;

const theme_dark: zigui.theme.Theme = zigui.theme.dark;

// ── 全局状态 ──────────────────────────────────────────────────────────────

var g_root: ?*Container = null;
var g_alloc: ?std.mem.Allocator = null;
var g_fps_label: ?*Label = null;
var g_frame_label: ?*Label = null;
var g_p99_label: ?*Label = null;
var g_total_label: ?*Label = null;
var g_drop_label: ?*Label = null;
var g_spinners: [8]?*Spinner = .{null} ** 8;

var g_buf_fps: [64]u8 = undefined;
var g_buf_frame: [96]u8 = undefined;
var g_buf_p99: [64]u8 = undefined;
var g_buf_total: [64]u8 = undefined;
var g_buf_drop: [256]u8 = undefined;

pub fn main() !void {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var app = try zigui.app.App.init(allocator, .{
        .title = "zigui - Performance Monitor",
        .width = 520,
        .height = 460,
    });
    defer app.deinit();

    try buildTree(allocator);
    defer destroyTree();

    try app.run(&drawFrame);

    styled_text.deinitFontCache();
}

// ── 控件树构建 ──────────────────────────────────────────────────────────────

fn buildTree(alloc: std.mem.Allocator) !void {
    const root = try Container.create(alloc, .{
        .bg_color = math.Color.hex(0x0F172AFF),
        .direction = .column,
        .padding = math.EdgeInsets.all(24),
        .gap = .{ .width = 0, .height = 14 },
    });
    errdefer root.destroy(alloc);

    const title = try Label.create(alloc, "Performance Monitor", .{
        .font_size = 22,
        .font_weight = 700,
        .color = math.Color.hex(0xF8FAFCFF),
    });
    try root.base.addChild(alloc, &title.base);

    g_fps_label = try addStat(alloc, root, "FPS: --");
    g_frame_label = try addStat(alloc, root, "Frame: --");
    g_p99_label = try addStat(alloc, root, "P99: --");
    g_total_label = try addStat(alloc, root, "Total: --");
    g_drop_label = try addStat(alloc, root, "Drop a file into this window");

    // 一排旋转 Spinner 提供持续渲染负载
    const row = try Container.create(alloc, .{
        .direction = .row,
        .gap = .{ .width = 16, .height = 0 },
    });
    row.base.layout_style.margin.top = 12;
    try root.base.addChild(alloc, &row.base);

    for (&g_spinners) |*slot| {
        const sp = try Spinner.create(alloc, .{ .size = 36, .speed = 2.0 });
        try row.base.addChild(alloc, &sp.base);
        slot.* = sp;
    }

    g_root = root;
    g_alloc = alloc;
}

fn addStat(alloc: std.mem.Allocator, parent: *Container, initial: []const u8) !*Label {
    const lbl = try Label.create(alloc, initial, .{
        .font_size = 16,
        .font_weight = 600,
        .color = math.Color.hex(0x38BDF8FF),
    });
    try parent.base.addChild(alloc, &lbl.base);
    return lbl;
}

fn destroyTree() void {
    if (g_root) |root| {
        root.destroy(g_alloc orelse return);
        g_root = null;
    }
}

// ── 每帧: 动画 + 统计刷新 + 布局 + 绘制 ───────────────────────────────────

fn drawFrame(app: *zigui.app.App) void {
    const root = g_root orelse return;
    const fb = app.getFramebufferSize();
    const w: f32 = @floatFromInt(fb.width);
    const h: f32 = @floatFromInt(fb.height);

    // 动画
    for (g_spinners) |slot| {
        if (slot) |sp| sp.tick(16);
    }

    // 刷新性能统计文本
    updateStats(app);

    // 文件拖放: 显示本帧拖入的文件路径
    if (app.file_drop) |fd| {
        if (g_drop_label) |lbl| {
            lbl.text = std.fmt.bufPrint(&g_buf_drop, "Dropped: {s}", .{fd.pathSlice()}) catch "Dropped: (path too long)";
            lbl.color = math.Color.hex(0x4ADE80FF);
        }
    }

    // 布局 + 绘制
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

fn updateStats(app: *zigui.app.App) void {
    const stats = app.getFrameStats();

    if (g_fps_label) |lbl| {
        lbl.text = std.fmt.bufPrint(&g_buf_fps, "FPS: {d:.1}", .{stats.fps}) catch "FPS: --";
    }
    if (g_frame_label) |lbl| {
        lbl.text = std.fmt.bufPrint(
            &g_buf_frame,
            "Frame: {d:.3} ms (avg {d:.3} ms)",
            .{ stats.frame_time_ms, stats.averageFrameTime() },
        ) catch "Frame: --";
    }
    if (g_p99_label) |lbl| {
        lbl.text = std.fmt.bufPrint(&g_buf_p99, "P99: {d:.3} ms", .{stats.frameTimePercentile(0.99)}) catch "P99: --";
    }
    if (g_total_label) |lbl| {
        lbl.text = std.fmt.bufPrint(&g_buf_total, "Total frames: {d}", .{stats.total_frames}) catch "Total: --";
    }
}
