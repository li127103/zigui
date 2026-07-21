//! 脏矩形区域跟踪
//! 收集需要重绘的屏幕区域, 用于:
//!  1. 帧跳过 (无脏区时不渲染)
//!  2. GPU 裁剪 (scissor 限定重绘像素)
//!  3. 控件树裁剪 (与脏区不相交的子树跳过绘制)

const std = @import("std");
const math = @import("../math.zig");

const Rect = math.Rect(f32);

/// 脏矩形数量上限, 超出后坍缩为单一外包矩形
pub const max_rects = 32;

pub const DirtyRegion = struct {
    rects: std.ArrayListUnmanaged(Rect) = .{ .items = &.{}, .capacity = 0 },
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) DirtyRegion {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *DirtyRegion) void {
        self.rects.deinit(self.allocator);
    }

    pub fn clear(self: *DirtyRegion) void {
        self.rects.clearRetainingCapacity();
    }

    pub fn isEmpty(self: *const DirtyRegion) bool {
        return self.rects.items.len == 0;
    }

    pub fn count(self: *const DirtyRegion) usize {
        return self.rects.items.len;
    }

    /// 添加脏矩形。与已有矩形相交则就地合并; 超出上限则坍缩为整体外包。
    /// 注意: 阴影/模糊等超出自身份围的绘制, 调用方应自行外扩 margin。
    pub fn add(self: *DirtyRegion, rect: Rect) !void {
        if (rect.width <= 0 or rect.height <= 0) return;

        for (self.rects.items) |*r| {
            if (r.intersects(rect)) {
                r.* = r.union_(rect);
                if (self.rects.items.len > max_rects) try self.collapse();
                return;
            }
        }

        try self.rects.append(self.allocator, rect);
        if (self.rects.items.len > max_rects) try self.collapse();
    }

    /// 坍缩为单一外包矩形
    pub fn collapse(self: *DirtyRegion) !void {
        const b = self.bounds() orelse return;
        self.rects.clearRetainingCapacity();
        try self.rects.append(self.allocator, b);
    }

    /// 整体外包矩形 (无脏区返回 null)
    pub fn bounds(self: *const DirtyRegion) ?Rect {
        if (self.rects.items.len == 0) return null;
        var b = self.rects.items[0];
        for (self.rects.items[1..]) |r| b = b.union_(r);
        return b;
    }

    /// 是否与任一脏矩形相交
    pub fn intersects(self: *const DirtyRegion, rect: Rect) bool {
        for (self.rects.items) |r| {
            if (r.intersects(rect)) return true;
        }
        return false;
    }
};

// ── Tests ──────────────────────────────────────────────────────────────────

test "dirty region add and bounds" {
    var d = DirtyRegion.init(std.testing.allocator);
    defer d.deinit();

    try std.testing.expect(d.isEmpty());
    try std.testing.expect(d.bounds() == null);

    try d.add(.{ .x = 0, .y = 0, .width = 10, .height = 10 });
    try d.add(.{ .x = 50, .y = 50, .width = 10, .height = 10 });
    try std.testing.expectEqual(@as(usize, 2), d.count());

    const b = d.bounds().?;
    try std.testing.expectEqual(@as(f32, 0), b.x);
    try std.testing.expectEqual(@as(f32, 0), b.y);
    try std.testing.expectEqual(@as(f32, 60), b.width);
    try std.testing.expectEqual(@as(f32, 60), b.height);
}

test "dirty region merges intersecting rects" {
    var d = DirtyRegion.init(std.testing.allocator);
    defer d.deinit();

    try d.add(.{ .x = 0, .y = 0, .width = 10, .height = 10 });
    try d.add(.{ .x = 5, .y = 5, .width = 10, .height = 10 });
    try std.testing.expectEqual(@as(usize, 1), d.count());

    const b = d.bounds().?;
    try std.testing.expectEqual(@as(f32, 15), b.width);
    try std.testing.expectEqual(@as(f32, 15), b.height);
}

test "dirty region ignores empty rects" {
    var d = DirtyRegion.init(std.testing.allocator);
    defer d.deinit();

    try d.add(.{ .x = 0, .y = 0, .width = 0, .height = 10 });
    try d.add(.{ .x = 0, .y = 0, .width = 10, .height = -1 });
    try std.testing.expect(d.isEmpty());
}

test "dirty region collapses past max_rects" {
    var d = DirtyRegion.init(std.testing.allocator);
    defer d.deinit();

    var i: u32 = 0;
    while (i < max_rects + 8) : (i += 1) {
        // 互不相交的矩形
        try d.add(.{
            .x = @floatFromInt(i * 100),
            .y = 0,
            .width = 10,
            .height = 10,
        });
    }
    // i=32 时 33 个矩形坍缩为 1; i=33..39 与外包不相交, 追加为 8 个
    try std.testing.expectEqual(@as(usize, 8), d.count());
    try std.testing.expect(d.count() < max_rects);

    const b = d.bounds().?;
    try std.testing.expectEqual(@as(f32, (max_rects + 7) * 100 + 10), b.width);
}

test "dirty region intersects" {
    var d = DirtyRegion.init(std.testing.allocator);
    defer d.deinit();

    try d.add(.{ .x = 100, .y = 100, .width = 50, .height = 50 });
    try std.testing.expect(d.intersects(.{ .x = 120, .y = 120, .width = 10, .height = 10 }));
    try std.testing.expect(!d.intersects(.{ .x = 0, .y = 0, .width = 50, .height = 50 }));
}

test "dirty region clear" {
    var d = DirtyRegion.init(std.testing.allocator);
    defer d.deinit();

    try d.add(.{ .x = 0, .y = 0, .width = 10, .height = 10 });
    d.clear();
    try std.testing.expect(d.isEmpty());
    try std.testing.expectEqual(@as(usize, 0), d.count());
}
