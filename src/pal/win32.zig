//! Win32 窗口后端 (Windows)
//!
//! 负责窗口创建、DPI 感知、事件循环、输入处理。接口与 Wayland/X11/Cocoa 后端对齐,
//! 由 pal.zig 在 Windows 平台下选择使用。
//!
//! 实现说明: 真实 Win32 逻辑用 `if (comptime is_windows)` 包裹, 非 Windows 下走 stub,
//! 以便在本机交叉验证类型/结构 (非 Windows 目标下 win32=void, 不会触碰真实 API)。

const std = @import("std");
const builtin = @import("builtin");
const is_windows = builtin.os.tag == .windows;

const event_mod = @import("event.zig");
const win_mod = @import("window.zig");

const win32 = if (is_windows) @cImport({
    @cDefine("WIN32_LEAN_AND_MEAN", "1");
    @cInclude("windows.h");
}) else void;

/// 跨平台阻塞睡眠 (毫秒)。Windows 走 Win32 Sleep; POSIX 走 std.c.nanosleep。
/// 注意: Zig 标准库没有 std.time.sleep, 切勿误用。
pub fn sleep(ms: u32) void {
    if (comptime is_windows) {
        win32.Sleep(ms);
        return;
    }
    var req: std.c.timespec = .{
        .sec = @intCast(ms / 1000),
        .nsec = @as(isize, @intCast((ms % 1000) * 1_000_000)),
    };
    _ = std.c.nanosleep(&req, null);
}

pub const Win32Backend = struct {
    allocator: std.mem.Allocator,
    id: u32 = 0,
    hwnd: if (is_windows) ?win32.HWND else void = null,
    hinstance: if (is_windows) ?win32.HINSTANCE else void = null,
    width: u32 = 800,
    height: u32 = 600,
    should_close: bool = false,
    scale_factor: f32 = 1.0,
    event_queue: ?*@import("pal.zig").EventQueue = null,
    mods: event_mod.Modifiers = .{},
    pointer_x: f64 = 0,
    pointer_y: f64 = 0,
    class_name: if (is_windows) [16]u8 else void = [_]u8{0} ** 16,

    pub fn init(allocator: std.mem.Allocator) !Win32Backend {
        if (comptime !is_windows) {
            return error.NotImplemented;
        }
        // 系统级 DPI 感知: 让窗口客户端坐标 = 物理像素
        _ = win32.SetProcessDPIAware();

        var self: Win32Backend = .{
            .allocator = allocator,
            .hinstance = win32.GetModuleHandleW(null),
            .class_name = [_]u8{0} ** 16,
        };

        // DPI 探测 (桌面 HDC 的 LOGPIXELSX)
        const hdc = win32.GetDC(null);
        const dpi = win32.GetDeviceCaps(hdc, win32.LOGPIXELSX);
        _ = win32.ReleaseDC(null, hdc);
        if (dpi > 0) {
            self.scale_factor = @max(1.0, @as(f32, @floatFromInt(dpi)) / 96.0);
        }
        return self;
    }

    pub fn deinit(self: *Win32Backend) void {
        if (comptime !is_windows) return;
        if (self.hwnd) |h| _ = win32.DestroyWindow(h);
        if (self.hinstance) |hinst| _ = win32.UnregisterClassA(@ptrCast(&self.class_name), hinst);
        self.hwnd = null;
    }

    pub fn createWindow(self: *Win32Backend, title: []const u8, width: u32, height: u32) !void {
        if (comptime !is_windows) {
            return error.NotImplemented;
        }
        if (self.hinstance == null) return error.NotInitialized;

        const phys_w: i32 = @intFromFloat(@as(f32, @floatFromInt(width)) * self.scale_factor);
        const phys_h: i32 = @intFromFloat(@as(f32, @floatFromInt(height)) * self.scale_factor);

        const class_name = "ZiguiWindow";
        @memcpy(self.class_name[0..class_name.len], class_name);
        self.class_name[class_name.len] = 0;

        var wc: win32.WNDCLASSEXW = std.mem.zeroes(win32.WNDCLASSEXW);
        wc.cbSize = @sizeOf(win32.WNDCLASSEXW);
        wc.style = win32.CS_HREDRAW | win32.CS_VREDRAW;
        wc.lpfnWndProc = wndProc;
        wc.hInstance = self.hinstance.?;
        wc.lpszClassName = @ptrCast(@constCast(&class_name_w));
        if (win32.RegisterClassExW(&wc) == 0) return error.WindowClassRegistrationFailed;

        const title_w = try utf8ToUtf16Le(self.allocator, title);
        defer self.allocator.free(title_w);

        const hwnd = win32.CreateWindowExW(
            win32.WS_EX_APPWINDOW,
            @ptrCast(@constCast(&class_name_w)),
            @ptrCast(title_w.ptr),
            win32.WS_OVERLAPPEDWINDOW,
            win32.CW_USEDEFAULT,
            win32.CW_USEDEFAULT,
            phys_w,
            phys_h,
            null,
            null,
            self.hinstance.?,
            @ptrCast(self),
        );
        if (hwnd == null) return error.WindowCreationFailed;
        self.hwnd = hwnd;
        _ = win32.SetWindowLongPtrW(hwnd, win32.GWLP_USERDATA, @intCast(@intFromPtr(self)));

        self.width = width;
        self.height = height;
        _ = win32.ShowWindow(hwnd, win32.SW_SHOW);
        _ = win32.UpdateWindow(hwnd);
    }

    /// 创建一个额外的顶层子窗口 (独立 HWND + 独立事件队列)。
    /// 返回堆分配的 Win32Backend; 调用方需设置其 .id 与 .event_queue。
    /// 复用主窗口已注册的 "ZiguiWindow" 窗口类与 hinstance。
    pub fn createSubWindow(self: *Win32Backend, allocator: std.mem.Allocator, id: u32, title: []const u8, width: u32, height: u32) !*Win32Backend {
        if (comptime !is_windows) {
            return error.NotImplemented;
        }
        if (self.hinstance == null) return error.NotInitialized;

        const sub = try allocator.create(Win32Backend);
        errdefer allocator.destroy(sub);
        sub.* = .{
            .allocator = allocator,
            .id = id,
            .hinstance = self.hinstance,
            .width = width,
            .height = height,
            .scale_factor = self.scale_factor,
            .event_queue = null,
            .class_name = self.class_name,
        };

        const phys_w: i32 = @intFromFloat(@as(f32, @floatFromInt(width)) * sub.scale_factor);
        const phys_h: i32 = @intFromFloat(@as(f32, @floatFromInt(height)) * sub.scale_factor);

        const title_w = try utf8ToUtf16Le(allocator, title);
        defer allocator.free(title_w);

        const hwnd = win32.CreateWindowExW(
            win32.WS_EX_APPWINDOW,
            @ptrCast(@constCast(&class_name_w)),
            @ptrCast(title_w.ptr),
            win32.WS_OVERLAPPEDWINDOW,
            win32.CW_USEDEFAULT,
            win32.CW_USEDEFAULT,
            phys_w,
            phys_h,
            null,
            null,
            self.hinstance.?,
            @ptrCast(sub),
        );
        if (hwnd == null) return error.WindowCreationFailed;
        sub.hwnd = hwnd;
        _ = win32.SetWindowLongPtrW(hwnd, win32.GWLP_USERDATA, @intCast(@intFromPtr(sub)));

        _ = win32.ShowWindow(hwnd, win32.SW_SHOW);
        _ = win32.UpdateWindow(hwnd);
        return sub;
    }

    pub fn showWindow(self: *Win32Backend) void {
        if (comptime !is_windows) return;
        if (self.hwnd) |h| {
            _ = win32.ShowWindow(h, win32.SW_SHOW);
        }
    }

    pub fn hideWindow(self: *Win32Backend) void {
        if (comptime !is_windows) return;
        if (self.hwnd) |h| {
            _ = win32.ShowWindow(h, win32.SW_HIDE);
        }
    }

    /// 设置所有者窗口 (Win32 下使子窗口始终位于 owner 之上, 并随 owner 最小化)。
    /// owner_hwnd 对外以 *anyopaque 暴露 (与主窗口 SurfaceInfo 约定一致)。
    pub fn setOwner(self: *Win32Backend, owner_hwnd: ?*anyopaque) void {
        if (comptime !is_windows) return;
        if (self.hwnd) |h| {
            const o: win32.HWND = if (owner_hwnd) |o2| @alignCast(@ptrCast(o2)) else null;
            _ = win32.SetWindowLongPtrW(h, win32.GWLP_HWNDPARENT, @intCast(@intFromPtr(o)));
        }
    }

    pub fn setTitleWindow(self: *Win32Backend, title: []const u8) void {
        if (comptime !is_windows) return;
        if (self.hwnd) |h| {
            const title_w = self.allocator.alloc(u16, title.len + 1) catch return;
            _ = std.unicode.utf8ToUtf16Le(title_w, title) catch return;
            title_w[title.len] = 0;
            _ = win32.SetWindowTextW(h, @ptrCast(title_w.ptr));
            self.allocator.free(title_w);
        }
    }

    pub fn destroyWindow(self: *Win32Backend) void {
        if (comptime !is_windows) return;
        if (self.hwnd) |h| {
            _ = win32.DestroyWindow(h);
            self.hwnd = null;
        }
        self.allocator.destroy(self);
    }

    pub fn getSurfaceInfo(self: *Win32Backend) win_mod.SurfaceInfo {
        return .{
            .win32 = .{
                .hwnd = @ptrCast(self.hwnd),
                .hinstance = @ptrCast(self.hinstance),
            },
        };
    }

    pub fn getScaleFactor(self: *const Win32Backend) f32 {
        return self.scale_factor;
    }

    fn updateScale(self: *Win32Backend) void {
        if (comptime !is_windows) return;
        if (self.hwnd) |h| {
            const dpi = win32.GetDpiForWindow(h);
            if (dpi != 0) self.scale_factor = @max(1.0, @as(f32, @floatFromInt(dpi)) / 96.0);
        }
    }

    pub fn pollEvents(self: *Win32Backend) void {
        _ = self;
        if (comptime !is_windows) return;
        var msg: win32.MSG = std.mem.zeroes(win32.MSG);
        while (win32.PeekMessageW(&msg, null, 0, 0, win32.PM_REMOVE) != 0) {
            _ = win32.TranslateMessage(&msg);
            _ = win32.DispatchMessageW(&msg);
        }
    }

    pub fn shouldClose(self: *const Win32Backend) bool {
        return self.should_close;
    }

    pub fn setTitle(self: *Win32Backend, title: []const u8) void {
        if (comptime !is_windows) {
            return;
        }
        if (self.hwnd) |h| {
            const title_w = self.allocator.alloc(u16, title.len + 1) catch return;
            _ = std.unicode.utf8ToUtf16Le(title_w, title) catch return;
            title_w[title.len] = 0;
            _ = win32.SetWindowTextW(h, @ptrCast(title_w.ptr));
            self.allocator.free(title_w);
        }
    }

    pub fn setSize(self: *Win32Backend, width: u32, height: u32) void {
        if (comptime !is_windows) {
            return;
        }
        if (self.hwnd) |h| {
            const phys_w: i32 = @intFromFloat(@as(f32, @floatFromInt(width)) * self.scale_factor);
            const phys_h: i32 = @intFromFloat(@as(f32, @floatFromInt(height)) * self.scale_factor);
            _ = win32.SetWindowPos(h, null, 0, 0, phys_w, phys_h,
                win32.SWP_NOMOVE | win32.SWP_NOZORDER | win32.SWP_NOACTIVATE);
            self.width = width;
            self.height = height;
        }
    }

    fn pushEvent(self: *Win32Backend, ev: event_mod.Event) void {
        if (self.event_queue) |q| q.push(self.allocator, ev) catch {};
    }
};

// ── Win32 宏的 Zig 等价实现 ────────────────────────────────────────────────
// 直接使用 windows.h 的 LOWORD/HIWORD/GET_X_LPARAM/GET_WHEEL_DELTA_WPARAM 等宏会触发
// Zig cImport 翻译阶段类型错误 (宏体内 `ULONG_PTR & 0xffff` 在 c_ulonglong 与 c_int 间
// 不兼容)。这里手动按位实现, 语义与 Win32 宏一致。
fn loword(lp: i64) u16 {
    return @as(u16, @truncate(@as(u64, @bitCast(lp))));
}
fn hiword(lp: i64) u16 {
    return @as(u16, @truncate((@as(u64, @bitCast(lp)) >> 16)));
}
fn getXLPARAM(lp: i64) i16 {
    return @as(i16, @truncate(@as(i64, @bitCast(lp))));
}
fn getYLPARAM(lp: i64) i16 {
    return @as(i16, @truncate((@as(i64, @bitCast(lp)) >> 16)));
}
fn getWheelDelta(wp: u64) i16 {
    return @as(i16, @truncate(@as(i64, @bitCast(wp)) >> 16));
}

// 窗口类名: W 系列 API 需要 UTF-16 (RegisterClassExW / CreateWindowExW)
const class_name_w = blk: {
    const ascii = "ZiguiWindow";
    var arr: [ascii.len + 1 : 0]u16 = undefined;
    for (ascii, 0..) |c, i| arr[i] = c;
    arr[ascii.len] = 0;
    break :blk arr;
};

fn wndProc(hwnd: win32.HWND, u_msg: win32.UINT, w_param: win32.WPARAM, l_param: win32.LPARAM) callconv(.c) win32.LRESULT {
    if (comptime !is_windows) {
        return 0;
    }
    const self = getBackend(@ptrCast(hwnd));
    switch (u_msg) {
        win32.WM_CLOSE => {
            if (self) |s| s.pushEvent(.{ .close_requested = .{ .window_id = s.id } });
            return 0;
        },
        win32.WM_DESTROY => {
            if (self) |s| {
                s.should_close = true;
                // 仅主窗口 (id==0) 触发退出消息循环; 子窗口关闭不应终止整个应用。
                if (s.id == 0) win32.PostQuitMessage(0);
            }
            return 0;
        },
        win32.WM_DPICHANGED => {
            if (self) |s| s.updateScale();
            return 0;
        },
        win32.WM_SIZE => {
            if (self) |s| {
                const client_w = @as(u32, loword(l_param));
                const client_h = @as(u32, hiword(l_param));
                const logical_w: u32 = @intFromFloat(@as(f32, @floatFromInt(client_w)) / s.scale_factor);
                const logical_h: u32 = @intFromFloat(@as(f32, @floatFromInt(client_h)) / s.scale_factor);
                s.width = logical_w;
                s.height = logical_h;
                s.pushEvent(.{ .resize = .{ .window_id = s.id, .width = logical_w, .height = logical_h } });
            }
            return 0;
        },
        win32.WM_MOVE => {
            if (self) |s| {
                const x = @as(i32, getXLPARAM(l_param));
                const y = @as(i32, getYLPARAM(l_param));
                s.pushEvent(.{ .move = .{ .window_id = s.id, .x = x, .y = y } });
            }
            return 0;
        },
        win32.WM_MOUSEMOVE => {
            if (self) |s| {
                const x = @as(i32, getXLPARAM(l_param));
                const y = @as(i32, getYLPARAM(l_param));
                s.pointer_x = @floatFromInt(x);
                s.pointer_y = @floatFromInt(y);
                s.pushEvent(.{ .mouse_move = .{ .window_id = s.id, .x = x, .y = y } });
            }
            return 0;
        },
        win32.WM_LBUTTONDOWN, win32.WM_LBUTTONUP, win32.WM_RBUTTONDOWN, win32.WM_RBUTTONUP, win32.WM_MBUTTONDOWN, win32.WM_MBUTTONUP => {
            if (self) |s| {
                const btn = buttonFromMsg(u_msg);
                const state: event_mod.ButtonState = if (u_msg == win32.WM_LBUTTONDOWN or u_msg == win32.WM_RBUTTONDOWN or u_msg == win32.WM_MBUTTONDOWN) .pressed else .released;
                const x = @as(i32, getXLPARAM(l_param));
                const y = @as(i32, getYLPARAM(l_param));
                s.pushEvent(.{ .mouse_button = .{ .window_id = s.id, .button = btn, .state = state, .x = x, .y = y } });
                updateModsFromKeyState(s);
            }
            return 0;
        },
        win32.WM_MOUSEWHEEL => {
            if (self) |s| {
                const delta: i16 = getWheelDelta(w_param);
                const scroll: f32 = @as(f32, @floatFromInt(delta)) / 120.0;
                s.pushEvent(.{ .scroll = .{ .window_id = s.id, .axis = .vertical, .delta = scroll } });
            }
            return 0;
        },
        win32.WM_KEYDOWN, win32.WM_KEYUP, win32.WM_SYSKEYDOWN, win32.WM_SYSKEYUP => {
            if (self) |s| {
                const vk: u32 = @intCast(w_param);
                const key = mapVirtualKey(vk) orelse return win32.DefWindowProcW(hwnd, u_msg, w_param, l_param);
                const state: event_mod.ButtonState = if (u_msg == win32.WM_KEYDOWN or u_msg == win32.WM_SYSKEYDOWN) .pressed else .released;
                updateModsFromKeyState(s);
                const mods = s.mods;
                if (state == .pressed) {
                    if (genTextInput(vk, w_param, l_param)) |cp| {
                        s.pushEvent(.{ .text_input = .{ .window_id = s.id, .codepoint = cp } });
                    }
                }
                s.pushEvent(.{ .key = .{ .window_id = s.id, .state = state, .key = key, .modifiers = mods } });
            }
            return 0;
        },
        else => return win32.DefWindowProcW(hwnd, u_msg, w_param, l_param),
    }
    return 0;
}

fn getBackend(hwnd: ?*anyopaque) ?*Win32Backend {
    if (comptime !is_windows) {
        return null;
    }
    if (hwnd == null) return null;
    const ptr: win32.LONG_PTR = win32.GetWindowLongPtrW(@alignCast(@ptrCast(hwnd)), win32.GWLP_USERDATA);
    if (ptr == 0) return null;
    return @ptrFromInt(@as(usize, @intCast(ptr)));
}

fn buttonFromMsg(u_msg: u32) event_mod.MouseButton {
    if (comptime !is_windows) {
        return .left;
    }
    return switch (u_msg) {
        win32.WM_LBUTTONDOWN, win32.WM_LBUTTONUP => .left,
        win32.WM_RBUTTONDOWN, win32.WM_RBUTTONUP => .right,
        else => .middle,
    };
}

fn updateModsFromKeyState(s: *Win32Backend) void {
    if (comptime !is_windows) {
        return;
    }
    s.mods.shift = (@as(c_int, win32.GetKeyState(win32.VK_SHIFT)) & 0x8000) != 0;
    s.mods.ctrl = (@as(c_int, win32.GetKeyState(win32.VK_CONTROL)) & 0x8000) != 0;
    s.mods.alt = (@as(c_int, win32.GetKeyState(win32.VK_MENU)) & 0x8000) != 0;
    s.mods.super_key = (@as(c_int, win32.GetKeyState(win32.VK_LWIN)) & 0x8000) != 0 or (@as(c_int, win32.GetKeyState(win32.VK_RWIN)) & 0x8000) != 0;
    s.mods.caps_lock = (win32.GetKeyState(win32.VK_CAPITAL) & 0x0001) != 0;
}

fn mapVirtualKey(vk: u32) ?event_mod.KeyCode {
    if (comptime !is_windows) {
        return null;
    }
    return switch (vk) {
        win32.VK_ESCAPE => .escape,
        win32.VK_TAB => .tab,
        win32.VK_CAPITAL => .caps_lock,
        win32.VK_SHIFT => .left_shift,
        win32.VK_CONTROL => .left_ctrl,
        win32.VK_MENU => .left_alt,
        win32.VK_LWIN, win32.VK_RWIN => .left_super,
        win32.VK_RETURN => .enter,
        win32.VK_BACK => .backspace,
        win32.VK_DELETE => .delete,
        win32.VK_SPACE => .space,
        win32.VK_LEFT => .left,
        win32.VK_RIGHT => .right,
        win32.VK_UP => .up,
        win32.VK_DOWN => .down,
        win32.VK_HOME => .home,
        win32.VK_END => .end,
        win32.VK_PRIOR => .page_up,
        win32.VK_NEXT => .page_down,
        win32.VK_INSERT => .insert,
        win32.VK_OEM_MINUS => .minus,
        win32.VK_OEM_PLUS => .equal,
        win32.VK_OEM_4 => .left_bracket,
        win32.VK_OEM_6 => .right_bracket,
        win32.VK_OEM_1 => .semicolon,
        win32.VK_OEM_7 => .apostrophe,
        win32.VK_OEM_3 => .grave,
        win32.VK_OEM_COMMA => .comma,
        win32.VK_OEM_PERIOD => .period,
        win32.VK_OEM_2 => .slash,
        win32.VK_OEM_5 => .backslash,
        win32.VK_NUMPAD0 => .kp_0,
        win32.VK_NUMPAD1 => .kp_1,
        win32.VK_NUMPAD2 => .kp_2,
        win32.VK_NUMPAD3 => .kp_3,
        win32.VK_NUMPAD4 => .kp_4,
        win32.VK_NUMPAD5 => .kp_5,
        win32.VK_NUMPAD6 => .kp_6,
        win32.VK_NUMPAD7 => .kp_7,
        win32.VK_NUMPAD8 => .kp_8,
        win32.VK_NUMPAD9 => .kp_9,
        win32.VK_ADD => .kp_add,
        win32.VK_SUBTRACT => .kp_subtract,
        win32.VK_MULTIPLY => .kp_multiply,
        win32.VK_DIVIDE => .kp_divide,
        win32.VK_DECIMAL => .kp_decimal,
        win32.VK_F1 => .f1,
        win32.VK_F2 => .f2,
        win32.VK_F3 => .f3,
        win32.VK_F4 => .f4,
        win32.VK_F5 => .f5,
        win32.VK_F6 => .f6,
        win32.VK_F7 => .f7,
        win32.VK_F8 => .f8,
        win32.VK_F9 => .f9,
        win32.VK_F10 => .f10,
        win32.VK_F11 => .f11,
        win32.VK_F12 => .f12,
        else => blk: {
            if (vk >= 'A' and vk <= 'Z') break :blk @enumFromInt(@as(u16, @intCast(vk - 'A')));
            if (vk >= '0' and vk <= '9') break :blk @enumFromInt(@as(u16, @intCast(vk - '0' + 26)));
            break :blk null;
        },
    };
}

fn genTextInput(vk: u32, w_param: win32.WPARAM, l_param: win32.LPARAM) ?u21 {
    // 非 Windows 构建下, vk/w_param/l_param 仅用于下方 win32 API 调用 (该分支不被生成),
    // 为避免 linter 报 unused, 用类型检查通过的赋值"使用"它们.
    const _vk = vk;
    _ = _vk;
    const _lp = l_param;
    _ = _lp;
    _ = w_param;
    if (comptime !is_windows) {
        return null;
    }
    var buf: [16]u16 = undefined;
    const len = win32.ToUnicode(@intCast(vk), @intCast(hiword(l_param) & 0x1FF), null, &buf, buf.len, 0);
    if (len <= 0) return null;
    const unit0 = buf[0];
    if (unit0 >= 0xD800 and unit0 <= 0xDBFF and len > 1) {
        const unit1 = buf[1];
        const cp: u32 = 0x10000 + ((@as(u32, unit0) - 0xD800) << 10) + (@as(u32, unit1) - 0xDC00);
        return @intCast(cp);
    }
    return @intCast(unit0);
}

fn utf8ToUtf16Le(allocator: std.mem.Allocator, s: []const u8) ![]u16 {
    const w = try allocator.alloc(u16, s.len + 1);
    errdefer allocator.free(w);
    const n = try std.unicode.utf8ToUtf16Le(w, s);
    w[n] = 0;
    return w[0 .. n + 1];
}
