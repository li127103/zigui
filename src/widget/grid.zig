//! Grid 控件 - 网格布局容器 (行 × 列)
//!
//! 子项通过 `addChild(child, row, col)` 放置到指定网格单元中。
//! 支持列/行独立扩展 (hexpand/vexpand)、跨距 (colspan/rowspan)、
//! 行间距和列间距。类似 GTK 的 GtkGrid。

const std = @import("std");
const math = @import("../math.zig");
const widget_mod = @import("widget.zig");
const layout_mod = @import("../layout/engine.zig");

const Widget = widget_mod.Widget;
const PaintContext = widget_mod.PaintContext;

const GridItem = struct {
    child: *Widget,
    row: usize,
    col: usize,
    row_span: usize = 1,
    col_span: usize = 1,
};

pub const Grid = struct {
    base: Widget,
    allocator: std.mem.Allocator,
    items: std.ArrayListUnmanaged(GridItem),
    rows: usize,
    cols: usize,
    row_gap: f32,
    col_gap: f32,
    padding: math.EdgeInsets,
    col_expand: std.DynamicBitSetUnmanaged,
    row_expand: std.DynamicBitSetUnmanaged,

    pub fn create(allocator: std.mem.Allocator, opts: struct {
        rows: usize = 1,
        cols: usize = 2,
        row_gap: f32 = 8,
        col_gap: f32 = 8,
        padding: math.EdgeInsets = .{},
        bg_color: ?math.Color = null,
        corner_radius: f32 = 0,
    }) !*Grid {
        const self = try allocator.create(Grid);
        self.* = .{
            .base = .{
                .vtable = &vtable,
                .id = widget_mod.genWidgetId(),
            },
            .allocator = allocator,
            .items = .{ .items = &.{}, .capacity = 0 },
            .rows = opts.rows,
            .cols = opts.cols,
            .row_gap = opts.row_gap,
            .col_gap = opts.col_gap,
            .padding = opts.padding,
            .col_expand = .{},
            .row_expand = .{},
        };
        try self.col_expand.resize(allocator, opts.cols, false);
        try self.row_expand.resize(allocator, opts.rows, false);
        if (opts.bg_color) |c| {
            self.base.background.bg = .{ .color = c };
        }
        self.base.background.corner_radius = opts.corner_radius;
        self.base.accessibility = .{ .role = .container };
        return self;
    }

    pub fn destroy(self: *Grid, allocator: std.mem.Allocator) void {
        for (self.items.items) |item| {
            item.child.vtable.destroy(item.child, allocator);
        }
        self.items.deinit(allocator);
        self.col_expand.deinit(allocator);
        self.row_expand.deinit(allocator);
        self.base.background.deinit(allocator);
        self.base.children.deinit(allocator);
        allocator.destroy(self);
    }

    /// 添加子控件到指定网格单元
    pub fn addChild(self: *Grid, child: *Widget, row: usize, col: usize) !void {
        try self.addChildWithSpan(child, row, col, .{});
    }

    /// 添加子控件到指定网格单元, 可指定跨行/跨列数
    pub fn addChildWithSpan(self: *Grid, child: *Widget, row: usize, col: usize, opts: struct {
        row_span: usize = 1,
        col_span: usize = 1,
    }) !void {
        try self.ensureSize(row + opts.row_span, col + opts.col_span);
        try self.items.append(self.allocator, .{
            .child = child,
            .row = row,
            .col = col,
            .row_span = opts.row_span,
            .col_span = opts.col_span,
        });
        try self.base.addChild(self.allocator, child);
    }

    /// 设置指定列是否水平扩展
    pub fn setColExpand(self: *Grid, col: usize, expand: bool) !void {
        try self.ensureSize(self.rows, @max(self.cols, col + 1));
        self.col_expand.setValue(col, expand);
        self.base.markLayoutDirty();
    }

    /// 设置指定行是否垂直扩展
    pub fn setRowExpand(self: *Grid, row: usize, expand: bool) !void {
        try self.ensureSize(@max(self.rows, row + 1), self.cols);
        self.row_expand.setValue(row, expand);
        self.base.markLayoutDirty();
    }

    /// 确保网格尺寸至少为 rows × cols
    fn ensureSize(self: *Grid, min_rows: usize, min_cols: usize) !void {
        if (min_cols > self.cols) {
            try self.col_expand.resize(self.allocator, min_cols, false);
            self.cols = min_cols;
        }
        if (min_rows > self.rows) {
            try self.row_expand.resize(self.allocator, min_rows, false);
            self.rows = min_rows;
        }
    }

    /// 设置网格尺寸
    pub fn setDimensions(self: *Grid, rows: usize, cols: usize) !void {
        try self.col_expand.resize(self.allocator, cols, false);
        try self.row_expand.resize(self.allocator, rows, false);
        self.rows = rows;
        self.cols = cols;
        self.base.markLayoutDirty();
    }

    /// 计算每列宽度和每行高度 (支持扩展和跨距)
    fn computeGridSizes(self: *Grid, ctx: *PaintContext) struct { col_widths: []f32, row_heights: []f32 } {
        const col_widths = self.allocator.alloc(f32, self.cols) catch return .{ .col_widths = &.{}, .row_heights = &.{} };
        const row_heights = self.allocator.alloc(f32, self.rows) catch return .{ .col_widths = col_widths, .row_heights = &.{} };
        @memset(col_widths, 0);
        @memset(row_heights, 0);

        const inner_w = self.base.rect.width - self.padding.left - self.padding.right;
        const inner_h = self.base.rect.height - self.padding.top - self.padding.bottom;

        // 第一轮: 计算不跨距的单元格最小尺寸
        for (self.items.items) |item| {
            if (!item.child.state.visible) continue;
            if (item.child.layout_style.position == .absolute) continue;
            if (item.row >= self.rows or item.col >= self.cols) continue;
            if (item.row_span != 1 or item.col_span != 1) continue;
            if (item.row + item.row_span > self.rows or item.col + item.col_span > self.cols) continue;

            const child_constraints = layout_mod.Constraints{
                .max_width = inner_w,
                .max_height = inner_h,
            };
            const child_size = item.child.vtable.measure(item.child, ctx, child_constraints);
            const cm = item.child.layout_style.margin;
            const total_w = child_size.width + cm.left + cm.right;
            const total_h = child_size.height + cm.top + cm.bottom;

            if (total_w > col_widths[item.col]) {
                col_widths[item.col] = total_w;
            }
            if (total_h > row_heights[item.row]) {
                row_heights[item.row] = total_h;
            }
        }

        // 第二轮: 处理跨距 (将跨距尺寸均匀分配给跨越的列/行)
        for (self.items.items) |item| {
            if (!item.child.state.visible) continue;
            if (item.child.layout_style.position == .absolute) continue;
            if (item.row >= self.rows or item.col >= self.cols) continue;
            if (item.row_span == 1 and item.col_span == 1) continue;
            if (item.row + item.row_span > self.rows or item.col + item.col_span > self.cols) continue;

            var cur_w: f32 = 0;
            var cur_h: f32 = 0;
            for (item.col..item.col + item.col_span) |c| {
                cur_w += col_widths[c];
            }
            cur_w += self.col_gap * @as(f32, @floatFromInt(item.col_span - 1));
            for (item.row..item.row + item.row_span) |r| {
                cur_h += row_heights[r];
            }
            cur_h += self.row_gap * @as(f32, @floatFromInt(item.row_span - 1));

            const child_constraints = layout_mod.Constraints{
                .max_width = @max(0, inner_w),
                .max_height = @max(0, inner_h),
            };
            const child_size = item.child.vtable.measure(item.child, ctx, child_constraints);
            const cm = item.child.layout_style.margin;
            const need_w = child_size.width + cm.left + cm.right;
            const need_h = child_size.height + cm.top + cm.bottom;

            if (need_w > cur_w and item.col_span > 1) {
                const extra = (need_w - cur_w) / @as(f32, @floatFromInt(item.col_span));
                for (item.col..item.col + item.col_span) |c| {
                    col_widths[c] += extra;
                }
            }
            if (need_h > cur_h and item.row_span > 1) {
                const extra = (need_h - cur_h) / @as(f32, @floatFromInt(item.row_span));
                for (item.row..item.row + item.row_span) |r| {
                    row_heights[r] += extra;
                }
            }
        }

        // 第三轮: 扩展列/行分配剩余空间
        // 统计当前总宽度/高度
        var total_min_w: f32 = 0;
        var total_min_h: f32 = 0;
        for (col_widths, 0..) |cw, i| {
            total_min_w += cw;
            if (i > 0) total_min_w += self.col_gap;
        }
        for (row_heights, 0..) |rh, i| {
            total_min_h += rh;
            if (i > 0) total_min_h += self.row_gap;
        }

        // 计算有多少扩展列/行
        var expand_col_count: usize = 0;
        var expand_row_count: usize = 0;
        for (0..self.cols) |c| {
            if (self.col_expand.isSet(c)) expand_col_count += 1;
        }
        for (0..self.rows) |r| {
            if (self.row_expand.isSet(r)) expand_row_count += 1;
        }

        // 分配剩余宽度给扩展列
        if (expand_col_count > 0 and inner_w > total_min_w) {
            const extra_per_col = (inner_w - total_min_w) / @as(f32, @floatFromInt(expand_col_count));
            for (0..self.cols) |c| {
                if (self.col_expand.isSet(c)) {
                    col_widths[c] += extra_per_col;
                }
            }
        }

        // 分配剩余高度给扩展行
        if (expand_row_count > 0 and inner_h > total_min_h) {
            const extra_per_row = (inner_h - total_min_h) / @as(f32, @floatFromInt(expand_row_count));
            for (0..self.rows) |r| {
                if (self.row_expand.isSet(r)) {
                    row_heights[r] += extra_per_row;
                }
            }
        }

        return .{ .col_widths = col_widths, .row_heights = row_heights };
    }

    // ── VTable ──────────────────────────────────────────────────────────────

    const vtable = Widget.VTable{
        .type_name = "grid",
        .measure = measure,
        .paint = paint,
        .on_event = null,
        .perform_layout = performLayout,
        .focusable = false,
        .destroy = destroyVTable,
    };

    fn destroyVTable(w: *Widget, allocator: std.mem.Allocator) void {
        const self: *Grid = @fieldParentPtr("base", w);
        self.destroy(allocator);
    }

    fn measure(w: *Widget, ctx: *PaintContext, constraints: layout_mod.Constraints) math.Size(f32) {
        const self: *Grid = @fieldParentPtr("base", w);

        const sizes = self.computeGridSizes(ctx);
        defer self.allocator.free(sizes.col_widths);
        defer self.allocator.free(sizes.row_heights);

        var total_w: f32 = self.padding.left + self.padding.right;
        var total_h: f32 = self.padding.top + self.padding.bottom;

        for (sizes.col_widths, 0..) |cw, i| {
            total_w += cw;
            if (i > 0) total_w += self.col_gap;
        }
        for (sizes.row_heights, 0..) |rh, i| {
            total_h += rh;
            if (i > 0) total_h += self.row_gap;
        }

        if (constraints.max_width < std.math.inf(f32) and total_w > constraints.max_width) {
            total_w = constraints.max_width;
        }
        if (constraints.max_height < std.math.inf(f32) and total_h > constraints.max_height) {
            total_h = constraints.max_height;
        }

        return .{ .width = total_w, .height = total_h };
    }

    fn paint(w: *Widget, ctx: *PaintContext) void {
        _ = w;
        _ = ctx;
    }

    fn performLayout(w: *Widget, ctx: *PaintContext) void {
        const self: *Grid = @fieldParentPtr("base", w);

        const sizes = self.computeGridSizes(ctx);
        defer self.allocator.free(sizes.col_widths);
        defer self.allocator.free(sizes.row_heights);

        // 计算列起始 x 坐标和行起始 y 坐标
        const col_x = self.allocator.alloc(f32, self.cols) catch return;
        defer self.allocator.free(col_x);
        const row_y = self.allocator.alloc(f32, self.rows) catch return;
        defer self.allocator.free(row_y);

        var x: f32 = self.padding.left;
        for (sizes.col_widths, 0..) |cw, i| {
            col_x[i] = x;
            x += cw + self.col_gap;
        }

        var y: f32 = self.padding.top;
        for (sizes.row_heights, 0..) |rh, i| {
            row_y[i] = y;
            y += rh + self.row_gap;
        }

        // 布局每个子项
        for (self.items.items) |item| {
            if (!item.child.state.visible) continue;
            if (item.child.layout_style.position == .absolute) continue;
            if (item.row >= self.rows or item.col >= self.cols) continue;
            if (item.row + item.row_span > self.rows or item.col + item.col_span > self.cols) continue;

            const cm = item.child.layout_style.margin;

            var cell_w: f32 = 0;
            var cell_h: f32 = 0;
            for (item.col..item.col + item.col_span) |c| {
                cell_w += sizes.col_widths[c];
            }
            cell_w += self.col_gap * @as(f32, @floatFromInt(item.col_span - 1));
            for (item.row..item.row + item.row_span) |r| {
                cell_h += sizes.row_heights[r];
            }
            cell_h += self.row_gap * @as(f32, @floatFromInt(item.row_span - 1));

            item.child.rect.x = col_x[item.col] + cm.left;
            item.child.rect.y = row_y[item.row] + cm.top;
            item.child.rect.width = cell_w - cm.left - cm.right;
            item.child.rect.height = cell_h - cm.top - cm.bottom;

            if (item.child.children.items.len > 0) {
                item.child.layoutSubtree(ctx);
            }
        }
    }
};

// ── Tests ──────────────────────────────────────────────────────────────────

test "grid create with default dimensions" {
    const g = try Grid.create(std.testing.allocator, .{});
    defer g.destroy(std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 1), g.rows);
    try std.testing.expectEqual(@as(usize, 2), g.cols);
}

test "grid setDimensions" {
    const g = try Grid.create(std.testing.allocator, .{ .rows = 2, .cols = 3 });
    defer g.destroy(std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 2), g.rows);
    try std.testing.expectEqual(@as(usize, 3), g.cols);

    try g.setDimensions(4, 5);
    try std.testing.expectEqual(@as(usize, 4), g.rows);
    try std.testing.expectEqual(@as(usize, 5), g.cols);
}

test "grid addChild expands dimensions" {
    const g = try Grid.create(std.testing.allocator, .{ .rows = 1, .cols = 1 });
    defer g.destroy(std.testing.allocator);

    const label_mod = @import("label.zig");
    const lbl = try label_mod.Label.create(std.testing.allocator, "test", .{});
    try g.addChild(&lbl.base, 3, 2);
    try std.testing.expectEqual(@as(usize, 4), g.rows);
    try std.testing.expectEqual(@as(usize, 3), g.cols);
}

test "grid default gaps" {
    const g = try Grid.create(std.testing.allocator, .{});
    defer g.destroy(std.testing.allocator);

    try std.testing.expectEqual(@as(f32, 8), g.row_gap);
    try std.testing.expectEqual(@as(f32, 8), g.col_gap);
}

test "grid custom gaps and padding" {
    const g = try Grid.create(std.testing.allocator, .{
        .row_gap = 16,
        .col_gap = 24,
        .padding = .{ .left = 10, .top = 20 },
    });
    defer g.destroy(std.testing.allocator);

    try std.testing.expectEqual(@as(f32, 16), g.row_gap);
    try std.testing.expectEqual(@as(f32, 24), g.col_gap);
    try std.testing.expectEqual(@as(f32, 10), g.padding.left);
    try std.testing.expectEqual(@as(f32, 20), g.padding.top);
}

test "grid col expand and row expand" {
    const g = try Grid.create(std.testing.allocator, .{ .rows = 2, .cols = 3 });
    defer g.destroy(std.testing.allocator);

    try g.setColExpand(1, true);
    try g.setRowExpand(0, true);

    try std.testing.expect(g.col_expand.isSet(1));
    try std.testing.expect(!g.col_expand.isSet(0));
    try std.testing.expect(g.row_expand.isSet(0));
    try std.testing.expect(!g.row_expand.isSet(1));
}
