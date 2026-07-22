//! TextInput 控件 - 单行文本输入 (光标/选择/编辑/IME preedit)
//!
//! 跨平台: macOS Metal / Linux Vulkan, 文本渲染经 styled_text。

const std = @import("std");
const math = @import("../math.zig");
const widget_mod = @import("widget.zig");
const layout_mod = @import("../layout/engine.zig");
const pal = @import("../pal/pal.zig");
const styled_text = @import("../text/styled_text.zig");
const r2d = @import("../render2d/r2d.zig");
const align_mod = @import("../text/align.zig");

const Widget = widget_mod.Widget;
const PaintContext = widget_mod.PaintContext;
const EventContext = widget_mod.EventContext;
const EventResult = widget_mod.EventResult;

pub const TextInput = struct {
    base: Widget,
    allocator: std.mem.Allocator,
    text: std.ArrayListUnmanaged(u8),
    cursor: usize = 0, // 字节偏移
    selection_start: ?usize = null,
    dragging: bool = false, // 鼠标拖拽选择中
    font_size: f32,
    placeholder: []const u8,
    on_change: ?*const fn (self: *TextInput, text: []const u8) void,
    on_submit: ?*const fn (self: *TextInput, text: []const u8) void,
    // 样式
    bg_color: math.Color = math.Color.hex(0x1E293BFF),
    border_color: math.Color = math.Color.hex(0x334155FF),
    focus_border: math.Color = math.Color.hex(0x3B82F6FF),
    text_color: math.Color = math.Color.hex(0xF8FAFCFF),
    placeholder_color: math.Color = math.Color.hex(0x64748BFF),
    preedit_color: math.Color = math.Color.hex(0x93C5FDFF),
    selection_color: math.Color = math.Color.hex(0x3B82F644),
    cursor_color: math.Color = math.Color.hex(0xF8FAFCFF),
    corner_radius: f32 = 8.0,
    padding_h: f32 = 12.0,
    cursor_blink_ms: u32 = 0,
    cursor_visible: bool = true,
    /// 文本水平对齐方式 (默认左对齐)
    text_align: align_mod.TextAlign = .left,
    // IME preedit 状态 (由外部通过 setPreedit 设置, 或经 onEvent .ime_preedit 事件)
    preedit_buf: [256]u8 = undefined,
    preedit_len: usize = 0,

    pub fn create(allocator: std.mem.Allocator, opts: struct {
        placeholder: []const u8 = "",
        font_size: f32 = 14.0,
        on_change: ?*const fn (self: *TextInput, text: []const u8) void = null,
        on_submit: ?*const fn (self: *TextInput, text: []const u8) void = null,
        text_align: align_mod.TextAlign = .left,
    }) !*TextInput {
        const self = try allocator.create(TextInput);
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
            .on_submit = opts.on_submit,
            .text_align = opts.text_align,
        };
        return self;
    }

    pub fn destroy(self: *TextInput, allocator: std.mem.Allocator) void {
        self.base.background.deinit(allocator);
        self.text.deinit(allocator);
        self.base.children.deinit(allocator);
        allocator.destroy(self);
    }

    pub fn getText(self: *const TextInput) []const u8 {
        return self.text.items;
    }

    pub fn setText(self: *TextInput, new_text: []const u8) !void {
        self.text.clearRetainingCapacity();
        try self.text.appendSlice(self.allocator, new_text);
        self.cursor = new_text.len;
        self.selection_start = null;
        self.base.markDirty();
    }

    /// 设置文本对齐方式 (左/居中/右; 单行输入两端对齐按左对齐处理)
    pub fn setTextAlign(self: *TextInput, alignment: align_mod.TextAlign) void {
        self.text_align = alignment;
        self.base.markDirty();
    }

    pub fn hasSelection(self: *const TextInput) bool {
        return self.selection_start != null and self.selection_start.? != self.cursor;
    }

    /// 获取当前 preedit 文本
    pub fn getPreedit(self: *const TextInput) []const u8 {
        return self.preedit_buf[0..self.preedit_len];
    }

    /// 设置 preedit 文本 (由外部 IME 通道每帧更新)
    pub fn setPreedit(self: *TextInput, text: []const u8) void {
        const n = @min(text.len, self.preedit_buf.len);
        @memcpy(self.preedit_buf[0..n], text[0..n]);
        self.preedit_len = n;
        self.base.markDirty();
    }

    /// 清除 preedit
    pub fn clearPreedit(self: *TextInput) void {
        self.preedit_len = 0;
    }

    /// 在光标处插入 UTF-8 字节 (IME 提交或外部调用)
    pub fn insertBytes(self: *TextInput, bytes: []const u8) void {
        if (self.hasSelection()) self.deleteSelection();
        self.text.insertSlice(self.allocator, self.cursor, bytes) catch return;
        self.cursor += bytes.len;
        self.notifyChange();
        self.base.markDirty();
    }

    /// 在光标处插入一个 codepoint
    pub fn insertCodepoint(self: *TextInput, cp: u21) void {
        var buf: [4]u8 = undefined;
        const len = std.unicode.utf8Encode(cp, &buf) catch return;
        self.insertBytes(buf[0..len]);
    }

    /// 删除光标前 n 个 codepoint (IME delete_surrounding_text)
    pub fn deleteBeforeCursor(self: *TextInput, n_codepoints: usize) void {
        var i: usize = 0;
        while (i < n_codepoints and self.cursor > 0) : (i += 1) {
            // 回退一个 UTF-8 codepoint
            var pos = self.cursor - 1;
            while (pos > 0 and (self.text.items[pos] & 0xC0) == 0x80) : (pos -= 1) {}
            const start = pos;
            var j: usize = self.cursor;
            while (j > start) : (j -= 1) {
                _ = self.text.orderedRemove(j - 1);
            }
            self.cursor = start;
        }
        self.notifyChange();
        self.base.markDirty();
    }

    // ── VTable ──────────────────────────────────────────────────────────────

    const vtable = Widget.VTable{
        .type_name = "text_input",
        .measure = measure,
        .paint = paint,
        .on_event = onEvent,
        .focusable = true,
        .destroy = destroyVTable,
    };

    fn destroyVTable(w: *Widget, allocator: std.mem.Allocator) void {
        const self: *TextInput = @fieldParentPtr("base", w);
        self.destroy(allocator);
    }

    fn measure(w: *Widget, ctx: *PaintContext, constraints: layout_mod.Constraints) math.Size(f32) {
        const self: *TextInput = @fieldParentPtr("base", w);
        _ = ctx;
        _ = constraints;
        return .{ .width = 240, .height = self.font_size + self.padding_h * 2 };
    }

    fn paint(w: *Widget, ctx: *PaintContext) void {
        const self: *TextInput = @fieldParentPtr("base", w);
        const rx = ctx.offset_x + w.rect.x;
        const ry = ctx.offset_y + w.rect.y;
        const rw = w.rect.width;
        const rh = w.rect.height;

        // 边框 (聚焦时高亮): 先画外框再画内框
        const border_c = if (w.state.focused) self.focus_border else self.border_color;
        ctx.renderer.fillRoundedRect(.{ .x = rx, .y = ry, .width = rw, .height = rh }, self.corner_radius, border_c) catch {};
        ctx.renderer.fillRoundedRect(.{ .x = rx + 1.5, .y = ry + 1.5, .width = rw - 3, .height = rh - 3 }, self.corner_radius - 1, self.bg_color) catch {};

        const text_x = rx + self.padding_h;
        const max_w = rw - self.padding_h * 2;
        // 垂直居中
        const text_y = ry + (rh - self.font_size * 1.2) / 2.0 + self.font_size * 0.85;

        const preedit = self.getPreedit();

        if (self.text.items.len == 0 and preedit.len == 0) {
            // Placeholder
            if (self.placeholder.len > 0 and !w.state.focused) {
                _ = styled_text.drawTextClipped(
                    ctx.renderer,
                    ctx.allocator,
                    self.placeholder,
                    text_x,
                    text_y,
                    .{ .font_size = self.font_size, .font_weight = 400, .color = self.placeholder_color },
                    max_w,
                );
            }
        } else {
            // 对齐偏移
            const style = styled_text.TextStyle{ .font_size = self.font_size, .font_weight = 400 };
            const text_w = styled_text.measureTextWidth(ctx.allocator, self.text.items, style);
            const offset = self.alignOffset(text_w, max_w);

            // 选区高亮 (精确文本测量)
            if (self.hasSelection()) {
                const sel_start = @min(self.selection_start.?, self.cursor);
                const sel_end = @max(self.selection_start.?, self.cursor);
                const s0 = @min(sel_start, self.text.items.len);
                const s1 = @min(sel_end, self.text.items.len);
                const w0 = styled_text.measureTextWidth(ctx.allocator, self.text.items[0..s0], style);
                const w1 = styled_text.measureTextWidth(ctx.allocator, self.text.items[0..s1], style);
                const hx0 = @max(text_x + offset + w0, rx);
                const hx1 = @min(text_x + offset + w1, rx + rw);
                if (hx1 > hx0) {
                    ctx.renderer.fillRect(
                        .{ .x = hx0, .y = ry + 4, .width = hx1 - hx0, .height = rh - 8 },
                        self.selection_color,
                    ) catch {};
                }
            }

            // 已提交文本 (裁剪到可用宽度)
            const committed_w = styled_text.drawTextClipped(
                ctx.renderer,
                ctx.allocator,
                self.text.items,
                text_x + offset,
                text_y,
                .{ .font_size = self.font_size, .font_weight = 400, .color = self.text_color },
                max_w - offset,
            );

            // Preedit 文本 (接在已提交文本后, 浅色显示)
            if (preedit.len > 0) {
                const remaining = max_w - offset - committed_w;
                if (remaining > 0) {
                    _ = styled_text.drawTextClipped(
                        ctx.renderer,
                        ctx.allocator,
                        preedit,
                        text_x + offset + committed_w,
                        text_y,
                        .{ .font_size = self.font_size, .font_weight = 400, .color = self.preedit_color },
                        remaining,
                    );
                }
            }

            // 光标
            if (w.state.focused and self.cursor_visible) {
                const composing = preedit.len > 0;
                const preedit_w = if (composing) styled_text.measureTextWidth(ctx.allocator, preedit, style) else 0;
                const cursor_x = text_x + offset + @min(committed_w + preedit_w, max_w - offset);
                ctx.renderer.fillRect(
                    .{ .x = cursor_x, .y = ry + 5, .width = 2, .height = rh - 10 },
                    self.cursor_color,
                ) catch {};
            }
        }
    }

    /// 单行文本对齐偏移 (左/居中/右; 两端对齐按左对齐; 文本溢出时保持左对齐)
    fn alignOffset(self: *const TextInput, text_w: f32, avail_w: f32) f32 {
        const extra = avail_w - text_w;
        if (extra <= 0) return 0;
        return switch (self.text_align) {
            .center => extra / 2.0,
            .right => extra,
            .left, .justify => 0,
        };
    }

    fn onEvent(w: *Widget, event: *const pal.Event, ectx: *EventContext) EventResult {
        const self: *TextInput = @fieldParentPtr("base", w);
        _ = ectx;

        switch (event.*) {
            .key => |k| {
                if (k.state != .pressed or !w.state.focused) return .ignored;

                const shift = k.modifiers.shift;

                switch (k.key) {
                    .left => {
                        if (shift) {
                            if (self.selection_start == null) self.selection_start = self.cursor;
                        } else {
                            self.selection_start = null;
                        }
                        if (self.cursor > 0) self.cursor -= 1;
                        self.base.markDirty();
                        return .handled;
                    },
                    .right => {
                        if (shift) {
                            if (self.selection_start == null) self.selection_start = self.cursor;
                        } else {
                            self.selection_start = null;
                        }
                        if (self.cursor < self.text.items.len) self.cursor += 1;
                        self.base.markDirty();
                        return .handled;
                    },
                    .home => {
                        if (shift) {
                            if (self.selection_start == null) self.selection_start = self.cursor;
                        } else {
                            self.selection_start = null;
                        }
                        self.cursor = 0;
                        self.base.markDirty();
                        return .handled;
                    },
                    .end => {
                        if (shift) {
                            if (self.selection_start == null) self.selection_start = self.cursor;
                        } else {
                            self.selection_start = null;
                        }
                        self.cursor = self.text.items.len;
                        self.base.markDirty();
                        return .handled;
                    },
                    .backspace => {
                        if (self.hasSelection()) {
                            self.deleteSelection();
                        } else if (self.cursor > 0) {
                            // 回退一个 UTF-8 codepoint
                            var pos = self.cursor - 1;
                            while (pos > 0 and (self.text.items[pos] & 0xC0) == 0x80) : (pos -= 1) {}
                            const start = pos;
                            var j: usize = self.cursor;
                            while (j > start) : (j -= 1) {
                                _ = self.text.orderedRemove(j - 1);
                            }
                            self.cursor = start;
                            self.notifyChange();
                        }
                        self.base.markDirty();
                        return .handled;
                    },
                    .delete => {
                        if (self.hasSelection()) {
                            self.deleteSelection();
                        } else if (self.cursor < self.text.items.len) {
                            _ = self.text.orderedRemove(self.cursor);
                            self.notifyChange();
                        }
                        self.base.markDirty();
                        return .handled;
                    },
                    .enter, .kp_enter => {
                        if (self.on_submit) |cb| {
                            cb(self, self.text.items);
                        }
                        return .handled;
                    },
                    // Cmd+A / Ctrl+A 全选
                    .a => {
                        if (k.modifiers.super_key or k.modifiers.ctrl) {
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
                self.insertCodepoint(ti.codepoint);
                return .handled;
            },
            // IME 事件 (Linux Wayland text-input-v3)
            .ime_commit => |ic| {
                if (!w.state.focused) return .ignored;
                if (ic.len > 0) {
                    self.insertBytes(ic.text[0..ic.len]);
                }
                self.clearPreedit();
                return .handled;
            },
            .ime_preedit => |ip| {
                if (!w.state.focused) return .ignored;
                if (ip.len > 0) {
                    self.setPreedit(ip.text[0..ip.len]);
                } else {
                    self.clearPreedit();
                }
                return .handled;
            },
            .ime_delete => |id| {
                if (!w.state.focused) return .ignored;
                if (id.before_length > 0) {
                    self.deleteBeforeCursor(id.before_length);
                }
                return .handled;
            },
            .mouse_button => |mb| {
                if (mb.button == .left) {
                    if (mb.state == .pressed) {
                        // 点击定位光标 (精确测量) + 设选区锚点
                        const abs = w.absoluteRect();
                        const rel_x: f32 = @floatFromInt(mb.x);
                        self.cursor = self.cursorAtX(rel_x - abs.x);
                        self.selection_start = self.cursor;
                        self.dragging = true;
                        self.base.markDirty();
                        return .handled;
                    } else {
                        self.dragging = false;
                    }
                }
            },
            .mouse_move => |mm| {
                // 拖拽扩展选区
                if (self.dragging) {
                    const abs = w.absoluteRect();
                    const rel_x: f32 = @floatFromInt(mm.x);
                    self.cursor = self.cursorAtX(rel_x - abs.x);
                    self.base.markDirty();
                    return .handled;
                }
            },
            else => {},
        }
        return .ignored;
    }

    fn deleteSelection(self: *TextInput) void {
        if (!self.hasSelection()) return;
        const start = @min(self.selection_start.?, self.cursor);
        const end = @max(self.selection_start.?, self.cursor);
        var i: usize = end;
        while (i > start) : (i -= 1) {
            _ = self.text.orderedRemove(i - 1);
        }
        self.cursor = start;
        self.selection_start = null;
        self.notifyChange();
    }

    /// 根据相对控件左边缘的 x 坐标计算光标字节偏移 (精确测量, UTF-8 感知)
    fn cursorAtX(self: *const TextInput, rel_x: f32) usize {
        const style = styled_text.TextStyle{ .font_size = self.font_size, .font_weight = 400 };
        const target = rel_x - self.padding_h;
        var best: usize = 0;
        var best_dist: f32 = std.math.floatMax(f32);
        var i: usize = 0;
        while (true) {
            const w = styled_text.measureTextWidth(self.allocator, self.text.items[0..i], style);
            const d = @abs(w - target);
            if (d < best_dist) {
                best_dist = d;
                best = i;
            }
            if (i >= self.text.items.len) break;
            i += 1;
            while (i < self.text.items.len and (self.text.items[i] & 0xC0) == 0x80) i += 1;
        }
        return best;
    }

    fn notifyChange(self: *TextInput) void {
        if (self.on_change) |cb| {
            cb(self, self.text.items);
        }
    }
};
