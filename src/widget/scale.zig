//! Scale 控件 - 带刻度和值标签的滑块 (对标 GtkScale)
//!
//! 在 Slider 基础上增加:
//! - 刻度标记 (ticks)
//! - 当前值显示
//! - 可选的最小值/最大值标签

const std = @import("std");
const math = @import("../math.zig");
const widget_mod = @import("widget.zig");
const layout_mod = @import("../layout/engine.zig");
const pal = @import("../pal/pal.zig");
const styled_text = @import("../text/styled_text.zig");
const adj_mod = @import("../model/adjustment.zig");

const Widget = widget_mod.Widget;
const PaintContext = widget_mod.PaintContext;
const EventContext = widget_mod.EventContext;
const EventResult = widget_mod.EventResult;
const Adjustment = adj_mod.Adjustment;

pub const ValuePosition = enum { top, bottom };

pub const ScaleMark = struct {
    value: f32,
    position: ValuePosition,
    label: []const u8,
};

pub const Scale = struct {
    base: Widget,
    value: f32,
    min: f32,
    max: f32,
    step: f32,
    on_change: ?*const fn (self: *Scale, value: f32) void,
    dragging: bool = false,
    /// 关联 Adjustment（设置后所有值/范围/步长委托给 adjustment）
    adjustment: ?*Adjustment = null,
    _saved_adj_vc: ?*const fn (userdata: ?*anyopaque, value: f32) void = null,
    _saved_adj_vc_userdata: ?*anyopaque = null,

    tick_count: u32 = 5,
    show_value: bool = true,
    show_min_max: bool = true,
    decimal_places: u8 = 1,

    track_color: math.Color = math.Color.hex(0x334155FF),
    fill_color: math.Color = math.Color.hex(0x3B82F6FF),
    thumb_color: math.Color = math.Color.hex(0xFFFFFFFF),
    tick_color: math.Color = math.Color.hex(0x64748BFF),
    text_color: math.Color = math.Color.hex(0x94A3B8FF),
    value_color: math.Color = math.Color.hex(0xF1F5FFFF),

    track_height: f32 = 6.0,
    thumb_radius: f32 = 9.0,
    tick_height: f32 = 8.0,
    scale_padding_bottom: f32 = 24.0,

    has_origin: bool = true,
    marks: std.ArrayListUnmanaged(ScaleMark) = .{ .items = &.{}, .capacity = 0 },

    pub fn create(allocator: std.mem.Allocator, opts: struct {
        value: f32 = 0,
        min: f32 = 0,
        max: f32 = 1,
        step: f32 = 0,
        tick_count: u32 = 5,
        show_value: bool = true,
        show_min_max: bool = true,
        decimal_places: u8 = 1,
        on_change: ?*const fn (self: *Scale, value: f32) void = null,
    }) !*Scale {
        const self = try allocator.create(Scale);
        self.* = .{
            .base = .{
                .vtable = &vtable,
                .id = widget_mod.genWidgetId(),
            },
            .value = std.math.clamp(opts.value, opts.min, opts.max),
            .min = opts.min,
            .max = opts.max,
            .step = opts.step,
            .tick_count = opts.tick_count,
            .show_value = opts.show_value,
            .show_min_max = opts.show_min_max,
            .decimal_places = opts.decimal_places,
            .on_change = opts.on_change,
        };
        self.base.cursor = .pointing_hand;
        return self;
    }

    pub fn destroy(self: *Scale, allocator: std.mem.Allocator) void {
        self.adjustment = null;
        self._saved_adj_vc = null;
        self._saved_adj_vc_userdata = null;
        self.base.background.deinit(allocator);
        self.base.children.deinit(allocator);
        self.marks.deinit(allocator);
        allocator.destroy(self);
    }

    pub fn setAdjustment(self: *Scale, adj: ?*Adjustment) void {
        if (self.adjustment == adj) return;
        self.adjustment = adj;
        if (adj) |a| {
            self.value = a.value;
            self.min = a.lower;
            self.max = a.upper;
            self.step = a.step_increment;
            self._saved_adj_vc = a.on_value_changed;
            self._saved_adj_vc_userdata = a.on_value_changed_userdata;
            a.on_value_changed = &onAdjValueChanged;
            a.on_value_changed_userdata = @ptrCast(self);
        }
        self.base.markDirty();
    }

    pub inline fn getAdjustment(self: *const Scale) ?*Adjustment {
        return self.adjustment;
    }

    pub fn setValue(self: *Scale, v: f32) void {
        if (self.adjustment) |a| {
            a.setValue(v);
            return;
        }
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

    pub fn setDrawValue(self: *Scale, v: bool) void {
        self.show_value = v;
        self.base.markDirty();
        self.base.markLayoutDirty();
    }

    pub fn setValuePos(self: *Scale, pos: ValuePosition) void {
        _ = pos;
        self.base.markDirty();
        self.base.markLayoutDirty();
    }

    pub fn setHasOrigin(self: *Scale, v: bool) void {
        self.has_origin = v;
        self.base.markDirty();
        self.base.markLayoutDirty();
    }

    pub fn setDigits(self: *Scale, n: u32) void {
        self.decimal_places = @intCast(n);
        self.base.markDirty();
        self.base.markLayoutDirty();
    }

    pub fn addMark(self: *Scale, value: f32, position: ValuePosition, label: []const u8) void {
        self.marks.append(std.heap.page_allocator, .{
            .value = value,
            .position = position,
            .label = label,
        }) catch {};
        self.base.markDirty();
        self.base.markLayoutDirty();
    }

    pub fn clearMarks(self: *Scale) void {
        self.marks.clearRetainingCapacity();
        self.base.markDirty();
        self.base.markLayoutDirty();
    }

    fn onAdjValueChanged(userdata: ?*anyopaque, value: f32) void {
        const self: *Scale = @ptrCast(@alignCast(userdata orelse return));
        self.value = value;
        if (self.adjustment) |a| {
            self.min = a.lower;
            self.max = a.upper;
            self.step = a.step_increment;
        }
        self.base.markDirty();
        if (self.on_change) |cb| cb(self, self.value);
    }

    pub fn normalized(self: *const Scale) f32 {
        if (self.max <= self.min) return 0;
        return (self.value - self.min) / (self.max - self.min);
    }

    // ── VTable ──────────────────────────────────────────────────────────────

    const vtable = Widget.VTable{
        .type_name = "scale",
        .measure = measure,
        .paint = paint,
        .on_event = onEvent,
        .focusable = true,
        .destroy = destroyVTable,
    };

    fn destroyVTable(w: *Widget, allocator: std.mem.Allocator) void {
        const self: *Scale = @fieldParentPtr("base", w);
        self.destroy(allocator);
    }

    fn measure(w: *Widget, ctx: *PaintContext, constraints: layout_mod.Constraints) math.Size(f32) {
        const self: *Scale = @fieldParentPtr("base", w);
        _ = ctx;
        const h = self.thumb_radius * 2 + 4 + self.tick_height + self.scale_padding_bottom;
        const min_w: f32 = if (self.show_min_max) 120 else 80;
        return .{
            .width = @max(min_w, constraints.min_width),
            .height = h,
        };
    }

    fn paint(w: *Widget, ctx: *PaintContext) void {
        const self: *Scale = @fieldParentPtr("base", w);
        const rx = ctx.offset_x + w.rect.x;
        const ry = ctx.offset_y + w.rect.y;
        const rw = w.rect.width;

        const slider_area_h = self.thumb_radius * 2 + 4;
        const track_y = ry + (slider_area_h - self.track_height) / 2.0;
        const norm = self.normalized();
        const thumb_x = rx + self.thumb_radius + norm * (rw - self.thumb_radius * 2);
        const thumb_y = ry + slider_area_h / 2.0;

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

        // 刻度线
        const tick_y_top = track_y + self.track_height + 2;
        const tick_y_bottom = tick_y_top + self.tick_height;
        if (self.tick_count > 1) {
            var i: u32 = 0;
            while (i < self.tick_count) : (i += 1) {
                const ti: f32 = @floatFromInt(i);
                const tc: f32 = @floatFromInt(self.tick_count - 1);
                const t: f32 = ti / tc;
                const tick_x = rx + self.thumb_radius + t * (rw - self.thumb_radius * 2);
                ctx.renderer.fillRect(
                    .{ .x = tick_x - 1, .y = tick_y_top, .width = 2, .height = self.tick_height },
                    self.tick_color,
                ) catch {};
            }
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

        // 值标签
        if (self.show_value) {
            const value_y = tick_y_bottom + 4;
            var buf: [32]u8 = undefined;
            const val_str = formatFloat(&buf, self.value, self.decimal_places);
            const text_w = @as(f32, @floatFromInt(val_str.len)) * 7.0;
            styled_text.drawText(
                ctx.renderer,
                ctx.allocator,
                val_str,
                thumb_x - text_w / 2,
                value_y,
                .{
                    .font_size = 11,
                    .color = self.value_color,
                    .font_weight = 600,
                },
            );
        }

        // min/max 标签
        if (self.show_min_max) {
            const label_y = tick_y_bottom + 4;
            var min_buf: [16]u8 = undefined;
            const min_str = formatFloat(&min_buf, self.min, self.decimal_places);
            styled_text.drawText(
                ctx.renderer,
                ctx.allocator,
                min_str,
                rx + self.thumb_radius,
                label_y,
                .{
                    .font_size = 10,
                    .color = self.text_color,
                },
            );

            var max_buf: [16]u8 = undefined;
            const max_str = formatFloat(&max_buf, self.max, self.decimal_places);
            const max_w = @as(f32, @floatFromInt(max_str.len)) * 6.0;
            styled_text.drawText(
                ctx.renderer,
                ctx.allocator,
                max_str,
                rx + rw - self.thumb_radius - max_w,
                label_y,
                .{
                    .font_size = 10,
                    .color = self.text_color,
                },
            );
        }
    }

    fn onEvent(w: *Widget, event: *const pal.Event, ectx: *EventContext) EventResult {
        const self: *Scale = @fieldParentPtr("base", w);
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

    fn updateFromMouse(self: *Scale, w: *Widget, mouse_x: f32) void {
        const usable_w = w.rect.width - self.thumb_radius * 2;
        if (usable_w <= 0) return;
        const rel = (mouse_x - self.thumb_radius) / usable_w;
        const norm = std.math.clamp(rel, 0.0, 1.0);
        self.setValue(self.min + norm * (self.max - self.min));
    }
};

fn formatFloat(buf: []u8, value: f32, decimals: u8) []const u8 {
    return switch (decimals) {
        0 => std.fmt.bufPrint(buf, "{d:.0}", .{value}) catch "0",
        1 => std.fmt.bufPrint(buf, "{d:.1}", .{value}) catch "0",
        2 => std.fmt.bufPrint(buf, "{d:.2}", .{value}) catch "0",
        3 => std.fmt.bufPrint(buf, "{d:.3}", .{value}) catch "0",
        else => std.fmt.bufPrint(buf, "{d:.1}", .{value}) catch "0",
    };
}
