//! ListView 控件 - 虚拟化列表

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

pub const ListView = struct {
    base: Widget,
    allocator: std.mem.Allocator,
    items: std.ArrayListUnmanaged([]const u8),
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
        self.base.markDirty();
    }

    fn totalHeight(self: *const ListView) f32 {
        return @as(f32, @floatFromInt(self.items.items.len)) * (self.item_height + self.padding);
    }

    fn maxScroll(self: *const ListView) f32 {
        const total = self.totalHeight();
        const visible = self.base.rect.height;
        return @max(0, total - visible);
    }

    fn visibleRange(self: *const ListView) struct { start: usize, end: usize } {
        const start: usize = @intFromFloat(@max(0, @floor(self.scroll_offset / (self.item_height + self.padding))));
        const visible_count: usize = @as(usize, @intFromFloat(@ceil(self.base.rect.height / (self.item_height + self.padding)))) + 1;
        const end = @min(self.items.items.len, start + visible_count);
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

            // 项背景
            if (self.selected != null and self.selected.? == i) {
                ctx.renderer.fillRoundedRect(
                    .{ .x = rx + self.padding, .y = item_y, .width = rw - self.padding * 2 - 6, .height = self.item_height },
                    6,
                    self.item_selected_bg,
                ) catch {};
            } else if (self.hovered != null and self.hovered.? == i) {
                ctx.renderer.fillRoundedRect(
                    .{ .x = rx + self.padding, .y = item_y, .width = rw - self.padding * 2 - 6, .height = self.item_height },
                    6,
                    self.item_hover_bg,
                ) catch {};
            }

            // 文本
            self.drawLabel(ctx, self.items.items[i], rx + self.padding + 12, item_y + (self.item_height - self.font_size * 1.2) / 2.0, self.text_color);
        }

        // 滚动条
        const total = self.totalHeight();
        if (total > rh) {
            const scrollbar_h = @max(20.0, rh * (rh / total));
            const scrollbar_y = ry + (self.scroll_offset / self.maxScroll()) * (rh - scrollbar_h);
            ctx.renderer.fillRoundedRect(
                .{ .x = rx + rw - 5, .y = scrollbar_y, .width = 3, .height = scrollbar_h },
                1.5,
                self.scrollbar_color,
            ) catch {};
        }
    }

    fn drawLabel(self: *ListView, ctx: *PaintContext, text: []const u8, x: f32, y: f32, color: math.Color) void {
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
                        self.selected = idx;
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
                        if (self.selected) |sel| {
                            if (sel > 0) {
                                self.selected = sel - 1;
                                self.scrollToVisible(self.selected.?);
                                self.base.markDirty();
                            }
                        } else if (self.items.items.len > 0) {
                            self.selected = 0;
                            self.base.markDirty();
                        }
                        return .handled;
                    },
                    .down => {
                        if (self.selected) |sel| {
                            if (sel + 1 < self.items.items.len) {
                                self.selected = sel + 1;
                                self.scrollToVisible(self.selected.?);
                                self.base.markDirty();
                            }
                        } else if (self.items.items.len > 0) {
                            self.selected = 0;
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
        if (idx < self.items.items.len) return idx;
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
