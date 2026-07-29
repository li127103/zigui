//! SearchBar 控件 - 搜索栏 (对标 GtkSearchBar)
//!
//! 可显示/隐藏的搜索栏, 内部包含 SearchEntry。
//! 通常放在窗口顶部, 支持通过键盘快捷键(Ctrl+F)切换显示。
//!
//! 使用方法:
//! ```
//! var bar = try SearchBar.create(allocator, .{
//!     .placeholder = "搜索...",
//!     .on_search_changed = onSearchChanged,
//! });
//! bar.setRevealChild(true); // 显示
//! ```

const std = @import("std");
const math = @import("../math.zig");
const widget_mod = @import("widget.zig");
const pal = @import("../pal/pal.zig");
const container_mod = @import("container.zig");
const search_entry_mod = @import("search_entry.zig");
const button_mod = @import("button.zig");
const label_mod = @import("label.zig");
const icons_mod = @import("icons.zig");

const Widget = widget_mod.Widget;
const PaintContext = widget_mod.PaintContext;
const EventContext = widget_mod.EventContext;
const EventResult = widget_mod.EventResult;
const Container = container_mod.Container;
const SearchEntry = search_entry_mod.SearchEntry;
const Button = button_mod.Button;
const Label = label_mod.Label;

pub const SearchBar = struct {
    base: Widget,
    allocator: std.mem.Allocator,
    search_entry: *SearchEntry,
    reveal_child: bool = false,
    show_close_button: bool = true,
    on_search_changed: ?*const fn (self: *SearchBar, text: []const u8) void = null,
    on_close: ?*const fn (self: *SearchBar) void = null,
    // GTK4 新增字段
    search_mode_enabled: bool = true,

    container: ?*Container = null,
    close_button: ?*Button = null,

    bg_color: math.Color = math.Color.hex(0x1E293BFF),
    border_color: math.Color = math.Color.hex(0x334155FF),
    height: f32 = 48,
    corner_radius: f32 = 6,

    const Self = @This();

    pub fn create(allocator: std.mem.Allocator, opts: struct {
        placeholder: []const u8 = "搜索...",
        show_close_button: bool = true,
        on_search_changed: ?*const fn (self: *SearchBar, text: []const u8) void = null,
        on_close: ?*const fn (self: *SearchBar) void = null,
        bg_color: math.Color = math.Color.hex(0x1E293BFF),
        height: f32 = 48,
    }) !*SearchBar {
        const self = try allocator.create(SearchBar);
        self.* = .{
            .base = .{
                .vtable = &vtable,
                .id = widget_mod.genWidgetId(),
            },
            .allocator = allocator,
            .search_entry = undefined,
            .show_close_button = opts.show_close_button,
            .on_search_changed = opts.on_search_changed,
            .on_close = opts.on_close,
            .bg_color = opts.bg_color,
            .height = opts.height,
        };
        try self.buildUI(opts.placeholder);
        return self;
    }

    pub fn destroy(self: *Self, allocator: std.mem.Allocator) void {
        self.base.background.deinit(allocator);
        self.base.children.deinit(allocator);
        if (self.container) |cc| {
            cc.base.vtable.destroy(&cc.base, allocator);
        }
        allocator.destroy(self);
    }

    pub fn setRevealChild(self: *Self, reveal: bool) void {
        self.reveal_child = reveal;
        self.base.markDirty();
        if (reveal) {
            // 显示时聚焦搜索框
            self.search_entry.base.state.focused = true;
        }
    }

    pub fn getRevealChild(self: *const Self) bool {
        return self.reveal_child;
    }

    // ── GTK4 SearchBar 新增 API ────────────────────────────────────────────

    /// GTK4: gtk_search_bar_set_search_mode
    pub fn setSearchMode(self: *Self, mode: bool) void {
        self.search_mode_enabled = mode;
        if (mode) {
            self.setRevealChild(true);
        }
    }

    /// GTK4: gtk_search_bar_get_search_mode
    pub fn getSearchMode(self: *const Self) bool {
        return self.search_mode_enabled and self.reveal_child;
    }

    /// GTK4: gtk_search_bar_connect_entry — 关联外部 SearchEntry
    pub fn connectEntry(self: *Self, entry: *SearchEntry) !void {
        // 解绑旧的 search_entry 回调
        self.search_entry.on_search = null;
        self.search_entry.base.user_data = null;
        // 绑定新的
        self.search_entry = entry;
        entry.base.user_data = self;
        entry.on_search = onEntrySearch;
    }

    /// GTK4: gtk_search_bar_get_search_entry
    pub fn getSearchEntry(self: *const Self) *SearchEntry {
        return self.search_entry;
    }

    /// GTK4: gtk_search_bar_set_search_entry
    pub fn setSearchEntry(self: *Self, entry: *SearchEntry) !void {
        try self.connectEntry(entry);
    }

    /// GTK4: gtk_search_bar_set_show_close_button
    pub fn setShowCloseButton(self: *Self, show: bool) void {
        self.show_close_button = show;
        if (self.close_button) |btn| {
            btn.base.visible = show;
            self.base.markDirty();
        }
    }

    /// GTK4: gtk_search_bar_get_show_close_button
    pub fn getShowCloseButton(self: *const Self) bool {
        return self.show_close_button;
    }

    pub fn setText(self: *Self, text: []const u8) void {
        self.search_entry.setText(text) catch {};
    }

    pub fn getText(self: *const Self) []const u8 {
        return self.search_entry.getText();
    }

    fn buildUI(self: *Self, placeholder: []const u8) !void {
        const alloc = self.allocator;

        const content = try Container.create(alloc, .{
            .direction = .row,
            .bg_color = self.bg_color,
            .padding = .{ .left = 12, .right = 12, .top = 8, .bottom = 8 },
            .gap = .{ .width = 8, .height = 0 },
        });
        self.container = content;
        try self.base.addChild(alloc, &content.base);

        const se = try SearchEntry.create(alloc, .{
            .placeholder = placeholder,
            .on_search = onEntrySearch,
        });
        se.base.layout_style.flex_grow = 1;
        self.search_entry = se;
        se.base.user_data = self;
        try content.base.addChild(alloc, &se.base);

        if (self.show_close_button) {
            const close_btn = try Button.create(alloc, "×", .{
                .on_click = onCloseClick,
            });
            close_btn.base.layout_style.min_width = .{ .px = 32 };
            close_btn.base.tooltip_text = "关闭搜索 (Esc)";
            self.close_button = close_btn;
            close_btn.base.user_data = self;
            try content.base.addChild(alloc, &close_btn.base);
        }
    }

    fn onEntrySearch(entry: *SearchEntry, text: []const u8) void {
        const self: *Self = @ptrCast(@alignCast(entry.base.user_data orelse return));
        if (self.on_search_changed) |cb| cb(self, text);
    }

    fn onCloseClick(btn: *Button) void {
        const self: *Self = @ptrCast(@alignCast(btn.base.user_data orelse return));
        self.setRevealChild(false);
        self.setText("");
        if (self.on_close) |cb| cb(self);
    }

    const vtable = Widget.VTable{
        .type_name = "search_bar",
        .measure = measure,
        .paint = paint,
        .on_event = onEvent,
        .focusable = false,
        .destroy = destroyVTable,
    };

    fn destroyVTable(w: *Widget, allocator: std.mem.Allocator) void {
        const self: *Self = @fieldParentPtr("base", w);
        self.destroy(allocator);
    }

    fn measure(w: *Widget, ctx: *PaintContext, constraints: @import("../layout/engine.zig").Constraints) math.Size(f32) {
        const self: *Self = @fieldParentPtr("base", w);
        _ = ctx;
        if (!self.reveal_child) {
            return constraints.constrain(.{ .width = 0, .height = 0 });
        }
        return constraints.constrain(.{ .width = constraints.max_width, .height = self.height });
    }

    fn paint(w: *Widget, ctx: *PaintContext) void {
        const self: *Self = @fieldParentPtr("base", w);
        if (!self.reveal_child) return;

        const rect = w.rect;
        ctx.renderer.fillRoundedRect(rect, self.corner_radius, self.bg_color) catch {};
        ctx.renderer.drawShadow(rect, self.corner_radius, .{
            .offset_y = 2,
            .blur_radius = 8,
            .color = math.Color.hex(0x00000040),
        }) catch {};

        if (self.container) |cc| {
            cc.base.rect = rect;
            cc.base.vtable.paint(&cc.base, ctx);
        }
    }

    fn onEvent(w: *Widget, event: *const pal.Event, ectx: *EventContext) EventResult {
        const self: *Self = @fieldParentPtr("base", w);

        // ── P34.3: Ctrl+F 切换搜索栏显示（即使 reveal_child=false 也可激活）──
        if (event.* == .key and event.key.state == .pressed and event.key.modifiers.ctrl) {
            const ke = event.key;
            // 归一化 key → 0x00-0x7F ASCII 比较 'F'/'f'
            const code = @as(u32, ke.keycode_normalized);
            if (code == 'F' or code == 'f') {
                self.setSearchMode(true);
                return .handled;
            }
        }

        if (!self.reveal_child) return .ignored;

        if (self.container) |cc| {
            if (cc.base.vtable.on_event) |ev_fn| {
                const result = ev_fn(&cc.base, event, ectx);
                if (result == .handled) return .handled;
            }
        }

        if (event.* == .key and event.key.state == .pressed) {
            if (event.key.key == .escape) {
                // ── P34.4: ESC 分级关闭（GTK4 默认交互）──
                // 1) 若搜索框有文本 → 先清空，不关闭
                if (self.search_entry.getText().len > 0) {
                    self.setText("");
                    if (self.on_search_changed) |cb| cb(self, "");
                    return .handled;
                }
                // 2) 无文本 → 真正关闭 SearchBar
                self.setRevealChild(false);
                if (self.on_close) |cb| cb(self);
                return .handled;
            }
        }

        return .ignored;
    }
};
