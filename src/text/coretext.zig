//! CoreText 文本引擎 (macOS) - Zig 封装层

const std = @import("std");

const c = @cImport({
    @cInclude("coretext_backend.h");
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

pub const CtFont = struct {
    handle: *c.ZiguiCtFont,
    size: f32,

    pub fn create(family: ?[]const u8, size: f32, weight: u16) !CtFont {
        const handle = if (family) |fam| blk: {
            // 栈上构造 null-terminated 字符串
            var buf: [256:0]u8 = undefined;
            const len = @min(fam.len, 255);
            @memcpy(buf[0..len], fam[0..len]);
            buf[len] = 0;
            break :blk c.zigui_ct_create_font(&buf, size, weight);
        } else c.zigui_ct_create_font(null, size, weight);

        if (handle == null) return error.FontCreationFailed;
        return .{ .handle = handle.?, .size = size };
    }

    pub fn destroy(self: *CtFont) void {
        c.zigui_ct_destroy_font(self.handle);
    }

    pub fn getMetrics(self: *const CtFont) FontMetrics {
        var m: c.ZiguiFontMetrics = undefined;
        c.zigui_ct_get_metrics(self.handle, &m);
        return .{
            .ascent = m.ascent,
            .descent = m.descent,
            .leading = m.leading,
            .line_height = m.line_height,
            .underline_position = m.underline_position,
            .underline_thickness = m.underline_thickness,
            .cap_height = m.cap_height,
            .x_height = m.x_height,
        };
    }

    /// Shape UTF-8 文本，返回 glyph 数量
    pub fn shapeText(self: *const CtFont, text: []const u8, out_glyphs: []ShapedGlyph) usize {
        if (text.len == 0 or out_glyphs.len == 0) return 0;
        const n = c.zigui_ct_shape_text(
            self.handle,
            text.ptr,
            @intCast(text.len),
            @ptrCast(out_glyphs.ptr),
            @intCast(out_glyphs.len),
        );
        return @intCast(@max(n, 0));
    }

    /// 测量文本宽度
    pub fn measureText(self: *const CtFont, text: []const u8) f32 {
        if (text.len == 0) return 0;
        return c.zigui_ct_measure_text(self.handle, text.ptr, @intCast(text.len));
    }

    /// 光栅化单个 glyph 到灰度位图
    pub fn rasterizeGlyph(self: *const CtFont, glyph_id: u32, buf: []u8) ?GlyphBitmapMetrics {
        var m: c.ZiguiGlyphBitmapMetrics = undefined;
        const ok = c.zigui_ct_rasterize_glyph(
            self.handle,
            glyph_id,
            buf.ptr,
            @intCast(buf.len),
            &m,
        );
        if (!ok) return null;
        return .{
            .width = m.width,
            .height = m.height,
            .bearing_x = m.bearing_x,
            .bearing_y = m.bearing_y,
            .advance = m.advance,
        };
    }
};
