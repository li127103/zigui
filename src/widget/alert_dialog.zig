//! AlertDialog 控件 - GTK4 警告/消息对话框
//!
//! 对应 GtkAlertDialog: GTK4 新的简化版消息对话框, 替代 GtkMessageDialog。
//! 支持: 标题、消息文本、详细说明、按钮配置、模态、异步回调。
//! 与 MessageDialog 的区别是 API 更简洁, 支持异步按钮回调。

const std = @import("std");
const math = @import("../math.zig");
const widget_mod = @import("widget.zig");
const layout_mod = @import("../layout/engine.zig");
const pal = @import("../pal/pal.zig");
const styled_text = @import("../text/styled_text.zig");
const button_mod = @import("button.zig");
const label_mod = @import("label.zig");
const separator_mod = @import("separator.zig");
const icons_mod = @import("icons.zig");

const Widget = widget_mod.Widget;
const PaintContext = widget_mod.PaintContext;
const EventContext = widget_mod.EventContext;
const EventResult = widget_mod.EventResult;
const Button = button_mod.Button;
const Label = label_mod.Label;

/// 对话框按钮类型
pub const AlertButtonStyle = enum {
    default_style,
    destructive,
    suggested,
    cancel,
};

pub const AlertButton = struct {
    text: []const u8,
    style: AlertButtonStyle = .default_style,
    on_click: ?*const fn (self: *AlertDialog, btn: usize) void = null,
};

/// 警告级别
pub const AlertLevel = enum {
    info,
    warning,
    err_level,
    question,
};

pub const AlertDialog = struct {
    base: Widget,
    allocator: std.mem.Allocator,

    title_text: []const u8,
    message_text: []const u8 = "",
    detail_text: []const u8 = "",
    level: AlertLevel = .info,
    modal: bool = true,
    buttons: []const AlertButton = &.{},

    width: f32 = 420,
    min_width: f32 = 360,
    min_height: f32 = 160,

    bg_color: math.Color = math.Color.hex(0xFFFFFFFF),
    header_bg: math.Color = math.Color.hex(0xF8FAFCFF),
    border_color: math.Color = math.Color.hex(0xE2E8F0FF),
    title_color: math.Color = math.Color.hex(0x0F172AFF),
    message_color: math.Color = math.Color.hex(0x334155FF),
    detail_color: math.Color = math.Color.hex(0x64748BFF),
    btn_bar_bg: math.Color = math.Color.hex(0xF8FAFCFF),

    on_response: ?*const fn (self: *AlertDialog, button_idx: usize) void = null,

    title_font_size: f32 = 18,
    message_font_size: f32 = 14,
    detail_font_size: f32 = 12,
    icon_size: f32 = 40,

    hover_close: bool = false,
    last_dw: f32 = 420,
    last_dh: f32 = 200,

    const Self = @This();

    pub fn create(allocator: std.mem.Allocator, opts: struct {
        title: []const u8,
        message: []const u8 = "",
        detail: []const u8 = "",
        level: AlertLevel = .info,
        modal: bool = true,
        width: f32 = 420,
        buttons: []const AlertButton = &.{
            .{ .text = "OK", .style = .default_style },
        },
        on_response: ?*const fn (self: *AlertDialog, button_idx: usize) void = null,
    }) !*AlertDialog {
        const title_dup = try allocator.dupe(u8, opts.title);
        const msg_dup = try allocator.dupe(u8, opts.message);
        const det_dup = try allocator.dupe(u8, opts.detail);

        const self = try allocator.create(AlertDialog);
        self.* = .{
            .base = .{
                .vtable = &vtable,
                .id = widget_mod.genWidgetId(),
            },
            .allocator = allocator,
            .title_text = title_dup,
            .message_text = msg_dup,
            .detail_text = det_dup,
            .level = opts.level,
            .modal = opts.modal,
            .width = opts.width,
            .buttons = opts.buttons,
            .on_response = opts.on_response,
        };
        self.base.accessibility = .{
            .role = .dialog,
            .label = title_dup,
        };
        self.last_dw = opts.width;
        return self;
    }

    pub fn destroy(self: *Self, allocator: std.mem.Allocator) void {
        allocator.free(self.title_text);
        allocator.free(self.message_text);
        allocator.free(self.detail_text);
        self.base.background.deinit(allocator);
        self.base.children.deinit(allocator);
        allocator.destroy(self);
    }

    fn getLevelColor(self: *const Self) math.Color {
        return switch (self.level) {
            .info => math.Color.hex(0x3B82F6FF),
            .warning => math.Color.hex(0xF59E0BFF),
            .err_level => math.Color.hex(0xEF4444FF),
            .question => math.Color.hex(0x8B5CF6FF),
        };
    }

    fn getLevelIcon(self: *const Self) icons_mod.IconName {
        return switch (self.level) {
            .info => icons_mod.IconName.info,
            .warning => icons_mod.IconName.warning,
            .err_level => icons_mod.IconName.err,
            .question => icons_mod.IconName.question,
        };
    }

    fn getButtonColors(style: AlertButtonStyle) struct { bg: math.Color, bg_hover: math.Color, text: math.Color, border: math.Color } {
        return switch (style) {
            .default_style => .{
                .bg = math.Color.hex(0xFFFFFFFF),
                .bg_hover = math.Color.hex(0xF1F5F9FF),
                .text = math.Color.hex(0x0F172AFF),
                .border = math.Color.hex(0xCBD5E1FF),
            },
            .destructive => .{
                .bg = math.Color.hex(0xEF4444FF),
                .bg_hover = math.Color.hex(0xDC2626FF),
                .text = math.Color.hex(0xFFFFFFFF),
                .border = math.Color.hex(0xEF4444FF),
            },
            .suggested => .{
                .bg = math.Color.hex(0x3B82F6FF),
                .bg_hover = math.Color.hex(0x2563EBFF),
                .text = math.Color.hex(0xFFFFFFFF),
                .border = math.Color.hex(0x3B82F6FF),
            },
            .cancel => .{
                .bg = math.Color.hex(0xFFFFFFFF),
                .bg_hover = math.Color.hex(0xF1F5F9FF),
                .text = math.Color.hex(0x475569FF),
                .border = math.Color.hex(0xCBD5E1FF),
            },
        };
    }

    // ── VTable ──────────────────────────────────────────────────────────────

    const vtable = Widget.VTable{
        .type_name = "alert_dialog",
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
        _ = ctx;

        const w_out = if (constraints.max_width < std.math.inf(f32))
            constraints.max_width
        else
            @max(self.min_width, self.width);

        var total_h: f32 = 56; // header
        total_h += 24; // padding

        const title_ts = styled_text.measureText(self.allocator, self.title_text, .{ .font_size = self.title_font_size });
        total_h += title_ts.height + 8;

        if (self.message_text.len > 0) {
            const max_w = w_out - self.icon_size - 3 * 24;
            const msg_ts = styled_text.measureText(self.allocator, self.message_text, .{
                .font_size = self.message_font_size,
                .max_width = max_w,
            });
            total_h += msg_ts.height + 4;
        }

        if (self.detail_text.len > 0) {
            const max_w = w_out - self.icon_size - 3 * 24;
            const det_ts = styled_text.measureText(self.allocator, self.detail_text, .{
                .font_size = self.detail_font_size,
                .max_width = max_w,
            });
            total_h += det_ts.height + 8;
        }

        total_h += 24; // spacing
        total_h += 1; // separator
        total_h += 60; // button bar

        const h_out = @max(self.min_height, total_h);
        self.last_dw = w_out;
        self.last_dh = h_out;
        return .{ .width = w_out, .height = h_out };
    }

    fn paint(w: *Widget, ctx: *PaintContext) void {
        const self: *Self = @fieldParentPtr("base", w);
        const rx = ctx.offset_x + w.rect.x;
        const ry = ctx.offset_y + w.rect.y;
        const dw = w.rect.width;
        const dh = w.rect.height;

        // 背景
        ctx.renderer.fillRoundedRect(.{ .x = rx, .y = ry, .width = dw, .height = dh }, 12, self.bg_color) catch {};
        ctx.renderer.strokeRoundedRect(.{ .x = rx, .y = ry, .width = dw, .height = dh }, 12, 1, self.border_color) catch {};

        // 顶部 header
        ctx.renderer.fillRoundedRect(.{ .x = rx, .y = ry, .width = dw, .height = 56 }, 12, self.header_bg) catch {};

        // 关闭按钮
        const close_x = rx + dw - 56;
        const close_y = ry + 14;
        const cs: f32 = 28;
        if (self.hover_close) {
            ctx.renderer.fillRoundedRect(.{ .x = close_x, .y = close_y, .width = cs, .height = cs }, 6, math.Color.hex(0xE2E8F0FF)) catch {};
        }
        icons_mod.drawIcon(ctx.renderer, close_x + (cs - 16) / 2, close_y + (cs - 16) / 2, 16, math.Color.hex(0x64748BFF), icons_mod.IconName.close) catch {};

        // 标题
        styled_text.drawText(ctx.renderer, ctx.allocator, self.title_text, rx + 24, ry + 18, .{
            .font_size = self.title_font_size,
            .color = self.title_color,
            .font_weight = 700,
            .max_width = dw - 100,
        });

        // 内容区域
        const content_start = ry + 56 + 24;
        const icon_x = rx + 24;
        const icon_y = content_start;

        const level_color = self.getLevelColor();
        icons_mod.drawIcon(ctx.renderer, icon_x, icon_y, self.icon_size, level_color, self.getLevelIcon()) catch {};

        // 消息区
        var msg_y: f32 = content_start;
        const text_x = icon_x + self.icon_size + 16;
        const max_text_w = rx + dw - 24 - text_x;

        if (self.message_text.len > 0) {
            styled_text.drawText(ctx.renderer, ctx.allocator, self.message_text, text_x, msg_y, .{
                .font_size = self.message_font_size,
                .color = self.message_color,
                .font_weight = 500,
                .max_width = max_text_w,
            });
            const msg_ts = styled_text.measureText(ctx.allocator, self.message_text, .{
                .font_size = self.message_font_size,
                .max_width = max_text_w,
            });
            msg_y += msg_ts.height + 4;
        }

        if (self.detail_text.len > 0) {
            styled_text.drawText(ctx.renderer, ctx.allocator, self.detail_text, text_x, msg_y, .{
                .font_size = self.detail_font_size,
                .color = self.detail_color,
                .max_width = max_text_w,
            });
        }

        // 底部按钮栏
        const btn_bar_y = ry + dh - 60;
        ctx.renderer.fillRoundedRect(.{ .x = rx, .y = btn_bar_y, .width = dw, .height = 60 }, 12, self.btn_bar_bg) catch {};

        // 分隔线
        ctx.renderer.fillRect(.{ .x = rx, .y = btn_bar_y, .width = dw, .height = 1 }, self.border_color) catch {};

        // 按钮 (从右到左)
        const btn_h: f32 = 36;
        const btn_y = btn_bar_y + (60 - btn_h) / 2;
        const btn_spacing: f32 = 8;
        const btn_padding_right: f32 = 20;

        var cur_x = rx + dw - btn_padding_right;
        for (0..self.buttons.len) |i| {
            const idx = self.buttons.len - 1 - i;
            const btn = self.buttons[idx];
            const btn_text_w = styled_text.measureText(ctx.allocator, btn.text, .{ .font_size = 13 }).width;
            const btn_w: f32 = @max(80, btn_text_w + 32);
            const bx = cur_x - btn_w;
            const colors = getButtonColors(btn.style);

            ctx.renderer.fillRoundedRect(.{ .x = bx, .y = btn_y, .width = btn_w, .height = btn_h }, 6, colors.bg) catch {};
            ctx.renderer.strokeRoundedRect(.{ .x = bx, .y = btn_y, .width = btn_w, .height = btn_h }, 6, 1, colors.border) catch {};

            const bt_ts = styled_text.measureText(ctx.allocator, btn.text, .{ .font_size = 13 });
            const bt_x = bx + (btn_w - bt_ts.width) / 2;
            const bt_y = btn_y + (btn_h - bt_ts.height) / 2;
            styled_text.drawText(ctx.renderer, ctx.allocator, btn.text, bt_x, bt_y, .{
                .font_size = 13,
                .color = colors.text,
                .font_weight = if (btn.style == .suggested or btn.style == .destructive) 600 else 500,
            });

            cur_x = bx - btn_spacing;
        }
    }

    fn onEvent(w: *Widget, event: *const pal.Event, ectx: *EventContext) EventResult {
        const self: *Self = @fieldParentPtr("base", w);
        _ = ectx;

        const dw = self.last_dw;
        const dh = self.last_dh;

        switch (event.*) {
            .mouse_move => |mm| {
                const mx: f32 = @floatFromInt(mm.x);
                const my: f32 = @floatFromInt(mm.y);

                // 关闭按钮检测
                const close_x = dw - 56;
                const close_y = 14;
                const cs: f32 = 28;
                const close_hover = mx >= close_x and mx < close_x + cs and
                    my >= close_y and my < close_y + cs;
                if (close_hover != self.hover_close) {
                    self.hover_close = close_hover;
                    self.base.markDirty();
                }
                return .handled;
            },
            .mouse_button => |mb| {
                if (mb.button == .left and mb.state == .released) {
                    const mx: f32 = @floatFromInt(mb.x);
                    const my: f32 = @floatFromInt(mb.y);

                    // 关闭按钮
                    const close_x = dw - 56;
                    const close_y = 14;
                    const cs: f32 = 28;
                    if (mx >= close_x and mx < close_x + cs and
                        my >= close_y and my < close_y + cs)
                    {
                        if (self.on_response) |cb| cb(self, 999);
                        return .handled;
                    }

                    // 按钮栏
                    const btn_bar_y = dh - 60;
                    const btn_h: f32 = 36;
                    const btn_y = btn_bar_y + (60 - btn_h) / 2;
                    if (my >= btn_y and my < btn_y + btn_h) {
                        const btn_spacing: f32 = 8;
                        const btn_padding_right: f32 = 20;
                        var cur_x = dw - btn_padding_right;

                        for (0..self.buttons.len) |i| {
                            const idx = self.buttons.len - 1 - i;
                            const btn = self.buttons[idx];
                            const btn_text_w = styled_text.measureText(self.allocator, btn.text, .{ .font_size = 13 }).width;
                            const btn_w: f32 = @max(80, btn_text_w + 32);
                            const bx = cur_x - btn_w;

                            if (mx >= bx and mx < cur_x) {
                                if (btn.on_click) |cb| cb(self, idx);
                                if (self.on_response) |cb| cb(self, idx);
                                return .handled;
                            }
                            cur_x = bx - btn_spacing;
                        }
                    }
                }
            },
            .key => |key| {
                if (key.state == .pressed and key.key == .escape) {
                    if (self.on_response) |cb| {
                        cb(self, 999);
                        return .handled;
                    }
                }
            },
            else => {},
        }
        return .ignored;
    }
};
