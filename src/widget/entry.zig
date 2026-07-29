//! Entry 控件 - 单行文本输入 (光标/选择/编辑/IME preedit)
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
const clipboard = @import("../pal/clipboard.zig");
const context_menu_mod = @import("context_menu.zig");
const editable_mod = @import("../model/editable.zig");
const ContextMenu = context_menu_mod.ContextMenu;
const EntryBuffer = editable_mod.EntryBuffer;
const Editable = editable_mod.Editable;
const EditableIface = editable_mod.EditableIface;

const Widget = widget_mod.Widget;
const PaintContext = widget_mod.PaintContext;
const EventContext = widget_mod.EventContext;
const EventResult = widget_mod.EventResult;

const EntryUndoItem = struct {
    text: []u8,
    cursor: usize,
    selection_start: ?usize,
};

// ── EditableIface vtable (Entry 内部使用) ────────────────────────────────
fn entryEditableGetText(ud: ?*anyopaque) []const u8 {
    const self: *Entry = @ptrCast(@alignCast(ud orelse return &.{}));
    return self.text.items;
}
fn entryEditableSetText(ud: ?*anyopaque, text: []const u8) void {
    const self: *Entry = @ptrCast(@alignCast(ud orelse return));
    self.setText(text) catch {};
}
fn entryEditableInsertText(ud: ?*anyopaque, position: usize, text: []const u8) usize {
    const self: *Entry = @ptrCast(@alignCast(ud orelse return 0));
    // 简单实现: 移动光标到 position -> insertText (Entry 内部没有直接的 position insert API, 用 insertTextAt)
    // 先记录旧光标
    const old_cursor = self.cursor;
    const old_sel = self.selection_start;
    self.cursor = @min(position, self.text.items.len);
    self.selection_start = null;
    self.insertText(text);
    const inserted = self.cursor - @min(position, self.text.items.len);
    _ = old_cursor;
    _ = old_sel;
    return inserted;
}
fn entryEditableDeleteText(ud: ?*anyopaque, position: usize, n_chars: usize) void {
    const self: *Entry = @ptrCast(@alignCast(ud orelse return));
    if (n_chars == 0) return;
    const pos = @min(position, self.text.items.len);
    const n = @min(n_chars, self.text.items.len - pos);
    if (n == 0) return;
    self.pushUndoState(false);
    self.redo_stack.clearRetainingCapacity();
    self.last_was_char_insert = false;
    // 删除范围
    // 用 Entry 内部没有直接 deleteRange: 直接操作 text.items
    // (Entry 的内部 deleteRange 在 onEvent key delete 中写的, 直接改 list)
    editable_mod.listDeleteRange(&self.text, pos, pos + n);
    if (self.cursor > self.text.items.len) self.cursor = self.text.items.len;
    if (self.selection_start != null and self.selection_start.? > self.text.items.len)
        self.selection_start = self.text.items.len;
    // 同步 buffer
    if (self.entry_buffer) |b| b.deleteText(pos, n);
    if (self.on_change) |cb| cb(self, self.text.items);
    self.base.markDirty();
}
fn entryEditableGetPosition(ud: ?*anyopaque) usize {
    const self: *Entry = @ptrCast(@alignCast(ud orelse return 0));
    return self.cursor;
}
fn entryEditableSelectRegion(ud: ?*anyopaque, start: usize, end: usize) void {
    const self: *Entry = @ptrCast(@alignCast(ud orelse return));
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
    self.base.markDirty();
}
fn entryEditableGetSelectionBounds(ud: ?*anyopaque, start: *usize, end: *usize) bool {
    const self: *Entry = @ptrCast(@alignCast(ud orelse return false));
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
fn entryEditableGetEntryBuffer(ud: ?*anyopaque) ?*EntryBuffer {
    const self: *Entry = @ptrCast(@alignCast(ud orelse return null));
    return self.entry_buffer;
}

const entry_editable_vtable = EditableIface{
    .getTextFn = entryEditableGetText,
    .setTextFn = entryEditableSetText,
    .insertTextFn = entryEditableInsertText,
    .deleteTextFn = entryEditableDeleteText,
    .getPositionFn = entryEditableGetPosition,
    .selectRegionFn = entryEditableSelectRegion,
    .getSelectionBoundsFn = entryEditableGetSelectionBounds,
    .getEntryBufferFn = entryEditableGetEntryBuffer,
    .getTextBufferFn = null,
};

// ── GTK4: GtkInputHints (packed bitfield, u16) ──────────────────────────
pub const InputHint = packed struct(u16) {
    none: bool = false,
    word_completion: bool = false,
    lowercase: bool = false,
    uppercase_chars: bool = false,
    uppercase_words: bool = false,
    uppercase_sentences: bool = false,
    digits: bool = false,
    _pad: u9 = 0,
};
pub const InputHints = InputHint;

pub const Entry = struct {
    base: Widget,
    allocator: std.mem.Allocator,
    text: std.ArrayListUnmanaged(u8),
    cursor: usize = 0, // 字节偏移
    selection_start: ?usize = null,
    dragging: bool = false, // 鼠标拖拽选择中
    font_size: f32,
    placeholder: []const u8,
    /// 是否可见文本 (false=密码模式, 显示圆点)
    visibility: bool = true,
    /// 密码模式下的遮罩字符
    password_char: u8 = '*',
    /// 最大输入长度 (字节; 0=无限)
    max_length: u32 = 0,
    on_change: ?*const fn (self: *Entry, text: []const u8) void,
    on_submit: ?*const fn (self: *Entry, text: []const u8) void,
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
    // 撤销/重做
    undo_stack: std.ArrayListUnmanaged(EntryUndoItem) = .{ .items = &.{}, .capacity = 0 },
    redo_stack: std.ArrayListUnmanaged(EntryUndoItem) = .{ .items = &.{}, .capacity = 0 },
    /// 最近一次操作是否是字符插入（用于合并连续输入）
    last_was_char_insert: bool = false,
    /// 撤销栈最大长度
    max_undo: usize = 100,
    /// 右键上下文菜单
    context_menu_owned: ?*ContextMenu = null,
    /// 可选的外部分享 EntryBuffer (GTK4: gtk_entry_get_buffer)
    entry_buffer: ?*EntryBuffer = null,
    /// GTK4: gtk_entry_set_input_hints (输入提示位域)
    input_hints: InputHints = .{},
    /// GTK4: gtk_entry_set_activates_default (Enter 激活默认控件)
    activates_default: bool = false,
    /// GTK4: gtk_entry_set_icon_from_icon_name (主图标名称, 简化存储)
    primary_icon_name: ?[]const u8 = null,
    /// GTK4: gtk_entry_set_icon_tooltip_text (主图标提示文字)
    primary_icon_tooltip: ?[]const u8 = null,

    pub fn create(allocator: std.mem.Allocator, opts: struct {
        placeholder: []const u8 = "",
        font_size: f32 = 14.0,
        visibility: bool = true,
        /// password=true 等价于 visibility=false (GTK 兼容字段名)
        password: bool = false,
        /// 密码遮罩字符
        password_char: u8 = '*',
        max_length: u32 = 0,
        on_change: ?*const fn (self: *Entry, text: []const u8) void = null,
        on_submit: ?*const fn (self: *Entry, text: []const u8) void = null,
        text_align: align_mod.TextAlign = .left,
        /// 初始文本
        text: []const u8 = "",
        text_color: math.Color = math.Color.hex(0xF8FAFCFF),
    }) !*Entry {
        const self = try allocator.create(Entry);
        const is_visible = !opts.password and opts.visibility;
        self.* = .{
            .base = .{
                .vtable = &vtable,
                .id = widget_mod.genWidgetId(),
            },
            .allocator = allocator,
            .text = .{ .items = &.{}, .capacity = 0 },
            .font_size = opts.font_size,
            .placeholder = opts.placeholder,
            .visibility = is_visible,
            .password_char = opts.password_char,
            .max_length = opts.max_length,
            .on_change = opts.on_change,
            .on_submit = opts.on_submit,
            .text_color = opts.text_color,
            .text_align = opts.text_align,
        };
        self.base.cursor = .ibeam;
        if (opts.text.len > 0) try self.text.appendSlice(self.allocator, opts.text);

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

    /// GTK4: gtk_editable_get_delegate / GtkEditable interface
    /// 返回 Editable 胖指针, 可用于通用编辑操作
    pub fn getEditable(self: *Entry) Editable {
        return .{
            .iface = &entry_editable_vtable,
            .userdata = @ptrCast(@alignCast(self)),
        };
    }

    /// GTK4: gtk_entry_get_buffer
    pub fn getEntryBuffer(self: *const Entry) ?*EntryBuffer {
        return self.entry_buffer;
    }

    /// GTK4: gtk_entry_set_buffer
    /// 设置外部分享 buffer，同步内容（如 buffer 非空）
    pub fn setEntryBuffer(self: *Entry, buf: ?*EntryBuffer) void {
        self.entry_buffer = buf;
        if (buf) |b| {
            const bytes = b.getBytes();
            // 把 buffer 内容同步到 Entry 文本
            self.setText(bytes) catch {};
            // 同步 max_length <-> max_bytes
            if (b.getMaxBytes() > 0 and self.max_length == 0) {
                self.max_length = @intCast(b.getMaxBytes());
            } else if (self.max_length > 0 and b.getMaxBytes() == 0) {
                b.setMaxBytes(self.max_length);
            }
        }
    }

    pub fn destroy(self: *Entry, allocator: std.mem.Allocator) void {
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

    fn clearUndoStack(self: *Entry) void {
        for (self.undo_stack.items) |item| {
            self.allocator.free(item.text);
        }
        self.undo_stack.clearRetainingCapacity();
    }

    fn clearRedoStack(self: *Entry) void {
        for (self.redo_stack.items) |item| {
            self.allocator.free(item.text);
        }
        self.redo_stack.clearRetainingCapacity();
    }

    fn pushUndoState(self: *Entry, merge_with_last_insert: bool) void {
        if (merge_with_last_insert and self.last_was_char_insert and self.undo_stack.items.len > 0) {
            const last = &self.undo_stack.items[self.undo_stack.items.len - 1];
            self.allocator.free(last.text);
            last.* = .{
                .text = self.allocator.dupe(u8, self.text.items) catch return,
                .cursor = self.cursor,
                .selection_start = self.selection_start,
            };
            return;
        }

        const item = EntryUndoItem{
            .text = self.allocator.dupe(u8, self.text.items) catch return,
            .cursor = self.cursor,
            .selection_start = self.selection_start,
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

    pub fn undo(self: *Entry) void {
        if (self.undo_stack.items.len == 0) return;

        const current = EntryUndoItem{
            .text = self.allocator.dupe(u8, self.text.items) catch return,
            .cursor = self.cursor,
            .selection_start = self.selection_start,
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
        self.allocator.free(prev.text);
        self.last_was_char_insert = false;
        self.base.markDirty();
        self.notifyChange();
    }

    pub fn redo(self: *Entry) void {
        if (self.redo_stack.items.len == 0) return;

        const current = EntryUndoItem{
            .text = self.allocator.dupe(u8, self.text.items) catch return,
            .cursor = self.cursor,
            .selection_start = self.selection_start,
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
        self.allocator.free(next.text);
        self.last_was_char_insert = false;
        self.base.markDirty();
        self.notifyChange();
    }

    pub fn getText(self: *const Entry) []const u8 {
        return self.text.items;
    }

    pub fn setText(self: *Entry, new_text: []const u8) !void {
        self.text.clearRetainingCapacity();
        try self.text.appendSlice(self.allocator, new_text);
        self.cursor = new_text.len;
        self.selection_start = null;
        self.base.markDirty();
        // 同步 buffer + 通知 on_change
        if (self.entry_buffer) |b| b.setText(self.text.items);
        self.notifyChange();
    }

    /// 设置文本对齐方式 (左/居中/右; 单行输入两端对齐按左对齐处理)
    pub fn setTextAlign(self: *Entry, alignment: align_mod.TextAlign) void {
        self.text_align = alignment;
        self.base.markDirty();
    }

    /// GTK4: gtk_entry_set_visibility (false=密码模式, 显示圆点)
    pub fn setVisibility(self: *Entry, v: bool) void {
        if (self.visibility != v) {
            self.visibility = v;
            self.base.markDirty();
        }
    }

    pub fn getVisibility(self: *const Entry) bool {
        return self.visibility;
    }

    /// GTK: set_invisible_char — 设置密码遮罩字符
    pub fn setPasswordChar(self: *Entry, ch: u8) void {
        self.password_char = ch;
        self.base.markDirty();
    }

    pub fn getPasswordChar(self: *const Entry) u8 {
        return self.password_char;
    }

    /// 快捷: setPassword(true) = setVisibility(false)
    pub fn setPassword(self: *Entry, pwd: bool) void {
        self.setVisibility(!pwd);
    }

    pub fn isPassword(self: *const Entry) bool {
        return !self.visibility;
    }

    pub fn setTextColor(self: *Entry, color: math.Color) void {
        self.text_color = color;
        self.base.markDirty();
    }

    pub fn setPlaceholder(self: *Entry, placeholder: []const u8) void {
        // 注意: 不拷贝内存, 外部需保证生命周期 (GTK 行为一致)
        self.placeholder = placeholder;
        self.base.markDirty();
    }

    /// GTK4: gtk_entry_get_placeholder_text
    pub fn getPlaceholderText(self: *const Entry) []const u8 {
        return self.placeholder;
    }

    /// GTK4: gtk_entry_set_placeholder_text (setPlaceholder 的别名, GTK 兼容命名)
    pub fn setPlaceholderText(self: *Entry, placeholder: []const u8) void {
        self.setPlaceholder(placeholder);
    }

    pub fn setFontSize(self: *Entry, size: f32) void {
        self.font_size = size;
        self.base.markLayoutDirty();
        self.base.markDirty();
    }

    pub fn setMaxLength(self: *Entry, max: u32) void {
        self.max_length = max;
        // EntryBuffer 同步
        if (self.entry_buffer) |b| b.setMaxBytes(max);
    }

    /// GTK4: gtk_entry_get_max_length
    pub fn getMaxLength(self: *const Entry) u32 {
        return self.max_length;
    }

    /// GTK4: gtk_entry_set_input_hints
    pub fn setInputHints(self: *Entry, hints: InputHints) void {
        self.input_hints = hints;
        self.base.markDirty();
    }

    /// GTK4: gtk_entry_set_activates_default
    pub fn setActivatesDefault(self: *Entry, v: bool) void {
        self.activates_default = v;
        self.base.markDirty();
    }

    /// GTK4: gtk_entry_set_icon_from_icon_name (简化为存储图标名称)
    pub fn setIconFromIconName(self: *Entry, icon_name: ?[]const u8) void {
        self.primary_icon_name = icon_name;
        self.base.markDirty();
    }

    /// GTK4: gtk_entry_set_icon_tooltip_text
    pub fn setIconTooltipText(self: *Entry, tooltip: ?[]const u8) void {
        self.primary_icon_tooltip = tooltip;
        self.base.markDirty();
    }

    /// GTK4: gtk_editable_get_position / gtk_entry_get_position
    pub fn getCursorPosition(self: *const Entry) usize {
        return self.cursor;
    }

    /// GTK4: gtk_editable_set_position
    pub fn setCursorPosition(self: *Entry, pos: usize) void {
        self.cursor = @min(pos, self.text.items.len);
        self.selection_start = null;
        self.base.markDirty();
    }

    /// GTK4: gtk_editable_select_region (start..end 字节偏移; start>end 自动交换; start==end 清除选择)
    pub fn selectRegion(self: *Entry, start: usize, end: usize) void {
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
        self.base.markDirty();
    }

    /// GTK4: gtk_editable_get_selection_bounds
    pub fn getSelectionBounds(self: *const Entry, out_start: *usize, out_end: *usize) bool {
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
    pub fn selectAll(self: *Entry) void {
        self.selectRegion(0, self.text.items.len);
    }

    pub fn hasSelection(self: *const Entry) bool {
        return self.selection_start != null and self.selection_start.? != self.cursor;
    }

    /// 获取当前 preedit 文本
    pub fn getPreedit(self: *const Entry) []const u8 {
        return self.preedit_buf[0..self.preedit_len];
    }

    /// 设置 preedit 文本 (由外部 IME 通道每帧更新)
    pub fn setPreedit(self: *Entry, text: []const u8) void {
        const n = @min(text.len, self.preedit_buf.len);
        @memcpy(self.preedit_buf[0..n], text[0..n]);
        self.preedit_len = n;
        self.base.markDirty();
    }

    /// 清除 preedit
    pub fn clearPreedit(self: *Entry) void {
        self.preedit_len = 0;
    }

    /// 在光标处插入 UTF-8 字节 (IME 提交或外部调用)
    pub fn insertBytes(self: *Entry, bytes: []const u8) void {
        self.pushUndoState(bytes.len == 1);
        if (self.hasSelection()) self.deleteSelectionNoUndo();
        // max_length 限制 (字节级)
        if (self.max_length > 0 and self.text.items.len + bytes.len > self.max_length) {
            const allowed = self.max_length - self.text.items.len;
            if (allowed == 0) return;
            self.text.insertSlice(self.allocator, self.cursor, bytes[0..allowed]) catch return;
            self.cursor += allowed;
        } else {
            self.text.insertSlice(self.allocator, self.cursor, bytes) catch return;
            self.cursor += bytes.len;
        }
        self.selection_start = null;
        self.last_was_char_insert = bytes.len == 1;
        self.notifyChange();
        self.base.markDirty();
    }

    /// 在光标处插入一个 codepoint
    pub fn insertCodepoint(self: *Entry, cp: u21) void {
        var buf: [4]u8 = undefined;
        const len = std.unicode.utf8Encode(cp, &buf) catch return;
        self.insertBytes(buf[0..len]);
    }

    /// 删除光标前 n 个 codepoint (IME delete_surrounding_text)
    pub fn deleteBeforeCursor(self: *Entry, n_codepoints: usize) void {
        self.pushUndoState(false);
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
        self.selection_start = null;
        self.last_was_char_insert = false;
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
        const self: *Entry = @fieldParentPtr("base", w);
        self.destroy(allocator);
    }

    fn measure(w: *Widget, ctx: *PaintContext, constraints: layout_mod.Constraints) math.Size(f32) {
        const self: *Entry = @fieldParentPtr("base", w);
        _ = ctx;
        _ = constraints;
        return .{ .width = 240, .height = self.font_size + self.padding_h * 2 };
    }

    fn paint(w: *Widget, ctx: *PaintContext) void {
        const self: *Entry = @fieldParentPtr("base", w);
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

            // 密码模式: 构建遮罩字符串
            var mask_buf: [256]u8 = undefined;
            const display_text = if (!self.visibility) blk: {
                const len = @min(self.text.items.len, mask_buf.len);
                @memset(mask_buf[0..len], self.password_char);
                break :blk mask_buf[0..len];
            } else self.text.items;

            const text_w = styled_text.measureTextWidth(ctx.allocator, display_text, style);
            const offset = self.alignOffset(text_w, max_w);

            // 选区高亮 (精确文本测量)
            if (self.hasSelection()) {
                const sel_start = @min(self.selection_start.?, self.cursor);
                const sel_end = @max(self.selection_start.?, self.cursor);
                const s0 = @min(sel_start, display_text.len);
                const s1 = @min(sel_end, display_text.len);
                const w0 = styled_text.measureTextWidth(ctx.allocator, display_text[0..s0], style);
                const w1 = styled_text.measureTextWidth(ctx.allocator, display_text[0..s1], style);
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
                display_text,
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
    fn alignOffset(self: *const Entry, text_w: f32, avail_w: f32) f32 {
        const extra = avail_w - text_w;
        if (extra <= 0) return 0;
        return switch (self.text_align) {
            .center => extra / 2.0,
            .right => extra,
            .left, .justify => 0,
        };
    }

    fn onEvent(w: *Widget, event: *const pal.Event, ectx: *EventContext) EventResult {
        const self: *Entry = @fieldParentPtr("base", w);
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
                            self.pushUndoState(false);
                            // 回退一个 UTF-8 codepoint
                            var pos = self.cursor - 1;
                            while (pos > 0 and (self.text.items[pos] & 0xC0) == 0x80) : (pos -= 1) {}
                            const start = pos;
                            var j: usize = self.cursor;
                            while (j > start) : (j -= 1) {
                                _ = self.text.orderedRemove(j - 1);
                            }
                            self.cursor = start;
                            self.last_was_char_insert = false;
                            self.notifyChange();
                        }
                        self.selection_start = null;
                        self.base.markDirty();
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
                        self.selection_start = null;
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
                    // Cmd/Ctrl+C 复制选区
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
                    // Cmd/Ctrl+X 剪切选区
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
                    // Cmd/Ctrl+V 粘贴
                    .v => {
                        if (k.modifiers.super_key or k.modifiers.ctrl) {
                            if (clipboard.getText(self.allocator)) |pasted| {
                                defer self.allocator.free(pasted);
                                if (pasted.len > 0) self.insertBytes(pasted);
                            } else |_| {}
                            return .handled;
                        }
                    },
                    // Cmd/Ctrl+Z 撤销
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

    /// GTK4: gtk_editable_delete_selection — 删除选中内容（推撤销栈）
    pub fn deleteSelection(self: *Entry) void {
        if (!self.hasSelection()) return;
        self.pushUndoState(false);
        self.deleteSelectionNoUndo();
        self.last_was_char_insert = false;
    }

    fn deleteSelectionNoUndo(self: *Entry) void {
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
    fn cursorAtX(self: *const Entry, rel_x: f32) usize {
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

    fn notifyChange(self: *Entry) void {
        if (self.on_change) |cb| {
            cb(self, self.text.items);
        }
    }
};

// ── Context Menu Callbacks ─────────────────────────────────────────────────

fn undoCallback(ctx: ?*anyopaque) void {
    const self: *Entry = @ptrCast(@alignCast(ctx orelse return));
    self.undo();
}

fn redoCallback(ctx: ?*anyopaque) void {
    const self: *Entry = @ptrCast(@alignCast(ctx orelse return));
    self.redo();
}

fn cutCallback(ctx: ?*anyopaque) void {
    const self: *Entry = @ptrCast(@alignCast(ctx orelse return));
    if (self.hasSelection()) {
        const s = @min(self.selection_start.?, self.cursor);
        const e = @max(self.selection_start.?, self.cursor);
        clipboard.setText(self.text.items[s..e]) catch {};
        self.deleteSelection();
        self.base.markDirty();
    }
}

fn copyCallback(ctx: ?*anyopaque) void {
    const self: *Entry = @ptrCast(@alignCast(ctx orelse return));
    if (self.hasSelection()) {
        const s = @min(self.selection_start.?, self.cursor);
        const e = @max(self.selection_start.?, self.cursor);
        clipboard.setText(self.text.items[s..e]) catch {};
    }
}

fn pasteCallback(ctx: ?*anyopaque) void {
    const self: *Entry = @ptrCast(@alignCast(ctx orelse return));
    if (clipboard.getText(self.allocator)) |pasted| {
        defer self.allocator.free(pasted);
        if (pasted.len > 0) self.insertBytes(pasted);
    } else |_| {}
}

fn selectAllCallback(ctx: ?*anyopaque) void {
    const self: *Entry = @ptrCast(@alignCast(ctx orelse return));
    self.selection_start = 0;
    self.cursor = self.text.items.len;
    self.base.markDirty();
}

fn beforeShowCallback(menu: *ContextMenu) void {
    const self: *Entry = blk: {
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

pub const TextInput = Entry;
pub const TextField = Entry;

// ── Tests ──────────────────────────────────────────────────────────────────

test "password input in ScrolledWindow receives focus on click and accepts text" {
    const alloc = std.testing.allocator;
    const Container = @import("container.zig").Container;
    const ScrolledWindow = @import("scrolled_window.zig").ScrolledWindow;

    const root = try Container.create(alloc, .{});
    defer root.destroy(alloc);
    root.base.rect = .{ .x = 0, .y = 0, .width = 400, .height = 400 };

    const sv = try ScrolledWindow.create(alloc, .{ .width = 400, .height = 400 });
    try root.base.addChild(alloc, &sv.base);
    sv.base.rect = .{ .x = 0, .y = 0, .width = 400, .height = 400 };

    const content = try Container.create(alloc, .{ .direction = .column });
    try sv.base.addChild(alloc, &content.base);
    content.base.rect = .{ .x = 0, .y = 0, .width = 400, .height = 800 };

    // 密码输入框 (visibility=false)
    const pwd = try Entry.create(alloc, .{
        .placeholder = "password",
        .visibility = false,
        .max_length = 16,
    });
    try content.base.addChild(alloc, &pwd.base);
    pwd.base.rect = .{ .x = 16, .y = 16, .width = 250, .height = 38 };

    var ectx = EventContext{ .mouse_x = 50, .mouse_y = 50 };

    // 1. 点击密码框 → 应自动聚焦
    var click = pal.Event{ .mouse_button = .{ .window_id = 0, .button = .left, .state = .pressed, .x = 50, .y = 50 } };
    _ = root.base.dispatchEvent(&click, &ectx);
    try std.testing.expect(pwd.base.state.focused);

    // 2. 输入字符 → 应插入文本
    var ti = pal.Event{ .text_input = .{ .window_id = 0, .codepoint = 'a' } };
    _ = root.base.dispatchEvent(&ti, &ectx);
    try std.testing.expectEqualStrings("a", pwd.getText());

    // 3. 再输入一个字符
    var ti2 = pal.Event{ .text_input = .{ .window_id = 0, .codepoint = 'b' } };
    _ = root.base.dispatchEvent(&ti2, &ectx);
    try std.testing.expectEqualStrings("ab", pwd.getText());
}
