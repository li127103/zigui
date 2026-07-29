//! ShortcutController 快捷键控制器 (对标 GtkShortcutController + GtkShortcut)
//!
//! 简化版 GTK4 快捷键系统。提供两种快捷键绑定方式：
//!   1. 绑定到 Action (推荐): addShortcutAction(mods, key, "app.cut", .{})
//!   2. 绑定到原始回调:  addShortcutCallback(mods, key, &onCut, userdata)
//!
//! 使用方法（在 Widget 或窗口 key 事件里）:
//!   if (shortcut_ctrl.handleKeyEvent(event.key) == .handled) return .handled;

const std = @import("std");
const Allocator = std.mem.Allocator;
const ArrayListUnmanaged = std.ArrayListUnmanaged;

const pal_mod = @import("../pal/pal.zig");
const event_mod = @import("../pal/event.zig");
const action_mod = @import("../model/action.zig");
const ActionGroup = action_mod.ActionGroup;
const ActionValue = action_mod.ActionValue;

pub const KeyCode = event_mod.KeyCode;
pub const Modifiers = event_mod.Modifiers;

/// 快捷键项
pub const Shortcut = struct {
    /// 需要的修饰键 (按位与; 0 表示不需要修饰键)
    modifiers: Modifiers,
    /// 触发键
    key: KeyCode,
    /// 绑定方式
    binding: union(enum) {
        action: struct {
            name: []const u8,
            target: ActionValue = .none,
            group: ?ActionGroup = null, // null 则使用 ShortcutController 的默认 action_group
        },
        callback: struct {
            cb: *const fn (ud: ?*anyopaque) void,
            userdata: ?*anyopaque = null,
        },
    },
    /// 是否启用 (默认启用)
    enabled: bool = true,
};

pub const ShortcutController = struct {
    pub const Self = @This();

    allocator: Allocator,
    shortcuts: ArrayListUnmanaged(Shortcut) = .{ .items = &.{}, .capacity = 0 },
    /// 默认 action_group (当 shortcut.action.group == null 时使用)
    action_group: ?ActionGroup = null,

    pub fn create(allocator: Allocator) Self {
        return .{ .allocator = allocator };
    }

    pub fn createPtr(allocator: Allocator) *Self {
        const s = allocator.create(Self) catch @panic("OOM ShortcutController");
        s.* = create(allocator);
        return s;
    }

    pub fn destroy(self: *Self) void {
        self.shortcuts.deinit(self.allocator);
    }

    pub fn destroyPtr(self: *Self) void {
        const a = self.allocator;
        self.destroy();
        a.destroy(self);
    }

    pub fn setActionGroup(self: *Self, ag: ?ActionGroup) void {
        self.action_group = ag;
    }

    // ── 添加快捷键 API ──────────────────────────────────────────────────

    pub fn addShortcutAction(
        self: *Self,
        modifiers: Modifiers,
        key: KeyCode,
        action_name: []const u8,
        action_target: ActionValue,
    ) !void {
        try self.shortcuts.append(self.allocator, .{
            .modifiers = modifiers,
            .key = key,
            .binding = .{ .action = .{ .name = action_name, .target = action_target } },
        });
    }

    pub fn addShortcutCallback(
        self: *Self,
        modifiers: Modifiers,
        key: KeyCode,
        cb: *const fn (ud: ?*anyopaque) void,
        userdata: ?*anyopaque,
    ) !void {
        try self.shortcuts.append(self.allocator, .{
            .modifiers = modifiers,
            .key = key,
            .binding = .{ .callback = .{ .cb = cb, .userdata = userdata } },
        });
    }

    pub fn add(self: *Self, shortcut: Shortcut) !void {
        try self.shortcuts.append(self.allocator, shortcut);
    }

    pub fn clear(self: *Self) void {
        self.shortcuts.clearRetainingCapacity();
    }

    pub fn len(self: *const Self) usize {
        return self.shortcuts.items.len;
    }

    // ── 处理 key 事件 ───────────────────────────────────────────────────

    /// 返回 .handled 若有快捷键被匹配并执行
    pub fn handleKeyEvent(self: *Self, key_ev: anytype) enum { handled, ignored } {
        // 支持 pal.Event 的 .key 结构 (有 .state, .key, .modifiers)
        // 或直接传 event_mod.Event.key 结构
        const state = @field(key_ev, "state");
        if (state != .pressed) return .ignored; // 仅在按下时触发 (避免 hold 连触发)
        const mods: Modifiers = @field(key_ev, "modifiers");
        const key: KeyCode = @field(key_ev, "key");

        for (self.shortcuts.items) |sc| {
            if (!sc.enabled) continue;
            if (sc.key != key) continue;
            if (!modifiersMatch(sc.modifiers, mods)) continue;

            switch (sc.binding) {
                .action => |a| {
                    const ag = a.group orelse self.action_group orelse continue;
                    if (ag.activateAction(a.name, a.target)) {
                        return .handled;
                    }
                },
                .callback => |c| {
                    c.cb(c.userdata);
                    return .handled;
                },
            }
        }
        return .ignored;
    }
};

/// 判断修饰键是否匹配: required 是需要的修饰键集合, actual 是实际按下的
/// 这里采用「精确包含」: required 里标记为 true 的位, actual 必须全部为 true;
/// 其余的位 (如额外的 shift) 不会导致不匹配。用户若要求精确匹配可以传实际的全部修饰键。
fn modifiersMatch(required: Modifiers, actual: Modifiers) bool {
    // Modifiers 为 packed struct 或 flags; 这里做简单的按位比较。
    // 由于 zig 的 packed struct 比较方式特殊, 我们转成整数位再比较。
    const req_int: u8 = @bitCast(required);
    const act_int: u8 = @bitCast(actual);
    return (req_int & act_int) == req_int;
}
