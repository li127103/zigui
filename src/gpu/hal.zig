//! GPU 渲染抽象层 (HAL)
//! 统一 D3D11 / Vulkan / Metal 接口

const pal = @import("../pal/pal.zig");
const math = @import("../math.zig");

pub const types = @import("types.zig");
pub const vertex = @import("vertex.zig");

pub const PixelFormat = types.PixelFormat;
pub const BufferDesc = types.BufferDesc;
pub const TextureDesc = types.TextureDesc;
pub const PipelineDesc = types.PipelineDesc;
pub const BlendState = types.BlendState;

pub const GpuDevice = struct {
    backend: Backend,

    pub const Backend = union(enum) {
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

const std = @import("std");
