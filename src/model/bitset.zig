const std = @import("std");
const Allocator = std.mem.Allocator;
const testing = std.testing;

/// 对齐 GTK4: GtkBitset
/// 动态整数集合 (bitset 实现), 用于 SelectionModel 存储选中项
pub const Bitset = struct {
    allocator: Allocator,
    data: std.DynamicBitSetUnmanaged = .empty,
    /// 记录最小的 index 以便快速迭代, 等于 self.data.capacity() 表示空
    min_idx: usize = 0,
    /// 记录最大的 index + 1 以便快速迭代
    max_idx_plus_1: usize = 0,

    pub fn initEmpty(allocator: Allocator) Bitset {
        return .{ .allocator = allocator };
    }

    /// GTK4: gtk_bitset_new_range(start, n_items)
    pub fn initRange(allocator: Allocator, start: usize, n_items: usize) !Bitset {
        var self = Bitset{ .allocator = allocator };
        if (n_items > 0) {
            try self.data.resize(allocator, start + n_items, false);
            var i: usize = 0;
            while (i < n_items) : (i += 1) {
                self.data.set(start + i);
            }
            self.min_idx = start;
            self.max_idx_plus_1 = start + n_items;
        }
        return self;
    }

    pub fn deinit(self: *Bitset) void {
        self.data.deinit(self.allocator);
        self.* = undefined;
    }

    pub fn copy(self: *const Bitset) !Bitset {
        var r = Bitset{ .allocator = self.allocator };
        try r.data.resize(self.allocator, self.data.capacity(), false);
        var it = self.data.iterator(.{});
        while (it.next()) |i| r.data.set(i);
        r.min_idx = self.min_idx;
        r.max_idx_plus_1 = self.max_idx_plus_1;
        return r;
    }

    /// GTK4: gtk_bitset_contains
    pub fn contains(self: *const Bitset, index: usize) bool {
        if (index >= self.data.capacity()) return false;
        return self.data.isSet(index);
    }

    /// GTK4: gtk_bitset_add
    pub fn add(self: *Bitset, index: usize) !bool {
        try self.ensureCapacity(index + 1);
        const was = self.data.isSet(index);
        if (!was) self.data.set(index);
        if (index < self.min_idx) self.min_idx = index;
        if (index + 1 > self.max_idx_plus_1) self.max_idx_plus_1 = index + 1;
        return !was;
    }

    /// GTK4: gtk_bitset_remove
    pub fn remove(self: *Bitset, index: usize) bool {
        if (index >= self.data.capacity()) return false;
        const was = self.data.isSet(index);
        if (was) self.data.unset(index);
        if (was) {
            if (index == self.min_idx) self.recalcMin();
            if (index + 1 == self.max_idx_plus_1) self.recalcMax();
        }
        return was;
    }

    /// GTK4: gtk_bitset_add_range
    pub fn addRange(self: *Bitset, start: usize, n_items: usize) !void {
        if (n_items == 0) return;
        try self.ensureCapacity(start + n_items);
        var i: usize = 0;
        while (i < n_items) : (i += 1) self.data.set(start + i);
        if (start < self.min_idx) self.min_idx = start;
        if (start + n_items > self.max_idx_plus_1) self.max_idx_plus_1 = start + n_items;
    }

    /// GTK4: gtk_bitset_remove_range
    pub fn removeRange(self: *Bitset, start: usize, n_items: usize) void {
        if (n_items == 0) return;
        const cap = self.data.capacity();
        const end = @min(start + n_items, cap);
        var i: usize = start;
        while (i < end) : (i += 1) self.data.unset(i);
        self.recalcMin();
        self.recalcMax();
    }

    /// GTK4: gtk_bitset_remove_all
    pub fn removeAll(self: *Bitset) void {
        self.data.toggleAll(); // 只是清空，更直接用 resize(0)
        if (self.data.capacity() > 0) {
            // TODO: 更快的清空, DynamicBitSet 没有 clearAll
            self.data.deinit(self.allocator);
            self.data = .empty;
        }
        self.min_idx = 0;
        self.max_idx_plus_1 = 0;
    }

    /// GTK4: gtk_bitset_shift_left(amount)
    /// 所有 index 减 amount, 小于 0 的丢弃
    pub fn shiftLeft(self: *Bitset, amount: usize) void {
        if (amount == 0) return;
        const cap = self.data.capacity();
        if (cap == 0) return;
        // 简单实现: collect -> clear -> reinsert
        var list = std.ArrayList(usize).init(self.allocator);
        defer list.deinit();
        var it = self.data.iterator(.{});
        while (it.next()) |i| {
            if (i >= amount) list.append(i - amount) catch {};
        }
        self.removeAll();
        for (list.items) |i| self.add(i) catch {};
    }

    /// GTK4: gtk_bitset_shift_right(amount)
    /// 所有 index 加 amount
    pub fn shiftRight(self: *Bitset, amount: usize) void {
        if (amount == 0) return;
        const cap = self.data.capacity();
        if (cap == 0) return;
        var list = std.ArrayList(usize).init(self.allocator);
        defer list.deinit();
        var it = self.data.iterator(.{});
        while (it.next()) |i| list.append(i + amount) catch {};
        self.removeAll();
        for (list.items) |i| self.add(i) catch {};
    }

    /// 集合运算: self = self | other
    pub fn unionWith(self: *Bitset, other: *const Bitset) !void {
        var it = other.data.iterator(.{});
        while (it.next()) |i| _ = try self.add(i);
    }

    /// 集合运算: self = self & other
    pub fn intersectWith(self: *Bitset, other: *const Bitset) void {
        var to_remove = std.ArrayList(usize).init(self.allocator);
        defer to_remove.deinit();
        var it = self.data.iterator(.{});
        while (it.next()) |i| {
            if (!other.contains(i)) to_remove.append(i) catch {};
        }
        for (to_remove.items) |i| _ = self.remove(i);
    }

    /// 集合运算: self = self - other
    pub fn subtractWith(self: *Bitset, other: *const Bitset) void {
        var it = other.data.iterator(.{});
        while (it.next()) |i| _ = self.remove(i);
    }

    /// 集合运算: self = self ^ other
    pub fn symmetricDifferenceWith(self: *Bitset, other: *const Bitset) !void {
        var it = other.data.iterator(.{});
        while (it.next()) |i| {
            if (self.contains(i)) _ = self.remove(i)
            else _ = try self.add(i);
        }
    }

    /// GTK4: gtk_bitset_is_empty
    pub fn isEmpty(self: *const Bitset) bool {
        return self.data.count() == 0;
    }

    /// GTK4: gtk_bitset_get_size (set bits 数量)
    pub fn getSize(self: *const Bitset) usize {
        return self.data.count();
    }

    /// GTK4: gtk_bitset_get_minimum, 若无返回 maxInt(usize)
    pub fn getMinimum(self: *const Bitset) usize {
        if (self.isEmpty()) return std.math.maxInt(usize);
        if (self.contains(self.min_idx)) return self.min_idx;
        const it = self.data.iterator(.{});
        return it.next() orelse std.math.maxInt(usize);
    }

    /// GTK4: gtk_bitset_get_maximum, 若无返回 0
    pub fn getMaximum(self: *const Bitset) usize {
        if (self.isEmpty()) return 0;
        if (self.max_idx_plus_1 > 0 and self.contains(self.max_idx_plus_1 - 1)) return self.max_idx_plus_1 - 1;
        // 回退: 遍历查找最大
        var max_val: usize = 0;
        var it = self.data.iterator(.{});
        while (it.next()) |i| max_val = i;
        return max_val;
    }

    fn ensureCapacity(self: *Bitset, needed: usize) !void {
        const cap = self.data.capacity();
        if (needed > cap) {
            try self.data.resize(self.allocator, needed, false);
            if (self.max_idx_plus_1 == 0) {
                self.min_idx = std.math.maxInt(usize);
            }
        }
    }

    fn recalcMin(self: *Bitset) void {
        const cap = self.data.capacity();
        var i: usize = 0;
        while (i < cap) : (i += 1) {
            if (self.data.isSet(i)) {
                self.min_idx = i;
                return;
            }
        }
        self.min_idx = std.math.maxInt(usize);
    }

    fn recalcMax(self: *Bitset) void {
        const cap = self.data.capacity();
        if (cap == 0) {
            self.max_idx_plus_1 = 0;
            return;
        }
        var i = cap;
        while (i > 0) : (i -= 1) {
            if (self.data.isSet(i - 1)) {
                self.max_idx_plus_1 = i;
                return;
            }
        }
        self.max_idx_plus_1 = 0;
    }
};
