//! zigui M3 示例 - 动画 & 高级控件 (跨平台: macOS Metal / Linux Vulkan)
//!
//! 演示: Easing 曲线 / Spring 物理 / Slider / TextInput / ComboBox / ListView /
//!       TabView / Dialog / Tooltip。
//!
//! 所有结构性背景 (窗口 / 标题栏 / Tab / 面板 / 状态栏) 均为 Widget 背景属性,
//! 由框架在 paintTree 中自动绘制; 复杂动态内容 (曲线 / 弹簧 / 滑块 / 输入框 /
//! 列表项 / 对话框) 由各 Canvas paint_fn 绘制。Tab 页通过 state.visible 切换
//! (不可见页不参与布局), Dialog / Tooltip 为绝对定位的全屏 Canvas。

const std = @import("std");
const zigui = @import("zigui");
const math = zigui.math;
const anim = zigui.animation;
const styled_text = zigui.styled_text;
const r2d = zigui.r2d;

const widget = zigui.widget;
const Container = zigui.container.Container;
const Label = zigui.label.Label;
const Canvas = zigui.canvas.Canvas;

const App = zigui.app.App;

/// 主题 (PaintContext 需要 *const Theme)
const theme_dark: zigui.theme.Theme = zigui.theme.dark;

// ── 全局状态 ──────────────────────────────────────────────────────────────────

var g_frame: u32 = 0;
var g_active_tab: u32 = 0;
var g_slider_value: f32 = 0.65;
var g_dialog_open: bool = false;
var g_tooltip_visible: bool = false;

/// 窗口尺寸与鼠标位置 (供 paint_fn 几何计算 / 悬停检测)
var g_win_w: f32 = 0;
var g_win_h: f32 = 0;
var g_mouse_x: f32 = 0;
var g_mouse_y: f32 = 0;
/// 本帧 IME 组合文本 (供 TextField 绘制)
var g_preedit: []const u8 = "";

// ── TextField (即时模式可复用输入框) ────────────────────────────────────────
// 独立的文本缓冲/光标/焦点/选区/横向滚动状态; 支持点击定位、拖拽选择、
// UTF-8 编辑、IME 组字内联显示、溢出裁剪与横向滚动。

const TextField = struct {
    text: [96]u8 = undefined,
    len: usize = 0,
    cursor: usize = 0, // 字节偏移
    sel_anchor: ?usize = null, // 选区锚点 (字节偏移; null = 无选区)
    focused: bool = false,
    dragging: bool = false, // 鼠标拖拽选择中
    scroll: f32 = 0, // 横向滚动偏移 (px)
    overflow: Overflow = .scroll, // 超出处理: 滚动 or 截断
    max_chars: ?usize = null, // 最大字符数限制 (null = 不限)

    const font_size: f32 = 24.0;
    const pad: f32 = 18.0;

    /// 超出宽度的处理模式
    const Overflow = enum {
        scroll, // 横向滚动, 光标始终可见
        truncate, // 直接截断, 不滚动 (超出部分裁剪不显示)
    };

    fn set(self: *TextField, s: []const u8) void {
        const n = @min(s.len, self.text.len);
        @memcpy(self.text[0..n], s[0..n]);
        self.len = n;
        self.cursor = n;
        self.sel_anchor = null;
    }

    /// 选区字节范围 [start, end) (anchor < cursor 或反之); 无选区返回 null
    fn selRange(self: *const TextField) ?struct { usize, usize } {
        const anchor = self.sel_anchor orelse return null;
        if (anchor == self.cursor) return null;
        return if (anchor < self.cursor) .{ anchor, self.cursor } else .{ self.cursor, anchor };
    }

    /// 删除选中文本, 光标置于删除起点
    fn deleteSelection(self: *TextField) void {
        if (self.selRange()) |sel| {
            const s = sel[0];
            const e = sel[1];
            std.mem.copyForwards(u8, self.text[s .. self.len - (e - s)], self.text[e..self.len]);
            self.len -= e - s;
            self.cursor = s;
        }
        self.sel_anchor = null;
    }

    /// 当前字符数 (UTF-8 码点数, 非字节数)
    fn charCount(self: *const TextField) usize {
        var count: usize = 0;
        var i: usize = 0;
        while (i < self.len) : (i += 1) {
            if ((self.text[i] & 0xC0) != 0x80) count += 1; // 仅计前导字节
        }
        return count;
    }

    /// 在光标处插入一个码点 (有选区时先替换选中文本)
    fn insertCp(self: *TextField, cp: u21) void {
        if (self.selRange() != null) self.deleteSelection();
        if (self.max_chars) |mc| {
            if (self.charCount() >= mc) return;
        }
        var buf: [4]u8 = undefined;
        const n: usize = @intCast(std.unicode.utf8Encode(cp, &buf) catch 0);
        if (n > 0 and self.len + n <= self.text.len) {
            std.mem.copyBackwards(u8, self.text[self.cursor + n .. self.len + n], self.text[self.cursor..self.len]);
            @memcpy(self.text[self.cursor .. self.cursor + n], buf[0..n]);
            self.len += n;
            self.cursor += n;
        }
    }

    /// 编辑: 插入本帧输入码点 + 处理编辑键 (选区感知)
    fn edit(self: *TextField, app: *App) void {
        for (app.typedCodepoints()) |cp| self.insertCp(cp);

        if (app.key_hit) |k| {
            switch (k) {
                .backspace => {
                    if (self.selRange() != null) {
                        self.deleteSelection();
                    } else if (self.cursor > 0) {
                        var prev = self.cursor - 1;
                        while (prev > 0 and (self.text[prev] & 0xC0) == 0x80) prev -= 1;
                        const del = self.cursor - prev;
                        std.mem.copyForwards(u8, self.text[prev .. self.len - del], self.text[prev + del .. self.len]);
                        self.len -= del;
                        self.cursor = prev;
                    }
                },
                .delete => {
                    if (self.selRange() != null) {
                        self.deleteSelection();
                    } else if (self.cursor < self.len) {
                        var next = self.cursor + 1;
                        while (next < self.len and (self.text[next] & 0xC0) == 0x80) next += 1;
                        const del = next - self.cursor;
                        std.mem.copyForwards(u8, self.text[self.cursor .. self.len - del], self.text[next .. self.len]);
                        self.len -= del;
                    }
                },
                .left => {
                    if (self.selRange()) |sel| {
                        // 有选区: 光标折叠到选区起点
                        self.cursor = sel[0];
                        self.sel_anchor = null;
                    } else if (self.cursor > 0) {
                        self.cursor -= 1;
                        while (self.cursor > 0 and (self.text[self.cursor] & 0xC0) == 0x80) self.cursor -= 1;
                    }
                },
                .right => {
                    if (self.selRange()) |sel| {
                        // 有选区: 光标折叠到选区终点
                        self.cursor = sel[1];
                        self.sel_anchor = null;
                    } else if (self.cursor < self.len) {
                        self.cursor += 1;
                        while (self.cursor < self.len and (self.text[self.cursor] & 0xC0) == 0x80) self.cursor += 1;
                    }
                },
                .home => {
                    self.cursor = 0;
                    self.sel_anchor = null;
                },
                .end => {
                    self.cursor = self.len;
                    self.sel_anchor = null;
                },
                else => {},
            }
        }
    }

    /// 根据点击位置 (相对文本原点) 计算光标字节偏移
    fn cursorAtX(self: *TextField, allocator: std.mem.Allocator, rel_x: f32) usize {
        const style = styled_text.TextStyle{ .font_size = font_size, .font_weight = 400 };
        var best: usize = 0;
        var best_dist: f32 = std.math.floatMax(f32);
        var i: usize = 0;
        while (true) {
            const w = styled_text.measureTextWidth(allocator, self.text[0..i], style);
            const d = @abs(w - rel_x);
            if (d < best_dist) {
                best_dist = d;
                best = i;
            }
            if (i >= self.len) break;
            i += 1;
            while (i < self.len and (self.text[i] & 0xC0) == 0x80) i += 1;
        }
        return best;
    }

    /// 调整横向滚动使光标保持在可见区域内 (截断模式不滚动)
    fn updateScroll(self: *TextField, allocator: std.mem.Allocator, caret_w: f32, visible_w: f32) void {
        if (self.overflow == .truncate) {
            self.scroll = 0;
            return;
        }
        const style = styled_text.TextStyle{ .font_size = font_size, .font_weight = 400 };
        const total_w = styled_text.measureTextWidth(allocator, self.text[0..self.len], style);
        const max_scroll = @max(0, @max(total_w, caret_w) - visible_w);
        if (caret_w - self.scroll > visible_w) self.scroll = caret_w - visible_w;
        if (caret_w - self.scroll < 0) self.scroll = caret_w;
        if (self.scroll > max_scroll) self.scroll = max_scroll;
        if (self.scroll < 0) self.scroll = 0;
    }

    /// 绘制输入框 (背景/边框/文本/IME组字/光标), 文本裁剪到框内并横向滚动
    /// 背景为内容级绘制 (聚焦边框动态变化), 由 InputPage Canvas paint_fn 调用。
    fn draw(self: *TextField, ctx: *widget.PaintContext, x: f32, y: f32, w: f32, h: f32, placeholder: []const u8) void {
        const r = ctx.renderer;
        const alloc = ctx.allocator;

        r.fillRoundedRect(.{ .x = x, .y = y, .width = w, .height = h }, 8, math.Color.hex(0x0F172AFF)) catch {};
        if (self.focused) {
            r.fillRoundedRect(.{ .x = x - 1, .y = y - 1, .width = w + 2, .height = h + 2 }, 9, math.Color.hex(0x3B82F6FF)) catch {};
            r.fillRoundedRect(.{ .x = x + 0.5, .y = y + 0.5, .width = w - 1, .height = h - 1 }, 8, math.Color.hex(0x0F172AFF)) catch {};
        }

        const style = styled_text.TextStyle{ .font_size = font_size, .font_weight = 400 };
        const marked = if (self.focused) g_preedit else "";

        const text_x = x + pad;
        const visible_w = w - pad * 2;
        const clip = math.Rect(f32){ .x = x + 2, .y = y, .width = w - 4, .height = h };
        const text_y = y + (h - font_size * 1.2) / 2.0;

        const pre_w = styled_text.measureTextWidth(alloc, self.text[0..self.cursor], style);
        const marked_w = if (marked.len > 0) styled_text.measureTextWidth(alloc, marked, style) else 0;

        self.updateScroll(alloc, pre_w + marked_w, visible_w);
        const origin_x = text_x - self.scroll;

        if (self.len == 0 and marked.len == 0 and !self.focused) {
            if (placeholder.len > 0) {
                drawTextClippedCtx(ctx, placeholder, origin_x, text_y, font_size, 400, 0x475569FF, clip);
            }
        } else {
            // 选区高亮 (文本层之下)
            if (self.selRange()) |sel| {
                const w0 = styled_text.measureTextWidth(alloc, self.text[0..sel[0]], style);
                const w1 = styled_text.measureTextWidth(alloc, self.text[0..sel[1]], style);
                const hx0 = @max(origin_x + w0, clip.x);
                const hx1 = @min(origin_x + w1, clip.x + clip.width);
                if (hx1 > hx0) {
                    r.fillRect(.{ .x = hx0, .y = y + 6, .width = hx1 - hx0, .height = h - 12 }, math.Color.hex(0x3B82F644)) catch {};
                }
            }

            drawTextClippedCtx(ctx, self.text[0..self.len], origin_x, text_y, font_size, 400, 0xF8FAFCFF, clip);

            if (marked.len > 0) {
                drawTextClippedCtx(ctx, marked, origin_x + pre_w, text_y, font_size, 400, 0x93C5FDFF, clip);
                const ux0 = @max(origin_x + pre_w, clip.x);
                const ux1 = @min(origin_x + pre_w + marked_w, clip.x + clip.width);
                if (ux1 > ux0) {
                    r.fillRect(.{ .x = ux0, .y = y + h - 12, .width = ux1 - ux0, .height = 2 }, math.Color.hex(0x3B82F6FF)) catch {};
                }
            }

            if (self.focused and g_frame % 60 < 30) {
                const cx = text_x + pre_w + marked_w - self.scroll;
                if (cx >= clip.x and cx <= clip.x + clip.width) {
                    r.fillRect(.{ .x = cx, .y = y + 8, .width = 2, .height = h - 16 }, math.Color.hex(0x3B82F6FF)) catch {};
                }
            }
        }
    }
};

// 三个独立可编辑输入框
var g_field_user: TextField = .{};
var g_field_email: TextField = .{};
var g_field_pass: TextField = .{};
var g_fields_inited: bool = false;

// ListView 滚动偏移 (滚轮驱动, 像素)
var g_list_scroll: f32 = 0;

// ComboBox 状态 (真实下拉选择)
var g_combo_open: bool = false;
var g_combo_selected: usize = 0;

// 动画演示状态
var g_anim_tweens: [6]anim.Tween = undefined;
var g_anim_inited: bool = false;

// ── 控件树引用 (供每帧更新动态属性 / 交互命中检测) ──────────────────────────

var g_root: ?*Container = null;
var g_tree_alloc: ?std.mem.Allocator = null;
var g_tabs: [5]?*Container = .{ null, null, null, null, null };
var g_tab_labels: [5]?*Label = .{ null, null, null, null, null };
var g_pages: [5]?*Container = .{ null, null, null, null, null };
var g_status_label: ?*Label = null;
var g_status_buf: [128]u8 = undefined;
var g_slider_canvas: ?*Canvas = null;
var g_left_canvas: ?*Canvas = null;
var g_right_canvas: ?*Canvas = null;
var g_bottom_canvas: ?*Canvas = null;
var g_list_canvas: ?*Canvas = null;
var g_dialog_canvas: ?*Canvas = null;
var g_tooltip_canvas: ?*Canvas = null;

// ── 几何常量 (绘制与交互共享, 保证命中检测与视觉一致) ───────────────────────

const tab_names = [_][]const u8{ "Easing Curves", "Spring", "Slider", "Input", "ListView" };
const combo_items = [_][]const u8{ "Zig", "Rust", "C", "C++", "Nim" };

// Input 页字段几何 (相对左侧面板 Canvas)
const in_pad: f32 = 20.0;
const in_box_h: f32 = 64.0;
fn inLabelY(idx: usize) f32 {
    return 95.0 + @as(f32, @floatFromInt(idx)) * 120.0;
}
fn inFieldY(idx: usize) f32 {
    return inLabelY(idx) + 30.0;
}

// ComboBox 几何 (相对右侧面板 Canvas)
const cb_pad: f32 = 20.0;
const cb_label_y: f32 = 95.0;
const cb_box_y: f32 = 127.0;
const cb_box_h: f32 = 56.0;
const combo_item_h: f32 = 48.0;

// Slider 页主轨道几何 (相对 Slider Canvas)
const slider_track_dy: f32 = 180.0;

// ── 入口 ────────────────────────────────────────────────────────────────────

pub fn main() !void {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var app = try App.init(allocator, .{
        .title = "zigui - M3 Animation & Advanced Widgets",
        .width = 1000,
        .height = 800,
    });
    defer app.deinit();

    try buildTree(allocator);
    defer destroyTree();

    try app.run(&drawFrame);

    styled_text.deinitFontCache();
}

// ── 控件树构建 (结构性背景全部为 Widget 属性) ───────────────────────────────

fn buildTree(alloc: std.mem.Allocator) !void {
    // 根容器: 窗口背景色
    const root = try Container.create(alloc, .{
        .bg_color = math.Color.hex(0x0F172AFF),
        .direction = .column,
    });
    errdefer root.destroy(alloc);

    // ── 标题栏 ──
    const title_bar = try Container.create(alloc, .{
        .bg_color = math.Color.hex(0x1E293BFF),
        .direction = .row,
        .height = .{ .px = 88 },
        .padding = .{ .left = 28, .top = 0, .right = 20, .bottom = 0 },
        .gap = .{ .width = 8, .height = 0 },
    });
    try root.base.addChild(alloc, &title_bar.base);

    const title_label = try Label.create(alloc, "zigui M3 - Animation & Advanced Widgets", .{
        .font_size = 30,
        .font_weight = 700,
        .color = math.Color.hex(0xF8FAFCFF),
    });
    title_label.base.layout_style.margin.top = 26;
    try title_bar.base.addChild(alloc, &title_label.base);

    const spacer = try Container.create(alloc, .{});
    spacer.base.layout_style.flex_grow = 1;
    try title_bar.base.addChild(alloc, &spacer.base);

    const dots = [_]u32{ 0xFF5F57FF, 0xFEBC2EFF, 0x28C840FF };
    for (dots) |dc| {
        const dot = try Container.create(alloc, .{
            .bg_color = math.Color.hex(dc),
            .corner_radius = 12,
            .width = .{ .px = 24 },
            .height = .{ .px = 24 },
        });
        dot.base.layout_style.margin.top = 32;
        try title_bar.base.addChild(alloc, &dot.base);
    }

    // ── Tab 栏 (5 个 Tab, 背景每帧随 active 切换) ──
    const tab_bar = try Container.create(alloc, .{
        .direction = .row,
        .gap = .{ .width = 12, .height = 0 },
        .padding = .{ .left = 28, .top = 0, .right = 0, .bottom = 0 },
        .height = .{ .px = 56 },
    });
    tab_bar.base.layout_style.margin.top = 12;
    try root.base.addChild(alloc, &tab_bar.base);

    for (tab_names, 0..) |name, i| {
        const tab_w: f32 = @floatFromInt(name.len * 16 + 44);
        const tab = try Container.create(alloc, .{
            .bg_color = math.Color.hex(0x334155FF),
            .corner_radius = 10,
            .direction = .column,
            .width = .{ .px = tab_w },
            .height = .{ .px = 56 },
        });
        // 标签文字在 Tab 内水平+垂直居中
        tab.base.layout_style.justify_content = .center;
        tab.base.layout_style.align_items = .center;
        try tab_bar.base.addChild(alloc, &tab.base);

        const lbl = try Label.create(alloc, name, .{
            .font_size = 22,
            .font_weight = 400,
            .color = math.Color.hex(0x94A3B8FF),
        });
        try tab.base.addChild(alloc, &lbl.base);

        g_tabs[i] = tab;
        g_tab_labels[i] = lbl;
    }

    // ── 内容区 (5 个 TabPage, 通过 state.visible 切换; 不可见页不占布局) ──
    const content = try Container.create(alloc, .{
        .direction = .column,
        .padding = .{ .left = 30, .top = 10, .right = 30, .bottom = 10 },
    });
    content.base.layout_style.margin.top = 16;
    content.base.layout_style.flex_grow = 1;
    try root.base.addChild(alloc, &content.base);

    // Tab 0: Easing 曲线 (整页 Canvas)
    const page0 = try Container.create(alloc, .{ .direction = .column });
    page0.base.layout_style.flex_grow = 1;
    try content.base.addChild(alloc, &page0.base);
    const easing_canvas = try Canvas.create(alloc, .{ .paint_fn = paintEasing });
    try fillParent(easing_canvas);
    try page0.base.addChild(alloc, &easing_canvas.base);
    g_pages[0] = page0;

    // Tab 1: Spring 动画 (整页 Canvas)
    const page1 = try Container.create(alloc, .{ .direction = .column });
    page1.base.layout_style.flex_grow = 1;
    try content.base.addChild(alloc, &page1.base);
    const spring_canvas = try Canvas.create(alloc, .{ .paint_fn = paintSpring });
    try fillParent(spring_canvas);
    try page1.base.addChild(alloc, &spring_canvas.base);
    g_pages[1] = page1;

    // Tab 2: Slider (整页 Canvas)
    const page2 = try Container.create(alloc, .{ .direction = .column });
    page2.base.layout_style.flex_grow = 1;
    try content.base.addChild(alloc, &page2.base);
    const slider_canvas = try Canvas.create(alloc, .{ .paint_fn = paintSlider });
    try fillParent(slider_canvas);
    try page2.base.addChild(alloc, &slider_canvas.base);
    g_slider_canvas = slider_canvas;
    g_pages[2] = page2;

    // Tab 3: Input (左右面板 Container 背景 + Canvas 内容 + 底部按钮栏)
    const page3 = try Container.create(alloc, .{
        .direction = .column,
        .gap = .{ .width = 0, .height = 16 },
    });
    page3.base.layout_style.flex_grow = 1;
    try content.base.addChild(alloc, &page3.base);

    const panels_row = try Container.create(alloc, .{
        .direction = .row,
        .gap = .{ .width = 20, .height = 0 },
    });
    panels_row.base.layout_style.flex_grow = 1;
    try page3.base.addChild(alloc, &panels_row.base);

    const left_panel = try Container.create(alloc, .{
        .bg_color = math.Color.hex(0x1E293BFF),
        .corner_radius = 10,
        .direction = .column,
    });
    left_panel.base.layout_style.flex_grow = 1;
    try panels_row.base.addChild(alloc, &left_panel.base);
    const left_canvas = try Canvas.create(alloc, .{ .paint_fn = paintInputLeft });
    try fillParent(left_canvas);
    try left_panel.base.addChild(alloc, &left_canvas.base);
    g_left_canvas = left_canvas;

    const right_panel = try Container.create(alloc, .{
        .bg_color = math.Color.hex(0x1E293BFF),
        .corner_radius = 10,
        .direction = .column,
    });
    right_panel.base.layout_style.flex_grow = 1;
    try panels_row.base.addChild(alloc, &right_panel.base);
    const right_canvas = try Canvas.create(alloc, .{ .paint_fn = paintInputRight });
    try fillParent(right_canvas);
    try right_panel.base.addChild(alloc, &right_canvas.base);
    g_right_canvas = right_canvas;

    const bottom_bar = try Container.create(alloc, .{
        .bg_color = math.Color.hex(0x1E293BFF),
        .corner_radius = 10,
        .direction = .row,
        .height = .{ .px = 80 },
    });
    try page3.base.addChild(alloc, &bottom_bar.base);
    const bottom_canvas = try Canvas.create(alloc, .{ .paint_fn = paintInputBottom });
    try fillParent(bottom_canvas);
    try bottom_bar.base.addChild(alloc, &bottom_canvas.base);
    g_bottom_canvas = bottom_canvas;
    g_pages[3] = page3;

    // Tab 4: ListView (面板 Container 背景 + Canvas 列表内容)
    const page4 = try Container.create(alloc, .{ .direction = .column });
    page4.base.layout_style.flex_grow = 1;
    try content.base.addChild(alloc, &page4.base);
    const list_panel = try Container.create(alloc, .{
        .bg_color = math.Color.hex(0x1E293BFF),
        .corner_radius = 10,
        .direction = .column,
    });
    list_panel.base.layout_style.flex_grow = 1;
    try page4.base.addChild(alloc, &list_panel.base);
    const list_canvas = try Canvas.create(alloc, .{ .paint_fn = paintList });
    try fillParent(list_canvas);
    try list_panel.base.addChild(alloc, &list_canvas.base);
    g_list_canvas = list_canvas;
    g_pages[4] = page4;

    // ── 底部状态栏 ──
    const status_bar = try Container.create(alloc, .{
        .bg_color = math.Color.hex(0x1E293BFF),
        .direction = .row,
        .height = .{ .px = 52 },
    });
    try root.base.addChild(alloc, &status_bar.base);

    const status_label = try Label.create(alloc, "zigui", .{
        .font_size = 18,
        .font_weight = 400,
        .color = math.Color.hex(0x64748BFF),
    });
    status_label.base.layout_style.margin.left = 20;
    status_label.base.layout_style.margin.top = 15;
    try status_bar.base.addChild(alloc, &status_label.base);
    g_status_label = status_label;

    // ── Dialog 覆盖层 (绝对定位全屏 Canvas, visibility 切换) ──
    const dialog = try Canvas.create(alloc, .{ .paint_fn = paintDialog });
    dialog.base.layout_style.position = .absolute;
    dialog.base.layout_style.top = 0;
    dialog.base.layout_style.left = 0;
    dialog.base.layout_style.width = .{ .percent = 100 };
    dialog.base.layout_style.height = .{ .percent = 100 };
    dialog.base.state.visible = false;
    try root.base.addChild(alloc, &dialog.base);
    g_dialog_canvas = dialog;

    // ── Tooltip (绝对定位全屏 Canvas, visibility 切换) ──
    const tooltip = try Canvas.create(alloc, .{ .paint_fn = paintTooltip });
    tooltip.base.layout_style.position = .absolute;
    tooltip.base.layout_style.top = 0;
    tooltip.base.layout_style.left = 0;
    tooltip.base.layout_style.width = .{ .percent = 100 };
    tooltip.base.layout_style.height = .{ .percent = 100 };
    tooltip.base.state.visible = false;
    try root.base.addChild(alloc, &tooltip.base);
    g_tooltip_canvas = tooltip;

    g_root = root;
    g_tree_alloc = alloc;
}

/// Canvas 撑满父容器 (width 交叉轴 stretch, height flex_grow)
fn fillParent(canvas: *Canvas) !void {
    canvas.base.layout_style.width = .{ .auto = {} };
    canvas.base.layout_style.height = .{ .auto = {} };
    canvas.base.layout_style.flex_grow = 1;
}

fn destroyTree() void {
    if (g_root) |root| {
        root.destroy(g_tree_alloc orelse return);
        g_root = null;
    }
}

// ── 每帧: 交互 + 动态属性 + 布局 + 绘制 (结构性背景由框架自动绘制) ──────────

fn drawFrame(app: *App) void {
    g_frame += 1;
    const root = g_root orelse return;
    const fb = app.getFramebufferSize();
    const w: f32 = @floatFromInt(fb.width);
    const h: f32 = @floatFromInt(fb.height);
    g_win_w = w;
    g_win_h = h;
    g_mouse_x = app.mouse_x;
    g_mouse_y = app.mouse_y;
    g_preedit = app.preeditText();

    // 初始化动画
    if (!g_anim_inited) {
        initAnimations();
        g_anim_inited = true;
    }
    // 更新动画 (假设 ~16ms/frame)
    for (&g_anim_tweens) |*tw| {
        if (tw.state == .running) {
            _ = tw.update(16);
            if (tw.state == .completed) {
                const tmp = tw.from;
                tw.from = tw.to;
                tw.to = tmp;
                tw.start();
            }
        }
    }
    // 初始化三个字段
    if (!g_fields_inited) {
        g_field_user.set("zigui_dev");
        g_field_user.overflow = .scroll;
        g_field_email.set("dev@zigui.io");
        g_field_email.overflow = .truncate;
        g_field_pass.set("");
        g_field_pass.overflow = .scroll;
        g_field_pass.max_chars = 8;
        g_fields_inited = true;
    }

    root.base.layout_style.width = .{ .px = w };
    root.base.layout_style.height = .{ .px = h };

    // 交互 (使用上一帧布局矩形做命中检测)
    handleInteraction(app);
    // 动态属性 (Tab 背景 / 页可见性 / Dialog/Tooltip / 状态文本)
    updateDynamicProps();

    var ctx = widget.PaintContext{
        .renderer = app.getRenderer(),
        .theme = &theme_dark,
        .allocator = app.allocator,
    };

    root.base.performLayout(&ctx, .{ .max_width = w, .max_height = h });
    root.base.paintTree(&ctx);
}

// ── 交互 ────────────────────────────────────────────────────────────────────

fn handleInteraction(app: *App) void {
    // Tab 点击 (Dialog 打开时不响应)
    for (g_tabs, 0..) |tab_opt, i| {
        if (tab_opt) |tab| {
            const tr = tab.base.absoluteRect();
            if (app.mouse_clicked and !g_dialog_open and
                hitRect(tr.x, tr.y, tr.width, tr.height, app.mouse_x, app.mouse_y))
            {
                g_active_tab = @intCast(i);
            }
        }
    }

    // 仅当前 Tab 的内容交互
    switch (g_active_tab) {
        2 => interactSlider(app),
        3 => interactInput(app),
        4 => interactList(app),
        else => {},
    }

    // Dialog 按钮
    if (g_dialog_open and app.mouse_clicked) {
        interactDialog(app);
    }
}

fn interactSlider(app: *App) void {
    const sc = g_slider_canvas orelse return;
    const sr = sc.base.absoluteRect();
    const track_x = sr.x + 20;
    const track_w = sr.width - 40;
    const track_y = sr.y + slider_track_dy;
    if (app.mouse_down and !g_dialog_open and
        app.mouse_y >= track_y - 24 and app.mouse_y <= track_y + 34 and
        app.mouse_x >= track_x - 20 and app.mouse_x <= track_x + track_w + 20)
    {
        g_slider_value = @max(0, @min(1, (app.mouse_x - track_x) / track_w));
    }
}

/// 输入框交互: 点击聚焦 + 点击定位光标 + 拖拽选择 + 编辑 (仅焦点框)
fn fieldInteract(field: *TextField, app: *App, bx: f32, by: f32, bw: f32, bh: f32) void {
    if (app.mouse_clicked and !g_dialog_open) {
        if (hitRect(bx, by, bw, bh, app.mouse_x, app.mouse_y)) {
            field.focused = true;
            const rel_x = app.mouse_x - (bx + TextField.pad) + field.scroll;
            field.cursor = field.cursorAtX(app.allocator, rel_x);
            field.sel_anchor = field.cursor; // 按下设锚点, 拖动扩展选区
            field.dragging = true;
        } else {
            field.focused = false;
            field.dragging = false;
        }
    }
    // 拖拽扩展选区 (鼠标按住期间持续更新光标位置)
    if (field.dragging and app.mouse_down and !g_dialog_open) {
        const rel_x = app.mouse_x - (bx + TextField.pad) + field.scroll;
        field.cursor = field.cursorAtX(app.allocator, rel_x);
    }
    if (!app.mouse_down) field.dragging = false;

    if (field.focused and !g_dialog_open) {
        field.edit(app);
    }
}

fn interactInput(app: *App) void {
    // 三个输入框
    if (g_left_canvas) |lc| {
        const lr = lc.base.absoluteRect();
        const fw = lr.width - 2 * in_pad;
        fieldInteract(&g_field_user, app, lr.x + in_pad, lr.y + inFieldY(0), fw, in_box_h);
        fieldInteract(&g_field_email, app, lr.x + in_pad, lr.y + inFieldY(1), fw, in_box_h);
        fieldInteract(&g_field_pass, app, lr.x + in_pad, lr.y + inFieldY(2), fw, in_box_h);
    }

    // ComboBox
    if (g_right_canvas) |rc| {
        const rr = rc.base.absoluteRect();
        const cbx = rr.x + cb_pad;
        const cby = rr.y + cb_box_y;
        const cbw = rr.width - 2 * cb_pad;
        const dd_y = cby + cb_box_h + 4;
        const dd_h = combo_item_h * @as(f32, @floatFromInt(combo_items.len)) + 8;

        if (app.mouse_clicked and !g_dialog_open) {
            if (hitRect(cbx, cby, cbw, cb_box_h, app.mouse_x, app.mouse_y)) {
                g_combo_open = !g_combo_open;
            } else if (g_combo_open) {
                if (hitRect(cbx, dd_y, cbw, dd_h, app.mouse_x, app.mouse_y)) {
                    const rel = app.mouse_y - (dd_y + 4);
                    if (rel >= 0) {
                        const idx_i: i32 = @intFromFloat(@floor(rel / combo_item_h));
                        if (idx_i >= 0 and @as(usize, @intCast(idx_i)) < combo_items.len) {
                            g_combo_selected = @intCast(idx_i);
                        }
                    }
                }
                g_combo_open = false;
            }
        }
    }

    // Dialog / Tooltip 触发按钮
    if (g_bottom_canvas) |bc| {
        const br = bc.base.absoluteRect();
        const dlg_x = br.x + 180;
        const dlg_y = br.y + 16;
        if (app.mouse_clicked and !g_dialog_open and hitRect(dlg_x, dlg_y, 200, 48, app.mouse_x, app.mouse_y)) {
            g_dialog_open = true;
        }
        const tip_x = br.x + 400;
        const tip_y = br.y + 16;
        if (app.mouse_clicked and !g_dialog_open and hitRect(tip_x, tip_y, 200, 48, app.mouse_x, app.mouse_y)) {
            g_tooltip_visible = !g_tooltip_visible;
        }
    }
}

fn interactList(app: *App) void {
    if (app.scroll_delta != 0 and !g_dialog_open) {
        g_list_scroll -= app.scroll_delta * 60.0;
        if (g_list_canvas) |lcv| {
            const lr = lcv.base.absoluteRect();
            const item_h: f32 = 64;
            const visible_count: u32 = @intFromFloat(@floor((lr.height - 100) / item_h));
            const total_items: u32 = 50;
            const scrollable: u32 = if (total_items > visible_count) total_items - visible_count else 0;
            const max_scroll: f32 = @as(f32, @floatFromInt(scrollable)) * item_h;
            if (g_list_scroll < 0) g_list_scroll = 0;
            if (g_list_scroll > max_scroll) g_list_scroll = max_scroll;
        }
    }
}

fn interactDialog(app: *App) void {
    const dw: f32 = 560;
    const dh: f32 = 300;
    const dx = (g_win_w - dw) / 2.0;
    const dy = (g_win_h - dh) / 2.0;
    const btn_w: f32 = 150;
    const btn_y = dy + dh - 84;
    const cancel_x = dx + dw - 32 - btn_w * 2 - 16;
    if (hitRect(cancel_x, btn_y, btn_w, 52, app.mouse_x, app.mouse_y)) {
        g_dialog_open = false;
    }
    const confirm_x = dx + dw - 32 - btn_w;
    if (hitRect(confirm_x, btn_y, btn_w, 52, app.mouse_x, app.mouse_y)) {
        g_dialog_open = false;
    }
}

// ── 动态属性更新 ────────────────────────────────────────────────────────────

fn updateDynamicProps() void {
    // Tab 背景 + 文本样式
    for (0..5) |i| {
        const active = g_active_tab == @as(u32, @intCast(i));
        if (g_tabs[i]) |tab| {
            tab.base.background.bg = .{ .color = math.Color.hex(if (active) 0x3B82F6FF else 0x334155FF) };
        }
        if (g_tab_labels[i]) |lbl| {
            lbl.color = math.Color.hex(if (active) 0xFFFFFFFF else 0x94A3B8FF);
            lbl.font_weight = if (active) 600 else 400;
        }
    }
    // TabPage 可见性 (不可见页不参与布局)
    for (0..5) |i| {
        if (g_pages[i]) |page| {
            page.base.state.visible = (g_active_tab == @as(u32, @intCast(i)));
        }
    }
    // Dialog / Tooltip 可见性
    if (g_dialog_canvas) |d| d.base.state.visible = g_dialog_open;
    if (g_tooltip_canvas) |t| t.base.state.visible = g_tooltip_visible;
    // 状态栏文本
    if (g_status_label) |sl| {
        sl.text = std.fmt.bufPrint(
            &g_status_buf,
            "zigui v0.1.0  |  M3: Animation + Slider + TextInput + ComboBox + ListView + TabView + Dialog + Tooltip  |  Frame {d}",
            .{g_frame},
        ) catch "zigui";
    }
}

// ── Tab 0: Easing 曲线可视化 (Canvas) ───────────────────────────────────────

const easing_demos = [_]struct { name: []const u8, easing: anim.Easing }{
    .{ .name = "linear", .easing = .{ .linear = {} } },
    .{ .name = "ease_in quad", .easing = .{ .ease_in = .quad } },
    .{ .name = "ease_out cubic", .easing = .{ .ease_out = .cubic } },
    .{ .name = "ease_in_out sine", .easing = .{ .ease_in_out = .sine } },
    .{ .name = "ease_out bounce", .easing = .{ .ease_out = .bounce } },
    .{ .name = "ease_out elastic", .easing = .{ .ease_out = .elastic } },
    .{ .name = "ease_in back", .easing = .{ .ease_in = .back } },
    .{ .name = "ease_out expo", .easing = .{ .ease_out = .expo } },
    .{ .name = "cubic-bezier(.4,0,.2,1)", .easing = .{ .cubic_bezier = .{ .x1 = 0.4, .y1 = 0, .x2 = 0.2, .y2 = 1 } } },
    .{ .name = "steps(8)", .easing = .{ .steps = .{ .count = 8, .jump_start = false } } },
};

fn paintEasing(w: *widget.Widget, ctx: *widget.PaintContext) void {
    const ax = ctx.offset_x + w.rect.x;
    const ay = ctx.offset_y + w.rect.y;
    const aw = w.rect.width;
    const ah = w.rect.height;
    const r = ctx.renderer;

    const cols: u32 = 5;
    const cell_w: f32 = aw / @as(f32, @floatFromInt(cols));
    const cell_h: f32 = ah / 2.0;

    for (easing_demos, 0..) |demo, idx| {
        const col: f32 = @floatFromInt(@as(u32, @intCast(idx)) % cols);
        const row: f32 = @floatFromInt(@as(u32, @intCast(idx)) / cols);
        const gx = ax + col * cell_w;
        const gy = ay + row * cell_h;

        // 卡片背景
        r.fillRoundedRect(.{ .x = gx, .y = gy, .width = cell_w - 12, .height = cell_h - 8 }, 10, math.Color.hex(0x1E293BFF)) catch {};
        drawTextCtx(ctx, demo.name, gx + 12, gy + 12, 19.0, 500, 0x94A3B8FF);

        // 图形区域
        const graph_size = @min(cell_w - 30, cell_h - 80);
        const plot_x = gx + 10;
        const plot_y = gy + 48;
        r.fillRoundedRect(.{ .x = plot_x, .y = plot_y, .width = graph_size, .height = graph_size }, 4, math.Color.hex(0x0F172AFF)) catch {};

        // 曲线
        var prev_px = plot_x;
        var prev_py = plot_y + graph_size;
        const steps: u32 = 40;
        var s: u32 = 0;
        while (s <= steps) : (s += 1) {
            const t: f32 = @as(f32, @floatFromInt(s)) / @as(f32, @floatFromInt(steps));
            const v = demo.easing.evaluate(t);
            const px = plot_x + t * graph_size;
            const py = plot_y + graph_size - v * graph_size;
            if (s > 0) {
                drawLine(r, prev_px, prev_py, px, py, math.Color.hex(0x38BDF8FF));
            }
            prev_px = px;
            prev_py = py;
        }

        // 动画球: 沿曲线运动
        const anim_t: f32 = @sin(@as(f32, @floatFromInt(g_frame)) * 0.03) * 0.5 + 0.5;
        const anim_v = demo.easing.evaluate(anim_t);
        const ball_x = plot_x + anim_t * graph_size;
        const ball_y = plot_y + graph_size - anim_v * graph_size;
        r.fillRoundedRect(.{ .x = ball_x - 7, .y = ball_y - 7, .width = 14, .height = 14 }, 7, math.Color.hex(0xF59E0BFF)) catch {};
    }
}

// ── Tab 1: Spring 动画演示 (Canvas) ─────────────────────────────────────────

fn paintSpring(w: *widget.Widget, ctx: *widget.PaintContext) void {
    const ax = ctx.offset_x + w.rect.x;
    const ay = ctx.offset_y + w.rect.y;
    const aw = w.rect.width;
    const ah = w.rect.height;
    const r = ctx.renderer;

    // 弹簧参数说明面板
    r.fillRoundedRect(.{ .x = ax, .y = ay, .width = aw, .height = 90 }, 10, math.Color.hex(0x1E293BFF)) catch {};
    drawTextCtx(ctx, "Spring Physics: x(t) = 1 - e^(-zeta*omega*t) * [cos(omega_d*t) + (zeta*omega/omega_d)*sin(omega_d*t)]", ax + 20, ay + 18, 20.0, 400, 0xCBD5E1FF);
    drawTextCtx(ctx, "stiffness=170  damping=26  mass=1  (underdamped, zeta=0.996)", ax + 20, ay + 56, 18.0, 400, 0x64748BFF);

    // 三个弹簧动画球 (不同阻尼)
    const configs = [_]struct { label: []const u8, stiffness: f32, damping: f32, color: u32 }{
        .{ .label = "Stiff (170/12)", .stiffness = 170, .damping = 12, .color = 0x3B82F6FF },
        .{ .label = "Normal (170/26)", .stiffness = 170, .damping = 26, .color = 0x22C55EFF },
        .{ .label = "Soft (80/20)", .stiffness = 80, .damping = 20, .color = 0xF59E0BFF },
    };
    const track_w = aw - 40;
    for (configs, 0..) |cfg, i| {
        const cy = ay + 100 + @as(f32, @floatFromInt(i)) * 68;
        drawTextCtx(ctx, cfg.label, ax + 20, cy, 20.0, 500, cfg.color);

        const rail_y = cy + 34;
        r.fillRoundedRect(.{ .x = ax + 20, .y = rail_y, .width = track_w, .height = 10 }, 5, math.Color.hex(0x334155FF)) catch {};

        const sp = anim.Easing.SpringConfig{ .stiffness = cfg.stiffness, .damping = cfg.damping, .mass = 1 };
        const spring_easing = anim.Easing{ .spring = sp };
        const t: f32 = @sin(@as(f32, @floatFromInt(g_frame)) * 0.02) * 0.5 + 0.5;
        const v = spring_easing.evaluate(t);
        const ball_x = ax + 20 + v * (track_w - 36);
        r.fillRoundedRect(.{ .x = ball_x, .y = rail_y - 13, .width = 36, .height = 36 }, 18, math.Color.hex(cfg.color)) catch {};

        drawSpring(r, ax + 20, rail_y + 5, ball_x, rail_y + 5, 12, math.Color.hex(0x64748BFF));
    }

    // 底部: Tween 值动画条面板
    const tween_y = ay + ah - 240;
    r.fillRoundedRect(.{ .x = ax, .y = tween_y, .width = aw, .height = 240 }, 10, math.Color.hex(0x1E293BFF)) catch {};
    drawTextCtx(ctx, "Tween Animations (ping-pong loop)", ax + 20, tween_y + 18, 20.0, 600, 0xF8FAFCFF);

    const bar_labels = [_][]const u8{ "opacity", "translate_x", "scale", "width", "rotation", "custom" };
    const bar_w = aw - 210;
    for (&g_anim_tweens, 0..) |*tw, i| {
        const by = tween_y + 62 + @as(f32, @floatFromInt(i)) * 28;
        const val = tw.currentValue();
        const norm: f32 = (val - tw.from) / (tw.to - tw.from + 0.001);
        drawTextCtx(ctx, bar_labels[i], ax + 20, by, 17.0, 400, 0x64748BFF);
        r.fillRoundedRect(.{ .x = ax + 170, .y = by + 4, .width = bar_w, .height = 14 }, 7, math.Color.hex(0x334155FF)) catch {};
        const fill_w = bar_w * @max(0, @min(1, norm));
        if (fill_w > 4) {
            r.fillRoundedRect(.{ .x = ax + 170, .y = by + 4, .width = fill_w, .height = 14 }, 7, math.Color.hex(0x8B5CF6FF)) catch {};
        }
    }
}

// ── Tab 2: Slider 演示 (Canvas) ─────────────────────────────────────────────

fn paintSlider(w: *widget.Widget, ctx: *widget.PaintContext) void {
    const ax = ctx.offset_x + w.rect.x;
    const ay = ctx.offset_y + w.rect.y;
    const aw = w.rect.width;
    const ah = w.rect.height;
    const r = ctx.renderer;

    // Slider 控件说明
    r.fillRoundedRect(.{ .x = ax, .y = ay, .width = aw, .height = 80 }, 10, math.Color.hex(0x1E293BFF)) catch {};
    drawTextCtx(ctx, "Slider: track + fill + thumb, drag/keyboard/step support", ax + 20, ay + 16, 20.0, 500, 0xCBD5E1FF);
    drawTextCtx(ctx, "Features: min/max range, step snapping, arrow keys, Home/End", ax + 20, ay + 48, 18.0, 400, 0x64748BFF);

    // 主 Slider (可交互)
    const slider_y = ay + 90;
    r.fillRoundedRect(.{ .x = ax, .y = slider_y, .width = aw, .height = 130 }, 10, math.Color.hex(0x1E293BFF)) catch {};
    drawTextCtx(ctx, "Volume", ax + 20, slider_y + 22, 20.0, 500, 0xF8FAFCFF);

    var buf: [16]u8 = undefined;
    const pct = std.fmt.bufPrint(&buf, "{d}%", .{@as(u32, @intFromFloat(g_slider_value * 100))}) catch "0%";
    drawTextCtx(ctx, pct, ax + aw - 100, slider_y + 22, 20.0, 600, 0x3B82F6FF);

    const track_x = ax + 20;
    const track_w = aw - 40;
    const track_y = slider_y + 90; // = ay + slider_track_dy
    r.fillRoundedRect(.{ .x = track_x, .y = track_y, .width = track_w, .height = 10 }, 5, math.Color.hex(0x334155FF)) catch {};
    r.fillRoundedRect(.{ .x = track_x, .y = track_y, .width = track_w * g_slider_value, .height = 10 }, 5, math.Color.hex(0x3B82F6FF)) catch {};
    const thumb_x = track_x + track_w * g_slider_value;
    r.fillRoundedRect(.{ .x = thumb_x - 16, .y = track_y - 11, .width = 32, .height = 32 }, 16, math.Color.hex(0xFFFFFFFF)) catch {};
    r.fillRoundedRect(.{ .x = thumb_x - 10, .y = track_y - 5, .width = 20, .height = 20 }, 10, math.Color.hex(0x3B82F6FF)) catch {};

    // 多个不同风格的 Slider
    const sliders = [_]struct { label: []const u8, value: f32, color: u32 }{
        .{ .label = "Brightness", .value = 0.8, .color = 0xF59E0BFF },
        .{ .label = "Contrast", .value = 0.45, .color = 0x22C55EFF },
        .{ .label = "Saturation", .value = 0.3, .color = 0xEF4444FF },
        .{ .label = "Temperature", .value = 0.6, .color = 0x8B5CF6FF },
    };
    var sy = ay + 230;
    for (sliders) |s| {
        r.fillRoundedRect(.{ .x = ax, .y = sy, .width = aw, .height = 76 }, 10, math.Color.hex(0x1E293BFF)) catch {};
        drawTextCtx(ctx, s.label, ax + 20, sy + 14, 18.0, 500, 0xCBD5E1FF);
        const st_x = ax + 20;
        const st_w = aw - 40;
        const st_y = sy + 50;
        r.fillRoundedRect(.{ .x = st_x, .y = st_y, .width = st_w, .height = 8 }, 4, math.Color.hex(0x334155FF)) catch {};
        r.fillRoundedRect(.{ .x = st_x, .y = st_y, .width = st_w * s.value, .height = 8 }, 4, math.Color.hex(s.color)) catch {};
        const th_x = st_x + st_w * s.value;
        r.fillRoundedRect(.{ .x = th_x - 13, .y = st_y - 9, .width = 26, .height = 26 }, 13, math.Color.hex(s.color)) catch {};
        sy += 81;
    }
    _ = ah;
}

// ── Tab 3: Input 控件演示 (面板背景为 Container 属性, 内容由 Canvas 绘制) ──

fn paintInputLeft(w: *widget.Widget, ctx: *widget.PaintContext) void {
    const ax = ctx.offset_x + w.rect.x;
    const ay = ctx.offset_y + w.rect.y;
    const aw = w.rect.width;

    drawTextCtx(ctx, "TextInput", ax + 20, ay + 20, 23.0, 600, 0xF8FAFCFF);
    drawTextCtx(ctx, "click to focus / IME / clip + h-scroll", ax + 20, ay + 56, 16.0, 400, 0x64748BFF);

    const in_w = aw - 2 * in_pad;
    drawTextCtx(ctx, "Username (scroll):", ax + in_pad, ay + inLabelY(0), 17.0, 500, 0x94A3B8FF);
    g_field_user.draw(ctx, ax + in_pad, ay + inFieldY(0), in_w, in_box_h, "");

    drawTextCtx(ctx, "Email (truncate):", ax + in_pad, ay + inLabelY(1), 17.0, 500, 0x94A3B8FF);
    g_field_email.draw(ctx, ax + in_pad, ay + inFieldY(1), in_w, in_box_h, "");

    drawTextCtx(ctx, "Password (max 8):", ax + in_pad, ay + inLabelY(2), 17.0, 500, 0x94A3B8FF);
    g_field_pass.draw(ctx, ax + in_pad, ay + inFieldY(2), in_w, in_box_h, "Enter password...");
}

fn paintInputRight(w: *widget.Widget, ctx: *widget.PaintContext) void {
    const ax = ctx.offset_x + w.rect.x;
    const ay = ctx.offset_y + w.rect.y;
    const aw = w.rect.width;
    const r = ctx.renderer;

    drawTextCtx(ctx, "ComboBox", ax + 20, ay + 20, 23.0, 600, 0xF8FAFCFF);
    drawTextCtx(ctx, "dropdown / keyboard nav / selection", ax + 20, ay + 56, 16.0, 400, 0x64748BFF);
    drawTextCtx(ctx, "Language:", ax + cb_pad, ay + cb_label_y, 17.0, 500, 0x94A3B8FF);

    const cbx = ax + cb_pad;
    const cby = ay + cb_box_y;
    const cbw = aw - 2 * cb_pad;

    // 选择框
    r.fillRoundedRect(.{ .x = cbx, .y = cby, .width = cbw, .height = cb_box_h }, 8, math.Color.hex(0x0F172AFF)) catch {};
    if (g_combo_open) {
        r.fillRoundedRect(.{ .x = cbx - 1, .y = cby - 1, .width = cbw + 2, .height = cb_box_h + 2 }, 9, math.Color.hex(0x3B82F6FF)) catch {};
        r.fillRoundedRect(.{ .x = cbx + 0.5, .y = cby + 0.5, .width = cbw - 1, .height = cb_box_h - 1 }, 8, math.Color.hex(0x0F172AFF)) catch {};
    }
    drawTextCtx(ctx, combo_items[g_combo_selected], cbx + 20, cby + 15, 21.0, 400, 0xF8FAFCFF);
    drawTextCtx(ctx, if (g_combo_open) "^" else "v", cbx + cbw - 40, cby + 15, 21.0, 400, 0x64748BFF);

    // 下拉列表
    if (g_combo_open) {
        const dd_y = cby + cb_box_h + 4;
        const dd_h = combo_item_h * @as(f32, @floatFromInt(combo_items.len)) + 8;
        r.fillRoundedRect(.{ .x = cbx - 1, .y = dd_y - 1, .width = cbw + 2, .height = dd_h + 2 }, 9, math.Color.hex(0x334155FF)) catch {};
        r.fillRoundedRect(.{ .x = cbx, .y = dd_y, .width = cbw, .height = dd_h }, 8, math.Color.hex(0x1E293BFF)) catch {};
        for (combo_items, 0..) |item, i| {
            const iy = dd_y + 4 + @as(f32, @floatFromInt(i)) * combo_item_h;
            const hovered = hitRect(cbx + 4, iy, cbw - 8, combo_item_h - 8, g_mouse_x, g_mouse_y);
            if (hovered) {
                r.fillRoundedRect(.{ .x = cbx + 4, .y = iy, .width = cbw - 8, .height = combo_item_h - 8 }, 6, math.Color.hex(0x334155FF)) catch {};
                drawTextCtx(ctx, item, cbx + 20, iy + 11, 19.0, 500, 0xF8FAFCFF);
            } else if (i == g_combo_selected) {
                drawTextCtx(ctx, item, cbx + 20, iy + 11, 19.0, 400, 0x3B82F6FF);
            } else {
                drawTextCtx(ctx, item, cbx + 20, iy + 11, 19.0, 400, 0xCBD5E1FF);
            }
        }
    }
}

fn paintInputBottom(w: *widget.Widget, ctx: *widget.PaintContext) void {
    const ax = ctx.offset_x + w.rect.x;
    const ay = ctx.offset_y + w.rect.y;
    const r = ctx.renderer;

    drawTextCtx(ctx, "Overlays:", ax + 20, ay + 28, 17.0, 500, 0x94A3B8FF);

    // Dialog 按钮
    const dlg_x = ax + 180;
    const dlg_y = ay + 16;
    r.fillRoundedRect(.{ .x = dlg_x, .y = dlg_y, .width = 200, .height = 48 }, 8, math.Color.hex(0x3B82F6FF)) catch {};
    drawTextCenteredCtx(ctx, "Open Dialog", dlg_x, dlg_y, 200, 48, 18.0, 500, 0xFFFFFFFF);

    // Tooltip 按钮 (背景随状态切换)
    const tip_x = ax + 400;
    const tip_y = ay + 16;
    const tip_bg: u32 = if (g_tooltip_visible) 0x475569FF else 0x334155FF;
    r.fillRoundedRect(.{ .x = tip_x, .y = tip_y, .width = 200, .height = 48 }, 8, math.Color.hex(tip_bg)) catch {};
    drawTextCenteredCtx(ctx, "Tooltip", tip_x, tip_y, 200, 48, 18.0, 500, 0xCBD5E1FF);
}

// ── Tab 4: ListView 演示 (面板背景为 Container 属性, 列表由 Canvas 绘制) ────

fn paintList(w: *widget.Widget, ctx: *widget.PaintContext) void {
    const ax = ctx.offset_x + w.rect.x;
    const ay = ctx.offset_y + w.rect.y;
    const aw = w.rect.width;
    const ah = w.rect.height;
    const r = ctx.renderer;

    drawTextCtx(ctx, "ListView (Virtualized)", ax + 20, ay + 20, 20.0, 600, 0xF8FAFCFF);
    drawTextCtx(ctx, "Only visible items rendered - scroll offset driven", ax + 300, ay + 24, 16.0, 400, 0x64748BFF);

    const list_x = ax + 20;
    const list_y = ay + 60;
    const list_w = aw - 56;
    const item_h: f32 = 64;
    const visible_count: u32 = @intFromFloat(@floor((ah - 100) / item_h));
    const total_items: u32 = 50;
    const scroll_offset: f32 = g_list_scroll;
    const start_idx: u32 = @intFromFloat(@floor(scroll_offset / item_h));

    var i: u32 = 0;
    while (i < visible_count) : (i += 1) {
        const idx = start_idx + i;
        if (idx >= total_items) break;
        const iy = list_y + @as(f32, @floatFromInt(i)) * item_h - @mod(scroll_offset, item_h);

        // 交替背景
        if (idx % 2 == 0) {
            r.fillRect(.{ .x = list_x, .y = iy, .width = list_w, .height = item_h - 2 }, math.Color.hex(0x162032FF)) catch {};
        }

        var buf: [16]u8 = undefined;
        const num_str = std.fmt.bufPrint(&buf, "#{d}", .{idx + 1}) catch "?";
        drawTextCtx(ctx, num_str, list_x + 16, iy + 20, 18.0, 600, 0x3B82F6FF);

        var buf2: [48]u8 = undefined;
        const content = std.fmt.bufPrint(&buf2, "Item {d} - Virtualized row data", .{idx + 1}) catch "Item";
        drawTextCtx(ctx, content, list_x + 110, iy + 20, 19.0, 400, 0xCBD5E1FF);

        r.fillRect(.{ .x = list_x, .y = iy + item_h - 2, .width = list_w, .height = 1 }, math.Color.hex(0x334155FF)) catch {};
    }

    // 滚动条
    const sb_x = list_x + list_w + 8;
    const sb_h = ah - 100;
    r.fillRoundedRect(.{ .x = sb_x, .y = list_y, .width = 10, .height = sb_h }, 5, math.Color.hex(0x334155FF)) catch {};
    const thumb_h: f32 = sb_h * @as(f32, @floatFromInt(visible_count)) / @as(f32, @floatFromInt(total_items));
    const scrollable: u32 = if (total_items > visible_count) total_items - visible_count else 0;
    const max_scroll: f32 = @as(f32, @floatFromInt(scrollable)) * item_h;
    const scroll_norm: f32 = if (max_scroll > 0) g_list_scroll / max_scroll else 0;
    const thumb_y = list_y + scroll_norm * (sb_h - thumb_h);
    r.fillRoundedRect(.{ .x = sb_x, .y = thumb_y, .width = 10, .height = thumb_h }, 5, math.Color.hex(0x64748BFF)) catch {};

    // 信息
    var info_buf: [64]u8 = undefined;
    const info = std.fmt.bufPrint(&info_buf, "Total: {d} items  |  Visible: {d}  |  Offset: {d:.0}px", .{ total_items, visible_count, scroll_offset }) catch "";
    drawTextCtx(ctx, info, list_x, ay + ah - 28, 16.0, 400, 0x64748BFF);
}

// ── Dialog 覆盖层 (绝对定位全屏 Canvas) ─────────────────────────────────────

fn paintDialog(w: *widget.Widget, ctx: *widget.PaintContext) void {
    _ = w;
    const r = ctx.renderer;
    const ww = g_win_w;
    const wh = g_win_h;

    // 遮罩
    r.fillRect(.{ .x = 0, .y = 0, .width = ww, .height = wh }, math.Color{ .r = 0, .g = 0, .b = 0, .a = 128 }) catch {};

    const dw: f32 = 560;
    const dh: f32 = 300;
    const dx = (ww - dw) / 2.0;
    const dy = (wh - dh) / 2.0;
    r.fillRoundedRect(.{ .x = dx, .y = dy, .width = dw, .height = dh }, 14, math.Color.hex(0x1E293BFF)) catch {};

    drawTextCtx(ctx, "Confirm Action", dx + 32, dy + 32, 25.0, 700, 0xF8FAFCFF);
    drawTextCtx(ctx, "Are you sure you want to proceed?", dx + 32, dy + 90, 20.0, 400, 0xCBD5E1FF);
    drawTextCtx(ctx, "This action cannot be undone.", dx + 32, dy + 128, 18.0, 400, 0x94A3B8FF);

    const btn_w: f32 = 150;
    const btn_y = dy + dh - 84;
    const cancel_x = dx + dw - 32 - btn_w * 2 - 16;
    r.fillRoundedRect(.{ .x = cancel_x, .y = btn_y, .width = btn_w, .height = 52 }, 8, math.Color.hex(0x334155FF)) catch {};
    drawTextCenteredCtx(ctx, "Cancel", cancel_x, btn_y, btn_w, 52, 18.0, 500, 0xCBD5E1FF);

    const confirm_x = dx + dw - 32 - btn_w;
    r.fillRoundedRect(.{ .x = confirm_x, .y = btn_y, .width = btn_w, .height = 52 }, 8, math.Color.hex(0x3B82F6FF)) catch {};
    drawTextCenteredCtx(ctx, "Confirm", confirm_x, btn_y, btn_w, 52, 18.0, 500, 0xFFFFFFFF);
}

// ── Tooltip (绝对定位全屏 Canvas) ───────────────────────────────────────────

fn paintTooltip(w: *widget.Widget, ctx: *widget.PaintContext) void {
    _ = w;
    const r = ctx.renderer;
    const ww = g_win_w;
    const tw: f32 = 360;
    const th: f32 = 80;
    const tx = ww / 2.0 - tw / 2.0;
    const ty: f32 = 200;

    // 箭头
    r.fillRoundedRect(.{ .x = tx + tw / 2.0 - 8, .y = ty - 8, .width = 16, .height = 16 }, 3, math.Color.hex(0x334155FF)) catch {};
    // 主体
    r.fillRoundedRect(.{ .x = tx, .y = ty, .width = tw, .height = th }, 8, math.Color.hex(0x334155FF)) catch {};
    drawTextCtx(ctx, "Tooltip: contextual info", tx + 16, ty + 14, 18.0, 500, 0xF8FAFCFF);
    drawTextCtx(ctx, "Appears on hover / focus", tx + 16, ty + 46, 16.0, 400, 0x94A3B8FF);
}

// ── 动画初始化 ──────────────────────────────────────────────────────────────

fn initAnimations() void {
    const easings = [_]anim.Easing{
        .{ .ease_out = .cubic },
        .{ .ease_in_out = .sine },
        .{ .ease_out = .elastic },
        .{ .ease_out = .bounce },
        .{ .spring = .{ .stiffness = 170, .damping = 26, .mass = 1 } },
        .{ .cubic_bezier = .{ .x1 = 0.4, .y1 = 0, .x2 = 0.2, .y2 = 1 } },
    };

    for (&g_anim_tweens, 0..) |*tw, i| {
        tw.* = .{
            .from = 0,
            .to = 100,
            .duration_ms = 1500 + @as(u32, @intCast(i)) * 300,
            .easing = easings[i],
        };
        tw.start();
    }
}

// ── 交互辅助 ────────────────────────────────────────────────────────────────

/// 点是否落在矩形内 (点击命中检测)
fn hitRect(x: f32, y: f32, w: f32, h: f32, px: f32, py: f32) bool {
    return px >= x and px < x + w and py >= y and py < y + h;
}

// ── 绘制辅助 ────────────────────────────────────────────────────────────────

fn drawLine(r: *r2d.Renderer2D, x0: f32, y0: f32, x1: f32, y1: f32, color: math.Color) void {
    const dx = x1 - x0;
    const dy = y1 - y0;
    const len = @sqrt(dx * dx + dy * dy);
    if (len < 0.5) return;

    // 简化: 水平/垂直分段
    const mid_x = (x0 + x1) / 2.0;
    r.fillRect(.{ .x = @min(x0, mid_x), .y = @min(y0, y1) - 0.5, .width = @abs(mid_x - x0) + 1, .height = @abs(y1 - y0) + 1 }, color) catch {};
    r.fillRect(.{ .x = @min(mid_x, x1), .y = @min(y0, y1) - 0.5, .width = @abs(x1 - mid_x) + 1, .height = @abs(y1 - y0) + 1 }, color) catch {};
}

fn drawSpring(r: *r2d.Renderer2D, x0: f32, y0: f32, x1: f32, y1: f32, coils: u32, color: math.Color) void {
    const dx = x1 - x0;
    if (dx < 10) return;
    const seg_w = dx / @as(f32, @floatFromInt(coils * 2));
    var cx = x0;
    var up = true;
    var c: u32 = 0;
    while (c < coils * 2) : (c += 1) {
        const ny = if (up) y0 - 10 else y0 + 10;
        r.fillRect(.{ .x = cx, .y = @min(y0, ny), .width = seg_w, .height = @abs(ny - y0) + 1 }, color) catch {};
        cx += seg_w;
        up = !up;
    }
    _ = y1;
}

fn drawTextCtx(ctx: *widget.PaintContext, text: []const u8, x: f32, y: f32, size: f32, weight: u16, color: u32) void {
    styled_text.drawText(
        ctx.renderer,
        ctx.allocator,
        text,
        x,
        y,
        .{ .font_size = size, .font_weight = weight, .color = math.Color.hex(color) },
    );
}

fn drawTextClippedCtx(ctx: *widget.PaintContext, text: []const u8, x: f32, y: f32, size: f32, weight: u16, color: u32, clip: math.Rect(f32)) void {
    _ = styled_text.drawTextClipped(
        ctx.renderer,
        ctx.allocator,
        text,
        x,
        y,
        .{ .font_size = size, .font_weight = weight, .color = math.Color.hex(color) },
        clip.width,
    );
}

fn drawTextCenteredCtx(ctx: *widget.PaintContext, text: []const u8, x: f32, y: f32, cw: f32, ch: f32, size: f32, weight: u16, color: u32) void {
    const text_size = styled_text.measureText(ctx.allocator, text, .{ .font_size = size, .font_weight = weight });
    const tx = x + (cw - text_size.width) / 2.0;
    const ty = y + (ch - size) / 2.0;
    drawTextCtx(ctx, text, tx, ty, size, weight, color);
}
