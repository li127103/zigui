//! FreeType 文本引擎 (Linux) - Zig 封装层
//! 提供字体加载、glyph 光栅化、文本测量

const std = @import("std");

const ft = @cImport({
    @cInclude("ft2build.h");
    @cInclude("freetype/freetype.h");
});

const fc = @cImport({
    @cInclude("fontconfig/fontconfig.h");
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
        // 缩放后的度量在 face->size->metrics (FT_Size_Metrics)
        const metrics = self.face.*.size.*.metrics;
        // FT_Size_Metrics 的 ascender/descender/height 是 26.6 定点数 (已按当前字号缩放), /64 得像素
        const ascent: f32 = @as(f32, @floatFromInt(metrics.ascender)) / 64.0;
        const descent: f32 = @as(f32, @floatFromInt(-metrics.descender)) / 64.0;
        const height: f32 = @as(f32, @floatFromInt(metrics.height)) / 64.0;
        // underline 度量来自 face (字体设计单位, 未缩放), 需按 size/units_per_em 缩放
        const units_per_em: f32 = @floatFromInt(self.face.*.units_per_EM);
        const scale = self.size / units_per_em;
        const underline_pos: f32 = @as(f32, @floatFromInt(self.face.*.underline_position)) * scale;
        const underline_thick: f32 = @as(f32, @floatFromInt(self.face.*.underline_thickness)) * scale;

        return .{
            .ascent = ascent,
            .descent = descent,
            .leading = height - (ascent + descent),
            .line_height = height,
            .underline_position = underline_pos,
            .underline_thickness = underline_thick,
            .cap_height = ascent * 0.7, // 近似
            .x_height = ascent * 0.5, // 近似
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

    /// 光栅化 glyph 并合成斜体 (fake italic: 水平错切)
    /// buf 为输出缓冲区, max_width 为缓冲区可用宽度 (像素)
    /// 返回写入 buf 中的斜体字形位图 (从 buf[0..] 开始)
    pub fn rasterizeGlyphItalic(self: *const FtFont, glyph_id: u32, buf: []u8, max_width: u32) ?GlyphBitmapMetrics {
        // 先正常光栅化
        if (ft.FT_Load_Glyph(self.face, glyph_id, ft.FT_LOAD_RENDER) != 0) {
            return null;
        }

        const bitmap = &self.face.*.glyph.*.bitmap;
        const src_w: i32 = @intCast(bitmap.*.width);
        const src_h: i32 = @intCast(bitmap.*.rows);
        const advance: i32 = @intCast(self.face.*.glyph.*.advance.x >> 6);
        const bearing_x: i32 = @intCast(self.face.*.glyph.*.bitmap_left);
        const bearing_y: i32 = @intCast(self.face.*.glyph.*.bitmap_top);

        if (src_w <= 0 or src_h <= 0) {
            return .{
                .width = 0,
                .height = 0,
                .bearing_x = 0,
                .bearing_y = 0,
                .advance = advance,
            };
        }

        // Fake italic: 水平错切, 约 18° (tan(18°) ≈ 0.325)
        const shear: f32 = 0.3;
        const src_pitch: i32 = @intCast(bitmap.*.pitch);
        const src_buf: [*]const u8 = @ptrCast(bitmap.*.buffer);

        // 计算错切后宽度
        const shear_shift: f32 = @as(f32, @floatFromInt(src_h)) * shear;
        const dst_w: i32 = @intFromFloat(@ceil(@as(f32, @floatFromInt(src_w)) + shear_shift));
        if (dst_w > @as(i32, @intCast(max_width))) return null;

        const dst_h = src_h;
        const needed: usize = @intCast(dst_w * dst_h);
        if (buf.len < needed) return null;

        // 清空目标缓冲区
        @memset(buf[0..needed], 0);

        // 逐行错切复制 (顶部右移最多, 底部右移为 0)
        const src_h_usize: usize = @intCast(src_h);
        const src_w_usize: usize = @intCast(src_w);
        const dst_w_usize: usize = @intCast(dst_w);
        const src_pitch_usize: usize = @intCast(src_pitch);
        var y: usize = 0;
        while (y < src_h_usize) : (y += 1) {
            // 从顶部到底部, 偏移量从 shear_shift 线性减到 0
            const y_frac: f32 = @as(f32, @floatFromInt(y)) / @as(f32, @floatFromInt(src_h - 1));
            const x_offset: f32 = shear_shift * (1.0 - y_frac);
            const x_off_int: usize = @intFromFloat(@round(x_offset));

            const src_row = src_buf + y * src_pitch_usize;
            const dst_row = buf[y * dst_w_usize + x_off_int ..];

            var x: usize = 0;
            while (x < src_w_usize and x_off_int + x < dst_w_usize) : (x += 1) {
                const src_val = src_row[x];
                if (src_val > 0) {
                    dst_row[x] = src_val;
                }
            }
        }

        return .{
            .width = dst_w,
            .height = dst_h,
            .bearing_x = bearing_x,
            .bearing_y = bearing_y,
            .advance = advance,
        };
    }

    /// 字体稳定标识
    pub fn fontId(self: *const FtFont) u64 {
        return self.font_id;
    }
};

/// 使用 fontconfig 查找系统字体
pub fn findSystemFont(allocator: std.mem.Allocator, family: ?[]const u8) ![:0]u8 {
    // 优先用 fontconfig 按族名查找
    if (family) |fam| {
        if (findFontWithFontconfig(allocator, fam)) |path| {
            return path;
        } else |_| {}
    }
    // 无 family 或查找失败, 回退到 sans-serif
    if (findFontWithFontconfig(allocator, "sans-serif")) |path| {
        return path;
    } else |_| {}

    // 最终回退: 硬编码路径
    const default_fonts = [_][:0]const u8{
        "/usr/share/fonts/truetype/dejavu/DejaVuSans.ttf",
        "/usr/share/fonts/TTF/DejaVuSans.ttf",
        "/usr/share/fonts/dejavu/DejaVuSans.ttf",
        "/usr/share/fonts/truetype/liberation/LiberationSans-Regular.ttf",
        "/usr/share/fonts/liberation-sans/LiberationSans-Regular.ttf",
        "/usr/share/fonts/noto/NotoSans-Regular.ttf",
        "/usr/share/fonts/truetype/noto/NotoSans-Regular.ttf",
    };

    for (default_fonts) |path| {
        if (std.c.access(path, 0) != 0) continue;
        return allocator.dupeZ(u8, path) catch continue;
    }

    return error.NoFontFound;
}

/// 查找支持 CJK (中日韩) 字形的系统字体
/// .otf 为 CFF 单字体, .ttc 为集合, 均取 face_index 0
pub fn findCjkFont(allocator: std.mem.Allocator) ![:0]u8 {
    // 优先用 fontconfig 查找 CJK 字体
    const cjk_families = [_][]const u8{
        "Noto Sans CJK SC",
        "Source Han Sans CN",
        "Source Han Sans SC",
        "WenQuanYi Micro Hei",
        "WenQuanYi Zen Hei",
    };
    for (cjk_families) |fam| {
        if (findFontWithFontconfig(allocator, fam)) |path| {
            return path;
        } else |_| {}
    }

    // 回退: 硬编码路径
    const cjk_fonts = [_][:0]const u8{
        "/usr/share/fonts/adobe-source-han-sans/SourceHanSansCN-Regular.otf",
        "/usr/share/fonts/noto-cjk/NotoSansCJK-Regular.ttc",
        "/usr/share/fonts/opentype/noto/NotoSansCJK-Regular.ttc",
        "/usr/share/fonts/truetype/noto/NotoSansCJK-Regular.ttc",
        "/usr/share/fonts/google-noto-cjk/NotoSansCJK-Regular.ttc",
    };

    for (cjk_fonts) |path| {
        if (std.c.access(path, 0) != 0) continue;
        return allocator.dupeZ(u8, path) catch continue;
    }

    return error.NoFontFound;
}

/// 通过 fontconfig 按字体族名查找字体文件路径
fn findFontWithFontconfig(allocator: std.mem.Allocator, family: []const u8) ![:0]u8 {
    const config = fc.FcInitLoadConfigAndFonts();
    if (config == null) return error.FontconfigInitFailed;
    defer fc.FcConfigDestroy(config);

    const pattern = fc.FcPatternCreate();
    if (pattern == null) return error.PatternCreateFailed;
    defer fc.FcPatternDestroy(pattern);

    // 将 family 名加入查找模式
    const family_z = try allocator.dupeZ(u8, family);
    defer allocator.free(family_z);
    _ = fc.FcPatternAddString(pattern, fc.FC_FAMILY, @ptrCast(family_z.ptr));

    // 应用 substitution 规则
    _ = fc.FcConfigSubstitute(config, pattern, fc.FcMatchPattern);
    fc.FcDefaultSubstitute(pattern);

    // 匹配最佳字体
    var result: fc.FcResult = fc.FcResultNoMatch;
    const font = fc.FcFontMatch(config, pattern, &result);
    if (font == null) return error.NoFontFound;
    defer fc.FcPatternDestroy(font);

    // 提取文件路径
    var file: [*c]u8 = null;
    if (fc.FcPatternGetString(font, fc.FC_FILE, 0, @ptrCast(&file)) != fc.FcResultMatch) {
        return error.NoFontFound;
    }

    const file_slice = std.mem.sliceTo(@as([*:0]const u8, @ptrCast(file)), 0);
    return allocator.dupeZ(u8, file_slice);
}
