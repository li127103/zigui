//! 控件系统 - 基类 + 控件树 + 事件分发

const std = @import("std");
const math = @import("../math.zig");
const pal = @import("../pal/pal.zig");
const renderer2d = @import("../render2d/renderer.zig");
const theme_mod = @import("../theme/theme.zig");
const layout_mod = @import("../layout/engine.zig");

pub const WidgetId = u64;

var next_id: WidgetId = 1;

pub fn genWidgetId() WidgetId {
    const id = next_id;
    next_id += 1;
    return id;
}

pub const WidgetState = packed struct(u16) {
    hovered: bool = false,
    focused: bool = false,
    pressed: bool = false,
    disabled: bool = false,
    visible: bool = true,
    dirty: bool = true,
    layout_dirty: bool = true,
    _padding: u9 = 0,
};

pub const EventResult = enum { handled, ignored };

/// 绘制上下文
pub const PaintContext = struct {
    renderer: *renderer2d.Renderer2D,
    theme: *const theme_mod.Theme,
    allocator: std.mem.Allocator,
    // 当前绘制的绝对偏移 (由控件树递归传递)
    offset_x: f32 = 0,
    offset_y: f32 = 0,
};

/// 事件上下文
pub const EventContext = struct {
    mouse_x: f32 = 0,
    mouse_y: f32 = 0,
};

pub const Widget = struct {
    vtable: *const VTable,
    id: WidgetId,
    parent: ?*Widget = null,
    children: std.ArrayListUnmanaged(*Widget) = .{ .items = &.{}, .capacity = 0 },
    // 布局结果 (相对于父控件)
    rect: math.Rect(f32) = .{ .x = 0, .y = 0, .width = 0, .height = 0 },
    state: WidgetState = .{},
    // 布局样式
    layout_style: layout_mod.LayoutStyle = .{},

    pub const VTable = struct {
        type_name: []const u8,
        /// 测量固有尺寸 (返回内容尺寸, 不含 margin)
        measure: *const fn (self: *Widget, ctx: *PaintContext, constraints: layout_mod.Constraints) math.Size(f32),
        /// 绘制
        paint: *const fn (self: *Widget, ctx: *PaintContext) void,
        /// 事件处理
        on_event: ?*const fn (self: *Widget, event: *const pal.Event, ectx: *EventContext) EventResult = null,
        /// 是否可聚焦
        focusable: bool = false,
        /// 销毁
        destroy: *const fn (self: *Widget, allocator: std.mem.Allocator) void,
    };

    // ── 树操作 ──────────────────────────────────────────────────────────────

    pub fn addChild(self: *Widget, allocator: std.mem.Allocator, child: *Widget) !void {
        try self.children.append(allocator, child);
        child.parent = self;
        self.markLayoutDirty();
    }

    pub fn removeChild(self: *Widget, allocator: std.mem.Allocator, child: *Widget) void {
        for (self.children.items, 0..) |c, i| {
            if (c == child) {
                _ = self.children.orderedRemove(i);
                child.parent = null;
                self.markLayoutDirty();
                return;
            }
        }
        _ = allocator;
    }

    // ── 脏标记 ──────────────────────────────────────────────────────────────

    pub fn markDirty(self: *Widget) void {
        var current: ?*Widget = self;
        while (current) |w| {
            if (w.state.dirty) break;
            w.state.dirty = true;
            current = w.parent;
        }
    }

    pub fn markLayoutDirty(self: *Widget) void {
        var current: ?*Widget = self;
        while (current) |w| {
            if (w.state.layout_dirty) break;
            w.state.layout_dirty = true;
            current = w.parent;
        }
    }

    // ── 布局 ──────────────────────────────────────────────────────────────

    /// 执行子树布局
    pub fn performLayout(self: *Widget, ctx: *PaintContext, available: layout_mod.Constraints) void {
        // 构建临时 LayoutNode 树并执行布局
        // 简化实现: 直接用 vtable.measure + 手动 flexbox
        const content_size = self.vtable.measure(self, ctx, available);

        // 应用显式尺寸
        var w = content_size.width;
        var h = content_size.height;

        if (self.layout_style.width.resolve(available.max_width)) |ew| w = ew;
        if (self.layout_style.height.resolve(available.max_height)) |eh| h = eh;

        self.rect.width = std.math.clamp(w, 0, available.max_width);
        self.rect.height = std.math.clamp(h, 0, available.max_height);

        // 布局子项 (简化 flexbox: 垂直堆叠)
        if (self.children.items.len > 0) {
            self.layoutChildren(ctx);
        }

        self.state.layout_dirty = false;
    }

    fn layoutChildren(self: *Widget, ctx: *PaintContext) void {
        const pad = self.layout_style.padding;
        const is_row = self.layout_style.direction == .row or self.layout_style.direction == .row_reverse;
        const gap: f32 = if (is_row) self.layout_style.gap.width else self.layout_style.gap.height;

        const inner_w = self.rect.width - pad.left - pad.right;
        const inner_h = self.rect.height - pad.top - pad.bottom;

        // 测量所有子项
        var total_main: f32 = 0;
        var total_grow: f32 = 0;
        var count: usize = 0;

        for (self.children.items) |child| {
            const child_constraints = layout_mod.Constraints{
                .max_width = if (is_row) inner_w else inner_w,
                .max_height = if (is_row) inner_h else inner_h,
            };
            const child_size = child.vtable.measure(child, ctx, child_constraints);

            // 应用显式尺寸
            var cw = child_size.width;
            var ch = child_size.height;
            if (child.layout_style.width.resolve(inner_w)) |ew| cw = ew;
            if (child.layout_style.height.resolve(inner_h)) |eh| ch = eh;

            child.rect.width = cw;
            child.rect.height = ch;

            if (is_row) {
                total_main += cw + child.layout_style.margin.left + child.layout_style.margin.right;
            } else {
                total_main += ch + child.layout_style.margin.top + child.layout_style.margin.bottom;
            }
            total_grow += child.layout_style.flex_grow;
            count += 1;
        }

        if (count > 1) total_main += gap * @as(f32, @floatFromInt(count - 1));

        // 弹性分配
        const free_space = (if (is_row) inner_w else inner_h) - total_main;
        if (free_space > 0 and total_grow > 0) {
            for (self.children.items) |child| {
                if (child.layout_style.flex_grow > 0) {
                    const extra = free_space * (child.layout_style.flex_grow / total_grow);
                    if (is_row) {
                        child.rect.width += extra;
                    } else {
                        child.rect.height += extra;
                    }
                }
            }
        }

        // 定位
        var cursor: f32 = 0;
        for (self.children.items) |child| {
            const cm = child.layout_style.margin;
            if (is_row) {
                cursor += cm.left;
                child.rect.x = pad.left + cursor;
                child.rect.y = pad.top + cm.top;
                cursor += child.rect.width + cm.right + gap;
            } else {
                cursor += cm.top;
                child.rect.x = pad.left + cm.left;
                child.rect.y = pad.top + cursor;
                cursor += child.rect.height + cm.bottom + gap;
            }

            // 递归布局子项
            if (child.children.items.len > 0) {
                child.layoutChildren(ctx);
            }
        }
    }

    // ── 绘制 ──────────────────────────────────────────────────────────────

    /// 递归绘制子树
    pub fn paintTree(self: *Widget, ctx: *PaintContext) void {
        if (!self.state.visible) return;

        // 绘制自身
        self.vtable.paint(self, ctx);

        // 递归子项 (传递偏移)
        for (self.children.items) |child| {
            var child_ctx = ctx.*;
            child_ctx.offset_x += self.rect.x;
            child_ctx.offset_y += self.rect.y;
            child.paintTree(&child_ctx);
        }

        self.state.dirty = false;
    }

    // ── 事件分发 ──────────────────────────────────────────────────────────

    /// Hit-test: 找到坐标处的最深层控件
    pub fn hitTest(self: *Widget, x: f32, y: f32) ?*Widget {
        if (!self.state.visible) return null;

        // 逆序遍历子项 (最顶层优先)
        var i: usize = self.children.items.len;
        while (i > 0) {
            i -= 1;
            const child = self.children.items[i];
            // 坐标转换为子项局部坐标
            const lx = x - self.rect.x;
            const ly = y - self.rect.y;
            if (child.containsPoint(lx, ly)) {
                if (child.hitTest(lx, ly)) |hit| {
                    return hit;
                }
            }
        }

        // 自身命中
        if (self.containsPoint(x, y)) return self;
        return null;
    }

    pub fn containsPoint(self: *const Widget, x: f32, y: f32) bool {
        return x >= 0 and y >= 0 and x < self.rect.width and y < self.rect.height;
    }

    /// 分发事件到目标控件 (冒泡)
    pub fn dispatchEvent(self: *Widget, event: *const pal.Event, ectx: *EventContext) EventResult {
        // 找到目标
        const target = switch (event.*) {
            .mouse_button => |mb| self.hitTest(@floatFromInt(mb.x), @floatFromInt(mb.y)),
            .mouse_move => |mm| self.hitTest(@floatFromInt(mm.x), @floatFromInt(mm.y)),
            else => self,
        } orelse return .ignored;

        // 目标处理
        if (target.vtable.on_event) |handler| {
            if (handler(target, event, ectx) == .handled) return .handled;
        }

        // 冒泡到父级
        var current = target.parent;
        while (current) |w| {
            if (w.vtable.on_event) |handler| {
                if (handler(w, event, ectx) == .handled) return .handled;
            }
            current = w.parent;
        }

        return .ignored;
    }

    // ── 焦点 ──────────────────────────────────────────────────────────────

    /// 获取下一个可聚焦控件 (Tab 顺序)
    pub fn nextFocusable(self: *Widget) ?*Widget {
        for (self.children.items) |child| {
            if (child.vtable.focusable and child.state.visible and !child.state.disabled) {
                return child;
            }
            if (child.nextFocusable()) |f| return f;
        }
        return null;
    }
};
