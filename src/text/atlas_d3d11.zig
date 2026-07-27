//! D3D11 Glyph Atlas (Windows) - 骨架实现
//!
//! 字形图集缓存, shelf packing 算法, 与 Metal/Vulkan 版 atlas 接口对齐。
//! 实际绘制时将灰度 alpha 8 数据作为 RGBA8 纹理上传 D3D11。
//!
//! 当前状态: 结构骨架, 待 M5 实现。

const std = @import("std");
const math = @import("../math.zig");

const d3d11_mod = @import("../gpu/d3d11.zig");
const dwrite = @import("dwrite.zig");

pub const AtlasEntry = struct {
    uv_rect: math.Rect(f32),
    width: u32,
    height: u32,
    bearing_x: i32,
    bearing_y: i32,
    advance: i32,
};

pub const GlyphAtlas = struct {
    allocator: std.mem.Allocator,
    width: u32,
    height: u32,
    pixels: []u8,
    texture: ?*anyopaque = null,
    dirty: bool = false,

    pub fn init(allocator: std.mem.Allocator, width: u32, height: u32) !GlyphAtlas {
        const pixels = try allocator.alloc(u8, width * height);
        @memset(pixels, 0);
        return .{
            .allocator = allocator,
            .width = width,
            .height = height,
            .pixels = pixels,
        };
    }

    pub fn deinit(self: *GlyphAtlas) void {
        self.allocator.free(self.pixels);
    }

    pub fn createTexture(self: *GlyphAtlas, device: *d3d11_mod.D3D11Device) !void {
        _ = self;
        _ = device;
        return error.NotImplemented;
    }

    pub fn getOrRasterize(
        self: *GlyphAtlas,
        device: *d3d11_mod.D3D11Device,
        font: *const dwrite.DwFont,
        glyph_id: u32,
        size: f32,
    ) !AtlasEntry {
        _ = self;
        _ = device;
        _ = font;
        _ = glyph_id;
        _ = size;
        return error.NotImplemented;
    }

    pub fn flush(self: *GlyphAtlas, device: *d3d11_mod.D3D11Device) void {
        _ = self;
        _ = device;
    }
};
