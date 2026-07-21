//! zigui 基础数学类型

/// 二维矩形
pub fn Rect(comptime T: type) type {
    return struct {
        x: T,
        y: T,
        width: T,
        height: T,

        const Self = @This();

        pub fn containsPoint(self: Self, px: T, py: T) bool {
            return px >= self.x and px < self.x + self.width and
                py >= self.y and py < self.y + self.height;
        }

        pub fn intersects(self: Self, other: Self) bool {
            return self.x < other.x + other.width and
                self.x + self.width > other.x and
                self.y < other.y + other.height and
                self.y + self.height > other.y;
        }

        pub fn intersection(self: Self, other: Self) ?Self {
            const x = @max(self.x, other.x);
            const y = @max(self.y, other.y);
            const r = @min(self.x + self.width, other.x + other.width);
            const b = @min(self.y + self.height, other.y + other.height);
            if (r <= x or b <= y) return null;
            return .{ .x = x, .y = y, .width = r - x, .height = b - y };
        }

        pub fn union_(self: Self, other: Self) Self {
            const x = @min(self.x, other.x);
            const y = @min(self.y, other.y);
            const r = @max(self.x + self.width, other.x + other.width);
            const b = @max(self.y + self.height, other.y + other.height);
            return .{ .x = x, .y = y, .width = r - x, .height = b - y };
        }
    };
}

/// 二维尺寸
pub fn Size(comptime T: type) type {
    return struct {
        width: T,
        height: T,
    };
}

/// 二维点
pub fn Point(comptime T: type) type {
    return struct {
        x: T,
        y: T,
    };
}

/// 四边间距
pub const EdgeInsets = struct {
    top: f32 = 0,
    right: f32 = 0,
    bottom: f32 = 0,
    left: f32 = 0,

    pub fn all(v: f32) EdgeInsets {
        return .{ .top = v, .right = v, .bottom = v, .left = v };
    }

    pub fn symmetric(h: f32, v: f32) EdgeInsets {
        return .{ .top = v, .right = h, .bottom = v, .left = h };
    }

    pub fn horizontal(self: EdgeInsets) f32 {
        return self.left + self.right;
    }

    pub fn vertical(self: EdgeInsets) f32 {
        return self.top + self.bottom;
    }
};

/// 2D 仿射变换矩阵 (3x2, 行主序)
/// | a  b  0 |
/// | c  d  0 |
/// | tx ty 1 |
pub const Mat3x2 = struct {
    a: f32 = 1,
    b: f32 = 0,
    c: f32 = 0,
    d: f32 = 1,
    tx: f32 = 0,
    ty: f32 = 0,

    pub const identity = Mat3x2{};

    pub fn translate(x: f32, y: f32) Mat3x2 {
        return .{ .tx = x, .ty = y };
    }

    pub fn scale(sx: f32, sy: f32) Mat3x2 {
        return .{ .a = sx, .d = sy };
    }

    pub fn rotate(radians: f32) Mat3x2 {
        const cos_r = @cos(radians);
        const sin_r = @sin(radians);
        return .{ .a = cos_r, .b = sin_r, .c = -sin_r, .d = cos_r };
    }

    pub fn multiply(self: Mat3x2, other: Mat3x2) Mat3x2 {
        return .{
            .a = self.a * other.a + self.b * other.c,
            .b = self.a * other.b + self.b * other.d,
            .c = self.c * other.a + self.d * other.c,
            .d = self.c * other.b + self.d * other.d,
            .tx = self.tx * other.a + self.ty * other.c + other.tx,
            .ty = self.tx * other.b + self.ty * other.d + other.ty,
        };
    }

    pub fn transformPoint(self: Mat3x2, p: [2]f32) [2]f32 {
        return .{
            self.a * p[0] + self.c * p[1] + self.tx,
            self.b * p[0] + self.d * p[1] + self.ty,
        };
    }

    pub fn invert(self: Mat3x2) ?Mat3x2 {
        const det = self.a * self.d - self.b * self.c;
        if (@abs(det) < 1e-10) return null;
        const inv_det = 1.0 / det;
        return .{
            .a = self.d * inv_det,
            .b = -self.b * inv_det,
            .c = -self.c * inv_det,
            .d = self.a * inv_det,
            .tx = (self.c * self.ty - self.d * self.tx) * inv_det,
            .ty = (self.b * self.tx - self.a * self.ty) * inv_det,
        };
    }
};

/// RGBA 颜色
pub const Color = struct {
    r: u8,
    g: u8,
    b: u8,
    a: u8,

    pub fn rgba(r: u8, g: u8, b: u8, a: u8) Color {
        return .{ .r = r, .g = g, .b = b, .a = a };
    }

    pub fn hex(v: u32) Color {
        return .{
            .r = @intCast((v >> 24) & 0xFF),
            .g = @intCast((v >> 16) & 0xFF),
            .b = @intCast((v >> 8) & 0xFF),
            .a = @intCast(v & 0xFF),
        };
    }

    pub fn toPremultiplied(self: Color) [4]f32 {
        const alpha: f32 = @as(f32, @floatFromInt(self.a)) / 255.0;
        return .{
            @as(f32, @floatFromInt(self.r)) / 255.0 * alpha,
            @as(f32, @floatFromInt(self.g)) / 255.0 * alpha,
            @as(f32, @floatFromInt(self.b)) / 255.0 * alpha,
            alpha,
        };
    }

    pub const white = Color{ .r = 255, .g = 255, .b = 255, .a = 255 };
    pub const black = Color{ .r = 0, .g = 0, .b = 0, .a = 255 };
    pub const transparent = Color{ .r = 0, .g = 0, .b = 0, .a = 0 };
};

// ─── Tests ───────────────────────────────────────────────────────────────────

test "Rect.containsPoint" {
    const r = Rect(f32){ .x = 10, .y = 20, .width = 100, .height = 50 };
    try std.testing.expect(r.containsPoint(50, 40));
    try std.testing.expect(!r.containsPoint(5, 40));
    try std.testing.expect(!r.containsPoint(50, 80));
}

test "Rect.intersection" {
    const a = Rect(f32){ .x = 0, .y = 0, .width = 100, .height = 100 };
    const b = Rect(f32){ .x = 50, .y = 50, .width = 100, .height = 100 };
    const inter = a.intersection(b).?;
    try std.testing.expectEqual(@as(f32, 50), inter.x);
    try std.testing.expectEqual(@as(f32, 50), inter.y);
    try std.testing.expectEqual(@as(f32, 50), inter.width);
    try std.testing.expectEqual(@as(f32, 50), inter.height);
}

test "Mat3x2.identity transform" {
    const p = Mat3x2.identity.transformPoint(.{ 3.0, 7.0 });
    try std.testing.expectApproxEqAbs(@as(f32, 3.0), p[0], 1e-6);
    try std.testing.expectApproxEqAbs(@as(f32, 7.0), p[1], 1e-6);
}

test "Mat3x2.translate" {
    const m = Mat3x2.translate(10, 20);
    const p = m.transformPoint(.{ 1.0, 2.0 });
    try std.testing.expectApproxEqAbs(@as(f32, 11.0), p[0], 1e-6);
    try std.testing.expectApproxEqAbs(@as(f32, 22.0), p[1], 1e-6);
}

test "Mat3x2.invert" {
    const m = Mat3x2.translate(5, 10).multiply(Mat3x2.scale(2, 3));
    const inv = m.invert().?;
    const p = m.transformPoint(.{ 1.0, 1.0 });
    const back = inv.transformPoint(p);
    try std.testing.expectApproxEqAbs(@as(f32, 1.0), back[0], 1e-5);
    try std.testing.expectApproxEqAbs(@as(f32, 1.0), back[1], 1e-5);
}

test "Color.hex" {
    const c = Color.hex(0xFF8800CC);
    try std.testing.expectEqual(@as(u8, 0xFF), c.r);
    try std.testing.expectEqual(@as(u8, 0x88), c.g);
    try std.testing.expectEqual(@as(u8, 0x00), c.b);
    try std.testing.expectEqual(@as(u8, 0xCC), c.a);
}

const std = @import("std");
