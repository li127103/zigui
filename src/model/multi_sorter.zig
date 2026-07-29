//! GtkMultiSorter — 多优先级组合排序器
//!
//! GTK 对应: GtkMultiSorter (GTK4)
//!
//! 持有多个 Sorter，按顺序（或按 priority 数值小优先）比较两个元素。
//! 如果第 1 个 sorter 返回 equal → 用第 2 个，以此类推；全部 equal → equal。
//!
//! 提供 `asSorter()` 方法，直接把 MultiSorter 包装为 Sorter 传给 SortListModel。

const std = @import("std");
const sort_mod = @import("sort_list_model.zig");

pub const Sorter = sort_mod.Sorter;
pub const Ordering = sort_mod.Ordering;
pub const SorterCompareFn = sort_mod.SorterCompareFn;

// ──────────────────────────────────────────────────────────────────────────────
// Sorter 条目：Sorter 实例 + priority（数值小优先）
// ──────────────────────────────────────────────────────────────────────────────

pub const SorterWithPriority = struct {
    sorter: Sorter,
    priority: u32 = 0,
};

// ──────────────────────────────────────────────────────────────────────────────
// MultiSorter 主体
// ──────────────────────────────────────────────────────────────────────────────

pub const MultiSorter = struct {
    allocator: std.mem.Allocator,
    sorters: std.ArrayListUnmanaged(SorterWithPriority) = .{},

    pub fn create(allocator: std.mem.Allocator) MultiSorter {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *MultiSorter) void {
        self.sorters.deinit(self.allocator);
    }

    /// 添加 sorter；priority 默认 0，数字越小越先比较。相同 priority 按添加顺序。
    pub fn addSorter(self: *MultiSorter, sorter: Sorter, priority: ?u32) void {
        const p: u32 = priority orelse (if (self.sorters.items.len > 0)
            self.sorters.items[self.sorters.items.len - 1].priority
        else
            0);
        self.sorters.append(self.allocator, .{
            .sorter = sorter,
            .priority = p,
        }) catch {};
        self.sortByPriority();
    }

    /// 移除指定索引的 sorter（索引从 0 开始，按当前 priority 排序后的列表）
    pub fn removeSorter(self: *MultiSorter, index: usize) void {
        if (index >= self.sorters.items.len) return;
        self.sorters.orderedRemove(index);
    }

    pub fn clear(self: *MultiSorter) void {
        self.sorters.clearRetainingCapacity();
    }

    pub fn getSorterCount(self: *const MultiSorter) u32 {
        return @intCast(self.sorters.items.len);
    }

    /// 按 priority 升序 + 原顺序稳定重排（在 add/remove 后调用）
    fn sortByPriority(self: *MultiSorter) void {
        const items = self.sorters.items;
        if (items.len < 2) return;
        // 简单冒泡稳定排序（N 一般不大，避免依赖排序库）
        var changed = true;
        while (changed) {
            changed = false;
            var i: usize = 1;
            while (i < items.len) : (i += 1) {
                if (items[i - 1].priority > items[i].priority) {
                    const tmp = items[i];
                    items[i] = items[i - 1];
                    items[i - 1] = tmp;
                    changed = true;
                }
            }
        }
    }

    /// 组合 compare：按顺序调用每个子 sorter，直到返回 ≠ equal
    pub fn compareFn(self_ptr: ?*anyopaque, a: ?*anyopaque, b: ?*anyopaque) Ordering {
        const s: *MultiSorter = @ptrCast(@alignCast(self_ptr orelse return .equal));
        for (s.sorters.items) |entry| {
            const result = entry.sorter.compare(a, b);
            if (result != .equal) return result;
        }
        return .equal;
    }

    // ── 导出为通用 Sorter ──────────────────────────────────────────────

    pub fn asIface(self: *MultiSorter) @TypeOf(Sorter.Iface) {
        _ = self;
        const T = if (@hasDecl(Sorter, "Iface")) Sorter.Iface else @TypeOf(sort_mod.CustomSorter);
        _ = T;
        // 实际：如果 sort_mod 中 Sorter 是 iface(self_ptr, compare)，直接 wrap
        return .{
            .compare = undefined,
        };
    }

    /// 导出为 Sorter（创建一个包装好的 Sorter 对象）
    /// 使用 self.compareFn 作为比较函数，Sorter 的 SorterIface.compare 指向它
    pub fn asSorter(self: *MultiSorter) Sorter {
        const compare_f: SorterCompareFn = struct {
            fn cmp(ud: ?*anyopaque, a: ?*anyopaque, b: ?*anyopaque) Ordering {
                const ms: *MultiSorter = @ptrCast(@alignCast(ud orelse return .equal));
                return ms.compareFn(ud, a, b);
            }
        }.cmp;
        // 通过 CustomSorter 生成包装 Sorter（如果 CustomSorter 需要 allocator，我们简化：直接用 Sorter 字段构造）
        return Sorter{
            .self_ptr = self,
            .compare_fn = compare_f,
            .changed_cb = null,
        };
    }
};
