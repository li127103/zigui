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
    touch: struct { id: u32, phase: TouchPhase, x: f32, y: f32 },

    // 文件拖放
    file_drop: struct { x: i32, y: i32 },
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
    _,
};
