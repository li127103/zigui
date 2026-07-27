//! ToggleButton 控件 - 切换按钮 (带选中状态的按钮)

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

pub const ToggleButton = struct {
    base: Widget,
    label: []const u8,
    active: bool,
    font_size: f32,
    on_toggle: ?*const fn (self: *ToggleButton, active: bool) void,
    // 样式 (未激活态)
    bg_color: math.Color,
    bg_hover: math.Color,
    bg_pressed: math.Color,
    text_color: math.Color,
    // 样式 (激活态)
    active_bg_color: math.Color,
    active_bg_hover: math.Color,
    active_bg_pressed: math.Color,
    active_text_color: math.Color,
    corner_radius: f32,
    padding_h: f32,
    padding_v: f32,
    border_width: f32,
    border_color: ?math.Color,

    pub fn create(allocator: std.mem.Allocator, label_text: []const u8, opts: struct {
        active: bool = false,
        font_size: f32 = 14.0,
        on_toggle: ?*const fn (self: *ToggleButton, active: bool) void = null,
        bg_color: math.Color = math.Color.hex(0xF1F5FFFF),
        bg_hover: math.Color = math.Color.hex(0xE2E8F0FF),
        bg_pressed: math.Color = math.Color.hex(0xCBD5E1FF),
        text_color: math.Color = math.Color.hex(0x334155FF),
        active_bg_color: math.Color = math.Color.hex(0x3B82F6FF),
        active_bg_hover: math.Color = math.Color.hex(0x2563EBFF),
        active_bg_pressed: math.Color = math.Color.hex(0x1D4ED8FF),
        active_text_color: math.Color = math.Color.hex(0xFFFFFFFF),
        corner_radius: f32 = 8.0,
        padding_h: f32 = 16.0,
        padding_v: f32 = 8.0,
        border_width: f32 = 0,
        border_color: ?math.Color = null,
    }) !*ToggleButton {
        const self = try allocator.create(ToggleButton);
        self.* = .{
            .base = .{
                .vtable = &vtable,
                .id = widget_mod.genWidgetId(),
            },
            .label = label_text,
            .active = opts.active,
            .font_size = opts.font_size,
            .on_toggle = opts.on_toggle,
            .bg_color = opts.bg_color,
            .bg_hover = opts.bg_hover,
            .bg_pressed = opts.bg_pressed,
            .text_color = opts.text_color,
            .active_bg_color = opts.active_bg_color,
            .active_bg_hover = opts.active_bg_hover,
            .active_bg_pressed = opts.active_bg_pressed,
            .active_text_color = opts.active_text_color,
            .corner_radius = opts.corner_radius,
            .padding_h = opts.padding_h,
            .padding_v = opts.padding_v,
            .border_width = opts.border_width,
            .border_color = opts.border_color,
        };
        self.base.accessibility = .{ .role = .toggle, .label = label_text };
        self.base.accessibility.value = if (self.active) "开" else "关";
        return self;
    }

    pub fn destroy(self: *ToggleButton, allocator: std.mem.Allocator) void {
        self.base.background.deinit(allocator);
        self.base.children.deinit(allocator);
        allocator.destroy(self);
    }

    pub fn setActive(self: *ToggleButton, active: bool) void {
        if (self.active != active) {
            self.active = active;
            self.base.accessibility.value = if (active) "开" else "关";
            self.base.markDirty();
        }
    }

    pub fn toggle(self: *ToggleButton) void {
        self.setActive(!self.active);
        if (self.on_toggle) |cb| {
            cb(self, self.active);
        }
    }

    fn currentBg(self: *const ToggleButton, pressed: bool, hovered: bool) math.Color {
        if (self.active) {
            if (pressed) return self.active_bg_pressed;
            if (hovered) return self.active_bg_hover;
            return self.active_bg_color;
        } else {
            if (pressed) return self.bg_pressed;
            if (hovered) return self.bg_hover;
            return self.bg_color;
        }
    }

    fn currentTextColor(self: *const ToggleButton) math.Color {
        return if (self.active) self.active_text_color else self.text_color;
    }

    // ── VTable ──────────────────────────────────────────────────────────────

    const vtable = Widget.VTable{
        .type_name = "toggle_button",
        .measure = measure,
        .paint = paint,
        .on_event = onEvent,
        .focusable = true,
        .destroy = destroyVTable,
    };

    fn destroyVTable(w: *Widget, allocator: std.mem.Allocator) void {
        const self: *ToggleButton = @fieldParentPtr("base", w);
        self.destroy(allocator);
    }

    fn measure(w: *Widget, ctx: *PaintContext, constraints: layout_mod.Constraints) math.Size(f32) {
        const self: *ToggleButton = @fieldParentPtr("base", w);
        _ = constraints;

        const text_size = styled_text.measureText(ctx.allocator, self.label, .{
            .font_size = self.font_size,
            .font_weight = 500,
        });

        return .{
            .width = text_size.width + self.padding_h * 2,
            .height = text_size.height + self.padding_v * 2,
        };
    }

    fn paint(w: *Widget, ctx: *PaintContext) void {
        const self: *ToggleButton = @fieldParentPtr("base", w);

        const bg = self.currentBg(w.state.pressed, w.state.hovered);
        const fg = self.currentTextColor();

        const rx = ctx.offset_x + w.rect.x;
        const ry = ctx.offset_y + w.rect.y;

        // 背景
        ctx.renderer.fillRoundedRect(
            .{ .x = rx, .y = ry, .width = w.rect.width, .height = w.rect.height },
            self.corner_radius,
            bg,
        ) catch {};

        // 边框
        if (self.border_color) |bc| {
            if (self.border_width > 0) {
                ctx.renderer.strokeRoundedRect(
                    .{ .x = rx, .y = ry, .width = w.rect.width, .height = w.rect.height },
                    self.corner_radius,
                    self.border_width,
                    bc,
                ) catch {};
            }
        }

        // 焦点环
        if (w.state.focused) {
            ctx.renderer.fillRoundedRect(
                .{ .x = rx - 2, .y = ry - 2, .width = w.rect.width + 4, .height = w.rect.height + 4 },
                self.corner_radius + 2,
                math.Color.hex(0x3B82F644),
            ) catch {};
        }

        // 文本 (居中)
        if (self.label.len > 0) {
            const text_size = styled_text.measureText(ctx.allocator, self.label, .{
                .font_size = self.font_size,
                .font_weight = 500,
            });
            const text_x = rx + (w.rect.width - text_size.width) / 2.0;
            const text_y = ry + (w.rect.height - text_size.height) / 2.0 + 1;

            styled_text.drawText(
                ctx.renderer,
                ctx.allocator,
                self.label,
                text_x,
                text_y,
                .{ .font_size = self.font_size, .font_weight = 500, .color = fg },
            );
        }
    }

    fn onEvent(w: *Widget, event: *const pal.Event, ectx: *EventContext) EventResult {
        const self: *ToggleButton = @fieldParentPtr("base", w);
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

// ── Tests ──────────────────────────────────────────────────────────────────

test "toggle_button create default inactive" {
    const tb = try ToggleButton.create(std.testing.allocator, "Toggle", .{});
    defer tb.destroy(std.testing.allocator);

    try std.testing.expectEqual(false, tb.active);
}

test "toggle_button setActive changes state" {
    const tb = try ToggleButton.create(std.testing.allocator, "Toggle", .{});
    defer tb.destroy(std.testing.allocator);

    tb.setActive(true);
    try std.testing.expectEqual(true, tb.active);

    tb.setActive(true);
    try std.testing.expectEqual(true, tb.active);
}

test "toggle_button toggle flips state" {
    const tb = try ToggleButton.create(std.testing.allocator, "Toggle", .{ .active = true });
    defer tb.destroy(std.testing.allocator);

    tb.toggle();
    try std.testing.expectEqual(false, tb.active);

    tb.toggle();
    try std.testing.expectEqual(true, tb.active);
}

test "toggle_button active text color differs" {
    const tb = try ToggleButton.create(std.testing.allocator, "Toggle", .{});
    defer tb.destroy(std.testing.allocator);

    const inactive = tb.currentTextColor();
    tb.setActive(true);
    const active = tb.currentTextColor();

    try std.testing.expect(inactive.r != active.r or inactive.g != active.g or inactive.b != active.b);
}

test "toggle_button pressed bg differs from hover" {
    const tb = try ToggleButton.create(std.testing.allocator, "Toggle", .{});
    defer tb.destroy(std.testing.allocator);

    const hovered = tb.currentBg(false, true);
    const pressed = tb.currentBg(true, false);

    try std.testing.expect(hovered.r != pressed.r or hovered.g != pressed.g or hovered.b != pressed.b);
}
