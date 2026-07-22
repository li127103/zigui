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
    fb_width: u32,
    fb_height: u32,

    // 脏矩形驱动重绘
    dirty: dirty_mod.DirtyRegion,
    needs_redraw: bool = true,

    // 鼠标状态
    mouse_x: f32 = 0,
    mouse_y: f32 = 0,
    mouse_down: bool = false,
    mouse_clicked: bool = false,

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

                // 设置 Wayland 全局事件队列引用
                wayland.setEventQueue(&self.event_queue, allocator, &self.backend.wayland);
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
                        wayland.setEventQueue(&self.event_queue, allocator, &self.backend.wayland);
                        return self;
                    }
                    return error.NoBackendAvailable;
                }
                try initX11(self, allocator, config);
            },
        }

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
            .fb_width = config.width,
            .fb_height = config.height,
            .dirty = dirty_mod.DirtyRegion.init(allocator),
        };
        self.renderer.device = &self.vk_device;
        self.renderer.glyph_atlas = &self.glyph_atlas;
    }

    pub fn deinit(self: *App) void {
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
                        if (k.state == .pressed) {
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
                        self.invalidate();
                    },
                    .mouse_button => |mb| {
                        self.mouse_x = @floatFromInt(mb.x);
                        self.mouse_y = @floatFromInt(mb.y);
                        if (mb.button == .left) {
                            if (mb.state == .pressed) {
                                self.mouse_down = true;
                                self.mouse_clicked = true;
                            } else {
                                self.mouse_down = false;
                            }
                        }
                        self.invalidate();
                    },
                    else => {},
                }
            }

            if (!self.running) break;

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
            draw_fn(self);
            self.renderer.submit();

            // 消费本帧输入
            self.mouse_clicked = false;
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
        }
    }

    pub fn getRenderer(self: *App) *renderer2d.Renderer2D {
        return &self.renderer;
    }

    pub fn getFramebufferSize(self: *App) math.Size(u32) {
        return .{ .width = self.fb_width, .height = self.fb_height };
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
};

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
