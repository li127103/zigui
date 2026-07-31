//! ScaleButton 控件 - 刻度按钮
//!
//! 类似 GtkScaleButton: 带有弹出式刻度滑块的按钮。
//! 点击按钮后弹出垂直滑块, 用于调整数值。
//! VolumeButton 是 ScaleButton 的特例。
//!
//! 支持:
//! - 自定义图标
//! - 弹出式垂直滑块
//! - 最小值/最大值/步长
//! - 数值变化回调
//! - 可定制样式

const std = @import("std");
const math = @import("../math.zig");
const widget_mod = @import("widget.zig");
const layout_mod = @import("../layout/engine.zig");
const pal = @import("../pal/pal.zig");
const slider_mod = @import("slider.zig");
const icons_mod = @import("icons.zig");

const Widget = widget_mod.Widget;
const PaintContext = widget_mod.PaintContext;
const EventContext = widget_mod.EventContext;
const EventResult = widget_mod.EventResult;
const Slider = slider_mod.Slider;
const IconName = icons_mod.IconName;

pub const ScaleButton = struct {
    base: Widget,
    allocator: std.mem.Allocator,
    value: f32,
    min_value: f32,
    max_value: f32,
    step: f32,
    popup_open: bool = false,
    icon_name: IconName = .minus,

    on_value_changed: ?*const fn (self: *ScaleButton, value: f32) void = null,

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

    hovered: bool = false,
    pressed: bool = false,
    slider: ?*Slider = null,

    const Self = @This();

    pub fn create(allocator: std.mem.Allocator, opts: struct {
        value: f32 = 0.5,
        min_value: f32 = 0,
        max_value: f32 = 1,
        step: f32 = 0.05,
        icon_name: IconName = .minus,
        size: f32 = 32,
        icon_size: f32 = 20,
        corner_radius: f32 = 8,
        bg_color: math.Color = math.Color.hex(0x334155FF),
        bg_hover: math.Color = math.Color.hex(0x475569FF),
        bg_pressed: math.Color = math.Color.hex(0x1E293BFF),
        icon_color: math.Color = math.Color.hex(0xF8FAFCFF),
        on_value_changed: ?*const fn (self: *ScaleButton, value: f32) void = null,
    }) !*ScaleButton {
        const self = try allocator.create(ScaleButton);
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
            .icon_name = opts.icon_name,
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
            .label = "scale",
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
            if (self.slider) |s| {
                s.setValue(clamped);
            }
            self.base.markDirty();
            if (self.on_value_changed) |cb| {
                cb(self, clamped);
            }
        }
    }

    pub fn popup(self: *Self) void {
        self.popup_open = true;
        self.base.markDirty();
    }

    pub fn popdown(self: *Self) void {
        self.popup_open = false;
        self.base.markDirty();
    }

    // ── VTable ──────────────────────────────────────────────────────────────

    const vtable = Widget.VTable{
        .type_name = "scale_button",
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
        const rx = ctx.offset_x + w.rect.x;
        const ry = ctx.offset_y + w.rect.y;

        const bg = if (self.pressed) self.bg_pressed else if (self.hovered) self.bg_hover else self.bg_color;
        ctx.renderer.fillRoundedRect(
            .{ .x = rx, .y = ry, .width = self.size, .height = self.size },
            self.corner_radius,
            bg,
        ) catch {};

        const ix = rx + (self.size - self.icon_size) / 2;
        const iy = ry + (self.size - self.icon_size) / 2;
        icons_mod.drawIcon(ctx.renderer, ix, iy, self.icon_size, self.icon_color, self.icon_name) catch {};

        if (self.popup_open) {
            const px = rx + (self.size - self.popup_width) / 2;
            const py = ry - self.popup_height - 8;

            ctx.renderer.fillRoundedRect(
                .{ .x = px, .y = py, .width = self.popup_width, .height = self.popup_height },
                8,
                self.popup_bg,
            ) catch {};

            if (self.slider) |s| {
                s.base.rect.x = px + self.popup_padding - ctx.offset_x - w.rect.x;
                s.base.rect.y = py + self.popup_padding - ctx.offset_y - w.rect.y;
                s.base.rect.width = self.popup_width - self.popup_padding * 2;
                s.base.rect.height = self.popup_height - self.popup_padding * 2;
                s.base.vtable.paint(&s.base, ctx);
            }
        }
    }

    fn onEvent(w: *Widget, event: *const pal.Event, ectx: *EventContext) EventResult {
        const self: *Self = @fieldParentPtr("base", w);

        switch (event.*) {
            .mouse_move => |mm| {
                const mx: f32 = @floatFromInt(mm.x);
                const my: f32 = @floatFromInt(mm.y);

                const in_button = mx >= 0 and mx < self.size and my >= 0 and my < self.size;

                if (self.popup_open and self.slider != null) { const s = self.slider.?;
                    const px = (self.size - self.popup_width) / 2;
                    const py = -self.popup_height - 8;
                    const slider_x = px + self.popup_padding;
                    const slider_y = py + self.popup_padding;

                    const local_sx = mx - slider_x;
                    const local_sy = my - slider_y;

                    if (local_sx >= 0 and local_sx < s.base.rect.width and
                        local_sy >= 0 and local_sy < s.base.rect.height)
                    {
                        const slider_event = pal.Event{
                            .mouse_move = .{
                                .x = @intFromFloat(local_sx),
                                .y = @intFromFloat(local_sy),
                                .window_id = mm.window_id,
                            },
                        };
                        const result = s.base.vtable.on_event.?(&s.base, &slider_event, ectx);
                        if (result == .handled) {
                            self.value = s.getValue();
                            if (self.on_value_changed) |cb| {
                                cb(self, self.value);
                            }
                            self.base.markDirty();
                            return .handled;
                        }
                    }
                }

                if (in_button != self.hovered) {
                    self.hovered = in_button;
                    self.base.markDirty();
                }

                return if (in_button) .handled else .ignored;
            },
            .mouse_button => |mb| {
                if (mb.button == .left) {
                    const mx: f32 = @floatFromInt(mb.x);
                    const my: f32 = @floatFromInt(mb.y);

                    const in_button = mx >= 0 and mx < self.size and my >= 0 and my < self.size;

                    if (self.popup_open and self.slider != null) { const s = self.slider.?;
                        const px = (self.size - self.popup_width) / 2;
                        const py = -self.popup_height - 8;
                        const slider_x = px + self.popup_padding;
                        const slider_y = py + self.popup_padding;

                        const local_sx = mx - slider_x;
                        const local_sy = my - slider_y;

                        if (local_sx >= 0 and local_sx < s.base.rect.width and
                            local_sy >= 0 and local_sy < s.base.rect.height)
                        {
                            const slider_event = pal.Event{
                                .mouse_button = .{
                                    .x = @intFromFloat(local_sx),
                                    .y = @intFromFloat(local_sy),
                                    .button = mb.button,
                                    .state = mb.state,
                                    .window_id = mb.window_id,
                                },
                            };
                            const result = s.base.vtable.on_event.?(&s.base, &slider_event, ectx);
                            if (result == .handled) {
                                self.value = s.getValue();
                                if (self.on_value_changed) |cb| {
                                    cb(self, self.value);
                                }
                                self.base.markDirty();
                                return .handled;
                            }
                        }
                    }

                    if (mb.state == .pressed) {
                        if (in_button) {
                            self.pressed = true;
                            self.popup_open = !self.popup_open;
                            self.base.markDirty();
                            return .handled;
                        } else if (self.popup_open) {
                            self.popup_open = false;
                            self.base.markDirty();
                            return .ignored;
                        }
                    } else if (mb.state == .released) {
                        self.pressed = false;
                        self.base.markDirty();
                        if (in_button) return .handled;
                    }
                }
            },
            .key => |key| {
                if (key.state == .pressed) {
                    if (key.key == .up or key.key == .right) {
                        self.setValue(self.value + self.step);
                        return .handled;
                    } else if (key.key == .down or key.key == .left) {
                        self.setValue(self.value - self.step);
                        return .handled;
                    } else if (key.key == .enter or key.key == .space) {
                        self.popup_open = !self.popup_open;
                        self.base.markDirty();
                        return .handled;
                    } else if (key.key == .escape and self.popup_open) {
                        self.popup_open = false;
                        self.base.markDirty();
                        return .handled;
                    }
                }
            },
            .mouse_leave => {
                self.hovered = false;
                self.pressed = false;
                self.base.markDirty();
            },
            else => {},
        }
        return .ignored;
    }
};
