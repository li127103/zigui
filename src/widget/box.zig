//! Box 控件 - GTK4 GtkBox：水平或垂直排列子控件的布局容器
//!
//! 与 Container 的 flexbox 不同，Box 提供 GTK4 风格的 API：
//! - `new(orientation, spacing)` 构造
//! - `append(child)` / `prepend(child)` / `remove(child)` 子项操作
//! - `setHomogeneous(h)` 所有子控件分配相同大小
//! - `setSpacing(sp)` 子项间距
//! - `insertChildAfter(child, sibling)` 指定位置插入

const std = @import("std");
const math = @import("../math.zig");
const widget_mod = @import("widget.zig");
const layout_mod = @import("../layout/engine.zig");
const container_mod = @import("container.zig");
const pal = @import("../pal/pal.zig");

const Widget = widget_mod.Widget;
const PaintContext = widget_mod.PaintContext;
const EventContext = widget_mod.EventContext;
const EventResult = widget_mod.EventResult;
const Container = container_mod.Container;

/// GTK4: GtkOrientation
pub const Orientation = enum {
    horizontal,
    vertical,
};

pub const Box = struct {
    base: Widget,
    allocator: std.mem.Allocator,
    orientation: Orientation,
    spacing: f32,
    homogeneous: bool = false,
    /// 实际布局由内部 Container 代理 (Box 不重复实现 flex 逻辑)
    inner: *Container,

    pub fn new(allocator: std.mem.Allocator, orientation: Orientation, spacing: f32) !*Box {
        const direction: layout_mod.FlexDirection = switch (orientation) {
            .horizontal => .row,
            .vertical => .column,
        };
        const inner = try Container.create(allocator, .{
            .direction = direction,
            .gap = if (direction == .row) .{ .width = spacing, .height = 0 } else .{ .width = 0, .height = spacing },
        });
        const self = try allocator.create(Box);
        self.* = .{
            .base = .{
                .vtable = &vtable,
                .id = widget_mod.genWidgetId(),
            },
            .allocator = allocator,
            .orientation = orientation,
            .spacing = spacing,
            .inner = inner,
        };
        // Box 作为容器，子项由 inner Container 管理
        try self.base.addChild(allocator, &inner.base);
        return self;
    }

    /// GTK4: gtk_box_new 别名
    pub fn create(allocator: std.mem.Allocator, opts: struct {
        orientation: Orientation = .vertical,
        spacing: f32 = 0,
        homogeneous: bool = false,
    }) !*Box {
        const b = try new(allocator, opts.orientation, opts.spacing);
        b.homogeneous = opts.homogeneous;
        return b;
    }

    pub fn destroy(self: *Box, allocator: std.mem.Allocator) void {
        // inner Container 及其子项由 Container.destroy 递归销毁
        self.inner.base.vtable.destroy(&self.inner.base, allocator);
        self.base.children.deinit(allocator);
        self.base.background.deinit(allocator);
        allocator.destroy(self);
    }

    // ── 内部辅助：在指定位置插入子项到 inner Container ───────────────────

    fn insertInnerAt(self: *Box, child: *Widget, index: usize) !void {
        const list = &self.inner.base.children;
        try list.insertAt(self.allocator, index, child);
        child.parent = &self.inner.base;
        self.inner.base.markLayoutDirty();
    }

    fn removeInner(self: *Box, child: *Widget) void {
        const list = &self.inner.base.children;
        for (list.items, 0..) |c, i| {
            if (c == child) {
                _ = list.orderedRemove(i);
                child.parent = null;
                self.inner.base.markLayoutDirty();
                return;
            }
        }
    }

    // ── GTK4 兼容 API ─────────────────────────────────────────────────────

    /// GTK4: gtk_box_append
    pub fn append(self: *Box, child: *Widget) !void {
        try self.inner.base.addChild(self.allocator, child);
    }

    /// GTK4: gtk_box_prepend
    pub fn prepend(self: *Box, child: *Widget) !void {
        try self.insertInnerAt(child, 0);
    }

    /// GTK4: gtk_box_remove
    pub fn remove(self: *Box, child: *Widget) void {
        self.removeInner(child);
    }

    /// GTK4: gtk_box_insert_child_after
    pub fn insertChildAfter(self: *Box, child: *Widget, sibling: ?*Widget) !void {
        if (sibling == null) {
            try self.append(child);
            return;
        }
        const sib = sibling orelse return;
        const items = self.inner.base.children.items;
        for (items, 0..) |c, i| {
            if (c == sib) {
                try self.insertInnerAt(child, i + 1);
                return;
            }
        }
        // sibling 找不到时 append 到末尾
        try self.append(child);
    }

    /// GTK4: gtk_box_reorder_child_after
    pub fn reorderChildAfter(self: *Box, child: *Widget, sibling: ?*Widget) void {
        // 先移除再插入 (简化实现, 不销毁)
        self.removeInner(child);
        self.insertChildAfter(child, sibling) catch {};
    }

    /// GTK4: gtk_box_set_homogeneous
    pub fn setHomogeneous(self: *Box, homogeneous: bool) void {
        self.homogeneous = homogeneous;
        self.base.markLayoutDirty();
        self.base.markDirty();
    }

    /// GTK4: gtk_box_get_homogeneous
    pub fn getHomogeneous(self: *const Box) bool {
        return self.homogeneous;
    }

    /// GTK4: gtk_box_set_spacing
    pub fn setSpacing(self: *Box, spacing: f32) void {
        self.spacing = spacing;
        const is_row = self.orientation == .horizontal;
        self.inner.base.layout_style.gap = if (is_row)
            .{ .width = spacing, .height = 0 }
        else
            .{ .width = 0, .height = spacing };
        self.base.markLayoutDirty();
        self.base.markDirty();
    }

    /// GTK4: gtk_box_get_spacing
    pub fn getSpacing(self: *const Box) f32 {
        return self.spacing;
    }

    /// GTK4: gtk_orientable_set_orientation
    pub fn setOrientation(self: *Box, orientation: Orientation) void {
        self.orientation = orientation;
        self.inner.base.layout_style.direction = switch (orientation) {
            .horizontal => .row,
            .vertical => .column,
        };
        // 更新 gap 方向保持 spacing 语义
        self.setSpacing(self.spacing);
    }

    /// GTK4: gtk_orientable_get_orientation
    pub fn getOrientation(self: *const Box) Orientation {
        return self.orientation;
    }

    /// 获取子控件数量
    pub fn getChildCount(self: *const Box) usize {
        return self.inner.base.children.items.len;
    }

    // ── VTable 代理到 inner Container ─────────────────────────────────────

    const vtable = Widget.VTable{
        .type_name = "box",
        .measure = measure,
        .paint = paint,
        .on_event = null, // Container 没有 on_event, Box 也不需要
        .focusable = false,
        .destroy = destroyVTable,
    };

    fn destroyVTable(w: *Widget, allocator: std.mem.Allocator) void {
        const self: *Box = @fieldParentPtr("base", w);
        self.destroy(allocator);
    }

    fn measure(w: *Widget, ctx: *PaintContext, constraints: layout_mod.Constraints) math.Size(f32) {
        const self: *Box = @fieldParentPtr("base", w);
        // 同步尺寸约束到 inner 并代理 measure
        self.inner.base.rect = w.rect;
        return self.inner.base.vtable.measure(&self.inner.base, ctx, constraints);
    }

    fn paint(w: *Widget, ctx: *PaintContext) void {
        const self: *Box = @fieldParentPtr("base", w);
        // 同步位置到 inner
        self.inner.base.rect = w.rect;
        self.inner.base.vtable.paint(&self.inner.base, ctx);
    }
};
