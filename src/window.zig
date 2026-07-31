//! 顶层窗口 (对标 GtkWindow)
//!
//! 每个窗口有独立的:
//! - X11/Wayland/macOS 平台窗口
//! - Vulkan swapchain / framebuffer
//! - 输入状态

const std = @import("std");
const builtin = @import("builtin");
const is_windows = builtin.os.tag == .windows;
const build_options = @import("build_options");
const use_vulkan = build_options.enable_vulkan;

const math = @import("math.zig");
const pal = @import("pal/pal.zig");
const vulkan = @import("gpu/vulkan.zig");
const renderer2d = @import("render2d/vulkan_renderer.zig");
const atlas_mod = @import("text/atlas_vulkan.zig");
const dirty_mod = @import("render2d/dirty.zig");
const perf_mod = @import("perf.zig");

// Windows 下若未启用 Vulkan, 子窗口走 D3D11 后端 (与主窗口一致)。
// 注意: d3d_renderer / atlas_d3d11 模块本身跨平台可被类型检查 (Linux 下是空壳类型),
// 但 root.zig 把它们别名为 void, 这里直接用模块路径引入以拿到真实类型。
const use_d3d = is_windows and !use_vulkan;
const d3d_backend = @import("render2d/d3d_renderer.zig");
const atlas_d3d11_mod = @import("text/atlas_d3d11.zig");
const atlas_vulkan_win32_mod = @import("text/atlas_vulkan_win32.zig");
const d3d11_mod = @import("gpu/d3d11.zig");
const win32_mod = @import("pal/win32.zig");

pub const Window = struct {
    allocator: std.mem.Allocator,
    platform_window_id: u32,
    title: []const u8,
    width: u32,
    height: u32,
    scale_factor: f32 = 1.0,

    // GPU 后端: Windows 非 Vulkan 用 D3D11, 其余用 Vulkan (Windows 用 Win32 图集, 非 Windows 用 FreeType 图集)。
    gpu_device: if (use_d3d) d3d_backend.D3DBackend else vulkan.VulkanDevice,
    renderer: if (use_d3d) d3d_backend.Renderer2D else renderer2d.Renderer2D,
    glyph_atlas: if (use_d3d)
        atlas_d3d11_mod.GlyphAtlas
    else if (is_windows)
        atlas_vulkan_win32_mod.GlyphAtlas
    else
        atlas_mod.GlyphAtlas,

    event_queue: pal.EventQueue = .{},

    mouse_x: f32 = 0,
    mouse_y: f32 = 0,
    mouse_down: bool = false,
    mouse_clicked: bool = false,
    right_clicked: bool = false,
    current_cursor: pal.CursorType = .arrow,
    scroll_delta: f32 = 0,
    key_hit: ?pal.event.KeyCode = null,
    key_mods: pal.event.Modifiers = .{},
    file_drop: ?pal.event.FileDrop = null,

    dirty: dirty_mod.DirtyRegion,
    needs_redraw: bool = true,

    frame_stats: perf_mod.FrameStats = .{},

    visible: bool = true,
    should_close: bool = false,

    user_data: ?*anyopaque = null,
    on_draw: ?*const fn (win: *Window) void = null,
    on_close: ?*const fn (win: *Window) void = null,

    pub fn init(
        allocator: std.mem.Allocator,
        xcb_conn_ptr: *anyopaque,
        x11_window_id: u32,
        title: []const u8,
        width: u32,
        height: u32,
        scale_factor: f32,
    ) !*Window {
        const self = try allocator.create(Window);
        errdefer allocator.destroy(self);

        var vk_device = try vulkan.VulkanDevice.init(allocator, xcb_conn_ptr, x11_window_id, width, height, scale_factor);
        errdefer vk_device.deinit();

        var glyph_atlas = try atlas_mod.GlyphAtlas.init(allocator, 1024, 1024);
        errdefer glyph_atlas.deinit();
        try glyph_atlas.createTexture(&vk_device);

        const renderer = renderer2d.Renderer2D.init(allocator, &vk_device);

        const dirty = dirty_mod.DirtyRegion.init(allocator);
        errdefer dirty.deinit();

        self.* = .{
            .allocator = allocator,
            .platform_window_id = x11_window_id,
            .title = title,
            .width = width,
            .height = height,
            .scale_factor = scale_factor,
            .gpu_device = vk_device,
            .renderer = renderer,
            .glyph_atlas = glyph_atlas,
            .dirty = dirty,
        };

        self.renderer.glyph_atlas = &self.glyph_atlas;
        // 关键: Renderer2D.init 传入的是 init 栈上的局部 vk_device 地址 (悬挂),
        // 必须把渲染器的 device 重新指向结构体字段 self.gpu_device (稳定地址)。
        // 主窗口 App.initX11 也有同样修正 (app_linux.zig:400); 这里漏掉会导致子窗口
        // 渲染时 win.renderer.device 读垃圾 → setScissor 通用保护异常。
        self.renderer.device = &self.gpu_device;

        return self;
    }

    pub fn initWayland(
        allocator: std.mem.Allocator,
        wl_display_ptr: *anyopaque,
        wl_surface_ptr: *anyopaque,
        window_id: u32,
        title: []const u8,
        width: u32,
        height: u32,
        scale_factor: f32,
    ) !*Window {
        const self = try allocator.create(Window);
        errdefer allocator.destroy(self);

        var vk_device = try vulkan.VulkanDevice.initWayland(allocator, wl_display_ptr, wl_surface_ptr, width, height, scale_factor);
        errdefer vk_device.deinit();

        var glyph_atlas = try atlas_mod.GlyphAtlas.init(allocator, 1024, 1024);
        errdefer glyph_atlas.deinit();
        try glyph_atlas.createTexture(&vk_device);

        const renderer = renderer2d.Renderer2D.init(allocator, &vk_device);

        const dirty = dirty_mod.DirtyRegion.init(allocator);
        errdefer dirty.deinit();

        self.* = .{
            .allocator = allocator,
            .platform_window_id = window_id,
            .title = title,
            .width = width,
            .height = height,
            .scale_factor = scale_factor,
            .gpu_device = vk_device,
            .renderer = renderer,
            .glyph_atlas = glyph_atlas,
            .dirty = dirty,
        };

        self.renderer.glyph_atlas = &self.glyph_atlas;
        // 同 init (X11): 重指向稳定字段, 避免 win.renderer.device 悬挂。
        self.renderer.device = &self.gpu_device;

        return self;
    }

    pub fn deinit(self: *Window) void {
        self.dirty.deinit();
        self.renderer.deinit();
        self.glyph_atlas.deinit();
        self.gpu_device.deinit();
        self.allocator.destroy(self);
    }

    /// Windows 子窗口构造: 基于已创建的 HWND/HINSTANCE 建立独立 GPU 后端。
    /// D3D11 (默认) 或 Vulkan Win32 (use_vulkan) 二选一, 与主窗口一致。
    pub fn initWin32(
        allocator: std.mem.Allocator,
        hwnd: *anyopaque,
        hinstance: *anyopaque,
        id: u32,
        title: []const u8,
        width: u32,
        height: u32,
        scale_factor: f32,
    ) !*Window {
        if (!is_windows) return error.NotImplemented;

        const self = try allocator.create(Window);
        errdefer allocator.destroy(self);

        var gpu_device: if (use_d3d) d3d_backend.D3DBackend else vulkan.VulkanDevice = undefined;
        var glyph_atlas: if (use_d3d) atlas_d3d11_mod.GlyphAtlas else atlas_vulkan_win32_mod.GlyphAtlas = undefined;

        if (comptime use_d3d) {
            var gpu11 = try d3d11_mod.D3D11Device.init(allocator, hwnd, width, height);
            errdefer gpu11.deinit();
            gpu_device = .{ .d3d11 = gpu11 };
            gpu_device.setContentScale(scale_factor);

            glyph_atlas = try atlas_d3d11_mod.GlyphAtlas.init(allocator, 1024, 1024);
            errdefer glyph_atlas.deinit();
            try glyph_atlas.createTexture(&gpu_device.d3d11);
        } else {
            gpu_device = try vulkan.VulkanDevice.initWin32(allocator, hinstance, hwnd, width, height, scale_factor);
            errdefer gpu_device.deinit();

            glyph_atlas = try atlas_vulkan_win32_mod.GlyphAtlas.init(allocator, 1024, 1024);
            errdefer glyph_atlas.deinit();
            try glyph_atlas.createTexture(&gpu_device);
        }

        const renderer = if (comptime use_d3d)
            d3d_backend.Renderer2D.init(allocator, &gpu_device)
        else
            renderer2d.Renderer2D.init(allocator, &gpu_device);
        errdefer renderer.deinit();

        const dirty = dirty_mod.DirtyRegion.init(allocator);
        errdefer dirty.deinit();

        self.* = .{
            .allocator = allocator,
            .platform_window_id = id,
            .title = title,
            .width = width,
            .height = height,
            .scale_factor = scale_factor,
            .gpu_device = gpu_device,
            .renderer = renderer,
            .glyph_atlas = glyph_atlas,
            .dirty = dirty,
        };

        if (comptime use_d3d) {
            self.renderer.glyph_atlas_texture = self.glyph_atlas.texture;
        } else {
            self.renderer.glyph_atlas = &self.glyph_atlas;
        }

        // 同 init/initWayland: 重指向稳定字段, 避免子窗口渲染器 device 悬挂。
        self.renderer.device = &self.gpu_device;

        return self;
    }

    /// 子窗口驱动: 开始一帧, 返回 [w, h]。失败 (交换链重建) 返回 null。
    pub fn beginFrame(self: *Window) ?[2]u32 {
        return self.gpu_device.beginFrame();
    }

    pub fn endFrame(self: *Window) void {
        self.gpu_device.endFrame();
    }

    pub fn setTitle(self: *Window, title: []const u8) void {
        self.title = title;
    }

    pub fn markDirty(self: *Window) void {
        self.needs_redraw = true;
    }

    pub fn getRenderer(self: *Window) *if (use_d3d) d3d_backend.Renderer2D else renderer2d.Renderer2D {
        return &self.renderer;
    }

    pub fn getWidth(self: *const Window) u32 {
        return self.width;
    }

    pub fn getHeight(self: *const Window) u32 {
        return self.height;
    }

    /// 处理窗口事件队列中的事件，更新窗口状态
    pub fn processEvents(self: *Window) void {
        const events = self.event_queue.drain();
        for (events) |ev| {
            switch (ev) {
                .close_requested => {
                    self.should_close = true;
                    if (self.on_close) |cb| cb(self);
                },
                .resize => |r| {
                    if (comptime use_d3d) {
                        // Win32 的 resize 事件已是逻辑尺寸 (WndProc 已 ÷ scale), 直接使用。
                        self.width = r.width;
                        self.height = r.height;
                        self.gpu_device.setDrawableSize(r.width, r.height);
                    } else if (comptime is_windows) {
                        // Vulkan Win32 子窗口: resize 也是逻辑尺寸。
                        self.width = r.width;
                        self.height = r.height;
                        self.gpu_device.setDrawableSize(r.width, r.height);
                    } else {
                        // X11 子窗口的 configure 事件是物理尺寸, 还原为逻辑尺寸
                        // (窗口按物理像素创建, Vulkan swapchain 也是物理 = 逻辑 × scale)
                        const lw: u32 = @intFromFloat(@as(f32, @floatFromInt(r.width)) / self.scale_factor);
                        const lh: u32 = @intFromFloat(@as(f32, @floatFromInt(r.height)) / self.scale_factor);
                        self.width = lw;
                        self.height = lh;
                        self.gpu_device.setDrawableSize(lw, lh);
                    }
                    self.markDirty();
                },
                .focus_change => |f| {
                    _ = f;
                },
                .mouse_move => |m| {
                    self.mouse_x = @floatFromInt(m.x);
                    self.mouse_y = @floatFromInt(m.y);
                },
                .mouse_button => |m| {
                    self.mouse_x = @floatFromInt(m.x);
                    self.mouse_y = @floatFromInt(m.y);
                    if (m.button == .left) {
                        if (m.state == .pressed) {
                            self.mouse_down = true;
                            self.mouse_clicked = true;
                        } else {
                            self.mouse_down = false;
                        }
                    }
                    if (m.button == .right and m.state == .pressed) {
                        self.right_clicked = true;
                    }
                },
                .scroll => |s| {
                    if (s.axis == .vertical) {
                        self.scroll_delta += s.delta;
                    }
                },
                .key => |k| {
                    self.key_mods = k.modifiers;
                    if (k.state == .pressed) {
                        self.key_hit = k.key;
                    }
                },
                .text_input => |t| {
                    _ = t;
                },
                else => {},
            }
        }
    }
};
