//! 手势识别器
//! 从原始触摸事件流识别高层手势 (Tap / Drag / Pinch)

const std = @import("std");
const pal = @import("../pal/pal.zig");

const Touch = pal.event.Touch;

/// 单击手势: began → ended, 时长与位移均在阈值内
pub const TapGesture = struct {
    /// 最长按压时长 (ns)
    max_duration_ns: u64 = 250 * std.time.ns_per_ms,
    /// 最大位移 (px)
    max_distance: f32 = 10.0,

    tracking: ?Tracking = null,

    pub const Tracking = struct {
        id: u32,
        x0: f32,
        y0: f32,
        t0_ns: u64,
    };

    pub const Result = struct {
        x: f32,
        y: f32,
    };

    /// 喂入触摸事件, 识别到 tap 时返回点击位置
    pub fn onTouch(self: *TapGesture, t: Touch, now_ns: u64) ?Result {
        switch (t.phase) {
            .began => {
                if (self.tracking == null) {
                    self.tracking = .{ .id = t.id, .x0 = t.x, .y0 = t.y, .t0_ns = now_ns };
                }
            },
            .moved => {
                if (self.tracking) |*tr| {
                    if (tr.id == t.id) {
                        const dx = t.x - tr.x0;
                        const dy = t.y - tr.y0;
                        if (dx * dx + dy * dy > self.max_distance * self.max_distance) {
                            self.tracking = null; // 位移过大, 不是 tap
                        }
                    }
                }
            },
            .ended => {
                if (self.tracking) |tr| {
                    defer self.tracking = null;
                    if (tr.id == t.id and now_ns - tr.t0_ns <= self.max_duration_ns) {
                        return .{ .x = t.x, .y = t.y };
                    }
                }
            },
            .cancelled => self.tracking = null,
        }
        return null;
    }
};

/// 拖拽手势: 单指 began → moved* → ended, 输出增量位移
pub const DragGesture = struct {
    /// 触发拖拽的最小位移 (px), 过滤抖动
    min_distance: f32 = 4.0,

    active: ?Active = null,

    pub const Active = struct {
        id: u32,
        x0: f32,
        y0: f32,
        last_x: f32,
        last_y: f32,
        started: bool = false,
    };

    pub const Result = struct {
        /// 相对上一 moved 的增量
        dx: f32,
        dy: f32,
        /// 相对起点的累计位移
        total_x: f32,
        total_y: f32,
        /// 是否为首次触发 (越过 min_distance 阈值)
        began: bool,
        /// 是否结束
        ended: bool,
    };

    /// 喂入触摸事件, 拖拽进行中/结束时返回位移信息
    pub fn onTouch(self: *DragGesture, t: Touch) ?Result {
        switch (t.phase) {
            .began => {
                if (self.active == null) {
                    self.active = .{
                        .id = t.id,
                        .x0 = t.x,
                        .y0 = t.y,
                        .last_x = t.x,
                        .last_y = t.y,
                        .started = false,
                    };
                }
            },
            .moved => {
                if (self.active) |*a| {
                    if (a.id == t.id) {
                        const total_x = t.x - a.x0;
                        const total_y = t.y - a.y0;
                        if (!a.started) {
                            if (total_x * total_x + total_y * total_y <
                                self.min_distance * self.min_distance) return null;
                            a.started = true;
                        }
                        const dx = t.x - a.last_x;
                        const dy = t.y - a.last_y;
                        a.last_x = t.x;
                        a.last_y = t.y;
                        return .{ .dx = dx, .dy = dy, .total_x = total_x, .total_y = total_y, .began = false, .ended = false };
                    }
                }
            },
            .ended => {
                if (self.active) |a| {
                    if (a.id == t.id and a.started) {
                        self.active = null;
                        return .{
                            .dx = 0,
                            .dy = 0,
                            .total_x = t.x - a.x0,
                            .total_y = t.y - a.y0,
                            .began = false,
                            .ended = true,
                        };
                    }
                    if (a.id == t.id) self.active = null;
                }
            },
            .cancelled => self.active = null,
        }
        return null;
    }
};

/// 双指捏合: 跟踪两触点距离变化, 输出缩放比例
pub const PinchGesture = struct {
    /// 两触点 id 与位置
    slots: [2]?Slot = .{ null, null },
    initial_dist: f32 = 0,
    last_dist: f32 = 0,

    pub const Slot = struct {
        id: u32,
        x: f32,
        y: f32,
    };

    pub const Result = struct {
        /// 相对初始距离的缩放比
        scale: f32,
        /// 相对上一帧的增量缩放比
        delta_scale: f32,
        /// 两指中点
        center_x: f32,
        center_y: f32,
        ended: bool,
    };

    pub fn onTouch(self: *PinchGesture, t: Touch) ?Result {
        switch (t.phase) {
            .began => {
                for (&self.slots) |*s| {
                    if (s.* == null) {
                        s.* = .{ .id = t.id, .x = t.x, .y = t.y };
                        break;
                    }
                }
                if (self.slots[0] != null and self.slots[1] != null) {
                    const d = self.distance();
                    self.initial_dist = d;
                    self.last_dist = d;
                }
            },
            .moved => {
                if (self.updateSlot(t)) {
                    if (self.slots[0] != null and self.slots[1] != null and self.initial_dist > 0) {
                        const d = self.distance();
                        const scale = d / self.initial_dist;
                        const delta = d / self.last_dist;
                        self.last_dist = d;
                        const s0 = self.slots[0].?;
                        const s1 = self.slots[1].?;
                        return .{
                            .scale = scale,
                            .delta_scale = delta,
                            .center_x = (s0.x + s1.x) / 2,
                            .center_y = (s0.y + s1.y) / 2,
                            .ended = false,
                        };
                    }
                }
            },
            .ended, .cancelled => {
                if (self.removeSlot(t.id)) {
                    if (self.slots[0] == null or self.slots[1] == null) {
                        self.initial_dist = 0;
                        self.last_dist = 0;
                        return .{ .scale = 1, .delta_scale = 1, .center_x = t.x, .center_y = t.y, .ended = true };
                    }
                }
            },
        }
        return null;
    }

    fn updateSlot(self: *PinchGesture, t: Touch) bool {
        for (&self.slots) |*s| {
            if (s.*) |*slot| {
                if (slot.id == t.id) {
                    slot.x = t.x;
                    slot.y = t.y;
                    return true;
                }
            }
        }
        return false;
    }

    fn removeSlot(self: *PinchGesture, id: u32) bool {
        for (&self.slots) |*s| {
            if (s.*) |slot| {
                if (slot.id == id) {
                    s.* = null;
                    return true;
                }
            }
        }
        return false;
    }

    fn distance(self: *const PinchGesture) f32 {
        const s0 = self.slots[0].?;
        const s1 = self.slots[1].?;
        const dx = s1.x - s0.x;
        const dy = s1.y - s0.y;
        return @sqrt(dx * dx + dy * dy);
    }
};

// ── Tests ──────────────────────────────────────────────────────────────────

fn touch(id: u32, phase: pal.TouchPhase, x: f32, y: f32) Touch {
    return .{ .id = id, .phase = phase, .x = x, .y = y };
}

test "tap gesture recognizes quick touch" {
    var tap = TapGesture{};
    const t0: u64 = 1_000_000_000;

    try std.testing.expect(tap.onTouch(touch(1, .began, 100, 100), t0) == null);
    try std.testing.expect(tap.onTouch(touch(1, .moved, 102, 101), t0 + 50 * std.time.ns_per_ms) == null);
    const result = tap.onTouch(touch(1, .ended, 102, 101), t0 + 100 * std.time.ns_per_ms);
    try std.testing.expect(result != null);
    try std.testing.expectEqual(@as(f32, 102), result.?.x);
    try std.testing.expectEqual(@as(f32, 101), result.?.y);
}

test "tap gesture rejects long press" {
    var tap = TapGesture{};
    const t0: u64 = 0;

    _ = tap.onTouch(touch(1, .began, 100, 100), t0);
    const result = tap.onTouch(touch(1, .ended, 100, 100), t0 + 500 * std.time.ns_per_ms);
    try std.testing.expect(result == null);
}

test "tap gesture rejects large movement" {
    var tap = TapGesture{};
    const t0: u64 = 0;

    _ = tap.onTouch(touch(1, .began, 100, 100), t0);
    _ = tap.onTouch(touch(1, .moved, 150, 100), t0 + 10 * std.time.ns_per_ms);
    const result = tap.onTouch(touch(1, .ended, 150, 100), t0 + 20 * std.time.ns_per_ms);
    try std.testing.expect(result == null);
}

test "drag gesture reports deltas after threshold" {
    var drag = DragGesture{ .min_distance = 4.0 };

    try std.testing.expect(drag.onTouch(touch(1, .began, 0, 0)) == null);
    // 小于阈值, 不触发
    try std.testing.expect(drag.onTouch(touch(1, .moved, 2, 0)) == null);
    // 越过阈值
    const r1 = drag.onTouch(touch(1, .moved, 10, 0));
    try std.testing.expect(r1 != null);
    try std.testing.expectEqual(@as(f32, 10), r1.?.total_x);
    try std.testing.expect(!r1.?.ended);

    const r2 = drag.onTouch(touch(1, .moved, 15, 5));
    try std.testing.expect(r2 != null);
    try std.testing.expectEqual(@as(f32, 5), r2.?.dx);
    try std.testing.expectEqual(@as(f32, 5), r2.?.dy);

    const r3 = drag.onTouch(touch(1, .ended, 15, 5));
    try std.testing.expect(r3 != null);
    try std.testing.expect(r3.?.ended);
}

test "drag gesture ignores second finger" {
    var drag = DragGesture{};

    _ = drag.onTouch(touch(1, .began, 0, 0));
    _ = drag.onTouch(touch(2, .began, 50, 50)); // 第二指忽略
    try std.testing.expect(drag.onTouch(touch(2, .moved, 60, 60)) == null);
    try std.testing.expect(drag.onTouch(touch(1, .moved, 20, 0)) != null);
}

test "pinch gesture computes scale" {
    var pinch = PinchGesture{};

    _ = pinch.onTouch(touch(1, .began, 0, 0));
    try std.testing.expect(pinch.onTouch(touch(2, .began, 100, 0)) == null);

    // 两指拉开到 200 → scale 2x
    _ = pinch.onTouch(touch(1, .moved, -50, 0));
    const r = pinch.onTouch(touch(2, .moved, 150, 0));
    try std.testing.expect(r != null);
    try std.testing.expectApproxEqAbs(@as(f32, 2.0), r.?.scale, 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, 50), r.?.center_x, 0.001);

    // 一指抬起 → 结束
    const e = pinch.onTouch(touch(2, .ended, 150, 0));
    try std.testing.expect(e != null);
    try std.testing.expect(e.?.ended);
}
