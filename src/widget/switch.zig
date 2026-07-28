//! Switch 控件 - 开关按钮 (对标 GtkSwitch)

const std = @import("std");
const math = @import("../math.zig");
const widget_mod = @import("widget.zig");
const layout_mod = @import("../layout/engine.zig");
const pal = @import("../pal/pal.zig");
const styled_text = @import("../text/styled_text.zig");

const Widget = widget_mod.Widget;
const PaintContext = widget_mod.PaintContext;
const EventContext = widget_mod.EventContext;
const EventResult = widget_mod.EventResult;

pub const Switch = struct {
    base: Widget,
    active: bool,
    label: []const u8,
    on_toggle: ?*const fn (self: *Switch, active: bool) void,
    /// 旋转速度倍数 (1.0 = 默认)
    speed: f32 = 1.0,
    // 样式
    track_color_off: math.Color,
    track_color_on: math.Color,
    thumb_color: math.Color,
    text_color: math.Color,
    corner_radius: f32,
    track_width: f32,
    track_height: f32,
    thumb_padding: f32,
    label_gap: f32 = 8,
    font_size: f32 = 14,
    /// 动画进度 0..1
    anim_progress: f32,

    pub fn create(allocator: std.mem.Allocator, opts: struct {
        active: bool = false,
        on: ?bool = null,
        label: []const u8 = "",
        on_toggle: ?*const fn (self: *Switch, active: bool) void = null,
        on_change: ?*const fn (self: *Switch, active: bool) void = null,
        track_color_off: math.Color = math.Color.hex(0xCBD5E1FF),
        track_color_on: math.Color = math.Color.hex(0x3B82F6FF),
        thumb_color: math.Color = math.Color.hex(0xFFFFFFFF),
        text_color: math.Color = math.Color.hex(0xF8FAFCFF),
        width: f32 = 44,
        height: f32 = 24,
        thumb_padding: f32 = 2,
        speed: f32 = 1.0,
    }) !*Switch {
        const is_active = opts.on orelse opts.active;
        const callback = opts.on_toggle orelse opts.on_change;
        const self = try allocator.create(Switch);
        self.* = .{
            .base = .{
                .vtable = &vtable,
                .id = widget_mod.genWidgetId(),
            },
            .active = is_active,
            .label = opts.label,
            .on_toggle = callback,
            .speed = opts.speed,
            .track_color_off = opts.track_color_off,
            .track_color_on = opts.track_color_on,
            .thumb_color = opts.thumb_color,
            .text_color = opts.text_color,
            .corner_radius = opts.height / 2.0,
            .track_width = opts.width,
            .track_height = opts.height,
            .thumb_padding = opts.thumb_padding,
            .anim_progress = if (is_active) 1.0 else 0.0,
        };
        const a11y_label = if (opts.label.len > 0) opts.label else "Switch";
        self.base.accessibility = .{ .role = .toggle, .label = a11y_label };
        self.base.accessibility.value = if (self.active) "开" else "关";
        self.base.cursor = .pointing_hand;
        return self;
    }

    pub fn destroy(self: *Switch, allocator: std.mem.Allocator) void {
        self.base.background.deinit(allocator);
        self.base.children.deinit(allocator);
        allocator.destroy(self);
    }

    pub fn setActive(self: *Switch, active: bool) void {
        if (self.active != active) {
            self.active = active;
            self.base.accessibility.value = if (active) "开" else "关";
            self.base.markDirty();
        }
    }

    pub fn toggle(self: *Switch) void {
        self.setActive(!self.active);
        if (self.on_toggle) |cb| {
            cb(self, self.active);
        }
    }

    fn lerpColor(a: math.Color, b: math.Color, t: f32) math.Color {
        return .{
            .r = @intFromFloat(@as(f32, @floatFromInt(a.r)) + (@as(f32, @floatFromInt(b.r)) - @as(f32, @floatFromInt(a.r))) * t),
            .g = @intFromFloat(@as(f32, @floatFromInt(a.g)) + (@as(f32, @floatFromInt(b.g)) - @as(f32, @floatFromInt(a.g))) * t),
            .b = @intFromFloat(@as(f32, @floatFromInt(a.b)) + (@as(f32, @floatFromInt(b.b)) - @as(f32, @floatFromInt(a.b))) * t),
            .a = @intFromFloat(@as(f32, @floatFromInt(a.a)) + (@as(f32, @floatFromInt(b.a)) - @as(f32, @floatFromInt(a.a))) * t),
        };
    }

    const vtable = Widget.VTable{
        .type_name = "switch",
        .measure = measure,
        .paint = paint,
        .on_event = onEvent,
        .tick = tick,
        .focusable = true,
        .destroy = destroyVTable,
    };

    fn destroyVTable(w: *Widget, allocator: std.mem.Allocator) void {
        const self: *Switch = @fieldParentPtr("base", w);
        self.destroy(allocator);
    }

    fn measure(w: *Widget, ctx: *PaintContext, constraints: layout_mod.Constraints) math.Size(f32) {
        const self: *Switch = @fieldParentPtr("base", w);
        _ = constraints;
        var width = self.track_width;
        var height = self.track_height;
        if (self.label.len > 0) {
            const label_w = styled_text.measureTextWidth(ctx.allocator, self.label, .{ .font_size = self.font_size });
            width += self.label_gap + label_w;
            height = @max(height, self.font_size * 1.4);
        }
        return .{
            .width = width,
            .height = height,
        };
    }

    fn tick(w: *Widget, delta_ms: u32) void {
        const self: *Switch = @fieldParentPtr("base", w);
        const target: f32 = if (self.active) 1.0 else 0.0;
        const speed: f32 = 0.008 * @as(f32, @floatFromInt(delta_ms)) * self.speed;
        if (self.anim_progress < target) {
            self.anim_progress = @min(self.anim_progress + speed, target);
            w.markDirty();
        } else if (self.anim_progress > target) {
            self.anim_progress = @max(self.anim_progress - speed, target);
            w.markDirty();
        }
    }

    fn paint(w: *Widget, ctx: *PaintContext) void {
        const self: *Switch = @fieldParentPtr("base", w);

        const rx = ctx.offset_x + w.rect.x;
        const ry = ctx.offset_y + w.rect.y;

        const track_color = lerpColor(self.track_color_off, self.track_color_on, self.anim_progress);

        const track_x = rx;
        const track_y = ry + (w.rect.height - self.track_height) / 2.0;

        ctx.renderer.fillRoundedRect(
            .{ .x = track_x, .y = track_y, .width = self.track_width, .height = self.track_height },
            self.corner_radius,
            track_color,
        ) catch {};

        const thumb_size = self.track_height - self.thumb_padding * 2.0;
        const thumb_y = track_y + self.thumb_padding;
        const thumb_x_start = track_x + self.thumb_padding;
        const thumb_x_end = track_x + self.track_width - thumb_size - self.thumb_padding;
        const thumb_x = thumb_x_start + (thumb_x_end - thumb_x_start) * self.anim_progress;

        ctx.renderer.fillCircle(
            thumb_x + thumb_size / 2.0,
            thumb_y + thumb_size / 2.0,
            thumb_size / 2.0,
            self.thumb_color,
        ) catch {};

        if (w.state.focused) {
            ctx.renderer.fillRoundedRect(
                .{ .x = track_x - 3, .y = track_y - 3, .width = self.track_width + 6, .height = self.track_height + 6 },
                self.corner_radius + 3,
                math.Color.hex(0x3B82F633),
            ) catch {};
        }

        if (self.label.len > 0) {
            const label_x = rx + self.track_width + self.label_gap;
            const label_y = ry + (w.rect.height - self.font_size * 1.2) / 2.0 + self.font_size * 0.85;
            _ = styled_text.drawText(
                ctx.renderer,
                ctx.allocator,
                self.label,
                label_x,
                label_y,
                .{ .font_size = self.font_size, .color = self.text_color },
            );
        }
    }

    fn onEvent(w: *Widget, event: *const pal.Event, ectx: *EventContext) EventResult {
        const self: *Switch = @fieldParentPtr("base", w);
        _ = ectx;

        switch (event.*) {
            .mouse_button => |mb| {
                if (mb.button == .left) {
                    if (mb.state == .pressed) {
                        w.state.pressed = true;
                        w.markDirty();
                        return .handled;
                    } else {
                        if (w.state.pressed) {
                            w.state.pressed = false;
                            w.markDirty();
                            self.toggle();
                            return .handled;
                        }
                    }
                }
            },
            .mouse_move => |mm| {
                const lx: f32 = @floatFromInt(mm.x);
                const ly: f32 = @floatFromInt(mm.y);
                const inside = lx >= 0 and ly >= 0 and lx < w.rect.width and ly < w.rect.height;
                if (inside != w.state.hovered) {
                    w.state.hovered = inside;
                    w.markDirty();
                }
                return .ignored;
            },
            .key => |k| {
                if (k.state == .pressed and (k.key == .space or k.key == .enter)) {
                    if (w.state.focused) {
                        self.toggle();
                        return .handled;
                    }
                }
                return .ignored;
            },
            else => return .ignored,
        }
        return .ignored;
    }
};
