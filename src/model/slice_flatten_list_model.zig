//! SliceListModel + FlattenListModel — 切片 & 展平模型
//!
//! - SliceListModel   (GtkSliceListModel): 取源模型 [offset, offset+size) 区间，用于分页
//! - FlattenListModel (GtkFlattenListModel): 把 ListModel<ListModel<T>> 展平成 ListModel<T>

const std = @import("std");
const Allocator = std.mem.Allocator;
const list_model = @import("list_model.zig");
const ListModel = list_model.ListModel;
const ListModelIface = list_model.ListModelIface;

// ═══════════════════════════════════════════════════════════════════════════
// SliceListModel
// ═══════════════════════════════════════════════════════════════════════════

pub const SliceListModel = struct {
    allocator: Allocator,
    source: ListModel,
    offset: usize = 0,
    size: usize = 0, // 0 = 直到末尾

    const static_iface = ListModelIface{
        .getItemFn = getItemFn,
        .getNItemsFn = getNItemsFn,
        .getItemTypeFn = getTypeFn,
    };

    const Self = @This();

    pub fn create(allocator: Allocator, source: ListModel, opts: struct {
        offset: usize = 0,
        size: usize = 0, // 0 = 直到末尾
    }) !*Self {
        const self = try allocator.create(Self);
        self.* = .{
            .allocator = allocator,
            .source = source,
            .offset = opts.offset,
            .size = opts.size,
        };
        return self;
    }

    pub fn destroy(self: *Self) void {
        self.allocator.destroy(self);
    }

    pub fn model(self: *Self) ListModel {
        return .{ .iface = &static_iface, .userdata = self };
    }

    /// 修改切片范围
    pub fn setSlice(self: *Self, offset: usize, size: usize) void {
        self.offset = offset;
        self.size = size;
    }

    fn effSize(self: *const Self) usize {
        const src_len = self.source.nItems();
        if (self.offset >= src_len) return 0;
        const remain = src_len - self.offset;
        if (self.size == 0) return remain;
        return @min(remain, self.size);
    }

    fn getItemFn(userdata: ?*anyopaque, position: usize) ?*anyopaque {
        const self: *Self = @ptrCast(@alignCast(userdata orelse return null));
        const n = self.effSize();
        if (position >= n) return null;
        return self.source.iface.getItemFn(self.source.userdata, self.offset + position);
    }

    fn getNItemsFn(userdata: ?*anyopaque) usize {
        const self: *Self = @ptrCast(@alignCast(userdata orelse return 0));
        return self.effSize();
    }

    fn getTypeFn(userdata: ?*anyopaque) []const u8 {
        const self: *Self = @ptrCast(@alignCast(userdata orelse return "SliceListModel"));
        return self.source.itemType();
    }
};

// ═══════════════════════════════════════════════════════════════════════════
// FlattenListModel
// ═══════════════════════════════════════════════════════════════════════════

/// 每个源 item 必须能被 extract 成 ListModel（即 source item = *ListModel 或者用 extract_fn）
pub const ExtractModelFn = *const fn (userdata: ?*anyopaque, outer_item: ?*anyopaque) ?ListModel;

pub const FlattenListModel = struct {
    allocator: Allocator,
    source: ListModel,
    extract_fn: ExtractModelFn = defaultExtract,
    extract_userdata: ?*anyopaque = null,

    const static_iface = ListModelIface{
        .getItemFn = getItemFn,
        .getNItemsFn = getNItemsFn,
        .getItemTypeFn = getTypeFn,
    };

    const Self = @This();

    pub fn create(allocator: Allocator, source: ListModel, opts: struct {
        extract_fn: ExtractModelFn = defaultExtract,
        extract_userdata: ?*anyopaque = null,
    }) !*Self {
        const self = try allocator.create(Self);
        self.* = .{
            .allocator = allocator,
            .source = source,
            .extract_fn = opts.extract_fn,
            .extract_userdata = opts.extract_userdata,
        };
        return self;
    }

    pub fn destroy(self: *Self) void {
        self.allocator.destroy(self);
    }

    pub fn model(self: *Self) ListModel {
        return .{ .iface = &static_iface, .userdata = self };
    }

    /// 默认: 把 outer_item 当作 *ListModel
    fn defaultExtract(_: ?*anyopaque, outer_item: ?*anyopaque) ?ListModel {
        const p: *ListModel = @ptrCast(@alignCast(outer_item orelse return null));
        return p.*;
    }

    fn totalN(self: *Self) usize {
        var total: usize = 0;
        const outer_len = self.source.nItems();
        for (0..outer_len) |i| {
            const outer_item = self.source.iface.getItemFn(self.source.userdata, i);
            const inner = self.extract_fn(self.extract_userdata, outer_item);
            if (inner) |m| total += m.nItems();
        }
        return total;
    }

    fn locate(self: *Self, flat_pos: usize) struct { idx: usize, inner_model: ?ListModel, inner_pos: usize } {
        var remaining = flat_pos;
        const outer_len = self.source.nItems();
        for (0..outer_len) |i| {
            const outer_item = self.source.iface.getItemFn(self.source.userdata, i);
            const inner = self.extract_fn(self.extract_userdata, outer_item);
            const ilen = if (inner) |m| m.nItems() else 0;
            if (remaining < ilen) {
                return .{ .idx = i, .inner_model = inner, .inner_pos = remaining };
            }
            remaining -= ilen;
        }
        return .{ .idx = 0, .inner_model = null, .inner_pos = 0 };
    }

    fn getItemFn(userdata: ?*anyopaque, position: usize) ?*anyopaque {
        const self: *Self = @ptrCast(@alignCast(userdata orelse return null));
        const loc = self.locate(position);
        if (loc.inner_model == null) return null;
        return loc.inner_model.?.iface.getItemFn(loc.inner_model.?.userdata, loc.inner_pos);
    }

    fn getNItemsFn(userdata: ?*anyopaque) usize {
        const self: *Self = @ptrCast(@alignCast(userdata orelse return 0));
        return self.totalN();
    }

    fn getTypeFn(userdata: ?*anyopaque) []const u8 {
        _ = userdata;
        return "FlattenListModel";
    }
};

// ═══════════════════════════════════════════════════════════════════════════
// 测试
// ═══════════════════════════════════════════════════════════════════════════

test "SliceListModel: slice from middle" {
    const alloc = std.testing.allocator;
    var store = try list_model.StringListStore.new(alloc);
    defer store.destroy();
    for (0..10) |i| {
        const buf: [16]u8 = undefined;
        _ = buf;
        const n = try std.fmt.allocPrint(alloc, "{d}", .{i});
        defer alloc.free(n);
        try store.append(n);
    }
    const src = store.model();
    try std.testing.expectEqual(@as(usize, 10), src.nItems());

    var slice1 = try SliceListModel.create(alloc, src, .{ .offset = 0, .size = 0 }); // 全量
    defer slice1.destroy();
    try std.testing.expectEqual(@as(usize, 10), slice1.model().nItems());

    var slice2 = try SliceListModel.create(alloc, src, .{ .offset = 2, .size = 5 });
    defer slice2.destroy();
    try std.testing.expectEqual(@as(usize, 5), slice2.model().nItems());
    // [2] = "2"
    const v0 = slice2.model().getItem([]const u8, 0).?.*;
    try std.testing.expectEqualStrings("2", v0);
    // [6] = "6"
    const v4 = slice2.model().getItem([]const u8, 4).?.*;
    try std.testing.expectEqualStrings("6", v4);

    // 溢出 offset 应返回 0
    var slice3 = try SliceListModel.create(alloc, src, .{ .offset = 100, .size = 5 });
    defer slice3.destroy();
    try std.testing.expectEqual(@as(usize, 0), slice3.model().nItems());
}
