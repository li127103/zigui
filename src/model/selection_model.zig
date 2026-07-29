//! SelectionModel — GTK4 选择模型集 (对应 GtkSelectionModel / GtkNoSelection / GtkSingleSelection / GtkMultiSelection)
//!
//! 架构:
//! - `SelectionModel` — 胖指针接口 + 通用 API: `isSelected`, `selectItem`, `unselectItem`,
//!   `getSelection` 返回位集合, 以及 `selectionChanged(position, n_items)` 信号。
//! - `NoSelection` — 所有项都不可选中 (用于纯展示视图)
//! - `SingleSelection` — 0 或 1 个选中项, 支持 `autoselect`, `canUnselect`, `selected` 字段
//! - `MultiSelection` — 任意项可选, 内部用 `DynamicBitSetUnmanaged`

const std = @import("std");
const Allocator = std.mem.Allocator;
const list_mod = @import("list_model.zig");
const ListModel = list_mod.ListModel;

/// 选择变更回调: (position, 变更范围长度)
pub const SelectionChangedFn = *const fn (
    userdata: ?*anyopaque,
    position: usize,
    n_items: usize,
) void;

/// 通用选择模型接口 (虚函数表)
pub const SelectionModelIface = struct {
    /// 项是否被选中
    isSelectedFn: *const fn (userdata: ?*anyopaque, position: usize) bool,
    /// 选中指定项 (true 表示成功，false 表示操作被抑制)
    selectItemFn: *const fn (userdata: ?*anyopaque, position: usize, exclusive: bool) bool,
    /// 取消选中
    unselectItemFn: *const fn (userdata: ?*anyopaque, position: usize) bool,
    /// 选中所有
    selectAllFn: ?*const fn (userdata: ?*anyopaque) bool = null,
    /// 取消所有
    unselectAllFn: ?*const fn (userdata: ?*anyopaque) bool = null,
    /// 选中范围 [position, position + n_items)
    selectRangeFn: ?*const fn (userdata: ?*anyopaque, position: usize, n_items: usize, exclusive: bool) bool = null,
    /// 取被选中的范围之一 (for iteration). 传入 cursor (=0, 初始)，返回下一个 cursor (end of range 之后)
    getSelectionInRangeFn: ?*const fn (
        userdata: ?*anyopaque,
        position: usize,
        n_items: usize,
    ) std.DynamicBitSet = null,
    /// 返回 model (SelectionModel 总是带一个 model)
    getModelFn: *const fn (userdata: ?*anyopaque) ListModel,
    /// 当前选中数量 (用于 UI 快速判定)
    getSelectionSizeFn: ?*const fn (userdata: ?*anyopaque) usize = null,
};

/// 擦除类型的胖指针
pub const SelectionModel = struct {
    iface: *const SelectionModelIface,
    userdata: ?*anyopaque = null,
    /// 变更回调
    on_selection_changed: ?SelectionChangedFn = null,
    on_selection_changed_userdata: ?*anyopaque = null,

    pub fn isSelected(self: SelectionModel, position: usize) bool {
        return self.iface.isSelectedFn(self.userdata, position);
    }

    pub fn selectItem(self: SelectionModel, position: usize, exclusive: bool) bool {
        return self.iface.selectItemFn(self.userdata, position, exclusive);
    }

    pub fn unselectItem(self: SelectionModel, position: usize) bool {
        return self.iface.unselectItemFn(self.userdata, position);
    }

    pub fn selectAll(self: SelectionModel) bool {
        if (self.iface.selectAllFn) |f| return f(self.userdata);
        return false;
    }

    pub fn unselectAll(self: SelectionModel) bool {
        if (self.iface.unselectAllFn) |f| return f(self.userdata);
        return false;
    }

    pub fn model(self: SelectionModel) ListModel {
        return self.iface.getModelFn(self.userdata);
    }

    pub fn selectionSize(self: SelectionModel) usize {
        if (self.iface.getSelectionSizeFn) |f| return f(self.userdata);
        // 退化
        var cnt: usize = 0;
        const n = self.model().nItems();
        var i: usize = 0;
        while (i < n) : (i += 1) {
            if (self.isSelected(i)) cnt += 1;
        }
        return cnt;
    }

    /// 返回第一个被选中的 position；若未选中返回 null
    pub fn getFirstSelected(self: SelectionModel) ?usize {
        const n = self.model().nItems();
        var i: usize = 0;
        while (i < n) : (i += 1) {
            if (self.isSelected(i)) return i;
        }
        return null;
    }

    pub fn emitChanged(self: *SelectionModel, position: usize, n_items: usize) void {
        if (self.on_selection_changed) |cb| {
            cb(self.on_selection_changed_userdata, position, n_items);
        }
    }
};

// ──────────────────────────────────────────────────────────
// NoSelection
// ──────────────────────────────────────────────────────────

pub const NoSelection = struct {
    const Self = @This();

    backing: ListModel,
    iface_instance: SelectionModelIface,

    const static_iface_template = blk: {
        const iface = SelectionModelIface{
            .isSelectedFn = &isSelectedFn,
            .selectItemFn = &selectItemFn,
            .unselectItemFn = &unselectItemFn,
            .getModelFn = &getModelFn,
        };
        break :blk iface;
    };

    pub fn new(backing: ListModel) Self {
        const iface = static_iface_template;
        return Self{
            .backing = backing,
            .iface_instance = iface,
        };
    }

    /// 取得 SelectionModel 接口胖指针
    pub fn asSelection(self: *Self) SelectionModel {
        return .{
            .iface = &self.iface_instance,
            .userdata = self,
        };
    }

    fn isSelectedFn(_: ?*anyopaque, _: usize) bool {
        return false;
    }

    fn selectItemFn(_: ?*anyopaque, _: usize, _: bool) bool {
        return false;
    }

    fn unselectItemFn(_: ?*anyopaque, _: usize) bool {
        return false;
    }

    fn getModelFn(userdata: ?*anyopaque) ListModel {
        const self: *Self = @ptrCast(@alignCast(userdata orelse unreachable));
        return self.backing;
    }
};

// ──────────────────────────────────────────────────────────
// SingleSelection
// ──────────────────────────────────────────────────────────

pub const SingleSelection = struct {
    const Self = @This();

    backing: ListModel,
    selected: ?usize = null,
    autoselect: bool = true, // 当 model 变了 / selected 超界时自动选中第 0 项
    can_unselect: bool = false, // 允许点击已选中项取消选中
    iface_instance: SelectionModelIface,
    /// 外部: 连接到 SelectionModel 的回调指针会存在这里
    parent_sel_model: SelectionModel = undefined,

    const static_iface_template = blk: {
        const iface = SelectionModelIface{
            .isSelectedFn = &isSelectedFn,
            .selectItemFn = &selectItemFn,
            .unselectItemFn = &unselectItemFn,
            .selectAllFn = &selectAllFn,
            .unselectAllFn = &unselectAllFn,
            .getSelectionSizeFn = &getSelectionSizeFn,
            .getModelFn = &getModelFn,
        };
        break :blk iface;
    };

    pub fn new(allocator: Allocator, backing: ListModel, opts: struct {
        selected: ?usize = null,
        autoselect: bool = true,
        can_unselect: bool = false,
    }) !*Self {
        const self: *Self = try allocator.create(Self);
        self.* = Self{
            .backing = backing,
            .selected = opts.selected,
            .autoselect = opts.autoselect,
            .can_unselect = opts.can_unselect,
            .iface_instance = static_iface_template,
        };
        // 初始 autoselect
        if (self.autoselect and self.selected == null and backing.nItems() > 0) {
            self.selected = 0;
        }
        return self;
    }

    pub fn destroy(self: *Self, allocator: Allocator) void {
        allocator.destroy(self);
    }

    pub fn asSelection(self: *Self) *SelectionModel {
        self.parent_sel_model = .{
            .iface = &self.iface_instance,
            .userdata = self,
        };
        return &self.parent_sel_model;
    }

    pub fn getSelected(self: *const Self) ?usize {
        // 边界检查
        if (self.selected) |s| {
            if (s >= self.backing.nItems()) return null;
        }
        return self.selected;
    }

    pub fn setSelected(self: *Self, position: ?usize) bool {
        const old = self.selected;
        if (position) |p| {
            if (p >= self.backing.nItems()) return false;
            self.selected = p;
        } else if (self.can_unselect) {
            self.selected = null;
        } else {
            if (self.backing.nItems() > 0 and self.autoselect) {
                self.selected = 0;
            } else {
                self.selected = null;
            }
        }
        const low = @min(old orelse usize.max, self.selected orelse usize.max);
        const high = @max(old orelse 0, self.selected orelse 0);
        const start = if (low == usize.max) 0 else low;
        const len = if (high > start) (high - start + 1) else 1;
        self.parent_sel_model.emitChanged(start, len);
        return true;
    }

    fn isSelectedFn(userdata: ?*anyopaque, position: usize) bool {
        const self: *Self = @ptrCast(@alignCast(userdata orelse return false));
        if (self.selected) |s| return s == position;
        return false;
    }

    fn selectItemFn(userdata: ?*anyopaque, position: usize, exclusive: bool) bool {
        const self: *Self = @ptrCast(@alignCast(userdata orelse return false));
        _ = exclusive;
        // 取消已选中 (can_unselect)
        if (self.selected) |s| {
            if (s == position and self.can_unselect) {
                self.selected = null;
                self.parent_sel_model.emitChanged(position, 1);
                return true;
            }
        }
        if (position >= self.backing.nItems()) return false;
        const changed_low = @min(self.selected orelse position, position);
        const changed_high = @max(self.selected orelse position, position);
        self.selected = position;
        self.parent_sel_model.emitChanged(changed_low, changed_high - changed_low + 1);
        return true;
    }

    fn unselectItemFn(userdata: ?*anyopaque, position: usize) bool {
        const self: *Self = @ptrCast(@alignCast(userdata orelse return false));
        if (self.selected) |s| {
            if (s == position) {
                self.setSelected(null);
                return true;
            }
        }
        return false;
    }

    fn selectAllFn(userdata: ?*anyopaque) bool {
        const self: *Self = @ptrCast(@alignCast(userdata orelse return false));
        // SingleSelection: select 第 0
        if (self.backing.nItems() > 0) {
            return self.selectItemFn(userdata, 0, true);
        }
        return false;
    }

    fn unselectAllFn(userdata: ?*anyopaque) bool {
        const self: *Self = @ptrCast(@alignCast(userdata orelse return false));
        if (self.selected == null) return false;
        const pos = self.selected orelse 0;
        self.selected = null;
        self.parent_sel_model.emitChanged(pos, 1);
        return true;
    }

    fn getSelectionSizeFn(userdata: ?*anyopaque) usize {
        const self: *Self = @ptrCast(@alignCast(userdata orelse return 0));
        return if (self.getSelected() != null) 1 else 0;
    }

    fn getModelFn(userdata: ?*anyopaque) ListModel {
        const self: *Self = @ptrCast(@alignCast(userdata orelse unreachable));
        return self.backing;
    }
};

// ──────────────────────────────────────────────────────────
// MultiSelection
// ──────────────────────────────────────────────────────────

pub const MultiSelection = struct {
    const Self = @This();

    allocator: Allocator,
    backing: ListModel,
    selected: std.DynamicBitSetUnmanaged = .{},
    iface_instance: SelectionModelIface,
    parent_sel_model: SelectionModel = undefined,

    const static_iface_template = blk: {
        const iface = SelectionModelIface{
            .isSelectedFn = &isSelectedFn,
            .selectItemFn = &selectItemFn,
            .unselectItemFn = &unselectItemFn,
            .selectAllFn = &selectAllFn,
            .unselectAllFn = &unselectAllFn,
            .selectRangeFn = &selectRangeFn,
            .getSelectionSizeFn = &getSelectionSizeFn,
            .getModelFn = &getModelFn,
        };
        break :blk iface;
    };

    pub fn new(allocator: Allocator, backing: ListModel) !*Self {
        const self = try allocator.create(Self);
        self.* = .{
            .allocator = allocator,
            .backing = backing,
            .selected = try std.DynamicBitSetUnmanaged.initEmpty(allocator, @max(64, backing.nItems())),
            .iface_instance = static_iface_template,
        };
        return self;
    }

    pub fn destroy(self: *Self) void {
        self.selected.deinit(self.allocator);
        self.allocator.destroy(self);
    }

    pub fn asSelection(self: *Self) *SelectionModel {
        self.parent_sel_model = .{
            .iface = &self.iface_instance,
            .userdata = self,
        };
        return &self.parent_sel_model;
    }

    fn ensureCapacity(self: *Self, n: usize) void {
        if (self.selected.capacity() < n) {
            self.selected.resize(self.allocator, @max(self.selected.capacity() * 2, n), false) catch {};
        }
    }

    fn isSelectedFn(userdata: ?*anyopaque, position: usize) bool {
        const self: *Self = @ptrCast(@alignCast(userdata orelse return false));
        self.ensureCapacity(position + 1);
        if (position >= self.backing.nItems()) return false;
        return self.selected.isSet(position);
    }

    fn selectItemFn(userdata: ?*anyopaque, position: usize, exclusive: bool) bool {
        const self: *Self = @ptrCast(@alignCast(userdata orelse return false));
        if (position >= self.backing.nItems()) return false;
        self.ensureCapacity(position + 1);
        if (exclusive) {
            self.selected.setRangeValue(0, self.selected.capacity(), false);
        }
        if (self.selected.isSet(position)) return true; // 已选中
        self.selected.set(position);
        self.parent_sel_model.emitChanged(position, 1);
        return true;
    }

    fn unselectItemFn(userdata: ?*anyopaque, position: usize) bool {
        const self: *Self = @ptrCast(@alignCast(userdata orelse return false));
        self.ensureCapacity(position + 1);
        if (!self.selected.isSet(position)) return false;
        self.selected.unset(position);
        self.parent_sel_model.emitChanged(position, 1);
        return true;
    }

    fn selectAllFn(userdata: ?*anyopaque) bool {
        const self: *Self = @ptrCast(@alignCast(userdata orelse return false));
        const n = self.backing.nItems();
        if (n == 0) return false;
        self.ensureCapacity(n);
        self.selected.setRangeValue(0, n, true);
        self.parent_sel_model.emitChanged(0, n);
        return true;
    }

    fn unselectAllFn(userdata: ?*anyopaque) bool {
        const self: *Self = @ptrCast(@alignCast(userdata orelse return false));
        const n = @min(self.selected.capacity(), self.backing.nItems());
        if (n == 0) return false;
        self.selected.setRangeValue(0, n, false);
        self.parent_sel_model.emitChanged(0, n);
        return true;
    }

    fn selectRangeFn(userdata: ?*anyopaque, position: usize, n_items: usize, exclusive: bool) bool {
        const self: *Self = @ptrCast(@alignCast(userdata orelse return false));
        const n = self.backing.nItems();
        const real_end = @min(position + n_items, n);
        if (position >= real_end) return false;
        const count = real_end - position;
        self.ensureCapacity(real_end);
        if (exclusive) {
            self.selected.setRangeValue(0, self.selected.capacity(), false);
        }
        self.selected.setRangeValue(position, count, true);
        self.parent_sel_model.emitChanged(position, count);
        return true;
    }

    fn getSelectionSizeFn(userdata: ?*anyopaque) usize {
        const self: *Self = @ptrCast(@alignCast(userdata orelse return 0));
        var it = self.selected.iterator(.{});
        var cnt: usize = 0;
        while (it.next()) |_| cnt += 1;
        return cnt;
    }

    fn getModelFn(userdata: ?*anyopaque) ListModel {
        const self: *Self = @ptrCast(@alignCast(userdata orelse unreachable));
        return self.backing;
    }
};
