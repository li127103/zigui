//! FontButton 控件 - 字体选择按钮
//!
//! 显示当前字体名称的按钮, 点击弹出字体选择对话框。
//!
//! 使用方法:
//! ```
//! var btn = try FontButton.create(allocator, .{
//!     .family = "Sans",
//!     .size = 14,
//!     .on_font_changed = onFontChanged,
//! });
//! ```

const std = @import("std");
const math = @import("../math.zig");
const widget_mod = @import("widget.zig");
const pal = @import("../pal/pal.zig");
const button_mod = @import("button.zig");
const font_chooser_mod = @import("font_chooser.zig");
const styled_text = @import("../text/styled_text.zig");

const Widget = widget_mod.Widget;
const PaintContext = widget_mod.PaintContext;
const EventContext = widget_mod.EventContext;
const EventResult = widget_mod.EventResult;
const Button = button_mod.Button;
const FontChooserDialog = font_chooser_mod.FontChooserDialog;
const FontDesc = font_chooser_mod.FontDesc;

pub const FontButton = struct {
    base: Widget,
    allocator: std.mem.Allocator,
    family: []const u8,
    size: f32,
    bold: bool,
    italic: bool,
    on_font_changed: ?*const fn (self: *FontButton, desc: FontDesc) void = null,
    dialog: ?*FontChooserDialog = null,

    corner_radius: f32 = 6,
    bg_color: math.Color = math.Color.hex(0x334155FF),
    text_color: math.Color = math.Color.hex(0xF1F5FFFF),
    border_color: math.Color = math.Color.hex(0x475569FF),
    border_width: f32 = 1,
    min_width: f32 = 150,
    height: f32 = 32,

    const Self = @This();

    pub fn create(allocator: std.mem.Allocator, opts: struct {
        family: []const u8 = "Sans",
        size: f32 = 14,
        bold: bool = false,
        italic: bool = false,
        on_font_changed: ?*const fn (self: *FontButton, desc: FontDesc) void = null,
        corner_radius: f32 = 6,
        min_width: f32 = 150,
        height: f32 = 32,
    }) !*FontButton {
        const self = try allocator.create(FontButton);
        self.* = .{
            .base = .{
                .vtable = &vtable,
                .id = widget_mod.genWidgetId(),
            },
            .allocator = allocator,
            .family = try allocator.dupe(u8, opts.family),
            .size = opts.size,
            .bold = opts.bold,
            .italic = opts.italic,
            .on_font_changed = opts.on_font_changed,
            .corner_radius = opts.corner_radius,
            .min_width = opts.min_width,
            .height = opts.height,
        };
        self.base.cursor = .pointing_hand;
        self.base.tooltip_text = "点击选择字体";
        return self;
    }

    pub fn destroy(self: *Self, allocator: std.mem.Allocator) void {
        allocator.free(self.family);
        self.base.background.deinit(allocator);
        self.base.children.deinit(allocator);
        if (self.dialog) |dlg| {
            dlg.base.vtable.destroy(&dlg.base, allocator);
        }
        allocator.destroy(self);
    }

    pub fn setFont(self: *Self, desc: FontDesc) void {
        self.allocator.free(self.family);
        self.family = self.allocator.dupe(u8, desc.family) catch return;
        self.size = desc.size;
        self.bold = desc.bold;
        self.italic = desc.italic;
        self.base.markDirty();
        if (self.on_font_changed) |cb| cb(self, desc);
    }

    pub fn getFont(self: *const Self) FontDesc {
        return .{
            .family = self.family,
            .size = self.size,
            .bold = self.bold,
            .italic = self.italic,
        };
    }

    fn openDialog(self: *Self) void {
        if (self.dialog) |dlg| {
            dlg.show();
            return;
        }

        const dlg = FontChooserDialog.create(self.allocator, .{
            .initial_family = self.family,
            .initial_size = self.size,
            .initial_bold = self.bold,
            .initial_italic = self.italic,
            .on_font_selected = onDialogFontSelected,
            .on_cancel = onDialogCancel,
        }) catch return;

        dlg.base.user_data = self;
        self.dialog = dlg;

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

    fn onDialogFontSelected(dlg: *FontChooserDialog, desc: FontDesc) void {
        const self: *Self = @ptrCast(@alignCast(dlg.base.user_data orelse return));
        self.setFont(desc);
    }

    fn onDialogCancel(_: *FontChooserDialog) void {}

    const vtable = Widget.VTable{
        .type_name = "font_button",
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
        const w_val = @max(self.min_width, 100);
        return constraints.constrain(.{ .width = w_val, .height = self.height });
    }

    fn paint(w: *Widget, ctx: *PaintContext) void {
        const self: *Self = @fieldParentPtr("base", w);
        const rect = w.rect;

        ctx.renderer.fillRoundedRect(rect, self.corner_radius, self.border_color) catch {};

        const inner = math.Rect(f32){
            .x = rect.x + self.border_width,
            .y = rect.y + self.border_width,
            .width = @max(0, rect.width - self.border_width * 2),
            .height = @max(0, rect.height - self.border_width * 2),
        };
        ctx.renderer.fillRoundedRect(inner, @max(0, self.corner_radius - self.border_width), self.bg_color) catch {};

        const text = self.family;
        const font_size: f32 = 13;
        const text_y = rect.y + (rect.height - font_size) / 2 + font_size * 0.8;

        styled_text.drawText(
            ctx.renderer,
            ctx.allocator,
            text,
            rect.x + 10,
            text_y,
            .{
                .font_size = font_size,
                .color = self.text_color,
                .font_weight = if (self.bold) 700 else 400,
            },
        );
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
