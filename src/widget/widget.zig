//! 控件系统 - 基类 + 控件树 + 事件分发

const std = @import("std");
const math = @import("../math.zig");
const pal = @import("../pal/pal.zig");
const r2d = @import("../render2d/r2d.zig");
const dirty_mod = @import("../render2d/dirty.zig");
const theme_mod = @import("../theme/theme.zig");
const layout_mod = @import("../layout/engine.zig");
const background_mod = @import("background.zig");

pub const Background = background_mod.Background;
pub const BackgroundImage = background_mod.BackgroundImage;
pub const BackgroundSizing = background_mod.BackgroundSizing;
pub const BackgroundStyle = background_mod.BackgroundStyle;

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
    renderer: *r2d.Renderer2D,
    theme: *const theme_mod.Theme,
    allocator: std.mem.Allocator,
    // 当前绘制的绝对偏移 (由控件树递归传递)
    offset_x: f32 = 0,
    offset_y: f32 = 0,
    // 脏矩形裁剪 (非空时跳过与脏区不相交的子树)
    dirty: ?*const dirty_mod.DirtyRegion = null,
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
    /// 背景样式 (框架在 paintTree 中自动绘制于控件内容之前, 默认无背景)
    background: BackgroundStyle = .{},
    // 脏矩形跟踪器 (仅根控件设置, markDirty 时记录绝对脏区)
    dirty_tracker: ?*dirty_mod.DirtyRegion = null,

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
        // 记录脏矩形到根控件的跟踪器 (若有)
        var root: *Widget = self;
        while (root.parent) |p| root = p;
        if (root.dirty_tracker) |tracker| {
            tracker.add(self.absoluteRect()) catch {};
        }

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

    /// 绝对矩形 (沿父链累加相对坐标 → 窗口坐标)
    pub fn absoluteRect(self: *const Widget) math.Rect(f32) {
        var r = self.rect;
        var current = self.parent;
        while (current) |w| {
            r.x += w.rect.x;
            r.y += w.rect.y;
            current = w.parent;
        }
        return r;
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

        // 测量所有子项 (跳过绝对定位子项, 它们不参与 flex 流)
        var total_main: f32 = 0;
        var total_grow: f32 = 0;
        var count: usize = 0;

        for (self.children.items) |child| {
            if (child.layout_style.position == .absolute) continue;
            // 不可见子项不参与 flex 流 (不占布局空间)
            if (!child.state.visible) continue;
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
                if (child.layout_style.position == .absolute) continue;
                if (!child.state.visible) continue;
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

        // 定位 (flex 流)
        // 主轴分布: 重新统计 flex 分配后的主轴总尺寸 (可见子项)
        const justify = self.layout_style.justify_content;
        var final_main: f32 = 0;
        var visible_count: usize = 0;
        for (self.children.items) |child| {
            if (child.layout_style.position == .absolute) continue;
            if (!child.state.visible) continue;
            const cm = child.layout_style.margin;
            if (is_row) {
                final_main += child.rect.width + cm.left + cm.right;
            } else {
                final_main += child.rect.height + cm.top + cm.bottom;
            }
            visible_count += 1;
        }
        if (visible_count > 1) final_main += gap * @as(f32, @floatFromInt(visible_count - 1));

        const remaining = @max(0, (if (is_row) inner_w else inner_h) - final_main);
        var start: f32 = 0;
        var extra_gap: f32 = 0;
        const vc: f32 = @floatFromInt(visible_count);
        switch (justify) {
            .start => {},
            .center => start = remaining / 2,
            .end => start = remaining,
            .space_between => {
                if (visible_count > 1) extra_gap = remaining / (vc - 1);
            },
            .space_around => {
                if (visible_count > 0) {
                    extra_gap = remaining / vc;
                    start = extra_gap / 2;
                }
            },
            .space_evenly => {
                extra_gap = remaining / (vc + 1);
                start = extra_gap;
            },
        }

        const cross_align = self.layout_style.align_items;
        var cursor: f32 = start;
        for (self.children.items) |child| {
            if (child.layout_style.position == .absolute) continue;
            if (!child.state.visible) continue;
            const cm = child.layout_style.margin;
            // 交叉轴对齐: align_self 优先于容器 align_items
            const cross = child.layout_style.align_self orelse cross_align;
            if (is_row) {
                cursor += cm.left;
                child.rect.x = pad.left + cursor;
                switch (cross) {
                    .stretch => {
                        child.rect.y = pad.top + cm.top;
                        // 未显式指定高度时撑满容器内高
                        if (child.layout_style.height == .auto) {
                            child.rect.height = inner_h - cm.top - cm.bottom;
                        }
                    },
                    .center => child.rect.y = pad.top + cm.top + (inner_h - cm.top - cm.bottom - child.rect.height) / 2,
                    .end => child.rect.y = pad.top + inner_h - child.rect.height - cm.bottom,
                    .start, .baseline => child.rect.y = pad.top + cm.top,
                }
                cursor += child.rect.width + cm.right + gap + extra_gap;
            } else {
                cursor += cm.top;
                child.rect.y = pad.top + cursor;
                switch (cross) {
                    .stretch => {
                        child.rect.x = pad.left + cm.left;
                        // 未显式指定宽度时撑满容器内宽
                        if (child.layout_style.width == .auto) {
                            child.rect.width = inner_w - cm.left - cm.right;
                        }
                    },
                    .center => child.rect.x = pad.left + cm.left + (inner_w - cm.left - cm.right - child.rect.width) / 2,
                    .end => child.rect.x = pad.left + inner_w - child.rect.width - cm.right,
                    .start, .baseline => child.rect.x = pad.left + cm.left,
                }
                cursor += child.rect.height + cm.bottom + gap + extra_gap;
            }

            // 递归布局子项
            if (child.children.items.len > 0) {
                child.layoutChildren(ctx);
            }
        }

        // 绝对定位子项 (不参与 flex 流, 按 top/left/right/bottom 相对父容器定位)
        for (self.children.items) |child| {
            if (child.layout_style.position != .absolute) continue;
            self.layoutAbsolute(child, ctx);
        }
    }

    /// 绝对定位子项: 根据 top/left/right/bottom + 父容器尺寸定位
    fn layoutAbsolute(self: *Widget, child: *Widget, ctx: *PaintContext) void {
        const cs = child.layout_style;

        // 测量 (应用显式尺寸)
        const child_size = child.vtable.measure(child, ctx, .{
            .max_width = self.rect.width,
            .max_height = self.rect.height,
        });
        var cw = child_size.width;
        var ch = child_size.height;
        if (cs.width.resolve(self.rect.width)) |ew| cw = ew;
        if (cs.height.resolve(self.rect.height)) |eh| ch = eh;
        child.rect.width = cw;
        child.rect.height = ch;

        // 水平定位
        if (cs.left) |l| {
            child.rect.x = l + cs.margin.left;
        } else if (cs.right) |rv| {
            child.rect.x = self.rect.width - rv - cw - cs.margin.right;
        } else {
            child.rect.x = cs.margin.left;
        }

        // 垂直定位
        if (cs.top) |t| {
            child.rect.y = t + cs.margin.top;
        } else if (cs.bottom) |bv| {
            child.rect.y = self.rect.height - bv - ch - cs.margin.bottom;
        } else {
            child.rect.y = cs.margin.top;
        }

        // 递归布局子项
        if (child.children.items.len > 0) {
            child.layoutChildren(ctx);
        }
    }

    // ── 绘制 ──────────────────────────────────────────────────────────────

    /// 递归绘制子树
    pub fn paintTree(self: *Widget, ctx: *PaintContext) void {
        if (!self.state.visible) return;

        // 脏矩形裁剪: 与脏区不相交的子树整体跳过
        // (阴影等超出自身范围的绘制, 由调用方外扩脏区 margin 保证)
        if (ctx.dirty) |d| {
            if (!d.isEmpty()) {
                const abs = math.Rect(f32){
                    .x = ctx.offset_x + self.rect.x,
                    .y = ctx.offset_y + self.rect.y,
                    .width = self.rect.width,
                    .height = self.rect.height,
                };
                if (!d.intersects(abs)) {
                    self.state.dirty = false;
                    return;
                }
            }
        }

        // 框架自动绘制背景 (先于控件内容, 子树绘制在其上)
        self.paintBackground(ctx);

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

    // ── 背景 (框架自主绘制) ────────────────────────────────────

    /// 绘制背景: 阴影 (可选) + 纯色 (支持圆角) / 图片 (stretch/cover/contain/center/tile)
    fn paintBackground(self: *Widget, ctx: *PaintContext) void {
        const rect = math.Rect(f32){
            .x = ctx.offset_x + self.rect.x,
            .y = ctx.offset_y + self.rect.y,
            .width = self.rect.width,
            .height = self.rect.height,
        };

        // 阴影 (先于背景绘制, 位于背景之下)
        if (self.background.shadow_color) |sc| {
            ctx.renderer.drawShadow(rect, self.background.corner_radius, .{
                .color = sc,
                .blur_radius = self.background.shadow_blur,
                .offset_x = self.background.shadow_offset_x,
                .offset_y = self.background.shadow_offset_y,
            }) catch {};
        }

        switch (self.background.bg) {
            .none => {},
            .color => |c| {
                if (self.background.corner_radius > 0) {
                    ctx.renderer.fillRoundedRect(rect, self.background.corner_radius, c) catch {};
                } else {
                    ctx.renderer.fillRect(rect, c) catch {};
                }
            },
            .image => |*img| {
                img.ensureTexture(ctx.renderer) catch return;
                if (img.texture == null) return;
                // 图片走立即绘制路径: 先 flush 之前累积的几何以保持 z 序
                ctx.renderer.flush();
                background_mod.drawImageBackground(ctx.renderer, img, rect);
            },
        }
    }

    /// 设置背景色 (框架自动绘制; 传 null 清除背景)
    pub fn setBackgroundColor(self: *Widget, allocator: std.mem.Allocator, color: ?math.Color) void {
        self.background.deinit(allocator);
        self.background.bg = if (color) |c| .{ .color = c } else .none;
        self.markDirty();
    }

    /// 设置背景图片 (PNG 数据被拷贝, GPU 纹理惰性创建; sizing 为适配模式)
    pub fn setBackgroundImage(self: *Widget, allocator: std.mem.Allocator, png_data: []const u8, sizing: BackgroundSizing) !void {
        self.background.deinit(allocator);
        self.background.bg = .{ .image = try BackgroundImage.fromPng(allocator, png_data, sizing) };
        self.markDirty();
    }

    /// 设置背景圆角半径 (仅对纯色背景生效)
    pub fn setCornerRadius(self: *Widget, radius: f32) void {
        self.background.corner_radius = radius;
        self.markDirty();
    }

    // ── 事件分发 ──────────────────────────────────────────────────────────

    /// Hit-test: 找到坐标处的最深层控件
    /// x/y 为父级坐标空间 (根控件调用时即窗口坐标)
    pub fn hitTest(self: *Widget, x: f32, y: f32) ?*Widget {
        if (!self.state.visible) return null;

        // 转换到自身局部坐标并检查自身范围
        const lx = x - self.rect.x;
        const ly = y - self.rect.y;
        if (!self.containsPoint(lx, ly)) return null;

        // 逆序遍历子项 (最顶层优先); 子项 rect 正在自身局部坐标系中
        var i: usize = self.children.items.len;
        while (i > 0) {
            i -= 1;
            if (self.children.items[i].hitTest(lx, ly)) |hit| return hit;
        }

        return self;
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

// ── Tests ──────────────────────────────────────────────────────────────────

test "widget absoluteRect accumulates parent chain" {
    var parent: Widget = .{ .vtable = undefined, .id = 1 };
    parent.rect = .{ .x = 100, .y = 50, .width = 400, .height = 300 };
    var child: Widget = .{ .vtable = undefined, .id = 2 };
    child.rect = .{ .x = 20, .y = 30, .width = 100, .height = 60 };
    child.parent = &parent;

    const abs = child.absoluteRect();
    try std.testing.expectEqual(@as(f32, 120), abs.x);
    try std.testing.expectEqual(@as(f32, 80), abs.y);
    try std.testing.expectEqual(@as(f32, 100), abs.width);
    try std.testing.expectEqual(@as(f32, 60), abs.height);
}

test "widget markDirty records to root tracker" {
    var tracker = dirty_mod.DirtyRegion.init(std.testing.allocator);
    defer tracker.deinit();

    var root: Widget = .{ .vtable = undefined, .id = 1 };
    root.rect = .{ .x = 0, .y = 0, .width = 800, .height = 600 };
    root.dirty_tracker = &tracker;

    var child: Widget = .{ .vtable = undefined, .id = 2 };
    child.rect = .{ .x = 100, .y = 100, .width = 50, .height = 50 };
    child.parent = &root;

    child.markDirty();

    try std.testing.expectEqual(@as(usize, 1), tracker.count());
    const b = tracker.bounds().?;
    try std.testing.expectEqual(@as(f32, 100), b.x);
    try std.testing.expectEqual(@as(f32, 100), b.y);
    try std.testing.expectEqual(@as(f32, 50), b.width);
    try std.testing.expect(child.state.dirty);
    try std.testing.expect(root.state.dirty);
}

// 测试用最小 vtable (hitTest 不解引用 vtable; dispatchEvent 仅用 on_event)
var test_event_log: [8]u64 = undefined;
var test_event_count: usize = 0;

fn testOnEvent(self: *Widget, event: *const pal.Event, ectx: *EventContext) EventResult {
    _ = event;
    _ = ectx;
    if (test_event_count < test_event_log.len) {
        test_event_log[test_event_count] = self.id;
        test_event_count += 1;
    }
    // id==3 (button) 处理事件, 其余忽略继续冒泡
    return if (self.id == 3) .handled else .ignored;
}

fn testMeasure(self: *Widget, ctx: *PaintContext, constraints: layout_mod.Constraints) math.Size(f32) {
    _ = self;
    _ = ctx;
    _ = constraints;
    return .{ .width = 0, .height = 0 };
}

fn testPaint(self: *Widget, ctx: *PaintContext) void {
    _ = self;
    _ = ctx;
}

fn testDestroy(self: *Widget, allocator: std.mem.Allocator) void {
    _ = self;
    _ = allocator;
}

const test_vtable = Widget.VTable{
    .type_name = "test",
    .measure = testMeasure,
    .paint = testPaint,
    .on_event = testOnEvent,
    .destroy = testDestroy,
};

test "widget hitTest finds deepest child with offsets" {
    var root: Widget = .{ .vtable = &test_vtable, .id = 1 };
    root.rect = .{ .x = 0, .y = 0, .width = 800, .height = 600 };

    var panel: Widget = .{ .vtable = &test_vtable, .id = 2 };
    panel.rect = .{ .x = 100, .y = 100, .width = 300, .height = 200 };

    var button: Widget = .{ .vtable = &test_vtable, .id = 3 };
    button.rect = .{ .x = 20, .y = 30, .width = 80, .height = 24 };

    try root.addChild(std.testing.allocator, &panel);
    try panel.addChild(std.testing.allocator, &button);
    defer root.children.deinit(std.testing.allocator);
    defer panel.children.deinit(std.testing.allocator);

    // button 绝对范围: x 120..200, y 130..154
    try std.testing.expect(root.hitTest(125, 135).? == &button);
    // panel 内 button 外
    try std.testing.expect(root.hitTest(110, 110).? == &panel);
    // panel 右缘附近 (偏移子控件回归: 旧实现 x=350 误判出界)
    try std.testing.expect(root.hitTest(350, 150).? == &panel);
    // 仅命中 root
    try std.testing.expect(root.hitTest(10, 10).? == &root);
    // 范围外
    try std.testing.expect(root.hitTest(900, 900) == null);

    // 不可见子控件不参与命中
    button.state.visible = false;
    try std.testing.expect(root.hitTest(125, 135).? == &panel);
    button.state.visible = true;

    // 顶层优先: 重叠时后加入的子控件命中
    var overlay: Widget = .{ .vtable = &test_vtable, .id = 4 };
    overlay.rect = .{ .x = 10, .y = 20, .width = 100, .height = 50 }; // 绝对 110..210, 120..170 与 button 重叠
    try panel.addChild(std.testing.allocator, &overlay);
    try std.testing.expect(root.hitTest(125, 135).? == &overlay);
}

test "widget dispatchEvent hits target and bubbles" {
    var root: Widget = .{ .vtable = &test_vtable, .id = 1 };
    root.rect = .{ .x = 0, .y = 0, .width = 800, .height = 600 };
    var panel: Widget = .{ .vtable = &test_vtable, .id = 2 };
    panel.rect = .{ .x = 100, .y = 100, .width = 300, .height = 200 };
    var button: Widget = .{ .vtable = &test_vtable, .id = 3 };
    button.rect = .{ .x = 20, .y = 30, .width = 80, .height = 24 };
    try root.addChild(std.testing.allocator, &panel);
    try panel.addChild(std.testing.allocator, &button);
    defer root.children.deinit(std.testing.allocator);
    defer panel.children.deinit(std.testing.allocator);

    var ectx: EventContext = .{};
    const ev: pal.Event = .{ .mouse_button = .{
        .button = .left,
        .state = .pressed,
        .x = 125,
        .y = 135,
    } };

    // 命中 button (id=3) → handled, 不冒泡
    test_event_count = 0;
    try std.testing.expectEqual(EventResult.handled, root.dispatchEvent(&ev, &ectx));
    try std.testing.expectEqual(@as(usize, 1), test_event_count);
    try std.testing.expectEqual(@as(u64, 3), test_event_log[0]);

    // 命中 panel (id=2) → ignored → 冒泡 root (id=1) → ignored
    const ev2: pal.Event = .{ .mouse_button = .{
        .button = .left,
        .state = .pressed,
        .x = 110,
        .y = 110,
    } };
    test_event_count = 0;
    try std.testing.expectEqual(EventResult.ignored, root.dispatchEvent(&ev2, &ectx));
    try std.testing.expectEqual(@as(usize, 2), test_event_count);
    try std.testing.expectEqual(@as(u64, 2), test_event_log[0]);
    try std.testing.expectEqual(@as(u64, 1), test_event_log[1]);

    // 范围外 → ignored 且无分发
    const ev3: pal.Event = .{ .mouse_button = .{
        .button = .left,
        .state = .pressed,
        .x = 900,
        .y = 900,
    } };
    test_event_count = 0;
    try std.testing.expectEqual(EventResult.ignored, root.dispatchEvent(&ev3, &ectx));
    try std.testing.expectEqual(@as(usize, 0), test_event_count);
}

test "widget background defaults to none" {
    const w: Widget = .{ .vtable = &test_vtable, .id = 1 };
    try std.testing.expect(std.meta.activeTag(w.background.bg) == .none);
    try std.testing.expectEqual(@as(f32, 0), w.background.corner_radius);
}

test "widget setBackgroundColor sets and clears" {
    var w: Widget = .{ .vtable = &test_vtable, .id = 1 };
    w.setBackgroundColor(std.testing.allocator, math.Color.hex(0xFF0000FF));
    try std.testing.expect(std.meta.activeTag(w.background.bg) == .color);
    try std.testing.expectEqual(@as(u8, 0xFF), w.background.bg.color.r);
    try std.testing.expect(w.state.dirty);

    // 传 null 清除
    w.setBackgroundColor(std.testing.allocator, null);
    try std.testing.expect(std.meta.activeTag(w.background.bg) == .none);
}

test "widget setBackgroundImage owns png data" {
    var w: Widget = .{ .vtable = &test_vtable, .id = 1 };
    try w.setBackgroundImage(std.testing.allocator, "fake-png", .tile);
    try std.testing.expect(std.meta.activeTag(w.background.bg) == .image);
    try std.testing.expectEqualSlices(u8, "fake-png", w.background.bg.image.png_data);
    try std.testing.expectEqual(BackgroundSizing.tile, w.background.bg.image.sizing);

    // 切换为颜色: 旧图片数据被释放
    w.setBackgroundColor(std.testing.allocator, math.Color.hex(0x00FF00FF));
    try std.testing.expect(std.meta.activeTag(w.background.bg) == .color);
}

test "widget setCornerRadius keeps background" {
    var w: Widget = .{ .vtable = &test_vtable, .id = 1 };
    w.setBackgroundColor(std.testing.allocator, math.Color.hex(0x0000FFFF));
    w.setCornerRadius(12);
    try std.testing.expectEqual(@as(f32, 12), w.background.corner_radius);
    try std.testing.expect(std.meta.activeTag(w.background.bg) == .color);
}
