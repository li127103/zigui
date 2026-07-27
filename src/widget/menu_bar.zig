//! MenuBar 控件 - 顶部菜单栏 (File/Edit/View/Help 等)
//!
//! 包含多个菜单项 (如 "File", "Edit"), 每项点击弹出对应的下拉菜单 (Menu)。
//! 通常放在窗口顶部, 作为应用的主菜单。

const std = @import("std");
const math = @import("../math.zig");
const widget_mod = @import("widget.zig");
const layout_mod = @import("../layout/engine.zig");
const pal = @import("../pal/pal.zig");
const menu_mod = @import("menu.zig");
const styled_text = @import("../text/styled_text.zig");

const Widget = widget_mod.Widget;
const PaintContext = widget_mod.PaintContext;
const EventContext = widget_mod.EventContext;
const EventResult = widget_mod.EventResult;

const MenuBarItem = struct {
    label: []const u8,
    menu: *menu_mod.Menu,
};

pub const MenuBar = struct {
    base: Widget,
    allocator: std.mem.Allocator,
    items: std.ArrayListUnmanaged(MenuBarItem),
    active_menu: ?usize = null,
    font_size: f32,
    height: f32,
    item_padding_h: f32,
    // 样式
    bg_color: math.Color,
    text_color: math.Color,
    hover_bg: math.Color,
    active_bg: math.Color,
    border_color: math.Color,

    pub fn create(allocator: std.mem.Allocator, opts: struct {
        font_size: f32 = 13.0,
        height: f32 = 28,
        item_padding_h: f32 = 12,
        bg_color: math.Color = math.Color.hex(0xF8FAFCFF),
        text_color: math.Color = math.Color.hex(0x1E293BFF),
        hover_bg: math.Color = math.Color.hex(0xE2E8F0FF),
        active_bg: math.Color = math.Color.hex(0xCBD5E1FF),
        border_color: math.Color = math.Color.hex(0xE2E8F0FF),
    }) !*MenuBar {
        const self = try allocator.create(MenuBar);
        self.* = .{
            .base = .{
                .vtable = &vtable,
                .id = widget_mod.genWidgetId(),
            },
            .allocator = allocator,
            .items = .{ .items = &.{}, .capacity = 0 },
            .font_size = opts.font_size,
            .height = opts.height,
            .item_padding_h = opts.item_padding_h,
            .bg_color = opts.bg_color,
            .text_color = opts.text_color,
            .hover_bg = opts.hover_bg,
            .active_bg = opts.active_bg,
            .border_color = opts.border_color,
        };
        self.base.accessibility = .{ .role = .menu };
        return self;
    }

    pub fn destroy(self: *MenuBar, allocator: std.mem.Allocator) void {
        for (self.items.items) |item| {
            item.menu.destroy(allocator);
        }
        self.items.deinit(allocator);
        self.base.background.deinit(allocator);
        self.base.children.deinit(allocator);
        allocator.destroy(self);
    }

    /// 添加菜单项 (标签 + 对应的下拉菜单)
    pub fn addMenu(self: *MenuBar, label: []const u8, menu: *menu_mod.Menu) !void {
        try self.items.append(self.allocator, .{ .label = label, .menu = menu });
        self.base.markLayoutDirty();
    }

    /// 关闭所有打开的菜单
    pub fn closeAll(self: *MenuBar) void {
        if (self.active_menu) |idx| {
            self.items.items[idx].menu.open = false;
        }
        self.active_menu = null;
        self.base.markDirty();
    }

    /// 获取菜单项的 x 范围
    fn getItemRect(self: *const MenuBar, ctx: *PaintContext, index: usize) math.Rect(f32) {
        var x: f32 = 0;
        for (self.items.items, 0..) |item, i| {
            const text_size = styled_text.measureText(ctx.allocator, item.label, .{
                .font_size = self.font_size,
            });
            const w = text_size.width + self.item_padding_h * 2;
            if (i == index) {
                return .{
                    .x = x,
                    .y = 0,
                    .width = w,
                    .height = self.height,
                };
            }
            x += w;
        }
        return .{ .x = 0, .y = 0, .width = 0, .height = 0 };
    }

    fn findItemAt(self: *const MenuBar, ctx: *PaintContext, x: f32) ?usize {
        var cur_x: f32 = 0;
        for (self.items.items, 0..) |item, i| {
            const text_size = styled_text.measureText(ctx.allocator, item.label, .{
                .font_size = self.font_size,
            });
            const w = text_size.width + self.item_padding_h * 2;
            if (x >= cur_x and x < cur_x + w) {
                return i;
            }
            cur_x += w;
        }
        return null;
    }

    // ── VTable ──────────────────────────────────────────────────────────────

    const vtable = Widget.VTable{
        .type_name = "menu_bar",
        .measure = measure,
        .paint = paint,
        .on_event = onEvent,
        .focusable = false,
        .destroy = destroyVTable,
    };

    fn destroyVTable(w: *Widget, allocator: std.mem.Allocator) void {
        const self: *MenuBar = @fieldParentPtr("base", w);
        self.destroy(allocator);
    }

    fn measure(w: *Widget, ctx: *PaintContext, constraints: layout_mod.Constraints) math.Size(f32) {
        const self: *MenuBar = @fieldParentPtr("base", w);
        _ = ctx;
        const w_out = if (constraints.max_width < std.math.inf(f32))
            constraints.max_width
        else
            400;
        return .{ .width = w_out, .height = self.height };
    }

    fn paint(w: *Widget, ctx: *PaintContext) void {
        const self: *MenuBar = @fieldParentPtr("base", w);
        const rx = ctx.offset_x + w.rect.x;
        const ry = ctx.offset_y + w.rect.y;

        // 背景
        ctx.renderer.fillRect(
            .{ .x = rx, .y = ry, .width = w.rect.width, .height = w.rect.height },
            self.bg_color,
        ) catch {};

        // 底部边框
        ctx.renderer.fillRect(
            .{ .x = rx, .y = ry + w.rect.height - 1, .width = w.rect.width, .height = 1 },
            self.border_color,
        ) catch {};

        // 菜单项
        var x: f32 = rx;
        for (self.items.items, 0..) |item, i| {
            const text_size = styled_text.measureText(ctx.allocator, item.label, .{
                .font_size = self.font_size,
            });
            const item_w = text_size.width + self.item_padding_h * 2;
            const is_active = (self.active_menu == i);

            // 背景
            if (is_active) {
                ctx.renderer.fillRect(
                    .{ .x = x, .y = ry, .width = item_w, .height = w.rect.height },
                    self.active_bg,
                ) catch {};
            }

            // 文本
            const text_x = x + self.item_padding_h;
            const text_y = ry + (w.rect.height - text_size.height) / 2.0 + 1;
            styled_text.drawText(
                ctx.renderer,
                ctx.allocator,
                item.label,
                text_x,
                text_y,
                .{ .font_size = self.font_size, .color = self.text_color },
            );

            // 如果菜单打开, 绘制下拉菜单
            if (is_active and item.menu.open) {
                item.menu.base.rect.x = x - rx;
                item.menu.base.rect.y = w.rect.height;
                item.menu.base.vtable.paint(&item.menu.base, ctx);
            }

            x += item_w;
        }
    }

    fn onEvent(w: *Widget, event: *const pal.Event, ectx: *EventContext) EventResult {
        const self: *MenuBar = @fieldParentPtr("base", w);

        switch (event.*) {
            .mouse_button => |mb| {
                if (mb.button == .left and mb.state == .pressed) {
                    const mx: f32 = @floatFromInt(mb.x);
                    const my: f32 = @floatFromInt(mb.y);

                    if (my >= 0 and my < w.rect.height) {
                        // 简化: 用估算宽度线性扫描查找菜单项
                        var found: ?usize = null;
                        var cur_x: f32 = 0;
                        for (self.items.items, 0..) |item, i| {
                            const est_w: f32 = @as(f32, @floatFromInt(item.label.len)) * 8 + self.item_padding_h * 2;
                            if (mx >= cur_x and mx < cur_x + est_w) {
                                found = i;
                                break;
                            }
                            cur_x += est_w;
                        }

                        if (found) |idx| {
                            if (self.active_menu == idx) {
                                self.closeAll();
                            } else {
                                self.closeAll();
                                self.active_menu = idx;
                                self.items.items[idx].menu.open = true;
                                self.base.markDirty();
                            }
                            return .handled;
                        }
                    } else {
                        self.closeAll();
                        return .handled;
                    }
                }
            },
            .mouse_move => |mm| {
                if (self.active_menu) |idx| {
                    const my: f32 = @floatFromInt(mm.y);
                    if (my >= w.rect.height) {
                        const item = self.items.items[idx];
                        return item.menu.base.vtable.on_event.?(&item.menu.base, event, ectx);
                    }
                }
                return .ignored;
            },
            else => {},
        }
        return .ignored;
    }
};

// ── Tests ──────────────────────────────────────────────────────────────────

test "menu_bar create" {
    const mb = try MenuBar.create(std.testing.allocator, .{});
    defer mb.destroy(std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 0), mb.items.items.len);
    try std.testing.expectEqual(@as(f32, 28), mb.height);
}

test "menu_bar addMenu increases count" {
    const mb = try MenuBar.create(std.testing.allocator, .{});
    defer mb.destroy(std.testing.allocator);

    const m1 = try menu_mod.Menu.create(std.testing.allocator, .{});
    const m2 = try menu_mod.Menu.create(std.testing.allocator, .{});

    try mb.addMenu("File", m1);
    try mb.addMenu("Edit", m2);

    try std.testing.expectEqual(@as(usize, 2), mb.items.items.len);
    try std.testing.expectEqualStrings("File", mb.items.items[0].label);
    try std.testing.expectEqualStrings("Edit", mb.items.items[1].label);
}

test "menu_bar closeAll" {
    const mb = try MenuBar.create(std.testing.allocator, .{});
    defer mb.destroy(std.testing.allocator);

    const m = try menu_mod.Menu.create(std.testing.allocator, .{});
    try mb.addMenu("File", m);

    mb.active_menu = 0;
    m.open = true;
    mb.closeAll();

    try std.testing.expectEqual(@as(?usize, null), mb.active_menu);
    try std.testing.expectEqual(false, m.open);
}

test "menu_bar custom height" {
    const mb = try MenuBar.create(std.testing.allocator, .{ .height = 32 });
    defer mb.destroy(std.testing.allocator);

    try std.testing.expectEqual(@as(f32, 32), mb.height);
}
