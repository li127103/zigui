//! Wayland 窗口后端 (Linux)
//! 使用 wayland-client + xdg-shell + xkbcommon

const std = @import("std");
const pal = @import("pal.zig");
const event_mod = @import("event.zig");

const wl = @cImport({
    @cInclude("wayland-client.h");
    @cInclude("xdg-shell-client-protocol.h");
    @cInclude("xdg-decoration-client-protocol.h");
});

const xkb = @cImport({
    @cInclude("xkbcommon/xkbcommon.h");
});

pub const WaylandBackend = struct {
    allocator: std.mem.Allocator,
    display: *wl.struct_wl_display,
    registry: *wl.struct_wl_registry,
    compositor: ?*wl.struct_wl_compositor = null,
    xdg_wm_base: ?*wl.struct_xdg_wm_base = null,
    decoration_manager: ?*wl.struct_zxdg_decoration_manager_v1 = null,
    seat: ?*wl.struct_wl_seat = null,
    keyboard: ?*wl.struct_wl_keyboard = null,
    pointer: ?*wl.struct_wl_pointer = null,
    // 窗口
    surface: ?*wl.struct_wl_surface = null,
    xdg_surface: ?*wl.struct_xdg_surface = null,
    toplevel: ?*wl.struct_xdg_toplevel = null,
    configured: bool = false,
    width: u32 = 0,
    height: u32 = 0,
    // xkb
    xkb_ctx: ?*xkb.xkb_context = null,
    xkb_keymap: ?*xkb.xkb_keymap = null,
    xkb_state: ?*xkb.xkb_state = null,
    // 鼠标状态
    pointer_x: f64 = 0,
    pointer_y: f64 = 0,
    // 修饰键
    mods: event_mod.Modifiers = .{},

    pub fn init(allocator: std.mem.Allocator) !WaylandBackend {
        const display = wl.wl_display_connect(null) orelse return error.ConnectionFailed;
        const registry = wl.wl_display_get_registry(display) orelse {
            wl.wl_display_disconnect(display);
            return error.RegistryFailed;
        };

        var self: WaylandBackend = .{
            .allocator = allocator,
            .display = display,
            .registry = registry,
        };

        // 绑定全局对象
        _ = wl.wl_registry_add_listener(registry, &registry_listener, &self);
        _ = wl.wl_display_roundtrip(display);
        _ = wl.wl_display_roundtrip(display);

        if (self.compositor == null) {
            self.deinit();
            return error.NoCompositor;
        }
        if (self.xdg_wm_base == null) {
            self.deinit();
            return error.NoXdgShell;
        }

        // 初始化 xkb context
        self.xkb_ctx = xkb.xkb_context_new(xkb.XKB_CONTEXT_NO_FLAGS);

        return self;
    }

    pub fn deinit(self: *WaylandBackend) void {
        if (self.xkb_state) |s| xkb.xkb_state_unref(s);
        if (self.xkb_keymap) |km| xkb.xkb_keymap_unref(km);
        if (self.xkb_ctx) |ctx| xkb.xkb_context_unref(ctx);

        if (self.keyboard) |kb| _ = wl.wl_keyboard_destroy(kb);
        if (self.pointer) |p| _ = wl.wl_pointer_destroy(p);
        if (self.toplevel) |t| _ = wl.xdg_toplevel_destroy(t);
        if (self.xdg_surface) |xs| _ = wl.xdg_surface_destroy(xs);
        if (self.surface) |s| _ = wl.wl_surface_destroy(s);
        if (self.seat) |s| _ = wl.wl_seat_destroy(s);
        if (self.xdg_wm_base) |x| _ = wl.xdg_wm_base_destroy(x);
        if (self.decoration_manager) |dm| _ = wl.zxdg_decoration_manager_v1_destroy(dm);
        if (self.compositor) |c| _ = wl.wl_compositor_destroy(c);
        _ = wl.wl_registry_destroy(self.registry);
        wl.wl_display_disconnect(self.display);
    }

    /// 创建窗口
    pub fn createWindow(self: *WaylandBackend, desc: pal.WindowDesc) !void {
        const compositor = self.compositor orelse return error.NoCompositor;
        const xdg_wm = self.xdg_wm_base orelse return error.NoXdgShell;

        const surface = wl.wl_compositor_create_surface(compositor) orelse return error.SurfaceFailed;
        const xdg_surface = wl.xdg_wm_base_get_xdg_surface(xdg_wm, surface) orelse return error.XdgSurfaceFailed;
        const toplevel = wl.xdg_surface_get_toplevel(xdg_surface) orelse return error.ToplevelFailed;

        // 设置标题和 app_id
        _ = wl.xdg_toplevel_set_title(toplevel, desc.title.ptr);
        _ = wl.xdg_toplevel_set_app_id(toplevel, "zigui");

        // 服务器端装饰
        if (self.decoration_manager) |dm| {
            const decoration = wl.zxdg_decoration_manager_v1_get_toplevel_decoration(dm, toplevel);
            if (decoration) |d| {
                _ = wl.zxdg_toplevel_decoration_v1_set_mode(d, wl.ZXDG_TOPLEVEL_DECORATION_V1_MODE_SERVER_SIDE);
            }
        }

        // 添加 xdg_surface listener
        _ = wl.xdg_surface_add_listener(xdg_surface, &xdg_surface_listener, self);
        _ = wl.xdg_toplevel_add_listener(toplevel, &xdg_toplevel_listener, self);

        // 提交 surface 以触发 configure
        wl.wl_surface_commit(surface);
        _ = wl.wl_display_roundtrip(self.display);

        self.surface = surface;
        self.xdg_surface = xdg_surface;
        self.toplevel = toplevel;
        self.width = desc.width;
        self.height = desc.height;

        // 绑定 seat 的 keyboard 和 pointer
        if (self.seat) |seat| {
            const kb = wl.wl_seat_get_keyboard(seat);
            if (kb) |k| {
                _ = wl.wl_keyboard_add_listener(k, &keyboard_listener, self);
                self.keyboard = k;
            }
            const ptr = wl.wl_seat_get_pointer(seat);
            if (ptr) |p| {
                _ = wl.wl_pointer_add_listener(p, &pointer_listener, self);
                self.pointer = p;
            }
        }
    }

    /// 轮询事件
    pub fn pollEvents(self: *WaylandBackend, queue: *pal.EventQueue, allocator: std.mem.Allocator) !void {
        _ = allocator;
        // 分发待处理事件 (非阻塞)
        while (wl.wl_display_prepare_read(self.display) != 0) {
            _ = wl.wl_display_dispatch_pending(self.display);
        }
        _ = wl.wl_display_flush(self.display);

        // 检查是否有数据可读 (非阻塞)
        const fd = wl.wl_display_get_fd(self.display);
        const pfd = std.posix.pollfd{
            .fd = fd,
            .events = std.posix.POLL.IN,
            .revents = 0,
        };
        var fds_mut = [_]std.posix.pollfd{pfd};
        const n = std.posix.poll(&fds_mut, 0) catch 0;
        if (n > 0) {
            _ = wl.wl_display_read_events(self.display);
            _ = wl.wl_display_dispatch_pending(self.display);
        } else {
            wl.wl_display_cancel_read(self.display);
        }
        _ = queue;
    }

    /// 获取 Wayland display 指针 (用于 Vulkan surface)
    pub fn getDisplay(self: *WaylandBackend) *anyopaque {
        return @ptrCast(self.display);
    }

    /// 获取 Wayland surface 指针 (用于 Vulkan surface)
    pub fn getSurface(self: *WaylandBackend) *anyopaque {
        return @ptrCast(self.surface);
    }

    pub fn getWindowSize(self: *const WaylandBackend) struct { width: u32, height: u32 } {
        return .{ .width = self.width, .height = self.height };
    }

    // ── 内部: 事件推送辅助 ──────────────────────────────────────────────────

    fn pushEvent(self: *WaylandBackend, ev: event_mod.Event) void {
        _ = self;
        // TODO: 需要持有 EventQueue 引用; 当前通过全局变量中转
        if (g_event_queue) |q| {
            q.push(g_allocator orelse return, ev) catch {};
        }
    }
};

// 全局事件队列引用 (Wayland 回调无法传递用户上下文到所有 listener)
var g_event_queue: ?*pal.EventQueue = null;
var g_allocator: ?std.mem.Allocator = null;
var g_backend: ?*WaylandBackend = null;

/// 设置全局事件队列 (在 pollEvents 前调用)
pub fn setEventQueue(queue: *pal.EventQueue, allocator: std.mem.Allocator, backend: *WaylandBackend) void {
    g_event_queue = queue;
    g_allocator = allocator;
    g_backend = backend;
}

// ── Registry Listener ──────────────────────────────────────────────────────

fn registryGlobal(
    data: ?*anyopaque,
    registry: ?*wl.struct_wl_registry,
    name: u32,
    interface: ?[*:0]const u8,
    version: u32,
) callconv(.c) void {
    const self: *WaylandBackend = @ptrCast(@alignCast(data.?));
    const iface = std.mem.span(interface orelse return);

    if (std.mem.eql(u8, iface, "wl_compositor")) {
        self.compositor = @ptrCast(wl.wl_registry_bind(registry.?, name, &wl.wl_compositor_interface, @min(version, 4)));
    } else if (std.mem.eql(u8, iface, "xdg_wm_base")) {
        self.xdg_wm_base = @ptrCast(wl.wl_registry_bind(registry.?, name, &wl.xdg_wm_base_interface, @min(version, 3)));
        if (self.xdg_wm_base) |x| {
            _ = wl.xdg_wm_base_add_listener(x, &xdg_wm_base_listener, self);
        }
    } else if (std.mem.eql(u8, iface, "zxdg_decoration_manager_v1")) {
        self.decoration_manager = @ptrCast(wl.wl_registry_bind(registry.?, name, &wl.zxdg_decoration_manager_v1_interface, @min(version, 1)));
    } else if (std.mem.eql(u8, iface, "wl_seat")) {
        self.seat = @ptrCast(wl.wl_registry_bind(registry.?, name, &wl.wl_seat_interface, @min(version, 5)));
    }
}

fn registryGlobalRemove(
    _: ?*anyopaque,
    _: ?*wl.struct_wl_registry,
    _: u32,
) callconv(.c) void {}

const registry_listener = wl.wl_registry_listener{
    .global = registryGlobal,
    .global_remove = registryGlobalRemove,
};

// ── XDG WM Base Listener (ping/pong) ──────────────────────────────────────

fn xdgWmBasePing(
    data: ?*anyopaque,
    xdg_wm_base: ?*wl.struct_xdg_wm_base,
    serial: u32,
) callconv(.c) void {
    _ = data;
    wl.xdg_wm_base_pong(xdg_wm_base.?, serial);
}

const xdg_wm_base_listener = wl.xdg_wm_base_listener{
    .ping = xdgWmBasePing,
};

// ── XDG Surface Listener ──────────────────────────────────────────────────

fn xdgSurfaceConfigure(
    data: ?*anyopaque,
    xdg_surface: ?*wl.struct_xdg_surface,
    serial: u32,
) callconv(.c) void {
    const self: *WaylandBackend = @ptrCast(@alignCast(data.?));
    wl.xdg_surface_ack_configure(xdg_surface.?, serial);
    self.configured = true;
}

const xdg_surface_listener = wl.xdg_surface_listener{
    .configure = xdgSurfaceConfigure,
};

// ── XDG Toplevel Listener ─────────────────────────────────────────────────

fn xdgToplevelConfigure(
    data: ?*anyopaque,
    _: ?*wl.struct_xdg_toplevel,
    width: i32,
    height: i32,
    _: ?*wl.struct_wl_array,
) callconv(.c) void {
    const self: *WaylandBackend = @ptrCast(@alignCast(data.?));
    if (width > 0 and height > 0) {
        self.width = @intCast(width);
        self.height = @intCast(height);
        self.pushEvent(.{ .resize = .{ .width = self.width, .height = self.height } });
    }
}

fn xdgToplevelClose(
    data: ?*anyopaque,
    _: ?*wl.struct_xdg_toplevel,
) callconv(.c) void {
    const self: *WaylandBackend = @ptrCast(@alignCast(data.?));
    self.pushEvent(.{ .close_requested = .{ .window_id = 0 } });
}

fn xdgToplevelConfigureBounds(
    _: ?*anyopaque,
    _: ?*wl.struct_xdg_toplevel,
    _: i32,
    _: i32,
) callconv(.c) void {}

fn xdgToplevelWmCapabilities(
    _: ?*anyopaque,
    _: ?*wl.struct_xdg_toplevel,
    _: ?*wl.struct_wl_array,
) callconv(.c) void {}

const xdg_toplevel_listener = wl.xdg_toplevel_listener{
    .configure = xdgToplevelConfigure,
    .close = xdgToplevelClose,
    .configure_bounds = xdgToplevelConfigureBounds,
    .wm_capabilities = xdgToplevelWmCapabilities,
};

// ── Keyboard Listener ─────────────────────────────────────────────────────

fn keyboardKeymap(
    _: ?*anyopaque,
    _: ?*wl.struct_wl_keyboard,
    _: u32,
    fd: i32,
    _: u32,
) callconv(.c) void {
    // TODO: 修复 xkb keymap 处理
    _ = std.os.linux.close(fd);
}

fn keyboardEnter(
    _: ?*anyopaque,
    _: ?*wl.struct_wl_keyboard,
    _: u32,
    _: ?*wl.struct_wl_surface,
    _: ?*wl.struct_wl_array,
) callconv(.c) void {}

fn keyboardLeave(
    _: ?*anyopaque,
    _: ?*wl.struct_wl_keyboard,
    _: u32,
    _: ?*wl.struct_wl_surface,
) callconv(.c) void {}

fn keyboardKey(
    data: ?*anyopaque,
    _: ?*wl.struct_wl_keyboard,
    _: u32,
    _: u32,
    key: u32,
    state: u32,
) callconv(.c) void {
    const self: *WaylandBackend = @ptrCast(@alignCast(data.?));
    const pressed = state == wl.WL_KEYBOARD_KEY_STATE_PRESSED;

    // evdev keycode → xkb keycode (+8)
    const keycode: xkb.xkb_keycode_t = key + 8;

    if (self.xkb_state) |xkb_state| {
        // 更新修饰键状态
        if (pressed) {
            _ = xkb.xkb_state_update_key(xkb_state, keycode, xkb.XKB_KEY_DOWN);
        }

        // 获取 keysym
        const keysym = xkb.xkb_state_key_get_one_sym(xkb_state, keycode);
        if (keysym != xkb.XKB_KEY_NoSymbol) {
            const btn_state: event_mod.ButtonState = if (pressed) .pressed else .released;
            const key_code = keysymToKeyCode(keysym);
            self.pushEvent(.{ .key = .{
                .state = btn_state,
                .key = key_code,
                .modifiers = self.mods,
            } });

            // 文本输入 (仅按下时)
            if (pressed) {
                var buf: [8]u8 = undefined;
                const len = xkb.xkb_keysym_to_utf8(keysym, &buf, buf.len);
                if (len > 1) {
                    // 解码 UTF-8 第一个 codepoint
                    const ulen: usize = @intCast(len);
                    const cp = std.unicode.utf8Decode(buf[0 .. ulen - 1]) catch 0;
                    if (cp >= 0x20) { // 排除控制字符
                        self.pushEvent(.{ .text_input = .{ .codepoint = cp } });
                    }
                }
            }
        }

        if (!pressed) {
            _ = xkb.xkb_state_update_key(xkb_state, keycode, xkb.XKB_KEY_UP);
        }
    }
}

fn keyboardModifiers(
    data: ?*anyopaque,
    _: ?*wl.struct_wl_keyboard,
    _: u32,
    mods_depressed: u32,
    mods_latched: u32,
    mods_locked: u32,
    group: u32,
) callconv(.c) void {
    const self: *WaylandBackend = @ptrCast(@alignCast(data.?));
    if (self.xkb_state) |xkb_state| {
        _ = xkb.xkb_state_update_mask(xkb_state, mods_depressed, mods_latched, mods_locked, 0, 0, group);

        // 更新修饰键
        const shift_active = xkb.xkb_state_mod_name_is_active(xkb_state, xkb.XKB_MOD_NAME_SHIFT, xkb.XKB_STATE_MODS_EFFECTIVE) > 0;
        const ctrl_active = xkb.xkb_state_mod_name_is_active(xkb_state, xkb.XKB_MOD_NAME_CTRL, xkb.XKB_STATE_MODS_EFFECTIVE) > 0;
        const alt_active = xkb.xkb_state_mod_name_is_active(xkb_state, xkb.XKB_MOD_NAME_ALT, xkb.XKB_STATE_MODS_EFFECTIVE) > 0;
        const super_active = xkb.xkb_state_mod_name_is_active(xkb_state, xkb.XKB_MOD_NAME_LOGO, xkb.XKB_STATE_MODS_EFFECTIVE) > 0;

        self.mods = .{
            .shift = shift_active,
            .ctrl = ctrl_active,
            .alt = alt_active,
            .super_key = super_active,
        };
    }
}

fn keyboardRepeatInfo(
    _: ?*anyopaque,
    _: ?*wl.struct_wl_keyboard,
    _: i32,
    _: i32,
) callconv(.c) void {}

const keyboard_listener = wl.wl_keyboard_listener{
    .keymap = keyboardKeymap,
    .enter = keyboardEnter,
    .leave = keyboardLeave,
    .key = keyboardKey,
    .modifiers = keyboardModifiers,
    .repeat_info = keyboardRepeatInfo,
};

// ── Pointer Listener ──────────────────────────────────────────────────────

fn pointerEnter(
    data: ?*anyopaque,
    _: ?*wl.struct_wl_pointer,
    _: u32,
    _: ?*wl.struct_wl_surface,
    sx: wl.wl_fixed_t,
    sy: wl.wl_fixed_t,
) callconv(.c) void {
    const self: *WaylandBackend = @ptrCast(@alignCast(data.?));
    self.pointer_x = wl.wl_fixed_to_double(sx);
    self.pointer_y = wl.wl_fixed_to_double(sy);
    self.pushEvent(.{ .mouse_move = .{
        .x = @intFromFloat(@round(self.pointer_x)),
        .y = @intFromFloat(@round(self.pointer_y)),
    } });
}

fn pointerLeave(
    data: ?*anyopaque,
    _: ?*wl.struct_wl_pointer,
    _: u32,
    _: ?*wl.struct_wl_surface,
) callconv(.c) void {
    const self: *WaylandBackend = @ptrCast(@alignCast(data.?));
    self.pushEvent(.mouse_leave);
}

fn pointerMotion(
    data: ?*anyopaque,
    _: ?*wl.struct_wl_pointer,
    _: u32,
    sx: wl.wl_fixed_t,
    sy: wl.wl_fixed_t,
) callconv(.c) void {
    const self: *WaylandBackend = @ptrCast(@alignCast(data.?));
    self.pointer_x = wl.wl_fixed_to_double(sx);
    self.pointer_y = wl.wl_fixed_to_double(sy);
    self.pushEvent(.{ .mouse_move = .{
        .x = @intFromFloat(@round(self.pointer_x)),
        .y = @intFromFloat(@round(self.pointer_y)),
    } });
}

fn pointerButton(
    data: ?*anyopaque,
    _: ?*wl.struct_wl_pointer,
    _: u32,
    _: u32,
    button: u32,
    state: u32,
) callconv(.c) void {
    const self: *WaylandBackend = @ptrCast(@alignCast(data.?));
    const btn_state: event_mod.ButtonState = if (state == wl.WL_POINTER_BUTTON_STATE_PRESSED) .pressed else .released;
    const btn: event_mod.MouseButton = switch (button) {
        0x110 => .left, // BTN_LEFT
        0x111 => .right, // BTN_RIGHT
        0x112 => .middle, // BTN_MIDDLE
        else => .left,
    };
    self.pushEvent(.{ .mouse_button = .{
        .button = btn,
        .state = btn_state,
        .x = @intFromFloat(@round(self.pointer_x)),
        .y = @intFromFloat(@round(self.pointer_y)),
    } });
}

fn pointerAxis(
    data: ?*anyopaque,
    _: ?*wl.struct_wl_pointer,
    _: u32,
    axis: u32,
    value: wl.wl_fixed_t,
) callconv(.c) void {
    const self: *WaylandBackend = @ptrCast(@alignCast(data.?));
    const delta: f32 = @floatCast(-wl.wl_fixed_to_double(value) / 10.0);
    const scroll_axis: event_mod.ScrollAxis = if (axis == wl.WL_POINTER_AXIS_VERTICAL_SCROLL) .vertical else .horizontal;
    self.pushEvent(.{ .scroll = .{ .axis = scroll_axis, .delta = delta } });
}

fn pointerFrame(
    _: ?*anyopaque,
    _: ?*wl.struct_wl_pointer,
) callconv(.c) void {}

fn pointerAxisSource(
    _: ?*anyopaque,
    _: ?*wl.struct_wl_pointer,
    _: u32,
) callconv(.c) void {}

fn pointerAxisStop(
    _: ?*anyopaque,
    _: ?*wl.struct_wl_pointer,
    _: u32,
    _: u32,
) callconv(.c) void {}

fn pointerAxisDiscrete(
    _: ?*anyopaque,
    _: ?*wl.struct_wl_pointer,
    _: u32,
    _: i32,
) callconv(.c) void {}

fn pointerAxisValue120(
    _: ?*anyopaque,
    _: ?*wl.struct_wl_pointer,
    _: u32,
    _: i32,
) callconv(.c) void {}

fn pointerAxisRelativeDirection(
    _: ?*anyopaque,
    _: ?*wl.struct_wl_pointer,
    _: u32,
    _: u32,
) callconv(.c) void {}

const pointer_listener = wl.wl_pointer_listener{
    .enter = pointerEnter,
    .leave = pointerLeave,
    .motion = pointerMotion,
    .button = pointerButton,
    .axis = pointerAxis,
    .frame = pointerFrame,
    .axis_source = pointerAxisSource,
    .axis_stop = pointerAxisStop,
    .axis_discrete = pointerAxisDiscrete,
    .axis_value120 = pointerAxisValue120,
    .axis_relative_direction = pointerAxisRelativeDirection,
};

// ── Keysym → KeyCode 映射 ─────────────────────────────────────────────────

fn keysymToKeyCode(keysym: xkb.xkb_keysym_t) event_mod.KeyCode {
    return switch (keysym) {
        // 字母
        0x61...0x7A => @enumFromInt(keysym - 0x61), // a-z
        0x41...0x5A => @enumFromInt(keysym - 0x41), // A-Z → same as lowercase
        // 数字
        0x30...0x39 => @enumFromInt(26 + (keysym - 0x30)), // 0-9
        // 功能键
        0xFFBE...0xFFC9 => @enumFromInt(36 + (keysym - 0xFFBE)), // F1-F12
        // 控制键
        0xFF1B => .escape,
        0xFF09 => .tab,
        0xFFE5 => .caps_lock,
        0xFFE1 => .left_shift,
        0xFFE2 => .right_shift,
        0xFFE3 => .left_ctrl,
        0xFFE4 => .right_ctrl,
        0xFFE9 => .left_alt,
        0xFFEA => .right_alt,
        0xFFEB => .left_super,
        0xFFEC => .right_super,
        0xFF0D => .enter,
        0xFF08 => .backspace,
        0xFFFF => .delete,
        0x20 => .space,
        // 方向键
        0xFF52 => .up,
        0xFF54 => .down,
        0xFF51 => .left,
        0xFF53 => .right,
        0xFF50 => .home,
        0xFF57 => .end,
        0xFF55 => .page_up,
        0xFF56 => .page_down,
        0xFF63 => .insert,
        // 标点
        0x2D => .minus,
        0x3D => .equal,
        0x5B => .left_bracket,
        0x5D => .right_bracket,
        0x3B => .semicolon,
        0x27 => .apostrophe,
        0x60 => .grave,
        0x2C => .comma,
        0x2E => .period,
        0x2F => .slash,
        0x5C => .backslash,
        else => @enumFromInt(@as(u16, 0xFFFF)),
    };
}
