//! zigui gallery - 选择类控件 (Choosers)
//!
//! 演示 (均为真正的可交互控件):
//!   - ColorButton   颜色选择按钮 (点击弹出取色对话框)
//!   - FontButton    字体选择按钮 (点击弹出字体对话框)
//!   - LinkButton    超链接按钮 (下划线 + 悬停高亮)
//!
//! 运行:  zig build run-gallery-choosers

const std = @import("std");
const zigui = @import("zigui");
const math = zigui.math;
const styled_text = zigui.styled_text;
const widget = zigui.widget;

const Container = zigui.container.Container;
const Label = zigui.label.Label;
const ColorButton = zigui.color_button.ColorButton;
const FontButton = zigui.font_button.FontButton;
const LinkButton = zigui.link_button.LinkButton;

const pal = zigui.pal;

const theme_dark: zigui.theme.Theme = zigui.theme.dark;

var g_root: ?*Container = null;
var g_tree_alloc: ?std.mem.Allocator = null;
var g_prev_mouse_down: bool = false;

var g_status_label: ?*Label = null;
var g_status_buf: [128]u8 = undefined;

pub fn main() !void {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var app = try zigui.app.App.init(allocator, .{
        .title = "zigui Gallery - Choosers",
        .width = 560,
        .height = 520,
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

    const title = try Label.create(alloc, "Choosers", .{ .font_size = 26, .font_weight = 700, .color = math.Color.hex(0xF8FAFCFF) });
    try root.base.addChild(alloc, &title.base);

    const sub = try Label.create(alloc, "Pickers open native-style dialogs; the link is a real hyperlink button.", .{ .font_size = 13, .color = math.Color.hex(0x64748BFF) });
    try root.base.addChild(alloc, &sub.base);

    // 颜色选择按钮
    const cb = try ColorButton.create(alloc, .{
        .color = math.Color.hex(0x3B82F6FF),
        .on_color_changed = onColorChanged,
    });
    try addRow(alloc, root, "ColorButton", &cb.base);

    // 字体选择按钮
    const fb = try FontButton.create(alloc, .{
        .family = "Sans",
        .size = 14,
        .bold = false,
    });
    try addRow(alloc, root, "FontButton", &fb.base);

    // 超链接按钮
    const lb = try LinkButton.create(alloc, "Visit zigui docs", .{
        .url = "https://github.com",
        .on_click = onLinkClicked,
    });
    try addRow(alloc, root, "LinkButton", &lb.base);

    // 状态行
    const status = try Label.create(alloc, "Interact with the controls above.", .{ .font_size = 13, .color = math.Color.hex(0x94A3B8FF) });
    status.base.layout_style.margin.top = 10;
    try root.base.addChild(alloc, &status.base);
    g_status_label = status;

    g_root = root;
    g_tree_alloc = alloc;
}

fn rowContainer(alloc: std.mem.Allocator) !*Container {
    const row = try Container.create(alloc, .{
        .direction = .row,
        .gap = .{ .width = 12, .height = 0 },
    });
    row.base.layout_style.align_items = .center;
    return row;
}

fn caption(alloc: std.mem.Allocator, text: []const u8) !*Label {
    const l = try Label.create(alloc, text, .{ .font_size = 13, .color = math.Color.hex(0x94A3B8FF) });
    l.base.layout_style.width = .{ .px = 110 };
    return l;
}

fn addRow(alloc: std.mem.Allocator, parent: *Container, cap: []const u8, ctrl: anytype) !void {
    const row = try rowContainer(alloc);
    try row.base.addChild(alloc, &(try caption(alloc, cap)).base);
    try row.base.addChild(alloc, ctrl);
    try parent.base.addChild(alloc, &row.base);
}

fn destroyTree() void {
    if (g_root) |root| {
        root.destroy(g_tree_alloc orelse return);
        g_root = null;
    }
}

// ── 回调 ──
fn onColorChanged(_: *ColorButton, color: math.Color) void {
    const hex_val: u32 = (@as(u32, color.r) << 24) | (@as(u32, color.g) << 16) | (@as(u32, color.b) << 8) | @as(u32, color.a);
    const s = std.fmt.bufPrint(&g_status_buf, "Color selected: #{X:0<8}", .{hex_val}) catch "Color selected";
    if (g_status_label) |l| l.text = s;
}

fn onLinkClicked(_: *LinkButton) void {
    if (g_status_label) |l| l.text = "Link activated (would open URL).";
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
