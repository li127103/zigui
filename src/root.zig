//! zigui - 跨平台 GPU 加速 GUI 框架
//! 支持 Windows (Win32+D3D12/D3D11) / Linux (X11+Wayland+Vulkan) / macOS (Cocoa+Metal)

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

// P2 模型层 (GTK4 Gio.ListModel / GtkSelectionModel / GtkListItemFactory)
// 不要别名 - 全部通过模块路径访问，例如 model.list_model.ListModel
pub const model = struct {
    pub const list_model = @import("model/list_model.zig");
    pub const selection_model = @import("model/selection_model.zig");
    pub const list_item_factory = @import("model/list_item_factory.zig");
    pub const adjustment = @import("model/adjustment.zig");
    pub const filter_list_model = @import("model/filter_list_model.zig");
    pub const sort_list_model = @import("model/sort_list_model.zig");
    pub const map_list_model = @import("model/map_list_model.zig");
    pub const tree_list_model = @import("model/tree_list_model.zig");
    pub const slice_flatten = @import("model/slice_flatten_list_model.zig");
    pub const directory_list = @import("model/directory_list.zig");
    pub const bookmark_list = @import("model/bookmark_list.zig");
    pub const string_list = @import("model/string_list.zig");
    pub const action = @import("model/action.zig");
    pub const menu_model = @import("model/menu_model.zig");
    // Expression — 属性路径求值 (模块路径访问, 无类型别名)
    pub const expression = @import("model/expression.zig");
    // Editable + EntryBuffer/TextBuffer + EditableIface (GTK4 可编辑接口)
    pub const editable = @import("model/editable.zig");
    // GTK4 Bitset — SelectionModel 底层 bitset 存储
    pub const bitset = @import("model/bitset.zig");
    // GTK4 SectionModel 分段模型
    pub const section_model = @import("model/section_model.zig");
    // GTK4 MultiSorter 多优先级组合排序器
    pub const multi_sorter = @import("model/multi_sorter.zig");
    // 【P29 新增】SliceListModel（分页切片）+ FlattenListModel（嵌套展平）
    pub const slice_flatten_list_model = @import("model/slice_flatten_list_model.zig");
    // GTK4 SignalListModel: 多回调槽的 items-changed 信号
    pub const signal_list_model = @import("model/signal_list_model.zig");
    // GtkFileFilter — MIME/glob/pattern 文件过滤器
    pub const file_filter = @import("model/file_filter.zig");
    // GtkRecentManager / RecentInfo — 最近使用文件管理
    pub const recent_manager = @import("model/recent_manager.zig");
    // GtkTextTag / GtkTextTagTable — 富文本样式标签
    pub const text_tag = @import("model/text_tag.zig");
    // GTK4 Launcher 系列: FileLauncher / UriLauncher / ColorDialogLauncher / FontDialogLauncher / AlertDialogLauncher
    pub const launcher = @import("model/launcher.zig");
    // GTK4 Print 核心数据结构: PaperSize / PrintSettings / PageSetup
    pub const print = @import("model/print.zig");
    // GTK4 PrintOperation: 打印运行时操作
    pub const print_operation = @import("model/print_operation.zig");
    // GTK3→GTK4 兼容传统树模型: TreeModel / TreeStore / ListStore / TreeIter / TreePath / GValue
    pub const tree_model = @import("model/tree_model.zig");
};

// GTK4 风格应用层 (GtkApplication / GtkApplicationWindow)
pub const application = @import("application.zig");

// 平台特定 App
pub const app = if (is_windows) @import("app_windows.zig") else if (is_linux) @import("app_linux.zig") else @import("app_macos.zig");

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
pub const vulkan = if (is_linux or is_windows) @import("gpu/vulkan.zig") else void;
pub const freetype = if (is_linux) @import("text/freetype.zig") else void;
pub const atlas_vulkan = if (is_linux) @import("text/atlas_vulkan.zig") else void;
pub const atlas_vulkan_win32 = if (is_windows) @import("text/atlas_vulkan_win32.zig") else void;
pub const vulkan_renderer = if (is_linux or is_windows) @import("render2d/vulkan_renderer.zig") else void;
pub const text_layout_ft = if (is_linux) @import("text/layout_ft.zig") else void;

// Windows 平台特定导出
pub const win32 = if (is_windows) @import("pal/win32.zig") else void;
pub const d3d11 = if (is_windows) @import("gpu/d3d11.zig") else void;
pub const d3d12 = if (is_windows) @import("gpu/d3d12.zig") else void;
pub const d3d11_renderer = if (is_windows) @import("render2d/d3d11_renderer.zig") else void;
pub const d3d_renderer = if (is_windows) @import("render2d/d3d_renderer.zig") else void;
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
pub const drawing_area = @import("widget/drawing_area.zig");
pub const slider = @import("widget/slider.zig");
pub const scale = @import("widget/scale.zig");
pub const entry = @import("widget/entry.zig");
pub const combo_box = @import("widget/combo_box.zig");
pub const list_view = @import("widget/list_view.zig");
pub const notebook = @import("widget/notebook.zig");
pub const dialog = @import("widget/dialog.zig");
pub const assistant = @import("widget/assistant.zig");
pub const tooltip = @import("widget/tooltip.zig");
pub const tooltip_controller = @import("widget/tooltip_controller.zig");
pub const context_menu = @import("widget/context_menu.zig");
pub const text_view = @import("widget/text_view.zig");
pub const menu = @import("widget/menu.zig");
pub const split_view = @import("widget/split_view.zig");
pub const tree_view = @import("widget/tree_view.zig");
pub const table = @import("widget/table.zig");

// 新增控件 (阶段1: 补齐技术文档 §7.2 缺失控件)
pub const check_button = @import("widget/check_button.zig");
pub const radio_button = @import("widget/radio_button.zig");
pub const switch_widget = @import("widget/switch.zig");
pub const progress_bar = @import("widget/progress_bar.zig");
pub const spinner = @import("widget/spinner.zig");
pub const image_widget = @import("widget/image.zig");
pub const scrolled_window = @import("widget/scrolled_window.zig");
pub const separator = @import("widget/separator.zig");
pub const statusbar = @import("widget/statusbar.zig");
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
pub const popover_menu = @import("widget/popover_menu.zig");
pub const action_bar = @import("widget/action_bar.zig");
pub const header_bar = @import("widget/header_bar.zig");
pub const fixed = @import("widget/fixed.zig");
pub const info_bar = @import("widget/info_bar.zig");
pub const search_entry = @import("widget/search_entry.zig");
pub const search_bar = @import("widget/search_bar.zig");
pub const filter_list_bar = @import("widget/filter_list_bar.zig");
pub const menu_button = @import("widget/menu_button.zig");
pub const drop_down = @import("widget/drop_down.zig");
pub const level_bar = @import("widget/level_bar.zig");
pub const calendar = @import("widget/calendar.zig");
pub const list_box = @import("widget/list_box.zig");
pub const about_dialog = @import("widget/about_dialog.zig");
pub const volume_button = @import("widget/volume_button.zig");
pub const app_chooser_button = @import("widget/app_chooser_button.zig");
pub const shortcut_label = @import("widget/shortcut_label.zig");
pub const shortcut_controller = @import("widget/shortcut_controller.zig");
pub const emoji_chooser = @import("widget/emoji_chooser.zig");
pub const file_chooser_button = @import("widget/file_chooser_button.zig");
pub const toolbar = @import("widget/toolbar.zig");
pub const shortcuts_window = @import("widget/shortcuts_window.zig");
pub const password_entry = @import("widget/password_entry.zig");
pub const scale_button = @import("widget/scale_button.zig");
pub const stack_sidebar = @import("widget/stack_sidebar.zig");
pub const window_controls = @import("widget/window_controls.zig");
pub const places_sidebar = @import("widget/places_sidebar.zig");
pub const lock_button = @import("widget/lock_button.zig");
pub const color_dialog_button = @import("widget/color_dialog_button.zig");
pub const font_dialog_button = @import("widget/font_dialog_button.zig");
pub const alert_dialog = @import("widget/alert_dialog.zig");
pub const picture = @import("widget/picture.zig");
pub const inscription = @import("widget/inscription.zig");
pub const paned = @import("widget/paned.zig");
pub const split_button = @import("widget/split_button.zig");
pub const window_handle = @import("widget/window_handle.zig");
pub const color_dialog = @import("widget/color_dialog.zig");
pub const font_dialog = @import("widget/font_dialog.zig");
pub const file_dialog = @import("widget/file_dialog.zig");
pub const tree_expander = @import("widget/tree_expander.zig");

// 阶段十 (P1)
pub const column_view = @import("widget/column_view.zig");
pub const grid_view = @import("widget/grid_view.zig");
pub const popover_menu_bar = @import("widget/popover_menu_bar.zig");
pub const gl_area = @import("widget/gl_area.zig");
pub const video = @import("widget/video.zig");

// P21: GTK4 特色控件补全
// GtkBox —— 标准 GTK4 布局容器 (append/prepend/remove/set_homogeneous)
pub const box = @import("widget/box.zig");
// GtkRecentChooserWidget —— 最近使用文件列表控件
pub const recent_chooser = @import("widget/recent_chooser.zig");

// P22: GTK4 高级交互与布局
// GtkGesture* 系列: GestureClick / GestureDrag / GestureLongPress / GestureZoom
pub const gesture_widget = @import("widget/gesture.zig");
// GtkConstraintLayout 约束布局
pub const constraint_layout = @import("widget/constraint_layout.zig");
// GtkAppChooserDialog / GtkColorChooserDialog / GtkFontChooserDialog
pub const chooser_dialogs = @import("widget/chooser_dialogs.zig");

// P23: 核心系统补全
// GtkEntryCompletion — Entry 自动补全
pub const entry_completion = @import("widget/entry_completion.zig");
// GtkIconView — 图标视图控件
pub const icon_view = @import("widget/icon_view.zig");
// GtkDragSource / GtkDropTarget + DragDropManager
pub const drag_drop = @import("widget/drag_drop.zig");
// EventControllerFocus / EventControllerMotion / EventControllerScroll
pub const event_controllers = @import("widget/event_controllers.zig");
// PrintDialog — 打印对话框控件
pub const print_dialog = @import("widget/print_dialog.zig");

// P24: 补漏（已存在实现但漏导出 + 兼容传统树模型）
// GtkAppChooserWidget — 应用选择控件（含 AppChooserButton 独立按钮版本）
pub const app_chooser = @import("widget/app_chooser.zig");
// GtkFontSelection — 字体选择控件（独立对象，供 FontChooser/FontButton/FontDialog 底层复用）
pub const font_selection = @import("widget/font_selection.zig");
// GtkToolPalette — 工具面板分组控件（组可折叠，组内按钮网格，配合 ToolItemGroup 模式）
pub const tool_palette = @import("widget/tool_palette.zig");
// GtkFileChooserNative — 跨平台原生文件对话框接口（优先原生 XDG/NSOpenPanel，回退内部实现）
pub const file_chooser_native = @import("widget/file_chooser_native.zig");
// ShortcutManager — 应用全局统一快捷键管理（GTK4 ShortcutManager 风格）
pub const shortcut_manager = @import("widget/shortcut_manager.zig");

// P25: GTK4 通用接口 + 打印运行
// GTK4 通用接口: Orientable / Scrollable / Root / Toplevel (类型擦除 + vtable 模式)
pub const gtk_interfaces = @import("widget/gtk_interfaces.zig");
// GtkPageSetupUnixDialog — Unix 页面设置对话框（纸张/方向/边距 + 预览）
pub const page_setup_unix_dialog = @import("widget/page_setup_unix_dialog.zig");

// P26: 可绘制对象 + 布局管理器
// GdkPaintable — 可绘制对象接口（TexturePaintable/SymbolPaintable/EmptyPaintable）
pub const paintable = @import("widget/paintable.zig");
// GtkLayoutManager 家族: BoxLayout/CenterLayout/GridLayout/OverlayLayout/BinLayout/FixedLayout/CustomLayout
pub const layout_manager = @import("widget/layout_manager.zig");

// P27: 打印对话框 + 输入法上下文 + 分段模型 + 导出补漏
// GtkPrintUnixDialog — UNIX 打印对话框（打印机/份数/范围/双面/质量 + 页设置按钮）
pub const print_unix_dialog = @import("widget/print_unix_dialog.zig");
// GtkIMContext 家族: IMContext / IMMulticontext / IMContextSimple (Compose Key / 死键)
pub const im_context = @import("widget/im_context.zig");

// P28: GTK4 全局底层 & 核心抽象补全（Settings / Display / Clipboard / Texture / NativeDialog / ConstraintGuide）
// GtkSettings — 全局显示/样式/动画设置单例
pub const gtk_settings = @import("widget/settings.zig");
// GdkDisplayManager + GdkDisplay + GdkMonitor — 显示/屏幕抽象（PAL 可注入具体实现）
pub const gdk_display = @import("widget/display.zig");
// GdkClipboard — 剪贴板（widget 层 GTK 命名包装，底层委托 pal/clipboard.zig）
pub const gdk_clipboard = @import("widget/clipboard.zig");
// GdkTexture + GdkMemoryTexture + GdkTextureDownloader — 纹理/像素（Paintable 可绘制对象）
pub const gdk_texture = @import("widget/texture.zig");
// GtkNativeDialog — 原生对话框接口基类（FileChooserNative / PrintUnixDialog 等可继承）
pub const gtk_native_dialog = @import("widget/native_dialog.zig");

// P29: CellRenderer 家族 + GTK3 兼容渲染器
pub const cell_renderer = @import("widget/cell_renderer.zig");

// P30: 控件 & 辅助对象补全
pub const editable_label = @import("widget/editable_label.zig");
pub const tree_view_column = @import("widget/tree_view_column.zig");
pub const tree_selection = @import("widget/tree_selection.zig");
pub const widget_paintable = @import("widget/widget_paintable.zig");
pub const scroll_info = @import("widget/scroll_info.zig");

// P31: Range / Scrollbar + 媒体管线（video/gl_area/emoji_chooser 已存在）
pub const range = @import("widget/range.zig");
pub const scrollbar = @import("widget/scrollbar.zig");
pub const media_stream = @import("widget/media_stream.zig");
pub const media_file = @import("widget/media_file.zig");
pub const media_controls = @import("widget/media_controls.zig");

// P32: 样式系统 3 件套（WidgetPath/CssProvider/StyleContext）（bitset/selection_model 已在 model 命名空间导出）
pub const widget_path = @import("widget/widget_path.zig");
pub const css_provider = @import("widget/css_provider.zig");
pub const style_context = @import("widget/style_context.zig");

// P33: 打印/离屏/快捷键对象 + 补漏 accessible
// GtkPrinter — 打印机对象（抽象系统打印机或虚拟打印机，供 PrintUnixDialog 选用）
pub const printer = @import("widget/printer.zig");
// GtkPrintJob — 打印作业（标题+打印机+设置+状态机，send/cancel/tick 推进）
pub const print_job = @import("widget/print_job.zig");
// GtkGraphicsOffload — GTK4.14 离屏渲染容器（子控件树→GPU纹理→一次贴图，性能优化）
pub const graphics_offload = @import("widget/graphics_offload.zig");
// GtkShortcutTrigger / GtkShortcutAction / GtkShortcut — 细粒度快捷键对象（触发条件+动作，组合挂 ShortcutController）
pub const shortcut_trigger = @import("widget/shortcut_trigger.zig");
// GtkAccessible - 无障碍接口补漏导出（AT-SPI 兼容，Role/State/Relation/属性查询）
pub const accessible = @import("accessibility/accessible.zig");
// P42: GtkSnapshot + GskRenderNode 桥接层（场景图 -> DrawCmd 列表）
pub const snapshot = @import("widget/snapshot.zig");

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
    _ = check_button;
    _ = radio_button;
    _ = switch_widget;
    _ = progress_bar;
    _ = spinner;
    _ = image_widget;
    _ = scrolled_window;
    _ = separator;
    _ = statusbar;
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
    _ = shortcut_controller;
    _ = emoji_chooser;
    _ = file_chooser_button;
    _ = toolbar;
    _ = shortcuts_window;
    _ = search_entry;
    _ = search_bar;
    _ = filter_list_bar;
    _ = menu_button;
    _ = drop_down;
    _ = level_bar;
    _ = calendar;
    _ = list_box;
    _ = about_dialog;
    _ = volume_button;
    _ = app_chooser_button;
    _ = shortcut_label;
    _ = shortcut_controller;
    _ = emoji_chooser;
    _ = file_chooser_button;
    _ = toolbar;
    _ = shortcuts_window;
    _ = password_entry;
    _ = scale_button;
    _ = stack_sidebar;
    _ = window_controls;
    _ = places_sidebar;
    _ = lock_button;
    _ = color_dialog_button;
    _ = font_dialog_button;
    _ = alert_dialog;
    _ = picture;
    _ = inscription;
    _ = paned;
    _ = split_button;
    _ = window_handle;
    _ = color_dialog;
    _ = font_dialog;
    _ = file_dialog;
    _ = tree_expander;
    _ = column_view;
    _ = grid_view;
    _ = popover_menu_bar;
    _ = popover_menu;
    _ = gl_area;
    _ = video;
    _ = perf;
    // P21 新增控件
    _ = box;
    _ = recent_chooser;
    // P22 新增控件
    _ = gesture_widget;
    _ = constraint_layout;
    _ = chooser_dialogs;
    // P2 模型层
    _ = model;
    _ = model.list_model;
    _ = model.selection_model;
    _ = model.list_item_factory;
    _ = model.adjustment;
    _ = model.filter_list_model;
    _ = model.sort_list_model;
    _ = model.map_list_model;
    _ = model.tree_list_model;
    _ = model.slice_flatten;
    _ = model.directory_list;
    _ = model.bookmark_list;
    _ = model.string_list;
    _ = model.action;
    _ = model.menu_model;
    _ = model.expression;
    _ = model.editable;
    _ = model.bitset;
    _ = model.file_filter;
    // P21 新增模型
    _ = model.recent_manager;
    _ = model.text_tag;
    _ = model.launcher;
    _ = application;
    // P33 新增模块
    _ = printer;
    _ = print_job;
    _ = graphics_offload;
    _ = shortcut_trigger;
    _ = accessible;
    _ = snapshot;
    // P39 新增模块
    _ = media_controls;
    if (is_linux) {
        _ = x11;
        _ = wayland;
        _ = atlas_vulkan;
    }
}
