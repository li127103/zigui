# zigui 技术规格设计文档

> 版本: 0.1.0-draft  
> 日期: 2026-07-21  
> 许可: MIT / Apache-2.0 双许可  
> 目标语言: Zig 0.16  
> 首个用户: RCDesktop 远程桌面客户端

---

## 目录

1. [项目概述](#1-项目概述)
2. [架构总览](#2-架构总览)
3. [平台抽象层 (PAL)](#3-平台抽象层-pal)
4. [GPU 渲染抽象层 (GPU HAL)](#4-gpu-渲染抽象层-gpu-hal)
5. [2D 渲染引擎](#5-2d-渲染引擎)
6. [文本引擎](#6-文本引擎)
7. [控件系统](#7-控件系统)
8. [布局系统](#8-布局系统)
9. [主题系统](#9-主题系统)
10. [动画系统](#10-动画系统)
11. [输入与事件系统](#11-输入与事件系统)
12. [构建系统与依赖管理](#12-构建系统与依赖管理)
13. [里程碑规划](#13-里程碑规划)
14. [风险分析与缓解](#14-风险分析与缓解)
15. [附录](#15-附录)

---

## 1. 项目概述

### 1.1 定位

zigui 是一个用 Zig 编写的跨平台 GUI 框架库，不绑定具体应用程序。它提供从窗口创建、GPU 加速 2D 渲染、文本排版到完整控件体系的全栈能力。设计目标是高性能、零隐式堆分配（调用者控制分配器）、无运行时反射、编译期可裁剪。

### 1.2 平台与后端矩阵

| 平台 | 窗口系统 | GPU 后端 | 文本 shaping | 最低版本 |
|------|----------|----------|--------------|----------|
| Windows | Win32 (HWND) | Direct3D 11 | DirectWrite | Windows 10 1809 |
| Linux | X11 (xcb) + Wayland | Vulkan 1.1 | FreeType + HarfBuzz | Kernel 4.18+, Xorg 1.20+ / wl_compositor v4 |
| macOS | Cocoa (NSWindow) | Metal 3 | CoreText | macOS 13 Ventura |
| HarmonyOS (远期) | OH_NativeWindow | Vulkan 1.1 / GLES 3.2 兜底 | FreeType + HarfBuzz | API 12 |

### 1.3 设计原则

1. **显式优于隐式**: 所有资源创建/销毁由调用者传入 Allocator，无全局状态。
2. **编译期裁剪**: 通过 `build.zig` options 选择目标平台和后端，未选中的代码不参与编译。
3. **零成本抽象**: GPU HAL 接口通过 comptime 泛型 + 直接调用实现，无虚函数表开销（热路径）。
4. **即时模式可选**: 核心是保留模式 (retained) 控件树，但提供 immediate-mode overlay API 用于调试/自定义绘制。
5. **无隐藏控制流**: 不使用 setjmp/longjmp、信号、隐式线程。事件循环由调用者驱动 (`app.tick()`)。

### 1.4 非目标

- 不提供 3D 场景图（仅 2D UI 渲染）。
- 不内置网络/IO（由上层应用如 RCDesktop 自行管理）。
- 不支持 Web 平台 (WASM)。
- 不做移动端适配（iOS/Android），HarmonyOS 为远期目标。

---

## 2. 架构总览

### 2.1 分层架构图

```
┌─────────────────────────────────────────────────────────────────┐
│                        Application Layer                         │
│                   (RCDesktop / 第三方应用)                        │
├─────────────────────────────────────────────────────────────────┤
│  ┌───────────┐  ┌───────────┐  ┌───────────┐  ┌─────────────┐  │
│  │  Widgets  │  │  Layout   │  │   Theme   │  │  Animation  │  │
│  │  控件系统  │  │  布局引擎  │  │  主题引擎  │  │   动画系统   │  │
│  └─────┬─────┘  └─────┬─────┘  └─────┬─────┘  └──────┬──────┘  │
│        │               │              │               │          │
│  ┌─────┴───────────────┴──────────────┴───────────────┴──────┐  │
│  │                    Render Tree (渲染树)                      │  │
│  │              脏标记 + 增量重绘 + 图层合成                     │  │
│  └───────────────────────────┬───────────────────────────────┘  │
│                              │                                   │
│  ┌───────────────────────────┴───────────────────────────────┐  │
│  │                   2D Render Engine                          │  │
│  │     路径/曲线/填充/描边/渐变/阴影/图片/裁剪/混合             │  │
│  └───────────────────────────┬───────────────────────────────┘  │
│                              │                                   │
│  ┌───────────────────────────┴───────────────────────────────┐  │
│  │                    Text Engine                              │  │
│  │        Shaping (HarfBuzz/CoreText/DirectWrite)              │  │
│  │        Raster (FreeType/CoreText/DirectWrite)               │  │
│  │        Atlas 管理 + 缓存                                    │  │
│  └───────────────────────────┬───────────────────────────────┘  │
│                              │                                   │
│  ┌───────────────────────────┴───────────────────────────────┐  │
│  │                    GPU HAL (图形抽象层)                       │  │
│  │   统一接口: Pipeline / Buffer / Texture / CmdEncoder        │  │
│  ├──────────────┬──────────────────┬─────────────────────────┤  │
│  │   D3D11      │     Vulkan       │        Metal            │  │
│  │  (Windows)   │    (Linux)       │       (macOS)           │  │
│  └──────────────┴──────────────────┴─────────────────────────┘  │
│                              │                                   │
│  ┌───────────────────────────┴───────────────────────────────┐  │
│  │                    PAL (平台抽象层)                           │  │
│  │   Window / EventLoop / Input / Clipboard / Cursor / IME    │  │
│  ├──────────────┬──────────────────┬─────────────────────────┤  │
│  │   Win32      │  X11 + Wayland   │        Cocoa            │  │
│  │  (Windows)   │    (Linux)       │       (macOS)           │  │
│  └──────────────┴──────────────────┴─────────────────────────┘  │
│                              │                                   │
│                    OS Kernel / Display Server                     │
└─────────────────────────────────────────────────────────────────┘
```

### 2.2 核心数据流

```
用户输入 (鼠标/键盘/触摸)
    │
    ▼
PAL 事件采集 (平台原生事件 → 统一 Event 枚举)
    │
    ▼
EventDispatcher (命中测试 → 控件树路由 → 冒泡/捕获)
    │
    ▼
Widget 状态变更 (标记 dirty)
    │
    ▼
Layout Pass (仅脏子树重新布局)
    │
    ▼
Paint Pass (控件 → DrawCmd 列表)
    │
    ▼
Render Tree 合成 (图层排序 → 裁剪 → 混合)
    │
    ▼
2D Engine 三角化 (路径 → 三角形批次)
    │
    ▼
GPU HAL 提交 (CmdBuffer → 后端 API 调用)
    │
    ▼
Present (SwapChain 交换 → 屏幕显示)
```

### 2.3 模块依赖关系

```
zigui/
├── pal/          ← 无内部依赖，仅依赖 OS SDK
├── gpu/          ← 依赖 pal (获取 native surface handle)
├── text/         ← 依赖 gpu (glyph atlas 上传)
├── render2d/     ← 依赖 gpu + text
├── widget/       ← 依赖 render2d + pal (输入事件类型)
├── layout/       ← 依赖 widget (约束传递)
├── theme/        ← 依赖 widget (样式属性定义)
├── animation/    ← 依赖 widget (属性插值目标)
└── app/          ← 顶层组装，依赖所有模块
```

### 2.4 线程模型

zigui 核心运行在单线程（UI 线程）上，不创建隐式线程。以下操作可选异步：

| 操作 | 线程策略 |
|------|----------|
| 事件循环 | UI 线程（调用者驱动 `app.run()` 或 `app.tick()`） |
| GPU 提交 | UI 线程（默认）/ 可选独立 render thread |
| 文本 shaping | UI 线程（缓存命中）/ 可选 worker pool |
| 图片解码 | 调用者线程（通过 `AsyncImageLoader` 接口） |
| 文件 IO | 不内置，由应用层处理 |

---

## 3. 平台抽象层 (PAL)

### 3.1 接口定义

PAL 提供统一的平台服务接口，所有后端实现此接口：

```zig
// pal/pal.zig - PAL 接口定义
pub const Pal = struct {
    backend: Backend,

    pub const Backend = union(enum) {
        win32: Win32Backend,
        x11: X11Backend,
        wayland: WaylandBackend,
        cocoa: CocoaBackend,
    };

    pub fn init(allocator: Allocator, opts: Options) !Pal;
    pub fn deinit(self: *Pal) void;
    pub fn createWindow(self: *Pal, desc: WindowDesc) !Window;
    pub fn pollEvents(self: *Pal, events: *EventQueue) PollResult;
    pub fn waitEvents(self: *Pal, events: *EventQueue, timeout_ms: ?u32) PollResult;
    pub fn getClipboard(self: *Pal) ![]const u8;
    pub fn setClipboard(self: *Pal, text: []const u8) !void;
    pub fn setCursor(self: *Pal, cursor: CursorType) void;
    pub fn getMonitorScale(self: *Pal, monitor: Monitor) f32;
};
```

### 3.2 窗口抽象

```zig
// pal/window.zig
pub const Window = struct {
    handle: NativeHandle,
    size: Size(u32),
    scale_factor: f32,
    title: []const u8,

    pub const NativeHandle = union(enum) {
        hwnd: *anyopaque,
        x11_window: u32,
        wayland_surface: *anyopaque,
        ns_window: *anyopaque,
    };

    pub fn getSurfaceInfo(self: Window) SurfaceInfo;

    pub const SurfaceInfo = union(enum) {
        win32: struct { hinstance: *anyopaque, hwnd: *anyopaque },
        x11: struct { display: *anyopaque, window: u32 },
        wayland: struct { display: *anyopaque, surface: *anyopaque },
        cocoa: struct { layer: *anyopaque },
    };
};

pub const WindowDesc = struct {
    title: []const u8 = "zigui",
    width: u32 = 800,
    height: u32 = 600,
    min_width: ?u32 = null,
    min_height: ?u32 = null,
    max_width: ?u32 = null,
    max_height: ?u32 = null,
    resizable: bool = true,
    decorated: bool = true,
    transparent: bool = false,
    always_on_top: bool = false,
    visible: bool = true,
    parent: ?Window = null,
};
```

### 3.3 Windows 后端 (Win32)

```zig
// pal/win32.zig
const win32 = @cImport({
    @cInclude("windows.h");
    @cInclude("dwmapi.h");
    @cInclude("shellscalingapi.h");
});

pub const Win32Backend = struct {
    hinstance: win32.HINSTANCE,
    windows: std.ArrayListUnmanaged(Window),
    class_atom: win32.ATOM,

    pub fn init(allocator: Allocator) !Win32Backend {
        const hinstance = win32.GetModuleHandleW(null);
        const wc = win32.WNDCLASSEXW{
            .cbSize = @sizeOf(win32.WNDCLASSEXW),
            .style = win32.CS_HREDRAW | win32.CS_VREDRAW | win32.CS_OWNDC,
            .lpfnWndProc = wndProc,
            .hInstance = hinstance,
            .hCursor = win32.LoadCursorW(null, win32.IDC_ARROW),
            .lpszClassName = std.unicode.utf8ToUtf16LeStringLiteral("zigui_window"),
        };
        const atom = win32.RegisterClassExW(&wc);
        _ = win32.SetProcessDpiAwarenessContext(win32.DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2);
        return .{ .hinstance = hinstance, .windows = .{}, .class_atom = atom };
    }

    fn wndProc(hwnd: win32.HWND, msg: win32.UINT, wparam: win32.WPARAM, lparam: win32.LPARAM) callconv(.c) win32.LRESULT {
        return switch (msg) {
            win32.WM_SIZE => handleResize(hwnd, wparam, lparam),
            win32.WM_PAINT => handlePaint(hwnd),
            win32.WM_MOUSEMOVE => handleMouseMove(hwnd, lparam),
            win32.WM_LBUTTONDOWN, win32.WM_LBUTTONUP => handleMouseButton(hwnd, msg, lparam),
            win32.WM_KEYDOWN, win32.WM_KEYUP => handleKey(hwnd, msg, wparam, lparam),
            win32.WM_CHAR => handleChar(hwnd, wparam),
            win32.WM_DPICHANGED => handleDpiChange(hwnd, wparam, lparam),
            win32.WM_CLOSE => handleClose(hwnd),
            win32.WM_DESTROY => handleDestroy(hwnd),
            else => win32.DefWindowProcW(hwnd, msg, wparam, lparam),
        };
    }
};
```

#### Win32 事件映射表

| Win32 消息 | zigui Event | 备注 |
|-----------|-------------|------|
| WM_SIZE | .resize | LOWORD/HIWORD 取新尺寸 |
| WM_MOVE | .move | 窗口位置变化 |
| WM_MOUSEMOVE | .mouse_move | GET_X_LPARAM/GET_Y_LPARAM |
| WM_LBUTTONDOWN/UP | .mouse_button(.left, .pressed/.released) | |
| WM_RBUTTONDOWN/UP | .mouse_button(.right, ...) | |
| WM_MOUSEWHEEL | .scroll(.vertical, delta) | WHEEL_DELTA=120 归一化 |
| WM_MOUSEHWHEEL | .scroll(.horizontal, delta) | |
| WM_KEYDOWN/UP | .key(.pressed/.released, keycode) | MapVirtualKey → 物理键码 |
| WM_CHAR | .text_input(codepoint) | UTF-16 → UTF-8 |
| WM_IME_COMPOSITION | .ime_composition(...) | GCS_RESULTSTR |
| WM_DPICHANGED | .scale_change(new_scale) | |
| WM_CLOSE | .close_requested | |
| WM_DROPFILES | .file_drop(paths) | DragQueryFileW |

### 3.4 Linux 后端

#### 3.4.1 后端选择策略

```zig
// pal/linux.zig
pub const LinuxBackend = struct {
    active: union(enum) {
        x11: X11Backend,
        wayland: WaylandBackend,
    },

    pub fn init(allocator: Allocator, opts: Options) !LinuxBackend {
        // 优先级: 用户强制 > WAYLAND_DISPLAY > DISPLAY
        if (opts.force_backend) |b| return initForced(allocator, b);
        if (std.posix.getenv("WAYLAND_DISPLAY") != null) {
            return .{ .active = .{ .wayland = try WaylandBackend.init(allocator) } };
        }
        if (std.posix.getenv("DISPLAY") != null) {
            return .{ .active = .{ .x11 = try X11Backend.init(allocator) } };
        }
        return error.NoDisplayServer;
    }
};
```

#### 3.4.2 X11 后端 (xcb)

使用 xcb 而非 Xlib：线程安全、协议级 API、无全局锁。

```zig
// pal/x11.zig
const xcb = @cImport({
    @cInclude("xcb/xcb.h");
    @cInclude("xcb/xkb.h");
    @cInclude("xcb/xinput.h");
    @cInclude("xcb/randr.h");
    @cInclude("xcb/present.h");
});

pub const X11Backend = struct {
    conn: *xcb.xcb_connection_t,
    screen: *xcb.xcb_screen_t,
    xkb_state: *XkbState,
    windows: std.ArrayListUnmanaged(X11Window),
    randr_ext: RandrExt,
    xinput_ext: XInputExt,

    pub fn init(allocator: Allocator) !X11Backend {
        const conn = xcb.xcb_connect(null, null) orelse return error.ConnectionFailed;
        if (xcb.xcb_connection_has_error(conn) != 0) return error.ConnectionFailed;
        const setup = xcb.xcb_get_setup(conn);
        const screen = firstScreen(setup);
        const xkb_state = try XkbState.init(conn);
        const randr_ext = try RandrExt.init(conn, screen);
        const xinput_ext = try XInputExt.init(conn, screen);
        return .{ .conn = conn, .screen = screen, .xkb_state = xkb_state,
                  .windows = .{}, .randr_ext = randr_ext, .xinput_ext = xinput_ext };
    }

    pub fn createWindow(self: *X11Backend, desc: WindowDesc) !Window {
        const wid = xcb.xcb_generate_id(self.conn);
        const mask = xcb.XCB_CW_EVENT_MASK | xcb.XCB_CW_COLORMAP;
        const values = [_]u32{
            xcb.XCB_EVENT_MASK_EXPOSURE | xcb.XCB_EVENT_MASK_STRUCTURE_NOTIFY |
            xcb.XCB_EVENT_MASK_KEY_PRESS | xcb.XCB_EVENT_MASK_KEY_RELEASE |
            xcb.XCB_EVENT_MASK_BUTTON_PRESS | xcb.XCB_EVENT_MASK_BUTTON_RELEASE |
            xcb.XCB_EVENT_MASK_POINTER_MOTION | xcb.XCB_EVENT_MASK_ENTER_WINDOW |
            xcb.XCB_EVENT_MASK_LEAVE_WINDOW | xcb.XCB_EVENT_MASK_FOCUS_CHANGE,
            self.screen.default_colormap,
        };
        _ = xcb.xcb_create_window(self.conn, xcb.XCB_COPY_FROM_PARENT, wid,
            self.screen.root, 0, 0, @intCast(desc.width), @intCast(desc.height),
            0, xcb.XCB_WINDOW_CLASS_INPUT_OUTPUT, self.screen.root_visual, mask, &values);
        try self.setWmProtocols(wid);
        try self.setTitle(wid, desc.title);
        try self.setSizeHints(wid, desc);
        if (desc.visible) { _ = xcb.xcb_map_window(self.conn, wid); }
        _ = xcb.xcb_flush(self.conn);
        return Window{ .handle = .{ .x11_window = wid }, .size = .{ .width = desc.width, .height = desc.height }, .scale_factor = 1.0, .title = desc.title };
    }

    pub fn pollEvents(self: *X11Backend, queue: *EventQueue) PollResult {
        while (xcb.xcb_poll_for_event(self.conn)) |event| {
            defer std.c.free(event);
            self.translateEvent(event, queue);
        }
        return if (queue.count > 0) .events_available else .no_events;
    }
};
```

#### 3.4.3 Wayland 后端

```zig
// pal/wayland.zig
const wl = @cImport({
    @cInclude("wayland-client.h");
    @cInclude("xdg-shell-client-protocol.h");
    @cInclude("xdg-decoration-client-protocol.h");
    @cInclude("relative-pointer-client-protocol.h");
    @cInclude("pointer-constraints-client-protocol.h");
    @cInclude("text-input-client-protocol.h");
    @cInclude("linux-dmabuf-client-protocol.h");
});

pub const WaylandBackend = struct {
    display: *wl.wl_display,
    registry: *wl.wl_registry,
    compositor: ?*wl.wl_compositor = null,
    xdg_wm_base: ?*wl.xdg_wm_base = null,
    seat: ?*wl.wl_seat = null,
    shm: ?*wl.wl_shm = null,
    keyboard: ?*wl.wl_keyboard = null,
    pointer: ?*wl.wl_pointer = null,
    touch: ?*wl.wl_touch = null,
    text_input_manager: ?*wl.zwp_text_input_manager_v3 = null,
    windows: std.ArrayListUnmanaged(WaylandWindow),
    event_queue: *wl.wl_event_queue,

    pub fn init(allocator: Allocator) !WaylandBackend {
        const display = wl.wl_display_connect(null) orelse return error.ConnectionFailed;
        const event_queue = wl.wl_display_create_queue(display);
        var self: WaylandBackend = .{ .display = display, .registry = undefined, .event_queue = event_queue, .windows = .{} };
        self.registry = wl.wl_display_get_registry(display);
        _ = wl.wl_registry_add_listener(self.registry, &registry_listener, &self);
        _ = wl.wl_display_roundtrip(display);
        _ = wl.wl_display_roundtrip(display);
        if (self.compositor == null) return error.NoCompositor;
        if (self.xdg_wm_base == null) return error.NoXdgShell;
        return self;
    }

    pub fn createWindow(self: *WaylandBackend, desc: WindowDesc) !Window {
        const surface = wl.wl_compositor_create_surface(self.compositor);
        const xdg_surface = wl.xdg_wm_base_get_xdg_surface(self.xdg_wm_base, surface);
        const toplevel = wl.xdg_surface_get_toplevel(xdg_surface);
        _ = wl.xdg_toplevel_set_title(toplevel, desc.title.ptr);
        _ = wl.xdg_toplevel_set_app_id(toplevel, "zigui");
        if (desc.min_width) |mw| {
            _ = wl.xdg_toplevel_set_min_size(toplevel, @intCast(mw), @intCast(desc.min_height orelse 0));
        }
        wl.wl_surface_commit(surface);
        return Window{ .handle = .{ .wayland_surface = surface }, .size = .{ .width = desc.width, .height = desc.height }, .scale_factor = 1.0, .title = desc.title };
    }

    pub fn pollEvents(self: *WaylandBackend, queue: *EventQueue) PollResult {
        while (wl.wl_display_prepare_read_queue(self.display, self.event_queue) != 0) {
            _ = wl.wl_display_dispatch_queue_pending(self.display, self.event_queue);
        }
        _ = wl.wl_display_flush(self.display);
        const fd = wl.wl_display_get_fd(self.display);
        var pfd = std.os.pollfd{ .fd = fd, .events = std.os.POLL.IN, .revents = 0 };
        const n = std.os.poll(&.{pfd}, 0) catch 0;
        if (n > 0) {
            _ = wl.wl_display_read_events(self.display);
            _ = wl.wl_display_dispatch_queue_pending(self.display, self.event_queue);
        } else {
            wl.wl_display_cancel_read(self.display);
        }
        return if (queue.count > 0) .events_available else .no_events;
    }
};
```

#### 3.4.4 X11/Wayland 事件映射

| X11 (xcb) 事件 | Wayland 事件 | zigui Event |
|----------------|-------------|-------------|
| XCB_KEY_PRESS | wl_keyboard.key (pressed) | .key(.pressed) |
| XCB_KEY_RELEASE | wl_keyboard.key (released) | .key(.released) |
| XCB_BUTTON_PRESS (1-3) | wl_pointer.button | .mouse_button |
| XCB_BUTTON_PRESS (4/5) | wl_pointer.axis | .scroll(.vertical) |
| XCB_MOTION_NOTIFY | wl_pointer.motion | .mouse_move |
| XCB_CONFIGURE_NOTIFY | xdg_surface.configure | .resize |
| XCB_ENTER_WINDOW | wl_pointer.enter | .mouse_enter |
| XCB_LEAVE_WINDOW | wl_pointer.leave | .mouse_leave |
| XCB_CLIENT_MESSAGE (WM_DELETE) | xdg_toplevel.close | .close_requested |
| XCB_FOCUS_IN/OUT | wl_keyboard.enter/leave | .focus_change |

### 3.5 macOS 后端 (Cocoa)

```zig
// pal/cocoa.zig
const objc = @cImport({
    @cInclude("objc/objc.h");
    @cInclude("objc/runtime.h");
    @cInclude("objc/message.h");
});
const cocoa = @cImport({
    @cInclude("Cocoa/Cocoa.h");
    @cInclude("QuartzCore/CAMetalLayer.h");
});

pub const CocoaBackend = struct {
    app: objc.id,
    delegate: objc.id,
    windows: std.ArrayListUnmanaged(CocoaWindow),

    pub fn init(allocator: Allocator) !CocoaBackend {
        const app = objc.objc_msgSend(objc.objc_getClass("NSApplication"), objc.sel_registerName("sharedApplication"));
        _ = objc.objc_msgSend(app, objc.sel_registerName("setActivationPolicy:"), @as(c_int, 0));
        const delegate = try createAppDelegate(allocator);
        _ = objc.objc_msgSend(app, objc.sel_registerName("setDelegate:"), delegate);
        return .{ .app = app, .delegate = delegate, .windows = .{} };
    }

    pub fn createWindow(self: *CocoaBackend, desc: WindowDesc) !Window {
        const style_mask: c_ulong = blk: {
            var mask: c_ulong = cocoa.NSWindowStyleMaskClosable | cocoa.NSWindowStyleMaskMiniaturizable;
            if (desc.resizable) mask |= cocoa.NSWindowStyleMaskResizable;
            if (desc.decorated) mask |= cocoa.NSWindowStyleMaskTitled;
            break :blk mask;
        };
        const frame = cocoa.NSMakeRect(0, 0, @floatFromInt(desc.width), @floatFromInt(desc.height));
        const ns_window = objc.objc_msgSend(objc.objc_getClass("NSWindow"),
            objc.sel_registerName("initWithContentRect:styleMask:backing:defer:"),
            frame, style_mask, @as(c_ulong, 2), @as(c_int, 0));
        const title_ns = createNSString(desc.title);
        _ = objc.objc_msgSend(ns_window, objc.sel_registerName("setTitle:"), title_ns);
        const content_view = createMetalView(frame);
        _ = objc.objc_msgSend(ns_window, objc.sel_registerName("setContentView:"), content_view);
        _ = objc.objc_msgSend(ns_window, objc.sel_registerName("center"));
        if (desc.visible) {
            _ = objc.objc_msgSend(ns_window, objc.sel_registerName("makeKeyAndOrderFront:"), @as(objc.id, null));
        }
        return Window{ .handle = .{ .ns_window = ns_window }, .size = .{ .width = desc.width, .height = desc.height }, .scale_factor = getBackingScaleFactor(ns_window), .title = desc.title };
    }

    pub fn pollEvents(self: *CocoaBackend, queue: *EventQueue) PollResult {
        const distant_past = objc.objc_msgSend(objc.objc_getClass("NSDate"), objc.sel_registerName("distantPast"));
        while (true) {
            const event = objc.objc_msgSend(self.app,
                objc.sel_registerName("nextEventMatchingMask:untilDate:inMode:dequeue:"),
                @as(c_ulong, 0xFFFFFFFF), distant_past,
                createNSString("kCFRunLoopDefaultMode"), @as(c_int, 1)) orelse break;
            self.translateEvent(event, queue);
        }
        return if (queue.count > 0) .events_available else .no_events;
    }
};
```

### 3.6 统一事件类型

```zig
// pal/event.zig
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
    ime_composition: struct { text: []const u8, cursor_start: u32, cursor_end: u32 },
    ime_commit: struct { text: []const u8 },
    ime_cancel: void,
    touch: struct { id: u32, phase: TouchPhase, x: f32, y: f32 },
    file_drop: struct { paths: []const []const u8, x: i32, y: i32 },
};

pub const MouseButton = enum { left, right, middle, extra1, extra2 };
pub const ButtonState = enum { pressed, released };
pub const ScrollAxis = enum { vertical, horizontal };
pub const TouchPhase = enum { began, moved, ended, cancelled };

pub const Modifiers = packed struct(u8) {
    shift: bool = false,
    ctrl: bool = false,
    alt: bool = false,
    super_key: bool = false,
    caps_lock: bool = false,
    num_lock: bool = false,
    _padding: u2 = 0,
};

pub const KeyCode = enum(u16) {
    a, b, c, d, e, f, g, h, i, j, k, l, m,
    n, o, p, q, r, s, t, u, v, w, x, y, z,
    @"0", @"1", @"2", @"3", @"4", @"5", @"6", @"7", @"8", @"9",
    f1, f2, f3, f4, f5, f6, f7, f8, f9, f10, f11, f12,
    escape, tab, caps_lock, left_shift, right_shift,
    left_ctrl, right_ctrl, left_alt, right_alt,
    left_super, right_super, enter, backspace, delete, space,
    up, down, left, right, home, end, page_up, page_down, insert,
    minus, equal, left_bracket, right_bracket,
    semicolon, apostrophe, grave, comma, period, slash, backslash,
    kp_0, kp_1, kp_2, kp_3, kp_4, kp_5, kp_6, kp_7, kp_8, kp_9,
    kp_add, kp_subtract, kp_multiply, kp_divide, kp_enter, kp_decimal,
    _,
};
```

### 3.7 IME (输入法) 支持

| 平台 | IME 框架 | 集成方式 |
|------|----------|----------|
| Windows | TSF (Text Services Framework) | ITfThreadMgr + ITfContext |
| Linux X11 | XIM / ibus / fcitx | XSetICFocus + XmbLookupString 或 D-Bus |
| Linux Wayland | zwp_text_input_v3 | wl_text_input 协议 |
| macOS | Input Method Kit | NSTextInputClient 协议 |

---

## 4. GPU 渲染抽象层 (GPU HAL)

### 4.1 设计目标

1. **面向 2D UI 渲染优化**：非通用 compute/3D 抽象，仅暴露 UI 渲染所需能力。
2. **帧级资源管理**：每帧分配临时 buffer（ring buffer），跨帧资源显式管理。
3. **批量提交**：DrawCmd 攒批后一次性编码，减少 API 调用次数。
4. **可插拔后端**：编译期通过 `build.zig` 选择，运行期无虚函数开销。

### 4.2 核心接口

```zig
// gpu/hal.zig
pub const GpuDevice = struct {
    backend: Backend,

    pub const Backend = union(enum) {
        d3d11: D3D11Device,
        vulkan: VulkanDevice,
        metal: MetalDevice,
    };

    pub fn create(allocator: Allocator, surface_info: pal.SurfaceInfo, opts: DeviceOptions) !GpuDevice;
    pub fn destroy(self: *GpuDevice) void;
    pub fn beginFrame(self: *GpuDevice) !FrameContext;
    pub fn endFrame(self: *GpuDevice, ctx: *FrameContext) !void;
    pub fn createBuffer(self: *GpuDevice, desc: BufferDesc) !Buffer;
    pub fn createTexture(self: *GpuDevice, desc: TextureDesc) !Texture;
    pub fn createPipeline(self: *GpuDevice, desc: PipelineDesc) !Pipeline;
    pub fn createSampler(self: *GpuDevice, desc: SamplerDesc) !Sampler;
    pub fn destroyBuffer(self: *GpuDevice, buf: Buffer) void;
    pub fn destroyTexture(self: *GpuDevice, tex: Texture) void;
    pub fn destroyPipeline(self: *GpuDevice, pipe: Pipeline) void;
    pub fn allocTransient(self: *GpuDevice, ctx: *FrameContext, size: usize, align: u32) ![*]u8;
};

pub const FrameContext = struct {
    frame_index: u64,
    cmd_encoder: CmdEncoder,
    swapchain_texture: Texture,
    swapchain_size: Size(u32),
};

pub const CmdEncoder = struct {
    pub fn beginRenderPass(self: *CmdEncoder, target: RenderTarget) void;
    pub fn endRenderPass(self: *CmdEncoder) void;
    pub fn bindPipeline(self: *CmdEncoder, pipe: Pipeline) void;
    pub fn bindVertexBuffer(self: *CmdEncoder, buf: Buffer, offset: u64) void;
    pub fn bindIndexBuffer(self: *CmdEncoder, buf: Buffer, offset: u64, index_type: IndexType) void;
    pub fn bindTexture(self: *CmdEncoder, slot: u32, tex: Texture, sampler: Sampler) void;
    pub fn pushConstants(self: *CmdEncoder, data: []const u8) void;
    pub fn draw(self: *CmdEncoder, vertex_count: u32, instance_count: u32, first_vertex: u32) void;
    pub fn drawIndexed(self: *CmdEncoder, index_count: u32, instance_count: u32, first_index: u32) void;
    pub fn setViewport(self: *CmdEncoder, vp: Viewport) void;
    pub fn setScissor(self: *CmdEncoder, rect: Rect(i32)) void;
};
```

### 4.3 资源描述

```zig
// gpu/types.zig
pub const BufferDesc = struct {
    size: u64,
    usage: BufferUsage,
    memory: MemoryType,
};

pub const BufferUsage = packed struct(u8) {
    vertex: bool = false,
    index: bool = false,
    uniform: bool = false,
    storage: bool = false,
    transfer_src: bool = false,
    transfer_dst: bool = false,
    _padding: u2 = 0,
};

pub const MemoryType = enum { device_local, host_visible, host_coherent };

pub const TextureDesc = struct {
    width: u32,
    height: u32,
    format: PixelFormat,
    usage: TextureUsage,
    mip_levels: u32 = 1,
    sample_count: u32 = 1,
};

pub const PixelFormat = enum {
    rgba8_unorm, bgra8_unorm, r8_unorm, rg8_unorm,
    rgba8_srgb, bgra8_srgb, depth32_float,
};

pub const PipelineDesc = struct {
    vertex_shader: []const u8,
    fragment_shader: []const u8,
    vertex_layout: VertexLayout,
    blend: BlendState,
    topology: PrimitiveTopology = .triangle_list,
    push_constant_size: u32 = 0,
};

pub const BlendState = struct {
    enabled: bool = true,
    src_color: BlendFactor = .src_alpha,
    dst_color: BlendFactor = .one_minus_src_alpha,
    op_color: BlendOp = .add,
    src_alpha: BlendFactor = .one,
    dst_alpha: BlendFactor = .one_minus_src_alpha,
    op_alpha: BlendOp = .add,
};
```

### 4.4 D3D11 后端 (Windows)

```zig
// gpu/d3d11.zig
const d3d11 = @cImport({
    @cInclude("d3d11.h");
    @cInclude("dxgi1_4.h");
    @cInclude("d3dcompiler.h");
});

pub const D3D11Device = struct {
    device: *d3d11.ID3D11Device,
    context: *d3d11.ID3D11DeviceContext,
    swapchain: *dxgi.IDXGISwapChain1,
    frames_in_flight: u32 = 2,
    current_frame: u32 = 0,
    ring_buffer: RingBuffer,

    pub fn create(allocator: Allocator, surface_info: pal.SurfaceInfo, opts: DeviceOptions) !D3D11Device {
        const win32_info = surface_info.win32;
        var device: ?*d3d11.ID3D11Device = null;
        var context: ?*d3d11.ID3D11DeviceContext = null;
        const flags: u32 = if (opts.debug) d3d11.D3D11_CREATE_DEVICE_DEBUG else 0;
        const feature_levels = [_]d3d11.D3D_FEATURE_LEVEL{ d3d11.D3D_FEATURE_LEVEL_11_1, d3d11.D3D_FEATURE_LEVEL_11_0 };
        const hr = d3d11.D3D11CreateDevice(null, d3d11.D3D_DRIVER_TYPE_HARDWARE, null, flags,
            &feature_levels, feature_levels.len, d3d11.D3D11_SDK_VERSION, &device, null, &context);
        if (hr != 0) return error.DeviceCreationFailed;
        // 创建 DXGI SwapChain (FLIP_DISCARD, 2 buffers, BGRA8)
        const factory = try createDXGIFactory();
        var swapchain: ?*dxgi.IDXGISwapChain1 = null;
        // ... CreateSwapChainForHwnd ...
        return .{ .device = device.?, .context = context.?, .swapchain = swapchain.?,
                  .ring_buffer = try RingBuffer.init(allocator, device.?, 4 * 1024 * 1024) };
    }

    pub fn beginFrame(self: *D3D11Device) !FrameContext { /* 获取 backbuffer, 创建 RTV, 设置视口 */ }
    pub fn endFrame(self: *D3D11Device, ctx: *FrameContext) !void { /* Present(1,0), ring_buffer.reset() */ }
};
```

### 4.5 Vulkan 后端 (Linux)

```zig
// gpu/vulkan.zig
const vk = @cImport({ @cInclude("vulkan/vulkan.h"); });

pub const VulkanDevice = struct {
    instance: vk.VkInstance,
    physical_device: vk.VkPhysicalDevice,
    device: vk.VkDevice,
    queue: vk.VkQueue,
    queue_family: u32,
    swapchain: Swapchain,
    frames: [2]FrameResources,
    current_frame: u32 = 0,
    cmd_pool: vk.VkCommandPool,
    allocator: GpuAllocator,

    pub fn create(alloc: Allocator, surface_info: pal.SurfaceInfo, opts: DeviceOptions) !VulkanDevice {
        // 1. VkInstance (API 1.1, 平台扩展)
        // 2. VkSurfaceKHR (Xlib / Wayland)
        // 3. 物理设备选择 (独立GPU优先, graphics+present queue)
        // 4. 逻辑设备 + queue
        // 5. Swapchain (FIFO/MAILBOX, 2-3 images)
        // 6. 帧资源 (fence, semaphores, cmd_buf)
        // ...
    }

    fn createSurface(instance: vk.VkInstance, info: pal.SurfaceInfo) !vk.VkSurfaceKHR {
        var surface: vk.VkSurfaceKHR = undefined;
        switch (info) {
            .x11 => |x11_info| {
                const ci = vk.VkXlibSurfaceCreateInfoKHR{
                    .sType = vk.VK_STRUCTURE_TYPE_XLIB_SURFACE_CREATE_INFO_KHR,
                    .dpy = @ptrCast(x11_info.display), .window = x11_info.window,
                };
                if (vk.vkCreateXlibSurfaceKHR(instance, &ci, null, &surface) != .VK_SUCCESS)
                    return error.SurfaceCreationFailed;
            },
            .wayland => |wl_info| {
                const ci = vk.VkWaylandSurfaceCreateInfoKHR{
                    .sType = vk.VK_STRUCTURE_TYPE_WAYLAND_SURFACE_CREATE_INFO_KHR,
                    .display = @ptrCast(wl_info.display), .surface = @ptrCast(wl_info.surface),
                };
                if (vk.vkCreateWaylandSurfaceKHR(instance, &ci, null, &surface) != .VK_SUCCESS)
                    return error.SurfaceCreationFailed;
            },
            else => return error.UnsupportedSurface,
        }
        return surface;
    }

    pub fn beginFrame(self: *VulkanDevice) !FrameContext { /* wait fence, acquire image, begin cmd */ }
    pub fn endFrame(self: *VulkanDevice, ctx: *FrameContext) !void { /* end cmd, submit, present */ }
};
```

### 4.6 Metal 后端 (macOS)

```zig
// gpu/metal.zig
pub const MetalDevice = struct {
    device: objc.id,      // MTLDevice
    queue: objc.id,       // MTLCommandQueue
    layer: objc.id,       // CAMetalLayer
    frames_in_flight: u32 = 3,
    semaphore: std.Thread.Semaphore,
    frame_counter: u64 = 0,

    pub fn create(allocator: Allocator, surface_info: pal.SurfaceInfo, opts: DeviceOptions) !MetalDevice {
        const device = mtl.MTLCreateSystemDefaultDevice() orelse return error.NoMetalDevice;
        const queue = objc.objc_msgSend(device, objc.sel_registerName("newCommandQueue"));
        const layer = surface_info.cocoa.layer;
        // 配置 CAMetalLayer: device, pixelFormat(BGRA8), maxDrawableCount(3), displaySync
        return .{ .device = device, .queue = queue, .layer = layer, .semaphore = .{ .permits = 3 } };
    }

    pub fn beginFrame(self: *MetalDevice) !FrameContext { /* semaphore.wait, nextDrawable, commandBuffer, renderEncoder */ }
    pub fn endFrame(self: *MetalDevice, ctx: *FrameContext) !void { /* endEncoding, presentDrawable, commit, semaphore.post */ }
};
```

### 4.7 Shader 管理

| 平台 | Shader 格式 | 编译方式 | 存储 |
|------|------------|----------|------|
| Windows | DXBC (SM 5.0) | 离线 fxc | `@embedFile` |
| Linux | SPIR-V 1.3 | 离线 glslangValidator | `@embedFile` |
| macOS | MSL / metallib | 离线 xcrun metal | `@embedFile` |

统一 shader 源码用 GLSL 450 编写，构建脚本分别编译：

```
shaders/
├── src/
│   ├── solid.vert.glsl
│   ├── solid.frag.glsl
│   ├── texture.vert.glsl
│   ├── texture.frag.glsl
│   ├── text_sdf.vert.glsl
│   ├── text_sdf.frag.glsl
│   ├── gradient.vert.glsl
│   └── gradient.frag.glsl
├── compiled/
│   ├── dxbc/
│   ├── spirv/
│   └── metallib/
└── build_shaders.zig
```

### 4.8 顶点格式

```zig
// gpu/vertex.zig
pub const Vertex2D = packed struct {
    pos: [2]f32,       // 屏幕坐标 (像素)
    uv: [2]f32,        // 纹理坐标
    color: [4]u8,      // RGBA (premultiplied alpha)
    flags: u32,        // 渲染模式标志
};
// sizeof = 24 bytes

pub const RenderMode = enum(u4) {
    solid_color,
    textured,
    text_sdf,
    linear_gradient,
    radial_gradient,
};
```

---

## 5. 2D 渲染引擎

### 5.1 渲染管线

```
DrawCmd 列表 (来自控件 Paint)
    │
    ▼
Path Flattening (贝塞尔 → 折线段, 容差 0.25px)
    │
    ▼
Tessellation (earcut / stencil-then-cover / 线段扩展)
    │
    ▼
Batching (按 pipeline + texture 分组, 合批)
    │
    ▼
GPU Submit (bind → upload → draw, scissor 裁剪)
```

### 5.2 路径 API

```zig
// render2d/path.zig
pub const Path = struct {
    commands: std.ArrayListUnmanaged(PathCommand),
    allocator: Allocator,

    pub fn init(allocator: Allocator) Path;
    pub fn deinit(self: *Path) void;
    pub fn reset(self: *Path) void;
    pub fn moveTo(self: *Path, x: f32, y: f32) void;
    pub fn lineTo(self: *Path, x: f32, y: f32) void;
    pub fn quadTo(self: *Path, cx: f32, cy: f32, x: f32, y: f32) void;
    pub fn cubicTo(self: *Path, c1x: f32, c1y: f32, c2x: f32, c2y: f32, x: f32, y: f32) void;
    pub fn arcTo(self: *Path, cx: f32, cy: f32, r: f32, start: f32, sweep: f32) void;
    pub fn close(self: *Path) void;
    pub fn addRect(self: *Path, rect: Rect(f32)) void;
    pub fn addRoundedRect(self: *Path, rect: Rect(f32), radius: f32) void;
    pub fn addRoundedRectEx(self: *Path, rect: Rect(f32), radii: [4]f32) void;
    pub fn addEllipse(self: *Path, cx: f32, cy: f32, rx: f32, ry: f32) void;
    pub fn addCircle(self: *Path, cx: f32, cy: f32, r: f32) void;
};

pub const PathCommand = union(enum) {
    move_to: [2]f32,
    line_to: [2]f32,
    quad_to: struct { control: [2]f32, end: [2]f32 },
    cubic_to: struct { c1: [2]f32, c2: [2]f32, end: [2]f32 },
    close: void,
};
```

### 5.3 绘制命令

```zig
// render2d/draw_cmd.zig
pub const DrawCmd = union(enum) {
    fill: struct { path: *const Path, brush: Brush, rule: FillRule = .non_zero },
    stroke: struct { path: *const Path, brush: Brush, width: f32, cap: StrokeCap = .butt, join: StrokeJoin = .miter, miter_limit: f32 = 4.0 },
    draw_image: struct { texture: gpu.Texture, src_rect: Rect(f32), dst_rect: Rect(f32), tint: Color = .white, corner_radius: [4]f32 = .{0,0,0,0} },
    draw_text: struct { glyphs: []const text.PlacedGlyph, atlas: gpu.Texture, color: Color },
    push_clip: Rect(f32),
    pop_clip: void,
    push_transform: Mat3x2,
    pop_transform: void,
    push_opacity: f32,
    pop_opacity: void,
};

pub const Brush = union(enum) {
    solid: Color,
    linear_gradient: LinearGradient,
    radial_gradient: RadialGradient,
    image: struct { texture: gpu.Texture, transform: Mat3x2 },
};

pub const Color = struct {
    r: u8, g: u8, b: u8, a: u8,
    pub fn rgba(r: u8, g: u8, b: u8, a: u8) Color;
    pub fn hex(v: u32) Color;
    pub fn toPremultiplied(self: Color) [4]f32;
};
```

### 5.4 三角化策略

1. **矩形/圆角矩形**: 直接网格生成，圆角 8 段/90°。
2. **凸多边形**: Fan triangulation, O(n)。
3. **凹多边形**: Earcut, O(n log n) 平均。
4. **复杂/自交路径**: Stencil-then-cover (Pass1 写 stencil, Pass2 覆盖着色)。
5. **描边**: 线段扩展为三角形带 + cap/join 处理。

### 5.5 图层合成

```zig
// render2d/compositor.zig
pub const Compositor = struct {
    layers: std.ArrayListUnmanaged(Layer),

    pub const Layer = struct {
        id: u32,
        bounds: Rect(f32),
        opacity: f32 = 1.0,
        transform: Mat3x2 = .identity,
        clip: ?Rect(f32) = null,
        needs_repaint: bool = true,
        texture: ?gpu.Texture = null,  // 离屏缓存
        draw_cmds: std.ArrayListUnmanaged(DrawCmd),
    };

    pub fn composite(self: *Compositor, gpu_dev: *gpu.GpuDevice, ctx: *gpu.FrameContext) !void {
        for (self.layers.items) |*layer| {
            if (!layer.needs_repaint and layer.texture != null) {
                try self.blitCachedLayer(gpu_dev, ctx, layer);
                continue;
            }
            if (layer.opacity < 1.0) {
                try self.renderToOffscreen(gpu_dev, ctx, layer);
                try self.blitWithOpacity(gpu_dev, ctx, layer);
            } else {
                try self.renderLayerDirect(gpu_dev, ctx, layer);
            }
            layer.needs_repaint = false;
        }
    }
};
```

---

## 6. 文本引擎

### 6.1 架构

```
┌─────────────────────────────────────────────────────┐
│                  Text Engine                         │
├─────────────────────────────────────────────────────┤
│  Shaping (HarfBuzz / CoreText / DirectWrite)         │
│       ↓                                             │
│  Rasterizer (FreeType / CoreText / DirectWrite)      │
│       ↓                                             │
│  Glyph Atlas (GPU Texture, Shelf Packing, SDF)       │
│       ↓                                             │
│  Layout (断行 / 对齐 / Bidi / 省略号)                │
└─────────────────────────────────────────────────────┘
```

### 6.2 字体管理

```zig
// text/font.zig
pub const FontCollection = struct {
    allocator: Allocator,
    families: std.StringArrayHashMapUnmanaged(FontFamily),
    fallback_chain: std.ArrayListUnmanaged([]const u8),

    pub fn loadFontFile(self: *FontCollection, path: []const u8) !void;
    pub fn loadFontMemory(self: *FontCollection, data: []const u8) !void;
    pub fn setFallbackChain(self: *FontCollection, families: []const []const u8) void;
    pub fn resolve(self: *FontCollection, desc: FontDesc) ?*FontFace;

    pub const FontDesc = struct {
        family: []const u8,
        size: f32,
        weight: FontWeight = .regular,
        style: FontStyle = .normal,
    };
};

pub const FontWeight = enum(u16) {
    thin = 100, extra_light = 200, light = 300, regular = 400,
    medium = 500, semi_bold = 600, bold = 700, extra_bold = 800, black = 900,
};
```

### 6.3 Shaping

```zig
// text/shaper.zig
pub const Shaper = struct {
    backend: union(enum) {
        harfbuzz: HarfBuzzShaper,
        coretext: CoreTextShaper,
        directwrite: DirectWriteShaper,
    },

    pub const ShapedGlyph = struct {
        glyph_id: u32,
        cluster: u32,
        x_advance: f32, y_advance: f32,
        x_offset: f32, y_offset: f32,
    };

    pub fn shape(self: *Shaper, text: []const u8, font: *FontFace, size: f32, opts: ShapeOptions) ![]ShapedGlyph;
};
```

### 6.4 Glyph Atlas

```zig
// text/atlas.zig
pub const GlyphAtlas = struct {
    texture: gpu.Texture,
    width: u32 = 2048,
    height: u32 = 2048,
    format: gpu.PixelFormat = .rg8_unorm,  // SDF 双通道
    shelves: std.ArrayListUnmanaged(Shelf),
    cache: std.HashMapUnmanaged(GlyphKey, AtlasEntry, GlyphKeyHash, 80),

    pub const GlyphKey = packed struct(u64) {
        font_id: u16,
        glyph_id: u32,
        size_bucket: u16,
    };

    pub const AtlasEntry = struct {
        uv_rect: Rect(f32),
        size: Size(u32),
        bearing: [2]i32,
    };

    pub fn getOrRasterize(self: *GlyphAtlas, gpu_dev: *gpu.GpuDevice, font: *FontFace, glyph_id: u32, size: f32) !AtlasEntry;
};
```

### 6.5 文本布局

```zig
// text/layout.zig
pub const TextLayout = struct {
    lines: std.ArrayListUnmanaged(TextLine),
    total_size: Size(f32),

    pub const TextLine = struct {
        glyphs: std.ArrayListUnmanaged(PlacedGlyph),
        baseline_y: f32,
        height: f32,
        width: f32,
    };

    pub const PlacedGlyph = struct {
        glyph_id: u32,
        x: f32, y: f32,
        advance: f32,
        atlas_entry: GlyphAtlas.AtlasEntry,
        cluster: u32,
    };

    pub fn layout(allocator: Allocator, shaper: *Shaper, atlas: *GlyphAtlas, text: []const u8, opts: LayoutOptions) !TextLayout;

    pub const LayoutOptions = struct {
        font: *FontFace,
        font_size: f32,
        max_width: ?f32 = null,
        max_lines: ?u32 = null,
        line_height: f32 = 1.2,
        align: TextAlign = .left,
        wrap: TextWrap = .word,
        ellipsis: bool = false,
    };
};
```

### 6.6 SDF 文本渲染 Fragment Shader

```glsl
#version 450
layout(set=0, binding=0) uniform sampler2D sdf_atlas;
layout(location=0) in vec2 v_uv;
layout(location=1) in vec4 v_color;
layout(location=0) out vec4 frag_color;
layout(push_constant) uniform PC {
    float smoothing;
    float outline;
    vec4 outline_color;
} pc;

void main() {
    float dist = texture(sdf_atlas, v_uv).r;
    float alpha = smoothstep(0.5 - pc.smoothing, 0.5 + pc.smoothing, dist);
    if (pc.outline > 0.0) {
        float outline_edge = 0.5 - pc.outline;
        float outline_alpha = smoothstep(outline_edge - pc.smoothing, outline_edge + pc.smoothing, dist);
        vec3 color = mix(pc.outline_color.rgb, v_color.rgb, alpha);
        alpha = max(alpha, outline_alpha);
        frag_color = vec4(color * alpha, alpha * v_color.a);
    } else {
        frag_color = vec4(v_color.rgb * alpha, alpha * v_color.a);
    }
}
```

---

## 7. 控件系统

### 7.1 控件树架构

```zig
// widget/widget.zig
pub const Widget = struct {
    vtable: *const VTable,
    id: WidgetId,
    parent: ?*Widget,
    children: std.ArrayListUnmanaged(*Widget),
    layout: LayoutResult,
    state: WidgetState,
    style: ResolvedStyle,

    pub const VTable = struct {
        type_name: []const u8,
        measure: *const fn (self: *Widget, ctx: *MeasureContext) Size(f32),
        paint: *const fn (self: *Widget, ctx: *PaintContext) void,
        on_event: ?*const fn (self: *Widget, event: *Event) EventResult = null,
        focusable: bool = false,
        destroy: *const fn (self: *Widget, allocator: Allocator) void,
    };

    pub const WidgetState = packed struct(u16) {
        hovered: bool = false,
        focused: bool = false,
        pressed: bool = false,
        disabled: bool = false,
        visible: bool = true,
        dirty: bool = true,
        layout_dirty: bool = true,
        _padding: u9 = 0,
    };
};
```

### 7.2 内置控件清单

| 控件 | 类型名 | 描述 | 里程碑 |
|------|--------|------|--------|
| Label | `label` | 静态文本 | M1 |
| Button | `button` | 按钮 | M1 |
| Checkbox | `checkbox` | 复选框 | M1 |
| Radio | `radio` | 单选按钮 | M1 |
| TextInput | `text_input` | 单行输入 | M1 |
| Switch | `switch` | 开关 | M1 |
| ScrollView | `scroll_view` | 滚动容器 | M1 |
| ScrollBar | `scroll_bar` | 滚动条 | M1 |
| Canvas | `canvas` | 自定义绘制 | M1 |
| Image | `image` | 图片 | M1 |
| TextArea | `text_area` | 多行编辑 | M2 |
| Slider | `slider` | 滑动条 | M2 |
| ProgressBar | `progress_bar` | 进度条 | M2 |
| ComboBox | `combo_box` | 下拉选择 | M2 |
| ListView | `list_view` | 虚拟化列表 | M2 |
| TabView | `tab_view` | 标签页 | M2 |
| Menu | `menu` | 菜单 | M2 |
| Tooltip | `tooltip` | 工具提示 | M2 |
| Dialog | `dialog` | 对话框 | M2 |
| Spinner | `spinner` | 加载指示 | M2 |
| TreeView | `tree_view` | 树形视图 | M3 |
| SplitView | `split_view` | 分割面板 | M3 |
| Table | `table` | 虚拟化表格 | M3 |

### 7.3 事件路由

```
事件到达 → HitTest (逆序遍历, 最顶层命中)
    → 捕获阶段 (根 → 目标)
    → 目标 on_event
        ├── handled → 停止
        └── ignored → 冒泡 (目标 → 根)
            → 未处理 → 默认行为 (焦点/滚动)
```

### 7.4 焦点管理

```zig
// widget/focus.zig
pub const FocusManager = struct {
    current: ?*Widget = null,
    ring: std.ArrayListUnmanaged(*Widget),

    pub fn advance(self: *FocusManager, reverse: bool) void;  // Tab/Shift+Tab
    pub fn navigateDirection(self: *FocusManager, dir: Direction) void;  // 方向键
    pub fn setFocus(self: *FocusManager, widget: ?*Widget) void;
};
```

---

## 8. 布局系统

### 8.1 布局模型

类 Flexbox：主轴/交叉轴、对齐、弹性伸缩、换行、绝对定位、百分比、min/max 约束。

### 8.2 约束

```zig
// layout/constraint.zig
pub const Constraints = struct {
    min_width: f32 = 0,
    max_width: f32 = std.math.inf(f32),
    min_height: f32 = 0,
    max_height: f32 = std.math.inf(f32),

    pub fn constrain(self: Constraints, size: Size(f32)) Size(f32);
    pub fn tight(width: f32, height: f32) Constraints;
    pub fn loose(width: f32, height: f32) Constraints;
};
```

### 8.3 布局节点与样式

```zig
// layout/node.zig
pub const LayoutNode = struct {
    style: LayoutStyle,
    children: std.ArrayListUnmanaged(*LayoutNode),
    result: LayoutResult,
    measure_fn: ?*const fn (node: *LayoutNode, constraints: Constraints) Size(f32) = null,

    pub const LayoutStyle = struct {
        width: Dimension = .auto,
        height: Dimension = .auto,
        min_width: Dimension = .auto,
        min_height: Dimension = .auto,
        max_width: Dimension = .auto,
        max_height: Dimension = .auto,
        direction: FlexDirection = .row,
        wrap: FlexWrap = .nowrap,
        justify_content: JustifyContent = .start,
        align_items: AlignItems = .stretch,
        align_content: AlignContent = .start,
        gap: Size(f32) = .{ .width = 0, .height = 0 },
        flex_grow: f32 = 0,
        flex_shrink: f32 = 1,
        flex_basis: Dimension = .auto,
        align_self: ?AlignItems = null,
        margin: EdgeInsets = .{},
        padding: EdgeInsets = .{},
        position: Position = .relative,
        top: ?f32 = null,
        left: ?f32 = null,
        right: ?f32 = null,
        bottom: ?f32 = null,
    };

    pub const Dimension = union(enum) { auto: void, px: f32, percent: f32 };
};
```

### 8.4 布局算法 (两遍)

- **Pass 1 (Measure)**: 递归测量子项固有尺寸，收集 flex 信息，确定容器尺寸。
- **Pass 2 (Arrange)**: 分配弹性空间，按 justify/align 定位子项，递归子树。

增量布局：仅进入 `layout_dirty` 子树，脏标记向上传播。

---

## 9. 主题系统

### 9.1 主题定义

```zig
// theme/theme.zig
pub const Theme = struct {
    name: []const u8,
    colors: ColorPalette,
    fonts: FontPalette,
    metrics: MetricsPalette,
    button: ButtonStyle,
    text_input: TextInputStyle,
    checkbox: CheckboxStyle,
    slider: SliderStyle,
    scroll_bar: ScrollBarStyle,

    pub const ColorPalette = struct {
        primary: Color, primary_hover: Color, primary_pressed: Color,
        secondary: Color,
        background: Color, surface: Color, surface_hover: Color,
        text_primary: Color, text_secondary: Color, text_disabled: Color,
        border: Color, border_focus: Color,
        error: Color, warning: Color, success: Color,
        overlay: Color, shadow: Color, selection: Color,
    };

    pub const MetricsPalette = struct {
        border_radius_sm: f32 = 4,
        border_radius_md: f32 = 6,
        border_radius_lg: f32 = 8,
        border_width: f32 = 1,
        focus_ring_width: f32 = 2,
        spacing_xs: f32 = 4, spacing_sm: f32 = 8,
        spacing_md: f32 = 12, spacing_lg: f32 = 16, spacing_xl: f32 = 24,
        control_height: f32 = 32,
        control_height_sm: f32 = 24,
        control_height_lg: f32 = 40,
        icon_size: f32 = 16,
        scroll_bar_width: f32 = 8,
    };
};
```

### 9.2 内置主题

- `light`: 白底深字，蓝色主色调 (#2563EB)
- `dark`: 深色底 (#0F172A)，浅字，亮蓝主色 (#3B82F6)

支持运行时切换、自定义主题覆盖、控件级样式覆盖、状态伪类。

---

## 10. 动画系统

### 10.1 核心接口

```zig
// animation/animation.zig
pub const Animation = struct {
    id: AnimationId,
    target: *Widget,
    property: AnimatableProperty,
    duration_ms: u32,
    easing: Easing,
    delay_ms: u32 = 0,
    repeat: RepeatMode = .none,
    on_complete: ?*const fn (anim: *Animation) void = null,
    elapsed_ms: u32 = 0,
    state: AnimState = .idle,
};

pub const AnimatableProperty = union(enum) {
    opacity: struct { from: f32, to: f32 },
    translate_x: struct { from: f32, to: f32 },
    translate_y: struct { from: f32, to: f32 },
    scale: struct { from: f32, to: f32 },
    rotation: struct { from: f32, to: f32 },
    color: struct { from: Color, to: Color },
    width: struct { from: f32, to: f32 },
    height: struct { from: f32, to: f32 },
    custom: struct { from: f32, to: f32, apply: *const fn (widget: *Widget, value: f32) void },
};
```

### 10.2 缓动函数

```zig
pub const Easing = union(enum) {
    linear: void,
    ease_in: EaseCurve,
    ease_out: EaseCurve,
    ease_in_out: EaseCurve,
    cubic_bezier: struct { x1: f32, y1: f32, x2: f32, y2: f32 },
    spring: SpringConfig,
    steps: struct { count: u32, jump: StepJump },

    pub const EaseCurve = enum {
        quad, cubic, quart, quint, sine, expo, circ, back, elastic, bounce,
    };

    pub const SpringConfig = struct {
        stiffness: f32 = 170,
        damping: f32 = 26,
        mass: f32 = 1,
        velocity: f32 = 0,
    };

    pub fn evaluate(self: Easing, t: f32) f32;
};
```

### 10.3 动画控制器

每帧由 `app.tick()` 调用 `controller.update(delta_ms)`，遍历活跃动画，计算插值并应用到目标控件属性，标记 dirty。

---

## 11. 输入与事件系统

### 11.1 命中测试

从根节点逆序遍历子节点（后绘制 = 上层），坐标转换到局部空间，边界检查后递归。

### 11.2 快捷键

```zig
// input/shortcut.zig
pub const ShortcutMap = struct {
    bindings: std.ArrayListUnmanaged(Binding),

    pub const Binding = struct {
        key: KeyCode,
        modifiers: Modifiers,
        action: []const u8,
        repeat: bool = false,
    };

    pub fn match(self: *ShortcutMap, key: KeyCode, mods: Modifiers) ?[]const u8;
    pub fn defaults() ShortcutMap;  // Ctrl+C/V/X/A/Z, Tab, Escape, Enter
};
```

---

## 12. 构建系统与依赖管理

### 12.1 项目结构

```
zigui/
├── build.zig
├── build.zig.zon
├── docs/
│   └── technical-spec.md
├── src/
│   ├── root.zig
│   ├── pal/
│   │   ├── pal.zig
│   │   ├── event.zig
│   │   ├── window.zig
│   │   ├── win32.zig
│   │   ├── x11.zig
│   │   ├── wayland.zig
│   │   └── cocoa.zig
│   ├── gpu/
│   │   ├── hal.zig
│   │   ├── types.zig
│   │   ├── vertex.zig
│   │   ├── d3d11.zig
│   │   ├── vulkan.zig
│   │   ├── metal.zig
│   │   └── allocator.zig
│   ├── render2d/
│   │   ├── engine.zig
│   │   ├── path.zig
│   │   ├── tessellation.zig
│   │   ├── draw_cmd.zig
│   │   ├── compositor.zig
│   │   └── batch.zig
│   ├── text/
│   │   ├── font.zig
│   │   ├── shaper.zig
│   │   ├── atlas.zig
│   │   ├── layout.zig
│   │   ├── harfbuzz.zig
│   │   ├── freetype.zig
│   │   ├── coretext.zig
│   │   └── directwrite.zig
│   ├── widget/
│   │   ├── widget.zig
│   │   ├── container.zig
│   │   ├── button.zig
│   │   ├── label.zig
│   │   ├── text_input.zig
│   │   ├── checkbox.zig
│   │   ├── radio.zig
│   │   ├── scroll_view.zig
│   │   ├── canvas.zig
│   │   ├── image.zig
│   │   ├── focus.zig
│   │   └── registry.zig
│   ├── layout/
│   │   ├── engine.zig
│   │   ├── node.zig
│   │   └── constraint.zig
│   ├── theme/
│   │   ├── theme.zig
│   │   ├── builtin.zig
│   │   └── resolver.zig
│   ├── animation/
│   │   ├── animation.zig
│   │   ├── easing.zig
│   │   └── controller.zig
│   ├── input/
│   │   ├── event_queue.zig
│   │   ├── hit_test.zig
│   │   └── shortcut.zig
│   └── app.zig
├── shaders/
│   ├── src/
│   └── compiled/
├── examples/
│   ├── hello.zig
│   ├── widgets_demo.zig
│   └── text_demo.zig
└── tests/
    ├── test_layout.zig
    ├── test_path.zig
    ├── test_tessellation.zig
    └── test_animation.zig
```

### 12.2 build.zig 核心逻辑

```zig
const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const options = b.addOptions();
    const enable_wayland = b.option(bool, "wayland", "Enable Wayland backend") orelse true;
    const enable_x11 = b.option(bool, "x11", "Enable X11 backend") orelse true;
    options.addOption(bool, "enable_wayland", enable_wayland);
    options.addOption(bool, "enable_x11", enable_x11);

    const zigui_mod = b.addModule("zigui", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });
    zigui_mod.addOptions("build_options", options);

    // 平台链接
    switch (target.result.os.tag) {
        .windows => {
            zigui_mod.linkSystemLibrary("d3d11", .{});
            zigui_mod.linkSystemLibrary("dxgi", .{});
            zigui_mod.linkSystemLibrary("d3dcompiler", .{});
            zigui_mod.linkSystemLibrary("dwmapi", .{});
            zigui_mod.linkSystemLibrary("user32", .{});
            zigui_mod.linkSystemLibrary("gdi32", .{});
            zigui_mod.linkSystemLibrary("shell32", .{});
            zigui_mod.linkSystemLibrary("ole32", .{});
        },
        .linux => {
            if (enable_x11) {
                zigui_mod.linkSystemLibrary("xcb", .{});
                zigui_mod.linkSystemLibrary("xcb-xkb", .{});
                zigui_mod.linkSystemLibrary("xcb-xinput", .{});
                zigui_mod.linkSystemLibrary("xcb-randr", .{});
            }
            if (enable_wayland) {
                zigui_mod.linkSystemLibrary("wayland-client", .{});
            }
            zigui_mod.linkSystemLibrary("vulkan", .{});
            zigui_mod.linkSystemLibrary("xkbcommon", .{});
            zigui_mod.linkSystemLibrary("freetype2", .{});
            zigui_mod.linkSystemLibrary("harfbuzz", .{});
            zigui_mod.linkSystemLibrary("fontconfig", .{});
        },
        .macos => {
            zigui_mod.linkFramework("Cocoa", .{});
            zigui_mod.linkFramework("Metal", .{});
            zigui_mod.linkFramework("QuartzCore", .{});
            zigui_mod.linkFramework("CoreText", .{});
            zigui_mod.linkFramework("CoreGraphics", .{});
            zigui_mod.linkFramework("CoreFoundation", .{});
        },
        else => {},
    }
    // examples + tests ...
}
```

### 12.3 系统依赖

| 平台 | 必需库 | 安装 |
|------|--------|------|
| Windows | Windows SDK 10.0.17763+ | Visual Studio |
| Linux X11 | libxcb-dev, xcb-util, libxkbcommon-dev | apt/pacman |
| Linux Wayland | wayland-dev, wayland-protocols | apt/pacman |
| Linux Vulkan | vulkan-headers, libvulkan-dev | apt/pacman |
| Linux 文本 | freetype2-dev, harfbuzz-dev, fontconfig-dev | apt/pacman |
| macOS | Xcode CLT (Metal, Cocoa, CoreText) | xcode-select --install |

---

## 13. 里程碑规划

### M0: 项目骨架 (1 周)

- 项目结构 + build.zig 编译通过
- 基础类型 (Color, Rect, Size, Point, Mat3x2)
- CI (GitHub Actions: Linux/macOS/Windows)

### M1: 窗口 + 渲染核心 (3-4 周)

- PAL: 三平台窗口创建/事件循环/键鼠事件
- GPU HAL: D3D11/Vulkan/Metal 初始化 + SwapChain + 基础绘制
- 2D Engine: 矩形/圆角矩形/纯色/渐变
- Text: 字体加载 + shaping + atlas + 渲染
- Demo: 三平台 "Hello zigui"

### M2: 控件基础 (3-4 周)

- Widget 基类 + 控件树 + 事件路由 + 焦点
- 布局引擎 (Flexbox 子集)
- 控件: Label, Button, Checkbox, Radio, TextInput, Switch, ScrollView, Canvas
- Theme: 亮/暗主题 + 切换
- 输入: 剪贴板, 快捷键

### M3: 高级控件 + 动画 (3-4 周)

- 完整 Flexbox + 绝对定位
- 控件: ComboBox, ListView, TabView, Menu, Dialog, Tooltip, Slider, TextArea
- Animation: 属性动画 + 缓动 + 弹簧
- Text: 选择/编辑/光标
- IME 集成

### M4: 生产就绪 (4-6 周)

- 控件: TreeView, Table, SplitView
- 渲染: 阴影, 图片解码, 高DPI, 脏矩形
- 输入: 触摸/手势, 文件拖放
- 无障碍, 性能监控
- 测试覆盖 > 80%, API 文档
- RCDesktop 集成验证

### M5: 远期

- HarmonyOS 后端
- RTL/Bidi
- 可视化编辑器

---

## 14. 风险分析与缓解

| 风险 | 概率 | 影响 | 缓解 |
|------|------|------|------|
| Zig 0.16 API 不稳定 | 高 | 中 | 封装适配层, 跟踪 nightly, 锁版本 |
| Wayland 协议碎片化 | 中 | 中 | 仅依赖核心协议 + xdg-shell, 可选扩展 |
| Metal 通过 ObjC runtime 调用繁琐 | 中 | 低 | 封装 helper, 参考 zig-metal 绑定 |
| Vulkan 初始化代码量大 | 高 | 低 | 封装 init helper, 参考 VMA 思路 |
| 文本渲染跨平台一致性 | 中 | 高 | 统一用 SDF, 允许平台 shaping 差异 |
| 高 DPI 多显示器 | 中 | 中 | Per-monitor DPI, 坐标全部 f32 |
| 三角化性能 (复杂路径) | 低 | 中 | 缓存三角化结果, 仅脏路径重算 |
| 无成熟 Zig GUI 生态参考 | 中 | 低 | 参考 Flutter/ImGui/Skia 架构 |

---

## 15. 附录

### 15.1 基础数学类型

```zig
// math.zig
pub fn Rect(comptime T: type) type {
    return struct { x: T, y: T, width: T, height: T };
}

pub fn Size(comptime T: type) type {
    return struct { width: T, height: T };
}

pub fn Point(comptime T: type) type {
    return struct { x: T, y: T };
}

pub fn EdgeInsets(comptime T: type) type {
    return struct { top: T, right: T, bottom: T, left: T };
}

pub const EdgeInsets = struct { top: f32 = 0, right: f32 = 0, bottom: f32 = 0, left: f32 = 0 };

/// 2D 仿射变换矩阵 (3x2, 行主序)
/// | a  b  0 |
/// | c  d  0 |
/// | tx ty 1 |
pub const Mat3x2 = struct {
    a: f32 = 1, b: f32 = 0,
    c: f32 = 0, d: f32 = 1,
    tx: f32 = 0, ty: f32 = 0,

    pub const identity = Mat3x2{};
    pub fn translate(x: f32, y: f32) Mat3x2;
    pub fn scale(sx: f32, sy: f32) Mat3x2;
    pub fn rotate(radians: f32) Mat3x2;
    pub fn multiply(self: Mat3x2, other: Mat3x2) Mat3x2;
    pub fn transformPoint(self: Mat3x2, p: [2]f32) [2]f32;
    pub fn invert(self: Mat3x2) ?Mat3x2;
};
```

### 15.2 参考项目

| 项目 | 语言 | 参考价值 |
|------|------|----------|
| Flutter Engine | C++/Dart | 架构分层, 布局算法, 文本引擎 |
| ImGui | C++ | 即时模式 UI, 合批策略 |
| Skia | C++ | 2D 渲染, 路径三角化, SDF |
| winit | Rust | 跨平台窗口抽象 |
| Vello | Rust | GPU 2D 渲染管线 |
| cosmic-text | Rust | 文本 shaping/布局 |
| Taffy | Rust | Flexbox 布局算法 |
| zig-gamedev | Zig | Zig + GPU API 绑定模式 |

### 15.3 许可证

本项目采用 MIT / Apache-2.0 双许可。

```
MIT License
Copyright (c) 2026 zigui contributors

Apache License, Version 2.0
Copyright 2026 zigui contributors
```

---

*文档结束*
