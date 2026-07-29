//! ListView 控件 - 虚拟化列表（兼容旧 items API + 新 GTK4 模型层）
//!
//! GTK4 对应: GtkListView
//!   - 旧 API: `addItem(str)` / `clearItems()` (直接字符串数组)
//!   - 新 API: `setModel(m)` + `setSelectionModel(sel)` + `setFactory(factory)` (模型层)

const std = @import("std");
const math = @import("../math.zig");
const widget_mod = @import("widget.zig");
const layout_mod = @import("../layout/engine.zig");
const pal = @import("../pal/pal.zig");
const styled_text = @import("../text/styled_text.zig");
const list_mod = @import("../model/list_model.zig");
const sel_mod = @import("../model/selection_model.zig");
const fact_mod = @import("../model/list_item_factory.zig");

const Widget = widget_mod.Widget;
const PaintContext = widget_mod.PaintContext;
const EventContext = widget_mod.EventContext;
const EventResult = widget_mod.EventResult;

const ListModel = list_mod.ListModel;
const SelectionModel = sel_mod.SelectionModel;
const ListItemFactory = fact_mod.ListItemFactory;
const ListItem = fact_mod.ListItem;

pub const ListView = struct {
    base: Widget,
    allocator: std.mem.Allocator,

    /// ── 旧 API：字符串数组 ──
    items: std.ArrayListUnmanaged([]const u8),

    /// ── GTK4 模型层 API ──
    /// ListModel (设置后优先使用 model 取数据)
    model: ?ListModel = null,
    /// SelectionModel (设置后选中状态由它管理)
    selection_model: ?*SelectionModel = null,
    /// ListItemFactory (若存在则调用 setup/bind)
    factory: ?ListItemFactory = null,
    /// ListItem 缓存: row_idx -> ListItem
    _listitem_cache: std.AutoHashMapUnmanaged(usize, ListItem) = .{},

    selected: ?usize = null,
    hovered: ?usize = null,
    scroll_offset: f32 = 0,
    item_height: f32,
    font_size: f32,
    on_select: ?*const fn (self: *ListView, index: usize) void,
    // 样式
    bg_color: math.Color = math.Color.hex(0x0F172AFF),
    item_bg: math.Color = math.Color.hex(0x1E293BFF),
    item_hover_bg: math.Color = math.Color.hex(0x334155FF),
    item_selected_bg: math.Color = math.Color.hex(0x3B82F633),
    text_color: math.Color = math.Color.hex(0xF8FAFCFF),
    text_secondary: math.Color = math.Color.hex(0x94A3B8FF),
    scrollbar_color: math.Color = math.Color.hex(0x475569FF),
    corner_radius: f32 = 10.0,
    padding: f32 = 4.0,

    pub fn create(allocator: std.mem.Allocator, opts: struct {
        item_height: f32 = 40.0,
        font_size: f32 = 14.0,
        on_select: ?*const fn (self: *ListView, index: usize) void = null,
    }) !*ListView {
        const self = try allocator.create(ListView);
        self.* = .{
            .base = .{
                .vtable = &vtable,
                .id = widget_mod.genWidgetId(),
            },
            .allocator = allocator,
            .items = .{ .items = &.{}, .capacity = 0 },
            .item_height = opts.item_height,
            .font_size = opts.font_size,
            .on_select = opts.on_select,
        };
        return self;
    }

    pub fn destroy(self: *ListView, allocator: std.mem.Allocator) void {
        self.base.background.deinit(allocator);
        self.items.deinit(allocator);
        // 清理 listitem cache (teardown)
        var cache_it = self._listitem_cache.iterator();
        while (cache_it.next()) |entry| {
            var li = entry.value_ptr.*;
            if (self.factory) |f| f.teardown(&li);
        }
        self._listitem_cache.deinit(allocator);
        self.base.children.deinit(allocator);
        allocator.destroy(self);
    }

    pub fn addItem(self: *ListView, item: []const u8) !void {
        try self.items.append(self.allocator, item);
        self.base.markDirty();
    }

    pub fn clearItems(self: *ListView) void {
        self.items.clearRetainingCapacity();
        self.selected = null;
        self.hovered = null;
        self.scroll_offset = 0;
        self._clearListItemCache();
        self.base.markDirty();
    }

    // ──────────────────────────────────────────────
    // GTK4 模型层 API (setModel / setSelectionModel / setFactory)
    // ──────────────────────────────────────────────

    /// 设置 ListModel (GtkListView: set_model)
    pub fn setModel(self: *ListView, m: ?ListModel) void {
        self.model = m;
        self._clearListItemCache();
        self.base.markLayoutDirty();
        self.base.markDirty();
    }

    /// 设置 SelectionModel (GtkListView: set_model)
    pub fn setSelectionModel(self: *ListView, sel: ?*SelectionModel) void {
        self.selection_model = sel;
        if (sel) |s| {
            // 自动同步 model
            self.model = s.model();
        }
        self._clearListItemCache();
        self.base.markDirty();
    }

    /// 设置 ListItemFactory (GtkListView: set_factory)
    pub fn setFactory(self: *ListView, factory: ?ListItemFactory) void {
        // teardown 旧的
        if (self.factory) |old_f| {
            var it = self._listitem_cache.iterator();
            while (it.next()) |entry| {
                var li = entry.value_ptr.*;
                old_f.teardown(&li);
            }
        }
        self.factory = factory;
        self._clearListItemCache();
        self.base.markDirty();
    }

    /// 有效行数 (有 model 取 model，否则取旧 items)
    pub fn effectiveRowCount(self: *const ListView) usize {
        if (self.model) |m| return m.nItems();
        return self.items.items.len;
    }

    /// 判断第 pos 行是否选中 (兼容 selection_model)
    pub fn effectiveIsSelected(self: *const ListView, pos: usize) bool {
        if (self.selection_model) |sm| return sm.isSelected(pos);
        if (self.selected) |s| return s == pos;
        return false;
    }

    /// 设置第 pos 行选中 (兼容 selection_model，自动 exclusive 模式)
    pub fn effectiveSelect(self: *ListView, pos: ?usize) void {
        if (self.selection_model) |sm| {
            if (pos) |p| {
                _ = sm.selectItem(p, true);
            } else {
                // 取消所有选中: 逐行 unselect (简化)
                for (0..self.effectiveRowCount()) |i| {
                    _ = sm.unselectItem(i);
                }
            }
        } else {
            self.selected = pos;
        }
    }

    // ── 内部: ListItem cache ──────────────────────────────────────────────

    fn _clearListItemCache(self: *ListView) void {
        var it = self._listitem_cache.iterator();
        while (it.next()) |entry| {
            var li = entry.value_ptr.*;
            if (self.factory) |f| f.teardown(&li);
        }
        self._listitem_cache.clearRetainingCapacity();
    }

    fn _getOrBindListItem(self: *ListView, row_idx: usize) !?ListItem {
        const factory = self.factory orelse return null;
        const gop = try self._listitem_cache.getOrPut(self.allocator, row_idx);
        if (!gop.found_existing) {
            gop.value_ptr.* = .{ .position = row_idx };
            var li = gop.value_ptr.*;
            factory.setup(&li);
            gop.value_ptr.* = li;
        }
        var li = gop.value_ptr.*;
        li.position = row_idx;
        if (self.model) |m| {
            li.item = if (m.iface.getItemFn(m.userdata, row_idx)) |p| p else null;
        }
        li.selected = self.effectiveIsSelected(row_idx);
        // bind (即使没变化也 bind，factory 自己决定)
        factory.bind(&li);
        // 保存回 cache (因为 bind 可能修改 userdata 等字段)
        gop.value_ptr.* = li;
        return li;
    }

    fn totalHeight(self: *const ListView) f32 {
        return @as(f32, @floatFromInt(self.effectiveRowCount())) * (self.item_height + self.padding);
    }

    fn maxScroll(self: *const ListView) f32 {
        const total = self.totalHeight();
        const visible = self.base.rect.height;
        return @max(0, total - visible);
    }

    fn visibleRange(self: *const ListView) struct { start: usize, end: usize } {
        const start: usize = @intFromFloat(@max(0, @floor(self.scroll_offset / (self.item_height + self.padding))));
        const visible_count: usize = @as(usize, @intFromFloat(@ceil(self.base.rect.height / (self.item_height + self.padding)))) + 1;
        const n = self.effectiveRowCount();
        const end = @min(n, start + visible_count);
        return .{ .start = start, .end = end };
    }

    // ── VTable ──────────────────────────────────────────────────────────────

    const vtable = Widget.VTable{
        .type_name = "list_view",
        .measure = measure,
        .paint = paint,
        .on_event = onEvent,
        .focusable = true,
        .destroy = destroyVTable,
    };

    fn destroyVTable(w: *Widget, allocator: std.mem.Allocator) void {
        const self: *ListView = @fieldParentPtr("base", w);
        self.destroy(allocator);
    }

    fn measure(w: *Widget, ctx: *PaintContext, constraints: layout_mod.Constraints) math.Size(f32) {
        _ = ctx;
        _ = constraints;
        _ = w;
        return .{ .width = 300, .height = 400 };
    }

    fn paint(w: *Widget, ctx: *PaintContext) void {
        const self: *ListView = @fieldParentPtr("base", w);
        const rx = ctx.offset_x + w.rect.x;
        const ry = ctx.offset_y + w.rect.y;
        const rw = w.rect.width;
        const rh = w.rect.height;

        // 背景
        ctx.renderer.fillRoundedRect(.{ .x = rx, .y = ry, .width = rw, .height = rh }, self.corner_radius, self.bg_color) catch {};

        // 虚拟化渲染: 只绘制可见项
        const range = self.visibleRange();
        var i: usize = range.start;
        while (i < range.end) : (i += 1) {
            const item_y = ry + @as(f32, @floatFromInt(i)) * (self.item_height + self.padding) - self.scroll_offset;

            // 裁剪: 跳过不可见的
            if (item_y + self.item_height < ry or item_y > ry + rh) continue;

            const is_sel = self.effectiveIsSelected(i);
            const is_hover = (self.hovered != null and self.hovered.? == i);

            // 项背景
            if (is_sel) {
                ctx.renderer.fillRoundedRect(
                    .{ .x = rx + self.padding, .y = item_y, .width = rw - self.padding * 2 - 6, .height = self.item_height },
                    6,
                    self.item_selected_bg,
                ) catch {};
            } else if (is_hover) {
                ctx.renderer.fillRoundedRect(
                    .{ .x = rx + self.padding, .y = item_y, .width = rw - self.padding * 2 - 6, .height = self.item_height },
                    6,
                    self.item_hover_bg,
                ) catch {};
            }

            // 文本: factory -> userdata; model -> item; old -> items[i]
            const tc: math.Color = if (is_sel) math.Color.hex(0xFFFFFFFF) else self.text_color;
            var maybe_text: ?[]const u8 = null;

            // 1) factory 模式：bind 后从 ListItem.userdata 拿 (SimpleTextFactory 把 userdata 指向字符串)
            if (self.factory != null) {
                const li = self._getOrBindListItem(i) catch null;
                if (li) |l| {
                    if (l.userdata) |ud| {
                        // SimpleTextFactory 默认把 userdata 当 *[]const u8
                        const p: *[]const u8 = @ptrCast(@alignCast(ud));
                        maybe_text = p.*;
                    }
                }
            }

            // 2) model 模式
            if (maybe_text == null) {
                if (self.model) |m| {
                    const raw = m.iface.getItemFn(m.userdata, i);
                    if (raw) |p| {
                        const as_bytes: *[]const u8 = @ptrCast(@alignCast(p));
                        maybe_text = as_bytes.*;
                    }
                }
            }

            // 3) old API items
            const text: []const u8 = maybe_text orelse if (i < self.items.items.len) self.items.items[i] else "";

            self.drawLabel(ctx, text, rx + self.padding + 12, item_y + (self.item_height - self.font_size * 1.2) / 2.0, tc);
        }

        // 滚动条
        const total = self.totalHeight();
        if (total > rh) {
            const scrollbar_h = @max(20.0, rh * (rh / total));
            const bar_max = self.maxScroll();
            const scrollbar_y = ry + if (bar_max > 0) (self.scroll_offset / bar_max) * (rh - scrollbar_h) else 0;
            ctx.renderer.fillRoundedRect(
                .{ .x = rx + rw - 5, .y = scrollbar_y, .width = 3, .height = scrollbar_h },
                1.5,
                self.scrollbar_color,
            ) catch {};
        }
    }

    fn drawLabel(self: *ListView, ctx: *PaintContext, text: []const u8, x: f32, y: f32, color: math.Color) void {
        styled_text.drawText(
            ctx.renderer,
            ctx.allocator,
            text,
            x,
            y,
            .{ .font_size = self.font_size, .color = color },
        );
    }

    fn onEvent(w: *Widget, event: *const pal.Event, ectx: *EventContext) EventResult {
        const self: *ListView = @fieldParentPtr("base", w);
        _ = ectx;

        switch (event.*) {
            .scroll => |sc| {
                const delta = sc.delta * 30.0;
                self.scroll_offset = std.math.clamp(self.scroll_offset - delta, 0, self.maxScroll());
                self.base.markDirty();
                return .handled;
            },
            .mouse_move => |mm| {
                const my: f32 = @floatFromInt(mm.y);
                const idx = self.itemAtY(my);
                if (idx != self.hovered) {
                    self.hovered = idx;
                    self.base.markDirty();
                }
            },
            .mouse_button => |mb| {
                if (mb.button == .left and mb.state == .pressed) {
                    const my: f32 = @floatFromInt(mb.y);
                    if (self.itemAtY(my)) |idx| {
                        self.effectiveSelect(idx);
                        self.base.markDirty();
                        if (self.on_select) |cb| cb(self, idx);
                        return .handled;
                    }
                }
            },
            .key => |k| {
                if (k.state != .pressed or !w.state.focused) return .ignored;
                switch (k.key) {
                    .up => {
                        const n = self.effectiveRowCount();
                        const cur: usize = if (self.selection_model) |sm|
                            sm.getFirstSelected() orelse std.math.maxInt(usize)
                        else
                            self.selected orelse std.math.maxInt(usize);
                        if (cur != std.math.maxInt(usize) and cur > 0) {
                            self.effectiveSelect(cur - 1);
                            self.scrollToVisible(cur - 1);
                            self.base.markDirty();
                        } else if (n > 0) {
                            self.effectiveSelect(0);
                            self.base.markDirty();
                        }
                        return .handled;
                    },
                    .down => {
                        const n = self.effectiveRowCount();
                        const cur: usize = if (self.selection_model) |sm|
                            sm.getFirstSelected() orelse std.math.maxInt(usize)
                        else
                            self.selected orelse std.math.maxInt(usize);
                        if (cur != std.math.maxInt(usize) and cur + 1 < n) {
                            self.effectiveSelect(cur + 1);
                            self.scrollToVisible(cur + 1);
                            self.base.markDirty();
                        } else if (n > 0) {
                            self.effectiveSelect(0);
                            self.base.markDirty();
                        }
                        return .handled;
                    },
                    else => {},
                }
            },
            else => {},
        }
        return .ignored;
    }

    fn itemAtY(self: *const ListView, y: f32) ?usize {
        if (y < 0 or y >= self.base.rect.height) return null;
        const idx: usize = @intFromFloat((y + self.scroll_offset) / (self.item_height + self.padding));
        if (idx < self.effectiveRowCount()) return idx;
        return null;
    }

    fn scrollToVisible(self: *ListView, index: usize) void {
        const item_top = @as(f32, @floatFromInt(index)) * (self.item_height + self.padding);
        const item_bottom = item_top + self.item_height;
        const view_h = self.base.rect.height;

        if (item_top < self.scroll_offset) {
            self.scroll_offset = item_top;
        } else if (item_bottom > self.scroll_offset + view_h) {
            self.scroll_offset = item_bottom - view_h;
        }
        self.scroll_offset = std.math.clamp(self.scroll_offset, 0, self.maxScroll());
    }
};
