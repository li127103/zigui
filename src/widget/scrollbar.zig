//! Scrollbar — GTK4 GtkScrollbar
//!
//! 水平/垂直滚动条：两端 stepper（±）+ 中间轨道 + 可拖拽 slider。
//! 继承语义：首字段 `range: Range`，子类可通过 @ptrCast 转为 Range。
//!

const std = @import("std");
const math = @import("../math.zig");
const widget_mod = @import("widget.zig");
const layout_mod = @import("../layout/engine.zig");
const pal_mod = @import("../pal/pal.zig");
const range_mod = @import("range.zig");
const adj_mod = @import("../model/adjustment.zig");

const Widget = widget_mod.Widget;
const PaintContext = widget_mod.PaintContext;
const EventContext = widget_mod.EventContext;
const EventResult = widget_mod.EventResult;
const Constraints = layout_mod.Constraints;
const Range = range_mod.Range;
const Orientation = range_mod.Orientation;
const Adjustment = adj_mod.Adjustment;
const RectF = math.Rect(f32);
const SizeF = math.Size(f32);

/// GTK4 GtkScrollType
pub const ScrollType = enum(u4) {
    none,
    jump,
    step_backward,
    step_forward,
    page_backward,
    page_forward,
    step_up,
    step_down,
    page_up,
    page_down,
    start,
    end,
};

const ScrollFn = *const fn (ud: ?*anyopaque, scroll_type: ScrollType) void;

pub const Scrollbar = struct {
    range: Range, // 首字段

    // stepper 状态
    stepper_sensitive_a: bool = true, // 首端（左/上）
    stepper_sensitive_b: bool = true, // 末端（右/下）
    hover_a: bool = false,
    hover_b: bool = false,
    hover_slider: bool = false,
    dragging: bool = false,

    stepper_width: f32 = 16,
    slider_min: f32 = 24,

    // 长按
    held_stepper: enum(u2) { none, a, b } = .none,
    long_press_us: i64 = 0,

    on_scroll: ?ScrollFn = null,
    on_scroll_ud: ?*anyopaque = null,

    const Self = @This();

    // ── 构造 / 析构 ───────────────────────────────────────────────────────

    pub fn create(allocator: std.mem.Allocator, orientation: Orientation, adj: ?*Adjustment) !*Self {
        const self = try allocator.create(Self);
        self.* = .{
            .range = .{
                .base = .{
                    .vtable = &vtable,
                    .id = widget_mod.genWidgetId(),
                    .cursor = .arrow,
                },
                .orientation = orientation,
                .adjustment = adj,
            },
        };
        return self;
    }

    pub fn destroy(self: *Self, allocator: std.mem.Allocator) void {
        self.range.destroy();
        allocator.destroy(self);
    }

    pub fn asRange(self: *Self) *Range { return &self.range; }

    pub fn setOnScroll(self: *Self, cb: ?ScrollFn, ud: ?*anyopaque) void {
        self.on_scroll = cb; self.on_scroll_ud = ud;
    }

    fn emitScroll(self: *Self, typ: ScrollType) void {
        if (self.on_scroll) |cb| cb(self.on_scroll_ud, typ);
        // 同时直接处理 adjustment
        const a = self.range.adjustment orelse return;
        const step = a.step_increment;
        const page = @max(step, a.page_increment);
        const dir: f64 = if (self.range.inverted) -1.0 else 1.0;
        switch (typ) {
            .step_backward, .step_up => self.range.setValue(a.value - step * dir),
            .step_forward, .step_down => self.range.setValue(a.value + step * dir),
            .page_backward, .page_up => self.range.setValue(a.value - page * dir),
            .page_forward, .page_down => self.range.setValue(a.value + page * dir),
            .start => self.range.setValue(a.lower),
            .end => self.range.setValue(a.upper),
            .jump, .none => {},
        }
    }

    // ── 几何辅助 ─────────────────────────────────────────────────────────

    fn trackRect(self: *Self) RectF {
        const w = self.range.base.rect;
        const sw = self.stepper_width;
        return switch (self.range.orientation) {
            .horizontal => .{ .x = w.x + sw, .y = w.y, .width = w.width - 2 * sw, .height = w.height },
            .vertical   => .{ .x = w.x, .y = w.y + sw, .width = w.width, .height = w.height - 2 * sw },
        };
    }

    fn sliderRect(self: *Self) RectF {
        const a = self.range.adjustment orelse return RectF{ .x = 0, .y = 0, .width = 0, .height = 0 };
        const tr = self.trackRect();
        // page_size 映射为滑块相对 px；0 = unknown（用 slider_min）
        const span = a.upper - a.lower;
        const page_ratio: f32 = if (span > 0 and a.page_size > 0) @floatCast(a.page_size / span) else 0.0;
        const page_px = switch (self.range.orientation) {
            .horizontal => tr.width * page_ratio,
            .vertical   => tr.height * page_ratio,
        };
        return self.range.sliderRange(tr, @max(self.slider_min, page_px));
    }

    // ── VTable ───────────────────────────────────────────────────────────

    const vtable = Widget.VTable{
        .type_name = "scrollbar",
        .measure = measure,
        .paint = paint,
        .on_event = onEvent,
        .destroy = destroyVTable,
        .tick = tick,
    };

    fn destroyVTable(w: *Widget, allocator: std.mem.Allocator) void {
        const range_ptr: *Range = @fieldParentPtr("base", w);
        const s: *Self = @fieldParentPtr("range", range_ptr);
        s.destroy(allocator);
    }

    fn measure(w: *Widget, _: *PaintContext, c: Constraints) SizeF {
        const range_ptr: *Range = @fieldParentPtr("base", w);
        const s: *Self = @fieldParentPtr("range", range_ptr);
        return s.range.defaultMeasure(c);
    }

    fn paint(w: *Widget, ctx: *PaintContext) void {
        const range_ptr: *Range = @fieldParentPtr("base", w);
        const s: *Self = @fieldParentPtr("range", range_ptr);
        const tr = s.trackRect();
        const sr = s.sliderRect();
        const r = s.range.base.rect;

        const track_color = math.Color.hex(0x1E293BFF);
        const slider_color = math.Color.hex(0x64748BFF);
        const slider_hover = math.Color.hex(0x94A3B8FF);
        const stepper_color = math.Color.hex(0x334155FF);
        const stepper_hover_color = math.Color.hex(0x475569FF);

        // 轨道
        ctx.renderer.fillRect(.{
            .x = ctx.offset_x + tr.x, .y = ctx.offset_y + tr.y,
            .width = tr.width, .height = tr.height,
        }, track_color) catch {};

        // stepper A
        const a_rect = switch (s.range.orientation) {
            .horizontal => RectF{ .x = r.x, .y = r.y, .width = s.stepper_width, .height = r.height },
            .vertical   => RectF{ .x = r.x, .y = r.y, .width = r.width, .height = s.stepper_width },
        };
        ctx.renderer.fillRect(.{
            .x = ctx.offset_x + a_rect.x, .y = ctx.offset_y + a_rect.y,
            .width = a_rect.width, .height = a_rect.height,
        }, if (s.hover_a) stepper_hover_color else stepper_color) catch {};

        // stepper B
        const b_rect = switch (s.range.orientation) {
            .horizontal => RectF{ .x = r.x + r.width - s.stepper_width, .y = r.y, .width = s.stepper_width, .height = r.height },
            .vertical   => RectF{ .x = r.x, .y = r.y + r.height - s.stepper_width, .width = r.width, .height = s.stepper_width },
        };
        ctx.renderer.fillRect(.{
            .x = ctx.offset_x + b_rect.x, .y = ctx.offset_y + b_rect.y,
            .width = b_rect.width, .height = b_rect.height,
        }, if (s.hover_b) stepper_hover_color else stepper_color) catch {};

        // 滑块
        ctx.renderer.fillRect(.{
            .x = ctx.offset_x + sr.x, .y = ctx.offset_y + sr.y,
            .width = sr.width, .height = sr.height,
        }, if (s.hover_slider or s.dragging) slider_hover else slider_color) catch {};
    }

    fn onEvent(w: *Widget, event: *const pal_mod.Event, _: *EventContext) EventResult {
        const range_ptr: *Range = @fieldParentPtr("base", w);
        const s: *Self = @fieldParentPtr("range", range_ptr);
        _ = s;
        _ = event;
        // 真实实现：点击 stepper → step_*；轨道非滑块 → page_*；滑块开始 drag → 持续 setValue
        return .ignored;
    }

    fn tick(w: *Widget, delta_ms: u32) void {
        const range_ptr: *Range = @fieldParentPtr("base", w);
        const s: *Self = @fieldParentPtr("range", range_ptr);
        const delta_us: i64 = @as(i64, delta_ms) * 1000;
        switch (s.held_stepper) {
            .none => {},
            .a => {
                s.long_press_us += delta_us;
                if (s.long_press_us > 150_000) { // 每 150ms 触发
                    s.long_press_us = 0;
                    s.emitScroll(if (s.range.orientation == .horizontal) .step_backward else .step_up);
                }
            },
            .b => {
                s.long_press_us += delta_us;
                if (s.long_press_us > 150_000) {
                    s.long_press_us = 0;
                    s.emitScroll(if (s.range.orientation == .horizontal) .step_forward else .step_down);
                }
            },
        }
    }
};
