//! 布局引擎 - Flexbox-like 约束布局

const std = @import("std");

pub const node = @import("node.zig");
pub const constraint = @import("constraint.zig");

pub const Constraints = constraint.Constraints;
pub const LayoutNode = node.LayoutNode;
pub const LayoutStyle = node.LayoutStyle;
pub const LayoutResult = node.LayoutResult;
pub const Dimension = node.Dimension;
pub const FlexDirection = node.FlexDirection;
pub const FlexWrap = node.FlexWrap;
pub const JustifyContent = node.JustifyContent;
pub const AlignItems = node.AlignItems;
pub const AlignContent = node.AlignContent;
pub const Position = node.Position;

/// 执行布局 (便捷入口)
pub fn layout(root: *LayoutNode, constraints: Constraints) void {
    root.computeLayout(constraints);
}

test {
    _ = node;
    _ = constraint;
}
