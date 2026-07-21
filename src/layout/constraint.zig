//! 布局约束

const std = @import("std");
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

    /// 收缩约束 (减去 padding)
    pub fn deflate(self: Constraints, pad: math.EdgeInsets) Constraints {
        const h_pad = pad.left + pad.right;
        const v_pad = pad.top + pad.bottom;
        return .{
            .min_width = @max(0, self.min_width - h_pad),
            .max_width = @max(0, self.max_width - h_pad),
            .min_height = @max(0, self.min_height - v_pad),
            .max_height = @max(0, self.max_height - v_pad),
        };
    }

    /// 扩展约束 (加上 padding)
    pub fn inflate(self: Constraints, pad: math.EdgeInsets) Constraints {
        const h_pad = pad.left + pad.right;
        const v_pad = pad.top + pad.bottom;
        return .{
            .min_width = self.min_width + h_pad,
            .max_width = if (std.math.isInf(self.max_width)) self.max_width else self.max_width + h_pad,
            .min_height = self.min_height + v_pad,
            .max_height = if (std.math.isInf(self.max_height)) self.max_height else self.max_height + v_pad,
        };
    }
};

test "Constraints.constrain" {
    const c = Constraints{ .min_width = 10, .max_width = 100, .min_height = 10, .max_height = 100 };
    const s = c.constrain(.{ .width = 200, .height = 5 });
    try std.testing.expectEqual(@as(f32, 100), s.width);
    try std.testing.expectEqual(@as(f32, 10), s.height);
}

test "Constraints.deflate" {
    const c = Constraints{ .min_width = 100, .max_width = 500, .min_height = 100, .max_height = 500 };
    const pad = math.EdgeInsets{ .left = 10, .right = 10, .top = 5, .bottom = 5 };
    const d = c.deflate(pad);
    try std.testing.expectEqual(@as(f32, 80), d.min_width);
    try std.testing.expectEqual(@as(f32, 480), d.max_width);
    try std.testing.expectEqual(@as(f32, 90), d.min_height);
    try std.testing.expectEqual(@as(f32, 490), d.max_height);
}
