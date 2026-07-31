//! VolumeButton 控件 - 音量按钮
//!
//! 类似 GtkVolumeButton: 带有音量图标的按钮, 点击后弹出垂直滑块调整音量。
//! 支持静音切换、音量值显示、图标随音量变化。

const std = @import("std");
const math = @import("../math.zig");
const widget_mod = @import("widget.zig");
const layout_mod = @import("../layout/engine.zig");
const pal = @import("../pal/pal.zig");
const slider_mod = @import("slider.zig");

const Widget = widget_mod.Widget;
const PaintContext = widget_mod.PaintContext;
const EventContext = widget_mod.EventContext;
const EventResult = widget_mod.EventResult;
const Slider = slider_mod.Slider;

pub const VolumeButton = struct {
    base: Widget,
    allocator: std.mem.Allocator,
    value: f32 = 0.5,
    min_value: f32 = 0,
    max_value: f32 = 1,
    step: f32 = 0.05,
    muted: bool = false,
    popup_open: bool = false,

    on_value_changed: ?*const fn (self: *VolumeButton, value: f32) void = null,

    size: f32 = 32,
    icon_size: f32 = 20,
    corner_radius: f32 = 8,

    bg_color: math.Color = math.Color.hex(0x334155FF),
    bg_hover: math.Color = math.Color.hex(0x475569FF),
    bg_pressed: math.Color = math.Color.hex(0x1E293BFF),
    icon_color: math.Color = math.Color.hex(0xF8FAFCFF),

    popup_bg: math.Color = math.Color.hex(0x1E293BFF),
    popup_width: f32 = 48,
    popup_height: f32 = 160,
    popup_padding: f32 = 12,

    slider: ?*Slider = null,

    const Self = @This();

    pub fn create(allocator: std.mem.Allocator, opts: struct {
        value: f32 = 0.5,
        min_value: f32 = 0,
        max_value: f32 = 1,
        step: f32 = 0.05,
        size: f32 = 32,
        icon_size: f32 = 20,
        corner_radius: f32 = 8,
        bg_color: math.Color = math.Color.hex(0x334155FF),
        bg_hover: math.Color = math.Color.hex(0x475569FF),
        bg_pressed: math.Color = math.Color.hex(0x1E293BFF),
        icon_color: math.Color = math.Color.hex(0xF8FAFCFF),
        on_value_changed: ?*const fn (self: *VolumeButton, value: f32) void = null,
    }) !*VolumeButton {
        const self = try allocator.create(VolumeButton);
        self.* = .{
            .base = .{
                .vtable = &vtable,
                .id = widget_mod.genWidgetId(),
            },
            .allocator = allocator,
            .value = std.math.clamp(opts.value, opts.min_value, opts.max_value),
            .min_value = opts.min_value,
            .max_value = opts.max_value,
            .step = opts.step,
            .size = opts.size,
            .icon_size = opts.icon_size,
            .corner_radius = opts.corner_radius,
            .bg_color = opts.bg_color,
            .bg_hover = opts.bg_hover,
            .bg_pressed = opts.bg_pressed,
            .icon_color = opts.icon_color,
            .on_value_changed = opts.on_value_changed,
        };
        self.base.accessibility = .{
            .role = .button,
            .label = "音量",
        };
        self.base.cursor = .pointing_hand;

        const slider = try Slider.create(allocator, .{
            .min = opts.min_value,
            .max = opts.max_value,
            .value = opts.value,
            .step = opts.step,
        });
        self.slider = slider;

        return self;
    }

    pub fn destroy(self: *Self, allocator: std.mem.Allocator) void {
        if (self.slider) |s| {
            s.base.vtable.destroy(&s.base, allocator);
        }
        self.base.background.deinit(allocator);
        self.base.children.deinit(allocator);
        allocator.destroy(self);
    }

    pub fn getValue(self: *const Self) f32 {
        return self.value;
    }

    pub fn setValue(self: *Self, value: f32) void {
        const clamped = std.math.clamp(value, self.min_value, self.max_value);
        if (clamped != self.value) {
            self.value = clamped;
            self.muted = false;
            if (self.slider) |s| {
                s.setValue(clamped);
            }
            self.base.markDirty();
            if (self.on_value_changed) |cb| {
                cb(self, clamped);
            }
        }
    }

    pub fn isMuted(self: *const Self) bool {
        return self.muted;
    }

    pub fn setMuted(self: *Self, muted: bool) void {
        if (self.muted != muted) {
            self.muted = muted;
            self.base.markDirty();
            if (self.on_value_changed) |cb| {
                cb(self, if (muted) 0 else self.value);
            }
        }
    }

    pub fn toggleMute(self: *Self) void {
        self.setMuted(!self.muted);
    }

    pub fn popup(self: *Self) void {
        self.popup_open = true;
        self.base.markDirty();
    }

    pub fn popdown(self: *Self) void {
        self.popup_open = false;
        self.base.markDirty();
    }

    fn drawVolumeIcon(self: *Self, r2d: anytype, x: f32, y: f32, size: f32, color: math.Color) void {
        const scale = size / 16.0;

        const display_value = if (self.muted) 0.0 else self.value;

        r2d.fillRect(.{
            .x = x + 2 * scale,
            .y = y + 5 * scale,
            .width = 3 * scale,
            .height = 6 * scale,
        }, color) catch {};
        r2d.fillRect(.{
            .x = x + 3 * scale,
            .y = y + 4 * scale,
            .width = 2 * scale,
            .height = 8 * scale,
        }, color) catch {};

        const speaker_pts = [_][2]f32{
            .{ 6, 2 },
            .{ 5, 3 },
            .{ 5, 13 },
            .{ 6, 14 },
            .{ 9, 11 },
            .{ 9, 5 },
        };
        var buf: [6][2]f32 = undefined;
        for (speaker_pts, 0..) |pt, i| {
            buf[i] = .{ x + pt[0] * scale, y + pt[1] * scale };
        }
        r2d.fillConvexPolygon(&buf, color) catch {};

        if (display_value > 0) {
            r2d.fillRing(x + 11.5 * scale, y + 8 * scale, 4 * scale, 2.8 * scale, color) catch {};
        }

        if (display_value > 0.5) {
            r2d.fillRing(x + 12.5 * scale, y + 8 * scale, 6 * scale, 4.8 * scale, color) catch {};
        }

        if (self.muted) {
            r2d.fillRect(.{
                .x = x + 3 * scale,
                .y = y + 7.5 * scale,
                .width = 10 * scale,
                .height = 1.5 * scale,
            }, color) catch {};
        }
    }

    const vtable = Widget.VTable{
        .type_name = "volume_button",
        .measure = measure,
        .paint = paint,
        .on_event = onEvent,
        .focusable = true,
        .destroy = destroyVTable,
    };

    fn destroyVTable(w: *Widget, allocator: std.mem.Allocator) void {
        const self: *Self = @fieldParentPtr("base", w);
        self.destroy(allocator);
    }

    fn measure(w: *Widget, ctx: *PaintContext, constraints: layout_mod.Constraints) math.Size(f32) {
        const self: *Self = @fieldParentPtr("base", w);
        _ = ctx;
        _ = constraints;
        return .{ .width = self.size, .height = self.size };
    }

    fn paint(w: *Widget, ctx: *PaintContext) void {
        const self: *Self = @fieldParentPtr("base", w);
        const r = w.rect;
        const r2d = ctx.renderer;

        const x = ctx.offset_x + r.x;
        const y = ctx.offset_y + r.y;

        const bg = if (w.state.pressed or self.popup_open)
            self.bg_pressed
        else if (w.state.hovered)
            self.bg_hover
        else
            self.bg_color;

        r2d.fillRoundedRect(.{ .x = x, .y = y, .width = r.width, .height = r.height }, self.corner_radius, bg) catch {};

        if (w.state.focused) {
            r2d.fillRoundedRect(
                .{ .x = x - 2, .y = y - 2, .width = r.width + 4, .height = r.height + 4 },
                self.corner_radius + 2,
                math.Color.hex(0x3B82F644),
            ) catch {};
        }

        const icon_x = x + (r.width - self.icon_size) / 2;
        const icon_y = y + (r.height - self.icon_size) / 2;
        self.drawVolumeIcon(r2d, icon_x, icon_y, self.icon_size, self.icon_color);

        if (self.popup_open) {
            const popup_w = self.popup_width;
            const popup_h = self.popup_height;
            const popup_x = x + (r.width - popup_w) / 2;
            const popup_y = y - popup_h - 8;

            r2d.fillRoundedRect(
                .{ .x = popup_x, .y = popup_y, .width = popup_w, .height = popup_h },
                8,
                self.popup_bg,
            ) catch {};

            if (self.slider) |s| {
                s.base.rect.x = popup_x + (popup_w - 24) / 2;
                s.base.rect.y = popup_y + self.popup_padding;
                s.base.rect.width = 24;
                s.base.rect.height = popup_h - self.popup_padding * 2;
                s.base.paintTree(ctx);
            }
        }
    }

    fn onEvent(w: *Widget, event: *const pal.Event, ectx: *EventContext) EventResult {
        const self: *Self = @fieldParentPtr("base", w);

        if (self.popup_open and self.slider != null) {
            if (self.slider) |s| {
                const result = s.base.dispatchEvent(event, ectx);
                if (result == .handled) {
                    const new_val = s.value;
                    if (new_val != self.value) {
                        self.value = new_val;
                        self.muted = false;
                        self.base.markDirty();
                        if (self.on_value_changed) |cb| {
                            cb(self, new_val);
                        }
                    }
                    return .handled;
                }
            }
        }

        switch (event.*) {
            .mouse_button => |mb| {
                if (mb.button == .left) {
                    if (mb.state == .pressed) {
                        if (self.popup_open) {
                            const abs = w.absoluteRect();
                            const popup_w = self.popup_width;
                            const popup_h = self.popup_height;
                            const popup_x = abs.x + (abs.width - popup_w) / 2;
                            const popup_y = abs.y - popup_h - 8;
                            const px = @as(f32, @floatFromInt(mb.x));
                            const py = @as(f32, @floatFromInt(mb.y));
                            const in_popup = px >= popup_x and px <= popup_x + popup_w and
                                py >= popup_y and py <= popup_y + popup_h;
                            const in_button = px >= abs.x and px <= abs.x + abs.width and
                                py >= abs.y and py <= abs.y + abs.height;

                            if (!in_popup and !in_button) {
                                self.popdown();
                                return .handled;
                            }
                        } else {
                            w.state.pressed = true;
                            w.markDirty();
                        }
                        return .handled;
                    } else {
                        if (w.state.pressed) {
                            w.state.pressed = false;
                            if (self.popup_open) {
                                self.popdown();
                            } else {
                                self.popup();
                            }
                            w.markDirty();
                        }
                        return .handled;
                    }
                }
                return .handled;
            },
            .mouse_move => |mm| {
                _ = mm;
                return .handled;
            },
            .key => |key| {
                if (key.state == .pressed) {
                    switch (key.key) {
                        .up, .right => {
                            self.setValue(self.value + self.step);
                            return .handled;
                        },
                        .down, .left => {
                            self.setValue(self.value - self.step);
                            return .handled;
                        },
                        .home, .page_up => {
                            self.setValue(self.max_value);
                            return .handled;
                        },
                        .end, .page_down => {
                            self.setValue(self.min_value);
                            return .handled;
                        },
                        .space, .enter, .kp_enter => {
                            self.toggleMute();
                            return .handled;
                        },
                        .escape => {
                            if (self.popup_open) {
                                self.popdown();
                                return .handled;
                            }
                        },
                        else => {},
                    }
                }
                return .ignored;
            },
            .scroll => |scr| {
                if (scr.delta < 0) {
                    self.setValue(self.value + self.step);
                } else {
                    self.setValue(self.value - self.step);
                }
                return .handled;
            },
            else => return .ignored,
        }
    }
};
