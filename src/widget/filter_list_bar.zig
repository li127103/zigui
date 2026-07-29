//! FilterListBar 控件 - 列表过滤栏 (对标 GtkFilterListBar, GTK4.10+)
//!
//! 可展开/折叠的过滤栏，内部包含 SearchEntry。
//! 通常放在 ListView / ColumnView / GridView 顶部，配合 FilterListModel 使用。
//!
//! 使用方法:
//! ```
//! var bar = try FilterListBar.create(allocator, .{
//!     .placeholder = "过滤项目...",
//!     .on_filter_changed = onFilterChanged,
//! });
//! bar.setRevealChild(true); // 显示
//!
//! // in onFilterChanged:
//! //   const filter = model.StringFilter.init(.{.search = text});
//! //   filter_list.setFilter(filter.filter);
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

pub const FilterListBar = struct {
    base: Widget,
    allocator: std.mem.Allocator,
    /// 搜索输入框 (GtkFilterListBar 内部用 GtkSearchEntry)
    search_entry: *SearchEntry,
    /// 是否展开 (false=完全隐藏，true=可见)
    reveal_child: bool = false,
    /// 显示右侧关闭按钮
    show_close_button: bool = true,
    /// 过滤文本变化回调 (包装 SearchEntry.on_search)
    on_filter_changed: ?*const fn (self: *FilterListBar, text: []const u8) void = null,
    /// 关闭按钮 / ESC 回调
    on_close: ?*const fn (self: *FilterListBar) void = null,

    /// 内部布局容器
    container: ?*Container = null,
    close_button: ?*Button = null,

    /// 样式
    bg_color: math.Color = math.Color.hex(0x1E293BFF),
    border_color: math.Color = math.Color.hex(0x334155FF),
    height: f32 = 48,
    corner_radius: f32 = 6,

    const Self = @This();

    // ── 内部: SearchEntry.on_search 的反查包装 ─────────────────────────────
    fn onSearchWrapper(se: *SearchEntry, text: []const u8) void {
        const pw = se.base.parent orelse return;
        // parent 是 FilterListBar.base
        const self: *Self = @fieldParentPtr("base", pw);
        if (self.on_filter_changed) |cb| cb(self, text);
    }

    fn onCloseClicked(b: *Button) void {
        const pw = b.base.parent orelse return; // Container
        const bar_widget = pw.parent orelse return; // FilterListBar
        const self_: *Self = @fieldParentPtr("base", bar_widget);
        self_.setRevealChild(false);
        if (self_.on_close) |c| c(self_);
    }

    pub fn create(allocator: std.mem.Allocator, opts: struct {
        placeholder: []const u8 = "过滤...",
        show_close_button: bool = true,
        on_filter_changed: ?*const fn (self: *Self, text: []const u8) void = null,
        on_close: ?*const fn (self: *Self) void = null,
        bg_color: math.Color = math.Color.hex(0x1E293BFF),
        height: f32 = 48,
    }) !*FilterListBar {
        const self = try allocator.create(FilterListBar);
        self.* = .{
            .base = .{
                .vtable = &vtable,
                .id = widget_mod.genWidgetId(),
            },
            .allocator = allocator,
            .search_entry = undefined,
            .show_close_button = opts.show_close_button,
            .on_filter_changed = opts.on_filter_changed,
            .on_close = opts.on_close,
            .bg_color = opts.bg_color,
            .height = opts.height,
        };
        try self.buildUI(opts.placeholder);
        return self;
    }

    fn buildUI(self: *Self, placeholder: []const u8) !void {
        // 布局: [Container [ (spacer) SearchEntry (gap 8) close_button? ] ]
        const cont = try Container.create(self.allocator, .{
            .direction = .row,
            .gap = .{ .width = 8, .height = 8 },
            .padding = math.EdgeInsets.all(8),
        });
        self.container = cont;
        try self.base.addChild(self.allocator, &cont.base);

        const se = try SearchEntry.create(self.allocator, .{
            .placeholder = placeholder,
            .on_search = onSearchWrapper,
        });
        self.search_entry = se;
        try cont.addChild(self.allocator, &se.base, .{ .expand = true, .fill = true });

        if (self.show_close_button) {
            const btn = try Button.create(self.allocator, "", .{
                .icon = .close,
                .icon_size = 16,
                .on_click = onCloseClicked,
                .bg_color = math.Color.hex(0x334155FF),
                .bg_hover = math.Color.hex(0x475569FF),
                .bg_pressed = math.Color.hex(0x1E293BFF),
            });
            self.close_button = btn;
            try cont.addChild(self.allocator, &btn.base, .{});
        }
        self.base.accessibility = .{ .role = .search, .label = placeholder };
    }

    pub fn destroy(self: *Self, allocator: std.mem.Allocator) void {
        self.base.background.deinit(allocator);
        self.base.children.deinit(allocator);
        if (self.container) |cc| {
            cc.base.vtable.destroy(&cc.base, allocator);
        }
        allocator.destroy(self);
    }

    /// GTK4: gtk_filter_list_bar_set_reveal_child
    pub fn setRevealChild(self: *Self, reveal: bool) void {
        self.reveal_child = reveal;
        self.base.visible = reveal;
        self.base.markDirty();
        if (reveal) {
            // 自动聚焦搜索
            self.search_entry.base.state.focused = true;
        }
    }

    pub fn getRevealChild(self: *const Self) bool {
        return self.reveal_child;
    }

    /// 返回内部 SearchEntry 指针，便于设置额外属性
    pub fn getSearchEntry(self: *Self) *SearchEntry {
        return self.search_entry;
    }

    /// 设置当前过滤文本 (同步到底层 SearchEntry)
    pub fn setFilterText(self: *Self, text: []const u8) void {
        self.search_entry.setText(text) catch {};
    }

    /// 获取当前过滤文本
    pub fn getFilterText(self: *const Self) []const u8 {
        return self.search_entry.getText();
    }

    /// 修改 placeholder
    pub fn setPlaceholder(self: *Self, placeholder: []const u8) void {
        self.search_entry.input.setPlaceholder(placeholder);
    }

    /// 清空过滤文本
    pub fn clear(self: *Self) void {
        self.search_entry.clear();
    }

    // ── Widget vtable ──────────────────────────────────────────────────────
    fn measure(
        widget: *Widget,
        ctx: *const PaintContext,
        available_w: f32,
        available_h: f32,
    ) math.Vec2 {
        const self: *Self = @ptrCast(@alignCast(widget));
        if (!self.reveal_child) {
            return math.Vec2{ .x = @min(available_w, 0), .y = 0 };
        }
        const cont = self.container orelse return .{ .x = @min(available_w, 120), .y = self.height };
        const m = cont.base.vtable.measure(&cont.base, ctx, available_w, available_h);
        const h = @max(self.height, m.y);
        return .{ .x = @max(120, m.x), .y = h };
    }

    fn layout(widget: *Widget, rect: math.Rect, ctx: *const PaintContext) void {
        const self: *Self = @ptrCast(@alignCast(widget));
        if (!self.reveal_child) return;
        if (self.container) |cont| {
            cont.base.vtable.layout(&cont.base, rect, ctx);
        }
    }

    fn paint(widget: *Widget, ctx: *const PaintContext, rect: math.Rect) void {
        const self: *Self = @ptrCast(@alignCast(widget));
        if (!self.reveal_child) return;
        // 背景圆角矩形
        pal.getRenderer2D().fillRectRounded(rect, self.bg_color, self.corner_radius);
        // 顶部细线分隔
        pal.getRenderer2D().strokeRect(
            math.Rect.new(rect.x, rect.y, rect.width, 1),
            self.border_color,
            1,
        );
        // 容器内容
        if (self.container) |cont| {
            cont.base.vtable.paint(&cont.base, ctx, rect);
        }
    }

    fn onEvent(widget: *Widget, ev: *const Widget.Event, ctx: *const EventContext) EventResult {
        const self: *Self = @ptrCast(@alignCast(widget));
        if (!self.reveal_child) return .ignored;

        // ESC 关闭
        switch (ev.*) {
            .key => |k| {
                if (k.state == .pressed and k.key == .escape) {
                    self.setRevealChild(false);
                    if (self.on_close) |c| c(self);
                    return .handled;
                }
            },
            else => {},
        }
        return widget.dispatchEventToChildren(ev, ctx) orelse .ignored;
    }

    const vtable = Widget.VTable{
        .type_name = "FilterListBar",
        .measure = measure,
        .layout = layout,
        .paint = paint,
        .on_event = onEvent,
        .focusable = false,
        .destroy = destroy,
    };
};
