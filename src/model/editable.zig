//! Editable + EntryBuffer + TextBuffer — GTK4 风格的可编辑文本缓冲与接口
//!
//! 对标 GTK4:
//!   - GtkEditableInterface: EditableIface — 统一 get/set/insert/delete/select 的接口胖指针
//!   - GtkEntryBuffer — Entry/TextInput 的底层缓冲 (单字节流, 支持 max_bytes, 插入/删除信号)
//!   - GtkTextBuffer — TextView/TextArea 的多行缓冲 (支持选择区间, changed 信号)

const std = @import("std");
const Allocator = std.mem.Allocator;
const ArrayListUnmanaged = std.ArrayListUnmanaged;

// ═══════════════════════════════════════════════════════════════════════════
// 内部辅助: 在 ArrayListUnmanaged 中插入/删除切片
// ═══════════════════════════════════════════════════════════════════════════

fn insertBytes(al: Allocator, list: *ArrayListUnmanaged(u8), pos: usize, bytes: []const u8) !void {
    const orig_len = list.items.len;
    if (pos > orig_len) return error.InvalidPosition;
    const new_len = orig_len + bytes.len;
    try list.ensureTotalCapacity(al, new_len);
    list.items.len = new_len;
    // shift right: [pos..orig_len] → [pos+bytes.len..new_len]
    if (pos < orig_len) {
        const to_move = orig_len - pos;
        const src = list.items[pos..][0..to_move];
        const dst = list.items[pos + bytes.len ..][0..to_move];
        std.mem.copyBackwards(u8, dst, src);
    }
    const insert_dst = list.items[pos..][0..bytes.len];
    @memcpy(insert_dst, bytes);
}

fn listDeleteRange(list: *ArrayListUnmanaged(u8), start: usize, end: usize) void {
    const orig_len = list.items.len;
    const s = @min(start, orig_len);
    const e = @min(end, orig_len);
    if (e <= s) return;
    const rest = orig_len - e;
    if (rest > 0) {
        const src = list.items[e..][0..rest];
        const dst = list.items[s..][0..rest];
        std.mem.copyForwards(u8, dst, src);
    }
    list.items.len = orig_len - (e - s);
}

// ═══════════════════════════════════════════════════════════════════════════
// EntryBuffer — GtkEntryBuffer (单字节文本缓冲)
// ═══════════════════════════════════════════════════════════════════════════

pub const EntryBuffer = struct {
    allocator: Allocator,
    bytes: ArrayListUnmanaged(u8) = .empty,
    /// 0 = 不限
    max_bytes: usize = 0,

    // 信号回调
    on_inserted_text: ?*const fn (buf: *EntryBuffer, position: usize, chars: []const u8, n_chars: usize) void = null,
    on_deleted_text: ?*const fn (buf: *EntryBuffer, position: usize, n_chars: usize) void = null,
    userdata: ?*anyopaque = null,

    pub fn create(allocator: Allocator, initial_text: []const u8, max_bytes: usize) !*EntryBuffer {
        const self = try allocator.create(EntryBuffer);
        self.* = .{ .allocator = allocator, .max_bytes = max_bytes };
        if (initial_text.len > 0) {
            const n = if (max_bytes == 0) initial_text.len else @min(max_bytes, initial_text.len);
            try self.bytes.appendSlice(allocator, initial_text[0..n]);
        }
        return self;
    }

    pub fn destroy(self: *EntryBuffer) void {
        self.bytes.deinit(self.allocator);
        self.allocator.destroy(self);
    }

    pub fn getBytes(self: *const EntryBuffer) []const u8 {
        return self.bytes.items;
    }

    pub fn getZ(self: *EntryBuffer) [:0]const u8 {
        // 如果末尾已经是 0，直接切片
        if (self.bytes.items.len > 0) {
            const last = self.bytes.items[self.bytes.items.len - 1];
            if (last == 0) return self.bytes.items[0 .. self.bytes.items.len - 1 :0];
        }
        // 追加一个 0 (下次写入会覆盖)
        self.bytes.append(self.allocator, 0) catch return self.bytes.items[0..0 :0];
        return self.bytes.items[0 .. self.bytes.items.len - 1 :0];
    }

    pub fn getLength(self: *const EntryBuffer) usize {
        return self.bytes.items.len;
    }

    pub fn setMaxBytes(self: *EntryBuffer, mb: usize) void {
        self.max_bytes = mb;
        if (mb != 0 and self.bytes.items.len > mb) {
            const old_len = self.bytes.items.len;
            listDeleteRange(&self.bytes, mb, old_len);
            if (self.on_deleted_text) |cb| cb(self, mb, old_len - mb);
        }
    }

    pub fn getMaxBytes(self: *const EntryBuffer) usize {
        return self.max_bytes;
    }

    pub fn setText(self: *EntryBuffer, text: []const u8) void {
        const avail = if (self.max_bytes == 0) text.len else @min(self.max_bytes, text.len);
        const old_len = self.bytes.items.len;
        // 清空再 append
        self.bytes.clearRetainingCapacity();
        self.bytes.appendSlice(self.allocator, text[0..avail]) catch return;
        if (old_len > 0) {
            if (self.on_deleted_text) |cb| cb(self, 0, old_len);
        }
        if (avail > 0) {
            if (self.on_inserted_text) |cb| cb(self, 0, self.bytes.items[0..avail], avail);
        }
    }

    pub fn insertText(self: *EntryBuffer, position: usize, chars: []const u8) usize {
        const pos = @min(position, self.bytes.items.len);
        var avail = chars.len;
        if (self.max_bytes != 0) {
            const cap = self.max_bytes -| self.bytes.items.len;
            if (avail > cap) avail = cap;
        }
        if (avail == 0) return 0;
        insertBytes(self.allocator, &self.bytes, pos, chars[0..avail]) catch return 0;
        if (self.on_inserted_text) |cb| cb(self, pos, self.bytes.items[pos..][0..avail], avail);
        return avail;
    }

    pub fn deleteText(self: *EntryBuffer, position: usize, n_chars: usize) void {
        const old_len = self.bytes.items.len;
        const pos = @min(position, old_len);
        const n = @min(n_chars, old_len - pos);
        if (n == 0) return;
        listDeleteRange(&self.bytes, pos, pos + n);
        if (self.on_deleted_text) |cb| cb(self, pos, n);
    }
};

// ═══════════════════════════════════════════════════════════════════════════
// TextBuffer — GtkTextBuffer (多行文本缓冲)
// ═══════════════════════════════════════════════════════════════════════════

pub const TextSelection = struct {
    start: usize = 0,
    end: usize = 0,
};

pub const TextBuffer = struct {
    allocator: Allocator,
    bytes: ArrayListUnmanaged(u8) = .{},
    /// 行起始偏移缓存, line_starts.len == 行数
    line_starts: ArrayListUnmanaged(usize) = .{},

    cursor_pos: usize = 0,
    selection: ?TextSelection = null,

    on_changed: ?*const fn (buf: *TextBuffer, userdata: ?*anyopaque) void = null,
    userdata: ?*anyopaque = null,

    pub fn create(allocator: Allocator, initial: []const u8) !*TextBuffer {
        const self = try allocator.create(TextBuffer);
        self.* = .{ .allocator = allocator };
        if (initial.len > 0) {
            try self.bytes.appendSlice(allocator, initial);
        }
        try self.rebuildLineStarts();
        return self;
    }

    pub fn destroy(self: *TextBuffer) void {
        self.bytes.deinit(self.allocator);
        self.line_starts.deinit(self.allocator);
        self.allocator.destroy(self);
    }

    pub fn getBytes(self: *const TextBuffer) []const u8 {
        return self.bytes.items;
    }

    pub fn getLength(self: *const TextBuffer) usize {
        return self.bytes.items.len;
    }

    pub fn getLineCount(self: *const TextBuffer) usize {
        return if (self.line_starts.items.len == 0) 1 else self.line_starts.items.len;
    }

    pub fn setText(self: *TextBuffer, text: []const u8) void {
        self.bytes.clearRetainingCapacity();
        self.bytes.appendSlice(self.allocator, text) catch return;
        self.rebuildLineStarts() catch return;
        self.cursor_pos = 0;
        self.selection = null;
        if (self.on_changed) |cb| cb(self, self.userdata);
    }

    pub fn insert(self: *TextBuffer, byte_offset: usize, text: []const u8) void {
        const pos = @min(byte_offset, self.bytes.items.len);
        insertBytes(self.allocator, &self.bytes, pos, text) catch return;
        if (self.cursor_pos >= pos) self.cursor_pos += text.len;
        if (self.selection) |*s| {
            if (s.start >= pos) s.start += text.len;
            if (s.end >= pos) s.end += text.len;
        }
        self.rebuildLineStarts() catch return;
        if (self.on_changed) |cb| cb(self, self.userdata);
    }

    pub fn deleteRange(self: *TextBuffer, start: usize, end: usize) void {
        const total = self.bytes.items.len;
        const s = @min(start, total);
        const e = @min(end, total);
        if (e <= s) return;
        const len = e - s;
        listDeleteRange(&self.bytes, s, e);
        if (self.cursor_pos >= e) {
            self.cursor_pos -= len;
        } else if (self.cursor_pos >= s) {
            self.cursor_pos = s;
        }
        if (self.selection) |*sel| {
            if (sel.start >= e) sel.start -= len else if (sel.start >= s) sel.start = s;
            if (sel.end >= e) sel.end -= len else if (sel.end >= s) sel.end = s;
        }
        self.rebuildLineStarts() catch return;
        if (self.on_changed) |cb| cb(self, self.userdata);
    }

    pub fn placeCursor(self: *TextBuffer, offset: usize) void {
        self.cursor_pos = @min(offset, self.bytes.items.len);
        self.selection = null;
    }

    pub fn selectRange(self: *TextBuffer, start: usize, end: usize) void {
        const total = self.bytes.items.len;
        const s = @min(start, total);
        const e = @min(end, total);
        self.selection = .{ .start = @min(s, e), .end = @max(s, e) };
        self.cursor_pos = e;
    }

    pub fn getSelection(self: *const TextBuffer) ?TextSelection {
        return self.selection;
    }

    fn rebuildLineStarts(self: *TextBuffer) !void {
        self.line_starts.clearRetainingCapacity();
        try self.line_starts.append(self.allocator, 0);
        for (self.bytes.items, 0..) |c, i| {
            if (c == '\n') try self.line_starts.append(self.allocator, i + 1);
        }
    }
};

// ═══════════════════════════════════════════════════════════════════════════
// EditableIface + Editable 胖指针
// ═══════════════════════════════════════════════════════════════════════════

pub const EditableIface = struct {
    getTextFn: *const fn (userdata: ?*anyopaque) []const u8,
    setTextFn: *const fn (userdata: ?*anyopaque, text: []const u8) void,
    insertTextFn: *const fn (userdata: ?*anyopaque, position: usize, text: []const u8) usize,
    deleteTextFn: *const fn (userdata: ?*anyopaque, position: usize, n_chars: usize) void,
    getPositionFn: *const fn (userdata: ?*anyopaque) usize,
    selectRegionFn: *const fn (userdata: ?*anyopaque, start: usize, end: usize) void,
    getSelectionBoundsFn: *const fn (userdata: ?*anyopaque, start: *usize, end: *usize) bool,

    getEntryBufferFn: ?*const fn (userdata: ?*anyopaque) ?*EntryBuffer = null,
    getTextBufferFn: ?*const fn (userdata: ?*anyopaque) ?*TextBuffer = null,
};

pub const Editable = struct {
    iface: *const EditableIface,
    userdata: ?*anyopaque,

    pub fn getText(self: Editable) []const u8 {
        return self.iface.getTextFn(self.userdata);
    }
    pub fn setText(self: Editable, text: []const u8) void {
        self.iface.setTextFn(self.userdata, text);
    }
    pub fn insertText(self: Editable, position: usize, text: []const u8) usize {
        return self.iface.insertTextFn(self.userdata, position, text);
    }
    pub fn deleteText(self: Editable, position: usize, n: usize) void {
        self.iface.deleteTextFn(self.userdata, position, n);
    }
    pub fn getPosition(self: Editable) usize {
        return self.iface.getPositionFn(self.userdata);
    }
    pub fn selectRegion(self: Editable, start: usize, end: usize) void {
        self.iface.selectRegionFn(self.userdata, start, end);
    }
    pub fn getSelectionBounds(self: Editable, start: *usize, end: *usize) bool {
        return self.iface.getSelectionBoundsFn(self.userdata, start, end);
    }
    pub fn getEntryBuffer(self: Editable) ?*EntryBuffer {
        const f = self.iface.getEntryBufferFn orelse return null;
        return f(self.userdata);
    }
    pub fn getTextBuffer(self: Editable) ?*TextBuffer {
        const f = self.iface.getTextBufferFn orelse return null;
        return f(self.userdata);
    }
};
