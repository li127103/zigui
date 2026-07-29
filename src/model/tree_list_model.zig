//! TreeListModel — 树形列表模型 (对标 GtkTreeListModel)
//!
//! 配合 TreeExpander 使用：把嵌套的树形结构展平成一维行列表，
//! 每一行用 TreeListRow 包装，提供 depth / expanded / has_children。
//!
//! 核心概念:
//!   - createFunc(item) → ?ListModel：给定父项，返回其子项的 ListModel（无子则 null）
//!   - 展平逻辑：遍历所有项，若展开则把对应子项递归插入
//!   - 行位置映射：view_idx → (root_items 扁平队列中的 entry)

const std = @import("std");
const Allocator = std.mem.Allocator;
const list_model = @import("list_model.zig");
const ListModel = list_model.ListModel;
const ListModelIface = list_model.ListModelIface;

/// TreeListRow — 每行携带的元数据（GTK 对应 GtkTreeListRow）
pub const TreeListRow = struct {
    /// 原始的 item 指针 (来自源模型)
    item: ?*anyopaque = null,
    /// 深度 (顶层 = 0)
    depth: u32 = 0,
    /// 是否有子项 (createFunc 返回非空且非零长度)
    has_children: bool = false,
    /// 当前是否展开
    expanded: bool = false,
    /// GTK4 兼容: 是否为占位行
    is_placeholder: bool = false,

    userdata: ?*anyopaque = null,
};

/// 为每个父项创建子模型的函数 (GTK: GtkTreeListModelCreateModelFunc)
pub const CreateModelFn = *const fn (userdata: ?*anyopaque, item: ?*anyopaque) ?ListModel;

pub const TreeListModel = struct {
    allocator: Allocator,
    root: ListModel,
    create_fn: CreateModelFn,
    create_userdata: ?*anyopaque = null,
    autoexpand: bool = false,

    /// 扁平的行列表 (view order)
    rows: std.ArrayListUnmanaged(TreeListRow) = .{},

    const static_iface = ListModelIface{
        .getItemFn = getItemFn,
        .getNItemsFn = getNItemsFn,
        .getItemTypeFn = getTypeFn,
    };

    const Self = @This();

    pub fn create(
        allocator: Allocator,
        root: ListModel,
        create_fn: CreateModelFn,
        opts: struct {
            create_userdata: ?*anyopaque = null,
            autoexpand: bool = false,
        },
    ) !*Self {
        const self = try allocator.create(Self);
        self.* = .{
            .allocator = allocator,
            .root = root,
            .create_fn = create_fn,
            .create_userdata = opts.create_userdata,
            .autoexpand = opts.autoexpand,
        };
        try self.rebuild();
        return self;
    }

    pub fn destroy(self: *Self) void {
        self.rows.deinit(self.allocator);
        self.allocator.destroy(self);
    }

    /// 返回擦除类型的模型，实际 item 为 *TreeListRow（每行包含真实 item + 元数据）
    pub fn model(self: *Self) ListModel {
        return .{ .iface = &static_iface, .userdata = self };
    }

    pub fn nRows(self: *const Self) usize {
        return self.rows.items.len;
    }

    /// 获取第 row_idx 行的可变引用（用于切换 expanded）
    pub fn getRow(self: *Self, row_idx: usize) ?*TreeListRow {
        if (row_idx >= self.rows.items.len) return null;
        return &self.rows.items[row_idx];
    }

    /// 切换第 row_idx 行的 expanded 状态，然后重构建
    pub fn toggleExpanded(self: *Self, row_idx: usize) !void {
        if (row_idx >= self.rows.items.len) return;
        const row = &self.rows.items[row_idx];
        if (!row.has_children) return;
        row.expanded = !row.expanded;
        try self.rebuild();
    }

    // ── 内部展平逻辑 ───────────────────────────────────────────────────────

    fn rebuild(self: *Self) !void {
        self.rows.clearRetainingCapacity();
        try self.appendChildren(self.root, 0);
    }

    fn appendChildren(self: *Self, m: ListModel, depth: u32) !void {
        const n = m.nItems();
        for (0..n) |i| {
            const item = m.iface.getItemFn(m.userdata, i);
            const children = self.create_fn(self.create_userdata, item);
            const has_children = if (children) |cm| cm.nItems() > 0 else false;
            const expanded = self.autoexpand or has_children == false; // autoexpand=true 或 无子都直接展开（无子自然无折叠）
            // 加入本项
            const row: TreeListRow = .{
                .item = item,
                .depth = depth,
                .has_children = has_children,
                .expanded = if (self.autoexpand) has_children else (if (has_children) expanded else false),
            };
            try self.rows.append(self.allocator, row);
            // 若有子且 expanded，递归加入
            if (has_children and self.rows.items[self.rows.items.len - 1].expanded) {
                if (children) |cm| {
                    try self.appendChildren(cm, depth + 1);
                }
            }
        }
    }

    // ── ListModelIface 实现 ────────────────────────────────────────────────
    // getItem 返回 *TreeListRow (用户可通过 row.item 访问真实数据)

    fn getItemFn(userdata: ?*anyopaque, position: usize) ?*anyopaque {
        const self: *Self = @ptrCast(@alignCast(userdata orelse return null));
        if (position >= self.rows.items.len) return null;
        return @ptrCast(&self.rows.items[position]);
    }

    fn getNItemsFn(userdata: ?*anyopaque) usize {
        const self: *Self = @ptrCast(@alignCast(userdata orelse return 0));
        return self.rows.items.len;
    }

    fn getTypeFn(userdata: ?*anyopaque) []const u8 {
        _ = userdata;
        return "TreeListRow";
    }
};

// ═══════════════════════════════════════════════════════════════════════════
// 测试
// ═══════════════════════════════════════════════════════════════════════════

test "TreeListModel: 2-level hierarchy with toggle" {
    const alloc = std.testing.allocator;

    // 构造: root = ["Fruits", "Colors"], Fruits.children = ["Apple","Banana"], Colors.children = ["Red","Blue"]
    var fruits = try list_model.StringListStore.new(alloc);
    defer fruits.destroy();
    try fruits.append("Apple");
    try fruits.append("Banana");

    var colors = try list_model.StringListStore.new(alloc);
    defer colors.destroy();
    try colors.append("Red");
    try colors.append("Blue");

    var root = try list_model.StringListStore.new(alloc);
    defer root.destroy();
    try root.append("Fruits");
    try root.append("Colors");

    const Ctx = struct {
        const Self = @This();
        fruits_m: ListModel,
        colors_m: ListModel,
        fn createFn(userdata: ?*anyopaque, item: ?*anyopaque) ?ListModel {
            const self_ctx: *Self = @ptrCast(@alignCast(userdata orelse return null));
            if (item == null) return null;
            const name = @as(*[]const u8, @ptrCast(@alignCast(item.?))).*;
            if (std.mem.eql(u8, name, "Fruits")) return self_ctx.fruits_m;
            if (std.mem.eql(u8, name, "Colors")) return self_ctx.colors_m;
            return null;
        }
    };
    var ctx = Ctx{ .fruits_m = fruits.model(), .colors_m = colors.model() };

    var tree = try TreeListModel.create(alloc, root.model(), Ctx.createFn, .{
        .create_userdata = &ctx,
        .autoexpand = false, // 先默认关闭
    });
    defer tree.destroy();

    // 默认都折叠：只有 2 行顶层
    try std.testing.expectEqual(@as(usize, 2), tree.nRows());
    try std.testing.expect(tree.getRow(0).?.has_children);
    try std.testing.expect(!tree.getRow(0).?.expanded);

    // 切换 Fruits 展开
    try tree.toggleExpanded(0);
    // Fruits 展开 → 4 行: Fruits, Apple, Banana, Colors
    try std.testing.expectEqual(@as(usize, 4), tree.nRows());
    // 切换 Colors 展开 (当前行 3)
    try tree.toggleExpanded(3);
    // 6 行: Fruits, Apple, Banana, Colors, Red, Blue
    try std.testing.expectEqual(@as(usize, 6), tree.nRows());

    const row_fruits = tree.getRow(0).?;
    try std.testing.expectEqual(@as(u32, 0), row_fruits.depth);
    try std.testing.expectEqual(@as(u32, 1), tree.getRow(1).?.depth); // Apple = 1
    try std.testing.expectEqual(@as(u32, 1), tree.getRow(4).?.depth); // Red = 1
}
