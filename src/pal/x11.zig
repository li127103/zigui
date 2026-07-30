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
    net_wm_state: u32 = 0,
    net_wm_state_maximized_vert: u32 = 0,
    net_wm_state_maximized_horz: u32 = 0,
    maximized: bool = false,
    /// 高 DPI 缩放因子 (来自 Xft.dpi 资源或屏幕物理尺寸; 默认 1.0)
    scale_factor: f32 = 1.0,
    // Xdnd 文件拖放 atoms
    xdnd_aware: u32 = 0,
    xdnd_enter: u32 = 0,
    xdnd_leave: u32 = 0,
    xdnd_position: u32 = 0,
    xdnd_drop: u32 = 0,
    xdnd_finished: u32 = 0,
    xdnd_status: u32 = 0,
    xdnd_selection: u32 = 0,
    xdnd_type_list: u32 = 0,
    text_uri_list: u32 = 0,
    // Xdnd 拖放状态
    xdnd_source: u32 = 0, // 拖放源窗口
    xdnd_version: u32 = 0,
    xdnd_has_uri: bool = false, // 源是否提供 text/uri-list
    drop_x: i32 = 0,
    drop_y: i32 = 0,
    // xkbcommon
    xkb_ctx: *xkb.xkb_context,
    xkb_keymap: ?*xkb.xkb_keymap = null,
    xkb_state: ?*xkb.xkb_state = null,
    /// 当前修饰键状态 (由 xkb_state 跟踪, 每次按键事件后更新)
    mods: event_mod.Modifiers = .{},
    // 事件队列引用 (pollEvents 时设置, 供 pushEvent 使用)
    event_queue: ?*pal.EventQueue = null,
    // 鼠标状态
    mouse_x: i32 = 0,
    mouse_y: i32 = 0,
    // 光标
    cursor_font: u32 = 0,
    cursors: [@typeInfo(pal.CursorType).@"enum".fields.len]u32 = .{0} ** @typeInfo(pal.CursorType).@"enum".fields.len,
    current_cursor: pal.CursorType = .arrow,
    // 子窗口 (额外的顶层窗口, 不含主窗口)
    sub_windows: std.AutoHashMapUnmanaged(u32, SubWindowData) = .{},

    /// 子窗口数据
    const SubWindowData = struct {
        window_id: u32,
        title: []const u8,
        width: u32,
        height: u32,
        visible: bool,
        // 子窗口的鼠标状态
        mouse_x: i32 = 0,
        mouse_y: i32 = 0,
        // 子窗口的修饰键状态 (共享 xkb_state, 但记录当前窗口的)
        focused: bool = false,
    };

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

        var backend: X11Backend = .{
            .allocator = allocator,
            .conn = conn,
            .screen = screen,
            .xkb_ctx = xkb_ctx,
            .xkb_keymap = xkb_keymap,
            .xkb_state = xkb_state,
        };
        backend.scale_factor = backend.detectScaleFactor();
        backend.initCursors();
        return backend;
    }

    pub fn deinit(self: *X11Backend) void {
        for (0..self.cursors.len) |i| {
            if (self.cursors[i] != 0) _ = xcb.xcb_free_cursor(self.conn, self.cursors[i]);
        }
        if (self.cursor_font != 0) _ = xcb.xcb_close_font(self.conn, self.cursor_font);
        if (self.xkb_state) |s| xkb.xkb_state_unref(s);
        if (self.xkb_keymap) |km| xkb.xkb_keymap_unref(km);
        xkb.xkb_context_unref(self.xkb_ctx);
        // 清理子窗口
        var it = self.sub_windows.valueIterator();
        while (it.next()) |sw| {
            self.allocator.free(sw.title);
            _ = xcb.xcb_destroy_window(self.conn, sw.window_id);
        }
        self.sub_windows.deinit(self.allocator);
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
                xcb.XCB_EVENT_MASK_FOCUS_CHANGE |
                xcb.XCB_EVENT_MASK_PROPERTY_CHANGE,
            self.screen.white_pixel,
        };

        // 窗口按 *物理* 像素创建: 逻辑尺寸 × 缩放因子 (HiDPI 清晰化).
        // 框架内部 fb_width/fb_height 仍保持逻辑语义, Vulkan 会把逻辑缓冲放大到
        // 物理 swapchain (逻辑 × content_scale). 这样 X11 与 Wayland 行为一致.
        const phys_w: u32 = @intFromFloat(@as(f32, @floatFromInt(desc.width)) * self.scale_factor);
        const phys_h: u32 = @intFromFloat(@as(f32, @floatFromInt(desc.height)) * self.scale_factor);

        _ = xcb.xcb_create_window(
            self.conn,
            xcb.XCB_COPY_FROM_PARENT,
            wid,
            self.screen.root,
            0,
            0,
            @intCast(phys_w),
            @intCast(phys_h),
            0,
            xcb.XCB_WINDOW_CLASS_INPUT_OUTPUT,
            self.screen.root_visual,
            mask,
            &values,
        );

        // 设置 WM_PROTOCOLS (WM_DELETE_WINDOW)
        self.wm_protocols = internAtom(self.conn, "WM_PROTOCOLS");
        self.wm_delete_window = internAtom(self.conn, "WM_DELETE_WINDOW");
        self.net_wm_state = internAtom(self.conn, "_NET_WM_STATE");
        self.net_wm_state_maximized_vert = internAtom(self.conn, "_NET_WM_STATE_MAXIMIZED_VERT");
        self.net_wm_state_maximized_horz = internAtom(self.conn, "_NET_WM_STATE_MAXIMIZED_HORZ");
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

        // 初始化 Xdnd 文件拖放 (声明 XdndAware 版本 5)
        self.initXdnd(wid);

        // 设置 WM_NORMAL_HINTS (尺寸约束)
        {
            var hints: [18]u32 = .{0} ** 18;
            // flags: PSize | PMinSize | PMaxSize
            hints[0] = 0x08 | 0x10 | 0x20;
            // width, height (index 2, 3) - 物理像素 (与窗口创建一致)
            hints[2] = phys_w;
            hints[3] = phys_h;
            if (!desc.resizable) {
                // 固定大小: min = max = 窗口尺寸 (物理)
                hints[4] = phys_w; // min_width
                hints[5] = phys_h; // min_height
                hints[6] = phys_w; // max_width
                hints[7] = phys_h; // max_height
            } else {
                hints[4] = desc.min_width orelse 1;
                hints[5] = desc.min_height orelse 1;
                hints[6] = desc.max_width orelse 0;
                hints[7] = desc.max_height orelse 0;
            }
            const wm_normal_hints = internAtom(self.conn, "WM_NORMAL_HINTS");
            if (wm_normal_hints != 0) {
                _ = xcb.xcb_change_property(
                    self.conn,
                    xcb.XCB_PROP_MODE_REPLACE,
                    wid,
                    wm_normal_hints,
                    wm_normal_hints, // type = WM_SIZE_HINTS
                    32,
                    18,
                    &hints,
                );
            }
        }

        if (desc.visible) {
            _ = xcb.xcb_map_window(self.conn, wid);
        }
        _ = xcb.xcb_flush(self.conn);

        self.window_id = wid;

        return .{
            .handle = .{ .x11_window = wid },
            .size = .{ .width = desc.width, .height = desc.height },
            .scale_factor = self.scale_factor,
        };
    }

    /// 创建一个额外的顶层子窗口
    pub fn createSubWindow(self: *X11Backend, title: []const u8, width: u32, height: u32) !u32 {
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
                xcb.XCB_EVENT_MASK_FOCUS_CHANGE |
                xcb.XCB_EVENT_MASK_PROPERTY_CHANGE,
            self.screen.*.white_pixel,
        };

        // 子窗口同样按物理像素创建 (逻辑 × scale), 与主窗口一致
        const sub_phys_w: u32 = @intFromFloat(@as(f32, @floatFromInt(width)) * self.scale_factor);
        const sub_phys_h: u32 = @intFromFloat(@as(f32, @floatFromInt(height)) * self.scale_factor);

        _ = xcb.xcb_create_window(
            self.conn,
            xcb.XCB_COPY_FROM_PARENT,
            wid,
            self.screen.*.root,
            100,
            100,
            @intCast(sub_phys_w),
            @intCast(sub_phys_h),
            0,
            xcb.XCB_WINDOW_CLASS_INPUT_OUTPUT,
            self.screen.*.root_visual,
            @intCast(mask),
            &values,
        );

        // 设置 WM_DELETE_WINDOW
        const protocols_cookie = xcb.xcb_intern_atom(self.conn, 0, 12, "WM_PROTOCOLS");
        const protocols_reply = xcb.xcb_intern_atom_reply(self.conn, protocols_cookie, null);
        const delete_cookie = xcb.xcb_intern_atom(self.conn, 0, 16, "WM_DELETE_WINDOW");
        const delete_reply = xcb.xcb_intern_atom_reply(self.conn, delete_cookie, null);

        if (protocols_reply != null and delete_reply != null) {
            const wm_protocols = protocols_reply.*.atom;
            const wm_delete_window = delete_reply.*.atom;
            _ = xcb.xcb_change_property(
                self.conn,
                xcb.XCB_PROP_MODE_REPLACE,
                wid,
                wm_protocols,
                xcb.XCB_ATOM_ATOM,
                32,
                1,
                &wm_delete_window,
            );
        }

        // 设置窗口标题
        _ = xcb.xcb_change_property(
            self.conn,
            xcb.XCB_PROP_MODE_REPLACE,
            wid,
            xcb.XCB_ATOM_WM_NAME,
            xcb.XCB_ATOM_STRING,
            8,
            @intCast(title.len),
            title.ptr,
        );

        // 显示窗口
        _ = xcb.xcb_map_window(self.conn, wid);
        _ = xcb.xcb_flush(self.conn);

        // 记录子窗口
        const title_dup = try self.allocator.dupe(u8, title);
        try self.sub_windows.put(self.allocator, wid, .{
            .window_id = wid,
            .title = title_dup,
            .width = width,
            .height = height,
            .visible = true,
        });

        return wid;
    }

    /// 销毁子窗口
    pub fn destroySubWindow(self: *X11Backend, wid: u32) void {
        if (self.sub_windows.get(wid)) |sw| {
            self.allocator.free(sw.title);
            _ = self.sub_windows.remove(wid);
        }
        _ = xcb.xcb_destroy_window(self.conn, wid);
        _ = xcb.xcb_flush(self.conn);
    }

    /// 显示子窗口
    pub fn showSubWindow(self: *X11Backend, wid: u32) void {
        if (self.sub_windows.getPtr(wid)) |sw| {
            sw.visible = true;
            _ = xcb.xcb_map_window(self.conn, wid);
            _ = xcb.xcb_flush(self.conn);
        }
    }

    /// 隐藏子窗口
    pub fn hideSubWindow(self: *X11Backend, wid: u32) void {
        if (self.sub_windows.getPtr(wid)) |sw| {
            sw.visible = false;
            _ = xcb.xcb_unmap_window(self.conn, wid);
            _ = xcb.xcb_flush(self.conn);
        }
    }

    /// 设置子窗口标题
    pub fn setSubWindowTitle(self: *X11Backend, wid: u32, title: []const u8) void {
        if (self.sub_windows.getPtr(wid)) |sw| {
            self.allocator.free(sw.title);
            const title_dup = self.allocator.dupe(u8, title) catch return;
            sw.title = title_dup;
            _ = xcb.xcb_change_property(
                self.conn,
                xcb.XCB_PROP_MODE_REPLACE,
                wid,
                xcb.XCB_ATOM_WM_NAME,
                xcb.XCB_ATOM_STRING,
                8,
                @intCast(title.len),
                title.ptr,
            );
            _ = xcb.xcb_flush(self.conn);
        }
    }

    /// 调整子窗口大小
    pub fn resizeSubWindow(self: *X11Backend, wid: u32, width: u32, height: u32) void {
        if (self.sub_windows.getPtr(wid)) |sw| {
            sw.width = width;
            sw.height = height;
            const values = [_]u32{ width, height };
            _ = xcb.xcb_configure_window(
                self.conn,
                wid,
                xcb.XCB_CONFIG_WINDOW_WIDTH | xcb.XCB_CONFIG_WINDOW_HEIGHT,
                &values,
            );
            _ = xcb.xcb_flush(self.conn);
        }
    }

    /// 移动子窗口
    pub fn moveSubWindow(self: *X11Backend, wid: u32, x: i32, y: i32) void {
        if (self.sub_windows.getPtr(wid)) |sw| {
            _ = sw;
            const values = [_]i32{ x, y };
            _ = xcb.xcb_configure_window(
                self.conn,
                wid,
                xcb.XCB_CONFIG_WINDOW_X | xcb.XCB_CONFIG_WINDOW_Y,
                &values,
            );
            _ = xcb.xcb_flush(self.conn);
        }
    }

    /// 最小化子窗口 (iconify)
    pub fn iconifySubWindow(self: *X11Backend, wid: u32) void {
        const wm_change_state_cookie = xcb.xcb_intern_atom(self.conn, 0, 15, "WM_CHANGE_STATE");
        const wm_change_state_reply = xcb.xcb_intern_atom_reply(self.conn, wm_change_state_cookie, null) orelse return;
        const wm_change_state = wm_change_state_reply.*.atom;

        const data: [5]u32 = .{ 3, 0, 0, 0, 0 }; // data[0] = 3 = IconicState (ICCCM)
        _ = xcb.xcb_send_event(
            self.conn,
            0,
            wid,
            xcb.XCB_EVENT_MASK_STRUCTURE_NOTIFY,
            @ptrCast(&xcb.xcb_client_message_event_t{
                .response_type = xcb.XCB_CLIENT_MESSAGE,
                .format = 32,
                .window = wid,
                .type = wm_change_state,
                .data = .{ .data32 = data },
            }),
        );
        _ = xcb.xcb_flush(self.conn);
    }

    /// 设置子窗口为 transient (父窗口之上，无任务栏图标)
    pub fn setSubWindowTransientFor(self: *X11Backend, wid: u32, parent_wid: u32) void {
        const wm_transient_for_cookie = xcb.xcb_intern_atom(self.conn, 0, 17, "WM_TRANSIENT_FOR");
        const wm_transient_for_reply = xcb.xcb_intern_atom_reply(self.conn, wm_transient_for_cookie, null) orelse return;
        const wm_transient_for = wm_transient_for_reply.*.atom;

        _ = xcb.xcb_change_property(
            self.conn,
            xcb.XCB_PROP_MODE_REPLACE,
            wid,
            wm_transient_for,
            xcb.XCB_ATOM_WINDOW,
            32,
            1,
            &parent_wid,
        );
        _ = xcb.xcb_flush(self.conn);
    }

    /// 当前高 DPI 缩放因子
    pub fn getScaleFactor(self: *const X11Backend) f32 {
        return self.scale_factor;
    }

    /// 初始化光标 (使用 X11 标准 cursor font)
    fn initCursors(self: *X11Backend) void {
        const font_name = "cursor";
        const font = xcb.xcb_generate_id(self.conn);
        _ = xcb.xcb_open_font(self.conn, font, @intCast(font_name.len), font_name);
        self.cursor_font = font;

        const glyph_map = .{
            .arrow = @as(u16, 68), // XC_left_ptr
            .ibeam = @as(u16, 152), // XC_xterm
            .crosshair = @as(u16, 34), // XC_crosshair
            .pointing_hand = @as(u16, 60), // XC_hand2
            .resize_ew = @as(u16, 108), // XC_sb_h_double_arrow
            .resize_ns = @as(u16, 116), // XC_sb_v_double_arrow
            .resize_nwse = @as(u16, 134), // XC_top_left_corner
            .resize_nesw = @as(u16, 136), // XC_top_right_corner
            .not_allowed = @as(u16, 0), // XC_X_cursor
            .wait = @as(u16, 150), // XC_watch
        };

        inline for (@typeInfo(pal.CursorType).@"enum".fields) |field| {
            const cursor_id = xcb.xcb_generate_id(self.conn);
            const glyph: u16 = @field(glyph_map, field.name);
            _ = xcb.xcb_create_glyph_cursor(
                self.conn,
                cursor_id,
                font,
                font,
                glyph,
                glyph + 1,
                0,
                0,
                0,
                0xFFFF,
                0xFFFF,
                0xFFFF,
            );
            self.cursors[field.value] = cursor_id;
        }
    }

    /// 设置鼠标光标
    pub fn setCursor(self: *X11Backend, cursor_type: pal.CursorType) void {
        if (self.window_id == 0) return;
        const idx = @intFromEnum(cursor_type);
        if (idx >= self.cursors.len or self.cursors[idx] == 0) return;
        if (self.current_cursor == cursor_type) return;

        const cursor = self.cursors[idx];
        const mask = xcb.XCB_CW_CURSOR;
        const values = [_]u32{cursor};
        _ = xcb.xcb_change_window_attributes(
            self.conn,
            self.window_id,
            mask,
            &values,
        );
        _ = xcb.xcb_flush(self.conn);
        self.current_cursor = cursor_type;
    }

    /// 检测缩放因子: 优先读取根窗口 RESOURCE_MANAGER 中的 Xft.dpi (基准 96),
    /// 缺失时回退到屏幕像素/物理尺寸比值。
    fn detectScaleFactor(self: *X11Backend) f32 {
        if (self.queryXftDpi()) |dpi| {
            if (dpi > 0) return @max(1.0, dpi / 96.0);
        }
        const w_mm = self.screen.width_in_millimeters;
        const h_mm = self.screen.height_in_millimeters;
        if (w_mm > 0 and h_mm > 0) {
            const dpi_x = @as(f32, @floatFromInt(self.screen.width_in_pixels)) / (@as(f32, @floatFromInt(w_mm)) / 25.4);
            const dpi_y = @as(f32, @floatFromInt(self.screen.height_in_pixels)) / (@as(f32, @floatFromInt(h_mm)) / 25.4);
            const dpi = (dpi_x + dpi_y) * 0.5;
            if (dpi > 0) return @max(1.0, dpi / 96.0);
        }
        return 1.0;
    }

    /// 从根窗口 RESOURCE_MANAGER 属性解析 Xft.dpi (返回 null 表示未设置)
    fn queryXftDpi(self: *X11Backend) ?f32 {
        const res_atom = internAtom(self.conn, "RESOURCE_MANAGER");
        const str_atom = internAtom(self.conn, "STRING");
        if (res_atom == 0) return null;
        const cookie = xcb.xcb_get_property(
            self.conn,
            0,
            self.screen.root,
            res_atom,
            if (str_atom != 0) str_atom else xcb.XCB_ATOM_ANY,
            0,
            0x10000,
        );
        var err: [*c]xcb.xcb_generic_error_t = null;
        const reply = xcb.xcb_get_property_reply(self.conn, cookie, &err);
        defer if (reply != null) std.c.free(reply);
        if (reply == null or err != null) return null;
        const len = xcb.xcb_get_property_value_length(reply);
        if (len <= 0) return null;
        const data: [*]const u8 = @ptrCast(xcb.xcb_get_property_value(reply));
        const resources = data[0..@intCast(len)];
        const key = "Xft.dpi:\t";
        const start = (std.mem.indexOf(u8, resources, key) orelse return null) + key.len;
        var end = start;
        while (end < resources.len and resources[end] != '\n' and resources[end] != 0) : (end += 1) {}
        return std.fmt.parseFloat(f32, resources[start..end]) catch return null;
    }

    pub fn pollEvents(self: *X11Backend, queue: *pal.EventQueue, allocator: std.mem.Allocator) !void {
        _ = allocator;
        self.event_queue = queue;
        _ = xcb.xcb_flush(self.conn);
        while (xcb.xcb_poll_for_event(self.conn)) |ev| {
            defer std.c.free(ev);
            if (try self.translateEvent(ev)) |translated| {
                try queue.push(self.allocator, translated);
            }
        }
    }

    /// 推送事件到队列 (供需要产生多个事件的翻译函数使用, 如按键→key+text_input)
    fn pushEvent(self: *X11Backend, ev: event_mod.Event) void {
        if (self.event_queue) |q| {
            q.push(self.allocator, ev) catch {};
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
        // 从事件中提取事件窗口 ID (使用 key_press_event 结构, 大多数事件 event 字段位置相同)
        const key_ev = @as([*c]xcb.xcb_key_press_event_t, @ptrCast(ev));
        const wid: u32 = key_ev.*.event;
        return switch (response_type) {
            xcb.XCB_KEY_PRESS, xcb.XCB_KEY_RELEASE => self.translateKeyEvent(ev, wid),
            xcb.XCB_BUTTON_PRESS, xcb.XCB_BUTTON_RELEASE => self.translateButtonEvent(ev, wid),
            xcb.XCB_MOTION_NOTIFY => self.translateMotionEvent(ev, wid),
            xcb.XCB_CONFIGURE_NOTIFY => self.translateConfigureEvent(ev, wid),
            xcb.XCB_PROPERTY_NOTIFY => self.translatePropertyNotify(ev, wid),
            xcb.XCB_CLIENT_MESSAGE => self.translateClientMessage(ev, wid),
            xcb.XCB_FOCUS_IN => .{ .focus_change = .{ .window_id = wid, .focused = true } },
            xcb.XCB_FOCUS_OUT => .{ .focus_change = .{ .window_id = wid, .focused = false } },
            xcb.XCB_ENTER_NOTIFY => .{ .mouse_enter = .{ .window_id = wid } },
            xcb.XCB_LEAVE_NOTIFY => .{ .mouse_leave = .{ .window_id = wid } },
            xcb.XCB_DESTROY_NOTIFY => .{ .close_requested = .{ .window_id = wid } },
            else => null,
        };
    }

    fn translateKeyEvent(self: *X11Backend, ev: [*c]xcb.xcb_generic_event_t, wid: u32) ?event_mod.Event {
        const key_ev = @as([*c]xcb.xcb_key_press_event_t, @ptrCast(ev));
        const pressed = (ev.*.response_type & 0x7f) == xcb.XCB_KEY_PRESS;
        // X11 keycode 比 evdev keycode 大 8 (xkbcommon 期望 xkb keycode = evdev + 8 = X11 keycode)
        const keycode: u32 = key_ev.*.detail;
        const key_code = xkbKeycodeToKeyCode(keycode);

        if (self.xkb_state) |state| {
            // 先更新 xkb_state (按下→KEY_DOWN, 释放→KEY_UP), 再读取修饰键状态
            // 必须在读取 mods 之前更新: 否则释放事件中 mods 仍反映按下状态 (Ctrl 释放后 ctrl 卡 true)
            _ = xkb.xkb_state_update_key(state, keycode, if (pressed) xkb.XKB_KEY_DOWN else xkb.XKB_KEY_UP);

            // 从 xkb_state 获取当前修饰键状态 (更新后, 反映本次按键后的真实状态)
            // (X11 state 字段为事件前状态, 不可靠; xkb_state 由我们手动维护, 准确)
            self.mods = .{
                .shift = xkb.xkb_state_mod_name_is_active(state, xkb.XKB_MOD_NAME_SHIFT, xkb.XKB_STATE_MODS_EFFECTIVE) > 0,
                .ctrl = xkb.xkb_state_mod_name_is_active(state, xkb.XKB_MOD_NAME_CTRL, xkb.XKB_STATE_MODS_EFFECTIVE) > 0,
                .alt = xkb.xkb_state_mod_name_is_active(state, xkb.XKB_MOD_NAME_ALT, xkb.XKB_STATE_MODS_EFFECTIVE) > 0,
                .super_key = xkb.xkb_state_mod_name_is_active(state, xkb.XKB_MOD_NAME_LOGO, xkb.XKB_STATE_MODS_EFFECTIVE) > 0,
            };

            const sym = xkb.xkb_state_key_get_one_sym(state, keycode);

            // 始终推送 key 事件 (使 Ctrl+字母等快捷键能被控件接收, 与 Wayland 行为一致)
            self.pushEvent(.{ .key = .{
                .window_id = wid,
                .state = if (pressed) .pressed else .released,
                .key = key_code,
                .modifiers = self.mods,
            } });

            // 文本输入 (仅按下时, 且无 Ctrl/Alt/Super 修饰 — 这些修饰下字符作为快捷键而非文本)
            if (pressed and !self.mods.ctrl and !self.mods.alt and !self.mods.super_key) {
                var buf: [8]u8 = undefined;
                const len = xkb.xkb_keysym_to_utf8(sym, &buf, buf.len);
                if (len > 1) {
                    const ulen: usize = @intCast(len);
                    const cp = std.unicode.utf8Decode(buf[0 .. ulen - 1]) catch 0;
                    if (cp >= 0x20) { // 排除控制字符
                        self.pushEvent(.{ .text_input = .{ .window_id = wid, .codepoint = cp } });
                    }
                }
            }
        } else {
            // xkb_state 不可用时的回退: 仅推送 key 事件 (使用 X11 state 字段)
            self.pushEvent(.{ .key = .{
                .window_id = wid,
                .state = if (pressed) .pressed else .released,
                .key = key_code,
                .modifiers = self.getModifiers(key_ev.*.state),
            } });
        }

        // 事件已通过 pushEvent 直接推送
        return null;
    }

    fn translateButtonEvent(self: *X11Backend, ev: [*c]xcb.xcb_generic_event_t, wid: u32) ?event_mod.Event {
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
                .window_id = wid,
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
            .window_id = wid,
            .button = mouse_button,
            .state = if (pressed) .pressed else .released,
            .x = x,
            .y = y,
        } };
    }

    fn translateMotionEvent(self: *X11Backend, ev: [*c]xcb.xcb_generic_event_t, wid: u32) ?event_mod.Event {
        const motion_ev = @as([*c]xcb.xcb_motion_notify_event_t, @ptrCast(ev));
        const x: i32 = @intCast(motion_ev.*.event_x);
        const y: i32 = @intCast(motion_ev.*.event_y);
        self.mouse_x = x;
        self.mouse_y = y;
        return .{ .mouse_move = .{ .window_id = wid, .x = x, .y = y } };
    }

    fn translateConfigureEvent(self: *X11Backend, ev: [*c]xcb.xcb_generic_event_t, wid: u32) ?event_mod.Event {
        _ = self;
        const cfg_ev = @as([*c]xcb.xcb_configure_notify_event_t, @ptrCast(ev));
        return .{ .resize = .{
            .window_id = wid,
            .width = @intCast(cfg_ev.*.width),
            .height = @intCast(cfg_ev.*.height),
        } };
    }

    fn translatePropertyNotify(self: *X11Backend, ev: [*c]xcb.xcb_generic_event_t, wid: u32) ?event_mod.Event {
        const prop_ev = @as([*c]xcb.xcb_property_notify_event_t, @ptrCast(ev));
        if (prop_ev.*.atom != self.net_wm_state) return null;
        // 查询当前 _NET_WM_STATE 属性
        const is_max = self.queryMaximizedState();
        if (is_max != self.maximized) {
            self.maximized = is_max;
            return .{ .maximize = .{ .window_id = wid, .maximized = is_max } };
        }
        return null;
    }

    /// 查询窗口当前最大化状态
    fn queryMaximizedState(self: *X11Backend) bool {
        if (self.net_wm_state == 0) return false;
        const cookie = xcb.xcb_get_property(
            self.conn,
            0, // delete
            self.window_id,
            self.net_wm_state,
            xcb.XCB_ATOM_ATOM,
            0,
            64,
        );
        var err: [*c]xcb.xcb_generic_error_t = null;
        const reply = xcb.xcb_get_property_reply(self.conn, cookie, &err);
        defer if (reply != null) std.c.free(reply);
        if (reply == null or err != null) return false;
        const len = xcb.xcb_get_property_value_length(reply);
        if (len <= 0) return false;
        const atoms: [*]const u32 = @ptrCast(@alignCast(xcb.xcb_get_property_value(reply)));
        const count: usize = @intCast(@divFloor(len, 4));
        for (atoms[0..count]) |atom| {
            if (atom == self.net_wm_state_maximized_vert or atom == self.net_wm_state_maximized_horz) {
                return true;
            }
        }
        return false;
    }

    /// 请求最大化窗口 (发送 _NET_WM_STATE client message)
    pub fn setMaximized(self: *X11Backend) void {
        self.sendWmStateChange(self.window_id, 1); // _NET_WM_STATE_ADD
    }

    /// 取消最大化
    pub fn unsetMaximized(self: *X11Backend) void {
        self.sendWmStateChange(self.window_id, 0); // _NET_WM_STATE_REMOVE
    }

    /// 最大化子窗口
    pub fn maximizeSubWindow(self: *X11Backend, wid: u32) void {
        self.sendWmStateChange(wid, 1);
    }

    /// 还原子窗口 (取消最大化)
    pub fn unmaximizeSubWindow(self: *X11Backend, wid: u32) void {
        self.sendWmStateChange(wid, 0);
    }

    fn sendWmStateChange(self: *X11Backend, wid: u32, action: u32) void {
        if (self.net_wm_state == 0) return;
        var ev: xcb.xcb_client_message_event_t = undefined;
        ev.response_type = xcb.XCB_CLIENT_MESSAGE;
        ev.format = 32;
        ev.sequence = 0;
        ev.window = wid;
        ev.type = self.net_wm_state;
        ev.data.data32[0] = action;
        ev.data.data32[1] = self.net_wm_state_maximized_vert;
        ev.data.data32[2] = self.net_wm_state_maximized_horz;
        ev.data.data32[3] = 1; // source: normal application
        ev.data.data32[4] = 0;
        _ = xcb.xcb_send_event(
            self.conn,
            0,
            self.screen.root,
            xcb.XCB_EVENT_MASK_SUBSTRUCTURE_REDIRECT | xcb.XCB_EVENT_MASK_SUBSTRUCTURE_NOTIFY,
            @ptrCast(&ev),
        );
        _ = xcb.xcb_flush(self.conn);
    }

    fn translateClientMessage(self: *X11Backend, ev: [*c]xcb.xcb_generic_event_t, wid: u32) ?event_mod.Event {
        const client_ev = @as([*c]xcb.xcb_client_message_event_t, @ptrCast(ev));
        if (client_ev.*.type == self.wm_protocols) {
            const data32: [*c]const u32 = @ptrCast(&client_ev.*.data);
            if (data32[0] == self.wm_delete_window) {
                return .{ .close_requested = .{ .window_id = wid } };
            }
        }
        // Xdnd 文件拖放协议
        return self.handleXdndClientMessage(client_ev, wid);
    }

    // ── Xdnd 文件拖放 (接收端) ──────────────────────────────────────

    /// 初始化 Xdnd: 内部化协议 atoms 并声明 XdndAware=5 (支持拖放接收)
    fn initXdnd(self: *X11Backend, wid: u32) void {
        self.xdnd_aware = internAtom(self.conn, "XdndAware");
        self.xdnd_enter = internAtom(self.conn, "XdndEnter");
        self.xdnd_leave = internAtom(self.conn, "XdndLeave");
        self.xdnd_position = internAtom(self.conn, "XdndPosition");
        self.xdnd_drop = internAtom(self.conn, "XdndDrop");
        self.xdnd_finished = internAtom(self.conn, "XdndFinished");
        self.xdnd_status = internAtom(self.conn, "XdndStatus");
        self.xdnd_selection = internAtom(self.conn, "XdndSelection");
        self.xdnd_type_list = internAtom(self.conn, "XdndTypeList");
        self.text_uri_list = internAtom(self.conn, "text/uri-list");
        if (self.xdnd_aware != 0) {
            const version: u32 = 5;
            _ = xcb.xcb_change_property(
                self.conn,
                xcb.XCB_PROP_MODE_REPLACE,
                wid,
                self.xdnd_aware,
                xcb.XCB_ATOM_ATOM,
                32,
                1,
                &version,
            );
        }
    }

    /// 处理 Xdnd 客户端消息 (Enter/Position/Drop/Leave)
    fn handleXdndClientMessage(self: *X11Backend, client_ev: [*c]xcb.xcb_client_message_event_t, wid: u32) ?event_mod.Event {
        const t = client_ev.*.type;
        const data32: [*c]const u32 = @ptrCast(&client_ev.*.data);
        if (t == self.xdnd_enter) {
            self.xdnd_source = client_ev.*.window;
            self.xdnd_version = (data32[0] >> 24) & 0xff;
            self.xdnd_has_uri = self.xdndOfferHasUri(data32);
            return null;
        } else if (t == self.xdnd_position) {
            self.xdnd_source = client_ev.*.window;
            // data32[1] = 根窗口坐标 (x<<16 | y)
            const root_x: i32 = @intCast(data32[1] >> 16);
            const root_y: i32 = @intCast(data32[1] & 0xffff);
            const local = self.rootToLocal(root_x, root_y);
            self.drop_x = local[0];
            self.drop_y = local[1];
            self.sendXdndStatus(data32[2]); // 回应接受/拒绝
            return null;
        } else if (t == self.xdnd_leave) {
            self.xdnd_source = 0;
            self.xdnd_has_uri = false;
            return null;
        } else if (t == self.xdnd_drop) {
            self.xdnd_source = client_ev.*.window;
            const time = data32[2];
            // 请求源将 XdndSelection 转换为 text/uri-list 存于本窗口属性
            if (self.xdnd_has_uri and self.xdnd_selection != 0 and self.text_uri_list != 0) {
                _ = xcb.xcb_convert_selection(
                    self.conn,
                    self.window_id,
                    self.xdnd_selection,
                    self.text_uri_list,
                    self.xdnd_selection, // 存储属性名
                    time,
                );
                _ = xcb.xcb_flush(self.conn);
                const path = self.readXdndDrop() orelse {
                    self.sendXdndFinished();
                    return null;
                };
                defer self.allocator.free(path);
                var fd: event_mod.FileDrop = .{ .x = self.drop_x, .y = self.drop_y, .path = undefined, .path_len = 0 };
                const n = @min(path.len, fd.path.len);
                @memcpy(fd.path[0..n], path[0..n]);
                fd.path_len = @intCast(n);
                self.sendXdndFinished();
                return .{ .file_drop = .{ .window_id = wid, .file_drop = fd } };
            }
            self.sendXdndFinished();
            return null;
        }
        return null;
    }

    /// 检查 XdndEnter 提供的类型是否含 text/uri-list。
    /// data32[0] bit0 表示类型多于 3 个 (需读源窗口 XdndTypeList 属性)。
    fn xdndOfferHasUri(self: *X11Backend, data32: [*c]const u32) bool {
        if (self.text_uri_list == 0) return false;
        if ((data32[0] & 1) != 0) {
            // 类型列表存于源窗口 XdndTypeList 属性
            if (self.xdnd_source == 0 or self.xdnd_type_list == 0) return false;
            const cookie = xcb.xcb_get_property(self.conn, 0, self.xdnd_source, self.xdnd_type_list, xcb.XCB_ATOM_ATOM, 0, 256);
            var err: [*c]xcb.xcb_generic_error_t = null;
            const reply = xcb.xcb_get_property_reply(self.conn, cookie, &err);
            defer if (reply != null) std.c.free(reply);
            if (reply == null or err != null) return false;
            const len = xcb.xcb_get_property_value_length(reply);
            if (len <= 0) return false;
            const atoms: [*]const u32 = @ptrCast(@alignCast(xcb.xcb_get_property_value(reply)));
            const count: usize = @intCast(@divFloor(len, 4));
            for (atoms[0..count]) |a| if (a == self.text_uri_list) return true;
            return false;
        }
        // 内联类型: data32[1..3]
        var i: usize = 1;
        while (i <= 3) : (i += 1) if (data32[i] == self.text_uri_list) return true;
        return false;
    }

    /// 回应 XdndStatus (接受=has_uri; 动作=XdndActionCopy)
    fn sendXdndStatus(self: *X11Backend, target_action: u32) void {
        _ = target_action;
        if (self.xdnd_source == 0 or self.xdnd_status == 0) return;
        var ev: xcb.xcb_client_message_event_t = undefined;
        ev.response_type = xcb.XCB_CLIENT_MESSAGE;
        ev.format = 32;
        ev.sequence = 0;
        ev.window = self.xdnd_source;
        ev.type = self.xdnd_status;
        ev.data.data32[0] = self.window_id;
        ev.data.data32[1] = if (self.xdnd_has_uri) @as(u32, 1) else 0; // bit0 = accept
        ev.data.data32[2] = 0;
        ev.data.data32[3] = 0;
        ev.data.data32[4] = internAtom(self.conn, "XdndActionCopy");
        _ = xcb.xcb_send_event(self.conn, 0, self.xdnd_source, xcb.XCB_EVENT_MASK_NO_EVENT, @ptrCast(&ev));
        _ = xcb.xcb_flush(self.conn);
    }

    /// 发送 XdndFinished 通知源拖放完成
    fn sendXdndFinished(self: *X11Backend) void {
        if (self.xdnd_source == 0 or self.xdnd_finished == 0) return;
        var ev: xcb.xcb_client_message_event_t = undefined;
        ev.response_type = xcb.XCB_CLIENT_MESSAGE;
        ev.format = 32;
        ev.sequence = 0;
        ev.window = self.xdnd_source;
        ev.type = self.xdnd_finished;
        ev.data.data32[0] = self.window_id;
        ev.data.data32[1] = 1; // accepted
        ev.data.data32[2] = internAtom(self.conn, "XdndActionCopy");
        ev.data.data32[3] = 0;
        ev.data.data32[4] = 0;
        _ = xcb.xcb_send_event(self.conn, 0, self.xdnd_source, xcb.XCB_EVENT_MASK_NO_EVENT, @ptrCast(&ev));
        _ = xcb.xcb_flush(self.conn);
        self.xdnd_source = 0;
        self.xdnd_has_uri = false;
    }

    /// 读取转换后的 XdndSelection 属性 (text/uri-list) 并解析首个文件路径 (调用者释放)。
    /// 通过 poll X11 连接 fd 等待 SelectionNotify (源完成转换) 后读取属性。
    fn readXdndDrop(self: *X11Backend) ?[]u8 {
        if (self.xdnd_selection == 0) return null;
        const fd = xcb.xcb_get_file_descriptor(self.conn);
        var elapsed_ms: i32 = 0;
        while (elapsed_ms < 1000) {
            // 等待连接可读 (SelectionNotify 到达)
            var pfd = [_]std.posix.pollfd{.{ .fd = fd, .events = std.posix.POLL.IN, .revents = 0 }};
            const pn = std.posix.poll(&pfd, 100) catch 0;
            elapsed_ms += 100;
            // 抽取事件 (SelectionNotify 触发源写入属性; 其余事件丢弃)
            if (pn > 0) {
                while (xcb.xcb_poll_for_event(self.conn)) |e| std.c.free(e);
            }
            // 尝试读取已转换的属性 (delete=1 读后清除)
            const cookie = xcb.xcb_get_property(self.conn, 1, self.window_id, self.xdnd_selection, xcb.XCB_ATOM_ANY, 0, 0x10000);
            var err: [*c]xcb.xcb_generic_error_t = null;
            const reply = xcb.xcb_get_property_reply(self.conn, cookie, &err);
            if (reply == null or err != null) {
                if (reply != null) std.c.free(reply);
                continue;
            }
            const len = xcb.xcb_get_property_value_length(reply);
            if (len <= 0) {
                std.c.free(reply);
                continue;
            }
            const data: [*]const u8 = @ptrCast(xcb.xcb_get_property_value(reply));
            const slice = data[0..@intCast(len)];
            const result = parseFirstFileUriX11(self.allocator, slice) catch null;
            std.c.free(reply);
            return result;
        }
        return null;
    }

    /// 根窗口坐标 → 本窗口局部坐标
    fn rootToLocal(self: *X11Backend, root_x: i32, root_y: i32) [2]i32 {
        const cookie = xcb.xcb_translate_coordinates(self.conn, self.window_id, self.window_id, @intCast(root_x), @intCast(root_y));
        var err: [*c]xcb.xcb_generic_error_t = null;
        const reply = xcb.xcb_translate_coordinates_reply(self.conn, cookie, &err);
        defer if (reply != null) std.c.free(reply);
        if (reply == null or err != null) return .{ root_x, root_y };
        return .{ reply.*.dst_x, reply.*.dst_y };
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

/// 从 text/uri-list 数据解析首个 file:// URI 为本地路径 (调用者释放)
fn parseFirstFileUriX11(allocator: std.mem.Allocator, data: []const u8) ![]u8 {
    var it = std.mem.splitScalar(u8, data, '\n');
    while (it.next()) |raw_line| {
        const line = std.mem.trimEnd(u8, raw_line, "\r \t");
        if (line.len == 0 or line[0] == '#') continue;
        if (!std.mem.startsWith(u8, line, "file://")) continue;
        var path = line["file://".len..];
        // 去掉可选主机名 (file://host/path → /path)
        if (path.len > 0 and path[0] != '/') {
            if (std.mem.indexOfScalar(u8, path, '/')) |slash| {
                path = path[slash..];
            }
        }
        return percentDecodeX11(allocator, path);
    }
    return error.NoFileUri;
}

/// 百分号解码 (%20 → 空格 等)
fn percentDecodeX11(allocator: std.mem.Allocator, src: []const u8) ![]u8 {
    var out = try allocator.alloc(u8, src.len);
    errdefer allocator.free(out);
    var j: usize = 0;
    var i: usize = 0;
    while (i < src.len) {
        if (src[i] == '%' and i + 2 < src.len) {
            const hi = std.fmt.charToDigit(src[i + 1], 16) catch {
                out[j] = src[i];
                j += 1;
                i += 1;
                continue;
            };
            const lo = std.fmt.charToDigit(src[i + 2], 16) catch {
                out[j] = src[i];
                j += 1;
                i += 1;
                continue;
            };
            out[j] = hi * 16 + lo;
            j += 1;
            i += 3;
        } else {
            out[j] = src[i];
            j += 1;
            i += 1;
        }
    }
    return allocator.realloc(out, j) catch out[0..j];
}

// ── Tests (文件拖放 URI 解析) ──────────────────────────────────────

test "x11 parseFirstFileUriX11 decodes first file uri" {
    const alloc = std.testing.allocator;
    const data = "# comment\r\nfile:///home/user/a%20b.txt\r\nfile:///other.txt\r\n";
    const path = try parseFirstFileUriX11(alloc, data);
    defer alloc.free(path);
    try std.testing.expectEqualStrings("/home/user/a b.txt", path);
}

test "x11 parseFirstFileUriX11 strips hostname" {
    const alloc = std.testing.allocator;
    const path = try parseFirstFileUriX11(alloc, "file://localhost/tmp/x.png");
    defer alloc.free(path);
    try std.testing.expectEqualStrings("/tmp/x.png", path);
}

test "x11 parseFirstFileUriX11 errors on no file uri" {
    const alloc = std.testing.allocator;
    try std.testing.expectError(error.NoFileUri, parseFirstFileUriX11(alloc, "http://x\nfoo"));
}
