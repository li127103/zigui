//! D3D11 图形设备 (Windows) - 骨架实现
//!
//! 提供 Direct3D 11 后端, 接口与 Metal/Vulkan 后端对齐,
//! 由 gpu/hal.zig 在 Windows 平台下选择使用。
//!
//! 当前状态: 结构骨架, 所有方法返回 NotImplemented, 待 M5 实现。

const std = @import("std");
const builtin = @import("builtin");
const is_windows = builtin.os.tag == .windows;
const math = @import("../math.zig");

const d3d11 = if (is_windows) @cImport({
    @cDefine("WIN32_LEAN_AND_MEAN", "1");
    @cInclude("windows.h");
    @cInclude("d3d11.h");
    @cInclude("d3dcommon.h");
    @cInclude("dxgi.h");
}) else void;

pub const D3D11Device = struct {
    allocator: std.mem.Allocator,
    device: if (is_windows) ?*d3d11.ID3D11Device else void = null,
    context: if (is_windows) ?*d3d11.ID3D11DeviceContext else void = null,
    swap_chain: if (is_windows) ?*d3d11.IDXGISwapChain else void = null,
    render_target_view: if (is_windows) ?*d3d11.ID3D11RenderTargetView else void = null,
    width: u32 = 0,
    height: u32 = 0,

    /// 从 Win32 HWND 创建 D3D11 设备与交换链
    pub fn initWin32(
        allocator: std.mem.Allocator,
        hwnd: *const anyopaque,
        width: u32,
        height: u32,
    ) !D3D11Device {
        _ = allocator;
        _ = hwnd;
        _ = width;
        _ = height;
        return error.NotImplemented;
    }

    pub fn deinit(self: *D3D11Device) void {
        _ = self;
    }

    pub fn resize(self: *D3D11Device, width: u32, height: u32) !void {
        _ = self;
        _ = width;
        _ = height;
        return error.NotImplemented;
    }

    pub fn beginFrame(self: *D3D11Device) void {
        _ = self;
    }

    pub fn endFrame(self: *D3D11Device) void {
        _ = self;
    }

    /// 创建 2D 纹理 (RGBA8)
    pub fn createTexture(self: *D3D11Device, width: u32, height: u32) ?*anyopaque {
        _ = self;
        _ = width;
        _ = height;
        return null;
    }

    pub fn destroyTexture(self: *D3D11Device, texture: *anyopaque) void {
        _ = self;
        _ = texture;
    }

    /// 更新纹理区域 (RGBA8 数据, 行跨度 = width)
    pub fn updateTextureRegion(
        self: *D3D11Device,
        texture: *anyopaque,
        x: u32,
        y: u32,
        width: u32,
        height: u32,
        data: []const u8,
        row_pitch: u32,
    ) void {
        _ = self;
        _ = texture;
        _ = x;
        _ = y;
        _ = width;
        _ = height;
        _ = data;
        _ = row_pitch;
    }

    /// 创建顶点缓冲区
    pub fn createVertexBuffer(self: *D3D11Device, size: u64) ?*anyopaque {
        _ = self;
        _ = size;
        return null;
    }

    pub fn updateVertexBuffer(self: *D3D11Device, buffer: *anyopaque, data: []const u8) void {
        _ = self;
        _ = buffer;
        _ = data;
    }

    pub fn destroyBuffer(self: *D3D11Device, buffer: *anyopaque) void {
        _ = self;
        _ = buffer;
    }
};
