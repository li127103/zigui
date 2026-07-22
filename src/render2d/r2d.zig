//! 跨平台渲染抽象层 (comptime 平台分发)
//!
//! 提供 Renderer2D / Device 的平台别名:
//! - macOS: Metal Renderer2D + MetalDevice
//! - Linux: Vulkan Renderer2D + VulkanDevice
//!
//! Widget 系统通过本模块引用渲染器, 实现跨平台编译。

const builtin = @import("builtin");
const is_macos = builtin.os.tag == .macos;
const is_linux = builtin.os.tag == .linux;

/// 平台 2D 渲染器类型
pub const Renderer2D = if (is_macos)
    @import("renderer.zig").Renderer2D
else if (is_linux)
    @import("vulkan_renderer.zig").Renderer2D
else
    void;

/// 平台 GPU 设备类型
pub const Device = if (is_macos)
    @import("../gpu/metal.zig").MetalDevice
else if (is_linux)
    @import("../gpu/vulkan.zig").VulkanDevice
else
    void;

/// 文本对齐 (平台无关, 来自 text/align.zig)
pub const TextAlign = @import("../text/align.zig").TextAlign;
