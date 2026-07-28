//! ContextMenu 右键菜单
//!
//! 便捷的右键菜单控件，封装了菜单的创建、定位和显示。
//! 用法:
//!   const menu = try ContextMenu.create(allocator, &.{
//!       .{ .label = "复制", .on_click = onCopy },
//!       .{ .label = "粘贴", .on_click = onPaste },
//!       .{ .is_separator = true },
//!       .{ .label = "删除", .disabled = true },
//!   });
//!   some_widget.context_menu = &menu.base;

const std = @import("std");
const math = @import("../math.zig");
const widget_mod = @import("widget.zig");
const layout_mod = @import("../layout/engine.zig");
const pal = @import("../pal/pal.zig");
const styled_text = @import("../text/styled_text.zig");

const Widget = widget_mod.Widget;
const PaintContext = widget_mod.PaintContext;
const EventContext = widget_mod.EventContext;
const EventResult = widget_mod.EventResult;

pub const ContextMenuItem = struct {
    label: []const u8 = "",
    disabled: bool = false,
    is_separator: bool = false,
    on_click: ?*const fn (ctx: ?*anyopaque) void = null,
    ctx: ?*anyopaque = null,
};

pub const ContextMenu = struct {
    base: Widget,
    allocator: std.mem.Allocator,
    items: std.ArrayListUnmanaged(ContextMenuItem),
    open: bool = false,
    pos_x: f32 = 0,
    pos_y: f32 = 0,
    hovered_index: ?usize = null,
    on_before_show: ?*const fn (self: *ContextMenu) void = null,
    // 样式
    bg_color: math.Color = math.Color.hex(0x1E293BFF),
    border_color: math.Color = math.Color.hex(0x334155FF),
    text_color: math.Color = math.Color.hex(0xF8FAFCFF),
    disabled_color: math.Color = math.Color.hex(0x475569FF),
    hover_bg: math.Color = math.Color.hex(0x3B82F6FF),
    separator_color: math.Color = math.Color.hex(0x334155FF),
    corner_radius: f32 = 8.0,
    item_height: f32 = 32.0,
    min_width: f32 = 200.0,
    padding_h: f32 = 16.0,
    font_size: f32 = 13.0,

    pub fn create(allocator: std.mem.Allocator, items: []const ContextMenuItem) !*ContextMenu {
        const self = try allocator.create(ContextMenu);
        self.* = .{
            .base = .{
                .vtable = &vtable,
                .id = widget_mod.genWidgetId(),
            },
            .allocator = allocator,
            .items = .{ .items = &.{}, .capacity = 0 },
        };
        try self.items.appendSlice(allocator, items);
        self.base.accessibility = .{ .role = .menu };
        return self;
    }

    pub fn destroy(self: *ContextMenu, allocator: std.mem.Allocator) void {
        self.base.background.deinit(allocator);
        self.base.children.deinit(allocator);
        self.items.deinit(allocator);
        allocator.destroy(self);
    }

    pub fn setItemDisabled(self: *ContextMenu, index: usize, disabled: bool) void {
        if (index < self.items.items.len) {
            self.items.items[index].disabled = disabled;
        }
    }

    /// 在指定位置显示菜单 (x/y 为父级坐标, 即调用者的坐标系)
    pub fn popupAt(self: *ContextMenu, x: f32, y: f32) void {
        if (self.on_before_show) |cb| cb(self);
        self.pos_x = x;
        self.pos_y = y;
        self.base.rect.x = x;
        self.base.rect.y = y;
        self.open = true;
        self.hovered_index = null;
        self.base.state.visible = true;
        self.base.markDirty();
    }

    /// 隐藏菜单
    pub fn popdown(self: *ContextMenu) void {
        self.open = false;
        self.base.state.visible = false;
        self.hovered_index = null;
        self.base.markDirty();
    }

    /// 检查点是否在菜单范围内 (用于点击外部关闭)
    pub fn containsPoint(self: *ContextMenu, x: f32, y: f32) bool {
        if (!self.open) return false;
        const w = @max(self.base.rect.width, self.min_width);
        const h = self.menuHeight();
        return x >= self.pos_x and x < self.pos_x + w and
            y >= self.pos_y and y < self.pos_y + h;
    }

    fn menuHeight(self: *const ContextMenu) f32 {
        const count: f32 = @floatFromInt(self.items.items.len);
        return count * self.item_height + 4;
    }

    fn itemY(self: *const ContextMenu, index: usize) f32 { 
        return self.pos_y + 2 + @as(f32, @floatFromInt(index)) * self.item_height;
    }

    fn hitTestItem(self: *ContextMenu, x: f32, y: f32) ?usize {
        if (!self.open) return null;
        if (x < self.pos_x or x >= self.pos_x + @max(self.base.rect.width, self.min_width)) return null;

        const local_y = y - self.pos_y - 2;
        if (local_y < 0) return null;

        const idx: usize = @intFromFloat(@floor(local_y / self.item_height));
        if (idx >= self.items.items.len) return null;
        return idx;
    }

    // ── VTable ──────────────────────────────────────────────────────────────

    const vtable = Widget.VTable{
        .type_name = "ContextMenu",
        .measure = measure,
        .paint = paint,
        .on_event = onEvent,
        .perform_layout = performLayout,
        .focusable = true,
        .destroy = destroyVTable,
    };

    fn destroyVTable(w: *Widget, allocator: std.mem.Allocator) void {
        const self: *ContextMenu = @fieldParentPtr("base", w);
        self.destroy(allocator);
    }

    fn performLayout(w: *Widget, _: *PaintContext) void {
        const self: *ContextMenu = @fieldParentPtr("base", w);
        // 不接受布局系统的位置设置, 使用自己的 pos_x/pos_y
        w.rect.width = self.min_width;
        w.rect.height = self.menuHeight();
        w.rect.x = self.pos_x;
        w.rect.y = self.pos_y;
    }

    fn measure(w: *Widget, ctx: *PaintContext, constraints: layout_mod.Constraints) math.Size(f32) {
        const self: *ContextMenu = @fieldParentPtr("base", w);
        if (!self.open) return .{ .width = 0, .height = 0 };
        _ = constraints;
        _ = ctx;
        return .{ .width = self.min_width, .height = self.menuHeight() };
    }

    fn paint(w: *Widget, ctx: *PaintContext) void {
        const self: *ContextMenu = @fieldParentPtr("base", w);
        if (!self.open or self.items.items.len == 0) return;

        const w_ = @max(self.min_width, 180);
        const h = self.menuHeight();

        // 边框背景
        ctx.renderer.fillRoundedRect(.{ .x = self.pos_x, .y = self.pos_y, .width = w_, .height = h }, self.corner_radius, self.border_color) catch {};
        ctx.renderer.fillRoundedRect(.{ .x = self.pos_x + 1, .y = self.pos_y + 1, .width = w_ - 2, .height = h - 2 }, self.corner_radius - 1, self.bg_color) catch {};

        for (self.items.items, 0..) |item, i| {
            const iy = self.itemY(i);

            if (item.is_separator) {
                ctx.renderer.fillRect(
                    .{ .x = self.pos_x + 12, .y = iy + self.item_height / 2 - 0.5, .width = w_ - 24, .height = 1 },
                    self.separator_color,
                ) catch {};
                continue;
            }

            const is_hovered = self.hovered_index != null and self.hovered_index.? == i;

            if (is_hovered and !item.disabled) {
                ctx.renderer.fillRoundedRect(
                    .{ .x = self.pos_x + 4, .y = iy, .width = w_ - 8, .height = self.item_height - 2 },
                    4,
                    self.hover_bg,
                ) catch {};
            }

            const color = if (item.disabled) self.disabled_color else self.text_color;
            styled_text.drawText(
                ctx.renderer,
                ctx.allocator,
                item.label,
                self.pos_x + self.padding_h,
                iy + (self.item_height - self.font_size * 1.2) / 2.0,
                .{ .font_size = self.font_size, .color = color },
            );
        }
    }

    fn onEvent(w: *Widget, event: *const pal.Event, ectx: *EventContext) EventResult {
        const self: *ContextMenu = @fieldParentPtr("base", w);
        if (!self.open) return .ignored;
        _ = ectx;

        switch (event.*) {
            .mouse_move => |mm| {
                const mx: f32 = @floatFromInt(mm.x);
                const my: f32 = @floatFromInt(mm.y);
                self.hovered_index = self.hitTestItem(mx, my);
                if (self.hovered_index != null) {
                    self.base.markDirty();
                    return .handled;
                }
            },
            .mouse_button => |mb| {
                if (mb.button == .left and mb.state == .pressed) {
                    const mx: f32 = @floatFromInt(mb.x);
                    const my: f32 = @floatFromInt(mb.y);

                    if (self.hitTestItem(mx, my)) |idx| {
                        const item = self.items.items[idx];
                        if (!item.disabled and item.on_click != null) {
                            item.on_click.?(item.ctx);
                        }
                        self.popdown();
                        return .handled;
                    }
                }
            },
            else => {},
        }

        return .ignored;
    }
};
