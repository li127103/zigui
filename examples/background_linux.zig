//! zigui 背景属性示例 - Linux 占位
//! 背景属性 (Widget 基类 background, 框架自主绘制) 依赖 retained-mode 控件系统,
//! 目前仅支持 macOS (CoreText + Metal)。Linux 版本将在控件系统适配 Vulkan 后实现。
//!
//! 此处仅以立即绘制展示"纯色 + 圆角"背景的视觉效果; 背景图片暂不支持。

const std = @import("std");
const zigui = @import("zigui");
const math = zigui.math;

pub fn main() !void {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var app = try zigui.app.App.init(allocator, .{
        .title = "zigui - Background (Linux)",
        .width = 900,
        .height = 620,
    });
    defer app.deinit();

    try app.run(&drawFrame);
}

fn drawFrame(app: *zigui.app.App) void {
    const r = app.getRenderer();
    const fb = app.getFramebufferSize();
    const w: f32 = @floatFromInt(fb.width);
    const h: f32 = @floatFromInt(fb.height);

    // 窗口背景 (对应根容器背景色)
    r.fillRect(.{ .x = 0, .y = 0, .width = w, .height = h }, math.Color.hex(0x0F172AFF)) catch {};

    // 标题
    drawText(app, "背景属性 Background", 32, 40, 22.0, 700, 0xF8FAFCFF);
    drawText(app, "Widget 基类属性, 框架自主绘制 (纯色 / 圆角 / 背景图片)。", 32, 80, 14.0, 400, 0x94A3B8FF);
    drawText(app, "控件系统 (retained-mode) 目前仅支持 macOS, Linux 版本开发中。", 32, 104, 14.0, 400, 0x94A3B8FF);

    // 纯色 + 圆角背景预览 (立即绘制近似)
    const panel_y: f32 = 160;
    const panel_w: f32 = 200;
    const panel_h: f32 = 110;
    const gap: f32 = 24;
    const colors = [_]u32{ 0x3B82F6FF, 0x8B5CF6FF, 0x22C55EFF };
    const radii = [_]f32{ 12, 12, 32 };
    const captions = [_][]const u8{ "color · radius 12", "color · radius 12", "color · radius 32" };

    for (colors, radii, captions, 0..) |c, radius, cap, i| {
        const x: f32 = 32 + @as(f32, @floatFromInt(i)) * (panel_w + gap);
        r.fillRoundedRect(.{ .x = x, .y = panel_y, .width = panel_w, .height = panel_h }, radius, math.Color.hex(c)) catch {};
        drawText(app, cap, x + 14, panel_y + 16, 13.0, 600, 0xFFFFFFFF);
    }

    // 背景图片说明
    drawText(app, "背景图片 (stretch / cover / contain / center / tile) 需在 macOS 上运行查看。", 32, panel_y + panel_h + 40, 14.0, 400, 0x64748BFF);
    drawText(app, "Press ESC to exit.", 32, h - 48, 13.0, 400, 0x475569FF);
}

fn drawText(app: *zigui.app.App, text: []const u8, x: f32, y: f32, size: f32, weight: u16, color: u32) void {
    if (text.len == 0) return;
    const freetype = zigui.freetype;
    const vulkan_renderer = zigui.vulkan_renderer;

    const font_path = freetype.findCjkFont(app.allocator) catch
        freetype.findSystemFont(app.allocator, null) catch return;
    defer app.allocator.free(font_path);

    var font = freetype.FtFont.createFromFile(app.allocator, font_path.ptr, size, weight) catch return;
    defer font.destroy();

    var shaped: [512]freetype.ShapedGlyph = undefined;
    const glyph_count = font.shapeText(text, &shaped);
    if (glyph_count == 0) return;

    var placed: [512]vulkan_renderer.PlacedGlyph = undefined;
    var pen_x: f32 = 0;
    var placed_count: usize = 0;

    const atlas = app.getGlyphAtlas();
    const device = app.getVulkanDevice();

    for (0..glyph_count) |i| {
        const sg = shaped[i];
        const entry = atlas.getOrRasterize(device, &font, sg.glyph_id, size) catch continue;
        placed[placed_count] = .{
            .glyph_id = sg.glyph_id,
            .x = pen_x,
            .y = 0,
            .advance = sg.x_advance,
            .atlas_entry = entry,
        };
        pen_x += sg.x_advance;
        placed_count += 1;
    }

    if (placed_count == 0) return;
    app.getRenderer().drawText(placed[0..placed_count], x, y, math.Color.hex(color)) catch {};
}
