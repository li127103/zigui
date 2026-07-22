//! Dialog 控件 - 模态对话框

const std = @import("std");
const math = @import("../math.zig");
const widget_mod = @import("widget.zig");
const layout_mod = @import("../layout/engine.zig");
const pal = @import("../pal/pal.zig");
const text_layout = @import("../text/layout.zig");
const coretext = @import("../text/coretext.zig");

const Widget = widget_mod.Widget;
const PaintContext = widget_mod.PaintContext;
const EventContext = widget_mod.EventContext;
const EventResult = widget_mod.EventResult;

pub const Dialog = struct {
    base: Widget,
    allocator: std.mem.Allocator,
    title: []const u8,
    message: []const u8,
    visible: bool = false,
    on_close: ?*const fn (self: *Dialog) void,
    on_confirm: ?*const fn (self: *Dialog) void,
    // 样式
    overlay_color: math.Color = math.Color.hex(0x000000AA),
    bg_color: math.Color = math.Color.hex(0x1E293BFF),
    title_color: math.Color = math.Color.hex(0xF8FAFCFF),
    message_color: math.Color = math.Color.hex(0xCBD5E1FF),
    corner_radius: f32 = 14.0,
    dialog_width: f32 = 400,
    title_size: f32 = 18.0,
    message_size: f32 = 14.0,

    pub fn create(allocator: std.mem.Allocator, opts: struct {
        title: []const u8 = "Dialog",
        message: []const u8 = "",
        on_close: ?*const fn (self: *Dialog) void = null,
        on_confirm: ?*const fn (self: *Dialog) void = null,
    }) !*Dialog {
        const self = try allocator.create(Dialog);
        self.* = .{
            .base = .{
                .vtable = &vtable,
                .id = widget_mod.genWidgetId(),
            },
            .allocator = allocator,
            .title = opts.title,
            .message = opts.message,
            .on_close = opts.on_close,
            .on_confirm = opts.on_confirm,
        };
        return self;
    }

    pub fn destroy(self: *Dialog, allocator: std.mem.Allocator) void {
        self.base.background.deinit(allocator);
        self.base.children.deinit(allocator);
        allocator.destroy(self);
    }

    pub fn show(self: *Dialog) void {
        self.visible = true;
        self.base.markDirty();
    }

    pub fn hide(self: *Dialog) void {
        self.visible = false;
        self.base.markDirty();
        if (self.on_close) |cb| cb(self);
    }

    // ── VTable ──────────────────────────────────────────────────────────────

    const vtable = Widget.VTable{
        .type_name = "dialog",
        .measure = measure,
        .paint = paint,
        .on_event = onEvent,
        .focusable = false,
        .destroy = destroyVTable,
    };

    fn destroyVTable(w: *Widget, allocator: std.mem.Allocator) void {
        const self: *Dialog = @fieldParentPtr("base", w);
        self.destroy(allocator);
    }

    fn measure(w: *Widget, ctx: *PaintContext, constraints: layout_mod.Constraints) math.Size(f32) {
        _ = ctx;
        _ = w;
        return .{ .width = constraints.max_width, .height = constraints.max_height };
    }

    fn paint(w: *Widget, ctx: *PaintContext) void {
        const self: *Dialog = @fieldParentPtr("base", w);
        if (!self.visible) return;

        const rx = ctx.offset_x + w.rect.x;
        const ry = ctx.offset_y + w.rect.y;
        const rw = w.rect.width;
        const rh = w.rect.height;

        // 遮罩层
        ctx.renderer.fillRect(.{ .x = rx, .y = ry, .width = rw, .height = rh }, self.overlay_color) catch {};

        // 对话框居中
        const dw = self.dialog_width;
        const dh: f32 = 180;
        const dx = rx + (rw - dw) / 2.0;
        const dy = ry + (rh - dh) / 2.0;

        // 对话框背景
        ctx.renderer.fillRoundedRect(.{ .x = dx, .y = dy, .width = dw, .height = dh }, self.corner_radius, self.bg_color) catch {};

        // 标题
        self.drawLabel(ctx, self.title, dx + 24, dy + 24, self.title_size, 700, self.title_color);

        // 消息
        if (self.message.len > 0) {
            self.drawLabel(ctx, self.message, dx + 24, dy + 60, self.message_size, 400, self.message_color);
        }

        // 按钮区域
        const btn_y = dy + dh - 52;
        // Cancel
        ctx.renderer.fillRoundedRect(.{ .x = dx + dw - 200, .y = btn_y, .width = 80, .height = 34 }, 7, math.Color.hex(0x334155FF)) catch {};
        self.drawLabel(ctx, "Cancel", dx + dw - 185, btn_y + 8, 13.0, 500, math.Color.hex(0xCBD5E1FF));

        // Confirm
        ctx.renderer.fillRoundedRect(.{ .x = dx + dw - 108, .y = btn_y, .width = 84, .height = 34 }, 7, math.Color.hex(0x3B82F6FF)) catch {};
        self.drawLabel(ctx, "Confirm", dx + dw - 96, btn_y + 8, 13.0, 500, math.Color.hex(0xFFFFFFFF));
    }

    fn drawLabel(self: *Dialog, ctx: *PaintContext, text: []const u8, x: f32, y: f32, size: f32, weight: u16, color: math.Color) void {
        _ = self;
        var font = coretext.CtFont.create(null, size, weight) catch return;
        defer font.destroy();

        var tl = text_layout.TextLayout.layout(
            ctx.allocator,
            &ctx.renderer.glyph_atlas.?,
            ctx.renderer.device,
            text,
            .{ .font = &font, .font_size = size },
        ) catch return;
        defer tl.deinit();

        ctx.renderer.drawText(&tl, x, y, color) catch {};
    }

    fn onEvent(w: *Widget, event: *const pal.Event, ectx: *EventContext) EventResult {
        const self: *Dialog = @fieldParentPtr("base", w);
        _ = ectx;
        if (!self.visible) return .ignored;

        switch (event.*) {
            .key => |k| {
                if (k.state == .pressed and k.key == .escape) {
                    self.hide();
                    return .handled;
                }
            },
            .mouse_button => |mb| {
                if (mb.button == .left and mb.state == .pressed) {
                    // 简化: 点击遮罩关闭
                    const mx: f32 = @floatFromInt(mb.x);
                    const my: f32 = @floatFromInt(mb.y);
                    const rw = w.rect.width;
                    const rh = w.rect.height;
                    const dw = self.dialog_width;
                    const dh: f32 = 180;
                    const dx = (rw - dw) / 2.0;
                    const dy = (rh - dh) / 2.0;

                    // 在对话框外部点击 → 关闭
                    if (mx < dx or mx > dx + dw or my < dy or my > dy + dh) {
                        self.hide();
                        return .handled;
                    }

                    // Confirm 按钮区域
                    const btn_y = dy + dh - 52;
                    if (mx >= dx + dw - 108 and mx <= dx + dw - 24 and my >= btn_y and my <= btn_y + 34) {
                        if (self.on_confirm) |cb| cb(self);
                        self.hide();
                        return .handled;
                    }
                    // Cancel 按钮区域
                    if (mx >= dx + dw - 200 and mx <= dx + dw - 120 and my >= btn_y and my <= btn_y + 34) {
                        self.hide();
                        return .handled;
                    }
                }
            },
            else => {},
        }
        return .ignored;
    }
};
