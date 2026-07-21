//! FreeType 文本引擎 (Linux) - Zig 封装层
//! 提供字体加载、glyph 光栅化、文本测量

const std = @import("std");

const ft = @cImport({
    @cInclude("ft2build.h");
    @cInclude("freetype/freetype.h");
});

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

pub const FtFont = struct {
    allocator: std.mem.Allocator,
    library: ft.FT_Library,
    face: ft.FT_Face,
    size: f32,
    weight: u16,
    font_id: u64,

    /// 从字体文件创建
    pub fn createFromFile(allocator: std.mem.Allocator, path: [*:0]const u8, size: f32, weight: u16) !FtFont {
        var library: ft.FT_Library = undefined;
        if (ft.FT_Init_FreeType(&library) != 0) {
            return error.FreeTypeInitFailed;
        }

        var face: ft.FT_Face = undefined;
        if (ft.FT_New_Face(library, path, 0, &face) != 0) {
            _ = ft.FT_Done_FreeType(library);
            return error.FontLoadFailed;
        }

        // 设置字体大小 (72 DPI)
        const size_26_6: ft.FT_F26Dot6 = @intFromFloat(size * 64.0);
        _ = ft.FT_Set_Char_Size(face, 0, size_26_6, 72, 72);

        // 生成稳定的 font_id (基于文件路径 + 大小 + 字重)
        const path_slice = std.mem.sliceTo(path, 0);
        var hasher = std.hash.Wyhash.init(0);
        hasher.update(path_slice);
        std.hash.autoHash(&hasher, size_26_6);
        std.hash.autoHash(&hasher, weight);
        const font_id = hasher.final();

        return .{
            .allocator = allocator,
            .library = library,
            .face = face,
            .size = size,
            .weight = weight,
            .font_id = font_id,
        };
    }

    /// 从内存创建
    pub fn createFromMemory(allocator: std.mem.Allocator, data: []const u8, size: f32, weight: u16) !FtFont {
        var library: ft.FT_Library = undefined;
        if (ft.FT_Init_FreeType(&library) != 0) {
            return error.FreeTypeInitFailed;
        }

        var face: ft.FT_Face = undefined;
        if (ft.FT_New_Memory_Face(library, data.ptr, @intCast(data.len), 0, &face) != 0) {
            _ = ft.FT_Done_FreeType(library);
            return error.FontLoadFailed;
        }

        const size_26_6: ft.FT_F26Dot6 = @intFromFloat(size * 64.0);
        _ = ft.FT_Set_Char_Size(face, 0, size_26_6, 72, 72);

        const font_id = std.hash.Wyhash.hash(0, data);

        return .{
            .allocator = allocator,
            .library = library,
            .face = face,
            .size = size,
            .weight = weight,
            .font_id = font_id,
        };
    }

    pub fn destroy(self: *FtFont) void {
        _ = ft.FT_Done_Face(self.face);
        _ = ft.FT_Done_FreeType(self.library);
    }

    pub fn getMetrics(self: *const FtFont) FontMetrics {
        const metrics = self.face.*.metrics;
        const units_per_em: f32 = @floatFromInt(self.face.*.units_per_EM);
        const actual_scale = self.size / units_per_em;

        const ascent: f32 = @floatFromInt(metrics.ascender);
        const descent: f32 = @floatFromInt(-metrics.descender);
        const height: f32 = @floatFromInt(metrics.height);
        const underline_pos: f32 = @floatFromInt(self.face.*.underline_position);
        const underline_thick: f32 = @floatFromInt(self.face.*.underline_thickness);

        return .{
            .ascent = ascent * actual_scale,
            .descent = descent * actual_scale,
            .leading = height * actual_scale - (ascent * actual_scale - descent * actual_scale),
            .line_height = height * actual_scale,
            .underline_position = underline_pos * actual_scale,
            .underline_thickness = underline_thick * actual_scale,
            .cap_height = ascent * actual_scale * 0.7, // 近似
            .x_height = ascent * actual_scale * 0.5, // 近似
        };
    }

    /// Shape UTF-8 文本 (简化版: 逐字符处理, 无 HarfBuzz)
    pub fn shapeText(self: *const FtFont, text: []const u8, out_glyphs: []ShapedGlyph) usize {
        if (text.len == 0 or out_glyphs.len == 0) return 0;

        var count: usize = 0;
        var i: usize = 0;
        var pen_x: f32 = 0;

        while (i < text.len and count < out_glyphs.len) {
            // 解码 UTF-8
            const cp_len = std.unicode.utf8ByteSequenceLength(text[i]) catch {
                i += 1;
                continue;
            };
            if (i + cp_len > text.len) break;

            const cp = std.unicode.utf8Decode(text[i .. i + cp_len]) catch {
                i += cp_len;
                continue;
            };

            // 获取 glyph index
            const glyph_index = ft.FT_Get_Char_Index(self.face, cp);
            if (glyph_index == 0) {
                i += cp_len;
                continue;
            }

            // 加载 glyph 获取 advance
            if (ft.FT_Load_Glyph(self.face, glyph_index, ft.FT_LOAD_DEFAULT) == 0) {
                const advance: f32 = @floatFromInt(self.face.*.glyph.*.advance.x >> 6);
                out_glyphs[count] = .{
                    .glyph_id = glyph_index,
                    .cluster = @intCast(i),
                    .x_advance = advance,
                    .y_advance = 0,
                    .x_offset = pen_x,
                    .y_offset = 0,
                };
                pen_x += advance;
                count += 1;
            }

            i += cp_len;
        }

        return count;
    }

    /// 测量文本宽度
    pub fn measureText(self: *const FtFont, text: []const u8) f32 {
        if (text.len == 0) return 0;

        var width: f32 = 0;
        var i: usize = 0;

        while (i < text.len) {
            const cp_len = std.unicode.utf8ByteSequenceLength(text[i]) catch {
                i += 1;
                continue;
            };
            if (i + cp_len > text.len) break;

            const cp = std.unicode.utf8Decode(text[i .. i + cp_len]) catch {
                i += cp_len;
                continue;
            };

            const glyph_index = ft.FT_Get_Char_Index(self.face, cp);
            if (glyph_index != 0) {
                if (ft.FT_Load_Glyph(self.face, glyph_index, ft.FT_LOAD_DEFAULT) == 0) {
                    width += @floatFromInt(self.face.*.glyph.*.advance.x >> 6);
                }
            }

            i += cp_len;
        }

        return width;
    }

    /// 光栅化单个 glyph 到灰度位图
    pub fn rasterizeGlyph(self: *const FtFont, glyph_id: u32, buf: []u8) ?GlyphBitmapMetrics {
        // 加载并渲染 glyph
        if (ft.FT_Load_Glyph(self.face, glyph_id, ft.FT_LOAD_RENDER) != 0) {
            return null;
        }

        const bitmap = &self.face.*.glyph.*.bitmap;
        const width: i32 = @intCast(bitmap.*.width);
        const height: i32 = @intCast(bitmap.*.rows);

        if (width <= 0 or height <= 0) {
            return .{
                .width = 0,
                .height = 0,
                .bearing_x = 0,
                .bearing_y = 0,
                .advance = @intCast(self.face.*.glyph.*.advance.x >> 6),
            };
        }

        // 检查缓冲区大小
        const needed: usize = @intCast(width * height);
        if (buf.len < needed) return null;

        // 复制位图数据
        const pitch: usize = @intCast(bitmap.*.pitch);
        const buffer: [*]const u8 = @ptrCast(bitmap.*.buffer);
        var row: usize = 0;
        while (row < @as(usize, @intCast(height))) : (row += 1) {
            const src_offset = row * pitch;
            const dst_offset = row * @as(usize, @intCast(width));
            @memcpy(buf[dst_offset .. dst_offset + @as(usize, @intCast(width))], buffer[src_offset .. src_offset + @as(usize, @intCast(width))]);
        }

        return .{
            .width = width,
            .height = height,
            .bearing_x = @intCast(self.face.*.glyph.*.bitmap_left),
            .bearing_y = @intCast(self.face.*.glyph.*.bitmap_top),
            .advance = @intCast(self.face.*.glyph.*.advance.x >> 6),
        };
    }

    /// 字体稳定标识
    pub fn fontId(self: *const FtFont) u64 {
        return self.font_id;
    }
};

/// 使用 fontconfig 查找系统字体
pub fn findSystemFont(allocator: std.mem.Allocator, family: ?[]const u8) ![:0]u8 {
    // 简化实现: 返回常见 Linux 字体路径
    const default_fonts = [_][:0]const u8{
        "/usr/share/fonts/truetype/dejavu/DejaVuSans.ttf",
        "/usr/share/fonts/TTF/DejaVuSans.ttf",
        "/usr/share/fonts/dejavu/DejaVuSans.ttf",
        "/usr/share/fonts/truetype/liberation/LiberationSans-Regular.ttf",
        "/usr/share/fonts/liberation-sans/LiberationSans-Regular.ttf",
        "/usr/share/fonts/noto/NotoSans-Regular.ttf",
        "/usr/share/fonts/truetype/noto/NotoSans-Regular.ttf",
    };

    _ = family; // TODO: 使用 fontconfig 查找

    for (default_fonts) |path| {
        // 检查文件是否存在
        if (std.c.access(path, 0) != 0) continue;
        return allocator.dupeZ(u8, path) catch continue;
    }

    return error.NoFontFound;
}
