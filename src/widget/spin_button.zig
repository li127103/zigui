//! SpinButton 控件 - 数值步进器 (带加减按钮的数字输入)

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

pub const SpinButton = struct {
    pub const ButtonKind = enum { none, up, down };

    base: Widget,
    allocator: std.mem.Allocator,
    value: f64,
    min: f64,
    max: f64,
    step: f64,
    digits: u8,
    editable: bool,
    on_change: ?*const fn (self: *SpinButton, value: f64) void,
    // 样式
    bg_color: math.Color,
    text_color: math.Color,
    border_color: math.Color,
    border_focus_color: math.Color,
    button_bg: math.Color,
    button_hover_bg: math.Color,
    button_press_bg: math.Color,
    button_text_color: math.Color,
    corner_radius: f32,
    font_size: f32,
    button_width: f32,
    height: f32,
    // 交互状态
    hovered_button: ButtonKind = .none,
    pressed_button: ButtonKind = .none,
    // 输入缓冲 (editable 模式)
    input_buf: [64]u8 = undefined,
    input_buf_len: usize = 0,
    editing: bool = false,

    pub fn create(allocator: std.mem.Allocator, opts: struct {
        value: f64 = 0,
        min: f64 = -std.math.inf(f64),
        max: f64 = std.math.inf(f64),
        step: f64 = 1,
        digits: u8 = 0,
        editable: bool = true,
        on_change: ?*const fn (self: *SpinButton, value: f64) void = null,
        bg_color: math.Color = math.Color.hex(0xFFFFFFFF),
        text_color: math.Color = math.Color.hex(0x1E293BFF),
        border_color: math.Color = math.Color.hex(0xE2E8F0FF),
        border_focus_color: math.Color = math.Color.hex(0x3B82F6FF),
        button_bg: math.Color = math.Color.hex(0xF8FAFCFF),
        button_hover_bg: math.Color = math.Color.hex(0xF1F5FFFF),
        button_press_bg: math.Color = math.Color.hex(0xE2E8F0FF),
        button_text_color: math.Color = math.Color.hex(0x475569FF),
        corner_radius: f32 = 6,
        font_size: f32 = 14,
        button_width: f32 = 28,
        height: f32 = 32,
    }) !*SpinButton {
        const self = try allocator.create(SpinButton);
        const clamped = std.math.clamp(opts.value, opts.min, opts.max);
        self.* = .{
            .base = .{
                .vtable = &vtable,
                .id = widget_mod.genWidgetId(),
            },
            .allocator = allocator,
            .value = clamped,
            .min = opts.min,
            .max = opts.max,
            .step = opts.step,
            .digits = opts.digits,
            .editable = opts.editable,
            .on_change = opts.on_change,
            .bg_color = opts.bg_color,
            .text_color = opts.text_color,
            .border_color = opts.border_color,
            .border_focus_color = opts.border_focus_color,
            .button_bg = opts.button_bg,
            .button_hover_bg = opts.button_hover_bg,
            .button_press_bg = opts.button_press_bg,
            .button_text_color = opts.button_text_color,
            .corner_radius = opts.corner_radius,
            .font_size = opts.font_size,
            .button_width = opts.button_width,
            .height = opts.height,
        };
        self.base.accessibility = .{ .role = .slider };
        self.syncInputBuf();
        self.base.cursor = .ibeam;
        return self;
    }

    pub fn destroy(self: *SpinButton, allocator: std.mem.Allocator) void {
        self.base.background.deinit(allocator);
        self.base.children.deinit(allocator);
        allocator.destroy(self);
    }

    pub fn setValue(self: *SpinButton, v: f64) void {
        const clamped = std.math.clamp(v, self.min, self.max);
        if (clamped != self.value) {
            self.value = clamped;
            self.syncInputBuf();
            self.base.markDirty();
        }
    }

    pub fn getValue(self: *const SpinButton) f64 {
        return self.value;
    }

    pub fn increment(self: *SpinButton) void {
        self.setValue(self.value + self.step);
        self.fireChange();
    }

    pub fn decrement(self: *SpinButton) void {
        self.setValue(self.value - self.step);
        self.fireChange();
    }

    fn fireChange(self: *SpinButton) void {
        if (self.on_change) |cb| {
            cb(self, self.value);
        }
    }

    fn syncInputBuf(self: *SpinButton) void {
        const n = std.fmt.bufPrint(&self.input_buf, "{d}", .{self.value}) catch return;
        self.input_buf_len = n.len;
    }

    fn parseInputValue(self: *SpinButton) void {
        const s = self.input_buf[0..self.input_buf_len];
        const v = std.fmt.parseFloat(f64, s) catch return;
        const clamped = std.math.clamp(v, self.min, self.max);
        if (clamped != self.value) {
            self.value = clamped;
            self.fireChange();
        }
        self.syncInputBuf();
    }

    // ── VTable ──────────────────────────────────────────────────────────────

    const vtable = Widget.VTable{
        .type_name = "spin_button",
        .measure = measure,
        .paint = paint,
        .on_event = onEvent,
        .focusable = true,
        .destroy = destroyVTable,
    };

    fn destroyVTable(w: *Widget, allocator: std.mem.Allocator) void {
        const self: *SpinButton = @fieldParentPtr("base", w);
        self.destroy(allocator);
    }

    fn measure(w: *Widget, ctx: *PaintContext, constraints: layout_mod.Constraints) math.Size(f32) {
        const self: *SpinButton = @fieldParentPtr("base", w);
        _ = ctx;
        const w_out = if (constraints.max_width < std.math.inf(f32))
            constraints.max_width
        else
            120 + 2 * self.button_width;
        return .{ .width = w_out, .height = self.height };
    }

    fn paint(w: *Widget, ctx: *PaintContext) void {
        const self: *SpinButton = @fieldParentPtr("base", w);
        const rx = ctx.offset_x + w.rect.x;
        const ry = ctx.offset_y + w.rect.y;
        const rw = w.rect.width;
        const rh = w.rect.height;

        const border_color = if (w.state.focused) self.border_focus_color else self.border_color;
        const text_color = self.text_color;

        // 主体背景
        ctx.renderer.fillRoundedRect(
            .{ .x = rx, .y = ry, .width = rw, .height = rh },
            self.corner_radius,
            self.bg_color,
        ) catch {};

        // 边框
        ctx.renderer.strokeRoundedRect(
            .{ .x = rx, .y = ry, .width = rw, .height = rh },
            self.corner_radius,
            1,
            border_color,
        ) catch {};

        // 数值文本 (居中)
        const text = self.input_buf[0..self.input_buf_len];
        const text_size = styled_text.measureText(ctx.allocator, text, .{ .font_size = self.font_size });
        const text_x = rx + (rw - 2 * self.button_width - text_size.width) / 2.0 + self.button_width;
        const text_y = ry + (rh - text_size.height) / 2.0 + 1;
        styled_text.drawText(
            ctx.renderer,
            ctx.allocator,
            text,
            text_x,
            text_y,
            .{ .font_size = self.font_size, .color = text_color, .font_weight = 500 },
        );

        // 减号按钮 (左)
        const dec_bg = self.buttonBgColor(.down);
        ctx.renderer.fillRoundedRect(
            .{ .x = rx, .y = ry, .width = self.button_width, .height = rh },
            self.corner_radius,
            dec_bg,
        ) catch {};
        // 清除右侧圆角
        ctx.renderer.fillRect(
            .{ .x = rx + self.button_width - self.corner_radius, .y = ry, .width = self.corner_radius, .height = rh },
            dec_bg,
        ) catch {};
        // 减号符号
        const minus_y = ry + rh / 2.0 - 1;
        ctx.renderer.fillRect(
            .{ .x = rx + self.button_width / 2.0 - 5, .y = minus_y, .width = 10, .height = 2 },
            self.button_text_color,
        ) catch {};

        // 加号按钮 (右)
        const inc_x = rx + rw - self.button_width;
        const inc_bg = self.buttonBgColor(.up);
        ctx.renderer.fillRoundedRect(
            .{ .x = inc_x, .y = ry, .width = self.button_width, .height = rh },
            self.corner_radius,
            inc_bg,
        ) catch {};
        // 清除左侧圆角
        ctx.renderer.fillRect(
            .{ .x = inc_x, .y = ry, .width = self.corner_radius, .height = rh },
            inc_bg,
        ) catch {};
        // 加号符号
        const plus_cx = inc_x + self.button_width / 2.0;
        const plus_cy = ry + rh / 2.0;
        ctx.renderer.fillRect(
            .{ .x = plus_cx - 5, .y = plus_cy - 1, .width = 10, .height = 2 },
            self.button_text_color,
        ) catch {};
        ctx.renderer.fillRect(
            .{ .x = plus_cx - 1, .y = plus_cy - 5, .width = 2, .height = 10 },
            self.button_text_color,
        ) catch {};
    }

    fn buttonBgColor(self: *const SpinButton, btn: ButtonKind) math.Color {
        const hovered = (self.hovered_button == btn);
        const pressed = (self.pressed_button == btn);
        if (pressed) return self.button_press_bg;
        if (hovered) return self.button_hover_bg;
        return self.button_bg;
    }

    fn onEvent(w: *Widget, event: *const pal.Event, ectx: *EventContext) EventResult {
        const self: *SpinButton = @fieldParentPtr("base", w);
        _ = ectx;

        switch (event.*) {
            .mouse_button => |mb| {
                if (mb.button == .left) {
                    const mx: f32 = @floatFromInt(mb.x);
                    const rw = w.rect.width;
                    const dec_hit = mx >= 0 and mx < self.button_width;
                    const inc_hit = mx >= rw - self.button_width and mx < rw;

                    if (mb.state == .pressed) {
                        if (dec_hit) {
                            self.pressed_button = .down;
                            self.base.markDirty();
                            return .handled;
                        } else if (inc_hit) {
                            self.pressed_button = .up;
                            self.base.markDirty();
                            return .handled;
                        }
                    } else {
                        if (self.pressed_button == .down and dec_hit) {
                            self.decrement();
                            self.pressed_button = .none;
                            self.base.markDirty();
                            return .handled;
                        }
                        if (self.pressed_button == .up and inc_hit) {
                            self.increment();
                            self.pressed_button = .none;
                            self.base.markDirty();
                            return .handled;
                        }
                        self.pressed_button = .none;
                        self.base.markDirty();
                    }
                }
            },
            .mouse_move => |mm| {
                const mx: f32 = @floatFromInt(mm.x);
                const rw = w.rect.width;
                const dec_hit = mx >= 0 and mx < self.button_width;
                const inc_hit = mx >= rw - self.button_width and mx < rw;

                const new_hover: @TypeOf(self.hovered_button) = if (dec_hit) .down else if (inc_hit) .up else .none;
                if (new_hover != self.hovered_button) {
                    self.hovered_button = new_hover;
                    self.base.markDirty();
                }
                return .ignored;
            },
            .key => |k| {
                if (k.state == .pressed) {
                    switch (k.key) {
                        .up => {
                            self.increment();
                            return .handled;
                        },
                        .down => {
                            self.decrement();
                            return .handled;
                        },
                        else => {},
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

test "spin_button create with default value" {
    const sb = try SpinButton.create(std.testing.allocator, .{});
    defer sb.destroy(std.testing.allocator);

    try std.testing.expectEqual(@as(f64, 0), sb.value);
    try std.testing.expectEqual(true, sb.editable);
}

test "spin_button setValue clamps to range" {
    const sb = try SpinButton.create(std.testing.allocator, .{ .min = 0, .max = 100, .value = 50 });
    defer sb.destroy(std.testing.allocator);

    sb.setValue(200);
    try std.testing.expectEqual(@as(f64, 100), sb.getValue());

    sb.setValue(-50);
    try std.testing.expectEqual(@as(f64, 0), sb.getValue());
}

test "spin_button increment / decrement" {
    const sb = try SpinButton.create(std.testing.allocator, .{ .value = 10, .step = 2 });
    defer sb.destroy(std.testing.allocator);

    sb.increment();
    try std.testing.expectEqual(@as(f64, 12), sb.getValue());

    sb.decrement();
    sb.decrement();
    try std.testing.expectEqual(@as(f64, 8), sb.getValue());
}

test "spin_button increment respects max" {
    const sb = try SpinButton.create(std.testing.allocator, .{ .value = 9, .min = 0, .max = 10, .step = 2 });
    defer sb.destroy(std.testing.allocator);

    sb.increment();
    try std.testing.expectEqual(@as(f64, 10), sb.getValue());

    sb.increment();
    try std.testing.expectEqual(@as(f64, 10), sb.getValue());
}

test "spin_button decrement respects min" {
    const sb = try SpinButton.create(std.testing.allocator, .{ .value = 1, .min = 0, .max = 10, .step = 2 });
    defer sb.destroy(std.testing.allocator);

    sb.decrement();
    try std.testing.expectEqual(@as(f64, 0), sb.getValue());

    sb.decrement();
    try std.testing.expectEqual(@as(f64, 0), sb.getValue());
}

test "spin_button default step is 1" {
    const sb = try SpinButton.create(std.testing.allocator, .{});
    defer sb.destroy(std.testing.allocator);

    try std.testing.expectEqual(@as(f64, 1), sb.step);
}
