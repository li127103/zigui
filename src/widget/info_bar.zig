//! Infobar 控件 - 信息栏
//!
//! 用于在内容区域顶部显示重要消息的控件，支持四种类型：
//! info（信息）、warning（警告）、error（错误）、question（问题）。
//!
//! 使用方法:
//! ```
//! var bar = try InfoBar.create(allocator, .{
//!     .message_type = .info,
//!     .text = "操作成功完成",
//! });
//! bar.show();
//! ```

const std = @import("std");
const math = @import("../math.zig");
const widget_mod = @import("widget.zig");
const pal = @import("../pal/pal.zig");
const container_mod = @import("container.zig");
const label_mod = @import("label.zig");
const button_mod = @import("button.zig");
const layout_mod = @import("../layout/engine.zig");

const Widget = widget_mod.Widget;
const PaintContext = widget_mod.PaintContext;
const EventContext = widget_mod.EventContext;
const EventResult = widget_mod.EventResult;

const Container = container_mod.Container;
const Label = label_mod.Label;
const Button = button_mod.Button;

pub const InfoBarType = enum {
    info,
    warning,
    err,
    question,
};

pub const InfoBar = struct {
    base: Widget,
    allocator: std.mem.Allocator,
    message_type: InfoBarType,
    text: []const u8,
    visible: bool = true,
    show_close: bool = true,
    on_close: ?*const fn (self: *InfoBar) void = null,
    on_response: ?*const fn (self: *InfoBar, response_id: i32) void = null,

    content_container: ?*Container = null,
    action_area: ?*Container = null,
    message_label: ?*Label = null,
    close_button: ?*Button = null,
    actions: std.ArrayListUnmanaged(*Button) = .{ .items = &.{}, .capacity = 0 },

    const Self = @This();

    pub fn create(allocator: std.mem.Allocator, opts: struct {
        message_type: InfoBarType = .info,
        text: []const u8 = "",
        show_close: bool = true,
        visible: bool = true,
        on_close: ?*const fn (self: *InfoBar) void = null,
        on_response: ?*const fn (self: *InfoBar, response_id: i32) void = null,
    }) !*InfoBar {
        const self = try allocator.create(InfoBar);
        self.* = .{
            .base = .{
                .vtable = &vtable,
                .id = widget_mod.genWidgetId(),
            },
            .allocator = allocator,
            .message_type = opts.message_type,
            .text = try allocator.dupe(u8, opts.text),
            .visible = opts.visible,
            .show_close = opts.show_close,
            .on_close = opts.on_close,
            .on_response = opts.on_response,
        };
        try self.buildUI();
        return self;
    }

    /// 兼容旧 API: create(allocator, text, message_type, opts)
    pub fn createLegacy(
        allocator: std.mem.Allocator,
        text: []const u8,
        message_type: InfoBarType,
        opts: struct {
            show_close: bool = true,
            on_close: ?*const fn (self: *InfoBar) void = null,
            on_response: ?*const fn (self: *InfoBar, response_id: i32) void = null,
        },
    ) !*InfoBar {
        return create(allocator, .{
            .message_type = message_type,
            .text = text,
            .show_close = opts.show_close,
            .on_close = opts.on_close,
            .on_response = opts.on_response,
        });
    }

    /// GTK 风格: gtk_info_bar_add_button
    pub fn addButton(self: *Self, text: []const u8, response_id: i32) !*Button {
        const alloc = self.allocator;
        const ActionWrapper = struct {
            info: *Self,
            response: i32,
        };
        const wrapper = try alloc.create(ActionWrapper);
        wrapper.* = .{ .info = self, .response = response_id };
        const btn = try Button.create(alloc, text, .{
            .font_size = 13,
            .corner_radius = 4,
            .min_width = 64,
            .height = 30,
            .padding = .{ .left = 12, .right = 12, .top = 4, .bottom = 4 },
        });
        btn.on_click = struct {
            fn onActionClick(b: *Button) void {
                const w: *ActionWrapper = @ptrCast(@alignCast(b.base.user_data orelse return));
                if (w.info.on_response) |cb| cb(w.info, w.response);
            }
        }.onActionClick;
        btn.base.user_data = wrapper;
        try self.actions.append(alloc, btn);
        if (self.action_area) |aa| {
            try aa.base.addChild(alloc, &btn.base);
        } else if (self.content_container) |cc| {
            try cc.base.addChild(alloc, &btn.base);
        }
        return btn;
    }

    /// addAction 是 addButton 的别名（兼容示例）
    pub const addAction = addButton;

    pub fn destroy(self: *Self, allocator: std.mem.Allocator) void {
        allocator.free(self.text);
        self.base.background.deinit(allocator);
        if (self.content_container) |cc| {
            cc.base.vtable.destroy(&cc.base, allocator);
        }
        self.base.children.deinit(allocator);
        allocator.destroy(self);
    }

    pub fn show(self: *Self) void {
        self.visible = true;
        self.base.markDirty();
    }

    pub fn hide(self: *Self) void {
        self.visible = false;
        self.base.markDirty();
    }

    pub fn setMessage(self: *Self, msg_type: InfoBarType, text: []const u8) void {
        self.message_type = msg_type;
        self.allocator.free(self.text);
        self.text = self.allocator.dupe(u8, text) catch return;
        if (self.message_label) |lbl| {
            lbl.setText(self.text) catch {};
        }
        self.base.markDirty();
    }

    pub fn setText(self: *Self, text: []const u8) void {
        self.allocator.free(self.text);
        self.text = self.allocator.dupe(u8, text) catch return;
        if (self.message_label) |lbl| {
            lbl.setText(self.text) catch {};
        }
        self.base.markDirty();
    }

    fn getBgColor(self: *const Self) math.Color {
        return switch (self.message_type) {
            .info => math.Color.hex(0xDBEAFEFF),
            .warning => math.Color.hex(0xFEf3C7FF),
            .err => math.Color.hex(0xFEE2E2FF),
            .question => math.Color.hex(0xE0E7FFFF),
        };
    }

    fn getTextColor(self: *const Self) math.Color {
        return switch (self.message_type) {
            .info => math.Color.hex(0x1E40AFFF),
            .warning => math.Color.hex(0x92400EFF),
            .err => math.Color.hex(0x991B1BFF),
            .question => math.Color.hex(0x3730A3FF),
        };
    }

    fn getBorderColor(self: *const Self) math.Color {
        return switch (self.message_type) {
            .info => math.Color.hex(0x93C5FDFF),
            .warning => math.Color.hex(0xFCD34DFF),
            .err => math.Color.hex(0xF87171FF),
            .question => math.Color.hex(0x818CF8FF),
        };
    }

    fn buildUI(self: *Self) !void {
        const alloc = self.allocator;

        const bg = self.getBgColor();

        const content = try Container.create(alloc, .{
            .direction = .row,
            .bg_color = bg,
            .padding = .{ .left = 16, .right = 12, .top = 10, .bottom = 10 },
            .gap = .{ .width = 12, .height = 0 },
        });
        self.content_container = content;
        try self.base.addChild(alloc, &content.base);

        const label = try Label.create(alloc, self.text, .{
            .font_size = 13,
            .color = self.getTextColor(),
            .wrap = true,
        });
        label.base.layout_style.flex_grow = 1;
        try content.base.addChild(alloc, &label.base);
        self.message_label = label;

        if (self.show_close) {
            const btn = try Button.create(alloc, "✕", .{
                .font_size = 14,
                .corner_radius = 4,
                .min_width = 28,
                .height = 28,
            });
            btn.on_click = onCloseClick;
            btn.base.user_data = self;
            try content.base.addChild(alloc, &btn.base);
            self.close_button = btn;
        }
    }

    fn onCloseClick(btn: *Button) void {
        const self: *Self = @ptrCast(@alignCast(btn.base.user_data orelse return));
        self.hide();
        if (self.on_close) |cb| cb(self);
    }

    // ── VTable ──────────────────────────────────────────────────────────────

    const vtable = Widget.VTable{
        .type_name = "info_bar",
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
        if (!self.visible) return .{ .width = 0, .height = 0 };
        const h = if (w.rect.height > 0) w.rect.height else 44;
        return .{ .width = constraints.max_width, .height = h };
    }

    fn paint(w: *Widget, ctx: *PaintContext) void {
        const self: *Self = @fieldParentPtr("base", w);
        if (!self.visible) return;

        const rx = ctx.offset_x + w.rect.x;
        const ry = ctx.offset_y + w.rect.y;
        const rw = w.rect.width;
        const rh = w.rect.height;

        const border_color = self.getBorderColor();
        ctx.renderer.fillRect(.{ .x = rx, .y = ry, .width = rw, .height = rh }, self.getBgColor()) catch {};
        ctx.renderer.fillRect(.{ .x = rx, .y = ry, .width = 3, .height = rh }, border_color) catch {};

        if (self.content_container) |cc| {
            cc.base.rect = .{ .x = rx, .y = ry, .width = rw, .height = rh };
            cc.base.vtable.paint(&cc.base, ctx);
        }
    }

    fn onEvent(w: *Widget, event: *const pal.Event, ectx: *EventContext) EventResult {
        const self: *Self = @fieldParentPtr("base", w);
        if (!self.visible) return .ignored;

        if (self.content_container) |cc| {
            if (cc.base.vtable.on_event) |ev_fn| {
                const result = ev_fn(&cc.base, event, ectx);
                if (result == .handled) return .handled;
            }
        }
        return .ignored;
    }
};
