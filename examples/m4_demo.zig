//! zigui M4 示例 - 图像 / 阴影 / 文件拖放 / 手势 / 按需重绘 showcases
//!
//! 交互:
//!   - 拖拽卡片 (鼠标或触摸, DragGesture)
//!   - 滚轮 / 双指捏合缩放 logo (PinchGesture)
//!   - 快速点击卡片闪烁 (TapGesture)
//!   - 从 Finder 拖文件进窗口显示路径 (FileDrop)

const std = @import("std");
const zigui = @import("zigui");
const math = zigui.math;
const pal = zigui.pal;

const logo_png = @embedFile("assets/zigui_logo.png");

const mouse_touch_id = 0xFFFF_FFFF;

const Demo = struct {
    card_x: f32 = 200,
    card_y: f32 = 140,
    card_w: f32 = 320,
    card_h: f32 = 260,
    image_scale: f32 = 1.0,
    flash: u32 = 0, // tap 闪烁剩余帧数
    grabbed: bool = false, // 按压起点在卡片内
    prev_mouse_down: bool = false,
    frame: u64 = 0, // 合成时钟 (60fps 假设, 供 TapGesture 计时)
    dropped_path: [512]u8 = undefined,
    dropped_len: usize = 0,
    logo_tex: ?*anyopaque = null,

    drag: zigui.gesture.DragGesture = .{},
    tap: zigui.gesture.TapGesture = .{},
    pinch: zigui.gesture.PinchGesture = .{},
};

var demo: Demo = .{};

pub fn main() !void {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var app = try zigui.app.App.init(allocator, .{
        .title = "zigui - M4 Demo",
        .width = 720,
        .height = 540,
    });
    defer app.deinit();

    try app.run(&drawFrame);
}

fn drawFrame(app: *zigui.app.App) void {
    const r = app.getRenderer();
    const fb = app.getFramebufferSize();
    const w: f32 = @floatFromInt(fb.width);
    const h: f32 = @floatFromInt(fb.height);

    // ── 输入: 鼠标合成触摸 + 真实触摸统一喂入手势识别器 ──
    const md = app.mouse_down;
    if (md and !demo.prev_mouse_down) {
        feedTouch(.{ .id = mouse_touch_id, .phase = .began, .x = app.mouse_x, .y = app.mouse_y });
    } else if (md and demo.prev_mouse_down) {
        feedTouch(.{ .id = mouse_touch_id, .phase = .moved, .x = app.mouse_x, .y = app.mouse_y });
    } else if (!md and demo.prev_mouse_down) {
        feedTouch(.{ .id = mouse_touch_id, .phase = .ended, .x = app.mouse_x, .y = app.mouse_y });
    }
    demo.prev_mouse_down = md;

    for (app.touchEvents()) |t| feedTouch(t);

    // 滚轮缩放 (触摸设备用双指捏合)
    if (app.scroll_delta != 0) {
        demo.image_scale = clampScale(demo.image_scale * (1.0 + app.scroll_delta * 0.05));
    }

    // 文件拖放
    if (app.file_drop) |fd| {
        const p = fd.pathSlice();
        const n = @min(p.len, demo.dropped_path.len);
        @memcpy(demo.dropped_path[0..n], p[0..n]);
        demo.dropped_len = n;
    }

    // ── 绘制 ──
    r.fillRect(.{ .x = 0, .y = 0, .width = w, .height = h }, math.Color.hex(0x0B1120FF)) catch {};

    const card = cardRect();

    // 阴影 (M4 渲染线)
    r.drawShadow(card, 16, .{
        .color = math.Color.hex(0x000000AA),
        .blur_radius = 28,
        .offset_y = 10,
    }) catch {};

    // 卡片 (tap 闪烁时高亮)
    const card_color: math.Color = if (demo.flash > 0) math.Color.hex(0x3B82F6FF) else math.Color.hex(0x1E293BFF);
    r.fillRoundedRect(card, 16, card_color) catch {};
    r.fillRoundedRect(card, 16, math.Color.hex(0x33415533)) catch {}; // 描边感

    // 图像 (M4 图像管线: PNG 解码 → RGBA 纹理)
    if (demo.logo_tex == null) {
        demo.logo_tex = r.createTextureFromPng(logo_png) catch null;
    }
    if (demo.logo_tex) |tex| {
        const s = 128.0 * demo.image_scale; // logo 64px, 基准 2x 绘制
        const cx = card.x + card.width / 2;
        const cy = card.y + card.height / 2;
        r.drawImage(tex, .{ .x = cx - s / 2, .y = cy - s / 2, .width = s, .height = s }, math.Color.hex(0xFFFFFFFF)) catch {};
    }

    // ── HUD ──
    drawText(app, "zigui M4 Demo", 32, 40, 26.0, 700, 0x38BDF8FF);
    drawText(app, "Drag card | Wheel/Pinch zoom | Tap flash | Drop file here", 32, 84, 15.0, 400, 0x94A3B8FF);

    var buf: [128]u8 = undefined;
    const info = std.fmt.bufPrint(&buf, "scale: {d:.0}%   card: ({d:.0}, {d:.0})", .{
        demo.image_scale * 100,
        card.x,
        card.y,
    }) catch "";
    drawText(app, info, 32, h - 90, 14.0, 400, 0x64748BFF);

    if (demo.dropped_len > 0) {
        drawText(app, "dropped:", 32, h - 60, 14.0, 600, 0x4ADE80FF);
        drawText(app, demo.dropped_path[0..demo.dropped_len], 32, h - 36, 13.0, 400, 0xCBD5E1FF);
    } else {
        drawText(app, "(no file dropped yet)", 32, h - 60, 14.0, 400, 0x475569FF);
    }

    // ── 帧末状态 ──
    if (demo.flash > 0) demo.flash -= 1;
    demo.frame += 1;
}

/// 统一触摸入口: 命中检测 + 三个手势识别器
fn feedTouch(t: pal.event.Touch) void {
    const now_ns = demo.frame * 16_666_667; // 合成时钟

    if (t.phase == .began) {
        demo.grabbed = pointInCard(t.x, t.y);
    }

    if (demo.tap.onTouch(t, now_ns)) |res| {
        if (pointInCard(res.x, res.y)) demo.flash = 20;
    }

    if (demo.drag.onTouch(t)) |res| {
        if (demo.grabbed and !res.ended) {
            demo.card_x += res.dx;
            demo.card_y += res.dy;
        }
        if (res.ended) demo.grabbed = false;
    }

    if (demo.pinch.onTouch(t)) |res| {
        if (!res.ended) {
            demo.image_scale = clampScale(demo.image_scale * res.delta_scale);
        }
    }
}

fn cardRect() math.Rect(f32) {
    return .{ .x = demo.card_x, .y = demo.card_y, .width = demo.card_w, .height = demo.card_h };
}

fn pointInCard(x: f32, y: f32) bool {
    return cardRect().containsPoint(x, y);
}

fn clampScale(s: f32) f32 {
    return std.math.clamp(s, 0.25, 4.0);
}

fn drawText(app: *zigui.app.App, text: []const u8, x: f32, y: f32, size: f32, weight: u16, color: u32) void {
    if (text.len == 0) return;
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
