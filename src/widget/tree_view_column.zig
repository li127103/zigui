//! TreeViewColumn — GTK3 GtkTreeView 的列定义
//!
//! 每个列 = 标题区域 + 若干 CellRenderer（CellAreaBox 容纳）
//! 支持列头点击排序（显示 ▲▼）、可调整大小、可重排、属性绑定（列号→CellRenderer 属性）。
//!

const std = @import("std");
const math = @import("../math.zig");
const cell_mod = @import("cell_renderer.zig");
pub const CellAreaBox = cell_mod.CellAreaBox;
pub const CellRenderer = cell_mod.CellRenderer;
const RectI = math.Rect(i32);
const RectF = math.Rect(f32);

const ColumnSizing = enum(u2) { grow_only, autosize, fixed };
const SortOrder = enum(u1) { ascending, descending };
const SelectionMode = enum(u2) { none, single, browse, multiple };

/// 属性绑定：TreeModel 列号 → CellRenderer 的属性名（如 "text"/"foreground"/"active"/"value"）
/// 真实 TreeView 渲染时，根据绑定把 TreeModel 的 GValue 赋给对应 CellRenderer 属性
pub const AttributeBinding = struct {
    column: i32,            // TreeModel 列号
    renderer: ?*CellRenderer,
    attr: []const u8,       // 属性名字符串，如 "text" / "active" / "pixbuf" / "value" / "foreground"
};

pub const TreeViewColumn = struct {
    allocator: std.mem.Allocator,

    // 列头
    title: []const u8 = "",
    owned_title: bool = false,

    // 排序
    sort_column_id: i32 = -1, // -1 = 不可排序
    sort_indicator: bool = false,
    sort_order: SortOrder = .ascending,

    // 交互
    clickable: bool = true,
    resizable: bool = true,
    reorderable: bool = false,
    expand: bool = false,

    // 尺寸
    sizing: ColumnSizing = .autosize,
    fixed_width: i32 = -1,
    min_width: i32 = 20,
    max_width: i32 = 100_000,
    spacing: u4 = 2,
    alignment: f32 = 0.0, // 0=左 1=右 0.5=中

    // 布局实时结果
    x_offset: i32 = 0,
    width: i32 = 120,

    // 内部渲染器 + 属性绑定
    area: CellAreaBox = CellAreaBox.init(),
    attributes: std.ArrayListUnmanaged(AttributeBinding) = .{},

    // 回调
    on_clicked: ?*const fn (ud: ?*anyopaque, col: *TreeViewColumn) void = null,
    on_clicked_ud: ?*anyopaque = null,

    const Self = @This();

    pub fn create(allocator: std.mem.Allocator, title: []const u8) !*Self {
        const self = try allocator.create(Self);
        const title_c = try allocator.dupe(u8, title);
        self.* = .{ .allocator = allocator, .title = title_c, .owned_title = true };
        return self;
    }

    pub fn destroy(self: *Self) void {
        const a = self.allocator;
        if (self.owned_title) a.free(self.title);
        self.area.deinit(a);
        self.attributes.deinit(a);
        a.destroy(self);
    }

    // ── 渲染器管理 ───────────────────────────────────────────────────────

    pub fn packStart(self: *Self, cell: *CellRenderer, expand: bool, fixed_align: bool, padding: f32) !void {
        try self.area.packStart(self.allocator, cell, expand, fixed_align, padding);
    }
    pub fn packEnd(self: *Self, cell: *CellRenderer, expand: bool, fixed_align: bool, padding: f32) !void {
        try self.area.packEnd(self.allocator, cell, expand, fixed_align, padding);
    }

    // ── 属性绑定 ─────────────────────────────────────────────────────────

    /// 添加一个属性绑定：TreeModel column → renderer.attr
    pub fn addAttribute(self: *Self, renderer: *CellRenderer, attr_name: []const u8, column: i32) !void {
        try self.attributes.append(self.allocator, .{
            .column = column,
            .renderer = renderer,
            .attr = attr_name,
        });
    }

    // ── 排序 UI ──────────────────────────────────────────────────────────

    pub fn setSortColumnId(self: *Self, id: i32) void { self.sort_column_id = id; self.clickable = (id >= 0); }
    pub fn setSortIndicator(self: *Self, visible: bool, order: SortOrder) void {
        self.sort_indicator = visible;
        self.sort_order = order;
    }

    /// 用户点击列头 → 切换方向 & 触发 on_clicked
    pub fn clicked(self: *Self) void {
        if (!self.clickable) return;
        if (self.sort_indicator) {
            self.sort_order = switch (self.sort_order) {
                .ascending => .descending,
                .descending => .ascending,
            };
        } else {
            self.sort_indicator = true;
            self.sort_order = .ascending;
        }
        if (self.on_clicked) |cb| cb(self.on_clicked_ud, self);
    }

    // ── 几何 ─────────────────────────────────────────────────────────────

    /// 获取列标题在 TreeView 中的全局矩形（x_offset 为相对 TreeView 内容区）
    pub fn headerRect(self: *const Self, header_h: i32) RectI {
        return .{ .x = self.x_offset, .y = 0, .width = self.width, .height = header_h };
    }

    /// 获取单元格几何（相对整行 rect；row_rect.y + 行高）
    pub fn cellAreaRect(self: *const Self, row_y: i32, row_height: i32) RectF {
        return .{
            .x = @floatFromInt(self.x_offset),
            .y = @floatFromInt(row_y),
            .width = @floatFromInt(self.width),
            .height = @floatFromInt(row_height),
        };
    }
};
