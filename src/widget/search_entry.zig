//! SearchEntry 控件 - 搜索输入框 (对标 GtkSearchEntry)
//! 在 Entry 基础上增加左侧搜索图标和右侧清除按钮

const std = @import("std");
const math = @import("../math.zig");
const widget_mod = @import("widget.zig");
const layout_mod = @import("../layout/engine.zig");
const pal = @import("../pal/pal.zig");
const perf = @import("../perf.zig");
const styled_text = @import("../text/styled_text.zig");
const entry_mod = @import("entry.zig");

const Widget = widget_mod.Widget;
const PaintContext = widget_mod.PaintContext;
const EventContext = widget_mod.EventContext;
const EventResult = widget_mod.EventResult;
const Entry = entry_mod.Entry;
const Editable = @import("../model/editable.zig").Editable;
const EntryBuffer = @import("../model/editable.zig").EntryBuffer;

// Entry on_change -> SearchEntry on_search 的包装 (反查 parent)
fn searchEntryChangeWrapper(entry_self: *Entry, text: []const u8) void {
    const parent_widget = entry_self.base.parent orelse return;
    const self: *SearchEntry = @fieldParentPtr("base", parent_widget);
    if (self.on_search) |cb| cb(self, text);
}

pub const SearchEntry = struct {
    base: Widget,
    allocator: std.mem.Allocator,
    input: *Entry,
    placeholder: []const u8,
    font_size: f32,
    on_search: ?*const fn (self: *SearchEntry, text: []const u8) void = null,
    // 样式
    bg_color: math.Color = math.Color.hex(0x1E293BFF),
    border_color: math.Color = math.Color.hex(0x334155FF),
    focus_border: math.Color = math.Color.hex(0x3B82F6FF),
    icon_color: math.Color = math.Color.hex(0x64748BFF),
    clear_color: math.Color = math.Color.hex(0x64748BFF),
    clear_hover_color: math.Color = math.Color.hex(0xF8FAFCFF),
    corner_radius: f32 = 8.0,
    icon_padding: f32 = 12.0,
    icon_size: f32 = 16.0,
    clear_size: f32 = 16.0,
    clear_btn_hover: bool = false,
    clear_btn_pressed: bool = false,
    // GTK4 新增字段
    loading: bool = false,
    search_delay_ms: u32 = 150,
    key_capture_widget: ?*Widget = null,
    // 搜索延迟定时器
    delay_timer_active: bool = false,
    delay_timer_start: u64 = 0,
    delay_pending_text: []const u8 = "",

    pub fn create(allocator: std.mem.Allocator, opts: struct {
        placeholder: []const u8 = "搜索...",
        font_size: f32 = 14.0,
        on_search: ?*const fn (self: *SearchEntry, text: []const u8) void = null,
    }) !*SearchEntry {
        const self = try allocator.create(SearchEntry);
        const input = try Entry.create(allocator, .{
            .placeholder = opts.placeholder,
            .font_size = opts.font_size,
        });
        self.* = .{
            .base = .{
                .vtable = &vtable,
                .id = widget_mod.genWidgetId(),
            },
            .allocator = allocator,
            .input = input,
            .placeholder = opts.placeholder,
            .font_size = opts.font_size,
            .on_search = opts.on_search,
        };
        // 先添加 child, 再绑定 on_change wrapper (wrapper 需要 parent 指针)
        try self.base.addChild(allocator, &input.base);
        input.on_change = searchEntryChangeWrapper;
        self.base.accessibility = .{ .role = .text, .label = "search" };
        return self;
    }

    pub fn destroy(self: *SearchEntry, allocator: std.mem.Allocator) void {
        self.input.destroy(allocator);
        self.base.background.deinit(allocator);
        self.base.children.deinit(allocator);
        allocator.destroy(self);
    }

    pub fn getText(self: *SearchEntry) []const u8 {
        return self.input.getText();
    }

    pub fn setText(self: *SearchEntry, text: []const u8) !void {
        try self.input.setText(text);
        self.base.markDirty();
    }

    /// 清空搜索文本 (GTK4: gtk_search_entry.set_text(""))
    pub fn clear(self: *SearchEntry) void {
        self.input.setText("") catch {};
    }

    /// GTK4: gtk_search_entry_get_event_controller_key / Editable interface
    pub fn getEditable(self: *SearchEntry) Editable {
        return self.input.getEditable();
    }

    /// GTK4: gtk_search_entry_get_buffer
    pub fn getEntryBuffer(self: *const SearchEntry) ?*EntryBuffer {
        return self.input.getEntryBuffer();
    }

    pub fn setEntryBuffer(self: *SearchEntry, buf: ?*EntryBuffer) void {
        self.input.setEntryBuffer(buf);
    }

    // ── GTK4 SearchEntry 新增 API ──────────────────────────────────────────

    /// GTK4: gtk_search_entry_set_loading
    pub fn setLoading(self: *SearchEntry, loading: bool) void {
        self.loading = loading;
        self.base.markDirty();
    }

    /// GTK4: gtk_search_entry_get_loading
    pub fn isLoading(self: *const SearchEntry) bool {
        return self.loading;
    }

    /// GTK4: gtk_search_entry_set_search_delay
    pub fn setSearchDelay(self: *SearchEntry, delay_ms: u32) void {
        self.search_delay_ms = delay_ms;
    }

    /// GTK4: gtk_search_entry_get_search_delay
    pub fn getSearchDelay(self: *const SearchEntry) u32 {
        return self.search_delay_ms;
    }

    /// GTK4: gtk_search_entry_set_key_capture_widget
    pub fn setKeyCaptureWidget(self: *SearchEntry, widget: ?*Widget) void {
        self.key_capture_widget = widget;
    }

    /// GTK4: gtk_search_entry_get_key_capture_widget
    pub fn getKeyCaptureWidget(self: *const SearchEntry) ?*Widget {
        return self.key_capture_widget;
    }

    // ── Entry API 代理 (GTK4 对齐) ─────────────────────────────────────────

    pub fn getPlaceholderText(self: *const SearchEntry) []const u8 {
        return self.input.getPlaceholderText();
    }
    pub fn setPlaceholderText(self: *SearchEntry, text: []const u8) void {
        self.placeholder = text;
        self.input.setPlaceholderText(text);
        self.base.markDirty();
    }
    pub fn getMaxLength(self: *const SearchEntry) u32 {
        return self.input.getMaxLength();
    }
    pub fn setMaxLength(self: *SearchEntry, max: u32) void {
        self.input.setMaxLength(max);
    }
    pub fn getCursorPosition(self: *const SearchEntry) usize {
        return self.input.getCursorPosition();
    }
    pub fn setCursorPosition(self: *SearchEntry, pos: usize) void {
        self.input.setCursorPosition(pos);
    }
    pub fn selectRegion(self: *SearchEntry, start: usize, end: usize) void {
        self.input.selectRegion(start, end);
    }
    pub fn getSelectionBounds(self: *const SearchEntry, out_start: *usize, out_end: *usize) bool {
        return self.input.getSelectionBounds(out_start, out_end);
    }
    pub fn selectAll(self: *SearchEntry) void {
        self.input.selectAll();
    }
    pub fn hasSelection(self: *const SearchEntry) bool {
        return self.input.hasSelection();
    }
    pub fn deleteSelection(self: *SearchEntry) void {
        self.input.deleteSelection();
    }

    // ── VTable 实现 ──────────────────────────────────────────────────────────

    const vtable = Widget.VTable{
        .type_name = "search_entry",
        .measure = measure,
        .paint = paint,
        .on_event = onEvent,
        .tick = tickFn,
        .focusable = false,
        .destroy = destroyVTable,
    };

    /// 每帧推进：search_delay 定时器超时触发 on_search(delay_pending_text)
    fn tickFn(w: *Widget, delta_ms: u32) void {
        const self: *SearchEntry = @fieldParentPtr("base", w);
        _ = delta_ms;
        if (!self.delay_timer_active) return;
        const now_ms: u64 = perf.nowMs();
        if (now_ms - self.delay_timer_start >= self.search_delay_ms) {
            self.delay_timer_active = false;
            if (self.on_search) |cb| cb(self, self.delay_pending_text);
        }
    }

    /// 文本变化后按 search_delay 决定：立即触发 或 启动/重置延迟定时器
    fn handleTextChanged(self: *SearchEntry) void {
        const text = self.getText();
        if (self.search_delay_ms == 0) {
            if (self.on_search) |cb| cb(self, text);
            return;
        }
        // 启动或重置定时器：只要 delay 期间又输入一次，重新计时（debounce）
        self.delay_pending_text = text;
        self.delay_timer_start = perf.nowMs();
        self.delay_timer_active = true;
    }

    /// 立即触发 on_search 并取消定时器（ESC/clear 清空等强交互场景）
    fn emitSearchNow(self: *SearchEntry, text: []const u8) void {
        self.delay_timer_active = false;
        if (self.on_search) |cb| cb(self, text);
    }

    fn destroyVTable(w: *Widget, allocator: std.mem.Allocator) void {
        const self: *SearchEntry = @fieldParentPtr("base", w);
        self.destroy(allocator);
    }

    fn measure(w: *Widget, ctx: *PaintContext, constraints: layout_mod.Constraints) math.Size(f32) {
        const self: *SearchEntry = @fieldParentPtr("base", w);

        // 测量内部 Entry (减去图标空间)
        const icon_space = self.icon_padding * 2 + self.icon_size;
        const clear_space = self.icon_padding + self.clear_size + self.icon_padding;
        const adjusted = layout_mod.Constraints{
            .min_width = 0,
            .max_width = if (constraints.max_width < std.math.inf(f32)) @max(0, constraints.max_width - icon_space - clear_space) else std.math.inf(f32),
            .min_height = 0,
            .max_height = constraints.max_height,
        };
        const input_size = self.input.base.vtable.measure(&self.input.base, ctx, adjusted);

        const height = @max(input_size.height, self.icon_size + self.icon_padding * 2);
        return .{
            .width = input_size.width + icon_space + clear_space,
            .height = height,
        };
    }

    fn paint(w: *Widget, ctx: *PaintContext) void {
        const self: *SearchEntry = @fieldParentPtr("base", w);
        const rx = ctx.offset_x + w.rect.x;
        const ry = ctx.offset_y + w.rect.y;

        // 背景
        const border = if (self.input.base.state.focused) self.focus_border else self.border_color;
        ctx.renderer.fillRoundedRect(
            .{ .x = rx, .y = ry, .width = w.rect.width, .height = w.rect.height },
            self.corner_radius,
            self.bg_color,
        ) catch {};

        // 边框
        ctx.renderer.strokeRoundedRect(
            .{ .x = rx, .y = ry, .width = w.rect.width, .height = w.rect.height },
            self.corner_radius,
            1.0,
            border,
        ) catch {};

        // ── 左侧图标: loading 时显示旋转指示器, 否则放大镜 ──
        const icon_x = rx + self.icon_padding;
        const icon_y = ry + (w.rect.height - self.icon_size) / 2.0;
        if (self.loading) {
            // 加载动画: 旋转的弧形
            const cx = icon_x + self.icon_size / 2.0;
            const cy = icon_y + self.icon_size / 2.0;
            const r = self.icon_size * 0.4;
            // 简化: 画一个开口圆环 (8个小方块模拟)
            const time_ms = @as(u64, perf.nowMs());
            const phase = @as(f32, @floatFromInt(time_ms % 1000)) / 1000.0;
            var i: u32 = 0;
            while (i < 8) : (i += 1) {
                const angle = (2.0 * 3.14159 * @as(f32, @floatFromInt(i)) / 8.0) + phase * 2.0 * 3.14159;
                const alpha: f32 = if (i == 0 or i == 1) 1.0 else if (i == 2 or i == 3) 0.6 else 0.25;
                const px = cx + @cos(angle) * r;
                const py = cy + @sin(angle) * r;
                const dot_size: f32 = 2.0;
                var dot_color = self.icon_color;
                dot_color.a = @as(u8, @intFromFloat(@as(f32, @floatFromInt(dot_color.a)) * alpha));
                ctx.renderer.fillRoundedRect(
                    .{ .x = px - dot_size / 2.0, .y = py - dot_size / 2.0, .width = dot_size, .height = dot_size },
                    dot_size / 2.0,
                    dot_color,
                ) catch {};
            }
        } else {
            // 放大镜
            const cx = icon_x + self.icon_size * 0.4;
            const cy = icon_y + self.icon_size * 0.4;
            const r = self.icon_size * 0.3;

            // 画圆边框 -- 用 4 个小矩形描边近似
            ctx.renderer.fillRect(.{ .x = cx - r, .y = cy - r - 1, .width = r * 2, .height = 1.5 }, self.icon_color) catch {};
            ctx.renderer.fillRect(.{ .x = cx - r, .y = cy + r - 0.5, .width = r * 2, .height = 1.5 }, self.icon_color) catch {};
            ctx.renderer.fillRect(.{ .x = cx - r - 1, .y = cy - r, .width = 1.5, .height = r * 2 }, self.icon_color) catch {};
            ctx.renderer.fillRect(.{ .x = cx + r - 0.5, .y = cy - r, .width = 1.5, .height = r * 2 }, self.icon_color) catch {};

            // 画手柄 (斜线)
            const handle_start_x = cx + r * 0.7;
            const handle_start_y = cy + r * 0.7;
            const handle_end_x = icon_x + self.icon_size - 2;
            const handle_end_y = icon_y + self.icon_size - 2;
            const hx = (handle_start_x + handle_end_x) / 2.0 - 1.0;
            const hy = (handle_start_y + handle_end_y) / 2.0 - 1.0;
            ctx.renderer.fillRect(.{ .x = hx, .y = hy, .width = 3.0, .height = 3.0 }, self.icon_color) catch {};
        }

        // ── 绘制内部 Entry ──
        // Entry 位置: 左侧图标之后, 右侧清除按钮之前
        const input_x = rx + self.icon_padding * 2 + self.icon_size;
        const input_w = w.rect.width - (self.icon_padding * 2 + self.icon_size) - (self.icon_padding + self.clear_size + self.icon_padding);
        // 设置 Entry 的 rect
        self.input.base.rect = .{
            .x = input_x - rx, // 相对父控件
            .y = 0,
            .width = input_w,
            .height = w.rect.height,
        };
        // 绘制 Entry (调用其 paintTree)
        self.input.base.paintTree(ctx);

        // ── 右侧清除按钮 (有文本时显示) ──
        const text = self.input.getText();
        if (text.len > 0) {
            const clear_x = rx + w.rect.width - self.icon_padding - self.clear_size;
            const clear_y = ry + (w.rect.height - self.clear_size) / 2.0;
            const clear_cx = clear_x + self.clear_size / 2.0;
            const clear_cy = clear_y + self.clear_size / 2.0;

            // 悬停背景
            if (self.clear_btn_hover or self.clear_btn_pressed) {
                const bg = if (self.clear_btn_pressed) math.Color.hex(0x334155FF) else math.Color.hex(0x1E293BFF);
                ctx.renderer.fillRoundedRect(
                    .{ .x = clear_x - 2, .y = clear_y - 2, .width = self.clear_size + 4, .height = self.clear_size + 4 },
                    (self.clear_size + 4) / 2.0,
                    bg,
                ) catch {};
            }

            // 画 X
            const x_color = if (self.clear_btn_hover) self.clear_hover_color else self.clear_color;
            const x_len = self.clear_size * 0.3;
            // 横竖线模拟 X (简化: 画十字)
            ctx.renderer.fillRect(
                .{ .x = clear_cx - x_len, .y = clear_cy - x_len, .width = x_len * 2, .height = 2.0 },
                x_color,
            ) catch {};
            ctx.renderer.fillRect(
                .{ .x = clear_cx - 1.0, .y = clear_cy - x_len, .width = 2.0, .height = x_len * 2 },
                x_color,
            ) catch {};
        }
    }

    fn onEvent(w: *Widget, event: *const pal.Event, ectx: *EventContext) EventResult {
        const self: *SearchEntry = @fieldParentPtr("base", w);
        const abs = w.absoluteRect();

        // ── P34.2: key_capture_widget 按键先转发给捕获 widget（如上层 SearchBar 处理 Ctrl+F）──
        if (event.* == .key) {
            if (self.key_capture_widget) |kcw| {
                const r = Widget.dispatchEvent(kcw, event, ectx);
                if (r == .handled) return .handled;
            }
        }

        // 先处理清除按钮的点击
        switch (event.*) {
            .mouse_button => |mb| {
                if (mb.button == .left) {
                    const mx = @as(f32, @floatFromInt(mb.x)) - abs.x;
                    const my = @as(f32, @floatFromInt(mb.y)) - abs.y;

                    // 清除按钮区域
                    const clear_x = w.rect.width - self.icon_padding - self.clear_size;
                    const clear_y = (w.rect.height - self.clear_size) / 2.0;
                    const in_clear = mx >= clear_x - 4 and mx <= clear_x + self.clear_size + 4 and
                        my >= clear_y - 4 and my <= clear_y + self.clear_size + 4;

                    if (in_clear and self.input.getText().len > 0) {
                        if (mb.state == .pressed) {
                            self.clear_btn_pressed = true;
                            w.markDirty();
                            return .handled;
                        } else {
                            if (self.clear_btn_pressed) {
                                self.clear_btn_pressed = false;
                                // 清空文本 ── 立即 on_search（不走 delay）
                                self.input.setText("") catch {};
                                self.emitSearchNow("");
                                w.markDirty();
                                return .handled;
                            }
                        }
                    } else {
                        if (mb.state == .released) {
                            self.clear_btn_pressed = false;
                        }
                    }
                }
            },
            .mouse_move => |mm| {
                const mx = @as(f32, @floatFromInt(mm.x)) - abs.x;
                const my = @as(f32, @floatFromInt(mm.y)) - abs.y;
                const clear_x = w.rect.width - self.icon_padding - self.clear_size;
                const clear_y = (w.rect.height - self.clear_size) / 2.0;
                const in_clear = mx >= clear_x - 4 and mx <= clear_x + self.clear_size + 4 and
                    my >= clear_y - 4 and my <= clear_y + self.clear_size + 4;
                const new_hover = in_clear and self.input.getText().len > 0;
                if (new_hover != self.clear_btn_hover) {
                    self.clear_btn_hover = new_hover;
                    w.markDirty();
                }
            },
            .key => |key| {
                if (key.state == .pressed and key.key == .escape) {
                    // ESC 清空 ── 有文本才清除，且立即 on_search（不走 delay）
                    if (self.input.getText().len > 0) {
                        self.input.setText("") catch {};
                        self.emitSearchNow("");
                        w.markDirty();
                        return .handled;
                    }
                }
            },
            else => {},
        }

        // 转发事件给内部 Entry。
        // 注意: 必须直接调用内部 Entry 的 handler, 不能走 dispatchEvent —— dispatchEvent
        // 处理完目标后会向父控件冒泡, 而 SearchEntry 正是 Entry 的父, 冒泡回来又会调用
        // 本 onEvent, 再次 dispatchEvent, 形成无限递归 → 栈溢出 (打字时在焦点 Entry 上触发)。
        // 这里只复刻 dispatchEvent 对目标控件自身的处理 (event controllers + on_event), 不冒泡。
        const input_w = &self.input.base;
        var result: EventResult = .ignored;
        if (!input_w.state.disabled) {
            for (input_w.event_controllers.items) |*ctrl| {
                if (ctrl.handle_event(ctrl.self_ptr, input_w, event, ectx) == .handled) {
                    result = .handled;
                    break;
                }
            }
            if (result != .handled) {
                if (input_w.vtable.on_event) |h| result = h(input_w, event, ectx);
            }
        }

        // 文本变化：按 search_delay 规则走 debounce 或立即触发
        if (event.* == .text_input or event.* == .key) {
            self.handleTextChanged();
        }

        return result;
    }
};
