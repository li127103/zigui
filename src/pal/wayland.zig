//! Wayland 窗口后端 (Linux)
//! 使用 wayland-client + xdg-shell + xkbcommon

const std = @import("std");
const pal = @import("pal.zig");
const event_mod = @import("event.zig");

const wl = @cImport({
    @cInclude("wayland-client.h");
    @cInclude("xdg-shell-client-protocol.h");
    @cInclude("xdg-decoration-client-protocol.h");
    @cInclude("text-input-unstable-v3-client-protocol.h");
    @cInclude("unistd.h");
    @cInclude("fcntl.h");
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
    maximized: bool = false,
    // xkb
    xkb_ctx: ?*xkb.xkb_context = null,
    xkb_keymap: ?*xkb.xkb_keymap = null,
    xkb_state: ?*xkb.xkb_state = null,
    // IME (text-input-v3)
    text_input_manager: ?*wl.struct_zwp_text_input_manager_v3 = null,
    text_input: ?*wl.struct_zwp_text_input_v3 = null,
    ime_cursor_rect: [4]i32 = .{ 0, 0, 0, 0 }, // x, y, w, h 缓存
    // 鼠标状态
    pointer_x: f64 = 0,
    pointer_y: f64 = 0,
    // 修饰键
    mods: event_mod.Modifiers = .{},
    // 剪贴板 (wl_data_device)
    data_device_manager: ?*wl.struct_wl_data_device_manager = null,
    data_device: ?*wl.struct_wl_data_device = null,
    clipboard_source: ?*wl.struct_wl_data_source = null,
    clipboard_text: [8192]u8 = undefined, // 本应用拥有 (复制源) 的文本
    clipboard_len: usize = 0,
    selection_offer: ?*wl.struct_wl_data_offer = null,
    selection_mime_mask: u8 = 0,
    pending_offer: ?*wl.struct_wl_data_offer = null,
    pending_mime_mask: u8 = 0,
    last_serial: u32 = 0,

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

        if (self.text_input) |ti| _ = wl.zwp_text_input_v3_destroy(ti);
        if (self.text_input_manager) |tim| _ = wl.zwp_text_input_manager_v3_destroy(tim);
        // 剪贴板资源
        if (self.selection_offer) |so| wl.wl_data_offer_destroy(so);
        if (self.pending_offer) |po| wl.wl_data_offer_destroy(po);
        if (self.clipboard_source) |cs| wl.wl_data_source_destroy(cs);
        if (self.data_device) |dd| _ = wl.wl_data_device_destroy(dd);
        if (self.data_device_manager) |ddm| _ = wl.wl_data_device_manager_destroy(ddm);
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

        // 提交 surface 以触发首次 configure
        wl.wl_surface_commit(surface);
        _ = wl.wl_display_roundtrip(self.display);

        // 固定窗口大小: 必须在首次 configure 后设置 (协议要求)
        if (!desc.resizable) {
            wl.xdg_toplevel_set_min_size(toplevel, @intCast(desc.width), @intCast(desc.height));
            wl.xdg_toplevel_set_max_size(toplevel, @intCast(desc.width), @intCast(desc.height));
            wl.wl_surface_commit(surface);
        }

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
            // IME: 创建 text_input 对象 (需 text_input_manager)
            if (self.text_input_manager) |tim| {
                if (wl.zwp_text_input_manager_v3_get_text_input(tim, seat)) |ti| {
                    _ = wl.zwp_text_input_v3_add_listener(ti, &text_input_listener, self);
                    self.text_input = ti;
                }
            }
            // 剪贴板: 创建 data_device (需 data_device_manager)
            if (self.data_device_manager) |ddm| {
                if (wl.wl_data_device_manager_get_data_device(ddm, seat)) |dd| {
                    _ = wl.wl_data_device_add_listener(dd, &data_device_listener, self);
                    self.data_device = dd;
                }
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

    /// 请求最大化窗口
    pub fn setMaximized(self: *WaylandBackend) void {
        if (self.toplevel) |tl| {
            wl.xdg_toplevel_set_maximized(tl);
            if (self.surface) |s| wl.wl_surface_commit(s);
        }
    }

    /// 取消最大化
    pub fn unsetMaximized(self: *WaylandBackend) void {
        if (self.toplevel) |tl| {
            wl.xdg_toplevel_unset_maximized(tl);
            if (self.surface) |s| wl.wl_surface_commit(s);
        }
    }

    /// 设置 IME 光标矩形 (供输入法候选窗定位)
    pub fn imeSetCursorRect(self: *WaylandBackend, x: i32, y: i32, w: i32, h: i32) void {
        self.ime_cursor_rect = .{ x, y, w, h };
        if (self.text_input) |ti| {
            wl.zwp_text_input_v3_set_cursor_rectangle(ti, x, y, w, h);
            wl.zwp_text_input_v3_commit(ti);
        }
    }

    // ── 剪贴板 (wl_data_device 原生实现) ───────────────────────────────

    /// 写入文本到系统剪贴板 (创建 data_source 并 set_selection)
    pub fn clipboardSetText(self: *WaylandBackend, text: []const u8) void {
        const ddm = self.data_device_manager orelse return;
        const dd = self.data_device orelse return;

        // 缓存文本 (其他应用粘贴时通过 source.send 事件读取)
        const n = @min(text.len, self.clipboard_text.len);
        @memcpy(self.clipboard_text[0..n], text[0..n]);
        self.clipboard_len = n;

        // 销毁旧 source (若有)
        if (self.clipboard_source) |old| {
            wl.wl_data_source_destroy(old);
            self.clipboard_source = null;
        }

        const source = wl.wl_data_device_manager_create_data_source(ddm) orelse return;
        _ = wl.wl_data_source_add_listener(source, &data_source_listener, self);
        wl.wl_data_source_offer(source, "text/plain;charset=utf-8");
        wl.wl_data_source_offer(source, "text/plain");
        wl.wl_data_source_offer(source, "UTF8_STRING");
        wl.wl_data_device_set_selection(dd, source, self.last_serial);
        self.clipboard_source = source;
        _ = wl.wl_display_flush(self.display);
    }

    /// 读取系统剪贴板文本 (同步阻塞, 带超时)。调用者拥有返回内存。
    pub fn clipboardGetText(self: *WaylandBackend, allocator: std.mem.Allocator) ?[]u8 {
        const offer = self.selection_offer orelse return null;
        const mime = bestMime(self.selection_mime_mask) orelse return null;

        var fds: [2]c_int = undefined;
        if (wl.pipe(&fds) != 0) return null;

        wl.wl_data_offer_receive(offer, mime, fds[1]);
        _ = wl.wl_display_flush(self.display);
        _ = wl.close(fds[1]); // 关闭写端, 读端才能收到 EOF

        // 读端设为非阻塞, 通过 poll 等待数据 (防止挂死)
        _ = wl.fcntl(fds[0], wl.F_SETFL, wl.O_NONBLOCK);

        var out: std.ArrayList(u8) = .empty;
        var buf: [4096]u8 = undefined;
        var attempts: usize = 0;
        while (attempts < 8) : (attempts += 1) {
            var pfd = [_]std.posix.pollfd{.{ .fd = fds[0], .events = std.posix.POLL.IN, .revents = 0 }};
            const pn = std.posix.poll(&pfd, 50) catch 0; // 50ms × 8 = 400ms 上限
            if (pn <= 0) {
                if (out.items.len > 0) break; // 已有部分数据且超时
                continue;
            }
            const r = wl.read(fds[0], &buf, buf.len);
            if (r <= 0) break; // EOF 或 EAGAIN
            out.appendSlice(allocator, buf[0..@intCast(r)]) catch break;
        }
        _ = wl.close(fds[0]);

        if (out.items.len == 0) {
            out.deinit(allocator);
            return null;
        }
        return out.toOwnedSlice(allocator) catch null;
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
    } else if (std.mem.eql(u8, iface, "zwp_text_input_manager_v3")) {
        self.text_input_manager = @ptrCast(wl.wl_registry_bind(registry.?, name, &wl.zwp_text_input_manager_v3_interface, @min(version, 2)));
    } else if (std.mem.eql(u8, iface, "wl_data_device_manager")) {
        self.data_device_manager = @ptrCast(wl.wl_registry_bind(registry.?, name, &wl.wl_data_device_manager_interface, @min(version, 3)));
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
    states: ?*wl.struct_wl_array,
) callconv(.c) void {
    const self: *WaylandBackend = @ptrCast(@alignCast(data.?));
    if (width > 0 and height > 0) {
        self.width = @intCast(width);
        self.height = @intCast(height);
        self.pushEvent(.{ .resize = .{ .width = self.width, .height = self.height } });
    }
    // 解析 states 数组检测最大化状态
    if (states) |arr| {
        const count = arr.size / @sizeOf(u32);
        if (count > 0) {
            const data_ptr: [*]const u32 = @ptrCast(@alignCast(arr.data));
            const slice = data_ptr[0..count];
            var is_maximized = false;
            for (slice) |s| {
                if (s == wl.XDG_TOPLEVEL_STATE_MAXIMIZED) {
                    is_maximized = true;
                    break;
                }
            }
            if (is_maximized != self.maximized) {
                self.maximized = is_maximized;
                self.pushEvent(.{ .maximize = .{ .maximized = is_maximized } });
            }
        }
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
    data: ?*anyopaque,
    _: ?*wl.struct_wl_keyboard,
    format: u32,
    fd: i32,
    size: u32,
) callconv(.c) void {
    const self: *WaylandBackend = @ptrCast(@alignCast(data.?));

    if (format != wl.WL_KEYBOARD_KEYMAP_FORMAT_XKB_V1) {
        _ = std.os.linux.close(fd);
        return;
    }

    // mmap 读取 keymap 字符串 (以 null 结尾, size 含结尾符)
    const keymap_bytes = std.posix.mmap(null, @intCast(size), .{ .READ = true }, .{ .TYPE = .SHARED }, fd, 0) catch {
        _ = std.os.linux.close(fd);
        return;
    };
    // 映射已持有文件引用, 可立即关闭 fd
    _ = std.os.linux.close(fd);
    defer std.posix.munmap(keymap_bytes);

    const ctx = self.xkb_ctx orelse return;

    // 释放旧的 state/keymap (keymap 可能因键盘热插拔而更新)
    if (self.xkb_state) |s| {
        xkb.xkb_state_unref(s);
        self.xkb_state = null;
    }
    if (self.xkb_keymap) |km| {
        xkb.xkb_keymap_unref(km);
        self.xkb_keymap = null;
    }

    const keymap = xkb.xkb_keymap_new_from_string(
        ctx,
        keymap_bytes.ptr,
        xkb.XKB_KEYMAP_FORMAT_TEXT_V1,
        xkb.XKB_KEYMAP_COMPILE_NO_FLAGS,
    ) orelse return;

    const state = xkb.xkb_state_new(keymap) orelse {
        xkb.xkb_keymap_unref(keymap);
        return;
    };

    self.xkb_keymap = keymap;
    self.xkb_state = state;
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
    serial: u32,
    _: u32,
    key: u32,
    state: u32,
) callconv(.c) void {
    const self: *WaylandBackend = @ptrCast(@alignCast(data.?));
    self.last_serial = serial;
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

// ── Text Input (IME) Listener ─────────────────────────────────────────────

/// 将 C 字符串拷贝进 IME 事件内联缓冲, 返回实际长度
fn copyImeText(text: ?[*:0]const u8, buf: *[event_mod.max_ime_text]u8) u32 {
    const src = std.mem.span(text orelse return 0);
    const n = @min(src.len, buf.len);
    @memcpy(buf[0..n], src[0..n]);
    return @intCast(n);
}

fn textInputEnter(
    data: ?*anyopaque,
    ti: ?*wl.struct_zwp_text_input_v3,
    _: ?*wl.struct_wl_surface,
) callconv(.c) void {
    const self: *WaylandBackend = @ptrCast(@alignCast(data.?));
    const t = ti orelse return;
    // 激活文本输入: enable + 光标矩形 + commit
    wl.zwp_text_input_v3_enable(t);
    wl.zwp_text_input_v3_set_cursor_rectangle(t, self.ime_cursor_rect[0], self.ime_cursor_rect[1], self.ime_cursor_rect[2], self.ime_cursor_rect[3]);
    wl.zwp_text_input_v3_commit(t);
}

fn textInputLeave(
    data: ?*anyopaque,
    ti: ?*wl.struct_zwp_text_input_v3,
    _: ?*wl.struct_wl_surface,
) callconv(.c) void {
    const self: *WaylandBackend = @ptrCast(@alignCast(data.?));
    const t = ti orelse return;
    wl.zwp_text_input_v3_disable(t);
    wl.zwp_text_input_v3_commit(t);
    // 组合结束: 推送空 preedit
    self.pushEvent(.{ .ime_preedit = .{ .text = undefined, .len = 0, .cursor_begin = 0, .cursor_end = 0 } });
}

fn textInputPreeditString(
    data: ?*anyopaque,
    _: ?*wl.struct_zwp_text_input_v3,
    text: ?[*:0]const u8,
    cursor_begin: i32,
    cursor_end: i32,
) callconv(.c) void {
    const self: *WaylandBackend = @ptrCast(@alignCast(data.?));
    var buf: [event_mod.max_ime_text]u8 = undefined;
    const len = copyImeText(text, &buf);
    self.pushEvent(.{ .ime_preedit = .{ .text = buf, .len = len, .cursor_begin = cursor_begin, .cursor_end = cursor_end } });
}

fn textInputCommitString(
    data: ?*anyopaque,
    _: ?*wl.struct_zwp_text_input_v3,
    text: ?[*:0]const u8,
) callconv(.c) void {
    const self: *WaylandBackend = @ptrCast(@alignCast(data.?));
    var buf: [event_mod.max_ime_text]u8 = undefined;
    const len = copyImeText(text, &buf);
    if (len > 0) {
        self.pushEvent(.{ .ime_commit = .{ .text = buf, .len = len } });
    }
}

fn textInputDeleteSurroundingText(
    data: ?*anyopaque,
    _: ?*wl.struct_zwp_text_input_v3,
    before_length: u32,
    after_length: u32,
) callconv(.c) void {
    const self: *WaylandBackend = @ptrCast(@alignCast(data.?));
    self.pushEvent(.{ .ime_delete = .{ .before_length = before_length, .after_length = after_length } });
}

fn textInputDone(
    data: ?*anyopaque,
    _: ?*wl.struct_zwp_text_input_v3,
    _: u32,
) callconv(.c) void {
    // done 表示 IME 状态更新批次结束 (preedit/commit/delete 已到达)。
    // 不能在此重新 commit: KWin 对每个 commit 都回 done, 重提交会造成
    // commit->done->commit 无限循环, 干扰输入法激活。
    _ = data;
}

fn textInputAction(
    _: ?*anyopaque,
    _: ?*wl.struct_zwp_text_input_v3,
    _: u32,
    _: u32,
) callconv(.c) void {}

fn textInputLanguage(
    _: ?*anyopaque,
    _: ?*wl.struct_zwp_text_input_v3,
    _: ?[*:0]const u8,
) callconv(.c) void {}

fn textInputPreeditHint(
    _: ?*anyopaque,
    _: ?*wl.struct_zwp_text_input_v3,
    _: u32,
    _: u32,
    _: u32,
) callconv(.c) void {}

const text_input_listener = wl.zwp_text_input_v3_listener{
    .enter = textInputEnter,
    .leave = textInputLeave,
    .preedit_string = textInputPreeditString,
    .commit_string = textInputCommitString,
    .delete_surrounding_text = textInputDeleteSurroundingText,
    .done = textInputDone,
    .action = textInputAction,
    .language = textInputLanguage,
    .preedit_hint = textInputPreeditHint,
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
    serial: u32,
    _: u32,
    button: u32,
    state: u32,
) callconv(.c) void {
    const self: *WaylandBackend = @ptrCast(@alignCast(data.?));
    self.last_serial = serial;
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

// ── 剪贴板 (wl_data_device) Listener ─────────────────────────────────────

/// MIME 类型位掩码 (优先级从高到低)
const MIME_UTF8: u8 = 1; // text/plain;charset=utf-8
const MIME_PLAIN: u8 = 2; // text/plain
const MIME_UTF8_STRING: u8 = 4; // UTF8_STRING
const MIME_TEXT: u8 = 8; // TEXT / STRING

fn mimeBit(mime: []const u8) u8 {
    if (std.mem.eql(u8, mime, "text/plain;charset=utf-8")) return MIME_UTF8;
    if (std.mem.eql(u8, mime, "text/plain")) return MIME_PLAIN;
    if (std.mem.eql(u8, mime, "UTF8_STRING")) return MIME_UTF8_STRING;
    if (std.mem.eql(u8, mime, "TEXT") or std.mem.eql(u8, mime, "STRING")) return MIME_TEXT;
    return 0;
}

fn bestMime(mask: u8) ?[*:0]const u8 {
    if (mask & MIME_UTF8 != 0) return "text/plain;charset=utf-8";
    if (mask & MIME_PLAIN != 0) return "text/plain";
    if (mask & MIME_UTF8_STRING != 0) return "UTF8_STRING";
    if (mask & MIME_TEXT != 0) return "TEXT";
    return null;
}

// data_offer: 跟踪 offer 提供的 MIME 类型
fn dataOfferOffer(
    data: ?*anyopaque,
    offer: ?*wl.struct_wl_data_offer,
    mime_type: ?[*:0]const u8,
) callconv(.c) void {
    const self: *WaylandBackend = @ptrCast(@alignCast(data.?));
    if (offer != self.pending_offer) return;
    const mime = std.mem.span(mime_type orelse return);
    self.pending_mime_mask |= mimeBit(mime);
}

fn dataOfferSourceActions(
    _: ?*anyopaque,
    _: ?*wl.struct_wl_data_offer,
    _: u32,
) callconv(.c) void {}

fn dataOfferAction(
    _: ?*anyopaque,
    _: ?*wl.struct_wl_data_offer,
    _: u32,
) callconv(.c) void {}

const data_offer_listener = wl.wl_data_offer_listener{
    .offer = dataOfferOffer,
    .source_actions = dataOfferSourceActions,
    .action = dataOfferAction,
};

// data_device: 接收 offer 与 selection 变化
fn dataDeviceDataOffer(
    data: ?*anyopaque,
    _: ?*wl.struct_wl_data_device,
    offer: ?*wl.struct_wl_data_offer,
) callconv(.c) void {
    const self: *WaylandBackend = @ptrCast(@alignCast(data.?));
    // 销毁未被消费的旧 pending offer
    if (self.pending_offer) |old| wl.wl_data_offer_destroy(old);
    self.pending_offer = offer;
    self.pending_mime_mask = 0;
    if (offer) |o| {
        _ = wl.wl_data_offer_add_listener(o, &data_offer_listener, self);
    }
}

fn dataDeviceSelection(
    data: ?*anyopaque,
    _: ?*wl.struct_wl_data_device,
    offer: ?*wl.struct_wl_data_offer,
) callconv(.c) void {
    const self: *WaylandBackend = @ptrCast(@alignCast(data.?));
    // 销毁旧 selection offer
    if (self.selection_offer) |old| {
        if (old != offer) wl.wl_data_offer_destroy(old);
    }
    // pending offer 转为当前 selection
    if (offer == self.pending_offer) {
        self.selection_offer = offer;
        self.selection_mime_mask = self.pending_mime_mask;
        self.pending_offer = null;
        self.pending_mime_mask = 0;
    } else {
        self.selection_offer = offer;
        self.selection_mime_mask = 0;
    }
}

fn dataDeviceEnter(
    data: ?*anyopaque,
    _: ?*wl.struct_wl_data_device,
    _: u32,
    _: ?*wl.struct_wl_surface,
    _: wl.wl_fixed_t,
    _: wl.wl_fixed_t,
    _: ?*wl.struct_wl_data_offer,
) callconv(.c) void {
    // 不支持拖放: 销毁 pending offer (DnD 用途)
    const self: *WaylandBackend = @ptrCast(@alignCast(data.?));
    if (self.pending_offer) |old| {
        wl.wl_data_offer_destroy(old);
        self.pending_offer = null;
        self.pending_mime_mask = 0;
    }
}

fn dataDeviceLeave(
    _: ?*anyopaque,
    _: ?*wl.struct_wl_data_device,
) callconv(.c) void {}

fn dataDeviceMotion(
    _: ?*anyopaque,
    _: ?*wl.struct_wl_data_device,
    _: u32,
    _: wl.wl_fixed_t,
    _: wl.wl_fixed_t,
) callconv(.c) void {}

fn dataDeviceDrop(
    _: ?*anyopaque,
    _: ?*wl.struct_wl_data_device,
) callconv(.c) void {}

const data_device_listener = wl.wl_data_device_listener{
    .data_offer = dataDeviceDataOffer,
    .enter = dataDeviceEnter,
    .leave = dataDeviceLeave,
    .motion = dataDeviceMotion,
    .drop = dataDeviceDrop,
    .selection = dataDeviceSelection,
};

// data_source: 本应用作为复制源, 响应其他应用的粘贴请求
fn dataSourceTarget(
    _: ?*anyopaque,
    _: ?*wl.struct_wl_data_source,
    _: ?[*:0]const u8,
) callconv(.c) void {}

fn dataSourceSend(
    data: ?*anyopaque,
    _: ?*wl.struct_wl_data_source,
    _: ?[*:0]const u8,
    fd: i32,
) callconv(.c) void {
    const self: *WaylandBackend = @ptrCast(@alignCast(data.?));
    // 将缓存文本写入请求方的管道
    var written: usize = 0;
    while (written < self.clipboard_len) {
        const n = wl.write(fd, self.clipboard_text[written..].ptr, self.clipboard_len - written);
        if (n <= 0) break;
        written += @intCast(n);
    }
    _ = wl.close(fd);
}

fn dataSourceCancelled(
    data: ?*anyopaque,
    source: ?*wl.struct_wl_data_source,
) callconv(.c) void {
    const self: *WaylandBackend = @ptrCast(@alignCast(data.?));
    if (source) |s| wl.wl_data_source_destroy(s);
    if (self.clipboard_source == source) self.clipboard_source = null;
}

fn dataSourceDndDropPerformed(
    _: ?*anyopaque,
    _: ?*wl.struct_wl_data_source,
) callconv(.c) void {}

fn dataSourceDndFinished(
    _: ?*anyopaque,
    _: ?*wl.struct_wl_data_source,
) callconv(.c) void {}

fn dataSourceAction(
    _: ?*anyopaque,
    _: ?*wl.struct_wl_data_source,
    _: u32,
) callconv(.c) void {}

const data_source_listener = wl.wl_data_source_listener{
    .target = dataSourceTarget,
    .send = dataSourceSend,
    .cancelled = dataSourceCancelled,
    .dnd_drop_performed = dataSourceDndDropPerformed,
    .dnd_finished = dataSourceDndFinished,
    .action = dataSourceAction,
};
