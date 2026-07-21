//! zigui M3 综合示例 - 动画系统 + 高级控件演示

const std = @import("std");
const zigui = @import("zigui");
const math = zigui.math;
const anim = zigui.animation;

pub fn main() !void {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var app = try zigui.app.App.init(allocator, .{
        .title = "zigui - M3 Animation & Advanced Widgets",
        .width = 1000,
        .height = 700,
    });
    defer app.deinit();

    try app.run(&drawFrame);
}

// ── 全局状态 ──────────────────────────────────────────────────────────────────

var g_frame: u32 = 0;
var g_active_tab: u32 = 0;
var g_slider_value: f32 = 0.65;
var g_dialog_open: bool = false;
var g_tooltip_visible: bool = false;

// ── TextField (即时模式可复用输入框) ────────────────────────────────────────
// 独立的文本缓冲/光标/焦点/横向滚动状态; 支持点击定位、UTF-8 编辑、
// IME 组字内联显示、溢出裁剪与横向滚动。

const TextField = struct {
    text: [96]u8 = undefined,
    len: usize = 0,
    cursor: usize = 0, // 字节偏移
    focused: bool = false,
    scroll: f32 = 0, // 横向滚动偏移 (px)
    overflow: Overflow = .scroll, // 超出处理: 滚动 or 截断
    max_chars: ?usize = null, // 最大字符数限制 (null = 不限)

    const font_size: f32 = 28.0;
    const pad: f32 = 20.0;

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

    /// 在光标处插入一个码点 (UTF-8 编码, 光标后内容后移)
    fn insertCp(self: *TextField, cp: u21) void {
        // 达到最大字符数限制则拒绝插入
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

    /// 编辑: 插入本帧输入码点 + 处理编辑键
    fn edit(self: *TextField, app: *zigui.app.App) void {
        for (app.typedCodepoints()) |cp| self.insertCp(cp);

        if (app.key_hit) |k| {
            switch (k) {
                .backspace => {
                    if (self.cursor > 0) {
                        var prev = self.cursor - 1;
                        while (prev > 0 and (self.text[prev] & 0xC0) == 0x80) prev -= 1;
                        const del = self.cursor - prev;
                        std.mem.copyForwards(u8, self.text[prev .. self.len - del], self.text[prev + del .. self.len]);
                        self.len -= del;
                        self.cursor = prev;
                    }
                },
                .delete => {
                    if (self.cursor < self.len) {
                        var next = self.cursor + 1;
                        while (next < self.len and (self.text[next] & 0xC0) == 0x80) next += 1;
                        const del = next - self.cursor;
                        std.mem.copyForwards(u8, self.text[self.cursor .. self.len - del], self.text[next .. self.len]);
                        self.len -= del;
                    }
                },
                .left => {
                    if (self.cursor > 0) {
                        self.cursor -= 1;
                        while (self.cursor > 0 and (self.text[self.cursor] & 0xC0) == 0x80) self.cursor -= 1;
                    }
                },
                .right => {
                    if (self.cursor < self.len) {
                        self.cursor += 1;
                        while (self.cursor < self.len and (self.text[self.cursor] & 0xC0) == 0x80) self.cursor += 1;
                    }
                },
                .home => self.cursor = 0,
                .end => self.cursor = self.len,
                else => {},
            }
        }
    }

    /// 根据点击位置 (相对文本原点) 计算光标字节偏移
    fn cursorAtX(self: *TextField, font: *zigui.coretext.CtFont, rel_x: f32) usize {
        var best: usize = 0;
        var best_dist: f32 = std.math.floatMax(f32);
        var i: usize = 0;
        while (true) {
            const w = font.measureText(self.text[0..i]);
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
    fn updateScroll(self: *TextField, font: *zigui.coretext.CtFont, caret_w: f32, visible_w: f32) void {
        if (self.overflow == .truncate) {
            self.scroll = 0; // 截断模式: 不滚动, 超出部分直接裁剪
            return;
        }
        const total_w = font.measureText(self.text[0..self.len]);
        const max_scroll = @max(0, @max(total_w, caret_w) - visible_w);
        if (caret_w - self.scroll > visible_w) self.scroll = caret_w - visible_w;
        if (caret_w - self.scroll < 0) self.scroll = caret_w;
        if (self.scroll > max_scroll) self.scroll = max_scroll;
        if (self.scroll < 0) self.scroll = 0;
    }

    /// 绘制输入框 (背景/边框/文本/IME组字/光标), 文本裁剪到框内并横向滚动
    fn draw(self: *TextField, r: *zigui.renderer.Renderer2D, app: *zigui.app.App, x: f32, y: f32, w: f32, h: f32, placeholder: []const u8) void {
        // 背景
        r.fillRoundedRect(.{ .x = x, .y = y, .width = w, .height = h }, 8, math.Color.hex(0x0F172AFF)) catch {};
        if (self.focused) {
            // 焦点边框
            r.fillRoundedRect(.{ .x = x - 1, .y = y - 1, .width = w + 2, .height = h + 2 }, 9, math.Color.hex(0x3B82F6FF)) catch {};
            r.fillRoundedRect(.{ .x = x + 0.5, .y = y + 0.5, .width = w - 1, .height = h - 1 }, 8, math.Color.hex(0x0F172AFF)) catch {};
        }

        var font: ?zigui.coretext.CtFont = zigui.coretext.CtFont.create(null, font_size, 400) catch null;
        defer if (font) |*f| f.destroy();

        // IME 组字中的 marked text (仅焦点框显示)
        var marked_buf: [64]u8 = undefined;
        var marked_len: usize = 0;
        if (self.focused) {
            marked_len = app.getMarkedText(&marked_buf);
        }

        const text_x = x + pad;
        const visible_w = w - pad * 2;
        const clip = math.Rect(f32){ .x = x + 2, .y = y, .width = w - 4, .height = h };
        const text_y = y + (h - font_size * 1.2) / 2.0;

        // 光标前文本宽 + 组字宽 (用于滚动与定位)
        const pre_w = if (font) |*f| f.measureText(self.text[0..self.cursor]) else 0;
        const marked_w = if (marked_len > 0 and font != null) font.?.measureText(marked_buf[0..marked_len]) else 0;

        // 横向滚动: 保持光标可见
        if (font) |*f| self.updateScroll(f, pre_w + marked_w, visible_w);
        const origin_x = text_x - self.scroll;

        if (self.len == 0 and marked_len == 0 and !self.focused) {
            // Placeholder
            if (placeholder.len > 0) {
                drawTextClipped(r, app, placeholder, origin_x, text_y, font_size, 400, 0x475569FF, clip);
            }
        } else {
            // 已提交文本
            drawTextClipped(r, app, self.text[0..self.len], origin_x, text_y, font_size, 400, 0xF8FAFCFF, clip);

            // IME 组字文本 (接在光标后, 带下划线)
            if (marked_len > 0) {
                const marked = marked_buf[0..marked_len];
                drawTextClipped(r, app, marked, origin_x + pre_w, text_y, font_size, 400, 0x93C5FDFF, clip);
                // 下划线 (手动裁剪到 clip)
                const ux0 = @max(origin_x + pre_w, clip.x);
                const ux1 = @min(origin_x + pre_w + marked_w, clip.x + clip.width);
                if (ux1 > ux0) {
                    r.fillRect(.{ .x = ux0, .y = y + h - 14, .width = ux1 - ux0, .height = 2 }, math.Color.hex(0x3B82F6FF)) catch {};
                }
            }

            // 光标 (闪烁, 位于已提交文本 + 组字文本之后)
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

// ── 主绘制 ──────────────────────────────────────────────────────────────────

fn drawFrame(app: *zigui.app.App) void {
    g_frame += 1;
    const r = app.getRenderer();
    const fb = app.getFramebufferSize();
    const w: f32 = @floatFromInt(fb.width);
    const h: f32 = @floatFromInt(fb.height);

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
                // 循环: 反转重启
                const tmp = tw.from;
                tw.from = tw.to;
                tw.to = tmp;
                tw.start();
            }
        }
    }

    // 背景
    r.fillRect(.{ .x = 0, .y = 0, .width = w, .height = h }, math.Color.hex(0x0F172AFF)) catch {};

    // 标题栏
    r.fillRect(.{ .x = 0, .y = 0, .width = w, .height = 88 }, math.Color.hex(0x1E293BFF)) catch {};
    drawText(r, app, "zigui M3 - Animation & Advanced Widgets", 28, 26, 34.0, 700, 0xF8FAFCFF);

    // 窗口装饰
    const dots = [_]u32{ 0xFF5F57FF, 0xFEBC2EFF, 0x28C840FF };
    for (dots, 0..) |dc, i| {
        const dx: f32 = w - 128 + @as(f32, @floatFromInt(i)) * 36;
        r.fillRoundedRect(.{ .x = dx, .y = 32, .width = 24, .height = 24 }, 12, math.Color.hex(dc)) catch {};
    }

    // Tab 栏
    drawTabBar(r, app, w);

    // 内容区
    const content_y: f32 = 172;
    switch (g_active_tab) {
        0 => drawEasingCurves(r, app, content_y, w, h),
        1 => drawSpringDemo(r, app, content_y, w, h),
        2 => drawSliderDemo(r, app, content_y, w, h),
        3 => drawInputDemo(r, app, content_y, w, h),
        4 => drawListDemo(r, app, content_y, w, h),
        else => {},
    }

    // Dialog 覆盖层
    if (g_dialog_open) {
        drawDialog(r, app, w, h);
    }

    // Tooltip
    if (g_tooltip_visible) {
        drawTooltip(r, app, w);
    }

    // 底部状态栏
    r.fillRect(.{ .x = 0, .y = h - 52, .width = w, .height = 52 }, math.Color.hex(0x1E293BFF)) catch {};
    var buf: [64]u8 = undefined;
    const status = std.fmt.bufPrint(&buf, "zigui v0.1.0  |  M3: Animation + Slider + TextInput + ComboBox + ListView + TabView + Dialog + Tooltip  |  Frame {d}", .{g_frame}) catch "zigui";
    drawText(r, app, status, 20, h - 35, 20.0, 400, 0x64748BFF);
}

// ── Tab 栏 ──────────────────────────────────────────────────────────────────

const tab_names = [_][]const u8{ "Easing Curves", "Spring", "Slider", "Input", "ListView" };

fn drawTabBar(r: *zigui.renderer.Renderer2D, app: *zigui.app.App, w: f32) void {
    const tab_y: f32 = 100;
    const tab_h: f32 = 56;
    var tab_x: f32 = 28;

    for (tab_names, 0..) |name, i| {
        const tab_w: f32 = @floatFromInt(name.len * 16 + 44);
        const idx: u32 = @intCast(i);

        // 点击命中检测: 落在 tab 矩形内则切换 (dialog 打开时不响应)
        if (app.mouse_clicked and !g_dialog_open and
            app.mouse_x >= tab_x and app.mouse_x < tab_x + tab_w and
            app.mouse_y >= tab_y and app.mouse_y < tab_y + tab_h)
        {
            g_active_tab = idx;
        }

        const active = g_active_tab == idx;

        if (active) {
            r.fillRoundedRect(.{ .x = tab_x, .y = tab_y, .width = tab_w, .height = tab_h }, 10, math.Color.hex(0x3B82F6FF)) catch {};
            drawText(r, app, name, tab_x + 22, tab_y + 16, 24.0, 600, 0xFFFFFFFF);
        } else {
            r.fillRoundedRect(.{ .x = tab_x, .y = tab_y, .width = tab_w, .height = tab_h }, 10, math.Color.hex(0x334155FF)) catch {};
            drawText(r, app, name, tab_x + 22, tab_y + 16, 24.0, 400, 0x94A3B8FF);
        }
        tab_x += tab_w + 12;
    }
    _ = w;
}

// ── Tab 0: Easing 曲线可视化 ─────────────────────────────────────────────────

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

fn drawEasingCurves(r: *zigui.renderer.Renderer2D, app: *zigui.app.App, content_y: f32, w: f32, h: f32) void {
    const cols: u32 = 5;
    const cell_w: f32 = (w - 60) / @as(f32, @floatFromInt(cols));
    const cell_h: f32 = (h - content_y - 80) / 2.0;
    const graph_size: f32 = @min(cell_w - 30, cell_h - 80);

    for (easing_demos, 0..) |demo, idx| {
        const col: f32 = @floatFromInt(@as(u32, @intCast(idx)) % cols);
        const row: f32 = @floatFromInt(@as(u32, @intCast(idx)) / cols);
        const gx = 30 + col * cell_w;
        const gy = content_y + 10 + row * cell_h;

        // 卡片背景
        r.fillRoundedRect(.{ .x = gx, .y = gy, .width = cell_w - 12, .height = cell_h - 8 }, 10, math.Color.hex(0x1E293BFF)) catch {};

        // 标签
        drawText(r, app, demo.name, gx + 12, gy + 12, 22.0, 500, 0x94A3B8FF);

        // 图形区域
        const plot_x = gx + 10;
        const plot_y = gy + 48;
        const plot_w = graph_size;
        const plot_h = graph_size;

        // 网格背景
        r.fillRoundedRect(.{ .x = plot_x, .y = plot_y, .width = plot_w, .height = plot_h }, 4, math.Color.hex(0x0F172AFF)) catch {};

        // 对角参考线 (linear)
        var prev_px = plot_x;
        var prev_py = plot_y + plot_h;
        const steps: u32 = 40;
        var s: u32 = 0;
        while (s <= steps) : (s += 1) {
            const t: f32 = @as(f32, @floatFromInt(s)) / @as(f32, @floatFromInt(steps));
            const v = demo.easing.evaluate(t);
            const px = plot_x + t * plot_w;
            const py = plot_y + plot_h - v * plot_h;

            if (s > 0) {
                // 绘制线段 (用小矩形模拟)
                drawLine(r, prev_px, prev_py, px, py, math.Color.hex(0x38BDF8FF));
            }
            prev_px = px;
            prev_py = py;
        }

        // 动画球: 沿曲线运动
        const anim_t: f32 = @sin(@as(f32, @floatFromInt(g_frame)) * 0.03) * 0.5 + 0.5;
        const anim_v = demo.easing.evaluate(anim_t);
        const ball_x = plot_x + anim_t * plot_w;
        const ball_y = plot_y + plot_h - anim_v * plot_h;
        r.fillRoundedRect(.{ .x = ball_x - 7, .y = ball_y - 7, .width = 14, .height = 14 }, 7, math.Color.hex(0xF59E0BFF)) catch {};
    }
}

// ── Tab 1: Spring 动画演示 ──────────────────────────────────────────────────

fn drawSpringDemo(r: *zigui.renderer.Renderer2D, app: *zigui.app.App, content_y: f32, w: f32, h: f32) void {
    const panel_w: f32 = w - 60;
    const panel_x: f32 = 30;

    // 弹簧参数说明
    r.fillRoundedRect(.{ .x = panel_x, .y = content_y + 10, .width = panel_w, .height = 110 }, 10, math.Color.hex(0x1E293BFF)) catch {};
    drawText(r, app, "Spring Physics: x(t) = 1 - e^(-zeta*omega*t) * [cos(omega_d*t) + (zeta*omega/omega_d)*sin(omega_d*t)]", panel_x + 20, content_y + 30, 24.0, 400, 0xCBD5E1FF);
    drawText(r, app, "stiffness=170  damping=26  mass=1  (underdamped, zeta=0.996)", panel_x + 20, content_y + 72, 22.0, 400, 0x64748BFF);

    // 三个弹簧动画球 (不同阻尼)
    const configs = [_]struct { label: []const u8, stiffness: f32, damping: f32, color: u32 }{
        .{ .label = "Stiff (170/12)", .stiffness = 170, .damping = 12, .color = 0x3B82F6FF },
        .{ .label = "Normal (170/26)", .stiffness = 170, .damping = 26, .color = 0x22C55EFF },
        .{ .label = "Soft (80/20)", .stiffness = 80, .damping = 20, .color = 0xF59E0BFF },
    };

    const track_y = content_y + 150;
    const track_w = panel_w - 40;

    for (configs, 0..) |cfg, i| {
        const cy = track_y + @as(f32, @floatFromInt(i)) * 150;

        // 标签
        drawText(r, app, cfg.label, panel_x + 20, cy, 24.0, 500, cfg.color);

        // 轨道
        const rail_y = cy + 46;
        r.fillRoundedRect(.{ .x = panel_x + 20, .y = rail_y, .width = track_w, .height = 10 }, 5, math.Color.hex(0x334155FF)) catch {};

        // 弹簧球位置 (用帧驱动)
        const sp = anim.Easing.SpringConfig{ .stiffness = cfg.stiffness, .damping = cfg.damping, .mass = 1 };
        const spring_easing = anim.Easing{ .spring = sp };
        const t: f32 = @sin(@as(f32, @floatFromInt(g_frame)) * 0.02) * 0.5 + 0.5;
        const v = spring_easing.evaluate(t);
        const ball_x = panel_x + 20 + v * (track_w - 36);

        r.fillRoundedRect(.{ .x = ball_x, .y = rail_y - 13, .width = 36, .height = 36 }, 18, math.Color.hex(cfg.color)) catch {};

        // 弹簧连线 (锯齿)
        drawSpring(r, panel_x + 20, rail_y + 5, ball_x, rail_y + 5, 12, math.Color.hex(0x64748BFF));
    }

    // 底部: Tween 值动画条
    const tween_y = track_y + 490;
    r.fillRoundedRect(.{ .x = panel_x, .y = tween_y, .width = panel_w, .height = 240 }, 10, math.Color.hex(0x1E293BFF)) catch {};
    drawText(r, app, "Tween Animations (ping-pong loop)", panel_x + 20, tween_y + 18, 24.0, 600, 0xF8FAFCFF);

    // 使用全局 tweens 展示
    const bar_labels = [_][]const u8{ "opacity", "translate_x", "scale", "width", "rotation", "custom" };
    for (&g_anim_tweens, 0..) |*tw, i| {
        const by = tween_y + 62 + @as(f32, @floatFromInt(i)) * 28;
        const val = tw.currentValue();
        const norm: f32 = (val - tw.from) / (tw.to - tw.from + 0.001);

        drawText(r, app, bar_labels[i], panel_x + 20, by, 20.0, 400, 0x64748BFF);
        r.fillRoundedRect(.{ .x = panel_x + 170, .y = by + 4, .width = panel_w - 210, .height = 14 }, 7, math.Color.hex(0x334155FF)) catch {};
        const fill_w = (panel_w - 210) * @max(0, @min(1, norm));
        if (fill_w > 4) {
            r.fillRoundedRect(.{ .x = panel_x + 170, .y = by + 4, .width = fill_w, .height = 14 }, 7, math.Color.hex(0x8B5CF6FF)) catch {};
        }
    }
    _ = h;
}

// ── Tab 2: Slider 演示 ──────────────────────────────────────────────────────

fn drawSliderDemo(r: *zigui.renderer.Renderer2D, app: *zigui.app.App, content_y: f32, w: f32, h: f32) void {
    const panel_x: f32 = 30;
    const panel_w: f32 = w - 60;

    // Slider 控件说明
    r.fillRoundedRect(.{ .x = panel_x, .y = content_y + 10, .width = panel_w, .height = 90 }, 10, math.Color.hex(0x1E293BFF)) catch {};
    drawText(r, app, "Slider: track + fill + thumb, drag/keyboard/step support", panel_x + 20, content_y + 26, 24.0, 500, 0xCBD5E1FF);
    drawText(r, app, "Features: min/max range, step snapping, arrow keys, Home/End", panel_x + 20, content_y + 58, 22.0, 400, 0x64748BFF);

    // 主 Slider (可交互模拟)
    const slider_y = content_y + 130;
    r.fillRoundedRect(.{ .x = panel_x, .y = slider_y, .width = panel_w, .height = 160 }, 10, math.Color.hex(0x1E293BFF)) catch {};
    drawText(r, app, "Volume", panel_x + 20, slider_y + 22, 24.0, 500, 0xF8FAFCFF);

    var buf: [16]u8 = undefined;
    const pct = std.fmt.bufPrint(&buf, "{d}%", .{@as(u32, @intFromFloat(g_slider_value * 100))}) catch "0%";
    drawText(r, app, pct, panel_x + panel_w - 100, slider_y + 22, 24.0, 600, 0x3B82F6FF);

    // Slider 轨道
    const track_x = panel_x + 20;
    const track_w = panel_w - 40;
    const track_y = slider_y + 90;

    // 拖拽: 左键按住且指针落在轨道附近时, 按水平位置更新值 (dialog 打开时不响应)
    if (app.mouse_down and !g_dialog_open and
        app.mouse_y >= track_y - 24 and app.mouse_y <= track_y + 34 and
        app.mouse_x >= track_x - 20 and app.mouse_x <= track_x + track_w + 20)
    {
        g_slider_value = @max(0, @min(1, (app.mouse_x - track_x) / track_w));
    }

    r.fillRoundedRect(.{ .x = track_x, .y = track_y, .width = track_w, .height = 10 }, 5, math.Color.hex(0x334155FF)) catch {};
    r.fillRoundedRect(.{ .x = track_x, .y = track_y, .width = track_w * g_slider_value, .height = 10 }, 5, math.Color.hex(0x3B82F6FF)) catch {};

    // Thumb
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

    var sy = slider_y + 190;
    for (sliders) |s| {
        r.fillRoundedRect(.{ .x = panel_x, .y = sy, .width = panel_w, .height = 104 }, 10, math.Color.hex(0x1E293BFF)) catch {};
        drawText(r, app, s.label, panel_x + 20, sy + 18, 22.0, 500, 0xCBD5E1FF);

        const st_x = panel_x + 20;
        const st_w = panel_w - 40;
        const st_y = sy + 62;
        r.fillRoundedRect(.{ .x = st_x, .y = st_y, .width = st_w, .height = 8 }, 4, math.Color.hex(0x334155FF)) catch {};
        r.fillRoundedRect(.{ .x = st_x, .y = st_y, .width = st_w * s.value, .height = 8 }, 4, math.Color.hex(s.color)) catch {};
        const th_x = st_x + st_w * s.value;
        r.fillRoundedRect(.{ .x = th_x - 13, .y = st_y - 9, .width = 26, .height = 26 }, 13, math.Color.hex(s.color)) catch {};

        sy += 116;
    }
    _ = h;
}

// ── Tab 3: Input 控件演示 ───────────────────────────────────────────────────

/// 输入框交互: 点击聚焦 + 点击定位光标 + 编辑 (仅焦点框)
fn fieldInteract(field: *TextField, app: *zigui.app.App, bx: f32, by: f32, bw: f32, bh: f32) void {
    if (app.mouse_clicked and !g_dialog_open) {
        if (hitRect(bx, by, bw, bh, app.mouse_x, app.mouse_y)) {
            field.focused = true;
            // 点击定位光标
            var font = zigui.coretext.CtFont.create(null, TextField.font_size, 400) catch return;
            defer font.destroy();
            const rel_x = app.mouse_x - (bx + TextField.pad) + field.scroll;
            field.cursor = field.cursorAtX(&font, rel_x);
        } else {
            field.focused = false;
        }
    }
    if (field.focused and !g_dialog_open) {
        field.edit(app);
    }
}

fn drawInputDemo(r: *zigui.renderer.Renderer2D, app: *zigui.app.App, content_y: f32, w: f32, h: f32) void {
    const panel_x: f32 = 30;
    const panel_w: f32 = w - 60;
    const half_w: f32 = (panel_w - 20) / 2.0;

    // 初始化三个字段的默认文本与配置
    // (Username=滚动, Email=截断, Password=滚动+限 8 字符)
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

    // 左: TextInput (放大布局)
    r.fillRoundedRect(.{ .x = panel_x, .y = content_y + 10, .width = half_w, .height = 560 }, 10, math.Color.hex(0x1E293BFF)) catch {};
    drawText(r, app, "TextInput", panel_x + 20, content_y + 30, 26.0, 600, 0xF8FAFCFF);
    drawText(r, app, "click to focus / IME / clip + h-scroll", panel_x + 20, content_y + 68, 20.0, 400, 0x64748BFF);

    // 字段几何 (放大: 框高 76, 字号 28)
    const in_x = panel_x + 20;
    const in_w = half_w - 40;
    const box_h: f32 = 76;
    const label_gap: f32 = 36;
    const row_h: f32 = 150;
    const in1_label_y = content_y + 112;
    const in2_label_y = in1_label_y + row_h;
    const in3_label_y = in2_label_y + row_h;
    const in1_y = in1_label_y + label_gap;
    const in2_y = in2_label_y + label_gap;
    const in3_y = in3_label_y + label_gap;

    // 交互 (点击聚焦/定位, 键入编辑)
    fieldInteract(&g_field_user, app, in_x, in1_y, in_w, box_h);
    fieldInteract(&g_field_email, app, in_x, in2_y, in_w, box_h);
    fieldInteract(&g_field_pass, app, in_x, in3_y, in_w, box_h);

    // 绘制三个可编辑输入框
    drawText(r, app, "Username (scroll):", in_x, in1_label_y, 22.0, 500, 0x94A3B8FF);
    g_field_user.draw(r, app, in_x, in1_y, in_w, box_h, "");

    drawText(r, app, "Email (truncate):", in_x, in2_label_y, 22.0, 500, 0x94A3B8FF);
    g_field_email.draw(r, app, in_x, in2_y, in_w, box_h, "");

    drawText(r, app, "Password (max 8):", in_x, in3_label_y, 22.0, 500, 0x94A3B8FF);
    g_field_pass.draw(r, app, in_x, in3_y, in_w, box_h, "Enter password...");

    // 右: ComboBox
    const right_x = panel_x + half_w + 20;
    r.fillRoundedRect(.{ .x = right_x, .y = content_y + 10, .width = half_w, .height = 560 }, 10, math.Color.hex(0x1E293BFF)) catch {};
    drawText(r, app, "ComboBox", right_x + 20, content_y + 30, 26.0, 600, 0xF8FAFCFF);
    drawText(r, app, "dropdown / keyboard nav / selection", right_x + 20, content_y + 68, 20.0, 400, 0x64748BFF);

    // ComboBox (真实下拉选择)
    const combo_items = [_][]const u8{ "Zig", "Rust", "C", "C++", "Nim" };
    const cb_x = right_x + 20;
    const cb_w = half_w - 40;
    const cb_y = content_y + 150;
    const dd_y = cb_y + 72;
    const dd_h: f32 = 60 * @as(f32, @floatFromInt(combo_items.len)) + 8;

    drawText(r, app, "Language:", right_x + 20, content_y + 112, 22.0, 500, 0x94A3B8FF);

    // 点击: 选择框切换展开 / 下拉项选中 / 框外关闭
    if (app.mouse_clicked and !g_dialog_open) {
        if (hitRect(cb_x, cb_y, cb_w, 64, app.mouse_x, app.mouse_y)) {
            g_combo_open = !g_combo_open;
        } else if (g_combo_open) {
            if (hitRect(cb_x, dd_y, cb_w, dd_h, app.mouse_x, app.mouse_y)) {
                const rel = app.mouse_y - (dd_y + 4);
                if (rel >= 0) {
                    const idx_i: i32 = @intFromFloat(@floor(rel / 60));
                    if (idx_i >= 0 and @as(usize, @intCast(idx_i)) < combo_items.len) {
                        g_combo_selected = @intCast(idx_i);
                    }
                }
            }
            g_combo_open = false;
        }
    }

    // 选择框
    r.fillRoundedRect(.{ .x = cb_x, .y = cb_y, .width = cb_w, .height = 64 }, 8, math.Color.hex(0x0F172AFF)) catch {};
    if (g_combo_open) {
        // 焦点边框
        r.fillRoundedRect(.{ .x = cb_x - 1, .y = cb_y - 1, .width = cb_w + 2, .height = 66 }, 9, math.Color.hex(0x3B82F6FF)) catch {};
        r.fillRoundedRect(.{ .x = cb_x + 0.5, .y = cb_y + 0.5, .width = cb_w - 1, .height = 63 }, 8, math.Color.hex(0x0F172AFF)) catch {};
    }
    drawText(r, app, combo_items[g_combo_selected], cb_x + 20, cb_y + 18, 26.0, 400, 0xF8FAFCFF);
    // 箭头 (展开时翻转)
    drawText(r, app, if (g_combo_open) "^" else "v", cb_x + cb_w - 40, cb_y + 18, 26.0, 400, 0x64748BFF);

    // 底部: Dialog + Tooltip 触发按钮
    const btn_y = content_y + 590;
    r.fillRoundedRect(.{ .x = panel_x, .y = btn_y, .width = panel_w, .height = 92 }, 10, math.Color.hex(0x1E293BFF)) catch {};
    drawText(r, app, "Overlays:", panel_x + 20, btn_y + 32, 22.0, 500, 0x94A3B8FF);

    // Dialog 按钮 (点击打开)
    const dlg_x = panel_x + 180;
    const dlg_y = btn_y + 18;
    if (app.mouse_clicked and !g_dialog_open and hitRect(dlg_x, dlg_y, 200, 56, app.mouse_x, app.mouse_y)) {
        g_dialog_open = true;
    }
    r.fillRoundedRect(.{ .x = dlg_x, .y = dlg_y, .width = 200, .height = 56 }, 8, math.Color.hex(0x3B82F6FF)) catch {};
    drawTextCentered(r, app, "Open Dialog", dlg_x, dlg_y, 200, 56, 24.0, 500, 0xFFFFFFFF);

    // Tooltip 按钮 (点击切换)
    const tip_x = panel_x + 400;
    const tip_y = btn_y + 18;
    if (app.mouse_clicked and !g_dialog_open and hitRect(tip_x, tip_y, 200, 56, app.mouse_x, app.mouse_y)) {
        g_tooltip_visible = !g_tooltip_visible;
    }
    const tip_bg: u32 = if (g_tooltip_visible) 0x475569FF else 0x334155FF;
    r.fillRoundedRect(.{ .x = tip_x, .y = tip_y, .width = 200, .height = 56 }, 8, math.Color.hex(tip_bg)) catch {};
    drawTextCentered(r, app, "Tooltip", tip_x, tip_y, 200, 56, 24.0, 500, 0xCBD5E1FF);

    // 下拉列表 (最后绘制, 覆盖下方面板)
    if (g_combo_open) {
        // 边框 + 背景
        r.fillRoundedRect(.{ .x = cb_x - 1, .y = dd_y - 1, .width = cb_w + 2, .height = dd_h + 2 }, 9, math.Color.hex(0x334155FF)) catch {};
        r.fillRoundedRect(.{ .x = cb_x, .y = dd_y, .width = cb_w, .height = dd_h }, 8, math.Color.hex(0x1E293BFF)) catch {};
        for (combo_items, 0..) |item, i| {
            const iy = dd_y + 4 + @as(f32, @floatFromInt(i)) * 60;
            const hovered = hitRect(cb_x + 4, iy, cb_w - 8, 52, app.mouse_x, app.mouse_y);
            if (hovered) {
                r.fillRoundedRect(.{ .x = cb_x + 4, .y = iy, .width = cb_w - 8, .height = 52 }, 6, math.Color.hex(0x334155FF)) catch {};
                drawText(r, app, item, cb_x + 20, iy + 12, 24.0, 500, 0xF8FAFCFF);
            } else if (i == g_combo_selected) {
                drawText(r, app, item, cb_x + 20, iy + 12, 24.0, 400, 0x3B82F6FF);
            } else {
                drawText(r, app, item, cb_x + 20, iy + 12, 24.0, 400, 0xCBD5E1FF);
            }
        }
    }
    _ = h;
}

// ── Tab 4: ListView 演示 ────────────────────────────────────────────────────

fn drawListDemo(r: *zigui.renderer.Renderer2D, app: *zigui.app.App, content_y: f32, w: f32, h: f32) void {
    const panel_x: f32 = 30;
    const panel_w: f32 = w - 60;
    const list_h: f32 = h - content_y - 90;

    r.fillRoundedRect(.{ .x = panel_x, .y = content_y + 10, .width = panel_w, .height = list_h }, 10, math.Color.hex(0x1E293BFF)) catch {};
    drawText(r, app, "ListView (Virtualized)", panel_x + 20, content_y + 30, 24.0, 600, 0xF8FAFCFF);
    drawText(r, app, "Only visible items rendered - scroll offset driven", panel_x + 320, content_y + 34, 20.0, 400, 0x64748BFF);

    // 列表区域
    const list_x = panel_x + 20;
    const list_y = content_y + 76;
    const list_w = panel_w - 56;
    const item_h: f32 = 72;
    const visible_count: u32 = @intFromFloat(@floor((list_h - 110) / item_h));

    // 滚轮驱动滚动
    const total_items: u32 = 50;
    const scrollable: u32 = if (total_items > visible_count) total_items - visible_count else 0;
    const max_scroll: f32 = @as(f32, @floatFromInt(scrollable)) * item_h;
    if (app.scroll_delta != 0 and !g_dialog_open) {
        g_list_scroll -= app.scroll_delta * 60.0;
        if (g_list_scroll < 0) g_list_scroll = 0;
        if (g_list_scroll > max_scroll) g_list_scroll = max_scroll;
    }
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

        // 序号
        var buf: [16]u8 = undefined;
        const num_str = std.fmt.bufPrint(&buf, "#{d}", .{idx + 1}) catch "?";
        drawText(r, app, num_str, list_x + 16, iy + 24, 22.0, 600, 0x3B82F6FF);

        // 内容
        var buf2: [48]u8 = undefined;
        const content = std.fmt.bufPrint(&buf2, "Item {d} - Virtualized row data", .{idx + 1}) catch "Item";
        drawText(r, app, content, list_x + 110, iy + 24, 24.0, 400, 0xCBD5E1FF);

        // 分隔线
        r.fillRect(.{ .x = list_x, .y = iy + item_h - 2, .width = list_w, .height = 1 }, math.Color.hex(0x334155FF)) catch {};
    }

    // 滚动条
    const sb_x = list_x + list_w + 8;
    const sb_h = list_h - 110;
    r.fillRoundedRect(.{ .x = sb_x, .y = list_y, .width = 10, .height = sb_h }, 5, math.Color.hex(0x334155FF)) catch {};
    const thumb_h: f32 = sb_h * @as(f32, @floatFromInt(visible_count)) / @as(f32, @floatFromInt(total_items));
    const scroll_norm: f32 = if (max_scroll > 0) g_list_scroll / max_scroll else 0;
    const thumb_y = list_y + scroll_norm * (sb_h - thumb_h);
    r.fillRoundedRect(.{ .x = sb_x, .y = thumb_y, .width = 10, .height = thumb_h }, 5, math.Color.hex(0x64748BFF)) catch {};

    // 信息
    var info_buf: [64]u8 = undefined;
    const info = std.fmt.bufPrint(&info_buf, "Total: {d} items  |  Visible: {d}  |  Offset: {d:.0}px", .{ total_items, visible_count, scroll_offset }) catch "";
    drawText(r, app, info, list_x, list_y + sb_h + 12, 20.0, 400, 0x64748BFF);
}

// ── Dialog ──────────────────────────────────────────────────────────────────

fn drawDialog(r: *zigui.renderer.Renderer2D, app: *zigui.app.App, w: f32, h: f32) void {
    // 遮罩
    r.fillRect(.{ .x = 0, .y = 0, .width = w, .height = h }, math.Color{ .r = 0, .g = 0, .b = 0, .a = 128 }) catch {};

    // Dialog 窗口
    const dw: f32 = 560;
    const dh: f32 = 300;
    const dx = (w - dw) / 2.0;
    const dy = (h - dh) / 2.0;

    r.fillRoundedRect(.{ .x = dx, .y = dy, .width = dw, .height = dh }, 14, math.Color.hex(0x1E293BFF)) catch {};

    // 标题
    drawText(r, app, "Confirm Action", dx + 32, dy + 32, 28.0, 700, 0xF8FAFCFF);

    // 消息
    drawText(r, app, "Are you sure you want to proceed?", dx + 32, dy + 90, 24.0, 400, 0xCBD5E1FF);
    drawText(r, app, "This action cannot be undone.", dx + 32, dy + 128, 22.0, 400, 0x94A3B8FF);

    // 按钮
    const btn_w: f32 = 150;
    const btn_y = dy + dh - 84;

    // Cancel (点击关闭)
    const cancel_x = dx + dw - 32 - btn_w * 2 - 16;
    if (app.mouse_clicked and hitRect(cancel_x, btn_y, btn_w, 52, app.mouse_x, app.mouse_y)) {
        g_dialog_open = false;
    }
    r.fillRoundedRect(.{ .x = cancel_x, .y = btn_y, .width = btn_w, .height = 52 }, 8, math.Color.hex(0x334155FF)) catch {};
    drawTextCentered(r, app, "Cancel", cancel_x, btn_y, btn_w, 52, 22.0, 500, 0xCBD5E1FF);

    // Confirm (点击关闭)
    const confirm_x = dx + dw - 32 - btn_w;
    if (app.mouse_clicked and hitRect(confirm_x, btn_y, btn_w, 52, app.mouse_x, app.mouse_y)) {
        g_dialog_open = false;
    }
    r.fillRoundedRect(.{ .x = confirm_x, .y = btn_y, .width = btn_w, .height = 52 }, 8, math.Color.hex(0x3B82F6FF)) catch {};
    drawTextCentered(r, app, "Confirm", confirm_x, btn_y, btn_w, 52, 22.0, 500, 0xFFFFFFFF);
}

// ── Tooltip ─────────────────────────────────────────────────────────────────

fn drawTooltip(r: *zigui.renderer.Renderer2D, app: *zigui.app.App, w: f32) void {
    const tw: f32 = 360;
    const th: f32 = 80;
    const tx = w / 2.0 - tw / 2.0;
    const ty: f32 = 200;

    // 箭头
    r.fillRoundedRect(.{ .x = tx + tw / 2.0 - 8, .y = ty - 8, .width = 16, .height = 16 }, 3, math.Color.hex(0x334155FF)) catch {};

    // 主体
    r.fillRoundedRect(.{ .x = tx, .y = ty, .width = tw, .height = th }, 8, math.Color.hex(0x334155FF)) catch {};
    drawText(r, app, "Tooltip: contextual info", tx + 16, ty + 14, 22.0, 500, 0xF8FAFCFF);
    drawText(r, app, "Appears on hover / focus", tx + 16, ty + 46, 20.0, 400, 0x94A3B8FF);
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

fn drawLine(r: *zigui.renderer.Renderer2D, x0: f32, y0: f32, x1: f32, y1: f32, color: math.Color) void {
    const dx = x1 - x0;
    const dy = y1 - y0;
    const len = @sqrt(dx * dx + dy * dy);
    if (len < 0.5) return;

    // 用 3px 宽的小矩形模拟线段
    const thickness: f32 = 3.0;
    const nx = -dy / len * thickness / 2.0;
    const ny = dx / len * thickness / 2.0;
    _ = nx;
    _ = ny;

    // 简化: 水平/垂直分段
    const mid_x = (x0 + x1) / 2.0;
    r.fillRect(.{ .x = @min(x0, mid_x), .y = @min(y0, y1) - 0.5, .width = @abs(mid_x - x0) + 1, .height = @abs(y1 - y0) + 1 }, color) catch {};
    r.fillRect(.{ .x = @min(mid_x, x1), .y = @min(y0, y1) - 0.5, .width = @abs(x1 - mid_x) + 1, .height = @abs(y1 - y0) + 1 }, color) catch {};
}

fn drawSpring(r: *zigui.renderer.Renderer2D, x0: f32, y0: f32, x1: f32, y1: f32, coils: u32, color: math.Color) void {
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

fn drawText(r: *zigui.renderer.Renderer2D, app: *zigui.app.App, text: []const u8, x: f32, y: f32, size: f32, weight: u16, color: u32) void {
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

    r.drawText(&tl, x, y, math.Color.hex(color)) catch {};
}

fn drawTextClipped(r: *zigui.renderer.Renderer2D, app: *zigui.app.App, text: []const u8, x: f32, y: f32, size: f32, weight: u16, color: u32, clip: math.Rect(f32)) void {
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

    r.drawTextClipped(&tl, x, y, math.Color.hex(color), clip) catch {};
}

fn drawTextCentered(r: *zigui.renderer.Renderer2D, app: *zigui.app.App, text: []const u8, x: f32, y: f32, w: f32, h: f32, size: f32, weight: u16, color: u32) void {
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

    const tx = x + (w - tl.total_size.width) / 2.0;
    const ty = y + (h - tl.total_size.height) / 2.0;
    r.drawText(&tl, tx, ty, math.Color.hex(color)) catch {};
}
