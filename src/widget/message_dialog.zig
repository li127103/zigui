//! MessageDialog 控件 - 标准消息对话框
//!
//! 封装 Dialog, 提供 info / warning / error / question 四种类型的标准消息框,
//! 可自定义按钮 (ok / ok_cancel / yes_no / yes_no_cancel)。
//!
//! 使用方法:
//! ```
//! var dlg = try MessageDialog.create(allocator, .{
//!     .kind = .info,
//!     .title = "提示",
//!     .message = "操作成功完成",
//!     .buttons = .ok,
//! });
//! dlg.show();
//! ```

const std = @import("std");
const math = @import("../math.zig");
const widget_mod = @import("widget.zig");
const dialog_mod = @import("dialog.zig");
const layout_mod = @import("../layout/engine.zig");
const pal = @import("../pal/pal.zig");
const styled_text = @import("../text/styled_text.zig");

const Widget = widget_mod.Widget;
const PaintContext = widget_mod.PaintContext;
const EventContext = widget_mod.EventContext;
const EventResult = widget_mod.EventResult;

pub const MessageDialogKind = enum {
    info,
    warning,
    err,
    question,
};

pub const MessageDialogButtons = enum {
    ok,
    ok_cancel,
    yes_no,
    yes_no_cancel,
};

pub const MessageDialogResult = enum {
    ok,
    cancel,
    yes,
    no,
};

pub const MessageDialog = struct {
    base: Widget,
    allocator: std.mem.Allocator,
    kind: MessageDialogKind,
    buttons: MessageDialogButtons,
    title: []const u8,
    message: []const u8,
    visible: bool,
    on_result: ?*const fn (self: *MessageDialog, result: MessageDialogResult) void,
    // 样式
    overlay_color: math.Color,
    bg_color: math.Color,
    title_color: math.Color,
    message_color: math.Color,
    corner_radius: f32,
    dialog_width: f32,
    title_size: f32,
    message_size: f32,

    pub fn create(allocator: std.mem.Allocator, opts: struct {
        kind: MessageDialogKind = .info,
        buttons: MessageDialogButtons = .ok,
        title: []const u8 = "Message",
        message: []const u8 = "",
        on_result: ?*const fn (self: *MessageDialog, result: MessageDialogResult) void = null,
        overlay_color: math.Color = math.Color.hex(0x000000AA),
        bg_color: math.Color = math.Color.hex(0x1E293BFF),
        title_color: math.Color = math.Color.hex(0xF8FAFCFF),
        message_color: math.Color = math.Color.hex(0xCBD5E1FF),
        corner_radius: f32 = 14.0,
        dialog_width: f32 = 420,
        title_size: f32 = 18.0,
        message_size: f32 = 14.0,
    }) !*MessageDialog {
        const self = try allocator.create(MessageDialog);
        self.* = .{
            .base = .{
                .vtable = &vtable,
                .id = widget_mod.genWidgetId(),
            },
            .allocator = allocator,
            .kind = opts.kind,
            .buttons = opts.buttons,
            .title = opts.title,
            .message = opts.message,
            .visible = false,
            .on_result = opts.on_result,
            .overlay_color = opts.overlay_color,
            .bg_color = opts.bg_color,
            .title_color = opts.title_color,
            .message_color = opts.message_color,
            .corner_radius = opts.corner_radius,
            .dialog_width = opts.dialog_width,
            .title_size = opts.title_size,
            .message_size = opts.message_size,
        };
        self.base.accessibility = .{ .role = .dialog, .label = opts.title };
        return self;
    }

    pub fn destroy(self: *MessageDialog, allocator: std.mem.Allocator) void {
        self.base.background.deinit(allocator);
        self.base.children.deinit(allocator);
        allocator.destroy(self);
    }

    pub fn show(self: *MessageDialog) void {
        self.visible = true;
        self.base.markDirty();
    }

    pub fn hide(self: *MessageDialog) void {
        self.visible = false;
        self.base.markDirty();
    }

    fn closeWithResult(self: *MessageDialog, result: MessageDialogResult) void {
        self.hide();
        if (self.on_result) |cb| {
            cb(self, result);
        }
    }

    fn kindIconChar(self: *const MessageDialog) []const u8 {
        return switch (self.kind) {
            .info => "ℹ",
            .warning => "⚠",
            .err => "✕",
            .question => "?",
        };
    }

    fn kindColor(self: *const MessageDialog) math.Color {
        return switch (self.kind) {
            .info => math.Color.hex(0x3B82F6FF),
            .warning => math.Color.hex(0xF59E0BFF),
            .err => math.Color.hex(0xEF4444FF),
            .question => math.Color.hex(0x8B5CF6FF),
        };
    }

    fn estimateDialogHeight(self: *const MessageDialog) f32 {
        _ = self;
        var h: f32 = 80; // 标题区 + 上边距
        h += 60; // 消息区 (至少一行)
        h += 70; // 按钮区
        return @max(h, 180);
    }

    // ── VTable ──────────────────────────────────────────────────────────────

    const vtable = Widget.VTable{
        .type_name = "message_dialog",
        .measure = measure,
        .paint = paint,
        .on_event = onEvent,
        .focusable = false,
        .destroy = destroyVTable,
    };

    fn destroyVTable(w: *Widget, allocator: std.mem.Allocator) void {
        const self: *MessageDialog = @fieldParentPtr("base", w);
        self.destroy(allocator);
    }

    fn measure(w: *Widget, ctx: *PaintContext, constraints: layout_mod.Constraints) math.Size(f32) {
        _ = ctx;
        _ = w;
        return .{ .width = constraints.max_width, .height = constraints.max_height };
    }

    fn paint(w: *Widget, ctx: *PaintContext) void {
        const self: *MessageDialog = @fieldParentPtr("base", w);
        if (!self.visible) return;

        const rx = ctx.offset_x + w.rect.x;
        const ry = ctx.offset_y + w.rect.y;
        const rw = w.rect.width;
        const rh = w.rect.height;

        ctx.renderer.fillRect(.{ .x = rx, .y = ry, .width = rw, .height = rh }, self.overlay_color) catch {};

        const dw = self.dialog_width;
        const dh = self.estimateDialogHeight();
        const dx = rx + (rw - dw) / 2.0;
        const dy = ry + (rh - dh) / 2.0;

        ctx.renderer.fillRoundedRect(.{ .x = dx, .y = dy, .width = dw, .height = dh }, self.corner_radius, self.bg_color) catch {};

        // 图标 (左侧大图标)
        const icon_size = 40;
        const icon_x = dx + 24;
        const icon_y = dy + 24;
        ctx.renderer.fillRoundedRect(
            .{ .x = icon_x, .y = icon_y, .width = icon_size, .height = icon_size },
            8,
            self.kindColor(),
        ) catch {};
        const icon_label = self.kindIconChar();
        styled_text.drawText(
            ctx.renderer,
            ctx.allocator,
            icon_label,
            icon_x + 12,
            icon_y + 6,
            .{ .font_size = 24, .color = math.Color.hex(0xFFFFFFFF), .font_weight = 700 },
        );

        // 标题
        const title_x = icon_x + icon_size + 16;
        styled_text.drawText(
            ctx.renderer,
            ctx.allocator,
            self.title,
            title_x,
            dy + 30,
            .{ .font_size = self.title_size, .color = self.title_color, .font_weight = 600 },
        );

        // 消息
        const msg_x = dx + 24;
        const msg_y = dy + 80;
        styled_text.drawText(
            ctx.renderer,
            ctx.allocator,
            self.message,
            msg_x,
            msg_y,
            .{ .font_size = self.message_size, .color = self.message_color },
        );

        // 按钮
        const btn_y = dy + dh - 52;
        const btn_h: f32 = 34;
        const secondary_bg = math.Color.hex(0x334155FF);
        const secondary_fg = math.Color.hex(0xCBD5E1FF);
        const primary_bg = math.Color.hex(0x3B82F6FF);
        const primary_fg = math.Color.hex(0xFFFFFFFF);

        var btn_x: f32 = dx + dw - 24;
        const button_configs = self.buttonConfigs();
        for (button_configs) |btn| {
            const w_btn = btn.width;
            btn_x -= w_btn + 8;
            const bg = if (btn.is_primary) primary_bg else secondary_bg;
            const fg = if (btn.is_primary) primary_fg else secondary_fg;
            ctx.renderer.fillRoundedRect(.{ .x = btn_x, .y = btn_y, .width = w_btn, .height = btn_h }, 7, bg) catch {};
            const label_size = styled_text.measureText(ctx.allocator, btn.label, .{ .font_size = 13, .font_weight = 500 });
            const label_x = btn_x + (w_btn - label_size.width) / 2.0;
            const label_y = btn_y + (btn_h - label_size.height) / 2.0 + 1;
            styled_text.drawText(ctx.renderer, ctx.allocator, btn.label, label_x, label_y, .{ .font_size = 13, .color = fg, .font_weight = 500 });
        }
    }

    const ButtonConfig = struct {
        label: []const u8,
        width: f32,
        is_primary: bool,
        result: MessageDialogResult,
    };

    fn buttonConfigs(self: *const MessageDialog) []const ButtonConfig {
        return switch (self.buttons) {
            .ok => &[_]ButtonConfig{.{ .label = "OK", .width = 80, .is_primary = true, .result = .ok }},
            .ok_cancel => &[_]ButtonConfig{
                .{ .label = "Cancel", .width = 80, .is_primary = false, .result = .cancel },
                .{ .label = "OK", .width = 80, .is_primary = true, .result = .ok },
            },
            .yes_no => &[_]ButtonConfig{
                .{ .label = "No", .width = 80, .is_primary = false, .result = .no },
                .{ .label = "Yes", .width = 80, .is_primary = true, .result = .yes },
            },
            .yes_no_cancel => &[_]ButtonConfig{
                .{ .label = "Cancel", .width = 80, .is_primary = false, .result = .cancel },
                .{ .label = "No", .width = 80, .is_primary = false, .result = .no },
                .{ .label = "Yes", .width = 80, .is_primary = true, .result = .yes },
            },
        };
    }

    fn onEvent(w: *Widget, event: *const pal.Event, ectx: *EventContext) EventResult {
        const self: *MessageDialog = @fieldParentPtr("base", w);
        _ = ectx;
        if (!self.visible) return .ignored;

        switch (event.*) {
            .key => |k| {
                if (k.state == .pressed) {
                    if (k.key == .escape) {
                        self.closeWithResult(.cancel);
                        return .handled;
                    }
                    if (k.key == .enter) {
                        const default_result = switch (self.buttons) {
                            .ok => MessageDialogResult.ok,
                            .ok_cancel => .ok,
                            .yes_no => .yes,
                            .yes_no_cancel => .yes,
                        };
                        self.closeWithResult(default_result);
                        return .handled;
                    }
                }
            },
            .mouse_button => |mb| {
                if (mb.button == .left and mb.state == .pressed) {
                    const mx: f32 = @floatFromInt(mb.x);
                    const my: f32 = @floatFromInt(mb.y);
                    const rw = w.rect.width;
                    const rh = w.rect.height;
                    const dw = self.dialog_width;
                    const dh = self.estimateDialogHeight();
                    const dx = (rw - dw) / 2.0;
                    const dy = (rh - dh) / 2.0;

                    if (mx < dx or mx > dx + dw or my < dy or my > dy + dh) {
                        self.closeWithResult(.cancel);
                        return .handled;
                    }

                    const btn_y = dy + dh - 52;
                    const btn_h: f32 = 34;
                    if (my >= btn_y and my <= btn_y + btn_h) {
                        const local_mx = mx - dx;
                        const configs = self.buttonConfigs();
                        var btn_x: f32 = dw - 24;
                        for (configs) |btn| {
                            btn_x -= btn.width + 8;
                            if (local_mx >= btn_x and local_mx <= btn_x + btn.width) {
                                self.closeWithResult(btn.result);
                                return .handled;
                            }
                        }
                    }
                }
            },
            else => {},
        }
        return .ignored;
    }
};

// ── Tests ──────────────────────────────────────────────────────────────────

test "message_dialog create info kind" {
    const d = try MessageDialog.create(std.testing.allocator, .{
        .kind = .info,
        .title = "Info",
        .message = "Hello",
    });
    defer d.destroy(std.testing.allocator);

    try std.testing.expectEqual(MessageDialogKind.info, d.kind);
    try std.testing.expectEqualStrings("Info", d.title);
    try std.testing.expectEqualStrings("Hello", d.message);
    try std.testing.expectEqual(false, d.visible);
}

test "message_dialog show/hide" {
    const d = try MessageDialog.create(std.testing.allocator, .{});
    defer d.destroy(std.testing.allocator);

    d.show();
    try std.testing.expectEqual(true, d.visible);

    d.hide();
    try std.testing.expectEqual(false, d.visible);
}

test "message_dialog kind colors differ" {
    const info = try MessageDialog.create(std.testing.allocator, .{ .kind = .info });
    defer info.destroy(std.testing.allocator);
    const warn = try MessageDialog.create(std.testing.allocator, .{ .kind = .warning });
    defer warn.destroy(std.testing.allocator);
    const err = try MessageDialog.create(std.testing.allocator, .{ .kind = .err });
    defer err.destroy(std.testing.allocator);
    const q = try MessageDialog.create(std.testing.allocator, .{ .kind = .question });
    defer q.destroy(std.testing.allocator);

    const ci = info.kindColor();
    const cw = warn.kindColor();
    const ce = err.kindColor();
    const cq = q.kindColor();

    try std.testing.expect(ci.r != cw.r or ci.g != cw.g or ci.b != cw.b);
    try std.testing.expect(ce.r != cw.r or ce.g != cw.g or ce.b != cw.b);
    try std.testing.expect(cq.r != ci.r or cq.g != ci.g or cq.b != ci.b);
}

test "message_dialog ok_cancel buttons count" {
    const d = try MessageDialog.create(std.testing.allocator, .{ .buttons = .ok_cancel });
    defer d.destroy(std.testing.allocator);

    const btns = d.buttonConfigs();
    try std.testing.expectEqual(@as(usize, 2), btns.len);
}

test "message_dialog yes_no_cancel buttons count" {
    const d = try MessageDialog.create(std.testing.allocator, .{ .buttons = .yes_no_cancel });
    defer d.destroy(std.testing.allocator);

    const btns = d.buttonConfigs();
    try std.testing.expectEqual(@as(usize, 3), btns.len);
}

test "message_dialog default buttons is ok" {
    const d = try MessageDialog.create(std.testing.allocator, .{});
    defer d.destroy(std.testing.allocator);

    try std.testing.expectEqual(MessageDialogButtons.ok, d.buttons);
    const btns = d.buttonConfigs();
    try std.testing.expectEqual(@as(usize, 1), btns.len);
    try std.testing.expectEqual(MessageDialogResult.ok, btns[0].result);
}
