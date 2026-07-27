//! Win32 窗口后端 (Windows) - 骨架实现
//!
//! 负责窗口创建、事件循环、输入处理。接口与 Wayland/X11/Cocoa 后端对齐,
//! 由 pal.zig 在 Windows 平台下选择使用。
//!
//! 当前状态: 结构骨架, 所有方法返回 NotImplemented, 待 M5 实现。

const std = @import("std");
const builtin = @import("builtin");
const is_windows = builtin.os.tag == .windows;

const event_mod = @import("event.zig");
const win_mod = @import("window.zig");

const win32 = if (is_windows) @cImport({
    @cDefine("WIN32_LEAN_AND_MEAN", "1");
    @cInclude("windows.h");
}) else void;

pub const Win32Backend = struct {
    allocator: std.mem.Allocator,
    hwnd: if (is_windows) ?win32.HWND else void = null,
    width: u32 = 800,
    height: u32 = 600,
    should_close: bool = false,
    scale_factor: f32 = 1.0,
    // 事件队列 (由 pal 层在 init 后设置)
    event_queue: ?*@import("pal.zig").EventQueue = null,
    // 输入状态
    mods: event_mod.Modifiers = .{},
    pointer_x: f64 = 0,
    pointer_y: f64 = 0,

    pub fn init(allocator: std.mem.Allocator) !Win32Backend {
        if (!is_windows) return error.NotImplemented;
        _ = allocator;
        return error.NotImplemented;
    }

    pub fn deinit(self: *Win32Backend) void {
        _ = self;
    }

    pub fn createWindow(self: *Win32Backend, title: []const u8, width: u32, height: u32) !void {
        _ = self;
        _ = title;
        _ = width;
        _ = height;
        return error.NotImplemented;
    }

    pub fn getSurfaceInfo(self: *Win32Backend) win_mod.SurfaceInfo {
        return .{
            .type = .win32,
            .win32 = .{
                .hwnd = @ptrFromInt(0),
                .hinstance = @ptrFromInt(0),
            },
            .width = self.width,
            .height = self.height,
            .scale_factor = self.scale_factor,
        };
    }

    pub fn getScaleFactor(self: *const Win32Backend) f32 {
        return self.scale_factor;
    }

    pub fn pollEvents(self: *Win32Backend) void {
        _ = self;
    }

    pub fn shouldClose(self: *const Win32Backend) bool {
        return self.should_close;
    }

    pub fn setTitle(self: *Win32Backend, title: []const u8) void {
        _ = self;
        _ = title;
    }

    pub fn setSize(self: *Win32Backend, width: u32, height: u32) void {
        _ = self;
        _ = width;
        _ = height;
    }

    fn pushEvent(self: *Win32Backend, ev: event_mod.Event) void {
        if (self.event_queue) |q| {
            q.push(self.allocator, ev) catch {};
        }
    }
};
