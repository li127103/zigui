//! zigui - 跨平台 GPU 加速 GUI 框架
//! 支持 Windows (Win32+D3D11) / Linux (X11+Wayland+Vulkan) / macOS (Cocoa+Metal)

pub const pal = @import("pal/pal.zig");
pub const gpu = @import("gpu/hal.zig");
pub const render2d = @import("render2d/engine.zig");
pub const text = @import("text/font.zig");
pub const widget = @import("widget/widget.zig");
pub const layout = @import("layout/engine.zig");
pub const theme = @import("theme/theme.zig");
pub const animation = @import("animation/animation.zig");
pub const input = @import("input/event_queue.zig");
pub const math = @import("math.zig");
pub const app = @import("app.zig");

// macOS 平台特定导出
pub const cocoa = @import("pal/cocoa.zig");
pub const metal = @import("gpu/metal.zig");
pub const renderer = @import("render2d/renderer.zig");

test {
    _ = math;
    _ = pal;
}
