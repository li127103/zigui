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

// 性能监控 (帧时间统计)
pub const perf = @import("perf.zig");
pub const shortcut = @import("shortcut.zig");
pub const dnd = @import("dnd.zig");
pub const builder = @import("builder.zig");
pub const window = @import("window.zig");

// 平台特定 App
pub const app = if (is_windows) @import("app_windows.zig") else if (is_linux) @import("app_linux.zig") else @import("app.zig");

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
pub const text_layout_ft = if (is_linux) @import("text/layout_ft.zig") else void;

// Windows 平台特定导出
pub const win32 = if (is_windows) @import("pal/win32.zig") else void;
pub const d3d11 = if (is_windows) @import("gpu/d3d11.zig") else void;
pub const d3d11_renderer = if (is_windows) @import("render2d/d3d11_renderer.zig") else void;
pub const dwrite = if (is_windows) @import("text/dwrite.zig") else void;
pub const atlas_d3d11 = if (is_windows) @import("text/atlas_d3d11.zig") else void;

// 文本对齐 (平台无关, 供 macOS/Linux 布局模块共享)
pub const text_align = @import("text/align.zig");

// 跨平台文本 helper (字体创建 + 布局 + 绘制)
pub const styled_text = @import("text/styled_text.zig");

// 跨平台渲染抽象层 (Renderer2D/Device 平台别名)
pub const r2d = @import("render2d/r2d.zig");

// 图片
pub const image = @import("image/png.zig");

// 控件
pub const label = @import("widget/label.zig");
pub const button = @import("widget/button.zig");
pub const icons = @import("widget/icons.zig");
pub const container = @import("widget/container.zig");
pub const canvas = @import("widget/canvas.zig");
pub const slider = @import("widget/slider.zig");
pub const scale = @import("widget/scale.zig");
pub const text_input = @import("widget/text_input.zig");
pub const combo_box = @import("widget/combo_box.zig");
pub const list_view = @import("widget/list_view.zig");
pub const tab_view = @import("widget/tab_view.zig");
pub const dialog = @import("widget/dialog.zig");
pub const assistant = @import("widget/assistant.zig");
pub const tooltip = @import("widget/tooltip.zig");
pub const tooltip_controller = @import("widget/tooltip_controller.zig");
pub const context_menu = @import("widget/context_menu.zig");
pub const text_area = @import("widget/text_area.zig");
pub const menu = @import("widget/menu.zig");
pub const split_view = @import("widget/split_view.zig");
pub const tree_view = @import("widget/tree_view.zig");
pub const table = @import("widget/table.zig");

// 新增控件 (阶段1: 补齐技术文档 §7.2 缺失控件)
pub const checkbox = @import("widget/checkbox.zig");
pub const radio = @import("widget/radio.zig");
pub const switch_widget = @import("widget/switch.zig");
pub const progress_bar = @import("widget/progress_bar.zig");
pub const spinner = @import("widget/spinner.zig");
pub const image_widget = @import("widget/image.zig");
pub const scroll_bar = @import("widget/scroll_bar.zig");
pub const scroll_view = @import("widget/scroll_view.zig");
pub const separator = @import("widget/separator.zig");
pub const status_bar = @import("widget/status_bar.zig");
pub const expander = @import("widget/expander.zig");
pub const message_dialog = @import("widget/message_dialog.zig");
pub const spin_button = @import("widget/spin_button.zig");
pub const toggle_button = @import("widget/toggle_button.zig");
pub const link_button = @import("widget/link_button.zig");
pub const grid = @import("widget/grid.zig");
pub const menu_bar = @import("widget/menu_bar.zig");
pub const stack = @import("widget/stack.zig");
pub const frame = @import("widget/frame.zig");
pub const file_chooser = @import("widget/file_chooser.zig");
pub const color_button = @import("widget/color_button.zig");
pub const color_chooser = @import("widget/color_chooser.zig");
pub const font_button = @import("widget/font_button.zig");
pub const font_chooser = @import("widget/font_chooser.zig");
pub const center_box = @import("widget/center_box.zig");
pub const flow_box = @import("widget/flow_box.zig");
pub const overlay = @import("widget/overlay.zig");
pub const revealer = @import("widget/revealer.zig");
pub const aspect_frame = @import("widget/aspect_frame.zig");
pub const stack_switcher = @import("widget/stack_switcher.zig");
pub const size_group = @import("widget/size_group.zig");
pub const popover = @import("widget/popover.zig");
pub const action_bar = @import("widget/action_bar.zig");
pub const header_bar = @import("widget/header_bar.zig");
pub const fixed = @import("widget/fixed.zig");
pub const info_bar = @import("widget/info_bar.zig");
pub const search_entry = @import("widget/search_entry.zig");
pub const search_bar = @import("widget/search_bar.zig");
pub const menu_button = @import("widget/menu_button.zig");
pub const drop_down = @import("widget/drop_down.zig");
pub const level_bar = @import("widget/level_bar.zig");
pub const calendar = @import("widget/calendar.zig");
pub const list_box = @import("widget/list_box.zig");
pub const about_dialog = @import("widget/about_dialog.zig");
pub const volume_button = @import("widget/volume_button.zig");
pub const app_chooser_button = @import("widget/app_chooser_button.zig");
pub const shortcut_label = @import("widget/shortcut_label.zig");
pub const emoji_chooser = @import("widget/emoji_chooser.zig");
pub const file_chooser_button = @import("widget/file_chooser_button.zig");

// 控件背景 (颜色/图片, 框架自主绘制)
pub const background = @import("widget/background.zig");

// 系统剪贴板 (Ctrl+C/V 复制粘贴)
pub const clipboard = @import("pal/clipboard.zig");

test {
    _ = math;
    _ = pal;
    _ = layout;
    _ = animation;
    _ = widget;
    _ = dirty;
    _ = builder;
    _ = split_view;
    _ = tree_view;
    _ = table;
    _ = image;
    _ = gesture;
    _ = input;
    _ = text_align;
    _ = background;
    _ = checkbox;
    _ = radio;
    _ = switch_widget;
    _ = progress_bar;
    _ = spinner;
    _ = image_widget;
    _ = scroll_bar;
    _ = scroll_view;
    _ = separator;
    _ = status_bar;
    _ = expander;
    _ = message_dialog;
    _ = spin_button;
    _ = toggle_button;
    _ = link_button;
    _ = grid;
    _ = stack;
    _ = frame;
    _ = center_box;
    _ = flow_box;
    _ = overlay;
    _ = revealer;
    _ = aspect_frame;
    _ = stack_switcher;
    _ = size_group;
    _ = popover;
    _ = action_bar;
    _ = header_bar;
    _ = fixed;
    _ = list_box;
    _ = about_dialog;
    _ = volume_button;
    _ = app_chooser_button;
    _ = shortcut_label;
    _ = emoji_chooser;
    _ = file_chooser_button;
    _ = perf;
    if (is_linux) {
        _ = x11;
        _ = wayland;
        _ = atlas_vulkan;
    }
}
