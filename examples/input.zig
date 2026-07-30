//! zigui input 示例 - 鼠标点击 / 键盘 / 文本输入
//!
//! 演示:
//!   - 鼠标点击命中测试 (absoluteRect + app.mouse_clicked)
//!   - 键盘输入: typedCodepoints 插入文本, key_hit 处理 Backspace/Enter/Esc
//!   - 文本缓冲 (UTF-8 感知) 与闪烁光标
//!   - Canvas paint_fn 自绘输入框内容
//!
//! 运行:  zig build run-input

const std = @import("std");
const zigui = @import("zigui");
const math = zigui.math;
const styled_text = zigui.styled_text;

const widget = zigui.widget;
const Container = zigui.container.Container;
const Label = zigui.label.Label;
const Canvas = zigui.canvas.Canvas;

const theme_dark: zigui.theme.Theme = zigui.theme.dark;

const MAX_TEXT = 128;

// UTF-8 文本缓冲 (定长, 免分配)
const TextBuf = struct {
    bytes: [MAX_TEXT]u8 = undefined,
    len: usize = 0,

    fn slice(self: *const TextBuf) []const u8 {
        return self.bytes[0..self.len];
    }
    fn clear(self: *TextBuf) void {
        self.len = 0;
    }
    fn insertCpAt(self: *TextBuf, pos: usize, cp: u21) usize {
        var tmp: [4]u8 = undefined;
        const n = std.unicode.utf8Encode(cp, &tmp) catch return pos;
        return self.insertBytesAt(pos, tmp[0..n]);
    }
    fn insertBytesAt(self: *TextBuf, pos: usize, data: []const u8) usize {
        const n = @min(data.len, self.bytes.len - self.len);
        if (n == 0) return pos;
        std.mem.copyBackwards(u8, self.bytes[pos + n .. self.len + n], self.bytes[pos..self.len]);
        @memcpy(self.bytes[pos .. pos + n], data[0..n]);
        self.len += n;
        return pos + n;
    }
    fn deleteCpBefore(self: *TextBuf, pos: usize) usize {
        if (pos == 0) return 0;
        var i = pos - 1;
        while (i > 0 and (self.bytes[i] & 0xC0) == 0x80) : (i -= 1) {}
        const e = @min(pos, self.len);
        std.mem.copyForwards(u8, self.bytes[i .. self.len - (e - i)], self.bytes[e..self.len]);
        self.len -= e - i;
        return i;
    }
};

var g_root: ?*Container = null;
var g_tree_alloc: ?std.mem.Allocator = null;
var g_frame: u32 = 0;

var g_text: TextBuf = .{};
var g_cursor: usize = 0;
var g_focused: bool = false;

var g_click_count: u32 = 0;
var g_click_buf: [32]u8 = undefined;
var g_click_label: ?*Label = null;

var g_submitted: ?[]const u8 = null;
var g_sub_buf: [MAX_TEXT]u8 = undefined;
var g_sub_label_buf: [MAX_TEXT + 24]u8 = undefined;
var g_submitted_label: ?*Label = null;

// 控件引用 (命中测试)
var g_click_btn: ?*Container = null;
var g_field: ?*Canvas = null;

fn rectContains(r: math.Rect(f32), x: f32, y: f32) bool {
    return x >= r.x and x <= r.x + r.width and y >= r.y and y <= r.y + r.height;
}

pub fn main() !void {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var app = try zigui.app.App.init(allocator, .{ .title = "zigui - Input", .width = 640, .height = 460 });
    defer app.deinit();

    try buildTree(allocator);
    defer destroyTree();

    try app.run(&drawFrame);
    styled_text.deinitFontCache();
}

fn buildTree(alloc: std.mem.Allocator) !void {
    const root = try Container.create(alloc, .{
        .bg_color = math.Color.hex(0x0F172AFF), .direction = .column,
        .padding = .{ .left = 30, .top = 30, .right = 30, .bottom = 30 }, .gap = .{ .width = 0, .height = 20 },
    });
    errdefer root.destroy(alloc);

    const title = try Label.create(alloc, "Input & Events", .{ .font_size = 22, .font_weight = 700, .color = math.Color.hex(0xF8FAFCFF) });
    try root.base.addChild(alloc, &title.base);

    // 点击计数按钮 (Container 风格, 命中测试驱动)
    const btn = try Container.create(alloc, .{
        .bg_color = math.Color.hex(0x3B82F6FF), .corner_radius = 10, .direction = .column, .height = .{ .px = 44 },
    });
    const btn_lbl = try Label.create(alloc, "Click me!", .{ .font_size = 15, .font_weight = 600, .color = math.Color.white, .text_align = .center });
    btn_lbl.base.layout_style.margin.top = 12;
    try btn.base.addChild(alloc, &btn_lbl.base);
    try root.base.addChild(alloc, &btn.base);
    g_click_btn = btn;

    const clk = try Label.create(alloc, "Clicked: 0", .{ .font_size = 14, .color = math.Color.hex(0x94A3B8FF) });
    g_click_label = clk;
    try root.base.addChild(alloc, &clk.base);

    // 文本输入框 (Canvas 自绘内容)
    const field = try Canvas.create(alloc, .{ .bg_color = math.Color.hex(0x1E293BFF), .corner_radius = 10, .paint_fn = paintField });
    field.base.layout_style.height = .{ .px = 44 };
    field.base.layout_style.width = .{ .auto = {} };
    try root.base.addChild(alloc, &field.base);
    g_field = field;

    const hint = try Label.create(alloc, "Click the box to focus, then type. Backspace deletes, Enter submits, Esc clears.", .{ .font_size = 12, .color = math.Color.hex(0x64748BFF) });
    try root.base.addChild(alloc, &hint.base);

    const sub = try Label.create(alloc, "Submitted: (none)", .{ .font_size = 14, .color = math.Color.hex(0x94A3B8FF) });
    g_submitted_label = sub;
    try root.base.addChild(alloc, &sub.base);

    g_root = root;
    g_tree_alloc = alloc;
}

fn destroyTree() void {
    if (g_root) |root| { root.destroy(g_tree_alloc orelse return); g_root = null; }
}

fn drawFrame(app: *zigui.app.App) void {
    g_frame += 1;
    const root = g_root orelse return;
    const fb = app.getFramebufferSize();
    const w: f32 = @floatFromInt(fb.width);
    const h: f32 = @floatFromInt(fb.height);

    // 输入处理 (命中测试 + 键盘)
    handleInput(app);

    // 动态文本
    if (g_click_label) |cl| cl.text = std.fmt.bufPrint(&g_click_buf, "Clicked: {d}", .{g_click_count}) catch "Clicked: ?";
    if (g_submitted_label) |sl| {
        if (g_submitted) |s| {
            sl.text = std.fmt.bufPrint(&g_sub_label_buf, "Submitted: {s}", .{s}) catch "Submitted: ?";
        } else {
            sl.text = "Submitted: (none)";
        }
    }

    root.base.layout_style.width = .{ .px = w };
    root.base.layout_style.height = .{ .px = h };

    var ctx = widget.PaintContext{ .renderer = app.getRenderer(), .theme = &theme_dark, .allocator = app.allocator };
    root.base.performLayout(&ctx, .{ .max_width = w, .max_height = h });
    root.base.paintTree(&ctx);
}

fn handleInput(app: *zigui.app.App) void {
    // 鼠标点击: 命中"按钮" -> 计数; 点击输入框 -> 聚焦
    if (app.mouse_clicked) {
        if (g_click_btn) |b| {
            if (rectContains(b.base.absoluteRect(), app.mouse_x, app.mouse_y)) {
                g_click_count += 1;
            }
        }
        if (g_field) |_| {
            g_focused = true; // 简化: 点击任意处聚焦输入框
        }
    }

    // 键盘控制键
    if (app.key_hit) |key| {
        switch (key) {
            .backspace => {
                g_cursor = g_text.deleteCpBefore(g_cursor);
            },
            .escape => {
                g_text.clear();
                g_cursor = 0;
                g_focused = false;
            },
            .enter => {
                const n = @min(g_text.len, g_sub_buf.len);
                @memcpy(g_sub_buf[0..n], g_text.bytes[0..n]);
                g_submitted = g_sub_buf[0..n];
            },
            else => {},
        }
    }

    // 文本输入 (UTF-8 codepoint)
    for (app.typedCodepoints()) |cp| {
        g_cursor = g_text.insertCpAt(g_cursor, cp);
    }
}

fn paintField(w: *widget.Widget, ctx: *widget.PaintContext) void {
    const ax = ctx.offset_x + w.rect.x;
    const ay = ctx.offset_y + w.rect.y;
    const pad: f32 = 14;
    const text_x = ax + pad;
    const max_w = w.rect.width - pad * 2;
    const font_size: f32 = 15;
    const text_y = ay + (w.rect.height + font_size * 0.7) / 2;

    const text = g_text.slice();
    if (text.len == 0) {
        const ph_style = styled_text.TextStyle{ .font_size = font_size, .font_weight = 400, .color = math.Color.hex(0x64748BFF) };
        styled_text.drawText(ctx.renderer, ctx.allocator, "Type something...", text_x, text_y, ph_style);
        return;
    }

    const style = styled_text.TextStyle{ .font_size = font_size, .font_weight = 400, .color = math.Color.hex(0xF8FAFCFF) };
    styled_text.drawText(ctx.renderer, ctx.allocator, text, text_x, text_y, style);

    // 闪烁光标
    if (g_focused and (g_frame / 30) % 2 == 0) {
        const cw = styled_text.measureTextWidth(ctx.allocator, text[0..@min(g_cursor, text.len)], style);
        ctx.renderer.fillRect(.{ .x = text_x + cw, .y = ay + 10, .width = 2, .height = w.rect.height - 20 }, math.Color.hex(0xF8FAFCFF)) catch {};
    }
    _ = max_w;
}
