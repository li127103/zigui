//! Adjustment — 值调整对象 (对标 GtkAdjustment)
//!
//! 用于 Slider / Scale / ScrollBar / SpinButton 等控件共享的可变值模型，
//! 带有 lower/upper 边界、step/page 步长以及 value-changed / changed 信号。
//!
//! 典型用法:
//! ```
//! var adj = try Adjustment.create(alloc, .{
//!     .lower = 0, .upper = 100, .value = 50,
//!     .step_increment = 1, .page_increment = 10, .page_size = 0,
//! });
//! defer adj.destroy(alloc);
//! adj.on_value_changed = &onAdjChanged;
//! adj.setValue(75); // 自动 clamp 并触发 value-changed
//! ```

const std = @import("std");
const Allocator = std.mem.Allocator;

pub const Adjustment = struct {
    // ── 值与范围 ───────────────────────────────────────────────────────────
    value: f32 = 0,
    lower: f32 = 0,
    upper: f32 = 100,
    step_increment: f32 = 1,
    page_increment: f32 = 10,
    page_size: f32 = 0,

    // ── 信号回调 ───────────────────────────────────────────────────────────
    /// 值发生改变（setValue、configure 等）
    on_value_changed: ?*const fn (self: *Adjustment) void = null,
    /// 属性批量改变（configure、setBounds 等）
    on_changed: ?*const fn (self: *Adjustment) void = null,

    const Self = @This();

    /// 创建 Adjustment。value 会被自动 clamp 到 [lower, upper-page_size]。
    pub fn create(allocator: Allocator, opts: struct {
        lower: f32 = 0,
        upper: f32 = 100,
        value: f32 = 0,
        step_increment: f32 = 1,
        page_increment: f32 = 10,
        page_size: f32 = 0,
        on_value_changed: ?*const fn (self: *Adjustment) void = null,
        on_changed: ?*const fn (self: *Adjustment) void = null,
    }) !*Self {
        const self = try allocator.create(Self);
        const clamped_val = clampValue(opts.value, opts.lower, opts.upper, opts.page_size);
        self.* = .{
            .value = clamped_val,
            .lower = opts.lower,
            .upper = opts.upper,
            .step_increment = opts.step_increment,
            .page_increment = opts.page_increment,
            .page_size = opts.page_size,
            .on_value_changed = opts.on_value_changed,
            .on_changed = opts.on_changed,
        };
        return self;
    }

    pub fn destroy(self: *Self, allocator: Allocator) void {
        allocator.destroy(self);
    }

    // ── 辅助 ───────────────────────────────────────────────────────────────
    inline fn clampValue(v: f32, lo: f32, hi: f32, page_sz: f32) f32 {
        const upper_limit = hi - page_sz;
        const eff_lo = if (lo < upper_limit) lo else upper_limit;
        const eff_hi = upper_limit;
        return std.math.clamp(v, eff_lo, eff_hi);
    }

    inline fn emitValueChanged(self: *Self) void {
        if (self.on_value_changed) |cb| cb(self);
    }

    inline fn emitChanged(self: *Self) void {
        if (self.on_changed) |cb| cb(self);
    }

    // ── Getter / Setter ────────────────────────────────────────────────────
    pub fn getValue(self: *const Self) f32 {
        return self.value;
    }

    /// 设置值，自动 clamp 到有效范围，触发 value-changed
    pub fn setValue(self: *Self, v: f32) void {
        const clamped = clampValue(v, self.lower, self.upper, self.page_size);
        if (clamped != self.value) {
            self.value = clamped;
            self.emitValueChanged();
        }
    }

    pub fn getLower(self: *const Self) f32 {
        return self.lower;
    }

    pub fn getUpper(self: *const Self) f32 {
        return self.upper;
    }

    pub fn getStepIncrement(self: *const Self) f32 {
        return self.step_increment;
    }

    pub fn getPageIncrement(self: *const Self) f32 {
        return self.page_increment;
    }

    pub fn getPageSize(self: *const Self) f32 {
        return self.page_size;
    }

    /// 设置范围 (lower → upper)，触发 changed；若 value 越界则同时触发 value-changed
    pub fn setBounds(self: *Self, lower: f32, upper: f32, page_size: f32) void {
        const old_lower = self.lower;
        const old_upper = self.upper;
        const old_page = self.page_size;
        const old_value = self.value;
        self.lower = lower;
        self.upper = upper;
        self.page_size = page_size;
        // 重新 clamp value
        self.value = clampValue(self.value, lower, upper, page_size);
        // 按顺序发信号: changed 然后 value-changed (若值变)
        if (old_lower != lower or old_upper != upper or old_page != page_size) {
            self.emitChanged();
        }
        if (old_value != self.value) {
            self.emitValueChanged();
        }
    }

    /// 批量配置所有参数，触发 changed + 必要的 value-changed
    pub fn configure(self: *Self, opts: struct {
        lower: ?f32 = null,
        upper: ?f32 = null,
        value: ?f32 = null,
        step_increment: ?f32 = null,
        page_increment: ?f32 = null,
        page_size: ?f32 = null,
    }) void {
        const lo = opts.lower orelse self.lower;
        const hi = opts.upper orelse self.upper;
        const ps = opts.page_size orelse self.page_size;
        const new_step = opts.step_increment orelse self.step_increment;
        const new_page_inc = opts.page_increment orelse self.page_increment;
        const desired_value = opts.value orelse self.value;

        const any_prop_changed = (self.lower != lo) or
            (self.upper != hi) or
            (self.page_size != ps) or
            (self.step_increment != new_step) or
            (self.page_increment != new_page_inc);

        self.lower = lo;
        self.upper = hi;
        self.page_size = ps;
        self.step_increment = new_step;
        self.page_increment = new_page_inc;

        const clamped = clampValue(desired_value, lo, hi, ps);
        const value_changed = clamped != self.value;
        self.value = clamped;

        if (any_prop_changed) self.emitChanged();
        if (value_changed) self.emitValueChanged();
    }

    /// 滚动条专用: 把当前 value 夹取到 [clamp_lower, clamp_upper - page_size]，
    /// 用于外部约束可见范围。
    pub fn clampPage(self: *Self, clamp_lower: f32, clamp_upper: f32) void {
        const lo = @max(self.lower, clamp_lower);
        const hi = @min(self.upper, clamp_upper);
        const clamped = clampValue(self.value, lo, hi, self.page_size);
        if (clamped != self.value) {
            self.value = clamped;
            self.emitValueChanged();
        }
    }

    // ── 步进快捷方法 ───────────────────────────────────────────────────────

    /// 加 step_increment × n_steps（n_steps 为正则加，负则减）
    pub fn step(self: *Self, n_steps: i32) void {
        self.setValue(self.value + self.step_increment * @as(f32, @floatFromInt(n_steps)));
    }

    /// 加 page_increment × n_pages
    pub fn page(self: *Self, n_pages: i32) void {
        self.setValue(self.value + self.page_increment * @as(f32, @floatFromInt(n_pages)));
    }

    /// 重置为 lower（最小值）
    pub fn resetMinimum(self: *Self) void {
        self.setValue(self.lower);
    }

    /// 重置为 upper - page_size（最大值）
    pub fn resetMaximum(self: *Self) void {
        self.setValue(self.upper - self.page_size);
    }
};

// ── Tests ──────────────────────────────────────────────────────────────────

test "Adjustment: create + setValue clamp + step/page/reset" {
    const alloc = std.testing.allocator;

    const adj = try Adjustment.create(alloc, .{
        .lower = 0,
        .upper = 100,
        .value = 50,
        .step_increment = 1,
        .page_increment = 10,
        .page_size = 0,
    });
    defer adj.destroy(alloc);

    try std.testing.expectEqual(@as(f32, 50), adj.getValue());

    // setValue 越界应 clamp
    adj.setValue(200);
    try std.testing.expectEqual(@as(f32, 100), adj.getValue());
    adj.setValue(-10);
    try std.testing.expectEqual(@as(f32, 0), adj.getValue());

    // step
    adj.setValue(50);
    adj.step(3);
    try std.testing.expectEqual(@as(f32, 53), adj.getValue());
    adj.step(-1);
    try std.testing.expectEqual(@as(f32, 52), adj.getValue());

    // page
    adj.page(2);
    try std.testing.expectEqual(@as(f32, 72), adj.getValue());

    // reset min/max
    adj.resetMinimum();
    try std.testing.expectEqual(@as(f32, 0), adj.getValue());
    adj.resetMaximum();
    try std.testing.expectEqual(@as(f32, 100), adj.getValue());

    // setBounds 改变范围使 value 越界
    adj.setValue(50);
    adj.setBounds(60, 80, 0);
    try std.testing.expectEqual(@as(f32, 60), adj.getValue()); // 被 clamp
}

test "Adjustment: page_size clamping" {
    const alloc = std.testing.allocator;
    const adj = try Adjustment.create(alloc, .{
        .lower = 0,
        .upper = 100,
        .value = 90,
        .page_size = 20, // upper - page_size = 80
    });
    defer adj.destroy(alloc);
    // value = 90 应该被 clamp 到 80
    try std.testing.expectEqual(@as(f32, 80), adj.getValue());
}

test "Adjustment: configure batch" {
    const alloc = std.testing.allocator;
    const adj = try Adjustment.create(alloc, .{ .value = 50 });
    defer adj.destroy(alloc);
    adj.configure(.{ .lower = 10, .upper = 20, .value = 15 });
    try std.testing.expectEqual(@as(f32, 10), adj.getLower());
    try std.testing.expectEqual(@as(f32, 20), adj.getUpper());
    try std.testing.expectEqual(@as(f32, 15), adj.getValue());
}
