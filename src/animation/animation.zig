//! 动画系统 - 缓动函数、动画控制器、属性动画
//!
//! 提供完整的动画系统，支持多种缓动函数，可用于 Widget 属性动画。
//!
//! 使用方法:
//! ```
//! var anim = try FloatAnimation.create(allocator, .{
//!     .from = 0,
//!     .to = 100,
//!     .duration = 0.5,
//!     .easing = .ease_in_out_cubic,
//!     .on_update = onAnimUpdate,
//! });
//! animation_controller.add(anim);
//! ```

const std = @import("std");
const math = @import("../math.zig");

// 简化的预设 Easing（供内部 FloatAnimation/ColorAnimation 使用，向后兼容）
pub const EasingPreset = enum {
    linear,
    ease_in_sine,
    ease_out_sine,
    ease_in_out_sine,
    ease_in_quad,
    ease_out_quad,
    ease_in_out_quad,
    ease_in_cubic,
    ease_out_cubic,
    ease_in_out_cubic,
    ease_in_quart,
    ease_out_quart,
    ease_in_out_quart,
    ease_in_quint,
    ease_out_quint,
    ease_in_out_quint,
    ease_in_expo,
    ease_out_expo,
    ease_in_out_expo,
    ease_in_circ,
    ease_out_circ,
    ease_in_out_circ,
    ease_in_back,
    ease_out_back,
    ease_in_out_back,
    ease_in_elastic,
    ease_out_elastic,
    ease_in_out_elastic,
    ease_in_bounce,
    ease_out_bounce,
    ease_in_out_bounce,
};

pub const easing = struct {
    pub fn linear(t: f32) f32 {
        return t;
    }

    pub fn easeInSine(t: f32) f32 {
        return 1.0 - @cos(t * std.math.pi / 2.0);
    }

    pub fn easeOutSine(t: f32) f32 {
        return @sin(t * std.math.pi / 2.0);
    }

    pub fn easeInOutSine(t: f32) f32 {
        return -(@cos(std.math.pi * t) - 1.0) / 2.0;
    }

    pub fn easeInQuad(t: f32) f32 {
        return t * t;
    }

    pub fn easeOutQuad(t: f32) f32 {
        return 1.0 - (1.0 - t) * (1.0 - t);
    }

    pub fn easeInOutQuad(t: f32) f32 {
        return if (t < 0.5) 2.0 * t * t else 1.0 - std.math.pow(f32, -2.0 * t + 2.0, 2.0) / 2.0;
    }

    pub fn easeInCubic(t: f32) f32 {
        return t * t * t;
    }

    pub fn easeOutCubic(t: f32) f32 {
        return 1.0 - std.math.pow(f32, 1.0 - t, 3.0);
    }

    pub fn easeInOutCubic(t: f32) f32 {
        return if (t < 0.5) 4.0 * t * t * t else 1.0 - std.math.pow(f32, -2.0 * t + 2.0, 3.0) / 2.0;
    }

    pub fn easeInQuart(t: f32) f32 {
        return t * t * t * t;
    }

    pub fn easeOutQuart(t: f32) f32 {
        return 1.0 - std.math.pow(f32, 1.0 - t, 4.0);
    }

    pub fn easeInOutQuart(t: f32) f32 {
        return if (t < 0.5) 8.0 * t * t * t * t else 1.0 - std.math.pow(f32, -2.0 * t + 2.0, 4.0) / 2.0;
    }

    pub fn easeInQuint(t: f32) f32 {
        return t * t * t * t * t;
    }

    pub fn easeOutQuint(t: f32) f32 {
        return 1.0 - std.math.pow(f32, 1.0 - t, 5.0);
    }

    pub fn easeInOutQuint(t: f32) f32 {
        return if (t < 0.5) 16.0 * t * t * t * t * t else 1.0 - std.math.pow(f32, -2.0 * t + 2.0, 5.0) / 2.0;
    }

    pub fn easeInExpo(t: f32) f32 {
        return if (t == 0) 0 else std.math.pow(f32, 2.0, 10.0 * t - 10.0);
    }

    pub fn easeOutExpo(t: f32) f32 {
        return if (t == 1) 1 else 1.0 - std.math.pow(f32, 2.0, -10.0 * t);
    }

    pub fn easeInOutExpo(t: f32) f32 {
        if (t == 0) return 0;
        if (t == 1) return 1;
        return if (t < 0.5)
            std.math.pow(f32, 2.0, 20.0 * t - 10.0) / 2.0
        else
            (2.0 - std.math.pow(f32, 2.0, -20.0 * t + 10.0)) / 2.0;
    }

    pub fn easeInCirc(t: f32) f32 {
        return 1.0 - @sqrt(1.0 - t * t);
    }

    pub fn easeOutCirc(t: f32) f32 {
        return @sqrt(1.0 - std.math.pow(f32, t - 1.0, 2.0));
    }

    pub fn easeInOutCirc(t: f32) f32 {
        return if (t < 0.5)
            (1.0 - @sqrt(1.0 - std.math.pow(f32, 2.0 * t, 2.0))) / 2.0
        else
            (@sqrt(1.0 - std.math.pow(f32, -2.0 * t + 2.0, 2.0)) + 1.0) / 2.0;
    }

    pub fn easeInBack(t: f32) f32 {
        const c1: f32 = 1.70158;
        const c3: f32 = c1 + 1.0;
        return c3 * t * t * t - c1 * t * t;
    }

    pub fn easeOutBack(t: f32) f32 {
        const c1: f32 = 1.70158;
        const c3: f32 = c1 + 1.0;
        return 1.0 + c3 * std.math.pow(f32, t - 1.0, 3.0) + c1 * std.math.pow(f32, t - 1.0, 2.0);
    }

    pub fn easeInOutBack(t: f32) f32 {
        const c1: f32 = 1.70158;
        const c2: f32 = c1 * 1.525;
        return if (t < 0.5)
            (std.math.pow(f32, 2.0 * t, 2.0) * ((c2 + 1.0) * 2.0 * t - c2)) / 2.0
        else
            (std.math.pow(f32, 2.0 * t - 2.0, 2.0) * ((c2 + 1.0) * (t * 2.0 - 2.0) + c2) + 2.0) / 2.0;
    }

    pub fn easeInElastic(t: f32) f32 {
        const c4: f32 = (2.0 * std.math.pi) / 3.0;
        if (t == 0) return 0;
        if (t == 1) return 1;
        return -std.math.pow(f32, 2.0, 10.0 * t - 10.0) * @sin((t * 10.0 - 10.75) * c4);
    }

    pub fn easeOutElastic(t: f32) f32 {
        const c4: f32 = (2.0 * std.math.pi) / 3.0;
        if (t == 0) return 0;
        if (t == 1) return 1;
        return std.math.pow(f32, 2.0, -10.0 * t) * @sin((t * 10.0 - 0.75) * c4) + 1.0;
    }

    pub fn easeInOutElastic(t: f32) f32 {
        const c5: f32 = (2.0 * std.math.pi) / 4.5;
        if (t == 0) return 0;
        if (t == 1) return 1;
        return if (t < 0.5)
            -(std.math.pow(f32, 2.0, 20.0 * t - 10.0) * @sin((20.0 * t - 11.125) * c5)) / 2.0
        else
            (std.math.pow(f32, 2.0, -20.0 * t + 10.0) * @sin((20.0 * t - 11.125) * c5)) / 2.0 + 1.0;
    }

    pub fn easeInBounce(t: f32) f32 {
        return 1.0 - easeOutBounce(1.0 - t);
    }

    pub fn easeOutBounce(t: f32) f32 {
        const n1: f32 = 7.5625;
        const d1: f32 = 2.75;
        const nt = t;
        if (nt < 1.0 / d1) {
            return n1 * nt * nt;
        } else if (nt < 2.0 / d1) {
            const x = nt - 1.5 / d1;
            return n1 * x * x + 0.75;
        } else if (nt < 2.5 / d1) {
            const x = nt - 2.25 / d1;
            return n1 * x * x + 0.9375;
        } else {
            const x = nt - 2.625 / d1;
            return n1 * x * x + 0.984375;
        }
    }

    pub fn easeInOutBounce(t: f32) f32 {
        return if (t < 0.5)
            (1.0 - easeOutBounce(1.0 - 2.0 * t)) / 2.0
        else
            (1.0 + easeOutBounce(2.0 * t - 1.0)) / 2.0;
    }

    pub fn apply(easing_type: EasingPreset, t: f32) f32 {
        return switch (easing_type) {
            .linear => linear(t),
            .ease_in_sine => easeInSine(t),
            .ease_out_sine => easeOutSine(t),
            .ease_in_out_sine => easeInOutSine(t),
            .ease_in_quad => easeInQuad(t),
            .ease_out_quad => easeOutQuad(t),
            .ease_in_out_quad => easeInOutQuad(t),
            .ease_in_cubic => easeInCubic(t),
            .ease_out_cubic => easeOutCubic(t),
            .ease_in_out_cubic => easeInOutCubic(t),
            .ease_in_quart => easeInQuart(t),
            .ease_out_quart => easeOutQuart(t),
            .ease_in_out_quart => easeInOutQuart(t),
            .ease_in_quint => easeInQuint(t),
            .ease_out_quint => easeOutQuint(t),
            .ease_in_out_quint => easeInOutQuint(t),
            .ease_in_expo => easeInExpo(t),
            .ease_out_expo => easeOutExpo(t),
            .ease_in_out_expo => easeInOutExpo(t),
            .ease_in_circ => easeInCirc(t),
            .ease_out_circ => easeOutCirc(t),
            .ease_in_out_circ => easeInOutCirc(t),
            .ease_in_back => easeInBack(t),
            .ease_out_back => easeOutBack(t),
            .ease_in_out_back => easeInOutBack(t),
            .ease_in_elastic => easeInElastic(t),
            .ease_out_elastic => easeOutElastic(t),
            .ease_in_out_elastic => easeInOutElastic(t),
            .ease_in_bounce => easeInBounce(t),
            .ease_out_bounce => easeOutBounce(t),
            .ease_in_out_bounce => easeInOutBounce(t),
        };
    }
};

// ── 富 Easing 描述 (Tagged Union + 参数化曲线) ─────────────────────────────

pub const CurveKind = enum {
    sine,
    quad,
    cubic,
    quart,
    quint,
    expo,
    circ,
    back,
    elastic,
    bounce,
};

pub const Easing = union(enum) {
    pub const SpringConfig = struct {
        stiffness: f32 = 170,
        damping: f32 = 26,
        mass: f32 = 1,
    };

    pub const CubicBezierConfig = struct {
        x1: f32,
        y1: f32,
        x2: f32,
        y2: f32,
    };

    pub const StepsConfig = struct {
        count: u32,
        jump_start: bool = false,
    };

    linear: void,
    ease_in: CurveKind,
    ease_out: CurveKind,
    ease_in_out: CurveKind,
    cubic_bezier: CubicBezierConfig,
    steps: StepsConfig,
    spring: SpringConfig,
    preset: EasingPreset,

    pub fn evaluate(self: Easing, t: f32) f32 {
        const e = easing;
        return switch (self) {
            .linear => e.linear(t),
            .ease_in => |k| switch (k) {
                .sine => e.easeInSine(t),
                .quad => e.easeInQuad(t),
                .cubic => e.easeInCubic(t),
                .quart => e.easeInQuart(t),
                .quint => e.easeInQuint(t),
                .expo => e.easeInExpo(t),
                .circ => e.easeInCirc(t),
                .back => e.easeInBack(t),
                .elastic => e.easeInElastic(t),
                .bounce => e.easeInBounce(t),
            },
            .ease_out => |k| switch (k) {
                .sine => e.easeOutSine(t),
                .quad => e.easeOutQuad(t),
                .cubic => e.easeOutCubic(t),
                .quart => e.easeOutQuart(t),
                .quint => e.easeOutQuint(t),
                .expo => e.easeOutExpo(t),
                .circ => e.easeOutCirc(t),
                .back => e.easeOutBack(t),
                .elastic => e.easeOutElastic(t),
                .bounce => e.easeOutBounce(t),
            },
            .ease_in_out => |k| switch (k) {
                .sine => e.easeInOutSine(t),
                .quad => e.easeInOutQuad(t),
                .cubic => e.easeInOutCubic(t),
                .quart => e.easeInOutQuart(t),
                .quint => e.easeInOutQuint(t),
                .expo => e.easeInOutExpo(t),
                .circ => e.easeInOutCirc(t),
                .back => e.easeInOutBack(t),
                .elastic => e.easeInOutElastic(t),
                .bounce => e.easeInOutBounce(t),
            },
            .cubic_bezier => |cfg| evaluateCubicBezier(cfg, t),
            .steps => |cfg| {
                const n: f32 = @floatFromInt(cfg.count);
                if (cfg.jump_start) {
                    return @min(@floor(t * (n + 1)) / n, 1);
                } else {
                    return @floor(t * n) / n;
                }
            },
            .spring => |cfg| evaluateSpring(cfg, t),
            .preset => |p| e.apply(p, t),
        };
    }

    fn evaluateCubicBezier(cfg: CubicBezierConfig, t: f32) f32 {
        // 简易近似: 对 x 做 Newton 法求 t, 然后返回 y
        const cx = 3.0 * cfg.x1;
        const bx = 3.0 * (cfg.x2 - cfg.x1) - cx;
        const ax = 1.0 - cx - bx;
        const cy = 3.0 * cfg.y1;
        const by = 3.0 * (cfg.y2 - cfg.y1) - cy;
        const ay = 1.0 - cy - by;

        var guess: f32 = t;
        for (0..8) |_| {
            const x = ((ax * guess + bx) * guess + cx) * guess;
            const dx = (3.0 * ax * guess + 2.0 * bx) * guess + cx;
            if (@abs(dx) < 1e-6) break;
            guess = guess - (x - t) / dx;
        }
        return ((ay * guess + by) * guess + cy) * guess;
    }

    fn evaluateSpring(cfg: SpringConfig, t: f32) f32 {
        // 基于二阶弹簧微分方程的闭式解 (临界/欠阻尼近似)
        const zeta = cfg.damping / (2.0 * @sqrt(cfg.stiffness * cfg.mass));
        const omega_n = @sqrt(cfg.stiffness / cfg.mass);
        const time = t * 2.0; // 归一化到 2 秒"观感"
        if (zeta < 1.0) {
            const omega_d = omega_n * @sqrt(1.0 - zeta * zeta);
            const envelope = @exp(-zeta * omega_n * time);
            return 1.0 - envelope * (@cos(omega_d * time) + (zeta * omega_n / @max(omega_d, 1e-6)) * @sin(omega_d * time));
        } else {
            // 临界/过阻尼
            const r1 = -omega_n * (zeta + @sqrt(zeta * zeta - 1.0));
            const r2 = -omega_n * (zeta - @sqrt(zeta * zeta - 1.0));
            const denom = r2 - r1;
            if (@abs(denom) < 1e-6) return 1.0 - (1.0 + omega_n * time) * @exp(-omega_n * time);
            return 1.0 - (r2 * @exp(r1 * time) - r1 * @exp(r2 * time)) / denom;
        }
    }
};

// ── Tween (简单补间, 面向 demo 使用) ────────────────────────────────────────

pub const Tween = struct {
    from: f32 = 0,
    to: f32 = 100,
    duration_ms: u32 = 1000,
    easing: Easing = .{ .linear = {} },

    state: AnimationState = .idle,
    elapsed_ms: u32 = 0,

    pub fn start(self: *Tween) void {
        self.state = .running;
        self.elapsed_ms = 0;
    }

    pub fn reset(self: *Tween) void {
        self.state = .idle;
        self.elapsed_ms = 0;
    }

    pub fn update(self: *Tween, delta_ms: u32) bool {
        if (self.state != .running) return false;
        self.elapsed_ms += delta_ms;
        if (self.elapsed_ms >= self.duration_ms) {
            self.elapsed_ms = self.duration_ms;
            self.state = .completed;
            return false;
        }
        return true;
    }

    pub fn progress(self: *const Tween) f32 {
        if (self.duration_ms == 0) return 1;
        return std.math.clamp(@as(f32, @floatFromInt(self.elapsed_ms)) / @as(f32, @floatFromInt(self.duration_ms)), 0, 1);
    }

    pub fn currentValue(self: *const Tween) f32 {
        const p = self.progress();
        const eased = self.easing.evaluate(p);
        return self.from + (self.to - self.from) * eased;
    }
};

pub const AnimationState = enum {
    idle,
    running,
    paused,
    completed,
};

pub const AnimationDirection = enum {
    normal,
    reverse,
    alternate,
    alternate_reverse,
};

pub const FloatAnimation = struct {
    from: f32,
    to: f32,
    duration: f32,
    current_time: f32 = 0,
    easing_type: EasingPreset = .ease_out_cubic,
    direction: AnimationDirection = .normal,
    iterations: i32 = 1,
    current_iteration: i32 = 0,
    state: AnimationState = .idle,
    delay: f32 = 0,
    delay_remaining: f32 = 0,
    auto_reverse: bool = false,

    value: f32 = 0,
    progress: f32 = 0,

    on_start: ?*const fn (anim: *FloatAnimation) void = null,
    on_update: ?*const fn (anim: *FloatAnimation, value: f32) void = null,
    on_complete: ?*const fn (anim: *FloatAnimation) void = null,

    user_data: ?*anyopaque = null,

    const Self = @This();

    pub fn create(allocator: std.mem.Allocator, opts: struct {
        from: f32,
        to: f32,
        duration: f32,
        easing: EasingPreset = .ease_out_cubic,
        direction: AnimationDirection = .normal,
        iterations: i32 = 1,
        delay: f32 = 0,
        auto_reverse: bool = false,
        on_start: ?*const fn (anim: *FloatAnimation) void = null,
        on_update: ?*const fn (anim: *FloatAnimation, value: f32) void = null,
        on_complete: ?*const fn (anim: *FloatAnimation) void = null,
        user_data: ?*anyopaque = null,
    }) !*FloatAnimation {
        const self = try allocator.create(FloatAnimation);
        self.* = .{
            .from = opts.from,
            .to = opts.to,
            .duration = opts.duration,
            .easing_type = opts.easing,
            .direction = opts.direction,
            .iterations = opts.iterations,
            .delay = opts.delay,
            .delay_remaining = opts.delay,
            .auto_reverse = opts.auto_reverse,
            .value = opts.from,
            .on_start = opts.on_start,
            .on_update = opts.on_update,
            .on_complete = opts.on_complete,
            .user_data = opts.user_data,
        };
        return self;
    }

    pub fn destroy(self: *Self, allocator: std.mem.Allocator) void {
        allocator.destroy(self);
    }

    pub fn start(self: *Self) void {
        self.state = .running;
        self.current_time = 0;
        self.current_iteration = 0;
        self.delay_remaining = self.delay;
        self.progress = 0;
        self.value = self.from;
        if (self.on_start) |cb| cb(self);
    }

    pub fn stop(self: *Self) void {
        self.state = .idle;
        self.current_time = 0;
        self.progress = 0;
    }

    pub fn pause(self: *Self) void {
        if (self.state == .running) {
            self.state = .paused;
        }
    }

    pub fn resumeAnim(self: *Self) void {
        if (self.state == .paused) {
            self.state = .running;
        }
    }

    pub fn restart(self: *Self) void {
        self.start();
    }

    pub fn update(self: *Self, delta_time: f32) bool {
        if (self.state != .running) return false;

        if (self.delay_remaining > 0) {
            self.delay_remaining -= delta_time;
            if (self.delay_remaining > 0) return true;
            delta_time = -self.delay_remaining;
            self.delay_remaining = 0;
        }

        self.current_time += delta_time;

        if (self.duration <= 0) {
            self.progress = 1;
        } else {
            self.progress = std.math.clamp(self.current_time / self.duration, 0, 1);
        }

        var t = self.progress;
        if (self.auto_reverse) {
            if (self.current_iteration % 2 == 1) {
                t = 1.0 - t;
            }
        }

        const eased = easing.apply(self.easing_type, t);
        self.value = self.from + (self.to - self.from) * eased;

        if (self.on_update) |cb| cb(self, self.value);

        if (self.progress >= 1.0) {
            self.current_iteration += 1;
            if (self.iterations < 0 or self.current_iteration < self.iterations) {
                self.current_time = 0;
                self.progress = 0;
                if (self.auto_reverse) {
                    const temp = self.from;
                    self.from = self.to;
                    self.to = temp;
                }
            } else {
                self.state = .completed;
                if (self.on_complete) |cb| cb(self);
                return false;
            }
        }

        return true;
    }
};

pub const AnimationController = struct {
    allocator: std.mem.Allocator,
    animations: std.ArrayListUnmanaged(*FloatAnimation) = .{ .items = &.{}, .capacity = 0 },
    time_scale: f32 = 1.0,
    is_running: bool = true,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator) Self {
        return .{
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *Self) void {
        for (self.animations.items) |anim| {
            anim.destroy(self.allocator);
        }
        self.animations.deinit(self.allocator);
    }

    pub fn add(self: *Self, anim: *FloatAnimation) !void {
        try self.animations.append(self.allocator, anim);
        anim.start();
    }

    pub fn remove(self: *Self, anim: *FloatAnimation) void {
        for (self.animations.items, 0..) |a, i| {
            if (a == anim) {
                _ = self.animations.orderedRemove(i);
                break;
            }
        }
    }

    pub fn update(self: *Self, delta_time: f32) void {
        if (!self.is_running) return;

        const dt = delta_time * self.time_scale;
        var i: usize = 0;
        while (i < self.animations.items.len) {
            const anim = self.animations.items[i];
            const alive = anim.update(dt);
            if (!alive and anim.state == .completed) {
                _ = self.animations.orderedRemove(i);
            } else {
                i += 1;
            }
        }
    }

    pub fn pauseAll(self: *Self) void {
        self.is_running = false;
    }

    pub fn resumeAll(self: *Self) void {
        self.is_running = true;
    }

    pub fn setTimeScale(self: *Self, scale: f32) void {
        self.time_scale = scale;
    }

    pub fn clear(self: *Self) void {
        for (self.animations.items) |anim| {
            anim.destroy(self.allocator);
        }
        self.animations.clearRetainingCapacity();
    }

    pub fn count(self: *const Self) usize {
        return self.animations.items.len;
    }
};

pub const ColorAnimation = struct {
    from: math.Color,
    to: math.Color,
    duration: f32,
    current_time: f32 = 0,
    easing_type: EasingPreset = .ease_out_cubic,
    state: AnimationState = .idle,
    delay: f32 = 0,
    delay_remaining: f32 = 0,

    value: math.Color = math.Color.transparent,
    progress: f32 = 0,

    on_start: ?*const fn (anim: *ColorAnimation) void = null,
    on_update: ?*const fn (anim: *ColorAnimation, value: math.Color) void = null,
    on_complete: ?*const fn (anim: *ColorAnimation) void = null,

    user_data: ?*anyopaque = null,

    const Self = @This();

    pub fn create(allocator: std.mem.Allocator, opts: struct {
        from: math.Color,
        to: math.Color,
        duration: f32,
        easing: EasingPreset = .ease_out_cubic,
        delay: f32 = 0,
        on_start: ?*const fn (anim: *ColorAnimation) void = null,
        on_update: ?*const fn (anim: *ColorAnimation, value: math.Color) void = null,
        on_complete: ?*const fn (anim: *ColorAnimation) void = null,
        user_data: ?*anyopaque = null,
    }) !*ColorAnimation {
        const self = try allocator.create(ColorAnimation);
        self.* = .{
            .from = opts.from,
            .to = opts.to,
            .duration = opts.duration,
            .easing_type = opts.easing,
            .delay = opts.delay,
            .delay_remaining = opts.delay,
            .value = opts.from,
            .on_start = opts.on_start,
            .on_update = opts.on_update,
            .on_complete = opts.on_complete,
            .user_data = opts.user_data,
        };
        return self;
    }

    pub fn destroy(self: *Self, allocator: std.mem.Allocator) void {
        allocator.destroy(self);
    }

    pub fn start(self: *Self) void {
        self.state = .running;
        self.current_time = 0;
        self.delay_remaining = self.delay;
        self.progress = 0;
        self.value = self.from;
        if (self.on_start) |cb| cb(self);
    }

    pub fn stop(self: *Self) void {
        self.state = .idle;
        self.current_time = 0;
        self.progress = 0;
    }

    pub fn update(self: *Self, delta_time: f32) bool {
        if (self.state != .running) return false;

        if (self.delay_remaining > 0) {
            self.delay_remaining -= delta_time;
            if (self.delay_remaining > 0) return true;
            delta_time = -self.delay_remaining;
            self.delay_remaining = 0;
        }

        self.current_time += delta_time;

        if (self.duration <= 0) {
            self.progress = 1;
        } else {
            self.progress = std.math.clamp(self.current_time / self.duration, 0, 1);
        }

        const eased = easing.apply(self.easing_type, self.progress);

        self.value = math.Color{
            .r = self.from.r + (self.to.r - self.from.r) * eased,
            .g = self.from.g + (self.to.g - self.from.g) * eased,
            .b = self.from.b + (self.to.b - self.from.b) * eased,
            .a = self.from.a + (self.to.a - self.from.a) * eased,
        };

        if (self.on_update) |cb| cb(self, self.value);

        if (self.progress >= 1.0) {
            self.state = .completed;
            if (self.on_complete) |cb| cb(self);
            return false;
        }

        return true;
    }
};
