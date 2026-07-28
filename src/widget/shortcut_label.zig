//! ShortcutLabel 控件 - 快捷键标签
//!
//! 类似 GtkShortcutLabel: 显示键盘快捷键的标签, 如 "Ctrl+C"、"Ctrl+Shift+Z"。
//! 自动格式化修饰键和主键, 支持可定制的分隔符和样式。

const std = @import("std");
const math = @import("../math.zig");
const widget_mod = @import("widget.zig");
const layout_mod = @import("../layout/engine.zig");
const styled_text = @import("../text/styled_text.zig");
const pal = @import("../pal/pal.zig");

const Widget = widget_mod.Widget;
const PaintContext = widget_mod.PaintContext;
const EventContext = widget_mod.EventContext;
const EventResult = widget_mod.EventResult;

/// 修饰键
pub const Modifier = enum {
    ctrl,
    shift,
    alt,
    super,
    meta,
    hyper,
};

/// 快捷键定义
pub const Shortcut = struct {
    modifiers: []const Modifier = &.{},
    key: []const u8,
};

pub const ShortcutLabel = struct {
    base: Widget,
    allocator: std.mem.Allocator,

    shortcut: Shortcut,
    display_text: []const u8 = "",

    text_color: math.Color = math.Color.hex(0x94A3B8FF),
    bg_color: math.Color = math.Color.hex(0x1E293BFF),
    border_color: math.Color = math.Color.hex(0x334155FF),
    corner_radius: f32 = 6.0,
    padding_h: f32 = 8.0,
    padding_v: f32 = 3.0,
    font_size: f32 = 12,
    font_weight: u32 = 500,
    border_width: f32 = 1.0,

    const Self = @This();

    pub fn create(allocator: std.mem.Allocator, opts: struct {
        shortcut: Shortcut,
        text_color: math.Color = math.Color.hex(0x94A3B8FF),
        bg_color: math.Color = math.Color.hex(0x1E293BFF),
        border_color: math.Color = math.Color.hex(0x334155FF),
        corner_radius: f32 = 6.0,
        font_size: f32 = 12,
    }) !*ShortcutLabel {
        const self = try allocator.create(ShortcutLabel);
        self.* = .{
            .base = .{
                .vtable = &vtable,
                .id = widget_mod.genWidgetId(),
            },
            .allocator = allocator,
            .shortcut = opts.shortcut,
            .text_color = opts.text_color,
            .bg_color = opts.bg_color,
            .border_color = opts.border_color,
            .corner_radius = opts.corner_radius,
            .font_size = opts.font_size,
        };
        self.display_text = try self.formatShortcut(allocator);
        self.base.accessibility = .{
            .role = .label,
            .label = self.display_text,
        };
        return self;
    }

    pub fn destroy(self: *Self, allocator: std.mem.Allocator) void {
        allocator.free(self.display_text);
        self.base.background.deinit(allocator);
        self.base.children.deinit(allocator);
        allocator.destroy(self);
    }

    pub fn setShortcut(self: *Self, shortcut: Shortcut) !void {
        self.allocator.free(self.display_text);
        self.shortcut = shortcut;
        self.display_text = try self.formatShortcut(self.allocator);
        self.base.accessibility.label = self.display_text;
        self.base.markDirty();
        self.base.markLayoutDirty();
    }

    fn modToString(mod: Modifier) []const u8 {
        return switch (mod) {
            .ctrl => "Ctrl",
            .shift => "Shift",
            .alt => "Alt",
            .super => "Super",
            .meta => "Meta",
            .hyper => "Hyper",
        };
    }

    fn formatShortcut(self: *Self, allocator: std.mem.Allocator) ![]const u8 {
        var buf = std.ArrayList(u8).init(allocator);
        errdefer buf.deinit();

        const writer = buf.writer();

        for (self.shortcut.modifiers) |mod| {
            try writer.writeAll(modToString(mod));
            try writer.writeAll("+");
        }

        try writer.writeAll(self.shortcut.key);

        return try buf.toOwnedSlice();
    }

    const vtable = Widget.VTable{
        .type_name = "shortcut_label",
        .measure = measure,
        .paint = paint,
        .on_event = onEvent,
        .focusable = false,
        .destroy = destroyVTable,
    };

    fn destroyVTable(w: *Widget, allocator: std.mem.Allocator) void {
        const self: *Self = @fieldParentPtr("base", w);
        self.destroy(allocator);
    }

    fn measure(w: *Widget, ctx: *PaintContext, constraints: layout_mod.Constraints) math.Size(f32) {
        const self: *Self = @fieldParentPtr("base", w);
        _ = constraints;

        const text_size = styled_text.measureText(ctx.allocator, self.display_text, .{
            .font_size = self.font_size,
            .font_weight = self.font_weight,
        });

        const w_used = text_size.width + self.padding_h * 2;
        const h_used = text_size.height + self.padding_v * 2;

        return .{ .width = w_used, .height = h_used };
    }

    fn paint(w: *Widget, ctx: *PaintContext) void {
        const self: *Self = @fieldParentPtr("base", w);

        const rx = ctx.offset_x + w.rect.x;
        const ry = ctx.offset_y + w.rect.y;

        ctx.renderer.fillRoundedRect(
            .{ .x = rx, .y = ry, .width = w.rect.width, .height = w.rect.height },
            self.corner_radius,
            self.bg_color,
        ) catch {};

        if (self.border_width > 0) {
            ctx.renderer.strokeRoundedRect(
                .{ .x = rx, .y = ry, .width = w.rect.width, .height = w.rect.height },
                self.corner_radius,
                self.border_width,
                self.border_color,
            ) catch {};
        }

        const text_size = styled_text.measureText(ctx.allocator, self.display_text, .{
            .font_size = self.font_size,
            .font_weight = self.font_weight,
        });
        const text_x = rx + self.padding_h;
        const text_y = ry + (w.rect.height - text_size.height) / 2;

        styled_text.drawText(
            ctx.renderer,
            ctx.allocator,
            self.display_text,
            text_x,
            text_y,
            .{
                .font_size = self.font_size,
                .font_weight = self.font_weight,
                .color = self.text_color,
            },
        );
    }

    fn onEvent(w: *Widget, event: *const pal.Event, ectx: *EventContext) EventResult {
        _ = w;
        _ = event;
        _ = ectx;
        return .ignored;
    }
};
