//! zigui simple 示例 - 最小可运行 demo
//! 窗口 + 背景 + 文字渲染 (跨平台: macOS Metal / Linux Vulkan)

const std = @import("std");
const builtin = @import("builtin");
const zigui = @import("zigui");
const math = zigui.math;

const is_linux = builtin.os.tag == .linux;
const is_macos = builtin.os.tag == .macos;

pub fn main() !void {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var app = try zigui.app.App.init(allocator, .{
        .title = "zigui - Simple",
        .width = 480,
        .height = 320,
        .resizable = false,
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

    // 标题 (相对布局)
    const margin_x = w * 0.08;
    drawText(app, "Hello, zigui!", margin_x, h * 0.25, 32.0, 700, 0x38BDF8FF);

    // 副标题
    drawText(app, "Cross-platform GPU-accelerated GUI in Zig.", margin_x, h * 0.44, 16.0, 400, 0xCBD5E1FF);

    // 平台信息
    if (comptime is_linux) {
        drawText(app, "Linux X11 + Vulkan + FreeType", margin_x, h * 0.63, 14.0, 400, 0x64748BFF);
    } else if (comptime is_macos) {
        drawText(app, "macOS Metal + CoreText", margin_x, h * 0.63, 14.0, 400, 0x64748BFF);
    }
}

fn drawText(app: *zigui.app.App, text: []const u8, x: f32, y: f32, size: f32, weight: u16, color: u32) void {
    if (is_linux) {
        drawTextLinux(app, text, x, y, size, weight, color);
    } else if (is_macos) {
        drawTextMacos(app, text, x, y, size, weight, color);
    }
}

// ── Linux: FreeType + GlyphAtlas + PlacedGlyph ──────────────────────────────

fn drawTextLinux(app: *zigui.app.App, text: []const u8, x: f32, y: f32, size: f32, weight: u16, color: u32) void {
    comptime if (!is_linux) return;

    const freetype = zigui.freetype;
    const vulkan_renderer = zigui.vulkan_renderer;

    // 查找系统字体
    const font_path = freetype.findSystemFont(app.allocator, null) catch return;
    defer app.allocator.free(font_path);

    // 创建字体
    var font = freetype.FtFont.createFromFile(app.allocator, font_path.ptr, size, weight) catch return;
    defer font.destroy();

    // Shape 文本
    var shaped: [256]freetype.ShapedGlyph = undefined;
    const glyph_count = font.shapeText(text, &shaped);
    if (glyph_count == 0) return;

    // 获取 atlas entries 并构建 PlacedGlyph
    var placed: [256]vulkan_renderer.PlacedGlyph = undefined;
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

// ── macOS: CoreText + TextLayout ────────────────────────────────────────────

fn drawTextMacos(app: *zigui.app.App, text: []const u8, x: f32, y: f32, size: f32, weight: u16, color: u32) void {
    comptime if (!is_macos) return;

    const coretext = zigui.coretext;
    const text_layout = zigui.text_layout;

    var font = coretext.CtFont.create(null, size, weight) catch return;
    defer font.destroy();

    var tl = text_layout.TextLayout.layout(
        app.allocator,
        app.getGlyphAtlas(),
        app.getMetalDevice(),
        text,
        .{ .font = &font, .font_size = size },
    ) catch return;
    defer tl.deinit();

    app.getRenderer().drawText(&tl, x, y, math.Color.hex(color)) catch {};
}
