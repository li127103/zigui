//! TextInput 控件 - 单行文本输入 (光标/选择/编辑)

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

pub const TextInput = struct {
    base: Widget,
    allocator: std.mem.Allocator,
    text: std.ArrayListUnmanaged(u8),
    cursor: usize = 0, // 字节偏移
    selection_start: ?usize = null,
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
    selection_color: math.Color = math.Color.hex(0x3B82F644),
    cursor_color: math.Color = math.Color.hex(0xF8FAFCFF),
    corner_radius: f32 = 8.0,
    padding_h: f32 = 12.0,
    cursor_blink_ms: u32 = 0,
    cursor_visible: bool = true,

    pub fn create(allocator: std.mem.Allocator, opts: struct {
        placeholder: []const u8 = "",
        font_size: f32 = 14.0,
        on_change: ?*const fn (self: *TextInput, text: []const u8) void = null,
        on_submit: ?*const fn (self: *TextInput, text: []const u8) void = null,
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
        };
        return self;
    }

    pub fn destroy(self: *TextInput, allocator: std.mem.Allocator) void {
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

    pub fn hasSelection(self: *const TextInput) bool {
        return self.selection_start != null and self.selection_start.? != self.cursor;
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

        // 背景
        ctx.renderer.fillRoundedRect(.{ .x = rx, .y = ry, .width = rw, .height = rh }, self.corner_radius, self.bg_color) catch {};

        // 边框
        const border_c = if (w.state.focused) self.focus_border else self.border_color;
        // 简化边框: 外框 - 内框
        ctx.renderer.fillRoundedRect(.{ .x = rx, .y = ry, .width = rw, .height = rh }, self.corner_radius, border_c) catch {};
        ctx.renderer.fillRoundedRect(.{ .x = rx + 1.5, .y = ry + 1.5, .width = rw - 3, .height = rh - 3 }, self.corner_radius - 1, self.bg_color) catch {};

        const text_x = rx + self.padding_h;
        const text_y = ry + (rh - self.font_size * 1.2) / 2.0;

        if (self.text.items.len == 0 and !w.state.focused) {
            // Placeholder
            if (self.placeholder.len > 0) {
                self.drawLabel(ctx, self.placeholder, text_x, text_y, self.placeholder_color);
            }
        } else {
            // 选区高亮
            if (self.hasSelection()) {
                const sel_start = @min(self.selection_start.?, self.cursor);
                const sel_end = @max(self.selection_start.?, self.cursor);
                // 简化: 用固定宽度估算选区
                const char_w = self.font_size * 0.6;
                const sx: f32 = @floatFromInt(sel_start);
                const ex: f32 = @floatFromInt(sel_end);
                ctx.renderer.fillRect(
                    .{ .x = text_x + sx * char_w, .y = ry + 4, .width = (ex - sx) * char_w, .height = rh - 8 },
                    self.selection_color,
                ) catch {};
            }

            // 文本
            self.drawLabel(ctx, self.text.items, text_x, text_y, self.text_color);

            // 光标
            if (w.state.focused and self.cursor_visible) {
                const char_w = self.font_size * 0.6;
                const cx = text_x + @as(f32, @floatFromInt(self.cursor)) * char_w;
                ctx.renderer.fillRect(
                    .{ .x = cx, .y = ry + 5, .width = 2, .height = rh - 10 },
                    self.cursor_color,
                ) catch {};
            }
        }
    }

    fn drawLabel(self: *TextInput, ctx: *PaintContext, text: []const u8, x: f32, y: f32, color: math.Color) void {
        var font = coretext.CtFont.create(null, self.font_size, 400) catch return;
        defer font.destroy();

        var tl = text_layout.TextLayout.layout(
            ctx.allocator,
            &ctx.renderer.glyph_atlas.?,
            ctx.renderer.device,
            text,
            .{ .font = &font, .font_size = self.font_size },
        ) catch return;
        defer tl.deinit();

        ctx.renderer.drawText(&tl, x, y, color) catch {};
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
                            _ = self.text.orderedRemove(self.cursor - 1);
                            self.cursor -= 1;
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
                    .enter => {
                        if (self.on_submit) |cb| {
                            cb(self, self.text.items);
                        }
                        return .handled;
                    },
                    // Cmd+A 全选
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
                // 插入字符
                if (self.hasSelection()) {
                    self.deleteSelection();
                }
                // 编码 codepoint 为 UTF-8
                var buf: [4]u8 = undefined;
                const len = std.unicode.utf8Encode(ti.codepoint, &buf) catch return .handled;
                self.text.insertSlice(self.allocator, self.cursor, buf[0..len]) catch return .handled;
                self.cursor += len;
                self.notifyChange();
                self.base.markDirty();
                return .handled;
            },
            .mouse_button => |mb| {
                if (mb.button == .left and mb.state == .pressed) {
                    // 简化: 点击定位光标
                    const char_w = self.font_size * 0.6;
                    const rel_x: f32 = @floatFromInt(mb.x);
                    const idx: usize = @intFromFloat(@max(0, (rel_x - self.padding_h) / char_w));
                    self.cursor = @min(idx, self.text.items.len);
                    self.selection_start = null;
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

    fn notifyChange(self: *TextInput) void {
        if (self.on_change) |cb| {
            cb(self, self.text.items);
        }
    }
};
