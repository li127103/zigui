//! zigui - 跨平台 GPU 加速 GUI 框架
//! 支持 Windows (Win32+D3D11) / Linux (X11+Wayland+Vulkan) / macOS (Cocoa+Metal)

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
pub const app = @import("app.zig");

// macOS 平台特定导出
pub const cocoa = @import("pal/cocoa.zig");
pub const metal = @import("gpu/metal.zig");
pub const renderer = @import("render2d/renderer.zig");

// 文本引擎 (macOS CoreText)
pub const coretext = @import("text/coretext.zig");
pub const glyph_atlas = @import("text/atlas.zig");
pub const text_layout = @import("text/layout.zig");

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
