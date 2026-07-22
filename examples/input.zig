//! zigui 输入框示例 - 文本输入 / 光标 / 焦点 / 鼠标选择 / IME / 提交 (跨平台: macOS Metal / Linux Vulkan)
//!
//! 演示:
//!   - 两个输入框 (Name / Email), 点击切换焦点
//!   - 鼠标点击定位光标, 拖拽选择文本 (选区高亮)
//!   - 键盘输入 (UTF-8), Backspace 删除, Tab 切换, Enter 提交, Esc 清空
//!   - IME 中文输入 (preedit 组合文本 + 提交)
//!   - 聚焦边框高亮 + 闪烁光标 + placeholder
//!   - 提交结果实时回显
//!
//! 所有背景 (窗口 / 表单卡片+阴影 / 输入框边框 / 提交按钮 / 结果卡片) 均为 Widget
//! 背景属性, 由框架在 paintTree 中自动绘制, 示例代码不再手动 fillRect 背景。
//! 输入框内容 (文本 / preedit / 光标) 与结果卡片内容由 Canvas paint_fn 绘制。

const std = @import("std");
const zigui = @import("zigui");
const math = zigui.math;
const styled_text = zigui.styled_text;

const widget = zigui.widget;
const Container = zigui.container.Container;
const Label = zigui.label.Label;
const Canvas = zigui.canvas.Canvas;

const App = zigui.app.App;

/// 主题 (PaintContext 需要 *const Theme)
const theme_dark: zigui.theme.Theme = zigui.theme.dark;

// ── 全局状态 (drawFrame 回调只能拿到 App, 状态放全局) ────────────────────────

const MAX_TEXT = 128;

/// 简单的 UTF-8 文本缓冲 (定长, 免分配器; 支持光标位置插入/删除)
const TextBuf = struct {
    bytes: [MAX_TEXT]u8 = undefined,
    len: usize = 0,

    fn slice(self: *const TextBuf) []const u8 {
        return self.bytes[0..self.len];
    }

    fn clear(self: *TextBuf) void {
        self.len = 0;
    }

    /// 在指定字节偏移处插入一个 codepoint
    fn insertCpAt(self: *TextBuf, pos: usize, cp: u21) usize {
        var tmp: [4]u8 = undefined;
        const n = std.unicode.utf8Encode(cp, &tmp) catch return pos;
        return self.insertBytesAt(pos, tmp[0..n]);
    }

    /// 在指定字节偏移处插入 UTF-8 字节, 返回新偏移
    fn insertBytesAt(self: *TextBuf, pos: usize, data: []const u8) usize {
        const n = @min(data.len, self.bytes.len - self.len);
        if (n == 0) return pos;
        std.mem.copyBackwards(u8, self.bytes[pos + n .. self.len + n], self.bytes[pos..self.len]);
        @memcpy(self.bytes[pos .. pos + n], data[0..n]);
        self.len += n;
        return pos + n;
    }

    /// 删除字节范围 [start, end), 返回 start
    fn deleteRange(self: *TextBuf, start: usize, end: usize) usize {
        const s = @min(start, self.len);
        const e = @min(end, self.len);
        if (e <= s) return s;
        std.mem.copyForwards(u8, self.bytes[s .. self.len - (e - s)], self.bytes[e..self.len]);
        self.len -= e - s;
        return s;
    }

    /// 删除 pos 前一个 codepoint, 返回新位置
    fn deleteCpBefore(self: *TextBuf, pos: usize) usize {
        if (pos == 0) return 0;
        var i = pos - 1;
        while (i > 0 and (self.bytes[i] & 0xC0) == 0x80) : (i -= 1) {}
        return self.deleteRange(i, pos);
    }

    /// 删除 pos 前 n 个 codepoint (IME delete_surrounding_text), 返回新位置
    fn deleteNCpsBefore(self: *TextBuf, pos: usize, n: usize) usize {
        var p = pos;
        var i: usize = 0;
        while (i < n) : (i += 1) p = self.deleteCpBefore(p);
        return p;
    }
};

var g_fields: [2]TextBuf = .{ .{}, .{} };
var g_cursors: [2]usize = .{ 0, 0 }; // 光标字节偏移
var g_sel_anchors: [2]?usize = .{ null, null }; // 选区锚点 (null = 无选区)
var g_drag_field: ?usize = null; // 正在拖拽选择的字段
var g_focused: ?usize = 0;
var g_sub_name: TextBuf = .{};
var g_sub_email: TextBuf = .{};
var g_has_submitted: bool = false;
var g_frame: u32 = 0;
var g_ime_rect_focus: ?usize = null;
/// 本帧 IME 组合文本 (drawFrame 中自 app.preeditText() 更新, 供 Canvas paint_fn 读取)
var g_preedit: []const u8 = "";

const placeholders = [_][]const u8{ "Enter your name", "you@example.com" };

// ── 控件树引用 (供每帧更新动态属性 / 输入命中检测) ──────────────────────────

var g_root: ?*Container = null;
var g_tree_alloc: ?std.mem.Allocator = null;
var g_form_card: ?*Container = null;
var g_result_card: ?*Container = null;
var g_field_outers: [2]?*Container = .{ null, null };
var g_submit_btn: ?*Container = null;

// ── 布局常量 (表单卡 / 结果卡几何) ──────────────────────────────────────────

const card_y: f32 = 56.0;
const card_h: f32 = 326.0;
const result_top: f32 = card_y + card_h + 18.0;
const result_h: f32 = 96.0;

fn rectContains(r: math.Rect(f32), x: f32, y: f32) bool {
    return x >= r.x and x <= r.x + r.width and y >= r.y and y <= r.y + r.height;
}

/// 字段选区字节范围 [start, end); 无选区返回 null
fn fieldSelRange(idx: usize) ?struct { usize, usize } {
    const anchor = g_sel_anchors[idx] orelse return null;
    const cursor = g_cursors[idx];
    if (anchor == cursor) return null;
    return if (anchor < cursor) .{ anchor, cursor } else .{ cursor, anchor };
}

/// 删除字段选中文本, 光标置于起点
fn deleteFieldSelection(idx: usize) void {
    if (fieldSelRange(idx)) |sel| {
        g_cursors[idx] = g_fields[idx].deleteRange(sel[0], sel[1]);
    }
    g_sel_anchors[idx] = null;
}

/// 根据鼠标 X 坐标计算光标字节偏移 (精确文本测量, UTF-8 感知)
fn cursorAtX(alloc: std.mem.Allocator, text: []const u8, rel_x: f32) usize {
    const style = styled_text.TextStyle{ .font_size = 15.0, .font_weight = 400 };
    var best: usize = 0;
    var best_dist: f32 = std.math.floatMax(f32);
    var i: usize = 0;
    while (true) {
        const w = styled_text.measureTextWidth(alloc, text[0..i], style);
        const d = @abs(w - rel_x);
        if (d < best_dist) {
            best_dist = d;
            best = i;
        }
        if (i >= text.len) break;
        i += 1;
        while (i < text.len and (text[i] & 0xC0) == 0x80) i += 1;
    }
    return best;
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

    try buildTree(allocator);
    defer destroyTree();

    try app.run(&drawFrame);

    styled_text.deinitFontCache();
}

// ── 控件树构建 (背景全部为 Widget 属性) ─────────────────────────────────────

fn buildTree(alloc: std.mem.Allocator) !void {
    // 根容器: 窗口背景色
    const root = try Container.create(alloc, .{
        .bg_color = math.Color.hex(0x0F172AFF),
        .direction = .column,
    });
    errdefer root.destroy(alloc);

    // ── 表单卡片 (背景 + 圆角 + 阴影为 Widget 属性; 绝对定位, left 每帧更新以水平居中) ──
    const form = try Container.create(alloc, .{
        .bg_color = math.Color.hex(0x1E293BFF),
        .corner_radius = 16,
        .direction = .column,
        .height = .{ .px = card_h },
        .padding = .{ .left = 30, .top = 24, .right = 30, .bottom = 0 },
    });
    form.base.background.shadow_color = math.Color.rgba(0, 0, 0, 140);
    form.base.background.shadow_blur = 16;
    form.base.background.shadow_offset_y = 6;
    form.base.layout_style.position = .absolute;
    form.base.layout_style.top = card_y;
    try root.base.addChild(alloc, &form.base);

    // 标题 + 副标题
    const title = try Label.create(alloc, "Create Account", .{
        .font_size = 20,
        .font_weight = 700,
        .color = math.Color.hex(0xF8FAFCFF),
    });
    try form.base.addChild(alloc, &title.base);

    const subtitle = try Label.create(alloc, "Fill in the form below, then press Enter or click Submit.", .{
        .font_size = 12.5,
        .font_weight = 400,
        .color = math.Color.hex(0x94A3B8FF),
    });
    subtitle.base.layout_style.margin.top = 6;
    try form.base.addChild(alloc, &subtitle.base);

    // 两个输入框 (字段标签 + 字段)
    try addFieldLabel(form, alloc, "Name", 13);
    try addField(form, alloc, 0, paintField0, 5);
    try addFieldLabel(form, alloc, "Email", 18);
    try addField(form, alloc, 1, paintField1, 5);

    // 提交按钮 (背景 = hover 色, 每帧更新)
    const submit = try Container.create(alloc, .{
        .bg_color = math.Color.hex(0x3B82F6FF),
        .corner_radius = 10,
        .direction = .column,
        .height = .{ .px = 40 },
    });
    submit.base.layout_style.margin.top = 22;
    try form.base.addChild(alloc, &submit.base);

    const submit_label = try Label.create(alloc, "Submit", .{
        .font_size = 15,
        .font_weight = 600,
        .color = math.Color.hex(0xFFFFFFFF),
        .text_align = .center,
    });
    submit_label.base.layout_style.margin.top = 11;
    try submit.base.addChild(alloc, &submit_label.base);

    // 操作提示
    const hint = try Label.create(alloc, "Tab: switch field    Backspace: delete    Enter: submit    Esc: clear", .{
        .font_size = 11,
        .font_weight = 400,
        .color = math.Color.hex(0x64748BFF),
    });
    hint.base.layout_style.margin.top = 14;
    try form.base.addChild(alloc, &hint.base);

    // ── 结果卡片 (背景随提交状态动态切换; 绝对定位于表单卡下方) ──
    const result = try Container.create(alloc, .{
        .bg_color = math.Color.hex(0x1E293B80),
        .corner_radius = 12,
        .direction = .column,
        .height = .{ .px = result_h },
    });
    result.base.layout_style.position = .absolute;
    result.base.layout_style.top = result_top;
    try root.base.addChild(alloc, &result.base);

    const result_canvas = try Canvas.create(alloc, .{ .paint_fn = paintResult });
    result_canvas.base.layout_style.width = .{ .auto = {} };
    result_canvas.base.layout_style.height = .{ .px = result_h };
    try result.base.addChild(alloc, &result_canvas.base);

    g_root = root;
    g_tree_alloc = alloc;
    g_form_card = form;
    g_result_card = result;
    g_submit_btn = submit;
}

/// 字段标签 (Name / Email)
fn addFieldLabel(parent: *Container, alloc: std.mem.Allocator, text: []const u8, margin_top: f32) !void {
    const lbl = try Label.create(alloc, text, .{
        .font_size = 12.5,
        .font_weight = 500,
        .color = math.Color.hex(0xCBD5E1FF),
    });
    lbl.base.layout_style.margin.top = margin_top;
    try parent.base.addChild(alloc, &lbl.base);
}

/// 输入框: 外层 Container 背景 = 边框色 (聚焦时每帧切换), 内层 Canvas 背景 =
/// 字段填充色, 内容 (文本 / preedit / 光标) 由 paint_fn 绘制。
fn addField(parent: *Container, alloc: std.mem.Allocator, idx: usize, paint_fn: *const fn (w: *widget.Widget, ctx: *widget.PaintContext) void, margin_top: f32) !void {
    const outer = try Container.create(alloc, .{
        .bg_color = math.Color.hex(0x334155FF), // 边框色 (未聚焦)
        .corner_radius = 10,
        .direction = .column,
        .height = .{ .px = 42 },
        .padding = math.EdgeInsets.all(1.5),
    });
    outer.base.layout_style.margin.top = margin_top;
    try parent.base.addChild(alloc, &outer.base);

    const inner = try Canvas.create(alloc, .{
        .bg_color = math.Color.hex(0x0F172AFF),
        .corner_radius = 9,
        .paint_fn = paint_fn,
    });
    inner.base.layout_style.width = .{ .auto = {} }; // 撑满外层内宽
    inner.base.layout_style.height = .{ .px = 39 }; // 42 - 1.5 * 2
    try outer.base.addChild(alloc, &inner.base);

    g_field_outers[idx] = outer;
}

fn destroyTree() void {
    if (g_root) |root| {
        root.destroy(g_tree_alloc orelse return);
        g_root = null;
    }
}

// ── 每帧: 布局 + 输入处理 + 动态属性 + 绘制 (背景由框架自动绘制) ────────────

fn drawFrame(app: *App) void {
    g_frame += 1;
    const root = g_root orelse return;
    const fb = app.getFramebufferSize();
    const w: f32 = @floatFromInt(fb.width);
    const h: f32 = @floatFromInt(fb.height);

    // 表单卡水平居中 (卡宽随窗口自适应)
    const card_w = @min(w - 80.0, 540.0);
    const card_x = (w - card_w) / 2.0;

    root.base.layout_style.width = .{ .px = w };
    root.base.layout_style.height = .{ .px = h };
    if (g_form_card) |fc| {
        fc.base.layout_style.left = card_x;
        fc.base.layout_style.width = .{ .px = card_w };
    }
    if (g_result_card) |rc| {
        rc.base.layout_style.left = card_x;
        rc.base.layout_style.width = .{ .px = card_w };
    }

    var ctx = widget.PaintContext{
        .renderer = app.getRenderer(),
        .theme = &theme_dark,
        .allocator = app.allocator,
    };

    // 先布局 (输入处理依赖各控件的绝对矩形)
    root.base.performLayout(&ctx, .{ .max_width = w, .max_height = h });

    handleInput(app);
    updateImeRect(app);

    // ── 每帧更新动态背景属性 ──
    g_preedit = app.preeditText();

    // 输入框聚焦边框色
    for (0..2) |i| {
        if (g_field_outers[i]) |fo| {
            const c: u32 = if (g_focused == i) 0x3B82F6FF else 0x334155FF;
            fo.base.background.bg = .{ .color = math.Color.hex(c) };
        }
    }
    // 提交按钮 hover 色
    if (g_submit_btn) |sb| {
        const hovered = rectContains(sb.base.absoluteRect(), app.mouse_x, app.mouse_y);
        sb.base.background.bg = .{ .color = math.Color.hex(if (hovered) 0x2563EBFF else 0x3B82F6FF) };
    }
    // 结果卡片背景 (提交状态)
    if (g_result_card) |rc| {
        rc.base.background.bg = .{ .color = math.Color.hex(if (g_has_submitted) 0x14532D66 else 0x1E293B80) };
    }

    root.base.paintTree(&ctx);
}

fn handleInput(app: *App) void {
    // 控制键
    if (app.key_hit) |key| {
        switch (key) {
            .tab => {
                g_focused = if (g_focused) |f| (f + 1) % 2 else 0;
                g_drag_field = null;
            },
            .escape => {
                if (g_focused) |f| {
                    g_fields[f].clear();
                    g_cursors[f] = 0;
                    g_sel_anchors[f] = null;
                }
                g_focused = null;
                g_drag_field = null;
            },
            .backspace => {
                if (g_focused) |f| {
                    if (fieldSelRange(f) != null) {
                        deleteFieldSelection(f);
                    } else {
                        g_cursors[f] = g_fields[f].deleteCpBefore(g_cursors[f]);
                    }
                }
            },
            .enter, .kp_enter => doSubmit(),
            else => {},
        }
    }

    // 文本输入 (仅插入到聚焦的输入框, 选区感知)
    if (g_focused) |f| {
        // IME 删除光标前文本 (先于提交处理, 符合协议顺序)
        if (app.takeImeDelete()) |d| {
            if (fieldSelRange(f) != null) deleteFieldSelection(f);
            g_cursors[f] = g_fields[f].deleteNCpsBefore(g_cursors[f], d.before);
        }
        // IME 提交文本 (中文等, 已是 UTF-8)
        const commit = app.imeCommitText();
        if (commit.len > 0) {
            if (fieldSelRange(f) != null) deleteFieldSelection(f);
            g_cursors[f] = g_fields[f].insertBytesAt(g_cursors[f], commit);
        }
        // 普通键盘输入 (ASCII / macOS insertText codepoints)
        for (app.typedCodepoints()) |cp| {
            if (fieldSelRange(f) != null) deleteFieldSelection(f);
            g_cursors[f] = g_fields[f].insertCpAt(g_cursors[f], cp);
        }
    }

    // 鼠标: 点击聚焦 + 定位光标 + 拖拽选择
    if (app.mouse_clicked) {
        var hit_field = false;
        for (0..2) |i| {
            if (g_field_outers[i]) |fo| {
                if (rectContains(fo.base.absoluteRect(), app.mouse_x, app.mouse_y)) {
                    g_focused = i;
                    hit_field = true;
                    // 点击定位光标 + 设选区锚点
                    const fr = fo.base.absoluteRect();
                    const rel_x = app.mouse_x - (fr.x + 14.0 + 1.5);
                    g_cursors[i] = cursorAtX(app.allocator, g_fields[i].slice(), rel_x);
                    g_sel_anchors[i] = g_cursors[i];
                    g_drag_field = i;
                }
            }
        }
        if (!hit_field) {
            g_drag_field = null;
            if (g_submit_btn) |sb| {
                if (rectContains(sb.base.absoluteRect(), app.mouse_x, app.mouse_y)) {
                    doSubmit();
                } else {
                    g_focused = null;
                }
            } else {
                g_focused = null;
            }
        }
    }
    // 拖拽扩展选区
    if (g_drag_field) |i| {
        if (app.mouse_down) {
            if (g_field_outers[i]) |fo| {
                const fr = fo.base.absoluteRect();
                const rel_x = app.mouse_x - (fr.x + 14.0 + 1.5);
                g_cursors[i] = cursorAtX(app.allocator, g_fields[i].slice(), rel_x);
            }
        } else {
            g_drag_field = null;
        }
    }
}

/// IME 候选窗定位: 焦点变化时更新
fn updateImeRect(app: *App) void {
    if (g_focused != g_ime_rect_focus) {
        g_ime_rect_focus = g_focused;
        if (g_focused) |f| {
            if (g_field_outers[f]) |fo| {
                const fr = fo.base.absoluteRect();
                app.setImeCursorRect(
                    @intFromFloat(fr.x),
                    @intFromFloat(fr.y + fr.height),
                    @intFromFloat(fr.width),
                    @intFromFloat(fr.height),
                );
            }
        }
    }
}

fn doSubmit() void {
    g_sub_name = g_fields[0];
    g_sub_email = g_fields[1];
    g_has_submitted = true;
}

// ── Canvas 内容绘制 (背景由框架自动绘制) ────────────────────────────────────

/// 输入框内容: placeholder / 选区高亮 / 文本 / preedit / 闪烁光标
fn paintField(w: *widget.Widget, ctx: *widget.PaintContext, idx: usize) void {
    const ax = ctx.offset_x + w.rect.x;
    const ay = ctx.offset_y + w.rect.y;
    const r = ctx.renderer;
    const alloc = ctx.allocator;

    const text = g_fields[idx].slice();
    const focused = g_focused == idx;
    const preedit = if (focused) g_preedit else "";

    const pad: f32 = 14.0;
    const text_x = ax + pad;
    const max_w = w.rect.width - pad * 2.0;
    const font_size: f32 = 15.0;
    const style = styled_text.TextStyle{ .font_size = font_size, .font_weight = 400 };

    // 垂直居中 (基线位置)
    const text_y = ay + (w.rect.height + font_size * 0.7) / 2.0;

    if (text.len == 0 and preedit.len == 0) {
        // placeholder
        _ = styled_text.drawTextClipped(
            r, alloc, placeholders[idx], text_x, text_y,
            .{ .font_size = font_size, .font_weight = 400, .color = math.Color.hex(0x64748BFF) },
            max_w,
        );
    } else {
        // 选区高亮 (文本层之下)
        if (fieldSelRange(idx)) |sel| {
            const w0 = styled_text.measureTextWidth(alloc, text[0..sel[0]], style);
            const w1 = styled_text.measureTextWidth(alloc, text[0..sel[1]], style);
            const hx0 = @max(text_x + w0, ax);
            const hx1 = @min(text_x + w1, ax + w.rect.width);
            if (hx1 > hx0) {
                r.fillRect(.{ .x = hx0, .y = ay + 5, .width = hx1 - hx0, .height = w.rect.height - 10 }, math.Color.hex(0x3B82F644)) catch {};
            }
        }

        // 已提交文本
        const committed_w = styled_text.drawTextClipped(
            r, alloc, text, text_x, text_y,
            .{ .font_size = font_size, .font_weight = 400, .color = math.Color.hex(0xF8FAFCFF) },
            max_w,
        );
        // 组合中 (preedit) 文本: 接在已提交文本后, 浅色显示
        if (preedit.len > 0) {
            const remaining = max_w - committed_w;
            if (remaining > 0) {
                _ = styled_text.drawTextClipped(
                    r, alloc, preedit, text_x + committed_w, text_y,
                    .{ .font_size = font_size, .font_weight = 400, .color = math.Color.hex(0x93C5FDFF) },
                    remaining,
                );
            }
        }
    }

    // 聚焦时绘制光标: 组合中常亮于 preedit 末尾, 否则闪烁于光标偏移处
    if (focused) {
        const composing = preedit.len > 0;
        const blink_on = composing or (g_frame / 30) % 2 == 0;
        if (blink_on) {
            const cursor = @min(g_cursors[idx], text.len);
            const pre_w = styled_text.measureTextWidth(alloc, text[0..cursor], style);
            const preedit_w = if (composing) styled_text.measureTextWidth(alloc, preedit, style) else 0;
            const cursor_x = text_x + @min(pre_w + preedit_w, max_w);
            r.fillRect(.{ .x = cursor_x, .y = ay + 8, .width = 2, .height = w.rect.height - 16 }, math.Color.hex(0xF8FAFCFF)) catch {};
        }
    }
}

fn paintField0(w: *widget.Widget, ctx: *widget.PaintContext) void {
    paintField(w, ctx, 0);
}
fn paintField1(w: *widget.Widget, ctx: *widget.PaintContext) void {
    paintField(w, ctx, 1);
}

/// 结果卡片内容: 占位文本, 或左侧强调条 + 提交回显
fn paintResult(w: *widget.Widget, ctx: *widget.PaintContext) void {
    const ax = ctx.offset_x + w.rect.x;
    const ay = ctx.offset_y + w.rect.y;
    const cw = w.rect.width;
    const ch = w.rect.height;

    if (!g_has_submitted) {
        drawTextCentered(ctx, "Nothing submitted yet.", ax, ay, cw, ch, 13.0, 400, 0x64748BFF);
        return;
    }

    // 左侧绿色强调条
    ctx.renderer.fillRoundedRect(.{ .x = ax, .y = ay, .width = 4, .height = ch }, 2, math.Color.hex(0x22C55EFF)) catch {};

    const tx = ax + 20.0;
    drawTextAt(ctx, "Submitted", tx, ay + 14, 13.0, 700, 0x4ADE80FF);
    drawTextAt(ctx, g_sub_name.slice(), tx, ay + 38, 14.0, 500, 0xF8FAFCFF);
    drawTextAt(ctx, g_sub_email.slice(), tx, ay + 62, 13.0, 400, 0xCBD5E1FF);
}

// ── 文本绘制辅助 ────────────────────────────────────────────────────────────

fn drawTextAt(ctx: *widget.PaintContext, text: []const u8, x: f32, y: f32, size: f32, weight: u16, color: u32) void {
    styled_text.drawText(
        ctx.renderer,
        ctx.allocator,
        text,
        x,
        y,
        .{ .font_size = size, .font_weight = weight, .color = math.Color.hex(color) },
    );
}

fn drawTextCentered(ctx: *widget.PaintContext, text: []const u8, x: f32, y: f32, cw: f32, ch: f32, size: f32, weight: u16, color: u32) void {
    const text_size = styled_text.measureText(ctx.allocator, text, .{ .font_size = size, .font_weight = weight });
    const tx = x + (cw - text_size.width) / 2.0;
    const ty = y + (ch - size) / 2.0;
    drawTextAt(ctx, text, tx, ty, size, weight, color);
}
