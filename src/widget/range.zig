//! Range — GTK4 GtkRange（Scale / Scrollbar 共同基类）
//!
//! Scale 和 Scrollbar 用首字段 `range: Range` 组合（@ptrCast 安全转换）。
//! 负责：
//!   - Adjustment 持有与值同步；
//!   - fill_level / show_fill_level / restrict_to_fill_level；
//!   - inverted / flippable / has_origin / slider_size_fixed；
//!   - round_digits 显示精度；
//!   - 几何：value → slider 位置；点 → value 反算。
//!

const std = @import("std");
const math = @import("../math.zig");
const widget_mod = @import("widget.zig");
const layout_mod = @import("../layout/engine.zig");
const adj_mod = @import("../model/adjustment.zig");

const Widget = widget_mod.Widget;
const PaintContext = widget_mod.PaintContext;
const Constraints = layout_mod.Constraints;
const Adjustment = adj_mod.Adjustment;
const SizeF = math.Size(f32);
const RectF = math.Rect(f32);

pub const Orientation = enum(u1) { horizontal, vertical };

/// 回调类型
const ValueChangedFn = *const fn (ud: ?*anyopaque, new_value: f64) void;
const AdjustBoundsFn = *const fn (ud: ?*anyopaque, value: f64) void;
const ChangeValueFn = *const fn (ud: ?*anyopaque, scroll_type: u4, new_value: f64) bool;

pub const Range = struct {
    base: Widget,

    orientation: Orientation = .horizontal,
    adjustment: ?*Adjustment = null,

    // 填充级别 (进度显示)
    fill_level: f64 = 0,
    show_fill_level: bool = false,
    restrict_to_fill_level: bool = false,

    // 方向与显示
    inverted: bool = false,
    flippable: bool = true,
    has_origin: bool = true,
    slider_size_fixed: bool = false,
    round_digits: i16 = -1, // -1 = 自动

    // 回调
    on_value_changed: ?ValueChangedFn = null,
    on_value_changed_ud: ?*anyopaque = null,
    on_adjust_bounds: ?AdjustBoundsFn = null,
    on_adjust_bounds_ud: ?*anyopaque = null,
    on_change_value: ?ChangeValueFn = null,
    on_change_value_ud: ?*anyopaque = null,

    const Self = @This();

    // ── 初始化 / 析构 ────────────────────────────────────────────────────

    pub fn init(self: *Self, base: Widget, orientation: Orientation, adj: ?*Adjustment) void {
        self.base = base;
        self.orientation = orientation;
        self.adjustment = adj;
    }

    pub fn destroy(self: *Self) void {
        self.adjustment = null;
        self.on_value_changed = null;
        self.on_adjust_bounds = null;
        self.on_change_value = null;
    }

    // ── Adjustment 访问 ──────────────────────────────────────────────────

    pub fn setAdjustment(self: *Self, adj: ?*Adjustment) void {
        self.adjustment = adj;
    }

    pub fn getAdjustment(self: *const Self) ?*Adjustment {
        return self.adjustment;
    }

    // ── 值与范围 ─────────────────────────────────────────────────────────

    pub fn getValue(self: *const Self) f64 {
        if (self.adjustment) |a| return a.value;
        return 0;
    }

    pub fn setValue(self: *Self, v: f64) void {
        const a = self.adjustment orelse return;
        const clamped = if (self.restrict_to_fill_level)
            @min(v, self.fill_level)
        else
            std.math.clamp(v, a.lower, a.upper);
        if (clamped != a.value) {
            a.value = clamped;
            if (a.on_value_changed) |cb| cb(a.on_value_changed_userdata, clamped);
            if (self.on_value_changed) |cb| cb(self.on_value_changed_ud, clamped);
        }
    }

    pub fn setRange(self: *Self, min: f64, max: f64) void {
        const a = self.adjustment orelse return;
        a.lower = min;
        a.upper = max;
        if (a.value < min) self.setValue(min);
        if (a.value > max) self.setValue(max);
    }

    // ── Fill Level ───────────────────────────────────────────────────────

    pub fn setFillLevel(self: *Self, level: f64) void {
        self.fill_level = level;
    }
    pub fn getFillLevel(self: *const Self) f64 { return self.fill_level; }
    pub fn setShowFillLevel(self: *Self, v: bool) void { self.show_fill_level = v; }
    pub fn setRestrictToFillLevel(self: *Self, v: bool) void { self.restrict_to_fill_level = v; }

    // ── 方向 / 显示 ──────────────────────────────────────────────────────

    pub fn setInverted(self: *Self, v: bool) void { self.inverted = v; }
    pub fn getInverted(self: *const Self) bool { return self.inverted; }
    pub fn setFlippable(self: *Self, v: bool) void { self.flippable = v; }
    pub fn setHasOrigin(self: *Self, v: bool) void { self.has_origin = v; }
    pub fn setSliderSizeFixed(self: *Self, v: bool) void { self.slider_size_fixed = v; }
    pub fn setRoundDigits(self: *Self, d: i16) void { self.round_digits = d; }
    pub fn getRoundDigits(self: *const Self) i16 { return self.round_digits; }

    // ── 回调 ─────────────────────────────────────────────────────────────

    pub fn setOnValueChanged(self: *Self, cb: ?ValueChangedFn, ud: ?*anyopaque) void {
        self.on_value_changed = cb; self.on_value_changed_ud = ud;
    }
    pub fn setOnAdjustBounds(self: *Self, cb: ?AdjustBoundsFn, ud: ?*anyopaque) void {
        self.on_adjust_bounds = cb; self.on_adjust_bounds_ud = ud;
    }
    pub fn setOnChangeValue(self: *Self, cb: ?ChangeValueFn, ud: ?*anyopaque) void {
        self.on_change_value = cb; self.on_change_value_ud = ud;
    }

    // ── 几何：value → slider 位置 ────────────────────────────────────────

    fn rangeFract(self: *const Self) f32 {
        const a = self.adjustment orelse return 0;
        const span = a.upper - a.lower;
        if (span <= 0) return 0;
        const v = (a.value - a.lower) / span;
        const frac: f32 = @floatCast(v);
        if (self.inverted) return 1.0 - frac;
        return std.math.clamp(frac, 0.0, 1.0);
    }

    /// 根据 range_rect（不含 stepper 的纯轨道矩形）算出滑块矩形
    pub fn sliderRange(self: *const Self, track_rect: RectF, page_size_px: f32) RectF {
        const f = self.rangeFract();
        const slider_px = @max(20.0, if (self.slider_size_fixed) page_size_px else @max(page_size_px, 20.0));
        return switch (self.orientation) {
            .horizontal => blk: {
                const track_inner = track_rect.width - slider_px;
                const sx = track_rect.x + if (track_inner > 0) track_inner * f else 0;
                break :blk .{ .x = sx, .y = track_rect.y, .width = slider_px, .height = track_rect.height };
            },
            .vertical => blk: {
                const track_inner = track_rect.height - slider_px;
                const sy = track_rect.y + if (track_inner > 0) track_inner * f else 0;
                break :blk .{ .x = track_rect.x, .y = sy, .width = track_rect.width, .height = slider_px };
            },
        };
    }

    /// 从点（相对 track_rect）反推值
    pub fn valueFromPoint(self: *const Self, track_rect: RectF, x: f32, y: f32) f64 {
        const a = self.adjustment orelse return 0;
        const span = a.upper - a.lower;
        if (span <= 0) return a.lower;
        const f: f32 = switch (self.orientation) {
            .horizontal => blk: {
                const w = track_rect.width;
                const p = if (w <= 0) 0.0 else (x - track_rect.x) / w;
                break :blk std.math.clamp(p, 0.0, 1.0);
            },
            .vertical => blk: {
                const h = track_rect.height;
                const p = if (h <= 0) 0.0 else (y - track_rect.y) / h;
                break :blk std.math.clamp(p, 0.0, 1.0);
            },
        };
        const frac = if (self.inverted) (1.0 - f) else f;
        return a.lower + @as(f64, @floatFromInt(0)) + @as(f64, @floatCast(frac)) * span;
    }

    // ── 便捷：round 显示值 ───────────────────────────────────────────────

    pub fn roundValue(self: *const Self, v: f64) f64 {
        if (self.round_digits < 0) return v;
        const d = std.math.pow(f64, 10.0, @floatFromInt(self.round_digits));
        return @round(v * d) / d;
    }

    // ── 默认 VTable helper（子类 override） ────────────────────────────────

    /// 默认最小测量（子类可覆盖）
    pub fn defaultMeasure(self: *const Self, c: Constraints) SizeF {
        const base: SizeF = switch (self.orientation) {
            .horizontal => .{ .width = 120.0, .height = 22.0 },
            .vertical   => .{ .width = 22.0,  .height = 120.0 },
        };
        return c.constrain(base);
    }
};
