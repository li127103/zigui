//! Radio 控件 - 单选按钮 (圆形, 配合 RadioGroup 实现互斥选择)

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

/// 单选按钮逻辑分组 (非 Widget, 仅维护选中索引)
/// 同一组内的 Radio 互斥: 选中一个会取消其他。
pub const RadioGroup = struct {
    selected_index: usize,
    on_change: ?*const fn (self: *RadioGroup, index: usize) void,

    pub fn init(selected_index: usize, opts: struct {
        on_change: ?*const fn (self: *RadioGroup, index: usize) void = null,
    }) RadioGroup {
        return .{ .selected_index = selected_index, .on_change = opts.on_change };
    }

    pub fn select(self: *RadioGroup, index: usize) void {
        if (index != self.selected_index) {
            self.selected_index = index;
            if (self.on_change) |cb| cb(self, index);
        }
    }
};

pub const Radio = struct {
    base: Widget,
    group: *RadioGroup,
    index: usize,
    label: []const u8,
    font_size: f32,
    // 样式
    circle_size: f32,
    circle_color: math.Color, // 未选中底色
    selected_color: math.Color, // 选中主色
    border_color: math.Color,
    dot_color: math.Color, // 选中中心圆点
    text_color: math.Color,
    text_disabled_color: math.Color,
    gap: f32,

    pub fn create(allocator: std.mem.Allocator, group: *RadioGroup, index: usize, label_text: []const u8, opts: struct {
        font_size: f32 = 14.0,
        circle_size: f32 = 18.0,
        circle_color: math.Color = math.Color.hex(0x1E293BFF),
        selected_color: math.Color = math.Color.hex(0x3B82F6FF),
        border_color: math.Color = math.Color.hex(0x475569FF),
        dot_color: math.Color = math.Color.hex(0xFFFFFFFF),
        text_color: math.Color = math.Color.hex(0xF8FAFCFF),
        text_disabled_color: math.Color = math.Color.hex(0x64748BFF),
        gap: f32 = 8.0,
    }) !*Radio {
        const self = try allocator.create(Radio);
        self.* = .{
            .base = .{
                .vtable = &vtable,
                .id = widget_mod.genWidgetId(),
            },
            .group = group,
            .index = index,
            .label = label_text,
            .font_size = opts.font_size,
            .circle_size = opts.circle_size,
            .circle_color = opts.circle_color,
            .selected_color = opts.selected_color,
            .border_color = opts.border_color,
            .dot_color = opts.dot_color,
            .text_color = opts.text_color,
            .text_disabled_color = opts.text_disabled_color,
            .gap = opts.gap,
        };
        self.base.accessibility = .{ .role = .radio, .label = label_text };
        return self;
    }

    pub fn destroy(self: *Radio, allocator: std.mem.Allocator) void {
        self.base.background.deinit(allocator);
        self.base.children.deinit(allocator);
        allocator.destroy(self);
    }

    pub fn isSelected(self: *const Radio) bool {
        return self.group.selected_index == self.index;
    }

    // ── VTable 实现 ──────────────────────────────────────────────────────────

    const vtable = Widget.VTable{
        .type_name = "radio",
        .measure = measure,
        .paint = paint,
        .on_event = onEvent,
        .focusable = true,
        .destroy = destroyVTable,
    };

    fn destroyVTable(w: *Widget, allocator: std.mem.Allocator) void {
        const self: *Radio = @fieldParentPtr("base", w);
        self.destroy(allocator);
    }

    fn measure(w: *Widget, ctx: *PaintContext, constraints: layout_mod.Constraints) math.Size(f32) {
        const self: *Radio = @fieldParentPtr("base", w);
        _ = constraints;
        const text_size = styled_text.measureText(ctx.allocator, self.label, .{
            .font_size = self.font_size,
        });
        return .{
            .width = self.circle_size + self.gap + text_size.width,
            .height = @max(self.circle_size, text_size.height),
        };
    }

    fn paint(w: *Widget, ctx: *PaintContext) void {
        const self: *Radio = @fieldParentPtr("base", w);
        const rx = ctx.offset_x + w.rect.x;
        const ry = ctx.offset_y + w.rect.y;
        const disabled = w.state.disabled;
        const selected = self.isSelected();

        const circle_y = ry + (w.rect.height - self.circle_size) / 2.0;
        const radius = self.circle_size / 2.0;

        // 圆形底 (rounded rect radius=半径 → 圆)
        ctx.renderer.fillRoundedRect(
            .{ .x = rx, .y = circle_y, .width = self.circle_size, .height = self.circle_size },
            radius,
            if (selected) self.selected_color else self.circle_color,
        ) catch {};

        // 边框
        if (!selected or disabled) {
            ctx.renderer.strokeRoundedRect(
                .{ .x = rx, .y = circle_y, .width = self.circle_size, .height = self.circle_size },
                radius,
                1.0,
                self.border_color,
            ) catch {};
        }

        // 焦点环
        if (w.state.focused and !disabled) {
            ctx.renderer.fillRoundedRect(
                .{ .x = rx - 2, .y = circle_y - 2, .width = self.circle_size + 4, .height = self.circle_size + 4 },
                radius + 2,
                math.Color.hex(0x3B82F644),
            ) catch {};
        }

        // 选中中心圆点
        if (selected) {
            const dot_size = self.circle_size * 0.4;
            const dot_xy = (self.circle_size - dot_size) / 2.0;
            ctx.renderer.fillRoundedRect(
                .{ .x = rx + dot_xy, .y = circle_y + dot_xy, .width = dot_size, .height = dot_size },
                dot_size / 2.0,
                self.dot_color,
            ) catch {};
        }

        // 文本
        if (self.label.len > 0) {
            const text_size = styled_text.measureText(ctx.allocator, self.label, .{
                .font_size = self.font_size,
            });
            const text_x = rx + self.circle_size + self.gap;
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
        const self: *Radio = @fieldParentPtr("base", w);
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
                        // 选中本项 (同组互斥由 group 维护)
                        const old = self.group.selected_index;
                        self.group.select(self.index);
                        if (old != self.group.selected_index) {
                            // 通知父级重绘以刷新原选中项
                            if (w.parent) |p| p.markDirty();
                            w.markDirty();
                        }
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
                        self.group.select(self.index);
                        if (w.parent) |p| p.markDirty();
                        w.markDirty();
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

var rg_change_count: usize = 0;
var rg_last_index: usize = 0;
fn rgOnChange(g: *RadioGroup, index: usize) void {
    _ = g;
    rg_change_count += 1;
    rg_last_index = index;
}

test "radio group select is exclusive and fires callback" {
    rg_change_count = 0;
    var group = RadioGroup.init(0, .{ .on_change = rgOnChange });
    group.select(2);
    try std.testing.expectEqual(@as(usize, 2), group.selected_index);
    try std.testing.expectEqual(@as(usize, 1), rg_change_count);
    try std.testing.expectEqual(@as(usize, 2), rg_last_index);

    // 选择相同索引不触发
    group.select(2);
    try std.testing.expectEqual(@as(usize, 1), rg_change_count);
}

test "radio isSelected reflects group selection" {
    var group = RadioGroup.init(0, .{});
    const r0 = try Radio.create(std.testing.allocator, &group, 0, "a", .{});
    defer r0.destroy(std.testing.allocator);
    const r1 = try Radio.create(std.testing.allocator, &group, 1, "b", .{});
    defer r1.destroy(std.testing.allocator);

    try std.testing.expect(r0.isSelected());
    try std.testing.expect(!r1.isSelected());

    group.select(1);
    try std.testing.expect(!r0.isSelected());
    try std.testing.expect(r1.isSelected());
}

test "radio click selects its index" {
    var group = RadioGroup.init(0, .{});
    const r1 = try Radio.create(std.testing.allocator, &group, 1, "b", .{});
    defer r1.destroy(std.testing.allocator);
    r1.base.rect = .{ .x = 0, .y = 0, .width = 100, .height = 20 };
    var ectx = EventContext{};

    var press = pal.Event{ .mouse_button = .{ .button = .left, .state = .pressed, .x = 5, .y = 5 } };
    _ = r1.base.dispatchEvent(&press, &ectx);
    var release = pal.Event{ .mouse_button = .{ .button = .left, .state = .released, .x = 5, .y = 5 } };
    _ = r1.base.dispatchEvent(&release, &ectx);

    try std.testing.expectEqual(@as(usize, 1), group.selected_index);
    try std.testing.expect(r1.isSelected());
}
