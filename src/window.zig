//! 顶层窗口 (对标 GtkWindow)
//!
//! 每个窗口有独立的:
//! - X11/Wayland/macOS 平台窗口
//! - Vulkan swapchain / framebuffer
//! - 输入状态

const std = @import("std");
const math = @import("math.zig");
const pal = @import("pal/pal.zig");
const vulkan = @import("gpu/vulkan.zig");
const renderer2d = @import("render2d/vulkan_renderer.zig");
const atlas_mod = @import("text/atlas_vulkan.zig");
const dirty_mod = @import("render2d/dirty.zig");
const perf_mod = @import("perf.zig");

pub const Window = struct {
    allocator: std.mem.Allocator,
    platform_window_id: u32,
    title: []const u8,
    width: u32,
    height: u32,
    scale_factor: f32 = 1.0,

    vk_device: vulkan.VulkanDevice,
    renderer: renderer2d.Renderer2D,
    glyph_atlas: atlas_mod.GlyphAtlas,

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

        var vk_device = try vulkan.VulkanDevice.init(allocator, xcb_conn_ptr, x11_window_id, width, height);
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
            .vk_device = vk_device,
            .renderer = renderer,
            .glyph_atlas = glyph_atlas,
            .dirty = dirty,
        };

        self.renderer.glyph_atlas = &self.glyph_atlas;

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

        var vk_device = try vulkan.VulkanDevice.initWayland(allocator, wl_display_ptr, wl_surface_ptr, width, height);
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
            .vk_device = vk_device,
            .renderer = renderer,
            .glyph_atlas = glyph_atlas,
            .dirty = dirty,
        };

        self.renderer.glyph_atlas = &self.glyph_atlas;

        return self;
    }

    pub fn deinit(self: *Window) void {
        self.dirty.deinit();
        self.renderer.deinit();
        self.glyph_atlas.deinit();
        self.vk_device.deinit();
        self.allocator.destroy(self);
    }

    pub fn setTitle(self: *Window, title: []const u8) void {
        self.title = title;
    }

    pub fn markDirty(self: *Window) void {
        self.needs_redraw = true;
    }

    pub fn getRenderer(self: *Window) *renderer2d.Renderer2D {
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
                    self.width = r.width;
                    self.height = r.height;
                    self.vk_device.setDrawableSize(r.width, r.height);
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
