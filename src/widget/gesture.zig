//! Gesture 手势识别控件系列 (对标 GTK4 GtkGesture*)
//!
//! 通过 Widget.event_controllers + EventController.wrap 机制挂接到任意 Widget。
//! 挂接后 widget.dispatchEvent 会在调用 on_event 之前先调用每个 gesture 的 handleEvent。
//!
//! 使用方式：
//! ```
//! var click = try gesture.GestureClick.create(allocator, .{ .on_pressed = onMyClick });
//! click.attach(&my_widget.base);  // 内部通过 EventController 挂到 my_widget
//! ```

const std = @import("std");
const math = @import("../math.zig");
const widget_mod = @import("widget.zig");
const pal = @import("../pal/pal.zig");
const perf = @import("../perf.zig");

const Widget = widget_mod.Widget;
const EventContext = widget_mod.EventContext;
const EventResult = widget_mod.EventResult;
const EventController = widget_mod.EventController;

// ────────────────────────────────────────────────────────────────────────────
// GestureBase —— 所有手势的公共基类 (GTK4: GtkGesture)
// ────────────────────────────────────────────────────────────────────────────

pub const GestureBase = struct {
    allocator: std.mem.Allocator,
    /// attach 到的目标 widget
    attached_widget: ?*Widget = null,
    /// 触摸点数量 (GTK4 n_points)
    n_points: u32 = 1,
    /// 当前手势是否处于活动状态 (序列中)
    is_active: bool = false,
    /// 当前识别的触摸点序列
    current_sequence: ?*anyopaque = null,

    pub fn init(allocator: std.mem.Allocator, n_points: u32) GestureBase {
        return .{
            .allocator = allocator,
            .n_points = n_points,
        };
    }

    pub fn deinit(self: *GestureBase) void {
        _ = self;
    }

    /// GTK4: gtk_event_controller_set_propagation_phase
    /// 具体 Gesture 子类 attach 时: 将自身封装为 EventController 挂到 widget.event_controllers
    pub fn attachAsController(self_ptr: *anyopaque, target: *Widget, allocator: std.mem.Allocator, comptime T: type, comptime handleEventFn: fn (self: *T, widget: *Widget, event: *const pal.Event, ectx: *EventContext) EventResult, comptime tickFn: ?fn (self: *T, delta_ms: u32) void, comptime name: []const u8) void {
        const typed: *T = @ptrCast(@alignCast(self_ptr));
        // 记录 attached_widget（基于 GestureBase 偏移：T 第一个字段如果是 GestureSingle，其第一个字段是 GestureBase）
        // 由具体子类在调用后再自行赋值 attached_widget（简单起见此处直接操作 base 指针）
        target.addEventController(allocator, EventController.wrap(T, typed, handleEventFn, tickFn, name)) catch {};
    }

    /// GTK4: gtk_gesture_get_widget
    pub fn getWidget(self: *const GestureBase) ?*Widget {
        return self.attached_widget;
    }

    /// GTK4: gtk_gesture_is_active
    pub fn isActive(self: *const GestureBase) bool {
        return self.is_active;
    }

    /// GTK4: gtk_gesture_set_sequence_state
    pub fn setSequenceState(_self: *GestureBase, _state: enum { none, claimed, denied }) void {
        _ = _self;
        _ = _state;
    }
};

// ────────────────────────────────────────────────────────────────────────────
// GestureSingle —— 单指点手势基类 (GTK4: GtkGestureSingle)
// ────────────────────────────────────────────────────────────────────────────

pub const GestureSingle = struct {
    base: GestureBase,
    button: pal.MouseButton = .left,
    current_button: u32 = 0,
    exclusive: bool = true,
    touch_only: bool = false,

    pub fn init(allocator: std.mem.Allocator, button: pal.MouseButton) GestureSingle {
        return .{
            .base = GestureBase.init(allocator, 1),
            .button = button,
        };
    }
};

// ────────────────────────────────────────────────────────────────────────────
// GestureClick —— 单击/双击识别 (GTK4: GtkGestureClick)
// ────────────────────────────────────────────────────────────────────────────

pub const GestureClick = struct {
    single: GestureSingle,
    button: pal.MouseButton,
    double_click_window_ms: u32 = 400,
    click_tolerance: f32 = 4.0,

    press_x: f32 = 0,
    press_y: f32 = 0,
    press_time_ms: u64 = 0,
    last_release_time_ms: u64 = 0,
    click_count: u32 = 0,
    in_press: bool = false,

    on_pressed: ?*const fn (self: *GestureClick, n_press: u32, x: f32, y: f32) void = null,
    on_released: ?*const fn (self: *GestureClick, n_press: u32, x: f32, y: f32) void = null,
    on_stopped: ?*const fn (self: *GestureClick) void = null,
    on_unpaired_release: ?*const fn (self: *GestureClick, x: f32, y: f32, button: pal.MouseButton) void = null,

    const Self = @This();

    pub fn create(allocator: std.mem.Allocator, opts: struct {
        button: pal.MouseButton = .left,
        double_click_window_ms: u32 = 400,
        click_tolerance: f32 = 4.0,
        on_pressed: ?*const fn (self: *GestureClick, n_press: u32, x: f32, y: f32) void = null,
        on_released: ?*const fn (self: *GestureClick, n_press: u32, x: f32, y: f32) void = null,
        on_stopped: ?*const fn (self: *GestureClick) void = null,
    }) !*GestureClick {
        const self = try allocator.create(GestureClick);
        self.* = .{
            .single = GestureSingle.init(allocator, opts.button),
            .button = opts.button,
            .double_click_window_ms = opts.double_click_window_ms,
            .click_tolerance = opts.click_tolerance,
            .on_pressed = opts.on_pressed,
            .on_released = opts.on_released,
            .on_stopped = opts.on_stopped,
        };
        return self;
    }

    pub fn destroy(self: *Self, allocator: std.mem.Allocator) void {
        if (self.single.base.attached_widget) |w| {
            w.removeEventController(@ptrCast(@alignCast(self)));
        }
        self.single.base.deinit();
        allocator.destroy(self);
    }

    /// attach 到 Widget (通过 EventController)
    pub fn attach(self: *Self, target: *Widget) void {
        self.single.base.attached_widget = target;
        GestureBase.attachAsController(
            @ptrCast(@alignCast(self)),
            target,
            self.single.base.allocator,
            Self,
            handleEvent,
            null,
            "GestureClick",
        );
    }

    pub fn getWidget(self: *const Self) ?*Widget {
        return self.single.base.getWidget();
    }

    pub fn setButton(self: *Self, button: pal.MouseButton) void {
        self.button = button;
        self.single.button = button;
    }

    pub fn getButton(self: *const Self) pal.MouseButton {
        return self.button;
    }

    fn nowMs() u64 {
        return perf.nowMs();
    }

    /// EventController 事件处理签名（带 widget 参数）
    pub fn handleEvent(self: *Self, _widget: *Widget, event: *const pal.Event, _ectx: *EventContext) EventResult {
        _ = _widget;
        _ = _ectx;
        switch (event.*) {
            .mouse_button => |mb| {
                if (mb.button != self.button) return .ignored;
                const x = @as(f32, @floatFromInt(mb.x));
                const y = @as(f32, @floatFromInt(mb.y));
                const t = nowMs();

                if (mb.state == .pressed) {
                    if (t - self.last_release_time_ms < self.double_click_window_ms and
                        @abs(x - self.press_x) < self.click_tolerance and
                        @abs(y - self.press_y) < self.click_tolerance)
                    {
                        self.click_count += 1;
                    } else {
                        self.click_count = 1;
                    }
                    self.press_x = x;
                    self.press_y = y;
                    self.press_time_ms = t;
                    self.in_press = true;
                    self.single.base.is_active = true;
                    if (self.on_pressed) |cb| cb(self, self.click_count, x, y);
                    return .handled;
                } else { // released
                    if (self.in_press) {
                        self.in_press = false;
                        self.last_release_time_ms = t;
                        if (@abs(x - self.press_x) < self.click_tolerance and
                            @abs(y - self.press_y) < self.click_tolerance)
                        {
                            if (self.on_released) |cb| cb(self, self.click_count, x, y);
                        }
                        self.single.base.is_active = false;
                        if (self.on_stopped) |cb| cb(self);
                        return .handled;
                    } else if (self.on_unpaired_release) |cb| {
                        cb(self, x, y, mb.button);
                    }
                }
            },
            else => {},
        }
        return .ignored;
    }
};

// ────────────────────────────────────────────────────────────────────────────
// GestureStable -- 稳定手势识别 (GTK4: GtkGestureStable)
// 用于识别"稳定"的触摸点：按下后保持不动超过阈值时间才触发
// ────────────────────────────────────────────────────────────────────────────

pub const GestureStable = struct {
    single: GestureSingle,
    /// 稳定阈值时间（ms），按下后保持不动超过此时间则认为"稳定"
    stability_threshold_ms: u32 = 500,
    /// 允许的移动容差（px），超过则取消稳定判定
    move_tolerance: f32 = 8.0,

    press_x: f32 = 0,
    press_y: f32 = 0,
    press_time_ms: u64 = 0,
    pressing: bool = false,
    stable: bool = false,
    triggered: bool = false,

    on_stable: ?*const fn (self: *GestureStable, x: f32, y: f32) void = null,
    on_unstable: ?*const fn (self: *GestureStable) void = null,

    const Self = @This();

    pub fn create(allocator: std.mem.Allocator, opts: struct {
        button: pal.MouseButton = .left,
        stability_threshold_ms: u32 = 500,
        move_tolerance: f32 = 8.0,
        on_stable: ?*const fn (self: *GestureStable, x: f32, y: f32) void = null,
        on_unstable: ?*const fn (self: *GestureStable) void = null,
    }) !*GestureStable {
        const self = try allocator.create(GestureStable);
        self.* = .{
            .single = GestureSingle.init(allocator, opts.button),
            .stability_threshold_ms = opts.stability_threshold_ms,
            .move_tolerance = opts.move_tolerance,
            .on_stable = opts.on_stable,
            .on_unstable = opts.on_unstable,
        };
        return self;
    }

    pub fn destroy(self: *Self, allocator: std.mem.Allocator) void {
        if (self.single.base.attached_widget) |w| w.removeEventController(@ptrCast(@alignCast(self)));
        self.single.base.deinit();
        allocator.destroy(self);
    }

    pub fn attach(self: *Self, target: *Widget) void {
        self.single.base.attached_widget = target;
        GestureBase.attachAsController(
            @ptrCast(@alignCast(self)),
            target,
            self.single.base.allocator,
            Self,
            handleEvent,
            tick,
            "GestureStable",
        );
    }

    pub fn getWidget(self: *const Self) ?*Widget {
        return self.single.base.getWidget();
    }

    fn nowMs() u64 {
        return perf.nowMs();
    }

    /// EventController.tick：每帧检查是否达到稳定阈值
    pub fn tick(self: *Self, _delta_ms: u32) void {
        _ = _delta_ms;
        if (!self.pressing or self.triggered or self.stable) return;
        const elapsed = nowMs() - self.press_time_ms;
        if (elapsed >= self.stability_threshold_ms) {
            self.stable = true;
            self.triggered = true;
            if (self.on_stable) |cb| cb(self, self.press_x, self.press_y);
        }
    }

    pub fn handleEvent(self: *Self, _widget: *Widget, event: *const pal.Event, _ectx: *EventContext) EventResult {
        _ = _widget;
        _ = _ectx;
        switch (event.*) {
            .mouse_button => |mb| {
                if (mb.button != self.single.button) return .ignored;
                const x = @as(f32, @floatFromInt(mb.x));
                const y = @as(f32, @floatFromInt(mb.y));
                if (mb.state == .pressed) {
                    self.press_x = x;
                    self.press_y = y;
                    self.press_time_ms = nowMs();
                    self.pressing = true;
                    self.stable = false;
                    self.triggered = false;
                    self.single.base.is_active = true;
                    return .handled;
                } else {
                    if (self.pressing) {
                        self.pressing = false;
                        self.single.base.is_active = false;
                        if (!self.triggered) {
                            if (self.on_unstable) |cb| cb(self);
                        }
                        self.triggered = false;
                        self.stable = false;
                        return .handled;
                    }
                }
            },
            .mouse_move => |mm| {
                if (!self.pressing or self.triggered) return .ignored;
                const x = @as(f32, @floatFromInt(mm.x));
                const y = @as(f32, @floatFromInt(mm.y));
                const dx = x - self.press_x;
                const dy = y - self.press_y;
                if (dx * dx + dy * dy > self.move_tolerance * self.move_tolerance) {
                    self.pressing = false;
                    self.single.base.is_active = false;
                    if (self.on_unstable) |cb| cb(self);
                }
                return .handled;
            },
            else => {},
        }
        return .ignored;
    }
};

// ────────────────────────────────────────────────────────────────────────────
// GesturePan -- 方向拖拽识别 (GTK4: GtkGesturePan)
// 继承 GestureDrag 语义：在拖拽基础上增加 orientation 约束和方向回调
// ────────────────────────────────────────────────────────────────────────────

pub const PanDirection = enum {
    left,
    right,
    up,
    down,
};

pub const GesturePan = struct {
    single: GestureSingle,
    orientation: enum { horizontal, vertical },
    drag_threshold: f32 = 8.0,

    start_x: f32 = 0,
    start_y: f32 = 0,
    last_x: f32 = 0,
    last_y: f32 = 0,
    dragging: bool = false,
    had_drag_start: bool = false,

    on_pan: ?*const fn (self: *GesturePan, direction: PanDirection, offset: f32) void = null,
    on_drag_begin: ?*const fn (self: *GesturePan, start_x: f32, start_y: f32) void = null,
    on_drag_end: ?*const fn (self: *GesturePan, offset: f32) void = null,

    const Self = @This();

    pub fn create(allocator: std.mem.Allocator, opts: struct {
        orientation: enum { horizontal, vertical } = .horizontal,
        button: pal.MouseButton = .left,
        drag_threshold: f32 = 8.0,
        on_pan: ?*const fn (self: *GesturePan, direction: PanDirection, offset: f32) void = null,
        on_drag_begin: ?*const fn (self: *GesturePan, start_x: f32, start_y: f32) void = null,
        on_drag_end: ?*const fn (self: *GesturePan, offset: f32) void = null,
    }) !*GesturePan {
        const self = try allocator.create(GesturePan);
        self.* = .{
            .single = GestureSingle.init(allocator, opts.button),
            .orientation = opts.orientation,
            .drag_threshold = opts.drag_threshold,
            .on_pan = opts.on_pan,
            .on_drag_begin = opts.on_drag_begin,
            .on_drag_end = opts.on_drag_end,
        };
        return self;
    }

    pub fn destroy(self: *Self, allocator: std.mem.Allocator) void {
        if (self.single.base.attached_widget) |w| w.removeEventController(@ptrCast(@alignCast(self)));
        self.single.base.deinit();
        allocator.destroy(self);
    }

    pub fn attach(self: *Self, target: *Widget) void {
        self.single.base.attached_widget = target;
        GestureBase.attachAsController(
            @ptrCast(@alignCast(self)),
            target,
            self.single.base.allocator,
            Self,
            handleEvent,
            null,
            "GesturePan",
        );
    }

    pub fn getWidget(self: *const Self) ?*Widget {
        return self.single.base.getWidget();
    }

    pub fn getOrientation(self: *const Self) enum { horizontal, vertical } {
        return self.orientation;
    }

    pub fn setOrientation(self: *Self, o: enum { horizontal, vertical }) void {
        self.orientation = o;
    }

    fn emitPan(self: *Self, dx: f32, dy: f32) void {
        if (self.on_pan == null) return;
        if (self.orientation == .horizontal) {
            const offset = @as(f32, @floatCast(self.last_x - self.start_x));
            _ = dx;
            const dir: PanDirection = if (offset >= 0) .right else .left;
            if (@abs(offset) >= self.drag_threshold) {
                self.on_pan.?(self, dir, @abs(offset));
            }
        } else {
            const offset = @as(f32, @floatCast(self.last_y - self.start_y));
            _ = dy;
            const dir: PanDirection = if (offset >= 0) .down else .up;
            if (@abs(offset) >= self.drag_threshold) {
                self.on_pan.?(self, dir, @abs(offset));
            }
        }
    }

    pub fn handleEvent(self: *Self, _widget: *Widget, event: *const pal.Event, _ectx: *EventContext) EventResult {
        _ = _widget;
        _ = _ectx;
        switch (event.*) {
            .mouse_button => |mb| {
                if (mb.button != self.single.button) return .ignored;
                const x = @as(f32, @floatFromInt(mb.x));
                const y = @as(f32, @floatFromInt(mb.y));
                if (mb.state == .pressed) {
                    self.start_x = x;
                    self.start_y = y;
                    self.last_x = x;
                    self.last_y = y;
                    self.dragging = true;
                    self.had_drag_start = true;
                    self.single.base.is_active = true;
                    if (self.on_drag_begin) |cb| cb(self, x, y);
                    return .handled;
                } else {
                    if (self.dragging) {
                        self.dragging = false;
                        self.single.base.is_active = false;
                        if (self.on_drag_end) |cb| {
                            if (self.orientation == .horizontal) {
                                cb(self, @abs(self.last_x - self.start_x));
                            } else {
                                cb(self, @abs(self.last_y - self.start_y));
                            }
                        }
                        return .handled;
                    }
                }
            },
            .mouse_move => |mm| {
                if (!self.dragging) return .ignored;
                self.last_x = @as(f32, @floatFromInt(mm.x));
                self.last_y = @as(f32, @floatFromInt(mm.y));
                self.emitPan(self.last_x - self.start_x, self.last_y - self.start_y);
                return .handled;
            },
            else => {},
        }
        return .ignored;
    }
};

// ────────────────────────────────────────────────────────────────────────────
// GestureSwipe -- 快速滑动识别 (GTK4: GtkGestureSwipe)
// 按下时记录位置和时间，释放时计算速度，超过阈值触发 on_swipe
// ────────────────────────────────────────────────────────────────────────────

pub const GestureSwipe = struct {
    single: GestureSingle,
    /// 速度阈值 (px/ms)，默认 1.0
    velocity_threshold: f32 = 1.0,

    start_x: f32 = 0,
    start_y: f32 = 0,
    start_time_ms: u64 = 0,
    pressing: bool = false,

    on_swipe: ?*const fn (self: *GestureSwipe, velocity_x: f32, velocity_y: f32) void = null,

    const Self = @This();

    pub fn create(allocator: std.mem.Allocator, opts: struct {
        button: pal.MouseButton = .left,
        velocity_threshold: f32 = 1.0,
        on_swipe: ?*const fn (self: *GestureSwipe, velocity_x: f32, velocity_y: f32) void = null,
    }) !*GestureSwipe {
        const self = try allocator.create(GestureSwipe);
        self.* = .{
            .single = GestureSingle.init(allocator, opts.button),
            .velocity_threshold = opts.velocity_threshold,
            .on_swipe = opts.on_swipe,
        };
        return self;
    }

    pub fn destroy(self: *Self, allocator: std.mem.Allocator) void {
        if (self.single.base.attached_widget) |w| w.removeEventController(@ptrCast(@alignCast(self)));
        self.single.base.deinit();
        allocator.destroy(self);
    }

    pub fn attach(self: *Self, target: *Widget) void {
        self.single.base.attached_widget = target;
        GestureBase.attachAsController(
            @ptrCast(@alignCast(self)),
            target,
            self.single.base.allocator,
            Self,
            handleEvent,
            null,
            "GestureSwipe",
        );
    }

    pub fn getWidget(self: *const Self) ?*Widget {
        return self.single.base.getWidget();
    }

    fn nowMs() u64 {
        return perf.nowMs();
    }

    pub fn handleEvent(self: *Self, _widget: *Widget, event: *const pal.Event, _ectx: *EventContext) EventResult {
        _ = _widget;
        _ = _ectx;
        switch (event.*) {
            .mouse_button => |mb| {
                if (mb.button != self.single.button) return .ignored;
                if (mb.state == .pressed) {
                    self.start_x = @as(f32, @floatFromInt(mb.x));
                    self.start_y = @as(f32, @floatFromInt(mb.y));
                    self.start_time_ms = nowMs();
                    self.pressing = true;
                    self.single.base.is_active = true;
                    return .handled;
                } else {
                    if (self.pressing) {
                        self.pressing = false;
                        self.single.base.is_active = false;
                        const end_x = @as(f32, @floatFromInt(mb.x));
                        const end_y = @as(f32, @floatFromInt(mb.y));
                        const dt = nowMs() - self.start_time_ms;
                        if (dt > 0) {
                            const vx = (end_x - self.start_x) / @as(f32, @floatFromInt(dt));
                            const vy = (end_y - self.start_y) / @as(f32, @floatFromInt(dt));
                            const speed = @sqrt(vx * vx + vy * vy);
                            if (speed >= self.velocity_threshold) {
                                if (self.on_swipe) |cb| cb(self, vx, vy);
                            }
                        }
                        return .handled;
                    }
                }
            },
            else => {},
        }
        return .ignored;
    }
};

// ────────────────────────────────────────────────────────────────────────────
// GestureRotate -- 双指旋转识别 (GTK4: GtkGestureRotate)
// 跟踪两个触点，计算角度差并触发 on_rotate
// ────────────────────────────────────────────────────────────────────────────

pub const GestureRotate = struct {
    base: GestureBase,
    initial_angle: f32 = 0,
    current_angle: f32 = 0,
    angle_delta: f32 = 0,

    points: [2]?struct { id: u32, x: f32, y: f32 } = .{ null, null },

    on_begin: ?*const fn (self: *GestureRotate, angle: f32) void = null,
    on_rotate: ?*const fn (self: *GestureRotate, angle_delta: f32, absolute_angle: f32) void = null,
    on_end: ?*const fn (self: *GestureRotate, angle_delta: f32) void = null,

    const Self = @This();

    pub fn create(allocator: std.mem.Allocator, opts: struct {
        on_begin: ?*const fn (self: *GestureRotate, angle: f32) void = null,
        on_rotate: ?*const fn (self: *GestureRotate, angle_delta: f32, absolute_angle: f32) void = null,
        on_end: ?*const fn (self: *GestureRotate, angle_delta: f32) void = null,
    }) !*GestureRotate {
        const self = try allocator.create(GestureRotate);
        self.* = .{
            .base = GestureBase.init(allocator, 2),
            .on_begin = opts.on_begin,
            .on_rotate = opts.on_rotate,
            .on_end = opts.on_end,
        };
        return self;
    }

    pub fn destroy(self: *Self, allocator: std.mem.Allocator) void {
        if (self.base.attached_widget) |w| w.removeEventController(@ptrCast(@alignCast(self)));
        self.base.deinit();
        allocator.destroy(self);
    }

    pub fn attach(self: *Self, target: *Widget) void {
        self.base.attached_widget = target;
        GestureBase.attachAsController(
            @ptrCast(@alignCast(self)),
            target,
            self.base.allocator,
            Self,
            handleEvent,
            null,
            "GestureRotate",
        );
    }

    pub fn getWidget(self: *const Self) ?*Widget {
        return self.base.getWidget();
    }

    pub fn getAngleDelta(self: *const Self) f32 {
        return self.angle_delta;
    }

    fn findPointSlot(self: *Self, id: u32) ?usize {
        for (self.points, 0..) |p, i| {
            if (p) |pp| if (pp.id == id) return i;
        }
        return null;
    }

    fn allocPointSlot(self: *Self) ?usize {
        for (self.points, 0..) |p, i| {
            if (p == null) return i;
        }
        return null;
    }

    fn angleBetween(self: *Self) f32 {
        const p0 = self.points[0] orelse return 0;
        const p1 = self.points[1] orelse return 0;
        const dx = p1.x - p0.x;
        const dy = p1.y - p0.y;
        return std.math.atan2(dy, dx);
    }

    pub fn handleEvent(self: *Self, _widget: *Widget, event: *const pal.Event, _ectx: *EventContext) EventResult {
        _ = _widget;
        _ = _ectx;
        switch (event.*) {
            .mouse_button => |mb| {
                const id: u32 = if (mb.button == .left) 1 else if (mb.button == .right) 2 else 0;
                if (id == 0) return .ignored;
                const x = @as(f32, @floatFromInt(mb.x));
                const y = @as(f32, @floatFromInt(mb.y));

                if (mb.state == .pressed) {
                    if (self.findPointSlot(id) == null) {
                        const slot = self.allocPointSlot() orelse return .ignored;
                        self.points[slot] = .{ .id = id, .x = x, .y = y };
                        if (self.points[0] != null and self.points[1] != null) {
                            self.initial_angle = self.angleBetween();
                            self.current_angle = self.initial_angle;
                            self.angle_delta = 0;
                            self.base.is_active = true;
                            if (self.on_begin) |cb| cb(self, self.initial_angle);
                        }
                    }
                    return .handled;
                } else {
                    if (self.findPointSlot(id)) |slot| {
                        self.points[slot] = null;
                        if (self.base.is_active) {
                            self.base.is_active = false;
                            if (self.on_end) |cb| cb(self, self.angle_delta);
                            self.initial_angle = 0;
                            self.angle_delta = 0;
                        }
                        return .handled;
                    }
                }
            },
            .mouse_move => |mm| {
                if (!self.base.is_active) return .ignored;
                const x = @as(f32, @floatFromInt(mm.x));
                const y = @as(f32, @floatFromInt(mm.y));
                var updated = false;
                for (&self.points) |*p| {
                    if (p.*) |pp| {
                        p.* = .{ .id = pp.id, .x = x, .y = y };
                        updated = true;
                        break;
                    }
                }
                if (updated) {
                    const new_angle = self.angleBetween();
                    const delta = new_angle - self.current_angle;
                    self.angle_delta += delta;
                    self.current_angle = new_angle;
                    if (self.on_rotate) |cb| cb(self, self.angle_delta, self.current_angle);
                    return .handled;
                }
            },
            else => {},
        }
        return .ignored;
    }
};

// ────────────────────────────────────────────────────────────────────────────
// GestureDrag —— 拖拽识别 (GTK4: GtkGestureDrag)
// ────────────────────────────────────────────────────────────────────────────

pub const GestureDrag = struct {
    single: GestureSingle,
    drag_threshold: f32 = 8.0,

    start_x: f32 = 0,
    start_y: f32 = 0,
    last_x: f32 = 0,
    last_y: f32 = 0,
    dragging: bool = false,
    had_drag_start: bool = false,

    on_drag_begin: ?*const fn (self: *GestureDrag, start_x: f32, start_y: f32) void = null,
    on_drag_update: ?*const fn (self: *GestureDrag, offset_x: f32, offset_y: f32) void = null,
    on_drag_end: ?*const fn (self: *GestureDrag, offset_x: f32, offset_y: f32) void = null,

    const Self = @This();

    pub fn create(allocator: std.mem.Allocator, opts: struct {
        button: pal.MouseButton = .left,
        drag_threshold: f32 = 8.0,
        on_drag_begin: ?*const fn (self: *GestureDrag, start_x: f32, start_y: f32) void = null,
        on_drag_update: ?*const fn (self: *GestureDrag, offset_x: f32, offset_y: f32) void = null,
        on_drag_end: ?*const fn (self: *GestureDrag, offset_x: f32, offset_y: f32) void = null,
    }) !*GestureDrag {
        const self = try allocator.create(GestureDrag);
        self.* = .{
            .single = GestureSingle.init(allocator, opts.button),
            .drag_threshold = opts.drag_threshold,
            .on_drag_begin = opts.on_drag_begin,
            .on_drag_update = opts.on_drag_update,
            .on_drag_end = opts.on_drag_end,
        };
        return self;
    }

    pub fn destroy(self: *Self, allocator: std.mem.Allocator) void {
        if (self.single.base.attached_widget) |w| w.removeEventController(@ptrCast(@alignCast(self)));
        self.single.base.deinit();
        allocator.destroy(self);
    }

    pub fn attach(self: *Self, target: *Widget) void {
        self.single.base.attached_widget = target;
        GestureBase.attachAsController(
            @ptrCast(@alignCast(self)),
            target,
            self.single.base.allocator,
            Self,
            handleEvent,
            null,
            "GestureDrag",
        );
    }

    pub fn getWidget(self: *const Self) ?*Widget {
        return self.single.base.getWidget();
    }

    pub fn getStartPoint(self: *const Self) ?struct { x: f32, y: f32 } {
        if (!self.dragging and !self.had_drag_start) return null;
        return .{ .x = self.start_x, .y = self.start_y };
    }

    pub fn getOffset(self: *const Self) ?struct { dx: f32, dy: f32 } {
        if (!self.dragging) return null;
        return .{ .dx = self.last_x - self.start_x, .dy = self.last_y - self.start_y };
    }

    pub fn handleEvent(self: *Self, _widget: *Widget, event: *const pal.Event, _ectx: *EventContext) EventResult {
        _ = _widget;
        _ = _ectx;
        switch (event.*) {
            .mouse_button => |mb| {
                if (mb.button != self.single.button) return .ignored;
                const x = @as(f32, @floatFromInt(mb.x));
                const y = @as(f32, @floatFromInt(mb.y));

                if (mb.state == .pressed) {
                    self.start_x = x;
                    self.start_y = y;
                    self.last_x = x;
                    self.last_y = y;
                    self.dragging = false;
                    self.had_drag_start = false;
                    self.single.base.is_active = true;
                    return .handled;
                } else {
                    if (self.single.base.is_active) {
                        self.single.base.is_active = false;
                        if (self.dragging) {
                            self.dragging = false;
                            if (self.on_drag_end) |cb| cb(self, self.last_x - self.start_x, self.last_y - self.start_y);
                        }
                        return .handled;
                    }
                }
            },
            .mouse_move => |mm| {
                if (!self.single.base.is_active) return .ignored;
                const x = @as(f32, @floatFromInt(mm.x));
                const y = @as(f32, @floatFromInt(mm.y));
                self.last_x = x;
                self.last_y = y;

                if (!self.dragging) {
                    const dx = x - self.start_x;
                    const dy = y - self.start_y;
                    if (dx * dx + dy * dy >= self.drag_threshold * self.drag_threshold) {
                        self.dragging = true;
                        self.had_drag_start = true;
                        if (self.on_drag_begin) |cb| cb(self, self.start_x, self.start_y);
                    }
                }
                if (self.dragging) {
                    if (self.on_drag_update) |cb| cb(self, x - self.start_x, y - self.start_y);
                    return .handled;
                }
            },
            else => {},
        }
        return .ignored;
    }
};

// ────────────────────────────────────────────────────────────────────────────
// GestureLongPress —— 长按识别 (GTK4: GtkGestureLongPress)
// ────────────────────────────────────────────────────────────────────────────

pub const GestureLongPress = struct {
    single: GestureSingle,
    delay_ms: u32 = 500,
    move_tolerance: f32 = 10.0,

    press_x: f32 = 0,
    press_y: f32 = 0,
    press_time_ms: u64 = 0,
    pressing: bool = false,
    triggered: bool = false,

    on_pressed: ?*const fn (self: *GestureLongPress, x: f32, y: f32) void = null,
    on_cancelled: ?*const fn (self: *GestureLongPress) void = null,

    const Self = @This();

    pub fn create(allocator: std.mem.Allocator, opts: struct {
        button: pal.MouseButton = .left,
        delay_ms: u32 = 500,
        move_tolerance: f32 = 10.0,
        on_pressed: ?*const fn (self: *GestureLongPress, x: f32, y: f32) void = null,
        on_cancelled: ?*const fn (self: *GestureLongPress) void = null,
    }) !*GestureLongPress {
        const self = try allocator.create(GestureLongPress);
        self.* = .{
            .single = GestureSingle.init(allocator, opts.button),
            .delay_ms = opts.delay_ms,
            .move_tolerance = opts.move_tolerance,
            .on_pressed = opts.on_pressed,
            .on_cancelled = opts.on_cancelled,
        };
        return self;
    }

    pub fn destroy(self: *Self, allocator: std.mem.Allocator) void {
        if (self.single.base.attached_widget) |w| w.removeEventController(@ptrCast(@alignCast(self)));
        self.single.base.deinit();
        allocator.destroy(self);
    }

    pub fn attach(self: *Self, target: *Widget) void {
        self.single.base.attached_widget = target;
        GestureBase.attachAsController(
            @ptrCast(@alignCast(self)),
            target,
            self.single.base.allocator,
            Self,
            handleEvent,
            tick,
            "GestureLongPress",
        );
    }

    pub fn getWidget(self: *const Self) ?*Widget {
        return self.single.base.getWidget();
    }

    fn nowMs() u64 {
        return perf.nowMs();
    }

    /// EventController.tick 接口：每帧检查是否超时触发长按
    pub fn tick(self: *Self, _delta_ms: u32) void {
        _ = _delta_ms;
        if (!self.pressing or self.triggered) return;
        const t = nowMs();
        if (t - self.press_time_ms >= self.delay_ms) {
            self.triggered = true;
            if (self.on_pressed) |cb| cb(self, self.press_x, self.press_y);
        }
    }

    pub fn handleEvent(self: *Self, _widget: *Widget, event: *const pal.Event, _ectx: *EventContext) EventResult {
        _ = _widget;
        _ = _ectx;
        switch (event.*) {
            .mouse_button => |mb| {
                if (mb.button != self.single.button) return .ignored;
                const x = @as(f32, @floatFromInt(mb.x));
                const y = @as(f32, @floatFromInt(mb.y));

                if (mb.state == .pressed) {
                    self.press_x = x;
                    self.press_y = y;
                    self.press_time_ms = nowMs();
                    self.pressing = true;
                    self.triggered = false;
                    self.single.base.is_active = true;
                    return .handled;
                } else {
                    if (self.pressing) {
                        self.pressing = false;
                        self.single.base.is_active = false;
                        if (!self.triggered) {
                            if (self.on_cancelled) |cb| cb(self);
                        }
                        self.triggered = false;
                        return .handled;
                    }
                }
            },
            .mouse_move => |mm| {
                if (!self.pressing or self.triggered) return .ignored;
                const x = @as(f32, @floatFromInt(mm.x));
                const y = @as(f32, @floatFromInt(mm.y));
                const dx = x - self.press_x;
                const dy = y - self.press_y;
                if (dx * dx + dy * dy > self.move_tolerance * self.move_tolerance) {
                    self.pressing = false;
                    self.single.base.is_active = false;
                    if (self.on_cancelled) |cb| cb(self);
                }
                return .handled;
            },
            else => {},
        }
        return .ignored;
    }
};

// ────────────────────────────────────────────────────────────────────────────
// GestureZoom —— 双指缩放识别 (GTK4: GtkGestureZoom)
// ────────────────────────────────────────────────────────────────────────────

pub const GestureZoom = struct {
    base: GestureBase,
    initial_distance: f32 = 0,
    current_distance: f32 = 0,
    scale: f32 = 1.0,
    center_x: f32 = 0,
    center_y: f32 = 0,

    points: [2]?struct { id: u32, x: f32, y: f32 } = .{ null, null },

    on_scale_changed: ?*const fn (self: *GestureZoom, scale: f32) void = null,
    on_begin: ?*const fn (self: *GestureZoom, x: f32, y: f32) void = null,
    on_end: ?*const fn (self: *GestureZoom, scale: f32) void = null,

    const Self = @This();

    pub fn create(allocator: std.mem.Allocator, opts: struct {
        on_scale_changed: ?*const fn (self: *GestureZoom, scale: f32) void = null,
        on_begin: ?*const fn (self: *GestureZoom, x: f32, y: f32) void = null,
        on_end: ?*const fn (self: *GestureZoom, scale: f32) void = null,
    }) !*GestureZoom {
        const self = try allocator.create(GestureZoom);
        self.* = .{
            .base = GestureBase.init(allocator, 2),
            .on_scale_changed = opts.on_scale_changed,
            .on_begin = opts.on_begin,
            .on_end = opts.on_end,
        };
        return self;
    }

    pub fn destroy(self: *Self, allocator: std.mem.Allocator) void {
        if (self.base.attached_widget) |w| w.removeEventController(@ptrCast(@alignCast(self)));
        self.base.deinit();
        allocator.destroy(self);
    }

    pub fn attach(self: *Self, target: *Widget) void {
        self.base.attached_widget = target;
        GestureBase.attachAsController(
            @ptrCast(@alignCast(self)),
            target,
            self.base.allocator,
            Self,
            handleEvent,
            null,
            "GestureZoom",
        );
    }

    pub fn getWidget(self: *const Self) ?*Widget {
        return self.base.getWidget();
    }

    pub fn getScaleDelta(self: *const Self) f32 {
        return self.scale;
    }

    fn findPointSlot(self: *Self, id: u32) ?usize {
        for (self.points, 0..) |p, i| {
            if (p) |pp| if (pp.id == id) return i;
        }
        return null;
    }

    fn allocPointSlot(self: *Self) ?usize {
        for (self.points, 0..) |p, i| {
            if (p == null) return i;
        }
        return null;
    }

    fn updateDistanceAndScale(self: *Self) void {
        const p0 = self.points[0] orelse return;
        const p1 = self.points[1] orelse return;
        const dx = p1.x - p0.x;
        const dy = p1.y - p0.y;
        const dist = @sqrt(dx * dx + dy * dy);
        self.current_distance = dist;
        self.center_x = (p0.x + p1.x) * 0.5;
        self.center_y = (p0.y + p1.y) * 0.5;
        if (self.initial_distance > 0) {
            self.scale = dist / self.initial_distance;
        }
    }

    pub fn handleEvent(self: *Self, _widget: *Widget, event: *const pal.Event, _ectx: *EventContext) EventResult {
        _ = _widget;
        _ = _ectx;
        switch (event.*) {
            .mouse_button => |mb| {
                const id: u32 = if (mb.button == .left) 1 else if (mb.button == .right) 2 else 0;
                if (id == 0) return .ignored;
                const x = @as(f32, @floatFromInt(mb.x));
                const y = @as(f32, @floatFromInt(mb.y));

                if (mb.state == .pressed) {
                    if (self.findPointSlot(id) == null) {
                        const slot = self.allocPointSlot() orelse return .ignored;
                        self.points[slot] = .{ .id = id, .x = x, .y = y };
                        if (self.points[0] != null and self.points[1] != null) {
                            self.updateDistanceAndScale();
                            self.initial_distance = self.current_distance;
                            self.scale = 1.0;
                            self.base.is_active = true;
                            if (self.on_begin) |cb| cb(self, self.center_x, self.center_y);
                        }
                    }
                    return .handled;
                } else {
                    if (self.findPointSlot(id)) |slot| {
                        self.points[slot] = null;
                        if (self.base.is_active) {
                            self.base.is_active = false;
                            if (self.on_end) |cb| cb(self, self.scale);
                            self.initial_distance = 0;
                            self.scale = 1.0;
                        }
                        return .handled;
                    }
                }
            },
            .mouse_move => |mm| {
                if (!self.base.is_active) return .ignored;
                const x = @as(f32, @floatFromInt(mm.x));
                const y = @as(f32, @floatFromInt(mm.y));
                var updated = false;
                for (&self.points) |*p| {
                    if (p.*) |pp| {
                        p.* = .{ .id = pp.id, .x = x, .y = y };
                        updated = true;
                        break;
                    }
                }
                if (updated) {
                    self.updateDistanceAndScale();
                    if (self.on_scale_changed) |cb| cb(self, self.scale);
                    return .handled;
                }
            },
            else => {},
        }
        return .ignored;
    }
};
