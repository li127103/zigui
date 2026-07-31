//! Paned 控件 - GTK4 可拖动分割面板
//!
//! 将区域分为两个可调整大小的窗格 (start / end), 中间为可拖拽的分割条。
//! 支持水平 (左右) 与垂直 (上下) 两种方向。
//!
//! GTK4 对应: GtkPaned
//!
//! 相比 SplitView 的特点:
//! - 使用 position (像素) 而不是 ratio (比例)
//! - 支持 min_position / max_position 像素级限制
//! - 支持 wide_handle 宽柄
//! - 支持 shrink / resize 控制子窗格行为

const std = @import("std");
const math = @import("../math.zig");
const widget_mod = @import("widget.zig");
const layout_mod = @import("../layout/engine.zig");
const pal = @import("../pal/pal.zig");
const icons_mod = @import("icons.zig");

const Widget = widget_mod.Widget;
const PaintContext = widget_mod.PaintContext;
const EventContext = widget_mod.EventContext;
const EventResult = widget_mod.EventResult;
const Allocator = std.mem.Allocator;
const Event = pal.Event;

const Self = @This();

pub const PanedOrientation = enum { horizontal, vertical };

pub const Paned = struct {
    base: Widget,
    allocator: Allocator,
    orientation: PanedOrientation,

    start_child: ?*Widget = null,
    end_child: ?*Widget = null,

    position: i32 = 0,
    min_position: i32 = 0,
    max_position: i32 = std.math.maxInt(i32),
    position_set: bool = false,

    resize_start_child: bool = true,
    shrink_start_child: bool = true,
    resize_end_child: bool = true,
    shrink_end_child: bool = true,

    wide_handle: bool = false,

    dragging: bool = false,
    hover_handle: bool = false,
    drag_start_pos: i32 = 0,
    drag_start_mouse: f32 = 0,

    on_position_changed: ?*const fn (self: *Paned, position: i32) void = null,

    bg_color: math.Color = math.Color.hex(0x0F172A00),
    divider_color: math.Color = math.Color.hex(0x334155FF),
    divider_hover_color: math.Color = math.Color.hex(0x3B82F6FF),
    divider_drag_color: math.Color = math.Color.hex(0x2563EBFF),
    grabber_color: math.Color = math.Color.hex(0x64748BFF),
    corner_radius: f32 = 0,

    const HANDLE_SIZE: f32 = 6;
    const WIDE_HANDLE_SIZE: f32 = 12;
    const MIN_CHILD_SIZE: f32 = 20;

    pub fn new(allocator: Allocator, orientation: PanedOrientation) !*Paned {
        const self = try allocator.create(Paned);
        self.* = .{
            .base = .{
                .vtable = &vtable,
                .id = widget_mod.genWidgetId(),
            },
            .allocator = allocator,
            .orientation = orientation,
        };
        self.base.accessibility = .{ .role = .container, .label = "Paned" };
        return self;
    }

    pub fn destroy(self: *Paned, allocator: Allocator) void {
        self.base.background.deinit(allocator);
        self.base.children.deinit(allocator);
        allocator.destroy(self);
    }

    pub fn setStartChild(self: *Paned, child: ?*Widget) void {
        self.start_child = child;
        self.base.children.deinit(self.allocator);
        if (self.start_child) |a| self.base.children.append(self.allocator, a) catch {};
        if (self.end_child) |b| self.base.children.append(self.allocator, b) catch {};
        self.base.markLayoutDirty();
        self.base.markDirty();
    }

    pub fn setEndChild(self: *Paned, child: ?*Widget) void {
        self.end_child = child;
        self.base.children.deinit(self.allocator);
        if (self.start_child) |a| self.base.children.append(self.allocator, a) catch {};
        if (self.end_child) |b| self.base.children.append(self.allocator, b) catch {};
        self.base.markLayoutDirty();
        self.base.markDirty();
    }

    pub fn setPosition(self: *Paned, position_obj: i32) void {
        const clamped = @max(self.min_position, @min(self.max_position, position_obj));
        if (clamped != self.position or !self.position_set) {
            self.position = clamped;
            self.position_set = true;
            self.base.markLayoutDirty();
            self.base.markDirty();
            if (self.on_position_changed) |cb| cb(self, self.position);
        }
    }

    pub fn getPosition(self: *Paned) i32 {
        return self.position;
    }

    pub fn setMinPosition(self: *Paned, min: i32) void {
        self.min_position = min;
        if (self.position < min) self.setPosition(min);
    }

    pub fn setMaxPosition(self: *Paned, max: i32) void {
        self.max_position = max;
        if (self.position > max) self.setPosition(max);
    }

    fn handleSize(self: *const Paned) f32 {
        return if (self.wide_handle) WIDE_HANDLE_SIZE else HANDLE_SIZE;
    }

    fn handleRect(self: *Paned) math.Rect(f32) {
        const r = self.base.rect;
        const hs = self.handleSize();
        const pos_f: f32 = @floatFromInt(self.position);
        return switch (self.orientation) {
            .horizontal => .{
                .x = r.x + pos_f,
                .y = r.y,
                .width = hs,
                .height = r.height,
            },
            .vertical => .{
                .x = r.x,
                .y = r.y + pos_f,
                .width = r.width,
                .height = hs,
            },
        };
    }

    fn hitTestHandle(self: *Paned, x: f32, y: f32) bool {
        const hr = self.handleRect();
        const pad: f32 = 2;
        return x >= hr.x - pad and x <= hr.x + hr.width + pad and
            y >= hr.y - pad and y <= hr.y + hr.height + pad;
    }
};

const vtable = Widget.VTable{
    .type_name = "paned",
    .measure = measure,
    .paint = paint,
    .on_event = onEvent,
    .focusable = false,
    .destroy = destroyVTable,
};

fn destroyVTable(w: *Widget, allocator: Allocator) void {
    const self: *Paned = @fieldParentPtr("base", w);
    self.destroy(allocator);
}

fn measure(w: *Widget, ctx: *PaintContext, constraints: layout_mod.Constraints) math.Size(f32) {
    const self: *Paned = @fieldParentPtr("base", w);
       const hs = self.handleSize();
    var min_w: f32 = hs;
    var min_h: f32 = hs;
    const avail_w = if (constraints.max_width < std.math.inf(f32)) constraints.max_width else 800;
    const avail_h = if (constraints.max_height < std.math.inf(f32)) constraints.max_height else 600;

    switch (self.orientation) {
        .horizontal => {
            if (self.start_child) |c| {
                const sz = c.vtable.measure(c, ctx, layout_mod.Constraints{ .min_width = 0, .max_width = @max(0, (avail_w - hs) / 2), .min_height = 0, .max_height = avail_h });
                min_w += sz.width;
                min_h = @max(min_h, sz.height);
            }
            if (self.end_child) |c| {
                const sz = c.vtable.measure(c, ctx, layout_mod.Constraints{ .min_width = 0, .max_width = @max(0, (avail_w - hs) / 2), .min_height = 0, .max_height = avail_h });
                min_w += sz.width;
                min_h = @max(min_h, sz.height);
            }
        },
        .vertical => {
            if (self.start_child) |c| {
                const sz = c.vtable.measure(c, ctx, layout_mod.Constraints{ .min_width = 0, .max_width = avail_w, .min_height = 0, .max_height = @max(0, (avail_h - hs) / 2) });
                min_w = @max(min_w, sz.width);
                min_h += sz.height;
            }
            if (self.end_child) |c| {
                const sz = c.vtable.measure(c, ctx, layout_mod.Constraints{ .min_width = 0, .max_width = avail_w, .min_height = 0, .max_height = @max(0, (avail_h - hs) / 2) });
                min_w = @max(min_w, sz.width);
                min_h += sz.height;
            }
        },
    }
    return .{ .width = min_w, .height = min_h };
}

fn paint(w: *Widget, ctx: *PaintContext) void {
    const self: *Paned = @fieldParentPtr("base", w);
    const rx = ctx.offset_x + w.rect.x;
    const ry = ctx.offset_y + w.rect.y;
    const rw = w.rect.width;
    const rh = w.rect.height;
    const hs = self.handleSize();

    if (self.bg_color.a > 0) {
        ctx.renderer.fillRoundedRect(.{ .x = rx, .y = ry, .width = rw, .height = rh }, self.corner_radius, self.bg_color) catch {};
    }

    // 布局并绘制两个子控件
    const usable_w = @max(0, rw - hs);
    const usable_h = @max(0, rh - hs);
    if (!self.position_set) {
        switch (self.orientation) {
            .horizontal => self.position = @intFromFloat(@floor(usable_w * 0.5)),
            .vertical => self.position = @intFromFloat(@floor(usable_h * 0.5)),
        }
    }
    const max_pos_val: i32 = switch (self.orientation) {
        .horizontal => @intFromFloat(@max(0, usable_w - 20)),
        .vertical => @intFromFloat(@max(0, usable_h - 20)),
    };
    var pos_val: i32 = @max(self.min_position, @min(self.max_position, @min(max_pos_val, self.position)));
    pos_val = @max(20, @min(max_pos_val, pos_val));
    self.position = pos_val;
    const posf: f32 = @floatFromInt(pos_val);

    var start_rect: math.Rect(f32) = undefined;
    var end_rect: math.Rect(f32) = undefined;
    var hr: math.Rect(f32) = undefined;
    switch (self.orientation) {
        .horizontal => {
            start_rect = .{ .x = 0, .y = 0, .width = posf, .height = rh };
            end_rect = .{ .x = posf + hs, .y = 0, .width = usable_w - posf, .height = rh };
            hr = .{ .x = posf, .y = 0, .width = hs, .height = rh };
        },
        .vertical => {
            start_rect = .{ .x = 0, .y = 0, .width = rw, .height = posf };
            end_rect = .{ .x = 0, .y = posf + hs, .width = rw, .height = usable_h - posf };
            hr = .{ .x = 0, .y = posf, .width = rw, .height = hs };
        },
    }

    var child_ctx = ctx.*;
    child_ctx.offset_x = rx;
    child_ctx.offset_y = ry;
    if (self.start_child) |pa| {
        pa.rect = start_rect;
        pa.paintTree(&child_ctx);
    }
    if (self.end_child) |pb| {
        pb.rect = end_rect;
        pb.paintTree(&child_ctx);
    }

    const div_color = if (self.dragging)
        self.divider_drag_color
    else if (self.hover_handle)
        self.divider_hover_color
    else
        self.divider_color;
    ctx.renderer.fillRect(.{ .x = rx + hr.x, .y = ry + hr.y, .width = hr.width, .height = hr.height }, div_color) catch {};

    const grabber_count = 3;
    const line_len: f32 = 14;
    const line_thick: f32 = 2;
    const gap: f32 = 3;
    switch (self.orientation) {
        .horizontal => {
            const cx = rx + hr.x + hs / 2;
            const total_h = line_thick * grabber_count + gap * (grabber_count - 1);
            var cy = ry + hr.y + (hr.height - total_h) / 2;
            for (0..grabber_count) |_| {
                ctx.renderer.fillRoundedRect(.{
                    .x = cx - line_len / 2,
                    .y = cy,
                    .width = line_len,
                    .height = line_thick,
                }, 1, self.grabber_color) catch {};
                cy += line_thick + gap;
            }
        },
        .vertical => {
            const cy = ry + hr.y + hs / 2;
            const total_w = line_thick * grabber_count + gap * (grabber_count - 1);
            var cx = rx + hr.x + (hr.width - total_w) / 2;
            for (0..grabber_count) |_| {
                ctx.renderer.fillRoundedRect(.{
                    .x = cx,
                    .y = cy - line_len / 2,
                    .width = line_thick,
                    .height = line_len,
                }, 1, self.grabber_color) catch {};
                cx += line_thick + gap;
            }
        },
    }
}

fn onEvent(w: *Widget, event: *const Event, ectx: *EventContext) EventResult {
    _ = ectx;
    const self: *Paned = @fieldParentPtr("base", w);
    const abs_rect = w.absoluteRect();

    switch (event.*) {
        .mouse_move => |m| {
            const mx: f32 = @floatFromInt(m.x);
            const my: f32 = @floatFromInt(m.y);
            if (self.dragging) {
                const delta: i32 = switch (self.orientation) {
                    .horizontal => @intFromFloat(@floor(mx - self.drag_start_mouse)),
                    .vertical => @intFromFloat(@floor(my - self.drag_start_mouse)),
                };
                self.setPosition(self.drag_start_pos + delta);
                w.cursor = switch (self.orientation) {
                    .horizontal => .resize_ew,
                    .vertical => .resize_ns,
                };
                return .handled;
            } else {
                const rel_x = mx - abs_rect.x;
                const rel_y = my - abs_rect.y;
                const hovering = self.hitTestHandle(rel_x, rel_y);
                if (hovering != self.hover_handle) {
                    self.hover_handle = hovering;
                    w.markDirty();
                }
                if (hovering) {
                    w.cursor = switch (self.orientation) {
                        .horizontal => .resize_ew,
                        .vertical => .resize_ns,
                    };
                    return .handled;
                }
            }
        },
        .mouse_button => |mb| {
            if (mb.button == .left) {
                const mx: f32 = @floatFromInt(mb.x);
                const my: f32 = @floatFromInt(mb.y);
                if (mb.state == .pressed) {
                    const rel_x = mx - abs_rect.x;
                    const rel_y = my - abs_rect.y;
                    if (self.hitTestHandle(rel_x, rel_y)) {
                        self.dragging = true;
                        self.drag_start_pos = self.position;
                        self.drag_start_mouse = switch (self.orientation) {
                            .horizontal => mx,
                            .vertical => my,
                        };
                        w.markDirty();
                        return .handled;
                    }
                } else {
                    if (self.dragging) {
                        self.dragging = false;
                        w.markDirty();
                        return .handled;
                    }
                }
            }
        },
        else => {},
    }
    return .ignored;
}
