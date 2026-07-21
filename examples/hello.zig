const std = @import("std");
const zigui = @import("zigui");

const Color = zigui.math.Color;
const Rect = zigui.math.Rect;

pub fn main() !void {
    var gpa = std.heap.DebugAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var app = try zigui.app.App.init(allocator, .{
        .title = "Hello zigui",
        .width = 900,
        .height = 640,
    });
    defer app.deinit();

    try app.run(&draw);
}

fn draw(app: *zigui.app.App) void {
    const r = app.getRenderer();
    const fb = app.getFramebufferSize();
    const w: f32 = @floatFromInt(fb.width);
    const h: f32 = @floatFromInt(fb.height);

    // 背景
    r.fillRect(Rect(f32){ .x = 0, .y = 0, .width = w, .height = h }, Color.hex(0x1A1B26FF)) catch {};

    // 标题栏区域
    r.fillRect(Rect(f32){ .x = 0, .y = 0, .width = w, .height = 48 }, Color.hex(0x24283BFF)) catch {};

    // 几个彩色圆角矩形 (模拟按钮/卡片)
    r.fillRoundedRect(Rect(f32){ .x = 40, .y = 80, .width = 200, .height = 120 }, 12, Color.hex(0x7AA2F7FF)) catch {};
    r.fillRoundedRect(Rect(f32){ .x = 280, .y = 80, .width = 200, .height = 120 }, 12, Color.hex(0x9ECE6AFF)) catch {};
    r.fillRoundedRect(Rect(f32){ .x = 520, .y = 80, .width = 200, .height = 120 }, 12, Color.hex(0xF7768EFF)) catch {};

    // 第二行
    r.fillRoundedRect(Rect(f32){ .x = 40, .y = 240, .width = 320, .height = 160 }, 16, Color.hex(0xE0AF68FF)) catch {};
    r.fillRoundedRect(Rect(f32){ .x = 400, .y = 240, .width = 320, .height = 160 }, 16, Color.hex(0xBB9AF7FF)) catch {};

    // 底部状态栏
    r.fillRect(Rect(f32){ .x = 0, .y = h - 32, .width = w, .height = 32 }, Color.hex(0x24283BFF)) catch {};

    // 小圆点装饰
    r.fillRoundedRect(Rect(f32){ .x = 16, .y = 16, .width = 14, .height = 14 }, 7, Color.hex(0xF7768EFF)) catch {};
    r.fillRoundedRect(Rect(f32){ .x = 38, .y = 16, .width = 14, .height = 14 }, 7, Color.hex(0xE0AF68FF)) catch {};
    r.fillRoundedRect(Rect(f32){ .x = 60, .y = 16, .width = 14, .height = 14 }, 7, Color.hex(0x9ECE6AFF)) catch {};
}
