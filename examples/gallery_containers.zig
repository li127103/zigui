//! zigui gallery - 容器类控件 (Containers)
//!
//! 演示:
//!   - Frame      带标题边框的容器
//!   - Expander   可折叠展开容器
//!   - Notebook   多页签容器
//!   - Stack      多页面堆叠容器 (一次显示一个)
//!   - Overlay    叠加层容器 (子控件浮于主内容之上)
//!
//! 运行:  zig build run-gallery-containers

const std = @import("std");
const zigui = @import("zigui");
const math = zigui.math;
const styled_text = zigui.styled_text;
const widget = zigui.widget;

const Container = zigui.container.Container;
const Frame = zigui.frame.Frame;
const Expander = zigui.expander.Expander;
const Notebook = zigui.notebook.Notebook;
const Stack = zigui.stack.Stack;
const Overlay = zigui.overlay.Overlay;
const Label = zigui.label.Label;

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
        .title = "zigui Gallery - Containers",
        .width = 760,
        .height = 920,
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
        .gap = .{ .width = 0, .height = 16 },
    });
    errdefer root.destroy(alloc);

    const title = try Label.create(alloc, "Containers", .{ .font_size = 26, .font_weight = 700, .color = math.Color.hex(0xF8FAFCFF) });
    try root.base.addChild(alloc, &title.base);

    const sub = try Label.create(alloc, "Composite widgets that group or switch children.", .{ .font_size = 13, .color = math.Color.hex(0x64748BFF) });
    try root.base.addChild(alloc, &sub.base);

    // Frame
    const frame = try Frame.create(alloc, "Frame", .{ .bg_color = math.Color.hex(0x1E293BFF), .width = .{ .px = 420 } });
    try frame.setChild(&(try Label.create(alloc, "Content inside a framed box.", .{ .font_size = 14, .color = math.Color.hex(0xE2E8F0FF) })).base);
    try addRow(alloc, root, "Frame", frame);

    // Expander
    const exp = try Expander.create(alloc, "Expander", .{ .expanded = true });
    const exp_content = try Label.create(alloc, "Hidden until expanded.", .{ .font_size = 14, .color = math.Color.hex(0xE2E8F0FF) });
    try exp.base.addChild(alloc, &exp_content.base);
    try addRow(alloc, root, "Expander", exp);

    // Notebook
    const nb = try Notebook.create(alloc, .{});
    nb.base.layout_style.width = .{ .px = 420 };
    nb.base.layout_style.height = .{ .px = 140 };
    _ = try nb.appendPage("Page A", &(try Label.create(alloc, "First page content.", .{ .font_size = 14, .color = math.Color.hex(0xE2E8F0FF) })).base);
    _ = try nb.appendPage("Page B", &(try Label.create(alloc, "Second page content.", .{ .font_size = 14, .color = math.Color.hex(0xE2E8F0FF) })).base);
    _ = try nb.appendPage("Page C", &(try Label.create(alloc, "Third page content.", .{ .font_size = 14, .color = math.Color.hex(0xE2E8F0FF) })).base);
    try addRow(alloc, root, "Notebook", nb);

    // Stack
    const stack = try Stack.create(alloc, .{ .width = .{ .px = 420 }, .height = .{ .px = 120 } });
    _ = try stack.addChild(&(try Label.create(alloc, "Stack page 0", .{ .font_size = 16, .color = math.Color.hex(0xF8FAFCFF) })).base);
    _ = try stack.addChild(&(try Label.create(alloc, "Stack page 1", .{ .font_size = 16, .color = math.Color.hex(0xF8FAFCFF) })).base);
    try addRow(alloc, root, "Stack", stack);

    // Overlay
    const ov = try Overlay.create(alloc, .{ .bg_color = math.Color.hex(0x1E293BFF), .corner_radius = 10, .width = .{ .px = 420 }, .height = .{ .px = 120 } });
    const ov_main = try Label.create(alloc, "Main content", .{ .font_size = 16, .color = math.Color.hex(0xE2E8F0FF) });
    try ov.setChild(&ov_main.base);
    const ov_badge = try Label.create(alloc, "★", .{ .font_size = 18, .color = math.Color.hex(0xFBBF24FF) });
    ov_badge.base.layout_style.position = .absolute;
    ov_badge.base.layout_style.top = 8;
    ov_badge.base.layout_style.right = 8;
    try ov.addOverlay(&ov_badge.base);
    try addRow(alloc, root, "Overlay", ov);

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
