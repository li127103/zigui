//! ScrollView 控件 - 滚动容器
//!
//! 子项按 flexbox 排布为内容, 内容超出视口时可滚动 (滚轮/方向键/拖动滚动条)。
//! 通过 vtable.perform_layout 覆盖默认布局以应用滚动偏移, 并经 base.clip_children
//! 将子树绘制裁剪到视口。滚动条为内部绘制 (非子控件), 支持拖动滑块。

const std = @import("std");
const math = @import("../math.zig");
const widget_mod = @import("widget.zig");
const layout_mod = @import("../layout/engine.zig");
const pal = @import("../pal/pal.zig");

const Widget = widget_mod.Widget;
const PaintContext = widget_mod.PaintContext;
const EventContext = widget_mod.EventContext;
const EventResult = widget_mod.EventResult;

pub const ScrollView = struct {
    base: Widget,
    scroll_x: f32 = 0,
    scroll_y: f32 = 0,
    scroll_enabled_x: bool,
    scroll_enabled_y: bool,
    /// 内容尺寸 (布局时由子项计算)
    content_width: f32 = 0,
    content_height: f32 = 0,
    // 样式
    scrollbar_thickness: f32,
    scrollbar_color: math.Color,
    scrollbar_active_color: math.Color,
    corner_radius: f32,
    /// 滚轮单步像素
    wheel_step: f32 = 40.0,
    // 拖动状态
    dragging_v: bool = false,
    dragging_h: bool = false,
    drag_offset: f32 = 0,

    pub fn create(allocator: std.mem.Allocator, opts: struct {
        width: ?f32 = null,
        height: ?f32 = null,
        scroll_enabled_x: bool = false,
        scroll_enabled_y: bool = true,
        direction: layout_mod.FlexDirection = .column,
        padding: math.EdgeInsets = .{},
        gap: math.Size(f32) = .{ .width = 0, .height = 0 },
        bg_color: ?math.Color = null,
        scrollbar_thickness: f32 = 8.0,
        scrollbar_color: math.Color = math.Color.hex(0x475569AA),
        scrollbar_active_color: math.Color = math.Color.hex(0x94A3B8FF),
        corner_radius: f32 = 0.0,
    }) !*ScrollView {
        const self = try allocator.create(ScrollView);
        self.* = .{
            .base = .{
                .vtable = &vtable,
                .id = widget_mod.genWidgetId(),
            },
            .scroll_enabled_x = opts.scroll_enabled_x,
            .scroll_enabled_y = opts.scroll_enabled_y,
            .scrollbar_thickness = opts.scrollbar_thickness,
            .scrollbar_color = opts.scrollbar_color,
            .scrollbar_active_color = opts.scrollbar_active_color,
            .corner_radius = opts.corner_radius,
        };
        self.base.layout_style.direction = opts.direction;
        self.base.layout_style.padding = opts.padding;
        self.base.layout_style.gap = opts.gap;
        if (opts.width) |w| self.base.layout_style.width = .{ .px = w };
        if (opts.height) |h| self.base.layout_style.height = .{ .px = h };
        if (opts.bg_color) |c| self.base.background.bg = .{ .color = c };
        self.base.background.corner_radius = opts.corner_radius;
        self.base.accessibility = .{ .role = .scroll_area };
        return self;
    }

    pub fn destroy(self: *ScrollView, allocator: std.mem.Allocator) void {
        self.base.background.deinit(allocator);
        for (self.base.children.items) |child| {
            child.vtable.destroy(child, allocator);
        }
        self.base.children.deinit(allocator);
        allocator.destroy(self);
    }

    // ── 滚动状态 ──────────────────────────────────────────────────────────

    fn maxScrollX(self: *const ScrollView) f32 {
        if (!self.scroll_enabled_x) return 0;
        return @max(0, self.content_width - self.base.rect.width);
    }

    fn maxScrollY(self: *const ScrollView) f32 {
        if (!self.scroll_enabled_y) return 0;
        return @max(0, self.content_height - self.base.rect.height);
    }

    pub fn scrollTo(self: *ScrollView, x: f32, y: f32) void {
        self.scroll_x = std.math.clamp(x, 0, self.maxScrollX());
        self.scroll_y = std.math.clamp(y, 0, self.maxScrollY());
        self.applyClip();
        self.base.markDirty();
        self.base.markLayoutDirty();
    }

    pub fn scrollBy(self: *ScrollView, dx: f32, dy: f32) void {
        self.scrollTo(self.scroll_x + dx, self.scroll_y + dy);
    }

    /// 更新子树裁剪矩形 (视口, 绝对坐标)
    fn applyClip(self: *ScrollView) void {
        const abs = self.base.absoluteRect();
        self.base.clip_children = math.Rect(f32){
            .x = abs.x,
            .y = abs.y,
            .width = self.base.rect.width,
            .height = self.base.rect.height,
        };
    }

    // ── 滚动条几何 ──────────────────────────────────────────────────────────

    fn verticalBarRect(self: *const ScrollView) math.Rect(f32) {
        return .{
            .x = self.base.rect.width - self.scrollbar_thickness,
            .y = 0,
            .width = self.scrollbar_thickness,
            .height = self.base.rect.height,
        };
    }

    fn horizontalBarRect(self: *const ScrollView) math.Rect(f32) {
        return .{
            .x = 0,
            .y = self.base.rect.height - self.scrollbar_thickness,
            .width = self.base.rect.width,
            .height = self.scrollbar_thickness,
        };
    }

    /// 滑块矩形 (相对控件局部坐标)
    fn thumbRect(self: *const ScrollView, vertical: bool) math.Rect(f32) {
        const min_thumb: f32 = 24.0;
        if (vertical) {
            const bar = self.verticalBarRect();
            const ratio = if (self.content_height > 0) self.base.rect.height / self.content_height else 1.0;
            if (ratio >= 1.0) return .{ .x = 0, .y = 0, .width = 0, .height = 0 };
            const tl = @max(min_thumb, bar.height * ratio);
            const free = bar.height - tl;
            const ts = free * (self.scroll_y / self.maxScrollY());
            return .{ .x = bar.x, .y = bar.y + ts, .width = bar.width, .height = tl };
        } else {
            const bar = self.horizontalBarRect();
            const ratio = if (self.content_width > 0) self.base.rect.width / self.content_width else 1.0;
            if (ratio >= 1.0) return .{ .x = 0, .y = 0, .width = 0, .height = 0 };
            const tl = @max(min_thumb, bar.width * ratio);
            const free = bar.width - tl;
            const ts = free * (self.scroll_x / self.maxScrollX());
            return .{ .x = bar.x + ts, .y = bar.y, .width = tl, .height = bar.height };
        }
    }

    // ── VTable 实现 ──────────────────────────────────────────────────────────

    const vtable = Widget.VTable{
        .type_name = "scroll_view",
        .measure = measure,
        .paint = paint,
        .on_event = onEvent,
        .perform_layout = performLayoutCustom,
        .focusable = true,
        .destroy = destroyVTable,
    };

    fn destroyVTable(w: *Widget, allocator: std.mem.Allocator) void {
        const self: *ScrollView = @fieldParentPtr("base", w);
        self.destroy(allocator);
    }

    fn measure(w: *Widget, ctx: *PaintContext, constraints: layout_mod.Constraints) math.Size(f32) {
        _ = ctx;
        // 优先使用显式尺寸; 否则取约束上限; 最后回退默认
        var width: f32 = 300;
        var height: f32 = 300;
        if (w.layout_style.width.resolve(constraints.max_width)) |ew| width = ew;
        if (w.layout_style.height.resolve(constraints.max_height)) |eh| height = eh;
        if (!std.math.isFinite(width)) width = 300;
        if (!std.math.isFinite(height)) height = 300;
        return .{ .width = width, .height = height };
    }

    /// 自定义布局: flexbox 排布子项 → 计算内容尺寸 → 夹紧滚动 → 应用偏移
    fn performLayoutCustom(w: *Widget, ctx: *PaintContext) void {
        const self: *ScrollView = @fieldParentPtr("base", w);
        const pad = w.layout_style.padding;
        const is_row = w.layout_style.direction == .row or w.layout_style.direction == .row_reverse;
        const gap: f32 = if (is_row) w.layout_style.gap.width else w.layout_style.gap.height;

        // 内容可用宽度 (列方向限制子项宽; 行方向不限以便内容横向延展)
        const inner_w = w.rect.width - pad.left - pad.right;

        // Pass 1: 测量并定位 (flex 流, 简化: start 对齐)
        var cursor: f32 = 0;
        var max_cross: f32 = 0;
        var count: usize = 0;
        for (w.children.items) |child| {
            if (child.layout_style.position == .absolute) continue;
            if (!child.state.visible) continue;
            const cm = child.layout_style.margin;
            const child_size = child.vtable.measure(child, ctx, .{
                .max_width = if (is_row) std.math.inf(f32) else inner_w,
                .max_height = std.math.inf(f32),
            });
            var cw = child_size.width;
            var ch = child_size.height;
            if (child.layout_style.width.resolve(inner_w)) |ew| cw = ew;
            if (child.layout_style.height.resolve(std.math.inf(f32))) |eh| ch = eh;
            child.rect.width = cw;
            child.rect.height = ch;

            if (is_row) {
                child.rect.x = pad.left + cursor + cm.left;
                child.rect.y = pad.top + cm.top;
                cursor += cw + cm.left + cm.right + gap;
                max_cross = @max(max_cross, ch + cm.top + cm.bottom);
            } else {
                child.rect.x = pad.left + cm.left;
                child.rect.y = pad.top + cursor + cm.top;
                // 列方向: 未显式指定宽度时撑满内容宽
                if (child.layout_style.width == .auto and cw < inner_w - cm.left - cm.right) {
                    child.rect.width = inner_w - cm.left - cm.right;
                }
                cursor += ch + cm.top + cm.bottom + gap;
                max_cross = @max(max_cross, child.rect.width + cm.left + cm.right);
            }
            count += 1;
        }
        if (count > 1) cursor -= gap;

        // 内容尺寸
        if (is_row) {
            self.content_width = cursor + pad.left + pad.right;
            self.content_height = max_cross + pad.top + pad.bottom;
        } else {
            self.content_width = max_cross + pad.left + pad.right;
            self.content_height = cursor + pad.top + pad.bottom;
        }

        // 夹紧滚动偏移
        self.scroll_x = std.math.clamp(self.scroll_x, 0, self.maxScrollX());
        self.scroll_y = std.math.clamp(self.scroll_y, 0, self.maxScrollY());

        // 应用滚动偏移 (平移所有流式子项)
        for (w.children.items) |child| {
            if (child.layout_style.position == .absolute) continue;
            child.rect.x -= self.scroll_x;
            child.rect.y -= self.scroll_y;
            if (child.children.items.len > 0) child.layoutSubtree(ctx);
        }

        // 绝对定位子项 (相对视口固定, 不随内容滚动)
        for (w.children.items) |child| {
            if (child.layout_style.position != .absolute) continue;
            self.layoutAbsoluteChild(child, ctx);
        }

        self.applyClip();
    }

    fn layoutAbsoluteChild(self: *ScrollView, child: *Widget, ctx: *PaintContext) void {
        const cs = child.layout_style;
        const child_size = child.vtable.measure(child, ctx, .{
            .max_width = self.base.rect.width,
            .max_height = self.base.rect.height,
        });
        var cw = child_size.width;
        var ch = child_size.height;
        if (cs.width.resolve(self.base.rect.width)) |ew| cw = ew;
        if (cs.height.resolve(self.base.rect.height)) |eh| ch = eh;
        child.rect.width = cw;
        child.rect.height = ch;
        child.rect.x = cs.left orelse (if (cs.right) |rv| self.base.rect.width - rv - cw else 0);
        child.rect.y = cs.top orelse (if (cs.bottom) |bv| self.base.rect.height - bv - ch else 0);
        if (child.children.items.len > 0) child.layoutSubtree(ctx);
    }

    fn paint(w: *Widget, ctx: *PaintContext) void {
        const self: *ScrollView = @fieldParentPtr("base", w);
        const rx = ctx.offset_x + w.rect.x;
        const ry = ctx.offset_y + w.rect.y;

        // 垂直滚动条
        if (self.scroll_enabled_y and self.content_height > w.rect.height) {
            const bar = self.verticalBarRect();
            const thumb = self.thumbRect(true);
            ctx.renderer.fillRoundedRect(
                .{ .x = rx + thumb.x, .y = ry + thumb.y, .width = thumb.width, .height = thumb.height },
                self.corner_radius,
                if (self.dragging_v) self.scrollbar_active_color else self.scrollbar_color,
            ) catch {};
            _ = bar;
        }

        // 水平滚动条
        if (self.scroll_enabled_x and self.content_width > w.rect.width) {
            const thumb = self.thumbRect(false);
            ctx.renderer.fillRoundedRect(
                .{ .x = rx + thumb.x, .y = ry + thumb.y, .width = thumb.width, .height = thumb.height },
                self.corner_radius,
                if (self.dragging_h) self.scrollbar_active_color else self.scrollbar_color,
            ) catch {};
        }
    }

    fn onEvent(w: *Widget, event: *const pal.Event, ectx: *EventContext) EventResult {
        const self: *ScrollView = @fieldParentPtr("base", w);
        _ = ectx;
        const abs = w.absoluteRect();

        switch (event.*) {
            .scroll => |sc| {
                if (sc.axis == .vertical and self.scroll_enabled_y) {
                    const before = self.scroll_y;
                    self.scrollBy(0, -sc.delta * self.wheel_step);
                    if (self.scroll_y != before or self.maxScrollY() > 0) return .handled;
                } else if (sc.axis == .horizontal and self.scroll_enabled_x) {
                    const before = self.scroll_x;
                    self.scrollBy(-sc.delta * self.wheel_step, 0);
                    if (self.scroll_x != before or self.maxScrollX() > 0) return .handled;
                }
            },
            .mouse_button => |mb| {
                if (mb.button != .left) return .ignored;
                const lx: f32 = @floatFromInt(mb.x);
                const ly: f32 = @floatFromInt(mb.y);
                const local_x = lx - abs.x;
                const local_y = ly - abs.y;
                if (mb.state == .pressed) {
                    // 优先命中滚动条滑块
                    if (self.scroll_enabled_y and self.content_height > w.rect.height) {
                        const t = self.thumbRect(true);
                        if (local_x >= t.x and local_x <= t.x + t.width and local_y >= t.y and local_y <= t.y + t.height) {
                            self.dragging_v = true;
                            self.drag_offset = local_y - t.y;
                            return .handled;
                        }
                    }
                    if (self.scroll_enabled_x and self.content_width > w.rect.width) {
                        const t = self.thumbRect(false);
                        if (local_x >= t.x and local_x <= t.x + t.width and local_y >= t.y and local_y <= t.y + t.height) {
                            self.dragging_h = true;
                            self.drag_offset = local_x - t.x;
                            return .handled;
                        }
                    }
                } else if (mb.state == .released) {
                    if (self.dragging_v or self.dragging_h) {
                        self.dragging_v = false;
                        self.dragging_h = false;
                        return .handled;
                    }
                }
            },
            .mouse_move => |mm| {
                if (self.dragging_v) {
                    const local_y = @as(f32, @floatFromInt(mm.y)) - abs.y;
                    const bar = self.verticalBarRect();
                    const thumb = self.thumbRect(true);
                    const free = bar.height - thumb.height;
                    if (free > 0) self.scrollTo(self.scroll_x, (local_y - self.drag_offset) / free * self.maxScrollY());
                    return .handled;
                }
                if (self.dragging_h) {
                    const local_x = @as(f32, @floatFromInt(mm.x)) - abs.x;
                    const bar = self.horizontalBarRect();
                    const thumb = self.thumbRect(false);
                    const free = bar.width - thumb.width;
                    if (free > 0) self.scrollTo((local_x - self.drag_offset) / free * self.maxScrollX(), self.scroll_y);
                    return .handled;
                }
            },
            .key => |k| {
                if (k.state != .pressed or !w.state.focused) return .ignored;
                const page_y = w.rect.height * 0.9;
                switch (k.key) {
                    .up => self.scrollBy(0, -self.wheel_step),
                    .down => self.scrollBy(0, self.wheel_step),
                    .left => self.scrollBy(-self.wheel_step, 0),
                    .right => self.scrollBy(self.wheel_step, 0),
                    .page_up => self.scrollBy(0, -page_y),
                    .page_down => self.scrollBy(0, page_y),
                    .home => self.scrollTo(self.scroll_x, 0),
                    .end => self.scrollTo(self.scroll_x, self.maxScrollY()),
                    else => return .ignored,
                }
                return .handled;
            },
            else => {},
        }
        return .ignored;
    }
};

// ── Tests ──────────────────────────────────────────────────────────────────

test "scroll_view clamps scroll offset" {
    const sv = try ScrollView.create(std.testing.allocator, .{
        .width = 200,
        .height = 100,
    });
    defer sv.destroy(std.testing.allocator);

    sv.content_height = 500;
    sv.base.rect.width = 200;
    sv.base.rect.height = 100;

    try std.testing.expectEqual(@as(f32, 400), sv.maxScrollY());

    sv.scrollTo(0, 1000);
    try std.testing.expectEqual(@as(f32, 400), sv.scroll_y); // 夹紧到 max
    sv.scrollTo(0, -50);
    try std.testing.expectEqual(@as(f32, 0), sv.scroll_y); // 夹紧到 0
}

test "scroll_view disabled axis has zero max scroll" {
    const sv = try ScrollView.create(std.testing.allocator, .{
        .scroll_enabled_x = false,
        .scroll_enabled_y = true,
    });
    defer sv.destroy(std.testing.allocator);
    sv.content_width = 1000;
    sv.content_height = 1000;
    sv.base.rect.width = 100;
    sv.base.rect.height = 100;
    try std.testing.expectEqual(@as(f32, 0), sv.maxScrollX()); // X 禁用
    try std.testing.expectEqual(@as(f32, 900), sv.maxScrollY());
}

test "scroll_view thumb hidden when content fits" {
    const sv = try ScrollView.create(std.testing.allocator, .{});
    defer sv.destroy(std.testing.allocator);
    sv.content_height = 50;
    sv.base.rect.height = 100;
    const t = sv.thumbRect(true);
    try std.testing.expectEqual(@as(f32, 0), t.height); // 内容未溢出 → 无滑块
}

test "scroll wheel routes to ScrollView under mouse" {
    const alloc = std.testing.allocator;
    const Container = @import("container.zig").Container;

    const root = try Container.create(alloc, .{});
    defer root.destroy(alloc);
    root.base.rect = .{ .x = 0, .y = 0, .width = 400, .height = 400 };

    const sv = try ScrollView.create(alloc, .{ .width = 200, .height = 100 });
    try root.base.addChild(alloc, &sv.base);
    sv.base.rect = .{ .x = 10, .y = 10, .width = 200, .height = 100 };
    sv.content_height = 500; // 内容溢出 → 可滚动

    const ev = pal.Event{ .scroll = .{ .axis = .vertical, .delta = -1 } }; // 负 delta = 滚轮向下 (与 Wayland 约定一致)

    // 鼠标在 ScrollView 范围内 (绝对坐标 50,50) → 滚轮生效
    var ectx_in = widget_mod.EventContext{ .mouse_x = 50, .mouse_y = 50 };
    const res = root.base.dispatchEvent(&ev, &ectx_in);
    try std.testing.expectEqual(widget_mod.EventResult.handled, res);
    try std.testing.expect(sv.scroll_y != 0);

    // 鼠标在 ScrollView 范围外 (绝对坐标 300,300) → 不滚动
    const before = sv.scroll_y;
    var ectx_out = widget_mod.EventContext{ .mouse_x = 300, .mouse_y = 300 };
    _ = root.base.dispatchEvent(&ev, &ectx_out);
    try std.testing.expectEqual(before, sv.scroll_y);
}

test "keyboard routes to focused ScrollView" {
    const alloc = std.testing.allocator;
    const Container = @import("container.zig").Container;

    const root = try Container.create(alloc, .{});
    defer root.destroy(alloc);
    root.base.rect = .{ .x = 0, .y = 0, .width = 400, .height = 400 };

    const sv = try ScrollView.create(alloc, .{ .width = 200, .height = 100 });
    try root.base.addChild(alloc, &sv.base);
    sv.base.rect = .{ .x = 0, .y = 0, .width = 200, .height = 100 };
    sv.content_height = 500;
    sv.base.state.focused = true; // 聚焦后才能接收键盘事件

    var ectx = widget_mod.EventContext{};
    const ev = pal.Event{ .key = .{ .state = .pressed, .key = .down, .modifiers = .{} } };
    const res = root.base.dispatchEvent(&ev, &ectx);
    try std.testing.expectEqual(widget_mod.EventResult.handled, res);
    try std.testing.expect(sv.scroll_y > 0); // 方向键下 → 向下滚动
}
