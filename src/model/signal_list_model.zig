//! SignalListModel — GListModel items-changed 信号机制
//!
//! GTK4 的 GListModel 自带 `items-changed` 信号（position, removed, added）。
//! 这里提供多回调槽的包装：套在任意 ListModel 外层，当数据源发生增删改时，
//! 通过 emitChanged 触发所有注册回调（通知 UI: ColumnView/GridView/ListView 重绘）。
//!

const std = @import("std");
const Allocator = std.mem.Allocator;
const list_model = @import("list_model.zig");
const ListModel = list_model.ListModel;
const ListModelIface = list_model.ListModelIface;
const ItemsChangedFn = list_model.ItemsChangedFn;

// ═══════════════════════════════════════════════════════════════════════════════
//  SignalListModel
// ═══════════════════════════════════════════════════════════════════════════════

/// 回调槽：用户 cb + userdata + 空闲 slot_id
const CallbackSlot = struct {
    cb: ItemsChangedFn,
    userdata: ?*anyopaque = null,
    /// slot_id = 数组索引 + 1（0 保留未占用）；删除时 slot_id 置 0 表示空槽
    slot_id: u32 = 0,
};

pub const SignalListModel = struct {
    /// 被包装的内部模型（所有 getItem/nItems/getItemType 委托它）
    inner: ListModel,
    /// 回调槽数组（删除时仅把 slot_id=0，不压缩，便于 slot_id 稳定）
    slots: std.ArrayListUnmanaged(CallbackSlot) = .{},

    const Self = @This();

    // ── 构造 / 析构 ────────────────────────────────────────────────────────

    /// 用一个已存在的 ListModel 包装（注意 inner 生命周期 ≥ SignalListModel）
    pub fn wrap(inner: ListModel) Self {
        return .{ .inner = inner };
    }

    pub fn deinit(self: *Self, allocator: Allocator) void {
        self.slots.deinit(allocator);
    }

    // ── 回调注册 ─────────────────────────────────────────────────────────

    /// 添加 items-changed 回调，返回稳定 slot_id（可用于 removeSlot）；≥1
    pub fn addOnItemsChanged(self: *Self, allocator: Allocator, cb: ItemsChangedFn, userdata: ?*anyopaque) !u32 {
        // 复用空槽
        for (self.slots.items, 0..) |*s, i| {
            if (s.slot_id == 0) {
                const new_id: u32 = @intCast(i + 1);
                s.* = .{ .cb = cb, .userdata = userdata, .slot_id = new_id };
                return new_id;
            }
        }
        const new_id: u32 = @intCast(self.slots.items.len + 1);
        try self.slots.append(allocator, .{ .cb = cb, .userdata = userdata, .slot_id = new_id });
        return new_id;
    }

    /// 按 slot_id 移除回调（保留槽位，不移动元素；下次 add 复用）
    pub fn removeSlot(self: *Self, slot_id: u32) void {
        if (slot_id == 0) return;
        const idx = slot_id - 1;
        if (idx < self.slots.items.len) self.slots.items[idx].slot_id = 0;
    }

    // ── 信号发射 ─────────────────────────────────────────────────────────

    /// 发射 items-changed 信号，通知所有仍注册的回调
    /// - position: 起始索引
    /// - removed:  在此之前该位置删除的元素数
    /// - added:    之后该位置新增的元素数
    pub fn emitChanged(self: *const Self, position: usize, removed: u32, added: u32) void {
        for (self.slots.items) |s| {
            if (s.slot_id != 0) s.cb(s.userdata, position, removed, added);
        }
    }

    // ── 包装为 ListModel（自身也能作为下游的源） ──────────────────────────

    const static_iface = ListModelIface{
        .getItemFn = getItemFn,
        .getNItemsFn = getNItemsFn,
        .getItemTypeFn = getTypeFn,
    };

    /// 返回一个把自身当作 ListModel 的视图，下游（Sort/Filter/Map）可再次嵌套
    pub fn model(self: *Self) ListModel {
        return .{ .iface = &static_iface, .userdata = self };
    }

    fn getItemFn(userdata: ?*anyopaque, position: usize) ?*anyopaque {
        const s: *Self = @ptrCast(@alignCast(userdata orelse return null));
        return s.inner.iface.getItemFn(s.inner.userdata, position);
    }
    fn getNItemsFn(userdata: ?*anyopaque) usize {
        const s: *Self = @ptrCast(@alignCast(userdata orelse return 0));
        return s.inner.nItems();
    }
    fn getTypeFn(userdata: ?*anyopaque) []const u8 {
        const s: *Self = @ptrCast(@alignCast(userdata orelse return "SignalListModel"));
        return s.inner.itemType();
    }
};
