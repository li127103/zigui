//! 文本对齐 (平台无关) - 左/居中/右/两端对齐
//!
//! 对齐枚举与核心算法的共享实现, 供 macOS (layout.zig / CoreText) 与
//! Linux (layout_ft.zig / FreeType) 的多行文本布局模块复用。

/// 文本水平对齐方式
pub const TextAlign = enum {
    left, // 左对齐
    center, // 居中对齐
    right, // 右对齐
    justify, // 两端对齐 (末行左对齐)
};

/// 断行方式
pub const TextWrap = enum {
    none, // 不断行
    word, // 按词断行 (空格/换行处)
    char, // 按字符断行
};

/// 对一行已定位的 glyph 应用水平对齐 (原地修改 x)
///
/// GlyphT 仅需 `.x: f32` 字段 (duck typing), 两平台的 PlacedGlyph 均满足。
/// 参数:
///   glyphs      - 本行 glyph (x 为相对行原点的水平位置)
///   line_width  - 本行自然宽度 (glyph advance 之和)
///   container_w - 容器宽度 (对齐参考宽度)
///   alignment   - 对齐方式
///   is_last     - 是否末行 (两端对齐时末行保持左对齐, 符合标准排版)
///
/// 两端对齐算法 (v1): 将多余空间 (container_w - line_width) 均匀分配到
/// 相邻 glyph 间隙。对 CJK 完全正确 (中文两端对齐即均匀字距); 对 Latin
/// 表现为字距拉伸。"仅扩展词边界空格" 的排版优化留作后续。
pub fn alignLine(
    comptime GlyphT: type,
    glyphs: []GlyphT,
    line_width: f32,
    container_w: f32,
    alignment: TextAlign,
    is_last: bool,
) void {
    const extra = container_w - line_width;
    switch (alignment) {
        .left => {},
        .center => {
            const offset = extra / 2.0;
            for (glyphs) |*g| g.x += offset;
        },
        .right => {
            for (glyphs) |*g| g.x += extra;
        },
        .justify => {
            // 末行 / 单 glyph 行 / 无剩余空间: 保持左对齐
            if (is_last or glyphs.len <= 1 or extra <= 0) return;
            const gap = extra / @as(f32, @floatFromInt(glyphs.len - 1));
            for (glyphs, 0..) |*g, i| {
                g.x += gap * @as(f32, @floatFromInt(i));
            }
        },
    }
}

// ── 单元测试 ────────────────────────────────────────────────────────────────

const TestGlyph = struct { x: f32 };

test "alignLine left 不移动" {
    var gs = [_]TestGlyph{ .{ .x = 0 }, .{ .x = 10 }, .{ .x = 20 } };
    alignLine(TestGlyph, &gs, 30, 100, .left, false);
    try std.testing.expectEqual(@as(f32, 0), gs[0].x);
    try std.testing.expectEqual(@as(f32, 10), gs[1].x);
    try std.testing.expectEqual(@as(f32, 20), gs[2].x);
}

test "alignLine center 整体平移 half extra" {
    var gs = [_]TestGlyph{ .{ .x = 0 }, .{ .x = 10 }, .{ .x = 20 } };
    alignLine(TestGlyph, &gs, 30, 100, .center, false);
    try std.testing.expectEqual(@as(f32, 35), gs[0].x);
    try std.testing.expectEqual(@as(f32, 45), gs[1].x);
    try std.testing.expectEqual(@as(f32, 55), gs[2].x);
}

test "alignLine right 整体平移 extra" {
    var gs = [_]TestGlyph{ .{ .x = 0 }, .{ .x = 10 }, .{ .x = 20 } };
    alignLine(TestGlyph, &gs, 30, 100, .right, false);
    try std.testing.expectEqual(@as(f32, 70), gs[0].x);
    try std.testing.expectEqual(@as(f32, 80), gs[1].x);
    try std.testing.expectEqual(@as(f32, 90), gs[2].x);
}

test "alignLine justify 均匀分配间隙且末 glyph 对齐右缘" {
    var gs = [_]TestGlyph{ .{ .x = 0 }, .{ .x = 10 }, .{ .x = 20 } };
    // extra = 100 - 30 = 70, gap = 35
    alignLine(TestGlyph, &gs, 30, 100, .justify, false);
    try std.testing.expectEqual(@as(f32, 0), gs[0].x);
    try std.testing.expectEqual(@as(f32, 45), gs[1].x);
    try std.testing.expectEqual(@as(f32, 90), gs[2].x);
}

test "alignLine justify 末行保持左对齐" {
    var gs = [_]TestGlyph{ .{ .x = 0 }, .{ .x = 10 }, .{ .x = 20 } };
    alignLine(TestGlyph, &gs, 30, 100, .justify, true);
    try std.testing.expectEqual(@as(f32, 0), gs[0].x);
    try std.testing.expectEqual(@as(f32, 10), gs[1].x);
    try std.testing.expectEqual(@as(f32, 20), gs[2].x);
}

test "alignLine justify 单 glyph 行保持左对齐" {
    var gs = [_]TestGlyph{.{ .x = 0 }};
    alignLine(TestGlyph, &gs, 10, 100, .justify, false);
    try std.testing.expectEqual(@as(f32, 0), gs[0].x);
}

const std = @import("std");
