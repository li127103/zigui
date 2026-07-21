**中文** | [English](README.en.md)

# zigui

跨平台 GPU 加速 GUI 框架, 使用 [Zig](https://ziglang.org) 编写。面向桌面应用的高性能即时渲染 UI, 各平台原生图形 API 直驱, 无中间抽象层损耗。

## 特性

- **原生 GPU 渲染** — macOS Metal / Windows D3D11 / Linux Vulkan, 顶点批次合并提交, 三管线 (纯色 / 纹理文本 / 图像) 分批绘制
- **原生文本引擎** — CoreText 整形 + 自动字体回退 (CJK 走 PingFang 等回退字体) + glyph atlas 缓存, 支持段落排版、自动换行、对齐
- **纯 Zig PNG 解码** — 零外部依赖, 支持灰度 / RGB / RGBA 与全部 5 种行滤波, 解码后一步上传 GPU 纹理
- **Flexbox 风格布局** — 约束式两遍算法 (measure + arrange), 支持 flex_grow 弹性分配、margin/padding/gap
- **控件系统** — Widget 基类 + 控件树 + 事件冒泡分发 + 脏标记; 内置 16 个控件 (Label / Button / TextInput / TextArea / Slider / ComboBox / ListView / TabView / TreeView / Table / SplitView / Menu / Dialog / Tooltip 等)
- **完整输入栈** — 统一事件模型、IME 输入法组字、文件拖放、多点触摸与手势识别 (Tap / Drag / Pinch)、快捷键绑定
- **按需重绘** — 脏矩形收集与合并、子树裁剪、离屏累积画布 + scissor 局部重绘, 空闲帧零 GPU 开销
- **动画系统** — 缓动曲线、补间、弹簧、颜色插值、动画控制器

## 平台支持

| 平台 | 窗口 | 渲染 | 状态 |
| --- | --- | --- | --- |
| macOS | Cocoa | Metal | ✅ 已实现 (M1–M4) |
| Windows | Win32 | D3D11 | 规划中 |
| Linux | X11 / Wayland | Vulkan | 规划中 |
| OpenHarmony | — | — | 远期 |

## 快速开始

需要 Zig 0.16。

```bash
zig build                      # 编译库与全部示例
zig build test --summary all   # 运行单元测试 (51 个)

zig build run-simple           # 最小示例: 窗口 + 文字
zig build run-widgets          # 控件展示
zig build run-m3-demo          # 文本 / IME / 动画综合演示
zig build run-m4-demo          # 图像 / 阴影 / 拖放 / 手势演示
```

最小代码:

```zig
const zigui = @import("zigui");

pub fn main() !void {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa.deinit();

    var app = try zigui.app.App.init(gpa.allocator(), .{
        .title = "hello zigui",
        .width = 800,
        .height = 600,
    });
    defer app.deinit();

    try app.run(&draw);
}

fn draw(app: *zigui.app.App) void {
    const r = app.getRenderer();
    r.fillRect(.{ .x = 100, .y = 100, .width = 200, .height = 80 },
        zigui.math.Color.hex(0x3B82F6FF)) catch {};
}
```

## 项目结构

```
src/
├── app.zig            # 应用主循环 (窗口 + 渲染 + 事件, 一站式入口)
├── math.zig           # Rect / Mat3x2 / Color 等几何基础
├── pal/               # 平台抽象层: 统一事件、窗口、Cocoa 后端
├── gpu/               # 图形 HAL + Metal 后端 (MSL 着色器)
├── render2d/          # 2D 渲染器: 矩形 / 圆角 / 阴影 / 图像 / 脏矩形
├── text/              # CoreText 封装 + glyph atlas + 段落排版
├── image/             # 纯 Zig PNG 解码器
├── widget/            # Widget 基类 + 16 个内置控件
├── layout/            # Flexbox 约束布局引擎
├── theme/             # 内置亮 / 暗主题
├── animation/         # 缓动 / 补间 / 弹簧动画
└── input/             # 快捷键表 + 触摸手势识别器
docs/                  # 技术规格与 API 参考 (中文)
examples/              # 示例程序
```

## 文档

- [API 参考](docs/api.md) — 全部公共模块、类型签名与使用约定
- [技术规格](docs/technical-spec.md) — 架构设计与里程碑规划

## 路线图

M1 窗口与渲染 ✅ → M2 控件与布局 ✅ → M3 文本与 IME ✅ → M4 图像 / 脏矩形 / 触摸 / 拖放 ✅ → M5 Windows (Win32 + D3D11) → M6 Linux (X11/Wayland + Vulkan) → 无障碍、高 DPI 完善、性能监控

## 许可证

MIT OR Apache-2.0 (双许可)
