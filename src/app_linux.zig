//! zigui 顶层 App (Linux X11/Wayland + Vulkan 实现)

const std = @import("std");
const build_options = @import("build_options");
const math = @import("math.zig");
const pal = @import("pal/pal.zig");
const vulkan = @import("gpu/vulkan.zig");
const renderer2d = @import("render2d/vulkan_renderer.zig");
const dirty_mod = @import("render2d/dirty.zig");
const atlas_mod = @import("text/atlas_vulkan.zig");
const freetype = @import("text/freetype.zig");
const clipboard = @import("pal/clipboard.zig");
const perf_mod = @import("perf.zig");
const shortcut_mod = @import("shortcut.zig");
const dnd_mod = @import("dnd.zig");
const window_mod = @import("window.zig");

// 编译期后端选择
const enable_wayland = build_options.enable_wayland;
const enable_x11 = build_options.enable_x11;

comptime {
    if (!enable_wayland and !enable_x11) {
        @compileError("At least one backend must be enabled: -Dwayland=true or -Dx11=true");
    }
}

const x11 = if (enable_x11) @import("pal/x11.zig") else void;
const wayland = if (enable_wayland) @import("pal/wayland.zig") else void;

pub const AppConfig = struct {
    title: []const u8 = "zigui app",
    width: u32 = 800,
    height: u32 = 600,
    resizable: bool = true,
    continuous: bool = true,
    /// 强制后端: null = 自动检测
    force_backend: ?BackendKind = null,
};

pub const BackendKind = enum { wayland, x11 };

/// IME 删除光标周围文本的请求 (字节数)
pub const ImeDelete = struct { before: u32, after: u32 };

/// 运行时后端抽象 (仅包含编译期启用的后端)
const PlatformBackend = union(BackendKind) {
    wayland: if (enable_wayland) wayland.WaylandBackend else noreturn,
    x11: if (enable_x11) x11.X11Backend else noreturn,

    fn pollEvents(self: *PlatformBackend, queue: *pal.EventQueue, allocator: std.mem.Allocator) !void {
        switch (self.*) {
            .wayland => |*b| {
                if (comptime enable_wayland) try b.pollEvents(queue, allocator);
            },
            .x11 => |*b| {
                if (comptime enable_x11) try b.pollEvents(queue, allocator);
            },
        }
    }

    fn deinit(self: *PlatformBackend) void {
        switch (self.*) {
            .wayland => |*b| {
                if (comptime enable_wayland) b.deinit();
            },
            .x11 => |*b| {
                if (comptime enable_x11) b.deinit();
            },
        }
    }

    fn setMaximized(self: *PlatformBackend) void {
        switch (self.*) {
            .wayland => |*b| {
                if (comptime enable_wayland) b.setMaximized();
            },
            .x11 => |*b| {
                if (comptime enable_x11) b.setMaximized();
            },
        }
    }

    fn unsetMaximized(self: *PlatformBackend) void {
        switch (self.*) {
            .wayland => |*b| {
                if (comptime enable_wayland) b.unsetMaximized();
            },
            .x11 => |*b| {
                if (comptime enable_x11) b.unsetMaximized();
            },
        }
    }

    fn imeSetCursorRect(self: *PlatformBackend, x: i32, y: i32, w: i32, h: i32) void {
        switch (self.*) {
            .wayland => |*b| {
                if (comptime enable_wayland) b.imeSetCursorRect(x, y, w, h);
            },
            .x11 => {
                // X11 后端暂未实现 IME, 空操作
            },
        }
    }

    fn setCursor(self: *PlatformBackend, cursor_type: pal.CursorType) void {
        switch (self.*) {
            .wayland => {
                // Wayland 后端光标暂未实现
            },
            .x11 => |*b| {
                if (comptime enable_x11) b.setCursor(cursor_type);
            },
        }
    }
};

pub const App = struct {
    allocator: std.mem.Allocator,
    config: AppConfig,
    backend: PlatformBackend,
    backend_kind: BackendKind,
    vk_device: vulkan.VulkanDevice,
    renderer: renderer2d.Renderer2D,
    glyph_atlas: atlas_mod.GlyphAtlas,
    event_queue: pal.EventQueue = .{},
    running: bool = false,
    maximized: bool = false,
    main_window_id: u32 = 0,
    fb_width: u32,
    fb_height: u32,
    /// 高 DPI 缩放因子 (逻辑坐标 → 物理像素; 来自后端输出检测)
    scale_factor: f32 = 1.0,
    /// 性能监控 (帧时间/FPS 统计)
    frame_stats: perf_mod.FrameStats = .{},
    /// 全局快捷键控制器
    shortcuts: shortcut_mod.ShortcutController = undefined,
    /// 拖拽状态
    drag_state: dnd_mod.DragState = .{},

    // 脏矩形驱动重绘
    dirty: dirty_mod.DirtyRegion,
    needs_redraw: bool = true,

    // 鼠标状态
    mouse_x: f32 = 0,
    mouse_y: f32 = 0,
    mouse_down: bool = false,
    mouse_clicked: bool = false,
    right_clicked: bool = false,
    current_cursor: pal.CursorType = .arrow,

    // 每帧输入状态
    scroll_delta: f32 = 0,
    typed_cps: [16]u21 = undefined,
    typed_cp_count: usize = 0,
    key_hit: ?pal.KeyCode = null,
    key_mods: pal.event.Modifiers = .{}, // 当前修饰键状态 (随按键事件更新)
    file_drop: ?pal.event.FileDrop = null,
    // 本帧触摸事件缓冲 (帧末清除)
    touches: [16]pal.event.Touch = undefined,
    touch_count: usize = 0,

    // IME 状态 (text-input)
    ime_commit_buf: [pal.event.max_ime_text]u8 = undefined, // 本帧提交的文本 (帧末重置)
    ime_commit_len: usize = 0,
    preedit_buf: [pal.event.max_ime_text]u8 = undefined, // 组合中文本 (持久)
    preedit_len: usize = 0,
    preedit_cursor_begin: i32 = 0,
    preedit_cursor_end: i32 = 0,
    pending_ime_delete: ?struct { before_length: u32, after_length: u32 } = null,

    // 子窗口 (额外的顶层窗口)
    sub_windows: std.AutoHashMapUnmanaged(u32, *window_mod.Window) = .{},

    pub fn typedCodepoints(self: *App) []const u21 {
        return self.typed_cps[0..self.typed_cp_count];
    }

    /// 本帧触摸事件 (drawFrame 内调用; 帧末自动清空)
    pub fn touchEvents(self: *App) []const pal.event.Touch {
        return self.touches[0..self.touch_count];
    }

    /// 本帧 IME 提交的文本 (UTF-8, 帧末重置)
    pub fn imeCommitText(self: *App) []const u8 {
        return self.ime_commit_buf[0..self.ime_commit_len];
    }

    /// 当前组合中 (preedit) 文本 (UTF-8, 持久至组合结束)
    pub fn preeditText(self: *App) []const u8 {
        return self.preedit_buf[0..self.preedit_len];
    }

    /// preedit 光标范围 (字节偏移)
    pub fn preeditCursor(self: *App) struct { i32, i32 } {
        return .{ self.preedit_cursor_begin, self.preedit_cursor_end };
    }

    /// 取出并清除待处理的 IME 删除请求
    pub fn takeImeDelete(self: *App) ?ImeDelete {
        const d = self.pending_ime_delete orelse return null;
        self.pending_ime_delete = null;
        return .{ .before = d.before_length, .after = d.after_length };
    }

    /// 设置 IME 光标矩形 (供输入法候选窗定位)
    pub fn setImeCursorRect(self: *App, x: i32, y: i32, w: i32, h: i32) void {
        self.backend.imeSetCursorRect(x, y, w, h);
    }

    // ── 剪贴板 API (Ctrl+C/V 快捷键使用) ─────────────────────────

    /// 读取系统剪贴板文本 (调用者拥有返回内存)
    /// Wayland: 原生 wl_data_device; X11: xclip 子进程
    pub fn clipboardGetText(self: *App) ![]u8 {
        switch (self.backend) {
            .wayland => |*b| {
                if (comptime enable_wayland) {
                    return b.clipboardGetText(self.allocator) orelse return error.ClipboardUnavailable;
                }
            },
            .x11 => {},
        }
        return clipboard.getText(self.allocator);
    }

    /// 写入文本到系统剪贴板
    pub fn clipboardSetText(self: *App, text: []const u8) !void {
        switch (self.backend) {
            .wayland => |*b| {
                if (comptime enable_wayland) {
                    b.clipboardSetText(text);
                    return;
                }
            },
            .x11 => {},
        }
        return clipboard.setText(text);
    }

    pub fn init(allocator: std.mem.Allocator, config: AppConfig) !*App {
        const self = try allocator.create(App);

        // 检测后端 (尊重编译期选项)
        const kind = config.force_backend orelse detectBackend();

        switch (kind) {
            .wayland => {
                if (comptime !enable_wayland) {
                    // Wayland 未编译，回退 X11
                    if (comptime enable_x11) {
                        try initX11(self, allocator, config);
                        return self;
                    }
                    return error.NoBackendAvailable;
                }
                // Wayland 路径
                const wl_backend = wayland.WaylandBackend.init(allocator) catch {
                    // Wayland 失败时回退 X11
                    if (comptime enable_x11) {
                        try initX11(self, allocator, config);
                        return self;
                    }
                    return error.BackendInitFailed;
                };

                // 先将 backend 放到最终位置 (self 是堆分配，指针稳定)
                self.* = .{
                    .allocator = allocator,
                    .config = config,
                    .backend = .{ .wayland = wl_backend },
                    .backend_kind = .wayland,
                    .vk_device = undefined,
                    .renderer = undefined,
                    .glyph_atlas = undefined,
                    .running = false,
                    .fb_width = config.width,
                    .fb_height = config.height,
                    .dirty = dirty_mod.DirtyRegion.init(allocator),
                };

                // 在稳定指针上创建窗口 (listener 回调使用此指针)
                self.backend.wayland.createWindow(.{
                    .title = config.title,
                    .width = config.width,
                    .height = config.height,
                    .resizable = config.resizable,
                }) catch {
                    self.backend.wayland.deinit();
                    if (comptime enable_x11) {
                        try initX11(self, allocator, config);
                        return self;
                    }
                    return error.BackendInitFailed;
                };

                // Vulkan + Wayland Surface
                const wl_display = self.backend.wayland.getDisplay();
                const wl_surface = self.backend.wayland.getSurface();
                self.vk_device = try vulkan.VulkanDevice.initWayland(allocator, wl_display, wl_surface, config.width, config.height);

                self.glyph_atlas = try atlas_mod.GlyphAtlas.init(allocator, 2048, 2048);
                try self.glyph_atlas.createTexture(&self.vk_device);

                self.renderer = renderer2d.Renderer2D.init(allocator, &self.vk_device);
                self.renderer.glyph_atlas = &self.glyph_atlas;

                // 设置 Wayland 事件队列
                self.backend.wayland.event_queue = &self.event_queue;
                self.scale_factor = self.backend.wayland.getScaleFactor();
                self.vk_device.setContentScale(self.scale_factor);
            },
            .x11 => {
                if (comptime !enable_x11) {
                    // X11 未编译，尝试 Wayland
                    if (comptime enable_wayland) {
                        // 重新走 wayland 路径
                        const wl_backend = wayland.WaylandBackend.init(allocator) catch {
                            return error.NoBackendAvailable;
                        };
                        self.* = .{
                            .allocator = allocator,
                            .config = config,
                            .backend = .{ .wayland = wl_backend },
                            .backend_kind = .wayland,
                            .vk_device = undefined,
                            .renderer = undefined,
                            .glyph_atlas = undefined,
                            .running = false,
                            .fb_width = config.width,
                            .fb_height = config.height,
                            .dirty = dirty_mod.DirtyRegion.init(allocator),
                        };
                        self.backend.wayland.createWindow(.{
                            .title = config.title,
                            .width = config.width,
                            .height = config.height,
                            .resizable = config.resizable,
                        }) catch return error.BackendInitFailed;
                        const wl_display = self.backend.wayland.getDisplay();
                        const wl_surface = self.backend.wayland.getSurface();
                        self.vk_device = try vulkan.VulkanDevice.initWayland(allocator, wl_display, wl_surface, config.width, config.height);
                        self.glyph_atlas = try atlas_mod.GlyphAtlas.init(allocator, 2048, 2048);
                        try self.glyph_atlas.createTexture(&self.vk_device);
                        self.renderer = renderer2d.Renderer2D.init(allocator, &self.vk_device);
                        self.renderer.glyph_atlas = &self.glyph_atlas;
                        self.backend.wayland.event_queue = &self.event_queue;
                        self.scale_factor = self.backend.wayland.getScaleFactor();
                        self.vk_device.setContentScale(self.scale_factor);
                        return self;
                    }
                    return error.NoBackendAvailable;
                }
                try initX11(self, allocator, config);
            },
        }

        self.shortcuts = shortcut_mod.ShortcutController.init(allocator);
        return self;
    }

    fn initX11(self: *App, allocator: std.mem.Allocator, config: AppConfig) !void {
        var x11_backend = try x11.X11Backend.init(allocator);

        _ = try x11_backend.createWindow(.{
            .title = config.title,
            .width = config.width,
            .height = config.height,
            .resizable = config.resizable,
        });

        const conn = x11_backend.getConnection();
        const window_id = x11_backend.getWindowId();
        var vk_device = try vulkan.VulkanDevice.init(allocator, @ptrCast(conn), window_id, config.width, config.height);

        var glyph_atlas = try atlas_mod.GlyphAtlas.init(allocator, 2048, 2048);
        try glyph_atlas.createTexture(&vk_device);

        var renderer = renderer2d.Renderer2D.init(allocator, &vk_device);
        renderer.glyph_atlas = &glyph_atlas;

        self.* = .{
            .allocator = allocator,
            .config = config,
            .backend = .{ .x11 = x11_backend },
            .backend_kind = .x11,
            .vk_device = vk_device,
            .renderer = renderer,
            .glyph_atlas = glyph_atlas,
            .running = false,
            .main_window_id = window_id,
            .fb_width = config.width,
            .fb_height = config.height,
            .dirty = dirty_mod.DirtyRegion.init(allocator),
        };
        self.renderer.device = &self.vk_device;
        self.renderer.glyph_atlas = &self.glyph_atlas;
        self.scale_factor = self.backend.x11.getScaleFactor();
        self.vk_device.setContentScale(self.scale_factor);
    }

    /// 创建一个额外的顶层窗口
    pub fn createSubWindow(self: *App, title: []const u8, width: u32, height: u32) !u32 {
        switch (self.backend) {
            .x11 => |*b| {
                if (comptime enable_x11) {
                    const wid = try b.createSubWindow(title, width, height);
                    const conn_ptr: *anyopaque = @ptrCast(b.conn);
                    const win = try window_mod.Window.init(
                        self.allocator,
                        conn_ptr,
                        wid,
                        title,
                        width,
                        height,
                        self.scale_factor,
                    );
                    try self.sub_windows.put(self.allocator, wid, win);
                    return wid;
                }
            },
            .wayland => |*b| {
                if (comptime enable_wayland) {
                    const wid = try b.createSubWindow(title, width, height);
                    const surface = b.getSubWindowSurface(wid) orelse return error.SurfaceFailed;
                    const display_ptr: *anyopaque = @ptrCast(b.display);
                    const surface_ptr: *anyopaque = @ptrCast(surface);
                    const win = try window_mod.Window.initWayland(
                        self.allocator,
                        display_ptr,
                        surface_ptr,
                        wid,
                        title,
                        width,
                        height,
                        self.scale_factor,
                    );
                    try self.sub_windows.put(self.allocator, wid, win);
                    return wid;
                }
            },
        }
        return error.NotImplemented;
    }

    /// 销毁子窗口
    pub fn destroySubWindow(self: *App, wid: u32) void {
        if (self.sub_windows.fetchRemove(wid)) |entry| {
            entry.value.deinit();
        }
        switch (self.backend) {
            .x11 => |*b| {
                if (comptime enable_x11) {
                    b.destroySubWindow(wid);
                }
            },
            .wayland => |*b| {
                if (comptime enable_wayland) {
                    b.destroySubWindow(wid);
                }
            },
        }
    }

    /// 获取子窗口指针 (用于设置回调等)
    pub fn getSubWindow(self: *App, wid: u32) ?*window_mod.Window {
        return self.sub_windows.get(wid);
    }

    /// 显示子窗口
    pub fn showSubWindow(self: *App, wid: u32) void {
        if (self.sub_windows.get(wid)) |win| {
            win.visible = true;
        }
        switch (self.backend) {
            .x11 => |*b| {
                if (comptime enable_x11) {
                    b.showSubWindow(wid);
                }
            },
            .wayland => |*b| {
                if (comptime enable_wayland) {
                    b.showSubWindow(wid);
                }
            },
        }
    }

    /// 隐藏子窗口
    pub fn hideSubWindow(self: *App, wid: u32) void {
        if (self.sub_windows.get(wid)) |win| {
            win.visible = false;
        }
        switch (self.backend) {
            .x11 => |*b| {
                if (comptime enable_x11) {
                    b.hideSubWindow(wid);
                }
            },
            .wayland => |*b| {
                if (comptime enable_wayland) {
                    b.hideSubWindow(wid);
                }
            },
        }
    }

    /// 设置子窗口标题
    pub fn setSubWindowTitle(self: *App, wid: u32, title: []const u8) void {
        if (self.sub_windows.get(wid)) |win| {
            win.setTitle(title);
        }
        switch (self.backend) {
            .x11 => |*b| {
                if (comptime enable_x11) {
                    b.setSubWindowTitle(wid, title);
                }
            },
            .wayland => |*b| {
                if (comptime enable_wayland) {
                    b.setSubWindowTitle(wid, title);
                }
            },
        }
    }

    /// 调整子窗口大小
    pub fn resizeSubWindow(self: *App, wid: u32, width: u32, height: u32) void {
        switch (self.backend) {
            .x11 => |*b| {
                if (comptime enable_x11) {
                    b.resizeSubWindow(wid, width, height);
                }
            },
            .wayland => {},
        }
    }

    /// 移动子窗口
    pub fn moveSubWindow(self: *App, wid: u32, x: i32, y: i32) void {
        switch (self.backend) {
            .x11 => |*b| {
                if (comptime enable_x11) {
                    b.moveSubWindow(wid, x, y);
                }
            },
            .wayland => {},
        }
    }

    /// 最小化子窗口
    pub fn iconifySubWindow(self: *App, wid: u32) void {
        switch (self.backend) {
            .x11 => |*b| {
                if (comptime enable_x11) {
                    b.iconifySubWindow(wid);
                }
            },
            .wayland => {},
        }
    }

    /// 设置子窗口为 transient (对话框样式，父窗口之上)
    pub fn setSubWindowTransientFor(self: *App, wid: u32, parent_wid: u32) void {
        switch (self.backend) {
            .x11 => |*b| {
                if (comptime enable_x11) {
                    b.setSubWindowTransientFor(wid, parent_wid);
                }
            },
            .wayland => {},
        }
    }

    /// 最大化子窗口
    pub fn maximizeSubWindow(self: *App, wid: u32) void {
        switch (self.backend) {
            .x11 => |*b| {
                if (comptime enable_x11) {
                    b.maximizeSubWindow(wid);
                }
            },
            .wayland => {},
        }
    }

    /// 还原子窗口 (取消最大化)
    pub fn unmaximizeSubWindow(self: *App, wid: u32) void {
        switch (self.backend) {
            .x11 => |*b| {
                if (comptime enable_x11) {
                    b.unmaximizeSubWindow(wid);
                }
            },
            .wayland => {},
        }
    }

    /// 处理所有子窗口的事件，关闭那些 should_close 的窗口
    fn processSubWindowEvents(self: *App) void {
        // 收集需要关闭的窗口 ID
        var to_close: [64]u32 = undefined;
        var close_count: usize = 0;

        var it = self.sub_windows.valueIterator();
        while (it.next()) |win_ptr| {
            const win = win_ptr.*;
            win.processEvents();
            if (win.should_close) {
                if (close_count < to_close.len) {
                    to_close[close_count] = win.platform_window_id;
                    close_count += 1;
                }
            }
        }

        // 关闭标记为 should_close 的窗口
        for (to_close[0..close_count]) |wid| {
            self.destroySubWindow(wid);
        }
    }

    /// 渲染所有可见的子窗口
    fn renderSubWindows(self: *App) void {
        var it = self.sub_windows.valueIterator();
        while (it.next()) |win_ptr| {
            const win = win_ptr.*;
            if (!win.visible) continue;
            // 开始帧
            const size = win.vk_device.beginFrame() orelse continue;
            win.width = size[0];
            win.height = size[1];

            // 开始渲染
            win.renderer.beginFrame();
            win.frame_stats.beginFrame();

            // 调用用户绘制回调
            if (win.on_draw) |draw_fn| {
                draw_fn(win);
            }

            // 提交渲染
            win.renderer.submit();
            win.frame_stats.endFrame();

            // 结束帧
            win.vk_device.endFrame();
        }
    }

    pub fn deinit(self: *App) void {
        // 清理子窗口
        var it = self.sub_windows.valueIterator();
        while (it.next()) |win_ptr| {
            win_ptr.*.deinit();
        }
        self.sub_windows.deinit(self.allocator);
        self.shortcuts.deinit();
        self.event_queue.deinit(self.allocator);
        self.dirty.deinit();
        self.renderer.deinit();
        self.glyph_atlas.deinit();
        self.vk_device.deinit();
        self.backend.deinit();
        self.allocator.destroy(self);
    }

    pub fn invalidate(self: *App) void {
        self.needs_redraw = true;
    }

    pub fn invalidateRect(self: *App, rect: math.Rect(f32)) void {
        self.dirty.add(rect) catch {};
        self.needs_redraw = true;
    }

    pub fn getDirtyRegion(self: *App) *dirty_mod.DirtyRegion {
        return &self.dirty;
    }

    /// 运行主循环
    pub fn run(self: *App, draw_fn: *const fn (app: *App) void) !void {
        self.running = true;
        while (self.running) {
            // 1. 采集事件
            try self.backend.pollEvents(&self.event_queue, self.allocator);

            // 2. 处理事件
            const events = self.event_queue.drain();
            for (events) |ev| {
                // 事件路由: 子窗口的事件推送到对应窗口的队列
                const ev_window_id = getEventWindowId(ev);
                if (ev_window_id != self.main_window_id) {
                    if (self.sub_windows.get(ev_window_id)) |win| {
                        win.event_queue.push(self.allocator, ev) catch {};
                        continue;
                    }
                }
                switch (ev) {
                    .close_requested => self.running = false,
                    .resize => |r| {
                        self.fb_width = r.width;
                        self.fb_height = r.height;
                        self.vk_device.setDrawableSize(r.width, r.height);
                        self.invalidate();
                    },
                    .maximize => |m| {
                        self.maximized = m.maximized;
                        self.invalidate();
                    },
                    .key => |k| {
                        self.key_mods = k.modifiers;
                        // 显式追踪修饰键 press/release
                        // (X11 state 字段为事件前状态, Wayland keyboardModifiers 可能滞后于 keyboardKey;
                        //  直接依赖 k.modifiers 会导致 Ctrl 释放后 key_mods.ctrl 卡在 true,
                        //  进而使所有 text_input 被 if(key_mods.ctrl) continue 跳过 → 无法输入)
                        switch (k.key) {
                            .left_shift, .right_shift => self.key_mods.shift = (k.state == .pressed),
                            .left_ctrl, .right_ctrl => self.key_mods.ctrl = (k.state == .pressed),
                            .left_alt, .right_alt => self.key_mods.alt = (k.state == .pressed),
                            .left_super, .right_super => self.key_mods.super_key = (k.state == .pressed),
                            else => {},
                        }
                        if (k.state == .pressed) {
                            // 先检查全局快捷键
                            if (self.shortcuts.handle(k.key, k.modifiers)) {
                                self.invalidate();
                                continue;
                            }
                            self.key_hit = k.key;
                            self.invalidate();
                            if (k.key == .escape) {
                                self.running = false;
                            }
                        }
                    },
                    .scroll => |s| {
                        if (s.axis == .vertical) {
                            self.scroll_delta += s.delta;
                        }
                        self.invalidate();
                    },
                    .text_input => |t| {
                        // Ctrl+字母 为快捷键 (复制/粘贴等), 不作为文本插入
                        if (self.key_mods.ctrl) continue;
                        if (self.typed_cp_count < self.typed_cps.len) {
                            self.typed_cps[self.typed_cp_count] = t.codepoint;
                            self.typed_cp_count += 1;
                        }
                        self.invalidate();
                    },
                    .ime_commit => |c| {
                        // 追加本帧提交文本 (可能一帧内多次提交)
                        const n = @min(c.len, self.ime_commit_buf.len - self.ime_commit_len);
                        @memcpy(self.ime_commit_buf[self.ime_commit_len .. self.ime_commit_len + n], c.text[0..n]);
                        self.ime_commit_len += n;
                        // 提交后组合结束
                        self.preedit_len = 0;
                        self.invalidate();
                    },
                    .ime_preedit => |p| {
                        // 整体替换组合中文本及光标位置 (len==0 表示组合结束)
                        const n = @min(p.len, self.preedit_buf.len);
                        @memcpy(self.preedit_buf[0..n], p.text[0..n]);
                        self.preedit_len = n;
                        self.preedit_cursor_begin = p.cursor_begin;
                        self.preedit_cursor_end = p.cursor_end;
                        self.invalidate();
                    },
                    .ime_delete => |d| {
                        self.pending_ime_delete = .{ .before_length = d.before_length, .after_length = d.after_length };
                        self.invalidate();
                    },
                    .mouse_move => |m| {
                        if (!self.mouse_clicked) {
                            self.mouse_x = @floatFromInt(m.x);
                            self.mouse_y = @floatFromInt(m.y);
                        }
                        // 拖拽位置更新
                        if (self.drag_state.active) {
                            _ = self.drag_state.update(@floatFromInt(m.x), @floatFromInt(m.y));
                        }
                        self.invalidate();
                    },
                    .mouse_button => |mb| {
                        self.mouse_x = @floatFromInt(mb.x);
                        self.mouse_y = @floatFromInt(mb.y);
                        if (mb.button == .left) {
                            if (mb.state == .pressed) {
                                self.mouse_down = true;
                                self.mouse_clicked = true;
                                // 开始潜在拖拽
                                self.drag_state.begin(@floatFromInt(mb.x), @floatFromInt(mb.y), null);
                            } else {
                                self.mouse_down = false;
                                // 结束拖拽 (如果有)
                                if (self.drag_state.isActive()) {
                                    _ = self.drag_state.end();
                                } else {
                                    self.drag_state.cancel();
                                }
                            }
                        } else if (mb.button == .right and mb.state == .pressed) {
                            self.right_clicked = true;
                        }
                        self.invalidate();
                    },
                    .file_drop => |fd| {
                        self.file_drop = fd.file_drop;
                        self.invalidate();
                    },
                    else => {},
                }
            }

            if (!self.running) break;

            // 2b. 处理子窗口事件
            self.processSubWindowEvents();

            // 3. 重绘决策
            if (!self.config.continuous and !self.needs_redraw) {
                continue;
            }

            // 4. 开始帧
            const size = self.vk_device.beginFrame() orelse continue;
            self.fb_width = size[0];
            self.fb_height = size[1];

            // 5. 用户绘制
            self.renderer.beginFrame();
            self.frame_stats.beginFrame();
            draw_fn(self);
            self.renderer.submit();
            self.frame_stats.endFrame();

            // 消费本帧输入
            self.mouse_clicked = false;
            self.right_clicked = false;
            self.scroll_delta = 0;
            self.typed_cp_count = 0;
            self.ime_commit_len = 0;
            self.key_hit = null;
            self.file_drop = null;
            self.touch_count = 0;
            self.dirty.clear();
            self.needs_redraw = false;

            // 6. 提交帧
            self.vk_device.endFrame();

            // 7. 渲染子窗口
            self.renderSubWindows();
        }
    }

    pub fn getRenderer(self: *App) *renderer2d.Renderer2D {
        return &self.renderer;
    }

    /// 获取主窗口 ID
    pub fn getMainWindowId(self: *const App) u32 {
        return self.main_window_id;
    }

    /// 添加全局快捷键
    pub fn addShortcut(
        self: *App,
        key: pal.KeyCode,
        mods: pal.event.Modifiers,
        callback: *const fn (ctx: ?*anyopaque) void,
        ctx: ?*anyopaque,
    ) !void {
        try self.shortcuts.add(key, mods, callback, ctx);
    }

    /// 移除快捷键 (按回调指针)
    pub fn removeShortcut(self: *App, callback: *const fn (ctx: ?*anyopaque) void) void {
        self.shortcuts.remove(callback);
    }

    /// 获取快捷键控制器 (直接操作)
    pub fn getShortcuts(self: *App) *shortcut_mod.ShortcutController {
        return &self.shortcuts;
    }

    /// 开始拖拽 (由控件在 mouse_down 时调用, 设置数据后正式启动)
    pub fn startDrag(self: *App, data: dnd_mod.DragData) void {
        self.drag_state.setData(data);
        self.invalidate();
    }

    /// 获取拖拽状态
    pub fn getDragState(self: *App) *dnd_mod.DragState {
        return &self.drag_state;
    }

    /// 拖拽是否正在进行
    pub fn isDragging(self: *App) bool {
        return self.drag_state.isActive();
    }

    pub fn getFramebufferSize(self: *App) math.Size(u32) {
        return .{ .width = self.fb_width, .height = self.fb_height };
    }

    /// 高 DPI 缩放因子 (逻辑坐标 × scale = 物理像素; 普通屏为 1.0)
    pub fn getScaleFactor(self: *App) f32 {
        return self.scale_factor;
    }

    /// 性能监控统计 (FPS / 帧耗时 / 百分位)
    pub fn getFrameStats(self: *App) *const perf_mod.FrameStats {
        return &self.frame_stats;
    }

    /// 获取上一帧到当前帧的时间差 (ms), 用于驱动动画
    pub fn getDeltaMs(self: *App) u32 {
        return self.frame_stats.getDeltaMs();
    }

    pub fn getGlyphAtlas(self: *App) *atlas_mod.GlyphAtlas {
        return &self.glyph_atlas;
    }

    pub fn getVulkanDevice(self: *App) *vulkan.VulkanDevice {
        return &self.vk_device;
    }

    /// 最大化窗口
    pub fn maximize(self: *App) void {
        self.backend.setMaximized();
    }

    /// 取消最大化
    pub fn unmaximize(self: *App) void {
        self.backend.unsetMaximized();
    }

    /// 切换最大化状态
    pub fn toggleMaximize(self: *App) void {
        if (self.maximized) {
            self.unmaximize();
        } else {
            self.maximize();
        }
    }

    /// 查询是否最大化
    pub fn isMaximized(self: *const App) bool {
        return self.maximized;
    }

    /// 设置鼠标光标样式
    pub fn setCursor(self: *App, cursor_type: pal.CursorType) void {
        if (self.current_cursor == cursor_type) return;
        self.current_cursor = cursor_type;
        self.backend.setCursor(cursor_type);
    }
};

/// 从事件中提取 window_id
fn getEventWindowId(ev: pal.Event) u32 {
    return switch (ev) {
        .resize => |e| e.window_id,
        .move => |e| e.window_id,
        .close_requested => |e| e.window_id,
        .focus_change => |e| e.window_id,
        .scale_change => |e| e.window_id,
        .minimize => |e| e.window_id,
        .maximize => |e| e.window_id,
        .mouse_move => |e| e.window_id,
        .mouse_button => |e| e.window_id,
        .scroll => |e| e.window_id,
        .mouse_enter => |e| e.window_id,
        .mouse_leave => |e| e.window_id,
        .key => |e| e.window_id,
        .text_input => |e| e.window_id,
        .ime_commit => |e| e.window_id,
        .ime_preedit => |e| e.window_id,
        .ime_delete => |e| e.window_id,
        .touch => |e| e.window_id,
        .file_drop => |e| e.window_id,
    };
}

/// 自动检测显示后端 (尊重编译期选项)
/// 优先级: WAYLAND_DISPLAY > DISPLAY
fn detectBackend() BackendKind {
    if (comptime enable_wayland and !enable_x11) return .wayland;
    if (comptime enable_x11 and !enable_wayland) return .x11;
    // 两者都启用时按环境变量检测
    if (std.c.getenv("WAYLAND_DISPLAY") != null) {
        return .wayland;
    }
    return .x11;
}
