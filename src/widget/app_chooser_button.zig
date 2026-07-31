//! AppChooserButton 控件 - 应用选择按钮
//!
//! 类似 GtkAppChooserButton: 显示当前选择的应用程序的按钮, 点击后弹出应用选择对话框。
//! 支持显示应用名称和图标。

const std = @import("std");
const math = @import("../math.zig");
const widget_mod = @import("widget.zig");
const layout_mod = @import("../layout/engine.zig");
const pal = @import("../pal/pal.zig");
const styled_text = @import("../text/styled_text.zig");
const app_chooser_mod = @import("app_chooser.zig");

const Widget = widget_mod.Widget;
const PaintContext = widget_mod.PaintContext;
const EventContext = widget_mod.EventContext;
const EventResult = widget_mod.EventResult;
const AppInfo = app_chooser_mod.AppInfo;
const AppChooserDialog = app_chooser_mod.AppChooserDialog;

pub const AppChooserButton = struct {
    base: Widget,
    allocator: std.mem.Allocator,

    content_type: []const u8,
    selected_app: ?AppInfo = null,
    show_default_text: []const u8 = "选择应用",
    dialog_title: []const u8 = "选择应用",

    dialog: ?*AppChooserDialog = null,

    on_app_selected: ?*const fn (self: *AppChooserButton, app: AppInfo) void = null,

    bg_color: math.Color = math.Color.hex(0x334155FF),
    bg_hover: math.Color = math.Color.hex(0x475569FF),
    bg_pressed: math.Color = math.Color.hex(0x1E293BFF),
    text_color: math.Color = math.Color.hex(0xF8FAFCFF),
    corner_radius: f32 = 8.0,
    padding_h: f32 = 14.0,
    padding_v: f32 = 10.0,
    min_width: f32 = 150,
    min_height: f32 = 36,
    font_size: f32 = 14,

    const Self = @This();

    pub fn create(allocator: std.mem.Allocator, opts: struct {
        content_type: []const u8 = "application/octet-stream",
        show_default_text: []const u8 = "选择应用",
        dialog_title: []const u8 = "选择应用",
        on_app_selected: ?*const fn (self: *AppChooserButton, app: AppInfo) void = null,
        bg_color: math.Color = math.Color.hex(0x334155FF),
        bg_hover: math.Color = math.Color.hex(0x475569FF),
        bg_pressed: math.Color = math.Color.hex(0x1E293BFF),
        text_color: math.Color = math.Color.hex(0xF8FAFCFF),
        corner_radius: f32 = 8.0,
    }) !*AppChooserButton {
        const self = try allocator.create(AppChooserButton);
        self.* = .{
            .base = .{
                .vtable = &vtable,
                .id = widget_mod.genWidgetId(),
            },
            .allocator = allocator,
            .content_type = try allocator.dupe(u8, opts.content_type),
            .show_default_text = opts.show_default_text,
            .dialog_title = try allocator.dupe(u8, opts.dialog_title),
            .on_app_selected = opts.on_app_selected,
            .bg_color = opts.bg_color,
            .bg_hover = opts.bg_hover,
            .bg_pressed = opts.bg_pressed,
            .text_color = opts.text_color,
            .corner_radius = opts.corner_radius,
        };
        self.base.accessibility = .{ .role = .button, .label = opts.show_default_text };
        self.base.cursor = .pointing_hand;
        return self;
    }

    pub fn destroy(self: *Self, allocator: std.mem.Allocator) void {
        allocator.free(self.content_type);
        allocator.free(self.dialog_title);
        if (self.selected_app) |*app| {
            if (app.name.ptr != self.show_default_text.ptr) {
                allocator.free(app.name);
                allocator.free(app.exec);
                if (app.icon_name.len > 0) allocator.free(app.icon_name);
                if (app.desktop_id.len > 0) allocator.free(app.desktop_id);
            }
        }
        if (self.dialog) |dlg| {
            dlg.base.vtable.destroy(&dlg.base, allocator);
        }
        self.base.background.deinit(allocator);
        self.base.children.deinit(allocator);
        allocator.destroy(self);
    }

    pub fn getSelectedApp(self: *const Self) ?AppInfo {
        return self.selected_app;
    }

    pub fn setSelectedApp(self: *Self, app: ?AppInfo) void {
        if (self.selected_app) |*old| {
            if (old.name.ptr != self.show_default_text.ptr) {
                self.allocator.free(old.name);
                self.allocator.free(old.exec);
                if (old.icon_name.len > 0) self.allocator.free(old.icon_name);
                if (old.desktop_id.len > 0) self.allocator.free(old.desktop_id);
            }
        }
        if (app) |a| {
            const new_name = self.allocator.dupe(u8, a.name) catch {
                self.selected_app = null;
                return;
            };
            const new_exec = self.allocator.dupe(u8, a.exec) catch {
                self.allocator.free(new_name);
                self.selected_app = null;
                return;
            };
            const new_icon = if (a.icon_name.len > 0) (self.allocator.dupe(u8, a.icon_name) catch "") else "";
            const new_desktop = if (a.desktop_id.len > 0) (self.allocator.dupe(u8, a.desktop_id) catch "") else "";
            self.selected_app = .{
                .name = new_name,
                .exec = new_exec,
                .icon_name = new_icon,
                .desktop_id = new_desktop,
            };
            self.base.accessibility.label = new_name;
        } else {
            self.selected_app = null;
            self.base.accessibility.label = self.show_default_text;
        }
        self.base.markDirty();
    }

    fn getDisplayText(self: *Self) []const u8 {
        if (self.selected_app) |app| {
            return app.name;
        }
        return self.show_default_text;
    }

    fn ensureDialog(self: *Self) !*AppChooserDialog {
        if (self.dialog) |dlg| return dlg;

        const dlg = try AppChooserDialog.create(self.allocator, .{
            .title = self.dialog_title,
            .content_type = self.content_type,
            .on_app_selected = onDialogAppSelected,
            .on_cancel = onDialogCancel,
        });
        dlg.base.parent = &self.base;
        self.dialog = dlg;
        return dlg;
    }

    fn onDialogAppSelected(dlg: *AppChooserDialog, app: AppInfo) void {
        const self: *Self = @fieldParentPtr("base", dlg.base.parent.?);
        dlg.visible = false;
        self.setSelectedApp(app);
        if (self.on_app_selected) |cb| {
            cb(self, app);
        }
    }

    fn onDialogCancel(dlg: *AppChooserDialog) void {
        dlg.visible = false;
    }

    const vtable = Widget.VTable{
        .type_name = "app_chooser_button",
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
        _ = constraints;

        const text = self.getDisplayText();
        const text_size = styled_text.measureText(ctx.allocator, text, .{
            .font_size = self.font_size,
            .font_weight = 500,
        });

        const w_used = @max(self.min_width, text_size.width + self.padding_h * 2 + 20);
        const h_used = @max(self.min_height, text_size.height + self.padding_v * 2);

        return .{ .width = w_used, .height = h_used };
    }

    fn paint(w: *Widget, ctx: *PaintContext) void {
        const self: *Self = @fieldParentPtr("base", w);

        const bg = if (w.state.pressed)
            self.bg_pressed
        else if (w.state.hovered)
            self.bg_hover
        else
            self.bg_color;

        const rx = ctx.offset_x + w.rect.x;
        const ry = ctx.offset_y + w.rect.y;

        ctx.renderer.fillRoundedRect(
            .{ .x = rx, .y = ry, .width = w.rect.width, .height = w.rect.height },
            self.corner_radius,
            bg,
        ) catch {};

        if (w.state.focused) {
            ctx.renderer.fillRoundedRect(
                .{ .x = rx - 2, .y = ry - 2, .width = w.rect.width + 4, .height = w.rect.height + 4 },
                self.corner_radius + 2,
                math.Color.hex(0x3B82F644),
            ) catch {};
        }

        const text = self.getDisplayText();
        const text_size = styled_text.measureText(ctx.allocator, text, .{
            .font_size = self.font_size,
            .font_weight = 500,
        });
        const text_x = rx + self.padding_h;
        const text_y = ry + (w.rect.height - text_size.height) / 2;

        styled_text.drawText(
            ctx.renderer,
            ctx.allocator,
            text,
            text_x,
            text_y,
            .{
                .font_size = self.font_size,
                .font_weight = 500,
                .color = self.text_color,
            },
        );

        const arrow_size: f32 = 8;
        const arrow_x = rx + w.rect.width - self.padding_h - arrow_size;
        const arrow_y = ry + (w.rect.height - arrow_size) / 2;
        self.drawArrow(ctx, arrow_x, arrow_y, arrow_size);

        if (self.dialog) |dlg| {
            if (dlg.visible) {
                dlg.base.paintTree(ctx);
            }
        }
    }

    fn drawArrow(self: *Self, ctx: *PaintContext, x: f32, y: f32, size: f32) void {
        const s = size;
        ctx.renderer.fillRect(.{ .x = x + s / 2 - 1, .y = y, .width = 2.0, .height = 2.0 }, self.text_color) catch {};
        ctx.renderer.fillRect(.{ .x = x + s / 2 - 2, .y = y + 2, .width = 4.0, .height = 2.0 }, self.text_color) catch {};
        if (s >= 6) {
            ctx.renderer.fillRect(.{ .x = x + s / 2 - 3, .y = y + 4, .width = 6.0, .height = 2.0 }, self.text_color) catch {};
        }
    }

    fn onEvent(w: *Widget, event: *const pal.Event, ectx: *EventContext) EventResult {
        const self: *Self = @fieldParentPtr("base", w);

        if (self.dialog) |dlg| {
            if (dlg.visible) {
                const result = dlg.base.dispatchEvent(event, ectx);
                if (result == .handled) return .handled;
            }
        }

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
                            const dlg = self.ensureDialog() catch return .handled;
                            dlg.show();
                            w.markDirty();
                        }
                        return .handled;
                    }
                }
                return .handled;
            },
            .mouse_move => |mm| {
                _ = mm;
                return .handled;
            },
            .key => |key| {
                if (key.state == .pressed) {
                    if (key.key == .space or key.key == .enter or key.key == .kp_enter) {
                        const dlg = self.ensureDialog() catch return .handled;
                        dlg.show();
                        return .handled;
                    }
                    if (key.key == .escape) {
                        if (self.dialog) |dlg| {
                            if (dlg.visible) {
                                dlg.visible = false;
                                return .handled;
                            }
                        }
                    }
                }
                return .ignored;
            },
            else => return .ignored,
        }
    }
};
