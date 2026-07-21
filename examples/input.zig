//! zigui 输入框示例 - 文本输入 / 光标 / 焦点 / 提交 (Linux Vulkan + FreeType)
//!
//! 演示:
//!   - 两个输入框 (Name / Email), 点击切换焦点
//!   - 键盘输入 (UTF-8), Backspace 删除, Tab 切换, Enter 提交, Esc 清空
//!   - 聚焦边框高亮 + 闪烁光标 + placeholder
//!   - 提交结果实时回显

const std = @import("std");
const zigui = @import("zigui");
const math = zigui.math;
const pal = zigui.pal;

const App = zigui.app.App;

// ── 全局状态 (drawFrame 回调只能拿到 App, 状态放全局) ────────────────────────

const MAX_TEXT = 128;

/// 简单的 UTF-8 文本缓冲 (定长, 免分配器)
const TextBuf = struct {
    bytes: [MAX_TEXT]u8 = undefined,
    len: usize = 0,

    fn slice(self: *const TextBuf) []const u8 {
        return self.bytes[0..self.len];
    }

    fn clear(self: *TextBuf) void {
        self.len = 0;
    }

    /// 追加一个 codepoint (编码为 UTF-8)
    fn appendCp(self: *TextBuf, cp: u21) void {
        var tmp: [4]u8 = undefined;
        const n = std.unicode.utf8Encode(cp, &tmp) catch return;
        if (self.len + n > self.bytes.len) return; // 缓冲满, 忽略
        @memcpy(self.bytes[self.len .. self.len + n], tmp[0..n]);
        self.len += n;
    }

    /// 删除末尾一个 codepoint (可能占 1~4 字节)
    fn popLastCp(self: *TextBuf) void {
        if (self.len == 0) return;
        var i = self.len - 1;
        // 回退跳过 UTF-8 连续字节 (10xxxxxx)
        while (i > 0 and (self.bytes[i] & 0xC0) == 0x80) : (i -= 1) {}
        self.len = i;
    }

    /// 追加一段 UTF-8 字节 (IME 提交的文本已是 UTF-8)
    fn appendBytes(self: *TextBuf, bytes: []const u8) void {
        const n = @min(bytes.len, self.bytes.len - self.len);
        @memcpy(self.bytes[self.len .. self.len + n], bytes[0..n]);
        self.len += n;
    }

    /// 从末尾删除 n 个 codepoint (IME delete_surrounding_text)
    fn popNCps(self: *TextBuf, n: usize) void {
        var i: usize = 0;
        while (i < n) : (i += 1) self.popLastCp();
    }
};

var g_fields: [2]TextBuf = .{ .{}, .{} };
var g_focused: ?usize = 0; // 初始聚焦第一个输入框
var g_sub_name: TextBuf = .{};
var g_sub_email: TextBuf = .{};
var g_has_submitted: bool = false;
var g_frame: u32 = 0;
var g_ime_rect_focus: ?usize = null; // 已为其设置 IME 光标矩形的字段索引

// ── 布局 ────────────────────────────────────────────────────────────────────

const Layout = struct {
    card: math.Rect(f32),
    fields: [2]math.Rect(f32),
    submit: math.Rect(f32),
    result: math.Rect(f32),
    pad: f32,
};

fn computeLayout(w: f32, h: f32) Layout {
    _ = h;
    const card_w = @min(w - 80.0, 540.0);
    const card_x = (w - card_w) / 2.0;
    const card_y = 56.0;
    const card_h = 326.0;
    const pad: f32 = 30.0;
    const inner_w = card_w - pad * 2.0;

    return .{
        .card = .{ .x = card_x, .y = card_y, .width = card_w, .height = card_h },
        .fields = .{
            .{ .x = card_x + pad, .y = card_y + 102, .width = inner_w, .height = 42 },
            .{ .x = card_x + pad, .y = card_y + 182, .width = inner_w, .height = 42 },
        },
        .submit = .{ .x = card_x + pad, .y = card_y + 246, .width = inner_w, .height = 40 },
        .result = .{ .x = card_x, .y = card_y + card_h + 18, .width = card_w, .height = 96 },
        .pad = pad,
    };
}

fn rectContains(r: math.Rect(f32), x: f32, y: f32) bool {
    return x >= r.x and x <= r.x + r.width and y >= r.y and y <= r.y + r.height;
}

// ── 入口 ────────────────────────────────────────────────────────────────────

pub fn main() !void {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var app = try App.init(allocator, .{
        .title = "zigui - Input Demo",
        .width = 720,
        .height = 600,
    });
    defer app.deinit();

    try app.run(&drawFrame);

    deinitFontCache();
}

// ── 每帧: 输入处理 + 渲染 ───────────────────────────────────────────────────

fn drawFrame(app: *App) void {
    g_frame += 1;

    const fb = app.getFramebufferSize();
    const w: f32 = @floatFromInt(fb.width);
    const h: f32 = @floatFromInt(fb.height);
    const lay = computeLayout(w, h);

    // ── 输入处理 ──
    handleInput(app, lay);

    // ── IME 光标矩形: 焦点变化时更新, 供输入法候选窗定位 ──
    if (g_focused != g_ime_rect_focus) {
        g_ime_rect_focus = g_focused;
        if (g_focused) |f| {
            const fr = lay.fields[f];
            app.setImeCursorRect(
                @intFromFloat(fr.x),
                @intFromFloat(fr.y + fr.height),
                @intFromFloat(fr.width),
                @intFromFloat(fr.height),
            );
        }
    }

    // ── 渲染 ──
    const r = app.getRenderer();

    // 背景
    r.fillRect(.{ .x = 0, .y = 0, .width = w, .height = h }, math.Color.hex(0x0F172AFF)) catch {};

    // 卡片 + 阴影
    r.drawShadow(lay.card, 16, .{}) catch {};
    r.fillRoundedRect(lay.card, 16, math.Color.hex(0x1E293BFF)) catch {};

    // 标题
    const cx = lay.card.x + lay.pad;
    drawText(app, "Create Account", cx, lay.card.y + 24, 20.0, 700, 0xF8FAFCFF);
    drawText(app, "Fill in the form below, then press Enter or click Submit.", cx, lay.card.y + 54, 12.5, 400, 0x94A3B8FF);

    // 两个输入框
    const labels = [_][]const u8{ "Name", "Email" };
    const placeholders = [_][]const u8{ "Enter your name", "you@example.com" };
    const preedit = app.preeditText();
    for (0..2) |i| {
        drawLabel(app, labels[i], cx, lay.fields[i].y - 20, 12.5, 0xCBD5E1FF);
        const field_preedit = if (g_focused == i) preedit else "";
        drawField(app, lay.fields[i], g_fields[i].slice(), placeholders[i], g_focused == i, field_preedit);
    }

    // 提交按钮
    const hovered = rectContains(lay.submit, app.mouse_x, app.mouse_y);
    const btn_color: u32 = if (hovered) 0x2563EBFF else 0x3B82F6FF;
    r.fillRoundedRect(lay.submit, 10, math.Color.hex(btn_color)) catch {};
    drawTextCentered(app, "Submit", lay.submit.x, lay.submit.y, lay.submit.width, lay.submit.height, 15.0, 600, 0xFFFFFFFF);

    // 操作提示
    drawText(app, "Tab: switch field    Backspace: delete    Enter: submit    Esc: clear", cx, lay.card.y + 300, 11.0, 400, 0x64748BFF);

    // 提交结果回显
    drawResult(app, lay.result);
}

fn handleInput(app: *App, lay: Layout) void {
    // 控制键
    if (app.key_hit) |key| {
        switch (key) {
            .tab => {
                g_focused = if (g_focused) |f| (f + 1) % 2 else 0;
            },
            .escape => {
                if (g_focused) |f| g_fields[f].clear();
                g_focused = null;
            },
            .backspace => {
                if (g_focused) |f| g_fields[f].popLastCp();
            },
            .enter, .kp_enter => doSubmit(),
            else => {},
        }
    }

    // 文本输入 (仅插入到聚焦的输入框)
    if (g_focused) |f| {
        // IME 删除光标前文本 (先于提交处理, 符合协议顺序)
        if (app.takeImeDelete()) |d| {
            g_fields[f].popNCps(d.before);
        }
        // IME 提交文本 (中文等, 已是 UTF-8)
        const commit = app.imeCommitText();
        if (commit.len > 0) {
            g_fields[f].appendBytes(commit);
        }
        // 普通键盘输入 (ASCII)
        for (app.typedCodepoints()) |cp| {
            g_fields[f].appendCp(cp);
        }
    }

    // 点击: 聚焦输入框 / 提交 / 失焦
    if (app.mouse_clicked) {
        var hit_field = false;
        for (0..2) |i| {
            if (rectContains(lay.fields[i], app.mouse_x, app.mouse_y)) {
                g_focused = i;
                hit_field = true;
            }
        }
        if (!hit_field) {
            if (rectContains(lay.submit, app.mouse_x, app.mouse_y)) {
                doSubmit();
            } else {
                g_focused = null;
            }
        }
    }
}

fn doSubmit() void {
    g_sub_name = g_fields[0];
    g_sub_email = g_fields[1];
    g_has_submitted = true;
}

// ── 绘制辅助 ────────────────────────────────────────────────────────────────

/// 绘制单个输入框 (背景 / 边框 / placeholder / 文本 / preedit / 光标)
fn drawField(app: *App, rect: math.Rect(f32), text: []const u8, placeholder: []const u8, focused: bool, preedit: []const u8) void {
    const r = app.getRenderer();

    // 边框 (聚焦时高亮): 先画外框再画内框
    const border_color: u32 = if (focused) 0x3B82F6FF else 0x334155FF;
    r.fillRoundedRect(rect, 10, math.Color.hex(border_color)) catch {};
    const inner = math.Rect(f32){
        .x = rect.x + 1.5,
        .y = rect.y + 1.5,
        .width = rect.width - 3.0,
        .height = rect.height - 3.0,
    };
    r.fillRoundedRect(inner, 9, math.Color.hex(0x0F172AFF)) catch {};

    const pad: f32 = 14.0;
    const text_x = inner.x + pad;
    const max_w = inner.width - pad * 2.0;

    // 垂直居中: drawText 的 y 是基线, 文本视觉中心 = 基线 + (descent - ascent)/2,
    // 令其等于输入框中心 => 基线 = rect.y + (rect.height + ascent - descent)/2
    const font_size: f32 = 15.0;
    const fm = if (getFont(app.allocator, font_size, 400)) |f| f.getMetrics() else null;
    const ascent: f32 = if (fm) |m| m.ascent else font_size * 0.75;
    const descent: f32 = if (fm) |m| m.descent else font_size * 0.25;
    const text_y = rect.y + (rect.height + ascent - descent) / 2.0;

    if (text.len == 0 and preedit.len == 0) {
        // placeholder
        _ = drawClippedText(app, placeholder, text_x, text_y, font_size, 400, 0x64748BFF, max_w);
    } else {
        // 已提交文本
        const committed_w = drawClippedText(app, text, text_x, text_y, font_size, 400, 0xF8FAFCFF, max_w);
        // 组合中 (preedit) 文本: 接在已提交文本后, 浅色显示
        if (preedit.len > 0) {
            const remaining = max_w - committed_w;
            if (remaining > 0) {
                _ = drawClippedText(app, preedit, text_x + committed_w, text_y, font_size, 400, 0x93C5FDFF, remaining);
            }
        }
    }

    // 聚焦时绘制光标: 组合中常亮于 preedit 末尾, 否则闪烁于已提交文本末尾
    if (focused) {
        const composing = preedit.len > 0;
        const blink_on = composing or (g_frame / 30) % 2 == 0;
        if (blink_on) {
            const text_w = measureText(app, text, font_size, 400);
            const preedit_w = measureText(app, preedit, font_size, 400);
            const cursor_x = text_x + @min(text_w + preedit_w, max_w);
            r.fillRect(.{ .x = cursor_x, .y = rect.y + 9, .width = 2, .height = rect.height - 18 }, math.Color.hex(0xF8FAFCFF)) catch {};
        }
    }
}

/// 绘制提交结果卡片
fn drawResult(app: *App, rect: math.Rect(f32)) void {
    const r = app.getRenderer();

    if (!g_has_submitted) {
        r.fillRoundedRect(rect, 12, math.Color.hex(0x1E293B80)) catch {};
        drawTextCentered(app, "Nothing submitted yet.", rect.x, rect.y, rect.width, rect.height, 13.0, 400, 0x64748BFF);
        return;
    }

    r.fillRoundedRect(rect, 12, math.Color.hex(0x14532D66)) catch {};
    r.fillRoundedRect(.{ .x = rect.x, .y = rect.y, .width = 4, .height = rect.height }, 2, math.Color.hex(0x22C55EFF)) catch {};

    const tx = rect.x + 20.0;
    drawText(app, "Submitted", tx, rect.y + 14, 13.0, 700, 0x4ADE80FF);
    drawText(app, g_sub_name.slice(), tx, rect.y + 38, 14.0, 500, 0xF8FAFCFF);
    drawText(app, g_sub_email.slice(), tx, rect.y + 62, 13.0, 400, 0xCBD5E1FF);
}

// ── 文本渲染 (Linux Vulkan + FreeType, 缓存 CJK 字体) ─────────────────────

/// 字体缓存项 (按 size+weight 缓存, 避免每帧重载 8MB CJK 字体)
const CachedFont = struct {
    size: f32,
    weight: u16,
    font: zigui.freetype.FtFont,
};

const MAX_CACHED_FONTS = 16;
var g_font_cache: [MAX_CACHED_FONTS]CachedFont = undefined;
var g_font_cache_len: usize = 0;
var g_font_path: ?[:0]u8 = null;
var g_font_allocator: ?std.mem.Allocator = null;

/// 解析字体路径: 优先 CJK 字体 (同时覆盖中英文), 回退普通系统字体
fn resolveFontPath(allocator: std.mem.Allocator) ?[:0]const u8 {
    if (g_font_path) |p| return p;
    const freetype = zigui.freetype;
    if (freetype.findCjkFont(allocator)) |p| {
        g_font_path = p;
        return p;
    } else |_| {}
    if (freetype.findSystemFont(allocator, null)) |p| {
        g_font_path = p;
        return p;
    } else |_| {}
    return null;
}

/// 获取 (size, weight) 对应的缓存字体
fn getFont(allocator: std.mem.Allocator, size: f32, weight: u16) ?*zigui.freetype.FtFont {
    for (g_font_cache[0..g_font_cache_len]) |*entry| {
        if (entry.size == size and entry.weight == weight) return &entry.font;
    }
    if (g_font_cache_len >= MAX_CACHED_FONTS) return null;
    const path = resolveFontPath(allocator) orelse return null;
    const font = zigui.freetype.FtFont.createFromFile(allocator, path.ptr, size, weight) catch return null;
    g_font_cache[g_font_cache_len] = .{ .size = size, .weight = weight, .font = font };
    g_font_cache_len += 1;
    return &g_font_cache[g_font_cache_len - 1].font;
}

/// 释放字体缓存 (退出前调用)
fn deinitFontCache() void {
    for (g_font_cache[0..g_font_cache_len]) |*entry| {
        entry.font.destroy();
    }
    g_font_cache_len = 0;
    if (g_font_path) |p| {
        if (g_font_allocator) |a| a.free(p);
        g_font_path = null;
    }
}

fn drawLabel(app: *App, text: []const u8, x: f32, y: f32, size: f32, color: u32) void {
    drawText(app, text, x, y, size, 500, color);
}

fn drawText(app: *App, text: []const u8, x: f32, y: f32, size: f32, weight: u16, color: u32) void {
    _ = drawClippedText(app, text, x, y, size, weight, color, std.math.inf(f32));
}

fn drawTextCentered(app: *App, text: []const u8, x: f32, y: f32, cw: f32, ch: f32, size: f32, weight: u16, color: u32) void {
    const text_w = measureText(app, text, size, weight);
    const tx = x + (cw - text_w) / 2.0;
    const ty = y + (ch - size) / 2.0;
    drawText(app, text, tx, ty, size, weight, color);
}

/// 测量文本宽度
fn measureText(app: *App, text: []const u8, size: f32, weight: u16) f32 {
    if (text.len == 0) return 0;
    g_font_allocator = app.allocator;
    const font = getFont(app.allocator, size, weight) orelse return 0;
    return font.measureText(text);
}

/// 绘制文本, 超出 max_width 的 glyph 不绘制; 返回实际绘制宽度
fn drawClippedText(app: *App, text: []const u8, x: f32, y: f32, size: f32, weight: u16, color: u32, max_width: f32) f32 {
    if (text.len == 0) return 0;

    const vulkan_renderer = zigui.vulkan_renderer;

    g_font_allocator = app.allocator;
    const font = getFont(app.allocator, size, weight) orelse return 0;

    var shaped: [512]zigui.freetype.ShapedGlyph = undefined;
    const glyph_count = font.shapeText(text, &shaped);
    if (glyph_count == 0) return 0;

    var placed: [512]vulkan_renderer.PlacedGlyph = undefined;
    var pen_x: f32 = 0;
    var placed_count: usize = 0;

    const atlas = app.getGlyphAtlas();
    const device = app.getVulkanDevice();

    for (0..glyph_count) |i| {
        const sg = shaped[i];
        if (pen_x + sg.x_advance > max_width) break; // 裁剪: 超出宽度停止
        const entry = atlas.getOrRasterize(device, font, sg.glyph_id, size) catch continue;
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

    if (placed_count == 0) return 0;
    app.getRenderer().drawText(placed[0..placed_count], x, y, math.Color.hex(color)) catch {};
    return pen_x;
}
