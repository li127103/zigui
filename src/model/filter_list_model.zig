//! Filter + FilterListModel — 列表过滤模型 (对标 GtkFilter + GtkFilterListModel)
//!
//! 通过 Filter 对源 ListModel 进行筛选，得到过滤后的视图。
//! 支持:
//!   - CustomFilter   — 用户自定义 match 闭包
//!   - StringFilter   — 按字符串包含关系过滤
//!   - MultiFilter    — 多 filter 组合 (ALL/ANY)
//!   - FilterListModel — 实现 ListModelIface，可被 ColumnView/GridView/SelectionModel 消费
//!
//! 典型用法:
//! ```
//! var store = try m.StringListStore.new(alloc, &.{"apple","banana","apricot"});
//! var flt = try m.CustomFilter.create(alloc, struct {
//!     fn matchFn(userdata: ?*anyopaque, item: ?*anyopaque) bool {
//!         _ = userdata;
//!         const s = @as(*[]const u8, @ptrCast(@alignCast(item orelse return false))).*;
//!         return std.mem.startsWith(u8, s, "a");
//!     }
//! }.matchFn, null);
//! var list = try m.FilterListModel.create(alloc, store.model(), flt.filter());
//! // list.model() 现在只包含 "apple" 和 "apricot"
//! ```

const std = @import("std");
const Allocator = std.mem.Allocator;
const list_model = @import("list_model.zig");
const ListModel = list_model.ListModel;
const ListModelIface = list_model.ListModelIface;
const ItemsChangedFn = list_model.ItemsChangedFn;
const expression_mod = @import("expression.zig");
const Expression = expression_mod.Expression;
const Value = expression_mod.Value;

// ═══════════════════════════════════════════════════════════════════════════
// Filter 接口胖指针
// ═══════════════════════════════════════════════════════════════════════════

/// GTK4: GtkFilterChange - 过滤器变更类型
pub const FilterChange = enum {
    /// 过滤行为完全不同，需重新评估所有 item
    differ,
    /// 过滤更严格（之前通过的现在可能不通过）
    more_strict,
    /// 过滤更宽松（之前不通过的现在可能通过）
    less_strict,
};

pub const FilterMatchFn = *const fn (userdata: ?*anyopaque, item: ?*anyopaque) bool;

pub const Filter = struct {
    matchFn: FilterMatchFn,
    userdata: ?*anyopaque = null,

    /// 判断单个 item 是否匹配
    pub fn match(self: Filter, item: ?*anyopaque) bool {
        return self.matchFn(self.userdata, item);
    }
};

// ═══════════════════════════════════════════════════════════════════════════
// CustomFilter — 包装任意 match 函数
// ═══════════════════════════════════════════════════════════════════════════

pub const CustomFilter = struct {
    f: Filter,

    pub fn create(allocator: Allocator, match_fn: FilterMatchFn, userdata: ?*anyopaque) !*CustomFilter {
        const self = try allocator.create(CustomFilter);
        self.* = .{ .f = .{ .matchFn = match_fn, .userdata = userdata } };
        return self;
    }

    pub fn destroy(self: *CustomFilter, allocator: Allocator) void {
        allocator.destroy(self);
    }

    pub fn filter(self: *CustomFilter) Filter {
        return self.f;
    }
};

// ═══════════════════════════════════════════════════════════════════════════
// StringFilter — 按字符串匹配过滤（大小写可选）
// ═══════════════════════════════════════════════════════════════════════════

pub const StringFilterMatchMode = enum { contains, prefix, suffix, equals };

pub const StringFilter = struct {
    allocator: Allocator,
    search: []const u8 = "",
    owned_search: []const u8 = "",
    ignore_case: bool = true,
    mode: StringFilterMatchMode = .contains,
    /// 如何从 item 中提取字符串：默认把 item 当作 *[]const u8
    stringifyFn: ?*const fn (item: ?*anyopaque) []const u8 = null,
    /// Expression 抽取 (优先使用, 若设置则取 evaluate().string)
    expression: ?Expression = null,
    f: Filter = .{ .matchFn = matchFunc },

    const Self = @This();

    pub fn create(allocator: Allocator, opts: struct {
        search: []const u8 = "",
        ignore_case: bool = true,
        mode: StringFilterMatchMode = .contains,
        stringifyFn: ?*const fn (item: ?*anyopaque) []const u8 = null,
        expression: ?Expression = null,
    }) !*Self {
        const owned = try allocator.dupe(u8, opts.search);
        const self = try allocator.create(Self);
        self.* = .{
            .allocator = allocator,
            .search = owned,
            .owned_search = owned,
            .ignore_case = opts.ignore_case,
            .mode = opts.mode,
            .stringifyFn = opts.stringifyFn,
            .expression = opts.expression,
        };
        self.f.userdata = self;
        return self;
    }

    pub fn destroy(self: *Self) void {
        self.allocator.free(self.owned_search);
        self.allocator.destroy(self);
    }

    /// 设置搜索字符串，自动 dup
    pub fn setSearch(self: *Self, search: []const u8) void {
        self.allocator.free(self.owned_search);
        self.owned_search = self.allocator.dupe(u8, search) catch self.owned_search;
        self.search = self.owned_search;
    }

    pub fn setExpression(self: *Self, expr: ?Expression) void {
        self.expression = expr;
    }

    pub fn filter(self: *Self) Filter {
        return self.f;
    }

    fn matchFunc(userdata: ?*anyopaque, item: ?*anyopaque) bool {
        const self: *Self = @ptrCast(@alignCast(userdata orelse return true));
        if (self.search.len == 0) return true; // 空搜索=全通过
        const str: []const u8 = if (self.expression) |*expr| blk: {
            const v = expr.evaluate(item);
            break :blk switch (v) {
                .string => |s| s,
                .int => |x| blk2: {
                    break :blk2 intToTempBuf(@floatFromInt(x));
                },
                .uint => |x| blk2: {
                    break :blk2 intToTempBuf(@floatFromInt(x));
                },
                .float => |x| blk2: {
                    break :blk2 intToTempBuf(x);
                },
                .bool_ => |b| if (b) "true" else "false",
                .none => return true,
            };
        } else if (self.stringifyFn) |sf| sf(item) else blk: {
            const p: *[]const u8 = @ptrCast(@alignCast(item orelse return false));
            break :blk p.*;
        };
        const hay = if (self.ignore_case) toLowerTemp(str) else str;
        const needle = if (self.ignore_case) toLowerTemp(self.search) else self.search;
        if (needle.len == 0) return true;
        return switch (self.mode) {
            .contains => std.mem.indexOf(u8, hay, needle) != null,
            .prefix => std.mem.startsWith(u8, hay, needle),
            .suffix => std.mem.endsWith(u8, hay, needle),
            .equals => std.mem.eql(u8, hay, needle),
        };
    }

    // 线程不安全的临时小写（栈/全局缓冲区），仅用于比较，不跨调用保留
    fn toLowerTemp(s: []const u8) []const u8 {
        // 简单实现：如果全是小写直接返回，否则用 TLS buffer
        const TlsBuf = struct {
            threadlocal var buf: [4096]u8 = undefined;
        };
        if (s.len > TlsBuf.buf.len) return s; // 太长直接用原串 (不完美但安全)
        for (s, 0..) |c, i| {
            TlsBuf.buf[i] = std.ascii.toLower(c);
        }
        return TlsBuf.buf[0..s.len];
    }

    fn intToTempBuf(x: f32) []const u8 {
        const TlsBuf2 = struct {
            threadlocal var buf: [64]u8 = undefined;
        };
        const formatted = std.fmt.bufPrint(&TlsBuf2.buf, "{d:.2}", .{x}) catch return "0";
        return formatted;
    }
};

// ═══════════════════════════════════════════════════════════════════════════
// BoolFilter — 按 Expression 的 bool 值过滤 (对标 GtkBoolFilter)
// ═══════════════════════════════════════════════════════════════════════════

pub const BoolFilter = struct {
    /// 从 item 中抽取 bool
    expression: Expression,
    /// true = 反向匹配 (bool == false 时通过)
    invert: bool = false,
    f: Filter = .{ .matchFn = matchFunc },

    const Self = @This();

    pub fn create(allocator: Allocator, opts: struct {
        expression: Expression,
        invert: bool = false,
    }) !*Self {
        const self = try allocator.create(Self);
        self.* = .{
            .expression = opts.expression,
            .invert = opts.invert,
        };
        self.f.userdata = self;
        return self;
    }

    pub fn destroy(self: *Self, allocator: Allocator) void {
        allocator.destroy(self);
    }

    pub fn setExpression(self: *Self, expr: Expression) void {
        self.expression = expr;
    }

    pub fn setInvert(self: *Self, inv: bool) void {
        self.invert = inv;
    }

    pub fn filter(self: *Self) Filter {
        return self.f;
    }

    fn matchFunc(userdata: ?*anyopaque, item: ?*anyopaque) bool {
        const self: *Self = @ptrCast(@alignCast(userdata orelse return true));
        const v = self.expression.evaluate(item);
        const b = switch (v) {
            .bool_ => |b_| b_,
            .none => false,
            else => true, // 其他非 none 当作 true
        };
        return if (self.invert) !b else b;
    }
};

// ═══════════════════════════════════════════════════════════════════════════
// MultiFilter — 多过滤器组合 (ALL / ANY)
// ═══════════════════════════════════════════════════════════════════════════

pub const MultiFilterMatchMode = enum { all, any };

pub const MultiFilter = struct {
    allocator: Allocator,
    mode: MultiFilterMatchMode,
    items: std.ArrayListUnmanaged(Filter) = .{},
    f: Filter = .{ .matchFn = matchFunc },

    const Self = @This();

    pub fn create(allocator: Allocator, mode: MultiFilterMatchMode) !*Self {
        const self = try allocator.create(Self);
        self.* = .{ .allocator = allocator, .mode = mode };
        self.f.userdata = self;
        return self;
    }

    pub fn destroy(self: *Self) void {
        self.items.deinit(self.allocator);
        self.allocator.destroy(self);
    }

    pub fn add(self: *Self, f: Filter) !void {
        try self.items.append(self.allocator, f);
    }

    pub fn filter(self: *Self) Filter {
        return self.f;
    }

    fn matchFunc(userdata: ?*anyopaque, item: ?*anyopaque) bool {
        const self: *Self = @ptrCast(@alignCast(userdata orelse return true));
        if (self.items.items.len == 0) return true;
        for (self.items.items) |f| {
            const ok = f.match(item);
            switch (self.mode) {
                .all => if (!ok) return false,
                .any => if (ok) return true,
            }
        }
        return switch (self.mode) {
            .all => true,
            .any => false,
        };
    }
};

// ═══════════════════════════════════════════════════════════════════════════
// EveryFilter - 全部子 filter 匹配才通过 (GTK4: GtkEveryFilter)
// 独立结构体，非 MultiFilter 别名
// ═══════════════════════════════════════════════════════════════════════════

pub const EveryFilter = struct {
    allocator: Allocator,
    items: std.ArrayListUnmanaged(Filter) = .{},
    f: Filter = .{ .matchFn = matchFunc },

    const Self = @This();

    pub fn create(allocator: Allocator) !*Self {
        const self = try allocator.create(Self);
        self.* = .{ .allocator = allocator };
        self.f.userdata = self;
        return self;
    }

    pub fn destroy(self: *Self) void {
        self.items.deinit(self.allocator);
        self.allocator.destroy(self);
    }

    pub fn append(self: *Self, child: Filter) !void {
        try self.items.append(self.allocator, child);
    }

    pub fn remove(self: *Self, index: usize) void {
        if (index < self.items.items.len) {
            _ = self.items.orderedRemove(index);
        }
    }

    pub fn filter(self: *Self) Filter {
        return self.f;
    }

    fn matchFunc(userdata: ?*anyopaque, item: ?*anyopaque) bool {
        const self: *Self = @ptrCast(@alignCast(userdata orelse return true));
        for (self.items.items) |f| {
            if (!f.match(item)) return false;
        }
        return true;
    }
};

// ═══════════════════════════════════════════════════════════════════════════
// AnyFilter - 任一子 filter 匹配即通过 (GTK4: GtkAnyFilter)
// 独立结构体，非 MultiFilter 别名
// ═══════════════════════════════════════════════════════════════════════════

pub const AnyFilter = struct {
    allocator: Allocator,
    items: std.ArrayListUnmanaged(Filter) = .{},
    f: Filter = .{ .matchFn = matchFunc },

    const Self = @This();

    pub fn create(allocator: Allocator) !*Self {
        const self = try allocator.create(Self);
        self.* = .{ .allocator = allocator };
        self.f.userdata = self;
        return self;
    }

    pub fn destroy(self: *Self) void {
        self.items.deinit(self.allocator);
        self.allocator.destroy(self);
    }

    pub fn append(self: *Self, child: Filter) !void {
        try self.items.append(self.allocator, child);
    }

    pub fn remove(self: *Self, index: usize) void {
        if (index < self.items.items.len) {
            _ = self.items.orderedRemove(index);
        }
    }

    pub fn filter(self: *Self) Filter {
        return self.f;
    }

    fn matchFunc(userdata: ?*anyopaque, item: ?*anyopaque) bool {
        const self: *Self = @ptrCast(@alignCast(userdata orelse return true));
        for (self.items.items) |f| {
            if (f.match(item)) return true;
        }
        return false;
    }
};

// ═══════════════════════════════════════════════════════════════════════════
// FilterListModel — 实现 ListModelIface 的过滤视图
// ═══════════════════════════════════════════════════════════════════════════

pub const FilterListModel = struct {
    allocator: Allocator,
    source: ListModel,
    filter: ?Filter,
    /// 映射表: view_idx → source_idx（只存匹配的）
    mapping: std.ArrayListUnmanaged(usize) = .{},

    /// 外部变更回调 (View 层监听)
    on_items_changed: ?ItemsChangedFn = null,
    on_items_changed_userdata: ?*anyopaque = null,

    // 静态 iface
    const static_iface = ListModelIface{
        .getItemFn = getItemFn,
        .getNItemsFn = getNItemsFn,
        .getItemTypeFn = getTypeFn,
    };

    const Self = @This();

    pub fn create(allocator: Allocator, source: ListModel, filter: ?Filter) !*Self {
        const self = try allocator.create(Self);
        self.* = .{
            .allocator = allocator,
            .source = source,
            .filter = filter,
        };
        try self.rebuildMapping();
        return self;
    }

    pub fn destroy(self: *Self) void {
        self.mapping.deinit(self.allocator);
        self.allocator.destroy(self);
    }

    /// 获取擦除类型的 ListModel 胖指针
    pub fn model(self: *Self) ListModel {
        return .{
            .iface = &static_iface,
            .userdata = self,
        };
    }

    /// 切换过滤器，重新构建映射
    pub fn setFilter(self: *Self, f: ?Filter) !void {
        self.filter = f;
        const old_len = self.mapping.items.len;
        try self.rebuildMapping();
        const new_len = self.mapping.items.len;
        self.emitChanged(0, old_len, new_len);
    }

    /// 强制重新构建映射（源模型内容变更后手动调用）
    pub fn invalidate(self: *Self) !void {
        const old_len = self.mapping.items.len;
        try self.rebuildMapping();
        const new_len = self.mapping.items.len;
        if (old_len != new_len or old_len > 0) {
            self.emitChanged(0, old_len, new_len);
        }
    }

    // ── 内部 ───────────────────────────────────────────────────────────────

    fn rebuildMapping(self: *Self) !void {
        self.mapping.clearRetainingCapacity();
        const total = self.source.nItems();
        const flt = self.filter orelse {
            // 无 filter → 恒等映射
            try self.mapping.ensureTotalCapacity(self.allocator, total);
            for (0..total) |i| self.mapping.appendAssumeCapacity(i);
            return;
        };
        for (0..total) |i| {
            const item = self.source.iface.getItemFn(self.source.userdata, i);
            if (flt.match(item)) {
                try self.mapping.append(self.allocator, i);
            }
        }
    }

    fn emitChanged(self: *Self, pos: usize, removed: usize, added: usize) void {
        if (self.on_items_changed) |cb| {
            cb(self.on_items_changed_userdata, pos, removed, added);
        }
    }

    // ── ListModelIface 实现 ────────────────────────────────────────────────

    fn getItemFn(userdata: ?*anyopaque, position: usize) ?*anyopaque {
        const self: *Self = @ptrCast(@alignCast(userdata orelse return null));
        if (position >= self.mapping.items.len) return null;
        const src_idx = self.mapping.items[position];
        return self.source.iface.getItemFn(self.source.userdata, src_idx);
    }

    fn getNItemsFn(userdata: ?*anyopaque) usize {
        const self: *Self = @ptrCast(@alignCast(userdata orelse return 0));
        return self.mapping.items.len;
    }

    fn getTypeFn(userdata: ?*anyopaque) []const u8 {
        const self: *Self = @ptrCast(@alignCast(userdata orelse return "FilterListModel"));
        return self.source.itemType();
    }
};

// ═══════════════════════════════════════════════════════════════════════════
// 测试
// ═══════════════════════════════════════════════════════════════════════════

test "Filter: StringFilter contains + prefix" {
    const alloc = std.testing.allocator;

    var store = try list_model.StringListStore.new(alloc);
    defer store.destroy();
    try store.append("apple");
    try store.append("banana");
    try store.append("apricot");
    try store.append("cherry");

    // prefix = "ap"
    var f1 = try StringFilter.create(alloc, .{ .search = "ap", .mode = .prefix });
    defer f1.destroy();
    const src = store.model();
    var count: usize = 0;
    for (0..src.nItems()) |i| {
        const raw = src.iface.getItemFn(src.userdata, i);
        if (f1.filter().match(raw)) count += 1;
    }
    try std.testing.expectEqual(@as(usize, 2), count); // apple + apricot

    // contains = "a"
    var f2 = try StringFilter.create(alloc, .{ .search = "a", .mode = .contains });
    defer f2.destroy();
    count = 0;
    for (0..src.nItems()) |i| {
        const raw = src.iface.getItemFn(src.userdata, i);
        if (f2.filter().match(raw)) count += 1;
    }
    try std.testing.expectEqual(@as(usize, 3), count); // apple+banana+apricot  cherry 不含 a
}

test "FilterListModel: integration" {
    const alloc = std.testing.allocator;

    var store = try list_model.StringListStore.new(alloc);
    defer store.destroy();
    try store.append("apple");
    try store.append("banana");
    try store.append("apricot");
    try store.append("cherry");

    var f = try StringFilter.create(alloc, .{ .search = "ap", .mode = .prefix });
    defer f.destroy();

    var list = try FilterListModel.create(alloc, store.model(), f.filter());
    defer list.destroy();

    const view = list.model();
    try std.testing.expectEqual(@as(usize, 2), view.nItems());
    const first = view.getItem([]const u8, 0).?.*;
    try std.testing.expectEqualStrings("apple", first);
    const second = view.getItem([]const u8, 1).?.*;
    try std.testing.expectEqualStrings("apricot", second);

    // 清空 filter
    try list.setFilter(null);
    try std.testing.expectEqual(@as(usize, 4), view.nItems());
}

test "MultiFilter: all + any" {
    const alloc = std.testing.allocator;

    var fa = try StringFilter.create(alloc, .{ .search = "a", .mode = .contains });
    defer fa.destroy();
    var fb = try StringFilter.create(alloc, .{ .search = "p", .mode = .contains });
    defer fb.destroy();

    var all_f = try MultiFilter.create(alloc, .all);
    defer all_f.destroy();
    try all_f.add(fa.filter());
    try all_f.add(fb.filter());

    const apple: []const u8 = "apple";
    const banana: []const u8 = "banana";
    const apricot: []const u8 = "apricot";
    const cherry: []const u8 = "cherry";
    try std.testing.expect(all_f.filter().match(@as(?*anyopaque, @ptrCast(@constCast(&apple))))); // apple 含 a+p
    try std.testing.expect(!all_f.filter().match(@as(?*anyopaque, @ptrCast(@constCast(&banana))))); // banana 不含 p
    try std.testing.expect(all_f.filter().match(@as(?*anyopaque, @ptrCast(@constCast(&apricot))))); // a+p
    try std.testing.expect(!all_f.filter().match(@as(?*anyopaque, @ptrCast(@constCast(&cherry))))); // cherry 不含 a

    var any_f = try MultiFilter.create(alloc, .any);
    defer any_f.destroy();
    try any_f.add(fa.filter());
    try any_f.add(fb.filter());
    try std.testing.expect(!any_f.filter().match(@as(?*anyopaque, @ptrCast(@constCast(&cherry))))); // cherry 都不满足
}
