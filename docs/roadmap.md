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

---

## 阶段九：P0 高优先级核心缺失（GTK4 特色）

> 对应 GTK4 常用但缺失的核心控件，按 **Paned → SplitButton → WindowHandle → ColorDialog/FontDialog/FileDialog → TreeExpander** 顺序实现。

### 9.1 Paned — 可拖动分割面板（左右/上下） ✅ 已完成
- **优先级**: 高 (P0)
- **GTK 对应**: GtkPaned
- **文件**: `src/widget/paned.zig`
- **功能**:
  - `horizontal` / `vertical` 两种方向
  - `start_child` / `end_child` 两个子控件
  - `position`: 分割条位置（像素）
  - `min_position` / `max_position`: 拖动限制
  - `position_set`: 是否已手动设置位置
  - `resize_start_child` / `shrink_start_child`
  - `resize_end_child` / `shrink_end_child`
  - `wide_handle`: 宽柄（更大的可点击区域）
  - `on_position_changed`: 位置变化回调
  - 分割条 hover / dragging 视觉反馈（三横/三竖 grabber）
  - 鼠标光标切换：horizontal→ew-resize，vertical→ns-resize

### 9.2 SplitButton — 分割按钮（主按钮 + 下拉菜单） ✅ 已完成
- **优先级**: 高 (P0)
- **GTK 对应**: GtkSplitButton
- **文件**: `src/widget/split_button.zig`
- **功能**:
  - 左侧主按钮：点击执行 `on_clicked`
  - 右侧下拉箭头：点击弹出 `popover` / `menu_model`
  - `label`: 主按钮文字 / `icon_name`: 主按钮图标
  - `popover`: 关联 Popover / `menu_model`: 关联菜单
  - `direction`: 弹出方向（up/down/left/right）
  - `on_clicked`: 主按钮点击回调
  - 主按钮区和箭头区独立 hover/pressed 样式
  - 中间分割竖线 + 左右分别圆角
  - 键盘支持（Space/Enter 触发点击, ↓ 弹出下拉）

### 9.3 WindowHandle — 自定义标题栏拖动句柄 ✅ 已完成
- **优先级**: 高 (P0)
- **GTK 对应**: GtkWindowHandle
- **文件**: `src/widget/window_handle.zig`
- **功能**:
  - 容器控件：包装子控件后，空白区域可拖动父窗口
  - 子控件的按钮/输入框仍正常响应（先分发事件给 child）
  - 双击可切换最大化：`on_toggle_maximized` 回调
  - 单按拖动模式：`on_begin_move_drag` 回调通知窗口层
  - 与 WindowControls 配合打造自定义 HeaderBar

### 9.4 ColorDialog / FontDialog / FileDialog — GTK4 新版异步对话框 ✅ 已完成
- **优先级**: 高 (P0)
- **GTK 对应**: GtkColorDialog / GtkFontDialog / GtkFileDialog
- **文件**:
  - `src/widget/color_dialog.zig`
  - `src/widget/font_dialog.zig`
  - `src/widget/file_dialog.zig`
- **功能**:
  - 简化版 Dialog API（GTK4 新版，替代旧的 ChooserDialog）
  - `title`: 对话框标题 / `modal`: 是否模态
  - `accept_label` / `cancel_label`: 按钮文字
  - **ColorDialog**: `initial_color` / `chooseRgba()` 异步回调
  - **FontDialog**: `family/size/bold/italic` / `chooseFont()` 回调
  - **FileDialog**: `open/save/select_folder` 三种模式 / `initial_folder` / `initial_name` / `filters`
  - 与对应的 *DialogButton 配对使用

### 9.5 TreeExpander — GTK4 树形展开器 ✅ 已完成
- **优先级**: 中 (P0 最后一个)
- **GTK 对应**: GtkTreeExpander
- **文件**: `src/widget/tree_expander.zig`
- **功能**:
  - GTK4 新型树控件（替代 GtkTreeView 的轻量方案）
  - `child`: 要显示的内容控件
  - `TreeListRow`: 行状态结构 `expanded / depth / has_children`
  - `indent_for_icon`: 是否为图标留出缩进（depth × 20px）
  - `hide_expander`: 是否隐藏展开按钮
  - `chevron_right → chevron_down` 展开箭头动画切换
  - 点击箭头 / Space 键切换展开
  - ← 折叠 / → 展开 键盘导航
  - `on_toggle` 展开变化回调
  - 箭头区域悬停高亮背景

---

## 阶段十：P1 中优先级特色控件

### 10.1 ColumnView — 现代化列视图（表格）
- **优先级**: 中
- **GTK 对应**: GtkColumnView
- **文件**: `src/widget/column_view.zig`

### 10.2 GridView — 网格视图（基于选择模型）
- **优先级**: 中
- **GTK 对应**: GtkGridView
- **文件**: `src/widget/grid_view.zig`

### 10.3 PopoverMenuBar — 弹出式菜单栏
- **优先级**: 中
- **GTK 对应**: GtkPopoverMenuBar
- **文件**: `src/widget/popover_menu_bar.zig`

### 10.4 GLArea — OpenGL 渲染区域
- **优先级**: 中
- **GTK 对应**: GtkGLArea
- **文件**: `src/widget/gl_area.zig`

### 10.5 Video — 视频播放控件
- **优先级**: 中
- **GTK 对应**: GtkVideo
- **文件**: `src/widget/video.zig`

---

## 最新实现顺序

```
✅ 已完成: 阶段一~阶段八 + 扩展功能 (85+ 控件)
✅ 已完成: StackSidebar / WindowControls / PlacesSidebar / LockButton
✅ 已完成: ColorDialogButton / FontDialogButton / AlertDialog / Picture / Inscription

✅ 已完成: 阶段九（P0 全部）
  ├─ 9.1 Paned                  ✅
  ├─ 9.2 SplitButton            ✅
  ├─ 9.3 WindowHandle           ✅
  ├─ 9.4 ColorDialog / FontDialog / FileDialog ✅
  └─ 9.5 TreeExpander           ✅

✅ 已完成: 阶段十（P1 全部）
  ├─ 10.1 ColumnView            ✅
  ├─ 10.2 GridView              ✅
  ├─ 10.3 PopoverMenuBar        ✅
  ├─ 10.4 GLArea                ✅
  └─ 10.5 Video                 ✅

✅ 已完成: 阶段十一（P2 模型层 全部）
  ├─ 11.1 ListModel / ListStore              ✅ (src/model/list_model.zig)
  │   • ListModelIface 虚表 + ListModel 胖指针
  │   • 泛型 ListStore(T) 动态数组 (append/insert/remove/splice)
  │   • StringListStore 字符串便捷封装
  │   • items-changed 变更信号回调
  ├─ 11.2 SelectionModel 集合                 ✅ (src/model/selection_model.zig)
  │   • NoSelection: 所有项不可选
  │   • SingleSelection: 0 或 1 个选中，支持 autoselect / canUnselect
  │   • MultiSelection: 任意项多选，selectRange / selectAll
  │   • selection-changed 变更信号
  ├─ 11.3 ListItemFactory / SignalListItemFactory ✅ (src/model/list_item_factory.zig)
  │   • ListItem 抽象句柄 (position / item / selected / userdata)
  │   • SetupFn / BindFn / UnbindFn / TeardownFn 四槽回调
  │   • SignalListItemFactory: 简单 4 槽位回调工厂
  │   • SimpleTextFactory: 内置文本工厂
  └─ 11.4 ColumnView / GridView 集成          ✅
      • ColumnView: setModel / setSelectionModel / setFactory(col, factory)
      • GridView:   setModel / setSelectionModel / setFactory(factory)
      • 保持向后兼容：旧 rows / items API 继续可用
      • root.zig 统一导出 zigui.model.* 快速别名

🎉 ZigUI 模型层架构 (GtkColumnView + GtkGridView + GListModel + GtkSelectionModel) 已搭建完成！
```

每个条目完成后:
1. 编译通过 (X11 + Wayland)
2. 添加 demo 示例
3. 更新本文档勾选状态

---

## 阶段十一：P2 模型层（Gio/Gtk 风格抽象）

### 11.1 ListModel / ListStore — Gio 风格抽象列表模型 ✅ 已完成
- **优先级**: 中 (P2)
- **GTK 对应**: Gio.ListModel / GListStore
- **文件**: `src/model/list_model.zig`
- **设计**:
  ```zig
  // 虚表接口
  pub const ListModelIface = struct {
      getItemFn: *const fn (userdata: ?*anyopaque, position: usize) ?*anyopaque,
      getNItemsFn: *const fn (userdata: ?*anyopaque) usize,
      getItemTypeFn: *const fn (userdata: ?*anyopaque) []const u8,
  };
  // 类型擦除胖指针
  pub const ListModel = struct {
      iface: *const ListModelIface,
      userdata: ?*anyopaque,
  };
  // 泛型具体实现
  pub fn ListStore(comptime T: type) type { /* ArrayListUnmanaged + dup/free */ }
  ```
- **功能**:
  - `ListStore(T).new(allocator, type_name, .{dup_fn, free_fn})` — 带 dup/free 的值语义存储
  - `append / prepend / insert / remove / splice / clear / set` 完整 API
  - `on_items_changed` 单一回调: `(position, removed, added)`
  - `StringListStore` + `newStringListStore()` 便捷封装 (自动 dup/free 字符串)

### 11.2 SelectionModel — Gtk 选择模型集 ✅ 已完成
- **优先级**: 中 (P2)
- **GTK 对应**: GtkSelectionModel / GtkNoSelection / GtkSingleSelection / GtkMultiSelection
- **文件**: `src/model/selection_model.zig`
- **功能**:
  - **NoSelection**: 所有项不可选（纯展示视图）
  - **SingleSelection**: 0 或 1 个选中
    - `autoselect: bool` — 初始 / 变空时自动选中第 0 项
    - `can_unselect: bool` — 允许点击已选中项取消选中
  - **MultiSelection**: 任意项多选
    - `selectRange(position, n, exclusive)` — 范围选择
    - `selectAll / unselectAll` — 全选/取消全部
    - 内部 `DynamicBitSetUnmanaged` + 自动扩容
  - **SelectionModel 胖指针通用 API**:
    - `isSelected(pos) / selectItem(pos, exclusive) / unselectItem(pos)`
    - `selectionSize()` — 快速判定选中数量
    - `on_selection_changed` 回调: `(position, n_items)`

### 11.3 ListItemFactory + SignalListItemFactory ✅ 已完成
- **优先级**: 中 (P2)
- **GTK 对应**: GtkListItemFactory / GtkSignalListItemFactory / GtkListItem
- **文件**: `src/model/list_item_factory.zig`
- **功能**:
  - **ListItem 句柄**:
    - `position` / `item: ?*anyopaque` (指向 model item)
    - `selected` / `activatable` / `selectable`
    - `userdata` (存放 factory 创建的控件/数据) + `destroy_userdata`
  - **四槽回调模式** (Setup/Bind/Unbind/Teardown):
    - `SetupFn` — 为每个 ListItem 创建渲染控件 (一次)
    - `BindFn` — 把 model item 数据绑定到控件 (反复)
    - `UnbindFn` — 解绑 (可选)
    - `TeardownFn` — 销毁控件 (可选)
  - **SignalListItemFactory**: 4 槽位回调工厂
  - **SimpleTextFactory**: 内置的文本工厂，把 model item 当字符串渲染
  - **ListItemFactory 胖指针**: `setup/bind/unbind/teardown` 统一调用

### 11.4 ColumnView / GridView 集成模型层 ✅ 已完成
- **优先级**: 中 (P2)
- **文件**: `src/widget/column_view.zig` / `src/widget/grid_view.zig`
- **ColumnView 新增 API**:
  ```zig
  pub fn setModel(self: *ColumnView, m: ?ListModel) void;
  pub fn setSelectionModel(self: *ColumnView, sel: ?*SelectionModel) void;
  pub fn setFactory(self: *ColumnView, col_idx: usize, factory: ?ListItemFactory) !void;
  ```
- **GridView 新增 API**:
  ```zig
  pub fn setModel(self: *GridView, m: ?ListModel) void;
  pub fn setSelectionModel(self: *GridView, sel: ?*SelectionModel) void;
  pub fn setFactory(self: *GridView, factory: ?ListItemFactory) void;
  ```
- **向后兼容**:
  - 旧的 `rows` (二维字符串) / `items` (GridItem 数组) API 完全保留
  - 内部通过 `effectiveRowCount()` / `effectiveIsSelected()` 自动切换
  - 有 model 时优先从 model 取，否则用旧 API

### 11.5 root.zig 统一导出 ✅ 已完成
```zig
pub const model = struct {
    // 子模块
    pub const list_model = @import("model/list_model.zig");
    pub const selection_model = @import("model/selection_model.zig");
    pub const list_item_factory = @import("model/list_item_factory.zig");
    // 快速类型别名
    pub const ListModel = list_model.ListModel;
    pub const ListStore = list_model.ListStore;
    pub const StringListStore = list_model.StringListStore;
    pub const SelectionModel = selection_model.SelectionModel;
    pub const NoSelection = selection_model.NoSelection;
    pub const SingleSelection = selection_model.SingleSelection;
    pub const MultiSelection = selection_model.MultiSelection;
    pub const ListItem = list_item_factory.ListItem;
    pub const ListItemFactory = list_item_factory.ListItemFactory;
    pub const SignalListItemFactory = list_item_factory.SignalListItemFactory;
    pub const SimpleTextFactory = list_item_factory.SimpleTextFactory;
};
```
用户使用方式: `const m = zigui.model; var store = try m.newStringListStore(alloc);`

---

## 阶段十二：P3 模型层增强（GTK4 核心模型组件补全）

> 补全 GTK4 核心模型层组件，对标 GtkAdjustment + GListModel 家族（过滤/排序/映射/树/切片/展平）。

### 12.1 Adjustment — 值调整对象（高优先级）
- **优先级**: 高 (P3)
- **GTK 对应**: GtkAdjustment
- **文件**: `src/model/adjustment.zig`
- **设计**:
  ```zig
  pub const Adjustment = struct {
      value: f32,
      lower: f32,
      upper: f32,
      step_increment: f32,   // 步长（点击箭头）
      page_increment: f32,   // 翻页（PageUp/Down）
      page_size: f32,        // 可见页面大小（ScrollBar 用）
      on_changed: ?*const fn(self: *Adjustment) void,
      on_value_changed: ?*const fn(self: *Adjustment) void,
  };
  ```
- **功能**:
  - `create(lower, upper, value, step_inc, page_inc, page_size)`
  - `setValue(v)` / `getValue()` — 自动 clamp，触发 value-changed
  - `clampPage(lower, upper)` — 滚动条范围夹取
  - `configure(lower, upper, value, step_inc, page_inc, page_size)` — 批量配置
  - `value-changed` / `changed` 两个信号回调

### 12.2 Filter + FilterListModel — 列表过滤模型（高优先级）
- **优先级**: 高 (P3)
- **GTK 对应**: GtkFilter + GtkFilterListModel
- **文件**: `src/model/filter_list_model.zig`
- **设计**:
  ```zig
  pub const Filter = struct {
      matchFn: *const fn(userdata: ?*anyopaque, item: ?*anyopaque) bool,
      userdata: ?*anyopaque,
  };
  pub const CustomFilter = struct { /* 包装 matchFn 闭包 */ };
  pub const BoolFilter = struct { expression: Expression, invert: bool };
  pub const StringFilter = struct { search: []const u8, ignore_case: bool };
  pub const MultiFilter = struct { match_mode: enum { all, any }, items: []Filter };

  pub const FilterListModel = struct {
      model: ListModel,         // 原始模型
      filter: ?Filter,          // 过滤器 (null=不过滤)
      items: std.ArrayListUnmanaged(usize), // 映射表: view_idx → source_idx
      on_items_changed: ...
  };
  ```
- **功能**:
  - `setFilter(filter)` — 切换过滤器，自动重算映射
  - 实现 ListModelIface，可被 SelectionModel / ColumnView 直接消费
  - 监听源模型 items-changed，增量更新映射表

### 12.3 Sorter + SortListModel — 列表排序模型（高优先级）
- **优先级**: 高 (P3)
- **GTK 对应**: GtkSorter + GtkSortListModel
- **文件**: `src/model/sort_list_model.zig`
- **设计**:
  ```zig
  pub const Ordering = enum(i8) { smaller = -1, equal = 0, larger = 1 };
  pub const Sorter = struct {
      compareFn: *const fn(a: ?*anyopaque, b: ?*anyopaque) Ordering,
  };
  pub const CustomSorter = struct { /* 包装 compareFn */ };
  pub const StringSorter = struct { /* 按字符串字段排序, 支持大小写 */ };
  pub const NumericSorter = struct { /* 按 f32/i32/i64 数值字段排序 */ };

  pub const SortListModel = struct {
      model: ListModel,
      sorter: ?Sorter,
      order: enum { ascending, descending },
      mapping: []usize,       // view_idx → source_idx
      on_items_changed: ...
  };
  ```
- **功能**:
  - `setSorter(sorter, order)` — 切换排序器，自动重算映射
  - 实现 ListModelIface，可被 SelectionModel 消费
  - incremental sort（稳定排序）

### 12.4 MapListModel — 映射模型（中优先级）
- **优先级**: 中 (P3)
- **GTK 对应**: GtkMapListModel
- **文件**: `src/model/map_list_model.zig`
- **功能**:
  - 输入 ListModel<T>，输出 ListModel<U>（user 提供 mapFn: T→U）
  - 可链式: `Filter → Sort → Map → SelectionModel → ColumnView`
  - 源模型变更时增量重映射

### 12.5 TreeListModel — 树形列表模型（中优先级）
- **优先级**: 中 (P3)
- **GTK 对应**: GtkTreeListModel
- **文件**: `src/model/tree_list_model.zig`
- **功能**:
  - 提供 `createFunc(root_item) → ListModel` 递归扩展子项
  - 展开后把子项扁平化插入主列表 (行位置管理)
  - 配合 TreeExpander 使用：每行对应 TreeListRow，提供 depth / expanded / has_children
  - `autoexpand: bool` 是否自动展开所有层

### 12.6 SliceListModel + FlattenListModel — 切片/展平模型（低优先级）
- **优先级**: 低 (P3)
- **GTK 对应**: GtkSliceListModel + GtkFlattenListModel
- **文件**: `src/model/slice_list_model.zig`, `src/model/flatten_list_model.zig`
- **Slice**: 取源模型 `[offset, offset+size)` 区间，用于分页
- **Flatten**: 把 ListModel<ListModel<T>> 展平为 ListModel<T>
- 均实现 ListModelIface，可无缝链式组合

---

## 阶段二十一：P22 GTK4 高级交互与布局补全

> 补齐 GTK4 高级交互控件：搜索框进阶 API、手势识别、约束布局、三大 Chooser 对话框。均通过 `root.zig` 模块路径导出（无类型别名）。

### 21.1 SearchEntry GTK4 API 进阶
- **优先级**: 高 (P22)
- **GTK 对应**: GtkSearchEntry
- **文件**: `src/widget/search_entry.zig`
- **功能**:
  - `setLoading(loading)` / `isLoading()` — 加载状态，左侧放大镜变为 8 点旋转环形加载动画（按帧相位自动旋转）
  - `setSearchDelay(delay_ms)` / `getSearchDelay()` — 搜索延迟触发，默认 150ms；内部状态字段 `delay_timer_active/pending_text` 供上层轮询
  - `setKeyCaptureWidget(widget)` / `getKeyCaptureWidget()` — 指定快捷键捕获目标

### 21.2 SearchBar GTK4 API 进阶
- **优先级**: 高 (P22)
- **GTK 对应**: GtkSearchBar
- **文件**: `src/widget/search_bar.zig`
- **功能**:
  - `setSearchMode(mode)` / `getSearchMode()` — 切换搜索模式（模式=显示/隐藏）
  - `connectEntry(entry)` / `setSearchEntry(entry)` / `getSearchEntry()` — 关联外部 SearchEntry，自动解绑旧回调再绑定新回调
  - `setShowCloseButton(show)` / `getShowCloseButton()` — 控制关闭按钮可见性，内部通过 `close_button.base.visible` 切换

### 21.3 Gesture 系列（手势识别）
- **优先级**: 中 (P22)
- **GTK 对应**: GtkGestureClick / GtkGestureDrag / GtkGestureLongPress / GtkGestureZoom
- **文件**: `src/widget/gesture.zig`
- **结构**:
  - `GestureBase` / `GestureSingle` — 基类，通用 `attached_widget / n_points / is_active` 状态
  - `GestureClick` — 单击/双击/多击识别（`400ms + 4px` 容差，`on_pressed/on_released/on_stopped/on_unpaired_release`）
  - `GestureDrag` — 拖拽识别（8px 阈值，`on_drag_begin/update/end`；`getStartPoint/getOffset`）
  - `GestureLongPress` — 长按识别（默认 500ms + 10px 容差；通过 EventController.tick 每帧推进超时）
  - `GestureZoom` — 双指缩放（左右键+移动模拟；`getScaleDelta`，`on_begin/on_scale_changed/on_end`）
- **挂接方式**: 通过 `Widget.event_controllers` + `EventController.wrap(T, obj, handleEvent, tickFn, name)` 自动封装为通用事件控制器；`attach(widget)` 即挂；`destroy` 时 `removeEventController` 解除

### 21.4 ConstraintLayout 约束布局
- **优先级**: 中 (P22)
- **GTK 对应**: GtkConstraintLayout
- **文件**: `src/widget/constraint_layout.zig`
- **功能**:
  - `ConstraintAttribute` 枚举：`start/end/top/bottom/left/right/width/height/center_x/center_y/baseline`
  - `ConstraintRelation` 枚举：`less_than_or_equal / equal / greater_than_or_equal`
  - `Constraint` 线性关系：`target.attr = source.attr × multiplier + constant`（`source = null` 表示父容器）
  - 求解器：按 `strength` 降序 + 最多 8 轮松弛迭代
  - 便捷 API：`pinToParent(child, padding)` / `centerInParent(child)` / `setSize(child, w, h)`
  - 子控件移除时销毁（遵循硬约束）+ 清理引用该子控件的所有约束

### 21.5 三大 Chooser 对话框
- **优先级**: 中 (P22)
- **GTK 对应**: GtkAppChooserDialog / GtkColorChooserDialog / GtkFontChooserDialog
- **文件**: `src/widget/chooser_dialogs.zig`
- **AppChooserDialog**（应用选择）:
  - `AppInfo` 结构：`display_name / executable / icon_name / supported_types`
  - `addApp(app)` / `getSelectedApp()` / `on_response(response, ?*AppInfo)`
  - 全屏遮罩 + 居中模态框；ESC 取消；OK/Cancel 按钮
- **ColorChooserDialog**（颜色选择）:
  - 内置 20 色 2×10 调色板（可点击选中，自绘方块 + 边框 + 命中测试）
  - HEX 输入框、实时预览框、use_alpha
  - 当前色 `getCurrentColor()` / `setCurrentColor()`
- **FontChooserDialog**（字体选择）:
  - Family / Size 输入框、Bold/Italic 切换按钮
  - 预览文本区（默认英文 + CJK 样本，支持 `preview_text` 配置）
  - `getFontFamily/getFontSize/isBold/isItalic` / `on_response(...)`

---

## 阶段二十二：P23 核心系统补全

> 深入 Widget 事件系统底层（EventController），补全 DnD 自动挂接、Entry 自动补全、列表行独立结构体、焦点/移动/滚动事件控制器，以及 GTK4 打印核心数据结构。

### 22.1 Widget 级 EventController 架构
- **优先级**: 高 (P23)
- **GTK 对应**: GtkEventController
- **文件**: `src/widget/widget.zig`
- **功能**:
  - 新增 `pub const EventController` 结构：`self_ptr` (类型擦除) + `handle_event` + 可选 `tick` + `name`
  - `EventController.wrap(comptime T, obj, handleFn, ?tickFn, name)` — 生成 shim，将 `*anyopaque` 转换回具体 `T`（解循环依赖）
  - Widget 字段 `event_controllers: std.ArrayListUnmanaged(EventController) = .empty`
  - `addEventController(alloc, ctrl)` / `removeEventController(ctrl_self)` — 挂接/移除
  - `tickControllers(delta_ms)` — 推进所有 controller 的 tick（长按等用）
  - `dispatchEvent` 流程调整：
    - 目标控件：先遍历 `event_controllers[i].handle_event(...)`，任一 `handled` 即返回
    - 冒泡链：每层父控件同样先遍历 `event_controllers` 再 `on_event`

### 22.2 EntryCompletion — Entry 自动补全（待实现）
- **优先级**: 高 (P23)
- **GTK 对应**: GtkEntryCompletion
- **文件**: `src/widget/entry_completion.zig`
- **功能**:
  - `setModel(model)` 绑定字符串 List / 自定义列表
  - `setTextColumn(column)` 指定显示列
  - `setMatchFunc(func)` 自定义匹配函数（默认前缀/包含匹配）
  - `setMinimumKeyLength(n)` — 触发最小击键数
  - Popover 弹出候选列表，方向键导航，Enter 补全，Esc 关闭

### 22.3 DragSource / DropTarget — EventController 挂接（待实现）
- **优先级**: 高 (P23)
- **GTK 对应**: GtkDragSource / GtkDropTarget（Gtk4.10+ Drag and Drop API）
- **文件**: `src/widget/drag_drop.zig` (增强) / 独立 `drag_source.zig`, `drop_target.zig`
- **功能**:
  - DragSource 作为 EventController 挂到 Widget：检测移动阈值后自动调用 `on_prepare/on_drag_begin`
  - DropTarget 作为 EventController：在 `on_event` 中接收 `drag_enter/move/leave/drop` 阶段事件
  - 调用链走 Widget.dispatchEvent → event_controllers.handle_event → 已有 `DragDropManager`

### 22.4 FlowBoxChild / ListBoxRow 独立结构体（待实现）
- **优先级**: 中 (P23)
- **GTK 对应**: GtkFlowBoxChild / GtkListBoxRow
- **文件**: 新增 / 修改 `src/widget/flow_box.zig`, `src/widget/list_box.zig`
- **功能**:
  - FlowBoxChild：独立包装 Widget，持有 `index / child / selectable / selected` 等状态，支持 `getChild/getIndex/isSelected`
  - ListBoxRow：独立包装 Widget，持有 `row_index / activatable / selectable / header`，支持 `setActivatable/getChild/setHeader`
  - FlowBox/ListBox 的 add/remove 改为返回对应 Child/Row 对象（遵循无别名原则）

### 22.5 EventController 系列：Focus/Motion/Scroll（待实现）
- **优先级**: 中 (P23)
- **GTK 对应**: GtkEventControllerFocus / GtkEventControllerMotion / GtkEventControllerScroll
- **文件**: `src/widget/event_controllers.zig` (或 widget.zig 内静态函数)
- **功能**:
  - EventControllerFocus：`on_enter` / `on_leave` 回调；绑定到 Widget 后监听 focus 状态变化
  - EventControllerMotion：`on_enter(x,y)` / `on_leave()` / `on_motion(x,y)`；监听鼠标悬停区域（命中目标 Widget）
  - EventControllerScroll：`on_scroll(dx, dy)` / `on_scroll_begin/end`；支持 `flags: none/vertical/horizontal/both/discrete`

### 22.6 打印核心数据结构：PaperSize / PrintSettings / PageSetup
- **优先级**: 中 (P23)
- **GTK 对应**: GtkPaperSize / GtkPrintSettings / GtkPageSetup
- **文件**: `src/model/print.zig` 或 独立 `paper_size.zig / print_settings.zig / page_setup.zig`
- **功能**:
  - PaperSize：预设 `A3/A4/A5/Letter/Legal/Tabloid` 等 + 自定义宽高（mm），`getWidth/getHeight(unit)`，`getDefault()`
  - PrintSettings：`printer/num_copies/collate/reverse/range(page_set)/orientation/color_mode/duplex/quality/resolution/scale/media_size`
  - PageSetup：`orientation + paper_size + 四边 margin(top/bottom/left/right, mm)`，`getPageWidth/Height()`
  - `saveToFile(key)` / `loadFromFile(key)`：序列化为 KV

---

## 阶段二十三：P24 兼容传统树模型 + 原生文件对话框 + 补漏

> 补漏 3 个已存在但漏导出的 widget（AppChooser/FontSelection/ToolPalette），
> 实现 GTK3 兼容传统树模型（GtkTreeModel/TreeStore/ListStore）用于旧版 TreeView 数据适配，
> 新增 GtkFileChooserNative 跨平台原生文件对话框，以及 ShortcutManager 统一快捷键管理。

### 23.1 补漏：3 个已存在但漏导出的 widget
- **AppChooser** (GtkAppChooserWidget):
  - 导出到 `zigui.app_chooser`，`AppChooserWidget` 列出所有支持给定 MIME 类型的应用
  - 配合已存在的 `app_chooser_button.zig` 使用
- **FontSelection** (GtkFontSelection):
  - 导出到 `zigui.font_selection`，字体选择的独立对象，提供 Family/Size/Bold/Italic/预览 API
  - 供 `font_chooser / font_button / font_dialog` 底层复用
- **ToolPalette** (GtkToolPalette):
  - 导出到 `zigui.tool_palette`，分组的工具按钮面板，每个组可折叠，组内按钮网格
  - 已有 `addGroup / addItem / setGroupCollapsed / getSelectedItem`

### 23.2 GTK3→GTK4 兼容传统树模型（TreeModel + TreeStore + ListStore）
- **优先级**: 中
- **GTK 对应**: GtkTreeModel / GtkTreeStore / GtkListStore / GtkTreeIter / GtkTreePath
- **文件**: `src/model/tree_model.zig`
- **设计**:
  - `TreePath = []u32`（从根到目标行的索引路径；列号独立）
  - `TreeIter = struct { stamp: c_int, user_data: ?*anyopaque, user_data2: ?*anyopaque, user_data3: ?*anyopaque }`
  - `TreeModelIface = struct { get_flags / get_n_columns / get_column_type / get_iter / get_path / get_value / iter_next / iter_children / iter_has_child / iter_n_children / iter_nth_child / iter_parent / ref_node / unref_node }`
  - `TreeModel = struct { iface: TreeModelIface, self: ?*anyopaque }`（类型擦除接口）
  - `ListStore`：扁平表格模型（N 列 × M 行），`append(iter) / set(iter, col, value) / get(iter, col) / remove(iter) / clear()`
  - `TreeStore`：分层树模型，`append(parent?, iter) / set(iter, col, value) / get(iter, col) / remove(iter) / iter_children(iter)`
  - 列类型支持 `string / int / uint / bool / float / pointer / color / pixbuf`，使用 tagged union `GValue`

### 23.3 GtkFileChooserNative — 原生文件对话框接口
- **优先级**: 中
- **GTK 对应**: GtkFileChooserNative（GTK4 跨平台原生文件对话框）
- **文件**: `src/widget/file_chooser_native.zig`
- **设计**:
  - `FileChooserAction = enum { open / save / select_folder / create_folder }`
  - 字段：`title / accept_label / cancel_label / action / current_name / current_folder / filters / do_overwrite_confirmation / select_multiple`
  - API：`create(action, title, accept_label, cancel_label) / show(parent_window, on_response, on_error) / setFileFilter(filter) / addFilter(filter) / getFile() / getFiles() / destroy()`
  - 回退实现：在桌面平台优先调原生对话框（Linux: XDG Portal / GTK dialog，macOS: NSOpenPanel/NSSavePanel）；回退使用 `file_chooser.zig` 内部实现
  - `FileFilter` 复用已实现的 `model.file_filter.FileFilter`

### 23.4 ShortcutManager — 统一快捷键管理
- **优先级**: 中
- **GTK 对应**: GtkShortcutManager (GTK4 接口) / GtkShortcutController
- **文件**: `src/widget/shortcut_manager.zig` (或扩展 shortcut.zig)
- **设计**:
  - `Shortcut = struct { trigger: ShortcutTrigger, action: ShortcutAction, args: ?ShortcutArgs }`
  - `ShortcutTrigger = enum(u8) { keyval, modifier, keycode, alternative }` + `key / mods` 字段
  - `ShortcutAction = enum(u8) { activate / mnemonic_activate / signal_activate / callback }` + user callback
  - `ShortcutManager = struct { shortcuts: ArrayList(Shortcut) }`，提供 `addShortcut / removeShortcut / handleKey(event)`
  - 应用层：`app.addShortcut(accel, callback)` → 最终注册到 ShortcutManager；全局 dispatch 时优先匹配
  - 与现有 `shortcut.zig` / `shortcut_controller.zig` 整合（避免重复实现）

### 23.5 Export + AST 全量验证
- `model` 命名空间新增：`pub const tree_model = @import("model/tree_model.zig");`
- 顶层 widget 新增：`file_chooser_native / shortcut_manager`（如后者为独立文件）
- AST 全量验证 0 error

---

## 阶段二十四：P25 GTK4 通用接口 + 打印运行

> 实现 GTK4 四大通用接口 (Orientable / Scrollable / Root / Toplevel)，
> 并补齐打印运行时 (PrintOperation) 与 Unix 页面设置对话框。

### 24.1 GTK4 四大通用接口（Orientable / Scrollable / Root / Toplevel）
- **优先级**: 中
- **GTK 对应**: GtkOrientable / GtkScrollable / GtkRoot / GtkToplevel
- **文件**: `src/widget/gtk_interfaces.zig`
- **设计**:
  - **OrientableIface**（方向接口）：
    - `get_orientation(self) → Orientation`、`set_orientation(self, Orientation)`
    - `Orientation = enum { horizontal, vertical }`
    - 实现方：Box / Scale / Paned / Scrollbar / Separator / LevelBar 等
  - **ScrollableIface**（可滚动接口）：
    - 字段 `hadjustment: ?*Adjustment` / `vadjustment: ?*Adjustment`
    - 接口：`set_hadjustment / get_hadjustment / set_vadjustment / get_vadjustment`
    - `ScrollablePolicy = enum { minimum, natural }`；`hscroll_policy`、`vscroll_policy`
    - 实现方：TextView / TreeView / ColumnView / IconView / Viewport
  - **RootIface**（根接口，所有顶层窗口实现）：
    - `get_display(self)` / `get_focus(self) → ?*Widget` / `set_focus(self, ?*Widget)`
    - `widget: *Widget`（根控件引用）
  - **ToplevelIface**（顶级窗口接口，GtkWindow/ApplicationWindow 实现）：
    - `present(self)` / `close(self)` / `minimize(self)` / `maximize(self)` / `unmaximize(self)` / `fullscreen(self)` / `unfullscreen(self)`
    - `get_title(self) → []const u8`、`set_title(self, []const u8)`
    - `get_modal(self) → bool`、`set_modal(self, bool)`
    - `begin_resize(self, edge, button, x, y, timestamp)`
  - 提供类型擦除包装：`Orientable = struct { iface + self_ptr }`、`Scrollable`、`Root`、`Toplevel`

### 24.2 PrintOperation — 打印运行时操作
- **优先级**: 中
- **GTK 对应**: GtkPrintOperation
- **文件**: `src/model/print_operation.zig`
- **核心字段**:
  - `job_name: []const u8`、`unit: Unit`、`export_filename: []const u8`（导出 PDF/PS/SVG）
  - `print_settings: ?PrintSettings`、`default_page_setup: ?PageSetup`
  - `track_print_status: bool`、`show_progress: bool`、`allow_async: bool`
  - `n_pages_to_print: i32`、`current_page: i32`
  - 状态机：`status: enum { initial / preparing / generating_data / sending_data / pending / finished / finished_aborted }`
- **回调**（对齐 GTK4 命名）：
  - `on_begin_print(op, context)` — 设置 n_pages
  - `on_draw_page(op, context, page_nr)` — 绘制指定页
  - `on_end_print(op, context)` — 清理
  - `on_status_changed(op)` / `on_done(op, result)` / `on_preview(op, preview, context)`
- **API**:
  - `create(settings, default_page_setup, on_begin_print, on_draw_page, on_end_print?)`
  - `run(parent_window, action: PrintOperationAction) → PrintOperationResult`
    - `action: print / print_dialog / preview / export`
  - `getError()`、`getStatusString()`、`getProgress()`
  - `draw_page_finish(result)`（分页绘制完成信号）

### 24.3 PageSetupUnixDialog — Unix 页面设置对话框
- **优先级**: 低
- **GTK 对应**: GtkPageSetupUnixDialog
- **文件**: 在 `src/widget/print_dialog.zig` 或 新增独立 `page_setup_unix_dialog.zig`
- **设计**:
  - 独立模态对话框：PaperSize 选择（下拉/列表）、方向切换（纵向/横向/反向）、四边 margin 数值输入（mm/英寸）、预览框显示纸张可打印区域
  - API：`create(title, parent?)` / `setPageSetup(setup)` / `getPageSetup()` / `setPrintSettings(settings)` / `getPrintSettings()`
  - `on_response(response: ok|cancel, new_setup)` 回调；ESC 取消；OK 保存并应用

### 24.4 导出 & AST 全量验证
- `widget.gtk_interfaces` 模块导出 Orientable / Scrollable / Root / Toplevel
- `model.print_operation` 模块导出 PrintOperation
- 顶层 widget：`page_setup_unix_dialog`（若新建独立文件）或通过 print_dialog 追加
- AST 全量验证 0 error

---

## 阶段二十五：P26 GTK4 可绘制对象 + 布局管理器 + 导出补漏

### 25.1 导出 10 个已存在但漏导出的组件 (P24 同类补漏)
- **优先级**: 高
- **问题**: 已有实现 12 个文件，仅 builder.zig 被 root.zig 导出
- **补漏清单（AST 全通过）**:
  - model 层：`bitset`（Bitset 位集合）、`selection_model`（NoSelection/SingleSelection/MultiSelection）、`list_item_factory`（ListItem/SignalListItemFactory/ListItemFactory）
  - widget 层：`picture`（GtkPicture 图片显示）、`header_bar`（GtkHeaderBar 标题栏）、`window_controls`（GtkWindowControls 最小/大/关闭）、`alert_dialog`（GtkAlertDialog 简易警告）、`message_dialog`（GtkMessageDialog 消息框）、`assistant`（GtkAssistant 向导）、`recent_chooser`（GtkRecentChooser 最近文档）

### 25.2 Paintable 可绘制对象接口
- **优先级**: 中
- **GTK 对应**: GdkPaintable
- **文件**: `src/widget/paintable.zig` 或 `src/render/paintable.zig`
- **PaintableIface** (对齐 GTK 命名)：
  - `get_flags(self) → PaintableFlags`（bitset：static_sizes / scalable / empty）
  - `get_intrinsic_width(self) → i32`、`get_intrinsic_height(self) → i32`
  - `get_intrinsic_aspect_ratio(self) → f32`（宽/高，0 表示无）
  - `snapshot(self, snapshot_ptr, width: f32, height: f32)`：实际绘制（snapshot 为 *anyopaque 跨 renderer）
- **类型擦除包装** `Paintable`：`{ iface, self_ptr }`
- **便捷实现**：
  - `TexturePaintable`：纹理贴图 paintable（url/data 字段 + intrinsic_size）
  - `SymbolPaintable`：可缩放符号 paintable（is_icon_scaled + scalable flag）
  - `EmptyPaintable`：尺寸空占位（flags=empty）

### 25.3 LayoutManager 布局管理器家族（GTK4 核心）
- **优先级**: 中
- **GTK 对应**: GtkLayoutManager 及 7 个派生
- **文件**: `src/widget/layout_manager.zig`
- **LayoutManagerIface**（vtable）：
  - `get_request_mode(self, widget) → SizeRequestMode`（height_for_width / width_for_height / constant_size）
  - `measure(self, widget, orientation, for_size: f32) → min: f32, nat: f32, min_baseline?, nat_baseline?`
  - `allocate(self, widget, width: f32, height: f32, baseline: i32)`：实际分配子控件坐标
- **LayoutChild** (布局子项，每个 widget 对应一个布局子项)：
  - `manager`、`widget`、`user_data: ?*anyopaque`
  - `getLayoutChild(self, widget) → LayoutChild?`
- **7 个具体布局**：
  - **BinLayout**：单子控件布局（fill、align x/y 0-1）
  - **BoxLayout**：同方向盒子布局（spacing / homogeneous / expand per child / spacing_placeholder）
  - **CenterLayout**：中心布局（start / center / end 三个位，shrink_center_last）
  - **GridLayout**：网格布局（row_spacing / col_spacing / row_homogeneous / col_homogeneous，子项 row/col/row_span/col_span）
  - **OverlayLayout**：叠加布局（child_overlay/clip_overlay）
  - **FixedLayout**：固定位置布局（child_x/child_y）
  - **CustomLayout**：自定义布局（传入 3 个自定义函数指针替代 vtable）
- **通用 API**（LayoutManager 包装）：
  - `layout(widget)`、`get_request_mode(widget)`、`measure(widget, o, s)`、`allocate(widget, w, h, b)`
  - `layoutChild(widget) → ?LayoutChild`

### 25.4 root.zig 同步 & AST 全量验证
- 新增导出：`model.bitset` / `model.selection_model` / `model.list_item_factory`
- 新增导出：widget 层 `paintable` / `layout_manager` / `picture` / `header_bar` / `window_controls` / `alert_dialog` / `message_dialog` / `assistant` / `recent_chooser`
- 全量 AST 验证 0 error

---

## 阶段二十六：P27 打印对话框 + 输入法上下文 + 分段模型 + 多排序器 + 导出补漏

### 26.1 补漏导出（已存在实现，AST 通过）
- **优先级**: 高
- `widget/drawing_area.zig` — GtkDrawingArea 自定义绘制区域（已完整实现，漏导出）
- `widget/icon_view.zig` — GtkIconView 图标网格视图（已完整实现，漏导出）

### 26.2 PrintUnixDialog — UNIX 打印对话框
- **优先级**: 中
- **GTK 对应**: GtkPrintUnixDialog
- **文件**: `src/widget/print_unix_dialog.zig`
- **功能**:
  - 打印机列表 ComboBox（从 PrintSettings.printer / 自定义列表）
  - 份数 SpinButton（1-999）+ 逐份打印/逆序
  - 范围：全部/当前页/页码范围（文本框，如 "1-5, 8, 10-12"）
  - 双面模式：单面/长边翻转/短边翻转
  - 页设置按钮：点击弹出 PageSetupUnixDialog
  - 纸张尺寸/方向预览（文本或 mini 示意框）
  - OK / Cancel 按钮；ESC 关闭
- **API**:
  - `create(allocator, title, parent?)` / `destroy`
  - `setCurrentPage(n)` / `getNPages()` / `setNPages(n)`
  - `setPrintSettings(settings)` / `getPrintSettings()`
  - `setPageSetup(setup)` / `getPageSetup()`
  - `setManualCapabilities(flags: PrintCapabilities)`
  - `present(parent?)` / `close()` / `on_response(response, settings, setup)` 回调
- **枚举**:
  - `PrintCapabilities = packed struct { page_set:bool, copies:bool, collate:bool, reverse:bool, scale:bool, generate_pdf:bool, generate_ps:bool, ... }`
  - `PageSet = enum { all, even, odd }`

### 26.3 IMContext — 输入法上下文 (IME 预编辑接口)
- **优先级**: 中
- **GTK 对应**: GtkIMContext / GtkIMMulticontext / GtkIMContextSimple
- **文件**: `src/widget/im_context.zig`
- **IMContextIface**（vtable，类型擦除）：
  - `set_client_widget(self, widget: ?*Widget) void`
  - `get_preedit_string(self, out_str[]: u8, attrs: ?*PreeditAttrList, cursor_pos: *i32) void`
  - `filter_keypress(self, event: *const KeyEvent) bool` — 返回 true 表示 IME 内部消费
  - `focus_in / focus_out / reset(self) void`
  - `set_cursor_location(self, rect: Rect) void`
  - `set_use_preedit(self, use: bool) void`
  - `set_surrounding(self, text: []const u8, cursor_index: i32, selection_index: i32) bool`
- **回调 (event)**:
  - `on_commit(self_ptr: ?*anyopaque, str: []const u8) void` — 用户确认提交文本
  - `on_preedit_changed(self_ptr: ?*anyopaque) void`
  - `on_preedit_end(self_ptr: ?*anyopaque) void`
  - `on_retrieve_surrounding(self_ptr: ?*anyopaque) bool`
  - `on_delete_surrounding(self_ptr: ?*anyopaque, offset: i32, n_chars: i32) bool`
- **PreeditAttrList** — 预编辑属性（下划线/高亮/光标等 Pango 风格简化版）：`underline(None/Single/Double/Error)/foreground(color)/background(color)` 数组
- **IMMulticontext** — 多 IME 调度器，切换 backend ID（如 `ibus` / `fcitx` / `simple`）；持有 `current_context: ?*IMContext`
- **IMContextSimple** — 最简 ASCII + Compose Key 组合实现：内置死键/组合序列表（如 `` `a → à ``、`'e → é`、`^i → î`、`"u → ü`、`~n → ñ`、`Compose + A + E → æ`）

### 26.4 SectionModel + MultiSorter
- **优先级**: 中
- **GTK 对应**: GtkSectionModel / GtkSectionListModel + GtkMultiSorter
- **SectionModel 文件**: `src/model/section_model.zig`
  - `SectionModelIface`: `get_n_sections(self) → u32`、`get_section(self, idx: u32) → SectionInfo`
    - `SectionInfo` = { start: u32, end: u32 }（半开区间）
  - `SectionListModel` 实现：根据 section_key_extract 函数对输入 ListModel 进行稳定分组（相同 key 合并为一个 Section）
- **MultiSorter 文件**: `src/model/multi_sorter.zig`
  - `MultiSorter`：持有 `sorters: ArrayListUnmanaged(SorterWithPriority)`，每个项 = `Sorter + priority`（或按顺序优先级）
  - `compare(a, b)`：按顺序调用每个 sorter，直到非 equal；或按 priority 数字升序优先
  - `addSorter(sorter, priority?)`、`removeSorter(idx)`、`clear()`、`getSorterCount() → u32`
  - 导出 `asSorter() → Sorter` 接口包装（可直接用于 SortListModel）

### 26.5 root.zig 同步 + AST 全量验证
- widget 层：`drawing_area`、`icon_view`、`print_unix_dialog`、`im_context`
- model 层：`section_model`、`multi_sorter`
- 全量 AST 验证 0 error

---

## 阶段二十七：P28 GTK4 全局底层 & 核心抽象补全（Settings / Display / Clipboard / Texture / NativeDialog / ConstraintGuide）

> 目标：补齐 GTK4 底层核心对象（全局设置、显示管理、剪贴板、纹理、原生对话框接口、约束导引），与 pal 层/布局层整合，为上层控件提供统一 GTK 风格 API。

### 27.1 GtkSettings — 全局显示/样式设置
- **优先级**: 中
- **GTK 对应**: GtkSettings（单例，持有所有 gtk 全局设置）
- **文件**: `src/widget/settings.zig`
- **设计**:
  - 单例 `default_settings = *Settings`，`getDefault() *Settings`
  - 字段：`gtk_font_name: []const u8 = "Inter 12"`、`gtk_theme_name: []const u8 = "Adwaita"`、`gtk_icon_theme_name: []const u8`、`gtk_xft_dpi: i32 = 96`（1/1024 inch）
  - 开关：`gtk_application_prefer_dark_theme: bool`、`gtk_dialogs_use_header: bool = true`、`gtk_overlay_scrolling: bool = true`、`gtk_cursor_blink: bool = true`
  - 动画：`gtk_enable_animations: bool = true`、`gtk_cursor_blink_time: i32 = 1200 ms`、`gtk_double_click_time: i32 = 400 ms`、`gtk_double_click_distance: i32 = 5 px`
  - DnD / 触控：`gtk_dnd_drag_threshold: i32 = 8`、`gtk_long_press_timeout: i32 = 500 ms`
  - API：`set(key, value)` / `get(key)` 泛型字符串查找（可选），+ 直接字段读写

### 27.2 GdkDisplayManager + GdkDisplay — 显示/屏幕抽象
- **优先级**: 中
- **GTK 对应**: GdkDisplayManager + GdkDisplay + GdkMonitor
- **文件**: `src/widget/display.zig`（单文件包含三者）
- **GdkMonitor**: `manufacturer/model`、`geometry: Rect`、`workarea: Rect`、`scale_factor: i32 = 1`、`refresh_rate: i32`、`is_primary: bool`
- **GdkDisplayIface**（vtable，类型擦除）：`get_n_monitors / get_monitor(idx) / get_default_monitor / get_name / is_closed / sync / make_default / beep / get_default_seat(opt)`
- **GdkDisplay** 包装：`iface + self_ptr + user_data`
- **GdkDisplayManager**: `instance = *DisplayManager` 单例；`getDefaultDisplay() ?*Display`、`getNDisplays() u32`、`getDisplay(idx) *Display`、`openDisplay(name)`（pal 层 open）

### 27.3 GdkClipboard — 剪贴板
- **优先级**: 中
- **GTK 对应**: GdkClipboard（GTK4，Display/Seat clipboard）
- **文件**: `src/widget/clipboard.zig`（widget 层，包装 pal/clipboard.zig OS 调用）
- **设计**:
  - 字段：`display: ?*Display`（可选，Display 关联）
  - 基础 API：`getDefault() *Clipboard`、`setText(self, str)`（调用 `pal.clipboard.setText`）、`readText(self, allocator) ?[]u8`（调用 `pal.clipboard.getText`；失败返回 null）
  - 扩展：`setContent(self, mimeType, bytes)`（预留存占位、后续真正实现提供不同 MIME 支持，当前 mime_type="text/plain" 委托 `setText`）
  - 回调钩子：`on_content_changed(self, ud)`

### 27.4 GdkTexture + GdkTextureDownloader — 像素/纹理
- **优先级**: 中
- **GTK 对应**: GdkTexture（GdkPaintable 实现）/ GdkMemoryTexture / GdkTextureDownloader
- **文件**: `src/widget/texture.zig`
- **GdkTexture**:
  - `width / height: i32`
  - `asPaintable(self) Paintable`（paintable.zig 已实现接口包装，`snapshot(self, snapshot_ptr, w, h)` 用纹理 rect 占位）
  - `MemoryTexture.createFromBytes(width, height, rowstride, bytes: []const u8) *Texture`
- **GdkTextureDownloader**:
  - `downloader = TextureDownloader{ texture: *Texture }`
  - `downloadBytes(self, out_rowstride: *i32) []const u8`（直接返回内存纹理字节，否则 null）
  - `download(self, gpu_image_ptr: ?*anyopaque) void`（GPU 上传占位，供后续 Vulkan 真正实现）

### 27.5 NativeDialog — 原生对话框接口基类
- **优先级**: 中
- **GTK 对应**: GtkNativeDialog（GTK4 原生对话框基类，FileChooserNative 继承）
- **文件**: `src/widget/native_dialog.zig`
- **设计**:
  - `NativeDialogIface（vtable）: `show(self, modal, parent) bool`、`hide(self) void`、`destroy(self) void`、`setModal(self, bool) void`、`getModal(self) bool`、`setTitle(self, title) / getTitle`、`setTransientFor(self, parent?)`
  - `NativeDialog` 包装：`iface + self_ptr + user_data + title: []const u8 + modal: bool + transient_for: ?*anyopaque`
  - 回调：`on_response(self, response_id: i32)`（response_id: GTK_RESPONSE_ACCEPT = -3 / REJECT = -4 / DELETE_EVENT = -2）
  - FileChooserNative 可通过该接口 wrap

### 27.6 ConstraintGuide — 约束布局导引/参考线
- **优先级**: 低
- **GTK 对应**: GtkConstraintGuide（GtkConstraintTarget，约束参考对象，非 Widget）
- **文件**: 在 `src/widget/constraint_layout.zig` 中新增 pub `ConstraintGuide`
- **设计**:
  - `ConstraintGuide` = struct { `name: []const u8`, `min_size/width: f32`, `nat_size: f32`, `max_size: f32`, `strength: f32` } × 2（水平 + 垂直各一组）
  - 便捷 API：`setName(self, name)`、`setMinSize(h_size, v_size)`、`setNatSize(h_size, v_size)`、`setMaxSize(h_size, v_size)`、`setStrength(level)`（level ∈ require/strong/medium/weak，对应 1.0 / 0.9 / 0.7 / 0.5）
  - `asConstraintTarget(self) *const anyopaque`：在约束 `constrain(guide, ...)` 中可直接充当 source/target（求解时通过 widget? == null 判定为 Guide，矩形值通过 guide 存储）

### 27.7 root.zig 同步导出 + AST 全量验证
- **widget 层新增**: `settings`、`display`、`clipboard`、`texture`、`native_dialog`
- **constraint_layout.zig**：内部新增 `ConstraintGuide` pub，无需改 root.zig（通过 `zigui.constraint_layout.ConstraintGuide` 访问）
- 全量 AST 验证 0 error

---

## 阶段二十八：P29 模型层补漏导出 + SignalListModel + CellRenderer 家族

> 目标：补漏导出 4 个已实现但长期未暴露的 ListModel 变换（Map/Sort/Filter/SliceFlatten），使
> `Custom/String/Numeric/Multi Sorter & Filter` 可直接通过根命名空间访问；新建 SignalListModel
> （GTK4 GListModel items-changed 信号机制）与 CellRenderer 家族（Text/Pixbuf/Toggle/Progress/Spin），
> 对标 GTK4 完整模型/渲染管线。

### 28.1 补漏导出：4 个已实现 ListModel 变换（均 AST 通过，已存在源码）
- **优先级**: 高
- **文件**: `src/model/map_list_model.zig`、`src/model/sort_list_model.zig`、`src/model/filter_list_model.zig`、`src/model/slice_flatten_list_model.zig`
- **每个文件内含的子模块（因此一导即全）**：
  - `sort_list_model.zig`：`Ordering / Sorter / SorterCompareFn / SortOrder` + `CustomSorter / StringSorter / NumericSorter` + `SortListModel`
  - `filter_list_model.zig`：`FilterMatchFn / Filter` + `CustomFilter / StringFilter / BoolFilter / MultiFilter` + `FilterListModel`
  - `map_list_model.zig`：`MapFn` + `MapListModel`（T → U 变换）
  - `slice_flatten_list_model.zig`：`SliceListModel`（分页/切片）+ `FlattenListModel`（嵌套 ListModel 展平）
- **root.zig model 命名空间新增 4 条 pub**：
  - `pub const sort_list_model = @import("model/sort_list_model.zig");`
  - `pub const filter_list_model = @import("model/filter_list_model.zig");`
  - `pub const map_list_model = @import("model/map_list_model.zig");`
  - `pub const slice_flatten_list_model = @import("model/slice_flatten_list_model.zig");`
- 调用示例：`zigui.model.sort_list_model.StringSorter` / `zigui.model.filter_list_model.MultiFilter`

### 28.2 SignalListModel — GListModel 信号/事件机制
- **优先级**: 中
- **GTK 对应**: GtkSignalListItemFactory（的 item 信号源思路）/ GListModel items-changed 信号
- **文件**: `src/model/signal_list_model.zig`
- **设计**:
  - 包装任意 `ListModel` + 提供 `onItemsChanged(position: usize, removed: u32, added: u32)` 多回调槽
  - `SignalListModel = struct { inner: ListModel, callbacks: ArrayListUnmanaged(CallbackSlot) }`
  - `CallbackSlot = struct { cb: ItemsChangedFn, userdata: ?*anyopaque }`
  - API：`wrap(inner ListModel) / addOnItemsChanged(cb, ud) → slot_id / removeSlot(id) / emitChanged(pos, rem, add)`
  - `model() → ListModel`：把自身包装为 ListModel，所有 getItem/nItems/getItemType 委托 inner
  - 典型：`SignalListModel` 套在 StringList / DirectoryList 外，任何时候 source 调用 `emitChanged` → 所有 UI（ColumnView/GridView）重绘

### 28.3 CellRenderer 家族（GTK4 兼容 GTK3 传统渲染器）
- **优先级**: 中
- **GTK 对应**: GtkCellRenderer / GtkCellRendererText / GtkCellRendererPixbuf / GtkCellRendererToggle / GtkCellRendererProgress / GtkCellRendererSpin
- **文件**: `src/widget/cell_renderer.zig`（单文件，pub 多子结构体）
- **通用 CellRendererIface**（vtable）：
  - `getPreferredWidth/Height(self, cell_area) → (min, nat)`
  - `render(self, snapshot_ptr, widget, cell_area, background_area, flags)`
  - `activate(self, event, widget, path, cell_area, flags) → bool`（Toggle/RendererText 编辑入口）
  - `startEditing(self, event, widget, path, cell_area, flags) ?*CellEditable`（编辑开始）
- **CellRendererFlags**：`editable / editable_set / visible / sensitive / padding / align_fixed`（packed bool）
- **CellRendererState**：`selected / prelit / insensitive / sorted / focused / expandable`（位域）
- **CellArea / CellAreaBox（简化版）**：横向线性布局，`packStart/End(cell, expand, align, padding)`，含 LayoutManager 风格测量/分配
- **CellRendererText**：`text / markup / font / foreground / background / size_points / wrap_width / wrap_mode / align / valign / single_paragraph_mode / ellipsize / editable / width_chars / max_width_chars`；snapshot 时按 Pango text_layout 渲染（占位调用现有 `text_layout.render`）
- **CellRendererPixbuf**：`texture: ?*GdkTexture / icon_name / stock_id / icon_size`；snapshot 用 texture.asPaintable().snapshot() 绘制
- **CellRendererToggle**：`active / inconsistent / activatable / radio(bool 单选 or 复选)`；activate 时翻转 active 状态
- **CellRendererProgress**：`value: f32 (0..1) / text: ?[]const u8 / pulse: i32 / inverted`；绘制进度条 + 文本
- **CellRendererSpin**：`adjustment(步长/上下限) / climb_rate / digits`；startEditing 返回可编辑 SpinButton

### 28.4 root.zig 同步 + 全量 AST 验证
- **model 命名空间新增 5 条**：`sort_list_model`、`filter_list_model`、`map_list_model`、`slice_flatten_list_model`、`signal_list_model`
- **widget 层新增**: `cell_renderer`
- 全量 AST 验证 0 error

---

## 阶段二十九：P30 控件 & 辅助对象补全（EditableLabel / TreeViewColumn / TreeSelection / WidgetPaintable / ScrollInfo）

> 目标：补全 GTK4.2+ 重要新增控件（GtkEditableLabel），完善 GTK3 TreeView 生态（TreeViewColumn/TreeSelection），
> 新增 WidgetPaintable（Widget→Paintable 快照）与 ScrollInfo（滚动事件位置信息）。

### 29.1 EditableLabel — GTK4.2 可编辑标签
- **优先级**: 中
- **GTK 对应**: GtkEditableLabel（GtkWidget，继承 GtkWidget + 实现 GtkEditable）
- **文件**: `src/widget/editable_label.zig`
- **行为**：
  - 初始态：只读显示 Label 文本
  - 双击 / F2 / 调用 `startEditing()` → 切换为 Entry 内联编辑
  - Enter 键：确认提交 → 触发 `onEditingDone(self, text)` 回调，切换回只读
  - Esc 键：取消编辑 → 还原文本，切换回只读
  - 焦点离开 Entry：默认视为提交（GTK4 默认行为）
- **字段**: `text: []const u8`、`editing: bool`、`placeholder: []const u8`、`xalign / yalign`、`ellipsize`、`single_line_mode: bool`、`max_width_chars`
- **VTable 中嵌入 Entry**：创建时不子控件化；进入编辑态时，在 paint 路径切换到 Entry 绘制，事件转发给 Entry
- **API**: `create(allocator, initial_text) / destroy / startEditing / stopEditing(cancel: bool) / setText / getText`
- **回调**: `onEditingDone(self, text)`（提交）/ `onEditingStarted(self)`（开始）

### 29.2 TreeViewColumn — GTK3 GtkTreeView 的列定义
- **优先级**: 中
- **GTK 对应**: GtkTreeViewColumn
- **文件**: `src/widget/tree_view_column.zig`
- **字段**:
  - `title: []const u8`（列标题文本）
  - `sort_column_id: i32`（点击列头切换排序时的列 ID；-1 = 不可排序）
  - `sort_indicator: bool`（显示 ▲▼ 方向）
  - `sort_order: enum(u1) { ascending, descending }`
  - `clickable: bool`、`resizable: bool`、`reorderable: bool`
  - `expand: bool`（是否占据剩余水平空间）
  - `sizing: enum(u2) { grow_only, autosize, fixed }`、`fixed_width: i32 = -1`
  - `min_width / max_width: i32`、`spacing: u4`、`x_offset / width: i32`（布局实时）
  - `alignment: f32 (0..1)`（列头对齐）
  - `area: CellAreaBox`（内部渲染器列表；packStart/End 封装后透出）
- **API**:
  - `create(title) / destroy / packStart(cell, expand, padding) / packEnd(cell, expand, padding)`
  - `attributes`: 把 TreeModel 列号 ↔ CellRenderer 属性 绑定映射表（如 `Column 0 → text`、`Column 1 → foreground`）
  - `setSortColumnId(id) / setSortIndicator(visible, order)`、`clicked()`（触发 TreeView 排序）
  - `cellGetPosition / cellGetSize` 几何计算占位

### 29.3 TreeSelection — TreeView 选择模型
- **优先级**: 中
- **GTK 对应**: GtkTreeSelection（关联到一个 GtkTreeView）
- **文件**: `src/widget/tree_selection.zig`（也可内联进 tree_view.zig，但为模块化单独新建）
- **字段**:
  - `mode: enum(u2) { none, single, browse, multiple }`（GTK4 GtkSelectionMode）
  - `owner: ?*anyopaque`（类型擦除指向 TreeView）
  - `selected_nodes: std.AutoHashMap(*Node, void)`（多选模式下的节点集合）
  - `single_selected: ?*Node`（单选模式下的选中节点）
- **API**:
  - `init(mode) / setMode / getMode`
  - `selectNode(node) / unselectNode(node) / selectAll / unselectAll`
  - `isSelected(node) → bool`
  - `countSelectedRows() → u32`
  - **回调**: `onChanged(ud)`（每次选择变化触发）

### 29.4 WidgetPaintable — Widget → Paintable 屏幕快照
- **优先级**: 低
- **GTK 对应**: GtkWidgetPaintable（GdkPaintable 的实现）
- **文件**: `src/widget/widget_paintable.zig`
- **字段**: `widget: ?*Widget`（被快照的 Widget；可 null）、`width/height: i32`（不设置时用 widget 自身尺寸）、`user_data: ?*anyopaque`
- **API**:
  - `create(widget?) → *WidgetPaintable`
  - `asPaintable() → Paintable`：Paintable.snapshot → 调用 Widget.paintTree 绘制到 snapshot（如果 widget 存在；否则绘制占位图）
  - `setWidget(widget?)`、`getWidget() → ?*Widget`
  - `invalidateContents(bounds?)`（标记需要重绘；发送 Paintable.invalidate_contents 信号占位）
  - `invalidateSize()`（尺寸变化）

### 29.5 ScrollInfo — 滚动位置/增量信息
- **优先级**: 低
- **GTK 对应**: GtkScrollInfo（GTK4.4+ `GtkScrollInfo`；传递滚动事件的位置和增量）
- **文件**: `src/widget/scroll_info.zig`（或 widget/ 层辅助；单独新建）
- **字段**:
  - `enabled: bool`（是否已处理；true = 已消费）
  - `delta_x / delta_y: f32`（像素增量）
  - `cursor_x / cursor_y: f32`（事件发生时的 Widget 坐标）
  - `has_position: bool`（是否提供位置）
  - `is_stop: bool`（惯性滚动停止事件；GTK4.12+）
  - `unit: enum(u2) { pixel, logical, surface }`
- **API**:
  - `init() → ScrollInfo`、`setEnabled / isEnabled`
  - `setDeltas(dx, dy) → (dx, dy)`、`getDeltas() → (dx, dy)`
  - `setPosition(x, y)`、`getPosition() → (x, y, has_position: bool)`
  - `setStop / isStop`
  - `unit` 设置

### 29.6 root.zig 同步 + AST 全量验证
- **widget 层新增**: `editable_label`、`tree_view_column`、`tree_selection`、`widget_paintable`、`scroll_info`
- 全量 AST 验证 0 error

---

## 阶段三十：P31 Range 基类 & Scrollbar + 媒体管线（MediaStream / MediaFile）

> 目标：补全 GTK4 重要基础控件和媒体管线：
>   - GtkRange（Scale/Scrollbar 共享抽象：adjustment + fill_level + inverted + round_digits）
>   - GtkScrollbar（水平/垂直滚动条：stepper 按钮 + slider）
>   - GtkMediaStream + GtkMediaFile（GTK4 播放管线基础抽象）
> 注意：video.zig / gl_area.zig / emoji_chooser.zig 已存在且已导出，不重复。

### 30.1 Range — GtkRange（Scale / Scrollbar 共同基类）
- **优先级**: 中
- **GTK 对应**: GtkRange（GtkWidget，Scale 和 Scrollbar 的抽象父类）
- **文件**: `src/widget/range.zig`
- **职责**: 只提供抽象字段 + 通用 helper API；Scale/Scrollbar 用首字段 `range: Range` 组合，实现 @ptrCast 到 Range
- **字段**:
  - `base: Widget`（首字段）
  - `orientation: enum(u1) { horizontal, vertical }`
  - `adjustment: ?*Adjustment`（= GTK4 Adjustment：lower/upper/value/step/page increment）
  - `fill_level: f64`（= GTK4 :fill-level；显示进度填充）
  - `show_fill_level: bool`、`restrict_to_fill_level: bool`
  - `inverted: bool`（反向：正常是 min→max 左右/上下；inverted 则反过来）
  - `round_digits: i16`（= GtkScale :round-digits；-1 = 显示自动）
  - `slider_size_fixed: bool`（true = 固定滑块尺寸；false = 根据 page_size 调整）
  - `has_origin: bool`（轨道原点显示）、`flippable: bool`（RTL 翻转）
- **信号**（回调占位）：
  - `on_value_changed(ud, new_value: f64)`、`on_adjust_bounds(ud, value: f64)`、`on_change_value(ud, scroll_type, new_value) → bool`
- **API**:
  - `init(self, orientation, adjustment?)`
  - `setAdjustment / getAdjustment`
  - `setFillLevel / getFillLevel`
  - `setShowFillLevel / setRestrictToFillLevel`
  - `setInverted / getInverted`
  - `setRoundDigits / getRoundDigits`
  - `setRange(min, max)` → 更新 adjustment.lower/upper
  - `getValue / setValue(v)` → 通过 adjustment 触发 on_value_changed
- **Geometry helpers**：
  - `sliderRange(range_rect) → (slider_x, slider_y, slider_w, slider_h)`：按 adjustment.value 计算滑块位置
  - `valueFromPoint(range_rect, x, y) → f64`：反向根据坐标计算值

### 30.2 Scrollbar — GtkScrollbar（水平/垂直滚动条）
- **优先级**: 中
- **GTK 对应**: GtkScrollbar（继承 GtkRange）
- **文件**: `src/widget/scrollbar.zig`
- **字段**：
  - `range: Range`（首字段 → 可通过 @ptrCast 转回 Range）
  - `stepper_sensitive_up: bool`、`stepper_sensitive_down: bool`（上/下/左/右步进按钮是否可点）
  - `hover_stepper_a: bool`、`hover_stepper_b: bool`、`hover_slider: bool`（视觉高亮）
  - `stepper_width: f32 = 16`、`slider_min: f32 = 24`（最小滑块尺寸）
  - `on_scroll: ?*const fn (ud, scroll_type: ScrollType) void`
    - 其中 ScrollType = enum(u4) { none, jump, step_backward, step_forward, page_backward, page_forward, step_up, step_down, page_up, page_down, start, end }
- **几何**：
  - 水平：两端 stepper 按钮 + 中间轨道 + 滑块
  - 垂直：上下 stepper + 中间轨道 + 滑块
- **交互**：
  - 点击 stepper → step_backward/forward
  - 点击轨道空白（非滑块）→ page_backward/forward（GtkRange 行为）
  - 拖拽滑块 → 实时 setValue
  - 滚轮 → step
  - 按住 stepper 长按 → tick 中持续触发
- **VTable**：measure/layout/paint/on_event/destroy
- **API**: `create(orientation, adjustment?) → *Scrollbar`、`destroy`、`asRange() → *Range`

### 30.3 MediaStream — GtkMediaStream 播放流抽象
- **优先级**: 低
- **GTK 对应**: GtkMediaStream（GObject，不是 Widget；GtkVideo/GtkMediaFile 使用）
- **文件**: `src/widget/media_stream.zig`
- **字段**：
  - `playing: bool`、`ended: bool`、`seekable: bool`、`seeking: bool`（GTK4 :playing / :ended / :seekable / :seeking 属性）
  - `has_audio: bool`、`has_video: bool`
  - `loop: bool`（循环播放）
  - `position: i64`（单位：微秒 μs；GTK4 约定）
  - `duration: i64`（-1 = 未知）
  - `volume: f32 = 1.0`（0..1）
  - `muted: bool`
  - `error: ?[]const u8`（错误字符串占位）
  - `prepared: bool`（已准备好可播放）
  - `realized: bool`（已附着到渲染管线）
- **信号（回调）**：
  - `on_prepared(ud, stream: *MediaStream)`
  - `on_unprepared(ud)`
  - `on_state_changed(ud, playing)`
  - `on_position_changed(ud, position_us: i64)`
  - `on_season_needed*` → GTK4 `notify::duration`：`on_duration_changed(ud, duration_us: i64)`
  - `on_ended(ud)`、`on_error(ud, err_str: []const u8)`
- **API**:
  - `create(allocator) → *MediaStream`、`destroy`
  - `play / pause / stop`
  - `seek(position_us: i64) → bool`（seekable=false 时返回 false）
  - `getPosition → i64`、`getDuration → i64`
  - `setVolume / getVolume`、`setMuted / getMuted`、`setLoop / getLoop`
  - `isPrepared / isPlaying / isSeekable / hasAudio / hasVideo`
  - **实时时钟**：`update(delta_us: i64)`（每帧按 delta 累计 position；若 position ≥ duration 则 ended + loop 循环或 on_ended）
  - **实现辅助**：`setPrepared(bool)`（子类或调用方准备好后调用，触发 on_prepared）、`setDuration(i64)`、`setError([]const u8)`

### 30.4 MediaFile — GtkMediaFile 文件/URI 媒体流
- **优先级**: 低
- **GTK 对应**: GtkMediaFile（GtkMediaStream 子类）
- **文件**: `src/widget/media_file.zig`
- **字段**：
  - `stream: MediaStream`（首字段 → @ptrCast 到 MediaStream）
  - `file_path: ?[]const u8`（本地文件路径）
  - `uri: ?[]const u8`（URI 如 file:// 或 https://）
  - `owned_path: bool`、`owned_uri: bool`
  - `backend_state: enum(u3) { closed, open, loading, ready, failed }`（后端占位）
- **API**:
  - `create(allocator) → *MediaFile`、`destroy`
  - `asMediaStream() → *MediaStream`
  - `setFilename(path: []const u8) / clear()`：设置本地文件路径（dupe）；设置后若可解析，调用 stream.setPrepared(true) / setDuration(根据文件元信息占位)
  - `setUri(uri: []const u8) / clear()`：设置 URI
  - `getFilename → ?[]const u8`、`getUri → ?[]const u8`
  - 内部 helper：`tryOpen()` → 占位；读取文件是否存在 / URI 是否合法

### 30.5 root.zig 同步 + 全量 AST 验证
- **widget 层新增**: `range`、`scrollbar`、`media_stream`、`media_file`
- 全量 AST 验证 0 error

---

## 阶段三十一：P32 样式系统（WidgetPath / CssProvider / StyleContext）+ 模型层 Bitset + SelectionModel 补漏导出

> 目标：补齐 GTK4 样式系统基础三件套（WidgetPath/CssProvider/StyleContext），
> 同时补漏 model 层中已存在但未导出的 Bitset 和 SelectionModel（含 NoSelection/SingleSelection/MultiSelection）。

### 31.1 WidgetPath — GtkWidgetPath 样式路径
- **优先级**: 中
- **GTK 对应**: GtkWidgetPath（Widget 在树形结构中的路径描述，供样式匹配）
- **文件**: `src/widget/widget_path.zig`
- **结构**：
  - 元素数组：每个元素 = `{ type_name: []const u8, widget_id: ?[]const u8, object_name: ?[]const u8, classes: []const []const u8, region: ?[]const u8, state_flags: GtkStateFlags, sibling_index: u32, sibling_count: u32 }`
  - `GtkStateFlags = packed struct(u16)`：`normal / active / prelit / selected / insensitive / inconsistent / focused / backdrop / direction_ltr / direction_rtl / link / visited / checked / drop_active`（= GTK4 GtkStateFlags）
- **API**:
  - `create(allocator) / destroy`
  - `appendType(type_name) → u32`（末尾追加元素，返回索引）
  - `appendWidget(widget) → u32`（从 Widget 自动提取 type_name/id/class 等）
  - `insertAt(index, type_name) / removeAt(index)`
  - `iter() / len() → u32`
  - `getObjectTypeAt(idx) / setObjectTypeAt(idx)`
  - **ID 与类**：`addClass(idx, class_name) / hasClass(idx, class_name) / removeClass(idx, class_name) / listClasses(idx)`；`setObjectName(idx, name)`、`setWidgetId(idx, id)`
  - **Region**：`addRegion(idx, region, flags) / hasRegion(idx, region)`
  - **State**：`setState(idx, flags) / getState(idx) → StateFlags`
  - **辅助**：`toString() → []const u8`（可还原 CSS-like 选择器：`#id.type.class:state:nth-child(idx/count)`）
  - `isType(ref_path) → bool`（前缀匹配：本 path 是 ref_path 的特化类型则命中）

### 31.2 CssProvider — GtkCssProvider 样式规则加载器
- **优先级**: 中
- **GTK 对应**: GtkCssProvider（加载/解析/存储 GTK CSS 样式规则，供 StyleContext 查询）
- **文件**: `src/widget/css_provider.zig`
- **设计**：
  - 样式规则 = `Rule { selector: Selector, properties: PropertyMap }`
  - Selector（CSS 子集）：`{ type: ?[]const u8, id: ?[]const u8, classes: []const []const u8, state: StateFlags, any_child: bool, specificity: u32 }`
  - PropertyMap = 键值哈希表（k="color"/"background"/"font-size"/"margin"/...，v = GValue 联合：颜色/长度/百分比/字符串/枚举）
  - PropertyValue = 联合类型：`{ color: Color, length_px: f32, percentage: f32, string: []const u8, enum_: i32 }` + 标签
- **API**:
  - `create(allocator) / destroy`
  - `loadFromData(css_str: []const u8) → bool`：解析 CSS 字符串 → 拆分分号花括号（简化解析；真实 CSS 解析器可后续接入）
  - `loadFromFile(path) → bool`（调用 fs 读取）
  - `loadFromResource(resource_path) → bool`（别名）
  - `addRule(selector, PropertyMap)`（程序化添加）
  - `lookupRules(path: *WidgetPath) → []const Rule`：根据 widget_path 的 type/id/class/state 筛选出匹配规则，按 specificity 排序返回
  - `getDefault() → *CssProvider`（静态单例占位）
  - **错误处理**：`parse_errors: []const []const u8`（记录解析失败行），`getParseErrors() → []const []const u8`

### 31.3 StyleContext — GtkStyleContext 样式查询核心
- **优先级**: 中
- **GTK 对应**: GtkStyleContext（Widget 持有，基于 Path + Providers 出最终样式属性）
- **文件**: `src/widget/style_context.zig`
- **字段**:
  - `path: WidgetPath`（path 引用或所有权）
  - `providers: ArrayListUnmanaged(*CssProvider)`（优先级：数组前小后大；最后一个优先级最高）
  - `state: StateFlags`（当前 widget 状态）
  - `scale: f32 = 1.0`（DPI 缩放）
  - `direction: enum(u1) { ltr, rtl }`
  - `display: ?*const gdk_display.GdkDisplay = null`
  - **计算缓存**：`cached: ?PropertyMap`（state/providers/path 变化时失效）
- **API**:
  - `create(allocator, path: WidgetPath) / destroy`
  - `addProvider(css, priority: u32)`：按 priority 把 provider 插入正确位置（0=最低，800=应用，600=主题，400=设置）
  - `removeProvider(css)`
  - `setState(StateFlags) / setStateOne(flag, bool)`
  - `save() / restore()`：状态栈（push/pop 一个 state + path 副本）
  - `invalidate()`：清除缓存
  - **查询核心**：
    - `getProperty(name) → ?PropertyValue`：合并所有 provider 匹配规则，取特异性最高的
    - `getColor(default) → Color`：`lookup color/background-color/foreground-color/border-color` 等
    - `getFontSize() → f32`、`getMarginPx() → [4]f32（top/right/bottom/left）`、`getPaddingPx() → [4]f32`、`getBorderPx() → [4]f32`
    - `getBorderRadiusPx() → f32`、`getOpacity() → f32`
    - `getStr(property: []const u8, default: []const u8) → []const u8`
  - **绑定 Widget**：`bind(widget_ptr: ?*anyopaque)`、`render(snapshot_ptr, width, height)` → 把边框/背景/圆角/不透明度写入 snapshot（占位）
  - **内置 fallback 表**：若 lookup 失败，从内部默认样式表返回 Adwaita 默认值

### 31.4 模型层补漏导出（Bitset + SelectionModel）
- **model 命名空间新增**：
  - `pub const bitset = @import("model/bitset.zig")`（`Bitset`：GTK4 位集合，用于列表/网格视图选中集合）
  - `pub const selection_model = @import("model/selection_model.zig")`（包含 `SelectionModel / NoSelection / SingleSelection / MultiSelection`，GTK4 ColumnView 选择模型接口 + 三种实现）

### 31.5 root.zig 同步 + 全量 AST 验证
- **widget 层新增**: `widget_path`、`css_provider`、`style_context`
- **model 层新增 2 条**（补漏）: `bitset`、`selection_model`
- 全量 AST 验证 0 error

---

## 阶段三十二：P33 Printer / PrintJob / GraphicsOffload / ShortcutTrigger / ShortcutAction + 补漏 filter_list_bar + accessible 导出

> 目标：补齐打印管线核心（Printer + PrintJob）、GTK4.14 离屏容器（GraphicsOffload）、
> GTK4 ShortcutTrigger / ShortcutAction 细粒度对象，
> 同时补漏导出已存在但未导出的 filter_list_bar 和 accessibility/accessible 模块。

### 32.1 Printer — GtkPrinter 打印机对象
- **优先级**: 中（GTK4 GtkPrintUnixDialog 必需配套）
- **GTK 对应**: GtkPrinter（抽象打印机：名称、后端、能力、支持的纸张）
- **文件**: `src/widget/printer.zig`（或放到 widget/ 层；此实现放 widget/ 命名）
- **字段**：
  - `name: []const u8`（打印机显示名）
  - `backend: []const u8`（= "cups"/"file"/"lpr"）
  - `icon_name: []const u8`（图标名）
  - `is_virtual: bool`（文件/虚拟打印机）
  - `is_default: bool`（系统默认）
  - `is_active: bool`（当前可连接）
  - `is_paused: bool`
  - `accepts_pdf: bool`（= CUPS 大多数可直接给 PDF）、`accepts_ps: bool`
  - `supports_custom_paper_sizes: bool`、`hard_margins: bool`
  - `state_message: ?[]const u8`（状态文字，如 "offline"/"idle"/"printing 3/10"）
  - `location: []const u8`（位置，如 "2F 复印室）
  - `paper_sizes: ArrayListUnmanaged(PaperSize)`（已存在 model/print.zig PaperSize）
  - `media_gap: f32 = 0`
- **PaperSize 关联**：直接复用 `model/print.zig` 的 PaperSize 类型
- **API**:
  - `create(name, backend) / destroy`
  - 访问：`getName/getBackend/isDefault/isActive/isPaused/isVirtual`
  - `listPapers() → []PaperSize`
  - `supportsPaper(size) → bool`：在 paper_sizes 中查找
  - `getHardMargins(unit) → (top,right,bottom,left: f32`
  - **比较：`isSame(other: *Printer) → bool`（name+backend 相同）
  - 回调：`on_status_changed(ud, state_msg[]const u8)`
  - 全局 list：全局枚举：`static enumerateAll(allocator) → ArrayList(*Printer)`（PAL 可注入真实 CUPS 返回）
- **状态机**：Paused / active / default 访问修改后通知

### 32.2 PrintJob — GtkPrintJob 打印作业
- **优先级**: 中
- **GTK 对应**: GtkPrintJob（一次打印：Printer + PrintSettings + PageSetup + status
- **文件**: `src/widget/print_job.zig`
- **字段**：
  - `title: []const u8`（= 窗口标题）
  - `printer: ?*Printer`
  - `settings: *print.PrintSettings`（= GTK4 PrintSettings）
  - `page_setup: *print.PageSetup`
  - `status: enum(u3) { initial, pending, generating_data, sending_data, pending_issue, printing, finished, finished_aborted, finished_with_error }`（= GTK4 GtkPrintStatus）
  - `status_message: ?[]const u8`
  - `pages: ArrayListUnmanaged(i32)`（要打印的页码集合，如 1,2,5-10）
  - `n_copies: i32 = 1`
  - `collate: bool`
  - `reverse: bool`
  - `rotate: bool`
  - `scale: f32 = 1.0`
  - `num_pages: i32 = 0`（源文档总页数（>0时才有效）
  - `track_print_status: bool`
  - `surface: ?*anyopaque`（= cairo_surface_t* 或 vulkan texture）
  - `progress: f32`（0-1
  - `on_status_changed(ud, status)`、`on_print_fire(ud, error_msg[])`
- **API**：
  - `create(title, printer?, settings*, page_setup*) / destroy`
  - 访问：`getStatus / getTitle / getPrinter / getSettings / getPageSetup`
  - `setSurface(ptr)` / `getSurface() → ?*anyopaque`
  - 页码设置：`setPages(indices[]i32` / `setCopies(n)` / `setCollate(bool)` / `setReverse(bool)` / `setRotate(bool)` / `setScale(f32)`
  - 核心流程：
    - `send(allocator) → bool`：真实发送；先把状态从 initial → pending → generating_data → sending_data → printing → finished
    - 异步：`tick(delta_time_us: i64) → void` 推进进度，send 后调用 tick 推进状态机
    - `getProgress → f32`
  - `cancel()`：abort → finished_aborted
  - `error_set(error_msg)`：设置错误 → finished_with_error 并触发 on_status_changed

### 32.3 GraphicsOffload — GTK4.14 离屏渲染容器
- **优先级**: 低
- **GTK 对应**: `GtkGraphicsOffload`（容器，只有 1 child，子控件树渲染到离屏 GPU 纹理（黑盒）
- **文件**: `src/widget/graphics_offload.zig`
- **字段**：
  - `base: Widget`（首字段）
  - `child: ?*Widget = null`
  - `enabled: bool = true`（false = 退化为正常渲染）
  - `area: RectF`（离屏纹理缓存）
  - `auto: ?*anyopaque`（真实 GPU 句柄占位）
  - `needs_redraw: bool = true`（是否重新生成新纹理
- **enable`: 开启/关闭离屏（关闭时直接渲染）
- **API**:
  - `create(alloc* → *GraphicsOffload`
  - `getChild → ?*Widget / setChild(?*Widget)`
  - `setEnabled(bool) / getEnabled → bool`
  - `getArea → RectF`
  - **VTable**：
    - measure：传递 child measure，
    - layout：分配到全部分配子
    - paint：enabled → paint（true）enabled → 渲染 child 绘制到离屏，然后贴图
    - on_event：转发给 child
    - destroy：销毁 child

### 32.4 ShortcutTrigger + ShortcutAction（GTK4 快捷键细粒度对象
- **优先级**: 低（在 ShortcutController之上更底层触发器/动作抽象）
- **GTK 对应：GtkShortcutTrigger（= `GtkShortcutAction）
- **文件**: `src/widget/shortcut.zig」`（注意名 shortcut_label/shortcuts_window/shortcut_controller 已存在，这里 `shortcut_trigger_action.zig 单独命名清晰）→ 实际用 `shortcut_trigger.zig` 双用 2 文件**两个类型，`ShortcutTrigger`、`ShortcutAction` 类型放在 shortcut_trigger.zig 中）→ 实际做法：新建 shortcut_trigger.zig 文件内放**两个**
- **ShortcutTrigger （触发器）枚举 variant):
  - `NeverTrigger` 永不触发
  - `KeyvalTrigger(keyval, modifiers)` 键值（从pal键值+修饰符(mod mask
  - `MnemonicTrigger(keyval)` = _trigger.（`= 3 mnemonic 字符 Alt+key）
  - `AlternativeTrigger(a, b): （或或 两个）`
  - `Parse and 字段 Trigger` (底层 accel：a 和 **trigger 字符串解析）
  - **API**:
    - `never() → Trigger` / `keyval(keyval, mods) → Trigger` / `mnemonic(char) → Trigger` / `alternative(a, b) → Trigger`
    - `triggered(self, event*) → bool 是否匹配一个 trigger
    - `hash(self) → u32`（哈希，放入 HashMap 查找）
    - `equal(a, b) → bool`
    - `print(self, string: Trigger, allocator) → []const u8`（<ctrl>s = "<alt>x`
    - `parse(string) → ?Trigger`
- **ShortcutAction**:
  - `NoneAction`
  - `CallbackAction(callback:*fn(ud, widget, args[]const u8, args[] args → bool`
  - `SignalAction(target, signal_name)` 发出信号`
  - `ActivateAction 激活 action 激活 widget` (activate))
  - `MnemonicAction` （激活 GAction` group actionable name 字符串`
  - **API**:
    - `none` → Action`
    - `callback(function → Action → Action)` 回调
    - `activate() → Action`（发信号 action）
    - `named(name) → Action`（
    - `activatable: Actionable widget 动作名
    - `activate(self, widget*, simple_action_group, args) → bool` 真实执行激活
  - **Shortcut 整体封装**: `Shortcut{ trigger: Trigger, action: Action }`；ShortcutController 现在 `Shortcut

### 32.5 补漏导出 + root.zig 同步
- **widget 层新增**:
  - printer、print_job、graphics_offload、shortcut_trigger（含 ShortcutTrigger + ShortcutAction + Shortcut）
- **补漏导出**（已有源码未导出）：
  - `filter_list_bar` = @import("widget/filter_list_bar.zig");
  - `accessible`（accessibility/accessible.zig");
- 全量 AST 验证 0 error

---

## 阶段三十四：P34 SearchEntry / SearchBar GTK4 新增字段功能完整接入 + SearchBar Ctrl+F/ESC 行为完善

> 目标：P22/P24 阶段已经为 SearchEntry/SearchBar 补齐了 GTK4 新增字段（第 47 行注释 loading/search_delay_ms/key_capture_widget/search_mode_enabled）
> 以及 setLoading/isLoading / setSearchDelay/getSearchDelay / setKeyCaptureWidget/getKeyCaptureWidget 等访问器，
> 但功能逻辑尚未真正接入事件管线：
>   - delay_timer_active/delay_timer_start/delay_pending_text（SearchEntry 51-54 行）只定义没驱动
>   - key_capture_widget 只存了指针，未将未处理按键转发给捕获 widget
>   - SearchBar 缺少 GTK4 默认行为：Ctrl+F 切换搜索栏显示；ESC 分级清空/关闭
> 本阶段补全这些功能，确保字段"不止有 setter/getter，还实际生效"。

### 33.1 SearchEntry — search_delay 搜索延迟定时器接入
- **背景**：字段已定义（`delay_timer_active: bool` / `delay_timer_start: u64` / `delay_pending_text: []const u8`），
  访问器 `setSearchDelay(delay_ms)` / `getSearchDelay() → u32` 也已实现；但从未启动定时器。
- **接入方式**：
  1. 在 SearchEntry 的 VTable 中注册 `.tick = tickFn` 实现（利用 Widget.VTable.tick 每帧回调机制 + tickTree 递归）
  2. tickFn：当 `delay_timer_active=true` 时，取当前时间 `(nanoTimestamp()/1_000_000) ms`，若 `now - delay_timer_start >= search_delay_ms`
     → 置 `delay_timer_active=false`；若 `on_search` 非空则 `cb(self, delay_pending_text)`
  3. 触发条件：在 onEvent 的 `.text_input`/`.key` 分支，**不再直接调用 on_search**，改为：
     - 若 `search_delay_ms == 0` → 立即调用 on_search(text)（实时）
     - 否则 → `delay_pending_text = 当前 getText()`；`delay_timer_start = 当下 ms`；`delay_timer_active = true`
     - 若用户继续快速输入：更新 pending_text 和 start_time（重置计时）
  4. ESC/Clear 按钮清空文本：**立即**触发 on_search("")，不走 delay（交互体验需要）
- **内存安全**：delay_pending_text 不持有内存，直接指向 EntryBuffer（已存在），无需 dupe/free

### 33.2 SearchEntry — key_capture_widget 按键捕获转发
- **背景**：字段已定义 `key_capture_widget: ?*Widget = null`，访问器 `setKeyCaptureWidget` / `getKeyCaptureWidget` 已实现，但没转发。
- **GTK4 行为**：`gtk_search_entry_set_key_capture_widget(widget)` 设为搜索栏（SearchBar），让 SearchEntry 将导航/未处理按键回传给 SearchBar 处理（典型如 Ctrl+F 切换）。
- **接入方式**：在 onEvent 的 `.key` 分支**最顶部**插入：
  - 若 `self.key_capture_widget != null` 且当前是 key 事件 → 先 `dispatchEvent(key_capture_widget, event, ectx)`
  - 若返回 `EventResult.handled` → **直接 return .handled**；否则继续 SearchEntry 自身的按键处理（ESC 清空等）

### 33.3 SearchBar — Ctrl+F 切换显示
- **GTK4 行为**：默认 Ctrl+F 切换 `reveal_child`（打开搜索栏；已打开则不变）。SearchBar 自己能捕获此组合键。
- **接入方式**：在 SearchBar 的 onEvent **最顶部**（reveal_child 判断之前）插入：
  - if `event.* == .key` and event.key.state == .pressed and event.key.modifiers.ctrl and ascii.toUpper(event.key.key as u8) == 'F'
    → `setSearchMode(true)`（即 reveal_child=true，focus 搜索框），return `.handled`
- **注意**：这样即使 SearchBar 自身 `reveal_child=false` 且上级 dispatch 到它，也能被 Ctrl+F 唤起。

### 33.4 SearchBar — ESC 分级关闭（GTK4 默认交互）
- **当前错误行为**：只要 ESC 按下 → 立即 `setRevealChild(false) + setText("") + on_close`
- **GTK4 正确行为**（两步）：
  1. **若 search_entry.getText() 非空** → 按 ESC 先清空文本（`setText("")` + `on_search_changed(self, "")`），**不关闭**
  2. **若文本已空** → 再按 ESC 才真正关闭（`setRevealChild(false) + on_close`）
- **接入方式**：在 SearchBar onEvent 的 ESC 处理分支改写为上述两级判断。

### 33.5 全量 AST 验证 0 error
- search_entry.zig / search_bar.zig / root.zig AST 通过

---

## 阶段三十五（P35）：Widget.tick 动画链路打通（解决 Spinner 不转 / SearchEntry.search_delay 不触发 / 事件控制器定时器失效）

> 问题根因：`Widget.paintTree`（最常用的绘制入口）从未调用 `vtable.tick` / `tickControllers`，
> 而 `Widget.tickTree` 虽然实现但外部从未显式调用（App 主循环不知道 widget 树根），
> 导致所有依赖 `vtable.tick` / `EventController.tick` 的功能全是死代码：
>   - `Spinner.speed/angle/arc_length`（vtable.tick） → Spinner 永远不转
>   - `SearchEntry.search_delay` 定时器（vtable.tick） → 输入后 debounce 永远不超时
>   - `GestureLongPress` 长按定时器（EventController.tick） → 长按手势永远无法触发

### 34.0 根因确认 + 方案选择（零侵入优先）
- **方案 A（侵入）**：App 主循环 `run()` / `renderSubWindows()` 里显式调用 `root_widget.tickTree(delta_ms)`
  - ❌ 需要 Window 增加 `root_widget: ?*Widget` 字段 / 用户调用前要设置，破坏"裸窗口不依赖 widget 层"设计
- **方案 B（零侵入，选定）**：**在 `Widget.paintTree` 入口直接调用 tick + tickControllers**
  - paintTree 每次绘制都会走到，先推进动画再绘制，语义自然
  - 不需要知道 widget 树根 / 不需要改调用方 / 不需要加 root_widget 字段
  - delta_ms 计算方式：在 Widget 结构挂 `last_paint_ms: ?u64 = null`，每次 paintTree 进入时 `now - last` 得到帧间隔，首次为 0
- **补充**：`Widget.tickTree` 同时补加 `tickControllers` 调用（目前只调了 vtable.tick，漏掉了挂接的事件控制器）

### 34.1 Widget 结构新增 last_paint_ms 字段
- 在 Widget 字段列表追加：
  ```zig
  /// 上一次 paintTree 调用时间（ms，用于计算帧间隔，供 tick 推进动画 / 定时器）
  last_paint_ms: ?u64 = null,
  ```

### 34.2 Widget.paintTree 改造：入口串联 tick + tickControllers
- 在 `Widget.paintTree` 跳过可见性判断后，先：
  1. `now_ms = nanoTimestamp() / 1_000_000`（Unix ms 或自增 ms 均可）
  2. `delta_ms = last_paint_ms ? (now - last) clamp 0..500 : 0`（首帧不推进，最大 500ms 防后台切回跳变）
  3. `self.last_paint_ms = now_ms`
  4. `if (vtable.tick) |fn| fn(self, delta_ms)`
  5. `self.tickControllers(delta_ms)`
- **脏区裁剪提前**：若脏区判定完全跳过，返回前也要先写 `last_paint_ms = now_ms` + 调 tick（否则裁剪时动画暂停，恢复时会一次性跳跃）

### 34.3 Widget.tickTree 修复：补充 tickControllers 调用
- 当前 `tickTree` 只调 `vtable.tick`，漏掉了挂接的 EventController（GestureLongPress 等）。
- 在 `vtable.tick(self, delta_ms)` 之后追加 `self.tickControllers(delta_ms)`，与 paintTree 方案保持一致。

### 34.4 全量 AST 验证 0 error
- widget.zig / spinner.zig / search_entry.zig AST 通过（保证编译无语法错误）

---

## 阶段三十六（P36）：Assistant GTK4 对标补齐 + ShortcutAction 占位分支实装

> 本轮聚焦两个 GTK4 关键"活功能"补齐：
>   1. **Assistant（向导）** 修复 content 事件坐标错位 bug + 补齐 GtkAssistantPageType / setForwardPageFunc / 按钮按页面类型自适应（GTK4 的核心特性）
>   2. **ShortcutAction** 的 signal / activate / named 三个分支不再是 return true 的占位，真的触发对应动作；新增 SimpleActionGroup 简单 GAction 抽象

### 36.0 探查结论（本轮修改依据）
- **assistant.zig 第 469 行 content 事件坐标转换 bug**：
  - paint 时 content 位置 `content.rect.x = dx + 20; content.rect.y = content_y + 16;`
  - onEvent 里却写 `translateEvent(event, dx - 20, dy - 16)` → 符号完全相反，且 dy 应该是 content_y + 16
  - 结果：页面内 Entry/Button 等控件的点击/悬停完全错位
- **AssistantPage 缺少 GTK4 `page_type`**：GtkAssistantPageType（intro/content/progress/confirm/summary/custom）决定按钮显示和文案
- **缺少 `setForwardPageFunc`**：GTK4 允许自定义"下一页跳到哪页"，progress 完成后可直接跳到 confirm
- **ShortcutAction 三个分支占位**：signal/activate/named 只 return true，实际没做事

---

### 36.1 Assistant — 修复 content 事件坐标错位 Bug
**错误代码**（assistant.zig 第 469 行）：
```zig
const local_ev = translateEvent(event, dx - 20, dy - 16);  // ❌ 符号反、且没算 header_height
```
**正确代码**：
```zig
const content_y = dy + self.header_height;
const local_ev = translateEvent(event, -(dx + 20), -(content_y + 16));  // ✅ 反向偏移
```

---

### 36.2 Assistant — 新增 GtkAssistantPageType（GTK4 对标）
**新增 AssistantPageType 枚举**（GTK4: GtkAssistantPageType）：
```zig
pub const AssistantPageType = enum {
    content,   // 常规内容页（默认：有 Back/Next，最后一页 Apply=完成）
    intro,     // 介绍页（无 Back，Next=继续）
    progress,  // 进度页（Next 变灰、Apply 变灰；需 setPageComplete(true) 才激活）
    confirm,   // 确认页（Apply 文案=确认，再点击 on_apply）
    summary,   // 汇总页（Back/Next 隐藏，Apply 文案=关闭，点击 hide）
    custom,    // 自定义（所有按钮默认 hide，由上层控制）
};
```
- AssistantPage 结构新增 `page_type: AssistantPageType = .content`
- 新增 `setPageType(index, type)` / `getPageType(index)` API
- **`updateButtonStates()` 和按钮 paint 时根据当前 page_type 控制：**
  - intro：btn_back 禁用/隐藏，btn_next.label="继续"，btn_apply 隐藏
  - progress：btn_next.disabled = !complete，btn_apply 隐藏或变灰
  - confirm：btn_apply.label="确认"（应用）
  - summary：Back/Next 隐藏，btn_apply.label="关闭"（点击 hide + on_close 而非 on_apply）
  - custom：全部按钮隐藏，用户自定义显隐

---

### 36.3 Assistant — 新增 `setForwardPageFunc`（GTK4 对标）
**GTK4：`gtk_assistant_set_forward_page_func`** 允许自定义"当前页 → 下一页索引"的跳转逻辑（而非 current+1 顺序），典型场景：progress 完成后跳到 confirm/summary，而跳过中间草稿页。
- Assistant 结构新增：
  ```zig
  forward_page_func: ?*const fn (self: *const Assistant, current_page: usize) ?usize = null,
  forward_page_data: ?*anyopaque = null,
  ```
- 新增 `setForwardPageFunc(self, func, data)` API
- `nextPage(self)` 逻辑修改：
  - 若 `forward_page_func` 存在 → 调用，返回 `?usize`（非空则跳到该页，空则不前进）
  - 否则保持默认 `current + 1`

---

### 36.4 ShortcutAction — 三个占位分支实装（真正做事）

#### 36.4.1 `.activate` 分支（GTK4: GtkActivateAction）
> 真实语义：调用 Widget 的 "activate" 动作（Button 点击 / Entry 激活 focus / MenuItem 激活）
- 实现：若 `widget != null`：
  - widget `type_name == "button"` / `on_click` 存在 → 构造一次 mouse_button left pressed/released 事件派发，或直接调 Button.on_click 包装回调
  - 通用兜底：`widget.state.focused = true; widget.markDirty()`（聚焦控件作为"激活"）

#### 36.4.2 `.signal` 分支（GTK4: GtkSignalAction）
> 真实语义：向 Widget 发送 "signal_name" 信号（widget/signals 目前未实现信号系统，用回调名匹配）
- 简化实装：已知几个常用信号名做动作匹配：
  - "clicked" / "activate" → 同 activate 分支（按钮点击）
  - "grab-focus" → widget.focused = true
  - 其他 → 至少做 `widget.markDirty()` 并 return true（表示已处理）
- **不强制要求完整信号系统（框架无信号机制，符合"占位升级到有实际效果"原则）**

#### 36.4.3 `.named` 分支（GTK4: GtkNamedAction）
> 真实语义：按 action_name 查全局 GActionMap 并调用（app 级 action）
- 本轮新增**轻量 SimpleActionGroup 抽象**（放在 shortcut_trigger.zig 内）：
  ```zig
  pub const SimpleAction = struct {
      name: []const u8,
      callback: *const fn (user_data: ?*anyopaque, parameter: ?[]const u8) void,
      user_data: ?*anyopaque = null,
  };
  pub const SimpleActionGroup = struct {
      actions: std.StringHashMapUnmanaged(SimpleAction) = .empty,
      pub fn addAction(self: *SimpleActionGroup, allocator: Allocator, act: SimpleAction) !void { ... }
      pub fn activateAction(self: *SimpleActionGroup, name: []const u8, parameter: ?[]const u8) bool { ... }
  };
  ```
- **线程安全简化**：`activate_` 方法签名不改，新增 `SimpleActionGroup` 指针字段到 ShortcutAction.named（暂通过全局单例或把 `args_v` 当 action_group 指针传递来支持），命名为 .named 里加一个 group 字段：
  - 由于 union 成员的扩展性限制，简化方案：**在 `activate_` 的 `args_v: ?*anyopaque` 参数中允许传 `*SimpleActionGroup` 指针**，若存在则用 group.activateAction(name, args) 查 action，找不到则 fallback 到全局静态 map（可选），仍找不到则 return false。

---

### 36.5 全量 AST 验证 0 error
- assistant.zig / shortcut_trigger.zig / root.zig AST 通过

---

## 阶段三十七（P37）：Notebook（标签页）GTK4 完整补齐 + 两大严重 bug 修复

> 问题根因：当前 [notebook.zig](file:///opt/user/xiaoyu/zig_learing/zigui/src/widget/notebook.zig) 存在两个**影响功能的严重 bug**（标签页容器内容区完全空白），且 GTK4 GtkNotebook 关键 API 大量缺失：
>   1. **Bug A — paint 完全没画活动 tab 的 content widget**：paint() 函数只画标签栏 + 分隔线，没调 content.vtable.paint / paintTree → 内容区永远白屏
>   2. **Bug B — 鼠标/键盘事件完全没转发给活动 tab 的 content widget**：onEvent 只处理标签栏点击，子控件无法响应任何事件
>   3. **vtable.type_name = "tab_view"**（不符合 GTK 命名，应为 "notebook"）
>   4. **Tab 结构缺字段**：GTK4 GtkNotebook 需要 `reorderable`/`detachable`/`action_widget`/tab 可关闭按钮；Notebook 结构缺 `show_tabs`/`show_border`/`tab_pos`(top/bottom/left/right)

### 37.0 Bug 验证（已确认）
- **paint bug**：`notebook.zig` paint() 第 100-143 行 → 标签栏绘制后结束，**完全无代码绘制 `self.tabs[self.active].content`** → 内容区 100% 白屏
- **事件转发 bug**：onEvent 第 168-196 行 → 只处理标签点击，**无对 active tab.content 的事件派发**，内容区 Entry/Button 不会响应
- **measureText 与 measureTextStatic 字号不一致**：paint 用 `self.font_size`，onEvent 用固定 14.0 → 标签宽度测算不一致，点击错位

### 37.1 Notebook — GTK4 结构补齐
**新增 `NotebookTabPosition`（GTK4: GtkPositionType）**：
```zig
pub const NotebookTabPosition = enum { top, bottom, left, right };
```
**Notebook 结构新增 4 字段（默认值保证旧行为不变）：**
```zig
show_tabs: bool = true,           // GTK4: gtk_notebook_set_show_tabs
show_border: bool = true,         // GTK4: gtk_notebook_set_show_border
tab_pos: NotebookTabPosition = .top,  // GTK4: gtk_notebook_set_tab_pos
scrollable: bool = false,         // GTK4: gtk_notebook_set_scrollable (标签过多时不挤压，简化：默认 false 保持旧行为)
```
**Tab 结构新增 3 字段 + 标签关闭按钮回调（GTK4）：**
```zig
pub const Tab = struct {
    title: []const u8,
    content: ?*Widget = null,
    reorderable: bool = false,     // GTK4: gtk_notebook_set_tab_reorderable
    detachable: bool = false,      // GTK4: gtk_notebook_set_tab_detachable
    can_close: bool = false,       // 是否在标签右侧显示关闭按钮（×）
};
```
- 新增 `on_tab_close_requested: ?*const fn (self: *Notebook, index: usize) void = null`（用户点击 × 时触发）

### 37.2 Notebook — 9 个 GTK4 对标 API 新增
| 新增 API | GTK4 对标 | 说明 |
|---|---|---|
| `appendPage(title, content) !usize` | `gtk_notebook_append_page` | 返回新增页索引；addTab 转调它保持兼容 |
| `removePage(index) void` | `gtk_notebook_remove_page` | 移除以 index 为下标的页面，活动页自动前移/复位 |
| `getNPages() usize` | `gtk_notebook_get_n_pages` | 返回总页数 |
| `getNthPage(n) ?*Widget` | `gtk_notebook_get_nth_page` | 返回第 n 页 content widget |
| `pageNum(child) ?usize` | `gtk_notebook_page_num` | 反查 content widget 所在页（找不到返回 null） |
| `setShowTabs(bool) / getShowTabs() bool` | `gtk_notebook_set_show_tabs` | 显示/隐藏标签栏 |
| `setShowBorder(bool)` | `gtk_notebook_set_show_border` | 显示/隐藏边框 |
| `setTabPos(NotebookTabPosition)` | `gtk_notebook_set_tab_pos` | 切换标签位置（top/bottom/left/right，默认 top） |
| `setTabReorderable(index, bool) / setTabDetachable(index, bool) / setTabCanClose(index, bool)` | `gtk_notebook_set_tab_*` | 单页属性设置 |
- **vtable.type_name 改名**：`"tab_view"` → `"notebook"`（GTK 统一命名对齐）

### 37.3 Notebook — paint 修复活动内容绘制（Bug A）
在 paint() 中：
1. 若 `show_tabs = true` → 绘制标签栏（top/bottom/left/right 按 tab_pos 调整）
2. 按 `show_border = true` 画边框（1px）
3. **计算内容区矩形 `content_rect`**（排除标签栏 + 边框）
4. **取 `active_tab.content`**：
   - `content.rect = content_rect`（先绝对定位）
   - `content.vtable.paint(content, ctx)` 或更好 `content.paintTree(ctx)`（让子 widget 子树递归画）
5. **标签关闭按钮（×）**：每个 tab 的 `can_close=true` 在标签右侧画一个 16×16 × 号

### 37.4 Notebook — onEvent 事件修复（Bug B + measureText 字号修复）
在 onEvent 中：
1. **先把鼠标事件转成相对内容区坐标**，若落在内容区 → 取 active tab.content，有 on_event → 派发；handled 则返回
2. **标签栏点击**：改 `measureTextStatic` 改为 `measureTextStatic(text, self.font_size)`，字号与 paint 对齐，避免宽度不一致导致点击错位
3. **标签关闭按钮点击命中测试**：若 `can_close=true` 的 × 区域被命中 → 调 `on_tab_close_requested(self, i)`，return handled

### 37.5 全量 AST 验证 0 error
- notebook.zig / root.zig AST 通过

---

# P38：FileChooserNative 接入系统原生对话框（GTK4 `gtk_file_chooser_native_new` 行为）

## 38.1 背景与目标
FileChooserNative 之前直接 `fallback = true` 全走内部 fallback（且 fallback 中 open/select_folder 永远 cancel，无法真实选文件），与 GTK4 优先使用桌面原生对话框（XDG Portal / NSOpenPanel / IFileDialog）的理念差距较大。本次在 Linux 上先接入 2 个最常用的命令行原生文件对话框后端：`kdialog`（KDE）、`zenity`（GNOME/XFCE），按顺序尝试，失败再走原 fallback。

### 38.2 探测与尝试顺序（GTK4 对齐）
```
tryNativeFileDialog() ->
  1. 构建 cmd 列表：[kdialog 参数字典 → zenity 参数字典]
  2. 对每个命令：
     - 先用 `which <cmd>` 或直接 exec（忽略 ENOENT）检测可用性
     - 构造 args：action、title、directory、filter、multiple、current_name
     - std.ChildProcess.exec(.{ .argv = &args, .allocator = gpa, .max_output_bytes = 64*1024 })
     - term.Exited(0) → 去除末尾 \n 作为选中路径（多文件按 \0 或 \n split）
     - 调用 addSelected(path) → fireResponse(.accept)
     - 成功后返回，不再尝试下一命令
  3. 全部失败 → runFallback()（保留原逻辑）
```

### 38.3 4 种 Action 命令参数字典
| FileChooserAction | kdialog args | zenity args |
|---|---|---|
| open (single) | `--title T --getopenfilename DIR [FILTERS]` | `--file-selection --title=T --filename=DIR/ [--file-filter=FILTER]` |
| open (multiple) | `--title T --getopenfilename --multiple DIR [FILTERS]`（输出用 ` ` 分隔，含空格路径用 `""`） | `--file-selection --multiple --separator=\n --title=T --filename=DIR/` |
| save | `--title T --getsavefilename DIR/[CURNAME] [FILTERS]` | `--file-selection --save --confirm-overwrite --title=T --filename=DIR/CURNAME` |
| select_folder | `--title T --getexistingdirectory DIR` | `--file-selection --directory --title=T --filename=DIR/` |
| create_folder | `--title T --getsavefilename DIR/CURNAME`（无原生“创建文件夹”命令，回退 save 路径，让用户命名后由应用创建） | `--file-selection --save --title=T --filename=DIR/CURNAME` |

### 38.4 FileFilter 翻译
`FileFilter` 的 `patterns: []const []const u8` → kdialog/zenity 通配符过滤器字符串：
- kdialog：`Name (*.png *.jpg)|*.png *.jpg`（多个用 `\n` 拼接，多个 filter 追加 `\n`）
- zenity：`--file-filter='Name | *.png *.jpg'`（多次传递 `--file-filter`）

### 38.5 多文件选择输出解析
- **zenity**：`--separator='\n'` 指定换行分隔 → `splitLines()` 逐行 trim 空行
- **kdialog --multiple**：输出多个路径用空格分隔，若路径含空格用 `""` 包裹 → 简单 shell-like tokenize

### 38.6 错误兜底与非阻塞
- 所有 exec 用带 `timeout_ms`（120s）避免卡死用户桌面
- 用户点击 Cancel → ExitCode 非 0 → `fireResponse(.cancel)`
- 输出解析失败（0 字节）→ 当作 cancel，不影响其他命令尝试
- 若 allocator 在 `runNativeCmd` 中 OOM → catch → 下一个尝试

### 38.7 show() 流程修复
移除硬编码 `const fallback = true;`，改为：
```zig
if (self.tryRunNative(parent_window)) { // 尝试原生
  // 在回调里 fireResponse
} else {
  self.runFallback(parent_window);   // 全部失败回退
}
```

### 38.8 全量 AST 验证 0 error
- file_chooser_native.zig / root.zig AST 通过

---

# P39：GTK4 缺失组件 1:1 补全（手势 / 事件控制器 / 媒体控件 / 过滤器 / 清理）

## 39.1 探查结论
全面对比 GTK4 控件/模型/手势/事件控制器清单后，识别出以下缺失项：

| 类别 | 缺失项 | GTK4 对应 | 优先级 |
|------|--------|----------|--------|
| 手势 | GesturePan | GtkGesturePan | P0 |
| 手势 | GestureSwipe | GtkGestureSwipe | P0 |
| 手势 | GestureRotate | GtkGestureRotate | P0 |
| 事件控制器 | EventControllerKey | GtkEventControllerKey | P0 |
| 控件 | MediaControls | GtkMediaControls | P0 |
| 过滤器 | EveryFilter | GtkEveryFilter | P1 |
| 过滤器 | AnyFilter | GtkAnyFilter | P1 |
| 控件 | ListHeader | GtkListHeader | P2 |
| 清理 | scroll_bar.zig | 旧 ScrollBar（非 GTK4 风格） | P0 |

已确认已实现：StringList/TreeListModel/MapListModel/SliceListModel/SortListModel/FilterListModel/FlattenListModel/MultiSelection/SingleSelection/NoSelection/Bitset/SelectionModel/Builder/SignalListItemFactory/ListItem 等全部存在。

## 39.2 清理：删除 scroll_bar.zig
- `scroll_bar.zig`（`ScrollBar`，独立实现不继承 Range）是旧版，无外部引用
- `scrollbar.zig`（`Scrollbar`，继承 `Range`）是 GTK4 风格的正确实现
- 删除 `scroll_bar.zig`，从 root.zig 移除 `pub const scroll_bar` 导出

## 39.3 实现 GesturePan（GTK4: GtkGesturePan）
- 继承 `GestureDrag`，增加 `orientation`（horizontal/vertical）和方向判定
- `on_pan(self, direction, offset)` 回调
- GTK4: `gtk_gesture_pan_new(orientation)` / `gtk_gesture_pan_get_orientation`

## 39.4 实现 GestureSwipe（GTK4: GtkGestureSwipe）
- 继承 `GestureSingle`，记录按下时间和位置
- 释放时计算速度（px/ms），超过阈值触发 `on_swipe(self, vx, vy)`
- GTK4: `gtk_gesture_swipe_new()` / `on_swipe` 信号

## 39.5 实现 GestureRotate（GTK4: GtkGestureRotate）
- 继承 `GestureBase(n_points=2)`，跟踪双触点
- 计算初始角度和当前角度差，触发 `on_angle_changed(self, angle_delta, angle)`
- GTK4: `gtk_gesture_rotate_new()` / `on_rotate` 信号

## 39.6 实现 EventControllerKey（GTK4: GtkEventControllerKey）
- 继承 `EventController` 接口
- `on_key_pressed(controller, keyval, keycode, state)` / `on_key_released(controller, keyval, keycode, state)` / `on_im_update(controller)` 回调
- GTK4: `gtk_event_controller_key_new()`

## 39.7 实现 MediaControls（GTK4: GtkMediaControls）
- 继承 `Widget`，关联 `MediaStream`
- 绘制播放/暂停按钮、进度条（position/duration）、音量按钮、时间标签
- 播放状态联动：stream.playing -> 暂停按钮图标，stream.ended -> 重播
- GTK4: `gtk_media_controls_new()` / `gtk_media_controls_set_media_stream()`

## 39.8 实现 EveryFilter / AnyFilter 独立结构体（不合并到 MultiFilter）
- `EveryFilter`：持有子 filter 列表，`match(item)` 全部子 filter 返回 true 才 true
- `AnyFilter`：持有子 filter 列表，`match(item)` 任一子 filter 返回 true 即 true
- 各自独立的 `append(child)` / `remove(child)` API
- GTK4: `gtk_every_filter_new()` / `gtk_any_filter_new()`

## 39.9 实现 ListHeader（GTK4: GtkListHeader）
- 用于 ListView/GridView 分组头
- 持有 `child` Widget、`start` / `end` 索引区间
- GTK4: `gtk_list_header_new()` / `gtk_list_header_set_child()`

## 39.10 全量 AST 验证 0 error
- 所有新增/修改文件 AST 通过

---

# P40：控件 API 补全（字段→setter 补齐，GTK4 1:1 对齐）

## 40.1 探查结论
全面对比 10 个核心控件的 GTK4 API，发现大量"字段存在但无 setter 方法"问题：

| 控件 | 缺失方法数 | 关键缺失 |
|------|-----------|---------|
| label | 9 | setWrap/setXalign/setYalign/setJustify/setEllipsize/setLines/setMaxWidthChars |
| scale | 6 | setDrawValue/setValuePos/setHasOrigin/addMark/clearMarks/setDigits |
| stack | 6 | addNamed/addTitled/setVisibleChild/setVisibleChildName/setTransitionType/setTransitionDuration |
| spin_button | 4 | setDigits/setNumeric/setWrap/setSnapToTicks |
| progress_bar | 4 | setPulseStep/pulse/setShowText/setInverted |
| drop_down | 4 | getSelected/setExpression/setEnableSearch/setShowArrow |
| popover | 4 | setChild/setPointingTo/setAutohide/setHasArrow |
| button | 3 | setChild/getChild/setUseUnderline |
| entry | 4 | setInputHints/setActivatesDefault/setIconFromIconName/setIconTooltipText |
| scrolled_window | 2 | setKineticScrolling/setOverlayScrolling |

## 40.2 label.zig 补全
- `setWrap(bool)` / `setEllipsize(bool)` / `setLines(u32)` / `setMaxWidthChars(u32)`
- `setXalign(f32)` / `setYalign(f32)` - 0.0~1.0 对齐
- `setJustify(Justification)` - left/right/center/fill 枚举
- `setTrackVisitedLinks(bool)`
- `setWrapMode(WrapMode)` - word/char/word_char 枚举

## 40.3 scale.zig 补全
- `setDrawValue(bool)` / `setValuePos(PositionType)` / `setHasOrigin(bool)` / `setDigits(u32)`
- `addMark(value, position, label)` - 添加命名刻度标记
- `clearMarks()` - 清除所有标记
- 新增 `ScaleMark` struct 和 `marks: ArrayList` 字段

## 40.4 stack.zig 补全
- `addNamed(child, name) -> usize` / `addTitled(child, name, title) -> usize`
- `setVisibleChild(*Widget)` / `setVisibleChildName(name)`
- `setTransitionType(TransitionType)` / `setTransitionDuration(u32)`
- 新增 `name` / `title` 到 StackChild

## 40.5 spin_button/progress_bar/drop_down/popover/button 补全
- spin_button: `setDigits/setNumeric/setWrap/setSnapToTicks`
- progress_bar: `setPulseStep/pulse/setShowText/setInverted`
- drop_down: `getSelected/setExpression/setEnableSearch/setShowArrow`
- popover: `setChild/setPointingTo/setAutohide/setHasArrow`
- button: `setChild/getChild/setUseUnderline`

## 40.6 FilterChange/SorterChange 枚举
- `FilterChange = enum { differ, more_strict, less_strict }` (GTK4: GtkFilterChange)
- `SorterChange = enum { differ, inverted, less_strict, more_strict }` (GTK4: GtkSorterChange)

## 40.7 全量 AST 验证 0 error

---

# P41：剩余缺口补全（手势8/8 + 事件控制器6/6 + 无障碍Property + entry/scrolled_window）

## 41.1 补全 entry.zig
- `setInputHints(InputHints)` - 新增 `InputHint` packed struct(u16) + 4 个字段
- `setActivatesDefault(bool)` / `setIconFromIconName(?[]const u8)` / `setIconTooltipText(?[]const u8)`

## 41.2 补全 scrolled_window.zig
- `setKineticScrolling(bool)` / `setOverlayScrolling(bool)` - 新增 2 个字段

## 41.3 GestureStable（GTK4: GtkGestureStable）
- 按下后保持不动超过 `stability_threshold_ms` 触发 `on_stable(x, y)`
- 移动超过 `move_tolerance` 或释放时未稳定 -> `on_unstable`
- 使用 `tick` 回调每帧检查超时

## 41.4 EventControllerPad（GTK4: GtkEventControllerPad）
- 游戏手柄事件：`on_button_pressed(button, axis_value)` / `on_button_released(button)` / `on_axis(axis, value)`
- 通过鼠标侧键 + 滚轮模拟手柄输入

## 41.5 EventControllerLegacy（GTK4: GtkEventControllerLegacy）
- 遗留事件透传：`on_event(target, event) -> EventResult`
- 将所有事件原样转发给回调

## 41.6 AccessibleProperty 枚举（GTK4: GtkAccessibleProperty）
- 26 个属性键：autocomplete/description/has_popup/key_shortcuts/label/level/modal/multi_line/...
- 新增 `AccessibleTristate` 三态枚举（false/true/mixed/undefined）

## 41.7 全量 AST 验证 0 error

