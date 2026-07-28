//! 快捷键系统 - 全局/局部快捷键绑定 (对标 GtkShortcutController)
//!
//! 用法:
//!   app.shortcuts.add(.s, .{ .ctrl = true }, saveCallback, ctx);
//!   // 在 App 主循环中, key 事件先经过 shortcuts.handle(), 命中则拦截

const std = @import("std");
const pal = @import("pal/pal.zig");

const event_mod = pal.event;

/// 快捷键定义
pub const Shortcut = struct {
    key: event_mod.KeyCode,
    mods: event_mod.Modifiers,
    callback: *const fn (ctx: ?*anyopaque) void,
    ctx: ?*anyopaque = null,
    /// 是否启用 (可用于动态禁用)
    enabled: bool = true,
};

/// 快捷键控制器
pub const ShortcutController = struct {
    shortcuts: std.ArrayListUnmanaged(Shortcut) = .{ .items = &.{}, .capacity = 0 },
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) ShortcutController {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *ShortcutController) void {
        self.shortcuts.deinit(self.allocator);
    }

    /// 添加快捷键
    pub fn add(
        self: *ShortcutController,
        key: event_mod.KeyCode,
        mods: event_mod.Modifiers,
        callback: *const fn (ctx: ?*anyopaque) void,
        ctx: ?*anyopaque,
    ) !void {
        try self.shortcuts.append(self.allocator, .{
            .key = key,
            .mods = mods,
            .callback = callback,
            .ctx = ctx,
        });
    }

    /// 移除快捷键 (按回调指针匹配)
    pub fn remove(self: *ShortcutController, callback: *const fn (ctx: ?*anyopaque) void) void {
        var i: usize = 0;
        while (i < self.shortcuts.items.len) {
            if (self.shortcuts.items[i].callback == callback) {
                _ = self.shortcuts.swapRemove(i);
            } else {
                i += 1;
            }
        }
    }

    /// 清除所有快捷键
    pub fn clear(self: *ShortcutController) void {
        self.shortcuts.clearRetainingCapacity();
    }

    /// 处理按键事件, 返回 true 表示命中并执行了回调
    pub fn handle(self: *ShortcutController, key: event_mod.KeyCode, mods: event_mod.Modifiers) bool {
        for (self.shortcuts.items) |sc| {
            if (!sc.enabled) continue;
            if (sc.key == key and modsMatch(sc.mods, mods)) {
                sc.callback(sc.ctx);
                return true;
            }
        }
        return false;
    }

    /// 检查修饰键是否匹配 (只比较 ctrl/shift/alt/super, 忽略 caps_lock/num_lock)
    fn modsMatch(expected: event_mod.Modifiers, actual: event_mod.Modifiers) bool {
        return expected.ctrl == actual.ctrl and
            expected.shift == actual.shift and
            expected.alt == actual.alt and
            expected.super_key == actual.super_key;
    }
};
