//! zigui simple 示例 - 最小可运行 demo
//! 窗口 + 背景 + 文字渲染

const std = @import("std");
const zigui = @import("zigui");
const math = zigui.math;

pub fn main() !void {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var app = try zigui.app.App.init(allocator, .{
        .title = "zigui - Simple",
        .width = 480,
        .height = 320,
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

    // 标题
    drawText(app, "Hello, zigui!", 40, 80, 32.0, 700, 0x38BDF8FF);

    // 副标题
    drawText(app, "Cross-platform GPU-accelerated GUI in Zig.", 40, 140, 16.0, 400, 0xCBD5E1FF);
}

fn drawText(app: *zigui.app.App, text: []const u8, x: f32, y: f32, size: f32, weight: u16, color: u32) void {
    var font = zigui.coretext.CtFont.create(null, size, weight) catch return;
    defer font.destroy();

    var tl = zigui.text_layout.TextLayout.layout(
        app.allocator,
        app.getGlyphAtlas(),
        app.getMetalDevice(),
        text,
        .{ .font = &font, .font_size = size },
    ) catch return;
    defer tl.deinit();

    app.getRenderer().drawText(&tl, x, y, math.Color.hex(color)) catch {};
}
