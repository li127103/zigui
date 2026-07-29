//! MapListModel — 映射模型 (对标 GtkMapListModel)
//!
//! 输入: 源 ListModel (T)
//! 输出: 新的 ListModel (U)，通过 mapFn 把 T 转换为 U
//!
//! 配合 Filter → Sort → Map 链式使用：
//! ```
//! FilterListModel → SortListModel → MapListModel → ColumnView
//! ```

const std = @import("std");
const Allocator = std.mem.Allocator;
const list_model = @import("list_model.zig");
const ListModel = list_model.ListModel;
const ListModelIface = list_model.ListModelIface;
const ItemsChangedFn = list_model.ItemsChangedFn;

/// Map 函数: 把 source_item 的指针映射成新的 ?*anyopaque（目标模型的 item）
pub const MapFn = *const fn (userdata: ?*anyopaque, source_item: ?*anyopaque) ?*anyopaque;

pub const MapListModel = struct {
    allocator: Allocator,
    source: ListModel,
    map_fn: MapFn,
    map_userdata: ?*anyopaque = null,

    /// 目标类型名 (调试用)
    target_type_name: []const u8 = "Mapped",

    on_items_changed: ?ItemsChangedFn = null,
    on_items_changed_userdata: ?*anyopaque = null,

    const static_iface = ListModelIface{
        .getItemFn = getItemFn,
        .getNItemsFn = getNItemsFn,
        .getItemTypeFn = getTypeFn,
    };

    const Self = @This();

    pub fn create(
        allocator: Allocator,
        source: ListModel,
        map_fn: MapFn,
        opts: struct {
            map_userdata: ?*anyopaque = null,
            target_type_name: []const u8 = "Mapped",
        },
    ) !*Self {
        const self = try allocator.create(Self);
        self.* = .{
            .allocator = allocator,
            .source = source,
            .map_fn = map_fn,
            .map_userdata = opts.map_userdata,
            .target_type_name = opts.target_type_name,
        };
        return self;
    }

    pub fn destroy(self: *Self) void {
        self.allocator.destroy(self);
    }

    pub fn model(self: *Self) ListModel {
        return .{ .iface = &static_iface, .userdata = self };
    }

    // ── ListModelIface 实现 ────────────────────────────────────────────────

    fn getItemFn(userdata: ?*anyopaque, position: usize) ?*anyopaque {
        const self: *Self = @ptrCast(@alignCast(userdata orelse return null));
        const src_item = self.source.iface.getItemFn(self.source.userdata, position);
        return self.map_fn(self.map_userdata, src_item);
    }

    fn getNItemsFn(userdata: ?*anyopaque) usize {
        const self: *Self = @ptrCast(@alignCast(userdata orelse return 0));
        return self.source.nItems();
    }

    fn getTypeFn(userdata: ?*anyopaque) []const u8 {
        const self: *Self = @ptrCast(@alignCast(userdata orelse return "MapListModel"));
        return self.target_type_name;
    }
};

// ═══════════════════════════════════════════════════════════════════════════
// 测试
// ═══════════════════════════════════════════════════════════════════════════

test "MapListModel: map string → length (f32)" {
    const alloc = std.testing.allocator;
    var store = try list_model.StringListStore.new(alloc);
    defer store.destroy();
    try store.append("apple");
    try store.append("banana");
    try store.append("kiwi");

    // 映射字符串 → *const f32（长度）
    const LengthCtx = struct {
        threadlocal var lens: [3]f32 = undefined;
        fn map(_: ?*anyopaque, src: ?*anyopaque) ?*anyopaque {
            const s: *[]const u8 = @ptrCast(@alignCast(src orelse return null));
            const idx: usize = if (std.mem.eql(u8, s.*, "apple")) 0 else if (std.mem.eql(u8, s.*, "banana")) 1 else if (std.mem.eql(u8, s.*, "kiwi")) 2 else 0;
            lens[idx] = @floatFromInt(s.*.len);
            return @ptrCast(&lens[idx]);
        }
    };

    var mapped = try MapListModel.create(alloc, store.model(), LengthCtx.map, .{ .target_type_name = "f32" });
    defer mapped.destroy();
    const view = mapped.model();
    try std.testing.expectEqual(@as(usize, 3), view.nItems());
    const l0 = @as(*f32, @ptrCast(@alignCast(view.iface.getItemFn(view.userdata, 0) orelse return error.ExpectedItem))).*;
    const l1 = @as(*f32, @ptrCast(@alignCast(view.iface.getItemFn(view.userdata, 1) orelse return error.ExpectedItem))).*;
    const l2 = @as(*f32, @ptrCast(@alignCast(view.iface.getItemFn(view.userdata, 2) orelse return error.ExpectedItem))).*;
    try std.testing.expectEqual(@as(f32, 5), l0); // "apple"  5
    try std.testing.expectEqual(@as(f32, 6), l1); // "banana" 6
    try std.testing.expectEqual(@as(f32, 4), l2); // "kiwi"   4
}
