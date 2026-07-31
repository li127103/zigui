//! GridView 控件 - GTK4 网格视图
//!
//! GTK4 对应: GtkGridView
//!   - 支持 ListModel + SelectionModel + ListItemFactory (GTK4 模型层方式)
//!   - 也兼容旧的 items 直接 API
//!
//! 相比 IconView 提供:
//! - 自定义 item 大小 + 自动列数
//! - 自定义渲染器 (每个 item 可绘制任意内容)
//! - 单选 / 多选 / 无选择模式
//! - 虚拟化滚动
//! - 更现代的选中样式

const std = @import("std");
const perf = @import("../perf.zig");
const math = @import("../math.zig");
const widget_mod = @import("widget.zig");
const layout_mod = @import("../layout/engine.zig");
const pal = @import("../pal/pal.zig");
const styled_text = @import("../text/styled_text.zig");
const icons_mod = @import("icons.zig");
const list_mod = @import("../model/list_model.zig");
const sel_mod = @import("../model/selection_model.zig");
const fact_mod = @import("../model/list_item_factory.zig");

const Widget = widget_mod.Widget;
const PaintContext = widget_mod.PaintContext;
const EventContext = widget_mod.EventContext;
const EventResult = widget_mod.EventResult;
const Allocator = std.mem.Allocator;
const Event = pal.event_mod.Event;

const ListModel = list_mod.ListModel;
const SelectionModel = sel_mod.SelectionModel;
const ListItemFactory = fact_mod.ListItemFactory;
const ListItem = fact_mod.ListItem;

pub const GridSelectionMode = enum { none, single, multiple };

pub const GridItem = struct {
    title: []const u8,
    subtitle: []const u8 = "",
    icon: []const u8 = "",
    icon_name: ?icons_mod.IconName = null,
    userdata: ?*anyopaque = null,
};

pub const GridView = struct {
    base: Widget,
    allocator: Allocator,

    /// ── 旧 API：items (GridItem 数组) ──
    items: std.ArrayListUnmanaged(GridItem) = .{},
    items_dup: std.ArrayListUnmanaged([2][]const u8) = .{}, // title_dup, subtitle_dup

    /// ── GTK4 模型层 API ──
    model: ?ListModel = null,
    selection_model: ?*SelectionModel = null,
    factory: ?ListItemFactory = null,
    _listitem_cache: std.AutoHashMapUnmanaged(usize, ListItem) = .{},

    selection_mode: GridSelectionMode = .single,
    selected_item: ?usize = null,
    hovered_item: ?usize = null,
    multi_selected: std.DynamicBitSetUnmanaged = .{},

    scroll_offset: f32 = 0,

    item_min_w: f32 = 140,
    item_min_h: f32 = 140,
    item_padding: f32 = 8,
    spacing: f32 = 10,
    padding: f32 = 10,
    radius: f32 = 10,

    show_labels: bool = true,

    on_selected: ?*const fn (self: *GridView, item: ?usize) void = null,
    on_activated: ?*const fn (self: *GridView, item: usize) void = null,

    /// 自定义渲染器: (ctx, rect, item_index, userdata)
    custom_renderer: ?*const fn (ctx: *PaintContext, rect: math.Rect, index: usize, userdata: ?*anyopaque) void = null,
    custom_userdata: ?*anyopaque = null,

    // 样式
    bg_color: math.Color = math.Color.hex(0x0B1220FF),
    item_bg: math.Color = math.Color.hex(0x1E293BFF),
    item_hover_bg: math.Color = math.Color.hex(0x334155FF),
    item_selected_bg: math.Color = math.Color.hex(0x3B82F644),
    item_selected_border: math.Color = math.Color.hex(0x3B82F6FF),
    title_color: math.Color = math.Color.hex(0xF8FAFCFF),
    subtitle_color: math.Color = math.Color.hex(0x94A3B8FF),
    icon_color: math.Color = math.Color.hex(0x60A5FAFF),
    scrollbar_color: math.Color = math.Color.hex(0x475569FF),

    // 点击历史（双击检测）
    last_click_item: ?usize = null,
    last_click_time: u64 = 0,

    pub fn new(allocator: Allocator, opts: struct {
        item_min_w: f32 = 140,
        item_min_h: f32 = 140,
        selection_mode: GridSelectionMode = .single,
        spacing: f32 = 10,
        padding: f32 = 10,
        radius: f32 = 10,
        show_labels: bool = true,
        on_selected: ?*const fn (self: *GridView, item: ?usize) void = null,
        on_activated: ?*const fn (self: *GridView, item: usize) void = null,
    }) !*GridView {
        const self = try allocator.create(GridView);
        self.* = .{
            .base = .{
                .vtable = &vtable,
                .id = widget_mod.genWidgetId(),
            },
            .allocator = allocator,
            .item_min_w = opts.item_min_w,
            .item_min_h = opts.item_min_h,
            .selection_mode = opts.selection_mode,
            .spacing = opts.spacing,
            .padding = opts.padding,
            .radius = opts.radius,
            .show_labels = opts.show_labels,
            .on_selected = opts.on_selected,
            .on_activated = opts.on_activated,
        };
        self.base.accessibility = .{ .role = .grid, .label = "Grid View" };
        return self;
    }

    pub fn destroy(self: *GridView, allocator: Allocator) void {
        self.base.background.deinit(allocator);
        // 清理旧 items
        for (self.items_dup.items) |d| {
            allocator.free(d[0]);
            if (d[1].len > 0) allocator.free(d[1]);
        }
        self.items_dup.deinit(allocator);
        self.items.deinit(allocator);
        self.multi_selected.deinit(allocator);
        // 清理 listitem cache
        var it = self._listitem_cache.iterator();
        while (it.next()) |entry| {
            var li = entry.value_ptr.*;
            if (self.factory) |f| f.teardown(&li);
        }
        self._listitem_cache.deinit(allocator);
        self.base.children.deinit(allocator);
        allocator.destroy(self);
    }

    // ──────────────────────────────────────────────
    // GTK4 模型层 API
    // ──────────────────────────────────────────────

    pub fn setModel(self: *GridView, m: ?ListModel) void {
        self.model = m;
        self._clearListItemCache();
        self.base.markLayoutDirty();
        self.base.markDirty();
    }

    pub fn setSelectionModel(self: *GridView, sel: ?*SelectionModel) void {
        self.selection_model = sel;
        if (sel) |s| {
            self.model = s.model();
        }
        self._clearListItemCache();
        self.base.markDirty();
    }

    pub fn setFactory(self: *GridView, factory: ?ListItemFactory) void {
        self.factory = factory;
        self._clearListItemCache();
        self.base.markDirty();
    }

    fn _clearListItemCache(self: *GridView) void {
        var it = self._listitem_cache.iterator();
        while (it.next()) |entry| {
            var li = entry.value_ptr.*;
            if (self.factory) |f| f.teardown(&li);
        }
        self._listitem_cache.clearRetainingCapacity();
    }

    fn effectiveCount(self: *const GridView) usize {
        if (self.model) |m| return m.nItems();
        return self.items.items.len;
    }

    fn effectiveIsSelected(self: *GridView, idx: usize) bool {
        if (self.selection_model) |sm| return sm.isSelected(idx);
        if (self.selected_item) |s| return s == idx;
        if (self.selection_mode == .multiple and self.multi_selected.capacity() > idx) {
            return self.multi_selected.isSet(idx);
        }
        return false;
    }

    fn effectiveSelect(self: *GridView, idx: usize) void {
        if (self.selection_model) |sm| {
            _ = sm.selectItem(idx, true);
        } else {
            self.setSelected(idx);
            return;
        }
        self.selected_item = idx;
        self.base.markDirty();
        if (self.on_selected) |cb| cb(self, idx);
    }

    fn _getOrBindListItem(self: *GridView, idx: usize) !ListItem {
        const gop = try self._listitem_cache.getOrPut(self.allocator, idx);
        if (!gop.found_existing) {
            gop.value_ptr.* = .{ .position = idx };
            var li = gop.value_ptr.*;
            if (self.factory) |f| f.setup(&li);
            gop.value_ptr.* = li;
        }
        var li = gop.value_ptr.*;
        li.position = idx;
        if (self.model) |m| {
            li.item = if (m.iface.getItemFn(m.userdata, idx)) |p| p else null;
        }
        li.selected = self.effectiveIsSelected(idx);
        return li;
    }

    pub fn addItem(self: *GridView, item: GridItem) !void {
        const title_dup = try self.allocator.dupe(u8, item.title);
        const sub_dup = if (item.subtitle.len > 0) try self.allocator.dupe(u8, item.subtitle) else &.{};
        try self.items.append(self.allocator, .{
            .title = title_dup,
            .subtitle = sub_dup,
            .icon = item.icon,
            .icon_name = item.icon_name,
            .userdata = item.userdata,
        });
        try self.items_dup.append(self.allocator, [2][]const u8{ title_dup, sub_dup });
        self.base.markDirty();
    }

    pub fn removeAllItems(self: *GridView) void {
        for (self.items_dup.items) |d| {
            self.allocator.free(d[0]);
            if (d[1].len > 0) self.allocator.free(d[1]);
        }
        self.items_dup.clearRetainingCapacity();
        self.items.clearRetainingCapacity();
        self.selected_item = null;
        self.hovered_item = null;
        if (self.multi_selected.capacity() > 0) {
            self.multi_selected.setRangeValue(0, self.multi_selected.capacity(), false);
        }
        self.base.markDirty();
    }

    pub fn count(self: *const GridView) usize {
        return self.effectiveCount();
    }

    pub fn setSelected(self: *GridView, idx: ?usize) void {
        if (self.selection_mode == .none) return;
        const total = self.effectiveCount();
        if (idx) |i| {
            if (i >= total) return;
        }
        // 同步 selection_model
        if (self.selection_model) |sm| {
            if (idx) |i| {
                _ = sm.selectItem(i, true);
            } else {
                _ = sm.unselectAll();
            }
        }
        self.selected_item = idx;
        self.base.markDirty();
        if (self.on_selected) |cb| cb(self, idx);
    }

    pub fn getSelected(self: *const GridView) ?usize {
        if (self.selection_model) |sm| {
            const total = self.effectiveCount();
            var i: usize = 0;
            while (i < total) : (i += 1) {
                if (sm.isSelected(i)) return i;
            }
            return null;
        }
        return self.selected_item;
    }

    /// 计算布局: 列数、每行 item 大小
    fn layout(self: *const GridView, view_w: f32) struct { cols: usize, item_w: f32, item_h: f32, col_gap: f32 } {
        const avail = view_w - self.padding * 2;
        var cols: usize = 1;
        if (self.item_min_w > 0) {
            cols = @max(1, @as(usize, @intFromFloat(@floor((avail + self.spacing) / (self.item_min_w + self.spacing)))));
        }
        const col_gap: f32 = self.spacing;
        const total_gaps = @as(f32, @floatFromInt(cols - 1)) * col_gap;
        const item_w = @max(self.item_min_w, (avail - total_gaps) / @as(f32, @floatFromInt(cols)));
        return .{
            .cols = cols,
            .item_w = item_w,
            .item_h = self.item_min_h,
            .col_gap = col_gap,
        };
    }

    fn itemIndexAt(self: *GridView, view_w: f32, view_h: f32, local_x: f32, local_y: f32) ?usize {
        const L = self.layout(view_w);
        const content_top = self.padding;
        const scroll_offset = self.scroll_offset;
        const rel_y = local_y - content_top + scroll_offset;
        if (rel_y < 0) return null;
        const col = @as(usize, @intFromFloat(@floor((local_x - self.padding) / (L.item_w + L.col_gap))));
        const row_f = @floor(rel_y / (L.item_h + self.spacing));
        if (row_f < 0) return null;
        const row: usize = @intFromFloat(row_f);
        if (col >= L.cols) return null;
        const idx = row * L.cols + col;
        if (idx >= self.effectiveCount()) return null;

        // 精确命中检测（忽略 item 之间的 gap）
        const real_x = self.padding + @as(f32, @floatFromInt(col)) * (L.item_w + L.col_gap);
        const real_y = content_top + @as(f32, @floatFromInt(row)) * (L.item_h + self.spacing) - scroll_offset;
        if (local_x < real_x or local_x > real_x + L.item_w) return null;
        if (local_y < real_y or local_y > real_y + L.item_h) return null;
        _ = view_h;
        return idx;
    }

    fn totalContentHeight(self: *GridView, view_w: f32) f32 {
        const L = self.layout(view_w);
        const n = self.effectiveCount();
        if (n == 0) return self.padding * 2;
        const cols = L.cols;
        const rows = (n + cols - 1) / cols;
        return self.padding * 2 + @as(f32, @floatFromInt(rows)) * (L.item_h + self.spacing) - self.spacing;
    }

    fn clampScroll(self: *GridView, view_w: f32, view_h: f32) void {
        const content = self.totalContentHeight(view_w);
        const max_scroll = @max(0, content - view_h);
        self.scroll_offset = @max(0, @min(self.scroll_offset, max_scroll));
    }
};

const vtable = Widget.VTable{
    .type_name = "grid_view",
    .measure = measure,
    .paint = paint,
    .on_event = onEvent,
    .focusable = true,
    .destroy = destroyVTable,
};

fn destroyVTable(w: *Widget, allocator: Allocator) void {
    const self: *GridView = @fieldParentPtr("base", w);
    self.destroy(allocator);
}

fn measure(w: *Widget, ctx: *PaintContext, constraints: layout_mod.Constraints) math.Size {
    const self: *GridView = @fieldParentPtr("base", w);
    const max_w = if (constraints.max_width < std.math.inf(f32)) constraints.max_width else 600;
    const max_h = if (constraints.max_height < std.math.inf(f32)) constraints.max_height else 500;
    _ = ctx;
    return .{
        .width = @max(200, @min(max_w, 600)),
        .height = @max(self.item_min_h + self.padding * 2, @min(max_h, 400)),
    };
}

fn paint(w: *Widget, ctx: *PaintContext) void {
    const self: *GridView = @fieldParentPtr("base", w);
    const rx = ctx.offset_x + w.rect.x;
    const ry = ctx.offset_y + w.rect.y;
    const rw = w.rect.width;
    const rh = w.rect.height;
    const R = ctx.renderer;
    const alloc = ctx.allocator;

    // 背景
    R.fillRoundedRect(.{ .x = rx, .y = ry, .width = rw, .height = rh }, self.radius, self.bg_color) catch {};

    const saved = R.getClipRect();
    R.setClipRect(.{ .x = rx, .y = ry, .width = rw, .height = rh }) catch {};

    self.clampScroll(rw, rh);
    const L = self.layout(rw);
    const n = self.effectiveCount();
    const rows = if (n == 0) 0 else (n + L.cols - 1) / L.cols;

    // 只绘制可见 rows
    const row_h = L.item_h + self.spacing;
    const start_row_f = self.scroll_offset / row_h;
    const start_row_64: u64 = @intFromFloat(@floor(start_row_f));
    const start_row: usize = @truncate(start_row_64);
    const vis_rows_f = @ceil(rh / row_h);
    const vis_rows_64: u64 = @intFromFloat(vis_rows_f);
    const vrows_usize: usize = @truncate(vis_rows_64);
    const end_row_calc = start_row + vrows_usize + 1;
    const end_row: usize = @min(rows, end_row_calc);

    for (start_row..end_row) |row| {
        for (0..L.cols) |col| {
            const idx = row * L.cols + col;
            if (idx >= n) continue;
            const x = rx + self.padding + @as(f32, @floatFromInt(col)) * (L.item_w + L.col_gap);
            const y_base = ry + self.padding + @as(f32, @floatFromInt(row)) * (L.item_h + self.spacing);
            const y = y_base - self.scroll_offset;
            const rect = math.Rect{ .x = x, .y = y, .width = L.item_w, .height = L.item_h };

            const is_hover = if (self.hovered_item) |h| h == idx else false;
            const any_sel = self.effectiveIsSelected(idx);
            const is_multi_sel = self.selection_mode == .multiple and
                self.multi_selected.capacity() > idx and self.multi_selected.isSet(idx);
            _ = is_multi_sel;

            // 先 bind factory (会更新 list_item.selected / list_item.item)
            if (self.factory) |factory| {
                var li = self._getOrBindListItem(idx) catch continue;
                factory.bind(&li);
            }

            // item 背景
            if (any_sel) {
                R.fillRoundedRect(rect, self.radius, self.item_selected_bg) catch {};
                R.strokeRoundedRect(rect, self.radius, 2, self.item_selected_border) catch {};
            } else if (is_hover) {
                R.fillRoundedRect(rect, self.radius, self.item_hover_bg) catch {};
            } else {
                R.fillRoundedRect(rect, self.radius, self.item_bg) catch {};
            }

            if (self.custom_renderer) |renderer| {
                const inner_rect = math.Rect{
                    .x = rect.x + self.item_padding,
                    .y = rect.y + self.item_padding,
                    .width = rect.width - self.item_padding * 2,
                    .height = rect.height - self.item_padding * 2,
                };
                renderer(ctx, inner_rect, idx, self.custom_userdata);
            } else if (self.model != null) {
                // model 模式的默认渲染: 把 item 当字符串显示 (title)，带文件夹图标
                const m = self.model orelse unreachable;
                const raw = m.iface.getItemFn(m.userdata, idx);
                const title = if (raw) |p| blk: {
                    const as_bytes: *[]const u8 = @ptrCast(@alignCast(p));
                    break :blk as_bytes.*;
                } else "";
                const inner_pad: f32 = 12;
                const avail_w = rect.width - inner_pad * 2;
                const avail_h = rect.height - inner_pad * 2;
                const title_h: f32 = 18;
                const icon_h = @max(32, avail_h - title_h - 10);
                const icon_size = @min(avail_w, icon_h);
                const icon_x = rect.x + (rect.width - icon_size) / 2;
                const icon_y = rect.y + inner_pad;
                icons_mod.drawIcon(alloc, R, icons_mod.IconName.folder, .{
                    .x = icon_x,
                    .y = icon_y,
                    .size = icon_size,
                    .color = self.icon_color,
                }) catch {};
                if (self.show_labels) {
                    const tc: math.Color = if (any_sel) math.Color.hex(0xFFFFFFFF) else self.title_color;
                    styled_text.drawText(ctx, title, .{
                        .x = rect.x + inner_pad,
                        .y = icon_y + icon_size + 6,
                        .color = tc,
                        .font_size = 13,
                        .max_width = avail_w,
                        .alignment = .center,
                    });
                }
            } else {
                // 默认渲染: 图标 + 标题 + 副标题 (旧 items API)
                const item = self.items.items[idx];
                const inner_pad: f32 = 12;
                const avail_w = rect.width - inner_pad * 2;
                const avail_h = rect.height - inner_pad * 2;

                // 图标区
                var icon_h: f32 = avail_h;
                var title_h: f32 = 0;
                var sub_h: f32 = 0;
                if (self.show_labels) {
                    title_h = 18;
                    sub_h = if (item.subtitle.len > 0) 16 else 0;
                    icon_h = avail_h - title_h - sub_h - (if (item.subtitle.len > 0) 12 else 6);
                }
                icon_h = @max(32, icon_h);

                const icon_size = @min(avail_w, icon_h);
                const icon_x = rect.x + (rect.width - icon_size) / 2;
                const icon_y = rect.y + inner_pad;

                if (item.icon_name) |iname| {
                    icons_mod.drawIcon(alloc, R, iname, .{
                        .x = icon_x,
                        .y = icon_y,
                        .size = icon_size,
                        .color = self.icon_color,
                    }) catch {};
                } else if (item.icon.len > 0) {
                    // emoji/text 图标
                    const icon_font = icon_size * 0.6;
                    const ts = styled_text.measureText(alloc, item.icon, .{ .font_size = icon_font });
                    styled_text.drawText(ctx, item.icon, .{
                        .x = rect.x + (rect.width - ts.width) / 2,
                        .y = icon_y + (icon_size - ts.height) / 2,
                        .font_size = icon_font,
                        .color = self.icon_color,
                    });
                } else {
                    // 默认图标
                    icons_mod.drawIcon(alloc, R, icons_mod.IconName.folder, .{
                        .x = icon_x,
                        .y = icon_y,
                        .size = icon_size,
                        .color = self.icon_color,
                    }) catch {};
                }

                if (self.show_labels) {
                    const label_y = icon_y + icon_size + 6;
                    // 标题
                    const tc: math.Color = if (any_sel) math.Color.hex(0xFFFFFFFF) else self.title_color;
                    styled_text.drawText(ctx, item.title, .{
                        .x = rect.x + inner_pad,
                        .y = label_y,
                        .color = tc,
                        .font_size = 13,
                        .max_width = avail_w,
                        .alignment = .center,
                    });
                    // 副标题
                    if (item.subtitle.len > 0) {
                        const sub_y = label_y + title_h + 4;
                        const sc: math.Color = if (any_sel) math.Color.hex(0xE2E8F0FF) else self.subtitle_color;
                        styled_text.drawText(ctx, item.subtitle, .{
                            .x = rect.x + inner_pad,
                            .y = sub_y,
                            .color = sc,
                            .font_size = 11,
                            .max_width = avail_w,
                            .alignment = .center,
                        });
                    }
                }
            }
        }
    }

    // 滚动条
    const content_h = self.totalContentHeight(rw);
    if (content_h > rh) {
        const bar_w: f32 = 6;
        const bar_h = @max(30, rh * (rh / content_h));
        const max_scroll = content_h - rh;
        const bar_y = ry + (self.scroll_offset / max_scroll) * (rh - bar_h);
        R.fillRoundedRect(.{
            .x = rx + rw - bar_w - 2,
            .y = bar_y,
            .width = bar_w,
            .height = bar_h,
        }, 3, self.scrollbar_color) catch {};
    }

    if (saved) |s| R.setClipRect(s) catch {};
    R.strokeRoundedRect(.{ .x = rx, .y = ry, .width = rw, .height = rh }, self.radius, 1, math.Color.hex(0x1E293BFF)) catch {};
}

fn onEvent(w: *Widget, event: *const Event, ectx: *EventContext) EventResult {
    const self: *GridView = @fieldParentPtr("base", w);
    const abs_rect = w.absoluteRect();

    switch (event.*) {
        .scroll => |s| {
            if (s.axis == .vertical) {
                self.scroll_offset -= s.delta * self.item_min_h * 0.6;
                self.clampScroll(abs_rect.width, abs_rect.height);
                self.base.markDirty();
                return .handled;
            }
        },
        .mouse_move => |m| {
            const mx: f32 = @floatFromInt(m.x);
            const my: f32 = @floatFromInt(m.y);
            const rel_x = mx - abs_rect.x;
            const rel_y = my - abs_rect.y;
            if (rel_x >= 0 and rel_x < abs_rect.width and rel_y >= 0 and rel_y < abs_rect.height) {
                const idx = self.itemIndexAt(abs_rect.width, abs_rect.height, rel_x, rel_y);
                if (idx != self.hovered_item) {
                    self.hovered_item = idx;
                    w.markDirty();
                }
                return .handled;
            }
            if (self.hovered_item != null) {
                self.hovered_item = null;
                w.markDirty();
            }
        },
        .mouse_button => |mb| {
            if (mb.button == .left) {
                const mx: f32 = @floatFromInt(mb.x);
                const my: f32 = @floatFromInt(mb.y);
                const rel_x = mx - abs_rect.x;
                const rel_y = my - abs_rect.y;
                if (rel_x < 0 or rel_x >= abs_rect.width or rel_y < 0 or rel_y >= abs_rect.height) return .ignored;
                if (mb.state == .pressed) {
                    const idx = self.itemIndexAt(abs_rect.width, abs_rect.height, rel_x, rel_y) orelse return .handled;
                    const now_ts = @as(i64, @intCast(perf.nowMs()));
                    const now_u: u64 = @intCast(if (now_ts < 0) 0 else now_ts);
                    // 双击
                    if (self.last_click_item) |li| {
                        if (li == idx and now_u - self.last_click_time < 350) {
                            self.last_click_item = null;
                            self.last_click_time = 0;
                            if (self.on_activated) |cb| cb(self, idx);
                            return .handled;
                        }
                    }
                    self.last_click_item = idx;
                    self.last_click_time = now_u;
                    self.effectiveSelect(idx);
                    return .handled;
                }
            }
        },
        .key => |k| {
            if (k.state == .pressed) {
                const L = self.layout(abs_rect.width);
                const n = self.effectiveCount();
                const cur = self.getSelected() orelse 0;
                if (k.key == .left and cur % L.cols > 0) {
                    self.setSelected(cur - 1);
                    return .handled;
                }
                if (k.key == .right and cur % L.cols + 1 < L.cols and cur + 1 < n) {
                    self.setSelected(cur + 1);
                    return .handled;
                }
                if (k.key == .up and cur >= L.cols) {
                    self.setSelected(cur - L.cols);
                    return .handled;
                }
                if (k.key == .down and cur + L.cols < n) {
                    self.setSelected(cur + L.cols);
                    return .handled;
                }
                if (k.key == .home and n > 0) {
                    self.setSelected(0);
                    return .handled;
                }
                if (k.key == .end and n > 0) {
                    self.setSelected(n - 1);
                    return .handled;
                }
                if ((k.key == .space or k.key == .enter or k.key == .kp_enter)) {
                    if (self.getSelected()) |s| {
                        if (self.on_activated) |cb| cb(self, s);
                    }
                    return .handled;
                }
                _ = ectx;
            }
        },
        else => {},
    }
    return .ignored;
}
