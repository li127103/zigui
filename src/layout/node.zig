//! 布局节点

const math = @import("../math.zig");
const constraint_mod = @import("constraint.zig");

pub const Dimension = union(enum) {
    auto: void,
    px: f32,
    percent: f32,
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
    children: std.ArrayListUnmanaged(*LayoutNode) = .{},
    result: LayoutResult = .{},
    measure_fn: ?*const fn (nd: *LayoutNode, constraints: constraint_mod.Constraints) math.Size(f32) = null,
};

const std = @import("std");
