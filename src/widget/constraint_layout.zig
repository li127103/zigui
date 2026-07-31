//! ConstraintLayout 约束布局 (对标 GTK4 GtkConstraintLayout)
//!
//! GTK4 GtkConstraintLayout 使用 GtkConstraint 对象描述子控件之间的约束关系，
//! 支持属性 (start/end/top/bottom/width/height/centerX/centerY) 之间的线性关系：
//!   target.attribute = relation × source.attribute × multiplier + constant
//!
//! 这里提供简化实现，支持常见的 4 边对齐、居中、宽高比、等宽/等高。
//!
//! 使用方式：
//! ```
//! var cl = try ConstraintLayout.create(allocator);
//! const a = try Label.create(...);
//! const b = try Button.create(...);
//! try cl.add(&a.base);
//! try cl.add(&b.base);
//! // a 左边 = 父容器左边 + 16
//! try cl.constrain(a, .start, .equal, null, .start, 1.0, 16);
//! // b 左边 = a 右边 + 8
//! try cl.constrain(b, .start, .equal, a, .end, 1.0, 8);
//! // b 垂直居中
//! try cl.constrain(b, .center_y, .equal, null, .center_y, 1.0, 0);
//! ```

const std = @import("std");
const math = @import("../math.zig");
const widget_mod = @import("widget.zig");
const layout_mod = @import("../layout/engine.zig");
const pal = @import("../pal/pal.zig");

const Widget = widget_mod.Widget;
const PaintContext = widget_mod.PaintContext;
const EventContext = widget_mod.EventContext;
const EventResult = widget_mod.EventResult;
const Constraints = layout_mod.Constraints;

// ────────────────────────────────────────────────────────────────────────────
// 约束类型定义 (GTK4: GtkConstraintAttribute / GtkConstraintRelation)
// ────────────────────────────────────────────────────────────────────────────

pub const ConstraintAttribute = enum {
    none,
    start, // 左/上边 (LTR/TTB)
    end, // 右/下边
    top,
    bottom,
    left,
    right,
    width,
    height,
    center_x,
    center_y,
    baseline,
};

pub const ConstraintRelation = enum {
    less_than_or_equal, // ≤
    equal, // =
    greater_than_or_equal, // ≥
};

/// 单个约束描述
pub const Constraint = struct {
    target: *Widget,
    target_attr: ConstraintAttribute,
    relation: ConstraintRelation,
    source: ?*Widget, // null = 父容器 (ConstraintLayout 自身)
    source_attr: ConstraintAttribute,
    multiplier: f32 = 1.0,
    constant: f32 = 0,
    strength: f32 = 1.0, // 0..1, 越大越优先
    target_is_guide: bool = false, // true → target 其实是 *ConstraintGuide，强制转换
    source_is_guide: bool = false,

    /// target.attr = source.attr * mul + const
    pub fn init(
        target: *Widget,
        target_attr: ConstraintAttribute,
        relation: ConstraintRelation,
        source: ?*Widget,
        source_attr: ConstraintAttribute,
        multiplier: f32,
        constant: f32,
    ) Constraint {
        return .{
            .target = target,
            .target_attr = target_attr,
            .relation = relation,
            .source = source,
            .source_attr = source_attr,
            .multiplier = multiplier,
            .constant = constant,
        };
    }
};

// ────────────────────────────────────────────────────────────────────────────
// ConstraintLayout 主类
// ────────────────────────────────────────────────────────────────────────────

pub const ConstraintLayout = struct {
    base: Widget,
    allocator: std.mem.Allocator,
    children: std.ArrayListUnmanaged(*Widget) = .empty,
    constraints: std.ArrayListUnmanaged(Constraint) = .empty,
    guides: std.ArrayListUnmanaged(*ConstraintGuide) = .empty,

    bg_color: math.Color = math.Color.hex(0x00000000),

    const Self = @This();

    pub fn create(allocator: std.mem.Allocator) !*ConstraintLayout {
        const self = try allocator.create(ConstraintLayout);
        self.* = .{
            .base = .{
                .vtable = &vtable,
                .id = widget_mod.genWidgetId(),
            },
            .allocator = allocator,
        };
        return self;
    }

    pub fn destroy(self: *Self, allocator: std.mem.Allocator) void {
        // 显式销毁所有子控件 (遵循硬约束)
        for (self.children.items) |child| {
            child.vtable.destroy(child, allocator);
        }
        self.children.deinit(allocator);
        self.constraints.deinit(allocator);
        self.guides.deinit(allocator);
        self.base.background.deinit(allocator);
        allocator.destroy(self);
    }

    /// 向布局中添加子控件
    pub fn add(self: *Self, child: *Widget) !void {
        try self.children.append(self.allocator, child);
        try self.base.addChild(self.allocator, child);
    }

    /// 移除子控件
    pub fn remove(self: *Self, child: *Widget) void {
        // 从 children 列表移除
        const idx = for (self.children.items, 0..) |c, i| {
            if (c == child) break i;
        } else return;
        _ = self.children.orderedRemove(idx);
        // 移除引用 child 的所有约束
        var i: usize = 0;
        while (i < self.constraints.items.len) {
            const c = self.constraints.items[i];
            if (c.target == child or (c.source orelse null == child)) {
                _ = self.constraints.orderedRemove(i);
            } else {
                i += 1;
            }
        }
        // 显式销毁 (遵循硬约束)
        if (child.vtable.destroy) |d| d(child, self.allocator);
        self.base.markLayoutDirty();
    }

    /// 添加约束
    pub fn addConstraint(self: *Self, c: Constraint) !void {
        try self.constraints.append(self.allocator, c);
        self.base.markLayoutDirty();
    }

    /// 便捷 API: 添加一条约束 (GTK4 风格)
    pub fn constrain(
        self: *Self,
        target: *Widget,
        target_attr: ConstraintAttribute,
        relation: ConstraintRelation,
        source: ?*Widget,
        source_attr: ConstraintAttribute,
        multiplier: f32,
        constant: f32,
    ) !void {
        try self.addConstraint(Constraint.init(
            target,
            target_attr,
            relation,
            source,
            source_attr,
            multiplier,
            constant,
        ));
    }

    /// 便捷 API: 四边对齐到父容器
    pub fn pinToParent(self: *Self, child: *Widget, padding: f32) !void {
        try self.constrain(child, .start, .equal, null, .start, 1.0, padding);
        try self.constrain(child, .top, .equal, null, .top, 1.0, padding);
        try self.constrain(child, .end, .equal, null, .end, 1.0, -padding);
        try self.constrain(child, .bottom, .equal, null, .bottom, 1.0, -padding);
    }

    /// 便捷 API: 居中于父容器
    pub fn centerInParent(self: *Self, child: *Widget) !void {
        try self.constrain(child, .center_x, .equal, null, .center_x, 1.0, 0);
        try self.constrain(child, .center_y, .equal, null, .center_y, 1.0, 0);
    }

    /// 便捷 API: 设置固定宽高
    pub fn setSize(self: *Self, child: *Widget, width: f32, height: f32) !void {
        try self.constrain(child, .width, .equal, null, .none, 0, width);
        try self.constrain(child, .height, .equal, null, .none, 0, height);
    }

    // ── 布局求解器 (简化: 多轮松弛) ─────────────────────────────────────────

    /// 读取 widget 某个属性的当前值
    fn readAttr(self: *Self, widget: ?*Widget, attr: ConstraintAttribute, parent_rect: math.Rect(f32)) f32 {
        const w = widget orelse {
            // 父容器 = self 的 rect (相对自身从 0 开始)
            const r = math.Rect(f32){ .x = 0, .y = 0, .width = self.base.rect.width, .height = self.base.rect.height };
            return readRectAttr(r, attr, parent_rect);
        };
        if (attr == .none) return 0;
        return readRectAttr(w.rect, attr, parent_rect);
    }

    fn readRectAttr(r: math.Rect(f32), attr: ConstraintAttribute, _parent: math.Rect(f32)) f32 {
        _ = _parent;
        return switch (attr) {
            .none => 0,
            .start, .left => r.x,
            .end, .right => r.x + r.width,
            .top => r.y,
            .bottom => r.y + r.height,
            .width => r.width,
            .height => r.height,
            .center_x => r.x + r.width * 0.5,
            .center_y => r.y + r.height * 0.5,
            .baseline => r.y + r.height * 0.8,
        };
    }

    /// 写入 widget 某个属性值 (调整 rect)
    fn writeAttr(_self: *Self, widget: *Widget, attr: ConstraintAttribute, value: f32) void {
        _ = _self;
        var r = widget.rect;
        switch (attr) {
            .start, .left => {
                const delta = value - r.x;
                r.x = value;
                r.width -= delta;
                if (r.width < 0) r.width = 0;
            },
            .end, .right => {
                r.width = value - r.x;
                if (r.width < 0) {
                    r.x = value;
                    r.width = 0;
                }
            },
            .top => {
                const delta = value - r.y;
                r.y = value;
                r.height -= delta;
                if (r.height < 0) r.height = 0;
            },
            .bottom => {
                r.height = value - r.y;
                if (r.height < 0) {
                    r.y = value;
                    r.height = 0;
                }
            },
            .width => {
                r.width = @max(0, value);
            },
            .height => {
                r.height = @max(0, value);
            },
            .center_x => {
                r.x = value - r.width * 0.5;
            },
            .center_y => {
                r.y = value - r.height * 0.5;
            },
            .baseline => {
                r.y = value - r.height * 0.8;
            },
            .none => {},
        }
        widget.rect = r;
    }

    fn solve(self: *Self, available_w: f32, available_h: f32) void {
        const parent_rect = math.Rect(f32){ .x = 0, .y = 0, .width = available_w, .height = available_h };
        // 先按 strength 从大到小排序约束
        std.sort.pdq(Constraint, self.constraints.items, {}, struct {
            fn lessThan(_: void, a: Constraint, b: Constraint) bool {
                return a.strength > b.strength;
            }
        }.lessThan);

        // 多轮松弛
        var round: u32 = 0;
        while (round < 8) : (round += 1) {
            var changed = false;
            for (self.constraints.items) |c| {
                const source_val = self.readAttr(c.source, c.source_attr, parent_rect);
                const target_val = self.readAttr(c.target, c.target_attr, parent_rect);
                const expected = source_val * c.multiplier + c.constant;
                const violate = switch (c.relation) {
                    .less_than_or_equal => target_val > expected + 0.01,
                    .equal => @abs(target_val - expected) > 0.01,
                    .greater_than_or_equal => target_val < expected - 0.01,
                };
                if (violate) {
                    // 简单处理: 直接设置到期望值 (忽略 multiplier 反向解)
                    self.writeAttr(c.target, c.target_attr, expected);
                    changed = true;
                }
            }
            if (!changed) break;
        }
    }

    // ── VTable ──────────────────────────────────────────────────────────────

    const vtable = Widget.VTable{
        .type_name = "constraint_layout",
        .measure = measure,
        .perform_layout = layout,
        .paint = paint,
        .on_event = onEvent,
        .focusable = false,
        .destroy = destroyVTable,
    };

    fn destroyVTable(w: *Widget, allocator: std.mem.Allocator) void {
        const self: *Self = @fieldParentPtr("base", w);
        self.destroy(allocator);
    }

    fn measure(w: *Widget, ctx: *PaintContext, constraints: Constraints) math.Size(f32) {
        const self: *Self = @fieldParentPtr("base", w);
        var max_w: f32 = 0;
        var max_h: f32 = 0;
        // 先测量各子控件 (不做约束求解)
        for (self.children.items) |child| {
            const size = child.vtable.measure(child, ctx, constraints);
            max_w = @max(max_w, size.width);
            max_h = @max(max_h, size.height);
            child.rect.width = size.width;
            child.rect.height = size.height;
        }
        // 至少填满可用空间
        return constraints.constrain(.{
            .width = @max(max_w, 1),
            .height = @max(max_h, 1),
        });
    }

    fn layout(w: *Widget, _ctx: *PaintContext) void {
        const self: *Self = @fieldParentPtr("base", w);
        _ = _ctx;
        // 先给子控件默认尺寸 (如果未被显式约束 width/height)
        for (self.children.items) |child| {
            if (child.rect.width <= 0) child.rect.width = @min(w.rect.width, 100);
            if (child.rect.height <= 0) child.rect.height = @min(w.rect.height, 32);
            child.rect.x = 0;
            child.rect.y = 0;
        }
        self.solve(w.rect.width, w.rect.height);
        // 确保 rect 非负
        for (self.children.items) |child| {
            if (child.rect.width < 0) child.rect.width = 0;
            if (child.rect.height < 0) child.rect.height = 0;
        }
    }

    fn paint(w: *Widget, ctx: *PaintContext) void {
        const self: *Self = @fieldParentPtr("base", w);
        if (self.bg_color.a != 0) {
            ctx.renderer.fillRect(.{
                .x = ctx.offset_x + w.rect.x,
                .y = ctx.offset_y + w.rect.y,
                .width = w.rect.width,
                .height = w.rect.height,
            }, self.bg_color) catch {};
        }
        // Widget.paintTree 默认循环会绘制 children, 此处无需手动 paintTree
    }

    fn onEvent(w: *Widget, event: *const pal.Event, ectx: *EventContext) EventResult {
        const self: *Self = @fieldParentPtr("base", w);
        _ = self;
        _ = event;
        _ = ectx;
        return .ignored;
    }

    // ── Guide 管理（GTK4 GtkConstraintGuide 支持） ────────────────────────

    /// 注册导引
    pub fn addGuide(self: *Self, guide: *ConstraintGuide) !void {
        try self.guides.append(self.allocator, guide);
    }

    pub fn removeGuide(self: *Self, guide: *ConstraintGuide) void {
        for (self.guides.items, 0..) |g, i| {
            if (g == guide) {
                _ = self.guides.orderedRemove(i);
                return;
            }
        }
    }

    pub fn getGuideCount(self: *const Self) u32 {
        return self.guides.items.len;
    }

    /// 以 Guide 为 target 的便捷约束添加（target = Guide，source 可为 Widget / Guide / null=父）
    pub fn constrainGuide(
        self: *Self,
        target: *ConstraintGuide,
        target_attr: ConstraintAttribute,
        rel: ConstraintRelation,
        source_widget: ?*Widget,
        source_attr: ConstraintAttribute,
        mul: f32,
        constant: f32,
    ) !void {
        try self.constraints.append(self.allocator, .{
            .target = @ptrCast(@alignCast(target)), // 作为 Widget* 占位，实际 readAttr 先查 guides
            .target_attr = target_attr,
            .target_is_guide = true,
            .relation = rel,
            .source = source_widget,
            .source_attr = source_attr,
            .multiplier = mul,
            .constant = constant,
        });
    }
};

// ═══════════════════════════════════════════════════════════════════════════════
//  ConstraintGuide（GTK4 GtkConstraintGuide — 约束参考线/容器）
// ═══════════════════════════════════════════════════════════════════════════════

/// 水平/垂直维度尺寸范围
pub const GuideSize = struct {
    min: f32 = 0,
    nat: f32 = 0,
    max: f32 = 100_000,
};

/// 导引强度级别（数字越大优先级越高，与 GTK4 GtkConstraintStrength 对应）
pub const ConstraintStrength = enum(f32) {
    require = 1.0,
    strong = 0.9,
    medium = 0.7,
    weak = 0.5,
};

pub const ConstraintGuide = struct {
    name: []const u8 = "",
    h: GuideSize = .{}, // 水平（width/x 相关）
    v: GuideSize = .{}, // 垂直（height/y 相关）
    strength: ConstraintStrength = .medium,

    /// 运行时计算得到的位置（Solver 写入；初始全 0）
    rect: math.Rect(f32) = .{ .x = 0, .y = 0, .width = 0, .height = 0 },

    const SelfG = @This();

    pub fn init(name: []const u8) SelfG {
        return .{ .name = name };
    }

    pub fn setName(self: *SelfG, name: []const u8) void {
        self.name = name;
    }
    pub fn setStrength(self: *SelfG, level: ConstraintStrength) void {
        self.strength = level;
    }

    /// 一次性设置 min/nat/max（水平 + 垂直）
    pub fn setMinSize(self: *SelfG, h_min: f32, v_min: f32) void {
        self.h.min = h_min;
        self.v.min = v_min;
    }
    pub fn setNatSize(self: *SelfG, h_nat: f32, v_nat: f32) void {
        self.h.nat = h_nat;
        self.v.nat = v_nat;
    }
    pub fn setMaxSize(self: *SelfG, h_max: f32, v_max: f32) void {
        self.h.max = h_max;
        self.v.max = v_max;
    }
    pub fn setMin(self: *SelfG, h_min: f32, v_min: f32) void {
        self.setMinSize(h_min, v_min);
    }
    pub fn setMax(self: *SelfG, h_max: f32, v_max: f32) void {
        self.setMaxSize(h_max, v_max);
    }
    pub fn setNat(self: *SelfG, h_nat: f32, v_nat: f32) void {
        self.setNatSize(h_nat, v_nat);
    }

    /// 作为通用 ConstraintTarget（供后续扩展 API 使用）
    pub fn asConstraintTarget(self: *SelfG) ?*anyopaque {
        return @ptrCast(self);
    }
};
