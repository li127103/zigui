//! GTK3→GTK4 兼容传统树模型：TreeModel + TreeStore + ListStore
//!
//! GTK 对应: GtkTreeModel / GtkTreeStore / GtkListStore / GtkTreeIter / GtkTreePath / GValue
//!
//! 适用场景：旧版 TreeView 数据适配；在 GTK4 中仍可使用并与 ColumnView/ListView 并存。
//!
//! 核心抽象：
//! - TreePath   : []u32，从根到目标行的索引序列（例: [0, 2] = 第一个根节点下的第 3 个子节点）
//! - TreeIter   : 轻量迭代器（stamp + 3 个 user_data 指针），由 TreeModel 实现内部解释
//! - GValue     : tagged union 保存各种类型单元格值
//! - TreeModel  : 接口（TreeModelIface + self*），提供 get_iter/get_value/iter_children 等
//! - ListStore  : 扁平表格（N 列 × M 行）
//! - TreeStore  : 分层树模型

const std = @import("std");
const math = @import("../math.zig");

// ──────────────────────────────────────────────────────────────────────────────
// GValue — 通用单元格值
// ──────────────────────────────────────────────────────────────────────────────

pub const GType = enum(u8) {
    invalid = 0,
    string = 1,
    int_ = 2,
    uint = 3,
    bool_ = 4,
    float_ = 5,
    pointer = 6,
    color = 7,
};

pub const GValue = union(GType) {
    invalid: void,
    string: []const u8,
    int_: i64,
    uint: u64,
    bool_: bool,
    float_: f64,
    pointer: ?*anyopaque,
    color: math.Color,

    pub fn ofString(s: []const u8) GValue {
        return .{ .string = s };
    }
    pub fn ofI64(v: i64) GValue {
        return .{ .int_ = v };
    }
    pub fn ofU64(v: u64) GValue {
        return .{ .uint = v };
    }
    pub fn ofBool(v: bool) GValue {
        return .{ .bool_ = v };
    }
    pub fn ofF64(v: f64) GValue {
        return .{ .float_ = v };
    }
    pub fn ofPtr(p: ?*anyopaque) GValue {
        return .{ .pointer = p };
    }
    pub fn ofColor(c: math.Color) GValue {
        return .{ .color = c };
    }

    pub fn getString(self: *const GValue) []const u8 {
        return if (self.* == .string) self.string else "";
    }
    pub fn getInt(self: *const GValue) i64 {
        return switch (self.*) {
            .int_ => self.int_,
            .uint => @intCast(self.uint),
            .float_ => @intFromFloat(self.float_),
            .bool_ => if (self.bool_) 1 else 0,
            else => 0,
        };
    }
    pub fn getBool(self: *const GValue) bool {
        return switch (self.*) {
            .bool_ => self.bool_,
            .int_ => self.int_ != 0,
            .uint => self.uint != 0,
            .pointer => self.pointer != null,
            else => false,
        };
    }
    pub fn getFloat(self: *const GValue) f64 {
        return switch (self.*) {
            .float_ => self.float_,
            .int_ => @floatFromInt(self.int_),
            .uint => @floatFromInt(self.uint),
            else => 0.0,
        };
    }
};

// ──────────────────────────────────────────────────────────────────────────────
// TreePath / TreeIter
// ──────────────────────────────────────────────────────────────────────────────

/// TreePath — 从根到目标行的索引序列
///
/// 例:
///  `&[_]u32 { 0 }`         — 第 1 个根节点
///  `&[_]u32 { 0, 2 }`      — 第 1 个根节点的第 3 个子节点
pub const TreePath = struct {
    indices: std.ArrayListUnmanaged(u32) = .empty,

    pub fn init() TreePath {
        return .{};
    }

    pub fn initFromSlice(alloc: std.mem.Allocator, slice: []const u32) !TreePath {
        var p = TreePath{};
        try p.indices.appendSlice(alloc, slice);
        return p;
    }

    pub fn deinit(self: *TreePath, alloc: std.mem.Allocator) void {
        self.indices.deinit(alloc);
    }

    pub fn depth(self: *const TreePath) u32 {
        return @intCast(self.indices.items.len);
    }

    pub fn up(self: *TreePath) bool {
        if (self.indices.items.len == 0) return false;
        self.indices.items.len -= 1;
        return true;
    }

    pub fn down(self: *TreePath, alloc: std.mem.Allocator) !void {
        try self.indices.append(alloc, 0);
    }

    pub fn next(self: *TreePath) bool {
        if (self.indices.items.len == 0) return false;
        self.indices.items[self.indices.items.len - 1] += 1;
        return true;
    }

    pub fn prev(self: *TreePath) bool {
        if (self.indices.items.len == 0) return false;
        const n = &self.indices.items[self.indices.items.len - 1];
        if (n.* == 0) return false;
        n.* -= 1;
        return true;
    }

    pub fn appendIndex(self: *TreePath, alloc: std.mem.Allocator, i: u32) !void {
        try self.indices.append(alloc, i);
    }

    pub fn toString(self: *const TreePath, alloc: std.mem.Allocator) ![]const u8 {
        if (self.indices.items.len == 0) return try alloc.dupe(u8, "0");
        var result: []const u8 = "";
        for (self.indices.items, 0..) |idx, i| {
            const n_str = try std.fmt.allocPrint(alloc, "{}{}", .{ if (i > 0) ":" else "", idx });
            defer alloc.free(n_str);
            const new_result = try std.mem.concat(alloc, u8, &.{ result, n_str });
            if (result.len > 0) alloc.free(result);
            result = new_result;
        }
        return result;
    }
};

/// TreeIter — 轻量行迭代器；由 TreeModel 解释 stamp 和 user_data 含义
pub const TreeIter = struct {
    stamp: c_int = 0,
    user_data: ?*anyopaque = null,
    user_data2: ?*anyopaque = null,
    user_data3: ?*anyopaque = null,

    pub fn isValid(self: *const TreeIter) bool {
        return self.stamp != 0 or self.user_data != null;
    }

    pub fn reset(self: *TreeIter) void {
        self.stamp = 0;
        self.user_data = null;
        self.user_data2 = null;
        self.user_data3 = null;
    }
};

// ──────────────────────────────────────────────────────────────────────────────
// TreeModelIface + TreeModel（接口对象）
// ──────────────────────────────────────────────────────────────────────────────

pub const TreeModelFlags = packed struct(u8) {
    iters_persist: bool = false,
    list_only: bool = false,
    _pad: u6 = 0,
};

pub const TreeModelIface = struct {
    get_flags: *const fn (self: ?*anyopaque) TreeModelFlags = defaultGetFlags,
    get_n_columns: *const fn (self: ?*anyopaque) u32 = defaultGetNColumns,
    get_column_type: *const fn (self: ?*anyopaque, col: u32) GType = defaultGetColumnType,
    get_iter: *const fn (self: ?*anyopaque, iter: *TreeIter, path: *const TreePath) bool = defaultGetIter,
    get_path: *const fn (self: ?*anyopaque, iter: *const TreeIter, alloc: std.mem.Allocator) ?TreePath = defaultGetPath,
    get_value: *const fn (self: ?*anyopaque, iter: *const TreeIter, col: u32, value: *GValue) void = defaultGetValue,
    iter_next: *const fn (self: ?*anyopaque, iter: *TreeIter) bool = defaultIterNext,
    iter_children: *const fn (self: ?*anyopaque, iter: *TreeIter, parent: ?*const TreeIter) bool = defaultIterChildren,
    iter_has_child: *const fn (self: ?*anyopaque, iter: *const TreeIter) bool = defaultIterHasChild,
    iter_n_children: *const fn (self: ?*anyopaque, iter: ?*const TreeIter) u32 = defaultIterNChildren,
    iter_nth_child: *const fn (self: ?*anyopaque, iter: *TreeIter, parent: ?*const TreeIter, n: u32) bool = defaultIterNthChild,
    iter_parent: *const fn (self: ?*anyopaque, iter: *TreeIter, child: *const TreeIter) bool = defaultIterParent,
    ref_node: ?*const fn (self: ?*anyopaque, iter: *const TreeIter) void = null,
    unref_node: ?*const fn (self: ?*anyopaque, iter: *const TreeIter) void = null,

    fn defaultGetFlags(_: ?*anyopaque) TreeModelFlags {
        return .{};
    }
    fn defaultGetNColumns(_: ?*anyopaque) u32 {
        return 0;
    }
    fn defaultGetColumnType(_: ?*anyopaque, _col: u32) GType {
        _ = _col;
        return .invalid;
    }
    fn defaultGetIter(_: ?*anyopaque, _iter: *TreeIter, _path: *const TreePath) bool {
        _ = _iter;
        _ = _path;
        return false;
    }
    fn defaultGetPath(_: ?*anyopaque, _iter: *const TreeIter, _alloc: std.mem.Allocator) ?TreePath {
        _ = _iter;
        _ = _alloc;
        return null;
    }
    fn defaultGetValue(_: ?*anyopaque, _iter: *const TreeIter, _col: u32, _value: *GValue) void {
        _ = _iter;
        _ = _col;
        _value.* = .invalid;
    }
    fn defaultIterNext(_: ?*anyopaque, _iter: *TreeIter) bool {
        _ = _iter;
        return false;
    }
    fn defaultIterChildren(_: ?*anyopaque, _iter: *TreeIter, _parent: ?*const TreeIter) bool {
        _ = _iter;
        _ = _parent;
        return false;
    }
    fn defaultIterHasChild(_: ?*anyopaque, _iter: *const TreeIter) bool {
        _ = _iter;
        return false;
    }
    fn defaultIterNChildren(_: ?*anyopaque, _iter: ?*const TreeIter) u32 {
        _ = _iter;
        return 0;
    }
    fn defaultIterNthChild(_: ?*anyopaque, _iter: *TreeIter, _parent: ?*const TreeIter, _n: u32) bool {
        _ = _iter;
        _ = _parent;
        _ = _n;
        return false;
    }
    fn defaultIterParent(_: ?*anyopaque, _iter: *TreeIter, _child: *const TreeIter) bool {
        _ = _iter;
        _ = _child;
        return false;
    }
};

/// 类型擦除 TreeModel：持有 iface + self 指针，可被 TreeView 等通用消费
pub const TreeModel = struct {
    iface: TreeModelIface,
    self: ?*anyopaque = null,

    pub fn asModel(self: anytype) TreeModel {
        const T = @TypeOf(self.*);
        return .{
            .iface = T.MODEL_IFACE,
            .self = @ptrCast(@alignCast(self)),
        };
    }

    // 便捷转发
    pub fn getFlags(m: *const TreeModel) TreeModelFlags {
        return m.iface.get_flags(m.self);
    }
    pub fn getNColumns(m: *const TreeModel) u32 {
        return m.iface.get_n_columns(m.self);
    }
    pub fn getColumnType(m: *const TreeModel, col: u32) GType {
        return m.iface.get_column_type(m.self, col);
    }
    pub fn getIter(m: *const TreeModel, iter: *TreeIter, path: *const TreePath) bool {
        return m.iface.get_iter(m.self, iter, path);
    }
    pub fn getPath(m: *const TreeModel, iter: *const TreeIter, alloc: std.mem.Allocator) ?TreePath {
        return m.iface.get_path(m.self, iter, alloc);
    }
    pub fn getValue(m: *const TreeModel, iter: *const TreeIter, col: u32, value: *GValue) void {
        m.iface.get_value(m.self, iter, col, value);
    }
    pub fn iterNext(m: *const TreeModel, iter: *TreeIter) bool {
        return m.iface.iter_next(m.self, iter);
    }
    pub fn iterChildren(m: *const TreeModel, iter: *TreeIter, parent: ?*const TreeIter) bool {
        return m.iface.iter_children(m.self, iter, parent);
    }
    pub fn iterHasChild(m: *const TreeModel, iter: *const TreeIter) bool {
        return m.iface.iter_has_child(m.self, iter);
    }
    pub fn iterNChildren(m: *const TreeModel, iter: ?*const TreeIter) u32 {
        return m.iface.iter_n_children(m.self, iter);
    }
    pub fn iterNthChild(m: *const TreeModel, iter: *TreeIter, parent: ?*const TreeIter, n: u32) bool {
        return m.iface.iter_nth_child(m.self, iter, parent, n);
    }
    pub fn iterParent(m: *const TreeModel, iter: *TreeIter, child: *const TreeIter) bool {
        return m.iface.iter_parent(m.self, iter, child);
    }
};

// ──────────────────────────────────────────────────────────────────────────────
// ListStore — 扁平表格（N 列 × M 行）
// ──────────────────────────────────────────────────────────────────────────────

const ListStoreRow = struct {
    cells: std.ArrayListUnmanaged(GValue),
};

pub const ListStore = struct {
    allocator: std.mem.Allocator,
    columns: std.ArrayListUnmanaged(GType),
    rows: std.ArrayListUnmanaged(ListStoreRow),
    stamp: c_int = 1,

    const Self = @This();

    pub fn create(allocator: std.mem.Allocator, column_types: []const GType) !*Self {
        const self = try allocator.create(Self);
        self.* = .{
            .allocator = allocator,
            .columns = .empty,
            .rows = .empty,
        };
        try self.columns.appendSlice(allocator, column_types);
        return self;
    }

    pub fn destroy(self: *Self) void {
        for (self.rows.items) |*row| {
            row.cells.deinit(self.allocator);
        }
        self.rows.deinit(self.allocator);
        self.columns.deinit(self.allocator);
        self.allocator.destroy(self);
    }

    pub fn getNColumns(self: *const Self) u32 {
        return @intCast(self.columns.items.len);
    }

    pub fn append(self: *Self, iter: *TreeIter) void {
        const idx: u32 = @intCast(self.rows.items.len);
        var row: ListStoreRow = .{ .cells = .empty };
        row.cells.appendNTimes(self.allocator, .invalid, self.columns.items.len) catch {};
        self.rows.append(self.allocator, row) catch {};
        iter.stamp = self.stamp;
        iter.user_data = @ptrFromInt(idx | 0x8000_0000); // 设置标记，表示 ListStore 迭代
        iter.user_data2 = null;
    }

    pub fn remove(self: *Self, iter: *TreeIter) bool {
        if (iter.stamp != self.stamp) return false;
        const raw = @intFromPtr(iter.user_data orelse return false);
        if (raw & 0x8000_0000 == 0) return false;
        const idx: u32 = @intCast(raw & 0x7FFF_FFFF);
        if (idx >= self.rows.items.len) return false;
        self.rows.items[idx].cells.deinit(self.allocator);
        self.rows.orderedRemove(idx);
        iter.reset();
        self.stamp +%= 1;
        return true;
    }

    pub fn clear(self: *Self) void {
        for (self.rows.items) |*row| {
            row.cells.deinit(self.allocator);
        }
        self.rows.deinit(self.allocator);
        self.stamp +%= 1;
    }

    pub fn setValue(self: *Self, iter: *const TreeIter, col: u32, value: GValue) void {
        if (iter.stamp != self.stamp) return;
        const raw = @intFromPtr(iter.user_data orelse return);
        if (raw & 0x8000_0000 == 0) return;
        const idx: u32 = @intCast(raw & 0x7FFF_FFFF);
        if (idx >= self.rows.items.len or col >= self.columns.items.len) return;
        self.rows.items[idx].cells.items[col] = value;
    }

    pub fn getValue(self: *const Self, iter: *const TreeIter, col: u32) GValue {
        if (iter.stamp != self.stamp) return .invalid;
        const raw = @intFromPtr(iter.user_data orelse return .invalid);
        if (raw & 0x8000_0000 == 0) return .invalid;
        const idx: u32 = @intCast(raw & 0x7FFF_FFFF);
        if (idx >= self.rows.items.len or col >= self.columns.items.len) return .invalid;
        return self.rows.items[idx].cells.items[col];
    }

    // ── 便捷：多列 set / get ────────────────────────────────────────────────

    pub fn set(self: *Self, iter: *const TreeIter, tuple: anytype) void {
        const info = @typeInfo(@TypeOf(tuple)).@"struct";
        inline for (info.fields, 0..) |field, i| {
            const col: u32 = @intCast(i);
            const raw = @field(tuple, field.name);
            const V = @TypeOf(raw);
            const gv: GValue = switch (@typeInfo(V)) {
                .pointer => blk: {
                    if (comptime @import("std").meta.trait.isZigString(V)) {
                        break :blk GValue.str(raw);
                    }
                    break :blk GValue.ptr(raw);
                },
                .array => blk: {
                    const s: []const u8 = &raw;
                    break :blk GValue.str(s);
                },
                .bool => GValue.bool(raw),
                .int => blk: {
                    const I = @typeInfo(V).int;
                    if (I.signedness == .signed) break :blk GValue.int(raw);
                    break :blk GValue.uint(raw);
                },
                .float => GValue.float(raw),
                else => GValue.invalid,
            };
            self.setValue(iter, col, gv);
        }
    }

    // ── TreeModelIface vtable ───────────────────────────────────────────────

    fn ifaceGetFlags(_: ?*anyopaque) TreeModelFlags {
        return .{ .iters_persist = true, .list_only = true };
    }
    fn ifaceGetNColumns(s: ?*anyopaque) u32 {
        const self: *Self = @ptrCast(@alignCast(s orelse return 0));
        return self.getNColumns();
    }
    fn ifaceGetColumnType(s: ?*anyopaque, col: u32) GType {
        const self: *Self = @ptrCast(@alignCast(s orelse return .invalid));
        if (col >= self.columns.items.len) return .invalid;
        return self.columns.items[col];
    }
    fn ifaceGetIter(s: ?*anyopaque, iter: *TreeIter, path: *const TreePath) bool {
        const self: *Self = @ptrCast(@alignCast(s orelse return false));
        if (path.indices.items.len != 1) return false;
        const idx = path.indices.items[0];
        if (idx >= self.rows.items.len) return false;
        iter.stamp = self.stamp;
        iter.user_data = @ptrFromInt(@as(usize, idx) | 0x8000_0000);
        iter.user_data2 = null;
        return true;
    }
    fn ifaceGetPath(s: ?*anyopaque, iter: *const TreeIter, alloc: std.mem.Allocator) ?TreePath {
        const self: *Self = @ptrCast(@alignCast(s orelse return null));
        if (iter.stamp != self.stamp) return null;
        const raw = @intFromPtr(iter.user_data orelse return null);
        if (raw & 0x8000_0000 == 0) return null;
        const idx: u32 = @intCast(raw & 0x7FFF_FFFF);
        if (idx >= self.rows.items.len) return null;
        var p = TreePath.init();
        p.indices.append(alloc, idx) catch return null;
        return p;
    }
    fn ifaceGetValue(s: ?*anyopaque, iter: *const TreeIter, col: u32, value: *GValue) void {
        const self: *Self = @ptrCast(@alignCast(s orelse return));
        value.* = self.getValue(iter, col);
    }
    fn ifaceIterNext(s: ?*anyopaque, iter: *TreeIter) bool {
        const self: *Self = @ptrCast(@alignCast(s orelse return false));
        if (iter.stamp != self.stamp) return false;
        const raw = @intFromPtr(iter.user_data orelse return false);
        if (raw & 0x8000_0000 == 0) return false;
        const idx: u32 = @intCast(raw & 0x7FFF_FFFF);
        const next_idx = idx + 1;
        if (next_idx >= self.rows.items.len) return false;
        iter.user_data = @ptrFromInt(@as(usize, next_idx) | 0x8000_0000);
        return true;
    }
    fn ifaceIterChildren(s: ?*anyopaque, iter: *TreeIter, parent: ?*const TreeIter) bool {
        const self: *Self = @ptrCast(@alignCast(s orelse return false));
        // ListStore 扁平模型，根层有 children；parent 非 null 时没有
        if (parent != null) return false;
        if (self.rows.items.len == 0) return false;
        iter.stamp = self.stamp;
        iter.user_data = @ptrFromInt(0x8000_0000);
        return true;
    }
    fn ifaceIterHasChild(_: ?*anyopaque, iter: ?*const TreeIter) bool {
        // ListStore 只有根层有数据；行本身没有 child
        _ = iter;
        return false;
    }
    fn ifaceIterNChildren(s: ?*anyopaque, iter: ?*const TreeIter) u32 {
        const self: *Self = @ptrCast(@alignCast(s orelse return 0));
        if (iter == null) return @intCast(self.rows.items.len);
        return 0;
    }
    fn ifaceIterNthChild(s: ?*anyopaque, iter: *TreeIter, parent: ?*const TreeIter, n: u32) bool {
        const self: *Self = @ptrCast(@alignCast(s orelse return false));
        if (parent != null) return false;
        if (n >= self.rows.items.len) return false;
        iter.stamp = self.stamp;
        iter.user_data = @ptrFromInt(@as(usize, n) | 0x8000_0000);
        return true;
    }
    fn ifaceIterParent(_: ?*anyopaque, _iter: *TreeIter, _child: *const TreeIter) bool {
        _ = _iter;
        _ = _child;
        return false;
    }

    pub const MODEL_IFACE: TreeModelIface = .{
        .get_flags = ifaceGetFlags,
        .get_n_columns = ifaceGetNColumns,
        .get_column_type = ifaceGetColumnType,
        .get_iter = ifaceGetIter,
        .get_path = ifaceGetPath,
        .get_value = ifaceGetValue,
        .iter_next = ifaceIterNext,
        .iter_children = ifaceIterChildren,
        .iter_has_child = ifaceIterHasChild,
        .iter_n_children = ifaceIterNChildren,
        .iter_nth_child = ifaceIterNthChild,
        .iter_parent = ifaceIterParent,
    };
};

// ──────────────────────────────────────────────────────────────────────────────
// TreeStore — 分层树模型
// ──────────────────────────────────────────────────────────────────────────────

const TreeStoreNode = struct {
    cells: std.ArrayListUnmanaged(GValue),
    children: std.ArrayListUnmanaged(*TreeStoreNode),
    parent: ?*TreeStoreNode = null,
    index_in_parent: u32 = 0,
};

pub const TreeStore = struct {
    allocator: std.mem.Allocator,
    columns: std.ArrayListUnmanaged(GType),
    roots: std.ArrayListUnmanaged(*TreeStoreNode),
    stamp: c_int = 1,

    const Self = @This();

    pub fn create(allocator: std.mem.Allocator, column_types: []const GType) !*Self {
        const self = try allocator.create(Self);
        self.* = .{
            .allocator = allocator,
            .columns = .empty,
            .roots = .empty,
        };
        try self.columns.appendSlice(allocator, column_types);
        return self;
    }

    fn destroyNode(self: *Self, node: *TreeStoreNode) void {
        for (node.children.items) |c| self.destroyNode(c);
        node.children.deinit(self.allocator);
        node.cells.deinit(self.allocator);
        self.allocator.destroy(node);
    }

    pub fn destroy(self: *Self) void {
        for (self.roots.items) |r| self.destroyNode(r);
        self.roots.deinit(self.allocator);
        self.columns.deinit(self.allocator);
        self.allocator.destroy(self);
    }

    pub fn getNColumns(self: *const Self) u32 {
        return @intCast(self.columns.items.len);
    }

    fn newNode(self: *Self) !*TreeStoreNode {
        const n = try self.allocator.create(TreeStoreNode);
        n.* = .{ .cells = .empty, .children = .empty };
        try n.cells.appendNTimes(self.allocator, .invalid, self.columns.items.len);
        return n;
    }

    /// 在 parent 下追加新行；parent=null 表示在根层追加。返回迭代器。
    pub fn append(self: *Self, parent: ?*TreeIter, iter: *TreeIter) void {
        const n = self.newNode() catch return;
        if (parent) |p| {
            if (p.stamp == self.stamp and p.user_data != null) {
                const p_node: *TreeStoreNode = @ptrCast(@alignCast(p.user_data orelse return));
                n.index_in_parent = @intCast(p_node.children.items.len);
                n.parent = p_node;
                p_node.children.append(self.allocator, n) catch return;
            } else {
                // parent 无效 — 回退到 root
                n.index_in_parent = @intCast(self.roots.items.len);
                self.roots.append(self.allocator, n) catch return;
            }
        } else {
            n.index_in_parent = @intCast(self.roots.items.len);
            self.roots.append(self.allocator, n) catch return;
        }
        iter.stamp = self.stamp;
        iter.user_data = @ptrCast(@alignCast(n));
    }

    pub fn remove(self: *Self, iter: *TreeIter) bool {
        if (iter.stamp != self.stamp) return false;
        const node: *TreeStoreNode = @ptrCast(@alignCast(iter.user_data orelse return false));
        // 从父或根层移除
        if (node.parent) |p| {
            const i = node.index_in_parent;
            if (i < p.children.items.len) {
                p.children.orderedRemove(i);
                for (p.children.items[i..], i..) |*c, idx| {
                    c.index_in_parent = idx;
                }
            }
        } else {
            const i = node.index_in_parent;
            if (i < self.roots.items.len) {
                self.roots.orderedRemove(i);
                for (self.roots.items[i..], i..) |*c, idx| {
                    c.index_in_parent = idx;
                }
            }
        }
        self.destroyNode(node);
        iter.reset();
        self.stamp +%= 1;
        return true;
    }

    pub fn setValue(self: *Self, iter: *const TreeIter, col: u32, value: GValue) void {
        if (iter.stamp != self.stamp) return;
        const node: *TreeStoreNode = @ptrCast(@alignCast(iter.user_data orelse return));
        if (col >= self.columns.items.len) return;
        node.cells.items[col] = value;
    }

    pub fn getValue(self: *const Self, iter: *const TreeIter, col: u32) GValue {
        if (iter.stamp != self.stamp) return .invalid;
        const node: *TreeStoreNode = @ptrCast(@alignCast(iter.user_data orelse return .invalid));
        if (col >= self.columns.items.len) return .invalid;
        return node.cells.items[col];
    }

    pub fn set(self: *Self, iter: *const TreeIter, tuple: anytype) void {
        const info = @typeInfo(@TypeOf(tuple)).@"struct";
        inline for (info.fields, 0..) |field, i| {
            const col: u32 = @intCast(i);
            const raw = @field(tuple, field.name);
            const V = @TypeOf(raw);
            const gv: GValue = switch (@typeInfo(V)) {
                .pointer => blk: {
                    if (comptime @import("std").meta.trait.isZigString(V)) break :blk GValue.str(raw);
                    break :blk GValue.ptr(raw);
                },
                .array => blk: {
                    const s: []const u8 = &raw;
                    break :blk GValue.str(s);
                },
                .bool => GValue.bool(raw),
                .int => blk: {
                    const I = @typeInfo(V).int;
                    if (I.signedness == .signed) break :blk GValue.int(raw);
                    break :blk GValue.uint(raw);
                },
                .float => GValue.float(raw),
                else => GValue.invalid,
            };
            self.setValue(iter, col, gv);
        }
    }

    pub fn isAncestor(self: *const Self, iter: *const TreeIter, descendant: *const TreeIter) bool {
        _ = self;
        if (iter.stamp != descendant.stamp) return false;
        const a: *TreeStoreNode = @ptrCast(@alignCast(iter.user_data orelse return false));
        var d: ?*TreeStoreNode = @ptrCast(@alignCast(descendant.user_data orelse return false));
        while (d) |n| : (d = n.parent) {
            if (n == a) return true;
        }
        return false;
    }

    pub fn iterDepth(self: *const Self, iter: *const TreeIter) u32 {
        _ = self;
        const node: *TreeStoreNode = @ptrCast(@alignCast(iter.user_data orelse return 0));
        var depth_v: u32 = 0;
        var p: ?*TreeStoreNode = node.parent;
        while (p) |n| : (p = n.parent) depth_v += 1;
        return depth_v;
    }

    // ── TreeModelIface vtable ───────────────────────────────────────────────

    fn ifaceGetFlags(_: ?*anyopaque) TreeModelFlags {
        return .{ .iters_persist = true };
    }
    fn ifaceGetNColumns(s: ?*anyopaque) u32 {
        const self: *Self = @ptrCast(@alignCast(s orelse return 0));
        return self.getNColumns();
    }
    fn ifaceGetColumnType(s: ?*anyopaque, col: u32) GType {
        const self: *Self = @ptrCast(@alignCast(s orelse return .invalid));
        if (col >= self.columns.items.len) return .invalid;
        return self.columns.items[col];
    }
    fn ifaceGetIter(s: ?*anyopaque, iter: *TreeIter, path: *const TreePath) bool {
        const self: *Self = @ptrCast(@alignCast(s orelse return false));
        if (path.indices.items.len == 0) return false;
        const first = path.indices.items[0];
        if (first >= self.roots.items.len) return false;
        var node: *TreeStoreNode = self.roots.items[first];
        for (path.indices.items[1..]) |child_idx| {
            if (child_idx >= node.children.items.len) return false;
            node = node.children.items[child_idx];
        }
        iter.stamp = self.stamp;
        iter.user_data = @ptrCast(@alignCast(node));
        return true;
    }
    fn ifaceGetPath(s: ?*anyopaque, iter: *const TreeIter, alloc: std.mem.Allocator) ?TreePath {
        const self: *Self = @ptrCast(@alignCast(s orelse return null));
        if (iter.stamp != self.stamp) return null;
        const node: *TreeStoreNode = @ptrCast(@alignCast(iter.user_data orelse return null));
        var p = TreePath.init();
        var cur: ?*TreeStoreNode = node;
        while (cur) |n| : (cur = n.parent) {
            var tmp_list = std.ArrayListUnmanaged(u32){ .items = p.indices.items, .capacity = p.indices.capacity };
            tmp_list.insert(alloc, 0, n.index_in_parent) catch return null;
            p.indices = tmp_list;
        }
        return p;
    }
    fn ifaceGetValue(s: ?*anyopaque, iter: *const TreeIter, col: u32, value: *GValue) void {
        const self: *Self = @ptrCast(@alignCast(s orelse return));
        value.* = self.getValue(iter, col);
    }
    fn ifaceIterNext(s: ?*anyopaque, iter: *TreeIter) bool {
        const self: *Self = @ptrCast(@alignCast(s orelse return false));
        if (iter.stamp != self.stamp) return false;
        const node: *TreeStoreNode = @ptrCast(@alignCast(iter.user_data orelse return false));
        const next_idx = node.index_in_parent + 1;
        if (node.parent) |p| {
            if (next_idx >= p.children.items.len) return false;
            const n = p.children.items[next_idx];
            iter.user_data = @ptrCast(@alignCast(n));
            return true;
        } else {
            if (next_idx >= self.roots.items.len) return false;
            const n = self.roots.items[next_idx];
            iter.user_data = @ptrCast(@alignCast(n));
            return true;
        }
    }
    fn ifaceIterChildren(s: ?*anyopaque, iter: *TreeIter, parent: ?*const TreeIter) bool {
        const self: *Self = @ptrCast(@alignCast(s orelse return false));
        if (parent == null) {
            if (self.roots.items.len == 0) return false;
            iter.stamp = self.stamp;
            iter.user_data = @ptrCast(@alignCast(self.roots.items[0]));
            return true;
        } else |p| {
            if (p.stamp != self.stamp) return false;
            const p_node: *TreeStoreNode = @ptrCast(@alignCast(p.user_data orelse return false));
            if (p_node.children.items.len == 0) return false;
            iter.stamp = self.stamp;
            iter.user_data = @ptrCast(@alignCast(p_node.children.items[0]));
            return true;
        }
    }
    fn ifaceIterHasChild(s: ?*anyopaque, iter: *const TreeIter) bool {
        const self: *Self = @ptrCast(@alignCast(s orelse return false));
        if (iter.stamp != self.stamp) return false;
        const node: *TreeStoreNode = @ptrCast(@alignCast(iter.user_data orelse return false));
        return node.children.items.len > 0;
    }
    fn ifaceIterNChildren(s: ?*anyopaque, iter: ?*const TreeIter) u32 {
        const self: *Self = @ptrCast(@alignCast(s orelse return 0));
        if (iter == null) return @intCast(self.roots.items.len);
        if (iter.?.stamp != self.stamp) return 0;
        const node: *TreeStoreNode = @ptrCast(@alignCast(iter.?.user_data orelse return 0));
        return @intCast(node.children.items.len);
    }
    fn ifaceIterNthChild(s: ?*anyopaque, iter: *TreeIter, parent: ?*const TreeIter, n: u32) bool {
        const self: *Self = @ptrCast(@alignCast(s orelse return false));
        if (parent == null) {
            if (n >= self.roots.items.len) return false;
            iter.stamp = self.stamp;
            iter.user_data = @ptrCast(@alignCast(self.roots.items[n]));
            return true;
        } else |p| {
            if (p.stamp != self.stamp) return false;
            const p_node: *TreeStoreNode = @ptrCast(@alignCast(p.user_data orelse return false));
            if (n >= p_node.children.items.len) return false;
            iter.stamp = self.stamp;
            iter.user_data = @ptrCast(@alignCast(p_node.children.items[n]));
            return true;
        }
    }
    fn ifaceIterParent(s: ?*anyopaque, iter: *TreeIter, child: *const TreeIter) bool {
        const self: *Self = @ptrCast(@alignCast(s orelse return false));
        if (child.stamp != self.stamp) return false;
        const c_node: *TreeStoreNode = @ptrCast(@alignCast(child.user_data orelse return false));
        const p_node = c_node.parent orelse return false;
        iter.stamp = self.stamp;
        iter.user_data = @ptrCast(@alignCast(p_node));
        return true;
    }

    pub const MODEL_IFACE: TreeModelIface = .{
        .get_flags = ifaceGetFlags,
        .get_n_columns = ifaceGetNColumns,
        .get_column_type = ifaceGetColumnType,
        .get_iter = ifaceGetIter,
        .get_path = ifaceGetPath,
        .get_value = ifaceGetValue,
        .iter_next = ifaceIterNext,
        .iter_children = ifaceIterChildren,
        .iter_has_child = ifaceIterHasChild,
        .iter_n_children = ifaceIterNChildren,
        .iter_nth_child = ifaceIterNthChild,
        .iter_parent = ifaceIterParent,
    };
};
