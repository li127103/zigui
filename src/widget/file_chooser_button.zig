//! FileChooserButton 控件 - 文件选择按钮
//!
//! 对标 GtkFileChooserButton: 显示当前选择文件的按钮, 点击后弹出文件选择对话框。
//! 支持打开文件和保存文件两种模式。

const std = @import("std");
const math = @import("../math.zig");
const widget_mod = @import("widget.zig");
const layout_mod = @import("../layout/engine.zig");
const pal = @import("../pal/pal.zig");
const styled_text = @import("../text/styled_text.zig");
const file_chooser_mod = @import("file_chooser.zig");

const Widget = widget_mod.Widget;
const PaintContext = widget_mod.PaintContext;
const EventContext = widget_mod.EventContext;
const EventResult = widget_mod.EventResult;
const FileChooser = file_chooser_mod.FileChooser;
const FileChooserMode = file_chooser_mod.FileChooserMode;
const FileFilter = file_chooser_mod.FileFilter;

pub const FileChooserButton = struct {
    base: Widget,
    allocator: std.mem.Allocator,

    mode: FileChooserMode = .open,
    title: []const u8 = "选择文件",
    selected_file: []const u8 = "",
    default_label: []const u8 = "选择文件",
    dialog: ?*FileChooser = null,

    filter: ?FileFilter = null,

    on_file_selected: ?*const fn (self: *FileChooserButton, path: []const u8) void = null,

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
        mode: FileChooserMode = .open,
        title: []const u8 = "选择文件",
        default_label: []const u8 = "选择文件",
        filter: ?FileFilter = null,
        on_file_selected: ?*const fn (self: *FileChooserButton, path: []const u8) void = null,
        bg_color: math.Color = math.Color.hex(0x334155FF),
        bg_hover: math.Color = math.Color.hex(0x475569FF),
        bg_pressed: math.Color = math.Color.hex(0x1E293BFF),
        text_color: math.Color = math.Color.hex(0xF8FAFCFF),
        corner_radius: f32 = 8.0,
    }) !*FileChooserButton {
        const self = try allocator.create(FileChooserButton);
        self.* = .{
            .base = .{
                .vtable = &vtable,
                .id = widget_mod.genWidgetId(),
            },
            .allocator = allocator,
            .mode = opts.mode,
            .title = try allocator.dupe(u8, opts.title),
            .default_label = opts.default_label,
            .filter = opts.filter,
            .on_file_selected = opts.on_file_selected,
            .bg_color = opts.bg_color,
            .bg_hover = opts.bg_hover,
            .bg_pressed = opts.bg_pressed,
            .text_color = opts.text_color,
            .corner_radius = opts.corner_radius,
        };
        self.base.accessibility = .{ .role = .button, .label = opts.default_label };
        self.base.cursor = .pointing_hand;
        return self;
    }

    pub fn destroy(self: *Self, allocator: std.mem.Allocator) void {
        allocator.free(self.title);
        if (self.selected_file.len > 0) {
            allocator.free(self.selected_file);
        }
        if (self.dialog) |dlg| {
            dlg.destroy(allocator);
        }
        self.base.background.deinit(allocator);
        self.base.children.deinit(allocator);
        allocator.destroy(self);
    }

    pub fn getFilename(self: *const Self) []const u8 {
        return self.selected_file;
    }

    pub fn setFilename(self: *Self, path: []const u8) void {
        if (self.selected_file.len > 0) {
            self.allocator.free(self.selected_file);
        }
        self.selected_file = self.allocator.dupe(u8, path) catch "";
        self.base.accessibility.label = if (self.selected_file.len > 0) self.selected_file else self.default_label;
        self.base.markDirty();
    }

    fn getDisplayText(self: *Self) []const u8 {
        if (self.selected_file.len > 0) {
            return getBasename(self.selected_file);
        }
        return self.default_label;
    }

    fn getBasename(path: []const u8) []const u8 {
        var i = path.len;
        while (i > 0) {
            i -= 1;
            if (path[i] == '/' or path[i] == '\\') {
                return path[i + 1 ..];
            }
        }
        return path;
    }

    fn ensureDialog(self: *Self) !*FileChooser {
        if (self.dialog) |dlg| return dlg;

        const dlg = try FileChooser.create(self.allocator, .{
            .mode = self.mode,
            .title = self.title,
            .on_file_selected = onDialogFileSelected,
            .on_cancel = onDialogCancel,
        });
        if (self.filter) |f| {
            dlg.filter = f;
        }
        dlg.base.parent = &self.base;
        self.dialog = dlg;
        return dlg;
    }

    fn onDialogFileSelected(dlg: *FileChooser, path: []const u8) void {
        const self: *Self = @fieldParentPtr("base", dlg.base.parent.?);
        dlg.visible = false;
        self.setFilename(path);
        if (self.on_file_selected) |cb| {
            cb(self, path);
        }
    }

    fn onDialogCancel(dlg: *FileChooser) void {
        dlg.visible = false;
    }

    const vtable = Widget.VTable{
        .type_name = "file_chooser_button",
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

        const icon_size: f32 = 16;
        const icon_x = rx + w.rect.width - self.padding_h - icon_size;
        const icon_y = ry + (w.rect.height - icon_size) / 2;
        self.drawFolderIcon(ctx, icon_x, icon_y, icon_size);

        if (self.dialog) |dlg| {
            if (dlg.visible) {
                dlg.paintTree(ctx);
            }
        }
    }

    fn drawFolderIcon(self: *Self, ctx: *PaintContext, x: f32, y: f32, size: f32) void {
        const r2d = ctx.renderer;
        const color = self.text_color;
        const scale = size / 16.0;

        r2d.fillRoundedRect(
            .{
                .x = x + 0 * scale,
                .y = y + 4 * scale,
                .width = 16 * scale,
                .height = 10 * scale,
            },
            2 * scale,
            color,
        ) catch {};

        r2d.fillRect(
            .{
                .x = x + 0 * scale,
                .y = y + 7 * scale,
                .width = 16 * scale,
                .height = 7 * scale,
            },
            color,
        ) catch {};

        r2d.fillRoundedRect(
            .{
                .x = x + 0 * scale,
                .y = y + 2 * scale,
                .width = 6 * scale,
                .height = 5 * scale,
            },
            1 * scale,
            color,
        ) catch {};
    }

    fn onEvent(w: *Widget, event: *const pal.Event, ectx: *EventContext) EventResult {
        const self: *Self = @fieldParentPtr("base", w);

        if (self.dialog) |dlg| {
            if (dlg.visible) {
                const result = dlg.dispatchEvent(event, ectx);
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
                    if (key.keycode == .space or key.keycode == .enter or key.keycode == .kp_enter) {
                        const dlg = self.ensureDialog() catch return .handled;
                        dlg.show();
                        return .handled;
                    }
                    if (key.keycode == .escape) {
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
