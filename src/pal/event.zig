//! 统一事件类型定义

/// 平台无关的统一事件
pub const Event = union(enum) {
    // 窗口事件
    resize: struct { width: u32, height: u32 },
    move: struct { x: i32, y: i32 },
    close_requested: struct { window_id: u32 },
    focus_change: struct { focused: bool },
    scale_change: struct { new_scale: f32 },
    minimize: void,
    maximize: struct { maximized: bool },

    // 鼠标事件
    mouse_move: struct { x: i32, y: i32 },
    mouse_button: struct { button: MouseButton, state: ButtonState, x: i32, y: i32 },
    scroll: struct { axis: ScrollAxis, delta: f32 },
    mouse_enter: void,
    mouse_leave: void,

    // 键盘事件
    key: struct { state: ButtonState, key: KeyCode, modifiers: Modifiers },
    text_input: struct { codepoint: u21 },

    // IME 事件
    ime_composition: struct { cursor_start: u32, cursor_end: u32 },
    ime_commit: void,
    ime_cancel: void,

    // 触摸事件
    touch: Touch,

    // 文件拖放
    file_drop: FileDrop,
};

/// 触摸点事件载荷
pub const Touch = struct {
    id: u32,
    phase: TouchPhase,
    x: f32,
    y: f32,
};

/// 文件拖放事件 (路径内联存储, 避免事件队列中的堆分配)
pub const FileDrop = struct {
    x: i32,
    y: i32,
    path: [max_path]u8,
    path_len: u32,

    pub const max_path = 1024;

    /// 文件路径 (UTF-8)
    pub fn pathSlice(self: *const FileDrop) []const u8 {
        return self.path[0..self.path_len];
    }
};

pub const MouseButton = enum { left, right, middle, extra1, extra2 };
pub const ButtonState = enum { pressed, released };
pub const ScrollAxis = enum { vertical, horizontal };
pub const TouchPhase = enum { began, moved, ended, cancelled };

pub const Modifiers = packed struct(u8) {
    shift: bool = false,
    ctrl: bool = false,
    alt: bool = false,
    super_key: bool = false,
    caps_lock: bool = false,
    num_lock: bool = false,
    _padding: u2 = 0,

    pub fn eql(self: Modifiers, other: Modifiers) bool {
        return @as(u8, @bitCast(self)) == @as(u8, @bitCast(other));
    }
};

pub const KeyCode = enum(u16) {
    // 字母
    a, b, c, d, e, f, g, h, i, j, k, l, m,
    n, o, p, q, r, s, t, u, v, w, x, y, z,
    // 数字
    @"0", @"1", @"2", @"3", @"4", @"5", @"6", @"7", @"8", @"9",
    // 功能键
    f1, f2, f3, f4, f5, f6, f7, f8, f9, f10, f11, f12,
    f13, f14, f15,
    // 控制键
    escape,
    tab,
    caps_lock,
    left_shift,
    right_shift,
    left_ctrl,
    right_ctrl,
    left_alt,
    right_alt,
    left_super,
    right_super,
    enter,
    backspace,
    delete,
    space,
    // 方向键
    up,
    down,
    left,
    right,
    home,
    end,
    page_up,
    page_down,
    insert,
    // 标点
    minus,
    equal,
    left_bracket,
    right_bracket,
    semicolon,
    apostrophe,
    grave,
    comma,
    period,
    slash,
    backslash,
    // 小键盘
    kp_0, kp_1, kp_2, kp_3, kp_4,
    kp_5, kp_6, kp_7, kp_8, kp_9,
    kp_add,
    kp_subtract,
    kp_multiply,
    kp_divide,
    kp_enter,
    kp_decimal,
    kp_equal,
    _,
};

const std = @import("std");

// ── Tests ──────────────────────────────────────────────────────────────────

test "FileDrop pathSlice returns valid path bytes" {
    var fd: FileDrop = .{ .x = 10, .y = 20, .path = undefined, .path_len = 0 };
    const p = "/tmp/你好.png";
    @memcpy(fd.path[0..p.len], p);
    fd.path_len = @intCast(p.len);

    try std.testing.expectEqualStrings(p, fd.pathSlice());
    try std.testing.expectEqual(@as(i32, 10), fd.x);
}

test "Modifiers eql compares all flags" {
    const a: Modifiers = .{ .shift = true, .ctrl = true };
    const b: Modifiers = .{ .shift = true, .ctrl = true };
    const c: Modifiers = .{ .shift = true };
    const d: Modifiers = .{ .shift = true, .ctrl = true, .super_key = true };

    try std.testing.expect(a.eql(b));
    try std.testing.expect(!a.eql(c));
    try std.testing.expect(!a.eql(d));
    try std.testing.expect((Modifiers{}).eql(.{}));
}
