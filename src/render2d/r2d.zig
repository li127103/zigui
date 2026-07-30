//! 跨平台渲染抽象层 (comptime 平台分发)
//!
//! 提供 Renderer2D / Device 的平台别名:
//! - macOS:   Metal Renderer2D + MetalDevice
//! - Linux:   Vulkan Renderer2D + VulkanDevice
//! - Windows: D3D Renderer2D + D3DBackend (D3D12 优先, D3D11 回退)
//!
//! Widget 系统通过本模块引用渲染器, 实现跨平台编译。

const builtin = @import("builtin");
const is_macos = builtin.os.tag == .macos;
const is_linux = builtin.os.tag == .linux;
const is_windows = builtin.os.tag == .windows;

const build_options = @import("build_options");

/// Windows 上是否使用 Vulkan 后端 (默认 D3D11)
pub const use_vulkan = build_options.enable_vulkan;

/// 平台 2D 渲染器类型
pub const Renderer2D = if (is_macos)
    @import("renderer.zig").Renderer2D
else if (is_linux)
    @import("vulkan_renderer.zig").Renderer2D
else if (is_windows)
    if (use_vulkan) @import("vulkan_renderer.zig").Renderer2D else @import("d3d_renderer.zig").Renderer2D
else
    void;

/// 平台 GPU 设备类型
pub const Device = if (is_macos)
    @import("../gpu/metal.zig").MetalDevice
else if (is_linux)
    @import("../gpu/vulkan.zig").VulkanDevice
else if (is_windows)
    if (use_vulkan) @import("../gpu/vulkan.zig").VulkanDevice else @import("d3d_renderer.zig").D3DBackend
else
    void;

/// 文本对齐 (平台无关, 来自 text/align.zig)
pub const TextAlign = @import("../text/align.zig").TextAlign;
