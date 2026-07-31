//! PasswordEntry 控件 - 密码输入框
//!
//! 类似 GtkPasswordEntry: 带显示/隐藏密码按钮的输入框。
//! 右侧有一个眼睛图标按钮, 点击可以切换密码的显示/隐藏状态。
//!
//! 支持:
//! - 密码显示/隐藏切换
//! - 自定义密码字符
//! - 占位符文本
//! - 可定制样式

const std = @import("std");
const math = @import("../math.zig");
const widget_mod = @import("widget.zig");
const layout_mod = @import("../layout/engine.zig");
const pal = @import("../pal/pal.zig");
const entry_mod = @import("entry.zig");
const icons_mod = @import("icons.zig");

const Widget = widget_mod.Widget;
const PaintContext = widget_mod.PaintContext;
const EventContext = widget_mod.EventContext;
const EventResult = widget_mod.EventResult;
const Entry = entry_mod.Entry;
const Editable = @import("../model/editable.zig").Editable;
const EntryBuffer = @import("../model/editable.zig").EntryBuffer;

// ── Entry callback wrappers (通过 entry.base.parent 反查 PasswordEntry) ───
fn entryChangeWrapper(entry_self: *Entry, text: []const u8) void {
    const parent_widget = entry_self.base.parent orelse return;
    const self: *PasswordEntry = @fieldParentPtr("base", parent_widget);
    if (self.on_text_changed) |cb| cb(self, text);
}
fn entrySubmitWrapper(entry_self: *Entry, text: []const u8) void {
    _ = text;
    const parent_widget = entry_self.base.parent orelse return;
    const self: *PasswordEntry = @fieldParentPtr("base", parent_widget);
    if (self.on_activate) |cb| cb(self);
}

pub const PasswordEntry = struct {
    base: Widget,
    allocator: std.mem.Allocator,
    entry: *Entry,
    show_password: bool = false,

    on_text_changed: ?*const fn (self: *PasswordEntry, text: []const u8) void = null,
    on_activate: ?*const fn (self: *PasswordEntry) void = null,

    size: f32 = 32,
    icon_size: f32 = 16,
    button_size: f32 = 28,
    corner_radius: f32 = 6,

    bg_color: math.Color = math.Color.hex(0xFFFFFFFF),
    border_color: math.Color = math.Color.hex(0xCBD5E1FF),
    border_focus: math.Color = math.Color.hex(0x3B82F6FF),
    text_color: math.Color = math.Color.hex(0x0F172AFF),
    placeholder_color: math.Color = math.Color.hex(0x94A3B8FF),
    icon_color: math.Color = math.Color.hex(0x64748BFF),
    icon_hover_color: math.Color = math.Color.hex(0x334155FF),
    button_hover_bg: math.Color = math.Color.hex(0xF1F5F9FF),

    hover_icon: bool = false,

    const Self = @This();

    pub fn create(allocator: std.mem.Allocator, opts: struct {
        placeholder: []const u8 = "",
        text: []const u8 = "",
        password_char: u8 = '*',
        size: f32 = 32,
        icon_size: f32 = 16,
        button_size: f32 = 28,
        corner_radius: f32 = 6,
        bg_color: math.Color = math.Color.hex(0xFFFFFFFF),
        border_color: math.Color = math.Color.hex(0xCBD5E1FF),
        text_color: math.Color = math.Color.hex(0x0F172AFF),
        on_text_changed: ?*const fn (self: *PasswordEntry, text: []const u8) void = null,
        on_activate: ?*const fn (self: *PasswordEntry) void = null,
    }) !*PasswordEntry {
        const entry = try Entry.create(allocator, .{
            .placeholder = opts.placeholder,
            .text = opts.text,
            .password = true,
            .password_char = opts.password_char,
            .text_color = opts.text_color,
        });

        const self = try allocator.create(PasswordEntry);
        self.* = .{
            .base = .{
                .vtable = &vtable,
                .id = widget_mod.genWidgetId(),
            },
            .allocator = allocator,
            .entry = entry,
            .show_password = false,
            .size = opts.size,
            .icon_size = opts.icon_size,
            .button_size = opts.button_size,
            .corner_radius = opts.corner_radius,
            .bg_color = opts.bg_color,
            .border_color = opts.border_color,
            .text_color = opts.text_color,
            .on_text_changed = opts.on_text_changed,
            .on_activate = opts.on_activate,
        };

        try self.base.addChild(allocator, &entry.base);
        // 在 addChild 之后 (parent 指针设置好) 再绑定包装回调
        entry.on_change = entryChangeWrapper;
        entry.on_submit = entrySubmitWrapper;
        self.base.accessibility = .{ .role = .text };

        return self;
    }

    pub fn destroy(self: *Self, allocator: std.mem.Allocator) void {
        self.entry.destroy(allocator);
        self.base.background.deinit(allocator);
        self.base.children.deinit(allocator);
        allocator.destroy(self);
    }

    /// 获取当前文本
    pub fn getText(self: *const Self) []const u8 {
        return self.entry.getText();
    }

    /// 设置文本
    pub fn setText(self: *Self, text: []const u8) void {
        self.entry.setText(text) catch {};
    }

    /// 设置显示/隐藏密码
    pub fn setShowPassword(self: *Self, show: bool) void {
        self.show_password = show;
        self.entry.setPassword(!show);
        self.base.markDirty();
    }

    /// 切换显示/隐藏密码
    pub fn toggleShowPassword(self: *Self) void {
        self.setShowPassword(!self.show_password);
    }

    /// GTK4 对齐: 返回底层 Entry 的 Editable 接口胖指针
    pub fn getEditable(self: *Self) Editable {
        return self.entry.getEditable();
    }

    /// GTK4: gtk_password_entry_get_buffer (底层 Entry buffer)
    pub fn getEntryBuffer(self: *const Self) ?*EntryBuffer {
        return self.entry.getEntryBuffer();
    }

    pub fn setEntryBuffer(self: *Self, buf: ?*EntryBuffer) void {
        self.entry.setEntryBuffer(buf);
    }

    // ── Entry API 代理 (GTK4 对齐) ─────────────────────────────────────────

    /// GTK4: gtk_entry_get_placeholder_text
    pub fn getPlaceholderText(self: *const Self) []const u8 {
        return self.entry.getPlaceholderText();
    }
    pub fn setPlaceholderText(self: *Self, text: []const u8) void {
        self.entry.setPlaceholderText(text);
        self.base.markDirty();
    }
    pub fn getMaxLength(self: *const Self) u32 {
        return self.entry.getMaxLength();
    }
    pub fn setMaxLength(self: *Self, max: u32) void {
        self.entry.setMaxLength(max);
    }
    pub fn getCursorPosition(self: *const Self) usize {
        return self.entry.getCursorPosition();
    }
    pub fn setCursorPosition(self: *Self, pos: usize) void {
        self.entry.setCursorPosition(pos);
    }
    pub fn selectRegion(self: *Self, start: usize, end: usize) void {
        self.entry.selectRegion(start, end);
    }
    pub fn getSelectionBounds(self: *const Self, out_start: *usize, out_end: *usize) bool {
        return self.entry.getSelectionBounds(out_start, out_end);
    }
    pub fn selectAll(self: *Self) void {
        self.entry.selectAll();
    }
    pub fn hasSelection(self: *const Self) bool {
        return self.entry.hasSelection();
    }
    pub fn deleteSelection(self: *Self) void {
        self.entry.deleteSelection();
    }

    fn getIconButtonRect(self: *const Self) math.Rect(f32) {
        const btn_x = self.base.rect.width - self.button_size - 4;
        const btn_y = (self.size - self.button_size) / 2;
        return .{ .x = btn_x, .y = btn_y, .width = self.button_size, .height = self.button_size };
    }

    // ── VTable ──────────────────────────────────────────────────────────────

    const vtable = Widget.VTable{
        .type_name = "password_entry",
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

        const entry_constraints = layout_mod.Constraints{
            .min_width = 0,
            .max_width = constraints.max_width - self.button_size - 8,
            .min_height = self.size,
            .max_height = self.size,
        };
        _ = self.entry.base.vtable.measure(&self.entry.base, ctx, entry_constraints);

        const w_out = if (constraints.max_width < std.math.inf(f32))
            constraints.max_width
        else
            200;
        const h_out = self.size;

        return .{ .width = w_out, .height = h_out };
    }

    fn paint(w: *Widget, ctx: *PaintContext) void {
        const self: *Self = @fieldParentPtr("base", w);
        const rx = ctx.offset_x + w.rect.x;
        const ry = ctx.offset_y + w.rect.y;

        const border = if (self.entry.base.state.focused) self.border_focus else self.border_color;
        ctx.renderer.fillRoundedRect(
            .{ .x = rx, .y = ry, .width = w.rect.width, .height = w.rect.height },
            self.corner_radius,
            self.bg_color,
        ) catch {};
        ctx.renderer.strokeRoundedRect(
            .{ .x = rx, .y = ry, .width = w.rect.width, .height = w.rect.height },
            self.corner_radius,
            1,
            border,
        ) catch {};

        const btn_rect = self.getIconButtonRect();
        if (self.hover_icon) {
            ctx.renderer.fillRoundedRect(
                .{
                    .x = rx + btn_rect.x,
                    .y = ry + btn_rect.y,
                    .width = btn_rect.width,
                    .height = btn_rect.height,
                },
                4,
                self.button_hover_bg,
            ) catch {};
        }

        const icon_x = rx + btn_rect.x + (btn_rect.width - self.icon_size) / 2;
        const icon_y = ry + btn_rect.y + (btn_rect.height - self.icon_size) / 2;
        const icon = if (self.show_password) icons_mod.IconName.eye else icons_mod.IconName.eye_off;
        const icon_color = if (self.hover_icon) self.icon_hover_color else self.icon_color;
        icons_mod.drawIcon(ctx.renderer, icon_x, icon_y, self.icon_size, icon_color, icon) catch {};

        self.entry.base.rect.x = 8;
        self.entry.base.rect.y = 0;
        self.entry.base.rect.width = w.rect.width - self.button_size - 16;
        self.entry.base.rect.height = w.rect.height;
        self.entry.base.vtable.paint(&self.entry.base, ctx);
    }

    fn onEvent(w: *Widget, event: *const pal.Event, ectx: *EventContext) EventResult {
        const self: *Self = @fieldParentPtr("base", w);

        switch (event.*) {
            .mouse_move => |mm| {
                const mx: f32 = @floatFromInt(mm.x);
                const my: f32 = @floatFromInt(mm.y);

                const btn_rect = self.getIconButtonRect();
                const hover = mx >= btn_rect.x and mx < btn_rect.x + btn_rect.width and
                    my >= btn_rect.y and my < btn_rect.y + btn_rect.height;

                if (hover != self.hover_icon) {
                    self.hover_icon = hover;
                    self.base.markDirty();
                }

                if (!hover) {
                    return self.entry.base.vtable.on_event.?(&self.entry.base, event, ectx);
                }
                return .handled;
            },
            .mouse_button => |mb| {
                if (mb.button == .left and mb.state == .pressed) {
                    const mx: f32 = @floatFromInt(mb.x);
                    const my: f32 = @floatFromInt(mb.y);

                    const btn_rect = self.getIconButtonRect();
                    if (mx >= btn_rect.x and mx < btn_rect.x + btn_rect.width and
                        my >= btn_rect.y and my < btn_rect.y + btn_rect.height)
                    {
                        self.toggleShowPassword();
                        return .handled;
                    }
                }
                return self.entry.base.vtable.on_event.?(&self.entry.base, event, ectx);
            },
            else => {
                return self.entry.base.vtable.on_event.?(&self.entry.base, event, ectx);
            },
        }
    }
};
