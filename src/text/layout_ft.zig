//! 多行文本布局 (Linux) - FreeType + Vulkan glyph atlas
//!
//! 镜像 macOS `layout.zig` (CoreText) 的设计: shape 整段 → 断行 → 定位 → 对齐。
//! 对齐枚举与算法复用平台无关的 `align.zig`。
//!
//! 与 macOS 的差异: FreeType 无字体回退 (run_font), 所有 glyph 使用同一字体。

const std = @import("std");
const math = @import("../math.zig");
const vulkan = @import("../gpu/vulkan.zig");
const freetype = @import("freetype.zig");
const atlas_mod = @import("atlas_vulkan.zig");
const align_mod = @import("align.zig");

pub const TextAlign = align_mod.TextAlign;
pub const TextWrap = align_mod.TextWrap;

pub const LayoutOptions = struct {
    font: *const freetype.FtFont,
    font_size: f32,
    max_width: ?f32 = null,
    max_lines: ?u32 = null,
    line_height_scale: f32 = 1.2,
    text_align: TextAlign = .left,
    wrap: TextWrap = .word,
};

pub const PlacedGlyph = struct {
    glyph_id: u32,
    x: f32,
    y: f32,
    advance: f32,
    cluster: u32,
    atlas_entry: atlas_mod.GlyphAtlas.AtlasEntry,
};

pub const TextLine = struct {
    glyphs: std.ArrayListUnmanaged(PlacedGlyph),
    baseline_y: f32,
    width: f32,
    height: f32,
};

pub const TextLayout = struct {
    allocator: std.mem.Allocator,
    lines: std.ArrayListUnmanaged(TextLine),
    total_size: math.Size(f32),

    pub fn init(allocator: std.mem.Allocator) TextLayout {
        return .{
            .allocator = allocator,
            .lines = .{ .items = &.{}, .capacity = 0 },
            .total_size = .{ .width = 0, .height = 0 },
        };
    }

    pub fn deinit(self: *TextLayout) void {
        for (self.lines.items) |*line| {
            line.glyphs.deinit(self.allocator);
        }
        self.lines.deinit(self.allocator);
    }

    /// 执行布局: shape + 断行 + 定位 + 对齐
    pub fn layout(
        allocator: std.mem.Allocator,
        glyph_atlas: *atlas_mod.GlyphAtlas,
        device: *vulkan.VulkanDevice,
        text: []const u8,
        opts: LayoutOptions,
    ) !TextLayout {
        var result = TextLayout.init(allocator);
        errdefer result.deinit();

        if (text.len == 0) return result;

        const metrics = opts.font.getMetrics();
        const line_height = metrics.line_height * opts.line_height_scale;

        // Shape 整段文本
        var shaped_buf: [4096]freetype.ShapedGlyph = undefined;
        const glyph_count = opts.font.shapeText(text, &shaped_buf);
        if (glyph_count == 0) return result;

        const shaped = shaped_buf[0..glyph_count];

        // 断行 + 定位
        var current_line = TextLine{
            .glyphs = .{ .items = &.{}, .capacity = 0 },
            .baseline_y = 0,
            .width = 0,
            .height = line_height,
        };
        var pen_x: f32 = 0;
        var line_idx: u32 = 0;
        var last_break_idx: ?usize = null; // 上一个可断行位置 (shaped 索引)
        var last_break_pen_x: f32 = 0;

        var i: usize = 0;
        while (i < glyph_count) {
            const sg = shaped[i];

            // 获取 atlas entry (FreeType 单字体, 无回退)
            const entry = try glyph_atlas.getOrRasterize(device, opts.font, sg.glyph_id, opts.font_size);

            const advance = sg.x_advance;

            // 检查是否需要换行
            if (opts.max_width) |max_w| {
                if (pen_x + advance > max_w and pen_x > 0) {
                    if (opts.wrap == .word and last_break_idx != null) {
                        // 回退到上一个断行点
                        const break_idx = last_break_idx.?;
                        const break_pen = last_break_pen_x;

                        // 移除断行点之后的 glyphs (含断行空格本身)
                        const keep_count = break_idx - (i - current_line.glyphs.items.len);
                        if (keep_count < current_line.glyphs.items.len) {
                            current_line.glyphs.shrinkRetainingCapacity(keep_count);
                        }
                        current_line.width = break_pen;
                        i = break_idx + 1;
                        pen_x = 0;
                        last_break_idx = null;
                    } else {
                        // 强制断行 (char wrap 或无断行点)
                        current_line.width = pen_x;
                        pen_x = 0;
                        last_break_idx = null;
                    }

                    // 完成当前行
                    current_line.baseline_y = @as(f32, @floatFromInt(line_idx)) * line_height + metrics.ascent;
                    try result.lines.append(allocator, current_line);
                    current_line = TextLine{
                        .glyphs = .{ .items = &.{}, .capacity = 0 },
                        .baseline_y = 0,
                        .width = 0,
                        .height = line_height,
                    };
                    line_idx += 1;

                    // 检查最大行数
                    if (opts.max_lines) |ml| {
                        if (line_idx >= ml) break;
                    }
                    continue;
                }
            }

            // 记录断行点 (空格、换行)
            if (sg.cluster < text.len and (text[sg.cluster] == ' ' or text[sg.cluster] == '\n')) {
                last_break_idx = i;
                last_break_pen_x = pen_x;
            }

            // 放置 glyph (x 为相对行原点的累计位置)
            const placed = PlacedGlyph{
                .glyph_id = sg.glyph_id,
                .x = pen_x,
                .y = 0, // 后续由 baseline_y 确定
                .advance = advance,
                .cluster = sg.cluster,
                .atlas_entry = entry,
            };
            try current_line.glyphs.append(allocator, placed);
            pen_x += advance;
            i += 1;
        }

        // 最后一行
        if (current_line.glyphs.items.len > 0) {
            current_line.width = pen_x;
            current_line.baseline_y = @as(f32, @floatFromInt(line_idx)) * line_height + metrics.ascent;
            try result.lines.append(allocator, current_line);
            line_idx += 1;
        }

        // 计算总尺寸
        var max_width: f32 = 0;
        for (result.lines.items) |line| {
            max_width = @max(max_width, line.width);
        }
        result.total_size = .{
            .width = max_width,
            .height = @as(f32, @floatFromInt(line_idx)) * line_height,
        };

        // 应用对齐 (共享 align.zig 算法; 末行 is_last=true)
        const container_w = opts.max_width orelse max_width;
        const n_lines = result.lines.items.len;
        for (result.lines.items, 0..) |*line, li| {
            align_mod.alignLine(
                PlacedGlyph,
                line.glyphs.items,
                line.width,
                container_w,
                opts.text_align,
                li == n_lines - 1,
            );
        }

        return result;
    }

    /// 简单测量 (不生成 glyph 位置, 仅计算单行宽度)
    pub fn measure(font: *const freetype.FtFont, text: []const u8) f32 {
        return font.measureText(text);
    }
};
