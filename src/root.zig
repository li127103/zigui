//! zigui - 跨平台 GPU 加速 GUI 框架
//! 支持 Windows (Win32+D3D11) / Linux (X11+Wayland+Vulkan) / macOS (Cocoa+Metal)

const builtin = @import("builtin");
const is_linux = builtin.os.tag == .linux;
const is_macos = builtin.os.tag == .macos;
const is_windows = builtin.os.tag == .windows;

pub const pal = @import("pal/pal.zig");
pub const gpu = @import("gpu/hal.zig");
pub const render2d = @import("render2d/engine.zig");
pub const dirty = @import("render2d/dirty.zig");
pub const text = @import("text/font.zig");
pub const widget = @import("widget/widget.zig");
pub const layout = @import("layout/engine.zig");
pub const theme = @import("theme/theme.zig");
pub const animation = @import("animation/animation.zig");
pub const input = @import("input/event_queue.zig");
pub const gesture = @import("input/gesture.zig");
pub const math = @import("math.zig");

// 平台特定 App
pub const app = if (is_linux) @import("app_linux.zig") else @import("app.zig");

// macOS 平台特定导出
pub const cocoa = if (is_macos) @import("pal/cocoa.zig") else void;
pub const metal = if (is_macos) @import("gpu/metal.zig") else void;
pub const renderer = if (is_macos) @import("render2d/renderer.zig") else void;

// 文本引擎 (macOS CoreText)
pub const coretext = if (is_macos) @import("text/coretext.zig") else void;
pub const glyph_atlas = if (is_macos) @import("text/atlas.zig") else void;
pub const text_layout = if (is_macos) @import("text/layout.zig") else void;

// Linux 平台特定导出
pub const x11 = if (is_linux) @import("pal/x11.zig") else void;
pub const wayland = if (is_linux) @import("pal/wayland.zig") else void;
pub const vulkan = if (is_linux) @import("gpu/vulkan.zig") else void;
pub const freetype = if (is_linux) @import("text/freetype.zig") else void;
pub const atlas_vulkan = if (is_linux) @import("text/atlas_vulkan.zig") else void;
pub const vulkan_renderer = if (is_linux) @import("render2d/vulkan_renderer.zig") else void;

// 图片
pub const image = @import("image/png.zig");

// 控件
pub const label = @import("widget/label.zig");
pub const button = @import("widget/button.zig");
pub const container = @import("widget/container.zig");
pub const slider = @import("widget/slider.zig");
pub const text_input = @import("widget/text_input.zig");
pub const combo_box = @import("widget/combo_box.zig");
pub const list_view = @import("widget/list_view.zig");
pub const tab_view = @import("widget/tab_view.zig");
pub const dialog = @import("widget/dialog.zig");
pub const tooltip = @import("widget/tooltip.zig");
pub const text_area = @import("widget/text_area.zig");
pub const menu = @import("widget/menu.zig");
pub const split_view = @import("widget/split_view.zig");
pub const tree_view = @import("widget/tree_view.zig");
pub const table = @import("widget/table.zig");

test {
    _ = math;
    _ = pal;
    _ = layout;
    _ = animation;
    _ = widget;
    _ = dirty;
    _ = split_view;
    _ = tree_view;
    _ = table;
    _ = image;
    _ = gesture;
    _ = input;
}
