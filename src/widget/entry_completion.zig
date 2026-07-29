//! EntryCompletion — Entry 自动补全控件
//!
//! GTK 对应: GtkEntryCompletion
//!
//! 绑定到 Entry（通过 EventController 挂接），当用户输入 ≥ minimum_key_length
//! 个字符时弹出候选列表；按方向键导航、Enter 补全、Esc 关闭。
//!
//! 使用方法:
//! ```
//! var comp = try EntryCompletion.create(allocator, .{});
//! for (suggestions) |s| try comp.appendSuggestion(allocator, s);
//! comp.attachTo(&my_entry);
//! ```

const std = @import("std");
const math = @import("../math.zig");
const widget_mod = @import("widget.zig");
const pal = @import("../pal/pal.zig");

const Widget = widget_mod.Widget;
const EventContext = widget_mod.EventContext;
const EventResult = widget_mod.EventResult;
const EventController = widget_mod.EventController;

/// 候选条目
pub const Suggestion = struct {
    text: []const u8,
    user_data: ?*anyopaque = null,
};

pub const EntryCompletion = struct {
    allocator: std.mem.Allocator,
    suggestions: std.ArrayListUnmanaged(Suggestion) = .empty,

    /// 自定义匹配函数；返回 true 表示该建议应显示
    match_func: ?*const fn (comp: *EntryCompletion, key: []const u8, sug: []const u8) bool = null,
    /// 触发候选的最小输入长度（默认 1）
    minimum_key_length: u32 = 1,
    /// 选择建议后回调
    on_match_selected: ?*const fn (self: *EntryCompletion, suggestion: *Suggestion) void = null,

    // 运行时状态
    attached_entry: ?*Widget = null,
    popup_open: bool = false,
    /// 当前过滤后的候选索引（指向 self.suggestions）
    filtered: std.ArrayListUnmanaged(usize) = .empty,
    /// filtered 中的选中索引
    selected_idx: i32 = -1,
    /// 是否包含匹配（true）还是前缀匹配（false）。默认 true。
    match_contains: bool = true,
    /// 是否忽略大小写。默认 true
    match_case_insensitive: bool = true,

    controller_handle: ?EventController = null,

    const Self = @This();

    pub fn create(allocator: std.mem.Allocator, opts: struct {
        minimum_key_length: u32 = 1,
        match_contains: bool = true,
        match_case_insensitive: bool = true,
        on_match_selected: ?*const fn (self: *EntryCompletion, suggestion: *Suggestion) void = null,
    }) !*EntryCompletion {
        const self = try allocator.create(EntryCompletion);
        self.* = .{
            .allocator = allocator,
            .minimum_key_length = opts.minimum_key_length,
            .match_contains = opts.match_contains,
            .match_case_insensitive = opts.match_case_insensitive,
            .on_match_selected = opts.on_match_selected,
        };
        return self;
    }

    pub fn destroy(self: *Self) void {
        self.detach();
        self.suggestions.deinit(self.allocator);
        self.filtered.deinit(self.allocator);
        self.allocator.destroy(self);
    }

    // ── 建议管理 ────────────────────────────────────────────────────────────────

    pub fn appendSuggestion(self: *Self, allocator: std.mem.Allocator, text: []const u8, user_data: ?*anyopaque) !void {
        const owned = try allocator.alloc(u8, text.len);
        @memcpy(owned, text);
        try self.suggestions.append(self.allocator, .{ .text = owned, .user_data = user_data });
    }

    pub fn setSuggestions(self: *Self, suggs: []const Suggestion) !void {
        self.suggestions.deinit(self.allocator);
        try self.suggestions.appendSlice(self.allocator, suggs);
    }

    pub fn clearSuggestions(self: *Self) void {
        self.suggestions.deinit(self.allocator);
    }

    // ── 挂接 / 解除挂接 ───────────────────────────────────────────────────────

    pub fn attachTo(self: *Self, entry_widget: *Widget) void {
        self.detach();
        self.attached_entry = entry_widget;
        const ctrl = EventController.wrap(Self, self, handleEvent, null, "EntryCompletion");
        if (entry_widget.addEventController(self.allocator, ctrl)) {
            self.controller_handle = ctrl;
        } else |_| {
            self.controller_handle = null;
        }
    }

    pub fn detach(self: *Self) void {
        if (self.attached_entry) |w| {
            if (self.controller_handle) |ctrl| {
                w.removeEventController(ctrl);
                self.controller_handle = null;
            }
        }
        self.attached_entry = null;
        self.popup_open = false;
        self.filtered.deinit(self.allocator);
        self.selected_idx = -1;
    }

    // ── 匹配 / 过滤 ─────────────────────────────────────────────────────────────

    fn defaultMatch(self: *Self, key: []const u8, sug_text: []const u8) bool {
        if (self.match_func) |mf| return mf(self, key, sug_text);
        if (key.len == 0) return false;
        if (sug_text.len < key.len) return false;
        if (self.match_case_insensitive) {
            const k = std.ascii.lowerString(&key_buf, key);
            _ = k;
            // 更可靠：逐字符比较
            var i: usize = 0;
            while (i + key.len <= sug_text.len) : (i += 1) {
                var ok = true;
                var j: usize = 0;
                while (j < key.len) : (j += 1) {
                    const a = std.ascii.toLower(sug_text[i + j]);
                    const b = std.ascii.toLower(key[j]);
                    if (a != b) {
                        ok = false;
                        break;
                    }
                }
                if (ok) {
                    if (!self.match_contains and i != 0) return false;
                    return true;
                }
            }
            return false;
        } else {
            if (self.match_contains) {
                return std.mem.indexOf(u8, sug_text, key) != null;
            } else {
                return std.mem.startsWith(u8, sug_text, key);
            }
        }
    }

    /// 键值栈（栈上小缓冲区）
    var key_buf: [256]u8 = undefined;
    var _sug_lower_buf: [1024]u8 = undefined;

    pub fn refilter(self: *Self, key: []const u8) void {
        self.filtered.deinit(self.allocator);
        if (key.len < self.minimum_key_length) {
            self.popup_open = false;
            self.selected_idx = -1;
            return;
        }
        for (self.suggestions.items, 0..) |s, i| {
            if (self.defaultMatch(key, s.text)) {
                self.filtered.append(self.allocator, i) catch break;
            }
        }
        self.popup_open = self.filtered.items.len > 0;
        self.selected_idx = if (self.popup_open) 0 else -1;
    }

    pub fn isPopupOpen(self: *Self) bool {
        return self.popup_open;
    }

    pub fn getSelectedSuggestion(self: *Self) ?*Suggestion {
        if (!self.popup_open) return null;
        if (self.selected_idx < 0) return null;
        const idx: usize = @intCast(self.selected_idx);
        if (idx >= self.filtered.items.len) return null;
        const sug_idx = self.filtered.items[idx];
        return &self.suggestions.items[sug_idx];
    }

    // ── EventController shim ──────────────────────────────────────────────────

    fn handleEvent(self: *Self, _widget: *Widget, event: *const pal.Event, _ectx: *EventContext) EventResult {
        _ = _widget;
        _ = _ectx;
        switch (event.*) {
            .key => |k| {
                if (!self.popup_open) return .pass;
                if (k.action != .press and k.action != .repeat) return .pass;
                switch (k.key) {
                    .arrow_up => {
                        if (self.filtered.items.len > 0) {
                            if (self.selected_idx <= 0) {
                                self.selected_idx = @intCast(self.filtered.items.len - 1);
                            } else {
                                self.selected_idx -= 1;
                            }
                        }
                        return .handled;
                    },
                    .arrow_down => {
                        if (self.filtered.items.len > 0) {
                            const n: i32 = @intCast(self.filtered.items.len);
                            self.selected_idx += 1;
                            if (self.selected_idx >= n) self.selected_idx = 0;
                        }
                        return .handled;
                    },
                    .enter, .kp_enter => {
                        if (self.getSelectedSuggestion()) |sug| {
                            if (self.on_match_selected) |cb| cb(self, sug);
                            self.popup_open = false;
                        }
                        return .pass;
                    },
                    .escape => {
                        self.popup_open = false;
                        self.selected_idx = -1;
                        return .handled;
                    },
                    else => return .pass,
                }
            },
            .text_input => |ti| {
                // refilter 在 entry 插入完文本后由上层调用（或者这里存一个 pending key）
                _ = ti;
                return .pass;
            },
            .mouse_button => |mb| {
                if (mb.action == .press) {
                    // 点击任何地方关闭 popup
                    self.popup_open = false;
                }
                return .pass;
            },
            else => return .pass,
        }
    }
};
