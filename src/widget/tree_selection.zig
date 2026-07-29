//! TreeSelection — TreeView 选择模型
//!
//! 对标 GtkTreeSelection：
//!   - 四种选择模式：none / single / browse / multiple
//!   - 支持 selectNode/unselectNode/selectAll/unselectAll；每次变化触发 onChanged
//!   - 为避免与 tree_view.zig 的具体 Node 类型耦合，这里对"节点指针"做两层支持：
//!     1) 若调用方能保证指针类型对齐 tree_view.Node，则直接用 typed API
//!     2) 通用 API 用 ?*anyopaque（NodeOpaque = ?*anyopaque）
//!

const std = @import("std");

pub const SelectionMode = enum(u2) {
    none,
    single,
    browse, // = single + 必须有一个选中
    multiple,
};

const NodeOpaque = ?*anyopaque;

const ChangedFn = *const fn (ud: ?*anyopaque) void;

pub const TreeSelection = struct {
    mode: SelectionMode = .single,
    owner: ?*anyopaque = null, // 类型擦除指向 TreeView

    // 单/浏览模式
    single_selected: NodeOpaque = null,

    // 多选模式
    multi_selected: std.AutoHashMapUnmanaged(NodeOpaque, void) = .{},

    // 回调
    on_changed: ?ChangedFn = null,
    on_changed_ud: ?*anyopaque = null,

    const Self = @This();

    pub fn init(mode: SelectionMode) Self {
        return .{ .mode = mode };
    }

    pub fn deinit(self: *Self, allocator: std.mem.Allocator) void {
        self.multi_selected.deinit(allocator);
    }

    // ── 模式 ────────────────────────────────────────────────────────────

    pub fn setMode(self: *Self, allocator: std.mem.Allocator, mode: SelectionMode) void {
        if (mode == self.mode) return;
        // 清空当前选择
        self.single_selected = null;
        if (self.multi_selected.count() > 0) {
            self.multi_selected.clearAndFree(allocator);
        }
        self.mode = mode;
        self.emitChanged();
    }
    pub fn getMode(self: *const Self) SelectionMode { return self.mode; }

    // ── 选择变更 ────────────────────────────────────────────────────────

    pub fn selectNode(self: *Self, allocator: std.mem.Allocator, node: NodeOpaque) void {
        switch (self.mode) {
            .none => {},
            .single, .browse => {
                self.single_selected = node;
                self.emitChanged();
            },
            .multiple => {
                if (node == null) return;
                self.multi_selected.put(allocator, node, {}) catch return;
                self.emitChanged();
            },
        }
    }

    pub fn unselectNode(self: *Self, node: NodeOpaque) void {
        switch (self.mode) {
            .none => {},
            .single => {
                if (self.single_selected == node) {
                    self.single_selected = null;
                    self.emitChanged();
                }
            },
            .browse => {
                // browse 不允许全空；忽略
            },
            .multiple => {
                if (self.multi_selected.remove(node)) self.emitChanged();
            },
        }
    }

    pub fn selectAll(self: *Self, allocator: std.mem.Allocator, node_iterator: anytype) void {
        if (self.mode != .multiple) return;
        var changed = false;
        while (node_iterator.next()) |n| {
            const np: NodeOpaque = n;
            const gop = self.multi_selected.getOrPut(allocator, np) catch continue;
            if (!gop.found_existing) changed = true;
        }
        if (changed) self.emitChanged();
    }

    pub fn unselectAll(self: *Self, allocator: std.mem.Allocator) void {
        switch (self.mode) {
            .none => {},
            .single => {
                if (self.single_selected != null) { self.single_selected = null; self.emitChanged(); }
            },
            .browse => {},
            .multiple => {
                if (self.multi_selected.count() > 0) {
                    self.multi_selected.clearAndFree(allocator);
                    self.emitChanged();
                }
            },
        }
    }

    // ── 查询 ────────────────────────────────────────────────────────────

    pub fn isSelected(self: *const Self, node: NodeOpaque) bool {
        return switch (self.mode) {
            .none => false,
            .single, .browse => self.single_selected == node,
            .multiple => self.multi_selected.contains(node),
        };
    }

    /// 返回选中行数量
    pub fn countSelectedRows(self: *const Self) u32 {
        return switch (self.mode) {
            .none => 0,
            .single, .browse => if (self.single_selected != null) 1 else 0,
            .multiple => @intCast(self.multi_selected.count()),
        };
    }

    /// 获取单选选中的节点（多选模式返回任意一个或 null）
    pub fn getSelected(self: *const Self) NodeOpaque {
        return switch (self.mode) {
            .single, .browse => self.single_selected,
            .multiple => if (self.multi_selected.keyIterator().next()) |k| k.* else null,
            .none => null,
        };
    }

    // ── 回调 ─────────────────────────────────────────────────────────────

    pub fn setOnChanged(self: *Self, cb: ?ChangedFn, ud: ?*anyopaque) void {
        self.on_changed = cb;
        self.on_changed_ud = ud;
    }

    fn emitChanged(self: *Self) void {
        if (self.on_changed) |cb| cb(self.on_changed_ud);
    }
};
