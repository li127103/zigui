//! zigui M4 示例 - 图像 / 阴影 / 文件拖放 / 手势 / 按需重绘 showcases (跨平台: macOS Metal / Linux Vulkan)
//!
//! 交互:
//!   - 拖拽卡片 (鼠标或触摸, DragGesture)
//!   - 滚轮 / 双指捏合缩放 logo (PinchGesture)
//!   - 快速点击卡片闪烁 (TapGesture)
//!   - 拖文件进窗口显示路径 (FileDrop)
//!
//! 窗口背景与卡片背景 (含阴影 / 圆角 / tap 闪烁高亮) 均为 Widget 背景属性,
//! 由框架在 paintTree 中自动绘制; 卡片描边层 + logo 图像与 HUD 文本由 Canvas 绘制。
//! 卡片位置 (拖拽) 通过每帧更新 layout_style.left/top 表达。

const std = @import("std");
const zigui = @import("zigui");
const math = zigui.math;
const pal = zigui.pal;
const styled_text = zigui.styled_text;

const widget = zigui.widget;
const Container = zigui.container.Container;
const Canvas = zigui.canvas.Canvas;

const App = zigui.app.App;

const logo_png = @embedFile("assets/zigui_logo.png");

const mouse_touch_id = 0xFFFF_FFFF;

/// 主题 (PaintContext 需要 *const Theme)
const theme_dark: zigui.theme.Theme = zigui.theme.dark;

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

// ── 控件树引用 ──────────────────────────────────────────────────────────────

var g_root: ?*Container = null;
var g_tree_alloc: ?std.mem.Allocator = null;
var g_card: ?*Container = null;

/// 窗口尺寸 (供 HUD paint_fn 计算底部文本位置)
var g_win_h: f32 = 0;

pub fn main() !void {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var app = try App.init(allocator, .{
        .title = "zigui - M4 Demo",
        .width = 720,
        .height = 540,
    });
    defer app.deinit();

    try buildTree(allocator);
    defer destroyTree();

    try app.run(&drawFrame);

    styled_text.deinitFontCache();
}

// ── 控件树构建 (窗口 / 卡片背景为 Widget 属性) ──────────────────────────────

fn buildTree(alloc: std.mem.Allocator) !void {
    // 根容器: 窗口背景色
    const root = try Container.create(alloc, .{
        .bg_color = math.Color.hex(0x0B1120FF),
        .direction = .column,
    });
    errdefer root.destroy(alloc);

    // ── 卡片 (背景 + 圆角 + 阴影为 Widget 属性; 绝对定位, left/top 每帧更新为拖拽位置) ──
    const card = try Container.create(alloc, .{
        .bg_color = math.Color.hex(0x1E293BFF),
        .corner_radius = 16,
        .direction = .column,
        .width = .{ .px = demo.card_w },
        .height = .{ .px = demo.card_h },
    });
    card.base.background.shadow_color = math.Color.hex(0x000000AA);
    card.base.background.shadow_blur = 28;
    card.base.background.shadow_offset_y = 10;
    card.base.layout_style.position = .absolute;
    card.base.layout_style.left = demo.card_x;
    card.base.layout_style.top = demo.card_y;
    try root.base.addChild(alloc, &card.base);

    // 卡片内容: 描边层 + logo 图像 (Canvas 绘制)
    const logo_canvas = try Canvas.create(alloc, .{ .paint_fn = paintLogo });
    logo_canvas.base.layout_style.width = .{ .auto = {} };
    logo_canvas.base.layout_style.height = .{ .auto = {} };
    logo_canvas.base.layout_style.flex_grow = 1;
    try card.base.addChild(alloc, &logo_canvas.base);

    // ── HUD (绝对定位全屏 Canvas: 标题 + 信息文本) ──
    const hud = try Canvas.create(alloc, .{ .paint_fn = paintHud });
    hud.base.layout_style.position = .absolute;
    hud.base.layout_style.top = 0;
    hud.base.layout_style.left = 0;
    hud.base.layout_style.width = .{ .percent = 100 };
    hud.base.layout_style.height = .{ .percent = 100 };
    try root.base.addChild(alloc, &hud.base);

    g_root = root;
    g_tree_alloc = alloc;
    g_card = card;
}

fn destroyTree() void {
    if (g_root) |root| {
        root.destroy(g_tree_alloc orelse return);
        g_root = null;
    }
}

// ── 每帧: 手势输入 + 动态属性 + 布局 + 绘制 (背景由框架自动绘制) ────────────

fn drawFrame(app: *App) void {
    const root = g_root orelse return;
    const fb = app.getFramebufferSize();
    const w: f32 = @floatFromInt(fb.width);
    const h: f32 = @floatFromInt(fb.height);
    g_win_h = h;

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

    root.base.layout_style.width = .{ .px = w };
    root.base.layout_style.height = .{ .px = h };

    // ── 每帧更新卡片动态属性: 位置 (拖拽) + 背景色 (tap 闪烁) ──
    if (g_card) |card| {
        card.base.layout_style.left = demo.card_x;
        card.base.layout_style.top = demo.card_y;
        card.base.background.bg = .{ .color = if (demo.flash > 0) math.Color.hex(0x3B82F6FF) else math.Color.hex(0x1E293BFF) };
    }

    var ctx = widget.PaintContext{
        .renderer = app.getRenderer(),
        .theme = &theme_dark,
        .allocator = app.allocator,
    };

    root.base.performLayout(&ctx, .{ .max_width = w, .max_height = h });
    root.base.paintTree(&ctx);

    // ── 帧末状态 ──
    if (demo.flash > 0) demo.flash -= 1;
    demo.frame += 1;
}

// ── Canvas 内容绘制 (背景由框架自动绘制) ────────────────────────────────────

/// 卡片内容: 描边层 + logo 图像 (PNG 解码 → RGBA 纹理)
fn paintLogo(w: *widget.Widget, ctx: *widget.PaintContext) void {
    const ax = ctx.offset_x + w.rect.x;
    const ay = ctx.offset_y + w.rect.y;
    const cw = w.rect.width;
    const ch = w.rect.height;
    const r = ctx.renderer;

    // 描边感 (半透明覆盖层)
    r.fillRoundedRect(.{ .x = ax, .y = ay, .width = cw, .height = ch }, 16, math.Color.hex(0x33415533)) catch {};

    // 图像 (M4 图像管线)
    if (demo.logo_tex == null) {
        demo.logo_tex = r.createTextureFromPng(logo_png) catch null;
    }
    if (demo.logo_tex) |tex| {
        const s = 128.0 * demo.image_scale; // logo 64px, 基准 2x 绘制
        const cx = ax + cw / 2;
        const cy = ay + ch / 2;
        r.drawImage(tex, .{ .x = cx - s / 2, .y = cy - s / 2, .width = s, .height = s }, math.Color.hex(0xFFFFFFFF)) catch {};
    }
}

/// HUD: 标题 + 操作提示 + 状态信息 + 拖放路径
fn paintHud(w: *widget.Widget, ctx: *widget.PaintContext) void {
    _ = w;
    const h = g_win_h;

    drawTextCtx(ctx, "zigui M4 Demo", 32, 40, 26.0, 700, 0x38BDF8FF);
    drawTextCtx(ctx, "Drag card | Wheel/Pinch zoom | Tap flash | Drop file here", 32, 84, 15.0, 400, 0x94A3B8FF);

    var buf: [128]u8 = undefined;
    const info = std.fmt.bufPrint(&buf, "scale: {d:.0}%   card: ({d:.0}, {d:.0})", .{
        demo.image_scale * 100,
        demo.card_x,
        demo.card_y,
    }) catch "";
    drawTextCtx(ctx, info, 32, h - 90, 14.0, 400, 0x64748BFF);

    if (demo.dropped_len > 0) {
        drawTextCtx(ctx, "dropped:", 32, h - 60, 14.0, 600, 0x4ADE80FF);
        drawTextCtx(ctx, demo.dropped_path[0..demo.dropped_len], 32, h - 36, 13.0, 400, 0xCBD5E1FF);
    } else {
        drawTextCtx(ctx, "(no file dropped yet)", 32, h - 60, 14.0, 400, 0x475569FF);
    }
}

// ── 手势 / 辅助 ─────────────────────────────────────────────────────────────

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

fn drawTextCtx(ctx: *widget.PaintContext, text: []const u8, x: f32, y: f32, size: f32, weight: u16, color: u32) void {
    if (text.len == 0) return;
    styled_text.drawText(
        ctx.renderer,
        ctx.allocator,
        text,
        x,
        y,
        .{ .font_size = size, .font_weight = weight, .color = math.Color.hex(color) },
    );
}
