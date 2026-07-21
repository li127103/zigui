//! 布局引擎

pub const node = @import("node.zig");
pub const constraint = @import("constraint.zig");

pub const Constraints = constraint.Constraints;
pub const LayoutNode = node.LayoutNode;
pub const LayoutStyle = node.LayoutStyle;
pub const Dimension = node.Dimension;
pub const FlexDirection = node.FlexDirection;
pub const JustifyContent = node.JustifyContent;
pub const AlignItems = node.AlignItems;

/// 执行布局
pub fn layout(root: *LayoutNode, constraints: Constraints) void {
    _ = root;
    _ = constraints;
    // M2: 实现两遍布局 (measure + arrange)
}
