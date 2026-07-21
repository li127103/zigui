//! 2D 渲染引擎

pub const path = @import("path.zig");
pub const draw_cmd = @import("draw_cmd.zig");

pub const Path = path.Path;
pub const PathCommand = path.PathCommand;
pub const DrawCmd = draw_cmd.DrawCmd;
pub const Brush = draw_cmd.Brush;
pub const FillRule = draw_cmd.FillRule;

/// 2D 渲染引擎主接口
pub const RenderEngine = struct {
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) RenderEngine {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *RenderEngine) void {
        _ = self;
    }
};

const std = @import("std");
