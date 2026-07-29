//! Stack 控件 - 多页面堆叠容器
//!
//! 类似 GtkStack: 多个子控件堆叠在一起, 同一时间只显示一个页面。
//! 通过 setVisibleChild / setVisibleIndex 切换页面。
//! 支持淡入淡出和滑动切换动画。

const std = @import("std");
const math = @import("../math.zig");
const widget_mod = @import("widget.zig");
const layout_mod = @import("../layout/engine.zig");
const pal = @import("../pal/pal.zig");

const Widget = widget_mod.Widget;
const PaintContext = widget_mod.PaintContext;
const EventContext = widget_mod.EventContext;
const EventResult = widget_mod.EventResult;

pub const StackTransition = enum {
    none,
    fade,
    slide_left,
    slide_right,
    slide_up,
    slide_down,
};

/// GTK4 对齐的过渡类型 (gtk_stack_set_transition_type 接受此枚举)
/// crossfade 对应内部 StackTransition.fade
pub const TransitionType = enum {
    none,
    crossfade,
    slide_left,
    slide_right,
    slide_up,
    slide_down,
};

/// Stack 页面元数据 (对应 GTK4 GtkStackPage: name/title 等附加信息)
/// 与 base.children 同序, 每个条目对应一个子页面。
pub const StackPage = struct {
    name: ?[]const u8 = null,
    title: ?[]const u8 = null,
};

pub const Stack = struct {
    base: Widget,
    allocator: std.mem.Allocator,
    visible_index: usize = 0,
    transition_type: StackTransition = .none,
    transition_duration_ms: u32 = 200,
    anim_progress: f32 = 1.0,
    prev_index: usize = 0,
    anim_running: bool = false,
    pages: std.ArrayListUnmanaged(StackPage) = .empty,

    pub fn create(allocator: std.mem.Allocator, opts: struct {
        bg_color: ?math.Color = null,
        corner_radius: f32 = 0,
        visible_index: usize = 0,
        transition_type: StackTransition = .none,
        transition_duration_ms: u32 = 200,
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
            .transition_type = opts.transition_type,
            .transition_duration_ms = opts.transition_duration_ms,
            .prev_index = opts.visible_index,
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
        self.pages.deinit(allocator);
        allocator.destroy(self);
    }

    /// 添加子页面
    pub fn addChild(self: *Stack, child: *Widget) !void {
        const index = self.base.children.items.len;
        try self.pages.append(self.allocator, .{});
        try self.base.addChild(self.allocator, child);
        if (index == self.visible_index) {
            child.state.visible = true;
        } else {
            child.state.visible = false;
        }
    }

    /// 按名称添加子页面, 返回索引 (GTK4: gtk_stack_add_named)
    pub fn addNamed(self: *Stack, child: *Widget, name: []const u8) !usize {
        const index = self.base.children.items.len;
        try self.addChild(child);
        self.pages.items[index].name = name;
        return index;
    }

    /// 按名称和标题添加子页面, 返回索引 (GTK4: gtk_stack_add_titled)
    pub fn addTitled(self: *Stack, child: *Widget, name: []const u8, title: []const u8) !usize {
        const index = self.base.children.items.len;
        try self.addChild(child);
        self.pages.items[index].name = name;
        self.pages.items[index].title = title;
        return index;
    }

    /// 按控件指针切换可见页面 (GTK4: gtk_stack_set_visible_child)
    pub fn setVisibleChild(self: *Stack, child: *Widget) void {
        for (self.base.children.items, 0..) |c, i| {
            if (c == child) {
                self.setVisibleIndex(i);
                return;
            }
        }
    }

    /// 按名称切换可见页面 (GTK4: gtk_stack_set_visible_child_name)
    pub fn setVisibleChildName(self: *Stack, name: []const u8) void {
        for (self.pages.items, 0..) |page, i| {
            if (page.name) |n| {
                if (std.mem.eql(u8, n, name)) {
                    self.setVisibleIndex(i);
                    return;
                }
            }
        }
    }

    /// 设置过渡类型 (GTK4: gtk_stack_set_transition_type)
    pub fn setTransitionType(self: *Stack, tt: TransitionType) void {
        self.transition_type = switch (tt) {
            .none => .none,
            .crossfade => .fade,
            .slide_left => .slide_left,
            .slide_right => .slide_right,
            .slide_up => .slide_up,
            .slide_down => .slide_down,
        };
        self.base.markDirty();
    }

    /// 设置过渡时长 (GTK4: gtk_stack_set_transition_duration)
    pub fn setTransitionDuration(self: *Stack, ms: u32) void {
        self.transition_duration_ms = ms;
        self.base.markDirty();
    }

    /// 切换到指定索引的页面
    pub fn setVisibleIndex(self: *Stack, index: usize) void {
        if (index >= self.base.children.items.len) return;
        if (index == self.visible_index) return;

        self.prev_index = self.visible_index;
        self.visible_index = index;
        self.anim_progress = 0.0;
        self.anim_running = self.transition_type != .none;

        if (self.anim_running) {
            // 动画期间两个页面都可见
            const children = self.base.children.items;
            children[self.prev_index].state.visible = true;
            children[self.visible_index].state.visible = true;
        } else {
            // 无动画: 直接更新可见性
            self.updateVisibility();
        }

        self.base.markLayoutDirty();
        self.base.markDirty();
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

    /// 推进切换动画 (每帧调用, delta_ms 为帧间隔)
    pub fn tick(self: *Stack, delta_ms: u32) void {
        if (!self.anim_running) return;
        if (self.transition_duration_ms == 0) {
            self.anim_progress = 1.0;
            self.anim_running = false;
            self.updateVisibility();
            return;
        }

        self.anim_progress += @as(f32, @floatFromInt(delta_ms)) / @as(f32, @floatFromInt(self.transition_duration_ms));
        if (self.anim_progress >= 1.0) {
            self.anim_progress = 1.0;
            self.anim_running = false;
            self.updateVisibility();
        }

        self.base.markDirty();
    }

    fn updateVisibility(self: *Stack) void {
        const children = self.base.children.items;
        for (children, 0..) |child, i| {
            child.state.visible = (i == self.visible_index);
        }
    }

    // ── VTable 实现 ──────────────────────────────────────────────────────────

    const vtable = Widget.VTable{
        .type_name = "stack",
        .measure = measure,
        .perform_layout = performLayout,
        .paint = paint,
        .on_event = null,
        .tick = tickVTable,
        .focusable = false,
        .destroy = destroyVTable,
    };

    fn destroyVTable(w: *Widget, allocator: std.mem.Allocator) void {
        const self: *Stack = @fieldParentPtr("base", w);
        self.destroy(allocator);
    }

    fn tickVTable(w: *Widget, delta_ms: u32) void {
        const self: *Stack = @fieldParentPtr("base", w);
        self.tick(delta_ms);
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

        const t = self.easedProgress();

        for (children, 0..) |child, idx| {
            if (child.layout_style.position == .absolute) continue;

            const cm = child.layout_style.margin;
            child.rect.width = @max(0, avail_w - cm.left - cm.right);
            child.rect.height = @max(0, avail_h - cm.top - cm.bottom);

            var x: f32 = pad.left + cm.left;
            var y: f32 = pad.top + cm.top;

            if (self.anim_running) {
                if (idx == self.prev_index) {
                    // 旧页面: 从中心滑出
                    switch (self.transition_type) {
                        .slide_left => x -= avail_w * t,
                        .slide_right => x += avail_w * t,
                        .slide_up => y -= avail_h * t,
                        .slide_down => y += avail_h * t,
                        .fade, .none => {},
                    }
                } else if (idx == self.visible_index) {
                    // 新页面: 从外面滑入
                    switch (self.transition_type) {
                        .slide_left => x += avail_w * (1.0 - t),
                        .slide_right => x -= avail_w * (1.0 - t),
                        .slide_up => y += avail_h * (1.0 - t),
                        .slide_down => y -= avail_h * (1.0 - t),
                        .fade, .none => {},
                    }
                }
            }

            child.rect.x = x;
            child.rect.y = y;
            child.layoutSubtree(ctx);
        }
    }

    fn easedProgress(self: *const Stack) f32 {
        const t = std.math.clamp(self.anim_progress, 0.0, 1.0);
        // ease_out_cubic
        const p = 1.0 - std.math.pow(f32, 1.0 - t, 3);
        return p;
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
