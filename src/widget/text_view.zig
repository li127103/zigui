//! TextView 控件 - 多行文本编辑 (多行光标/选区/滚动)

const std = @import("std");
const math = @import("../math.zig");
const widget_mod = @import("widget.zig");
const layout_mod = @import("../layout/engine.zig");
const pal = @import("../pal/pal.zig");
const styled_text = @import("../text/styled_text.zig");
const clipboard = @import("../pal/clipboard.zig");
const context_menu_mod = @import("context_menu.zig");
const editable_mod = @import("../model/editable.zig");
const ContextMenu = context_menu_mod.ContextMenu;
const TextBuffer = editable_mod.TextBuffer;
const Editable = editable_mod.Editable;
const EditableIface = editable_mod.EditableIface;

const Widget = widget_mod.Widget;
const PaintContext = widget_mod.PaintContext;
const EventContext = widget_mod.EventContext;
const EventResult = widget_mod.EventResult;

const TextViewUndoItem = struct {
    text: []u8,
    cursor: usize,
    selection_start: ?usize,
    scroll_y: f32,
};

// ── EditableIface vtable (TextView 内部使用) ─────────────────────────────
fn tvEditableGetText(ud: ?*anyopaque) []const u8 {
    const self: *TextView = @ptrCast(@alignCast(ud orelse return &.{}));
    return self.text.items;
}
fn tvEditableSetText(ud: ?*anyopaque, text: []const u8) void {
    const self: *TextView = @ptrCast(@alignCast(ud orelse return));
    self.setText(text) catch {};
}
fn tvEditableInsertText(ud: ?*anyopaque, position: usize, text: []const u8) usize {
    const self: *TextView = @ptrCast(@alignCast(ud orelse return 0));
    const old_cursor = self.cursor;
    const old_sel = self.selection_start;
    self.cursor = @min(position, self.text.items.len);
    self.selection_start = null;
    self.desired_col = null;
    // 调用 insertBytes 或直接 insertSlice
    self.pushUndoState(false);
    self.clearRedoStack();
    self.last_was_char_insert = false;
    self.text.insertSlice(self.allocator, self.cursor, text) catch return 0;
    self.cursor += text.len;
    if (self.text_buffer) |b| b.insert(position, text);
    self.base.markDirty();
    self.notifyChange();
    _ = old_cursor;
    _ = old_sel;
    return text.len;
}
fn tvEditableDeleteText(ud: ?*anyopaque, position: usize, n_chars: usize) void {
    const self: *TextView = @ptrCast(@alignCast(ud orelse return));
    if (n_chars == 0) return;
    const pos = @min(position, self.text.items.len);
    const n = @min(n_chars, self.text.items.len - pos);
    if (n == 0) return;
    self.pushUndoState(false);
    self.clearRedoStack();
    self.last_was_char_insert = false;
    editable_mod.listDeleteRange(&self.text, pos, pos + n);
    if (self.cursor > self.text.items.len) self.cursor = self.text.items.len;
    if (self.selection_start != null and self.selection_start.? > self.text.items.len)
        self.selection_start = self.text.items.len;
    if (self.text_buffer) |b| b.delete(pos, n);
    self.base.markDirty();
    self.notifyChange();
}
fn tvEditableGetPosition(ud: ?*anyopaque) usize {
    const self: *TextView = @ptrCast(@alignCast(ud orelse return 0));
    return self.cursor;
}
fn tvEditableSelectRegion(ud: ?*anyopaque, start: usize, end: usize) void {
    const self: *TextView = @ptrCast(@alignCast(ud orelse return));
    if (self.text.items.len == 0) {
        self.cursor = 0;
        self.selection_start = null;
        return;
    }
    const s = @min(start, self.text.items.len);
    const e = @min(end, self.text.items.len);
    if (s == e) {
        self.cursor = s;
        self.selection_start = null;
    } else {
        self.cursor = e;
        self.selection_start = s;
    }
    self.desired_col = null;
    self.base.markDirty();
}
fn tvEditableGetSelectionBounds(ud: ?*anyopaque, start: *usize, end: *usize) bool {
    const self: *TextView = @ptrCast(@alignCast(ud orelse return false));
    const s = self.selection_start orelse {
        start.* = self.cursor;
        end.* = self.cursor;
        return false;
    };
    if (s <= self.cursor) {
        start.* = s;
        end.* = self.cursor;
    } else {
        start.* = self.cursor;
        end.* = s;
    }
    return true;
}
fn tvEditableGetTextBuffer(ud: ?*anyopaque) ?*TextBuffer {
    const self: *TextView = @ptrCast(@alignCast(ud orelse return null));
    return self.text_buffer;
}

const textview_editable_vtable = EditableIface{
    .getTextFn = tvEditableGetText,
    .setTextFn = tvEditableSetText,
    .insertTextFn = tvEditableInsertText,
    .deleteTextFn = tvEditableDeleteText,
    .getPositionFn = tvEditableGetPosition,
    .selectRegionFn = tvEditableSelectRegion,
    .getSelectionBoundsFn = tvEditableGetSelectionBounds,
    .getEntryBufferFn = null,
    .getTextBufferFn = tvEditableGetTextBuffer,
};

pub const TextView = struct {
    base: Widget,
    allocator: std.mem.Allocator,
    text: std.ArrayListUnmanaged(u8),
    cursor: usize = 0, // 字节偏移
    selection_start: ?usize = null,
    desired_col: ?usize = null, // 上下移动时保持列位置
    font_size: f32,
    scroll_y: f32 = 0,
    placeholder: []const u8,
    on_change: ?*const fn (self: *TextView, text: []const u8) void,
    /// 最大输入字节长度 (0=无限, 与 Entry 保持一致; GTK4 GtkTextView 无限制, 这里为易用性提供)
    max_length: u32 = 0,
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
    text_align: styled_text.TextAlign = .left,
    /// 是否显示行号
    show_line_numbers: bool = false,
    /// 是否高亮当前行
    highlight_current_line: bool = false,
    /// 行号区域宽度（自动计算时用此值）
    line_number_width: f32 = 0,
    /// 行号文字颜色
    line_number_color: math.Color = math.Color.hex(0x64748BFF),
    /// 行号区域背景色
    line_number_bg: math.Color = math.Color.hex(0x1A2332FF),
    /// 当前行高亮颜色
    current_line_color: math.Color = math.Color.hex(0x33415533),
    // 撤销/重做
    undo_stack: std.ArrayListUnmanaged(TextViewUndoItem) = .{ .items = &.{}, .capacity = 0 },
    redo_stack: std.ArrayListUnmanaged(TextViewUndoItem) = .{ .items = &.{}, .capacity = 0 },
    last_was_char_insert: bool = false,
    max_undo: usize = 100,
    /// 右键上下文菜单
    context_menu_owned: ?*ContextMenu = null,
    /// 可选的外部分享 TextBuffer (GTK4: gtk_text_view_get_buffer)
    text_buffer: ?*TextBuffer = null,

    pub fn create(allocator: std.mem.Allocator, opts: struct {
        placeholder: []const u8 = "",
        font_size: f32 = 14.0,
        on_change: ?*const fn (self: *TextView, text: []const u8) void = null,
        text_align: styled_text.TextAlign = .left,
        show_line_numbers: bool = false,
        highlight_current_line: bool = false,
        max_length: u32 = 0,
    }) !*TextView {
        const self = try allocator.create(TextView);
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
            .max_length = opts.max_length,
            .text_align = opts.text_align,
            .show_line_numbers = opts.show_line_numbers,
            .highlight_current_line = opts.highlight_current_line,
        };
        self.base.cursor = .ibeam;

        const menu = try ContextMenu.create(allocator, &.{
            .{ .label = "撤销", .on_click = undoCallback, .ctx = self },
            .{ .label = "重做", .on_click = redoCallback, .ctx = self },
            .{ .is_separator = true },
            .{ .label = "剪切", .on_click = cutCallback, .ctx = self },
            .{ .label = "复制", .on_click = copyCallback, .ctx = self },
            .{ .label = "粘贴", .on_click = pasteCallback, .ctx = self },
            .{ .is_separator = true },
            .{ .label = "全选", .on_click = selectAllCallback, .ctx = self },
        });
        menu.on_before_show = beforeShowCallback;
        self.context_menu_owned = menu;
        self.base.context_menu = menu;

        return self;
    }

    /// GTK4 对齐: 返回 Editable 接口胖指针
    pub fn getEditable(self: *TextView) Editable {
        return .{
            .iface = &textview_editable_vtable,
            .userdata = @ptrCast(@alignCast(self)),
        };
    }

    /// GTK4: gtk_text_view_get_buffer
    pub fn getTextBuffer(self: *const TextView) ?*TextBuffer {
        return self.text_buffer;
    }

    /// GTK4: gtk_text_view_set_buffer, 同步内容
    pub fn setTextBuffer(self: *TextView, buf: ?*TextBuffer) void {
        self.text_buffer = buf;
        if (buf) |b| {
            const bytes = b.getBytes();
            self.setText(bytes) catch {};
            // 同步 cursor/selection
            self.cursor = @min(b.cursor_pos, self.text.items.len);
            if (b.selection) |sel| {
                self.selection_start = @min(sel.start, self.text.items.len);
            } else {
                self.selection_start = null;
            }
        }
    }

    pub fn destroy(self: *TextView, allocator: std.mem.Allocator) void {
        self.base.background.deinit(allocator);
        self.text.deinit(allocator);
        self.base.children.deinit(allocator);
        self.clearUndoStack();
        self.clearRedoStack();
        self.undo_stack.deinit(allocator);
        self.redo_stack.deinit(allocator);
        if (self.context_menu_owned) |menu| {
            menu.destroy(allocator);
        }
        allocator.destroy(self);
    }

    fn clearUndoStack(self: *TextView) void {
        for (self.undo_stack.items) |item| {
            self.allocator.free(item.text);
        }
        self.undo_stack.clearRetainingCapacity();
    }

    fn clearRedoStack(self: *TextView) void {
        for (self.redo_stack.items) |item| {
            self.allocator.free(item.text);
        }
        self.redo_stack.clearRetainingCapacity();
    }

    fn pushUndoState(self: *TextView, merge_with_last_insert: bool) void {
        if (merge_with_last_insert and self.last_was_char_insert and self.undo_stack.items.len > 0) {
            const last = &self.undo_stack.items[self.undo_stack.items.len - 1];
            self.allocator.free(last.text);
            last.* = .{
                .text = self.allocator.dupe(u8, self.text.items) catch return,
                .cursor = self.cursor,
                .selection_start = self.selection_start,
                .scroll_y = self.scroll_y,
            };
            return;
        }

        const item = TextViewUndoItem{
            .text = self.allocator.dupe(u8, self.text.items) catch return,
            .cursor = self.cursor,
            .selection_start = self.selection_start,
            .scroll_y = self.scroll_y,
        };

        if (self.undo_stack.items.len >= self.max_undo) {
            const oldest = self.undo_stack.orderedRemove(0);
            self.allocator.free(oldest.text);
        }

        self.undo_stack.append(self.allocator, item) catch {
            self.allocator.free(item.text);
        };

        self.clearRedoStack();
    }

    pub fn undo(self: *TextView) void {
        if (self.undo_stack.items.len == 0) return;

        const current = TextViewUndoItem{
            .text = self.allocator.dupe(u8, self.text.items) catch return,
            .cursor = self.cursor,
            .selection_start = self.selection_start,
            .scroll_y = self.scroll_y,
        };
        self.redo_stack.append(self.allocator, current) catch {
            self.allocator.free(current.text);
            return;
        };

        const prev = self.undo_stack.pop().?;
        self.text.clearRetainingCapacity();
        self.text.appendSlice(self.allocator, prev.text) catch {};
        self.cursor = prev.cursor;
        self.selection_start = prev.selection_start;
        self.scroll_y = prev.scroll_y;
        self.desired_col = null;
        self.allocator.free(prev.text);
        self.last_was_char_insert = false;
        self.base.markDirty();
        self.notifyChange();
    }

    pub fn redo(self: *TextView) void {
        if (self.redo_stack.items.len == 0) return;

        const current = TextViewUndoItem{
            .text = self.allocator.dupe(u8, self.text.items) catch return,
            .cursor = self.cursor,
            .selection_start = self.selection_start,
            .scroll_y = self.scroll_y,
        };
        self.undo_stack.append(self.allocator, current) catch {
            self.allocator.free(current.text);
            return;
        };

        const next = self.redo_stack.pop().?;
        self.text.clearRetainingCapacity();
        self.text.appendSlice(self.allocator, next.text) catch {};
        self.cursor = next.cursor;
        self.selection_start = next.selection_start;
        self.scroll_y = next.scroll_y;
        self.desired_col = null;
        self.allocator.free(next.text);
        self.last_was_char_insert = false;
        self.base.markDirty();
        self.notifyChange();
    }

    pub fn getText(self: *const TextView) []const u8 {
        return self.text.items;
    }

    pub fn setText(self: *TextView, new_text: []const u8) !void {
        self.text.clearRetainingCapacity();
        try self.text.appendSlice(self.allocator, new_text);
        self.cursor = new_text.len;
        self.selection_start = null;
        self.desired_col = null;
        self.base.markDirty();
        // 同步 buffer + on_change
        if (self.text_buffer) |b| b.setText(self.text.items);
        self.notifyChange();
    }

    /// 设置文本对齐方式 (左/居中/右; 多行编辑两端对齐按左对齐处理)
    pub fn setTextAlign(self: *TextView, alignment: styled_text.TextAlign) void {
        self.text_align = alignment;
        self.base.markDirty();
    }

    /// GTK4: gtk_entry_get_placeholder_text (TextView 兼容)
    pub fn getPlaceholderText(self: *const TextView) []const u8 {
        return self.placeholder;
    }

    /// GTK4: gtk_entry_set_placeholder_text (TextView 兼容)
    pub fn setPlaceholderText(self: *TextView, placeholder: []const u8) void {
        self.placeholder = placeholder;
        self.base.markDirty();
    }

    /// 返回最大输入字节长度 (0=无限)
    pub fn getMaxLength(self: *const TextView) u32 {
        return self.max_length;
    }

    /// 设置最大输入字节长度 (0=无限)
    pub fn setMaxLength(self: *TextView, max: u32) void {
        self.max_length = max;
    }

    /// GTK4: gtk_editable_get_position
    pub fn getCursorPosition(self: *const TextView) usize {
        return self.cursor;
    }

    /// GTK4: gtk_editable_set_position
    pub fn setCursorPosition(self: *TextView, pos: usize) void {
        self.cursor = @min(pos, self.text.items.len);
        self.selection_start = null;
        self.desired_col = null;
        self.ensureCursorVisible();
        self.base.markDirty();
    }

    /// GTK4: gtk_editable_select_region (start..end 字节偏移; start>end 自动交换; start==end 清除选择)
    pub fn selectRegion(self: *TextView, start: usize, end: usize) void {
        const s = @min(start, end);
        const e = @max(start, end);
        const clamped_s = @min(s, self.text.items.len);
        const clamped_e = @min(e, self.text.items.len);
        if (clamped_s == clamped_e) {
            self.cursor = clamped_s;
            self.selection_start = null;
        } else {
            self.cursor = clamped_e;
            self.selection_start = clamped_s;
        }
        self.desired_col = null;
        self.ensureCursorVisible();
        self.base.markDirty();
    }

    /// GTK4: gtk_editable_get_selection_bounds
    pub fn getSelectionBounds(self: *const TextView, out_start: *usize, out_end: *usize) bool {
        const s = self.selection_start orelse {
            out_start.* = self.cursor;
            out_end.* = self.cursor;
            return false;
        };
        if (s <= self.cursor) {
            out_start.* = s;
            out_end.* = self.cursor;
        } else {
            out_start.* = self.cursor;
            out_end.* = s;
        }
        return true;
    }

    /// GTK4: gtk_editable_select_all — 选择全部文本
    pub fn selectAll(self: *TextView) void {
        self.selectRegion(0, self.text.items.len);
    }

    pub fn hasSelection(self: *const TextView) bool {
        return self.selection_start != null and self.selection_start.? != self.cursor;
    }

    // ── 行辅助 (基于 '\n' 扫描) ─────────────────────────────────────────────

    fn lineHeight(self: *const TextView) f32 {
        return self.font_size * 1.4;
    }

    fn charWidth(self: *const TextView) f32 {
        return self.font_size * 0.6;
    }

    fn lineNumberAreaWidth(self: *const TextView) f32 {
        if (!self.show_line_numbers) return 0;
        const digits = countDigits(self.lineCount());
        return @as(f32, @floatFromInt(digits)) * self.charWidth() + self.padding * 2;
    }

    fn countDigits(n: usize) usize {
        if (n == 0) return 1;
        var count: usize = 0;
        var x = n;
        while (x > 0) : (x /= 10) {
            count += 1;
        }
        return count;
    }

    /// 包含 offset 的行的起始字节偏移
    fn lineStart(self: *const TextView, offset: usize) usize {
        const items = self.text.items;
        if (offset == 0) return 0;
        var i = @min(offset, items.len);
        while (i > 0) : (i -= 1) {
            if (items[i - 1] == '\n') return i;
        }
        return 0;
    }

    /// 包含 offset 的行的结束字节偏移 ('\n' 之前或文本末尾)
    fn lineEnd(self: *const TextView, offset: usize) usize {
        const items = self.text.items;
        var i = @min(offset, items.len);
        while (i < items.len) : (i += 1) {
            if (items[i] == '\n') return i;
        }
        return items.len;
    }

    /// offset 所在的行号 (0-based)
    fn lineIndex(self: *const TextView, offset: usize) usize {
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
    fn lineCount(self: *const TextView) usize {
        return self.lineIndex(self.text.items.len) + 1;
    }

    /// 第 line 行的起始字节偏移
    fn lineStartAtIndex(self: *const TextView, line: usize) usize {
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
    fn offsetAt(self: *const TextView, line: usize, col: usize) usize {
        const start = self.lineStartAtIndex(line);
        const end = self.lineEnd(start);
        const line_len = end - start;
        return start + @min(col, line_len);
    }

    /// offset 处的列号 (字节列)
    fn colOf(self: *const TextView, offset: usize) usize {
        return offset - self.lineStart(offset);
    }

    /// 内容总高度
    fn contentHeight(self: *const TextView) f32 {
        return @as(f32, @floatFromInt(self.lineCount())) * self.lineHeight();
    }

    fn maxScroll(self: *const TextView) f32 {
        const visible = self.base.rect.height - self.padding * 2;
        const content = self.contentHeight();
        return @max(0, content - visible);
    }

    fn clampScroll(self: *TextView) void {
        self.scroll_y = std.math.clamp(self.scroll_y, 0, self.maxScroll());
    }

    /// 确保光标在可视区域内 (自动滚动)
    fn ensureCursorVisible(self: *TextView) void {
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
        const self: *TextView = @fieldParentPtr("base", w);
        self.destroy(allocator);
    }

    fn measure(w: *Widget, ctx: *PaintContext, constraints: layout_mod.Constraints) math.Size(f32) {
        const self: *TextView = @fieldParentPtr("base", w);
        _ = ctx;
        _ = constraints;
        return .{ .width = 320, .height = self.lineHeight() * 5 + self.padding * 2 };
    }

    fn paint(w: *Widget, ctx: *PaintContext) void {
        const self: *TextView = @fieldParentPtr("base", w);
        const rx = ctx.offset_x + w.rect.x;
        const ry = ctx.offset_y + w.rect.y;
        const rw = w.rect.width;
        const rh = w.rect.height;

        // 背景 + 边框
        const border_c = if (w.state.focused) self.focus_border else self.border_color;
        ctx.renderer.fillRoundedRect(.{ .x = rx, .y = ry, .width = rw, .height = rh }, self.corner_radius, border_c) catch {};
        ctx.renderer.fillRoundedRect(.{ .x = rx + 1.5, .y = ry + 1.5, .width = rw - 3, .height = rh - 3 }, self.corner_radius - 1, self.bg_color) catch {};

        const lnw = self.lineNumberAreaWidth();
        const text_x = rx + self.padding + lnw;
        const lh = self.lineHeight();
        const avail_w = rw - self.padding * 2 - lnw;

        if (self.text.items.len == 0 and !w.state.focused) {
            if (self.placeholder.len > 0) {
                self.drawLabel(ctx, self.placeholder, text_x, ry + self.padding, self.placeholder_color);
            }
            return;
        }

        // 行号区域背景
        if (self.show_line_numbers) {
            ctx.renderer.fillRect(
                .{ .x = rx + 1.5, .y = ry + 1.5, .width = lnw, .height = rh - 3 },
                self.line_number_bg,
            ) catch {};
        }

        // 可视行范围
        const first_line: usize = @intFromFloat(@max(0, @floor(self.scroll_y / lh)));
        const visible_lines: usize = @as(usize, @intFromFloat(@ceil((rh - self.padding * 2) / lh))) + 1;
        const total_lines = self.lineCount();

        // 当前行
        const cursor_line = if (w.state.focused) self.lineIndex(self.cursor) else total_lines;

        // 选区范围
        const has_sel = self.hasSelection();
        const sel_start = if (has_sel) @min(self.selection_start.?, self.cursor) else 0;
        const sel_end = if (has_sel) @max(self.selection_start.?, self.cursor) else 0;

        var li: usize = first_line;
        while (li < first_line + visible_lines and li < total_lines) : (li += 1) {
            const ls = self.lineStartAtIndex(li);
            const le = self.lineEnd(ls);
            const line_y = ry + self.padding + @as(f32, @floatFromInt(li)) * lh - self.scroll_y;

            // 当前行高亮
            if (self.highlight_current_line and li == cursor_line) {
                ctx.renderer.fillRect(
                    .{ .x = rx + 1.5, .y = line_y + 1, .width = rw - 3, .height = lh - 2 },
                    self.current_line_color,
                ) catch {};
            }

            // 行号
            if (self.show_line_numbers) {
                var num_buf: [16]u8 = undefined;
                const num_str = std.fmt.bufPrint(&num_buf, "{d}", .{li + 1}) catch "?";
                const nw = @as(f32, @floatFromInt(num_str.len)) * self.charWidth();
                const num_x = rx + self.padding + lnw - self.padding - nw;
                self.drawLabel(ctx, num_str, num_x, line_y, self.line_number_color);
            }

            // 该行对齐偏移
            const line_slice = self.text.items[ls..le];
            const offset = self.lineAlignOffset(styled_text.measureText(ctx.allocator, line_slice, .{ .font_size = self.font_size }).width, avail_w);

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
                self.drawLabel(ctx, line_slice, text_x + offset, line_y, self.text_color);
            }
        }

        // 光标
        if (w.state.focused and self.cursor_visible) {
            const cl = self.lineIndex(self.cursor);
            const cursor_col = self.colOf(self.cursor);
            // 光标所在行的对齐偏移
            const cls = self.lineStartAtIndex(cl);
            const cle = self.lineEnd(cls);
            const c_offset = self.lineAlignOffset(styled_text.measureText(ctx.allocator, self.text.items[cls..cle], .{ .font_size = self.font_size }).width, avail_w);
            const cx = text_x + c_offset + @as(f32, @floatFromInt(cursor_col)) * self.charWidth();
            const cy = ry + self.padding + @as(f32, @floatFromInt(cl)) * lh - self.scroll_y;
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
    fn lineAlignOffset(self: *const TextView, line_w: f32, avail_w: f32) f32 {
        const extra = avail_w - line_w;
        if (extra <= 0) return 0;
        return switch (self.text_align) {
            .center => extra / 2.0,
            .right => extra,
            .left, .justify => 0,
        };
    }

    fn drawLabel(self: *TextView, ctx: *PaintContext, text: []const u8, x: f32, y: f32, color: math.Color) void {
        if (text.len == 0) return;
        styled_text.drawText(
            ctx.renderer,
            ctx.allocator,
            text,
            x,
            y,
            .{ .font_size = self.font_size, .color = color },
        );
    }

    fn onEvent(w: *Widget, event: *const pal.Event, ectx: *EventContext) EventResult {
        const self: *TextView = @fieldParentPtr("base", w);
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
                            self.pushUndoState(false);
                            _ = self.text.orderedRemove(self.cursor - 1);
                            self.cursor -= 1;
                            self.desired_col = null;
                            self.last_was_char_insert = false;
                            self.notifyChange();
                        }
                        self.afterMove();
                        return .handled;
                    },
                    .delete => {
                        if (self.hasSelection()) {
                            self.deleteSelection();
                        } else if (self.cursor < self.text.items.len) {
                            self.pushUndoState(false);
                            _ = self.text.orderedRemove(self.cursor);
                            self.last_was_char_insert = false;
                            self.notifyChange();
                        }
                        self.afterMove();
                        return .handled;
                    },
                    .enter => {
                        // 插入换行
                        self.pushUndoState(false);
                        if (self.hasSelection()) self.deleteSelectionNoUndo();
                        self.text.insertSlice(self.allocator, self.cursor, "\n") catch return .handled;
                        self.cursor += 1;
                        self.desired_col = null;
                        self.last_was_char_insert = false;
                        self.notifyChange();
                        self.afterMove();
                        return .handled;
                    },
                    .tab => {
                        // 插入 4 空格
                        self.pushUndoState(false);
                        if (self.hasSelection()) self.deleteSelectionNoUndo();
                        self.text.insertSlice(self.allocator, self.cursor, "    ") catch return .handled;
                        self.cursor += 4;
                        self.desired_col = null;
                        self.last_was_char_insert = false;
                        self.notifyChange();
                        self.afterMove();
                        return .handled;
                    },
                    .a => {
                        if (k.modifiers.super_key or k.modifiers.ctrl) {
                            self.selection_start = 0;
                            self.cursor = self.text.items.len;
                            self.base.markDirty();
                            return .handled;
                        }
                    },
                    // Ctrl/Cmd+C 复制选区
                    .c => {
                        if (k.modifiers.super_key or k.modifiers.ctrl) {
                            if (self.hasSelection()) {
                                const s = @min(self.selection_start.?, self.cursor);
                                const e = @max(self.selection_start.?, self.cursor);
                                clipboard.setText(self.text.items[s..e]) catch {};
                            }
                            return .handled;
                        }
                    },
                    // Ctrl/Cmd+X 剪切选区
                    .x => {
                        if (k.modifiers.super_key or k.modifiers.ctrl) {
                            if (self.hasSelection()) {
                                const s = @min(self.selection_start.?, self.cursor);
                                const e = @max(self.selection_start.?, self.cursor);
                                clipboard.setText(self.text.items[s..e]) catch {};
                                self.deleteSelection();
                                self.base.markDirty();
                            }
                            return .handled;
                        }
                    },
                    // Ctrl/Cmd+V 粘贴
                    .v => {
                        if (k.modifiers.super_key or k.modifiers.ctrl) {
                            if (clipboard.getText(self.allocator)) |pasted| {
                                defer self.allocator.free(pasted);
                                if (pasted.len > 0) {
                                    self.pushUndoState(false);
                                    if (self.hasSelection()) self.deleteSelectionNoUndo();
                                    self.text.insertSlice(self.allocator, self.cursor, pasted) catch return .handled;
                                    self.cursor += pasted.len;
                                    self.desired_col = null;
                                    self.last_was_char_insert = false;
                                    self.notifyChange();
                                    self.afterMove();
                                }
                            } else |_| {}
                            return .handled;
                        }
                    },
                    // Ctrl/Cmd+Z 撤销
                    .z => {
                        if (k.modifiers.super_key or k.modifiers.ctrl) {
                            if (k.modifiers.shift) {
                                self.redo();
                            } else {
                                self.undo();
                            }
                            return .handled;
                        }
                    },
                    // Ctrl+Y 重做
                    .y => {
                        if (k.modifiers.ctrl) {
                            self.redo();
                            return .handled;
                        }
                    },
                    else => {},
                }
            },
            .text_input => |ti| {
                if (!w.state.focused) return .ignored;
                self.pushUndoState(true);
                if (self.hasSelection()) self.deleteSelectionNoUndo();
                var buf: [4]u8 = undefined;
                const len = std.unicode.utf8Encode(ti.codepoint, &buf) catch return .handled;
                self.text.insertSlice(self.allocator, self.cursor, buf[0..len]) catch return .handled;
                self.cursor += len;
                self.desired_col = null;
                self.last_was_char_insert = true;
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

    fn beginSelect(self: *TextView, shift: bool) void {
        if (shift) {
            if (self.selection_start == null) self.selection_start = self.cursor;
        } else {
            self.selection_start = null;
        }
    }

    /// 垂直移动 delta 行 (-1 上 / +1 下), 保持列位置
    fn moveVertical(self: *TextView, delta: i32) void {
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

    fn afterMove(self: *TextView) void {
        self.ensureCursorVisible();
        self.base.markDirty();
    }

    /// GTK4: gtk_editable_delete_selection — 删除选中内容（推撤销栈）
    pub fn deleteSelection(self: *TextView) void {
        if (!self.hasSelection()) return;
        self.pushUndoState(false);
        self.deleteSelectionNoUndo();
        self.last_was_char_insert = false;
    }

    fn deleteSelectionNoUndo(self: *TextView) void {
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

    fn notifyChange(self: *TextView) void {
        if (self.on_change) |cb| {
            cb(self, self.text.items);
        }
    }
};

// ── Context Menu Callbacks ─────────────────────────────────────────────────

fn undoCallback(ctx: ?*anyopaque) void {
    const self: *TextView = @ptrCast(@alignCast(ctx orelse return));
    self.undo();
}

fn redoCallback(ctx: ?*anyopaque) void {
    const self: *TextView = @ptrCast(@alignCast(ctx orelse return));
    self.redo();
}

fn cutCallback(ctx: ?*anyopaque) void {
    const self: *TextView = @ptrCast(@alignCast(ctx orelse return));
    if (self.hasSelection()) {
        const s = @min(self.selection_start.?, self.cursor);
        const e = @max(self.selection_start.?, self.cursor);
        clipboard.setText(self.text.items[s..e]) catch {};
        self.deleteSelection();
        self.base.markDirty();
    }
}

fn copyCallback(ctx: ?*anyopaque) void {
    const self: *TextView = @ptrCast(@alignCast(ctx orelse return));
    if (self.hasSelection()) {
        const s = @min(self.selection_start.?, self.cursor);
        const e = @max(self.selection_start.?, self.cursor);
        clipboard.setText(self.text.items[s..e]) catch {};
    }
}

fn pasteCallback(ctx: ?*anyopaque) void {
    const self: *TextView = @ptrCast(@alignCast(ctx orelse return));
    if (clipboard.getText(self.allocator)) |pasted| {
        defer self.allocator.free(pasted);
        if (pasted.len > 0) {
            self.pushUndoState(false);
            if (self.hasSelection()) self.deleteSelectionNoUndo();
            self.text.insertSlice(self.allocator, self.cursor, pasted) catch return;
            self.cursor += pasted.len;
            self.desired_col = null;
            self.last_was_char_insert = false;
            self.notifyChange();
            self.ensureCursorVisible();
            self.base.markDirty();
        }
    } else |_| {}
}

fn selectAllCallback(ctx: ?*anyopaque) void {
    const self: *TextView = @ptrCast(@alignCast(ctx orelse return));
    self.selection_start = 0;
    self.cursor = self.text.items.len;
    self.base.markDirty();
}

fn beforeShowCallback(menu: *ContextMenu) void {
    const self: *TextView = blk: {
        if (menu.items.items.len == 0) return;
        const first = menu.items.items[0];
        const ctx = first.ctx orelse return;
        break :blk @ptrCast(@alignCast(ctx));
    };

    const has_undo = self.undo_stack.items.len > 0;
    const has_redo = self.redo_stack.items.len > 0;
    const has_sel = self.hasSelection();
    const has_paste = clipboard.getText(self.allocator) catch null != null;

    menu.setItemDisabled(0, !has_undo);
    menu.setItemDisabled(1, !has_redo);
    menu.setItemDisabled(3, !has_sel);
    menu.setItemDisabled(4, !has_sel);
    menu.setItemDisabled(5, !has_paste);
}
