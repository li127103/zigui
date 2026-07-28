# ZigUI 功能补全落地计划

> 对标 GTK4，逐步补齐缺失控件与功能。
> 每个条目标注 **优先级**、**实现文件**、**关键设计**。

---

## 阶段一：缺失控件（高优先级）

### 1.1 InfoBar - 通知消息条 ✅ 已完成
- **优先级**: 高
- **GTK 对应**: GtkInfoBar
- **文件**: `src/widget/info_bar.zig`
- **设计**:
  ```zig
  pub const InfoBarKind = enum { info, warning, err, question };
  pub const InfoBar = struct {
      base: Widget,
      kind: InfoBarKind,
      message: []const u8,
      on_close: ?*const fn(self: *InfoBar) void,
      on_response: ?*const fn(self: *InfoBar, response: i32) void,
      // 布局: 左侧图标+消息 | 右侧按钮组
  };
  ```
- **实现要点**:
  - measure: 水平排列 [图标 | 消息文本 | 按钮组]
  - paint: 按 kind 绘制不同背景色 (info=蓝/warning=黄/error=红/question=灰)
  - 提供 `addAction(label, response_id)` 添加按钮
  - `show()` / `hide()` 控制可见性
- **步骤**:
  1. 创建结构体 + create/destroy
  2. 实现 measure/paint (图标+文本+按钮水平布局)
  3. 实现 on_event (按钮点击触发 on_response)
  4. 添加 demo 示例

### 1.2 SearchEntry - 搜索输入框 ✅ 已完成
- **优先级**: 高
- **GTK 对应**: GtkSearchEntry
- **文件**: `src/widget/search_entry.zig`
- **设计**:
  ```zig
  pub const SearchEntry = struct {
      base: Widget,
      input: *TextInput,          // 内部 TextInput
      placeholder: []const u8,
      on_search: ?*const fn(self: *SearchEntry, text: []const u8) void,
      on_clear: ?*const fn(self: *SearchEntry) void,
  };
  ```
- **实现要点**:
  - 复用 TextInput 的输入逻辑 (组合而非继承)
  - 左侧绘制放大镜图标 (用线条画)
  - 右侧绘制清除按钮 (有文本时显示 X)
  - 文本变化时触发 on_search (可加 debounce)
  - ESC 键清空
- **步骤**:
  1. 创建结构体, 内部创建 TextInput 子控件
  2. measure/paint: TextInput + 图标叠加
  3. on_event: 转发键盘到 TextInput, ESC 清空, 点击 X 清空
  4. 添加 demo 示例

### 1.3 MenuButton - 菜单按钮 ✅ 已完成
- **优先级**: 高
- **GTK 对应**: GtkMenuButton
- **文件**: `src/widget/menu_button.zig`
- **设计**:
  ```zig
  pub const MenuButton = struct {
      base: Widget,
      label: []const u8,
      popover: ?*Popover,         // 关联的弹出菜单
      on_click: ?*const fn(self: *MenuButton) void,
  };
  ```
- **实现要点**:
  - 外观同 Button, 右侧加下拉箭头
  - 点击时 `popover.popup()` (定位到自身下方)
  - 再次点击或 Popover 关闭时切换状态
  - 支持 `setPopover(popover)` 关联任意 Popover
- **步骤**:
  1. 创建结构体 (基于 Button 模式)
  2. measure/paint: 文本 + 下拉箭头
  3. on_event: 点击触发 popover.popup/popdown
  4. 添加 demo 示例

---

## 阶段二：已有控件功能补全

### 2.1 Label 富文本标记 ✅ 已完成
- **优先级**: 高
- **GTK 对应**: Pango markup
- **文件**: 修改 `src/widget/label.zig` + `src/text/styled_text.zig`
- **设计**:
  - 支持 `<b>粗体</b>` `<i>斜体</i>` `<color=0xFF0000>红色</color>` 标记
  - 解析标记生成 StyledText 的 TextSpan 数组
  - measure/paint 使用 styled_text 的富文本路径
- **步骤**:
  1. 在 styled_text.zig 添加标记解析函数 `parseMarkup(text) -> []TextSpan`
  2. Label 增加 `use_markup: bool` 字段
  3. measure/paint 根据 use_markup 走富文本路径
  4. 添加 demo 示例

### 2.2 Label 自动换行与省略号 ✅ 已完成
- **优先级**: 高
- **GTK 对应**: wrap, ellipsize
- **文件**: 修改 `src/widget/label.zig`
- **设计**:
  ```zig
  wrap: bool = false,           // 自动换行
  ellipsize: EllipsizeMode = .none,  // none/start/middle/end
  max_lines: u32 = 0,           // 0=无限
  ```
- **步骤**:
  1. 添加字段
  2. measure: wrap 时按 max_width 分行; ellipsize 时截断加 "…"
  3. paint: 多行绘制
  4. 添加 demo 示例

### 2.3 TextInput 密码模式与占位文本 ✅ 已完成
- **优先级**: 高
- **GTK 对应**: visibility, placeholder-text
- **文件**: 修改 `src/widget/text_input.zig`
- **设计**:
  ```zig
  visibility: bool = true,       // false=密码模式, 显示圆点
  placeholder: []const u8 = "",  // 空文本时显示的占位符
  max_length: u32 = 0,           // 0=无限
  ```
- **步骤**:
  1. 添加字段
  2. paint: visibility=false 时绘制圆点替代字符; 空文本时绘制 placeholder (灰色)
  3. insertBytes: 检查 max_length
  4. 添加 demo 示例

### 2.4 ProgressBar 不确定模式 ✅ 已完成
- **优先级**: 中
- **GTK 对应**: pulse mode
- **文件**: 修改 `src/widget/progress_bar.zig`
- **设计**:
  ```zig
  mode: enum { determinate, indeterminate } = .determinate,
  pulse_progress: f32 = 0,      // 不确定模式的滚动位置
  ```
- **步骤**:
  1. 添加字段和 `pulse()` 方法
  2. 实现 tick 动画 (滚动条来回)
  3. paint: indeterminate 时绘制滑动块
  4. 添加 demo 示例

### 2.5 Button 图标支持 ✅ 已完成
- **优先级**: 中
- **GTK 对应**: icon-name
- **文件**: 新建 `src/widget/icons.zig` + 修改 `src/widget/button.zig` + 渲染器辅助函数
- **设计**:
  ```zig
  icon: ?IconName = null,       // 内置矢量图标枚举
  icon_size: f32 = 16,
  icon_color: ?math.Color = null, // 默认跟随 text_color
  ```
- **实现要点**:
  - 渲染器新增 `fillCircle` / `fillRing` / `fillConvexPolygon` 三角化辅助函数
  - 图标定义在 16×16 归一化坐标系, 由基元 (矩形/圆/圆环/凸多边形/三角形列表) 组合
  - comptime 辅助 `line()` 生成粗线段凸四边形, `tri()` 处理非凸形状 (星形中心扇形)
  - drawIcon 等比缩放到目标尺寸, 支持任意 DPI
  - 内置 23 个常用图标: close/search/menu/settings/plus/minus/check/arrow×4/refresh/edit/trash/save/home/user/star/heart/info/warning/err/question
  - Button 支持: 纯图标 / 图标+文本 / 纯文本 三种模式, 内容整体居中
- **步骤**:
  1. 渲染器添加 fillCircle/fillRing/fillConvexPolygon (vulkan + metal)
  2. 创建 icons.zig: IconName 枚举 + 基元数据 + drawIcon + 单元测试
  3. Button 添加 icon 字段, measure/paint 支持图标布局
  4. 添加 demo 示例 (4 行: 纯图标/图标+文本/信息类/箭头)

---

## 阶段三：框架级功能

### 3.1 快捷键系统 ✅ 已完成
- **优先级**: 高
- **GTK 对应**: GtkShortcutController
- **文件**: 新建 `src/shortcut.zig` + 修改 `src/app_linux.zig`
- **设计**:
  ```zig
  pub const Shortcut = struct {
      key: KeyCode,
      mods: Modifiers,           // ctrl/shift/alt
      callback: *const fn(ctx: ?*anyopaque) void,
      ctx: ?*anyopaque,
  };

  pub const ShortcutController = struct {
      shortcuts: std.ArrayList(Shortcut),
      pub fn add(self, key, mods, callback, ctx)
      pub fn handle(self, key, mods) bool
  };
  ```
- **步骤**:
  1. 创建 Shortcut 和 ShortcutController 结构
  2. App 中持有全局 ShortcutController
  3. key 事件处理时先查快捷键
  4. 添加 demo 示例

### 3.2 拖拽 (Drag and Drop) ✅ 已完成
- **优先级**: 高
- **GTK 对应**: GdkDrop
- **文件**: 新建 `src/dnd.zig` + 修改 widget/event
- **设计**:
  ```zig
  pub const DropTarget = struct {
      mime_types: []const []const u8,
      on_drop: ?*const fn(widget: *Widget, data: []const u8, mime: []const u8) void,
  };
  ```
- **步骤**:
  1. 定义 DnD 事件类型 (drag_start/drag_move/drop)
  2. Widget 增加 `drop_target: ?*DropTarget` 字段
  3. 鼠标拖拽时检测目标控件
  4. 触发 on_drop 回调

### 3.3 富文本属性 (Pango 替代) ✅ 已完成
- **优先级**: 中
- **GTK 对应**: Pango
- **文件**: 扩展 `src/text/styled_text.zig` + `src/text/freetype.zig` + `src/text/atlas_vulkan.zig`
- **设计**:
  - TextSpan 已支持 font_size/font_weight/color
  - 补充: italic (fake italic 水平错切合成) / strikethrough / underline
- **步骤**:
  1. TextSpan 添加 italic/underline/strikethrough 字段 ✅
  2. FreeType 实现 rasterizeGlyphItalic (fake italic) ✅
  3. GlyphAtlas 支持 italic 缓存键 ✅
  4. drawSpans 支持下划线/删除线绘制 ✅
  5. parseMarkup 支持 <i>/<u>/<s> 标记 ✅

### 3.4 UI 构建器 (JSON) ✅ 已完成
- **优先级**: 中
- **GTK 对应**: GtkBuilder
- **文件**: 新建 `src/builder.zig`
- **设计**:
  ```zig
  pub const Builder = struct {
      pub fn buildFromString(self, allocator, json_str) !*Widget
      pub fn buildFromValue(self, value) !*Widget
      pub fn find(self, id) ?*Widget
      pub fn findTyped(self, comptime T, id) ?*T
  };
  ```
- **支持的控件类型**:
  - container (direction, gap_width, gap_height, children)
  - label (text, font_size, color, use_markup)
  - button (text)
  - text_input (placeholder, max_length, visibility)
  - scroll_view (width, height, child/children)
  - checkbox (label, checked)
  - switch (on)
  - slider (min, max, value)
  - progress_bar (value)
  - spinner
  - separator (orientation)
  - frame (title, child)
  - expander (label, expanded, child)
  - stack (children)
- **步骤**:
  1. 创建 Builder 结构体 + JSON 解析 ✅
  2. 实现递归构建控件树 ✅
  3. 实现 find/findTyped 按 id 查找 ✅
  4. 支持 15+ 种控件类型 ✅
  5. 添加单元测试 ✅

---

## 阶段四：补充控件（中低优先级）

### 4.1 DropDown - 轻量下拉选择 ✅ 已完成
- **优先级**: 中
- **文件**: `src/widget/drop_down.zig`
- **设计**: 比 ComboBox 更简单, 用 Popover 实现下拉列表

### 4.2 LevelBar - 等级条 ✅ 已完成
- **优先级**: 中
- **文件**: `src/widget/level_bar.zig`
- **设计**: 离散分段进度条, 支持 min/max/value/mode

### 4.3 Calendar - 日历 ✅ 已完成
- **优先级**: 中
- **文件**: `src/widget/calendar.zig`
- **设计**: 月历视图, 支持 月份导航/日期选择/标记

### 4.4 FileChooser — 文件选择器 ✅ 已完成
- **优先级**: 中
- **GTK 对应**: GtkFileChooserDialog / GtkFileChooserButton
- **文件**: `src/widget/file_chooser.zig`
- **设计**:
  - 基于 Dialog 模式 (模态对话框, 覆盖在父窗口上)
  - 内部组合: Container + ScrollView + ListView + TextInput + Button
  - 使用 libc opendir/readdir 遍历目录 (跨平台基础)
- **功能**:
  - 支持 open / save 两种模式
  - 目录导航 (进入子目录 / 返回上级)
  - 文件过滤 (按扩展名)
  - 键盘 ESC 关闭
  - 回调: on_file_selected / on_cancel
- **步骤**:
  1. 创建 FileChooser 结构体 ✅
  2. 实现文件列表显示 (libc readdir) ✅
  3. 实现目录导航 (进入/上级) ✅
  4. 实现选择/确认/取消逻辑 ✅
  5. 添加 demo 示例 ✅
  6. 修复 ListView 跨平台文本渲染 (改用 styled_text) ✅

### 4.5 ColorButton — 颜色选择按钮 ✅ 已完成
- **优先级**: 低
- **GTK 对应**: GtkColorButton + GtkColorChooserDialog
- **文件**: `src/widget/color_button.zig` + `src/widget/color_chooser.zig`
- **设计**:
  - ColorButton: 显示当前颜色的小方块按钮, 点击弹出对话框
  - ColorChooserDialog: 模态对话框, 包含调色板 + 颜色预览 + 确定/取消
- **功能**:
  - 24 色调色板 (4行 x 6列)
  - 颜色预览条
  - 支持 ESC 关闭
  - 回调: on_color_changed / on_color_selected / on_cancel
- **步骤**:
  1. 创建 ColorButton 控件 ✅
  2. 创建 ColorChooserDialog 对话框 ✅
  3. 实现调色板点击选色 ✅
  4. 添加 demo 示例 ✅

### 4.6 FontButton — 字体选择按钮 ✅ 已完成
- **优先级**: 低
- **GTK 对应**: GtkFontButton + GtkFontChooserDialog
- **文件**: `src/widget/font_button.zig` + `src/widget/font_chooser.zig`
- **设计**:
  - FontButton: 显示当前字体族名称的按钮, 点击弹出字体选择对话框
  - FontChooserDialog: 模态对话框, 包含字体族列表 + 字号 + 粗体/斜体 + 预览
- **功能**:
  - 通过 fontconfig 加载系统所有字体族
  - 字体族列表 (带滚动)
  - 字号设置 + 粗体/斜体复选框
  - 实时预览文本效果
  - 支持 ESC 关闭
  - 回调: on_font_changed / on_font_selected / on_cancel
- **步骤**:
  1. 创建 FontButton 控件 ✅
  2. 创建 FontChooserDialog 对话框 ✅
  3. 实现 fontconfig 字体枚举 ✅
  4. 实现字体预览 ✅
  5. 添加 demo 示例 ✅

### 4.7 SearchBar — 搜索栏 ✅ 已完成
- **优先级**: 低
- **GTK 对应**: GtkSearchBar
- **文件**: `src/widget/search_bar.zig`
- **设计**:
  - 可显示/隐藏的搜索栏容器
  - 内部包含 SearchEntry + 可选关闭按钮
  - 通常放在窗口顶部, 配合 Ctrl+F 快捷键切换
- **功能**:
  - `setRevealChild()` / `getRevealChild()` 控制显示
  - 内置 SearchEntry 搜索输入框
  - 可选关闭按钮
  - ESC 快捷键关闭
  - 阴影效果提升视觉层次感
  - 回调: on_search_changed / on_close

---

## 阶段五："好用"特性 (P0/P1)

### 5.1 鼠标光标样式 ✅ 已完成
- **优先级**: P0
- **GTK 对应**: GtkWidget:cursor, GdkCursor
- **文件**: 修改 `src/pal/x11.zig` + `src/widget/widget.zig` + `src/app_linux.zig`
- **功能**:
  - 10 种标准光标: arrow/ibeam/crosshair/pointing_hand/resize_ew/resize_ns/resize_nwse/resize_nesw/not_allowed/wait
  - X11 后端使用标准 cursor font 创建光标
  - App 层 `setCursor()` API
  - Widget 基类 `cursor` 字段 (null=继承父级) + `resolveCursor()` + `updateCursorAt()`
  - 12 个常见控件设置默认光标

### 5.2 Widget 级 Tooltip 支持 ✅ 已完成
- **优先级**: P0
- **GTK 对应**: GtkWidget:tooltip-text
- **文件**: 修改 `src/widget/widget.zig` + 新建 `src/widget/tooltip_controller.zig`
- **功能**:
  - Widget 基类 `tooltip_text` 字段 (null=无 tooltip)
  - `findTooltip()` 方法 (向上查找第一个有 tooltip 的控件)
  - TooltipController 自动管理显示/隐藏
  - 500ms 悬停延迟

### 5.3 Context Menu 右键菜单支持 ✅ 已完成
- **优先级**: P0
- **GTK 对应**: GtkWidget:context-menu
- **文件**: 新建 `src/widget/context_menu.zig` + 修改 `src/widget/widget.zig`
- **功能**:
  - ContextMenu 组件封装菜单创建/定位/显示
  - 支持菜单项、分隔线、禁用状态
  - 可在指定位置弹出, 点击外部关闭
  - Widget 基类 `context_menu` 字段, 右键自动弹出
  - 动态更新菜单项状态 (`setItemDisabled` + `on_before_show` 回调)
  - TextInput 内置上下文菜单: 撤销/重做/剪切/复制/粘贴/全选
  - TextArea 内置上下文菜单: 撤销/重做/剪切/复制/粘贴/全选

### 5.4 控件 disabled 视觉反馈完善 ✅ 已完成
- **优先级**: P0
- **GTK 对应**: GtkWidget:sensitive
- **功能**:
  - 统一的半透明遮罩 (40% 黑色)
  - disabled 控件不响应事件、不获取焦点
  - 光标使用父级样式

---

## 阶段六：多窗口系统 (P0)

### 6.1 事件层 window_id ✅ 已完成
- **优先级**: P0
- **文件**: 修改 `src/pal/event.zig`
- **功能**: 所有事件类型添加 `window_id: u32` 字段

### 6.2 X11 后端多窗口支持 ✅ 已完成
- **优先级**: P0
- **文件**: 修改 `src/pal/x11.zig`
- **功能**:
  - SubWindowData 子窗口数据结构
  - `createSubWindow()` / `destroySubWindow()`
  - `showSubWindow()` / `hideSubWindow()`
  - `setSubWindowTitle()` / `resizeSubWindow()` / `moveSubWindow()`
  - `maximizeSubWindow()` / `unmaximizeSubWindow()` / `iconifySubWindow()`
  - `setSubWindowTransientFor()` 父子窗口关系
  - 事件自动携带正确的 window_id

### 6.3 Window 封装模块 ✅ 已完成
- **优先级**: P0
- **文件**: 新建 `src/window.zig`
- **功能**:
  - 每个窗口独立 Vulkan swapchain
  - 独立渲染器、字形图集、脏区域
  - 独立事件队列和输入状态
  - `processEvents()` 统一处理窗口事件

### 6.4 App 层多窗口集成 ✅ 已完成
- **优先级**: P0
- **文件**: 修改 `src/app_linux.zig`
- **功能**:
  - `sub_windows` 哈希表管理所有子窗口
  - 事件按 window_id 自动路由
  - `processSubWindowEvents()` 统一处理子窗口事件
  - `renderSubWindows()` 依次渲染所有可见子窗口
  - 10+ 个窗口管理 API

### 6.5 Wayland 后端多窗口支持 ✅ 完整完成
- **优先级**: P1
- **文件**: 修改 `src/pal/wayland.zig` + `src/window.zig` + `src/app_linux.zig`
- **状态**: 完整实现子窗口创建/销毁 + 独立 Vulkan swapchain + 完整事件路由
- **功能**:
  - `SubWindowData` 结构管理每个子窗口的 Wayland 资源
  - `createSubWindow` / `destroySubWindow` / `showSubWindow` / `hideSubWindow` / `setSubWindowTitle`
  - 独立的 `xdg_surface` / `xdg_toplevel` / `wl_surface`
  - 独立 Vulkan swapchain (通过 `Window.initWayland`)
  - resize / close_requested 事件带正确 window_id
  - **键盘焦点跟踪**: `keyboard_focus_window_id` + `keyboardEnter/Leave` 更新焦点
  - **指针焦点跟踪**: `pointer_focus_window_id` + `pointerEnter/Leave` 更新焦点
  - **键盘事件路由**: key / text_input 事件发送到当前键盘焦点窗口
  - **鼠标事件路由**: mouse_move / mouse_button / scroll / mouse_leave 发送到当前指针焦点窗口
  - **IME 事件路由**: ime_preedit / ime_commit / ime_delete 跟随键盘焦点
  - **file_drop 事件路由**: 文件拖拽跟随指针焦点
  - `getWindowIdFromSurface()` 辅助函数通过 surface 指针查找 window_id

### 6.6 macOS 后端多窗口支持 ✅ 完整完成
- **优先级**: P1
- **文件**: 修改 `src/pal/cocoa/cocoa_backend.h` + `src/pal/cocoa/cocoa_backend.m` + `src/pal/cocoa.zig` + `src/app.zig`
- **状态**: 完整实现子窗口创建/销毁 + 独立 NSWindow + 独立 Metal 渲染 + 完整事件路由
- **功能**:
  - `ZgSubWindow` 结构管理每个子窗口的 NSWindow / NSView / CAMetalLayer
  - `createSubWindow` / `destroySubWindow` / `showSubWindow` / `hideSubWindow` / `setSubWindowTitle`
  - 独立的 `NSWindow` + `ZiguiContentView` + `CAMetalLayer`
  - 独立 Metal 设备 (每个子窗口有自己的 MetalDevice / Renderer2D / GlyphAtlas)
  - 事件结构带 `window_id` 字段，支持事件路由
  - 键盘/鼠标/滚轮/触摸/拖放事件正确分发到对应窗口
  - `CocoaSubWindow` 结构管理子窗口的所有状态和资源
  - App 层 `sub_windows` 哈希表管理所有子窗口
  - 子窗口支持 `on_draw` / `on_close` 回调
  - 子窗口支持独立的事件队列和脏区跟踪

### 6.7 子窗口 Widget 树支持 ✅ 基础完成
- **优先级**: P1
- **文件**: 修改 `src/window.zig` + `src/app_linux.zig`
- **状态**: 已支持自定义绘制回调 (on_draw)，用户可在回调中管理自己的 widget 树
- **功能**:
  - Window 添加 `on_draw` / `on_close` / `user_data` 回调
  - App 层 `renderSubWindows` 调用子窗口的 on_draw
  - App 层 `getSubWindow(wid)` API 获取窗口指针
  - multi_window_demo 中演示子窗口自定义绘制
- **后续**: 可进一步封装标准 widget 树挂载方式

---

## 阶段七：补充控件与功能 (P2)

### 7.1 Scale — 带刻度的滑块 ✅ 已完成
- **优先级**: 低
- **GTK 对应**: GtkScale
- **文件**: `src/widget/scale.zig`
- **说明**: 在 Slider 基础上增加刻度标记、当前值标签、min/max 标签
- **功能**:
  - 可配置刻度数量 (tick_count)
  - 当前值显示 (可自定义格式字符串)
  - 可选最小值/最大值标签
  - 完整的键盘支持 (方向键/Home/End)
  - 悬浮/拖动滑块放大效果

### 7.2 Assistant — 向导对话框 ✅ 已完成
- **优先级**: 低
- **GTK 对应**: GtkAssistant
- **文件**: `src/widget/assistant.zig`
- **说明**: 多步骤向导, 带前进/后退/完成按钮和页面切换
- **功能**:
  - 多页面管理 (addPage)
  - 进度指示器 (圆点, 已完成=绿色, 当前=蓝色, 未完成=灰色)
  - 上一步/下一步/完成/取消 按钮
  - 页面 complete 状态控制下一步是否可用
  - on_prepare 回调 (页面切换时触发)
  - on_apply / on_cancel / on_close 回调
  - ESC 快捷键关闭
  - 支持嵌入自定义内容 widget

### 7.3 AppChooser — 应用选择器 ✅ 基础完成
- **优先级**: 低
- **GTK 对应**: GtkAppChooserDialog
- **文件**: `src/widget/app_chooser.zig`
- **功能**:
  - `AppChooserDialog` 对话框组件
  - 扫描系统 .desktop 文件获取应用列表
  - 支持 XDG_DATA_HOME / XDG_DATA_DIRS 标准路径
  - 过滤 Hidden / NoDisplay 应用
  - 列表展示 + "设为默认" 复选框
  - on_app_selected / on_cancel 回调
  - ESC 快捷键关闭

### 7.4 FontSelection — 字体选择 (独立控件) ✅ 基础完成
- **优先级**: 低
- **GTK 对应**: GtkFontSelection
- **文件**: `src/widget/font_selection.zig`
- **功能**:
  - 可嵌入的独立字体选择控件 (非对话框)
  - 字体族列表 (通过 fontconfig 加载)
  - 字号输入
  - 粗体/斜体 样式选择
  - 实时预览
  - on_font_changed 回调
  - getFontDesc / setFont API

### 7.5 剪贴板完善 ✅ 基础完成
- **优先级**: 中
- **GTK 对应**: GtkClipboard
- **文件**: `src/pal/clipboard.zig` + `src/widget/text_input.zig` + `src/widget/text_area.zig`
- **功能**:
  - 文本复制/剪切/粘贴 (TextInput / TextArea)
  - 快捷键支持: Ctrl+C / Ctrl+X / Ctrl+V / Cmd+C / Cmd+X / Cmd+V
  - 右键上下文菜单: 剪切/复制/粘贴/全选/撤销/重做
  - **图像剪贴板**: `getImagePng` / `setImagePng` / `hasImage` API
    - X11: 基于 xclip -t image/png
    - Wayland: 基于 wl-copy/wl-paste --type image/png
    - macOS: 基于 pbcopy/pbpaste (基础支持)

### 7.6 ProgressBar — 进度条 ✅ 基础完成
- **优先级**: 低
- **GTK 对应**: GtkProgressBar
- **文件**: `src/widget/progress_bar.zig`
- **功能**:
  - 确定模式: 显示 0-100% 进度
  - 不确定模式 (脉冲动画): `pulse` / `pulseStep`
  - 显示文本: 百分比或自定义文本
  - 可定制颜色/圆角/尺寸

### 7.7 LevelBar — 等级指示器 ✅ 基础完成
- **优先级**: 低
- **GTK 对应**: GtkLevelBar
- **文件**: `src/widget/level_bar.zig`
- **功能**:
  - 两种模式: continuous (连续) / discrete (离散块)
  - 水平 / 垂直 方向
  - 反转显示
  - 高/低阈值颜色变化
  - 可定制块数量、间距、颜色

### 7.8 Statusbar — 状态栏 ✅ 基础完成
- **优先级**: 低
- **GTK 对应**: GtkStatusbar
- **文件**: `src/widget/statusbar.zig`
- **功能**:
  - 栈式消息管理: push / pop / setText
  - 支持 context_id 上下文标识
  - 可定制背景色/文本色/高度
  - 顶部分隔线

### 7.9 InfoBar — 信息栏 ✅ 基础完成
- **优先级**: 低
- **GTK 对应**: GtkInfoBar
- **文件**: `src/widget/info_bar.zig`
- **功能**:
  - 四种消息类型: info / warning / error / question
  - 每种类型有对应的配色方案
  - 左侧彩色指示条
  - 可选关闭按钮
  - show / hide 控制可见性
  - on_close 回调

### 7.10 ToolPalette — 工具面板 ✅ 基础完成
- **优先级**: 低
- **GTK 对应**: GtkToolPalette
- **文件**: `src/widget/tool_palette.zig`
- **功能**:
  - 可分组的工具按钮面板
  - 每个组可展开/折叠 (基于 Expander)
  - 组内按钮网格排列
  - `addGroup` / `addItem` API
  - 可定制图标尺寸、列数、颜色

### 7.11 IconView — 图标视图 ✅ 基础完成
- **优先级**: 低
- **GTK 对应**: GtkIconView
- **文件**: `src/widget/icon_view.zig`
- **功能**:
  - 网格布局显示图标+标签
  - 支持单选 (点击/键盘)
  - 双击激活 (on_activate 回调)
  - 键盘导航: 方向键 / Home / End / Enter
  - 鼠标悬停高亮
  - 垂直滚动 + 滚动条
  - 可定制: 图标大小、列数、间距、颜色

### 7.12 PrintDialog — 打印对话框 ✅ 基础完成
- **优先级**: 低
- **GTK 对应**: GtkPrintDialog / GtkPrintSettings
- **文件**: `src/widget/print_dialog.zig`
- **功能**:
  - `PrintSettings` 结构封装所有打印参数
  - 打印机选择
  - 份数 + 自动分页 + 逆序打印
  - 页面范围: 全部 / 自定义范围
  - 方向: 纵向 / 横向
  - 纸张大小: A4 / Letter / Legal / A3 / A5
  - 颜色模式: 彩色 / 黑白
  - 双面打印: 无 / 长边 / 短边
  - on_print / on_cancel 回调
  - ESC 快捷键关闭

### 7.13 Drag & Drop — 拖放系统 ✅ 基础框架
- **优先级**: 低
- **GTK 对应**: GtkDragSource / GtkDropTarget
- **文件**: `src/widget/drag_drop.zig`
- **功能**:
  - `DragData` 结构: 支持 text / image / file / custom 数据类型
  - `DragSource` 拖拽源: on_drag_begin / on_drag_end 回调
  - `DropTarget` 拖放目标: on_drag_enter / on_drag_move / on_drag_leave / on_drop 回调
  - `DragOperation`: copy / move / link 操作类型
  - `DragDropManager` 全局管理器: 注册/查找 源和目标
  - 基础拖拽状态跟踪

### 7.14 Animation System — 动画系统 ✅ 基础完成
- **优先级**: 低
- **GTK 对应**: GtkWidget: animation / AdwAnimation
- **文件**: `src/animation/animation.zig`
- **功能**:
  - **31 种缓动函数**:
    - Linear: linear
    - Sine: ease_in / ease_out / ease_in_out
    - Quad / Cubic / Quart / Quint: ease_in / ease_out / ease_in_out
    - Expo / Circ / Back / Elastic / Bounce: ease_in / ease_out / ease_in_out
  - **FloatAnimation**: 浮点属性动画
    - from / to / duration / easing
    - delay / iterations / auto_reverse
    - on_start / on_update / on_complete 回调
    - start / stop / pause / resumeAnim / restart 控制
  - **ColorAnimation**: 颜色属性动画 (RGBA 插值)
  - **AnimationController**: 动画控制器
    - 管理多个动画的播放
    - time_scale 时间缩放
    - pauseAll / resumeAll 全局控制
    - 自动清理已完成动画

### 7.15 Accessibility — 无障碍系统 ✅ 基础框架
- **优先级**: 低
- **GTK 对应**: GtkAccessible / ATK
- **文件**: `src/accessibility/accessible.zig`
- **功能**:
  - **AccessibleRole**: 60+ 种无障碍角色定义
    - 按钮类: button / check_button / radio_button / toggle_button
    - 文本类: label / entry / text / search_entry / password_text
    - 容器类: box / list / tree / table / tab_list / window / dialog
    - 菜单类: menu / menu_bar / menu_item / check_menu_item
    - 其他: progress_bar / slider / scroll_bar / status_bar / info_bar 等
  - **AccessibleState**: 32 个状态标志 (packed struct)
    - sensitive / enabled / visible / showing
    - focused / selected / pressed / checked
    - expanded / collapsed / busy / read_only
    - modal / has_popup / focusable / active 等
  - **Accessible**: 无障碍属性对象
    - role / name / description / placeholder
    - value / min_value / max_value
    - state 状态管理
    - on_state_changed / on_name_changed / on_focus / on_activate 回调
  - **AccessibleText**: 文本无障碍扩展
    - 文本内容 / 光标位置 / 选区范围
    - 可编辑 / 多行 / 换行模式
  - **AccessibleValue**: 数值无障碍扩展
    - 当前值 / 最小 / 最大 / 步长
    - increment / decrement / pageIncrement / pageDecrement
  - **AccessibilityManager**: 全局无障碍管理器
    - 事件监听器注册/移除
    - 焦点管理 (setFocus / getFocus)
    - 根对象管理
    - 全局启用/禁用开关

---

## 阶段八：补充 GTK 组件 (P2)

### 8.1 ListBox — 列表框容器 ✅ 基础完成
- **优先级**: 中
- **GTK 对应**: GtkListBox
- **文件**: `src/widget/list_box.zig`
- **功能**:
  - 垂直排列的列表容器, 每个子项是一行
  - 支持单选、浏览、多选模式
  - 键盘导航: 上/下/Home/End
  - 行悬停高亮 + 选中高亮
  - 行激活 (单击/双击/Enter)
  - on_row_selected / on_row_activated 回调
  - 支持可配置的行间距和内边距

### 8.2 AboutDialog — 关于对话框 ✅ 基础完成
- **优先级**: 中
- **GTK 对应**: GtkAboutDialog
- **文件**: `src/widget/about_dialog.zig`
- **功能**:
  - 程序名称 + 版本号显示
  - 版权信息
  - 描述/注释
  - 网站链接 (可点击)
  - 作者列表
  - 文档作者列表
  - 美术设计列表
  - 翻译者
  - 许可证文本查看 (带滚动)
  - 模态对话框, ESC 关闭
  - on_close / on_activate_link 回调

### 8.3 VolumeButton — 音量按钮 ✅ 基础完成
- **优先级**: 中
- **GTK 对应**: GtkVolumeButton
- **文件**: `src/widget/volume_button.zig`
- **功能**:
  - 带音量图标的按钮 (图标随音量变化)
  - 点击弹出垂直滑块调整音量
  - 静音切换 (Space/Enter)
  - 键盘支持: 上下/左右/PageUp/PageDown/Home/End
  - 滚轮调整音量
  - 音量值回调 on_value_changed
  - 可自定义颜色和尺寸

### 8.4 AppChooserButton — 应用选择按钮 ✅ 基础完成
- **优先级**: 中
- **GTK 对应**: GtkAppChooserButton
- **文件**: `src/widget/app_chooser_button.zig`
- **功能**:
  - 显示当前选择的应用名称
  - 点击弹出 AppChooserDialog
  - 支持指定 content_type (MIME 类型)
  - 自定义默认显示文本和对话框标题
  - on_app_selected 回调
  - getSelectedApp / setSelectedApp API
  - 键盘支持 (Space/Enter 打开, ESC 关闭)

### 8.5 ShortcutLabel — 快捷键标签 ✅ 基础完成
- **优先级**: 中
- **GTK 对应**: GtkShortcutLabel
- **文件**: `src/widget/shortcut_label.zig`
- **功能**:
  - 显示键盘快捷键 (如 "Ctrl+C")
  - 自动格式化修饰键和主键
  - 支持 Ctrl/Shift/Alt/Super/Meta/Hyper 修饰键
  - 带背景色和边框的标签样式
  - 可自定义颜色、圆角、字体大小
  - setShortcut() 动态修改快捷键

### 8.6 EmojiChooser — 表情选择器 ✅ 基础完成
- **优先级**: 中
- **GTK 对应**: GtkEmojiChooser
- **文件**: `src/widget/emoji_chooser.zig`
- **功能**:
  - 弹出式表情选择面板
  - 9 个分类: 笑脸/人物/动物/食物/旅行/活动/物品/符号/旗帜
  - 最近使用 (Recently Used) 功能
  - 搜索功能 (按表情名称搜索)
  - 网格布局显示表情
  - 悬停高亮效果
  - 点击选中后触发回调并关闭
  - ESC 关闭 / 点击外部关闭
  - 200+ 常用表情内置

---

## 实现顺序建议

```
已完成: 阶段一~阶段八 (全部) + 扩展功能
  - 阶段一~阶段五: 全部完成
  - 阶段六: X11 完整完成, Wayland 完整完成, macOS 完整完成
  - 阶段七: 全部完成 (Scale / Assistant / 剪贴板 / Switch / Spinner / TextArea右键+撤销重做 / AppChooser / FontSelection / ProgressBar / LevelBar / Statusbar / InfoBar / ToolPalette / IconView)
  - 阶段八: 全部完成 (ListBox / AboutDialog / VolumeButton / AppChooserButton / ShortcutLabel / EmojiChooser)
  - 扩展: PrintDialog / Drag & Drop 基础框架 / 动画系统 / Accessibility 无障碍基础框架

🎉 ZigUI 已达到"好用"级别！
  - 85+ 个控件组件
  - 三大平台支持 (X11 / Wayland / macOS)
  - 多窗口系统
  - 完整的文本编辑 (撤销重做 / 右键菜单)
  - 动画系统 (31种缓动)
  - 无障碍基础框架

下一步优先级:
  ┌─────────────────────────────────────────┐
  │  继续探索更多 GTK 组件 / 功能优化        │
  └─────────────────────────────────────────┘
```

每个条目完成后:
1. 编译通过 (X11 + Wayland)
2. 添加 demo 示例
3. 更新本文档勾选状态
