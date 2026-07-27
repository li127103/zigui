[中文](README.md) | **English**

# zigui

A cross-platform, GPU-accelerated GUI framework written in [Zig](https://ziglang.org). High-performance immediate-mode rendering for desktop applications, driven directly by each platform's native graphics API with no lossy abstraction layer in between.

## Features

- **Native GPU rendering** - macOS Metal / Linux Vulkan. Batched vertex submission across three pipelines (solid color / textured text / images).
- **Native text engine** - macOS CoreText / Linux FreeType+HarfBuzz shaping with automatic font fallback (CJK routed to fallback fonts such as PingFang), a cached glyph atlas, paragraph layout, word wrapping and alignment.
- **Pure-Zig PNG decoding** - zero external dependencies. Grayscale / RGB / RGBA with all five scanline filters; decode-to-GPU-texture in a single step.
- **Flexbox-style layout** - constraint-based two-pass algorithm (measure + arrange) with flex_grow distribution, margin / padding / gap.
- **Widget system** - Widget base class, widget tree, bubbling event dispatch, dirty flags. 38 built-in widgets (Label / Button / TextInput / TextArea / Slider / ComboBox / ListView / TabView / TreeView / Table / SplitView / Menu / MenuBar / Dialog / MessageDialog / Tooltip / Checkbox / Radio / Switch / ProgressBar / Spinner / Image / ScrollView / ScrollBar / Canvas / Separator / StatusBar / Expander / SpinButton / ToggleButton / LinkButton / Grid / Stack / Frame / CenterBox / FlowBox / Overlay, etc.).
- **Full input stack** - unified event model, IME composition, file drag & drop, multi-touch with gesture recognizers (Tap / Drag / Pinch), shortcut bindings, system clipboard.
- **On-demand redraw** - dirty-region collection and merging, subtree culling, offscreen accumulation canvas with scissored partial redraws. Zero GPU cost on idle frames.
- **Animation system** - easing curves, tweens, springs, color interpolation, animation controller.
- **Accessibility & perf monitoring** - widget semantic roles (a11y), focus navigation, frame-time stats (FPS / P99 stutter metrics).

## Platform Support

| Platform | Windowing | Rendering | Status |
| --- | --- | --- | --- |
| macOS | Cocoa | Metal | ✅ Implemented (M1–M4) |
| Windows | Win32 | D3D11 | Planned |
| Linux | X11 / Wayland | Vulkan | ✅ Implemented |
| OpenHarmony | - | - | Long-term |

## Quick Start

Requires Zig 0.16.

```bash
zig build                      # Build the library and all examples
zig build test --summary all   # Run the unit test suite (154 tests)

zig build run-simple           # Minimal example: window + text
zig build run-widgets          # Widget showcase
zig build run-new-widgets      # New widget showcase (Checkbox/Radio/Switch/ScrollView, etc.)
zig build run-m3-demo          # Text / IME / animation demo
zig build run-m4-demo          # Image / shadow / drag-drop / gesture demo
zig build run-perf-demo        # Performance monitoring demo (FPS / frame time)
```

Minimal code:

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

## Project Structure

```
src/
├── app.zig            # App main loop (window + rendering + events, all-in-one entry)
├── app_linux.zig      # Linux app main loop (Wayland/X11 + Vulkan)
├── math.zig           # Rect / Mat3x2 / Color geometry primitives
├── perf.zig           # Frame-time stats (FPS / P99 stutter metrics)
├── pal/               # Platform abstraction: unified events, windows, Cocoa/Wayland/X11 backends
├── gpu/               # Graphics HAL + Metal/Vulkan backends (shaders)
├── render2d/          # 2D renderer: rects / rounded rects / shadows / images / dirty regions
├── text/              # CoreText/FreeType bindings + glyph atlas + paragraph layout
├── image/             # Pure-Zig PNG decoder
├── widget/            # Widget base class + 38 built-in widgets
├── layout/            # Flexbox constraint layout engine
├── theme/             # Built-in light / dark themes
├── animation/         # Easing / tweens / spring animations
└── input/             # Shortcut map + touch gesture recognizers
docs/                  # Technical spec and API reference
examples/              # Example programs
```

## Documentation

- [API Reference](docs/api.md) — all public modules, type signatures and usage conventions (Chinese)
- [Technical Spec](docs/technical-spec.md) — architecture and milestone plan (Chinese)

## Roadmap

M1 windowing & rendering ✅ -> M2 widgets & layout ✅ -> M3 text & IME ✅ -> M4 images / dirty rects / touch / drag-drop / accessibility / perf monitoring ✅ -> Linux (X11/Wayland + Vulkan) ✅ -> M5 Windows (Win32 + D3D11) -> accessibility refinements, HiDPI, visual editor

## License

MIT OR Apache-2.0 (dual-licensed)
