//! EventController 家族 — 焦点/鼠标移动/滚动事件控制器
//!
//! GTK 对应: GtkEventControllerFocus / GtkEventControllerMotion / GtkEventControllerScroll
//!
//! 用法:
//! ```
//! var fc = try EventControllerFocus.create(allocator, .{
//!     .on_enter = onFocusEnter, .on_leave = onFocusLeave,
//! });
//! fc.attachTo(&widget.base);
//! ```

const std = @import("std");
const math = @import("../math.zig");
const widget_mod = @import("widget.zig");
const pal = @import("../pal/pal.zig");

const Widget = widget_mod.Widget;
const EventContext = widget_mod.EventContext;
const EventResult = widget_mod.EventResult;
const EventController = widget_mod.EventController;

// ──────────────────────────────────────────────────────────────────────────────
// EventControllerFocus
// ──────────────────────────────────────────────────────────────────────────────

pub const EventControllerFocus = struct {
    allocator: std.mem.Allocator,
    on_enter: ?*const fn (self: *EventControllerFocus, target: *Widget) void = null,
    on_leave: ?*const fn (self: *EventControllerFocus, target: *Widget) void = null,
    is_focused: bool = false,
    attached: ?*Widget = null,
    ctrl: ?EventController = null,

    const Self = @This();

    pub fn create(allocator: std.mem.Allocator, opts: struct {
        on_enter: ?*const fn (self: *EventControllerFocus, target: *Widget) void = null,
        on_leave: ?*const fn (self: *EventControllerFocus, target: *Widget) void = null,
    }) !*EventControllerFocus {
        const self = try allocator.create(EventControllerFocus);
        self.* = .{
            .allocator = allocator,
            .on_enter = opts.on_enter,
            .on_leave = opts.on_leave,
        };
        return self;
    }

    pub fn destroy(self: *Self) void {
        self.detach();
        self.allocator.destroy(self);
    }

    pub fn attachTo(self: *Self, widget: *Widget) void {
        self.detach();
        self.attached = widget;
        const c = EventController.wrap(Self, self, handleEvent, null, "EventControllerFocus");
        if (widget.addEventController(self.allocator, c)) {
            self.ctrl = c;
        } else |_| self.ctrl = null;
    }

    pub fn detach(self: *Self) void {
        if (self.attached) |w| {
            if (self.ctrl) |c| w.removeEventController(c);
        }
        self.attached = null;
        self.ctrl = null;
    }

    fn handleEvent(self: *Self, widget: *Widget, event: *const pal.Event, _ectx: *EventContext) EventResult {
        _ = _ectx;
        switch (event.*) {
            .focus => |f| {
                if (f.enter and !self.is_focused) {
                    self.is_focused = true;
                    if (self.on_enter) |cb| cb(self, widget);
                } else if (!f.enter and self.is_focused) {
                    self.is_focused = false;
                    if (self.on_leave) |cb| cb(self, widget);
                }
                return .pass;
            },
            else => return .pass,
        }
    }
};

// ──────────────────────────────────────────────────────────────────────────────
// EventControllerPad (GTK4: GtkEventControllerPad)
// 游戏手柄事件控制器：按钮按下/释放/摇杆移动
// ──────────────────────────────────────────────────────────────────────────────

pub const EventControllerPad = struct {
    allocator: std.mem.Allocator,
    on_button_pressed: ?*const fn (
        self: *EventControllerPad,
        target: *Widget,
        button: u32,
        axis_value: f32,
    ) EventResult = null,
    on_button_released: ?*const fn (
        self: *EventControllerPad,
        target: *Widget,
        button: u32,
    ) void = null,
    on_axis: ?*const fn (
        self: *EventControllerPad,
        target: *Widget,
        axis: u32,
        value: f32,
    ) void = null,

    attached: ?*Widget = null,
    ctrl: ?EventController = null,

    const Self = @This();

    pub fn create(allocator: std.mem.Allocator, opts: struct {
        on_button_pressed: ?*const fn (
            self: *EventControllerPad,
            target: *Widget,
            button: u32,
            axis_value: f32,
        ) EventResult = null,
        on_button_released: ?*const fn (
            self: *EventControllerPad,
            target: *Widget,
            button: u32,
        ) void = null,
        on_axis: ?*const fn (
            self: *EventControllerPad,
            target: *Widget,
            axis: u32,
            value: f32,
        ) void = null,
    }) !*EventControllerPad {
        const self = try allocator.create(EventControllerPad);
        self.* = .{
            .allocator = allocator,
            .on_button_pressed = opts.on_button_pressed,
            .on_button_released = opts.on_button_released,
            .on_axis = opts.on_axis,
        };
        return self;
    }

    pub fn destroy(self: *Self) void {
        self.detach();
        self.allocator.destroy(self);
    }

    pub fn attachTo(self: *Self, widget: *Widget) void {
        self.detach();
        self.attached = widget;
        const c = EventController.wrap(Self, self, handleEvent, null, "EventControllerPad");
        if (widget.addEventController(self.allocator, c)) self.ctrl = c else |_| self.ctrl = null;
    }

    pub fn detach(self: *Self) void {
        if (self.attached) |w| {
            if (self.ctrl) |c| w.removeEventController(c);
        }
        self.attached = null;
        self.ctrl = null;
    }

    fn handleEvent(self: *Self, widget: *Widget, event: *const pal.Event, _ectx: *EventContext) EventResult {
        _ = _ectx;
        // 手柄事件目前通过 mouse_button（按钮）和 scroll（摇杆）模拟
        switch (event.*) {
            .mouse_button => |mb| {
                // 将鼠标侧键映射为手柄按钮
                const pad_button: u32 = switch (mb.button) {
                    .extra1 => 0,
                    .extra2 => 1,
                    else => return .pass,
                };
                if (mb.state == .pressed) {
                    if (self.on_button_pressed) |cb| {
                        return cb(self, widget, pad_button, 0.0);
                    }
                } else {
                    if (self.on_button_released) |cb| cb(self, widget, pad_button);
                }
                return .pass;
            },
            .scroll => |s| {
                // 将滚轮映射为摇杆轴
                if (self.on_axis) |cb| {
                    const axis: u32 = if (s.axis == .vertical) 0 else 1;
                    cb(self, widget, axis, s.delta);
                }
                return .pass;
            },
            else => return .pass,
        }
    }
};

// ──────────────────────────────────────────────────────────────────────────────
// EventControllerLegacy (GTK4: GtkEventControllerLegacy)
// 遗留事件透传控制器：将所有事件原样转发给回调
// ──────────────────────────────────────────────────────────────────────────────

pub const EventControllerLegacy = struct {
    allocator: std.mem.Allocator,
    on_event: ?*const fn (
        self: *EventControllerLegacy,
        target: *Widget,
        event: *const pal.Event,
    ) EventResult = null,

    attached: ?*Widget = null,
    ctrl: ?EventController = null,

    const Self = @This();

    pub fn create(allocator: std.mem.Allocator, opts: struct {
        on_event: ?*const fn (
            self: *EventControllerLegacy,
            target: *Widget,
            event: *const pal.Event,
        ) EventResult = null,
    }) !*EventControllerLegacy {
        const self = try allocator.create(EventControllerLegacy);
        self.* = .{
            .allocator = allocator,
            .on_event = opts.on_event,
        };
        return self;
    }

    pub fn destroy(self: *Self) void {
        self.detach();
        self.allocator.destroy(self);
    }

    pub fn attachTo(self: *Self, widget: *Widget) void {
        self.detach();
        self.attached = widget;
        const c = EventController.wrap(Self, self, handleEvent, null, "EventControllerLegacy");
        if (widget.addEventController(self.allocator, c)) self.ctrl = c else |_| self.ctrl = null;
    }

    pub fn detach(self: *Self) void {
        if (self.attached) |w| {
            if (self.ctrl) |c| w.removeEventController(c);
        }
        self.attached = null;
        self.ctrl = null;
    }

    fn handleEvent(self: *Self, widget: *Widget, event: *const pal.Event, _ectx: *EventContext) EventResult {
        _ = _ectx;
        if (self.on_event) |cb| {
            return cb(self, widget, event);
        }
        return .pass;
    }
};

// ──────────────────────────────────────────────────────────────────────────────
// EventControllerMotion
// ──────────────────────────────────────────────────────────────────────────────

pub const EventControllerMotion = struct {
    allocator: std.mem.Allocator,
    on_enter: ?*const fn (self: *EventControllerMotion, x: f32, y: f32) void = null,
    on_leave: ?*const fn (self: *EventControllerMotion) void = null,
    on_motion: ?*const fn (self: *EventControllerMotion, x: f32, y: f32) void = null,
    is_inside: bool = false,
    last_x: f32 = 0,
    last_y: f32 = 0,
    attached: ?*Widget = null,
    ctrl: ?EventController = null,

    const Self = @This();

    pub fn create(allocator: std.mem.Allocator, opts: struct {
        on_enter: ?*const fn (self: *EventControllerMotion, x: f32, y: f32) void = null,
        on_leave: ?*const fn (self: *EventControllerMotion) void = null,
        on_motion: ?*const fn (self: *EventControllerMotion, x: f32, y: f32) void = null,
    }) !*EventControllerMotion {
        const self = try allocator.create(EventControllerMotion);
        self.* = .{
            .allocator = allocator,
            .on_enter = opts.on_enter,
            .on_leave = opts.on_leave,
            .on_motion = opts.on_motion,
        };
        return self;
    }

    pub fn destroy(self: *Self) void {
        self.detach();
        self.allocator.destroy(self);
    }

    pub fn attachTo(self: *Self, widget: *Widget) void {
        self.detach();
        self.attached = widget;
        const c = EventController.wrap(Self, self, handleEvent, null, "EventControllerMotion");
        if (widget.addEventController(self.allocator, c)) self.ctrl = c else |_| self.ctrl = null;
    }

    pub fn detach(self: *Self) void {
        if (self.attached) |w| {
            if (self.ctrl) |c| w.removeEventController(c);
        }
        self.attached = null;
        self.ctrl = null;
        if (self.is_inside) {
            self.is_inside = false;
            if (self.on_leave) |cb| cb(self);
        }
    }

    fn handleEvent(self: *Self, widget: *Widget, event: *const pal.Event, _ectx: *EventContext) EventResult {
        _ = _ectx;
        switch (event.*) {
            .mouse_motion => |m| {
                const alloc_rect = widget.allocation orelse return .pass;
                const lx = m.x - alloc_rect.x;
                const ly = m.y - alloc_rect.y;
                const inside = lx >= 0 and ly >= 0 and lx < alloc_rect.w and ly < alloc_rect.h;
                self.last_x = lx;
                self.last_y = ly;
                if (inside) {
                    if (!self.is_inside) {
                        self.is_inside = true;
                        if (self.on_enter) |cb| cb(self, lx, ly);
                    }
                    if (self.on_motion) |cb| cb(self, lx, ly);
                } else {
                    if (self.is_inside) {
                        self.is_inside = false;
                        if (self.on_leave) |cb| cb(self);
                    }
                }
                return .pass;
            },
            else => return .pass,
        }
    }
};

// ──────────────────────────────────────────────────────────────────────────────
// EventControllerScroll
// ──────────────────────────────────────────────────────────────────────────────

pub const EventControllerScrollFlags = packed struct(u8) {
    none: bool = false,
    vertical: bool = false,
    horizontal: bool = false,
    both: bool = false,
    discrete: bool = false,
    _pad: u3 = 0,
};

pub const EventControllerScroll = struct {
    allocator: std.mem.Allocator,
    flags: EventControllerScrollFlags = .{ .both = true },
    on_scroll: ?*const fn (self: *EventControllerScroll, dx: f32, dy: f32) EventResult = null,
    on_scroll_begin: ?*const fn (self: *EventControllerScroll) void = null,
    on_scroll_end: ?*const fn (self: *EventControllerScroll) void = null,
    scrolling: bool = false,
    attached: ?*Widget = null,
    ctrl: ?EventController = null,

    const Self = @This();

    pub fn create(allocator: std.mem.Allocator, opts: struct {
        flags: EventControllerScrollFlags = .{ .both = true },
        on_scroll: ?*const fn (self: *EventControllerScroll, dx: f32, dy: f32) EventResult = null,
        on_scroll_begin: ?*const fn (self: *EventControllerScroll) void = null,
        on_scroll_end: ?*const fn (self: *EventControllerScroll) void = null,
    }) !*EventControllerScroll {
        const self = try allocator.create(EventControllerScroll);
        self.* = .{
            .allocator = allocator,
            .flags = opts.flags,
            .on_scroll = opts.on_scroll,
            .on_scroll_begin = opts.on_scroll_begin,
            .on_scroll_end = opts.on_scroll_end,
        };
        return self;
    }

    pub fn destroy(self: *Self) void {
        self.detach();
        self.allocator.destroy(self);
    }

    pub fn attachTo(self: *Self, widget: *Widget) void {
        self.detach();
        self.attached = widget;
        const c = EventController.wrap(Self, self, handleEvent, null, "EventControllerScroll");
        if (widget.addEventController(self.allocator, c)) self.ctrl = c else |_| self.ctrl = null;
    }

    pub fn detach(self: *Self) void {
        if (self.attached) |w| {
            if (self.ctrl) |c| w.removeEventController(c);
        }
        self.attached = null;
        self.ctrl = null;
        if (self.scrolling) {
            self.scrolling = false;
            if (self.on_scroll_end) |cb| cb(self);
        }
    }

    fn handleEvent(self: *Self, _widget: *Widget, event: *const pal.Event, _ectx: *EventContext) EventResult {
        _ = _widget;
        _ = _ectx;
        switch (event.*) {
            .scroll => |s| {
                var dx = s.dx;
                var dy = s.dy;
                if (self.flags.vertical) dx = 0;
                if (self.flags.horizontal) dy = 0;
                if (!self.scrolling) {
                    self.scrolling = true;
                    if (self.on_scroll_begin) |cb| cb(self);
                }
                if (self.on_scroll) |cb| {
                    const r = cb(self, dx, dy);
                    if (r == .handled) return .handled;
                }
                return .pass;
            },
            else => return .pass,
        }
    }

    pub fn scrollEnd(self: *Self) void {
        if (self.scrolling) {
            self.scrolling = false;
            if (self.on_scroll_end) |cb| cb(self);
        }
    }
};

// ──────────────────────────────────────────────────────────────────────────────
// EventControllerKey (GTK4: GtkEventControllerKey)
// 键盘事件控制器：按下/释放/输入法更新
// ──────────────────────────────────────────────────────────────────────────────

pub const EventControllerKey = struct {
    allocator: std.mem.Allocator,
    on_key_pressed: ?*const fn (
        self: *EventControllerKey,
        target: *Widget,
        key: pal.KeyCode,
        modifiers: pal.Modifiers,
    ) EventResult = null,
    on_key_released: ?*const fn (
        self: *EventControllerKey,
        target: *Widget,
        key: pal.KeyCode,
        modifiers: pal.Modifiers,
    ) void = null,
    on_im_update: ?*const fn (self: *EventControllerKey, target: *Widget) void = null,

    attached: ?*Widget = null,
    ctrl: ?EventController = null,

    const Self = @This();

    pub fn create(allocator: std.mem.Allocator, opts: struct {
        on_key_pressed: ?*const fn (
            self: *EventControllerKey,
            target: *Widget,
            key: pal.KeyCode,
            modifiers: pal.Modifiers,
        ) EventResult = null,
        on_key_released: ?*const fn (
            self: *EventControllerKey,
            target: *Widget,
            key: pal.KeyCode,
            modifiers: pal.Modifiers,
        ) void = null,
        on_im_update: ?*const fn (self: *EventControllerKey, target: *Widget) void = null,
    }) !*EventControllerKey {
        const self = try allocator.create(EventControllerKey);
        self.* = .{
            .allocator = allocator,
            .on_key_pressed = opts.on_key_pressed,
            .on_key_released = opts.on_key_released,
            .on_im_update = opts.on_im_update,
        };
        return self;
    }

    pub fn destroy(self: *Self) void {
        self.detach();
        self.allocator.destroy(self);
    }

    pub fn attachTo(self: *Self, widget: *Widget) void {
        self.detach();
        self.attached = widget;
        const c = EventController.wrap(Self, self, handleEvent, null, "EventControllerKey");
        if (widget.addEventController(self.allocator, c)) self.ctrl = c else |_| self.ctrl = null;
    }

    pub fn detach(self: *Self) void {
        if (self.attached) |w| {
            if (self.ctrl) |c| w.removeEventController(c);
        }
        self.attached = null;
        self.ctrl = null;
    }

    fn handleEvent(self: *Self, widget: *Widget, event: *const pal.Event, _ectx: *EventContext) EventResult {
        _ = _ectx;
        switch (event.*) {
            .key => |k| {
                if (k.state == .pressed) {
                    if (self.on_key_pressed) |cb| {
                        return cb(self, widget, k.key, k.modifiers);
                    }
                } else {
                    if (self.on_key_released) |cb| cb(self, widget, k.key, k.modifiers);
                }
                return .pass;
            },
            .text_input => {
                if (self.on_im_update) |cb| cb(self, widget);
                return .pass;
            },
            else => return .pass,
        }
    }
};
