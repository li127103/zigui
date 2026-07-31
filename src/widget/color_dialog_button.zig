//! ColorDialogButton 控件 - GTK4 颜色对话框按钮
//!
//! 对应 GtkColorDialogButton: 显示当前颜色的按钮, 点击弹出颜色选择对话框。
//! GTK4 新版替代 ColorButton，接受一个 Dialog 对象（此处简化为直接弹出）。

const std = @import("std");
const math = @import("../math.zig");
const widget_mod = @import("widget.zig");
const layout_mod = @import("../layout/engine.zig");
const pal = @import("../pal/pal.zig");
const color_chooser_mod = @import("color_chooser.zig");
const styled_text = @import("../text/styled_text.zig");

const Widget = widget_mod.Widget;
const PaintContext = widget_mod.PaintContext;
const EventContext = widget_mod.EventContext;
const EventResult = widget_mod.EventResult;
const ColorChooserDialog = color_chooser_mod.ColorChooserDialog;

pub const ColorDialogButton = struct {
    base: Widget,
    allocator: std.mem.Allocator,
    color: math.Color,
    dialog: ?*ColorChooserDialog = null,
    show_hex: bool = true,

    on_color_changed: ?*const fn (self: *ColorDialogButton, color: math.Color) void = null,

    size: f32 = 36,
    swatch_size: f32 = 28,
    corner_radius: f32 = 8,

    bg_color: math.Color = math.Color.hex(0xFFFFFFFF),
    bg_hover: math.Color = math.Color.hex(0xF1F5F9FF),
    border_color: math.Color = math.Color.hex(0xCBD5E1FF),
    border_hover: math.Color = math.Color.hex(0x94A3B8FF),
    text_color: math.Color = math.Color.hex(0x0F172AFF),

    hovered: bool = false,
    pressed: bool = false,

    const Self = @This();

    pub fn create(allocator: std.mem.Allocator, opts: struct {
        color: math.Color = math.Color.hex(0x3B82F6FF),
        show_hex: bool = true,
        size: f32 = 36,
        swatch_size: f32 = 28,
        corner_radius: f32 = 8,
        on_color_changed: ?*const fn (self: *ColorDialogButton, color: math.Color) void = null,
    }) !*ColorDialogButton {
        const self = try allocator.create(ColorDialogButton);
        self.* = .{
            .base = .{
                .vtable = &vtable,
                .id = widget_mod.genWidgetId(),
            },
            .allocator = allocator,
            .color = opts.color,
            .show_hex = opts.show_hex,
            .size = opts.size,
            .swatch_size = opts.swatch_size,
            .corner_radius = opts.corner_radius,
            .on_color_changed = opts.on_color_changed,
        };
        self.base.accessibility = .{
            .role = .button,
            .label = "color",
        };
        self.base.cursor = .pointing_hand;
        return self;
    }

    pub fn destroy(self: *Self, allocator: std.mem.Allocator) void {
        if (self.dialog) |dlg| {
            dlg.base.vtable.destroy(&dlg.base, allocator);
        }
        self.base.background.deinit(allocator);
        self.base.children.deinit(allocator);
        allocator.destroy(self);
    }

    pub fn setColor(self: *Self, color: math.Color) void {
        self.color = color;
        self.base.markDirty();
        if (self.on_color_changed) |cb| cb(self, color);
    }

    pub fn getColor(self: *const Self) math.Color {
        return self.color;
    }

    fn toHex(self: *Self) [8]u8 {
        const c = self.color;
        const r: u8 = if (c.r > 255) 255 else c.r;
        const g: u8 = if (c.g > 255) 255 else c.g;
        const b: u8 = if (c.b > 255) 255 else c.b;
        const hex_chars = "0123456789ABCDEF";
        var buf: [8]u8 = undefined;
        buf[0] = '#';
        buf[1] = hex_chars[r >> 4];
        buf[2] = hex_chars[r & 15];
        buf[3] = hex_chars[g >> 4];
        buf[4] = hex_chars[g & 15];
        buf[5] = hex_chars[b >> 4];
        buf[6] = hex_chars[b & 15];
        buf[7] = 0;
        return buf;
    }

    // ── VTable ──────────────────────────────────────────────────────────────

    const vtable = Widget.VTable{
        .type_name = "color_dialog_button",
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

        var total_w = self.size;
        if (self.show_hex) {
            total_w = self.size + 70;
        }
        const h_out = self.size;

        const w_out = if (constraints.max_width < std.math.inf(f32))
            constraints.max_width
        else
            total_w;
        return .{ .width = w_out, .height = h_out };
    }

    fn paint(w: *Widget, ctx: *PaintContext) void {
        const self: *Self = @fieldParentPtr("base", w);
        const rx = ctx.offset_x + w.rect.x;
        const ry = ctx.offset_y + w.rect.y;

        const bg = if (self.pressed) self.bg_color else if (self.hovered) self.bg_hover else self.bg_color;
        const border = if (self.hovered) self.border_hover else self.border_color;

        ctx.renderer.fillRoundedRect(
            .{ .x = rx, .y = ry, .width = w.rect.width, .height = w.rect.height },
            self.corner_radius,
            bg,
        ) catch {};
        ctx.renderer.strokeRoundedRect(
            .{ .x = rx, .y = ry, .width = w.rect.width, .height = w.rect.height },
            self.corner_radius,
            1,
            border,
        ) catch {};

        const sx = rx + (self.size - self.swatch_size) / 2;
        const sy = ry + (self.size - self.swatch_size) / 2;
        ctx.renderer.fillRoundedRect(
            .{ .x = sx, .y = sy, .width = self.swatch_size, .height = self.swatch_size },
            self.corner_radius * 0.6,
            self.color,
        ) catch {};
        ctx.renderer.strokeRoundedRect(
            .{ .x = sx, .y = sy, .width = self.swatch_size, .height = self.swatch_size },
            self.corner_radius * 0.6,
            1,
            math.Color.hex(0x00000033),
        ) catch {};

        if (self.show_hex) {
            const hex = self.toHex();
            const hex_str: []const u8 = &hex;
            const ts = styled_text.measureText(ctx.allocator, hex_str[0..7], .{ .font_size = 13 });
            const ty = ry + (w.rect.height - ts.height) / 2;
            styled_text.drawText(ctx.renderer, ctx.allocator, hex_str[0..7], rx + self.size, ty, .{
                .font_size = 13,
                .color = self.text_color,
            });
        }
    }

    fn onEvent(w: *Widget, event: *const pal.Event, ectx: *EventContext) EventResult {
        const self: *Self = @fieldParentPtr("base", w);
        _ = ectx;

        switch (event.*) {
            .mouse_move => |mm| {
                const mx: f32 = @floatFromInt(mm.x);
                const my: f32 = @floatFromInt(mm.y);
                const inside = mx >= 0 and mx < w.rect.width and my >= 0 and my < w.rect.height;
                if (inside != self.hovered) {
                    self.hovered = inside;
                    self.base.markDirty();
                }
                return if (inside) .handled else .ignored;
            },
            .mouse_button => |mb| {
                if (mb.button == .left) {
                    const mx: f32 = @floatFromInt(mb.x);
                    const my: f32 = @floatFromInt(mb.y);
                    const inside = mx >= 0 and mx < w.rect.width and my >= 0 and my < w.rect.height;

                    if (mb.state == .pressed and inside) {
                        self.pressed = true;
                        self.base.markDirty();
                        return .handled;
                    } else if (mb.state == .released) {
                        const was_pressed = self.pressed;
                        self.pressed = false;
                        self.base.markDirty();
                        if (inside and was_pressed) {
                            // 简化：使用回调改变颜色，实际应弹出对话框
                            const colors = [_]math.Color{
                                math.Color.hex(0xEF4444FF),
                                math.Color.hex(0xF97316FF),
                                math.Color.hex(0xEAB308FF),
                                math.Color.hex(0x22C55EFF),
                                math.Color.hex(0x06B6D4FF),
                                math.Color.hex(0x3B82F6FF),
                                math.Color.hex(0x8B5CF6FF),
                                math.Color.hex(0xEC4899FF),
                            };
                            var idx: usize = 0;
                            var best_diff: f32 = std.math.inf(f32);
                            for (colors, 0..) |c, i| {
                                const dr = c.r - self.color.r;
                                const dg = c.g - self.color.g;
                                const db = c.b - self.color.b;
                                const diff = dr * dr + dg * dg + db * db;
                                if (diff < best_diff) {
                                    best_diff = diff;
                                    idx = i;
                                }
                            }
                            const new_idx = (idx + 1) % colors.len;
                            self.setColor(colors[new_idx]);
                            return .handled;
                        }
                    }
                }
            },
            .key => |key| {
                if (key.state == .pressed and (key.key == .enter or key.key == .space)) {
                    const colors = [_]math.Color{
                        math.Color.hex(0xEF4444FF),
                        math.Color.hex(0x22C55EFF),
                        math.Color.hex(0x3B82F6FF),
                    };
                    self.setColor(colors[@mod(self.color.r + self.color.g, colors.len)]);
                    return .handled;
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
