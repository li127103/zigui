//! Toolbar 控件 - 工具栏
//!
//! 类似 GtkToolbar: 水平排列的工具栏, 包含工具按钮、分隔线等。
//! 通常放在窗口顶部菜单栏下方, 提供常用操作的快捷按钮。
//!
//! 支持:
//! - ToolButton: 图标 + 文字的工具按钮
//! - ToolSeparator: 工具分隔线
//! - 水平/垂直方向
//! - 图标大小调节
//! - 样式可定制

const std = @import("std");
const math = @import("../math.zig");
const widget_mod = @import("widget.zig");
const layout_mod = @import("../layout/engine.zig");
const pal = @import("../pal/pal.zig");
const styled_text = @import("../text/styled_text.zig");
const icons_mod = @import("icons.zig");

const Widget = widget_mod.Widget;
const PaintContext = widget_mod.PaintContext;
const EventContext = widget_mod.EventContext;
const EventResult = widget_mod.EventResult;

/// 工具栏项类型
pub const ToolItemType = enum {
    button,
    separator,
    custom,
};

/// 工具按钮样式
pub const ToolButtonStyle = enum {
    icon_only,
    text_only,
    both_horiz,
    both_vert,
};

/// 工具栏项
pub const ToolItem = struct {
    item_type: ToolItemType,
    label: []const u8 = "",
    icon_name: []const u8 = "",
    tooltip_text: []const u8 = "",
    enabled: bool = true,
    active: bool = false,
    custom_widget: ?*Widget = null,
    on_click: ?*const fn (self: *anyopaque) void = null,
    on_click_ctx: ?*anyopaque = null,
};

pub const Toolbar = struct {
    base: Widget,
    allocator: std.mem.Allocator,
    items: std.ArrayListUnmanaged(ToolItem),
    orientation: enum { horizontal, vertical } = .horizontal,
    button_style: ToolButtonStyle = .both_horiz,
    icon_size: f32 = 16,
    font_size: f32 = 11,
    item_size: f32 = 36,
    item_spacing: f32 = 2,
    item_padding: f32 = 6,
    separator_padding: f32 = 4,

    bg_color: math.Color = math.Color.hex(0xF1F5F9FF),
    border_color: math.Color = math.Color.hex(0xE2E8F0FF),
    text_color: math.Color = math.Color.hex(0x334155FF),
    hover_bg: math.Color = math.Color.hex(0xE2E8F0FF),
    active_bg: math.Color = math.Color.hex(0xCBD5E1FF),
    disabled_text_color: math.Color = math.Color.hex(0x94A3B8FF),

    hovered_item: ?usize = null,
    pressed_item: ?usize = null,

    const Self = @This();

    pub fn create(allocator: std.mem.Allocator, opts: struct {
        orientation: enum { horizontal, vertical } = .horizontal,
        button_style: ToolButtonStyle = .both_horiz,
        icon_size: f32 = 16,
        font_size: f32 = 11,
        item_size: f32 = 36,
        item_spacing: f32 = 2,
        item_padding: f32 = 6,
        bg_color: math.Color = math.Color.hex(0xF1F5F9FF),
        border_color: math.Color = math.Color.hex(0xE2E8F0FF),
        text_color: math.Color = math.Color.hex(0x334155FF),
    }) !*Toolbar {
        const self = try allocator.create(Toolbar);
        self.* = .{
            .base = .{
                .vtable = &vtable,
                .id = widget_mod.genWidgetId(),
            },
            .allocator = allocator,
            .items = .{},
            .orientation = opts.orientation,
            .button_style = opts.button_style,
            .icon_size = opts.icon_size,
            .font_size = opts.font_size,
            .item_size = opts.item_size,
            .item_spacing = opts.item_spacing,
            .item_padding = opts.item_padding,
            .bg_color = opts.bg_color,
            .border_color = opts.border_color,
            .text_color = opts.text_color,
        };
        self.base.accessibility = .{ .role = .toolbar };
        return self;
    }

    pub fn destroy(self: *Self, allocator: std.mem.Allocator) void {
        for (self.items.items) |item| {
            if (item.item_type == .custom and item.custom_widget) |w| {
                w.destroy(allocator);
            }
        }
        self.items.deinit(allocator);
        self.base.background.deinit(allocator);
        self.base.children.deinit(allocator);
        allocator.destroy(self);
    }

    /// 添加工具按钮
    pub fn addButton(self: *Self, label: []const u8, icon_name: []const u8, on_click: ?*const fn (ctx: *anyopaque) void, ctx: ?*anyopaque) !void {
        try self.items.append(self.allocator, .{
            .item_type = .button,
            .label = label,
            .icon_name = icon_name,
            .on_click = on_click,
            .on_click_ctx = ctx,
        });
        self.base.markLayoutDirty();
    }

    /// 添加分隔线
    pub fn addSeparator(self: *Self) !void {
        try self.items.append(self.allocator, .{
            .item_type = .separator,
        });
        self.base.markLayoutDirty();
    }

    /// 添加自定义控件
    pub fn addCustom(self: *Self, widget: *Widget) !void {
        try self.items.append(self.allocator, .{
            .item_type = .custom,
            .custom_widget = widget,
        });
        try self.base.addChild(self.allocator, widget);
        self.base.markLayoutDirty();
    }

    /// 获取指定索引的项
    pub fn getItem(self: *Self, index: usize) ?*ToolItem {
        if (index >= self.items.items.len) return null;
        return &self.items.items[index];
    }

    /// 设置项的启用状态
    pub fn setItemEnabled(self: *Self, index: usize, enabled: bool) void {
        if (index >= self.items.items.len) return;
        self.items.items[index].enabled = enabled;
        self.base.markDirty();
    }

    /// 设置项的激活状态
    pub fn setItemActive(self: *Self, index: usize, active: bool) void {
        if (index >= self.items.items.len) return;
        self.items.items[index].active = active;
        self.base.markDirty();
    }

    fn getItemSize(self: *const Self, item: *const ToolItem, allocator: std.mem.Allocator) math.Size(f32) {
        if (item.item_type == .separator) {
            if (self.orientation == .horizontal) {
                return .{ .width = 1, .height = self.item_size - self.separator_padding * 2 };
            } else {
                return .{ .width = self.item_size - self.separator_padding * 2, .height = 1 };
            }
        }

        if (item.item_type == .custom and item.custom_widget) |w| {
            return .{ .width = w.rect.width, .height = w.rect.height };
        }

        var w: f32 = 0;
        var h: f32 = 0;

        const has_icon = item.icon_name.len > 0;
        const has_text = item.label.len > 0;

        switch (self.button_style) {
            .icon_only => {
                if (has_icon) {
                    w = self.icon_size + self.item_padding * 2;
                    h = self.icon_size + self.item_padding * 2;
                } else {
                    w = self.item_size;
                    h = self.item_size;
                }
            },
            .text_only => {
                if (has_text) {
                    const text_size = styled_text.measureText(allocator, item.label, .{
                        .font_size = self.font_size,
                    });
                    w = text_size.width + self.item_padding * 2;
                    h = text_size.height + self.item_padding * 2;
                } else {
                    w = self.item_size;
                    h = self.item_size;
                }
            },
            .both_horiz => {
                var content_w: f32 = 0;
                var content_h: f32 = 0;
                if (has_icon) {
                    content_w += self.icon_size;
                    content_h = @max(content_h, self.icon_size);
                }
                if (has_text) {
                    const text_size = styled_text.measureText(allocator, item.label, .{
                        .font_size = self.font_size,
                    });
                    if (has_icon) content_w += 4;
                    content_w += text_size.width;
                    content_h = @max(content_h, text_size.height);
                }
                w = content_w + self.item_padding * 2;
                h = content_h + self.item_padding * 2;
            },
            .both_vert => {
                var content_w: f32 = 0;
                var content_h: f32 = 0;
                if (has_icon) {
                    content_w = @max(content_w, self.icon_size);
                    content_h += self.icon_size;
                }
                if (has_text) {
                    const text_size = styled_text.measureText(allocator, item.label, .{
                        .font_size = self.font_size,
                    });
                    if (has_icon) content_h += 2;
                    content_w = @max(content_w, text_size.width);
                    content_h += text_size.height;
                }
                w = content_w + self.item_padding * 2;
                h = content_h + self.item_padding * 2;
            },
        }

        return .{ .width = w, .height = h };
    }

    fn findItemAt(self: *const Self, w: *const Widget, allocator: std.mem.Allocator, x: f32, y: f32) ?usize {
        var cur_x: f32 = self.item_spacing;
        var cur_y: f32 = self.item_spacing;

        for (self.items.items, 0..) |item, i| {
            const size = self.getItemSize(&item, allocator);

            if (self.orientation == .horizontal) {
                if (x >= cur_x and x < cur_x + size.width and
                    y >= 0 and y < w.rect.height)
                {
                    if (item.item_type == .button and item.enabled) return i;
                }
                cur_x += size.width + self.item_spacing;
            } else {
                if (y >= cur_y and y < cur_y + size.height and
                    x >= 0 and x < w.rect.width)
                {
                    if (item.item_type == .button and item.enabled) return i;
                }
                cur_y += size.height + self.item_spacing;
            }
        }
        return null;
    }

    // ── VTable ──────────────────────────────────────────────────────────────

    const vtable = Widget.VTable{
        .type_name = "toolbar",
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

        var total_w: f32 = self.item_spacing;
        var total_h: f32 = self.item_spacing;
        var max_cross: f32 = 0;

        for (self.items.items) |item| {
            const size = self.getItemSize(&item, ctx.allocator);

            if (self.orientation == .horizontal) {
                total_w += size.width + self.item_spacing;
                max_cross = @max(max_cross, size.height + self.item_spacing * 2);
            } else {
                total_h += size.height + self.item_spacing;
                max_cross = @max(max_cross, size.width + self.item_spacing * 2);
            }
        }

        if (self.orientation == .horizontal) {
            total_h = @max(max_cross, self.item_size);
        } else {
            total_w = @max(max_cross, self.item_size);
        }

        if (self.orientation == .horizontal) {
            const w_out = if (constraints.max_width < std.math.inf(f32))
                constraints.max_width
            else
                total_w;
            return .{ .width = w_out, .height = total_h };
        } else {
            const h_out = if (constraints.max_height < std.math.inf(f32))
                constraints.max_height
            else
                total_h;
            return .{ .width = total_w, .height = h_out };
        }
    }

    fn paint(w: *Widget, ctx: *PaintContext) void {
        const self: *Self = @fieldParentPtr("base", w);
        const rx = ctx.offset_x + w.rect.x;
        const ry = ctx.offset_y + w.rect.y;

        ctx.renderer.fillRect(
            .{ .x = rx, .y = ry, .width = w.rect.width, .height = w.rect.height },
            self.bg_color,
        ) catch {};

        if (self.orientation == .horizontal) {
            ctx.renderer.fillRect(
                .{ .x = rx, .y = ry + w.rect.height - 1, .width = w.rect.width, .height = 1 },
                self.border_color,
            ) catch {};
        } else {
            ctx.renderer.fillRect(
                .{ .x = rx + w.rect.width - 1, .y = ry, .width = 1, .height = w.rect.height },
                self.border_color,
            ) catch {};
        }

        var cur_x: f32 = rx + self.item_spacing;
        var cur_y: f32 = ry + self.item_spacing;

        for (self.items.items, 0..) |item, i| {
            const size = self.getItemSize(&item, ctx.allocator);

            if (item.item_type == .separator) {
                if (self.orientation == .horizontal) {
                    const sep_y = ry + self.separator_padding;
                    const sep_h = w.rect.height - self.separator_padding * 2;
                    ctx.renderer.fillRect(
                        .{ .x = cur_x, .y = sep_y, .width = 1, .height = sep_h },
                        self.border_color,
                    ) catch {};
                } else {
                    const sep_x = rx + self.separator_padding;
                    const sep_w = w.rect.width - self.separator_padding * 2;
                    ctx.renderer.fillRect(
                        .{ .x = sep_x, .y = cur_y, .width = sep_w, .height = 1 },
                        self.border_color,
                    ) catch {};
                }
            } else if (item.item_type == .button) {
                const is_hovered = (self.hovered_item == i);
                const is_pressed = (self.pressed_item == i);
                const is_active = item.active;

                if (is_pressed or is_active) {
                    ctx.renderer.fillRoundedRect(
                        .{ .x = cur_x, .y = cur_y, .width = size.width, .height = size.height },
                        4,
                        if (is_pressed) self.active_bg else self.hover_bg,
                    ) catch {};
                } else if (is_hovered and item.enabled) {
                    ctx.renderer.fillRoundedRect(
                        .{ .x = cur_x, .y = cur_y, .width = size.width, .height = size.height },
                        4,
                        self.hover_bg,
                    ) catch {};
                }

                const text_color = if (item.enabled) self.text_color else self.disabled_text_color;

                var content_x: f32 = 0;
                var content_y: f32 = 0;

                const has_icon = item.icon_name.len > 0;
                const has_text = item.label.len > 0;

                switch (self.button_style) {
                    .icon_only => {
                        if (has_icon) {
                            const icon_x = cur_x + (size.width - self.icon_size) / 2;
                            const icon_y = cur_y + (size.height - self.icon_size) / 2;
                            const icon = std.meta.stringToEnum(icons_mod.IconName, item.icon_name) orelse .none;
                            icons_mod.drawIcon(
                                ctx.renderer,
                                icon_x,
                                icon_y,
                                self.icon_size,
                                text_color,
                                icon,
                            ) catch {};
                        }
                    },
                    .text_only => {
                        if (has_text) {
                            const text_size = styled_text.measureText(ctx.allocator, item.label, .{
                                .font_size = self.font_size,
                            });
                            const text_x = cur_x + (size.width - text_size.width) / 2;
                            const text_y = cur_y + (size.height - text_size.height) / 2;
                            styled_text.drawText(
                                ctx.renderer,
                                ctx.allocator,
                                item.label,
                                text_x,
                                text_y,
                                .{ .font_size = self.font_size, .color = text_color },
                            );
                        }
                    },
                    .both_horiz => {
                        var cw: f32 = 0;
                        var ch: f32 = 0;
                        if (has_icon) {
                            cw += self.icon_size;
                            ch = @max(ch, self.icon_size);
                        }
                        if (has_text) {
                            const ts = styled_text.measureText(ctx.allocator, item.label, .{
                                .font_size = self.font_size,
                            });
                            if (has_icon) cw += 4;
                            cw += ts.width;
                            ch = @max(ch, ts.height);
                        }
                        content_x = cur_x + (size.width - cw) / 2;
                        content_y = cur_y + (size.height - ch) / 2;

                        var draw_x = content_x;
                        if (has_icon) {
                            const icon = std.meta.stringToEnum(icons_mod.IconName, item.icon_name) orelse .none;
                            icons_mod.drawIcon(
                                ctx.renderer,
                                draw_x,
                                content_y + (ch - self.icon_size) / 2,
                                self.icon_size,
                                text_color,
                                icon,
                            ) catch {};
                            draw_x += self.icon_size + 4;
                        }
                        if (has_text) {
                            const ts = styled_text.measureText(ctx.allocator, item.label, .{
                                .font_size = self.font_size,
                            });
                            styled_text.drawText(
                                ctx.renderer,
                                ctx.allocator,
                                item.label,
                                draw_x,
                                content_y + (ch - ts.height) / 2,
                                .{ .font_size = self.font_size, .color = text_color },
                            );
                        }
                    },
                    .both_vert => {
                        var cw: f32 = 0;
                        var ch: f32 = 0;
                        if (has_icon) {
                            cw = @max(cw, self.icon_size);
                            ch += self.icon_size;
                        }
                        if (has_text) {
                            const ts = styled_text.measureText(ctx.allocator, item.label, .{
                                .font_size = self.font_size,
                            });
                            if (has_icon) ch += 2;
                            cw = @max(cw, ts.width);
                            ch += ts.height;
                        }
                        content_x = cur_x + (size.width - cw) / 2;
                        content_y = cur_y + (size.height - ch) / 2;

                        var draw_y = content_y;
                        if (has_icon) {
                            const icon = std.meta.stringToEnum(icons_mod.IconName, item.icon_name) orelse .none;
                            icons_mod.drawIcon(
                                ctx.renderer,
                                content_x + (cw - self.icon_size) / 2,
                                draw_y,
                                self.icon_size,
                                text_color,
                                icon,
                            ) catch {};
                            draw_y += self.icon_size + 2;
                        }
                        if (has_text) {
                            const ts = styled_text.measureText(ctx.allocator, item.label, .{
                                .font_size = self.font_size,
                            });
                            styled_text.drawText(
                                ctx.renderer,
                                ctx.allocator,
                                item.label,
                                content_x + (cw - ts.width) / 2,
                                draw_y,
                                .{ .font_size = self.font_size, .color = text_color },
                            );
                        }
                    },
                }
            } else if (item.item_type == .custom and item.custom_widget) |child| {
                child.rect.x = cur_x - rx;
                child.rect.y = cur_y - ry;
                child.vtable.paint(child, ctx);
            }

            if (self.orientation == .horizontal) {
                cur_x += size.width + self.item_spacing;
            } else {
                cur_y += size.height + self.item_spacing;
            }
        }
    }

    fn onEvent(w: *Widget, event: *const pal.Event, ectx: *EventContext) EventResult {
        const self: *Self = @fieldParentPtr("base", w);

        switch (event.*) {
            .mouse_move => |mm| {
                const mx: f32 = @floatFromInt(mm.x);
                const my: f32 = @floatFromInt(mm.y);

                const hovered = self.findItemAt(w, self.allocator, mx, my);
                if (hovered != self.hovered_item) {
                    self.hovered_item = hovered;
                    self.base.markDirty();
                }

                if (hovered) |idx| {
                    const item = &self.items.items[idx];
                    if (item.item_type == .custom and item.custom_widget) |child| {
                        const child_event = event.*;
                        return child.vtable.on_event.?(child, &child_event, ectx);
                    }
                }

                return .ignored;
            },
            .mouse_button => |mb| {
                if (mb.button == .left) {
                    const mx: f32 = @floatFromInt(mb.x);
                    const my: f32 = @floatFromInt(mb.y);

                    if (mb.state == .pressed) {
                        const clicked = self.findItemAt(w, self.allocator, mx, my);
                        if (clicked) |idx| {
                            const item = &self.items.items[idx];
                            if (item.item_type == .button and item.enabled) {
                                self.pressed_item = idx;
                                self.base.markDirty();
                                return .handled;
                            } else if (item.item_type == .custom and item.custom_widget) |child| {
                                return child.vtable.on_event.?(child, event, ectx);
                            }
                        }
                    } else if (mb.state == .released) {
                        if (self.pressed_item) |idx| {
                            const released = self.findItemAt(w, self.allocator, mx, my);
                            if (released == idx) {
                                const item = &self.items.items[idx];
                                if (item.on_click) |cb| {
                                    cb(item.on_click_ctx);
                                }
                            }
                            self.pressed_item = null;
                            self.base.markDirty();
                            return .handled;
                        }
                    }
                }
            },
            else => {},
        }
        return .ignored;
    }
};
