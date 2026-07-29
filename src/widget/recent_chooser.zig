//! RecentChooserWidget - GTK4 GtkRecentChooserWidget 风格：显示最近使用文件列表
//!
//! 核心功能：
//! - 绑定到 RecentManager 并显示其中的项
//! - 支持按 MIME 类型 / 分组过滤
//! - 点击项触发 onItemActivated 回调
//! - 支持搜索过滤 (show_private, show_not_found, limit 等)
//! - 支持 selectMultiple / getSelectedUris 多选模式

const std = @import("std");
const math = @import("../math.zig");
const widget_mod = @import("widget.zig");
const layout_mod = @import("../layout/engine.zig");
const pal = @import("../pal/pal.zig");
const styled_text = @import("../text/styled_text.zig");
const recent_manager_mod = @import("../model/recent_manager.zig");

const Widget = widget_mod.Widget;
const PaintContext = widget_mod.PaintContext;
const EventContext = widget_mod.EventContext;
const EventResult = widget_mod.EventResult;
const RecentManager = recent_manager_mod.RecentManager;
const RecentInfo = recent_manager_mod.RecentInfo;

pub const RecentChooserWidget = struct {
    base: Widget,
    allocator: std.mem.Allocator,
    manager: ?*RecentManager = null,
    /// 选中项索引 (单选模式)
    selected_index: ?usize = null,
    /// 多选模式
    select_multiple: bool = false,
    selected_bits: std.DynamicBitSetUnmanaged = .empty,
    /// 是否显示私有项
    show_private: bool = false,
    /// 最多显示项数 (null = 不限制)
    limit: ?usize = null,
    /// MIME 类型过滤 (null = 不过滤, 例如 &.{"image/png", "text/plain"})
    filter_mime_types: ?[]const []const u8 = null,
    /// 分组过滤
    filter_groups: ?[]const []const u8 = null,
    /// 搜索文本 (可选)
    search_text: []const u8 = "",
    /// 滚动偏移
    scroll_offset: f32 = 0,
    item_height: f32 = 32,
    font_size: f32 = 14,
    /// 回调
    on_item_activated: ?*const fn (self: *RecentChooserWidget, uri: []const u8, info: *const RecentInfo) void = null,
    on_selection_changed: ?*const fn (self: *RecentChooserWidget) void = null,

    pub fn create(allocator: std.mem.Allocator, opts: struct {
        manager: ?*RecentManager = null,
        item_height: f32 = 32,
        font_size: f32 = 14,
        select_multiple: bool = false,
        show_private: bool = false,
        limit: ?usize = null,
        on_item_activated: ?*const fn (self: *RecentChooserWidget, uri: []const u8, info: *const RecentInfo) void = null,
        on_selection_changed: ?*const fn (self: *RecentChooserWidget) void = null,
    }) !*RecentChooserWidget {
        const self = try allocator.create(RecentChooserWidget);
        self.* = .{
            .base = .{
                .vtable = &vtable,
                .id = widget_mod.genWidgetId(),
            },
            .allocator = allocator,
            .manager = opts.manager,
            .item_height = opts.item_height,
            .font_size = opts.font_size,
            .select_multiple = opts.select_multiple,
            .show_private = opts.show_private,
            .limit = opts.limit,
            .on_item_activated = opts.on_item_activated,
            .on_selection_changed = opts.on_selection_changed,
        };
        self.base.accessibility = .{ .role = .list_box };
        self.base.cursor = .default;
        return self;
    }

    pub fn destroy(self: *RecentChooserWidget, allocator: std.mem.Allocator) void {
        self.selected_bits.deinit(allocator);
        self.base.background.deinit(allocator);
        self.base.children.deinit(allocator);
        allocator.destroy(self);
    }

    // ── GTK4 兼容 API ─────────────────────────────────────────────────────

    /// GTK4: gtk_recent_chooser_set_recent_manager
    pub fn setRecentManager(self: *RecentChooserWidget, manager: ?*RecentManager) void {
        self.manager = manager;
        self.selected_index = null;
        self.selected_bits = .empty;
        self.base.markDirty();
    }
    pub fn getRecentManager(self: *const RecentChooserWidget) ?*RecentManager {
        return self.manager;
    }

    /// GTK4: gtk_recent_chooser_get_current_uri (单选)
    pub fn getCurrentUri(self: *const RecentChooserWidget) ?[]const u8 {
        const items = self.filteredItems();
        const idx = self.selected_index orelse return null;
        if (idx >= items.len) return null;
        return items[idx].uri;
    }

    /// GTK4: gtk_recent_chooser_get_current_item
    pub fn getCurrentItem(self: *const RecentChooserWidget) ?*const RecentInfo {
        const items = self.filteredItems();
        const idx = self.selected_index orelse return null;
        if (idx >= items.len) return null;
        return items[idx];
    }

    /// GTK4: gtk_recent_chooser_get_uris (多选)
    pub fn getSelectedUris(self: *RecentChooserWidget, out: *std.ArrayListUnmanaged([]const u8)) void {
        const items = self.filteredItems();
        if (self.select_multiple) {
            var it = self.selected_bits.iterator(.{});
            while (it.next()) |bit| {
                if (bit < items.len) out.append(self.allocator, items[bit].uri) catch {};
            }
        } else {
            if (self.selected_index) |idx| {
                if (idx < items.len) out.append(self.allocator, items[idx].uri) catch {};
            }
        }
    }

    /// GTK4: gtk_recent_chooser_select_uri
    pub fn selectUri(self: *RecentChooserWidget, uri: []const u8) bool {
        const items = self.filteredItems();
        for (items, 0..) |it, i| {
            if (std.mem.eql(u8, it.uri, uri)) {
                self.selectIndex(i);
                return true;
            }
        }
        return false;
    }

    /// GTK4: gtk_recent_chooser_unselect_uri
    pub fn unselectUri(self: *RecentChooserWidget, uri: []const u8) void {
        const items = self.filteredItems();
        for (items, 0..) |it, i| {
            if (std.mem.eql(u8, it.uri, uri)) {
                self.unselectIndex(i);
                return;
            }
        }
    }

    /// GTK4: gtk_recent_chooser_select_all
    pub fn selectAll(self: *RecentChooserWidget) !void {
        if (!self.select_multiple) return;
        const items = self.filteredItems();
        try self.selected_bits.resize(self.allocator, items.len, false);
        self.selected_bits.setRangeValue(.{ .start = 0, .end = items.len }, true);
        self.base.markDirty();
        if (self.on_selection_changed) |cb| cb(self);
    }

    /// GTK4: gtk_recent_chooser_unselect_all
    pub fn unselectAll(self: *RecentChooserWidget) void {
        self.selected_index = null;
        self.selected_bits = .empty;
        self.base.markDirty();
        if (self.on_selection_changed) |cb| cb(self);
    }

    /// GTK4: gtk_recent_chooser_set_show_private
    pub fn setShowPrivate(self: *RecentChooserWidget, v: bool) void {
        self.show_private = v;
        self.base.markDirty();
    }
    pub fn getShowPrivate(self: *const RecentChooserWidget) bool {
        return self.show_private;
    }

    /// GTK4: gtk_recent_chooser_set_limit
    pub fn setLimit(self: *RecentChooserWidget, limit: ?usize) void {
        self.limit = limit;
        self.base.markDirty();
    }
    pub fn getLimit(self: *const RecentChooserWidget) ?usize {
        return self.limit;
    }

    /// 设置搜索文本过滤
    pub fn setSearchText(self: *RecentChooserWidget, text: []const u8) void {
        self.search_text = text;
        self.base.markDirty();
    }

    /// 设置 MIME 类型过滤 (切片生命周期由调用者管理)
    pub fn setFilterMimeTypes(self: *RecentChooserWidget, types: ?[]const []const u8) void {
        self.filter_mime_types = types;
        self.base.markDirty();
    }

    // ── 辅助：过滤并返回符合条件的项 ──────────────────────────────────────

    fn filteredItems(self: *const RecentChooserWidget) []const RecentInfo {
        const mgr = self.manager orelse return &.{};
        // 这里无法动态分配，使用 RecentManager 的全量 items 在绘制时过滤
        // 外部调用者请用 iterateFilteredItems
        return mgr.getItems();
    }

    /// 遍历过滤后的项 (callback 方式，避免分配)
    pub fn iterateFilteredItems(self: *const RecentChooserWidget, ctx: anytype, cb: *const fn (ctx2: @TypeOf(ctx), idx: usize, info: *const RecentInfo) bool) void {
        const mgr = self.manager orelse return;
        var idx: usize = 0;
        var count: usize = 0;
        for (mgr.getItems()) |*info| {
            // 私有项过滤
            if (info.is_private and !self.show_private) continue;
            // MIME 类型过滤
            if (self.filter_mime_types) |mimes| {
                const info_mime = info.mime_type orelse continue;
                var matched = false;
                for (mimes) |m| {
                    if (std.mem.eql(u8, m, info_mime)) {
                        matched = true;
                        break;
                    }
                    // "text/*" 通配
                    if (m.len > 1 and m[m.len - 1] == '*' and m[m.len - 2] == '/') {
                        if (info_mime.len >= m.len - 1 and std.mem.eql(u8, m[0 .. m.len - 2], info_mime[0 .. m.len - 2])) {
                            matched = true;
                            break;
                        }
                    }
                }
                if (!matched) continue;
            }
            // 分组过滤
            if (self.filter_groups) |groups| {
                var matched = false;
                for (groups) |g| {
                    for (info.groups.items) |ig| {
                        if (std.mem.eql(u8, g, ig)) {
                            matched = true;
                            break;
                        }
                    }
                    if (matched) break;
                }
                if (!matched) continue;
            }
            // 搜索文本过滤 (display_name 或 uri 包含)
            if (self.search_text.len > 0) {
                const in_display = std.mem.indexOf(u8, &std.ascii.lowerString(std.heap.page_allocator, info.display_name) catch continue, &std.ascii.lowerString(std.heap.page_allocator, self.search_text) catch continue) != null;
                const in_uri = std.mem.indexOf(u8, &std.ascii.lowerString(std.heap.page_allocator, info.uri) catch continue, &std.ascii.lowerString(std.heap.page_allocator, self.search_text) catch continue) != null;
                if (!in_display and !in_uri) continue;
            }
            // Limit
            if (self.limit) |lim| {
                if (count >= lim) break;
            }
            if (!cb(ctx, idx, info)) break;
            idx += 1;
            count += 1;
        }
    }

    fn countFilteredItems(self: *const RecentChooserWidget) usize {
        const Ctx = struct { n: usize = 0 };
        var ctx = Ctx{};
        const Cb = struct {
            fn f(c: *Ctx, _: usize, _: *const RecentInfo) bool {
                c.n += 1;
                return true;
            }
        };
        self.iterateFilteredItems(&ctx, &Cb.f);
        return ctx.n;
    }

    fn nthFilteredItem(self: *const RecentChooserWidget, n: usize) ?*const RecentInfo {
        const Ctx = struct { target: usize, found: ?*const RecentInfo = null };
        var ctx = Ctx{ .target = n };
        const Cb = struct {
            fn f(c: *Ctx, i: usize, info: *const RecentInfo) bool {
                if (i == c.target) {
                    c.found = info;
                    return false;
                }
                return true;
            }
        };
        self.iterateFilteredItems(&ctx, &Cb.f);
        return ctx.found;
    }

    fn selectIndex(self: *RecentChooserWidget, idx: usize) void {
        if (self.select_multiple) {
            if (self.selected_bits.capacity() <= idx) {
                self.selected_bits.resize(self.allocator, idx + 1, false) catch return;
            }
            self.selected_bits.set(idx);
        } else {
            self.selected_index = idx;
        }
        self.base.markDirty();
        if (self.on_selection_changed) |cb| cb(self);
    }

    fn unselectIndex(self: *RecentChooserWidget, idx: usize) void {
        if (self.select_multiple) {
            if (idx < self.selected_bits.capacity()) {
                self.selected_bits.unset(idx);
            }
        } else {
            if (self.selected_index == idx) self.selected_index = null;
        }
        self.base.markDirty();
        if (self.on_selection_changed) |cb| cb(self);
    }

    fn isIndexSelected(self: *const RecentChooserWidget, idx: usize) bool {
        if (self.select_multiple) {
            if (idx < self.selected_bits.capacity()) {
                return self.selected_bits.isSet(idx);
            }
            return false;
        } else {
            return self.selected_index == idx;
        }
    }

    // ── VTable 实现 ──────────────────────────────────────────────────────────

    const vtable = Widget.VTable{
        .type_name = "recent_chooser",
        .measure = measure,
        .paint = paint,
        .on_event = onEvent,
        .focusable = true,
        .destroy = destroyVTable,
    };

    fn destroyVTable(w: *Widget, allocator: std.mem.Allocator) void {
        const self: *RecentChooserWidget = @fieldParentPtr("base", w);
        self.destroy(allocator);
    }

    fn measure(w: *Widget, ctx: *PaintContext, constraints: layout_mod.Constraints) math.Size(f32) {
        _ = ctx;
        const self: *RecentChooserWidget = @fieldParentPtr("base", w);
        const count: f32 = @floatFromInt(@min(self.countFilteredItems(), 10));
        const h = count * self.item_height;
        const ww = constraints.max_width;
        return .{
            .width = if (ww > 100) ww else 300,
            .height = @min(h, constraints.max_height),
        };
    }

    fn paint(w: *Widget, ctx: *PaintContext) void {
        const self: *RecentChooserWidget = @fieldParentPtr("base", w);
        const rx = ctx.offset_x + w.rect.x;
        const ry = ctx.offset_y + w.rect.y;
        const width = w.rect.width;
        const height = w.rect.height;

        // 背景
        ctx.renderer.fillRect(.{ .x = rx, .y = ry, .width = width, .height = height }, math.Color.hex(0x0F172AFF)) catch {};

        const total_count = self.countFilteredItems();
        const vs_f: f32 = @max(0, self.scroll_offset / self.item_height);
        const visible_start: usize = @intFromFloat(vs_f);
        const vc_f: f32 = @ceil(height / self.item_height) + 1;
        const visible_count: usize = @intFromFloat(vc_f);
        const item_w = width - 8;

        var drawn: usize = 0;
        var i = visible_start;
        while (i < total_count and drawn < visible_count) : (i += 1) {
            const info = self.nthFilteredItem(i) orelse break;
            const item_y = ry + @as(f32, @floatFromInt(i)) * self.item_height - self.scroll_offset;
            const item_selected = self.isIndexSelected(i);

            // 选中背景
            if (item_selected) {
                ctx.renderer.fillRect(
                    .{ .x = rx + 4, .y = item_y + 2, .width = item_w - 8, .height = self.item_height - 4 },
                    math.Color.hex(0x3B82F633),
                ) catch {};
            }
            // 悬停高亮 (用 base state 近似)
            if (w.state.hovered) {
                // 简单的 hover 效果省略 (需要精确 hover 行索引)
            }

            // 图标 + 文本 (简化：第一列显示 display_name, 第二列显示小的 uri 截断)
            const text_x = rx + 12;
            const text_y = item_y + (self.item_height - self.font_size) / 2.0 - 2;
            styled_text.drawText(
                ctx.renderer,
                ctx.allocator,
                info.display_name,
                text_x,
                text_y,
                .{
                    .font_size = self.font_size,
                    .color = if (item_selected) math.Color.hex(0xBFDBFEFF) else math.Color.hex(0xF8FAFCFF),
                },
            );
            // 次信息 (modified 时间)
            if (item_w > 280) {
                const time_str = formatTime(info.modified);
                const ts_w = styled_text.measureText(ctx.allocator, &time_str, .{ .font_size = self.font_size * 0.85 }).width;
                styled_text.drawText(
                    ctx.renderer,
                    ctx.allocator,
                    &time_str,
                    rx + width - ts_w - 12,
                    text_y,
                    .{
                        .font_size = self.font_size * 0.85,
                        .color = math.Color.hex(0x64748BFF),
                    },
                );
            }
            drawn += 1;
        }
    }

    fn formatTime(ts: i64) [32]u8 {
        var buf: [32]u8 = [_]u8{' '} ** 32;
        const now = std.time.timestamp();
        const diff = now - ts;
        if (diff < 60) {
            @memcpy(buf[0..6], "刚刚");
            return buf;
        } else if (diff < 3600) {
            const m: u32 = @intCast(@divFloor(diff, 60));
            const s = std.fmt.bufPrint(&buf, "{d}分钟前", .{m}) catch return buf;
            return copyToBuf32(s);
        } else if (diff < 86400) {
            const h: u32 = @intCast(@divFloor(diff, 3600));
            const s = std.fmt.bufPrint(&buf, "{d}小时前", .{h}) catch return buf;
            return copyToBuf32(s);
        } else if (diff < 7 * 86400) {
            const d: u32 = @intCast(@divFloor(diff, 86400));
            const s = std.fmt.bufPrint(&buf, "{d}天前", .{d}) catch return buf;
            return copyToBuf32(s);
        } else {
            // 格式化为 MM-DD
            const epoch = std.time.epoch.EpochSeconds{ .secs = @intCast(ts) };
            const day = epoch.getDayOfEpoch();
            const month = day.month.numeric();
            const d = day.day;
            const s = std.fmt.bufPrint(&buf, "{d:0>2}-{d:0>2}", .{ month, d }) catch return buf;
            return copyToBuf32(s);
        }
    }

    fn copyToBuf32(s: []const u8) [32]u8 {
        var buf: [32]u8 = [_]u8{' '} ** 32;
        @memcpy(buf[0..s.len], s);
        return buf;
    }

    fn onEvent(w: *Widget, event: *const pal.Event, ectx: *EventContext) EventResult {
        const self: *RecentChooserWidget = @fieldParentPtr("base", w);
        if (w.state.disabled) return .ignored;

        switch (event.*) {
            .mouse_button => |mb| {
                if (mb.button == .left) {
                    if (mb.state == .pressed) {
                        const ly: f32 = @floatFromInt(mb.y);
                        const row: usize = @intFromFloat(@floor((ly + self.scroll_offset) / self.item_height));
                        const total = self.countFilteredItems();
                        if (row < total) {
                            // Ctrl 点击切换多选 (如果支持)
                            if (self.select_multiple and mb.modifiers.ctrl) {
                                if (self.isIndexSelected(row)) self.unselectIndex(row) else self.selectIndex(row);
                            } else {
                                self.selectIndex(row);
                            }
                            return .handled;
                        }
                    } else if (mb.state == .released and self.selected_index != null) {
                        // 双击激活 (简化: release 就触发 on_item_activated)
                        const info = self.nthFilteredItem(self.selected_index.?);
                        if (info) |it| {
                            if (self.on_item_activated) |cb| cb(self, it.uri, it);
                        }
                        return .handled;
                    }
                }
            },
            .mouse_wheel => |mw| {
                const total_height: f32 = @as(f32, @floatFromInt(self.countFilteredItems())) * self.item_height;
                const max_scroll = @max(0, total_height - w.rect.height);
                self.scroll_offset = @max(0, @min(max_scroll, self.scroll_offset - @as(f32, @floatFromInt(mw.delta_y)) * self.item_height));
                w.markDirty();
                return .handled;
            },
            .mouse_move => |mm| {
                const lx: f32 = @floatFromInt(mm.x);
                const ly: f32 = @floatFromInt(mm.y);
                const inside = lx >= 0 and ly >= 0 and lx < w.rect.width and ly < w.rect.height;
                if (inside != w.state.hovered) {
                    w.state.hovered = inside;
                    w.markDirty();
                }
                if (inside) return .handled;
            },
            .key => |k| {
                if (k.state == .pressed and w.state.focused) {
                    const total = self.countFilteredItems();
                    switch (k.key) {
                        .up => {
                            if (self.selected_index) |si| {
                                if (si > 0) self.selectIndex(si - 1);
                            } else if (total > 0) {
                                self.selectIndex(0);
                            }
                            return .handled;
                        },
                        .down => {
                            if (self.selected_index) |si| {
                                if (si + 1 < total) self.selectIndex(si + 1);
                            } else if (total > 0) {
                                self.selectIndex(0);
                            }
                            return .handled;
                        },
                        .home => {
                            if (total > 0) self.selectIndex(0);
                            return .handled;
                        },
                        .end => {
                            if (total > 0) self.selectIndex(total - 1);
                            return .handled;
                        },
                        .space => {
                            if (self.select_multiple) {
                                if (self.selected_index) |si| {
                                    if (self.isIndexSelected(si)) self.unselectIndex(si) else self.selectIndex(si);
                                }
                            }
                            return .handled;
                        },
                        .enter => {
                            if (self.selected_index) |si| {
                                const info = self.nthFilteredItem(si);
                                if (info) |it| {
                                    if (self.on_item_activated) |cb| cb(self, it.uri, it);
                                }
                            }
                            return .handled;
                        },
                        else => {},
                    }
                }
            },
            else => {},
        }
        _ = ectx;
        return .ignored;
    }
};
