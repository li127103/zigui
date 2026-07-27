//! DirectWrite 文本引擎 (Windows) - 骨架实现
//!
//! 提供字体加载、glyph 光栅化、文本测量。接口与 CoreText/FreeType 后端对齐,
//! 由 text/font.zig 在 Windows 平台下选择使用。
//!
//! 当前状态: 结构骨架, 待 M5 实现。

const std = @import("std");
const builtin = @import("builtin");
const is_windows = builtin.os.tag == .windows;

pub const ShapedGlyph = struct {
    glyph_id: u32,
    cluster: u32,
    x_advance: f32,
    y_advance: f32,
    x_offset: f32,
    y_offset: f32,
};

pub const FontMetrics = struct {
    ascent: f32,
    descent: f32,
    leading: f32,
    line_height: f32,
    underline_position: f32,
    underline_thickness: f32,
    cap_height: f32,
    x_height: f32,
};

pub const GlyphBitmapMetrics = struct {
    width: i32,
    height: i32,
    bearing_x: i32,
    bearing_y: i32,
    advance: i32,
};

pub const DwFont = struct {
    allocator: std.mem.Allocator,
    size: f32,
    weight: u16,
    font_id: u64,

    pub fn createFromFile(allocator: std.mem.Allocator, path: [*:0]const u8, size: f32, weight: u16) !DwFont {
        _ = allocator;
        _ = path;
        _ = size;
        _ = weight;
        return error.NotImplemented;
    }

    pub fn createFromMemory(allocator: std.mem.Allocator, data: []const u8, size: f32, weight: u16) !DwFont {
        _ = allocator;
        _ = data;
        _ = size;
        _ = weight;
        return error.NotImplemented;
    }

    pub fn destroy(self: *DwFont) void {
        _ = self;
    }

    pub fn getMetrics(self: *const DwFont) FontMetrics {
        _ = self;
        return .{
            .ascent = 0,
            .descent = 0,
            .leading = 0,
            .line_height = 0,
            .underline_position = 0,
            .underline_thickness = 0,
            .cap_height = 0,
            .x_height = 0,
        };
    }

    pub fn shapeText(self: *const DwFont, text: []const u8, out_glyphs: []ShapedGlyph) usize {
        _ = self;
        _ = text;
        _ = out_glyphs;
        return 0;
    }

    pub fn measureText(self: *const DwFont, text: []const u8) f32 {
        _ = self;
        _ = text;
        return 0;
    }

    pub fn rasterizeGlyph(self: *const DwFont, glyph_id: u32, buf: []u8) ?GlyphBitmapMetrics {
        _ = self;
        _ = glyph_id;
        _ = buf;
        return null;
    }

    pub fn fontId(self: *const DwFont) u64 {
        return self.font_id;
    }
};

/// 查找系统字体
pub fn findSystemFont(allocator: std.mem.Allocator, family: ?[]const u8) ![:0]u8 {
    _ = allocator;
    _ = family;
    return error.NotImplemented;
}

/// 查找支持 CJK (中日韩) 字形的系统字体
pub fn findCjkFont(allocator: std.mem.Allocator) ![:0]u8 {
    _ = allocator;
    return error.NotImplemented;
}
