//! Sorter + SortListModel — 排序模型 (对标 GtkSorter + GtkSortListModel)
//!
//! 通过 Sorter 对源 ListModel 进行排序，生成排序后的视图。
//! 支持:
//!   - CustomSorter   — 用户自定义 compare 函数
//!   - StringSorter   — 按字符串字典序排序（大小写可选）
//!   - NumericSorter  — 按 f32/i32/i64 数值排序
//!   - SortListModel  — 实现 ListModelIface，支持排序方向 (asc/desc)
//!
//! 典型用法:
//! ```
//! var sorter = try m.NumericSorter.create(alloc, .{
//!     .extract = struct { fn fn_(p: ?*anyopaque) f32 {
//!         const x = @as(*f32, @ptrCast(@alignCast(p))).*;
//!         return x;
//!     }}.fn_
//! });
//! var list = try m.SortListModel.create(alloc, source.model(), sorter.sorter(), .ascending);
//! ```

const std = @import("std");
const Allocator = std.mem.Allocator;
const list_model = @import("list_model.zig");
const ListModel = list_model.ListModel;
const ListModelIface = list_model.ListModelIface;
const ItemsChangedFn = list_model.ItemsChangedFn;
const expression_mod = @import("expression.zig");
const Expression = expression_mod.Expression;
const compareValues = expression_mod.compareValues;

// ═══════════════════════════════════════════════════════════════════════════
// Ordering + Sorter 接口
// ═══════════════════════════════════════════════════════════════════════════

pub const Ordering = enum(i8) {
    smaller = -1,
    equal = 0,
    larger = 1,

    pub fn reverse(o: Ordering) Ordering {
        return switch (o) {
            .smaller => .larger,
            .equal => .equal,
            .larger => .smaller,
        };
    }
};

pub const SorterCompareFn = *const fn (userdata: ?*anyopaque, a: ?*anyopaque, b: ?*anyopaque) Ordering;

/// GTK4: GtkSorterChange - 排序器变更类型
pub const SorterChange = enum {
    /// 排序行为完全不同，需重新排序
    differ,
    /// 排序反转（升降序互换）
    inverted,
    /// 排序更宽松
    less_strict,
    /// 排序更严格
    more_strict,
};

pub const Sorter = struct {
    compareFn: SorterCompareFn,
    userdata: ?*anyopaque = null,

    pub fn compare(self: Sorter, a: ?*anyopaque, b: ?*anyopaque) Ordering {
        return self.compareFn(self.userdata, a, b);
    }
};

pub const SortOrder = enum { ascending, descending };

// ═══════════════════════════════════════════════════════════════════════════
// CustomSorter — 用户自定义 compare 函数
// ═══════════════════════════════════════════════════════════════════════════

pub const CustomSorter = struct {
    s: Sorter,

    pub fn create(allocator: Allocator, cmp: SorterCompareFn, userdata: ?*anyopaque) !*CustomSorter {
        const self = try allocator.create(CustomSorter);
        self.* = .{ .s = .{ .compareFn = cmp, .userdata = userdata } };
        return self;
    }

    pub fn destroy(self: *CustomSorter, allocator: Allocator) void {
        allocator.destroy(self);
    }

    pub fn sorter(self: *CustomSorter) Sorter {
        return self.s;
    }
};

// ═══════════════════════════════════════════════════════════════════════════
// StringSorter — 按字符串排序
// ═══════════════════════════════════════════════════════════════════════════

pub const StringSorter = struct {
    allocator: Allocator,
    ignore_case: bool = true,
    /// 从 item 中提取字符串 (默认把 item 当 *[]const u8)
    extractFn: ?*const fn (item: ?*anyopaque) []const u8 = null,
    /// Expression 抽取 (优先使用, 若设置则取 evaluate().string)
    expression: ?Expression = null,
    s: Sorter = .{ .compareFn = compareFunc },

    const Self = @This();

    pub fn create(allocator: Allocator, opts: struct {
        ignore_case: bool = true,
        extractFn: ?*const fn (item: ?*anyopaque) []const u8 = null,
        expression: ?Expression = null,
    }) !*Self {
        const self = try allocator.create(Self);
        self.* = .{
            .allocator = allocator,
            .ignore_case = opts.ignore_case,
            .extractFn = opts.extractFn,
            .expression = opts.expression,
        };
        self.s.userdata = self;
        return self;
    }

    pub fn destroy(self: *Self) void {
        self.allocator.destroy(self);
    }

    pub fn setExpression(self: *Self, expr: ?Expression) void {
        self.expression = expr;
    }

    pub fn sorter(self: *Self) Sorter {
        return self.s;
    }

    fn compareFunc(userdata: ?*anyopaque, a_raw: ?*anyopaque, b_raw: ?*anyopaque) Ordering {
        const self: *Self = @ptrCast(@alignCast(userdata orelse return .equal));
        const sa: []const u8 = if (self.expression) |*expr| blk: {
            const v = expr.evaluate(a_raw);
            break :blk switch (v) {
                .string => |s| s,
                .int => |x| blk2: {
                    break :blk2 numericTemp(@floatFromInt(x));
                },
                .uint => |x| blk2: {
                    break :blk2 numericTemp(@floatFromInt(x));
                },
                .float => |x| blk2: {
                    break :blk2 numericTemp(x);
                },
                .bool_ => |b| if (b) "true" else "false",
                .none => return .equal,
            };
        } else if (self.extractFn) |ef| ef(a_raw) else blk: {
            if (a_raw == null) return .equal;
            const p: *[]const u8 = @ptrCast(@alignCast(a_raw));
            break :blk p.*;
        };
        const sb: []const u8 = if (self.expression) |*expr| blk: {
            const v = expr.evaluate(b_raw);
            break :blk switch (v) {
                .string => |s| s,
                .int => |x| blk2: {
                    break :blk2 numericTemp(@floatFromInt(x));
                },
                .uint => |x| blk2: {
                    break :blk2 numericTemp(@floatFromInt(x));
                },
                .float => |x| blk2: {
                    break :blk2 numericTemp(x);
                },
                .bool_ => |b| if (b) "true" else "false",
                .none => return .equal,
            };
        } else if (self.extractFn) |ef| ef(b_raw) else blk: {
            if (b_raw == null) return .equal;
            const p: *[]const u8 = @ptrCast(@alignCast(b_raw));
            break :blk p.*;
        };
        const cmp = if (self.ignore_case) std.ascii.orderIgnoreCase(sa, sb) else std.mem.order(u8, sa, sb);
        return switch (cmp) {
            .lt => .smaller,
            .eq => .equal,
            .gt => .larger,
        };
    }

    fn numericTemp(x: f32) []const u8 {
        const TlsBuf = struct {
            threadlocal var buf: [64]u8 = undefined;
        };
        return std.fmt.bufPrint(&TlsBuf.buf, "{d:.2}", .{x}) catch "0";
    }
};

// ═══════════════════════════════════════════════════════════════════════════
// NumericSorter — 按 f32 数值排序
// ═══════════════════════════════════════════════════════════════════════════

pub const NumericExtractFn = *const fn (item: ?*anyopaque) f32;

pub const NumericSorter = struct {
    allocator: Allocator,
    extractFn: ?NumericExtractFn = null,
    /// Expression 抽取 (优先使用, 若设置则 evaluate 后转 float)
    expression: ?Expression = null,
    s: Sorter = .{ .compareFn = compareFunc },

    const Self = @This();

    pub fn create(allocator: Allocator, opts: struct {
        extract: ?NumericExtractFn = null,
        expression: ?Expression = null,
    }) !*Self {
        const self = try allocator.create(Self);
        self.* = .{
            .allocator = allocator,
            .extractFn = opts.extract,
            .expression = opts.expression,
        };
        self.s.userdata = self;
        return self;
    }

    pub fn destroy(self: *Self) void {
        self.allocator.destroy(self);
    }

    pub fn setExpression(self: *Self, expr: ?Expression) void {
        self.expression = expr;
    }

    pub fn sorter(self: *Self) Sorter {
        return self.s;
    }

    fn toFloat(v: expression_mod.Value) f32 {
        return switch (v) {
            .float => |f| f,
            .int => |i| @floatFromInt(i),
            .uint => |u| @floatFromInt(u),
            .bool_ => |b| if (b) 1.0 else 0.0,
            .string => |s| std.fmt.parseFloat(f32, s) catch 0.0,
            .none => 0.0,
        };
    }

    fn compareFunc(userdata: ?*anyopaque, a: ?*anyopaque, b: ?*anyopaque) Ordering {
        const self: *Self = @ptrCast(@alignCast(userdata orelse return .equal));
        const va: f32 = if (self.expression) |*expr|
            toFloat(expr.evaluate(a))
        else if (self.extractFn) |ef|
            ef(a)
        else
            0.0;
        const vb: f32 = if (self.expression) |*expr|
            toFloat(expr.evaluate(b))
        else if (self.extractFn) |ef|
            ef(b)
        else
            0.0;
        if (va < vb) return .smaller;
        if (va > vb) return .larger;
        return .equal;
    }
};

// ═══════════════════════════════════════════════════════════════════════════
// ExpressionSorter — 通用表达式比较器 (使用 compareValues, 支持任意 Value 类型)
// ═══════════════════════════════════════════════════════════════════════════

pub const ExpressionSorter = struct {
    expression: Expression,
    s: Sorter = .{ .compareFn = compareFunc },

    const Self = @This();

    pub fn create(allocator: Allocator, expression: Expression) !*Self {
        const self = try allocator.create(Self);
        self.* = .{ .expression = expression };
        self.s.userdata = self;
        return self;
    }

    pub fn destroy(self: *Self, allocator: Allocator) void {
        allocator.destroy(self);
    }

    pub fn setExpression(self: *Self, expr: Expression) void {
        self.expression = expr;
    }

    pub fn sorter(self: *Self) Sorter {
        return self.s;
    }

    fn compareFunc(userdata: ?*anyopaque, a: ?*anyopaque, b: ?*anyopaque) Ordering {
        const self: *Self = @ptrCast(@alignCast(userdata orelse return .equal));
        const va = self.expression.evaluate(a);
        const vb = self.expression.evaluate(b);
        const o = compareValues(va, vb);
        return switch (o) {
            .lt => .smaller,
            .eq => .equal,
            .gt => .larger,
        };
    }
};

// ═══════════════════════════════════════════════════════════════════════════
// SortListModel — 实现 ListModelIface 的排序视图
// ═══════════════════════════════════════════════════════════════════════════

pub const SortListModel = struct {
    allocator: Allocator,
    source: ListModel,
    sorter: ?Sorter,
    order: SortOrder,
    /// 映射表: view_idx → source_idx（排序后）
    mapping: std.ArrayListUnmanaged(usize) = .{},

    on_items_changed: ?ItemsChangedFn = null,
    on_items_changed_userdata: ?*anyopaque = null,

    const static_iface = ListModelIface{
        .getItemFn = getItemFn,
        .getNItemsFn = getNItemsFn,
        .getItemTypeFn = getTypeFn,
    };

    const Self = @This();

    pub fn create(allocator: Allocator, source: ListModel, sorter: ?Sorter, order: SortOrder) !*Self {
        const self = try allocator.create(Self);
        self.* = .{
            .allocator = allocator,
            .source = source,
            .sorter = sorter,
            .order = order,
        };
        try self.rebuildMapping();
        return self;
    }

    pub fn destroy(self: *Self) void {
        self.mapping.deinit(self.allocator);
        self.allocator.destroy(self);
    }

    pub fn model(self: *Self) ListModel {
        return .{ .iface = &static_iface, .userdata = self };
    }

    /// 切换排序器 + 方向
    pub fn setSorter(self: *Self, s: ?Sorter, order: ?SortOrder) !void {
        self.sorter = s;
        if (order) |o| self.order = o;
        const old_len = self.mapping.items.len;
        try self.rebuildMapping();
        self.emitChanged(0, old_len, self.mapping.items.len);
    }

    /// 切换升/降序
    pub fn setOrder(self: *Self, order: SortOrder) !void {
        if (self.order == order) return;
        self.order = order;
        const old_len = self.mapping.items.len;
        try self.rebuildMapping();
        self.emitChanged(0, old_len, self.mapping.items.len);
    }

    pub fn invalidate(self: *Self) !void {
        const old_len = self.mapping.items.len;
        try self.rebuildMapping();
        if (old_len != self.mapping.items.len or old_len > 0) {
            self.emitChanged(0, old_len, self.mapping.items.len);
        }
    }

    // ── 内部 ───────────────────────────────────────────────────────────────

    const SortContext = struct {
        source: ListModel,
        sorter: Sorter,
        order: SortOrder,
    };

    fn rebuildMapping(self: *Self) !void {
        const total = self.source.nItems();
        self.mapping.clearRetainingCapacity();
        try self.mapping.resize(self.allocator, total);
        for (0..total) |i| self.mapping.items[i] = i;

        const s = self.sorter orelse return; // 无排序器=保持原序

        const ctx = SortContext{ .source = self.source, .sorter = s, .order = self.order };
        const Ctx = struct {
            fn less(context: SortContext, a: usize, b: usize) bool {
                const ra = context.source.iface.getItemFn(context.source.userdata, a);
                const rb = context.source.iface.getItemFn(context.source.userdata, b);
                var ord = context.sorter.compare(ra, rb);
                if (context.order == .descending) ord = ord.reverse();
                return ord == .smaller;
            }
        };
        // 使用插入排序或快排包装 (std.sort 对任意 context 不直接支持，这里实现一个简单的 in-place)
        // 改用 sort 带上下文的版本：通过把 ctx 放在 TLS 或者直接闭包包装
        self.sortMappingByCtx(&ctx, &Ctx.less);
    }

    /// 稳定的插入排序 (用于演示；项目不大时可接受)
    fn sortMappingByCtx(self: *Self, ctx: *const SortContext, less_fn: *const fn (SortContext, usize, usize) bool) void {
        const items = self.mapping.items;
        for (1..items.len) |i| {
            const key = items[i];
            var j = i;
            while (j > 0 and !less_fn(ctx.*, items[j - 1], key)) {
                items[j] = items[j - 1];
                j -= 1;
            }
            items[j] = key;
        }
    }

    fn emitChanged(self: *Self, pos: usize, removed: usize, added: usize) void {
        if (self.on_items_changed) |cb| cb(self.on_items_changed_userdata, pos, removed, added);
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
        const self: *Self = @ptrCast(@alignCast(userdata orelse return "SortListModel"));
        return self.source.itemType();
    }
};

// ═══════════════════════════════════════════════════════════════════════════
// 测试
// ═══════════════════════════════════════════════════════════════════════════

test "Sorter: StringSorter + SortListModel ascending/descending" {
    const alloc = std.testing.allocator;

    var store = try list_model.StringListStore.new(alloc);
    defer store.destroy();
    try store.append("cherry");
    try store.append("banana");
    try store.append("apple");
    try store.append("date");

    var s = try StringSorter.create(alloc, .{});
    defer s.destroy();

    var list = try SortListModel.create(alloc, store.model(), s.sorter(), .ascending);
    defer list.destroy();

    const view = list.model();
    try std.testing.expectEqual(@as(usize, 4), view.nItems());
    try std.testing.expectEqualStrings("apple", view.getItem([]const u8, 0).?.*);
    try std.testing.expectEqualStrings("banana", view.getItem([]const u8, 1).?.*);
    try std.testing.expectEqualStrings("cherry", view.getItem([]const u8, 2).?.*);
    try std.testing.expectEqualStrings("date", view.getItem([]const u8, 3).?.*);

    try list.setOrder(.descending);
    try std.testing.expectEqualStrings("date", view.getItem([]const u8, 0).?.*);
    try std.testing.expectEqualStrings("apple", view.getItem([]const u8, 3).?.*);
}

test "Sorter: NumericSorter" {
    const alloc = std.testing.allocator;

    const NStore = list_model.ListStore(f32);
    var store = try NStore.new(alloc, "f32", .{});
    defer store.destroy();
    try store.append(3.14);
    try store.append(1.59);
    try store.append(2.65);
    try store.append(0.42);

    var ns = try NumericSorter.create(alloc, .{ .extract = (struct {
        fn f(p: ?*anyopaque) f32 {
            return @as(*f32, @ptrCast(@alignCast(p orelse return 0))).*;
        }
    }).f });
    defer ns.destroy();

    var list = try SortListModel.create(alloc, store.model(), ns.sorter(), .ascending);
    defer list.destroy();
    const view = list.model();
    try std.testing.expectEqual(@as(f32, 0.42), view.getItem(f32, 0).?.*);
    try std.testing.expectEqual(@as(f32, 1.59), view.getItem(f32, 1).?.*);
    try std.testing.expectEqual(@as(f32, 2.65), view.getItem(f32, 2).?.*);
    try std.testing.expectEqual(@as(f32, 3.14), view.getItem(f32, 3).?.*);
}

test "SortListModel: null sorter = identity order" {
    const alloc = std.testing.allocator;
    var store = try list_model.StringListStore.new(alloc);
    defer store.destroy();
    try store.append("c");
    try store.append("a");
    try store.append("b");

    var list = try SortListModel.create(alloc, store.model(), null, .ascending);
    defer list.destroy();
    const view = list.model();
    try std.testing.expectEqualStrings("c", view.getItem([]const u8, 0).?.*);
    try std.testing.expectEqualStrings("a", view.getItem([]const u8, 1).?.*);
    try std.testing.expectEqualStrings("b", view.getItem([]const u8, 2).?.*);
}
