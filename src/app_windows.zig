//! Windows 应用主循环 (Win32 + D3D11)
//!
//! 一站式入口: 封装窗口创建、GPU 设备初始化 (D3D11, 因字形图集为 D3D11 专用)、
//! 消息循环、渲染调度、事件分发。
//! 接口与 macOS (app.zig) / Linux (app_linux.zig) App 对齐, 供示例跨平台复用。
//!
//! 注意: 本文件仅在 Windows 目标下被编译 (root.zig 通过 `if (is_windows)` 分发)。

const std = @import("std");
const builtin = @import("builtin");
const is_windows = builtin.os.tag == .windows;

const build_options = @import("build_options");
const use_vulkan = build_options.enable_vulkan;

const math = @import("math.zig");
const pal = @import("pal/pal.zig");
const window_mod = @import("window.zig");
const win32 = @import("pal/win32.zig");
const d3d_backend = @import("render2d/d3d_renderer.zig");
const renderer2d = if (use_vulkan) @import("render2d/vulkan_renderer.zig") else @import("render2d/d3d_renderer.zig");
const vulkan = @import("gpu/vulkan.zig");
const vulkan_renderer_mod = @import("render2d/vulkan_renderer.zig");
const d3d11_mod = @import("gpu/d3d11.zig");
const dwrite = @import("text/dwrite.zig");
const atlas_mod = @import("text/atlas_d3d11.zig");
const atlas_vulkan_win32_mod = @import("text/atlas_vulkan_win32.zig");
const widget_mod = @import("widget/widget.zig");
const input = @import("input/event_queue.zig");
const theme = @import("theme/theme.zig");
const perf = @import("perf.zig");
const event_mod = @import("pal/event.zig");

pub const AppConfig = struct {
    title: []const u8 = "zigui App",
    width: u32 = 800,
    height: u32 = 600,
    vsync: bool = true,
    resizable: bool = true,
    continuous: bool = true,
};

/// 子窗口条目: 关联 Window (GPU/渲染器/图集) 与底层 Win32 backend (事件队列/HWND)。
pub const SubWindowEntry = struct {
    window: *window_mod.Window,
    backend: *win32.Win32Backend,
};

pub const App = struct {
    allocator: std.mem.Allocator,
    config: AppConfig,
    event_queue: input.EventQueue,
    backend: union(enum) {
        win32: win32.Win32Backend,
    },
    gpu_device: if (use_vulkan) vulkan.VulkanDevice else d3d_backend.D3DBackend,
    renderer: if (use_vulkan) vulkan_renderer_mod.Renderer2D else d3d_backend.Renderer2D,
    glyph_atlas: if (use_vulkan) atlas_vulkan_win32_mod.GlyphAtlas else atlas_mod.GlyphAtlas,
    root_widget: ?*widget_mod.Widget = null,
    theme: theme.Theme,
    frame_stats: perf.FrameStats,
    scale_factor: f32 = 1.0,
    running: bool = true,

    // ── 帧缓冲 / 输入状态 (供示例访问, 与 Linux App 对齐) ──
    fb_width: u32 = 800,
    fb_height: u32 = 600,
    needs_redraw: bool = true,
    continuous: bool = false,
    mouse_x: f32 = 0,
    mouse_y: f32 = 0,
    mouse_clicked: bool = false,
    mouse_down: bool = false,
    key_hit: ?event_mod.KeyCode = null,
    key_mods: event_mod.Modifiers = .{},
    typed_cps: [64]u21 = undefined,
    typed_cp_count: usize = 0,

    // ── 子窗口 (多窗口) ──
    next_sub_id: u32 = 1,
    sub_windows: std.AutoHashMap(u32, SubWindowEntry),

    pub fn init(allocator: std.mem.Allocator, config: AppConfig) !*App {
        if (!is_windows) return error.NotImplemented;

        const self = try allocator.create(App);
        self.* = .{
            .allocator = allocator,
            .config = config,
            .event_queue = input.EventQueue{},
            // 以下四个字段在 init 后续步骤中创建并赋值 (GPU 设备 / 渲染器 / 图集 / 窗口后端),
            // 此处先用 undefined 占位, 避免 Linux 下这些 comptime 分支为死代码而被跳过、
            // 导致 Windows 真正编译时缺字段初始化。
            .backend = undefined,
            .gpu_device = undefined,
            .renderer = undefined,
            .glyph_atlas = undefined,
            .theme = theme.light,
            .frame_stats = perf.FrameStats{},
            .fb_width = config.width,
            .fb_height = config.height,
            .scale_factor = 1.0,
            .next_sub_id = 1,
            .sub_windows = std.AutoHashMap(u32, SubWindowEntry).init(allocator),
        };
        errdefer allocator.destroy(self);

        // 1. 创建 Win32 窗口后端 (内部做 DPI 感知)
        var backend = try win32.Win32Backend.init(allocator);
        // 事件队列指针需在 createWindow 前设置 (WndProc 会向它推送)
        backend.event_queue = &self.event_queue;
        self.scale_factor = backend.scale_factor;
        try backend.createWindow(config.title, config.width, config.height);
        self.backend = .{ .win32 = backend };

        // 2. 创建 GPU 设备 + 渲染器 + 字形图集
        //    后端可选: Vulkan (Win32 表面) 或 D3D11 (默认)。
        const surface = self.backend.win32.getSurfaceInfo();
        const hwnd: *anyopaque = surface.win32.hwnd;
        const hinst: *anyopaque = surface.win32.hinstance;

        if (comptime use_vulkan) {
            self.gpu_device = try vulkan.VulkanDevice.initWin32(
                allocator,
                hinst,
                hwnd,
                config.width,
                config.height,
                self.scale_factor,
            );
            self.renderer = vulkan_renderer_mod.Renderer2D.init(allocator, &self.gpu_device);
            self.glyph_atlas = try atlas_vulkan_win32_mod.GlyphAtlas.init(allocator, 2048, 2048);
            try self.glyph_atlas.createTexture(&self.gpu_device);
            self.renderer.glyph_atlas = &self.glyph_atlas;
        } else {
            const gpu11 = try d3d11_mod.D3D11Device.init(allocator, hwnd, config.width, config.height);
            self.gpu_device = .{ .d3d11 = gpu11 };
            self.gpu_device.setContentScale(self.scale_factor);

            self.renderer = renderer2d.Renderer2D.init(allocator, &self.gpu_device);
            self.glyph_atlas = try atlas_mod.GlyphAtlas.init(allocator, 2048, 2048);
            try self.glyph_atlas.createTexture(&self.gpu_device.d3d11);
            self.renderer.glyph_atlas_texture = self.glyph_atlas.texture;
        }

        return self;
    }

    pub fn deinit(self: *App) void {
        // 销毁所有子窗口
        var it = self.sub_windows.iterator();
        while (it.next()) |entry| {
            entry.value_ptr.*.window.deinit();
            entry.value_ptr.*.backend.destroyWindow();
        }
        self.sub_windows.deinit();
        self.glyph_atlas.deinit();
        self.renderer.deinit();
        self.gpu_device.deinit();
        switch (self.backend) {
            .win32 => |*b| b.deinit(),
        }
        self.event_queue.deinit(self.allocator);
        self.allocator.destroy(self);
    }

    pub fn setRoot(self: *App, root: *widget_mod.Widget) void {
        self.root_widget = root;
    }

    /// 运行主循环: 采集事件 → 分发 → 绘制 → 呈现
    pub fn run(self: *App, draw_fn: *const fn (app: *App) void) !void {
        self.running = true;
        while (self.running) {
            // 1. 采集事件
            switch (self.backend) {
                .win32 => |*b| b.pollEvents(),
            }

            // 2. 处理事件
            const events = self.event_queue.drain();
            for (events) |ev| {
                switch (ev) {
                    .close_requested => self.running = false,
                    .resize => |r| {
                        // Win32 的 resize 事件已是逻辑尺寸 (WndProc 已 ÷ scale)
                        self.fb_width = r.width;
                        self.fb_height = r.height;
                        self.gpu_device.setDrawableSize(r.width, r.height);
                        self.invalidate();
                    },
                    .move => {},
                    .key => |k| {
                        self.key_mods = k.modifiers;
                        if (k.state == .pressed) {
                            self.key_hit = k.key;
                            self.invalidate();
                            if (k.key == .escape) self.running = false;
                        }
                    },
                    .scroll => |s| {
                        if (s.axis == .vertical) {
                            _ = s.delta;
                        }
                        self.invalidate();
                    },
                    .text_input => |t| {
                        // Ctrl+字母为快捷键, 不插入文本
                        if (self.key_mods.ctrl) continue;
                        if (self.typed_cp_count < self.typed_cps.len) {
                            self.typed_cps[self.typed_cp_count] = t.codepoint;
                            self.typed_cp_count += 1;
                        }
                        self.invalidate();
                    },
                    .mouse_move => |m| {
                        self.mouse_x = @floatFromInt(m.x);
                        self.mouse_y = @floatFromInt(m.y);
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
                        } else if (mb.button == .right and mb.state == .pressed) {
                            // right_clicked 暂未跟踪 (与 Linux 对齐可加)
                        }
                        self.invalidate();
                    },
                    else => {},
                }
            }

            if (!self.running) break;

            // 3. 重绘决策
            if (!self.continuous and !self.needs_redraw) {
                // 让出 CPU: Win32 消息驱动, 无消息时不必忙等
                win32.sleep(1);
                continue;
            }

            // 4. 开始帧
            const size = self.gpu_device.beginFrame() orelse {
                // 交换链重建失败, 跳过本帧
                self.needs_redraw = false;
                continue;
            };
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
            self.scroll_delta_clear();
            self.typed_cp_count = 0;
            self.key_hit = null;
            self.needs_redraw = false;

            // 6. 提交帧 (Present)
            self.gpu_device.endFrame();

            // 7. 子窗口渲染: 每个子窗口独立 beginFrame → on_draw → submit → endFrame
            var it = self.sub_windows.iterator();
            while (it.next()) |entry| {
                const win = entry.value_ptr.*.window;
                // 处理子窗口自身事件队列 (鼠标/键盘/关闭等)
                win.processEvents();
                if (win.should_close) {
                    // 子窗口被关闭: 销毁并移除
                    win.deinit();
                    entry.value_ptr.*.backend.destroyWindow();
                    _ = self.sub_windows.remove(entry.key_ptr.*);
                    continue;
                }
                const sw_size = win.beginFrame() orelse continue;
                _ = sw_size;
                win.getRenderer().beginFrame();
                if (win.on_draw) |cb| cb(win);
                win.getRenderer().submit();
                win.endFrame();
            }
        }
    }

    fn scroll_delta_clear(self: *App) void {
        _ = self;
    }

    pub fn getRenderer(self: *App) *renderer2d.Renderer2D {
        return &self.renderer;
    }

    pub fn getFramebufferSize(self: *const App) math.Size(u32) {
        return .{ .width = self.fb_width, .height = self.fb_height };
    }

    /// 高 DPI 缩放因子 (逻辑坐标 × scale = 物理像素; 普通屏为 1.0)
    pub fn getScaleFactor(self: *const App) f32 {
        return self.scale_factor;
    }

    pub fn getMainWindowId(self: *const App) u32 {
        _ = self;
        return 0;
    }

    pub fn invalidate(self: *App) void {
        self.needs_redraw = true;
    }

    /// 返回本帧累积的文本输入 codepoint 切片
    pub fn typedCodepoints(self: *const App) []const u21 {
        return self.typed_cps[0..self.typed_cp_count];
    }

    // ── 子窗口 API (签名对齐 Linux App, Windows 下真正可用) ──
    pub fn createSubWindow(self: *App, title: []const u8, width: u32, height: u32) !u32 {
        if (!is_windows) return error.NotImplemented;

        const id = self.next_sub_id;
        self.next_sub_id += 1;

        // 1. 创建独立 Win32 子窗口 (独立 HWND + 事件队列)
        const backend = try self.backend.win32.createSubWindow(self.allocator, id, title, width, height);
        errdefer backend.destroyWindow();

        // 2. 创建 Window (独立 GPU 设备 / 渲染器 / 字形图集)
        const surface = backend.getSurfaceInfo();
        const hwnd: *anyopaque = surface.win32.hwnd;
        const hinst: *anyopaque = surface.win32.hinstance;

        const win = try window_mod.Window.initWin32(
            self.allocator,
            hwnd,
            hinst,
            id,
            title,
            width,
            height,
            self.scale_factor,
        );
        errdefer win.deinit();

        // 3. 关联事件队列: 子窗口 backend 的事件推送给 Window 的事件队列
        backend.event_queue = &win.event_queue;

        try self.sub_windows.put(id, .{ .window = win, .backend = backend });
        return id;
    }

    pub fn showSubWindow(self: *App, wid: u32) void {
        if (self.sub_windows.get(wid)) |entry| entry.backend.showWindow();
    }
    pub fn hideSubWindow(self: *App, wid: u32) void {
        if (self.sub_windows.get(wid)) |entry| entry.backend.hideWindow();
    }
    pub fn setSubWindowTitle(self: *App, wid: u32, title: []const u8) void {
        if (self.sub_windows.get(wid)) |entry| entry.backend.setTitleWindow(title);
    }
    pub fn setSubWindowTransientFor(self: *App, wid: u32, parent: u32) void {
        if (!is_windows) return;
        if (self.sub_windows.get(wid)) |entry| {
            const owner: ?*anyopaque = if (parent == 0)
                @ptrCast(self.backend.win32.hwnd)
            else
                @ptrCast(if (self.sub_windows.get(parent)) |p| p.backend.hwnd else null);
            entry.backend.setOwner(owner);
        }
    }
    pub fn getSubWindow(self: *App, wid: u32) ?*window_mod.Window {
        if (self.sub_windows.get(wid)) |entry| return entry.window;
        return null;
    }
    pub fn destroySubWindow(self: *App, wid: u32) void {
        if (self.sub_windows.getEntry(wid)) |*entry| {
            entry.value_ptr.*.window.deinit();
            entry.value_ptr.*.backend.destroyWindow();
            _ = self.sub_windows.remove(wid);
        }
    }
};
