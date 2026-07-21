//! zigui M4 示例 - Linux 占位
//! 图像 / 阴影 / 文件拖放 / 手势 showcases 目前仅支持 macOS
//! Linux 版本将在图像加载和手势系统适配后实现

const std = @import("std");
const zigui = @import("zigui");
const math = zigui.math;

pub fn main() !void {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var app = try zigui.app.App.init(allocator, .{
        .title = "zigui - M4 Demo (Linux)",
        .width = 720,
        .height = 540,
    });
    defer app.deinit();

    try app.run(&drawFrame);
}

var frame_count: u64 = 0;

fn drawFrame(app: *zigui.app.App) void {
    const r = app.getRenderer();
    const fb = app.getFramebufferSize();
    const w: f32 = @floatFromInt(fb.width);
    const h: f32 = @floatFromInt(fb.height);
    frame_count += 1;

    // 背景
    r.fillRect(.{ .x = 0, .y = 0, .width = w, .height = h }, math.Color.hex(0x0F172AFF)) catch {};

    // 阴影演示卡片
    const card_w: f32 = 320;
    const card_h: f32 = 200;
    const card_x = (w - card_w) / 2.0;
    const card_y = (h - card_h) / 2.0 - 40;

    // 阴影
    r.drawShadow(
        .{ .x = card_x, .y = card_y, .width = card_w, .height = card_h },
        16,
        .{ .blur_radius = 20.0, .offset_y = 8.0, .layers = 12 },
    ) catch {};

    // 卡片
    r.fillRoundedRect(.{ .x = card_x, .y = card_y, .width = card_w, .height = card_h }, 16, math.Color.hex(0x1E293BFF)) catch {};
    r.fillRoundedRect(.{ .x = card_x, .y = card_y, .width = card_w, .height = 4 }, 2, math.Color.hex(0x8B5CF6FF)) catch {};

    // 文本
    drawText(app, "M4 Demo - Shadows & Gestures", card_x + 24, card_y + 40, 20.0, 700, 0xF8FAFCFF);
    drawText(app, "Shadow rendering with Vulkan backend.", card_x + 24, card_y + 80, 15.0, 400, 0x94A3B8FF);
    drawText(app, "Image/Gesture/FileDrop coming soon.", card_x + 24, card_y + 110, 15.0, 400, 0x94A3B8FF);
    drawText(app, "Press ESC to exit.", card_x + 24, card_y + 150, 14.0, 400, 0x64748BFF);

    // 动画色块 (演示连续渲染)
    const t: f32 = @floatFromInt(frame_count % 360);
    const angle = t * std.math.pi / 180.0;
    const dot_x = w / 2.0 + @cos(angle) * 60.0 - 8;
    const dot_y = card_y + card_h + 50 + @sin(angle) * 20.0 - 8;
    r.fillRoundedRect(.{ .x = dot_x, .y = dot_y, .width = 16, .height = 16 }, 8, math.Color.hex(0x38BDF8FF)) catch {};
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
