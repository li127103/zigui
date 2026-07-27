//! Windows 应用主循环 (Win32 + D3D11) - 骨架实现
//!
//! 一站式入口: 封装窗口创建、D3D11 设备初始化、消息循环、渲染调度、事件分发。
//! 接口与 macOS (app.zig) / Linux (app_linux.zig) App 对齐。
//!
//! 当前状态: 结构骨架, 待 M5 实现。

const std = @import("std");
const builtin = @import("builtin");
const is_windows = builtin.os.tag == .windows;

const math = @import("math.zig");
const pal = @import("pal/pal.zig");
const win32 = @import("pal/win32.zig");
const d3d11 = @import("gpu/d3d11.zig");
const renderer2d = @import("render2d/engine.zig");
const dwrite = @import("text/dwrite.zig");
const atlas_mod = @import("text/atlas_d3d11.zig");
const widget_mod = @import("widget/widget.zig");
const input = @import("input/event_queue.zig");
const theme = @import("theme/theme.zig");
const perf = @import("perf.zig");

pub const AppConfig = struct {
    title: []const u8 = "zigui App",
    width: u32 = 800,
    height: u32 = 600,
    vsync: bool = true,
    resizable: bool = true,
};

pub const App = struct {
    allocator: std.mem.Allocator,
    config: AppConfig,
    event_queue: input.EventQueue,
    backend: union(enum) {
        win32: win32.Win32Backend,
    },
    d3d_device: d3d11.D3D11Device,
    renderer: renderer2d.Renderer2D,
    glyph_atlas: atlas_mod.GlyphAtlas,
    root_widget: ?*widget_mod.Widget = null,
    theme: theme.Theme,
    frame_stats: perf.FrameStats,
    scale_factor: f32 = 1.0,
    running: bool = true,

    pub fn init(allocator: std.mem.Allocator, config: AppConfig) !App {
        if (!is_windows) return error.NotImplemented;
        _ = allocator;
        _ = config;
        return error.NotImplemented;
    }

    pub fn deinit(self: *App) void {
        _ = self;
    }

    pub fn setRoot(self: *App, root: *widget_mod.Widget) void {
        self.root_widget = root;
    }

    pub fn run(self: *App) void {
        _ = self;
    }

    pub fn getScaleFactor(self: *const App) f32 {
        return self.scale_factor;
    }
};
