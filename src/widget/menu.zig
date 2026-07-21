//! Menu 控件 - 菜单 (菜单项/分隔线/快捷键/子菜单)

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

pub const MenuItem = struct {
    label: []const u8 = "",
    shortcut: []const u8 = "", // 快捷键提示文本 (如 "⌘C")
    is_separator: bool = false,
    disabled: bool = false,
    on_click: ?*const fn (ctx: ?*anyopaque) void = null,
    ctx: ?*anyopaque = null,
    submenu: ?*Menu = null,

    pub fn separator() MenuItem {
        return .{ .is_separator = true };
    }
};

pub const Menu = struct {
    base: Widget,
    allocator: std.mem.Allocator,
    items: std.ArrayListUnmanaged(MenuItem),
    open: bool = false,
    hovered: ?usize = null,
    submenu_open: ?usize = null, // 展开子菜单的项索引
    font_size: f32,
    on_close: ?*const fn (self: *Menu) void,
    // 样式
    bg_color: math.Color = math.Color.hex(0x1E293BFF),
    border_color: math.Color = math.Color.hex(0x334155FF),
    text_color: math.Color = math.Color.hex(0xF8FAFCFF),
    disabled_color: math.Color = math.Color.hex(0x475569FF),
    shortcut_color: math.Color = math.Color.hex(0x64748BFF),
    hover_bg: math.Color = math.Color.hex(0x3B82F6FF),
    separator_color: math.Color = math.Color.hex(0x334155FF),
    corner_radius: f32 = 8.0,
    item_height: f32 = 30.0,
    min_width: f32 = 180.0,
    padding_h: f32 = 12.0,

    pub fn create(allocator: std.mem.Allocator, opts: struct {
        font_size: f32 = 13.0,
        on_close: ?*const fn (self: *Menu) void = null,
    }) !*Menu {
        const self = try allocator.create(Menu);
        self.* = .{
            .base = .{
                .vtable = &vtable,
                .id = widget_mod.genWidgetId(),
            },
            .allocator = allocator,
            .items = .{ .items = &.{}, .capacity = 0 },
            .font_size = opts.font_size,
            .on_close = opts.on_close,
        };
        return self;
    }

    pub fn destroy(self: *Menu, allocator: std.mem.Allocator) void {
        // 递归销毁子菜单
        for (self.items.items) |*item| {
            if (item.submenu) |sub| {
                sub.destroy(allocator);
            }
        }
        self.items.deinit(allocator);
        self.base.children.deinit(allocator);
        allocator.destroy(self);
    }

    pub fn addItem(self: *Menu, item: MenuItem) !void {
        try self.items.append(self.allocator, item);
    }

    pub fn addSeparator(self: *Menu) !void {
        try self.items.append(self.allocator, MenuItem.separator());
    }

    pub fn openMenu(self: *Menu) void {
        self.open = true;
        self.hovered = null;
        self.submenu_open = null;
        self.base.markDirty();
    }

    pub fn closeMenu(self: *Menu) void {
        self.open = false;
        self.hovered = null;
        // 关闭子菜单
        if (self.submenu_open) |idx| {
            if (idx < self.items.items.len) {
                if (self.items.items[idx].submenu) |sub| sub.closeMenu();
            }
        }
        self.submenu_open = null;
        self.base.markDirty();
        if (self.on_close) |cb| cb(self);
    }

    /// 菜单面板高度
    fn panelHeight(self: *const Menu) f32 {
        var h: f32 = 8; // 上下内边距
        for (self.items.items) |item| {
            h += if (item.is_separator) 9.0 else self.item_height;
        }
        return h;
    }

    /// 第 i 项的 Y 偏移 (相对面板顶部)
    fn itemY(self: *const Menu, index: usize) f32 {
        var y: f32 = 4;
        var i: usize = 0;
        while (i < index and i < self.items.items.len) : (i += 1) {
            y += if (self.items.items[i].is_separator) 9.0 else self.item_height;
        }
        return y;
    }

    /// 根据面板内相对 Y 坐标求项索引
    fn indexAtY(self: *const Menu, rel_y: f32) ?usize {
        var y: f32 = 4;
        for (self.items.items, 0..) |item, i| {
            const h: f32 = if (item.is_separator) 9.0 else self.item_height;
            if (rel_y >= y and rel_y < y + h) {
                return if (item.is_separator) null else i;
            }
            y += h;
        }
        return null;
    }

    // ── VTable ──────────────────────────────────────────────────────────────

    const vtable = Widget.VTable{
        .type_name = "menu",
        .measure = measure,
        .paint = paint,
        .on_event = onEvent,
        .focusable = true,
        .destroy = destroyVTable,
    };

    fn destroyVTable(w: *Widget, allocator: std.mem.Allocator) void {
        const self: *Menu = @fieldParentPtr("base", w);
        self.destroy(allocator);
    }

    fn measure(w: *Widget, ctx: *PaintContext, constraints: layout_mod.Constraints) math.Size(f32) {
        const self: *Menu = @fieldParentPtr("base", w);
        _ = ctx;
        _ = constraints;
        return .{ .width = self.min_width, .height = self.panelHeight() };
    }

    fn paint(w: *Widget, ctx: *PaintContext) void {
        const self: *Menu = @fieldParentPtr("base", w);
        if (!self.open) return;

        const rx = ctx.offset_x + w.rect.x;
        const ry = ctx.offset_y + w.rect.y;
        const rw = @max(w.rect.width, self.min_width);
        const rh = self.panelHeight();

        // 面板背景 + 边框
        ctx.renderer.fillRoundedRect(.{ .x = rx, .y = ry, .width = rw, .height = rh }, self.corner_radius, self.border_color) catch {};
        ctx.renderer.fillRoundedRect(.{ .x = rx + 1, .y = ry + 1, .width = rw - 2, .height = rh - 2 }, self.corner_radius - 1, self.bg_color) catch {};

        for (self.items.items, 0..) |item, i| {
            const iy = ry + self.itemY(i);

            if (item.is_separator) {
                ctx.renderer.fillRect(
                    .{ .x = rx + 8, .y = iy + 4, .width = rw - 16, .height = 1 },
                    self.separator_color,
                ) catch {};
                continue;
            }

            const is_hovered = self.hovered != null and self.hovered.? == i;
            const is_submenu_open = self.submenu_open != null and self.submenu_open.? == i;

            // hover / 子菜单展开背景
            if (is_hovered or is_submenu_open) {
                ctx.renderer.fillRoundedRect(
                    .{ .x = rx + 4, .y = iy, .width = rw - 8, .height = self.item_height - 2 },
                    4,
                    self.hover_bg,
                ) catch {};
            }

            const label_color = if (item.disabled) self.disabled_color else self.text_color;
            self.drawLabel(ctx, item.label, rx + self.padding_h, iy + (self.item_height - self.font_size * 1.2) / 2.0, label_color);

            // 快捷键文本 (右对齐) 或子菜单箭头
            if (item.submenu != null) {
                // 子菜单箭头 ›
                const ax = rx + rw - 20;
                const ay = iy + self.item_height / 2.0 - 4;
                ctx.renderer.fillRoundedRect(.{ .x = ax, .y = ay, .width = 2, .height = 8 }, 1, label_color) catch {};
                ctx.renderer.fillRoundedRect(.{ .x = ax + 2, .y = ay + 2, .width = 2, .height = 4 }, 1, label_color) catch {};
                ctx.renderer.fillRoundedRect(.{ .x = ax + 4, .y = ay + 3, .width = 2, .height = 2 }, 1, label_color) catch {};
            } else if (item.shortcut.len > 0) {
                // 快捷键右对齐 (估算宽度)
                const sc_w: f32 = @floatFromInt(item.shortcut.len);
                self.drawLabel(ctx, item.shortcut, rx + rw - self.padding_h - sc_w * self.font_size * 0.6, iy + (self.item_height - self.font_size * 1.2) / 2.0, self.shortcut_color);
            }
        }

        // 绘制展开的子菜单 (在本菜单右侧)
        if (self.submenu_open) |idx| {
            if (idx < self.items.items.len) {
                if (self.items.items[idx].submenu) |sub| {
                    if (sub.open) {
                        // 子菜单定位: 右侧偏移
                        sub.base.rect.x = w.rect.x + rw - 4;
                        sub.base.rect.y = w.rect.y + self.itemY(idx);
                        var sub_ctx = ctx.*;
                        sub.paintTree(&sub_ctx);
                    }
                }
            }
        }
    }

    fn drawLabel(self: *Menu, ctx: *PaintContext, text: []const u8, x: f32, y: f32, color: math.Color) void {
        if (text.len == 0) return;
        var font = coretext.CtFont.create(null, self.font_size, 400) catch return;
        defer font.destroy();

        var tl = text_layout.TextLayout.layout(
            ctx.allocator,
            &ctx.renderer.glyph_atlas.?,
            ctx.renderer.device,
            text,
            .{ .font = &font, .font_size = self.font_size },
        ) catch return;
        defer tl.deinit();

        ctx.renderer.drawText(&tl, x, y, color) catch {};
    }

    fn onEvent(w: *Widget, event: *const pal.Event, ectx: *EventContext) EventResult {
        const self: *Menu = @fieldParentPtr("base", w);
        _ = ectx;

        if (!self.open) return .ignored;

        switch (event.*) {
            .mouse_move => |mm| {
                const mx: f32 = @floatFromInt(mm.x);
                const my: f32 = @floatFromInt(mm.y);
                const rw = @max(w.rect.width, self.min_width);

                if (mx >= 0 and mx < rw and my >= 0 and my < self.panelHeight()) {
                    const new_hover = self.indexAtY(my);
                    if (new_hover != self.hovered) {
                        self.hovered = new_hover;
                        // hover 到有子菜单的项时展开
                        self.updateSubmenuOpen(new_hover);
                        self.base.markDirty();
                    }
                    return .handled;
                } else {
                    if (self.hovered != null) {
                        self.hovered = null;
                        self.base.markDirty();
                    }
                }
            },
            .mouse_button => |mb| {
                if (mb.button != .left or mb.state != .pressed) return .ignored;
                const my: f32 = @floatFromInt(mb.y);
                const mx: f32 = @floatFromInt(mb.x);
                const rw = @max(w.rect.width, self.min_width);

                if (mx >= 0 and mx < rw and my >= 0 and my < self.panelHeight()) {
                    if (self.indexAtY(my)) |idx| {
                        self.activateItem(idx);
                        return .handled;
                    }
                }
                // 点击外部关闭
                self.closeMenu();
                return .handled;
            },
            .key => |k| {
                if (k.state != .pressed) return .ignored;
                switch (k.key) {
                    .down => {
                        self.moveHover(1);
                        return .handled;
                    },
                    .up => {
                        self.moveHover(-1);
                        return .handled;
                    },
                    .enter, .space => {
                        if (self.hovered) |idx| {
                            self.activateItem(idx);
                        }
                        return .handled;
                    },
                    .right => {
                        // 展开子菜单
                        if (self.hovered) |idx| {
                            if (idx < self.items.items.len and self.items.items[idx].submenu != null) {
                                self.updateSubmenuOpen(idx);
                                self.base.markDirty();
                            }
                        }
                        return .handled;
                    },
                    .escape => {
                        self.closeMenu();
                        return .handled;
                    },
                    else => {},
                }
            },
            else => {},
        }
        return .ignored;
    }

    // ── 内部操作 ────────────────────────────────────────────────────────────

    fn moveHover(self: *Menu, delta: i32) void {
        const n = self.items.items.len;
        if (n == 0) return;

        var idx: isize = if (self.hovered) |h| @intCast(h) else if (delta > 0) -1 else @as(isize, @intCast(n));

        // 跳到下一个非分隔线项
        var steps: usize = 0;
        while (steps < n) : (steps += 1) {
            idx += delta;
            if (idx < 0) idx = @as(isize, @intCast(n)) - 1;
            if (idx >= @as(isize, @intCast(n))) idx = 0;
            const uidx: usize = @intCast(idx);
            if (!self.items.items[uidx].is_separator and !self.items.items[uidx].disabled) {
                self.hovered = uidx;
                self.base.markDirty();
                return;
            }
        }
    }

    fn updateSubmenuOpen(self: *Menu, hover: ?usize) void {
        // 关闭之前的子菜单
        if (self.submenu_open) |prev| {
            if (hover == null or prev != hover.?) {
                if (prev < self.items.items.len) {
                    if (self.items.items[prev].submenu) |sub| sub.closeMenu();
                }
                self.submenu_open = null;
            }
        }
        // 展开新的
        if (hover) |idx| {
            if (idx < self.items.items.len) {
                if (self.items.items[idx].submenu) |sub| {
                    sub.openMenu();
                    self.submenu_open = idx;
                }
            }
        }
    }

    fn activateItem(self: *Menu, idx: usize) void {
        if (idx >= self.items.items.len) return;
        const item = &self.items.items[idx];
        if (item.disabled or item.is_separator) return;

        if (item.submenu) |sub| {
            // 有子菜单: 展开而非触发
            self.updateSubmenuOpen(idx);
            _ = sub;
            self.base.markDirty();
            return;
        }

        if (item.on_click) |cb| {
            cb(item.ctx);
        }
        self.closeMenu();
    }
};
