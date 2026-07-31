//! zigui gallery - 网格与布局容器 (Grid & Layout Containers)
//!
//! 演示 (均为真正的可交互控件):
//!   - Grid          网格布局 (行 × 列, 支持跨距与扩展)
//!   - Overlay       叠加层 (主内容 + 浮动覆盖层)
//!   - Frame         带标题边框分组
//!   - CenterBox     三栏居中布局 (start / center / end)
//!   - FlowBox       流式换行布局
//!   - AspectFrame   保持宽高比容器
//!
//! 运行:  zig build run-gallery-grid

const std = @import("std");
const zigui = @import("zigui");
const math = zigui.math;
const styled_text = zigui.styled_text;
const widget = zigui.widget;

const Container = zigui.container.Container;
const Label = zigui.label.Label;
const Button = zigui.button.Button;
const Grid = zigui.grid.Grid;
const Overlay = zigui.overlay.Overlay;
const Frame = zigui.frame.Frame;
const CenterBox = zigui.center_box.CenterBox;
const FlowBox = zigui.flow_box.FlowBox;
const AspectFrame = zigui.aspect_frame.AspectFrame;

const pal = zigui.pal;

const theme_dark: zigui.theme.Theme = zigui.theme.dark;

var g_root: ?*Container = null;
var g_tree_alloc: ?std.mem.Allocator = null;
var g_prev_mouse_down: bool = false;

pub fn main() !void {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var app = try zigui.app.App.init(allocator, .{
        .title = "zigui Gallery - Grid & Layout Containers",
        .width = 640,
        .height = 900,
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
        .padding = .{ .left = 20, .top = 16, .right = 20, .bottom = 16 },
        .gap = .{ .width = 0, .height = 18 },
    });
    errdefer root.destroy(alloc);

    const title = try Label.create(alloc, "Grid & Layout Containers", .{ .font_size = 24, .font_weight = 700, .color = math.Color.hex(0xF8FAFCFF) });
    try root.base.addChild(alloc, &title.base);

    const sub = try Label.create(alloc, "GTK4-style layout containers: grid, overlay, frame, center box, flow box, aspect frame.", .{ .font_size = 13, .color = math.Color.hex(0x64748BFF) });
    try root.base.addChild(alloc, &sub.base);

    // Grid
    try section(alloc, root, "Grid (2×3)");
    const grid = try Grid.create(alloc, .{ .rows = 2, .cols = 3, .row_gap = 8, .col_gap = 8, .bg_color = math.Color.hex(0x1E293BFF), .corner_radius = 8 });
    var r: usize = 0;
    while (r < 2) : (r += 1) {
        var c: usize = 0;
        while (c < 3) : (c += 1) {
            const cell = try Label.create(alloc, try std.fmt.allocPrint(alloc, "R{d}C{d}", .{ r, c }), .{ .font_size = 13, .color = math.Color.hex(0xE2E8F0FF) });
            cell.base.layout_style.align_self = .center;
            try grid.addChild(&cell.base, r, c);
        }
    }
    try root.base.addChild(alloc, &grid.base);

    // Overlay
    try section(alloc, root, "Overlay (floating button)");
    const ov = try Overlay.create(alloc, .{ .bg_color = math.Color.hex(0x1E293BFF), .corner_radius = 8, .height = .{ .px = 140 } });
    const ov_main = try Label.create(alloc, "Main content underneath the overlay.", .{ .font_size = 14, .color = math.Color.hex(0xE2E8F0FF) });
    ov_main.base.layout_style.align_self = .center;
    try ov.setChild(&ov_main.base);
    const ov_btn = try Button.create(alloc, "Floating", .{ .corner_radius = 6 });
    ov_btn.base.layout_style.position = .absolute;
    ov_btn.base.layout_style.right = 12;
    ov_btn.base.layout_style.bottom = 12;
    try ov.addOverlay(&ov_btn.base);
    try root.base.addChild(alloc, &ov.base);

    // Frame
    try section(alloc, root, "Frame");
    const frame = try Frame.create(alloc, "Connection", .{ .bg_color = math.Color.hex(0x1E293BFF), .corner_radius = 8 });
    const frame_child = try Label.create(alloc, "Grouped settings live inside this framed box.", .{ .font_size = 14, .color = math.Color.hex(0xE2E8F0FF), .wrap = true });
    try frame.setChild(&frame_child.base);
    try root.base.addChild(alloc, &frame.base);

    // CenterBox
    try section(alloc, root, "CenterBox");
    const cb = try CenterBox.create(alloc, .{ .bg_color = math.Color.hex(0x1E293BFF), .corner_radius = 8, .height = .{ .px = 60 } });
    const cb_start = try Label.create(alloc, "Start", .{ .font_size = 13, .color = math.Color.hex(0xE2E8F0FF) });
    const cb_center = try Label.create(alloc, "Center", .{ .font_size = 13, .color = math.Color.hex(0xF8FAFCFF) });
    const cb_end = try Label.create(alloc, "End", .{ .font_size = 13, .color = math.Color.hex(0xE2E8F0FF) });
    try cb.setStartWidget(&cb_start.base);
    try cb.setCenterWidget(&cb_center.base);
    try cb.setEndWidget(&cb_end.base);
    try root.base.addChild(alloc, &cb.base);

    // FlowBox
    try section(alloc, root, "FlowBox (wraps)");
    const fb = try FlowBox.create(alloc, .{ .bg_color = math.Color.hex(0x1E293BFF), .corner_radius = 8, .padding = .{ .left = 10, .top = 10, .right = 10, .bottom = 10 } });
    var i: usize = 0;
    while (i < 8) : (i += 1) {
        const tag = try std.fmt.allocPrint(alloc, "Item {d}", .{i + 1});
        const item = try Button.create(alloc, tag, .{ .corner_radius = 6 });
        _ = try fb.appendChild(&item.base);
    }
    try root.base.addChild(alloc, &fb.base);

    // AspectFrame
    try section(alloc, root, "AspectFrame (16:9)");
    const af = try AspectFrame.create(alloc, .{ .ratio = 16.0 / 9.0, .bg_color = math.Color.hex(0x1E293BFF), .corner_radius = 8 });
    const af_child = try Label.create(alloc, "16 : 9", .{ .font_size = 16, .color = math.Color.hex(0xF8FAFCFF) });
    af_child.base.layout_style.align_self = .center;
    try af.setChild(&af_child.base);
    try root.base.addChild(alloc, &af.base);

    g_root = root;
    g_tree_alloc = alloc;
}

fn section(alloc: std.mem.Allocator, parent: *Container, title: []const u8) !void {
    const l = try Label.create(alloc, title, .{ .font_size = 15, .font_weight = 600, .color = math.Color.hex(0xCBD5E1FF) });
    l.base.layout_style.margin.top = 6;
    try parent.base.addChild(alloc, &l.base);
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
}
