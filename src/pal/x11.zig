//! X11 窗口后端 (xcb + xkbcommon)
//! 使用 xcb 而非 Xlib: 线程安全、协议级 API、无全局锁

const std = @import("std");
const pal = @import("pal.zig");
const event_mod = @import("event.zig");
const window_mod = @import("window.zig");

const xcb = @cImport({
    @cInclude("xcb/xcb.h");
});

const xkb = @cImport({
    @cInclude("xkbcommon/xkbcommon.h");
});

pub const X11Backend = struct {
    allocator: std.mem.Allocator,
    conn: *xcb.xcb_connection_t,
    screen: *xcb.xcb_screen_t,
    window_id: u32 = 0,
    wm_delete_window: u32 = 0,
    wm_protocols: u32 = 0,
    // xkbcommon
    xkb_ctx: *xkb.xkb_context,
    xkb_keymap: ?*xkb.xkb_keymap = null,
    xkb_state: ?*xkb.xkb_state = null,
    // 鼠标状态
    mouse_x: i32 = 0,
    mouse_y: i32 = 0,

    pub fn init(allocator: std.mem.Allocator) !X11Backend {
        const conn = xcb.xcb_connect(null, null) orelse return error.ConnectionFailed;
        if (xcb.xcb_connection_has_error(conn) != 0) return error.ConnectionFailed;

        const setup = xcb.xcb_get_setup(conn) orelse return error.ConnectionFailed;
        const screen = getFirstScreen(setup) orelse return error.NoScreen;

        // 初始化 xkbcommon
        const xkb_ctx = xkb.xkb_context_new(xkb.XKB_CONTEXT_NO_FLAGS) orelse return error.XkbInitFailed;

        // 创建基础 keymap (使用 evdev 规则, 适用于大多数 Linux 桌面)
        const rules = try allocator.dupeZ(u8, "evdev");
        defer allocator.free(rules);
        const model = try allocator.dupeZ(u8, "pc105");
        defer allocator.free(model);
        const layout = try allocator.dupeZ(u8, "us");
        defer allocator.free(layout);

        const rmlvo = xkb.xkb_rule_names{
            .rules = rules.ptr,
            .model = model.ptr,
            .layout = layout.ptr,
            .variant = null,
            .options = null,
        };
        const xkb_keymap = xkb.xkb_keymap_new_from_names(xkb_ctx, &rmlvo, xkb.XKB_KEYMAP_COMPILE_NO_FLAGS);
        const xkb_state = if (xkb_keymap) |km| xkb.xkb_state_new(km) else null;

        return .{
            .allocator = allocator,
            .conn = conn,
            .screen = screen,
            .xkb_ctx = xkb_ctx,
            .xkb_keymap = xkb_keymap,
            .xkb_state = xkb_state,
        };
    }

    pub fn deinit(self: *X11Backend) void {
        if (self.xkb_state) |s| xkb.xkb_state_unref(s);
        if (self.xkb_keymap) |km| xkb.xkb_keymap_unref(km);
        xkb.xkb_context_unref(self.xkb_ctx);
        if (self.window_id != 0) {
            _ = xcb.xcb_destroy_window(self.conn, self.window_id);
        }
        xcb.xcb_disconnect(self.conn);
    }

    pub fn createWindow(self: *X11Backend, desc: window_mod.WindowDesc) !window_mod.Window {
        const wid = xcb.xcb_generate_id(self.conn);
        const mask = xcb.XCB_CW_EVENT_MASK | xcb.XCB_CW_BACK_PIXEL;
        const values = [_]u32{
            xcb.XCB_EVENT_MASK_EXPOSURE |
                xcb.XCB_EVENT_MASK_STRUCTURE_NOTIFY |
                xcb.XCB_EVENT_MASK_KEY_PRESS |
                xcb.XCB_EVENT_MASK_KEY_RELEASE |
                xcb.XCB_EVENT_MASK_BUTTON_PRESS |
                xcb.XCB_EVENT_MASK_BUTTON_RELEASE |
                xcb.XCB_EVENT_MASK_POINTER_MOTION |
                xcb.XCB_EVENT_MASK_ENTER_WINDOW |
                xcb.XCB_EVENT_MASK_LEAVE_WINDOW |
                xcb.XCB_EVENT_MASK_FOCUS_CHANGE,
            self.screen.white_pixel,
        };

        _ = xcb.xcb_create_window(
            self.conn,
            xcb.XCB_COPY_FROM_PARENT,
            wid,
            self.screen.root,
            0,
            0,
            @intCast(desc.width),
            @intCast(desc.height),
            0,
            xcb.XCB_WINDOW_CLASS_INPUT_OUTPUT,
            self.screen.root_visual,
            mask,
            &values,
        );

        // 设置 WM_PROTOCOLS (WM_DELETE_WINDOW)
        self.wm_protocols = internAtom(self.conn, "WM_PROTOCOLS");
        self.wm_delete_window = internAtom(self.conn, "WM_DELETE_WINDOW");
        if (self.wm_protocols != 0 and self.wm_delete_window != 0) {
            _ = xcb.xcb_change_property(
                self.conn,
                xcb.XCB_PROP_MODE_REPLACE,
                wid,
                self.wm_protocols,
                4, // XCB_ATOM_ATOM
                32,
                1,
                &self.wm_delete_window,
            );
        }

        // 设置窗口标题
        setTitle(self.conn, wid, desc.title);

        // 设置最小尺寸提示
        if (desc.min_width) |mw| {
            _ = mw;
            // TODO: 设置 WM_SIZE_HINTS
        }

        if (desc.visible) {
            _ = xcb.xcb_map_window(self.conn, wid);
        }
        _ = xcb.xcb_flush(self.conn);

        self.window_id = wid;

        return .{
            .handle = .{ .x11_window = wid },
            .size = .{ .width = desc.width, .height = desc.height },
            .scale_factor = 1.0,
        };
    }

    pub fn pollEvents(self: *X11Backend, queue: *pal.EventQueue, allocator: std.mem.Allocator) !void {
        _ = xcb.xcb_flush(self.conn);
        while (xcb.xcb_poll_for_event(self.conn)) |ev| {
            defer std.c.free(ev);
            if (try self.translateEvent(ev)) |translated| {
                try queue.push(allocator, translated);
            }
        }
    }

    /// 获取 X11 display 指针 (用于 Vulkan surface 创建)
    pub fn getDisplay(self: *X11Backend) *anyopaque {
        // xcb 连接底层使用 Xlib display, 通过 xcb_get_xlib_display 获取
        // 但纯 xcb 没有此函数, 我们返回 connection 指针
        // Vulkan 的 VK_KHR_xcb_surface 使用 xcb_connection_t
        return @ptrCast(self.conn);
    }

    /// 获取 xcb connection (用于 Vulkan VK_KHR_xcb_surface)
    pub fn getConnection(self: *X11Backend) *xcb.xcb_connection_t {
        return self.conn;
    }

    /// 获取 X11 window ID
    pub fn getWindowId(self: *X11Backend) u32 {
        return self.window_id;
    }

    /// 设置窗口标题
    fn setTitle(conn: *xcb.xcb_connection_t, wid: u32, title: []const u8) void {
        _ = xcb.xcb_change_property(
            conn,
            xcb.XCB_PROP_MODE_REPLACE,
            wid,
            xcb.XCB_ATOM_WM_NAME,
            xcb.XCB_ATOM_STRING,
            8,
            @intCast(title.len),
            title.ptr,
        );
        // 同时设置 _NET_WM_NAME (UTF-8)
        const net_wm_name = internAtom(conn, "_NET_WM_NAME");
        const utf8_string = internAtom(conn, "UTF8_STRING");
        if (net_wm_name != 0 and utf8_string != 0) {
            _ = xcb.xcb_change_property(
                conn,
                xcb.XCB_PROP_MODE_REPLACE,
                wid,
                net_wm_name,
                utf8_string,
                8,
                @intCast(title.len),
                title.ptr,
            );
        }
    }

    /// 转换 X11 事件为统一事件
    fn translateEvent(self: *X11Backend, ev: [*c]xcb.xcb_generic_event_t) !?event_mod.Event {
        const response_type = ev.*.response_type & 0x7f;
        return switch (response_type) {
            xcb.XCB_KEY_PRESS, xcb.XCB_KEY_RELEASE => self.translateKeyEvent(ev),
            xcb.XCB_BUTTON_PRESS, xcb.XCB_BUTTON_RELEASE => self.translateButtonEvent(ev),
            xcb.XCB_MOTION_NOTIFY => self.translateMotionEvent(ev),
            xcb.XCB_CONFIGURE_NOTIFY => self.translateConfigureEvent(ev),
            xcb.XCB_CLIENT_MESSAGE => self.translateClientMessage(ev),
            xcb.XCB_FOCUS_IN => .{ .focus_change = .{ .focused = true } },
            xcb.XCB_FOCUS_OUT => .{ .focus_change = .{ .focused = false } },
            xcb.XCB_ENTER_NOTIFY => .mouse_enter,
            xcb.XCB_LEAVE_NOTIFY => .mouse_leave,
            xcb.XCB_DESTROY_NOTIFY => .{ .close_requested = .{ .window_id = self.window_id } },
            else => null,
        };
    }

    fn translateKeyEvent(self: *X11Backend, ev: [*c]xcb.xcb_generic_event_t) ?event_mod.Event {
        const key_ev = @as([*c]xcb.xcb_key_press_event_t, @ptrCast(ev));
        const pressed = (ev.*.response_type & 0x7f) == xcb.XCB_KEY_PRESS;
        // X11 keycode 比 evdev keycode 大 8
        const keycode: u32 = key_ev.*.detail;

        const modifiers = self.getModifiers(key_ev.*.state);
        const key_code = xkbKeycodeToKeyCode(keycode);

        // 文本输入 (仅按下时, 使用 xkbcommon 获取 Unicode)
        if (pressed) {
            if (self.xkb_state) |state| {
                const sym = xkb.xkb_state_key_get_one_sym(state, keycode);
                const cp = xkb.xkb_keysym_to_utf32(sym);
                if (cp >= 32 and cp != 127) {
                    // 可打印字符 → text_input 事件
                    return .{ .text_input = .{ .codepoint = @intCast(cp) } };
                }
            }
        }

        return .{ .key = .{
            .state = if (pressed) .pressed else .released,
            .key = key_code,
            .modifiers = modifiers,
        } };
    }

    fn translateButtonEvent(self: *X11Backend, ev: [*c]xcb.xcb_generic_event_t) ?event_mod.Event {
        const btn_ev = @as([*c]xcb.xcb_button_press_event_t, @ptrCast(ev));
        const pressed = (ev.*.response_type & 0x7f) == xcb.XCB_BUTTON_PRESS;
        const button = btn_ev.*.detail;
        const x: i32 = @intCast(btn_ev.*.event_x);
        const y: i32 = @intCast(btn_ev.*.event_y);
        self.mouse_x = x;
        self.mouse_y = y;

        // 滚轮: button 4=上, 5=下, 6=左, 7=右
        if (button >= 4 and button <= 7) {
            if (!pressed) return null; // 滚轮只处理 press
            const delta: f32 = switch (button) {
                4 => 1.0,
                5 => -1.0,
                else => 0.0,
            };
            const axis: event_mod.ScrollAxis = if (button <= 5) .vertical else .horizontal;
            const h_delta: f32 = switch (button) {
                6 => -1.0,
                7 => 1.0,
                else => 0.0,
            };
            return .{ .scroll = .{
                .axis = axis,
                .delta = if (axis == .vertical) delta else h_delta,
            } };
        }

        const mouse_button: event_mod.MouseButton = switch (button) {
            1 => .left,
            2 => .middle,
            3 => .right,
            8 => .extra1,
            9 => .extra2,
            else => .left,
        };

        return .{ .mouse_button = .{
            .button = mouse_button,
            .state = if (pressed) .pressed else .released,
            .x = x,
            .y = y,
        } };
    }

    fn translateMotionEvent(self: *X11Backend, ev: [*c]xcb.xcb_generic_event_t) ?event_mod.Event {
        const motion_ev = @as([*c]xcb.xcb_motion_notify_event_t, @ptrCast(ev));
        const x: i32 = @intCast(motion_ev.*.event_x);
        const y: i32 = @intCast(motion_ev.*.event_y);
        self.mouse_x = x;
        self.mouse_y = y;
        return .{ .mouse_move = .{ .x = x, .y = y } };
    }

    fn translateConfigureEvent(self: *X11Backend, ev: [*c]xcb.xcb_generic_event_t) ?event_mod.Event {
        _ = self;
        const cfg_ev = @as([*c]xcb.xcb_configure_notify_event_t, @ptrCast(ev));
        return .{ .resize = .{
            .width = @intCast(cfg_ev.*.width),
            .height = @intCast(cfg_ev.*.height),
        } };
    }

    fn translateClientMessage(self: *X11Backend, ev: [*c]xcb.xcb_generic_event_t) ?event_mod.Event {
        const client_ev = @as([*c]xcb.xcb_client_message_event_t, @ptrCast(ev));
        if (client_ev.*.type == self.wm_protocols) {
            const data32: [*c]const u32 = @ptrCast(&client_ev.*.data);
            if (data32[0] == self.wm_delete_window) {
                return .{ .close_requested = .{ .window_id = self.window_id } };
            }
        }
        return null;
    }

    fn getModifiers(self: *X11Backend, state: u16) event_mod.Modifiers {
        _ = self;
        return .{
            .shift = (state & xcb.XCB_MOD_MASK_SHIFT) != 0,
            .ctrl = (state & xcb.XCB_MOD_MASK_CONTROL) != 0,
            .alt = (state & xcb.XCB_MOD_MASK_1) != 0,
            .super_key = (state & xcb.XCB_MOD_MASK_4) != 0,
            .caps_lock = (state & xcb.XCB_MOD_MASK_LOCK) != 0,
        };
    }

    /// X11 keycode (evdev + 8) → zigui KeyCode
    fn xkbKeycodeToKeyCode(keycode: u32) event_mod.KeyCode {
        // evdev keycode = X11 keycode - 8
        const evdev = keycode -| 8;
        return switch (evdev) {
            // 字母 (evdev codes)
            30 => .a,
            48 => .b,
            46 => .c,
            32 => .d,
            18 => .e,
            33 => .f,
            34 => .g,
            35 => .h,
            23 => .i,
            36 => .j,
            37 => .k,
            38 => .l,
            50 => .m,
            49 => .n,
            24 => .o,
            25 => .p,
            16 => .q,
            19 => .r,
            31 => .s,
            20 => .t,
            22 => .u,
            47 => .v,
            17 => .w,
            45 => .x,
            21 => .y,
            44 => .z,
            // 数字
            11 => .@"0",
            2 => .@"1",
            3 => .@"2",
            4 => .@"3",
            5 => .@"4",
            6 => .@"5",
            7 => .@"6",
            8 => .@"7",
            9 => .@"8",
            10 => .@"9",
            // 功能键
            59 => .f1,
            60 => .f2,
            61 => .f3,
            62 => .f4,
            63 => .f5,
            64 => .f6,
            65 => .f7,
            66 => .f8,
            67 => .f9,
            68 => .f10,
            87 => .f11,
            88 => .f12,
            // 控制键
            1 => .escape,
            15 => .tab,
            58 => .caps_lock,
            42 => .left_shift,
            54 => .right_shift,
            29 => .left_ctrl,
            97 => .right_ctrl,
            56 => .left_alt,
            100 => .right_alt,
            125 => .left_super,
            126 => .right_super,
            28 => .enter,
            14 => .backspace,
            111 => .delete,
            57 => .space,
            // 方向键
            103 => .up,
            108 => .down,
            105 => .left,
            106 => .right,
            102 => .home,
            107 => .end,
            104 => .page_up,
            109 => .page_down,
            110 => .insert,
            // 标点
            12 => .minus,
            13 => .equal,
            26 => .left_bracket,
            27 => .right_bracket,
            39 => .semicolon,
            40 => .apostrophe,
            41 => .grave,
            51 => .comma,
            52 => .period,
            53 => .slash,
            43 => .backslash,
            // 小键盘
            82 => .kp_0,
            79 => .kp_1,
            80 => .kp_2,
            81 => .kp_3,
            75 => .kp_4,
            76 => .kp_5,
            77 => .kp_6,
            71 => .kp_7,
            72 => .kp_8,
            73 => .kp_9,
            78 => .kp_add,
            74 => .kp_subtract,
            55 => .kp_multiply,
            98 => .kp_divide,
            96 => .kp_enter,
            83 => .kp_decimal,
            else => .escape,
        };
    }
};

/// 获取第一个屏幕
fn getFirstScreen(setup: [*c]const xcb.xcb_setup_t) ?*xcb.xcb_screen_t {
    const iter = xcb.xcb_setup_roots_iterator(setup);
    if (iter.rem == 0) return null;
    return iter.data;
}

/// 内部化 X11 atom
fn internAtom(conn: *xcb.xcb_connection_t, name: [*:0]const u8) u32 {
    const cookie = xcb.xcb_intern_atom(conn, 0, @intCast(std.mem.len(name)), name);
    var err: [*c]xcb.xcb_generic_error_t = null;
    const reply = xcb.xcb_intern_atom_reply(conn, cookie, &err);
    defer if (reply != null) std.c.free(reply);
    if (err != null) return 0;
    if (reply) |r| return r.*.atom;
    return 0;
}
