//! PlacesSidebar 控件 - 位置侧边栏
//!
//! 类似 GtkPlacesSidebar: 文件管理器常用位置侧边栏。
//! 显示常用位置: 用户目录、桌面、文档、下载、音乐、图片、视频、回收站、其他位置等。
//!
//! 支持:
//! - 标准位置 (Desktop/Documents/Downloads/Music/Pictures/Videos
//! - 用户目录、已挂载驱动器
//! - 书签功能
//! - 位置图标和名称
//! - 点击激活位置
//! - 悬停高亮、当前选中
//! - 分组标题

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

/// 位置类型
pub const PlaceType = enum {
    home,
    desktop,
    documents,
    downloads,
    music,
    pictures,
    videos,
    trash,
    recent,
    bookmarks,
    drive,
    network,
    other,
};

pub const Place = struct {
    name: []const u8,
    path: []const u8,
    place_type: PlaceType,
    is_removable: bool = false,
};

pub const PlacesSidebar = struct {
    base: Widget,
    allocator: std.mem.Allocator,
    places: std.ArrayListUnmanaged(Place) = .{ .items = &[_]Place{}, .capacity = 0 },
    selected_index: ?usize = null,
    hovered_index: ?usize = null,

    on_location_changed: ?*const fn (self: *PlacesSidebar, index: usize, place: *const Place) void = null,

    bg_color: math.Color = math.Color.hex(0xF8FAFCFF),
    header_text_color: math.Color = math.Color.hex(0x64748BFF),
    item_bg_color: math.Color = math.Color.hex(0xF1F5F9FF),
    item_active_color: math.Color = math.Color.hex(0x3B82F614),
    item_hover_color: math.Color = math.Color.hex(0xE2E8F0FF),
    text_color: math.Color = math.Color.hex(0x0F172AFF),
    active_text_color: math.Color = math.Color.hex(0x2563EBFF),
    active_indicator_color: math.Color = math.Color.hex(0x3B82F6FF),

    item_height: f32 = 36,
    item_padding: f32 = 12,
    item_spacing: f32 = 1,
    sidebar_width: f32 = 200,
    icon_size: f32 = 18,
    text_start: f32 = 36,
    header_height: f32 = 28,
    active_indicator_width: f32 = 3,
    title_font_size: f32 = 13,
    header_font_size: f32 = 11,

    const Self = @This();

    pub fn create(allocator: std.mem.Allocator, opts: struct {
        sidebar_width: f32 = 200,
        item_height: f32 = 36,
        bg_color: math.Color = math.Color.hex(0xF8FAFCFF),
        text_color: math.Color = math.Color.hex(0x0F172AFF),
        on_location_changed: ?*const fn (self: *PlacesSidebar, index: usize, place: *const Place) void = null,
        include_defaults: bool = true,
    }) !*PlacesSidebar {
        const self = try allocator.create(PlacesSidebar);
        self.* = .{
            .base = .{
                .vtable = &vtable,
                .id = widget_mod.genWidgetId(),
            },
            .allocator = allocator,
            .sidebar_width = opts.sidebar_width,
            .item_height = opts.item_height,
            .bg_color = opts.bg_color,
            .text_color = opts.text_color,
            .on_location_changed = opts.on_location_changed,
        };
        self.base.accessibility = .{ .role = .list };
        self.base.cursor = .arrow;

        if (opts.include_defaults) {
            try self.addDefaultPlaces();
        }
        return self;
    }

    pub fn destroy(self: *Self, allocator: std.mem.Allocator) void {
        for (self.places.items) |*p| {
            allocator.free(p.name);
            allocator.free(p.path);
        }
        self.places.deinit(allocator);
        self.base.background.deinit(allocator);
        self.base.children.deinit(allocator);
        allocator.destroy(self);
    }

    fn dupStr(self: *Self, s: []const u8) ![]const u8 {
        return try self.allocator.dupe(u8, s);
    }

    /// 添加默认位置
    pub fn addDefaultPlaces(self: *Self) !void {
        const home = if (std.c.getenv("HOME")) |h| std.mem.span(h) else "/home/user";

        try self.addPlace("Home", home, .home);
        try self.addPlace("Desktop", tryConcat(home, "/Desktop") catch "/home/user/Desktop", .desktop);
        try self.addPlace("Documents", tryConcat(home, "/Documents") catch "/home/user/Documents", .documents);
        try self.addPlace("Downloads", tryConcat(home, "/Downloads") catch "/home/user/Downloads", .downloads);
        try self.addPlace("Music", tryConcat(home, "/Music") catch "/home/user/Music", .music);
        try self.addPlace("Pictures", tryConcat(home, "/Pictures") catch "/home/user/Pictures", .pictures);
        try self.addPlace("Videos", tryConcat(home, "/Videos") catch "/home/user/Videos", .videos);
        try self.addPlace("Recent", "", .recent);
        try self.addPlace("Trash", "trash:///", .trash);
    }

    fn tryConcat(home: []const u8, suffix: []const u8) ![]const u8 {
        var buf: [4096]u8 = undefined;
        const len = home.len + suffix.len;
        if (len >= buf.len) return error.NoSpaceLeft;
        @memcpy(buf[0..home.len], home);
        @memcpy(buf[home.len..][0..suffix.len], suffix);
        return buf[0..len];
    }

    /// 添加一个位置
    pub fn addPlace(self: *Self, name: []const u8, path: []const u8, place_type: PlaceType) !void {
        const name_dup = try self.dupStr(name);
        const path_dup = try self.dupStr(path);
        try self.places.append(self.allocator, .{
            .name = name_dup,
            .path = path_dup,
            .place_type = place_type,
        });
        self.base.markLayoutDirty();
        self.base.markDirty();
    }

    /// 获取位置数量
    pub fn getPlaceCount(self: *const Self) usize {
        return self.places.items.len;
    }

    /// 获取当前选中
    pub fn getSelected(self: *const Self) ?usize {
        return self.selected_index;
    }

    /// 选中指定位置
    pub fn selectPlace(self: *Self, index: ?usize) void {
        if (self.selected_index != index) {
            self.selected_index = index;
            self.base.markDirty();
        }
    }

    /// 计算 item index 对应的 y 范围
    fn getYForItem(self: *const Self, index: usize) f32 {
        return self.header_height + @as(f32, @floatFromInt(index)) * (self.item_height + self.item_spacing);
    }

    /// 根据 y 找 item
    fn findItemAt(self: *const Self, y: f32) ?usize {
        const header_h = self.header_height;
        if (y < header_h) return null;
        const rel_y = y - header_h;
        const row_h = self.item_height + self.item_spacing;
        if (rel_y < 0) return null;
        const idx_f = rel_y / row_h;
        const idx: usize = @intFromFloat(idx_f);
        if (idx < self.places.items.len) {
            const exact_y = self.header_height + @as(f32, @floatFromInt(idx)) * row_h;
            if (y < exact_y + self.item_height) return idx;
        }
        return null;
    }

    /// 切换到位置
    fn activatePlace(self: *Self, index: usize) void {
        if (index >= self.places.items.len) return;
        self.selectPlace(index);
        if (self.on_location_changed) |cb| {
            cb(self, index, &self.places.items[index]);
        }
    }

    /// 绘制位置图标（简化版）
    fn drawPlaceIcon(self: *Self, r2d: anytype, x: f32, y: f32, place: Place, color: math.Color) void {
        const s = self.icon_size;

        switch (place.place_type) {
            .home => {
                // 简单的房子形状
                const cx = x + s / 2;
                const ty = y + s * 0.2;

                // 屋顶三角形
                const tri = [3][2]f32{
                    .{ cx, y },
                    .{ x + s, ty + s * 0.15 },
                    .{ x, ty + s * 0.15 },
                };
                r2d.fillConvexPolygon(&tri, color) catch {};
                // 房子主体
                r2d.fillRect(.{
                    .x = x + s * 0.15,
                    .y = ty + s * 0.15,
                    .width = s * 0.7,
                    .height = s * 0.65,
                }, color) catch {};
            },
            .desktop, .documents, .downloads, .other, .bookmarks => {
                // 文件夹形状
                r2d.strokeRect(.{ .x = x, .y = y + s * 0.2, .width = s, .height = s * 0.7 }, s * 0.1, color) catch {};
                r2d.fillRect(.{ .x = x, .y = y + s * 0.1, .width = s * 0.45, .height = s * 0.15 }, color) catch {};
            },
            .music => {
                // 音符
                r2d.fillRect(.{ .x = x + s * 0.5, .y = y + s * 0.15, .width = s * 0.12, .height = s * 0.55 }, color) catch {};
                r2d.strokeRect(.{ .x = x + s * 0.45, .y = y + s * 0.62, .width = s * 0.3, .height = s * 0.22 }, s * 0.08, color) catch {};
            },
            .pictures => {
                // 相框
                r2d.strokeRect(.{ .x = x, .y = y, .width = s, .height = s }, s * 0.08, color) catch {};
                // 山
                const tri = [3][2]f32{
                    .{ x + s * 0.2, y + s * 0.75 },
                    .{ x + s * 0.45, y + s * 0.35 },
                    .{ x + s * 0.7, y + s * 0.75 },
                };
                r2d.fillConvexPolygon(&tri, color) catch {};
            },
            .videos => {
                // 胶片
                r2d.fillRect(.{ .x = x, .y = y + s * 0.2, .width = s, .height = s * 0.6 }, color) catch {};
                // 播放三角
                const tri = [3][2]f32{
                    .{ x + s * 0.38, y + s * 0.35 },
                    .{ x + s * 0.72, y + s * 0.5 },
                    .{ x + s * 0.38, y + s * 0.65 },
                };
                const white = math.Color.hex(0xFFFFFFFF);
                r2d.fillConvexPolygon(&tri, white) catch {};
            },
            .trash => {
                // 垃圾桶
                r2d.fillRect(.{ .x = x + s * 0.25, .y = y + s * 0.15, .width = s * 0.5, .height = s * 0.08 }, color) catch {};
                r2d.strokeRect(.{
                    .x = x + s * 0.2,
                    .y = y + s * 0.2,
                    .width = s * 0.6,
                    .height = s * 0.65,
                }, s * 0.1, color) catch {};
            },
            .recent => {
                // 圆圈
                r2d.strokeRect(.{ .x = x, .y = y + s * 0.1, .width = s * 0.8, .height = s * 0.8 }, s * 0.1, color) catch {};
                r2d.fillRect(.{ .x = x + s * 0.38, .y = y + s * 0.28, .width = s * 0.12, .height = s * 0.32 }, color) catch {};
                r2d.fillRect(.{ .x = x + s * 0.38, .y = y + s * 0.28, .width = s * 0.3, .height = s * 0.12 }, color) catch {};
            },
            .drive => {
                // 硬盘
                r2d.strokeRect(.{ .x = x, .y = y + s * 0.25, .width = s, .height = s * 0.5 }, s * 0.1, color) catch {};
                r2d.fillRect(.{ .x = x + s * 0.72, .y = y + s * 0.45, .width = s * 0.1, .height = s * 0.1 }, color) catch {};
            },
            .network => {
                // 网络图标
                const cx = x + s / 2;
                const tri = [3][2]f32{
                    .{ cx, y + s * 0.15 },
                    .{ x + s * 0.1, y + s * 0.55 },
                    .{ x + s * 0.9, y + s * 0.55 },
                };
                r2d.fillConvexPolygon(&tri, color) catch {};
                r2d.fillRect(.{ .x = cx - s * 0.05, .y = y + s * 0.55, .width = s * 0.1, .height = s * 0.25 }, color) catch {};
            },
        }
    }

    // ── VTable ──────────────────────────────────────────────────────────────

    const vtable = Widget.VTable{
        .type_name = "places_sidebar",
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
        const self: *Self = @fieldParentPtr("base", w);
        _ = ctx;

        const cnt = self.places.items.len;
        const cnt_f: f32 = @floatFromInt(cnt);
        const total_h = self.header_height + cnt_f * (self.item_height + self.item_spacing);

        const w_out = if (constraints.max_width < std.math.inf(f32))
            constraints.max_width
        else
            self.sidebar_width;
        const h_out = if (constraints.max_height < std.math.inf(f32))
            constraints.max_height
        else
            total_h;
        return .{ .width = w_out, .height = h_out };
    }

    fn paint(w: *Widget, ctx: *PaintContext) void {
        const self: *Self = @fieldParentPtr("base", w);
        const rx = ctx.offset_x + w.rect.x;
        const ry = ctx.offset_y + w.rect.y;

        ctx.renderer.fillRect(
            .{ .x = rx, .y = ry, .width = w.rect.width, .height = w.rect.height },
            self.bg_color,
        ) catch {};

        // Header "Places" 标题
        const header_label = "Places";
        styled_text.drawText(
            ctx.renderer,
            ctx.allocator,
            header_label,
            rx + self.item_padding,
            ry + (self.header_height - self.header_font_size) / 2 + 1,
            .{
                .font_size = self.header_font_size,
                .color = self.header_text_color,
                .font_weight = 600,
            },
        );

        for (self.places.items, 0..) |place, i| {
            const cur_y = ry + self.getYForItem(i);
            const is_active = (self.selected_index == i);
            const is_hovered = (self.hovered_index == i);

            if (is_active) {
                ctx.renderer.fillRect(.{
                    .x = rx,
                    .y = cur_y,
                    .width = self.active_indicator_width,
                    .height = self.item_height,
                }, self.active_indicator_color) catch {};
                ctx.renderer.fillRect(.{
                    .x = rx + self.active_indicator_width,
                    .y = cur_y,
                    .width = w.rect.width - self.active_indicator_width,
                    .height = self.item_height,
                }, self.item_active_color) catch {};
            } else if (is_hovered) {
                ctx.renderer.fillRect(.{
                    .x = rx,
                    .y = cur_y,
                    .width = w.rect.width,
                    .height = self.item_height,
                }, self.item_hover_color) catch {};
            }

            const icon_x = rx + self.item_padding + if (is_active) self.active_indicator_width else 0;
            const icon_y = cur_y + (self.item_height - self.icon_size) / 2;
            const tcolor = if (is_active) self.active_text_color else self.text_color;
            self.drawPlaceIcon(ctx.renderer, icon_x, icon_y, place, tcolor);

            const ts = self.text_start;
            const text_x = rx + ts + if (is_active) self.active_indicator_width else 0;
            const tsize = styled_text.measureText(ctx.allocator, place.name, .{ .font_size = self.title_font_size });
            const text_y = cur_y + (self.item_height - tsize.height) / 2;
            styled_text.drawText(ctx.renderer, ctx.allocator, place.name, text_x, text_y, .{
                .font_size = self.title_font_size,
                .color = tcolor,
                .font_weight = if (is_active) 600 else 400,
            });
        }
    }

    fn onEvent(w: *Widget, event: *const pal.Event, ectx: *EventContext) EventResult {
        const self: *Self = @fieldParentPtr("base", w);
        _ = ectx;

        switch (event.*) {
            .mouse_move => |mm| {
                const my: f32 = @floatFromInt(mm.y);
                const hovered = self.findItemAt(my);
                if (hovered != self.hovered_index) {
                    self.hovered_index = hovered;
                    self.base.markDirty();
                }
                return if (hovered != null) .handled else .ignored;
            },
            .mouse_button => |mb| {
                if (mb.button == .left and mb.state == .pressed) {
                    const my: f32 = @floatFromInt(mb.y);
                    if (self.findItemAt(my)) |idx| {
                        self.activatePlace(idx);
                        return .handled;
                    }
                }
            },
            .key => |key| {
                if (key.state == .pressed) {
                    const cur = self.selected_index orelse 0;
                    const cnt = self.places.items.len;
                    if (cnt == 0) return .ignored;
                    if (key.key == .up) {
                        if (cur > 0) self.activatePlace(cur - 1);
                        return .handled;
                    } else if (key.key == .down) {
                        if (cur < cnt - 1) self.activatePlace(cur + 1);
                        return .handled;
                    } else if (key.key == .home) {
                        self.activatePlace(0);
                        return .handled;
                    } else if (key.key == .end and cnt > 0) {
                        self.activatePlace(cnt - 1);
                        return .handled;
                    }
                }
            },
            .mouse_leave => {
                self.hovered_index = null;
                self.base.markDirty();
            },
            else => {},
        }
        return .ignored;
    }
};
