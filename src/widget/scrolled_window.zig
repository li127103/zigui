//! ScrolledWindow 控件 - 滚动容器
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

/// GTK4: GtkPolicyType — 滚动条显示策略
pub const PolicyType = enum {
    /// 始终显示滚动条 (即使不溢出)
    always,
    /// 内容溢出时才显示滚动条 (默认)
    automatic,
    /// 永不显示滚动条 (也不支持滚动)
    never,
    /// 不绘制内部滚动条, 由外部控件提供滚动
    external,
};

pub const ScrolledWindow = struct {
    base: Widget,
    scroll_x: f32 = 0,
    scroll_y: f32 = 0,
    scroll_enabled_x: bool,
    scroll_enabled_y: bool,
    /// GTK4: gtk_scrolled_window_set_policy (水平/垂直滚动条策略)
    hscrollbar_policy: PolicyType = .automatic,
    vscrollbar_policy: PolicyType = .automatic,
    /// GTK4: gtk_scrolled_window_set_has_frame — 显示边框
    has_frame: bool = false,
    /// GTK4: gtk_scrolled_window_set_min_content_width
    min_content_width: f32 = 0,
    /// GTK4: gtk_scrolled_window_set_min_content_height
    min_content_height: f32 = 0,
    /// 内容尺寸 (布局时由子项计算)
    content_width: f32 = 0,
    content_height: f32 = 0,
    // 样式
    scrollbar_thickness: f32,
    scrollbar_color: math.Color,
    scrollbar_active_color: math.Color,
    /// has_frame=true 时的边框颜色/粗细
    frame_color: math.Color = math.Color.hex(0x334155FF),
    frame_width: f32 = 1.0,
    corner_radius: f32,
    /// 滚轮单步像素
    wheel_step: f32 = 40.0,
    // 拖动状态
    dragging_v: bool = false,
    dragging_h: bool = false,
    drag_offset: f32 = 0,
    /// GTK4: gtk_scrolled_window_set_kinetic_scrolling
    kinetic_scrolling: bool = true,
    /// GTK4: gtk_scrolled_window_set_overlay_scrolling
    overlay_scrolling: bool = true,

    pub fn create(allocator: std.mem.Allocator, opts: struct {
        width: ?f32 = null,
        height: ?f32 = null,
        scroll_enabled_x: bool = false,
        scroll_enabled_y: bool = true,
        hscrollbar_policy: ?PolicyType = null,
        vscrollbar_policy: ?PolicyType = null,
        has_frame: bool = false,
        min_content_width: f32 = 0,
        min_content_height: f32 = 0,
        direction: layout_mod.FlexDirection = .column,
        padding: math.EdgeInsets = .{},
        gap: math.Size(f32) = .{ .width = 0, .height = 0 },
        bg_color: ?math.Color = null,
        scrollbar_thickness: f32 = 8.0,
        scrollbar_color: math.Color = math.Color.hex(0x475569AA),
        scrollbar_active_color: math.Color = math.Color.hex(0x94A3B8FF),
        frame_color: math.Color = math.Color.hex(0x334155FF),
        frame_width: f32 = 1.0,
        corner_radius: f32 = 0.0,
    }) !*ScrolledWindow {
        const self = try allocator.create(ScrolledWindow);
        const hp: PolicyType = opts.hscrollbar_policy orelse
            (if (opts.scroll_enabled_x) PolicyType.automatic else PolicyType.never);
        const vp: PolicyType = opts.vscrollbar_policy orelse
            (if (opts.scroll_enabled_y) PolicyType.automatic else PolicyType.never);
        const s_x = hp != .never and hp != .external;
        const s_y = vp != .never and vp != .external;
        self.* = .{
            .base = .{
                .vtable = &vtable,
                .id = widget_mod.genWidgetId(),
            },
            .scroll_enabled_x = s_x,
            .scroll_enabled_y = s_y,
            .hscrollbar_policy = hp,
            .vscrollbar_policy = vp,
            .has_frame = opts.has_frame,
            .min_content_width = opts.min_content_width,
            .min_content_height = opts.min_content_height,
            .scrollbar_thickness = opts.scrollbar_thickness,
            .scrollbar_color = opts.scrollbar_color,
            .scrollbar_active_color = opts.scrollbar_active_color,
            .frame_color = opts.frame_color,
            .frame_width = opts.frame_width,
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

    pub fn destroy(self: *ScrolledWindow, allocator: std.mem.Allocator) void {
        self.base.background.deinit(allocator);
        for (self.base.children.items) |child| {
            child.vtable.destroy(child, allocator);
        }
        self.base.children.deinit(allocator);
        allocator.destroy(self);
    }

    // ── GTK4 API 对齐 ─────────────────────────────────────────────────────

    /// GTK4: gtk_scrolled_window_set_policy
    pub fn setPolicy(self: *ScrolledWindow, h: PolicyType, v: PolicyType) void {
        self.hscrollbar_policy = h;
        self.vscrollbar_policy = v;
        self.scroll_enabled_x = h != .never and h != .external;
        self.scroll_enabled_y = v != .never and v != .external;
        if (!self.scroll_enabled_x) self.scroll_x = 0;
        if (!self.scroll_enabled_y) self.scroll_y = 0;
        self.base.markDirty();
    }

    /// GTK4: gtk_scrolled_window_get_policy
    pub fn getPolicy(self: *const ScrolledWindow, out_h: *PolicyType, out_v: *PolicyType) void {
        out_h.* = self.hscrollbar_policy;
        out_v.* = self.vscrollbar_policy;
    }

    /// GTK4: gtk_scrolled_window_set_has_frame
    pub fn setHasFrame(self: *ScrolledWindow, has: bool) void {
        self.has_frame = has;
        self.base.markDirty();
    }
    pub fn getHasFrame(self: *const ScrolledWindow) bool {
        return self.has_frame;
    }

    /// GTK4: gtk_scrolled_window_set_min_content_width
    pub fn setMinContentWidth(self: *ScrolledWindow, w: f32) void {
        self.min_content_width = @max(0, w);
        self.base.markLayoutDirty();
    }
    pub fn getMinContentWidth(self: *const ScrolledWindow) f32 {
        return self.min_content_width;
    }
    pub fn setMinContentHeight(self: *ScrolledWindow, h: f32) void {
        self.min_content_height = @max(0, h);
        self.base.markLayoutDirty();
    }
    pub fn getMinContentHeight(self: *const ScrolledWindow) f32 {
        return self.min_content_height;
    }

    /// GTK4: gtk_scrolled_window_set_child — 替换为单 child (GTK4 单 child)
    /// 清空现有 children 并添加传入 widget；传 null 仅清空。
    pub fn setChild(self: *ScrolledWindow, allocator: std.mem.Allocator, child: ?*Widget) void {
        // destroy 现有 children
        for (self.base.children.items) |c| c.vtable.destroy(c, allocator);
        self.base.children.clearRetainingCapacity();
        if (child) |c| self.base.addChild(allocator, c) catch {};
        self.base.markLayoutDirty();
        self.base.markDirty();
    }

    /// GTK4: gtk_scrolled_window_get_child — 返回第一个 child (GTK4 单 child)
    pub fn getChild(self: *const ScrolledWindow) ?*Widget {
        return if (self.base.children.items.len > 0) self.base.children.items[0] else null;
    }

    /// GTK4: gtk_scrolled_window_set_kinetic_scrolling
    pub fn setKineticScrolling(self: *ScrolledWindow, v: bool) void {
        self.kinetic_scrolling = v;
        self.base.markDirty();
    }

    /// GTK4: gtk_scrolled_window_set_overlay_scrolling
    pub fn setOverlayScrolling(self: *ScrolledWindow, v: bool) void {
        self.overlay_scrolling = v;
        self.base.markDirty();
    }

    // ── 滚动状态 ──────────────────────────────────────────────────────────

    fn maxScrollX(self: *const ScrolledWindow) f32 {
        if (!self.scroll_enabled_x) return 0;
        return @max(0, self.content_width - self.base.rect.width);
    }

    fn maxScrollY(self: *const ScrolledWindow) f32 {
        if (!self.scroll_enabled_y) return 0;
        return @max(0, self.content_height - self.base.rect.height);
    }

    pub fn scrollTo(self: *ScrolledWindow, x: f32, y: f32) void {
        self.scroll_x = std.math.clamp(x, 0, self.maxScrollX());
        self.scroll_y = std.math.clamp(y, 0, self.maxScrollY());
        self.applyClip();
        self.base.markDirty();
        self.base.markLayoutDirty();
    }

    pub fn scrollBy(self: *ScrolledWindow, dx: f32, dy: f32) void {
        self.scrollTo(self.scroll_x + dx, self.scroll_y + dy);
    }

    /// 更新子树裁剪矩形 (视口, 绝对坐标)
    fn applyClip(self: *ScrolledWindow) void {
        const abs = self.base.absoluteRect();
        self.base.clip_children = math.Rect(f32){
            .x = abs.x,
            .y = abs.y,
            .width = self.base.rect.width,
            .height = self.base.rect.height,
        };
    }

    // ── 滚动条几何 ──────────────────────────────────────────────────────────

    fn verticalBarRect(self: *const ScrolledWindow) math.Rect(f32) {
        return .{
            .x = self.base.rect.width - self.scrollbar_thickness,
            .y = 0,
            .width = self.scrollbar_thickness,
            .height = self.base.rect.height,
        };
    }

    fn horizontalBarRect(self: *const ScrolledWindow) math.Rect(f32) {
        return .{
            .x = 0,
            .y = self.base.rect.height - self.scrollbar_thickness,
            .width = self.base.rect.width,
            .height = self.scrollbar_thickness,
        };
    }

    /// 滑块矩形 (相对控件局部坐标)
    fn thumbRect(self: *const ScrolledWindow, vertical: bool) math.Rect(f32) {
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
        const self: *ScrolledWindow = @fieldParentPtr("base", w);
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
        const self: *ScrolledWindow = @fieldParentPtr("base", w);
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

    fn layoutAbsoluteChild(self: *ScrolledWindow, child: *Widget, ctx: *PaintContext) void {
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
        const self: *ScrolledWindow = @fieldParentPtr("base", w);
        const rx = ctx.offset_x + w.rect.x;
        const ry = ctx.offset_y + w.rect.y;

        // 边框 (GTK4: has_frame)
        if (self.has_frame and self.frame_width > 0) {
            ctx.renderer.strokeRoundedRect(
                .{ .x = rx, .y = ry, .width = w.rect.width, .height = w.rect.height },
                self.corner_radius,
                self.frame_width,
                self.frame_color,
            ) catch {};
        }

        // 垂直滚动条
        const show_v = switch (self.vscrollbar_policy) {
            .never, .external => false,
            .always => true,
            .automatic => self.content_height > w.rect.height,
        };
        if (self.scroll_enabled_y and show_v) {
            const bar = self.verticalBarRect();
            // always policy 时画轨道背景
            if (self.vscrollbar_policy == .always) {
                ctx.renderer.fillRoundedRect(
                    .{ .x = rx + bar.x, .y = ry + bar.y, .width = bar.width, .height = bar.height },
                    self.corner_radius,
                    math.Color.rgba(self.scrollbar_color.r, self.scrollbar_color.g, self.scrollbar_color.b, 0x22),
                ) catch {};
            }
            const thumb = self.thumbRect(true);
            if (thumb.height > 0 or self.vscrollbar_policy == .always) {
                ctx.renderer.fillRoundedRect(
                    .{ .x = rx + thumb.x, .y = ry + thumb.y, .width = thumb.width, .height = @max(2, thumb.height) },
                    self.corner_radius,
                    if (self.dragging_v) self.scrollbar_active_color else self.scrollbar_color,
                ) catch {};
            }
        }

        // 水平滚动条
        const show_h = switch (self.hscrollbar_policy) {
            .never, .external => false,
            .always => true,
            .automatic => self.content_width > w.rect.width,
        };
        if (self.scroll_enabled_x and show_h) {
            const bar = self.horizontalBarRect();
            if (self.hscrollbar_policy == .always) {
                ctx.renderer.fillRoundedRect(
                    .{ .x = rx + bar.x, .y = ry + bar.y, .width = bar.width, .height = bar.height },
                    self.corner_radius,
                    math.Color.rgba(self.scrollbar_color.r, self.scrollbar_color.g, self.scrollbar_color.b, 0x22),
                ) catch {};
            }
            const thumb = self.thumbRect(false);
            if (thumb.width > 0 or self.hscrollbar_policy == .always) {
                ctx.renderer.fillRoundedRect(
                    .{ .x = rx + thumb.x, .y = ry + thumb.y, .width = @max(2, thumb.width), .height = thumb.height },
                    self.corner_radius,
                    if (self.dragging_h) self.scrollbar_active_color else self.scrollbar_color,
                ) catch {};
            }
        }
    }

    fn onEvent(w: *Widget, event: *const pal.Event, ectx: *EventContext) EventResult {
        const self: *ScrolledWindow = @fieldParentPtr("base", w);
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

pub const ScrollView = ScrolledWindow;

// ── Tests ──────────────────────────────────────────────────────────────────

test "scroll_view clamps scroll offset" {
    const sv = try ScrolledWindow.create(std.testing.allocator, .{
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
    const sv = try ScrolledWindow.create(std.testing.allocator, .{
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
    const sv = try ScrolledWindow.create(std.testing.allocator, .{});
    defer sv.destroy(std.testing.allocator);
    sv.content_height = 50;
    sv.base.rect.height = 100;
    const t = sv.thumbRect(true);
    try std.testing.expectEqual(@as(f32, 0), t.height); // 内容未溢出 → 无滑块
}

test "scroll wheel routes to ScrolledWindow under mouse" {
    const alloc = std.testing.allocator;
    const Container = @import("container.zig").Container;

    const root = try Container.create(alloc, .{});
    defer root.destroy(alloc);
    root.base.rect = .{ .x = 0, .y = 0, .width = 400, .height = 400 };

    const sv = try ScrolledWindow.create(alloc, .{ .width = 200, .height = 100 });
    try root.base.addChild(alloc, &sv.base);
    sv.base.rect = .{ .x = 10, .y = 10, .width = 200, .height = 100 };
    sv.content_height = 500; // 内容溢出 → 可滚动

    const ev = pal.Event{ .scroll = .{ .window_id = 0, .axis = .vertical, .delta = -1 } }; // 负 delta = 滚轮向下 (与 Wayland 约定一致)

    // 鼠标在 ScrolledWindow 范围内 (绝对坐标 50,50) → 滚轮生效
    var ectx_in = widget_mod.EventContext{ .mouse_x = 50, .mouse_y = 50 };
    const res = root.base.dispatchEvent(&ev, &ectx_in);
    try std.testing.expectEqual(widget_mod.EventResult.handled, res);
    try std.testing.expect(sv.scroll_y != 0);

    // 鼠标在 ScrolledWindow 范围外 (绝对坐标 300,300) → 不滚动
    const before = sv.scroll_y;
    var ectx_out = widget_mod.EventContext{ .mouse_x = 300, .mouse_y = 300 };
    _ = root.base.dispatchEvent(&ev, &ectx_out);
    try std.testing.expectEqual(before, sv.scroll_y);
}

test "keyboard routes to focused ScrolledWindow" {
    const alloc = std.testing.allocator;
    const Container = @import("container.zig").Container;

    const root = try Container.create(alloc, .{});
    defer root.destroy(alloc);
    root.base.rect = .{ .x = 0, .y = 0, .width = 400, .height = 400 };

    const sv = try ScrolledWindow.create(alloc, .{ .width = 200, .height = 100 });
    try root.base.addChild(alloc, &sv.base);
    sv.base.rect = .{ .x = 0, .y = 0, .width = 200, .height = 100 };
    sv.content_height = 500;
    sv.base.state.focused = true; // 聚焦后才能接收键盘事件

    var ectx = widget_mod.EventContext{};
    const ev = pal.Event{ .key = .{ .window_id = 0, .state = .pressed, .key = .down, .modifiers = .{} } };
    const res = root.base.dispatchEvent(&ev, &ectx);
    try std.testing.expectEqual(widget_mod.EventResult.handled, res);
    try std.testing.expect(sv.scroll_y > 0); // 方向键下 → 向下滚动
}
