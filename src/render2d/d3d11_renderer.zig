//! D3D11 2D 渲染器 (Windows) - 骨架实现
//!
//! 基于 Renderer2D 接口的 Direct3D 11 实现, 使用三管线 (纯色 / 纹理文本 / 图像)
//! 批量绘制。接口与 Metal/Vulkan 渲染器对齐。
//!
//! 当前状态: 结构骨架, 待 M5 实现。

const std = @import("std");
const builtin = @import("builtin");
const is_windows = builtin.os.tag == .windows;
const math = @import("../math.zig");

const d3d11_mod = @import("../gpu/d3d11.zig");

pub const D3D11Renderer = struct {
    allocator: std.mem.Allocator,
    device: *d3d11_mod.D3D11Device,

    pub fn init(allocator: std.mem.Allocator, device: *d3d11_mod.D3D11Device) D3D11Renderer {
        return .{
            .allocator = allocator,
            .device = device,
        };
    }

    pub fn deinit(self: *D3D11Renderer) void {
        _ = self;
    }

    pub fn beginFrame(self: *D3D11Renderer, clear_color: math.Color) void {
        _ = self;
        _ = clear_color;
    }

    pub fn endFrame(self: *D3D11Renderer) void {
        _ = self;
    }

    pub fn drawRect(self: *D3D11Renderer, rect: math.Rect(f32), color: math.Color) void {
        _ = self;
        _ = rect;
        _ = color;
    }

    pub fn drawRoundedRect(
        self: *D3D11Renderer,
        rect: math.Rect(f32),
        corner_radius: f32,
        color: math.Color,
    ) void {
        _ = self;
        _ = rect;
        _ = corner_radius;
        _ = color;
    }

    pub fn drawShadow(
        self: *D3D11Renderer,
        rect: math.Rect(f32),
        corner_radius: f32,
        blur_radius: f32,
        color: math.Color,
    ) void {
        _ = self;
        _ = rect;
        _ = corner_radius;
        _ = blur_radius;
        _ = color;
    }

    pub fn drawImage(
        self: *D3D11Renderer,
        texture: *anyopaque,
        src_rect: math.Rect(f32),
        dst_rect: math.Rect(f32),
        tint: ?math.Color,
    ) void {
        _ = self;
        _ = texture;
        _ = src_rect;
        _ = dst_rect;
        _ = tint;
    }

    pub fn setClipRect(self: *D3D11Renderer, rect: ?math.Rect(f32)) void {
        _ = self;
        _ = rect;
    }

    pub fn setTransform(self: *D3D11Renderer, transform: math.Mat3x2) void {
        _ = self;
        _ = transform;
    }
};
