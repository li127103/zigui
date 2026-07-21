//! 布局节点 + Flexbox 算法

const std = @import("std");
const math = @import("../math.zig");
const constraint_mod = @import("constraint.zig");
const Constraints = constraint_mod.Constraints;

pub const Dimension = union(enum) {
    auto: void,
    px: f32,
    percent: f32,

    /// 解析为像素值 (percent 需要 parent_size)
    pub fn resolve(self: Dimension, parent_size: f32) ?f32 {
        return switch (self) {
            .auto => null,
            .px => |v| v,
            .percent => |p| p / 100.0 * parent_size,
        };
    }
};

pub const FlexDirection = enum { row, row_reverse, column, column_reverse };
pub const FlexWrap = enum { nowrap, wrap, wrap_reverse };
pub const JustifyContent = enum { start, center, end, space_between, space_around, space_evenly };
pub const AlignItems = enum { start, center, end, stretch, baseline };
pub const AlignContent = enum { start, center, end, stretch, space_between, space_around };
pub const Position = enum { relative, absolute };

pub const LayoutStyle = struct {
    // 尺寸
    width: Dimension = .{ .auto = {} },
    height: Dimension = .{ .auto = {} },
    min_width: Dimension = .{ .auto = {} },
    min_height: Dimension = .{ .auto = {} },
    max_width: Dimension = .{ .auto = {} },
    max_height: Dimension = .{ .auto = {} },

    // Flex 容器
    direction: FlexDirection = .row,
    wrap: FlexWrap = .nowrap,
    justify_content: JustifyContent = .start,
    align_items: AlignItems = .stretch,
    align_content: AlignContent = .start,
    gap: math.Size(f32) = .{ .width = 0, .height = 0 },

    // Flex 子项
    flex_grow: f32 = 0,
    flex_shrink: f32 = 1,
    flex_basis: Dimension = .{ .auto = {} },
    align_self: ?AlignItems = null,

    // 间距
    margin: math.EdgeInsets = .{},
    padding: math.EdgeInsets = .{},

    // 定位
    position: Position = .relative,
    top: ?f32 = null,
    left: ?f32 = null,
    right: ?f32 = null,
    bottom: ?f32 = null,
};

pub const LayoutResult = struct {
    x: f32 = 0,
    y: f32 = 0,
    width: f32 = 0,
    height: f32 = 0,
};

pub const LayoutNode = struct {
    style: LayoutStyle = .{},
    children: std.ArrayListUnmanaged(*LayoutNode) = .{ .items = &.{}, .capacity = 0 },
    result: LayoutResult = .{},
    measure_fn: ?*const fn (nd: *LayoutNode, constraints: Constraints) math.Size(f32) = null,
    allocator: ?std.mem.Allocator = null,

    pub fn init(allocator: std.mem.Allocator) LayoutNode {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *LayoutNode) void {
        if (self.allocator) |alloc| {
            self.children.deinit(alloc);
        }
    }

    pub fn addChild(self: *LayoutNode, child: *LayoutNode) !void {
        if (self.allocator) |alloc| {
            try self.children.append(alloc, child);
        }
    }

    /// 执行布局 (入口)
    pub fn computeLayout(self: *LayoutNode, available: Constraints) void {
        const size = self.measure(available);
        self.result.width = size.width;
        self.result.height = size.height;
        self.arrange(available);
    }

    // ── 内部实现 ──────────────────────────────────────────────────────────────

    fn isRow(self: *const LayoutNode) bool {
        return self.style.direction == .row or self.style.direction == .row_reverse;
    }

    fn isReverse(self: *const LayoutNode) bool {
        return self.style.direction == .row_reverse or self.style.direction == .column_reverse;
    }

    /// 解析 Dimension 到具体像素值
    fn resolveDim(dim: Dimension, parent_main: f32, parent_cross: f32, is_main: bool) ?f32 {
        const parent = if (is_main) parent_main else parent_cross;
        return dim.resolve(parent);
    }

    /// Pass 1: 测量节点尺寸
    fn measure(self: *LayoutNode, constraints: Constraints) math.Size(f32) {
        const s = &self.style;
        const parent_w = constraints.max_width;
        const parent_h = constraints.max_height;

        // 解析显式尺寸
        const explicit_w = resolveDim(s.width, parent_w, parent_h, true);
        const explicit_h = resolveDim(s.height, parent_w, parent_h, false);

        // 如果有显式宽高，直接返回 (受 min/max 约束)
        if (explicit_w != null and explicit_h != null) {
            var size = math.Size(f32){ .width = explicit_w.?, .height = explicit_h.? };
            size = self.applyMinMax(size, parent_w, parent_h);
            return constraints.constrain(size);
        }

        // 叶子节点: 调用 measure_fn
        if (self.children.items.len == 0) {
            if (self.measure_fn) |mf| {
                var inner = constraints;
                if (explicit_w) |w| {
                    inner.min_width = w;
                    inner.max_width = w;
                }
                if (explicit_h) |h| {
                    inner.min_height = h;
                    inner.max_height = h;
                }
                const measured = mf(self, inner);
                var size = math.Size(f32){
                    .width = explicit_w orelse measured.width,
                    .height = explicit_h orelse measured.height,
                };
                size = self.applyMinMax(size, parent_w, parent_h);
                return constraints.constrain(size);
            }
            // 无 measure_fn 的叶子 = 零尺寸
            var size = math.Size(f32){
                .width = explicit_w orelse 0,
                .height = explicit_h orelse 0,
            };
            size = self.applyMinMax(size, parent_w, parent_h);
            return constraints.constrain(size);
        }

        // 容器节点: 递归测量子项
        const pad = s.padding;
        const inner_constraints = constraints.deflate(pad);
        const is_row = self.isRow();
        const gap_main: f32 = if (is_row) s.gap.width else s.gap.height;

        var total_main: f32 = 0;
        var max_cross: f32 = 0;
        var child_count: usize = 0;

        for (self.children.items) |child| {
            if (child.style.position == .absolute) continue;

            const child_size = child.measure(inner_constraints);
            const child_margin = child.style.margin;

            if (is_row) {
                total_main += child_size.width + child_margin.left + child_margin.right;
                max_cross = @max(max_cross, child_size.height + child_margin.top + child_margin.bottom);
            } else {
                total_main += child_size.height + child_margin.top + child_margin.bottom;
                max_cross = @max(max_cross, child_size.width + child_margin.left + child_margin.right);
            }
            child_count += 1;
        }

        // 加上 gap
        if (child_count > 1) {
            total_main += gap_main * @as(f32, @floatFromInt(child_count - 1));
        }

        // 加上 padding
        var size: math.Size(f32) = undefined;
        if (is_row) {
            size = .{
                .width = explicit_w orelse (total_main + pad.left + pad.right),
                .height = explicit_h orelse (max_cross + pad.top + pad.bottom),
            };
        } else {
            size = .{
                .width = explicit_w orelse (max_cross + pad.left + pad.right),
                .height = explicit_h orelse (total_main + pad.top + pad.bottom),
            };
        }

        size = self.applyMinMax(size, parent_w, parent_h);
        return constraints.constrain(size);
    }

    /// Pass 2: 定位子项
    fn arrange(self: *LayoutNode, constraints: Constraints) void {
        _ = constraints;
        if (self.children.items.len == 0) return;

        const s = &self.style;
        const pad = s.padding;
        const is_row = self.isRow();
        const is_reverse = self.isReverse();
        const gap_main: f32 = if (is_row) s.gap.width else s.gap.height;

        const container_w = self.result.width;
        const container_h = self.result.height;
        const inner_w = container_w - pad.left - pad.right;
        const inner_h = container_h - pad.top - pad.bottom;
        const inner_main: f32 = if (is_row) inner_w else inner_h;
        const inner_cross: f32 = if (is_row) inner_h else inner_w;

        // 收集 relative 子项
        var child_count: usize = 0;
        var total_main: f32 = 0;
        var total_grow: f32 = 0;
        var total_shrink: f32 = 0;

        // 第一遍: 测量并收集 flex 信息
        const inner_constraints = Constraints{
            .min_width = 0,
            .max_width = if (is_row) inner_w else std.math.inf(f32),
            .min_height = 0,
            .max_height = if (is_row) std.math.inf(f32) else inner_h,
        };

        for (self.children.items) |child| {
            if (child.style.position == .absolute) {
                self.arrangeAbsolute(child, container_w, container_h);
                continue;
            }
            const child_size = child.measure(inner_constraints);
            child.result.width = child_size.width;
            child.result.height = child_size.height;

            const cm = child.style.margin;
            if (is_row) {
                total_main += child_size.width + cm.left + cm.right;
            } else {
                total_main += child_size.height + cm.top + cm.bottom;
            }
            total_grow += child.style.flex_grow;
            total_shrink += child.style.flex_shrink;
            child_count += 1;
        }

        if (child_count == 0) return;

        // 加上 gap
        if (child_count > 1) {
            total_main += gap_main * @as(f32, @floatFromInt(child_count - 1));
        }

        // 计算剩余空间
        const free_space = inner_main - total_main;

        // 分配弹性空间
        if (free_space > 0 and total_grow > 0) {
            for (self.children.items) |child| {
                if (child.style.position == .absolute) continue;
                if (child.style.flex_grow > 0) {
                    const extra = free_space * (child.style.flex_grow / total_grow);
                    if (is_row) {
                        child.result.width += extra;
                    } else {
                        child.result.height += extra;
                    }
                }
            }
        } else if (free_space < 0 and total_shrink > 0) {
            for (self.children.items) |child| {
                if (child.style.position == .absolute) continue;
                if (child.style.flex_shrink > 0) {
                    const shrink = (-free_space) * (child.style.flex_shrink / total_shrink);
                    if (is_row) {
                        child.result.width = @max(0, child.result.width - shrink);
                    } else {
                        child.result.height = @max(0, child.result.height - shrink);
                    }
                }
            }
        }

        // 重新计算实际占用 (弹性分配后)
        var used_main: f32 = 0;
        for (self.children.items) |child| {
            if (child.style.position == .absolute) continue;
            const cm = child.style.margin;
            if (is_row) {
                used_main += child.result.width + cm.left + cm.right;
            } else {
                used_main += child.result.height + cm.top + cm.bottom;
            }
        }
        if (child_count > 1) {
            used_main += gap_main * @as(f32, @floatFromInt(child_count - 1));
        }

        // 主轴起始位置 (justify_content)
        const remaining = inner_main - used_main;
        var main_offset: f32 = 0;
        var extra_gap: f32 = 0;

        switch (s.justify_content) {
            .start => main_offset = 0,
            .center => main_offset = remaining / 2.0,
            .end => main_offset = remaining,
            .space_between => {
                main_offset = 0;
                if (child_count > 1) extra_gap = remaining / @as(f32, @floatFromInt(child_count - 1));
            },
            .space_around => {
                if (child_count > 0) {
                    extra_gap = remaining / @as(f32, @floatFromInt(child_count));
                    main_offset = extra_gap / 2.0;
                }
            },
            .space_evenly => {
                if (child_count > 0) {
                    extra_gap = remaining / @as(f32, @floatFromInt(child_count + 1));
                    main_offset = extra_gap;
                }
            },
        }

        if (is_reverse) {
            main_offset = inner_main - main_offset;
        }

        // 定位每个子项
        var cursor: f32 = main_offset;
        for (self.children.items) |child| {
            if (child.style.position == .absolute) continue;

            const cm = child.style.margin;
            const child_main: f32 = if (is_row) child.result.width else child.result.height;
            const child_cross: f32 = if (is_row) child.result.height else child.result.width;

            // 主轴定位
            if (is_reverse) {
                if (is_row) {
                    cursor -= cm.right + child_main;
                    child.result.x = pad.left + cursor;
                } else {
                    cursor -= cm.bottom + child_main;
                    child.result.y = pad.top + cursor;
                }
                cursor -= (if (is_row) cm.left else cm.top) + gap_main + extra_gap;
            } else {
                if (is_row) {
                    cursor += cm.left;
                    child.result.x = pad.left + cursor;
                    cursor += child_main + cm.right + gap_main + extra_gap;
                } else {
                    cursor += cm.top;
                    child.result.y = pad.top + cursor;
                    cursor += child_main + cm.bottom + gap_main + extra_gap;
                }
            }

            // 交叉轴定位 (align_items / align_self)
            const cross_align = child.style.align_self orelse s.align_items;
            const cross_start: f32 = if (is_row) pad.top else pad.left;

            switch (cross_align) {
                .start => {
                    if (is_row) {
                        child.result.y = cross_start + cm.top;
                    } else {
                        child.result.x = cross_start + cm.left;
                    }
                },
                .center => {
                    if (is_row) {
                        child.result.y = cross_start + (inner_cross - child_cross - cm.top - cm.bottom) / 2.0 + cm.top;
                    } else {
                        child.result.x = cross_start + (inner_cross - child_cross - cm.left - cm.right) / 2.0 + cm.left;
                    }
                },
                .end => {
                    if (is_row) {
                        child.result.y = cross_start + inner_cross - child_cross - cm.bottom;
                    } else {
                        child.result.x = cross_start + inner_cross - child_cross - cm.right;
                    }
                },
                .stretch => {
                    if (is_row) {
                        child.result.y = cross_start + cm.top;
                        // stretch: 扩展交叉轴尺寸
                        if (child.style.height == .auto) {
                            child.result.height = inner_cross - cm.top - cm.bottom;
                        }
                    } else {
                        child.result.x = cross_start + cm.left;
                        if (child.style.width == .auto) {
                            child.result.width = inner_cross - cm.left - cm.right;
                        }
                    }
                },
                .baseline => {
                    // 简化: baseline 当作 start
                    if (is_row) {
                        child.result.y = cross_start + cm.top;
                    } else {
                        child.result.x = cross_start + cm.left;
                    }
                },
            }

            // 递归布局子项
            const child_constraints = Constraints.tight(child.result.width, child.result.height);
            child.arrange(child_constraints);
        }
    }

    /// 绝对定位子项
    fn arrangeAbsolute(self: *LayoutNode, child: *LayoutNode, container_w: f32, container_h: f32) void {
        _ = self;
        const cs = &child.style;

        // 测量
        const child_size = child.measure(Constraints.unlimited());
        child.result.width = child_size.width;
        child.result.height = child_size.height;

        // 水平定位
        if (cs.left) |l| {
            child.result.x = l + cs.margin.left;
        } else if (cs.right) |r| {
            child.result.x = container_w - r - child.result.width - cs.margin.right;
        } else {
            child.result.x = cs.margin.left;
        }

        // 垂直定位
        if (cs.top) |t| {
            child.result.y = t + cs.margin.top;
        } else if (cs.bottom) |bt| {
            child.result.y = container_h - bt - child.result.height - cs.margin.bottom;
        } else {
            child.result.y = cs.margin.top;
        }

        // 递归
        const child_constraints = Constraints.tight(child.result.width, child.result.height);
        child.arrange(child_constraints);
    }

    /// 应用 min/max 约束
    fn applyMinMax(self: *const LayoutNode, size: math.Size(f32), parent_w: f32, parent_h: f32) math.Size(f32) {
        const s = &self.style;
        var result = size;

        if (resolveDim(s.min_width, parent_w, parent_h, true)) |mw| {
            result.width = @max(result.width, mw);
        }
        if (resolveDim(s.max_width, parent_w, parent_h, true)) |mw| {
            result.width = @min(result.width, mw);
        }
        if (resolveDim(s.min_height, parent_w, parent_h, false)) |mh| {
            result.height = @max(result.height, mh);
        }
        if (resolveDim(s.max_height, parent_w, parent_h, false)) |mh| {
            result.height = @min(result.height, mh);
        }

        return result;
    }
};

// ── 单元测试 ──────────────────────────────────────────────────────────────────

test "LayoutNode: 固定尺寸" {
    var node = LayoutNode{};
    node.style.width = .{ .px = 100 };
    node.style.height = .{ .px = 50 };
    node.computeLayout(.{ .max_width = 800, .max_height = 600 });
    try std.testing.expectEqual(@as(f32, 100), node.result.width);
    try std.testing.expectEqual(@as(f32, 50), node.result.height);
}

test "LayoutNode: row 布局 + flex_grow" {
    const alloc = std.testing.allocator;

    var parent = LayoutNode.init(alloc);
    defer parent.deinit();
    parent.style.width = .{ .px = 300 };
    parent.style.height = .{ .px = 100 };
    parent.style.direction = .row;
    parent.style.padding = .{ .left = 10, .right = 10, .top = 10, .bottom = 10 };

    var child1 = LayoutNode{};
    child1.style.width = .{ .px = 50 };
    child1.style.height = .{ .px = 30 };

    var child2 = LayoutNode{};
    child2.style.flex_grow = 1.0;
    child2.style.height = .{ .px = 30 };

    try parent.addChild(&child1);
    try parent.addChild(&child2);

    parent.computeLayout(.{ .max_width = 800, .max_height = 600 });

    // parent: 300x100, padding 10 each side → inner 280x80
    // child1: 50px, child2: 280-50=230px (flex_grow fills remaining)
    try std.testing.expectEqual(@as(f32, 50), child1.result.width);
    try std.testing.expectEqual(@as(f32, 230), child2.result.width);
    try std.testing.expectEqual(@as(f32, 10), child1.result.x); // padding.left
    try std.testing.expectEqual(@as(f32, 60), child2.result.x); // 10 + 50
}

test "LayoutNode: column 布局 + justify center" {
    const alloc = std.testing.allocator;

    var parent = LayoutNode.init(alloc);
    defer parent.deinit();
    parent.style.width = .{ .px = 200 };
    parent.style.height = .{ .px = 400 };
    parent.style.direction = .column;
    parent.style.justify_content = .center;

    var child1 = LayoutNode{};
    child1.style.width = .{ .px = 100 };
    child1.style.height = .{ .px = 50 };

    var child2 = LayoutNode{};
    child2.style.width = .{ .px = 100 };
    child2.style.height = .{ .px = 50 };

    try parent.addChild(&child1);
    try parent.addChild(&child2);

    parent.computeLayout(.{ .max_width = 800, .max_height = 600 });

    // total children height = 100, container = 400, remaining = 300
    // center → offset = 150
    try std.testing.expectEqual(@as(f32, 150), child1.result.y);
    try std.testing.expectEqual(@as(f32, 200), child2.result.y);
}
