//! Stack 控件 - 多页面堆叠容器
//!
//! 类似 GtkStack: 多个子控件堆叠在一起, 同一时间只显示一个页面。
//! 通过 setVisibleChild / setVisibleIndex 切换页面。

const std = @import("std");
const math = @import("../math.zig");
const widget_mod = @import("widget.zig");
const layout_mod = @import("../layout/engine.zig");
const pal = @import("../pal/pal.zig");

const Widget = widget_mod.Widget;
const PaintContext = widget_mod.PaintContext;
const EventContext = widget_mod.EventContext;
const EventResult = widget_mod.EventResult;

pub const Stack = struct {
    base: Widget,
    allocator: std.mem.Allocator,
    visible_index: usize = 0,

    pub fn create(allocator: std.mem.Allocator, opts: struct {
        bg_color: ?math.Color = null,
        corner_radius: f32 = 0,
        visible_index: usize = 0,
        width: layout_mod.Dimension = .{ .auto = {} },
        height: layout_mod.Dimension = .{ .auto = {} },
    }) !*Stack {
        const self = try allocator.create(Stack);
        self.* = .{
            .base = .{
                .vtable = &vtable,
                .id = widget_mod.genWidgetId(),
            },
            .allocator = allocator,
            .visible_index = opts.visible_index,
        };
        if (opts.bg_color) |c| {
            self.base.background.bg = .{ .color = c };
        }
        self.base.background.corner_radius = opts.corner_radius;
        self.base.layout_style.width = opts.width;
        self.base.layout_style.height = opts.height;
        self.base.accessibility = .{ .role = .container };
        return self;
    }

    pub fn destroy(self: *Stack, allocator: std.mem.Allocator) void {
        self.base.background.deinit(allocator);
        for (self.base.children.items) |child| {
            child.vtable.destroy(child, allocator);
        }
        self.base.children.deinit(allocator);
        allocator.destroy(self);
    }

    /// 添加子页面
    pub fn addChild(self: *Stack, child: *Widget) !void {
        const index = self.base.children.items.len;
        try self.base.addChild(self.allocator, child);
        if (index == self.visible_index) {
            child.state.visible = true;
        } else {
            child.state.visible = false;
        }
    }

    /// 切换到指定索引的页面
    pub fn setVisibleIndex(self: *Stack, index: usize) void {
        if (index >= self.base.children.items.len) return;
        if (index == self.visible_index) return;
        const children = self.base.children.items;
        children[self.visible_index].state.visible = false;
        self.visible_index = index;
        children[self.visible_index].state.visible = true;
        self.base.markLayoutDirty();
    }

    /// 获取当前可见页面索引
    pub fn getVisibleIndex(self: *Stack) usize {
        return self.visible_index;
    }

    /// 切换到下一页 (循环)
    pub fn next(self: *Stack) void {
        const n = self.base.children.items.len;
        if (n == 0) return;
        self.setVisibleIndex((self.visible_index + 1) % n);
    }

    /// 切换到上一页 (循环)
    pub fn prev(self: *Stack) void {
        const n = self.base.children.items.len;
        if (n == 0) return;
        self.setVisibleIndex(if (self.visible_index == 0) n - 1 else self.visible_index - 1);
    }

    // ── VTable 实现 ──────────────────────────────────────────────────────────

    const vtable = Widget.VTable{
        .type_name = "stack",
        .measure = measure,
        .perform_layout = performLayout,
        .paint = paint,
        .on_event = onEvent,
        .focusable = false,
        .destroy = destroyVTable,
    };

    fn destroyVTable(w: *Widget, allocator: std.mem.Allocator) void {
        const self: *Stack = @fieldParentPtr("base", w);
        self.destroy(allocator);
    }

    fn measure(w: *Widget, ctx: *PaintContext, constraint: layout_mod.Constraints) math.Size(f32) {
        const self: *Stack = @fieldParentPtr("base", w);
        const children = self.base.children.items;
        const pad = w.layout_style.padding;
        if (children.len == 0) {
            return .{ .width = pad.left + pad.right, .height = pad.top + pad.bottom };
        }

        const inner_w = @max(0, constraint.max_width - pad.left - pad.right);
        const inner_h = @max(0, constraint.max_height - pad.top - pad.bottom);
        const inner_constraint = layout_mod.Constraints{
            .max_width = inner_w,
            .max_height = inner_h,
        };

        var max_w: f32 = 0;
        var max_h: f32 = 0;
        for (children) |child| {
            if (child.layout_style.position == .absolute) continue;
            const size = child.vtable.measure(child, ctx, inner_constraint);
            var cw = size.width;
            var ch = size.height;
            if (child.layout_style.width.resolve(inner_w)) |ew| cw = ew;
            if (child.layout_style.height.resolve(inner_h)) |eh| ch = eh;
            const cm = child.layout_style.margin;
            if (cw + cm.left + cm.right > max_w) max_w = cw + cm.left + cm.right;
            if (ch + cm.top + cm.bottom > max_h) max_h = ch + cm.top + cm.bottom;
        }

        return .{
            .width = @min(max_w + pad.left + pad.right, constraint.max_width),
            .height = @min(max_h + pad.top + pad.bottom, constraint.max_height),
        };
    }

    fn performLayout(w: *Widget, ctx: *PaintContext) void {
        const self: *Stack = @fieldParentPtr("base", w);
        const children = self.base.children.items;
        if (children.len == 0) return;

        const pad = w.layout_style.padding;
        const avail_w = @max(0, w.rect.width - pad.left - pad.right);
        const avail_h = @max(0, w.rect.height - pad.top - pad.bottom);

        for (children) |child| {
            if (child.layout_style.position == .absolute) continue;

            const cm = child.layout_style.margin;
            child.rect.x = pad.left + cm.left;
            child.rect.y = pad.top + cm.top;
            child.rect.width = @max(0, avail_w - cm.left - cm.right);
            child.rect.height = @max(0, avail_h - cm.top - cm.bottom);
            child.layoutSubtree(ctx);
        }
    }

    fn paint(w: *Widget, ctx: *PaintContext) void {
        _ = w;
        _ = ctx;
    }

    fn onEvent(w: *Widget, event: *const pal.Event, ectx: *EventContext) EventResult {
        const self: *Stack = @fieldParentPtr("base", w);
        const children = self.base.children.items;
        if (children.len == 0) return .ignored;
        if (self.visible_index >= children.len) return .ignored;

        const child = children[self.visible_index];
        return child.dispatchEvent(event, ectx);
    }
};

// ── Tests ──────────────────────────────────────────────────────────────────

test "stack create" {
    const s = try Stack.create(std.testing.allocator, .{});
    defer s.destroy(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 0), s.visible_index);
    try std.testing.expectEqualStrings("stack", s.base.vtable.type_name);
}

test "stack set visible index" {
    const s = try Stack.create(std.testing.allocator, .{ .visible_index = 0 });
    defer s.destroy(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 0), s.getVisibleIndex());
    s.setVisibleIndex(0);
    try std.testing.expectEqual(@as(usize, 0), s.getVisibleIndex());
    s.next();
    try std.testing.expectEqual(@as(usize, 0), s.getVisibleIndex());
    s.prev();
    try std.testing.expectEqual(@as(usize, 0), s.getVisibleIndex());
}
