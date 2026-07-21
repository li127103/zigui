# zigui API 参考

> 跨平台 GPU 加速 GUI 框架 · Zig 0.16 · macOS (Cocoa + Metal) 已实现, Windows / Linux 规划中
>
> 本文档覆盖 `src/root.zig` 导出的全部公共模块。所有坐标单位为**设备像素** (device pixels, Retina 下 = points × backingScaleFactor), 原点左上角。

## 目录

- [模块总览](#模块总览)
- [快速开始](#快速开始)
- [app — 应用主循环](#app--应用主循环)
- [math — 几何与颜色](#math--几何与颜色)
- [pal — 平台抽象层](#pal--平台抽象层)
- [render2d — 2D 渲染器](#render2d--2d-渲染器)
- [dirty — 脏矩形](#dirty--脏矩形)
- [text — 文本引擎](#text--文本引擎)
- [image — PNG 解码](#image--png-解码)
- [widget — 控件系统](#widget--控件系统)
- [内置控件](#内置控件)
- [layout — 布局引擎](#layout--布局引擎)
- [theme — 主题](#theme--主题)
- [animation — 动画](#animation--动画)
- [input — 快捷键与手势](#input--快捷键与手势)
- [gpu — Metal 设备](#gpu--metal-设备)
- [构建与测试](#构建与测试)

---

## 模块总览

| 导入路径 | 模块 | 职责 |
| --- | --- | --- |
| `zigui.app` | App | 窗口 + 渲染 + 事件主循环, 一站式入口 |
| `zigui.math` | math | Rect / Size / Point / EdgeInsets / Mat3x2 / Color |
| `zigui.pal` | pal | 统一事件、窗口描述、EventQueue、光标 |
| `zigui.render2d` / `zigui.renderer` | Renderer2D | 矩形 / 圆角 / 阴影 / 文本 / 图像绘制, 批次提交 |
| `zigui.dirty` | DirtyRegion | 脏矩形收集、合并、裁剪 |
| `zigui.text` | CtFont / GlyphAtlas / TextLayout | CoreText 整形 + glyph atlas + 段落排版 |
| `zigui.image` | png | 纯 Zig PNG 解码器 (RGBA8 输出) |
| `zigui.widget` | Widget | 控件基类、控件树、事件分发、脏标记 |
| `zigui.label` … `zigui.table` | 各控件 | 16 个内置控件 |
| `zigui.layout` | LayoutNode | Flexbox 风格约束布局 |
| `zigui.theme` | Theme | 内置亮 / 暗主题 |
| `zigui.animation` | Tween / AnimationController | 缓动、补间、弹簧 |
| `zigui.input` | ShortcutMap | 快捷键绑定表 |
| `zigui.gesture` | Tap / Drag / Pinch | 触摸手势识别器 |
| `zigui.metal` | MetalDevice | Metal 底层设备 (一般经 App/Renderer 间接使用) |

---

## 快速开始

```zig
const zigui = @import("zigui");
const App = zigui.app.App;

pub fn main() !void {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa.deinit();

    var app = try App.init(gpa.allocator(), .{
        .title = "hello zigui",
        .width = 800,
        .height = 600,
        .continuous = true, // false = 按需重绘 (事件驱动)
    });
    defer app.deinit();

    try app.run(&draw);
}

fn draw(app: *App) void {
    const r = app.getRenderer();
    r.fillRect(.{ .x = 0, .y = 0, .width = 800, .height = 600 }, zigui.math.Color.hex(0x1E1E2EFF)) catch {};
    r.fillRect(.{ .x = 100, .y = 100, .width = 200, .height = 80 }, zigui.math.Color.hex(0x3B82F6FF)) catch {};

    // 每帧输入状态 (帧末自动清除)
    if (app.mouse_clicked) { /* app.mouse_x / app.mouse_y 为点击坐标 */ }
    for (app.typedCodepoints()) |cp| { _ = cp; } // IME 提交的码点
}
```

`App.run` 每帧流程: 采集事件 → 更新输入状态 → `beginFrame[Dirty]` → 调用 `draw_fn` → `submit` → 清除帧状态 → `endFrame`。

---

## app — 应用主循环

```zig
pub const AppConfig = struct {
    title: []const u8 = "zigui app",
    width: u32 = 800,
    height: u32 = 600,
    continuous: bool = true, // false: 仅在输入事件或 invalidate() 后重绘
};

pub const App = struct {
    // 每帧输入状态 (draw_fn 内读取, 帧末自动清零)
    mouse_x: f32, mouse_y: f32,       // 光标位置 (设备像素)
    mouse_down: bool,                  // 左键按住 (level)
    mouse_clicked: bool,               // 左键本帧按下 (edge)
    scroll_delta: f32,                 // 垂直滚轮累计
    key_hit: ?pal.KeyCode,             // 本帧按下的键
    file_drop: ?pal.event.FileDrop,    // 本帧拖放的文件
    // typed_cps / typed_cp_count 经 typedCodepoints() 访问

    pub fn init(allocator: std.mem.Allocator, config: AppConfig) !*App;
    pub fn deinit(self: *App) void;
    pub fn run(self: *App, draw_fn: *const fn (app: *App) void) !void;

    pub fn typedCodepoints(self: *App) []const u21;      // 本帧 IME/键盘输入的码点
    pub fn getMarkedText(self: *App, buf: []u8) usize;   // IME 组字中的拼音等
    pub fn touchEvents(self: *App) []const pal.event.Touch;

    pub fn invalidate(self: *App) void;                  // 标记整帧需要重绘
    pub fn invalidateRect(self: *App, rect: math.Rect(f32)) void; // 局部脏区
    pub fn getDirtyRegion(self: *App) *dirty_mod.DirtyRegion;

    pub fn getRenderer(self: *App) *renderer2d.Renderer2D;
    pub fn getFramebufferSize(self: *App) math.Size(u32);
    pub fn getGlyphAtlas(self: *App) *atlas_mod.GlyphAtlas;
    pub fn getMetalDevice(self: *App) *metal.MetalDevice;
};
```

按需重绘 (`continuous = false`) 时, 所有输入事件自动触发 `invalidate()`; 无事件且无脏区的帧直接跳过 GPU 提交。脏区存在时使用离屏累积画布 + scissor 局部重绘, 再整帧 blit 到 drawable。

---

## math — 几何与颜色

```zig
pub fn Rect(comptime T: type) type;   // { x, y, width, height: T }
//   containsPoint(px, py) bool
//   intersects(other) bool
//   intersection(other) ?Self
//   union_(other) Self

pub fn Size(comptime T: type) type;   // { width, height: T }
pub fn Point(comptime T: type) type;  // { x, y: T }

pub const EdgeInsets = struct {       // left, top, right, bottom: f32
    pub fn all(v: f32) EdgeInsets;
    pub fn symmetric(h: f32, v: f32) EdgeInsets;
    pub fn horizontal(self) f32;
    pub fn vertical(self) f32;
};

pub const Mat3x2 = struct {           // 3x2 仿射矩阵
    pub fn translate(x: f32, y: f32) Mat3x2;
    pub fn scale(sx: f32, sy: f32) Mat3x2;
    pub fn rotate(radians: f32) Mat3x2;
    pub fn multiply(self, other) Mat3x2;
    pub fn transformPoint(self, p: [2]f32) [2]f32;
    pub fn invert(self) ?Mat3x2;
};

pub const Color = struct {            // r, g, b, a: u8
    pub fn rgba(r: u8, g: u8, b: u8, a: u8) Color;
    pub fn hex(v: u32) Color;         // 0xRRGGBBAA
    pub fn toPremultiplied(self) [4]f32;
};
```

---

## pal — 平台抽象层

### Event

```zig
pub const Event = union(enum) {
    resize: struct { width: u32, height: u32 },
    move: struct { x: i32, y: i32 },
    close_requested: struct { window_id: u32 },
    focus_change: struct { focused: bool },
    scale_change: struct { new_scale: f32 },
    minimize: void,
    maximize: struct { maximized: bool },

    mouse_move: struct { x: i32, y: i32 },
    mouse_button: struct { button: MouseButton, state: ButtonState, x: i32, y: i32 },
    scroll: struct { axis: ScrollAxis, delta: f32 },
    mouse_enter: void,
    mouse_leave: void,

    key: struct { state: ButtonState, key: KeyCode, modifiers: Modifiers },
    text_input: struct { codepoint: u21 },

    ime_composition: struct { cursor_start: u32, cursor_end: u32 },
    ime_commit: void,
    ime_cancel: void,

    touch: Touch,        // { id: u32, phase: TouchPhase, x: f32, y: f32 }
    file_drop: FileDrop, // 见下
};

pub const MouseButton = enum { left, right, middle, extra1, extra2 };
pub const ButtonState = enum { pressed, released };
pub const ScrollAxis = enum { vertical, horizontal };
pub const TouchPhase = enum { began, moved, ended, cancelled };
```

### FileDrop

路径内联存储 (1024 字节), 事件队列中零堆分配。

```zig
pub const FileDrop = struct {
    x: i32, y: i32,             // 落点 (设备像素)
    path: [1024]u8,
    path_len: u32,
    pub fn pathSlice(self: *const FileDrop) []const u8; // UTF-8 路径
};
```

### Modifiers / KeyCode

```zig
pub const Modifiers = packed struct(u8) {
    shift, ctrl, alt, super_key, caps_lock, num_lock: bool,
    pub fn eql(self, other: Modifiers) bool; // 按位整体比较
};

pub const KeyCode = enum(u16) { a..z, @"0"..@"9", f1..f15, escape, tab, enter, ... };
```

### EventQueue

```zig
pub const EventQueue = struct {
    pub fn push(self: *EventQueue, allocator: std.mem.Allocator, ev: Event) !void;
    pub fn drain(self: *EventQueue) []Event; // 取走全部事件并清零
    pub fn deinit(self: *EventQueue, allocator: std.mem.Allocator) void;
};
```

> **实现要点**: `push` 写入 `count` 槽位复用已 drain 的容量, 仅 `count == items.len` 时扩容。直接 `append` 会使事件落在 `items.len` (只增不减) 之外, 首次 drain 后全部丢失 —— 历史物理点击失效的根因, 有回归测试保护。

---

## render2d — 2D 渲染器

```zig
pub const Renderer2D = struct {
    pub fn init(allocator: std.mem.Allocator, device: *metal.MetalDevice) Renderer2D;
    pub fn deinit(self: *Renderer2D) void;
    pub fn beginFrame(self: *Renderer2D) void; // 清空批次 (App.run 已调用)

    // ── 几何 ──
    pub fn fillRect(self, rect: math.Rect(f32), color: math.Color) !void;
    pub fn fillRoundedRect(self, rect: math.Rect(f32), radius: f32, color: math.Color) !void;

    // ── 阴影 ──
    pub const ShadowStyle = struct {
        color: math.Color = math.Color.hex(0x00000055),
        blur_radius: f32 = 12,
        offset_x: f32 = 0,
        offset_y: f32 = 4,
        spread: f32 = 0,
    };
    pub fn drawShadow(self, rect: math.Rect(f32), radius: f32, style: ShadowStyle) !void;

    // ── 文本 ──
    pub fn drawText(self, tl: *const text_layout.TextLayout, origin_x: f32, origin_y: f32, color: math.Color) !void;
    pub fn drawTextClipped(self, tl: *const TextLayout, origin_x: f32, origin_y: f32, color: math.Color, clip: math.Rect(f32)) !void;

    // ── 图像 ──
    pub fn drawImage(self, texture: *anyopaque, dst: math.Rect(f32), tint: math.Color) !void;
    pub fn drawImageRect(self, texture: *anyopaque, dst: math.Rect(f32), src: math.Rect(f32), tint: math.Color) !void;
    //   src 为归一化 UV (0..1); tint 为直通色 (shader 内自行预乘)
    pub fn createTextureFromPng(self, png_data: []const u8) !*anyopaque; // 解码 + 上传 RGBA 纹理

    pub fn submit(self: *Renderer2D) void; // 按 solid → text → image 三管线分批提交 GPU
};
```

绘制调用仅累积顶点, `submit` 时统一上传。同一纹理的连续 image 调用自动合并为单个 draw。文本顶点按 128 个/块分片上传, 避免共享顶点缓冲在 GPU 执行期间被覆盖。

---

## dirty — 脏矩形

```zig
pub const DirtyRegion = struct {
    pub fn init(allocator: std.mem.Allocator) DirtyRegion;
    pub fn deinit(self: *DirtyRegion) void;
    pub fn add(self: *DirtyRegion, rect: math.Rect(f32)) !void; // 相交就地合并; 超过 32 个折叠为单矩形
    pub fn clear(self: *DirtyRegion) void;
    pub fn isEmpty(self: *const DirtyRegion) bool;
    pub fn count(self: *const DirtyRegion) usize;
    pub fn collapse(self: *DirtyRegion) void;      // 折叠为外包矩形
    pub fn bounds(self: *const DirtyRegion) ?math.Rect(f32);
    pub fn intersects(self: *const DirtyRegion, rect: math.Rect(f32)) bool;
};
```

控件 `markDirty()` 会沿父链找到根控件的 `dirty_tracker` 并记录绝对脏区; `paintTree` 依据 `PaintContext.dirty` 跳过与脏区不相交的子树。

---

## text — 文本引擎

### CtFont (CoreText 封装)

```zig
pub const CtFont = struct {
    pub fn create(family: ?[]const u8, size: f32, weight: u16) !CtFont; // family=null → 系统字体
    pub fn destroy(self: *CtFont) void;
    pub fn getMetrics(self: *const CtFont) FontMetrics; // ascent/descent/leading/line_height
    pub fn shapeText(self: *const CtFont, text: []const u8, out_glyphs: []ShapedGlyph) usize;
    pub fn measureText(self: *const CtFont, text: []const u8) f32; // 像素宽度 (光标定位用)
    pub fn rasterizeGlyph(self: *const CtFont, glyph_id: u32, buf: []u8) ?GlyphBitmapMetrics;
    pub fn native(self: *const CtFont) *anyopaque;
    pub fn fontId(self: *const CtFont) u64; // CFHash, 稳定缓存键
};
```

> **CJK 注意**: `shapeText` 返回的每个 `ShapedGlyph` 携带 `run_font` (该 glyph 实际所属的回退字体, 如中文走 PingFang) 与 `font_id`。光栅化必须用 `run_font` 而非主字体, 否则 glyph ID 错位导致乱码。调用方负责逐个 `releaseNativeFont(sg.run_font)`。

### GlyphAtlas

```zig
pub const GlyphAtlas = struct {
    pub fn init(allocator: std.mem.Allocator, width: u32, height: u32) !GlyphAtlas; // 典型 2048x2048
    pub fn deinit(self: *GlyphAtlas) void;
    pub fn createTexture(self, device: *metal.MetalDevice) !void;
    pub fn getOrRasterize(self, device, native_font, font_id: u64, weight: u16, glyph_id: u32, size: f32) !AtlasEntry;
    pub fn flush(self, device: *metal.MetalDevice) void; // 上传脏区到 GPU 纹理
};
```

缓存键为 `(font_id, size, weight, glyph_id)` —— 必须含 size 与 weight, 否则同 glyph_id 跨字号串扰。

### TextLayout

```zig
pub const LayoutOptions = struct {
    font: *const coretext.CtFont,
    font_size: f32,
    max_width: ?f32 = null,        // null = 单行
    max_lines: ?u32 = null,
    line_height_scale: f32 = 1.2,
    text_align: TextAlign = .left, // left / center / right
    wrap: TextWrap = .word,        // none / word / char
};

pub const TextLayout = struct {
    pub fn init(allocator: std.mem.Allocator) TextLayout;
    pub fn deinit(self: *TextLayout) void;
    pub fn layout(allocator, glyph_atlas: *GlyphAtlas, device: *anyopaque, text: []const u8, opts: LayoutOptions) !TextLayout;
    pub fn measure(font: *const coretext.CtFont, text: []const u8) f32;
    // lines: []TextLine, 每行 glyphs: []PlacedGlyph { x, y, u0,v0,u1,v1, size... }
};
```

---

## image — PNG 解码

纯 Zig 实现, 支持灰度 / 灰度+Alpha / RGB / RGBA (8-bit, 非隔行), zlib 经 `std.compress.flate` 解压, 全部 5 种行滤波 (None/Sub/Up/Average/Paeth)。

```zig
pub const Image = struct {
    width: u32,
    height: u32,
    pixels: []u8, // RGBA8, 行主序
    pub fn deinit(self: *Image, allocator: std.mem.Allocator) void;
};

pub const DecodeError = error{ InvalidSignature, Truncated, UnsupportedFormat, InvalidChunkOrder, CorruptedData, OutOfMemory };

pub fn decode(allocator: std.mem.Allocator, data: []const u8) DecodeError!Image;
```

配合渲染器: `const tex = try renderer.createTextureFromPng(png_bytes);` 一步完成解码 + GPU 上传。

---

## widget — 控件系统

### Widget 基类

```zig
pub const Widget = struct {
    vtable: *const VTable,
    id: WidgetId,
    parent: ?*Widget,
    children: std.ArrayListUnmanaged(*Widget),
    rect: math.Rect(f32),              // 相对父控件
    state: WidgetState,                // hovered/focused/pressed/disabled/visible/dirty/layout_dirty
    layout_style: layout_mod.LayoutStyle,
    dirty_tracker: ?*dirty_mod.DirtyRegion, // 仅根控件设置

    pub const VTable = struct {
        type_name: []const u8,
        measure: *const fn (self, ctx: *PaintContext, constraints: Constraints) math.Size(f32),
        paint: *const fn (self, ctx: *PaintContext) void,
        on_event: ?*const fn (self, event: *const pal.Event, ectx: *EventContext) EventResult,
        focusable: bool = false,
        destroy: *const fn (self, allocator) void,
    };

    // 树操作
    pub fn addChild(self, allocator, child: *Widget) !void;
    pub fn removeChild(self, allocator, child: *Widget) void;

    // 脏标记
    pub fn markDirty(self) void;        // 记录绝对脏区到根 tracker + 向上传播 dirty 标志
    pub fn markLayoutDirty(self) void;
    pub fn absoluteRect(self) math.Rect(f32); // 沿父链累加 → 窗口坐标

    // 布局 / 绘制
    pub fn performLayout(self, ctx: *PaintContext, available: Constraints) void;
    pub fn paintTree(self, ctx: *PaintContext) void; // 脏矩形裁剪 + 递归子项

    // 事件
    pub fn hitTest(self, x: f32, y: f32) ?*Widget; // 入参为父级坐标空间; 返回最深层命中控件
    pub fn containsPoint(self, x: f32, y: f32) bool;
    pub fn dispatchEvent(self, event: *const pal.Event, ectx: *EventContext) EventResult; // 命中 → 目标处理 → 冒泡
    pub fn nextFocusable(self) ?*Widget; // Tab 顺序
};

pub const PaintContext = struct {
    renderer: *renderer2d.Renderer2D,
    theme: *const theme_mod.Theme,
    allocator: std.mem.Allocator,
    offset_x: f32 = 0, offset_y: f32 = 0,          // 递归传递的绝对偏移
    dirty: ?*const dirty_mod.DirtyRegion = null,    // 非空时裁剪子树
};

pub const EventResult = enum { handled, ignored };
```

`hitTest` 约定: 入参坐标位于**父级坐标空间** (对根控件即窗口坐标), 内部先减去 `self.rect` 偏移转换到局部坐标。事件分发采用目标处理 → 父级冒泡模型。

---

## 内置控件

所有控件经 `create(allocator, opts)` 创建 (堆分配, 返回 `!*T`), 内部持有 `base: Widget`, 通过 `&ctl.base` 挂入控件树。`opts` 均为带默认值的匿名 struct。

| 控件 | 关键 opts 字段 | 关键方法 |
| --- | --- | --- |
| `Label` | `text`, `font_size=14`, `font_weight=400`, `color` | `setText(text)` |
| `Button` | `label_text`, `font_size=14`, `on_click: ?*const fn(*Button)`, `bg_color` | — |
| `Container` | `bg_color: ?Color`, `corner_radius=0`, `border_color: ?Color` | 纯布局/装饰容器 |
| `Slider` | `value=0`, `min=0`, `max=1`, `on_change` | `setValue(v)` |
| `TextInput` | `placeholder`, `font_size=14`, `on_change: ?*const fn(*TextInput, []const u8)` | `getText()`, `setText(text)` |
| `TextArea` | 同 TextInput (多行) | `getText()`, `setText(text)` |
| `ComboBox` | `font_size=14`, `on_change: ?*const fn(*ComboBox, usize)` | `addItem(item)`, `setSelected(i)`, `getSelectedText()` |
| `ListView` | `item_height=40`, `on_select: ?*const fn(*ListView, usize)` | `addItem(item)` |
| `TabView` | `font_size=14`, `on_change: ?*const fn(*TabView, usize)` | `addTab(title, ?*Widget)`, `setActive(i)` |
| `Dialog` | `title`, `message`, `on_close` | 模态对话框 |
| `Tooltip` | `text` | 悬浮提示 |
| `Menu` | `font_size=13`, `on_close` | `addItem(MenuItem)`, `addSeparator()` |
| `SplitView` | `orientation: .horizontal/.vertical`, `split_ratio=0.5`, `divider_size=8` | `setPanes(a, b)`, `setRatio(r)` |
| `TreeView` | `row_height=32`, `indent=20`, `font_size=14` | `addRoot(label) !*Node`, `addChild(parent, label) !*Node` |
| `Table` | `header_height=40`, `row_height=36`, `font_size=14` | `addColumn(title, width)`, `addRow(cells)` |

示例:

```zig
var btn = try zigui.button.Button.create(alloc, "保存", .{ .on_click = onSave });
btn.base.rect = .{ .x = 20, .y = 20, .width = 120, .height = 32 };
try root.addChild(alloc, &btn.base);
```

---

## layout — 布局引擎

```zig
pub const Constraints = struct {
    min_width, min_height, max_width, max_height: f32,
    pub fn constrain(self, size: math.Size(f32)) math.Size(f32);
    pub fn tight(w: f32, h: f32) Constraints;
    pub fn loose(w: f32, h: f32) Constraints;
    pub fn unlimited() Constraints;
    pub fn deflate(self, pad: math.EdgeInsets) Constraints;
    pub fn inflate(self, pad: math.EdgeInsets) Constraints;
};

pub const Dimension = union(enum) { auto, fixed: f32, percent: f32, ... };
//   pub fn resolve(self, parent_size: f32) ?f32;

pub const FlexDirection = enum { row, row_reverse, column, column_reverse };
pub const FlexWrap = enum { nowrap, wrap, wrap_reverse };
pub const JustifyContent = enum { start, center, end, space_between, space_around, space_evenly };
pub const AlignItems = enum { start, center, end, stretch, baseline };
pub const Position = enum { relative, absolute };

pub const LayoutStyle = struct { width, height: Dimension, margin, padding: EdgeInsets, direction, gap, flex_grow, ... };

pub const LayoutNode = struct {
    pub fn init(allocator) LayoutNode;
    pub fn deinit(self) void;
    pub fn addChild(self, child: *LayoutNode) !void;
    pub fn computeLayout(self, available: Constraints) void;
};

pub fn layout(root: *LayoutNode, constraints: Constraints) void; // 便捷入口
```

控件树的 `Widget.performLayout` 使用简化的垂直/水平堆叠 + `flex_grow` 弹性分配; 独立 `LayoutNode` 提供完整 Flexbox 语义。

---

## theme — 主题

```zig
pub const Theme = struct {
    name: []const u8,
    colors: ColorPalette,   // primary / background / surface / text_primary / border / shadow / selection 等 22 色
    fonts: FontPalette,     // family, size_body=14, size_small=12, size_large=16, size_title=20
    metrics: MetricsPalette, // border_radius_sm/md/lg, spacing_xs..xl, control_height, scroll_bar_width 等
};

pub const light: Theme; // 内置亮色
pub const dark: Theme;  // 内置暗色
```

---

## animation — 动画

```zig
pub const Easing = struct {
    pub const EaseCurve = enum { linear, ease_in_quad, ease_out_quad, ease_in_out_quad, ease_in_cubic, ease_out_cubic, ease_in_out_cubic, bounce, cubic_bezier };
    pub const SpringConfig = struct { stiffness, damping, mass };
    pub fn evaluate(self: Easing, t: f32) f32;
};

pub const Tween = struct {
    // from, to, duration_ms, easing, delay_ms, repeat: RepeatMode
    pub fn start(self: *Tween) void;
    pub fn update(self: *Tween, delta_ms: u32) f32; // 返回当前插值
    pub fn currentValue(self: *const Tween) f32;
};

pub fn lerpColor(from: math.Color, to: math.Color, t: f32) math.Color;

pub const AnimationController = struct {
    pub fn init(allocator) AnimationController;
    pub fn deinit(self) void;
    pub fn addAnimation(self, anim: Animation) !AnimationId;
    pub fn addTween(self, tween: *Tween) void;
    pub fn update(self, delta_ms: u32) void; // 每帧调用
};

pub const RepeatMode = enum { none, restart, reverse, ping_pong };
pub const AnimState = enum { idle, running, paused, completed };
```

---

## input — 快捷键与手势

### ShortcutMap

```zig
pub const ShortcutBinding = struct { key: pal.KeyCode, modifiers: pal.Modifiers, action: []const u8, repeat: bool = false };

pub const ShortcutMap = struct {
    bindings: std.ArrayListUnmanaged(ShortcutBinding),
    pub fn match(self: *ShortcutMap, key: pal.KeyCode, mods: pal.Modifiers) ?[]const u8; // 精确匹配 (含修饰键)
    pub fn deinit(self, allocator) void;
};
```

### 手势识别器

三者均消费 `pal.event.Touch` 流, 在 `draw_fn` 中遍历 `app.touchEvents()` 喂入。

```zig
pub const TapGesture = struct {
    // max_duration_ns = 250ms, max_distance = 10px; 长按/大位移/cancelled 均拒绝
    pub fn onTouch(self, t: Touch, now_ns: u64) ?Result; // Result { x, y }
};

pub const DragGesture = struct {
    // min_distance = 4px 触发阈值; 单指, 忽略第二根手指
    pub fn onTouch(self, t: Touch) ?Result; // Result { dx, dy, total_x, total_y, began, ended }
};

pub const PinchGesture = struct {
    // 双指; 跟踪初始/上次指距
    pub fn onTouch(self, t: Touch) ?Result; // Result { scale, delta_scale, center_x, center_y, ended }
};
```

---

## gpu — Metal 设备

一般经 `App` / `Renderer2D` 间接使用; 自定义渲染管线时直接操作:

```zig
pub const MetalDevice = struct {
    pub fn init(metal_layer: *anyopaque, max_vertices: u32) !MetalDevice;
    pub fn deinit(self) void;

    pub fn beginFrame(self) ?[2]u32;             // 返回 drawable 尺寸 [w, h]
    pub fn beginFrameDirty(self, dirty_x: i32, dirty_y: i32, dirty_w: i32, dirty_h: i32) ?[2]u32;
    //   离屏累积画布 + loadAction Load + scissor 局部重绘; endFrame 时整帧 blit
    pub fn endFrame(self) void;
    pub fn setDrawableSize(self, width: u32, height: u32) void;

    // 纯色管线
    pub fn updateVertices(self, vertices: []const Vertex2D) void;
    pub fn drawTriangles(self, vertex_count: u32) void;

    // 纹理管线 (glyph atlas)
    pub fn createTexture(self, width: u32, height: u32) ?*anyopaque; // R8Unorm
    pub fn updateTextureRegion(self, texture, x, y, w, h, data: []const u8, data_stride: u32) void;
    pub fn updateTextVertices(self, vertices: []const TextVertex) void;
    pub fn drawTextured(self, vertex_count: u32, texture: *anyopaque) void;

    // 图像管线
    pub fn createTextureRGBA(self, width: u32, height: u32) ?*anyopaque; // RGBA8Unorm
    pub fn drawImage(self, vertices: []const TextVertex, texture: *anyopaque) void;
    pub fn destroyTexture(self, texture: *anyopaque) void;
};
```

---

## 构建与测试

```bash
zig build                      # 编译库 + 全部示例
zig build test --summary all   # 运行全部单元测试 (当前 51 个)
zig build run-m3-demo          # 运行 M3 综合演示
zig build run-simple           # 最小示例
zig build run-widgets          # 控件示例
```

测试分布: math (7) / EventQueue 回归 (1) / layout (1) / animation (7) / widget (4) / dirty (6) / split_view (2) / tree_view (1) / table (2) / image (6) / gesture (6) / event (2) / ShortcutMap (1) 等。

### 已知约定与陷阱

- **坐标系**: 渲染器 viewport 为设备像素; Cocoa 事件已在 PAL 层乘以 `backingScaleFactor` 并翻转 Y, 应用层无需再转换。
- **ArrayListUnmanaged 默认值**: Zig 0.16 下必须显式 `.{ .items = &.{}, .capacity = 0 }`, `.{}` 编译失败。
- **ShapedGlyph 必须 `extern struct`**: 经 `@ptrCast` 直传 C, 普通 struct 字段重排会破坏 ABI。
- **EventQueue**: 勿改为直接 `append` (见 [pal 一节](#eventqueue))。
- **帧状态**: `mouse_clicked` / `scroll_delta` / `typed_cp_count` / `key_hit` / `file_drop` / 触摸均为边沿量, 帧末清除, 不可跨帧缓存。
