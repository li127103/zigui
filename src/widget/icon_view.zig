//! IconView 控件 - 图标视图
//!
//! 以网格形式显示图标和标签的视图控件，支持单选。
//! 图标使用文本/emoji 表示，也可以扩展为纹理图标。
//!
//! 使用方法:
//! ```
//! var view = try IconView.create(allocator, .{
//!     .icon_size = 48,
//!     .columns = 4,
//! });
//! try view.addItem("📁", "Documents");
//! try view.addItem("🖼️", "Pictures");
//! ```

const std = @import("std");
const math = @import("../math.zig");
const widget_mod = @import("widget.zig");
const layout_mod = @import("../layout/engine.zig");
const pal = @import("../pal/pal.zig");

const Widget = widget_mod.Widget;
const PaintContext = widget_mod.PaintContext;
const EventContext = widget_mod.EventContext;
const EventResult = widget_mod.EventResult;

pub const IconViewItem = struct {
    icon: []const u8,
    label: []const u8,
    user_data: ?*anyopaque = null,
};

pub const IconView = struct {
    base: Widget,
    allocator: std.mem.Allocator,
    items: std.ArrayListUnmanaged(IconViewItem) = .{ .items = &.{}, .capacity = 0 },
    selected: ?usize = null,
    hovered: ?usize = null,
    scroll_offset: f32 = 0,

    icon_size: f32 = 48,
    icon_font_size: f32 = 32,
    label_font_size: f32 = 12,
    item_width: f32 = 100,
    item_height: f32 = 90,
    columns: u32 = 4,
    item_padding: f32 = 8,
    spacing: f32 = 8,

    on_select: ?*const fn (self: *IconView, index: usize) void = null,
    on_activate: ?*const fn (self: *IconView, index: usize) void = null,

    bg_color: math.Color = math.Color.hex(0x0F172AFF),
    item_bg: math.Color = math.Color.hex(0x1E293BFF),
    item_hover_bg: math.Color = math.Color.hex(0x334155FF),
    item_selected_bg: math.Color = math.Color.hex(0x3B82F633),
    icon_color: math.Color = math.Color.hex(0xF8FAFCFF),
    text_color: math.Color = math.Color.hex(0xF8FAFCFF),
    text_secondary: math.Color = math.Color.hex(0x94A3B8FF),
    scrollbar_color: math.Color = math.Color.hex(0x475569FF),
    corner_radius: f32 = 8.0,
    padding: f32 = 8.0,

    const Self = @This();

    pub fn create(allocator: std.mem.Allocator, opts: struct {
        icon_size: f32 = 48,
        columns: u32 = 4,
        item_width: f32 = 100,
        item_height: f32 = 90,
        on_select: ?*const fn (self: *IconView, index: usize) void = null,
        on_activate: ?*const fn (self: *IconView, index: usize) void = null,
        bg_color: ?math.Color = null,
    }) !*IconView {
        const self = try allocator.create(IconView);
        self.* = .{
            .base = .{
                .vtable = &vtable,
                .id = widget_mod.genWidgetId(),
            },
            .allocator = allocator,
            .icon_size = opts.icon_size,
            .columns = opts.columns,
            .item_width = opts.item_width,
            .item_height = opts.item_height,
            .icon_font_size = opts.icon_size * 0.66,
            .on_select = opts.on_select,
            .on_activate = opts.on_activate,
            .bg_color = opts.bg_color orelse self.bg_color,
        };
        return self;
    }

    pub fn destroy(self: *Self, allocator: std.mem.Allocator) void {
        for (self.items.items) |*item| {
            allocator.free(item.icon);
            allocator.free(item.label);
        }
        self.items.deinit(allocator);
        self.base.background.deinit(allocator);
        self.base.children.deinit(allocator);
        allocator.destroy(self);
    }

    pub fn addItem(self: *Self, icon: []const u8, label: []const u8) !void {
        const owned_icon = try self.allocator.dupe(u8, icon);
        const owned_label = try self.allocator.dupe(u8, label);
        errdefer {
            self.allocator.free(owned_icon);
            self.allocator.free(owned_label);
        }
        try self.items.append(self.allocator, .{
            .icon = owned_icon,
            .label = owned_label,
        });
        self.base.markDirty();
    }

    pub fn addItemWithData(self: *Self, icon: []const u8, label: []const u8, user_data: ?*anyopaque) !void {
        const owned_icon = try self.allocator.dupe(u8, icon);
        const owned_label = try self.allocator.dupe(u8, label);
        errdefer {
            self.allocator.free(owned_icon);
            self.allocator.free(owned_label);
        }
        try self.items.append(self.allocator, .{
            .icon = owned_icon,
            .label = owned_label,
            .user_data = user_data,
        });
        self.base.markDirty();
    }

    pub fn clearItems(self: *Self) void {
        for (self.items.items) |*item| {
            self.allocator.free(item.icon);
            self.allocator.free(item.label);
        }
        self.items.clearRetainingCapacity();
        self.selected = null;
        self.hovered = null;
        self.scroll_offset = 0;
        self.base.markDirty();
    }

    pub fn getSelected(self: *const Self) ?usize {
        return self.selected;
    }

    pub fn setSelected(self: *Self, index: ?usize) void {
        if (index) |idx| {
            if (idx < self.items.items.len) {
                self.selected = idx;
            }
        } else {
            self.selected = null;
        }
        self.base.markDirty();
    }

    fn totalRows(self: *const Self) usize {
        const cols: usize = @intCast(self.columns);
        if (cols == 0) return 0;
        return (self.items.items.len + cols - 1) / cols;
    }

    fn totalHeight(self: *const Self) f32 {
        return self.padding * 2 + @as(f32, @floatFromInt(self.totalRows())) * (self.item_height + self.spacing);
    }

    fn maxScroll(self: *const Self) f32 {
        const h = self.base.rect.height;
        return @max(0, self.totalHeight() - h);
    }

    fn indexAt(self: *const Self, x: f32, y: f32) ?usize {
        const cols: usize = @intCast(self.columns);
        if (cols == 0) return null;

        const adjusted_y = y + self.scroll_offset - self.padding;
        if (adjusted_y < 0) return null;

        const col: usize = @intFromFloat(@max(0, (x - self.padding) / (self.item_width + self.spacing)));
        const row: usize = @intFromFloat(@max(0, adjusted_y / (self.item_height + self.spacing)));

        if (col >= cols) return null;

        const idx = row * cols + col;
        if (idx >= self.items.items.len) return null;

        const item_x = self.padding + @as(f32, @floatFromInt(col)) * (self.item_width + self.spacing);
        const item_y = self.padding + @as(f32, @floatFromInt(row)) * (self.item_height + self.spacing) - self.scroll_offset;

        if (x >= item_x and x < item_x + self.item_width and
            y >= item_y and y < item_y + self.item_height)
        {
            return idx;
        }
        return null;
    }

    fn clampScroll(self: *Self) void {
        const max_s = self.maxScroll();
        if (self.scroll_offset < 0) self.scroll_offset = 0;
        if (self.scroll_offset > max_s) self.scroll_offset = max_s;
    }

    // ── VTable ──────────────────────────────────────────────────────────────

    const vtable = Widget.VTable{
        .type_name = "icon_view",
        .measure = measure,
        .paint = paint,
        .on_event = onEvent,
        .focusable = true,
        .destroy = destroyVTable,
    };

    fn destroyVTable(w: *Widget, allocator: std.mem.Allocator) void {
        const self: *Self = @fieldParentPtr("base", w);
        self.destroy(allocator);
    }

    fn measure(w: *Widget, ctx: *PaintContext, constraints: layout_mod.Constraints) math.Size(f32) {
        _ = ctx;
        const w_used = if (w.rect.width > 0) w.rect.width else @min(400, constraints.max_width);
        const h_used = if (w.rect.height > 0) w.rect.height else @min(300, constraints.max_height);
        return .{ .width = w_used, .height = h_used };
    }

    fn paint(w: *Widget, ctx: *PaintContext) void {
        const self: *Self = @fieldParentPtr("base", w);
        const rx = ctx.offset_x + w.rect.x;
        const ry = ctx.offset_y + w.rect.y;
        const rw = w.rect.width;
        const rh = w.rect.height;

        ctx.renderer.fillRect(.{ .x = rx, .y = ry, .width = rw, .height = rh }, self.bg_color) catch {};

        const cols: usize = @intCast(self.columns);
        if (cols == 0) return;

        for (self.items.items, 0..) |item, idx| {
            const col = idx % cols;
            const row = idx / cols;

            const item_x = rx + self.padding + @as(f32, @floatFromInt(col)) * (self.item_width + self.spacing);
            const item_y = ry + self.padding + @as(f32, @floatFromInt(row)) * (self.item_height + self.spacing) - self.scroll_offset;

            if (item_y + self.item_height < ry or item_y > ry + rh) continue;

            const is_selected = if (self.selected) |s| s == idx else false;
            const is_hovered = if (self.hovered) |h| h == idx else false;

            const item_rect = math.Rect(f32){
                .x = item_x,
                .y = item_y,
                .width = self.item_width,
                .height = self.item_height,
            };

            const bg = if (is_selected)
                self.item_selected_bg
            else if (is_hovered)
                self.item_hover_bg
            else
                self.item_bg;

            ctx.renderer.fillRoundedRect(item_rect, self.corner_radius, bg) catch {};

            const icon_y = item_y + self.item_padding;
            ctx.renderer.drawText(
                item.icon,
                item_x + self.item_width / 2,
                icon_y + (self.icon_size - self.icon_font_size) / 2,
                self.icon_font_size,
                self.icon_color,
                .center,
            ) catch {};

            ctx.renderer.drawText(
                item.label,
                item_x + self.item_width / 2,
                item_y + self.item_height - self.item_padding - self.label_font_size,
                self.label_font_size,
                self.text_color,
                .center,
            ) catch {};
        }

        const total_h = self.totalHeight();
        if (total_h > rh) {
            const bar_w: f32 = 6;
            const bar_x = rx + rw - bar_w - 2;
            const bar_h = rh * (rh / total_h);
            const bar_y = ry + (self.scroll_offset / total_h) * rh;
            ctx.renderer.fillRoundedRect(
                .{ .x = bar_x, .y = bar_y, .width = bar_w, .height = bar_h },
                3,
                self.scrollbar_color,
            ) catch {};
        }
    }

    fn onEvent(w: *Widget, event: *const pal.Event, ectx: *EventContext) EventResult {
        const self: *Self = @fieldParentPtr("base", w);
        _ = ectx;

        switch (event.*) {
            .mouse_move => |me| {
                const local_x = me.x - w.rect.x;
                const local_y = me.y - w.rect.y;
                self.hovered = self.indexAt(local_x, local_y);
                self.base.markDirty();
                return if (self.hovered != null) .handled else .ignored;
            },
            .mouse_button => |mb| {
                if (mb.button == .left and mb.state == .pressed) {
                    const local_x = mb.x - w.rect.x;
                    const local_y = mb.y - w.rect.y;
                    if (self.indexAt(local_x, local_y)) |idx| {
                        self.selected = idx;
                        self.base.markDirty();
                        if (self.on_select) |cb| cb(self, idx);
                        return .handled;
                    } else {
                        self.selected = null;
                        self.base.markDirty();
                        return .handled;
                    }
                }
                if (mb.button == .left and mb.state == .double_click) {
                    const local_x = mb.x - w.rect.x;
                    const local_y = mb.y - w.rect.y;
                    if (self.indexAt(local_x, local_y)) |idx| {
                        if (self.on_activate) |cb| cb(self, idx);
                        return .handled;
                    }
                }
                return .ignored;
            },
            .scroll => |se| {
                self.scroll_offset += se.dy * 30;
                self.clampScroll();
                self.base.markDirty();
                return .handled;
            },
            .key => |ke| {
                if (ke.state != .pressed) return .ignored;
                const cols: isize = @intCast(self.columns);
                const current: isize = @intCast(self.selected orelse return .ignored);
                const total: isize = @intCast(self.items.items.len);

                var new_idx: isize = current;
                switch (ke.key) {
                    .up => new_idx = current - cols,
                    .down => new_idx = current + cols,
                    .left => new_idx = current - 1,
                    .right => new_idx = current + 1,
                    .home => new_idx = 0,
                    .end => new_idx = total - 1,
                    .return_, .enter => {
                        if (self.on_activate) |cb| cb(self, @intCast(current));
                        return .handled;
                    },
                    else => return .ignored,
                }

                if (new_idx >= 0 and new_idx < total) {
                    self.selected = @intCast(new_idx);
                    if (self.on_select) |cb| cb(self, @intCast(new_idx));

                    const row: f32 = @floatFromInt(@as(usize, @intCast(new_idx)) / @as(usize, @intCast(self.columns)));
                    const item_top = self.padding + row * (self.item_height + self.spacing);
                    const item_bottom = item_top + self.item_height;
                    const view_top = self.scroll_offset;
                    const view_bottom = self.scroll_offset + w.rect.height;

                    if (item_top < view_top) {
                        self.scroll_offset = item_top;
                    } else if (item_bottom > view_bottom) {
                        self.scroll_offset = item_bottom - w.rect.height;
                    }
                    self.clampScroll();
                    self.base.markDirty();
                }
                return .handled;
            },
            else => return .ignored,
        }
    }
};
