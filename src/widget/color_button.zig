//! ColorButton 控件 - 颜色选择按钮
//!
//! 显示当前颜色的按钮, 点击弹出颜色选择对话框。
//!
//! 使用方法:
//! ```
//! var btn = try ColorButton.create(allocator, .{
//!     .color = math.Color.hex(0x3B82F6FF),
//!     .on_color_changed = onColorChanged,
//! });
//! ```

const std = @import("std");
const math = @import("../math.zig");
const widget_mod = @import("widget.zig");
const pal = @import("../pal/pal.zig");
const button_mod = @import("button.zig");
const color_chooser_mod = @import("color_chooser.zig");

const Widget = widget_mod.Widget;
const PaintContext = widget_mod.PaintContext;
const EventContext = widget_mod.EventContext;
const EventResult = widget_mod.EventResult;
const Button = button_mod.Button;
const ColorChooserDialog = color_chooser_mod.ColorChooserDialog;

pub const ColorButton = struct {
    base: Widget,
    allocator: std.mem.Allocator,
    color: math.Color,
    on_color_changed: ?*const fn (self: *ColorButton, color: math.Color) void = null,
    dialog: ?*ColorChooserDialog = null,
    // 样式
    corner_radius: f32 = 6,
    border_width: f32 = 2,
    border_color: math.Color = math.Color.hex(0x475569FF),
    button_size: f32 = 32,

    const Self = @This();

    pub fn create(allocator: std.mem.Allocator, opts: struct {
        color: math.Color = math.Color.hex(0x3B82F6FF),
        on_color_changed: ?*const fn (self: *ColorButton, color: math.Color) void = null,
        corner_radius: f32 = 6,
        border_width: f32 = 2,
        button_size: f32 = 32,
    }) !*ColorButton {
        const self = try allocator.create(ColorButton);
        self.* = .{
            .base = .{
                .vtable = &vtable,
                .id = widget_mod.genWidgetId(),
            },
            .allocator = allocator,
            .color = opts.color,
            .on_color_changed = opts.on_color_changed,
            .corner_radius = opts.corner_radius,
            .border_width = opts.border_width,
            .button_size = opts.button_size,
        };
        self.base.cursor = .pointing_hand;
        return self;
    }

    pub fn destroy(self: *Self, allocator: std.mem.Allocator) void {
        self.base.background.deinit(allocator);
        self.base.children.deinit(allocator);
        if (self.dialog) |dlg| {
            dlg.base.vtable.destroy(&dlg.base, allocator);
        }
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

    fn openDialog(self: *Self) void {
        if (self.dialog) |dlg| {
            dlg.current_color = self.color;
            dlg.show();
            return;
        }

        const dlg = ColorChooserDialog.create(self.allocator, .{
            .initial_color = self.color,
            .on_color_selected = onDialogColorSelected,
            .on_cancel = onDialogCancel,
        }) catch return;

        dlg.base.user_data = self;
        self.dialog = dlg;

        // 添加到根控件
        var root = &self.base;
        while (root.parent) |p| {
            root = p;
        }
        root.addChild(self.allocator, &dlg.base) catch {
            dlg.destroy(self.allocator);
            return;
        };

        dlg.show();
    }

    fn onDialogColorSelected(dlg: *ColorChooserDialog, color: math.Color) void {
        const self: *Self = @ptrCast(@alignCast(dlg.base.user_data orelse return));
        self.setColor(color);
    }

    fn onDialogCancel(dlg: *ColorChooserDialog) void {
        _ = dlg;
    }

    // ── VTable ──────────────────────────────────────────────────────────────

    const vtable = Widget.VTable{
        .type_name = "color_button",
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

    fn measure(w: *Widget, ctx: *PaintContext, constraints: @import("../layout/engine.zig").Constraints) math.Size(f32) {
        const self: *Self = @fieldParentPtr("base", w);
        _ = ctx;
        const size = self.button_size + self.border_width * 2;
        return constraints.constrain(.{ .width = size, .height = size });
    }

    fn paint(w: *Widget, ctx: *PaintContext) void {
        const self: *Self = @fieldParentPtr("base", w);
        const rect = w.rect;

        // 边框
        ctx.renderer.fillRoundedRect(rect, self.corner_radius, self.border_color) catch {};

        // 内部颜色
        const inner = math.Rect(f32){
            .x = rect.x + self.border_width,
            .y = rect.y + self.border_width,
            .width = rect.width - self.border_width * 2,
            .height = rect.height - self.border_width * 2,
        };
        ctx.renderer.fillRoundedRect(inner, self.corner_radius - self.border_width, self.color) catch {};
    }

    fn onEvent(w: *Widget, event: *const pal.Event, ectx: *EventContext) EventResult {
        const self: *Self = @fieldParentPtr("base", w);
        _ = ectx;

        switch (event.*) {
            .mouse_button => |mb| {
                if (mb.button == .left and mb.state == .pressed) {
                    self.openDialog();
                    return .handled;
                }
            },
            .key => |k| {
                if (k.state == .pressed and (k.key == .space or k.key == .enter)) {
                    self.openDialog();
                    return .handled;
                }
            },
            else => {},
        }

        return .ignored;
    }
};
