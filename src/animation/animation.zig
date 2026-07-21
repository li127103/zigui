//! 动画系统 - Easing + Spring + Tween + AnimationController

const std = @import("std");
const math = @import("../math.zig");

pub const AnimationId = u64;

var next_anim_id: AnimationId = 1;

pub fn genAnimId() AnimationId {
    const id = next_anim_id;
    next_anim_id += 1;
    return id;
}

pub const AnimState = enum { idle, running, paused, completed };
pub const RepeatMode = enum { none, restart, reverse, ping_pong };

// ── Easing ──────────────────────────────────────────────────────────────────

pub const Easing = union(enum) {
    linear: void,
    ease_in: EaseCurve,
    ease_out: EaseCurve,
    ease_in_out: EaseCurve,
    cubic_bezier: struct { x1: f32, y1: f32, x2: f32, y2: f32 },
    spring: SpringConfig,
    steps: struct { count: u32, jump_start: bool },

    pub const EaseCurve = enum {
        quad, cubic, quart, quint,
        sine, expo, circ,
        back, elastic, bounce,
    };

    pub const SpringConfig = struct {
        stiffness: f32 = 170,
        damping: f32 = 26,
        mass: f32 = 1,
        velocity: f32 = 0,
    };

    pub fn evaluate(self: Easing, t: f32) f32 {
        const tc = std.math.clamp(t, 0.0, 1.0);
        return switch (self) {
            .linear => tc,
            .ease_in => |curve| easeIn(curve, tc),
            .ease_out => |curve| easeOut(curve, tc),
            .ease_in_out => |curve| easeInOut(curve, tc),
            .cubic_bezier => |bz| cubicBezier(bz.x1, bz.y1, bz.x2, bz.y2, tc),
            .spring => |sp| springEvaluate(sp, tc),
            .steps => |s| stepsEvaluate(s.count, s.jump_start, tc),
        };
    }

    fn easeIn(curve: EaseCurve, t: f32) f32 {
        return switch (curve) {
            .quad => t * t,
            .cubic => t * t * t,
            .quart => t * t * t * t,
            .quint => t * t * t * t * t,
            .sine => 1.0 - @cos(t * std.math.pi / 2.0),
            .expo => if (t <= 0) 0 else std.math.pow(f32, 2.0, 10.0 * (t - 1.0)),
            .circ => 1.0 - @sqrt(@max(0, 1.0 - t * t)),
            .back => {
                const c1: f32 = 1.70158;
                const c3 = c1 + 1.0;
                return c3 * t * t * t - c1 * t * t;
            },
            .elastic => {
                if (t <= 0) return 0;
                if (t >= 1) return 1;
                const c4 = (2.0 * std.math.pi) / 3.0;
                return -std.math.pow(f32, 2.0, 10.0 * t - 10.0) * @sin((t * 10.0 - 10.75) * c4);
            },
            .bounce => {
                return 1.0 - bounceOut(1.0 - t);
            },
        };
    }

    fn easeOut(curve: EaseCurve, t: f32) f32 {
        return switch (curve) {
            .quad => 1.0 - (1.0 - t) * (1.0 - t),
            .cubic => 1.0 - std.math.pow(f32, 1.0 - t, 3),
            .quart => 1.0 - std.math.pow(f32, 1.0 - t, 4),
            .quint => 1.0 - std.math.pow(f32, 1.0 - t, 5),
            .sine => @sin(t * std.math.pi / 2.0),
            .expo => if (t >= 1) 1 else 1.0 - std.math.pow(f32, 2.0, -10.0 * t),
            .circ => @sqrt(@max(0, 1.0 - (1.0 - t) * (1.0 - t))),
            .back => {
                const c1: f32 = 1.70158;
                const c3 = c1 + 1.0;
                const u = t - 1.0;
                return 1.0 + c3 * u * u * u + c1 * u * u;
            },
            .elastic => {
                if (t <= 0) return 0;
                if (t >= 1) return 1;
                const c4 = (2.0 * std.math.pi) / 3.0;
                return std.math.pow(f32, 2.0, -10.0 * t) * @sin((t * 10.0 - 0.75) * c4) + 1.0;
            },
            .bounce => bounceOut(t),
        };
    }

    fn easeInOut(curve: EaseCurve, t: f32) f32 {
        if (t < 0.5) return easeIn(curve, t * 2.0) / 2.0;
        return 1.0 - easeIn(curve, (1.0 - t) * 2.0) / 2.0;
    }

    fn bounceOut(t: f32) f32 {
        const n1: f32 = 7.5625;
        const d1: f32 = 2.75;
        if (t < 1.0 / d1) {
            return n1 * t * t;
        } else if (t < 2.0 / d1) {
            const u = t - 1.5 / d1;
            return n1 * u * u + 0.75;
        } else if (t < 2.5 / d1) {
            const u = t - 2.25 / d1;
            return n1 * u * u + 0.9375;
        } else {
            const u = t - 2.625 / d1;
            return n1 * u * u + 0.984375;
        }
    }

    /// Cubic bezier 精确求解 (牛顿迭代)
    fn cubicBezier(x1: f32, y1: f32, x2: f32, y2: f32, x: f32) f32 {
        if (x <= 0) return 0;
        if (x >= 1) return 1;

        // 求 t 使得 bezierX(t) = x
        var t = x; // 初始猜测
        var i: u32 = 0;
        while (i < 8) : (i += 1) {
            const bx = bezierComponent(x1, x2, t) - x;
            if (@abs(bx) < 1e-6) break;
            const dbx = bezierDerivative(x1, x2, t);
            if (@abs(dbx) < 1e-6) break;
            t -= bx / dbx;
            t = std.math.clamp(t, 0.0, 1.0);
        }

        return bezierComponent(y1, y2, t);
    }

    fn bezierComponent(p1: f32, p2: f32, t: f32) f32 {
        const u = 1.0 - t;
        return 3.0 * u * u * t * p1 + 3.0 * u * t * t * p2 + t * t * t;
    }

    fn bezierDerivative(p1: f32, p2: f32, t: f32) f32 {
        const u = 1.0 - t;
        return 3.0 * u * u * p1 + 6.0 * u * t * (p2 - p1) + 3.0 * t * t * (1.0 - p2);
    }

    fn springEvaluate(sp: SpringConfig, t: f32) f32 {
        // 将 t (0..1) 映射到时间 (0..duration), duration 由弹簧参数决定
        const duration: f32 = 4.0; // 归一化到 4 个时间单位
        const time = t * duration;

        const omega = @sqrt(sp.stiffness / sp.mass);
        const zeta = sp.damping / (2.0 * @sqrt(sp.stiffness * sp.mass));

        if (zeta >= 1.0) {
            // 过阻尼 / 临界阻尼
            return 1.0 - @exp(-omega * time * zeta);
        }
        // 欠阻尼
        const omega_d = omega * @sqrt(1.0 - zeta * zeta);
        const decay = @exp(-zeta * omega * time);
        return 1.0 - decay * (@cos(omega_d * time) + (zeta * omega / omega_d) * @sin(omega_d * time));
    }

    fn stepsEvaluate(count: u32, jump_start: bool, t: f32) f32 {
        if (count == 0) return t;
        const n: f32 = @floatFromInt(count);
        if (jump_start) {
            return @ceil(t * n) / n;
        }
        return @floor(t * n) / n;
    }
};

// ── Tween (值插值) ──────────────────────────────────────────────────────────

pub const Tween = struct {
    from: f32,
    to: f32,
    duration_ms: u32,
    easing: Easing = .{ .ease_out = .cubic },
    elapsed_ms: u32 = 0,
    state: AnimState = .idle,
    on_update: ?*const fn (value: f32, ctx: ?*anyopaque) void = null,
    on_complete: ?*const fn (ctx: ?*anyopaque) void = null,
    ctx: ?*anyopaque = null,

    pub fn start(self: *Tween) void {
        self.elapsed_ms = 0;
        self.state = .running;
    }

    pub fn update(self: *Tween, delta_ms: u32) f32 {
        if (self.state != .running) return self.currentValue();

        self.elapsed_ms += delta_ms;
        const t: f32 = if (self.duration_ms == 0) 1.0 else @min(1.0, @as(f32, @floatFromInt(self.elapsed_ms)) / @as(f32, @floatFromInt(self.duration_ms)));
        const value = self.lerp(self.easing.evaluate(t));

        if (self.on_update) |cb| {
            cb(value, self.ctx);
        }

        if (t >= 1.0) {
            self.state = .completed;
            if (self.on_complete) |cb| {
                cb(self.ctx);
            }
        }

        return value;
    }

    pub fn currentValue(self: *const Tween) f32 {
        const t: f32 = if (self.duration_ms == 0) 1.0 else @min(1.0, @as(f32, @floatFromInt(self.elapsed_ms)) / @as(f32, @floatFromInt(self.duration_ms)));
        return self.lerp(self.easing.evaluate(t));
    }

    fn lerp(self: *const Tween, t: f32) f32 {
        return self.from + (self.to - self.from) * t;
    }
};

/// 颜色插值
pub fn lerpColor(from: math.Color, to: math.Color, t: f32) math.Color {
    const tc = std.math.clamp(t, 0.0, 1.0);
    return .{
        .r = @intFromFloat(@as(f32, @floatFromInt(from.r)) + (@as(f32, @floatFromInt(to.r)) - @as(f32, @floatFromInt(from.r))) * tc),
        .g = @intFromFloat(@as(f32, @floatFromInt(from.g)) + (@as(f32, @floatFromInt(to.g)) - @as(f32, @floatFromInt(from.g))) * tc),
        .b = @intFromFloat(@as(f32, @floatFromInt(from.b)) + (@as(f32, @floatFromInt(to.b)) - @as(f32, @floatFromInt(from.b))) * tc),
        .a = @intFromFloat(@as(f32, @floatFromInt(from.a)) + (@as(f32, @floatFromInt(to.a)) - @as(f32, @floatFromInt(from.a))) * tc),
    };
}

// ── AnimationController ─────────────────────────────────────────────────────

pub const AnimatableProperty = union(enum) {
    opacity: struct { from: f32, to: f32 },
    translate_x: struct { from: f32, to: f32 },
    translate_y: struct { from: f32, to: f32 },
    scale: struct { from: f32, to: f32 },
    rotation: struct { from: f32, to: f32 },
    color: struct { from: math.Color, to: math.Color },
    width: struct { from: f32, to: f32 },
    height: struct { from: f32, to: f32 },
    custom: struct { from: f32, to: f32 },
};

pub const Animation = struct {
    id: AnimationId,
    property: AnimatableProperty,
    duration_ms: u32,
    easing: Easing = .{ .ease_out = .cubic },
    delay_ms: u32 = 0,
    repeat: RepeatMode = .none,
    elapsed_ms: u32 = 0,
    state: AnimState = .idle,
    on_update: ?*const fn (value: f32, ctx: ?*anyopaque) void = null,
    on_complete: ?*const fn (ctx: ?*anyopaque) void = null,
    ctx: ?*anyopaque = null,

    pub fn progress(self: *const Animation) f32 {
        if (self.elapsed_ms < self.delay_ms) return 0;
        const active = self.elapsed_ms - self.delay_ms;
        return @min(1.0, @as(f32, @floatFromInt(active)) / @as(f32, @floatFromInt(@max(1, self.duration_ms))));
    }

    pub fn value(self: *const Animation) f32 {
        const t = self.easing.evaluate(self.progress());
        return switch (self.property) {
            .opacity => |p| p.from + (p.to - p.from) * t,
            .translate_x => |p| p.from + (p.to - p.from) * t,
            .translate_y => |p| p.from + (p.to - p.from) * t,
            .scale => |p| p.from + (p.to - p.from) * t,
            .rotation => |p| p.from + (p.to - p.from) * t,
            .width => |p| p.from + (p.to - p.from) * t,
            .height => |p| p.from + (p.to - p.from) * t,
            .custom => |p| p.from + (p.to - p.from) * t,
            .color => 0, // 颜色单独处理
        };
    }
};

pub const AnimationController = struct {
    allocator: std.mem.Allocator,
    animations: std.ArrayListUnmanaged(Animation) = .{ .items = &.{}, .capacity = 0 },
    tweens: std.ArrayListUnmanaged(*Tween) = .{ .items = &.{}, .capacity = 0 },

    pub fn init(allocator: std.mem.Allocator) AnimationController {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *AnimationController) void {
        self.animations.deinit(self.allocator);
        self.tweens.deinit(self.allocator);
    }

    /// 添加动画
    pub fn addAnimation(self: *AnimationController, anim: Animation) !AnimationId {
        var a = anim;
        a.id = genAnimId();
        a.state = .running;
        try self.animations.append(self.allocator, a);
        return a.id;
    }

    /// 添加 Tween
    pub fn addTween(self: *AnimationController, tween: *Tween) void {
        tween.start();
        self.tweens.append(self.allocator, tween) catch {};
    }

    /// 每帧更新
    pub fn update(self: *AnimationController, delta_ms: u32) void {
        // 更新 animations
        var i: usize = 0;
        while (i < self.animations.items.len) {
            const anim = &self.animations.items[i];
            if (anim.state != .running) {
                // 移除已完成的
                if (anim.state == .completed) {
                    _ = self.animations.orderedRemove(i);
                    continue;
                }
                i += 1;
                continue;
            }

            anim.elapsed_ms += delta_ms;
            if (anim.elapsed_ms < anim.delay_ms) {
                i += 1;
                continue;
            }

            const v = anim.value();
            if (anim.on_update) |cb| {
                cb(v, anim.ctx);
            }

            if (anim.progress() >= 1.0) {
                switch (anim.repeat) {
                    .none => {
                        anim.state = .completed;
                        if (anim.on_complete) |cb| {
                            cb(anim.ctx);
                        }
                    },
                    .restart => {
                        anim.elapsed_ms = anim.delay_ms;
                    },
                    .reverse, .ping_pong => {
                        // 简化: 反转 from/to
                        anim.elapsed_ms = anim.delay_ms;
                    },
                }
            }
            i += 1;
        }

        // 更新 tweens
        var j: usize = 0;
        while (j < self.tweens.items.len) {
            const tw = self.tweens.items[j];
            _ = tw.update(delta_ms);
            if (tw.state == .completed) {
                _ = self.tweens.orderedRemove(j);
            } else {
                j += 1;
            }
        }
    }

    /// 是否有活跃动画
    pub fn hasActive(self: *const AnimationController) bool {
        if (self.animations.items.len > 0) return true;
        if (self.tweens.items.len > 0) return true;
        return false;
    }

    /// 取消所有动画
    pub fn cancelAll(self: *AnimationController) void {
        self.animations.clearRetainingCapacity();
        self.tweens.clearRetainingCapacity();
    }
};

// ── 单元测试 ──────────────────────────────────────────────────────────────────

test "Easing.linear" {
    const e = Easing{ .linear = {} };
    try std.testing.expectApproxEqAbs(@as(f32, 0.5), e.evaluate(0.5), 1e-6);
}

test "Easing.ease_in quad" {
    const e = Easing{ .ease_in = .quad };
    try std.testing.expectApproxEqAbs(@as(f32, 0.25), e.evaluate(0.5), 1e-6);
}

test "Easing.ease_out cubic" {
    const e = Easing{ .ease_out = .cubic };
    // ease_out cubic at 0.5 = 1 - (1-0.5)^3 = 1 - 0.125 = 0.875
    try std.testing.expectApproxEqAbs(@as(f32, 0.875), e.evaluate(0.5), 1e-5);
}

test "Easing.bounce boundaries" {
    const e = Easing{ .ease_out = .bounce };
    try std.testing.expectApproxEqAbs(@as(f32, 0.0), e.evaluate(0.0), 1e-5);
    try std.testing.expectApproxEqAbs(@as(f32, 1.0), e.evaluate(1.0), 1e-5);
}

test "Easing.cubic_bezier linear" {
    // cubic-bezier(0, 0, 1, 1) ≈ linear
    const e = Easing{ .cubic_bezier = .{ .x1 = 0, .y1 = 0, .x2 = 1, .y2 = 1 } };
    try std.testing.expectApproxEqAbs(@as(f32, 0.5), e.evaluate(0.5), 0.01);
}

test "Tween basic" {
    var tw = Tween{ .from = 0, .to = 100, .duration_ms = 1000 };
    tw.start();
    _ = tw.update(500);
    const v = tw.currentValue();
    try std.testing.expect(v > 0 and v < 100);
    _ = tw.update(600);
    try std.testing.expectEqual(AnimState.completed, tw.state);
    try std.testing.expectApproxEqAbs(@as(f32, 100), tw.currentValue(), 0.01);
}

test "lerpColor" {
    const from = math.Color{ .r = 0, .g = 0, .b = 0, .a = 255 };
    const to = math.Color{ .r = 255, .g = 255, .b = 255, .a = 255 };
    const mid = lerpColor(from, to, 0.5);
    try std.testing.expect(mid.r > 120 and mid.r < 135);
}
