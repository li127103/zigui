//! 布局约束

const math = @import("../math.zig");

pub const Constraints = struct {
    min_width: f32 = 0,
    max_width: f32 = std.math.inf(f32),
    min_height: f32 = 0,
    max_height: f32 = std.math.inf(f32),

    pub fn constrain(self: Constraints, size: math.Size(f32)) math.Size(f32) {
        return .{
            .width = std.math.clamp(size.width, self.min_width, self.max_width),
            .height = std.math.clamp(size.height, self.min_height, self.max_height),
        };
    }

    pub fn tight(width: f32, height: f32) Constraints {
        return .{ .min_width = width, .max_width = width, .min_height = height, .max_height = height };
    }

    pub fn loose(width: f32, height: f32) Constraints {
        return .{ .min_width = 0, .max_width = width, .min_height = 0, .max_height = height };
    }

    pub fn unlimited() Constraints {
        return .{};
    }
};

const std = @import("std");

test "Constraints.constrain" {
    const c = Constraints{ .min_width = 10, .max_width = 100, .min_height = 10, .max_height = 100 };
    const s = c.constrain(.{ .width = 200, .height = 5 });
    try std.testing.expectEqual(@as(f32, 100), s.width);
    try std.testing.expectEqual(@as(f32, 10), s.height);
}
