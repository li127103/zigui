//! 输入事件队列

const pal = @import("../pal/pal.zig");

pub const EventQueue = pal.EventQueue;

pub const ShortcutBinding = struct {
    key: pal.KeyCode,
    modifiers: pal.Modifiers,
    action: []const u8,
    repeat: bool = false,
};

pub const ShortcutMap = struct {
    bindings: std.ArrayListUnmanaged(ShortcutBinding) = .{ .items = &.{}, .capacity = 0 },

    pub fn match(self: *ShortcutMap, key: pal.KeyCode, mods: pal.Modifiers) ?[]const u8 {
        for (self.bindings.items) |b| {
            if (b.key == key and b.modifiers.eql(mods)) return b.action;
        }
        return null;
    }

    pub fn deinit(self: *ShortcutMap, allocator: std.mem.Allocator) void {
        self.bindings.deinit(allocator);
    }
};

const std = @import("std");

// ── Tests ──────────────────────────────────────────────────────────────────

test "ShortcutMap matches key and modifiers exactly" {
    var map: ShortcutMap = .{};
    defer map.deinit(std.testing.allocator);

    try map.bindings.append(std.testing.allocator, .{
        .key = .s,
        .modifiers = .{ .super_key = true },
        .action = "save",
    });
    try map.bindings.append(std.testing.allocator, .{
        .key = .c,
        .modifiers = .{ .ctrl = true, .shift = true },
        .action = "copy_special",
    });

    try std.testing.expectEqualStrings("save", map.match(.s, .{ .super_key = true }).?);
    try std.testing.expectEqualStrings("copy_special", map.match(.c, .{ .ctrl = true, .shift = true }).?);

    // 修饰键不同 → 不匹配
    try std.testing.expect(map.match(.s, .{}) == null);
    try std.testing.expect(map.match(.s, .{ .super_key = true, .shift = true }) == null);
    // 键不同 → 不匹配
    try std.testing.expect(map.match(.a, .{ .super_key = true }) == null);
}
