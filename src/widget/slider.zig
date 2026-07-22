//! Slider 控件 - 滑动条

const std = @import("std");
const math = @import("../math.zig");
const widget_mod = @import("widget.zig");
const layout_mod = @import("../layout/engine.zig");
const pal = @import("../pal/pal.zig");

const Widget = widget_mod.Widget;
const PaintContext = widget_mod.PaintContext;
const EventContext = widget_mod.EventContext;
const EventResult = widget_mod.EventResult;

pub const Slider = struct {
    base: Widget,
    value: f32,
    min: f32,
    max: f32,
    step: f32,
    on_change: ?*const fn (self: *Slider, value: f32) void,
    dragging: bool = false,
    // 样式
    track_color: math.Color = math.Color.hex(0x334155FF),
    fill_color: math.Color = math.Color.hex(0x3B82F6FF),
    thumb_color: math.Color = math.Color.hex(0xFFFFFFFF),
    track_height: f32 = 6.0,
    thumb_radius: f32 = 9.0,

    pub fn create(allocator: std.mem.Allocator, opts: struct {
        value: f32 = 0,
        min: f32 = 0,
        max: f32 = 1,
        step: f32 = 0,
        on_change: ?*const fn (self: *Slider, value: f32) void = null,
    }) !*Slider {
        const self = try allocator.create(Slider);
        self.* = .{
            .base = .{
                .vtable = &vtable,
                .id = widget_mod.genWidgetId(),
            },
            .value = std.math.clamp(opts.value, opts.min, opts.max),
            .min = opts.min,
            .max = opts.max,
            .step = opts.step,
            .on_change = opts.on_change,
        };
        return self;
    }

    pub fn destroy(self: *Slider, allocator: std.mem.Allocator) void {
        self.base.background.deinit(allocator);
        self.base.children.deinit(allocator);
        allocator.destroy(self);
    }

    pub fn setValue(self: *Slider, v: f32) void {
        const clamped = std.math.clamp(v, self.min, self.max);
        const stepped = if (self.step > 0) blk: {
            const steps = @round((clamped - self.min) / self.step);
            break :blk self.min + steps * self.step;
        } else clamped;
        if (stepped != self.value) {
            self.value = stepped;
            self.base.markDirty();
            if (self.on_change) |cb| cb(self, self.value);
        }
    }

    pub fn normalized(self: *const Slider) f32 {
        if (self.max <= self.min) return 0;
        return (self.value - self.min) / (self.max - self.min);
    }

    // ── VTable ──────────────────────────────────────────────────────────────

    const vtable = Widget.VTable{
        .type_name = "slider",
        .measure = measure,
        .paint = paint,
        .on_event = onEvent,
        .focusable = true,
        .destroy = destroyVTable,
    };

    fn destroyVTable(w: *Widget, allocator: std.mem.Allocator) void {
        const self: *Slider = @fieldParentPtr("base", w);
        self.destroy(allocator);
    }

    fn measure(w: *Widget, ctx: *PaintContext, constraints: layout_mod.Constraints) math.Size(f32) {
        const self: *Slider = @fieldParentPtr("base", w);
        _ = ctx;
        _ = constraints;
        return .{ .width = 200, .height = self.thumb_radius * 2 + 4 };
    }

    fn paint(w: *Widget, ctx: *PaintContext) void {
        const self: *Slider = @fieldParentPtr("base", w);
        const rx = ctx.offset_x + w.rect.x;
        const ry = ctx.offset_y + w.rect.y;
        const rw = w.rect.width;
        const rh = w.rect.height;

        const track_y = ry + (rh - self.track_height) / 2.0;
        const norm = self.normalized();
        const thumb_x = rx + self.thumb_radius + norm * (rw - self.thumb_radius * 2);
        const thumb_y = ry + rh / 2.0;

        // 轨道背景
        ctx.renderer.fillRoundedRect(
            .{ .x = rx + self.thumb_radius, .y = track_y, .width = rw - self.thumb_radius * 2, .height = self.track_height },
            self.track_height / 2.0,
            self.track_color,
        ) catch {};

        // 已填充部分
        const fill_w = (thumb_x - rx - self.thumb_radius);
        if (fill_w > 0) {
            ctx.renderer.fillRoundedRect(
                .{ .x = rx + self.thumb_radius, .y = track_y, .width = fill_w, .height = self.track_height },
                self.track_height / 2.0,
                self.fill_color,
            ) catch {};
        }

        // 滑块
        const thumb_r = if (w.state.hovered or self.dragging) self.thumb_radius + 1 else self.thumb_radius;
        ctx.renderer.fillRoundedRect(
            .{ .x = thumb_x - thumb_r, .y = thumb_y - thumb_r, .width = thumb_r * 2, .height = thumb_r * 2 },
            thumb_r,
            self.thumb_color,
        ) catch {};

        // 焦点环
        if (w.state.focused) {
            ctx.renderer.fillRoundedRect(
                .{ .x = thumb_x - thumb_r - 3, .y = thumb_y - thumb_r - 3, .width = (thumb_r + 3) * 2, .height = (thumb_r + 3) * 2 },
                thumb_r + 3,
                math.Color.hex(0x3B82F644),
            ) catch {};
        }
    }

    fn onEvent(w: *Widget, event: *const pal.Event, ectx: *EventContext) EventResult {
        const self: *Slider = @fieldParentPtr("base", w);
        _ = ectx;

        switch (event.*) {
            .mouse_button => |mb| {
                if (mb.button == .left) {
                    if (mb.state == .pressed) {
                        self.dragging = true;
                        self.updateFromMouse(w, @floatFromInt(mb.x));
                        return .handled;
                    } else {
                        self.dragging = false;
                        w.markDirty();
                        return .handled;
                    }
                }
            },
            .mouse_move => |mm| {
                if (self.dragging) {
                    self.updateFromMouse(w, @floatFromInt(mm.x));
                    return .handled;
                }
                // hover 检测
                const lx: f32 = @floatFromInt(mm.x);
                const ly: f32 = @floatFromInt(mm.y);
                const inside = lx >= 0 and ly >= 0 and lx < w.rect.width and ly < w.rect.height;
                if (inside != w.state.hovered) {
                    w.state.hovered = inside;
                    w.markDirty();
                }
            },
            .key => |k| {
                if (k.state == .pressed and w.state.focused) {
                    const range = self.max - self.min;
                    const inc = if (self.step > 0) self.step else range / 20.0;
                    switch (k.key) {
                        .left, .down => {
                            self.setValue(self.value - inc);
                            return .handled;
                        },
                        .right, .up => {
                            self.setValue(self.value + inc);
                            return .handled;
                        },
                        .home => {
                            self.setValue(self.min);
                            return .handled;
                        },
                        .end => {
                            self.setValue(self.max);
                            return .handled;
                        },
                        else => {},
                    }
                }
            },
            else => {},
        }
        return .ignored;
    }

    fn updateFromMouse(self: *Slider, w: *Widget, mouse_x: f32) void {
        const usable_w = w.rect.width - self.thumb_radius * 2;
        if (usable_w <= 0) return;
        const rel = (mouse_x - self.thumb_radius) / usable_w;
        const norm = std.math.clamp(rel, 0.0, 1.0);
        self.setValue(self.min + norm * (self.max - self.min));
    }
};
