//! WindowHandle 控件 - GTK4 窗口拖动句柄
//!
//! 容器控件: 包装子控件后, 子控件中未被其自身捕获的区域
//! (即 "空白" 区域) 可用于拖动整个窗口。
//!
//! 与 WindowControls 配合可打造自定义 HeaderBar。
//!
//! GTK4 对应: GtkWindowHandle

const std = @import("std");
const perf = @import("../perf.zig");
const math = @import("../math.zig");
const widget_mod = @import("widget.zig");
const layout_mod = @import("../layout/engine.zig");
const pal = @import("../pal/pal.zig");

const Widget = widget_mod.Widget;
const PaintContext = widget_mod.PaintContext;
const EventContext = widget_mod.EventContext;
const EventResult = widget_mod.EventResult;
const Allocator = std.mem.Allocator;
const Event = pal.Event;

pub const WindowHandle = struct {
    base: Widget,
    allocator: Allocator,
    child: ?*Widget = null,

    dragging: bool = false,
    drag_start_x: f32 = 0,
    drag_start_y: f32 = 0,

    last_press_time: u64 = 0,

    on_begin_move_drag: ?*const fn (self: *WindowHandle, window_id: u32, root_x: f32, root_y: f32) void = null,
    on_toggle_maximized: ?*const fn (self: *WindowHandle, window_id: u32) void = null,

    pub fn new(allocator: Allocator) !*WindowHandle {
        const self = try allocator.create(WindowHandle);
        self.* = .{
            .base = .{
                .vtable = &vtable,
                .id = widget_mod.genWidgetId(),
            },
            .allocator = allocator,
        };
        self.base.accessibility = .{ .role = .container, .label = "Window Handle" };
        return self;
    }

    pub fn destroy(self: *WindowHandle, allocator: Allocator) void {
        self.base.background.deinit(allocator);
        self.base.children.deinit(allocator);
        allocator.destroy(self);
    }

    pub fn setChild(self: *WindowHandle, child: ?*Widget) void {
        self.child = child;
        self.base.children.deinit(self.allocator);
        if (child) |c| self.base.children.append(self.allocator, c) catch {};
        self.base.markLayoutDirty();
        self.base.markDirty();
    }

    pub fn getChild(self: *WindowHandle) ?*Widget {
        return self.child;
    }
};

const vtable = Widget.VTable{
    .type_name = "window_handle",
    .measure = measure,
    .paint = paint,
    .on_event = onEvent,
    .focusable = false,
    .destroy = destroyVTable,
};

fn destroyVTable(w: *Widget, allocator: Allocator) void {
    const self: *WindowHandle = @fieldParentPtr("base", w);
    self.destroy(allocator);
}

fn measure(w: *Widget, ctx: *PaintContext, constraints: layout_mod.Constraints) math.Size(f32) {
    const self: *WindowHandle = @fieldParentPtr("base", w);
    if (self.child) |c| {
        return c.vtable.measure(c, ctx, constraints);
    }
    return .{ .width = 0, .height = 0 };
}

fn paint(w: *Widget, ctx: *PaintContext) void {
    const self: *WindowHandle = @fieldParentPtr("base", w);
    // WindowHandle 本身不绘制任何视觉元素
    if (self.child) |c| {
        const rx = ctx.offset_x + w.rect.x;
        const ry = ctx.offset_y + w.rect.y;
        c.rect = .{ .x = 0, .y = 0, .width = w.rect.width, .height = w.rect.height };
        var child_ctx = ctx.*;
        child_ctx.offset_x = rx;
        child_ctx.offset_y = ry;
        c.paintTree(&child_ctx);
    }
}

fn onEvent(w: *Widget, event: *const Event, ectx: *EventContext) EventResult {
    const self: *WindowHandle = @fieldParentPtr("base", w);

    // 事件先传给 child
    if (self.child) |c| {
        const r = Widget.dispatchEvent(c, event, ectx);
        if (r == .handled) return .handled;
    }

    // child 未处理: 本控件接管
    switch (event.*) {
        .mouse_button => |mb| {
            if (mb.button == .left) {
                const mx: f32 = @floatFromInt(mb.x);
                const my: f32 = @floatFromInt(mb.y);
                if (mb.state == .pressed) {
                    const now_ts = @as(i64, @intCast(perf.nowMs()));
                    const now_u: u64 = @intCast(if (now_ts < 0) 0 else now_ts);
                    const double_click = (now_u - self.last_press_time) < 350;
                    self.last_press_time = now_u;

                    if (double_click) {
                        self.last_press_time = 0;
                        if (self.on_toggle_maximized) |cb| {
                            cb(self, mb.window_id);
                        }
                        return .handled;
                    }

                    self.dragging = true;
                    self.drag_start_x = mx;
                    self.drag_start_y = my;
                    if (self.on_begin_move_drag) |cb| {
                        cb(self, mb.window_id, mx, my);
                    }
                    return .handled;
                } else {
                    if (self.dragging) {
                        self.dragging = false;
                        return .handled;
                    }
                }
            }
        },
        .mouse_move => |m| {
            if (self.dragging) {
                _ = m;
                return .handled;
            }
        },
        else => {},
    }
    return .ignored;
}
