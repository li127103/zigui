//! zigui gallery - 媒体 / 系统 / 布局控件 (More 10)
//!
//! 演示:
//!   - Video             视频播放器 (含控制栏占位)
//!   - MediaControls     媒体控制条
//!   - GLArea            OpenGL 绘制区
//!   - GraphicsOffload   离屏渲染卸载容器
//!   - Scrollbar         滚动条 (带 Adjustment)
//!   - FileDialog        文件对话框 (点击打开新窗口)
//!   - FilterListBar     过滤列表栏
//!   - ConstraintLayout 约束布局
//!   - ShortcutLabel     快捷键标签
//!
//! 运行:  zig build run-gallery-more10

const std = @import("std");
const zigui = @import("zigui");
const math = zigui.math;
const styled_text = zigui.styled_text;
const widget = zigui.widget;

const Container = zigui.container.Container;
const Label = zigui.label.Label;
const Button = zigui.button.Button;
const Video = zigui.video.Video;
const MediaControls = zigui.media_controls.MediaControls;
const GLArea = zigui.gl_area.GLArea;
const GraphicsOffload = zigui.graphics_offload.GraphicsOffload;
const Scrollbar = zigui.scrollbar.Scrollbar;
const Adjustment = zigui.model.adjustment.Adjustment;
const FileDialog = zigui.file_dialog.FileDialog;
const FileDialogResult = zigui.file_dialog.FileDialogResult;
const FilterListBar = zigui.filter_list_bar.FilterListBar;
const ConstraintLayout = zigui.constraint_layout.ConstraintLayout;
const ShortcutLabel = zigui.shortcut_label.ShortcutLabel;
const Shortcut = zigui.shortcut_label.Shortcut;

const pal = zigui.pal;

const theme_dark: zigui.theme.Theme = zigui.theme.dark;

var g_root: ?*Container = null;
var g_tree_alloc: ?std.mem.Allocator = null;
var g_prev_mouse_down: bool = false;

// 控件引用
var g_file_label: ?*Label = null;
var g_file_dialog: ?*FileDialog = null;
var g_file_buf: [256]u8 = undefined;
var g_filter_label: ?*Label = null;
var g_filter_buf: [256]u8 = undefined;
var g_filter_bar: ?*FilterListBar = null;

pub fn main() !void {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var app = try zigui.app.App.init(allocator, .{
        .title = "zigui Gallery - More (10)",
        .width = 760,
        .height = 2600,
    });
    defer app.deinit();

    try buildTree(allocator);
    defer destroyTree();

    try app.run(&drawFrame);
    styled_text.deinitFontCache();
}

fn section(alloc: std.mem.Allocator, root: *Container, name: []const u8) !void {
    const cap = try Label.create(alloc, name, .{ .font_size = 15, .font_weight = 600, .color = math.Color.hex(0x94A3B8FF) });
    try root.base.addChild(alloc, &cap.base);
}

fn buildTree(alloc: std.mem.Allocator) !void {
    const root = try Container.create(alloc, .{
        .bg_color = math.Color.hex(0x0F172AFF),
        .direction = .column,
        .padding = .{ .left = 24, .top = 20, .right = 24, .bottom = 20 },
        .gap = .{ .width = 0, .height = 14 },
    });
    errdefer root.destroy(alloc);

    const title = try Label.create(alloc, "More (10) — 媒体 / 系统 / 布局控件", .{ .font_size = 26, .font_weight = 700, .color = math.Color.hex(0xF8FAFCFF) });
    try root.base.addChild(alloc, &title.base);

    // ── Video ───────────────────────────────────────────────────────────────
    try section(alloc, root, "Video (视频播放器)");
    const video = try Video.new(alloc, .{ .show_controls = true, .duration_s = 213 });
    try root.base.addChild(alloc, &video.base);
    const mc = try MediaControls.create(alloc);
    try root.base.addChild(alloc, &mc.base);

    // ── GLArea ──────────────────────────────────────────────────────────────
    try section(alloc, root, "GLArea (OpenGL 绘制区)");
    const gl = try GLArea.new(alloc, .{});
    try root.base.addChild(alloc, &gl.base);

    // ── GraphicsOffload ─────────────────────────────────────────────────────
    try section(alloc, root, "GraphicsOffload (离屏渲染卸载)");
    const go = try GraphicsOffload.create(alloc);
    const go_child = try Label.create(alloc, "Offloaded content", .{ .font_size = 14, .color = math.Color.hex(0xF8FAFCFF) });
    go.setChild(&go_child.base);
    try root.base.addChild(alloc, &go.base);

    // ── Scrollbar ───────────────────────────────────────────────────────────
    try section(alloc, root, "Scrollbar (滚动条 + Adjustment)");
    const sb_tile = try Container.create(alloc, .{ .bg_color = math.Color.hex(0x00000000), .direction = .column });
    sb_tile.base.layout_style.width = .{ .px = 620 };
    sb_tile.base.layout_style.height = .{ .px = 60 };
    const adj = try Adjustment.create(alloc, .{ .lower = 0, .upper = 100, .value = 30, .step_increment = 5, .page_increment = 20, .page_size = 20 });
    const sb = try Scrollbar.create(alloc, .horizontal, adj);
    try sb_tile.base.addChild(alloc, &sb.range.base);
    sb.range.base.layout_style.hexpand = true;
    sb.range.base.layout_style.vexpand = true;
    try root.base.addChild(alloc, &sb_tile.base);

    // ── FileDialog (文件对话框 · 点击打开新窗口) ──────────────────────────────
    try section(alloc, root, "FileDialog (文件对话框 · 点击打开新窗口)");
    const fd = try FileDialog.new(alloc, "Open File");
    fd.setMode(.open);
    g_file_dialog = fd;
    const fd_open = try Button.create(alloc, "Open File…", .{ .on_click = onFileOpen });
    try root.base.addChild(alloc, &fd_open.base);
    const fd_save = try Button.create(alloc, "Save File…", .{ .on_click = onFileSave });
    try root.base.addChild(alloc, &fd_save.base);
    g_file_label = try Label.create(alloc, "result: (none)", .{ .font_size = 13, .color = math.Color.hex(0x94A3B8FF) });
    try root.base.addChild(alloc, &g_file_label.?.base);

    // ── FilterListBar ───────────────────────────────────────────────────────
    try section(alloc, root, "FilterListBar (过滤栏)");
    const flb = try FilterListBar.create(alloc, .{ .on_filter_changed = onFilterChanged });
    g_filter_bar = flb;
    try root.base.addChild(alloc, &flb.base);
    const flb_toggle = try Button.create(alloc, "Toggle Reveal", .{ .on_click = onToggleFilter });
    try root.base.addChild(alloc, &flb_toggle.base);
    g_filter_label = try Label.create(alloc, "filter text: (none)", .{ .font_size = 13, .color = math.Color.hex(0x94A3B8FF) });
    try root.base.addChild(alloc, &g_filter_label.?.base);

    // ── ConstraintLayout ────────────────────────────────────────────────────
    try section(alloc, root, "ConstraintLayout (约束布局)");
    const cl_tile = try Container.create(alloc, .{ .bg_color = math.Color.hex(0x00000000), .direction = .column });
    cl_tile.base.layout_style.width = .{ .px = 620 };
    cl_tile.base.layout_style.height = .{ .px = 240 };
    const cl = try ConstraintLayout.create(alloc);
    cl.bg_color = math.Color.hex(0x162032FF);
    const cl_btn_a = try Button.create(alloc, "Pinned", .{});
    const cl_btn_b = try Button.create(alloc, "Centered", .{});
    try cl.add(&cl_btn_a.base);
    try cl.add(&cl_btn_b.base);
    try cl.pinToParent(&cl_btn_a.base, 24);
    try cl.setSize(&cl_btn_a.base, 120, 36);
    try cl.centerInParent(&cl_btn_b.base);
    try cl.setSize(&cl_btn_b.base, 120, 36);
    try cl_tile.base.addChild(alloc, &cl.base);
    cl.base.layout_style.hexpand = true;
    cl.base.layout_style.vexpand = true;
    try root.base.addChild(alloc, &cl_tile.base);

    // ── ShortcutLabel ───────────────────────────────────────────────────────
    try section(alloc, root, "ShortcutLabel (快捷键标签)");
    const sc_row = try Container.create(alloc, .{ .bg_color = math.Color.hex(0x00000000), .direction = .row, .gap = .{ .width = 12, .height = 0 } });
    const sc1 = try ShortcutLabel.create(alloc, .{ .shortcut = Shortcut{ .modifiers = &.{ .ctrl }, .key = "C" } });
    try sc_row.base.addChild(alloc, &sc1.base);
    const sc2 = try ShortcutLabel.create(alloc, .{ .shortcut = Shortcut{ .modifiers = &.{ .ctrl, .shift }, .key = "S" } });
    try sc_row.base.addChild(alloc, &sc2.base);
    const sc3 = try ShortcutLabel.create(alloc, .{ .shortcut = Shortcut{ .modifiers = &.{ .alt }, .key = "F" } });
    try sc_row.base.addChild(alloc, &sc3.base);
    try root.base.addChild(alloc, &sc_row.base);

    g_root = root;
    g_tree_alloc = alloc;
}

// ── 回调 ─────────────────────────────────────────────────────────────────────

fn onFileOpen(_: *Button) void {
    if (g_file_dialog) |d| d.openFile(onFileResult, null);
}

fn onFileSave(_: *Button) void {
    if (g_file_dialog) |d| d.saveFile(onFileResult, null);
}

fn onFileResult(_: ?*anyopaque, result: FileDialogResult) void {
    if (g_file_label) |lbl| {
        const txt = switch (result) {
            .open => |p| std.fmt.bufPrint(&g_file_buf, "result: open {s}", .{p}) catch "result",
            .save => |n| std.fmt.bufPrint(&g_file_buf, "result: save {s}", .{n}) catch "result",
            .folder => |p| std.fmt.bufPrint(&g_file_buf, "result: folder {s}", .{p}) catch "result",
            .multi_open => |ps| std.fmt.bufPrint(&g_file_buf, "result: multi {d} files", .{ps.len}) catch "result",
            .cancel => "result: cancel",
        };
        lbl.text = txt;
    }
}

fn onFilterChanged(self: *FilterListBar, text: []const u8) void {
    _ = self;
    if (g_filter_label) |lbl| {
        lbl.text = std.fmt.bufPrint(&g_filter_buf, "filter text: {s}", .{text}) catch "filter";
    }
}

fn onToggleFilter(_: *Button) void {
    if (g_filter_bar) |fb| {
        fb.setRevealChild(!fb.getRevealChild());
    }
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

    if (app.key_hit) |key| {
        var ev = pal.Event{ .key = .{ .window_id = 0, .state = .pressed, .key = key, .modifiers = app.key_mods } };
        _ = g_root.?.base.dispatchEvent(&ev, &ectx);
    }

    for (app.typedCodepoints()) |cp| {
        var ev = pal.Event{ .text_input = .{ .window_id = 0, .codepoint = cp } };
        _ = g_root.?.base.dispatchEvent(&ev, &ectx);
    }
}
