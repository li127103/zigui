//! ScrollBar 控件 - 滚动条 (可独立使用, 也被 ScrollView 内部复用)
//!
//! 通过 scroll_ratio (0..1 滚动位置) 与 thumb_ratio (可见/总长 比例) 描述状态,
//! 拖动滑块或点击轨道时经 on_scroll 回调通知宿主。

const std = @import("std");
const math = @import("../math.zig");
const widget_mod = @import("widget.zig");
const layout_mod = @import("../layout/engine.zig");
const pal = @import("../pal/pal.zig");

const Widget = widget_mod.Widget;
const PaintContext = widget_mod.PaintContext;
const EventContext = widget_mod.EventContext;
const EventResult = widget_mod.EventResult;

pub const Orientation = enum { vertical, horizontal };

pub const ScrollBar = struct {
    base: Widget,
    orientation: Orientation,
    /// 滚动位置 0..1 (0 = 顶部/左端, 1 = 底部/右端)
    scroll_ratio: f32,
    /// 滑块占比 0..1 (可见长度 / 内容总长; >=1 时隐藏滑块)
    thumb_ratio: f32,
    /// 滚动回调 (新 scroll_ratio)
    on_scroll: ?*const fn (self: *ScrollBar, ratio: f32) void,
    // 样式
    track_color: math.Color,
    thumb_color: math.Color,
    thumb_hover_color: math.Color,
    thumb_active_color: math.Color,
    corner_radius: f32,
    min_thumb: f32,
    // 拖动状态
    dragging: bool = false,
    drag_offset: f32 = 0, // 指针相对滑块起点的偏移 (像素)
    hover_thumb: bool = false,

    pub fn create(allocator: std.mem.Allocator, opts: struct {
        orientation: Orientation = .vertical,
        scroll_ratio: f32 = 0,
        thumb_ratio: f32 = 0.5,
        thickness: f32 = 10.0,
        length: f32 = 200.0,
        on_scroll: ?*const fn (self: *ScrollBar, ratio: f32) void = null,
        track_color: math.Color = math.Color.hex(0x1E293B66),
        thumb_color: math.Color = math.Color.hex(0x475569FF),
        thumb_hover_color: math.Color = math.Color.hex(0x64748BFF),
        thumb_active_color: math.Color = math.Color.hex(0x94A3B8FF),
        corner_radius: f32 = 5.0,
        min_thumb: f32 = 24.0,
    }) !*ScrollBar {
        const self = try allocator.create(ScrollBar);
        self.* = .{
            .base = .{
                .vtable = &vtable,
                .id = widget_mod.genWidgetId(),
            },
            .orientation = opts.orientation,
            .scroll_ratio = std.math.clamp(opts.scroll_ratio, 0, 1),
            .thumb_ratio = std.math.clamp(opts.thumb_ratio, 0, 1),
            .on_scroll = opts.on_scroll,
            .track_color = opts.track_color,
            .thumb_color = opts.thumb_color,
            .thumb_hover_color = opts.thumb_hover_color,
            .thumb_active_color = opts.thumb_active_color,
            .corner_radius = opts.corner_radius,
            .min_thumb = opts.min_thumb,
        };
        if (opts.orientation == .vertical) {
            self.base.rect.width = opts.thickness;
            self.base.rect.height = opts.length;
        } else {
            self.base.rect.width = opts.length;
            self.base.rect.height = opts.thickness;
        }
        return self;
    }

    pub fn destroy(self: *ScrollBar, allocator: std.mem.Allocator) void {
        self.base.background.deinit(allocator);
        self.base.children.deinit(allocator);
        allocator.destroy(self);
    }

    /// 更新状态 (由宿主在滚动时调用)
    pub fn update(self: *ScrollBar, scroll_ratio: f32, thumb_ratio: f32) void {
        self.scroll_ratio = std.math.clamp(scroll_ratio, 0, 1);
        self.thumb_ratio = std.math.clamp(thumb_ratio, 0, 1);
        self.base.markDirty();
    }

    fn trackLen(self: *const ScrollBar) f32 {
        return if (self.orientation == .vertical) self.base.rect.height else self.base.rect.width;
    }

    fn thumbLen(self: *const ScrollBar) f32 {
        if (self.thumb_ratio >= 1.0) return 0;
        return @max(self.min_thumb, self.trackLen() * self.thumb_ratio);
    }

    fn thumbStart(self: *const ScrollBar) f32 {
        const free = self.trackLen() - self.thumbLen();
        return free * self.scroll_ratio;
    }

    /// 设置滚动位置并触发回调 (内部使用)
    fn setRatio(self: *ScrollBar, ratio: f32) void {
        const clamped = std.math.clamp(ratio, 0, 1);
        if (clamped == self.scroll_ratio) return;
        self.scroll_ratio = clamped;
        self.base.markDirty();
        if (self.on_scroll) |cb| cb(self, clamped);
    }

    // ── VTable 实现 ──────────────────────────────────────────────────────────

    const vtable = Widget.VTable{
        .type_name = "scroll_bar",
        .measure = measure,
        .paint = paint,
        .on_event = onEvent,
        .focusable = false,
        .destroy = destroyVTable,
    };

    fn destroyVTable(w: *Widget, allocator: std.mem.Allocator) void {
        const self: *ScrollBar = @fieldParentPtr("base", w);
        self.destroy(allocator);
    }

    fn measure(w: *Widget, ctx: *PaintContext, constraints: layout_mod.Constraints) math.Size(f32) {
        _ = ctx;
        _ = constraints;
        return .{ .width = w.rect.width, .height = w.rect.height };
    }

    fn paint(w: *Widget, ctx: *PaintContext) void {
        const self: *ScrollBar = @fieldParentPtr("base", w);
        const rx = ctx.offset_x + w.rect.x;
        const ry = ctx.offset_y + w.rect.y;

        // 轨道
        ctx.renderer.fillRoundedRect(
            .{ .x = rx, .y = ry, .width = w.rect.width, .height = w.rect.height },
            self.corner_radius,
            self.track_color,
        ) catch {};

        // 内容未溢出 → 不画滑块
        if (self.thumb_ratio >= 1.0) return;

        const thumb_color = if (self.dragging) self.thumb_active_color else if (self.hover_thumb) self.thumb_hover_color else self.thumb_color;
        const tl = self.thumbLen();
        const ts = self.thumbStart();
        const thumb_rect: math.Rect(f32) = if (self.orientation == .vertical)
            .{ .x = rx, .y = ry + ts, .width = w.rect.width, .height = tl }
        else
            .{ .x = rx + ts, .y = ry, .width = tl, .height = w.rect.height };
        ctx.renderer.fillRoundedRect(thumb_rect, self.corner_radius, thumb_color) catch {};
    }

    fn onEvent(w: *Widget, event: *const pal.Event, ectx: *EventContext) EventResult {
        const self: *ScrollBar = @fieldParentPtr("base", w);
        if (self.thumb_ratio >= 1.0) return .ignored;

        const abs = w.absoluteRect();
        switch (event.*) {
            .mouse_button => |mb| {
                if (mb.button != .left) return .ignored;
                const local = if (self.orientation == .vertical)
                    @as(f32, @floatFromInt(mb.y)) - abs.y
                else
                    @as(f32, @floatFromInt(mb.x)) - abs.x;

                if (mb.state == .pressed) {
                    const ts = self.thumbStart();
                    const tl = self.thumbLen();
                    if (local >= ts and local <= ts + tl) {
                        // 抓住滑块
                        self.dragging = true;
                        self.drag_offset = local - ts;
                        self.base.markDirty();
                    } else {
                        // 点击轨道: 以点击点为中心跳转
                        const free = self.trackLen() - tl;
                        if (free > 0) self.setRatio((local - tl / 2.0) / free);
                    }
                    return .handled;
                } else if (mb.state == .released and self.dragging) {
                    self.dragging = false;
                    self.base.markDirty();
                    return .handled;
                }
            },
            .mouse_move => |mm| {
                const local = if (self.orientation == .vertical)
                    @as(f32, @floatFromInt(mm.y)) - abs.y
                else
                    @as(f32, @floatFromInt(mm.x)) - abs.x;

                if (self.dragging) {
                    const free = self.trackLen() - self.thumbLen();
                    if (free > 0) self.setRatio((local - self.drag_offset) / free);
                    return .handled;
                }
                // 悬停高亮
                const ts = self.thumbStart();
                const tl = self.thumbLen();
                const over = local >= ts and local <= ts + tl;
                if (over != self.hover_thumb) {
                    self.hover_thumb = over;
                    self.base.markDirty();
                }
            },
            else => {},
        }
        _ = ectx;
        return .ignored;
    }
};

// ── Tests ──────────────────────────────────────────────────────────────────

test "scroll_bar thumb geometry" {
    const sb = try ScrollBar.create(std.testing.allocator, .{
        .orientation = .vertical,
        .scroll_ratio = 0,
        .thumb_ratio = 0.5,
        .thickness = 10,
        .length = 200,
    });
    defer sb.destroy(std.testing.allocator);

    // 轨道 200, 滑块 = max(24, 200*0.5)=100
    try std.testing.expectEqual(@as(f32, 200), sb.trackLen());
    try std.testing.expectEqual(@as(f32, 100), sb.thumbLen());
    try std.testing.expectEqual(@as(f32, 0), sb.thumbStart());

    // 滚到底: free=100, start=100
    sb.scroll_ratio = 1.0;
    try std.testing.expectEqual(@as(f32, 100), sb.thumbStart());
}

test "scroll_bar clamps ratio and hides when full" {
    const sb = try ScrollBar.create(std.testing.allocator, .{
        .thumb_ratio = 1.0,
    });
    defer sb.destroy(std.testing.allocator);
    try std.testing.expectEqual(@as(f32, 0), sb.thumbLen()); // 未溢出 → 无滑块

    sb.update(2.0, 0.5);
    try std.testing.expectEqual(@as(f32, 1.0), sb.scroll_ratio); // 夹紧到 1
    sb.update(-1.0, 0.5);
    try std.testing.expectEqual(@as(f32, 0.0), sb.scroll_ratio); // 夹紧到 0
}
