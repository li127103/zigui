//! GPU 渲染抽象层 (HAL)
//! 统一 D3D12 / D3D11 / Vulkan / Metal 接口
//!
//! 后端选择策略:
//! - Windows: 优先 D3D12, 不支持时回退 D3D11 (运行时自动检测)
//! - Linux:   Vulkan (X11 / Wayland)
//! - macOS:   Metal (CoreAnimation + CAMetalLayer)

const builtin = @import("builtin");
const pal = @import("../pal/pal.zig");
const math = @import("../math.zig");

const std = @import("std");

pub const types = @import("types.zig");
pub const vertex = @import("vertex.zig");

pub const PixelFormat = types.PixelFormat;
pub const BufferDesc = types.BufferDesc;
pub const TextureDesc = types.TextureDesc;
pub const PipelineDesc = types.PipelineDesc;
pub const BlendState = types.BlendState;

/// GPU 后端类型
pub const BackendType = enum {
    d3d12,
    d3d11,
    vulkan,
    metal,
};

/// 平台默认后端 (编译期确定)
pub const default_backend: BackendType = switch (builtin.os.tag) {
    .windows => .d3d12, // 运行时自动回退到 d3d11
    .linux => .vulkan,
    .macos => .metal,
    else => .vulkan,
};

/// GPU 设备 (平台分发)
pub const GpuDevice = struct {
    backend: Backend,

    pub const Backend = union(enum) {
        d3d12: void,
        d3d11: void,
        vulkan: void,
        metal: void,
    };

    pub const DeviceOptions = struct {
        width: u32 = 800,
        height: u32 = 600,
        vsync: bool = true,
        debug: bool = false,
        sample_count: u32 = 1,
    };

    pub fn create(allocator: std.mem.Allocator, surface_info: pal.SurfaceInfo, opts: DeviceOptions) !GpuDevice {
        _ = allocator;
        _ = surface_info;
        _ = opts;
        // 实际设备创建由各平台 App 层直接调用后端 init 完成
        // (VulkanDevice.init / MetalDevice.init / D3DBackend.create)
        return error.NotImplemented;
    }

    pub fn destroy(self: *GpuDevice) void {
        _ = self;
    }

    pub fn beginFrame(self: *GpuDevice) !FrameContext {
        _ = self;
        return error.NotImplemented;
    }

    pub fn endFrame(self: *GpuDevice, ctx: *FrameContext) !void {
        _ = self;
        _ = ctx;
    }
};

pub const FrameContext = struct {
    frame_index: u64,
    swapchain_size: math.Size(u32),
};

pub const Buffer = struct {
    handle: u64,
    size: u64,
};

pub const Texture = struct {
    handle: u64,
    width: u32,
    height: u32,
    format: PixelFormat,
};

pub const Pipeline = struct {
    handle: u64,
};

pub const Sampler = struct {
    handle: u64,
};
