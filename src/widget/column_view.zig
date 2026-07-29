//! ColumnView 控件 - GTK4 现代化列视图（表格）
//!
//! 支持多列、自定义列宽度、表头排序箭头、行选中/高亮、行激活、
//! 虚拟化滚动、斑马纹、可定制列渲染器。
//!
//! GTK4 对应: GtkColumnView
//!   - 支持 ListModel + SelectionModel + ListItemFactory (GTK4 模型层方式)
//!   - 也兼容旧的 rows (二维字符串) 直接 API
//!
//! 与旧 Table 的区别:
//! - 列可自定义渲染回调 (每个 cell 可渲染任意控件/颜色/图标)
//! - 选中高亮样式更现代 (蓝色圆角选中块)
//! - 表头 hover / 排序方向指示
//! - 单元格支持 widget 渲染 (不仅仅是字符串)

const std = @import("std");
const math = @import("../math.zig");
const widget_mod = @import("widget.zig");
const layout_mod = @import("../layout/engine.zig");
const pal = @import("../pal/pal.zig");
const styled_text = @import("../text/styled_text.zig");
const icons_mod = @import("icons.zig");
const list_mod = @import("../model/list_model.zig");
const sel_mod = @import("../model/selection_model.zig");
const fact_mod = @import("../model/list_item_factory.zig");
const expr_mod = @import("../model/expression.zig");
const Expression = expr_mod.Expression;

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

pub const SelectionMode = enum { none, single, browse };
pub const SortOrder = enum { ascending, descending, none };

pub const ColumnViewColumn = struct {
    title: []const u8,
    width: f32,
    expand: bool = false,
    fixed: bool = true,
    /// 用户是否可通过拖拽列右边缘调整宽度 (GTK4: GtkColumnViewColumn:resizable)
    resizable: bool = true,
    /// 最小/最大宽度 (resizable 时 clamp)
    min_width: f32 = 40,
    max_width: f32 = 10000,
    /// GTK4 风格: 列自带的 ListItemFactory (GtkColumnViewColumn: set_factory)
    factory: ?ListItemFactory = null,
    /// Expression (GTK4: GtkColumnViewColumn: set_expression)
    ///   - 点击表头排序时, 视图会用这个 Expression + ExpressionSorter 提示上层
    ///   - 也可被 cell renderer / ListItemFactory 直接调用抽取 cell 文本
    expression: ?Expression = null,
    /// 自定义 cell 渲染函数 (可选): (renderer, cell_rect, row_index, column_index, userdata)
    cell_renderer: ?*const fn (ctx: *PaintContext, rect: math.Rect, row: usize, col: usize, userdata: ?*anyopaque) void = null,
    /// 自定义渲染的 userdata
    userdata: ?*anyopaque = null,
};

pub const ColumnView = struct {
    base: Widget,
    allocator: Allocator,

    columns: std.ArrayListUnmanaged(ColumnViewColumn) = .{},
    columns_dup: std.ArrayListUnmanaged([]const u8) = .{}, // 列标题 dup 缓存

    /// ── 旧 API：行数据 (每行 cells 是字符串列表) ──
    rows: std.ArrayListUnmanaged(std.ArrayListUnmanaged([]const u8)) = .{},

    /// ── GTK4 模型层 API ──
    /// 关联的 ListModel (设置后，优先使用 model 取数据，不再用 rows)
    model: ?ListModel = null,
    /// 关联的 SelectionModel (设置后，选中状态由它管理)
    selection_model: ?*SelectionModel = null,
    /// 每列的 ListItemFactory (和 columns 一一对应)
    column_factories: std.ArrayListUnmanaged(?ListItemFactory) = .{},
    /// 列工厂的列缓存: setup 后产生的 ListItem (用于 paint 时 bind/unbind)
    _listitem_cache: std.AutoHashMapUnmanaged(usize, ListItem) = .{}, // key = row_idx

    selection_mode: SelectionMode = .single,
    selected_row: ?usize = null,
    hovered_row: ?usize = null,
    activated_row: ?usize = null,

    sort_column: ?usize = null,
    sort_order: SortOrder = .none,

    // 列宽拖拽
    drag_resize_col: ?usize = null,
    drag_start_mouse_x: f32 = 0,
    drag_start_col_width: f32 = 0,
    // 当前 hover 的列右边缘 (hover 时显示 resize 光标)
    hover_resize_col: ?usize = null,

    scroll_offset: f32 = 0,
    header_height: f32 = 40,
    row_height: f32 = 36,
    font_size: f32 = 14,

    on_row_selected: ?*const fn (self: *ColumnView, row: ?usize) void = null,
    on_row_activated: ?*const fn (self: *ColumnView, row: usize) void = null,
    on_column_clicked: ?*const fn (self: *ColumnView, col: usize) void = null,

    hovered_col: ?usize = null,

    // 样式
    bg_color: math.Color = math.Color.hex(0x0F172AFF),
    header_bg: math.Color = math.Color.hex(0x1E293BFF),
    header_hover_bg: math.Color = math.Color.hex(0x273449FF),
    header_text: math.Color = math.Color.hex(0x94A3B8FF),
    row_alt_bg: math.Color = math.Color.hex(0x162032FF),
    hover_bg: math.Color = math.Color.hex(0x334155CC),
    selected_bg: math.Color = math.Color.hex(0x3B82F655),
    selected_border: math.Color = math.Color.hex(0x3B82F6FF),
    text_color: math.Color = math.Color.hex(0xF8FAFCFF),
    grid_color: math.Color = math.Color.hex(0x1E293BFF),
    corner_radius: f32 = 10,
    cell_padding: f32 = 12,
    scrollbar_color: math.Color = math.Color.hex(0x475569FF),
    row_radius: f32 = 6, // 选中行的圆角

    last_click_row: ?usize = null,
    last_click_time: u64 = 0,

    pub fn new(allocator: Allocator, opts: struct {
        header_height: f32 = 40,
        row_height: f32 = 36,
        font_size: f32 = 14,
        selection_mode: SelectionMode = .single,
    }) !*ColumnView {
        const self = try allocator.create(ColumnView);
        self.* = .{
            .base = .{
                .vtable = &vtable,
                .id = widget_mod.genWidgetId(),
                .cursor = .default,
            },
            .allocator = allocator,
            .header_height = opts.header_height,
            .row_height = opts.row_height,
            .font_size = opts.font_size,
            .selection_mode = opts.selection_mode,
        };
        self.base.accessibility = .{ .role = .table, .label = "Column View" };
        return self;
    }

    pub fn destroy(self: *ColumnView, allocator: Allocator) void {
        self.base.background.deinit(allocator);
        // 清理旧 rows
        for (self.rows.items) |*r| r.deinit(allocator);
        self.rows.deinit(allocator);
        for (self.columns_dup.items) |t| allocator.free(t);
        self.columns_dup.deinit(allocator);
        self.columns.deinit(allocator);
        // 清理列工厂
        self.column_factories.deinit(allocator);
        // 清理 listitem 缓存 (teardown)
        var cache_it = self._listitem_cache.iterator();
        while (cache_it.next()) |entry| {
            var li = entry.value_ptr.*;
            // 尝试对所有列调用 teardown
            for (self.column_factories.items) |opt_factory| {
                if (opt_factory) |factory| {
                    factory.teardown(&li);
                }
            }
        }
        self._listitem_cache.deinit(allocator);
        self.base.children.deinit(allocator);
        allocator.destroy(self);
    }

    // ──────────────────────────────────────────────
    // GTK4 模型层 API
    // ──────────────────────────────────────────────

    /// 设置 ListModel (GtkColumnView: set_model)
    /// 设置后，视图会从 model 取数据，忽略旧的 rows API。
    pub fn setModel(self: *ColumnView, m: ?ListModel) void {
        self.model = m;
        self._clearListItemCache();
        self.base.markLayoutDirty();
        self.base.markDirty();
    }

    /// 设置 SelectionModel (GtkColumnView: set_model with selection)
    /// 同时会把 SelectionModel 内部的 backing model 作为 setModel。
    pub fn setSelectionModel(self: *ColumnView, sel: ?*SelectionModel) void {
        self.selection_model = sel;
        if (sel) |s| {
            // 自动同步 model
            self.model = s.model();
        }
        self._clearListItemCache();
        self.base.markDirty();
    }

    /// 给第 col 列设置 ListItemFactory
    pub fn setFactory(self: *ColumnView, col_idx: usize, factory: ?ListItemFactory) !void {
        while (self.column_factories.items.len <= col_idx) {
            try self.column_factories.append(self.allocator, null);
        }
        self.column_factories.items[col_idx] = factory;
        self._clearListItemCache();
        self.base.markDirty();
    }

    /// 设置指定列的 Expression (GTK4: gtk_column_view_column_set_expression)
    pub fn setColumnExpression(self: *ColumnView, col_idx: usize, expr: ?Expression) void {
        if (col_idx >= self.columns.items.len) return;
        self.columns.items[col_idx].expression = expr;
    }

    pub fn getColumnExpression(self: *const ColumnView, col_idx: usize) ?Expression {
        if (col_idx >= self.columns.items.len) return null;
        return self.columns.items[col_idx].expression;
    }

    /// 设置指定列可否拖拽调宽
    pub fn setColumnResizable(self: *ColumnView, col_idx: usize, v: bool) void {
        if (col_idx >= self.columns.items.len) return;
        self.columns.items[col_idx].resizable = v;
    }

    pub fn getColumnResizable(self: *const ColumnView, col_idx: usize) bool {
        if (col_idx >= self.columns.items.len) return false;
        return self.columns.items[col_idx].resizable;
    }

    /// 手动设置列宽 (clamp 到 min/max)
    pub fn setColumnWidth(self: *ColumnView, col_idx: usize, w: f32) void {
        if (col_idx >= self.columns.items.len) return;
        const c = &self.columns.items[col_idx];
        c.width = @max(c.min_width, @min(c.max_width, w));
        self.base.markLayoutDirty();
        self.base.markDirty();
    }

    pub fn getColumnWidth(self: *const ColumnView, col_idx: usize) f32 {
        if (col_idx >= self.columns.items.len) return 0;
        return self.columns.items[col_idx].width;
    }

    fn _clearListItemCache(self: *ColumnView) void {
        var it = self._listitem_cache.iterator();
        while (it.next()) |entry| {
            var li = entry.value_ptr.*;
            for (self.column_factories.items) |opt_f| {
                if (opt_f) |f| f.teardown(&li);
            }
        }
        self._listitem_cache.clearRetainingCapacity();
    }

    /// ── 数据访问 helper：优先 model，否则 rows ──
    fn effectiveRowCount(self: *const ColumnView) usize {
        if (self.model) |m| return m.nItems();
        return self.rows.items.len;
    }

    fn effectiveIsSelected(self: *ColumnView, row: usize) bool {
        if (self.selection_model) |sm| return sm.isSelected(row);
        if (self.selected_row) |s| return s == row;
        return false;
    }

    fn effectiveSelectRow(self: *ColumnView, row: usize) void {
        if (self.selection_model) |sm| {
            _ = sm.selectItem(row, true);
        } else {
            self.setSelectedRow(row);
            return;
        }
        // 走 SelectionModel 时，也同步旧字段（便于 paint 内部代码未改动的部分）
        self.selected_row = row;
        self.base.markDirty();
        if (self.on_row_selected) |cb| cb(self, row);
    }

    /// 追加列 (GtkColumnView: gtk_column_view_append_column)
    /// 若 col.factory 非空，会自动同步到列工厂列表
    pub fn appendColumn(self: *ColumnView, col: ColumnViewColumn) !void {
        const col_idx = self.columns.items.len;
        const title_dup = try self.allocator.dupe(u8, col.title);
        try self.columns.append(self.allocator, .{
            .title = title_dup,
            .width = col.width,
            .expand = col.expand,
            .fixed = col.fixed,
            .resizable = col.resizable,
            .min_width = col.min_width,
            .max_width = col.max_width,
            .factory = col.factory,
            .expression = col.expression,
            .cell_renderer = col.cell_renderer,
            .userdata = col.userdata,
        });
        try self.columns_dup.append(self.allocator, title_dup);
        // 同步列 factory
        while (self.column_factories.items.len <= col_idx) {
            try self.column_factories.append(self.allocator, null);
        }
        self.column_factories.items[col_idx] = col.factory;
        self._clearListItemCache();
        self.base.markLayoutDirty();
        self.base.markDirty();
    }

    pub fn removeAllColumns(self: *ColumnView) void {
        for (self.columns_dup.items) |t| self.allocator.free(t);
        self.columns_dup.clearRetainingCapacity();
        self.columns.clearRetainingCapacity();
        self.base.markLayoutDirty();
        self.base.markDirty();
    }

    pub fn addRow(self: *ColumnView, cells: []const []const u8) !void {
        var row: std.ArrayListUnmanaged([]const u8) = .{};
        for (cells) |cell| {
            const dup = try self.allocator.dupe(u8, cell);
            try row.append(self.allocator, dup);
        }
        try self.rows.append(self.allocator, row);
        self.base.markDirty();
    }

    pub fn addRowOwned(self: *ColumnView, row_cells: std.ArrayListUnmanaged([]const u8)) !void {
        try self.rows.append(self.allocator, row_cells);
        self.base.markDirty();
    }

    pub fn removeAllRows(self: *ColumnView) void {
        for (self.rows.items) |*r| {
            for (r.items) |cell| self.allocator.free(cell);
            r.deinit(self.allocator);
        }
        self.rows.clearRetainingCapacity();
        self.selected_row = null;
        self.hovered_row = null;
        self.base.markDirty();
    }

    pub fn rowCount(self: *const ColumnView) usize {
        return self.effectiveRowCount();
    }

    pub fn columnCount(self: *const ColumnView) usize {
        return self.columns.items.len;
    }

    pub fn setSelectedRow(self: *ColumnView, row: ?usize) void {
        if (self.selection_mode == .none) return;
        const total = self.effectiveRowCount();
        if (row) |r| {
            if (r >= total) return;
        }
        // 如果有 selection_model，同步写入
        if (self.selection_model) |sm| {
            if (row) |r| {
                _ = sm.selectItem(r, true);
            } else {
                _ = sm.unselectAll();
            }
        }
        self.selected_row = row;
        self.base.markDirty();
        if (self.on_row_selected) |cb| cb(self, self.selected_row);
    }

    pub fn getSelectedRow(self: *const ColumnView) ?usize {
        // 优先从 SelectionModel 读
        if (self.selection_model) |sm| {
            const total = self.effectiveRowCount();
            var i: usize = 0;
            while (i < total) : (i += 1) {
                if (sm.isSelected(i)) return i;
            }
            return null;
        }
        return self.selected_row;
    }

    /// 获取一行文本 (rows API 模式)。model 模式下用户应通过 factory bind 来处理。
    pub fn getRowCell(self: *const ColumnView, row: usize, col: usize) ?[]const u8 {
        if (self.model != null) return null; // model 模式不提供
        if (row >= self.rows.items.len) return null;
        const r = self.rows.items[row];
        if (col >= r.items.len) return null;
        return r.items[col];
    }

    /// 获取列 x 位置 + 宽度数组 (考虑 expand 列)
    fn getColumnLayout(self: *const ColumnView, view_w: f32) struct { xs: [64]f32, ws: [64]f32, count: usize } {
        var result: struct { xs: [64]f32, ws: [64]f32, count: usize } = .{
            .xs = [_]f32{0} ** 64,
            .ws = [_]f32{0} ** 64,
            .count = 0,
        };
        const n = @min(self.columns.items.len, 64);
        result.count = n;

        var fixed_total: f32 = 0;
        var expand_count: usize = 0;
        for (0..n) |i| {
            const c = self.columns.items[i];
            if (c.expand and !c.fixed) {
                expand_count += 1;
            } else {
                fixed_total += c.width;
            }
        }
        const expand_w = if (expand_count > 0 and view_w > fixed_total)
            (view_w - fixed_total) / @as(f32, @floatFromInt(expand_count))
        else
            0;

        var x: f32 = 0;
        for (0..n) |i| {
            const c = self.columns.items[i];
            const w = if (c.expand and !c.fixed) @max(c.width, expand_w) else c.width;
            result.xs[i] = x;
            result.ws[i] = w;
            x += w;
        }
        return result;
    }

    /// 返回 rel_x 是否落在可调整宽度的列的右边缘 (±4px 命中区域)，返回列 index 或 null
    fn findResizeEdge(self: *const ColumnView, cols: anytype, rel_x: f32) ?usize {
        const edge: f32 = 4;
        for (0..cols.count) |i| {
            if (!self.columns.items[i].resizable) continue;
            const right_x = cols.xs[i] + cols.ws[i];
            // 命中: right_x ± edge (但最右边一列的右边缘是控件边缘, 不允许调整)
            if (rel_x >= right_x - edge and rel_x < right_x + edge) {
                // 命中, 但排除最右边一列 (如果用户真的想调最后一列可以去掉限制, 这里和 GTK 对齐)
                // 最后一列不允许调整, 除非列总宽度 < 容器宽
                if (i + 1 < self.columns.items.len or i + 1 < cols.count) {
                    return i;
                }
                // 最后一列只有当左边还有剩余空间时允许 shrink, 简单起见返回
                return i;
            }
        }
        return null;
    }

    fn totalHeight(self: *ColumnView) f32 {
        return self.header_height + @as(f32, @floatFromInt(self.effectiveRowCount())) * self.row_height;
    }

    fn clampScroll(self: *ColumnView, view_h: f32) void {
        const content = self.totalHeight();
        const max_scroll = @max(0, content - view_h);
        self.scroll_offset = @max(0, @min(self.scroll_offset, max_scroll));
    }

    /// 内部: 获取或创建 listitem (cache)，绑定 data + selected
    fn _getOrBindListItem(self: *ColumnView, row_idx: usize) !ListItem {
        const gop = try self._listitem_cache.getOrPut(self.allocator, row_idx);
        if (!gop.found_existing) {
            gop.value_ptr.* = .{ .position = row_idx };
            // 对所有列 factory 执行 setup (若列工厂存在)
            var li = gop.value_ptr.*;
            for (self.column_factories.items) |opt_f| {
                if (opt_f) |f| f.setup(&li);
            }
            gop.value_ptr.* = li;
        }
        var li = gop.value_ptr.*;
        li.position = row_idx;
        if (self.model) |m| {
            li.item = if (m.iface.getItemFn(m.userdata, row_idx)) |p| p else null;
        }
        li.selected = self.effectiveIsSelected(row_idx);
        return li;
    }

    /// 取列的 ListItemFactory (若存在)
    fn _getColumnFactory(self: *const ColumnView, col_idx: usize) ?ListItemFactory {
        if (col_idx >= self.column_factories.items.len) return null;
        return self.column_factories.items[col_idx];
    }
};

const vtable = Widget.VTable{
    .type_name = "column_view",
    .measure = measure,
    .paint = paint,
    .on_event = onEvent,
    .focusable = true,
    .destroy = destroyVTable,
};

fn destroyVTable(w: *Widget, allocator: Allocator) void {
    const self: *ColumnView = @fieldParentPtr("base", w);
    self.destroy(allocator);
}

fn measure(w: *Widget, ctx: *PaintContext, constraints: layout_mod.Constraints) math.Size {
    const self: *ColumnView = @fieldParentPtr("base", w);
    var total_w: f32 = 0;
    const n = @min(self.columns.items.len, 64);
    for (0..n) |i| {
        total_w += self.columns.items[i].width;
    }
    const max_w = if (constraints.max_width < std.math.inf(f32)) constraints.max_width else 800;
    const max_h = if (constraints.max_height < std.math.inf(f32)) constraints.max_height else 500;
    _ = ctx;
    return .{
        .width = if (total_w > 0) @max(total_w, 200) else @min(max_w, 600),
        .height = @min(self.header_height + @max(2, 6) * self.row_height, max_h),
    };
}

fn paint(w: *Widget, ctx: *PaintContext) void {
    const self: *ColumnView = @fieldParentPtr("base", w);
    const rx = ctx.offset_x + w.rect.x;
    const ry = ctx.offset_y + w.rect.y;
    const rw = w.rect.width;
    const rh = w.rect.height;
    const alloc = ctx.allocator;
    const R = ctx.renderer;

    const cols = self.getColumnLayout(rw);
    self.clampScroll(rh - self.header_height);

    // 背景
    R.fillRoundedRect(.{ .x = rx, .y = ry, .width = rw, .height = rh }, self.corner_radius, self.bg_color) catch {};

    // 裁剪
    const saved = R.getClipRect();
    R.setClipRect(.{ .x = rx, .y = ry, .width = rw, .height = rh }) catch {};

    // ── 表头 ──
    const h_rect = math.Rect{ .x = rx, .y = ry, .width = rw, .height = self.header_height };
    R.fillRect(h_rect, self.header_bg, 0) catch {};
    // 顶部圆角覆盖
    R.fillRoundedRectPartial(h_rect, self.header_bg, self.corner_radius, .{
        .top_left = true,
        .top_right = true,
        .bottom_left = false,
        .bottom_right = false,
    }) catch {};

    var col_x: f32 = rx;
    for (0..cols.count) |i| {
        const c = self.columns.items[i];
        const cw = cols.ws[i];
        const hov = if (self.hovered_col) |hc| hc == i else false;
        if (hov) {
            R.fillRect(.{ .x = col_x, .y = ry, .width = cw, .height = self.header_height }, self.header_hover_bg, 0) catch {};
        }
        // 排序箭头
        const show_sort = if (self.sort_column) |sc| sc == i else false;
        var text_end_extra: f32 = 0;
        if (show_sort and self.sort_order != .none) {
            const sort_icon: icons_mod.IconName = if (self.sort_order == .ascending) icons_mod.IconName.chevron_up else icons_mod.IconName.chevron_down;
            const icon_w: f32 = 12;
            icons_mod.drawIcon(alloc, R, sort_icon, .{
                .x = col_x + cw - self.cell_padding - icon_w,
                .y = ry + (self.header_height - icon_w) / 2,
                .size = icon_w,
                .color = self.header_text,
            }) catch {};
            text_end_extra = icon_w + 4;
        }
        // 标题
        const ts = styled_text.measureText(alloc, c.title, .{ .font_size = self.font_size });
        const ty = ry + (self.header_height - ts.height) / 2;
        styled_text.drawText(ctx, c.title, .{
            .x = col_x + self.cell_padding,
            .y = ty,
            .color = self.header_text,
            .font_size = self.font_size,
            .max_width = cw - self.cell_padding * 2 - text_end_extra,
        });
        // 列分隔线
        if (i < cols.count - 1) {
            R.fillRect(.{
                .x = col_x + cw - 1,
                .y = ry + 8,
                .width = 1,
                .height = self.header_height - 16,
            }, self.grid_color, 0) catch {};
        }
        col_x += cw;
    }
    // 表头下分割线
    R.fillRect(.{
        .x = rx,
        .y = ry + self.header_height - 1,
        .width = rw,
        .height = 1,
    }, self.grid_color, 0) catch {};

    // ── 数据行 ──
    const view_top = ry + self.header_height;
    const view_h = rh - self.header_height;
    const n_rows = self.effectiveRowCount();

    const start_row_f = self.scroll_offset / self.row_height;
    const start_row_64: u64 = @intFromFloat(@floor(start_row_f));
    const view_per_row_f = @ceil(view_h / self.row_height);
    const vpr: u64 = @intFromFloat(view_per_row_f);
    const start_row: usize = @truncate(start_row_64);
    const end_row_calc = start_row + @as(usize, @truncate(vpr)) + 1;
    const end_row: usize = @min(n_rows, end_row_calc);

    for (start_row..end_row) |ri| {
        const rel_y = @as(f32, @floatFromInt(ri)) * self.row_height - self.scroll_offset;
        const row_top = view_top + rel_y;
        const row_bot = row_top + self.row_height;
        if (row_bot < view_top or row_top > view_top + view_h) continue;

        // 斑马纹
        const alt_bg = if (ri % 2 == 1) self.row_alt_bg else self.bg_color;
        if (alt_bg != self.bg_color) {
            R.fillRect(.{ .x = rx, .y = row_top, .width = rw, .height = self.row_height }, alt_bg, 0) catch {};
        }

        const is_hover = if (self.hovered_row) |hr| hr == ri else false;
        const is_sel = self.effectiveIsSelected(ri);

        // hover
        if (is_hover and !is_sel) {
            R.fillRoundedRect(.{
                .x = rx + 4,
                .y = row_top + 2,
                .width = rw - 8,
                .height = self.row_height - 4,
            }, self.row_radius, self.hover_bg) catch {};
        }
        // selected
        if (is_sel) {
            R.fillRoundedRect(.{
                .x = rx + 4,
                .y = row_top + 2,
                .width = rw - 8,
                .height = self.row_height - 4,
            }, self.row_radius, self.selected_bg) catch {};
            R.strokeRoundedRect(.{
                .x = rx + 4,
                .y = row_top + 2,
                .width = rw - 8,
                .height = self.row_height - 4,
            }, self.row_radius, 1, self.selected_border) catch {};
        }

        // cell 内容
        for (0..cols.count) |ci| {
            const cx = rx + cols.xs[ci];
            const cw = cols.ws[ci];
            const cell_rect = math.Rect{
                .x = cx,
                .y = row_top,
                .width = cw,
                .height = self.row_height,
            };
            const col = self.columns.items[ci];

            // 1) 列 factory: bind -> 自定义 paint userdata 模式 (简化：通过 cell_renderer)
            if (self._getColumnFactory(ci)) |factory| {
                var li = self._getOrBindListItem(ri) catch continue;
                factory.bind(&li);
                // bind 后 li.userdata 通常包含控件/渲染配置；但 ZigUI 的 PaintContext 是
                // 立即模式，用户可在 cell_renderer 中自行从 model.item 取数据。
            }

            if (col.cell_renderer) |renderer| {
                // 自定义渲染
                const inner = math.Rect{
                    .x = cx + self.cell_padding,
                    .y = row_top + 2,
                    .width = cw - self.cell_padding * 2,
                    .height = self.row_height - 4,
                };
                renderer(ctx, inner, ri, ci, col.userdata);
            } else {
                // 默认文本渲染
                const tc: math.Color = if (is_sel) math.Color.hex(0xFFFFFFFF) else self.text_color;
                if (self.model) |m| {
                    // model 模式: 简单地把 item 指针当字符串指针显示 (用户如需要自行用 cell_renderer)
                    const raw = m.iface.getItemFn(m.userdata, ri);
                    if (raw) |p| {
                        // 尝试当 *[]const u8 读
                        const as_bytes: *[]const u8 = @ptrCast(@alignCast(p));
                        const ts = styled_text.measureText(alloc, as_bytes.*, .{ .font_size = self.font_size });
                        const ty = row_top + (self.row_height - ts.height) / 2;
                        styled_text.drawText(ctx, as_bytes.*, .{
                            .x = cx + self.cell_padding,
                            .y = ty,
                            .color = tc,
                            .font_size = self.font_size,
                            .max_width = cw - self.cell_padding * 2,
                        });
                        continue;
                    }
                    // 没拿到，退回到空文本
                    const ts = styled_text.measureText(alloc, "", .{ .font_size = self.font_size });
                    const ty = row_top + (self.row_height - ts.height) / 2;
                    styled_text.drawText(ctx, "", .{
                        .x = cx + self.cell_padding,
                        .y = ty,
                        .color = tc,
                        .font_size = self.font_size,
                        .max_width = cw - self.cell_padding * 2,
                    });
                } else {
                    const txt = self.getRowCell(ri, ci) orelse "";
                    const ts = styled_text.measureText(alloc, txt, .{ .font_size = self.font_size });
                    const ty = row_top + (self.row_height - ts.height) / 2;
                    styled_text.drawText(ctx, txt, .{
                        .x = cx + self.cell_padding,
                        .y = ty,
                        .color = tc,
                        .font_size = self.font_size,
                        .max_width = cw - self.cell_padding * 2,
                    });
                }
                _ = cell_rect;
            }
        }
    }

    // ── 滚动条 ──
    const content = @max(1, self.totalHeight() - self.header_height);
    if (view_h < content) {
        const track_h = view_h;
        const bar_h = track_h * (view_h / content);
        const max_scroll = content - view_h;
        const bar_y = view_top + (self.scroll_offset / max_scroll) * (track_h - bar_h);
        const bar_w: f32 = 6;
        const bar_x = rx + rw - bar_w - 2;
        R.fillRoundedRect(.{
            .x = bar_x,
            .y = bar_y,
            .width = bar_w,
            .height = bar_h,
        }, 3, self.scrollbar_color) catch {};
    }

    // 恢复 clip
    if (saved) |s| R.setClipRect(s) catch {};
    // 边框
    R.strokeRoundedRect(.{ .x = rx, .y = ry, .width = rw, .height = rh }, self.corner_radius, 1, self.grid_color) catch {};
}

fn onEvent(w: *Widget, event: *const Event, ectx: *EventContext) EventResult {
    const self: *ColumnView = @fieldParentPtr("base", w);
    const abs_rect = w.absoluteRect();

    switch (event.*) {
        .scroll => |s| {
            const mx: f32 = @floatFromInt(s.axis == .vertical); // suppress unused
            _ = mx;
            const view_h = abs_rect.height - self.header_height;
            const delta_pix = s.delta * self.row_height * 3;
            if (s.axis == .vertical) {
                self.scroll_offset -= delta_pix;
                self.clampScroll(view_h);
                self.base.markDirty();
                return .handled;
            }
        },
        .mouse_move => |m| {
            const mx: f32 = @floatFromInt(m.x);
            const my: f32 = @floatFromInt(m.y);
            const rel_x = mx - abs_rect.x;
            const rel_y = my - abs_rect.y;

            // 1. 正在拖拽列宽
            if (self.drag_resize_col) |ci| {
                const delta = mx - self.drag_start_mouse_x;
                var new_w = self.drag_start_col_width + delta;
                const c = &self.columns.items[ci];
                new_w = @max(c.min_width, @min(c.max_width, new_w));
                if (new_w != c.width) {
                    c.width = new_w;
                    self.base.markLayoutDirty();
                    self.base.markDirty();
                }
                // 拖拽期间不触发其他 hover
                return .handled;
            }

            // 2. 列宽边缘 hover (设置 resize 光标)
            var new_hover_resize: ?usize = null;
            if (rel_y >= 0 and rel_y < abs_rect.height and rel_x >= 0 and rel_x < abs_rect.width) {
                // 任何 y 位置都可以抓列边缘 (GTK 风格)
                const cols = self.getColumnLayout(abs_rect.width);
                new_hover_resize = self.findResizeEdge(cols, rel_x);
            }
            if (new_hover_resize != self.hover_resize_col) {
                self.hover_resize_col = new_hover_resize;
                // 切换光标: resize_ew / default
                w.setCursor(if (new_hover_resize != null) .resize_ew else .default);
                w.markDirty();
            }
            if (self.hover_resize_col != null) {
                // 光标悬停在边缘上不触发列/行 hover
                return .handled;
            }

            // 3. 表头 hover
            if (rel_y >= 0 and rel_y < self.header_height and rel_x >= 0 and rel_x < abs_rect.width) {
                const cols = self.getColumnLayout(abs_rect.width);
                var found: ?usize = null;
                for (0..cols.count) |i| {
                    if (rel_x >= cols.xs[i] and rel_x < cols.xs[i] + cols.ws[i]) {
                        found = i;
                        break;
                    }
                }
                if (found != self.hovered_col) {
                    self.hovered_col = found;
                    w.markDirty();
                }
            } else if (self.hovered_col != null) {
                self.hovered_col = null;
                w.markDirty();
            }

            // 行 hover
            if (rel_y >= self.header_height and rel_y < abs_rect.height and rel_x >= 0 and rel_x < abs_rect.width) {
                const row_y = rel_y - self.header_height + self.scroll_offset;
                const ri: usize = @intFromFloat(@floor(row_y / self.row_height));
                if (ri < self.effectiveRowCount()) {
                    if (self.hovered_row != ri) {
                        self.hovered_row = ri;
                        w.markDirty();
                    }
                    return .handled;
                }
            }
            if (self.hovered_row != null) {
                self.hovered_row = null;
                w.markDirty();
            }
        },
        .mouse_button => |mb| {
            if (mb.button == .left) {
                const mx: f32 = @floatFromInt(mb.x);
                const my: f32 = @floatFromInt(mb.y);
                const rel_x = mx - abs_rect.x;
                const rel_y = my - abs_rect.y;
                const inside = rel_x >= 0 and rel_x < abs_rect.width and rel_y >= 0 and rel_y < abs_rect.height;

                // 1. 先处理列宽拖拽 release: 任何位置 release 都结束拖拽
                if (mb.state == .released) {
                    if (self.drag_resize_col != null) {
                        self.drag_resize_col = null;
                        return .handled;
                    }
                    if (!inside) return .ignored;
                }

                if (!inside) return .ignored;

                if (mb.state == .pressed) {
                    // 2. 若 hover_resize_col != null, 开始拖拽列宽
                    if (self.hover_resize_col) |ci| {
                        self.drag_resize_col = ci;
                        self.drag_start_mouse_x = mx;
                        self.drag_start_col_width = self.columns.items[ci].width;
                        return .handled;
                    }

                    // 3. 表头点击
                    if (rel_y < self.header_height) {
                        const cols = self.getColumnLayout(abs_rect.width);
                        // 先检测是否点击在列右边缘 (但还没 hover 到, 保险)
                        if (self.findResizeEdge(cols, rel_x)) |ci| {
                            self.drag_resize_col = ci;
                            self.drag_start_mouse_x = mx;
                            self.drag_start_col_width = self.columns.items[ci].width;
                            return .handled;
                        }
                        for (0..cols.count) |i| {
                            if (rel_x >= cols.xs[i] and rel_x < cols.xs[i] + cols.ws[i]) {
                                // 切换排序
                                if (self.sort_column) |sc| {
                                    if (sc == i) {
                                        self.sort_order = if (self.sort_order == .ascending) .descending else .ascending;
                                    } else {
                                        self.sort_column = i;
                                        self.sort_order = .ascending;
                                    }
                                } else {
                                    self.sort_column = i;
                                    self.sort_order = .ascending;
                                }
                                if (self.on_column_clicked) |cb| cb(self, i);
                                w.markDirty();
                                return .handled;
                            }
                        }
                        return .handled;
                    }

                    // 4. 行点击
                    const row_y = rel_y - self.header_height + self.scroll_offset;
                    const ri_f = @floor(row_y / self.row_height);
                    if (ri_f < 0 or ri_f >= @as(f32, @floatFromInt(self.effectiveRowCount()))) return .ignored;
                    const ri: usize = @intFromFloat(ri_f);
                    const now_ts = std.time.milliTimestamp();
                    const now_u: u64 = @intCast(if (now_ts < 0) 0 else now_ts);

                    // 双击检测
                    if (self.last_click_row) |lr| {
                        if (lr == ri and now_u - self.last_click_time < 350) {
                            self.activated_row = ri;
                            self.last_click_row = null;
                            self.last_click_time = 0;
                            if (self.on_row_activated) |cb| cb(self, ri);
                            return .handled;
                        }
                    }
                    self.last_click_row = ri;
                    self.last_click_time = now_u;

                    if (self.selection_mode == .single or self.selection_mode == .browse) {
                        self.setSelectedRow(ri);
                    }
                    return .handled;
                }
            }
        },
        .key => |k| {
            if (k.state == .pressed) {
                const total_r = self.effectiveRowCount();
                const cur = self.getSelectedRow();
                if (k.key == .up) {
                    if (cur) |sr| {
                        if (sr > 0) self.setSelectedRow(sr - 1);
                    } else if (total_r > 0) {
                        self.setSelectedRow(total_r - 1);
                    }
                    return .handled;
                }
                if (k.key == .down) {
                    if (cur) |sr| {
                        if (sr + 1 < total_r) self.setSelectedRow(sr + 1);
                    } else if (total_r > 0) {
                        self.setSelectedRow(0);
                    }
                    return .handled;
                }
                if (k.key == .home and total_r > 0) {
                    self.setSelectedRow(0);
                    return .handled;
                }
                if (k.key == .end and total_r > 0) {
                    self.setSelectedRow(total_r - 1);
                    return .handled;
                }
                if (k.key == .space or k.key == .enter or k.key == .kp_enter) {
                    if (cur) |sr| {
                        if (self.on_row_activated) |cb| cb(self, sr);
                    }
                    return .handled;
                }
            }
            _ = ectx;
        },
        else => {},
    }
    return .ignored;
}
