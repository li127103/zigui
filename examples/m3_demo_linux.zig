//! zigui M3 综合示例 - Linux 占位
//! 完整的动画 + 高级控件演示目前仅支持 macOS (依赖 CoreText 文本引擎)
//! Linux 版本将在文本布局引擎完成后实现

const std = @import("std");
const zigui = @import("zigui");
const math = zigui.math;

pub fn main() !void {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var app = try zigui.app.App.init(allocator, .{
        .title = "zigui - M3 Demo (Linux)",
        .width = 800,
        .height = 600,
    });
    defer app.deinit();

    try app.run(&drawFrame);
}

fn drawFrame(app: *zigui.app.App) void {
    const r = app.getRenderer();
    const fb = app.getFramebufferSize();
    const w: f32 = @floatFromInt(fb.width);
    const h: f32 = @floatFromInt(fb.height);

    // 背景
    r.fillRect(.{ .x = 0, .y = 0, .width = w, .height = h }, math.Color.hex(0x0F172AFF)) catch {};

    // 中心卡片
    const card_w: f32 = 500;
    const card_h: f32 = 200;
    const card_x = (w - card_w) / 2.0;
    const card_y = (h - card_h) / 2.0;

    r.fillRoundedRect(.{ .x = card_x, .y = card_y, .width = card_w, .height = card_h }, 16, math.Color.hex(0x1E293BFF)) catch {};
    r.fillRoundedRect(.{ .x = card_x, .y = card_y, .width = card_w, .height = 4 }, 2, math.Color.hex(0x3B82F6FF)) catch {};

    // 文本提示
    drawText(app, "M3 Demo - Animation & Widgets", card_x + 30, card_y + 40, 24.0, 700, 0xF8FAFCFF);
    drawText(app, "Full demo requires text layout engine.", card_x + 30, card_y + 90, 16.0, 400, 0x94A3B8FF);
    drawText(app, "Linux Vulkan backend: X11 + Vulkan + FreeType", card_x + 30, card_y + 120, 14.0, 400, 0x64748BFF);
    drawText(app, "Press ESC to exit.", card_x + 30, card_y + 155, 14.0, 400, 0x64748BFF);
}

fn drawText(app: *zigui.app.App, text: []const u8, x: f32, y: f32, size: f32, weight: u16, color: u32) void {
    const freetype = zigui.freetype;
    const vulkan_renderer = zigui.vulkan_renderer;

    const font_path = freetype.findSystemFont(app.allocator, null) catch return;
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
