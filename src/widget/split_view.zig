//! SplitView 控件 - 可拖拽分割面板
//!
//! 将区域分为两个可调整大小的窗格, 中间为可拖拽的分割条。
//! 支持水平 (左右) 与垂直 (上下) 两种方向。

const std = @import("std");
const math = @import("../math.zig");
const widget_mod = @import("widget.zig");
const layout_mod = @import("../layout/engine.zig");
const pal = @import("../pal/pal.zig");

const Widget = widget_mod.Widget;
const PaintContext = widget_mod.PaintContext;
const EventContext = widget_mod.EventContext;
const EventResult = widget_mod.EventResult;

pub const Orientation = enum { horizontal, vertical };

pub const SplitView = struct {
    base: Widget,
    allocator: std.mem.Allocator,
    orientation: Orientation,
    /// 第一个窗格占比 (0.0 ~ 1.0)
    split_ratio: f32,
    /// 分割条厚度 (px)
    divider_size: f32,
    /// 单个窗格的最小尺寸 (px)
    min_pane_size: f32,
    /// 两个内容窗格 (可选, 由 SplitView 负责布局与绘制)
    pane_a: ?*Widget = null,
    pane_b: ?*Widget = null,
    /// 拖拽状态
    dragging: bool = false,
    divider_hover: bool = false,
    on_change: ?*const fn (self: *SplitView, ratio: f32) void,
    // 样式
    bg_color: math.Color = math.Color.hex(0x0F172AFF),
    divider_color: math.Color = math.Color.hex(0x334155FF),
    divider_hover_color: math.Color = math.Color.hex(0x3B82F6FF),
    grabber_color: math.Color = math.Color.hex(0x64748BFF),
    corner_radius: f32 = 10.0,

    pub fn create(allocator: std.mem.Allocator, opts: struct {
        orientation: Orientation = .horizontal,
        split_ratio: f32 = 0.5,
        divider_size: f32 = 8.0,
        min_pane_size: f32 = 60.0,
        on_change: ?*const fn (self: *SplitView, ratio: f32) void = null,
    }) !*SplitView {
        const self = try allocator.create(SplitView);
        self.* = .{
            .base = .{
                .vtable = &vtable,
                .id = widget_mod.genWidgetId(),
            },
            .allocator = allocator,
            .orientation = opts.orientation,
            .split_ratio = std.math.clamp(opts.split_ratio, 0.0, 1.0),
            .divider_size = opts.divider_size,
            .min_pane_size = opts.min_pane_size,
            .on_change = opts.on_change,
        };
        return self;
    }

    pub fn destroy(self: *SplitView, allocator: std.mem.Allocator) void {
        self.base.children.deinit(allocator);
        allocator.destroy(self);
    }

    pub fn setPanes(self: *SplitView, a: ?*Widget, b: ?*Widget) void {
        self.pane_a = a;
        self.pane_b = b;
        self.base.markDirty();
    }

    pub fn setRatio(self: *SplitView, ratio: f32) void {
        const clamped = self.clampRatio(ratio);
        if (clamped != self.split_ratio) {
            self.split_ratio = clamped;
            self.base.markDirty();
            if (self.on_change) |cb| cb(self, clamped);
        }
    }

    /// 依据窗格最小尺寸约束夹取比例
    fn clampRatio(self: *const SplitView, ratio: f32) f32 {
        const total = self.mainAxisSize();
        const avail = total - self.divider_size;
        if (avail <= 0) return 0.5;
        const min_r = self.min_pane_size / avail;
        const max_r = 1.0 - min_r;
        if (min_r >= max_r) return 0.5;
        return std.math.clamp(ratio, min_r, max_r);
    }

    /// 主轴方向上的总尺寸 (水平为宽, 垂直为高)
    fn mainAxisSize(self: *const SplitView) f32 {
        return if (self.orientation == .horizontal) self.base.rect.width else self.base.rect.height;
    }

    /// 计算三个区域 (窗格A / 分割条 / 窗格B), 坐标相对控件原点
    pub fn paneRects(self: *const SplitView) struct { a: math.Rect(f32), divider: math.Rect(f32), b: math.Rect(f32) } {
        const w = self.base.rect.width;
        const h = self.base.rect.height;
        if (self.orientation == .horizontal) {
            const avail = w - self.divider_size;
            const a_w = avail * self.split_ratio;
            return .{
                .a = .{ .x = 0, .y = 0, .width = a_w, .height = h },
                .divider = .{ .x = a_w, .y = 0, .width = self.divider_size, .height = h },
                .b = .{ .x = a_w + self.divider_size, .y = 0, .width = avail - a_w, .height = h },
            };
        } else {
            const avail = h - self.divider_size;
            const a_h = avail * self.split_ratio;
            return .{
                .a = .{ .x = 0, .y = 0, .width = w, .height = a_h },
                .divider = .{ .x = 0, .y = a_h, .width = w, .height = self.divider_size },
                .b = .{ .x = 0, .y = a_h + self.divider_size, .width = w, .height = avail - a_h },
            };
        }
    }

    fn inDivider(self: *const SplitView, x: f32, y: f32) bool {
        const r = self.paneRects().divider;
        // 扩大命中区域便于抓取
        const pad: f32 = 3.0;
        return x >= r.x - pad and x < r.x + r.width + pad and
            y >= r.y - pad and y < r.y + r.height + pad;
    }

    // ── VTable ──────────────────────────────────────────────────────────────

    const vtable = Widget.VTable{
        .type_name = "split_view",
        .measure = measure,
        .paint = paint,
        .on_event = onEvent,
        .focusable = false,
        .destroy = destroyVTable,
    };

    fn destroyVTable(w: *Widget, allocator: std.mem.Allocator) void {
        const self: *SplitView = @fieldParentPtr("base", w);
        self.destroy(allocator);
    }

    fn measure(w: *Widget, ctx: *PaintContext, constraints: layout_mod.Constraints) math.Size(f32) {
        _ = ctx;
        _ = constraints;
        _ = w;
        return .{ .width = 600, .height = 400 };
    }

    fn paint(w: *Widget, ctx: *PaintContext) void {
        const self: *SplitView = @fieldParentPtr("base", w);
        const rx = ctx.offset_x + w.rect.x;
        const ry = ctx.offset_y + w.rect.y;
        const rw = w.rect.width;
        const rh = w.rect.height;

        // 背景
        ctx.renderer.fillRoundedRect(.{ .x = rx, .y = ry, .width = rw, .height = rh }, self.corner_radius, self.bg_color) catch {};

        const rects = self.paneRects();

        // 内容窗格 (设置相对 rect 后以控件原点为偏移递归绘制)
        var child_ctx = ctx.*;
        child_ctx.offset_x = rx;
        child_ctx.offset_y = ry;
        if (self.pane_a) |pa| {
            pa.rect = rects.a;
            pa.paintTree(&child_ctx);
        }
        if (self.pane_b) |pb| {
            pb.rect = rects.b;
            pb.paintTree(&child_ctx);
        }

        // 分割条
        const d = rects.divider;
        const d_color = if (self.dragging or self.divider_hover) self.divider_hover_color else self.divider_color;
        ctx.renderer.fillRect(.{ .x = rx + d.x, .y = ry + d.y, .width = d.width, .height = d.height }, d_color) catch {};

        // 抓取点 (中点三个小点)
        const cx = rx + d.x + d.width / 2.0;
        const cy = ry + d.y + d.height / 2.0;
        if (self.orientation == .horizontal) {
            var i: i32 = -1;
            while (i <= 1) : (i += 1) {
                const gy = cy + @as(f32, @floatFromInt(i)) * 6.0;
                ctx.renderer.fillRoundedRect(.{ .x = cx - 1.5, .y = gy - 1.5, .width = 3, .height = 3 }, 1.5, self.grabber_color) catch {};
            }
        } else {
            var i: i32 = -1;
            while (i <= 1) : (i += 1) {
                const gx = cx + @as(f32, @floatFromInt(i)) * 6.0;
                ctx.renderer.fillRoundedRect(.{ .x = gx - 1.5, .y = cy - 1.5, .width = 3, .height = 3 }, 1.5, self.grabber_color) catch {};
            }
        }
    }

    fn onEvent(w: *Widget, event: *const pal.Event, ectx: *EventContext) EventResult {
        const self: *SplitView = @fieldParentPtr("base", w);
        _ = ectx;

        switch (event.*) {
            .mouse_button => |mb| {
                if (mb.button != .left) return .ignored;
                const mx: f32 = @floatFromInt(mb.x);
                const my: f32 = @floatFromInt(mb.y);
                if (mb.state == .pressed) {
                    if (self.inDivider(mx, my)) {
                        self.dragging = true;
                        self.base.markDirty();
                        return .handled;
                    }
                } else {
                    if (self.dragging) {
                        self.dragging = false;
                        self.base.markDirty();
                        return .handled;
                    }
                }
            },
            .mouse_move => |mm| {
                const mx: f32 = @floatFromInt(mm.x);
                const my: f32 = @floatFromInt(mm.y);
                if (self.dragging) {
                    const total = self.mainAxisSize();
                    const pos = if (self.orientation == .horizontal) mx else my;
                    const avail = total - self.divider_size;
                    if (avail > 0) {
                        self.setRatio((pos - self.divider_size / 2.0) / avail);
                    }
                    return .handled;
                } else {
                    const hover = self.inDivider(mx, my);
                    if (hover != self.divider_hover) {
                        self.divider_hover = hover;
                        self.base.markDirty();
                    }
                }
            },
            else => {},
        }
        return .ignored;
    }
};

// ── 测试 ──────────────────────────────────────────────────────────────────

test "split_view paneRects horizontal" {
    var sv = SplitView{
        .base = .{ .vtable = undefined, .id = 1 },
        .allocator = std.testing.allocator,
        .orientation = .horizontal,
        .split_ratio = 0.5,
        .divider_size = 8.0,
        .min_pane_size = 60.0,
        .on_change = null,
    };
    sv.base.rect = .{ .x = 0, .y = 0, .width = 208, .height = 100 };
    const r = sv.paneRects();
    // avail = 200, a_w = 100
    try std.testing.expectApproxEqAbs(r.a.width, 100.0, 0.001);
    try std.testing.expectApproxEqAbs(r.divider.x, 100.0, 0.001);
    try std.testing.expectApproxEqAbs(r.b.x, 108.0, 0.001);
    try std.testing.expectApproxEqAbs(r.b.width, 100.0, 0.001);
}

test "split_view clampRatio respects min pane" {
    var sv = SplitView{
        .base = .{ .vtable = undefined, .id = 1 },
        .allocator = std.testing.allocator,
        .orientation = .horizontal,
        .split_ratio = 0.5,
        .divider_size = 8.0,
        .min_pane_size = 50.0,
        .on_change = null,
    };
    sv.base.rect = .{ .x = 0, .y = 0, .width = 208, .height = 100 };
    // avail = 200, min_r = 50/200 = 0.25
    try std.testing.expectApproxEqAbs(sv.clampRatio(0.05), 0.25, 0.001);
    try std.testing.expectApproxEqAbs(sv.clampRatio(0.99), 0.75, 0.001);
    try std.testing.expectApproxEqAbs(sv.clampRatio(0.5), 0.5, 0.001);
}
