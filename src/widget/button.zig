//! Button 控件 - 可点击按钮

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

pub const Button = struct {
    base: Widget,
    label: []const u8,
    font_size: f32,
    on_click: ?*const fn (self: *Button) void,
    // 样式
    bg_color: math.Color,
    bg_hover: math.Color,
    bg_pressed: math.Color,
    text_color: math.Color,
    corner_radius: f32,
    padding_h: f32,
    padding_v: f32,

    pub fn create(allocator: std.mem.Allocator, label_text: []const u8, opts: struct {
        font_size: f32 = 14.0,
        on_click: ?*const fn (self: *Button) void = null,
        bg_color: math.Color = math.Color.hex(0x3B82F6FF),
        bg_hover: math.Color = math.Color.hex(0x60A5FAFF),
        bg_pressed: math.Color = math.Color.hex(0x2563EBFF),
        text_color: math.Color = math.Color.hex(0xFFFFFFFF),
        corner_radius: f32 = 8.0,
        padding_h: f32 = 16.0,
        padding_v: f32 = 10.0,
    }) !*Button {
        const self = try allocator.create(Button);
        self.* = .{
            .base = .{
                .vtable = &vtable,
                .id = widget_mod.genWidgetId(),
            },
            .label = label_text,
            .font_size = opts.font_size,
            .on_click = opts.on_click,
            .bg_color = opts.bg_color,
            .bg_hover = opts.bg_hover,
            .bg_pressed = opts.bg_pressed,
            .text_color = opts.text_color,
            .corner_radius = opts.corner_radius,
            .padding_h = opts.padding_h,
            .padding_v = opts.padding_v,
        };
        return self;
    }

    pub fn destroy(self: *Button, allocator: std.mem.Allocator) void {
        self.base.background.deinit(allocator);
        self.base.children.deinit(allocator);
        allocator.destroy(self);
    }

    // ── VTable 实现 ──────────────────────────────────────────────────────────

    const vtable = Widget.VTable{
        .type_name = "button",
        .measure = measure,
        .paint = paint,
        .on_event = onEvent,
        .focusable = true,
        .destroy = destroyVTable,
    };

    fn destroyVTable(w: *Widget, allocator: std.mem.Allocator) void {
        const self: *Button = @fieldParentPtr("base", w);
        self.destroy(allocator);
    }

    fn measure(w: *Widget, ctx: *PaintContext, constraints: layout_mod.Constraints) math.Size(f32) {
        const self: *Button = @fieldParentPtr("base", w);
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
        const self: *Button = @fieldParentPtr("base", w);

        // 选择背景色
        const bg = if (w.state.pressed)
            self.bg_pressed
        else if (w.state.hovered)
            self.bg_hover
        else
            self.bg_color;

        const rx = ctx.offset_x + w.rect.x;
        const ry = ctx.offset_y + w.rect.y;

        // 背景
        ctx.renderer.fillRoundedRect(
            .{ .x = rx, .y = ry, .width = w.rect.width, .height = w.rect.height },
            self.corner_radius,
            bg,
        ) catch {};

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
            const text_y = ry + (w.rect.height - text_size.height) / 2.0;

            styled_text.drawText(
                ctx.renderer,
                ctx.allocator,
                self.label,
                text_x,
                text_y,
                .{
                    .font_size = self.font_size,
                    .font_weight = 500,
                    .color = self.text_color,
                },
            );
        }
    }

    fn onEvent(w: *Widget, event: *const pal.Event, ectx: *EventContext) EventResult {
        const self: *Button = @fieldParentPtr("base", w);

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
                            // 触发点击
                            if (self.on_click) |cb| {
                                cb(self);
                            }
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
            },
            else => {},
        }
        _ = ectx;
        return .ignored;
    }
};
