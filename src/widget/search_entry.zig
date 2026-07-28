//! SearchEntry 控件 - 搜索输入框 (对标 GtkSearchEntry)
//! 在 TextInput 基础上增加左侧搜索图标和右侧清除按钮

const std = @import("std");
const math = @import("../math.zig");
const widget_mod = @import("widget.zig");
const layout_mod = @import("../layout/engine.zig");
const pal = @import("../pal/pal.zig");
const styled_text = @import("../text/styled_text.zig");
const text_input_mod = @import("text_input.zig");

const Widget = widget_mod.Widget;
const PaintContext = widget_mod.PaintContext;
const EventContext = widget_mod.EventContext;
const EventResult = widget_mod.EventResult;
const TextInput = text_input_mod.TextInput;

pub const SearchEntry = struct {
    base: Widget,
    allocator: std.mem.Allocator,
    input: *TextInput,
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

    pub fn create(allocator: std.mem.Allocator, opts: struct {
        placeholder: []const u8 = "搜索...",
        font_size: f32 = 14.0,
        on_search: ?*const fn (self: *SearchEntry, text: []const u8) void = null,
    }) !*SearchEntry {
        const self = try allocator.create(SearchEntry);
        const input = try TextInput.create(allocator, .{
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

    // ── VTable 实现 ──────────────────────────────────────────────────────────

    const vtable = Widget.VTable{
        .type_name = "search_entry",
        .measure = measure,
        .paint = paint,
        .on_event = onEvent,
        .focusable = false,
        .destroy = destroyVTable,
    };

    fn destroyVTable(w: *Widget, allocator: std.mem.Allocator) void {
        const self: *SearchEntry = @fieldParentPtr("base", w);
        self.destroy(allocator);
    }

    fn measure(w: *Widget, ctx: *PaintContext, constraints: layout_mod.Constraints) math.Size(f32) {
        const self: *SearchEntry = @fieldParentPtr("base", w);

        // 测量内部 TextInput (减去图标空间)
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

        // ── 左侧搜索图标 (放大镜) ──
        const icon_x = rx + self.icon_padding;
        const icon_y = ry + (w.rect.height - self.icon_size) / 2.0;
        const cx = icon_x + self.icon_size * 0.4;
        const cy = icon_y + self.icon_size * 0.4;
        const r = self.icon_size * 0.3;

        // 画圆 (用 fillRoundedRect 近似)
        ctx.renderer.fillRoundedRect(
            .{ .x = cx - r, .y = cy - r, .width = r * 2, .height = r * 2 },
            r,
            math.Color.hex(0x00000000),
        ) catch {};
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
        // 用小矩形近似斜线 (简化: 画一个对角小方块)
        const hx = (handle_start_x + handle_end_x) / 2.0 - 1.0;
        const hy = (handle_start_y + handle_end_y) / 2.0 - 1.0;
        ctx.renderer.fillRect(.{ .x = hx, .y = hy, .width = 3.0, .height = 3.0 }, self.icon_color) catch {};

        // ── 绘制内部 TextInput ──
        // TextInput 位置: 左侧图标之后, 右侧清除按钮之前
        const input_x = rx + self.icon_padding * 2 + self.icon_size;
        const input_w = w.rect.width - (self.icon_padding * 2 + self.icon_size) - (self.icon_padding + self.clear_size + self.icon_padding);
        // 设置 TextInput 的 rect
        self.input.base.rect = .{
            .x = input_x - rx, // 相对父控件
            .y = 0,
            .width = input_w,
            .height = w.rect.height,
        };
        // 绘制 TextInput (调用其 paintTree)
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
                                // 清空文本
                                self.input.setText("") catch {};
                                if (self.on_search) |cb| cb(self, "");
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
                    // ESC 清空
                    if (self.input.getText().len > 0) {
                        self.input.setText("") catch {};
                        if (self.on_search) |cb| cb(self, "");
                        w.markDirty();
                        return .handled;
                    }
                }
            },
            else => {},
        }

        // 转发事件给 TextInput
        const result = self.input.base.dispatchEvent(event, ectx);

        // 文本变化时触发 on_search
        if (event.* == .text_input or event.* == .key) {
            if (self.on_search) |cb| cb(self, self.input.getText());
        }

        return result;
    }
};
