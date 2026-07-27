//! zigui 布局容器示例 - Linux 版本
//!
//! 展示: Stack / Frame / CenterBox / FlowBox / Overlay
//!
//! 交互:
//!   - Stack: 点击按钮切换页面 (上一页/下一页)
//!   - Frame: 带标题的边框分组容器
//!   - CenterBox: 三栏居中布局 (开始/居中/结束)
//!   - FlowBox: 流式自适应网格布局
//!   - Overlay: 叠加层 (点击按钮显示/隐藏浮层)

const std = @import("std");
const zigui = @import("zigui");
const math = zigui.math;
const styled_text = zigui.styled_text;
const widget = zigui.widget;
const pal = zigui.pal;

const Container = zigui.container.Container;
const Label = zigui.label.Label;
const Button = zigui.button.Button;
const Stack = zigui.stack.Stack;
const Frame = zigui.frame.Frame;
const CenterBox = zigui.center_box.CenterBox;
const FlowBox = zigui.flow_box.FlowBox;
const Overlay = zigui.overlay.Overlay;

const theme_dark: zigui.theme.Theme = zigui.theme.dark;

var g_root: ?*Container = null;
var g_alloc: ?std.mem.Allocator = null;
var g_stack: ?*Stack = null;
var g_stack_label: ?*Label = null;
var g_stack_buf: [32]u8 = undefined;
var g_overlay: ?*Overlay = null;
var g_overlay_visible: bool = false;
var g_frame: u32 = 0;
var g_prev_mouse_down: bool = false;

pub fn main() !void {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var app = try zigui.app.App.init(allocator, .{
        .title = "zigui - Layout Containers Demo (Linux)",
        .width = 1000,
        .height = 720,
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
    });
    errdefer root.destroy(alloc);

    try buildHeader(root, alloc);
    try buildBody(root, alloc);

    g_root = root;
    g_alloc = alloc;
}

fn buildHeader(root: *Container, alloc: std.mem.Allocator) !void {
    const header = try Container.create(alloc, .{
        .bg_color = math.Color.hex(0x1E293BFF),
        .direction = .row,
        .height = .{ .px = 64 },
        .padding = .{ .left = 20, .top = 0, .right = 20, .bottom = 0 },
    });
    header.base.layout_style.align_items = .center;
    try root.base.addChild(alloc, &header.base);

    const title = try Label.create(alloc, "Layout Containers Showcase", .{
        .font_size = 22,
        .font_weight = 700,
        .color = math.Color.hex(0xF8FAFCFF),
    });
    try header.base.addChild(alloc, &title.base);
}

fn buildBody(root: *Container, alloc: std.mem.Allocator) !void {
    const body = try Container.create(alloc, .{
        .direction = .row,
        .gap = .{ .width = 16, .height = 0 },
        .padding = .{ .left = 16, .top = 16, .right = 16, .bottom = 16 },
    });
    body.base.layout_style.flex_grow = 1;
    try root.base.addChild(alloc, &body.base);

    try buildLeftColumn(body, alloc);
    try buildRightColumn(body, alloc);
}

fn buildLeftColumn(body: *Container, alloc: std.mem.Allocator) !void {
    const col = try Container.create(alloc, .{
        .bg_color = math.Color.hex(0x1E293BFF),
        .corner_radius = 12,
        .direction = .column,
        .width = .{ .px = 420 },
        .padding = math.EdgeInsets.all(16),
        .gap = .{ .width = 0, .height = 16 },
    });
    col.base.layout_style.flex_shrink = 0;
    try body.base.addChild(alloc, &col.base);

    try buildStackDemo(col, alloc);
    try buildFrameDemo(col, alloc);
}

fn buildRightColumn(body: *Container, alloc: std.mem.Allocator) !void {
    const col = try Container.create(alloc, .{
        .direction = .column,
        .gap = .{ .width = 0, .height = 16 },
    });
    col.base.layout_style.flex_grow = 1;
    col.base.layout_style.min_width = .{ .px = 0 };
    try body.base.addChild(alloc, &col.base);

    try buildCenterBoxDemo(col, alloc);
    try buildFlowBoxDemo(col, alloc);
    try buildOverlayDemo(col, alloc);
}

fn addSection(parent: *Container, alloc: std.mem.Allocator, text: []const u8) !void {
    const lbl = try Label.create(alloc, text, .{
        .font_size = 13,
        .font_weight = 700,
        .color = math.Color.hex(0x64748BFF),
    });
    try parent.base.addChild(alloc, &lbl.base);
}

fn buildStackDemo(parent: *Container, alloc: std.mem.Allocator) !void {
    try addSection(parent, alloc, "Stack 多页面堆叠切换");

    const demo = try Container.create(alloc, .{
        .direction = .column,
        .gap = .{ .width = 0, .height = 10 },
    });
    try parent.base.addChild(alloc, &demo.base);

    const stack = try Stack.create(alloc, .{
        .bg_color = math.Color.hex(0x334155FF),
        .corner_radius = 8,
        .height = .{ .px = 160 },
    });
    g_stack = stack;
    try demo.base.addChild(alloc, &stack.base);

    const page1 = try Container.create(alloc, .{
        .direction = .column,
        .padding = math.EdgeInsets.all(16),
        .bg_color = math.Color.hex(0x3B82F6FF),
        .corner_radius = 8,
    });
    const p1_title = try Label.create(alloc, "Page 1 - Welcome", .{
        .font_size = 18,
        .font_weight = 700,
        .color = math.Color.hex(0xFFFFFFFF),
    });
    try page1.base.addChild(alloc, &p1_title.base);
    const p1_desc = try Label.create(alloc, "这是第一页的内容", .{
        .font_size = 13,
        .color = math.Color.hex(0xE0E7FFFF),
    });
    p1_desc.base.layout_style.margin.top = 6;
    try page1.base.addChild(alloc, &p1_desc.base);
    try stack.addChild(&page1.base);

    const page2 = try Container.create(alloc, .{
        .direction = .column,
        .padding = math.EdgeInsets.all(16),
        .bg_color = math.Color.hex(0x10B981FF),
        .corner_radius = 8,
    });
    const p2_title = try Label.create(alloc, "Page 2 - Settings", .{
        .font_size = 18,
        .font_weight = 700,
        .color = math.Color.hex(0xFFFFFFFF),
    });
    try page2.base.addChild(alloc, &p2_title.base);
    const p2_desc = try Label.create(alloc, "这是第二页的内容", .{
        .font_size = 13,
        .color = math.Color.hex(0xD1FAE5FF),
    });
    p2_desc.base.layout_style.margin.top = 6;
    try page2.base.addChild(alloc, &p2_desc.base);
    try stack.addChild(&page2.base);

    const page3 = try Container.create(alloc, .{
        .direction = .column,
        .padding = math.EdgeInsets.all(16),
        .bg_color = math.Color.hex(0xF59E0BFF),
        .corner_radius = 8,
    });
    const p3_title = try Label.create(alloc, "Page 3 - Profile", .{
        .font_size = 18,
        .font_weight = 700,
        .color = math.Color.hex(0xFFFFFFFF),
    });
    try page3.base.addChild(alloc, &p3_title.base);
    const p3_desc = try Label.create(alloc, "这是第三页的内容", .{
        .font_size = 13,
        .color = math.Color.hex(0xFEF3C7FF),
    });
    p3_desc.base.layout_style.margin.top = 6;
    try page3.base.addChild(alloc, &p3_desc.base);
    try stack.addChild(&page3.base);

    const btn_row = try Container.create(alloc, .{
        .direction = .row,
        .gap = .{ .width = 8, .height = 0 },
    });
    try demo.base.addChild(alloc, &btn_row.base);

    const prev_btn = try Button.create(alloc, "← 上一页", .{
        .on_click = onPrevPage,
    });
    prev_btn.base.layout_style.height = .{ .px = 32 };
    try btn_row.base.addChild(alloc, &prev_btn.base);

    const next_btn = try Button.create(alloc, "下一页 →", .{
        .on_click = onNextPage,
    });
    next_btn.base.layout_style.height = .{ .px = 32 };
    try btn_row.base.addChild(alloc, &next_btn.base);

    const page_label = try Label.create(alloc, "第 1 / 3 页", .{
        .font_size = 13,
        .color = math.Color.hex(0x94A3B8FF),
    });
    page_label.base.layout_style.margin.top = 8;
    g_stack_label = page_label;
    try demo.base.addChild(alloc, &page_label.base);
}

fn buildFrameDemo(parent: *Container, alloc: std.mem.Allocator) !void {
    try addSection(parent, alloc, "Frame 带标题的边框分组");

    const frame = try Frame.create(alloc, "User Information", .{
        .border_color = math.Color.hex(0x475569FF),
        .border_width = 1,
        .corner_radius = 8,
        .padding = .{ .left = 12, .top = 8, .right = 12, .bottom = 12 },
        .bg_color = math.Color.hex(0x1E293BFF),
    });
    try parent.base.addChild(alloc, &frame.base);

    const content = try Container.create(alloc, .{
        .direction = .column,
        .gap = .{ .width = 0, .height = 8 },
    });
    try frame.setChild(&content.base);

    const name_row = try Container.create(alloc, .{ .direction = .row, .gap = .{ .width = 8, .height = 0 } });
    const name_lbl = try Label.create(alloc, "姓名:", .{ .color = math.Color.hex(0x94A3B8FF), .font_size = 13 });
    name_lbl.base.layout_style.width = .{ .px = 50 };
    try name_row.base.addChild(alloc, &name_lbl.base);
    const name_val = try Label.create(alloc, "张三", .{ .color = math.Color.hex(0xF1F5F9FF), .font_size = 13 });
    try name_row.base.addChild(alloc, &name_val.base);
    try content.base.addChild(alloc, &name_row.base);

    const email_row = try Container.create(alloc, .{ .direction = .row, .gap = .{ .width = 8, .height = 0 } });
    const email_lbl = try Label.create(alloc, "邮箱:", .{ .color = math.Color.hex(0x94A3B8FF), .font_size = 13 });
    email_lbl.base.layout_style.width = .{ .px = 50 };
    try email_row.base.addChild(alloc, &email_lbl.base);
    const email_val = try Label.create(alloc, "zhangsan@example.com", .{ .color = math.Color.hex(0xF1F5F9FF), .font_size = 13 });
    try email_row.base.addChild(alloc, &email_val.base);
    try content.base.addChild(alloc, &email_row.base);

    const role_row = try Container.create(alloc, .{ .direction = .row, .gap = .{ .width = 8, .height = 0 } });
    const role_lbl = try Label.create(alloc, "角色:", .{ .color = math.Color.hex(0x94A3B8FF), .font_size = 13 });
    role_lbl.base.layout_style.width = .{ .px = 50 };
    try role_row.base.addChild(alloc, &role_lbl.base);
    const role_val = try Label.create(alloc, "管理员", .{ .color = math.Color.hex(0x34D399FF), .font_size = 13 });
    try role_row.base.addChild(alloc, &role_val.base);
    try content.base.addChild(alloc, &role_row.base);
}

fn buildCenterBoxDemo(parent: *Container, alloc: std.mem.Allocator) !void {
    try addSection(parent, alloc, "CenterBox 三栏居中布局");

    const cb_row = try Container.create(alloc, .{
        .bg_color = math.Color.hex(0x1E293BFF),
        .corner_radius = 12,
        .padding = math.EdgeInsets.all(16),
        .direction = .column,
        .gap = .{ .width = 0, .height = 12 },
    });
    try parent.base.addChild(alloc, &cb_row.base);

    const cb_h = try CenterBox.create(alloc, .{
        .direction = .row,
        .bg_color = math.Color.hex(0x0F172AFF),
        .corner_radius = 8,
        .height = .{ .px = 60 },
    });
    try cb_row.base.addChild(alloc, &cb_h.base);

    const start_h = try Label.create(alloc, "← Start", .{
        .font_size = 14,
        .color = math.Color.hex(0x60A5FAFF),
    });
    start_h.base.layout_style.margin.left = 12;
    start_h.base.layout_style.margin.top = 20;
    try cb_h.setStart(&start_h.base);

    const center_h = try Label.create(alloc, "Center (居中)", .{
        .font_size = 16,
        .font_weight = 700,
        .color = math.Color.hex(0xF8FAFCFF),
    });
    center_h.base.layout_style.margin.top = 18;
    try cb_h.setCenter(&center_h.base);

    const end_h = try Label.create(alloc, "End →", .{
        .font_size = 14,
        .color = math.Color.hex(0x34D399FF),
    });
    end_h.base.layout_style.margin.right = 12;
    end_h.base.layout_style.margin.top = 20;
    try cb_h.setEnd(&end_h.base);

    const cb_v_label = try Label.create(alloc, "垂直方向:", .{
        .font_size = 12,
        .color = math.Color.hex(0x64748BFF),
    });
    try cb_row.base.addChild(alloc, &cb_v_label.base);

    const cb_v = try CenterBox.create(alloc, .{
        .direction = .column,
        .bg_color = math.Color.hex(0x0F172AFF),
        .corner_radius = 8,
        .height = .{ .px = 160 },
    });
    try cb_row.base.addChild(alloc, &cb_v.base);

    const top_v = try Label.create(alloc, "▲ Top", .{
        .font_size = 13,
        .color = math.Color.hex(0x60A5FAFF),
    });
    top_v.base.layout_style.margin.top = 10;
    try cb_v.setStart(&top_v.base);

    const middle_v = try Label.create(alloc, "Middle (垂直居中)", .{
        .font_size = 14,
        .font_weight = 700,
        .color = math.Color.hex(0xF8FAFCFF),
    });
    try cb_v.setCenter(&middle_v.base);

    const bottom_v = try Label.create(alloc, "Bottom ▼", .{
        .font_size = 13,
        .color = math.Color.hex(0x34D399FF),
    });
    bottom_v.base.layout_style.margin.bottom = 10;
    try cb_v.setEnd(&bottom_v.base);
}

fn buildFlowBoxDemo(parent: *Container, alloc: std.mem.Allocator) !void {
    try addSection(parent, alloc, "FlowBox 流式自适应网格");

    const flow_container = try Container.create(alloc, .{
        .bg_color = math.Color.hex(0x1E293BFF),
        .corner_radius = 12,
        .padding = math.EdgeInsets.all(16),
        .direction = .column,
        .gap = .{ .width = 0, .height = 10 },
    });
    try parent.base.addChild(alloc, &flow_container.base);

    const flow = try FlowBox.create(alloc, .{
        .direction = .row,
        .row_gap = 8,
        .col_gap = 8,
    });
    flow.base.layout_style.flex_grow = 1;
    try flow_container.base.addChild(alloc, &flow.base);

    const colors = [_]u32{
        0xEF4444FF, 0xF97316FF, 0xF59E0BFF, 0xEAB308FF,
        0x84CC16FF, 0x22C55EFF, 0x10B981FF, 0x14B8A6FF,
        0x06B6D4FF, 0x0EA5E9FF, 0x3B82F6FF, 0x6366F1FF,
        0x8B5CF6FF, 0xA855F7FF, 0xD946EFF,  0xEC4899FF,
    };

    for (colors, 0..) |c, i| {
        const item = try Container.create(alloc, .{
            .bg_color = math.Color.hex(c),
            .corner_radius = 6,
            .width = .{ .px = 70 },
            .height = .{ .px = 50 },
            .direction = .column,
        });
        const num_lbl = try Label.create(alloc, "", .{ .font_size = 14, .font_weight = 700, .color = math.Color.hex(0xFFFFFFFF) });
        num_lbl.base.layout_style.margin.top = 16;
        num_lbl.base.layout_style.margin.left = 28;
        const buf = try alloc.alloc(u8, 4);
        const len = std.fmt.bufPrint(buf, "{}", .{i + 1}) catch "?";
        num_lbl.text = len;
        try item.base.addChild(alloc, &num_lbl.base);
        try flow.addChild(&item.base);
    }
}

fn buildOverlayDemo(parent: *Container, alloc: std.mem.Allocator) !void {
    try addSection(parent, alloc, "Overlay 叠加层");

    const overlay_container = try Container.create(alloc, .{
        .bg_color = math.Color.hex(0x1E293BFF),
        .corner_radius = 12,
        .padding = math.EdgeInsets.all(16),
        .direction = .column,
        .gap = .{ .width = 0, .height = 10 },
    });
    try parent.base.addChild(alloc, &overlay_container.base);

    const overlay = try Overlay.create(alloc, .{
        .bg_color = math.Color.hex(0x0F172AFF),
        .corner_radius = 8,
        .height = .{ .px = 140 },
    });
    g_overlay = overlay;
    try overlay_container.base.addChild(alloc, &overlay.base);

    const base_content = try Container.create(alloc, .{
        .direction = .column,
        .padding = math.EdgeInsets.all(16),
    });
    const base_title = try Label.create(alloc, "基础内容层", .{
        .font_size = 16,
        .font_weight = 700,
        .color = math.Color.hex(0xF8FAFCFF),
    });
    try base_content.base.addChild(alloc, &base_title.base);
    const base_desc = try Label.create(alloc, "点击下方按钮显示/隐藏浮层", .{
        .font_size = 13,
        .color = math.Color.hex(0x94A3B8FF),
    });
    base_desc.base.layout_style.margin.top = 4;
    try base_content.base.addChild(alloc, &base_desc.base);
    try overlay.setChild(&base_content.base);

    const toggle_btn = try Button.create(alloc, "显示浮层", .{
        .on_click = onToggleOverlay,
    });
    toggle_btn.base.layout_style.height = .{ .px = 32 };
    try overlay_container.base.addChild(alloc, &toggle_btn.base);
}

fn destroyTree() void {
    if (g_root) |root| {
        root.destroy(g_alloc orelse return);
        g_root = null;
    }
}

fn onPrevPage(btn: *Button) void {
    if (g_stack) |s| {
        s.prev();
        updateStackLabel();
    }
    _ = btn;
}

fn onNextPage(btn: *Button) void {
    if (g_stack) |s| {
        s.next();
        updateStackLabel();
    }
    _ = btn;
}

fn updateStackLabel() void {
    if (g_stack) |s| {
        if (g_stack_label) |lbl| {
            const total = s.base.children.items.len;
            const current = s.getVisibleIndex() + 1;
            lbl.text = std.fmt.bufPrint(&g_stack_buf, "第 {d} / {d} 页", .{ current, total }) catch "?";
        }
    }
}

fn onToggleOverlay(btn: *Button) void {
    g_overlay_visible = !g_overlay_visible;
    if (g_overlay) |o| {
        const alloc = g_alloc orelse return;
        if (g_overlay_visible) {
            const float_layer = createFloatLayer(alloc) catch return;
            float_layer.base.layout_style.left = 20;
            float_layer.base.layout_style.top = 20;
            o.addOverlay(&float_layer.base) catch {};
            btn.label = "隐藏浮层";
        } else {
            if (o.base.children.items.len > 1) {
                const child = o.base.children.items[o.base.children.items.len - 1];
                o.base.removeChild(alloc, child);
            }
            btn.label = "显示浮层";
        }
    }
}

fn createFloatLayer(alloc: std.mem.Allocator) !*Container {
    const layer = try Container.create(alloc, .{
        .bg_color = math.Color.hex(0x7C3AEDFF),
        .corner_radius = 10,
        .width = .{ .px = 200 },
        .height = .{ .px = 80 },
        .direction = .column,
        .padding = math.EdgeInsets.all(12),
    });
    const title = try Label.create(alloc, "浮层提示", .{
        .font_size = 14,
        .font_weight = 700,
        .color = math.Color.hex(0xFFFFFFFF),
    });
    try layer.base.addChild(alloc, &title.base);
    const desc = try Label.create(alloc, "这是一个叠加浮层", .{
        .font_size = 12,
        .color = math.Color.hex(0xE9D5FFFF),
    });
    desc.base.layout_style.margin.top = 4;
    try layer.base.addChild(alloc, &desc.base);
    return layer;
}

fn drawFrame(app: *zigui.app.App) void {
    g_frame += 1;
    const root = g_root orelse return;
    const fb = app.getFramebufferSize();
    const w: f32 = @floatFromInt(fb.width);
    const h: f32 = @floatFromInt(fb.height);

    dispatchInput(app);

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

fn dispatchInput(app: *zigui.app.App) void {
    const root = g_root orelse return;
    var ectx = widget.EventContext{ .mouse_x = app.mouse_x, .mouse_y = app.mouse_y };
    const mx: i32 = @intFromFloat(app.mouse_x);
    const my: i32 = @intFromFloat(app.mouse_y);

    var ev_move = pal.Event{ .mouse_move = .{ .x = mx, .y = my } };
    _ = root.base.dispatchEvent(&ev_move, &ectx);

    if (app.mouse_clicked) {
        var ev = pal.Event{ .mouse_button = .{ .button = .left, .state = .pressed, .x = mx, .y = my } };
        _ = root.base.dispatchEvent(&ev, &ectx);
    }
    const md = app.mouse_down;
    if (!md and g_prev_mouse_down) {
        var ev = pal.Event{ .mouse_button = .{ .button = .left, .state = .released, .x = mx, .y = my } };
        _ = root.base.dispatchEvent(&ev, &ectx);
    }
    g_prev_mouse_down = md;

    if (app.scroll_delta != 0) {
        var ev = pal.Event{ .scroll = .{ .axis = .vertical, .delta = app.scroll_delta } };
        _ = root.base.dispatchEvent(&ev, &ectx);
    }

    if (app.key_hit) |key| {
        if (key == .tab) {
            if (app.key_mods.shift) {
                _ = root.base.focusPrev();
            } else {
                _ = root.base.focusNext();
            }
            return;
        }
        var ev = pal.Event{ .key = .{ .state = .pressed, .key = key, .modifiers = app.key_mods } };
        _ = root.base.dispatchEvent(&ev, &ectx);
    }
}
