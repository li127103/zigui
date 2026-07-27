//! Switch 控件 - 开关 (二态切换, 圆形滑块在轨道上滑动)

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
    on: bool,
    label: []const u8,
    font_size: f32,
    on_change: ?*const fn (self: *Switch, on: bool) void,
    // 样式
    track_width: f32,
    track_height: f32,
    track_on_color: math.Color,
    track_off_color: math.Color,
    thumb_color: math.Color,
    text_color: math.Color,
    text_disabled_color: math.Color,
    gap: f32,

    pub fn create(allocator: std.mem.Allocator, opts: struct {
        on: bool = false,
        label: []const u8 = "",
        font_size: f32 = 14.0,
        on_change: ?*const fn (self: *Switch, on: bool) void = null,
        track_width: f32 = 44.0,
        track_height: f32 = 24.0,
        track_on_color: math.Color = math.Color.hex(0x3B82F6FF),
        track_off_color: math.Color = math.Color.hex(0x475569FF),
        thumb_color: math.Color = math.Color.hex(0xFFFFFFFF),
        text_color: math.Color = math.Color.hex(0xF8FAFCFF),
        text_disabled_color: math.Color = math.Color.hex(0x64748BFF),
        gap: f32 = 8.0,
    }) !*Switch {
        const self = try allocator.create(Switch);
        self.* = .{
            .base = .{
                .vtable = &vtable,
                .id = widget_mod.genWidgetId(),
            },
            .on = opts.on,
            .label = opts.label,
            .font_size = opts.font_size,
            .on_change = opts.on_change,
            .track_width = opts.track_width,
            .track_height = opts.track_height,
            .track_on_color = opts.track_on_color,
            .track_off_color = opts.track_off_color,
            .thumb_color = opts.thumb_color,
            .text_color = opts.text_color,
            .text_disabled_color = opts.text_disabled_color,
            .gap = opts.gap,
        };
        self.base.accessibility = .{ .role = .toggle, .label = opts.label };
        return self;
    }

    pub fn destroy(self: *Switch, allocator: std.mem.Allocator) void {
        self.base.background.deinit(allocator);
        self.base.children.deinit(allocator);
        allocator.destroy(self);
    }

    pub fn setOn(self: *Switch, v: bool) void {
        if (v != self.on) {
            self.on = v;
            self.base.markDirty();
            if (self.on_change) |cb| cb(self, self.on);
        }
    }

    pub fn toggle(self: *Switch) void {
        self.setOn(!self.on);
    }

    // ── VTable 实现 ──────────────────────────────────────────────────────────

    const vtable = Widget.VTable{
        .type_name = "switch",
        .measure = measure,
        .paint = paint,
        .on_event = onEvent,
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
            const text_size = styled_text.measureText(ctx.allocator, self.label, .{
                .font_size = self.font_size,
            });
            width += self.gap + text_size.width;
            height = @max(height, text_size.height);
        }
        return .{ .width = width, .height = height };
    }

    fn paint(w: *Widget, ctx: *PaintContext) void {
        const self: *Switch = @fieldParentPtr("base", w);
        const rx = ctx.offset_x + w.rect.x;
        const ry = ctx.offset_y + w.rect.y;
        const disabled = w.state.disabled;

        // 轨道垂直居中
        const track_y = ry + (w.rect.height - self.track_height) / 2.0;
        const track_radius = self.track_height / 2.0;

        // 轨道
        const track_color = if (self.on) self.track_on_color else self.track_off_color;
        ctx.renderer.fillRoundedRect(
            .{ .x = rx, .y = track_y, .width = self.track_width, .height = self.track_height },
            track_radius,
            track_color,
        ) catch {};

        // 焦点环
        if (w.state.focused and !disabled) {
            ctx.renderer.fillRoundedRect(
                .{ .x = rx - 2, .y = track_y - 2, .width = self.track_width + 4, .height = self.track_height + 4 },
                track_radius + 2,
                math.Color.hex(0x3B82F644),
            ) catch {};
        }

        // 滑块 (圆, 内缩 2px)
        const inset: f32 = 2.0;
        const thumb_d = self.track_height - inset * 2;
        const thumb_y = track_y + inset;
        const thumb_x_off = if (self.on) self.track_width - inset - thumb_d else inset;
        ctx.renderer.fillRoundedRect(
            .{ .x = rx + thumb_x_off, .y = thumb_y, .width = thumb_d, .height = thumb_d },
            thumb_d / 2.0,
            self.thumb_color,
        ) catch {};

        // 文本
        if (self.label.len > 0) {
            const text_size = styled_text.measureText(ctx.allocator, self.label, .{
                .font_size = self.font_size,
            });
            const text_x = rx + self.track_width + self.gap;
            const text_y = ry + (w.rect.height - text_size.height) / 2.0;
            const color = if (disabled) self.text_disabled_color else self.text_color;
            styled_text.drawText(
                ctx.renderer,
                ctx.allocator,
                self.label,
                text_x,
                text_y,
                .{ .font_size = self.font_size, .color = color },
            );
        }
    }

    fn onEvent(w: *Widget, event: *const pal.Event, ectx: *EventContext) EventResult {
        const self: *Switch = @fieldParentPtr("base", w);
        _ = ectx;
        if (w.state.disabled) return .ignored;

        switch (event.*) {
            .mouse_button => |mb| {
                if (mb.button == .left) {
                    if (mb.state == .pressed) {
                        w.state.pressed = true;
                        w.markDirty();
                        return .handled;
                    } else if (w.state.pressed) {
                        w.state.pressed = false;
                        w.markDirty();
                        self.toggle();
                        return .handled;
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
            },
            .key => |k| {
                if (k.state == .pressed and w.state.focused) {
                    if (k.key == .space or k.key == .enter) {
                        self.toggle();
                        return .handled;
                    }
                }
            },
            else => {},
        }
        return .ignored;
    }
};

// ── Tests ──────────────────────────────────────────────────────────────────

var sw_change_count: usize = 0;
var sw_last_on: bool = false;
fn swOnChange(s: *Switch, on: bool) void {
    _ = s;
    sw_change_count += 1;
    sw_last_on = on;
}

test "switch toggle fires on_change" {
    sw_change_count = 0;
    const sw = try Switch.create(std.testing.allocator, .{ .on_change = swOnChange });
    defer sw.destroy(std.testing.allocator);

    try std.testing.expect(!sw.on);
    sw.toggle();
    try std.testing.expect(sw.on);
    try std.testing.expectEqual(@as(usize, 1), sw_change_count);
    try std.testing.expect(sw_last_on);

    // 相同值不触发
    sw.setOn(true);
    try std.testing.expectEqual(@as(usize, 1), sw_change_count);
}

test "switch click toggles" {
    const sw = try Switch.create(std.testing.allocator, .{});
    defer sw.destroy(std.testing.allocator);
    sw.base.rect = .{ .x = 0, .y = 0, .width = 44, .height = 24 };
    var ectx = EventContext{};

    var press = pal.Event{ .mouse_button = .{ .button = .left, .state = .pressed, .x = 10, .y = 10 } };
    _ = sw.base.dispatchEvent(&press, &ectx);
    var release = pal.Event{ .mouse_button = .{ .button = .left, .state = .released, .x = 10, .y = 10 } };
    _ = sw.base.dispatchEvent(&release, &ectx);
    try std.testing.expect(sw.on);
}

test "switch space key toggles when focused" {
    const sw = try Switch.create(std.testing.allocator, .{});
    defer sw.destroy(std.testing.allocator);
    sw.base.state.focused = true;
    var ectx = EventContext{};

    var ev = pal.Event{ .key = .{ .state = .pressed, .key = .space, .modifiers = .{} } };
    _ = sw.base.dispatchEvent(&ev, &ectx);
    try std.testing.expect(sw.on);
}
