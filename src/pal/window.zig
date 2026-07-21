//! 窗口抽象

const math = @import("../math.zig");

pub const Window = struct {
    handle: NativeHandle,
    size: math.Size(u32),
    scale_factor: f32,

    pub const NativeHandle = union(enum) {
        hwnd: *anyopaque,
        x11_window: u32,
        wayland_surface: *anyopaque,
        ns_window: *anyopaque,
    };

    pub fn getSurfaceInfo(self: Window) SurfaceInfo {
        return switch (self.handle) {
            .hwnd => |h| .{ .win32 = .{ .hinstance = h, .hwnd = h } },
            .x11_window => |w| .{ .x11 = .{ .display = undefined, .window = w } },
            .wayland_surface => |s| .{ .wayland = .{ .display = undefined, .surface = s } },
            .ns_window => |w| .{ .cocoa = .{ .layer = w } },
        };
    }
};

pub const SurfaceInfo = union(enum) {
    win32: struct { hinstance: *anyopaque, hwnd: *anyopaque },
    x11: struct { display: *anyopaque, window: u32 },
    wayland: struct { display: *anyopaque, surface: *anyopaque },
    cocoa: struct { layer: *anyopaque },
};

pub const WindowDesc = struct {
    title: []const u8 = "zigui",
    width: u32 = 800,
    height: u32 = 600,
    min_width: ?u32 = null,
    min_height: ?u32 = null,
    max_width: ?u32 = null,
    max_height: ?u32 = null,
    resizable: bool = true,
    decorated: bool = true,
    transparent: bool = false,
    always_on_top: bool = false,
    visible: bool = true,
};
