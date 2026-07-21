//! Table 控件 - 虚拟化表格
//!
//! 列定义 (标题 + 宽度) + 行数据 (字符串单元)。表头固定, 数据行虚拟化滚动。
//! 支持行选中、键盘导航、单元格按列宽裁剪。

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

pub const Column = struct {
    title: []const u8,
    width: f32,
};

pub const Row = std.ArrayListUnmanaged([]const u8);

pub const Table = struct {
    base: Widget,
    allocator: std.mem.Allocator,
    columns: std.ArrayListUnmanaged(Column),
    rows: std.ArrayListUnmanaged(Row),
    selected: ?usize = null,
    hovered: ?usize = null,
    scroll_offset: f32 = 0,
    header_height: f32,
    row_height: f32,
    font_size: f32,
    on_select: ?*const fn (self: *Table, index: usize) void,
    // 样式
    bg_color: math.Color = math.Color.hex(0x0F172AFF),
    header_bg: math.Color = math.Color.hex(0x1E293BFF),
    header_text: math.Color = math.Color.hex(0x94A3B8FF),
    row_alt_bg: math.Color = math.Color.hex(0x162032FF),
    hover_bg: math.Color = math.Color.hex(0x334155FF),
    selected_bg: math.Color = math.Color.hex(0x3B82F633),
    text_color: math.Color = math.Color.hex(0xF8FAFCFF),
    grid_color: math.Color = math.Color.hex(0x334155FF),
    scrollbar_color: math.Color = math.Color.hex(0x475569FF),
    corner_radius: f32 = 10.0,
    cell_padding: f32 = 10.0,

    pub fn create(allocator: std.mem.Allocator, opts: struct {
        header_height: f32 = 40.0,
        row_height: f32 = 36.0,
        font_size: f32 = 14.0,
        on_select: ?*const fn (self: *Table, index: usize) void = null,
    }) !*Table {
        const self = try allocator.create(Table);
        self.* = .{
            .base = .{
                .vtable = &vtable,
                .id = widget_mod.genWidgetId(),
            },
            .allocator = allocator,
            .columns = .{ .items = &.{}, .capacity = 0 },
            .rows = .{ .items = &.{}, .capacity = 0 },
            .header_height = opts.header_height,
            .row_height = opts.row_height,
            .font_size = opts.font_size,
            .on_select = opts.on_select,
        };
        return self;
    }

    pub fn destroy(self: *Table, allocator: std.mem.Allocator) void {
        for (self.rows.items) |*r| r.deinit(allocator);
        self.rows.deinit(allocator);
        self.columns.deinit(allocator);
        self.base.children.deinit(allocator);
        allocator.destroy(self);
    }

    pub fn addColumn(self: *Table, title: []const u8, width: f32) !void {
        try self.columns.append(self.allocator, .{ .title = title, .width = width });
        self.base.markDirty();
    }

    pub fn addRow(self: *Table, cells: []const []const u8) !void {
        var row: Row = .{ .items = &.{}, .capacity = 0 };
        errdefer row.deinit(self.allocator);
        for (cells) |c| try row.append(self.allocator, c);
        try self.rows.append(self.allocator, row);
        self.base.markDirty();
    }

    pub fn clearRows(self: *Table) void {
        for (self.rows.items) |*r| r.deinit(self.allocator);
        self.rows.clearRetainingCapacity();
        self.selected = null;
        self.hovered = null;
        self.scroll_offset = 0;
        self.base.markDirty();
    }

    /// 各列起始 x 偏移 (相对控件左缘)
    fn columnX(self: *const Table, index: usize) f32 {
        var x: f32 = 0;
        for (self.columns.items[0..index]) |c| x += c.width;
        return x;
    }

    fn totalWidth(self: *const Table) f32 {
        var x: f32 = 0;
        for (self.columns.items) |c| x += c.width;
        return x;
    }

    fn dataHeight(self: *const Table) f32 {
        return self.base.rect.height - self.header_height;
    }

    fn totalRowsHeight(self: *const Table) f32 {
        return @as(f32, @floatFromInt(self.rows.items.len)) * self.row_height;
    }

    fn maxScroll(self: *const Table) f32 {
        return @max(0, self.totalRowsHeight() - self.dataHeight());
    }

    // ── VTable ──────────────────────────────────────────────────────────────

    const vtable = Widget.VTable{
        .type_name = "table",
        .measure = measure,
        .paint = paint,
        .on_event = onEvent,
        .focusable = true,
        .destroy = destroyVTable,
    };

    fn destroyVTable(w: *Widget, allocator: std.mem.Allocator) void {
        const self: *Table = @fieldParentPtr("base", w);
        self.destroy(allocator);
    }

    fn measure(w: *Widget, ctx: *PaintContext, constraints: layout_mod.Constraints) math.Size(f32) {
        _ = ctx;
        _ = constraints;
        _ = w;
        return .{ .width = 500, .height = 400 };
    }

    fn paint(w: *Widget, ctx: *PaintContext) void {
        const self: *Table = @fieldParentPtr("base", w);
        const rx = ctx.offset_x + w.rect.x;
        const ry = ctx.offset_y + w.rect.y;
        const rw = w.rect.width;
        const rh = w.rect.height;

        // 背景
        ctx.renderer.fillRoundedRect(.{ .x = rx, .y = ry, .width = rw, .height = rh }, self.corner_radius, self.bg_color) catch {};

        // ── 数据行 (虚拟化) ──
        const data_y = ry + self.header_height;
        const data_h = rh - self.header_height;
        const start: usize = @intFromFloat(@max(0, @floor(self.scroll_offset / self.row_height)));
        const end = @min(self.rows.items.len, start + @as(usize, @intFromFloat(@ceil(data_h / self.row_height))) + 1);

        var i: usize = start;
        while (i < end) : (i += 1) {
            const row_y = data_y + @as(f32, @floatFromInt(i)) * self.row_height - self.scroll_offset;
            if (row_y + self.row_height < data_y or row_y > ry + rh) continue;

            // 交替 / 悬停 / 选中背景
            if (self.selected != null and self.selected.? == i) {
                ctx.renderer.fillRect(.{ .x = rx, .y = row_y, .width = rw, .height = self.row_height }, self.selected_bg) catch {};
            } else if (self.hovered != null and self.hovered.? == i) {
                ctx.renderer.fillRect(.{ .x = rx, .y = row_y, .width = rw, .height = self.row_height }, self.hover_bg) catch {};
            } else if (i % 2 == 1) {
                ctx.renderer.fillRect(.{ .x = rx, .y = row_y, .width = rw, .height = self.row_height }, self.row_alt_bg) catch {};
            }

            // 单元格 (按列宽裁剪)
            const row = self.rows.items[i];
            for (self.columns.items, 0..) |col, ci| {
                if (ci >= row.items.len) break;
                const cx = rx + self.columnX(ci);
                const clip = math.Rect(f32){ .x = cx + 2, .y = row_y, .width = col.width - 4, .height = self.row_height };
                self.drawCellClipped(ctx, row.items[ci], cx + self.cell_padding, row_y + (self.row_height - self.font_size * 1.2) / 2.0, self.text_color, clip);
            }

            // 行分隔线
            ctx.renderer.fillRect(.{ .x = rx, .y = row_y + self.row_height - 1, .width = rw, .height = 1 }, self.grid_color) catch {};
        }

        // ── 表头 (固定, 最后绘制以覆盖滚动行) ──
        ctx.renderer.fillRect(.{ .x = rx, .y = ry, .width = rw, .height = self.header_height }, self.header_bg) catch {};
        for (self.columns.items, 0..) |col, ci| {
            const cx = rx + self.columnX(ci);
            self.drawCell(ctx, col.title, cx + self.cell_padding, ry + (self.header_height - self.font_size * 1.2) / 2.0, self.header_text, 600);
            // 列分隔线
            if (ci > 0) {
                ctx.renderer.fillRect(.{ .x = cx, .y = ry, .width = 1, .height = self.header_height }, self.grid_color) catch {};
            }
        }
        // 表头底边
        ctx.renderer.fillRect(.{ .x = rx, .y = ry + self.header_height - 1, .width = rw, .height = 1 }, self.grid_color) catch {};

        // ── 滚动条 ──
        const total = self.totalRowsHeight();
        if (total > data_h) {
            const sb_h = @max(20.0, data_h * (data_h / total));
            const sb_y = data_y + (self.scroll_offset / self.maxScroll()) * (data_h - sb_h);
            ctx.renderer.fillRoundedRect(.{ .x = rx + rw - 5, .y = sb_y, .width = 3, .height = sb_h }, 1.5, self.scrollbar_color) catch {};
        }
    }

    fn drawCell(self: *Table, ctx: *PaintContext, text: []const u8, x: f32, y: f32, color: math.Color, weight: u16) void {
        var font = coretext.CtFont.create(null, self.font_size, weight) catch return;
        defer font.destroy();
        var tl = text_layout.TextLayout.layout(ctx.allocator, &ctx.renderer.glyph_atlas.?, ctx.renderer.device, text, .{ .font = &font, .font_size = self.font_size }) catch return;
        defer tl.deinit();
        ctx.renderer.drawText(&tl, x, y, color) catch {};
    }

    fn drawCellClipped(self: *Table, ctx: *PaintContext, text: []const u8, x: f32, y: f32, color: math.Color, clip: math.Rect(f32)) void {
        var font = coretext.CtFont.create(null, self.font_size, 400) catch return;
        defer font.destroy();
        var tl = text_layout.TextLayout.layout(ctx.allocator, &ctx.renderer.glyph_atlas.?, ctx.renderer.device, text, .{ .font = &font, .font_size = self.font_size }) catch return;
        defer tl.deinit();
        ctx.renderer.drawTextClipped(&tl, x, y, color, clip) catch {};
    }

    fn onEvent(w: *Widget, event: *const pal.Event, ectx: *EventContext) EventResult {
        const self: *Table = @fieldParentPtr("base", w);
        _ = ectx;

        switch (event.*) {
            .scroll => |sc| {
                self.scroll_offset = std.math.clamp(self.scroll_offset - sc.delta * 30.0, 0, self.maxScroll());
                self.base.markDirty();
                return .handled;
            },
            .mouse_move => |mm| {
                const my: f32 = @floatFromInt(mm.y);
                const idx = self.rowAtY(my);
                if (idx != self.hovered) {
                    self.hovered = idx;
                    self.base.markDirty();
                }
            },
            .mouse_button => |mb| {
                if (mb.button == .left and mb.state == .pressed) {
                    const my: f32 = @floatFromInt(mb.y);
                    if (self.rowAtY(my)) |idx| {
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
                        } else if (self.rows.items.len > 0) {
                            self.selected = 0;
                            self.base.markDirty();
                        }
                        return .handled;
                    },
                    .down => {
                        if (self.selected) |sel| {
                            if (sel + 1 < self.rows.items.len) {
                                self.selected = sel + 1;
                                self.scrollToVisible(self.selected.?);
                                self.base.markDirty();
                            }
                        } else if (self.rows.items.len > 0) {
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

    /// 数据区某 y 坐标对应的行索引 (y 相对控件原点)
    fn rowAtY(self: *const Table, y: f32) ?usize {
        const rel = y - self.header_height;
        if (rel < 0 or rel >= self.dataHeight()) return null;
        const idx: usize = @intFromFloat((rel + self.scroll_offset) / self.row_height);
        if (idx < self.rows.items.len) return idx;
        return null;
    }

    fn scrollToVisible(self: *Table, index: usize) void {
        const top = @as(f32, @floatFromInt(index)) * self.row_height;
        const bottom = top + self.row_height;
        const view_h = self.dataHeight();
        if (top < self.scroll_offset) {
            self.scroll_offset = top;
        } else if (bottom > self.scroll_offset + view_h) {
            self.scroll_offset = bottom - view_h;
        }
        self.scroll_offset = std.math.clamp(self.scroll_offset, 0, self.maxScroll());
    }
};

// ── 测试 ──────────────────────────────────────────────────────────────────

test "table columnX accumulates widths" {
    const alloc = std.testing.allocator;
    var t = Table{
        .base = .{ .vtable = undefined, .id = 1 },
        .allocator = alloc,
        .columns = .{ .items = &.{}, .capacity = 0 },
        .rows = .{ .items = &.{}, .capacity = 0 },
        .header_height = 40,
        .row_height = 36,
        .font_size = 14,
        .on_select = null,
    };
    defer t.columns.deinit(alloc);

    try t.addColumn("A", 100);
    try t.addColumn("B", 150);
    try t.addColumn("C", 80);

    try std.testing.expectApproxEqAbs(t.columnX(0), 0.0, 0.001);
    try std.testing.expectApproxEqAbs(t.columnX(1), 100.0, 0.001);
    try std.testing.expectApproxEqAbs(t.columnX(2), 250.0, 0.001);
    try std.testing.expectApproxEqAbs(t.totalWidth(), 330.0, 0.001);
}

test "table addRow stores cells" {
    const alloc = std.testing.allocator;
    var t = Table{
        .base = .{ .vtable = undefined, .id = 1 },
        .allocator = alloc,
        .columns = .{ .items = &.{}, .capacity = 0 },
        .rows = .{ .items = &.{}, .capacity = 0 },
        .header_height = 40,
        .row_height = 36,
        .font_size = 14,
        .on_select = null,
    };
    defer {
        for (t.rows.items) |*r| r.deinit(alloc);
        t.rows.deinit(alloc);
    }

    try t.addRow(&.{ "a1", "b1", "c1" });
    try t.addRow(&.{ "a2", "b2", "c2" });

    try std.testing.expectEqual(@as(usize, 2), t.rows.items.len);
    try std.testing.expectEqualStrings("b2", t.rows.items[1].items[1]);
}
