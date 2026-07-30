//! DirectWrite 文本引擎 (Windows)
//!
//! 提供字体加载、glyph 度量、文本测量与 shaping。接口与 CoreText/FreeType 后端对齐,
//! 由 text/font.zig 在 Windows 平台下选择使用。
//! 实际光栅化 (栅格化到像素) 由 atlas_d3d11 借助 D2D1 完成, 本文件负责字体/度量。

const std = @import("std");
const builtin = @import("builtin");
const is_windows = builtin.os.tag == .windows;

const dwrite = if (is_windows) @cImport({
    @cDefine("WIN32_LEAN_AND_MEAN", "1");
    @cInclude("windows.h");
    @cInclude("dwrite.h");
}) else void;

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

    // DirectWrite 对象 (仅 Windows 下有效)
    factory: if (is_windows) ?*dwrite.IDWriteFactory else void = null,
    font_face: if (is_windows) ?*dwrite.IDWriteFontFace else void = null,
    design_units_per_em: f32 = 2048.0,
    metrics: FontMetrics = std.mem.zeroes(FontMetrics),

    pub fn createFromFile(allocator: std.mem.Allocator, path: [*:0]const u8, size: f32, weight: u16) !DwFont {
        _ = path;
        return createSystem(allocator, size, weight);
    }

    pub fn createFromMemory(allocator: std.mem.Allocator, data: []const u8, size: f32, weight: u16) !DwFont {
        _ = data;
        return createSystem(allocator, size, weight);
    }

    /// 使用系统默认 UI 字体族创建 (Windows 下 Segoe UI; CJK 回退另由 findCjkFont)
    fn createSystem(allocator: std.mem.Allocator, size: f32, weight: u16) !DwFont {
        if (!is_windows) return error.NotImplemented;

        var factory: ?*dwrite.IDWriteFactory = null;
        const hr = dwrite.DWriteCreateFactory(
            dwrite.DWRITE_FACTORY_TYPE_SHARED,
            &dwrite.IID_IDWriteFactory,
            @ptrCast(&factory),
        );
        if (hr != dwrite.S_OK or factory == null) return error.FontFactoryFailed;

        var self: DwFont = .{
            .allocator = allocator,
            .size = size,
            .weight = weight,
            .font_id = fontIdCounter(),
            .factory = factory,
        };

        // 系统字体集合 → 默认 UI 家族 → 字体面
        var font_collection: ?*dwrite.IDWriteFontCollection = null;
        if (factory.?.*.lpVtbl.*.GetSystemFontCollection.?(factory.?, &font_collection, 0) != dwrite.S_OK) {
            return error.FontCollectionFailed;
        }

        const family_name = [*:0]const u16{ 'S', 'e', 'g', 'o', 'e', ' ', 'U', 'I', 0 };
        var index: u32 = 0;
        var exists: dwrite.BOOL = 0;
        if (font_collection.?.*.lpVtbl.*.FindFamilyName.?(font_collection.?, family_name, &index, &exists) != dwrite.S_OK or exists == 0) {
            // 回退到集合第一个家族
            index = 0;
        }

        var family: ?*dwrite.IDWriteFontFamily = null;
        if (font_collection.?.*.lpVtbl.*.GetFontFamily.?(font_collection.?, index, &family) != dwrite.S_OK or family == null) {
            return error.FontFamilyFailed;
        }

        var font: ?*dwrite.IDWriteFont = null;
        if (family.?.*.lpVtbl.*.GetFirstMatchingFont.?(family.?, @intCast(weight), dwrite.DWRITE_FONT_STRETCH_NORMAL, dwrite.DWRITE_FONT_STYLE_NORMAL, &font) != dwrite.S_OK or font == null) {
            return error.FontFaceFailed;
        }

        var face: ?*dwrite.IDWriteFontFace = null;
        if (font.?.*.lpVtbl.*.CreateFontFace.?(font.?, &face) != dwrite.S_OK or face == null) {
            return error.FontFaceFailed;
        }
        self.font_face = face;

        // 度量
        var fm: dwrite.DWRITE_FONT_METRICS = std.mem.zeroes(dwrite.DWRITE_FONT_METRICS);
        face.?.*.lpVtbl.*.GetMetrics.?(face.?, &fm);
        self.design_units_per_em = @floatFromInt(fm.designUnitsPerEm);
        const em = self.design_units_per_em;
        self.metrics = .{
            .ascent = @as(f32, @floatFromInt(fm.ascent)) / em * size,
            .descent = @as(f32, @floatFromInt(fm.descent)) / em * size,
            .leading = @as(f32, @floatFromInt(fm.lineGap)) / em * size,
            .line_height = (@as(f32, @floatFromInt(fm.ascent + fm.descent + fm.lineGap))) / em * size,
            .underline_position = @as(f32, @floatFromInt(fm.underlinePosition)) / em * size,
            .underline_thickness = @as(f32, @floatFromInt(fm.underlineThickness)) / em * size,
            .cap_height = @as(f32, @floatFromInt(fm.capHeight)) / em * size,
            .x_height = @as(f32, @floatFromInt(fm.xHeight)) / em * size,
        };

        return self;
    }

    pub fn destroy(self: *DwFont) void {
        if (!is_windows) return;
        if (self.font_face) |f| f.*.lpVtbl.*.Release.?(f);
        if (self.factory) |f| f.*.lpVtbl.*.Release.?(f);
        self.font_face = null;
        self.factory = null;
    }

    pub fn getMetrics(self: *const DwFont) FontMetrics {
        return self.metrics;
    }

    /// 把文本 shape 为 glyph 序列 (逐字符取 glyph 索引与 advance)
    pub fn shapeText(self: *const DwFont, text: []const u8, out_glyphs: []ShapedGlyph) usize {
        if (!is_windows) return 0;
        if (self.font_face == null) return 0;

        var codepoints: [256]u32 = undefined;
        var n: usize = 0;

        var i: usize = 0;
        while (i < text.len and n < codepoints.len) {
            const cp = std.unicode.utf8Decode(text[i..]) catch break;
            const len = std.unicode.utf8CodepointSequenceLength(text[i]) catch break;
            i += len;
            codepoints[n] = cp;
            n += 1;
        }
        if (n == 0) return 0;

        var glyph_indices: [256]u16 = undefined;
        self.font_face.?.*.lpVtbl.*.GetGlyphIndices.?(self.font_face.?, &codepoints, @intCast(n), &glyph_indices);

        // 设计空间 advance 度量
        var glyph_metrics: [256]dwrite.DWRITE_GLYPH_METRICS = undefined;
        self.font_face.?.*.lpVtbl.*.GetDesignGlyphMetrics.?(self.font_face.?, &glyph_indices, @intCast(n), &glyph_metrics, 0);

        const em = self.design_units_per_em;
        const count = @min(n, out_glyphs.len);
        var x: f32 = 0;
        for (0..count) |k| {
            const adv = @as(f32, @floatFromInt(glyph_metrics[k].advanceWidth)) / em * self.size;
            out_glyphs[k] = .{
                .glyph_id = glyph_indices[k],
                .cluster = 0,
                .x_advance = adv,
                .y_advance = 0,
                .x_offset = 0,
                .y_offset = 0,
            };
            x += adv;
        }
        return count;
    }

    pub fn measureText(self: *const DwFont, text: []const u8) f32 {
        if (!is_windows) return 0;
        if (self.font_face == null) return 0;

        // 简化测量: 用 shapeText 累加 advance (已含设计空间 advance ÷ em × size)
        var glyphs: [512]ShapedGlyph = undefined;
        const n = self.shapeText(text, &glyphs);
        var width: f32 = 0;
        for (0..n) |k| width += glyphs[k].x_advance;
        return width;
    }

    pub fn rasterizeGlyph(self: *const DwFont, glyph_id: u32, buf: []u8) ?GlyphBitmapMetrics {
        // 实际光栅化由 atlas_d3d11 使用 D2D1 完成; 此处不实现
        _ = self;
        _ = glyph_id;
        _ = buf;
        return null;
    }

    pub fn fontId(self: *const DwFont) u64 {
        return self.font_id;
    }
};

var next_font_id: u64 = 1;
fn fontIdCounter() u64 {
    const id = next_font_id;
    next_font_id += 1;
    return id;
}

fn utf8ToUtf16Le(allocator: std.mem.Allocator, s: []const u8) ![]u16 {
    const w = try allocator.alloc(u16, s.len + 1);
    errdefer allocator.free(w);
    const n = try std.unicode.utf8ToUtf16Le(w, s);
    w[n] = 0;
    return w[0 .. n + 1];
}

/// 查找系统字体 (返回 family 名 UTF-8; 调用方需释放)
pub fn findSystemFont(allocator: std.mem.Allocator, family: ?[]const u8) ![:0]u8 {
    _ = allocator;
    _ = family;
    // 默认使用 Segoe UI (由 DwFont.createSystem 实际加载)
    return error.NotImplemented;
}

/// 查找支持 CJK (中日韩) 字形的系统字体
pub fn findCjkFont(allocator: std.mem.Allocator) ![:0]u8 {
    _ = allocator;
    return error.NotImplemented;
}
