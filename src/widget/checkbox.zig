//! Checkbox 控件 - 复选框 (可勾选/取消)

const std = @import("std");
const math = @import("../math.zig");
const widget_mod = @import("widget.zig");
const layout_mod = @import("../layout/engine.zig");
const pal = @import("../pal/pal.zig");
const r2d = @import("../render2d/r2d.zig");
const styled_text = @import("../text/styled_text.zig");

const Widget = widget_mod.Widget;
const PaintContext = widget_mod.PaintContext;
const EventContext = widget_mod.EventContext;
const EventResult = widget_mod.EventResult;

pub const Checkbox = struct {
    base: Widget,
    checked: bool,
    label: []const u8,
    font_size: f32,
    on_change: ?*const fn (self: *Checkbox, checked: bool) void,
    // 样式
    box_size: f32,
    box_color: math.Color, // 未选中底色
    box_checked_color: math.Color, // 选中底色
    border_color: math.Color,
    check_color: math.Color, // 对勾颜色
    text_color: math.Color,
    text_disabled_color: math.Color,
    corner_radius: f32,
    gap: f32, // 框与文字间距

    pub fn create(allocator: std.mem.Allocator, label_text: []const u8, opts: struct {
        checked: bool = false,
        font_size: f32 = 14.0,
        on_change: ?*const fn (self: *Checkbox, checked: bool) void = null,
        box_size: f32 = 18.0,
        box_color: math.Color = math.Color.hex(0x1E293BFF),
        box_checked_color: math.Color = math.Color.hex(0x3B82F6FF),
        border_color: math.Color = math.Color.hex(0x475569FF),
        check_color: math.Color = math.Color.hex(0xFFFFFFFF),
        text_color: math.Color = math.Color.hex(0xF8FAFCFF),
        text_disabled_color: math.Color = math.Color.hex(0x64748BFF),
        corner_radius: f32 = 4.0,
        gap: f32 = 8.0,
    }) !*Checkbox {
        const self = try allocator.create(Checkbox);
        self.* = .{
            .base = .{
                .vtable = &vtable,
                .id = widget_mod.genWidgetId(),
            },
            .checked = opts.checked,
            .label = label_text,
            .font_size = opts.font_size,
            .on_change = opts.on_change,
            .box_size = opts.box_size,
            .box_color = opts.box_color,
            .box_checked_color = opts.box_checked_color,
            .border_color = opts.border_color,
            .check_color = opts.check_color,
            .text_color = opts.text_color,
            .text_disabled_color = opts.text_disabled_color,
            .corner_radius = opts.corner_radius,
            .gap = opts.gap,
        };
        self.base.accessibility = .{ .role = .checkbox, .label = label_text };
        return self;
    }

    pub fn destroy(self: *Checkbox, allocator: std.mem.Allocator) void {
        self.base.background.deinit(allocator);
        self.base.children.deinit(allocator);
        allocator.destroy(self);
    }

    pub fn setChecked(self: *Checkbox, v: bool) void {
        if (v != self.checked) {
            self.checked = v;
            self.base.markDirty();
            if (self.on_change) |cb| cb(self, self.checked);
        }
    }

    pub fn toggle(self: *Checkbox) void {
        self.setChecked(!self.checked);
    }

    // ── VTable 实现 ──────────────────────────────────────────────────────────

    const vtable = Widget.VTable{
        .type_name = "checkbox",
        .measure = measure,
        .paint = paint,
        .on_event = onEvent,
        .focusable = true,
        .destroy = destroyVTable,
    };

    fn destroyVTable(w: *Widget, allocator: std.mem.Allocator) void {
        const self: *Checkbox = @fieldParentPtr("base", w);
        self.destroy(allocator);
    }

    fn measure(w: *Widget, ctx: *PaintContext, constraints: layout_mod.Constraints) math.Size(f32) {
        const self: *Checkbox = @fieldParentPtr("base", w);
        _ = constraints;

        const text_size = styled_text.measureText(ctx.allocator, self.label, .{
            .font_size = self.font_size,
        });
        const content_h = @max(self.box_size, text_size.height);
        return .{
            .width = self.box_size + self.gap + text_size.width,
            .height = content_h,
        };
    }

    fn paint(w: *Widget, ctx: *PaintContext) void {
        const self: *Checkbox = @fieldParentPtr("base", w);
        const rx = ctx.offset_x + w.rect.x;
        const ry = ctx.offset_y + w.rect.y;
        const disabled = w.state.disabled;

        // 复选框垂直居中
        const box_y = ry + (w.rect.height - self.box_size) / 2.0;

        // 框底色
        const box_bg = if (self.checked) self.box_checked_color else self.box_color;
        ctx.renderer.fillRoundedRect(
            .{ .x = rx, .y = box_y, .width = self.box_size, .height = self.box_size },
            self.corner_radius,
            box_bg,
        ) catch {};

        // 边框 (未选中或禁用时显示; 选中时主色已足够醒目)
        if (!self.checked or disabled) {
            ctx.renderer.strokeRoundedRect(
                .{ .x = rx, .y = box_y, .width = self.box_size, .height = self.box_size },
                self.corner_radius,
                1.0,
                self.border_color,
            ) catch {};
        }

        // 焦点环
        if (w.state.focused and !disabled) {
            ctx.renderer.fillRoundedRect(
                .{ .x = rx - 2, .y = box_y - 2, .width = self.box_size + 4, .height = self.box_size + 4 },
                self.corner_radius + 2,
                math.Color.hex(0x3B82F644),
            ) catch {};
        }

        // 对勾
        if (self.checked) {
            drawCheckmark(ctx.renderer, rx, box_y, self.box_size, self.check_color);
        }

        // 文本 (垂直居中)
        if (self.label.len > 0) {
            const text_size = styled_text.measureText(ctx.allocator, self.label, .{
                .font_size = self.font_size,
            });
            const text_x = rx + self.box_size + self.gap;
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
        const self: *Checkbox = @fieldParentPtr("base", w);
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

/// 用若干小矩形沿两段折线绘制对勾 (渲染器无路径描边能力的简化方案)
fn drawCheckmark(renderer: *r2d.Renderer2D, box_x: f32, box_y: f32, box_size: f32, color: math.Color) void {
    // 对勾路径 (归一化坐标): (0.22,0.52) -> (0.42,0.72) -> (0.80,0.30)
    const p0x = box_x + box_size * 0.22;
    const p0y = box_y + box_size * 0.52;
    const p1x = box_x + box_size * 0.42;
    const p1y = box_y + box_size * 0.72;
    const p2x = box_x + box_size * 0.80;
    const p2y = box_y + box_size * 0.30;
    const thickness = @max(1.5, box_size * 0.12);
    drawPolyline(renderer, p0x, p0y, p1x, p1y, thickness, color);
    drawPolyline(renderer, p1x, p1y, p2x, p2y, thickness, color);
}

/// 沿直线段 (x0,y0)->(x1,y1) 以 thickness 粗细绘制连续小方块
fn drawPolyline(renderer: *r2d.Renderer2D, x0: f32, y0: f32, x1: f32, y1: f32, thickness: f32, color: math.Color) void {
    const dx = x1 - x0;
    const dy = y1 - y0;
    const len = @sqrt(dx * dx + dy * dy);
    if (len < 0.001) return;
    const step = thickness * 0.4;
    const steps: i32 = @max(2, @as(i32, @intFromFloat(@ceil(len / step))));
    const half = thickness / 2.0;
    var i: i32 = 0;
    while (i <= steps) : (i += 1) {
        const t = @as(f32, @floatFromInt(i)) / @as(f32, @floatFromInt(steps));
        const cx = x0 + dx * t;
        const cy = y0 + dy * t;
        renderer.fillRect(.{ .x = cx - half, .y = cy - half, .width = thickness, .height = thickness }, color) catch {};
    }
}

// ── Tests ──────────────────────────────────────────────────────────────────

var cb_change_count: usize = 0;
var cb_last_checked: bool = false;
fn cbOnChange(c: *Checkbox, checked: bool) void {
    _ = c;
    cb_change_count += 1;
    cb_last_checked = checked;
}

test "checkbox toggle fires on_change once" {
    cb_change_count = 0;
    const cb = try Checkbox.create(std.testing.allocator, "opt", .{ .on_change = cbOnChange });
    defer cb.destroy(std.testing.allocator);

    try std.testing.expect(!cb.checked);
    cb.toggle();
    try std.testing.expect(cb.checked);
    try std.testing.expectEqual(@as(usize, 1), cb_change_count);
    try std.testing.expect(cb_last_checked);

    // 设置相同值不触发回调
    cb.setChecked(true);
    try std.testing.expectEqual(@as(usize, 1), cb_change_count);
}

test "checkbox click toggles state" {
    const cb = try Checkbox.create(std.testing.allocator, "opt", .{});
    defer cb.destroy(std.testing.allocator);
    cb.base.rect = .{ .x = 0, .y = 0, .width = 100, .height = 20 };
    var ectx = EventContext{};

    var press = pal.Event{ .mouse_button = .{ .button = .left, .state = .pressed, .x = 5, .y = 5 } };
    _ = cb.base.dispatchEvent(&press, &ectx);
    try std.testing.expect(cb.base.state.pressed);

    var release = pal.Event{ .mouse_button = .{ .button = .left, .state = .released, .x = 5, .y = 5 } };
    _ = cb.base.dispatchEvent(&release, &ectx);
    try std.testing.expect(cb.checked);
    try std.testing.expect(!cb.base.state.pressed);
}

test "checkbox space key toggles when focused" {
    const cb = try Checkbox.create(std.testing.allocator, "opt", .{});
    defer cb.destroy(std.testing.allocator);
    cb.base.state.focused = true;
    var ectx = EventContext{};

    var ev = pal.Event{ .key = .{ .state = .pressed, .key = .space, .modifiers = .{} } };
    _ = cb.base.dispatchEvent(&ev, &ectx);
    try std.testing.expect(cb.checked);
}

test "checkbox disabled ignores events" {
    const cb = try Checkbox.create(std.testing.allocator, "opt", .{});
    defer cb.destroy(std.testing.allocator);
    cb.base.state.disabled = true;
    var ectx = EventContext{};

    var press = pal.Event{ .mouse_button = .{ .button = .left, .state = .pressed, .x = 5, .y = 5 } };
    const r = cb.base.dispatchEvent(&press, &ectx);
    try std.testing.expect(r == .ignored);
    try std.testing.expect(!cb.checked);
}
