//! ShortcutTrigger + ShortcutAction + Shortcut（GTK4 快捷键细粒度对象）
//!
//! - ShortcutTrigger：什么时候触发（按什么键）
//!     - Never            = 永不触发
//!     - Keyval           = 键值 + 修饰符掩码（按 ctrl+s、alt+x 等）
//!     - Mnemonic         = Alt + 字母（UI 中 _X 下划线样式）
//!     - Alternative(a,b) = a 或 b 任一匹配即触发
//!
//! - ShortcutAction：触发后做什么
//!     - None             = 无动作
//!     - Callback         = 调用函数
//!     - Signal           = 向 Widget 发信号（占位：存 target/signal_name）
//!     - Activate         = activate Widget
//!     - Named            = 通过 GAction/ActionGroup 调用具名动作
//!
//! - Shortcut：trigger + action 组合；可直接挂到 ShortcutController
//!

const std = @import("std");
const Allocator = std.mem.Allocator;
const pal_mod = @import("../pal/pal.zig");
const widget_mod = @import("widget.zig");
const button_mod = @import("button.zig"); // 识别 Button 类型做点击激活
const Widget = widget_mod.Widget;
const Button = button_mod.Button;

const KeyEvent = pal_mod.KeyEvent;

// ── SimpleAction / SimpleActionGroup（轻量 GAction 抽象，供 named action 使用） ──

pub const SimpleAction = struct {
    name: []const u8,
    callback: *const fn (user_data: ?*anyopaque, parameter: ?[]const u8) void,
    user_data: ?*anyopaque = null,
};

/// 简单动作组（GTK4: GSimpleActionGroup）：按 name 查动作并激活
pub const SimpleActionGroup = struct {
    allocator: Allocator,
    actions: std.StringHashMapUnmanaged(SimpleAction) = .empty,

    pub fn create(allocator: Allocator) *SimpleActionGroup {
        const self = allocator.create(SimpleActionGroup) catch unreachable;
        self.* = .{ .allocator = allocator };
        return self;
    }

    pub fn destroy(self: *SimpleActionGroup) void {
        var it = self.actions.valueIterator();
        while (it.next()) |act| {
            // name 字符串由调用方/构造方管理，此处不释放
            _ = act;
        }
        self.actions.deinit(self.allocator);
        self.allocator.destroy(self);
    }

    /// 注册一个 action；若同名已存在则覆盖
    pub fn addAction(self: *SimpleActionGroup, act: SimpleAction) !void {
        const gop = try self.actions.getOrPut(self.allocator, act.name);
        gop.value_ptr.* = act;
    }

    /// 按 name 激活 action；找到并调用返回 true，否则 false
    pub fn activateAction(self: *SimpleActionGroup, name: []const u8, parameter: ?[]const u8) bool {
        if (self.actions.get(name)) |act| {
            act.callback(act.user_data, parameter);
            return true;
        }
        return false;
    }
};

pub const ModifierMask = packed struct(u8) {
    shift: bool = false,
    ctrl: bool = false,
    alt: bool = false,
    super_: bool = false,
    meta: bool = false,
    hyper: bool = false,
    caps_lock: bool = false,
    num_lock: bool = false,

    pub fn any(m: @This()) bool {
        const b: u8 = @bitCast(m);
        return b != 0;
    }
    pub fn eql(a: @This(), b: @This()) bool {
        const x: u8 = @bitCast(a);
        const y: u8 = @bitCast(b);
        return x == y;
    }
    pub fn hash(m: @This()) u32 {
        const x: u8 = @bitCast(m);
        return @intCast(x);
    }
};

// ── ShortcutTrigger ───────────────────────────────────────────────────────

pub const ShortcutTriggerTag = enum(u3) { never, keyval, mnemonic, alternative };

pub const ShortcutTrigger = union(ShortcutTriggerTag) {
    never: void,
    keyval: struct { keyval: u32, mods: ModifierMask },
    mnemonic: struct { keyval: u32, mods: ModifierMask = .{ .alt = true } },
    alternative: struct { a: *ShortcutTrigger, b: *ShortcutTrigger, owned: bool = false },

    const SelfT = @This();

    pub fn newNever() SelfT {
        return .never;
    }

    pub fn newKeyval(key: u32, mods: ModifierMask) SelfT {
        return .{ .keyval = .{ .keyval = key, .mods = mods } };
    }

    pub fn newMnemonic(key: u32) SelfT {
        return .{ .mnemonic = .{ .keyval = key } };
    }

    pub fn newAlternative(a: *SelfT, b: *SelfT, owned: bool) SelfT {
        return .{ .alternative = .{ .a = a, .b = b, .owned = owned } };
    }

    pub fn destroy(self: *SelfT, allocator: Allocator) void {
        switch (self.*) {
            .never, .keyval, .mnemonic => {},
            .alternative => |alt| if (alt.owned) {
                alt.a.destroy(allocator);
                alt.b.destroy(allocator);
                allocator.destroy(alt.a);
                allocator.destroy(alt.b);
            },
        }
    }

    /// 判断 key 事件是否匹配
    pub fn triggered(self: *const SelfT, ke: ?*const KeyEvent) bool {
        switch (self.*) {
            .never => return false,
            .keyval => |kv| {
                const k = ke orelse return false;
                if (k.keycode_normalized != kv.keyval) return false;
                if (!modsMatch(k.modifiers, kv.mods)) return false;
                return true;
            },
            .mnemonic => |mn| {
                const k = ke orelse return false;
                if (k.keycode_normalized != mn.keyval) return false;
                if (!modsMatch(k.modifiers, mn.mods)) return false;
                return true;
            },
            .alternative => |alt| {
                return alt.a.triggered(ke) or alt.b.triggered(ke);
            },
        }
    }

    pub fn hash(self: *const SelfT) u32 {
        var h: u32 = 17;
        switch (self.*) {
            .never => h ^= 0xB0BACAFE,
            .keyval => |kv| {
                h = h * 31 + kv.keyval;
                h ^= kv.mods.hash();
            },
            .mnemonic => |mn| {
                h = h * 31 + mn.keyval * 7;
                h ^= mn.mods.hash();
            },
            .alternative => |alt| {
                h = alt.a.hash() * 13 + alt.b.hash() * 29;
            },
        }
        return h;
    }

    pub fn equal(a: *const SelfT, b: *const SelfT) bool {
        if (@as(ShortcutTriggerTag, a.*) != @as(ShortcutTriggerTag, b.*)) return false;
        switch (a.*) {
            .never => return true,
            .keyval => |akv| switch (b.*) {
                .keyval => |bkv| return akv.keyval == bkv.keyval and akv.mods.eql(bkv.mods),
                else => return false,
            },
            .mnemonic => |amn| switch (b.*) {
                .mnemonic => |bmn| return amn.keyval == bmn.keyval and amn.mods.eql(bmn.mods),
                else => return false,
            },
            .alternative => |aa| switch (b.*) {
                .alternative => |ab| return (aa.a.equal(ab.a) and aa.b.equal(ab.b)) or (aa.a.equal(ab.b) and aa.b.equal(ab.a)),
                else => return false,
            },
        }
    }

    pub fn toString(self: *const SelfT, allocator: Allocator) ![]const u8 {
        switch (self.*) {
            .never => return allocator.dupe(u8, "never"),
            .keyval => |kv| {
                var list = std.ArrayList(u8).init(allocator);
                defer list.deinit();
                try appendMods(&list, kv.mods);
                try list.writer().print("0x{X}", .{kv.keyval});
                return list.toOwnedSlice();
            },
            .mnemonic => |mn| {
                var list = std.ArrayList(u8).init(allocator);
                defer list.deinit();
                try appendMods(&list, mn.mods);
                try list.writer().print("_0x{X}", .{mn.keyval});
                return list.toOwnedSlice();
            },
            .alternative => |alt| {
                var list = std.ArrayList(u8).init(allocator);
                defer list.deinit();
                const sa = try alt.a.toString(allocator);
                defer allocator.free(sa);
                const sb = try alt.b.toString(allocator);
                defer allocator.free(sb);
                try list.writer().print("({s}|{s})", .{ sa, sb });
                return list.toOwnedSlice();
            },
        }
    }

    /// 解析 accel 字符串如 "<ctrl>s" / "<alt><shift>F1" / "<ctrl><shift>0x4B"
    pub fn parse(str: []const u8) ?SelfT {
        if (std.mem.eql(u8, str, "never")) return SelfT.newNever();
        var mods: ModifierMask = .{};
        var pos: usize = 0;
        while (pos < str.len and str[pos] == '<') {
            const close = std.mem.indexOfScalarPos(u8, str, pos, '>') orelse return null;
            const name = std.mem.trim(u8, str[pos + 1 .. close], " \t");
            if (std.ascii.eqlIgnoreCase(name, "ctrl") or std.ascii.eqlIgnoreCase(name, "control")) mods.ctrl = true else if (std.ascii.eqlIgnoreCase(name, "shift")) mods.shift = true else if (std.ascii.eqlIgnoreCase(name, "alt")) mods.alt = true else if (std.ascii.eqlIgnoreCase(name, "super") or std.ascii.eqlIgnoreCase(name, "win")) mods.super_ = true else if (std.ascii.eqlIgnoreCase(name, "meta")) mods.meta = true else if (std.ascii.eqlIgnoreCase(name, "hyper")) mods.hyper = true;
            pos = close + 1;
        }
        if (pos >= str.len) return null;
        const rest = str[pos..];
        if (rest.len >= 2 and rest[0] == '_') {
            const k: u32 = @intCast(std.ascii.toUpper(rest[1]));
            return SelfT{ .mnemonic = .{ .keyval = k, .mods = mods } };
        }
        const keyval: u32 = if (std.mem.startsWith(u8, rest, "0x"))
            std.fmt.parseInt(u32, rest[2..], 16) catch return null
        else if (rest.len == 1)
            @intCast(std.ascii.toUpper(rest[0]))
        else if (std.mem.eql(u8, rest, "F1")) 0xFFBE else if (std.mem.eql(u8, rest, "F2")) 0xFFBF else if (std.mem.eql(u8, rest, "F3")) 0xFFC0 else if (std.mem.eql(u8, rest, "F4")) 0xFFC1 else if (std.mem.eql(u8, rest, "F5")) 0xFFC2 else if (std.mem.eql(u8, rest, "F6")) 0xFFC3 else if (std.mem.eql(u8, rest, "F7")) 0xFFC4 else if (std.mem.eql(u8, rest, "F8")) 0xFFC5 else if (std.mem.eql(u8, rest, "F9")) 0xFFC6 else if (std.mem.eql(u8, rest, "F10")) 0xFFC7 else if (std.mem.eql(u8, rest, "F11")) 0xFFC8 else if (std.mem.eql(u8, rest, "F12")) 0xFFC9 else if (std.mem.eql(u8, rest, "Escape") or std.mem.eql(u8, rest, "Esc")) 0xFF1B else if (std.mem.eql(u8, rest, "Return") or std.mem.eql(u8, rest, "Enter")) 0xFF0D else if (std.mem.eql(u8, rest, "Space")) 0x20 else if (std.mem.eql(u8, rest, "Tab")) 0xFF09 else return null;
        return SelfT.newKeyval(keyval, mods);
    }
};

// ── ShortcutAction ────────────────────────────────────────────────────────

pub const ShortcutActionTag = enum(u3) { none, callback, signal, activate, named };

pub const ShortcutCallbackFn = *const fn (user_data: ?*anyopaque, widget: ?*Widget, args: []const u8) bool;

pub const ShortcutAction = union(ShortcutActionTag) {
    none: void,
    callback: struct { cb: ShortcutCallbackFn, user_data: ?*anyopaque, owned: bool = false },
    signal: struct { signal_name: []const u8, detail: ?[]const u8 },
    activate: void,
    named: struct { action_name: []const u8, args: ?[]const u8 },

    const SelfA = @This();

    pub fn newNone() SelfA {
        return .none;
    }
    pub fn newCallback(cb: ShortcutCallbackFn, ud: ?*anyopaque) SelfA {
        return .{ .callback = .{ .cb = cb, .user_data = ud } };
    }
    pub fn newSignal(signal: []const u8, detail: ?[]const u8) SelfA {
        return .{ .signal = .{ .signal_name = signal, .detail = detail } };
    }
    pub fn newActivate() SelfA {
        return .activate;
    }
    pub fn newNamed(name: []const u8, args: ?[]const u8) SelfA {
        return .{ .named = .{ .action_name = name, .args = args } };
    }

    /// 真实执行动作。returns 成功与否。
    /// - args_v: 可选上下文指针；对于 `.named` 分支，允许传 `*SimpleActionGroup` 以查 action
    pub fn activate_(self: *const SelfA, widget: ?*Widget, args_v: ?*anyopaque) bool {
        switch (self.*) {
            .none => return false,
            .callback => |c| return c.cb(c.user_data, widget, &.{}),
            .signal => |s| {
                // GTK4: GtkSignalAction - 向 Widget 发送 signal_name 信号
                // 本框架无信号系统，用"常用信号名→动作"降级匹配
                const w = widget orelse {
                    // 无 widget: 标记已处理但无副作用
                    return true;
                };
                if (std.ascii.eqlIgnoreCase(s.signal_name, "clicked") or
                    std.ascii.eqlIgnoreCase(s.signal_name, "activate"))
                {
                    return simulateWidgetActivate(w);
                }
                if (std.ascii.eqlIgnoreCase(s.signal_name, "grab-focus") or
                    std.ascii.eqlIgnoreCase(s.signal_name, "focus"))
                {
                    w.state.focused = true;
                    w.markDirty();
                    return true;
                }
                // 其他信号：至少 markDirty 表示已处理
                w.markDirty();
                return true;
            },
            .activate => {
                // GTK4: GtkActivateAction - activate widget（按钮点击/控件聚焦等）
                const w = widget orelse return false;
                return simulateWidgetActivate(w);
            },
            .named => |n| {
                // GTK4: GtkNamedAction - 查 GActionMap 调用具名动作
                // 约定 args_v = *SimpleActionGroup（调用方把动作组传进来）
                const group: *SimpleActionGroup = if (args_v) |p|
                    @ptrCast(@alignCast(p))
                else
                    return false;
                return group.activateAction(n.action_name, n.args);
            },
        }
    }

    // ── 工具：通用 widget activate 模拟（按钮点击 / 其他 widget 聚焦 + markDirty） ──
    fn simulateWidgetActivate(w: *Widget) bool {
        // 识别 Button（通过 vtable.type_name，无需 import 互依赖）
        if (std.mem.eql(u8, w.vtable.type_name, "button")) {
            // Button 结构: base = Widget 第一个字段，on_click 在 Button 对象内部
            // 通过 @fieldParentPtr 还原 Button*
            const btn: *Button = @fieldParentPtr("base", w);
            if (btn.on_click) |cb| {
                cb(btn);
                return true;
            }
        }
        // 通用兜底：聚焦 + 标记脏（表示"激活了"）
        w.state.focused = true;
        w.markDirty();
        return true;
    }
};

// ── Shortcut（组合） ──────────────────────────────────────────────────────

pub const Shortcut = struct {
    trigger: ShortcutTrigger,
    action: ShortcutAction,

    pub fn create(trig: ShortcutTrigger, act: ShortcutAction) Shortcut {
        return .{ .trigger = trig, .action = act };
    }

    pub fn destroy(self: *Shortcut, allocator: Allocator) void {
        self.trigger.destroy(allocator);
    }
};

// ── 工具函数（内部） ──────────────────────────────────────────────────────

fn modsMatch(widget_mods: ModifierMask, required: ModifierMask) bool {
    const w: u8 = @bitCast(widget_mods);
    const r: u8 = @bitCast(required);
    return (w & r) == r;
}

fn appendMods(list: *std.ArrayList(u8), mods: ModifierMask) !void {
    if (mods.ctrl) try list.appendSlice("<ctrl>");
    if (mods.shift) try list.appendSlice("<shift>");
    if (mods.alt) try list.appendSlice("<alt>");
    if (mods.super_) try list.appendSlice("<super>");
    if (mods.meta) try list.appendSlice("<meta>");
    if (mods.hyper) try list.appendSlice("<hyper>");
}
