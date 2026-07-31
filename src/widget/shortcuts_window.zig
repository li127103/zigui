//! ShortcutsWindow 控件 - 快捷键窗口
//!
//! 类似 GtkShortcutsWindow: 显示应用程序快捷键的对话框。
//! 按分类组织快捷键, 支持搜索功能, 方便用户查看和学习快捷键。
//!
//! 支持:
//! - 多组快捷键分类
//! - 每组包含多个快捷键条目
//! - 搜索过滤
//! - 键盘导航
//! - 可定制样式

const std = @import("std");
const math = @import("../math.zig");
const widget_mod = @import("widget.zig");
const layout_mod = @import("../layout/engine.zig");
const pal = @import("../pal/pal.zig");
const styled_text = @import("../text/styled_text.zig");
const scrolled_window_mod = @import("scrolled_window.zig");
const search_entry_mod = @import("search_entry.zig");

const Widget = widget_mod.Widget;
const PaintContext = widget_mod.PaintContext;
const EventContext = widget_mod.EventContext;
const EventResult = widget_mod.EventResult;

/// 快捷键条目
pub const ShortcutEntry = struct {
    title: []const u8,
    shortcut: []const u8,
    subtitle: []const u8 = "",
};

/// 快捷键分组
pub const ShortcutGroup = struct {
    title: []const u8,
    entries: []const ShortcutEntry = &.{},
};

pub const ShortcutsWindow = struct {
    base: Widget,
    allocator: std.mem.Allocator,
    groups: std.ArrayListUnmanaged(ShortcutGroup),
    search_text: []const u8 = "",
    scroll_view: ?*scrolled_window_mod.ScrolledWindow = null,
    content_widget: ?*Widget = null,

    window_title: []const u8 = "Keyboard Shortcuts",
    modal: bool = true,

    title_font_size: f32 = 18,
    group_title_font_size: f32 = 14,
    entry_font_size: f32 = 13,
    shortcut_font_size: f32 = 12,
    subtitle_font_size: f32 = 11,

    bg_color: math.Color = math.Color.hex(0xF8FAFCFF),
    text_color: math.Color = math.Color.hex(0x0F172AFF),
    group_title_color: math.Color = math.Color.hex(0x334155FF),
    shortcut_text_color: math.Color = math.Color.hex(0x475569FF),
    subtitle_color: math.Color = math.Color.hex(0x64748BFF),
    border_color: math.Color = math.Color.hex(0xE2E8F0FF),
    hover_bg: math.Color = math.Color.hex(0xF1F5F9FF),

    padding: f32 = 20,
    group_spacing: f32 = 24,
    entry_spacing: f32 = 8,
    entry_padding: f32 = 8,

    const Self = @This();

    pub fn create(allocator: std.mem.Allocator, opts: struct {
        window_title: []const u8 = "Keyboard Shortcuts",
        modal: bool = true,
        title_font_size: f32 = 18,
        group_title_font_size: f32 = 14,
        entry_font_size: f32 = 13,
        shortcut_font_size: f32 = 12,
        subtitle_font_size: f32 = 11,
    }) !*ShortcutsWindow {
        const self = try allocator.create(ShortcutsWindow);
        self.* = .{
            .base = .{
                .vtable = &vtable,
                .id = widget_mod.genWidgetId(),
            },
            .allocator = allocator,
            .groups = .empty,
            .window_title = opts.window_title,
            .modal = opts.modal,
            .title_font_size = opts.title_font_size,
            .group_title_font_size = opts.group_title_font_size,
            .entry_font_size = opts.entry_font_size,
            .shortcut_font_size = opts.shortcut_font_size,
            .subtitle_font_size = opts.subtitle_font_size,
        };
        self.base.accessibility = .{ .role = .dialog };
        return self;
    }

    pub fn destroy(self: *Self, allocator: std.mem.Allocator) void {
        if (self.search_text.len > 0) {
            allocator.free(self.search_text);
        }
        self.groups.deinit(allocator);
        self.base.background.deinit(allocator);
        self.base.children.deinit(allocator);
        allocator.destroy(self);
    }

    /// 添加一个快捷键组
    pub fn addGroup(self: *Self, group: ShortcutGroup) !void {
        try self.groups.append(self.allocator, group);
        self.base.markLayoutDirty();
    }

    /// 设置搜索文本
    pub fn setSearchText(self: *Self, text: []const u8) !void {
        if (self.search_text.len > 0) {
            self.allocator.free(self.search_text);
        }
        self.search_text = try self.allocator.dupe(u8, text);
        self.base.markDirty();
    }

    /// 计算内容高度
    fn calcContentHeight(self: *const Self, ctx: *PaintContext, width: f32) f32 {
        _ = width;
        var h: f32 = self.padding * 2;

        const search_height: f32 = 40;
        h += search_height + self.padding;

        const title_size = styled_text.measureText(ctx.allocator, self.window_title, .{
            .font_size = self.title_font_size,
            .font_weight = 700,
        });
        h += title_size.height + self.group_spacing;

        for (self.groups.items) |group| {
            const visible_entries = self.getVisibleEntries(group);
            if (visible_entries == 0 and self.search_text.len > 0) continue;

            const group_title_size = styled_text.measureText(ctx.allocator, group.title, .{
                .font_size = self.group_title_font_size,
                .font_weight = 600,
            });
            h += group_title_size.height + self.entry_spacing;

            for (group.entries) |entry| {
                if (!self.entryMatches(entry)) continue;

                var entry_h: f32 = self.entry_padding * 2;
                const entry_title_size = styled_text.measureText(ctx.allocator, entry.title, .{
                    .font_size = self.entry_font_size,
                });
                entry_h += entry_title_size.height;

                if (entry.subtitle.len > 0) {
                    const sub_size = styled_text.measureText(ctx.allocator, entry.subtitle, .{
                        .font_size = self.subtitle_font_size,
                    });
                    entry_h += sub_size.height + 2;
                }

                h += entry_h + self.entry_spacing;
            }

            h += self.group_spacing;
        }

        return h;
    }

    fn entryMatches(self: *const Self, entry: ShortcutEntry) bool {
        if (self.search_text.len == 0) return true;

        if (indexOfIgnoreCase(entry.title, self.search_text)) return true;
        if (entry.subtitle.len > 0 and indexOfIgnoreCase(entry.subtitle, self.search_text)) return true;

        return false;
    }

    fn indexOfIgnoreCase(haystack: []const u8, needle: []const u8) bool {
        if (needle.len > haystack.len) return false;
        const n_len = needle.len;
        var i: usize = 0;
        while (i <= haystack.len - n_len) : (i += 1) {
            var match = true;
            var j: usize = 0;
            while (j < n_len) : (j += 1) {
                const hc = std.ascii.toLower(haystack[i + j]);
                const nc = std.ascii.toLower(needle[j]);
                if (hc != nc) {
                    match = false;
                    break;
                }
            }
            if (match) return true;
        }
        return false;
    }

    fn getVisibleEntries(self: *const Self, group: ShortcutGroup) usize {
        if (self.search_text.len == 0) return group.entries.len;
        var count: usize = 0;
        for (group.entries) |entry| {
            if (self.entryMatches(entry)) count += 1;
        }
        return count;
    }

    // ── VTable ──────────────────────────────────────────────────────────────

    const vtable = Widget.VTable{
        .type_name = "shortcuts_window",
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

    fn measure(w: *Widget, ctx: *PaintContext, constraints: layout_mod.Constraints) math.Size(f32) {
        const self: *Self = @fieldParentPtr("base", w);
        _ = self;
        _ = ctx;

        const w_out = if (constraints.max_width < std.math.inf(f32))
            constraints.max_width
        else
            600;
        const h_out = if (constraints.max_height < std.math.inf(f32))
            constraints.max_height
        else
            500;

        return .{ .width = w_out, .height = h_out };
    }

    fn paint(w: *Widget, ctx: *PaintContext) void {
        const self: *Self = @fieldParentPtr("base", w);
        const rx = ctx.offset_x + w.rect.x;
        const ry = ctx.offset_y + w.rect.y;

        ctx.renderer.fillRect(
            .{ .x = rx, .y = ry, .width = w.rect.width, .height = w.rect.height },
            self.bg_color,
        ) catch {};

        const search_y = ry + self.padding;
        const search_h: f32 = 36;
        const search_x = rx + self.padding;
        const search_w = w.rect.width - self.padding * 2;

        ctx.renderer.fillRoundedRect(
            .{ .x = search_x, .y = search_y, .width = search_w, .height = search_h },
            8,
            math.Color.hex(0xF1F5F9FF),
        ) catch {};
        ctx.renderer.strokeRoundedRect(
            .{ .x = search_x, .y = search_y, .width = search_w, .height = search_h },
            8,
            1,
            self.border_color,
        ) catch {};

        const search_placeholder = "Search shortcuts...";
        const placeholder_size = styled_text.measureText(ctx.allocator, search_placeholder, .{
            .font_size = self.entry_font_size,
        });
        const text_color = if (self.search_text.len > 0) self.text_color else self.subtitle_color;
        const display_text = if (self.search_text.len > 0) self.search_text else search_placeholder;
        styled_text.drawText(
            ctx.renderer,
            ctx.allocator,
            display_text,
            search_x + 12,
            search_y + (search_h - placeholder_size.height) / 2,
            .{ .font_size = self.entry_font_size, .color = text_color },
        );

        var cur_y = search_y + search_h + self.padding;

        const title_size = styled_text.measureText(ctx.allocator, self.window_title, .{
            .font_size = self.title_font_size,
            .font_weight = 700,
        });
        styled_text.drawText(
            ctx.renderer,
            ctx.allocator,
            self.window_title,
            rx + self.padding,
            cur_y,
            .{ .font_size = self.title_font_size, .font_weight = 700, .color = self.text_color },
        );
        cur_y += title_size.height + self.group_spacing;

        const content_width = w.rect.width - self.padding * 2;

        for (self.groups.items) |group| {
            const visible_entries = self.getVisibleEntries(group);
            if (visible_entries == 0 and self.search_text.len > 0) continue;

            const group_title_size = styled_text.measureText(ctx.allocator, group.title, .{
                .font_size = self.group_title_font_size,
                .font_weight = 600,
            });
            styled_text.drawText(
                ctx.renderer,
                ctx.allocator,
                group.title,
                rx + self.padding,
                cur_y,
                .{ .font_size = self.group_title_font_size, .font_weight = 600, .color = self.group_title_color },
            );
            cur_y += group_title_size.height + self.entry_spacing;

            for (group.entries) |entry| {
                if (!self.entryMatches(entry)) continue;

                var entry_h: f32 = self.entry_padding * 2;
                const entry_title_size = styled_text.measureText(ctx.allocator, entry.title, .{
                    .font_size = self.entry_font_size,
                });
                entry_h += entry_title_size.height;

                if (entry.subtitle.len > 0) {
                    const sub_size = styled_text.measureText(ctx.allocator, entry.subtitle, .{
                        .font_size = self.subtitle_font_size,
                    });
                    entry_h += sub_size.height + 2;
                }

                const entry_x = rx + self.padding;
                const entry_w = content_width;

                const shortcut_size = styled_text.measureText(ctx.allocator, entry.shortcut, .{
                    .font_size = self.shortcut_font_size,
                    .font_weight = 500,
                });

                const shortcut_x = entry_x + entry_w - shortcut_size.width - 12;
                const shortcut_y = cur_y + self.entry_padding + (entry_title_size.height - shortcut_size.height) / 2;

                ctx.renderer.fillRoundedRect(
                    .{ .x = shortcut_x - 6, .y = shortcut_y - 3, .width = shortcut_size.width + 12, .height = shortcut_size.height + 6 },
                    4,
                    math.Color.hex(0xE2E8F0FF),
                ) catch {};

                styled_text.drawText(
                    ctx.renderer,
                    ctx.allocator,
                    entry.shortcut,
                    shortcut_x,
                    shortcut_y,
                    .{ .font_size = self.shortcut_font_size, .font_weight = 500, .color = self.shortcut_text_color },
                );

                styled_text.drawText(
                    ctx.renderer,
                    ctx.allocator,
                    entry.title,
                    entry_x + 12,
                    cur_y + self.entry_padding,
                    .{ .font_size = self.entry_font_size, .color = self.text_color },
                );

                if (entry.subtitle.len > 0) {
                    styled_text.drawText(
                        ctx.renderer,
                        ctx.allocator,
                        entry.subtitle,
                        entry_x + 12,
                        cur_y + self.entry_padding + entry_title_size.height + 2,
                        .{ .font_size = self.subtitle_font_size, .color = self.subtitle_color },
                    );
                }

                cur_y += entry_h + self.entry_spacing;
            }

            cur_y += self.group_spacing - self.entry_spacing;
        }
    }

    fn onEvent(w: *Widget, event: *const pal.Event, ectx: *EventContext) EventResult {
        const self: *Self = @fieldParentPtr("base", w);
        _ = ectx;

        switch (event.*) {
            .key => |key| {
                if (key.state == .pressed) {
                    if (key.key == .escape) {
                        return .handled;
                    }
                    if (key.key == .backspace) {
                        if (self.search_text.len > 0) {
                            const new_len = self.search_text.len - 1;
                            const new_text = self.allocator.alloc(u8, new_len) catch return .ignored;
                            @memcpy(new_text, self.search_text[0..new_len]);
                            self.allocator.free(self.search_text);
                            self.search_text = new_text;
                            self.base.markDirty();
                            return .handled;
                        }
                    }
                }
            },
            .text_input => |ti| {
                const new_text = std.fmt.allocPrint(self.allocator, "{s}{u}", .{ self.search_text, ti.codepoint }) catch return .ignored;
                self.allocator.free(self.search_text);
                self.search_text = new_text;
                self.base.markDirty();
                return .handled;
            },
            else => {},
        }
        return .ignored;
    }
};
