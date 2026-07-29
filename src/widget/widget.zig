//! 控件系统 - 基类 + 控件树 + 事件分发

const std = @import("std");
const math = @import("../math.zig");
const pal = @import("../pal/pal.zig");
const perf = @import("../perf.zig");
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

/// 无障碍语义角色 (供屏幕阅读器/辅助技术识别控件类型)
pub const Role = enum {
    none,
    button,
    checkbox,
    radio,
    toggle,
    slider,
    progress,
    text,
    image,
    list,
    list_item,
    container,
    scroll_area,
    tab,
    menu,
    dialog,
    status,
};

/// 无障碍元数据 (a11y): 描述控件语义, 供辅助技术 (屏幕阅读器) 与焦点导航使用
pub const Accessibility = struct {
    /// 语义角色 (默认 none; 控件工厂可自动设置)
    role: Role = .none,
    /// 可读名称 (如按钮文本/图片替代文本)
    label: ?[]const u8 = null,
    /// 当前值文本 (如进度 "50%"、滑块数值)
    value: ?[]const u8 = null,
    /// 操作提示 (如 "按空格切换")
    hint: ?[]const u8 = null,
    /// 是否展开 (折叠面板/树节点等用)
    expanded: ?bool = null,
};

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
    // 是否已有祖先控件处于 disabled 状态 (避免重复叠加遮罩)
    has_disabled_ancestor: bool = false,
};

/// 事件上下文
pub const EventContext = struct {
    mouse_x: f32 = 0,
    mouse_y: f32 = 0,
};

/// 通用事件控制器 (GTK4: GtkEventController)
/// 挂在 Widget.event_controllers 上，事件先于 on_event/冒泡阶段处理。
/// 通过 self_ptr + handle_event 实现类型擦除，避免 Gesture/其他模块与 Widget 互依赖。
pub const EventController = struct {
    /// 控制器自身指针 (指向 GestureClick 等具体对象, 不管理生命周期)
    self_ptr: *anyopaque,
    /// 事件处理函数。widget = 事件到达的当前控件, event = 原始事件
    handle_event: *const fn (self: *anyopaque, widget: *Widget, event: *const pal.Event, ectx: *EventContext) EventResult,
    /// 每帧 tick (可选；动画 / GestureLongPress 定时等会用到）
    tick: ?*const fn (self: *anyopaque, delta_ms: u32) void = null,
    /// 名称 (调试用)
    name: []const u8 = "event_controller",

    /// 便捷创建：将一个具体 T 类型指针封装为 EventController
    pub fn wrap(comptime T: type, obj: *T, comptime handleFn: fn (self: *T, widget: *Widget, event: *const pal.Event, ectx: *EventContext) EventResult, comptime tickFn: ?fn (self: *T, delta_ms: u32) void, comptime name: []const u8) EventController {
        const shim_event = struct {
            fn shim(s: *anyopaque, w: *Widget, e: *const pal.Event, ec: *EventContext) EventResult {
                const self_t: *T = @ptrCast(@alignCast(s));
                return @call(.always_inline, handleFn, .{ self_t, w, e, ec });
            }
        }.shim;
        const shim_tick = if (tickFn) |tf| (struct {
            fn shim(s: *anyopaque, d: u32) void {
                const self_t: *T = @ptrCast(@alignCast(s));
                return @call(.always_inline, tf, .{ self_t, d });
            }
        }.shim) else null;
        return .{
            .self_ptr = obj,
            .handle_event = shim_event,
            .tick = shim_tick,
            .name = name,
        };
    }
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
    /// 子树裁剪矩形 (绝对坐标; 非 null 时 paintTree 将子项绘制裁剪到此矩形, 供 ScrolledWindow 等容器使用)
    clip_children: ?math.Rect(f32) = null,
    /// 无障碍元数据 (role/label/value/hint; 供辅助技术与焦点导航)
    accessibility: Accessibility = .{},
    /// 透明度 (0.0 - 1.0, 影响整个子树)
    opacity: f32 = 1.0,
    /// 拖拽 drop 目标 (非 null 时控件可接收拖拽数据)
    drop_target: ?*@import("../dnd.zig").DropTarget = null,
    /// 用户自定义数据指针 (供回调使用, 框架不管理其生命周期)
    user_data: ?*anyopaque = null,
    /// 鼠标光标样式 (null = 继承父控件; 根控件默认为 arrow)
    cursor: ?pal.CursorType = null,
    /// 工具提示文本 (null = 无 tooltip; 悬停延迟显示)
    tooltip_text: ?[]const u8 = null,
    /// 右键菜单 (null = 无右键菜单; 右键点击时自动弹出)
    context_menu: ?*@import("context_menu.zig").ContextMenu = null,
    /// 事件控制器列表 (GTK4 GtkEventController 概念, 挂接 Gesture/Focus/Motion 等)
    /// 每个 Widget 可以挂接多个 EventController，事件先由 controllers 预处理再走 on_event/冒泡
    event_controllers: std.ArrayListUnmanaged(EventController) = .empty,
    // 脏矩形跟踪器 (仅根控件设置, markDirty 时记录绝对脏区)
    dirty_tracker: ?*dirty_mod.DirtyRegion = null,
    /// 上一次 paintTree 调用时间（ms, 用于计算帧间隔，供 tick 推进动画/定时器；首帧为 null）
    last_paint_ms: ?u64 = null,

    pub const VTable = struct {
        type_name: []const u8,
        /// 测量固有尺寸 (返回内容尺寸, 不含 margin)
        measure: *const fn (self: *Widget, ctx: *PaintContext, constraints: layout_mod.Constraints) math.Size(f32),
        /// 给定宽度计算高度 (height-for-width, 可选, 文本类控件实现)
        measure_height_for_width: ?*const fn (self: *Widget, ctx: *PaintContext, width: f32) f32 = null,
        /// 给定高度计算宽度 (width-for-height, 可选)
        measure_width_for_height: ?*const fn (self: *Widget, ctx: *PaintContext, height: f32) f32 = null,
        /// 获取基线位置 (从 widget 顶部到基线的距离, 可选, 文本类控件实现)
        get_baseline: ?*const fn (self: *Widget, ctx: *PaintContext, height: f32) f32 = null,
        /// 绘制
        paint: *const fn (self: *Widget, ctx: *PaintContext) void,
        /// 事件处理
        on_event: ?*const fn (self: *Widget, event: *const pal.Event, ectx: *EventContext) EventResult = null,
        /// 自定义命中测试 (可选; 如弹出菜单等位置不受布局控制的控件覆盖)
        hit_test: ?*const fn (self: *Widget, x: f32, y: f32) ?*Widget = null,
        /// 自定义布局 (可选; 容器如 ScrolledWindow 覆盖默认 flexbox 以应用滚动偏移)
        perform_layout: ?*const fn (self: *Widget, ctx: *PaintContext) void = null,
        /// 帧动画 tick (可选; 动画控件实现, 每帧调用以推进动画)
        tick: ?*const fn (self: *Widget, delta_ms: u32) void = null,
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

    // ── Event Controllers ─────────────────────────────────────────────────

    /// 挂接一个事件控制器 (GTK4: gtk_widget_add_controller)
    pub fn addEventController(self: *Widget, allocator: std.mem.Allocator, ctrl: EventController) !void {
        try self.event_controllers.append(allocator, ctrl);
    }

    /// 移除所有同名或等于 self_ptr 的控制器 (GTK4: gtk_widget_remove_controller)
    pub fn removeEventController(self: *Widget, ctrl_self: *anyopaque) void {
        var i: usize = 0;
        while (i < self.event_controllers.items.len) {
            if (self.event_controllers.items[i].self_ptr == ctrl_self) {
                _ = self.event_controllers.orderedRemove(i);
            } else {
                i += 1;
            }
        }
    }

    /// 推进所有挂接的 controllers 的 tick 函数 (每帧由 app 主循环调用，或由 Widget.tick 调用)
    pub fn tickControllers(self: *Widget, delta_ms: u32) void {
        for (self.event_controllers.items) |*ctrl| {
            if (ctrl.tick) |t| t(ctrl.self_ptr, delta_ms);
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

        // 布局子项 (简化 flexbox; 容器可经 vtable.perform_layout 覆盖)
        if (self.children.items.len > 0) {
            self.layoutSubtree(ctx);
        }

        self.state.layout_dirty = false;
    }

    /// 布局子树: 优先使用 vtable.perform_layout 自定义布局, 否则默认 flexbox
    /// (pub 供自定义布局容器如 ScrolledWindow 递归布局子项)
    pub fn layoutSubtree(self: *Widget, ctx: *PaintContext) void {
        if (self.vtable.perform_layout) |custom| {
            custom(self, ctx);
        } else {
            self.layoutChildren(ctx);
        }
    }

    fn layoutChildren(self: *Widget, ctx: *PaintContext) void {
        const FlexItem = struct {
            widget: *Widget,
            main_size: f32,
            cross_size: f32,
            baseline: f32 = 0,
        };
        const LineInfo = struct {
            start: usize,
            end: usize,
            main_size: f32,
            cross_size: f32,
            baseline: f32 = 0,
        };

        const pad = self.layout_style.padding;
        const is_row = self.layout_style.direction == .row or self.layout_style.direction == .row_reverse;
        const wrap = self.layout_style.wrap != .nowrap;
        const gap_main: f32 = if (is_row) self.layout_style.gap.width else self.layout_style.gap.height;
        const gap_cross: f32 = if (is_row) self.layout_style.gap.height else self.layout_style.gap.width;

        const inner_w = self.rect.width - pad.left - pad.right;
        const inner_h = self.rect.height - pad.top - pad.bottom;
        const main_max: f32 = if (is_row) inner_w else inner_h;
        const cross_max: f32 = if (is_row) inner_h else inner_w;
        const cross_align = self.layout_style.align_items;

        // 1. 测量所有子项
        var flex_items = std.ArrayListUnmanaged(FlexItem){ .items = &.{}, .capacity = 0 };
        defer flex_items.deinit(ctx.allocator);

        for (self.children.items) |child| {
            if (child.layout_style.position == .absolute) continue;
            if (!child.state.visible) continue;

            const child_constraints = layout_mod.Constraints{
                .max_width = inner_w,
                .max_height = inner_h,
            };
            const child_size = child.vtable.measure(child, ctx, child_constraints);

            var cw = child_size.width;
            var ch = child_size.height;
            if (child.layout_style.width.resolve(inner_w)) |ew| cw = ew;
            if (child.layout_style.height.resolve(inner_h)) |eh| ch = eh;

            // flex-basis: 主轴方向的基准尺寸
            const fb = child.layout_style.flex_basis;
            if (fb != .auto) {
                const fb_val = fb.resolve(if (is_row) inner_w else inner_h) orelse 0;
                if (is_row) {
                    cw = fb_val;
                } else {
                    ch = fb_val;
                }
            }

            child.rect.width = cw;
            child.rect.height = ch;

            // 计算基线 (从子元素顶部到基线的距离)
            var baseline: f32 = 0;
            if (child.vtable.get_baseline) |get_baseline| {
                baseline = get_baseline(child, ctx, ch);
            }

            const cm = child.layout_style.margin;
            const main_size = if (is_row) cw + cm.left + cm.right else ch + cm.top + cm.bottom;
            const cross_size = if (is_row) ch + cm.top + cm.bottom else cw + cm.left + cm.right;

            flex_items.append(ctx.allocator, .{
                .widget = child,
                .main_size = main_size,
                .cross_size = cross_size,
                .baseline = baseline,
            }) catch {};
        }

        if (flex_items.items.len == 0) {
            // 绝对定位子项
            for (self.children.items) |child| {
                if (child.layout_style.position != .absolute) continue;
                self.layoutAbsolute(child, ctx);
            }
            return;
        }

        // 2. 按行/列分组 (flex-wrap)
        var lines = std.ArrayListUnmanaged(LineInfo){ .items = &.{}, .capacity = 0 };
        defer lines.deinit(ctx.allocator);
        var cur_line_main: f32 = 0;
        var cur_line_cross: f32 = 0;
        var line_start: usize = 0;

        for (flex_items.items, 0..) |item, i| {
            const with_gap = if (i > line_start) cur_line_main + gap_main + item.main_size else cur_line_main + item.main_size;
            if (wrap and with_gap > main_max and i > line_start) {
                // 换行
                lines.append(ctx.allocator, .{
                    .start = line_start,
                    .end = i,
                    .main_size = cur_line_main,
                    .cross_size = cur_line_cross,
                }) catch {};
                line_start = i;
                cur_line_main = item.main_size;
                cur_line_cross = item.cross_size;
            } else {
                cur_line_main = with_gap;
                cur_line_cross = @max(cur_line_cross, item.cross_size);
            }
        }
        // 最后一行
        lines.append(ctx.allocator, .{
            .start = line_start,
            .end = flex_items.items.len,
            .main_size = cur_line_main,
            .cross_size = cur_line_cross,
        }) catch {};

        // 3. 每行的 flex_grow/flex_shrink (每行独立计算)
        for (lines.items) |*line| {
            // 计算该行的 grow/shrink 总和
            var line_grow: f32 = 0;
            var line_shrink: f32 = 0;
            for (flex_items.items[line.start..line.end]) |item| {
                const child = item.widget;
                if (is_row) {
                    line_grow += if (child.layout_style.hexpand) @max(child.layout_style.flex_grow, 1.0) else child.layout_style.flex_grow;
                    line_shrink += if (child.layout_style.hexpand) @max(child.layout_style.flex_shrink, 1.0) else child.layout_style.flex_shrink;
                } else {
                    line_grow += if (child.layout_style.vexpand) @max(child.layout_style.flex_grow, 1.0) else child.layout_style.flex_grow;
                    line_shrink += if (child.layout_style.vexpand) @max(child.layout_style.flex_shrink, 1.0) else child.layout_style.flex_shrink;
                }
            }

            const free_space = main_max - line.main_size;
            if (free_space > 0 and line_grow > 0) {
                // 伸展
                for (flex_items.items[line.start..line.end]) |*item| {
                    const child = item.widget;
                    const fg = if (is_row) (if (child.layout_style.hexpand) @max(child.layout_style.flex_grow, 1.0) else child.layout_style.flex_grow) else (if (child.layout_style.vexpand) @max(child.layout_style.flex_grow, 1.0) else child.layout_style.flex_grow);
                    if (fg > 0) {
                        const extra = free_space * (fg / line_grow);
                        const cm = child.layout_style.margin;
                        if (is_row) {
                            var new_w = child.rect.width + extra;
                            if (child.layout_style.max_width.resolve(inner_w)) |mw| new_w = @min(new_w, mw - cm.left - cm.right);
                            if (child.layout_style.min_width.resolve(inner_w)) |mw| new_w = @max(new_w, mw - cm.left - cm.right);
                            child.rect.width = new_w;
                            item.main_size = new_w + cm.left + cm.right;
                        } else {
                            var new_h = child.rect.height + extra;
                            if (child.layout_style.max_height.resolve(inner_h)) |mh| new_h = @min(new_h, mh - cm.top - cm.bottom);
                            if (child.layout_style.min_height.resolve(inner_h)) |mh| new_h = @max(new_h, mh - cm.top - cm.bottom);
                            child.rect.height = new_h;
                            item.main_size = new_h + cm.top + cm.bottom;
                        }
                    }
                }
                // 重新计算行主轴尺寸
                line.main_size = 0;
                for (flex_items.items[line.start..line.end], 0..) |item, i| {
                    if (i > 0) line.main_size += gap_main;
                    line.main_size += item.main_size;
                }
            } else if (free_space < 0 and line_shrink > 0) {
                // 收缩
                const deficit = -free_space;
                for (flex_items.items[line.start..line.end]) |*item| {
                    const child = item.widget;
                    const fs = if (is_row) (if (child.layout_style.hexpand) @max(child.layout_style.flex_shrink, 1.0) else child.layout_style.flex_shrink) else (if (child.layout_style.vexpand) @max(child.layout_style.flex_shrink, 1.0) else child.layout_style.flex_shrink);
                    if (fs > 0) {
                        const shrink = deficit * (fs / line_shrink);
                        const cm = child.layout_style.margin;
                        if (is_row) {
                            var new_w = child.rect.width - shrink;
                            const min_w = child.layout_style.min_width.resolve(inner_w) orelse 0;
                            new_w = @max(new_w, min_w - cm.left - cm.right);
                            if (new_w < 0) new_w = 0;
                            child.rect.width = new_w;
                            item.main_size = new_w + cm.left + cm.right;
                        } else {
                            var new_h = child.rect.height - shrink;
                            const min_h = child.layout_style.min_height.resolve(inner_h) orelse 0;
                            new_h = @max(new_h, min_h - cm.top - cm.bottom);
                            if (new_h < 0) new_h = 0;
                            child.rect.height = new_h;
                            item.main_size = new_h + cm.top + cm.bottom;
                        }
                    }
                }
                line.main_size = 0;
                for (flex_items.items[line.start..line.end], 0..) |item, i| {
                    if (i > 0) line.main_size += gap_main;
                    line.main_size += item.main_size;
                }
            }
            // stretch 模式下, 行的交叉轴尺寸等于容器交叉轴尺寸
            if (cross_align == .stretch) {
                line.cross_size = cross_max;
            }
        }

        // 3.2 height-for-width: 确定宽度后重新测量高度 (仅 nowrap 单行模式, 非 stretch 时)
        // 暂时完全禁用, 排查左栏布局问题
        // if (is_row and !wrap and cross_align != .stretch) {
        //     for (lines.items) |line| {
        //         for (flex_items.items[line.start..line.end]) |*item| {
        //             const child = item.widget;
        //             if (child.vtable.measure_height_for_width) |hfw| {
        //                 const cm = child.layout_style.margin;
        //                 const avail_w = child.rect.width;
        //                 if (avail_w > 0) {
        //                     const new_h = hfw(child, ctx, avail_w);
        //                     child.rect.height = new_h;
        //                     item.cross_size = new_h + cm.top + cm.bottom;
        //                     if (child.vtable.get_baseline) |get_baseline| {
        //                         item.baseline = get_baseline(child, ctx, new_h);
        //                     }
        //                 }
        //             }
        //         }
        //     }
        //     for (lines.items) |*line| {
        //         var max_cross: f32 = 0;
        //         for (flex_items.items[line.start..line.end]) |item| {
        //             max_cross = @max(max_cross, item.cross_size);
        //         }
        //         line.cross_size = max_cross;
        //     }
        // }

        // 3.5 baseline 对齐: 重新计算每行的行高和基线位置
        if (cross_align == .baseline and is_row) {
            for (lines.items) |*line| {
                var max_ascent: f32 = 0;
                var max_descent: f32 = 0;
                for (flex_items.items[line.start..line.end]) |item| {
                    const cm = item.widget.layout_style.margin;
                    const ascent = cm.top + item.baseline;
                    const descent = item.widget.rect.height - item.baseline + cm.bottom;
                    max_ascent = @max(max_ascent, ascent);
                    max_descent = @max(max_descent, descent);
                }
                line.baseline = max_ascent;
                line.cross_size = max_ascent + max_descent;
            }
        }

        // 4. 计算所有行的总交叉轴尺寸
        var total_cross: f32 = 0;
        for (lines.items, 0..) |line, i| {
            if (i > 0) total_cross += gap_cross;
            total_cross += line.cross_size;
        }

        // 5. align_content: 多行在交叉轴上的分布
        const align_content = self.layout_style.align_content;
        const cross_remaining = @max(0, cross_max - total_cross);
        var cross_start: f32 = 0;
        var cross_extra_gap: f32 = 0;
        const line_count_f: f32 = @floatFromInt(lines.items.len);

        switch (align_content) {
            .start => {},
            .center => cross_start = cross_remaining / 2,
            .end => cross_start = cross_remaining,
            .space_between => {
                if (lines.items.len > 1) cross_extra_gap = cross_remaining / (line_count_f - 1);
            },
            .space_around => {
                if (lines.items.len > 0) {
                    cross_extra_gap = cross_remaining / line_count_f;
                    cross_start = cross_extra_gap / 2;
                }
            },
            .stretch => {
                // stretch 模式下各行交叉轴尺寸平分剩余空间
                if (lines.items.len > 0 and cross_remaining > 0) {
                    const extra_per_line = cross_remaining / line_count_f;
                    for (lines.items) |*line| {
                        line.cross_size += extra_per_line;
                    }
                }
            },
        }

        // 6. 逐行定位子项
        const justify = self.layout_style.justify_content;
        var cross_cursor: f32 = cross_start;

        for (lines.items) |line| {
            // 每行的 justify-content
            const line_items = flex_items.items[line.start..line.end];
            const line_count = line.end - line.start;
            const lc_f: f32 = @floatFromInt(line_count);
            const main_remaining = @max(0, main_max - line.main_size);
            var main_start: f32 = 0;
            var main_extra_gap: f32 = 0;

            // RTL: start/end 互换
            const is_rtl = is_row and self.layout_style.text_direction == .rtl;
            var effective_justify = justify;
            if (is_rtl) {
                effective_justify = switch (justify) {
                    .start => .end,
                    .end => .start,
                    else => justify,
                };
            }

            switch (effective_justify) {
                .start => {},
                .center => main_start = main_remaining / 2,
                .end => main_start = main_remaining,
                .space_between => {
                    if (line_count > 1) main_extra_gap = main_remaining / (lc_f - 1);
                },
                .space_around => {
                    if (line_count > 0) {
                        main_extra_gap = main_remaining / lc_f;
                        main_start = main_extra_gap / 2;
                    }
                },
                .space_evenly => {
                    main_extra_gap = main_remaining / (lc_f + 1);
                    main_start = main_extra_gap;
                },
            }

            var main_cursor: f32 = main_start;

            for (line_items) |*item| {
                const child = item.widget;
                const cm = child.layout_style.margin;
                const cross = child.layout_style.align_self orelse cross_align;

                if (is_row) {
                    // 主轴: x
                    main_cursor += cm.left;
                    child.rect.x = pad.left + main_cursor;
                    main_cursor -= cm.left;

                    // 交叉轴: y
                    switch (cross) {
                        .stretch => {
                            child.rect.y = pad.top + cross_cursor + cm.top;
                            if (child.layout_style.height == .auto) {
                                child.rect.height = line.cross_size - cm.top - cm.bottom;
                            }
                        },
                        .center => child.rect.y = pad.top + cross_cursor + cm.top + (line.cross_size - cm.top - cm.bottom - child.rect.height) / 2,
                        .end => child.rect.y = pad.top + cross_cursor + line.cross_size - child.rect.height - cm.bottom,
                        .start => child.rect.y = pad.top + cross_cursor + cm.top,
                        .baseline => {
                            // 行基线位置 = cross_cursor + line.baseline
                            // 子元素顶部 = 行基线位置 - item.baseline - cm.top
                            child.rect.y = pad.top + cross_cursor + line.baseline - item.baseline - cm.top;
                        },
                    }

                    main_cursor += item.main_size + gap_main + main_extra_gap;
                } else {
                    // 主轴: y
                    main_cursor += cm.top;
                    child.rect.y = pad.top + main_cursor;
                    main_cursor -= cm.top;

                    // 交叉轴: x
                    switch (cross) {
                        .stretch => {
                            child.rect.x = pad.left + cross_cursor + cm.left;
                            if (child.layout_style.width == .auto) {
                                child.rect.width = line.cross_size - cm.left - cm.right;
                            }
                        },
                        .center => child.rect.x = pad.left + cross_cursor + cm.left + (line.cross_size - cm.left - cm.right - child.rect.width) / 2,
                        .end => child.rect.x = pad.left + cross_cursor + line.cross_size - child.rect.width - cm.right,
                        .start, .baseline => child.rect.x = pad.left + cross_cursor + cm.left,
                    }

                    main_cursor += item.main_size + gap_main + main_extra_gap;
                }

                if (child.children.items.len > 0) {
                    child.layoutSubtree(ctx);
                }
            }

            cross_cursor += line.cross_size + gap_cross + cross_extra_gap;
        }

        // 绝对定位子项
        for (self.children.items) |child| {
            if (child.layout_style.position != .absolute) continue;
            self.layoutAbsolute(child, ctx);
        }

        // reverse 方向: 对已布局的子元素做坐标镜像
        const direction = self.layout_style.direction;
        const is_row_reverse = direction == .row_reverse;
        const is_col_reverse = direction == .column_reverse;
        const is_wrap_reverse = self.layout_style.wrap == .wrap_reverse;

        if (is_row_reverse or is_col_reverse or is_wrap_reverse) {
            for (self.children.items) |child| {
                if (child.layout_style.position == .absolute) continue;
                if (!child.state.visible) continue;

                if (is_row_reverse) {
                    const rel_x = child.rect.x - self.rect.x - pad.left;
                    child.rect.x = self.rect.x + pad.left + inner_w - rel_x - child.rect.width;
                }
                if (is_col_reverse) {
                    const rel_y = child.rect.y - self.rect.y - pad.top;
                    child.rect.y = self.rect.y + pad.top + inner_h - rel_y - child.rect.height;
                }
                if (is_wrap_reverse) {
                    if (is_row) {
                        const rel_y = child.rect.y - self.rect.y - pad.top;
                        child.rect.y = self.rect.y + pad.top + inner_h - rel_y - child.rect.height;
                    } else {
                        const rel_x = child.rect.x - self.rect.x - pad.left;
                        child.rect.x = self.rect.x + pad.left + inner_w - rel_x - child.rect.width;
                    }
                }
            }
        }
    }

    /// 绝对定位子项: 根据 top/left/right/bottom + 父容器尺寸定位
    pub fn layoutAbsolute(self: *Widget, child: *Widget, ctx: *PaintContext) void {
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
            child.layoutSubtree(ctx);
        }
    }

    // ── 绘制 ──────────────────────────────────────────────────────────────

    /// 递归绘制子树
    pub fn paintTree(self: *Widget, ctx: *PaintContext) void {
        if (!self.state.visible) return;
        if (self.opacity <= 0.0) return;

        // 每帧推进：动画/定时器/事件控制器 tick（零侵入，paint 前先让所有 widget 走到 tick）
        const now_ms: u64 = perf.nowMs();
        const delta_ms: u32 = if (self.last_paint_ms) |last|
            @intCast(@min(now_ms -| last, 500)) // 首帧后正常推进，防后台切回跳变最大 500ms
        else
            0; // 首帧不推进
        self.last_paint_ms = now_ms;
        if (self.vtable.tick) |tick_fn| tick_fn(self, delta_ms);
        self.tickControllers(delta_ms);

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

        // 子树裁剪 (容器如 ScrolledWindow 限制子项绘制范围; 先于子项绘制压入, 绘制后恢复)
        const prev_clip = if (self.clip_children) |clip_rect| ctx.renderer.pushClip(clip_rect) else null;

        // 递归子项 (传递偏移)
        for (self.children.items) |child| {
            var child_ctx = ctx.*;
            child_ctx.offset_x += self.rect.x;
            child_ctx.offset_y += self.rect.y;
            child_ctx.has_disabled_ancestor = ctx.has_disabled_ancestor or self.state.disabled;
            child.paintTree(&child_ctx);
        }

        if (self.clip_children != null) ctx.renderer.popClip(prev_clip);

        // disabled 视觉反馈: 半透明遮罩 (仅在没有 disabled 祖先时绘制, 避免重复叠加)
        if (self.state.disabled and !ctx.has_disabled_ancestor) {
            ctx.renderer.fillRect(
                .{ .x = ctx.offset_x + self.rect.x, .y = ctx.offset_y + self.rect.y, .width = self.rect.width, .height = self.rect.height },
                math.Color{ .r = 0, .g = 0, .b = 0, .a = 102 }, // ~40% 透明度
            ) catch {};
        }

        self.state.dirty = false;
    }

    /// 递归 tick 动画子树
    pub fn tickTree(self: *Widget, delta_ms: u32) void {
        if (!self.state.visible) return;

        if (self.vtable.tick) |tick_fn| {
            tick_fn(self, delta_ms);
        }
        self.tickControllers(delta_ms);

        for (self.children.items) |child| {
            child.tickTree(delta_ms);
        }
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

        // 自定义命中测试 (弹出菜单等位置不受布局控制的控件)
        if (self.vtable.hit_test) |ht| {
            return ht(self, x, y);
        }

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

    /// 解析控件的有效光标样式: 向上查找父级, 直到找到非 null 的 cursor; 根控件默认 arrow
    pub fn resolveCursor(self: *const Widget) pal.CursorType {
        var current: ?*const Widget = self;
        var is_first = true;
        while (current) |w| {
            // disabled 的控件使用父级光标 (第一个 = 最深层的禁用控件跳过自己的 cursor)
            if (is_first and w.state.disabled) {
                current = w.parent;
                is_first = false;
                continue;
            }
            if (w.cursor) |c| return c;
            current = w.parent;
            is_first = false;
        }
        return .arrow;
    }

    /// 根据鼠标位置更新光标: hitTest 找到最深控件, 调用 setCursorFn 设置光标
    pub fn updateCursorAt(self: *Widget, x: f32, y: f32, setCursorFn: *const fn (cursor: pal.CursorType) void) void {
        const hit = self.hitTest(x, y) orelse {
            setCursorFn(.arrow);
            return;
        };
        setCursorFn(hit.resolveCursor());
    }

    /// 向上查找第一个有 tooltip_text 的控件 (含自己)
    pub fn findTooltip(self: *const Widget) ?[]const u8 {
        var current: ?*const Widget = self;
        while (current) |w| {
            if (w.tooltip_text) |t| return t;
            current = w.parent;
        }
        return null;
    }

    /// 从指定控件开始向上查找第一个有 context_menu 的控件 (含自己), 返回菜单
    pub fn findContextMenu(_: *const Widget, start: *const Widget) ?*@import("context_menu.zig").ContextMenu {
        var current: ?*const Widget = start;
        while (current) |w| {
            if (w.context_menu) |m| return m;
            current = w.parent;
        }
        return null;
    }

    /// 分发事件到目标控件 (冒泡)
    pub fn dispatchEvent(self: *Widget, event: *const pal.Event, ectx: *EventContext) EventResult {
        // 找到目标
        const target = switch (event.*) {
            .mouse_button => |mb| self.hitTest(@floatFromInt(mb.x), @floatFromInt(mb.y)),
            .mouse_move => |mm| self.hitTest(@floatFromInt(mm.x), @floatFromInt(mm.y)),
            // 滚轮事件命中鼠标下方的控件 (使 ScrolledWindow 等在鼠标悬停于其范围内时随滚轮滚动)
            .scroll => self.hitTest(ectx.mouse_x, ectx.mouse_y),
            // 键盘 / 文本输入 / IME 事件路由到焦点控件 (聚焦的 TextInput 接收字符与输入法提交),
            // 无焦点时回退根控件
            .key, .text_input, .ime_commit, .ime_preedit, .ime_delete => self.findFocused() orelse self,
            else => self,
        } orelse return .ignored;

        // 鼠标按下命中可聚焦控件时自动聚焦 (GTK 行为: 点击输入框/按钮等获取焦点)
        if (event.* == .mouse_button and event.mouse_button.state == .pressed and target.vtable.focusable and !target.state.disabled) {
            self.setFocused(target);
        }

        // 右键菜单: 右键按下时向上查找第一个有 context_menu 的控件并弹出
        // (disabled 控件自己的 context_menu 不弹出, 但父控件的可以)
        if (event.* == .mouse_button and event.mouse_button.button == .right and event.mouse_button.state == .pressed) {
            const start = if (target.state.disabled) target.parent orelse target else target;
            if (self.findContextMenu(start)) |menu| {
                menu.popupAt(@floatFromInt(event.mouse_button.x), @floatFromInt(event.mouse_button.y));
                return .handled;
            }
        }

        // 目标处理 (disabled 控件不处理事件, 但仍允许冒泡)
        if (!target.state.disabled) {
            // 先调用目标自身的 event controllers (GTK4: controllers 先于 widget.on_event)
            for (target.event_controllers.items) |*ctrl| {
                if (ctrl.handle_event(ctrl.self_ptr, target, event, ectx) == .handled) return .handled;
            }
            if (target.vtable.on_event) |handler| {
                if (handler(target, event, ectx) == .handled) return .handled;
            }
        }

        // 冒泡到父级
        var current = target.parent;
        while (current) |w| {
            if (!w.state.disabled) {
                for (w.event_controllers.items) |*ctrl| {
                    if (ctrl.handle_event(ctrl.self_ptr, w, event, ectx) == .handled) return .handled;
                }
            }
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

    /// 深度优先收集所有可聚焦控件 (按 Tab 顺序)。调用者拥有返回切片。
    pub fn collectFocusable(self: *Widget, allocator: std.mem.Allocator) ![]*Widget {
        var list = std.ArrayListUnmanaged(*Widget){ .items = &.{}, .capacity = 0 };
        errdefer list.deinit(allocator);
        self.collectFocusableInto(&list, allocator);
        return list.toOwnedSlice(allocator);
    }

    fn collectFocusableInto(self: *Widget, list: *std.ArrayListUnmanaged(*Widget), allocator: std.mem.Allocator) void {
        for (self.children.items) |child| {
            if (!child.state.visible or child.state.disabled) continue;
            if (child.vtable.focusable) list.append(allocator, child) catch {};
            child.collectFocusableInto(list, allocator);
        }
    }

    /// 查找子树中当前聚焦的控件
    pub fn findFocused(self: *Widget) ?*Widget {
        if (self.state.focused) return self;
        for (self.children.items) |child| {
            if (child.findFocused()) |f| return f;
        }
        return null;
    }

    /// 将焦点设置到指定控件 (清除子树中其他焦点)
    pub fn setFocused(self: *Widget, target: ?*Widget) void {
        self.clearFocus();
        if (target) |t| t.state.focused = true;
    }

    /// 清除子树中所有焦点标记
    pub fn clearFocus(self: *Widget) void {
        self.state.focused = false;
        for (self.children.items) |child| child.clearFocus();
    }

    /// Tab 焦点前进 (循环)。返回新聚焦控件 (无可聚焦控件时返回 null)。
    pub fn focusNext(self: *Widget) ?*Widget {
        return self.focusAdvance(1);
    }

    /// Shift+Tab 焦点后退 (循环)。
    pub fn focusPrev(self: *Widget) ?*Widget {
        return self.focusAdvance(-1);
    }

    fn focusAdvance(self: *Widget, dir: i32) ?*Widget {
        const alloc = std.heap.page_allocator;
        const list = self.collectFocusable(alloc) catch return null;
        defer alloc.free(list);
        if (list.len == 0) return null;
        const focused = self.findFocused();
        const n = list.len;
        var next_idx: usize = 0;
        if (focused) |f| {
            var idx: usize = 0;
            for (list, 0..) |w, i| {
                if (w == f) {
                    idx = i;
                    break;
                }
            }
            next_idx = if (dir >= 0) (idx + 1) % n else (idx + n - 1) % n;
        } else {
            // 无当前焦点: 前进→首个, 后退→末个
            next_idx = if (dir >= 0) 0 else n - 1;
        }
        self.setFocused(list[next_idx]);
        return list[next_idx];
    }

    /// 控件是否为 ancestor 的后代 (含自身)
    pub fn isDescendantOf(self: *const Widget, ancestor: *const Widget) bool {
        var cur: ?*const Widget = self;
        while (cur) |w| : (cur = w.parent) {
            if (w == ancestor) return true;
        }
        return false;
    }

    /// 无障碍描述文本: "角色 名称 值" (供屏幕阅读器朗读; 调用者拥有返回切片)
    pub fn accessibilityDescription(self: *const Widget, allocator: std.mem.Allocator) ![]u8 {
        const role_name = roleName(self.accessibility.role);
        const label = self.accessibility.label orelse "";
        const value = self.accessibility.value orelse "";
        return try std.fmt.allocPrint(allocator, "{s} {s} {s}", .{ role_name, label, value });
    }
};

/// 角色 → 可读名称 (无障碍朗读)
pub fn roleName(role: Role) []const u8 {
    return switch (role) {
        .none => "",
        .button => "按钮",
        .checkbox => "复选框",
        .radio => "单选按钮",
        .toggle => "开关",
        .slider => "滑块",
        .progress => "进度条",
        .text => "文本",
        .image => "图片",
        .list => "列表",
        .list_item => "列表项",
        .container => "容器",
        .scroll_area => "滚动区域",
        .tab => "标签页",
        .menu => "菜单",
        .dialog => "对话框",
        .status => "状态栏",
    };
}

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
        .window_id = 0,
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
        .window_id = 0,
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
        .window_id = 0,
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

// ── 焦点导航 / 无障碍 Tests ──────────────────────────────────────

const test_vtable_focusable = Widget.VTable{
    .type_name = "test_focusable",
    .measure = testMeasure,
    .paint = testPaint,
    .on_event = testOnEvent,
    .focusable = true,
    .destroy = testDestroy,
};

test "widget collectFocusable skips disabled and invisible" {
    var root: Widget = .{ .vtable = &test_vtable, .id = 1 };
    var a: Widget = .{ .vtable = &test_vtable_focusable, .id = 2 };
    var b: Widget = .{ .vtable = &test_vtable_focusable, .id = 3 };
    var c: Widget = .{ .vtable = &test_vtable_focusable, .id = 4 };
    b.state.disabled = true; // 禁用: 跳过
    c.state.visible = false; // 不可见: 跳过
    try root.addChild(std.testing.allocator, &a);
    try root.addChild(std.testing.allocator, &b);
    try root.addChild(std.testing.allocator, &c);
    defer root.children.deinit(std.testing.allocator);

    const list = try root.collectFocusable(std.testing.allocator);
    defer std.testing.allocator.free(list);
    try std.testing.expectEqual(@as(usize, 1), list.len);
    try std.testing.expectEqual(@as(WidgetId, 2), list[0].id);
}

test "widget focusNext cycles through focusable children" {
    var root: Widget = .{ .vtable = &test_vtable, .id = 1 };
    var a: Widget = .{ .vtable = &test_vtable_focusable, .id = 2 };
    var b: Widget = .{ .vtable = &test_vtable_focusable, .id = 3 };
    try root.addChild(std.testing.allocator, &a);
    try root.addChild(std.testing.allocator, &b);
    defer root.children.deinit(std.testing.allocator);

    // 初始无焦点 → focusNext 聚焦第一个
    const f1 = root.focusNext();
    try std.testing.expectEqual(@as(WidgetId, 2), f1.?.id);
    try std.testing.expect(a.state.focused);

    // 再 Tab → 第二个
    const f2 = root.focusNext();
    try std.testing.expectEqual(@as(WidgetId, 3), f2.?.id);
    try std.testing.expect(!a.state.focused);
    try std.testing.expect(b.state.focused);

    // 循环回第一个
    const f3 = root.focusNext();
    try std.testing.expectEqual(@as(WidgetId, 2), f3.?.id);

    // Shift+Tab 后退到第二个
    const f4 = root.focusPrev();
    try std.testing.expectEqual(@as(WidgetId, 3), f4.?.id);
}

test "widget findFocused and clearFocus" {
    var root: Widget = .{ .vtable = &test_vtable, .id = 1 };
    var a: Widget = .{ .vtable = &test_vtable_focusable, .id = 2 };
    try root.addChild(std.testing.allocator, &a);
    defer root.children.deinit(std.testing.allocator);

    try std.testing.expect(root.findFocused() == null);
    root.setFocused(&a);
    try std.testing.expectEqual(@as(WidgetId, 2), root.findFocused().?.id);
    root.clearFocus();
    try std.testing.expect(root.findFocused() == null);
}

test "widget isDescendantOf traces parent chain" {
    var root: Widget = .{ .vtable = &test_vtable, .id = 1 };
    var child: Widget = .{ .vtable = &test_vtable, .id = 2 };
    var grand: Widget = .{ .vtable = &test_vtable, .id = 3 };
    try root.addChild(std.testing.allocator, &child);
    try child.addChild(std.testing.allocator, &grand);
    defer child.children.deinit(std.testing.allocator);
    defer root.children.deinit(std.testing.allocator);

    try std.testing.expect(grand.isDescendantOf(&root));
    try std.testing.expect(grand.isDescendantOf(&child));
    try std.testing.expect(!root.isDescendantOf(&grand));
}

test "widget accessibilityDescription formats role label value" {
    var w: Widget = .{ .vtable = &test_vtable, .id = 1 };
    w.accessibility = .{ .role = .checkbox, .label = "同意条款", .value = "已选中" };
    const desc = try w.accessibilityDescription(std.testing.allocator);
    defer std.testing.allocator.free(desc);
    try std.testing.expectEqualStrings("复选框 同意条款 已选中", desc);
}

test "roleName maps roles to readable names" {
    try std.testing.expectEqualStrings("按钮", roleName(.button));
    try std.testing.expectEqualStrings("滚动区域", roleName(.scroll_area));
    try std.testing.expectEqualStrings("", roleName(.none));
}
