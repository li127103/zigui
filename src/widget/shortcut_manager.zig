//! ShortcutManager — 统一快捷键管理（GTK4 GtkShortcutManager 风格）
//!
//! 与现有 shortcut.zig 互补：
//! - Shortcut / ShortcutController 属于 Widget 级别，挂接在单个控件
//! - ShortcutManager 属于 应用全局 级别，集中管理 Ctrl+S/Ctrl+C/Esc 等全局快捷键
//!
//! 核心 API:
//! ```
//! var mgr = try ShortcutManager.create(allocator);
//! try mgr.add(.{ .key = .s, .ctrl = true }, onSave);
//! // 应用层 key event dispatch 时调用：
//! const handled = mgr.handleKey(&event);
//! ```

const std = @import("std");
const pal = @import("../pal/pal.zig");

pub const ShortcutTrigger = struct {
    /// Key 名称，与 pal.Key 枚举对齐
    key: pal.Key,
    ctrl: bool = false,
    shift: bool = false,
    alt: bool = false,
    meta: bool = false, // macOS Command / Windows Super
};

pub const ShortcutActionResult = enum {
    handled,
    pass,
};

pub const ShortcutEntry = struct {
    trigger: ShortcutTrigger,
    /// 用户回调（返回 handled 表示拦截，pass 表示不拦截）
    on_activate: *const fn (trigger: *const ShortcutTrigger, user_data: ?*anyopaque) ShortcutActionResult,
    user_data: ?*anyopaque = null,
    /// 描述性名称（调试/文档显示）
    name: []const u8 = "",
};

pub const ShortcutManager = struct {
    allocator: std.mem.Allocator,
    entries: std.ArrayListUnmanaged(ShortcutEntry) = .empty,

    const Self = @This();

    pub fn create(allocator: std.mem.Allocator) !*ShortcutManager {
        const self = try allocator.create(ShortcutManager);
        self.* = .{ .allocator = allocator };
        return self;
    }

    pub fn destroy(self: *Self) void {
        self.entries.deinit(self.allocator);
        self.allocator.destroy(self);
    }

    // ── 添加/移除 ─────────────────────────────────────────────────────────────

    pub fn add(self: *Self, trigger: ShortcutTrigger, on_activate: *const fn (trigger: *const ShortcutTrigger, user_data: ?*anyopaque) ShortcutActionResult, user_data: ?*anyopaque, name: []const u8) !void {
        try self.entries.append(self.allocator, .{
            .trigger = trigger,
            .on_activate = on_activate,
            .user_data = user_data,
            .name = name,
        });
    }

    pub fn removeByKey(self: *Self, trigger: ShortcutTrigger) void {
        var i = self.entries.items.len;
        while (i > 0) {
            i -= 1;
            const e = &self.entries.items[i];
            if (triggersEqual(&e.trigger, &trigger)) {
                self.entries.orderedRemove(i);
                return;
            }
        }
    }

    pub fn clear(self: *Self) void {
        self.entries.deinit(self.allocator);
    }

    pub fn getEntryCount(self: *const Self) usize {
        return self.entries.items.len;
    }

    // ── Key Event 分发（在 Application / Window key dispatch 中调用）────────

    pub fn handleKey(self: *const Self, event: *const pal.Event) bool {
        const key_event = switch (event.*) {
            .key => |k| k,
            else => return false,
        };
        if (key_event.action != .press and key_event.action != .repeat) return false;
        const trigger: ShortcutTrigger = .{
            .key = key_event.key,
            .ctrl = key_event.modifiers.control,
            .shift = key_event.modifiers.shift,
            .alt = key_event.modifiers.alt,
            .meta = key_event.modifiers.meta,
        };
        for (self.entries.items) |entry| {
            if (triggersEqual(&entry.trigger, &trigger)) {
                if (entry.on_activate(&entry.trigger, entry.user_data) == .handled) {
                    return true;
                }
            }
        }
        return false;
    }

    /// 支持按 accel_string (如 "<ctrl>s" "<ctrl><shift>C" "Escape") 格式化添加
    pub fn addAccelString(self: *Self, accel: []const u8, on_activate: *const fn (trigger: *const ShortcutTrigger, user_data: ?*anyopaque) ShortcutActionResult, user_data: ?*anyopaque, name: []const u8) !void {
        const trigger = try parseAccelString(accel);
        try self.add(trigger, on_activate, user_data, name);
    }
};

fn triggersEqual(a: *const ShortcutTrigger, b: *const ShortcutTrigger) bool {
    return a.key == b.key and
        a.ctrl == b.ctrl and
        a.shift == b.shift and
        a.alt == b.alt and
        a.meta == b.meta;
}

/// 解析 GTK 风格 accel 字符串，如 "<ctrl>s"、"<ctrl><shift>C"、"<alt>F4"、"Escape"
/// 只支持有限的常见 key 名称；其余原样返回错误。
pub fn parseAccelString(accel: []const u8) !ShortcutTrigger {
    var i: usize = 0;
    var ctrl = false;
    var shift = false;
    var alt = false;
    var meta = false;
    while (i < accel.len and accel[i] == '<') {
        const end = std.mem.indexOfScalarPos(u8, accel, i, '>') orelse return error.InvalidAccel;
        const mod_name = accel[i + 1 .. end];
        if (std.ascii.eqlIgnoreCase(mod_name, "ctrl") or std.ascii.eqlIgnoreCase(mod_name, "control")) {
            ctrl = true;
        } else if (std.ascii.eqlIgnoreCase(mod_name, "shift")) {
            shift = true;
        } else if (std.ascii.eqlIgnoreCase(mod_name, "alt")) {
            alt = true;
        } else if (std.ascii.eqlIgnoreCase(mod_name, "meta") or std.ascii.eqlIgnoreCase(mod_name, "super") or std.ascii.eqlIgnoreCase(mod_name, "cmd") or std.ascii.eqlIgnoreCase(mod_name, "command")) {
            meta = true;
        } else if (std.ascii.eqlIgnoreCase(mod_name, "primary")) {
            // GTK <primary> : macOS 指 Command，其他平台指 Ctrl
            ctrl = true; // 简化为 Ctrl
        } else {
            return error.InvalidAccelModifier;
        }
        i = end + 1;
    }
    const key_part = accel[i..];
    const k = try keyNameToKey(key_part);
    return .{ .key = k, .ctrl = ctrl, .shift = shift, .alt = alt, .meta = meta };
}

fn keyNameToKey(name: []const u8) !pal.Key {
    if (name.len == 1) {
        const c = name[0];
        if (std.ascii.isAlpha(c)) {
            const lower = std.ascii.toLower(c);
            const offset: u8 = lower - 'a';
            const base: pal.Key = @enumFromInt(@intFromEnum(pal.Key.a));
            return @enumFromInt(@intFromEnum(base) + offset);
        }
        if (c >= '0' and c <= '9') {
            const offset: u8 = c - '0';
            const base: pal.Key = @enumFromInt(@intFromEnum(pal.Key._0));
            return @enumFromInt(@intFromEnum(base) + offset);
        }
    }
    if (std.ascii.eqlIgnoreCase(name, "escape") or std.ascii.eqlIgnoreCase(name, "esc")) return .escape;
    if (std.ascii.eqlIgnoreCase(name, "enter") or std.ascii.eqlIgnoreCase(name, "return")) return .enter;
    if (std.ascii.eqlIgnoreCase(name, "tab")) return .tab;
    if (std.ascii.eqlIgnoreCase(name, "space")) return .space;
    if (std.ascii.eqlIgnoreCase(name, "backspace")) return .backspace;
    if (std.ascii.eqlIgnoreCase(name, "delete") or std.ascii.eqlIgnoreCase(name, "del")) return .delete;
    if (std.ascii.eqlIgnoreCase(name, "insert")) return .insert;
    if (std.ascii.eqlIgnoreCase(name, "home")) return .home;
    if (std.ascii.eqlIgnoreCase(name, "end")) return .end;
    if (std.ascii.eqlIgnoreCase(name, "page_up")) return .page_up;
    if (std.ascii.eqlIgnoreCase(name, "page_down")) return .page_down;
    if (std.ascii.eqlIgnoreCase(name, "arrow_up") or std.ascii.eqlIgnoreCase(name, "up")) return .arrow_up;
    if (std.ascii.eqlIgnoreCase(name, "arrow_down") or std.ascii.eqlIgnoreCase(name, "down")) return .arrow_down;
    if (std.ascii.eqlIgnoreCase(name, "arrow_left") or std.ascii.eqlIgnoreCase(name, "left")) return .arrow_left;
    if (std.ascii.eqlIgnoreCase(name, "arrow_right") or std.ascii.eqlIgnoreCase(name, "right")) return .arrow_right;
    if (std.ascii.eqlIgnoreCase(name, "f1")) return .f1;
    if (std.ascii.eqlIgnoreCase(name, "f2")) return .f2;
    if (std.ascii.eqlIgnoreCase(name, "f3")) return .f3;
    if (std.ascii.eqlIgnoreCase(name, "f4")) return .f4;
    if (std.ascii.eqlIgnoreCase(name, "f5")) return .f5;
    if (std.ascii.eqlIgnoreCase(name, "f6")) return .f6;
    if (std.ascii.eqlIgnoreCase(name, "f7")) return .f7;
    if (std.ascii.eqlIgnoreCase(name, "f8")) return .f8;
    if (std.ascii.eqlIgnoreCase(name, "f9")) return .f9;
    if (std.ascii.eqlIgnoreCase(name, "f10")) return .f10;
    if (std.ascii.eqlIgnoreCase(name, "f11")) return .f11;
    if (std.ascii.eqlIgnoreCase(name, "f12")) return .f12;
    if (std.ascii.eqlIgnoreCase(name, "minus") or std.ascii.eqlIgnoreCase(name, "-")) return .minus;
    if (std.ascii.eqlIgnoreCase(name, "plus") or std.ascii.eqlIgnoreCase(name, "equal") or std.ascii.eqlIgnoreCase(name, "+")) return .equal;
    if (std.ascii.eqlIgnoreCase(name, "slash") or std.ascii.eqlIgnoreCase(name, "/")) return .slash;
    if (std.ascii.eqlIgnoreCase(name, "semicolon") or std.ascii.eqlIgnoreCase(name, ";")) return .semicolon;
    if (std.ascii.eqlIgnoreCase(name, "apostrophe") or std.ascii.eqlIgnoreCase(name, "'")) return .apostrophe;
    if (std.ascii.eqlIgnoreCase(name, "comma") or std.ascii.eqlIgnoreCase(name, ",")) return .comma;
    if (std.ascii.eqlIgnoreCase(name, "period") or std.ascii.eqlIgnoreCase(name, ".")) return .period;
    return error.UnknownKeyName;
}
