//! TextArea 控件 - 多行文本编辑 (多行光标/选区/滚动)

const std = @import("std");
const math = @import("../math.zig");
const widget_mod = @import("widget.zig");
const layout_mod = @import("../layout/engine.zig");
const pal = @import("../pal/pal.zig");
const text_layout = @import("../text/layout.zig");
const coretext = @import("../text/coretext.zig");

const Widget = widget_mod.Widget;
const PaintContext = widget_mod.PaintContext;
const EventContext = widget_mod.EventContext;
const EventResult = widget_mod.EventResult;

pub const TextArea = struct {
    base: Widget,
    allocator: std.mem.Allocator,
    text: std.ArrayListUnmanaged(u8),
    cursor: usize = 0, // 字节偏移
    selection_start: ?usize = null,
    desired_col: ?usize = null, // 上下移动时保持列位置
    font_size: f32,
    scroll_y: f32 = 0,
    placeholder: []const u8,
    on_change: ?*const fn (self: *TextArea, text: []const u8) void,
    // 样式
    bg_color: math.Color = math.Color.hex(0x1E293BFF),
    border_color: math.Color = math.Color.hex(0x334155FF),
    focus_border: math.Color = math.Color.hex(0x3B82F6FF),
    text_color: math.Color = math.Color.hex(0xF8FAFCFF),
    placeholder_color: math.Color = math.Color.hex(0x64748BFF),
    selection_color: math.Color = math.Color.hex(0x3B82F644),
    cursor_color: math.Color = math.Color.hex(0xF8FAFCFF),
    corner_radius: f32 = 8.0,
    padding: f32 = 10.0,
    cursor_visible: bool = true,
    /// 文本水平对齐方式 (默认左对齐)
    text_align: text_layout.TextAlign = .left,

    pub fn create(allocator: std.mem.Allocator, opts: struct {
        placeholder: []const u8 = "",
        font_size: f32 = 14.0,
        on_change: ?*const fn (self: *TextArea, text: []const u8) void = null,
        text_align: text_layout.TextAlign = .left,
    }) !*TextArea {
        const self = try allocator.create(TextArea);
        self.* = .{
            .base = .{
                .vtable = &vtable,
                .id = widget_mod.genWidgetId(),
            },
            .allocator = allocator,
            .text = .{ .items = &.{}, .capacity = 0 },
            .font_size = opts.font_size,
            .placeholder = opts.placeholder,
            .on_change = opts.on_change,
            .text_align = opts.text_align,
        };
        return self;
    }

    pub fn destroy(self: *TextArea, allocator: std.mem.Allocator) void {
        self.text.deinit(allocator);
        self.base.children.deinit(allocator);
        allocator.destroy(self);
    }

    pub fn getText(self: *const TextArea) []const u8 {
        return self.text.items;
    }

    pub fn setText(self: *TextArea, new_text: []const u8) !void {
        self.text.clearRetainingCapacity();
        try self.text.appendSlice(self.allocator, new_text);
        self.cursor = new_text.len;
        self.selection_start = null;
        self.desired_col = null;
        self.base.markDirty();
    }

    /// 设置文本对齐方式 (左/居中/右; 多行编辑两端对齐按左对齐处理)
    pub fn setTextAlign(self: *TextArea, alignment: text_layout.TextAlign) void {
        self.text_align = alignment;
        self.base.markDirty();
    }

    pub fn hasSelection(self: *const TextArea) bool {
        return self.selection_start != null and self.selection_start.? != self.cursor;
    }

    // ── 行辅助 (基于 '\n' 扫描) ─────────────────────────────────────────────

    fn lineHeight(self: *const TextArea) f32 {
        return self.font_size * 1.4;
    }

    fn charWidth(self: *const TextArea) f32 {
        return self.font_size * 0.6;
    }

    /// 包含 offset 的行的起始字节偏移
    fn lineStart(self: *const TextArea, offset: usize) usize {
        const items = self.text.items;
        if (offset == 0) return 0;
        var i = @min(offset, items.len);
        while (i > 0) : (i -= 1) {
            if (items[i - 1] == '\n') return i;
        }
        return 0;
    }

    /// 包含 offset 的行的结束字节偏移 ('\n' 之前或文本末尾)
    fn lineEnd(self: *const TextArea, offset: usize) usize {
        const items = self.text.items;
        var i = @min(offset, items.len);
        while (i < items.len) : (i += 1) {
            if (items[i] == '\n') return i;
        }
        return items.len;
    }

    /// offset 所在的行号 (0-based)
    fn lineIndex(self: *const TextArea, offset: usize) usize {
        const items = self.text.items;
        var line: usize = 0;
        var i: usize = 0;
        const end = @min(offset, items.len);
        while (i < end) : (i += 1) {
            if (items[i] == '\n') line += 1;
        }
        return line;
    }

    /// 总行数
    fn lineCount(self: *const TextArea) usize {
        return self.lineIndex(self.text.items.len) + 1;
    }

    /// 第 line 行的起始字节偏移
    fn lineStartAtIndex(self: *const TextArea, line: usize) usize {
        if (line == 0) return 0;
        const items = self.text.items;
        var current_line: usize = 0;
        var i: usize = 0;
        while (i < items.len) : (i += 1) {
            if (items[i] == '\n') {
                current_line += 1;
                if (current_line == line) return i + 1;
            }
        }
        return items.len;
    }

    /// 给定行号和列号 (字节列) 求字节偏移, 钳制到行尾
    fn offsetAt(self: *const TextArea, line: usize, col: usize) usize {
        const start = self.lineStartAtIndex(line);
        const end = self.lineEnd(start);
        const line_len = end - start;
        return start + @min(col, line_len);
    }

    /// offset 处的列号 (字节列)
    fn colOf(self: *const TextArea, offset: usize) usize {
        return offset - self.lineStart(offset);
    }

    /// 内容总高度
    fn contentHeight(self: *const TextArea) f32 {
        return @as(f32, @floatFromInt(self.lineCount())) * self.lineHeight();
    }

    fn maxScroll(self: *const TextArea) f32 {
        const visible = self.base.rect.height - self.padding * 2;
        const content = self.contentHeight();
        return @max(0, content - visible);
    }

    fn clampScroll(self: *TextArea) void {
        self.scroll_y = std.math.clamp(self.scroll_y, 0, self.maxScroll());
    }

    /// 确保光标在可视区域内 (自动滚动)
    fn ensureCursorVisible(self: *TextArea) void {
        const lh = self.lineHeight();
        const line = self.lineIndex(self.cursor);
        const cursor_top = @as(f32, @floatFromInt(line)) * lh;
        const cursor_bottom = cursor_top + lh;
        const view_top = self.scroll_y;
        const view_bottom = self.scroll_y + self.base.rect.height - self.padding * 2;

        if (cursor_top < view_top) {
            self.scroll_y = cursor_top;
        } else if (cursor_bottom > view_bottom) {
            self.scroll_y = cursor_bottom - (self.base.rect.height - self.padding * 2);
        }
        self.clampScroll();
    }

    // ── VTable ──────────────────────────────────────────────────────────────

    const vtable = Widget.VTable{
        .type_name = "text_area",
        .measure = measure,
        .paint = paint,
        .on_event = onEvent,
        .focusable = true,
        .destroy = destroyVTable,
    };

    fn destroyVTable(w: *Widget, allocator: std.mem.Allocator) void {
        const self: *TextArea = @fieldParentPtr("base", w);
        self.destroy(allocator);
    }

    fn measure(w: *Widget, ctx: *PaintContext, constraints: layout_mod.Constraints) math.Size(f32) {
        const self: *TextArea = @fieldParentPtr("base", w);
        _ = ctx;
        _ = constraints;
        return .{ .width = 320, .height = self.lineHeight() * 5 + self.padding * 2 };
    }

    fn paint(w: *Widget, ctx: *PaintContext) void {
        const self: *TextArea = @fieldParentPtr("base", w);
        const rx = ctx.offset_x + w.rect.x;
        const ry = ctx.offset_y + w.rect.y;
        const rw = w.rect.width;
        const rh = w.rect.height;

        // 背景 + 边框
        const border_c = if (w.state.focused) self.focus_border else self.border_color;
        ctx.renderer.fillRoundedRect(.{ .x = rx, .y = ry, .width = rw, .height = rh }, self.corner_radius, border_c) catch {};
        ctx.renderer.fillRoundedRect(.{ .x = rx + 1.5, .y = ry + 1.5, .width = rw - 3, .height = rh - 3 }, self.corner_radius - 1, self.bg_color) catch {};

        const text_x = rx + self.padding;
        const lh = self.lineHeight();
        const avail_w = rw - self.padding * 2;

        var font = coretext.CtFont.create(null, self.font_size, 400) catch return;
        defer font.destroy();

        if (self.text.items.len == 0 and !w.state.focused) {
            if (self.placeholder.len > 0) {
                self.drawLabel(ctx, &font, self.placeholder, text_x, ry + self.padding, self.placeholder_color);
            }
            return;
        }

        // 可视行范围
        const first_line: usize = @intFromFloat(@max(0, @floor(self.scroll_y / lh)));
        const visible_lines: usize = @as(usize, @intFromFloat(@ceil((rh - self.padding * 2) / lh))) + 1;
        const total_lines = self.lineCount();

        // 选区范围
        const has_sel = self.hasSelection();
        const sel_start = if (has_sel) @min(self.selection_start.?, self.cursor) else 0;
        const sel_end = if (has_sel) @max(self.selection_start.?, self.cursor) else 0;

        var li: usize = first_line;
        while (li < first_line + visible_lines and li < total_lines) : (li += 1) {
            const ls = self.lineStartAtIndex(li);
            const le = self.lineEnd(ls);
            const line_y = ry + self.padding + @as(f32, @floatFromInt(li)) * lh - self.scroll_y;

            // 该行对齐偏移
            const line_slice = self.text.items[ls..le];
            const offset = self.lineAlignOffset(font.measureText(line_slice), avail_w);

            // 该行选区高亮
            if (has_sel and ls < sel_end and le > sel_start) {
                const hl_start = @max(ls, sel_start);
                const hl_end = @min(le, sel_end);
                const sx: f32 = @floatFromInt(hl_start - ls);
                const ex: f32 = @floatFromInt(hl_end - ls);
                ctx.renderer.fillRect(
                    .{ .x = text_x + offset + sx * self.charWidth(), .y = line_y + 2, .width = (ex - sx) * self.charWidth(), .height = lh - 4 },
                    self.selection_color,
                ) catch {};
            }

            // 该行文本
            if (le > ls) {
                self.drawLabel(ctx, &font, line_slice, text_x + offset, line_y, self.text_color);
            }
        }

        // 光标
        if (w.state.focused and self.cursor_visible) {
            const cursor_line = self.lineIndex(self.cursor);
            const cursor_col = self.colOf(self.cursor);
            // 光标所在行的对齐偏移
            const cls = self.lineStartAtIndex(cursor_line);
            const cle = self.lineEnd(cls);
            const c_offset = self.lineAlignOffset(font.measureText(self.text.items[cls..cle]), avail_w);
            const cx = text_x + c_offset + @as(f32, @floatFromInt(cursor_col)) * self.charWidth();
            const cy = ry + self.padding + @as(f32, @floatFromInt(cursor_line)) * lh - self.scroll_y;
            if (cy >= ry and cy + lh <= ry + rh) {
                ctx.renderer.fillRect(
                    .{ .x = cx, .y = cy + 3, .width = 2, .height = lh - 6 },
                    self.cursor_color,
                ) catch {};
            }
        }

        // 滚动条
        if (self.maxScroll() > 0) {
            const sb_h = rh - self.padding * 2;
            const thumb_h = @max(20.0, sb_h * (sb_h / self.contentHeight()));
            const thumb_y = ry + self.padding + (self.scroll_y / self.maxScroll()) * (sb_h - thumb_h);
            ctx.renderer.fillRoundedRect(.{ .x = rx + rw - 6, .y = thumb_y, .width = 4, .height = thumb_h }, 2, math.Color.hex(0x475569FF)) catch {};
        }
    }

    /// 逐行文本对齐偏移 (左/居中/右; 两端对齐按左对齐; 行溢出时保持左对齐)
    fn lineAlignOffset(self: *const TextArea, line_w: f32, avail_w: f32) f32 {
        const extra = avail_w - line_w;
        if (extra <= 0) return 0;
        return switch (self.text_align) {
            .center => extra / 2.0,
            .right => extra,
            .left, .justify => 0,
        };
    }

    fn drawLabel(self: *TextArea, ctx: *PaintContext, font: *const coretext.CtFont, text: []const u8, x: f32, y: f32, color: math.Color) void {
        if (text.len == 0) return;

        var tl = text_layout.TextLayout.layout(
            ctx.allocator,
            &ctx.renderer.glyph_atlas.?,
            ctx.renderer.device,
            text,
            .{ .font = font, .font_size = self.font_size },
        ) catch return;
        defer tl.deinit();

        ctx.renderer.drawText(&tl, x, y, color) catch {};
    }

    fn onEvent(w: *Widget, event: *const pal.Event, ectx: *EventContext) EventResult {
        const self: *TextArea = @fieldParentPtr("base", w);
        _ = ectx;

        switch (event.*) {
            .key => |k| {
                if (k.state != .pressed or !w.state.focused) return .ignored;
                const shift = k.modifiers.shift;

                switch (k.key) {
                    .left => {
                        self.beginSelect(shift);
                        if (self.cursor > 0) self.cursor -= 1;
                        self.desired_col = null;
                        self.afterMove();
                        return .handled;
                    },
                    .right => {
                        self.beginSelect(shift);
                        if (self.cursor < self.text.items.len) self.cursor += 1;
                        self.desired_col = null;
                        self.afterMove();
                        return .handled;
                    },
                    .up => {
                        self.beginSelect(shift);
                        self.moveVertical(-1);
                        self.afterMove();
                        return .handled;
                    },
                    .down => {
                        self.beginSelect(shift);
                        self.moveVertical(1);
                        self.afterMove();
                        return .handled;
                    },
                    .home => {
                        self.beginSelect(shift);
                        self.cursor = self.lineStart(self.cursor);
                        self.desired_col = null;
                        self.afterMove();
                        return .handled;
                    },
                    .end => {
                        self.beginSelect(shift);
                        self.cursor = self.lineEnd(self.cursor);
                        self.desired_col = null;
                        self.afterMove();
                        return .handled;
                    },
                    .page_up => {
                        self.beginSelect(shift);
                        const lines: usize = @intFromFloat((self.base.rect.height - self.padding * 2) / self.lineHeight());
                        var n = lines;
                        while (n > 0 and self.cursor > 0) : (n -= 1) {
                            self.moveVertical(-1);
                        }
                        self.afterMove();
                        return .handled;
                    },
                    .page_down => {
                        self.beginSelect(shift);
                        const lines: usize = @intFromFloat((self.base.rect.height - self.padding * 2) / self.lineHeight());
                        var n = lines;
                        while (n > 0 and self.cursor < self.text.items.len) : (n -= 1) {
                            self.moveVertical(1);
                        }
                        self.afterMove();
                        return .handled;
                    },
                    .backspace => {
                        if (self.hasSelection()) {
                            self.deleteSelection();
                        } else if (self.cursor > 0) {
                            _ = self.text.orderedRemove(self.cursor - 1);
                            self.cursor -= 1;
                            self.desired_col = null;
                            self.notifyChange();
                        }
                        self.afterMove();
                        return .handled;
                    },
                    .delete => {
                        if (self.hasSelection()) {
                            self.deleteSelection();
                        } else if (self.cursor < self.text.items.len) {
                            _ = self.text.orderedRemove(self.cursor);
                            self.notifyChange();
                        }
                        self.afterMove();
                        return .handled;
                    },
                    .enter => {
                        // 插入换行
                        if (self.hasSelection()) self.deleteSelection();
                        self.text.insertSlice(self.allocator, self.cursor, "\n") catch return .handled;
                        self.cursor += 1;
                        self.desired_col = null;
                        self.notifyChange();
                        self.afterMove();
                        return .handled;
                    },
                    .tab => {
                        // 插入 4 空格
                        if (self.hasSelection()) self.deleteSelection();
                        self.text.insertSlice(self.allocator, self.cursor, "    ") catch return .handled;
                        self.cursor += 4;
                        self.desired_col = null;
                        self.notifyChange();
                        self.afterMove();
                        return .handled;
                    },
                    .a => {
                        if (k.modifiers.super_key) {
                            self.selection_start = 0;
                            self.cursor = self.text.items.len;
                            self.base.markDirty();
                            return .handled;
                        }
                    },
                    else => {},
                }
            },
            .text_input => |ti| {
                if (!w.state.focused) return .ignored;
                if (self.hasSelection()) self.deleteSelection();
                var buf: [4]u8 = undefined;
                const len = std.unicode.utf8Encode(ti.codepoint, &buf) catch return .handled;
                self.text.insertSlice(self.allocator, self.cursor, buf[0..len]) catch return .handled;
                self.cursor += len;
                self.desired_col = null;
                self.notifyChange();
                self.afterMove();
                return .handled;
            },
            .scroll => |sc| {
                if (sc.axis == .vertical) {
                    self.scroll_y -= sc.delta * self.lineHeight();
                    self.clampScroll();
                    self.base.markDirty();
                    return .handled;
                }
            },
            .mouse_button => |mb| {
                if (mb.button == .left and mb.state == .pressed) {
                    // 点击定位光标 (行/列)
                    const rel_y: f32 = @floatFromInt(mb.y);
                    const rel_x: f32 = @floatFromInt(mb.x);
                    const line_f = (rel_y - self.padding + self.scroll_y) / self.lineHeight();
                    const line: usize = @intFromFloat(@max(0, @floor(line_f)));
                    const col: usize = @intFromFloat(@max(0, (rel_x - self.padding) / self.charWidth()));
                    self.cursor = self.offsetAt(@min(line, self.lineCount() - 1), col);
                    self.selection_start = null;
                    self.desired_col = null;
                    self.base.markDirty();
                    return .handled;
                }
            },
            else => {},
        }
        return .ignored;
    }

    // ── 内部操作 ────────────────────────────────────────────────────────────

    fn beginSelect(self: *TextArea, shift: bool) void {
        if (shift) {
            if (self.selection_start == null) self.selection_start = self.cursor;
        } else {
            self.selection_start = null;
        }
    }

    /// 垂直移动 delta 行 (-1 上 / +1 下), 保持列位置
    fn moveVertical(self: *TextArea, delta: i32) void {
        const current_line = self.lineIndex(self.cursor);
        const col = self.desired_col orelse self.colOf(self.cursor);
        self.desired_col = col;

        if (delta < 0) {
            if (current_line == 0) {
                self.cursor = 0;
            } else {
                self.cursor = self.offsetAt(current_line - 1, col);
            }
        } else {
            const last_line = self.lineCount() - 1;
            if (current_line >= last_line) {
                self.cursor = self.text.items.len;
            } else {
                self.cursor = self.offsetAt(current_line + 1, col);
            }
        }
    }

    fn afterMove(self: *TextArea) void {
        self.ensureCursorVisible();
        self.base.markDirty();
    }

    fn deleteSelection(self: *TextArea) void {
        if (!self.hasSelection()) return;
        const start = @min(self.selection_start.?, self.cursor);
        const end = @max(self.selection_start.?, self.cursor);
        var i: usize = end;
        while (i > start) : (i -= 1) {
            _ = self.text.orderedRemove(i - 1);
        }
        self.cursor = start;
        self.selection_start = null;
        self.desired_col = null;
        self.notifyChange();
    }

    fn notifyChange(self: *TextArea) void {
        if (self.on_change) |cb| {
            cb(self, self.text.items);
        }
    }
};
