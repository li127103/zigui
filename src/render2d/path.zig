//! 路径构建

const math = @import("../math.zig");

pub const PathCommand = union(enum) {
    move_to: [2]f32,
    line_to: [2]f32,
    quad_to: struct { control: [2]f32, end: [2]f32 },
    cubic_to: struct { c1: [2]f32, c2: [2]f32, end: [2]f32 },
    close: void,
};

pub const Path = struct {
    commands: std.ArrayListUnmanaged(PathCommand) = .{},
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) Path {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *Path) void {
        self.commands.deinit(self.allocator);
    }

    pub fn reset(self: *Path) void {
        self.commands.clearRetainingCapacity();
    }

    pub fn moveTo(self: *Path, x: f32, y: f32) !void {
        try self.commands.append(self.allocator, .{ .move_to = .{ x, y } });
    }

    pub fn lineTo(self: *Path, x: f32, y: f32) !void {
        try self.commands.append(self.allocator, .{ .line_to = .{ x, y } });
    }

    pub fn quadTo(self: *Path, cx: f32, cy: f32, x: f32, y: f32) !void {
        try self.commands.append(self.allocator, .{ .quad_to = .{ .control = .{ cx, cy }, .end = .{ x, y } } });
    }

    pub fn cubicTo(self: *Path, c1x: f32, c1y: f32, c2x: f32, c2y: f32, x: f32, y: f32) !void {
        try self.commands.append(self.allocator, .{ .cubic_to = .{ .c1 = .{ c1x, c1y }, .c2 = .{ c2x, c2y }, .end = .{ x, y } } });
    }

    pub fn close(self: *Path) !void {
        try self.commands.append(self.allocator, .{ .close = {} });
    }

    pub fn addRect(self: *Path, rect: math.Rect(f32)) !void {
        try self.moveTo(rect.x, rect.y);
        try self.lineTo(rect.x + rect.width, rect.y);
        try self.lineTo(rect.x + rect.width, rect.y + rect.height);
        try self.lineTo(rect.x, rect.y + rect.height);
        try self.close();
    }

    pub fn addRoundedRect(self: *Path, rect: math.Rect(f32), radius: f32) !void {
        try self.addRoundedRectEx(rect, .{ radius, radius, radius, radius });
    }

    /// 四角独立圆角 (tl, tr, br, bl)
    pub fn addRoundedRectEx(self: *Path, rect: math.Rect(f32), radii: [4]f32) !void {
        const x = rect.x;
        const y = rect.y;
        const w = rect.width;
        const h = rect.height;
        const tl = @min(radii[0], @min(w, h) / 2);
        const tr = @min(radii[1], @min(w, h) / 2);
        const br = @min(radii[2], @min(w, h) / 2);
        const bl = @min(radii[3], @min(w, h) / 2);

        try self.moveTo(x + tl, y);
        try self.lineTo(x + w - tr, y);
        if (tr > 0) try self.quadTo(x + w, y, x + w, y + tr);
        try self.lineTo(x + w, y + h - br);
        if (br > 0) try self.quadTo(x + w, y + h, x + w - br, y + h);
        try self.lineTo(x + bl, y + h);
        if (bl > 0) try self.quadTo(x, y + h, x, y + h - bl);
        try self.lineTo(x, y + tl);
        if (tl > 0) try self.quadTo(x, y, x + tl, y);
        try self.close();
    }

    pub fn addCircle(self: *Path, cx: f32, cy: f32, r: f32) !void {
        try self.addEllipse(cx, cy, r, r);
    }

    pub fn addEllipse(self: *Path, cx: f32, cy: f32, rx: f32, ry: f32) !void {
        // 用 4 段三次贝塞尔逼近椭圆 (kappa ≈ 0.5522847498)
        const k: f32 = 0.5522847498;
        const kx = rx * k;
        const ky = ry * k;

        try self.moveTo(cx + rx, cy);
        try self.cubicTo(cx + rx, cy + ky, cx + kx, cy + ry, cx, cy + ry);
        try self.cubicTo(cx - kx, cy + ry, cx - rx, cy + ky, cx - rx, cy);
        try self.cubicTo(cx - rx, cy - ky, cx - kx, cy - ry, cx, cy - ry);
        try self.cubicTo(cx + kx, cy - ry, cx + rx, cy - ky, cx + rx, cy);
        try self.close();
    }
};

const std = @import("std");

test "Path.addRect" {
    var p = Path.init(std.testing.allocator);
    defer p.deinit();
    try p.addRect(.{ .x = 0, .y = 0, .width = 100, .height = 50 });
    try std.testing.expectEqual(@as(usize, 5), p.commands.items.len);
}

test "Path.addCircle" {
    var p = Path.init(std.testing.allocator);
    defer p.deinit();
    try p.addCircle(50, 50, 25);
    // moveTo + 4 cubicTo + close = 6
    try std.testing.expectEqual(@as(usize, 6), p.commands.items.len);
}
