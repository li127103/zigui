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
    bindings: std.ArrayListUnmanaged(ShortcutBinding) = .{},

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
