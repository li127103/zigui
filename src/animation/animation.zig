//! 动画系统

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

pub const Easing = union(enum) {
    linear: void,
    ease_in: EaseCurve,
    ease_out: EaseCurve,
    ease_in_out: EaseCurve,
    cubic_bezier: struct { x1: f32, y1: f32, x2: f32, y2: f32 },
    spring: SpringConfig,

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
        return switch (self) {
            .linear => t,
            .ease_in => |curve| easeIn(curve, t),
            .ease_out => |curve| easeOut(curve, t),
            .ease_in_out => |curve| easeInOut(curve, t),
            .cubic_bezier => |bz| cubicBezier(bz, t),
            .spring => |sp| springEvaluate(sp, t),
        };
    }

    fn easeIn(curve: EaseCurve, t: f32) f32 {
        return switch (curve) {
            .quad => t * t,
            .cubic => t * t * t,
            .quart => t * t * t * t,
            .quint => t * t * t * t * t,
            .sine => 1.0 - @cos(t * std.math.pi / 2.0),
            .expo => if (t == 0) 0 else std.math.pow(f32, 2.0, 10.0 * (t - 1.0)),
            .circ => 1.0 - @sqrt(1.0 - t * t),
            else => t,
        };
    }

    fn easeOut(curve: EaseCurve, t: f32) f32 {
        return 1.0 - easeIn(curve, 1.0 - t);
    }

    fn easeInOut(curve: EaseCurve, t: f32) f32 {
        if (t < 0.5) return easeIn(curve, t * 2.0) / 2.0;
        return 1.0 - easeIn(curve, (1.0 - t) * 2.0) / 2.0;
    }

    fn cubicBezier(bz: struct { x1: f32, y1: f32, x2: f32, y2: f32 }, t: f32) f32 {
        // 简化: 直接对 y 做插值 (精确实现需要牛顿迭代求 x→t 映射)
        _ = bz;
        return t; // M3: 实现精确 cubic-bezier
    }

    fn springEvaluate(sp: SpringConfig, t: f32) f32 {
        // 阻尼弹簧: x(t) = 1 - e^(-ζωt)(cos(ωd·t) + (ζω/ωd)sin(ωd·t))
        const omega = @sqrt(sp.stiffness / sp.mass);
        const zeta = sp.damping / (2.0 * @sqrt(sp.stiffness * sp.mass));
        if (zeta >= 1.0) {
            // 过阻尼
            return 1.0 - @exp(-omega * t * zeta);
        }
        const omega_d = omega * @sqrt(1.0 - zeta * zeta);
        const decay = @exp(-zeta * omega * t);
        return 1.0 - decay * (@cos(omega_d * t) + (zeta * omega / omega_d) * @sin(omega_d * t));
    }
};

pub const AnimatableProperty = union(enum) {
    opacity: struct { from: f32, to: f32 },
    translate_x: struct { from: f32, to: f32 },
    translate_y: struct { from: f32, to: f32 },
    scale: struct { from: f32, to: f32 },
    rotation: struct { from: f32, to: f32 },
    color: struct { from: math.Color, to: math.Color },
};

pub const Animation = struct {
    id: AnimationId,
    property: AnimatableProperty,
    duration_ms: u32,
    easing: Easing = .{ .linear = {} },
    delay_ms: u32 = 0,
    repeat: RepeatMode = .none,
    elapsed_ms: u32 = 0,
    state: AnimState = .idle,
};

pub const AnimationController = struct {
    allocator: std.mem.Allocator,
    animations: std.ArrayListUnmanaged(Animation) = .{},

    pub fn init(allocator: std.mem.Allocator) AnimationController {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *AnimationController) void {
        self.animations.deinit(self.allocator);
    }

    pub fn update(self: *AnimationController, delta_ms: u32) void {
        for (self.animations.items) |*anim| {
            if (anim.state != .running) continue;
            anim.elapsed_ms += delta_ms;
            if (anim.elapsed_ms < anim.delay_ms) continue;
            const active_time = anim.elapsed_ms - anim.delay_ms;
            const t: f32 = @min(1.0, @as(f32, @floatFromInt(active_time)) / @as(f32, @floatFromInt(anim.duration_ms)));
            _ = anim.easing.evaluate(t);
            if (t >= 1.0) {
                anim.state = .completed;
            }
        }
    }

    pub fn hasActive(self: *AnimationController) bool {
        for (self.animations.items) |anim| {
            if (anim.state == .running) return true;
        }
        return false;
    }
};

const std = @import("std");

test "Easing.linear" {
    const e = Easing{ .linear = {} };
    try std.testing.expectApproxEqAbs(@as(f32, 0.5), e.evaluate(0.5), 1e-6);
}

test "Easing.ease_in quad" {
    const e = Easing{ .ease_in = .quad };
    try std.testing.expectApproxEqAbs(@as(f32, 0.25), e.evaluate(0.5), 1e-6);
}
