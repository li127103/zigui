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

    pub fn typedCodepoints(self: *App) []const u21 {
        return self.typed_cps[0..self.typed_cp_count];
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
                        if (self.typed_cp_count < self.typed_cps.len) {
                            self.typed_cps[self.typed_cp_count] = t.codepoint;
                            self.typed_cp_count += 1;
                        }
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
            self.key_hit = null;
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
