//! StackSidebar 控件 - Stack 侧边栏导航
//!
//! 类似 GtkStackSidebar: 显示关联 Stack 中每个页面的标题列表,
//! 点击条目切换页面。通常放在 Stack 的左侧作为导航菜单。
//!
//! 支持:
//! - 自动显示 Stack 页面标题
//! - 点击切换页面
//! - 当前页面高亮
//! - 悬停效果
//! - 可定制样式

const std = @import("std");
const math = @import("../math.zig");
const widget_mod = @import("widget.zig");
const layout_mod = @import("../layout/engine.zig");
const pal = @import("../pal/pal.zig");
const stack_mod = @import("stack.zig");
const styled_text = @import("../text/styled_text.zig");

const Widget = widget_mod.Widget;
const PaintContext = widget_mod.PaintContext;
const EventContext = widget_mod.EventContext;
const EventResult = widget_mod.EventResult;
const Stack = stack_mod.Stack;

pub const StackSidebar = struct {
    base: Widget,
    allocator: std.mem.Allocator,
    stack: ?*Stack = null,
    page_titles: std.ArrayListUnmanaged([]const u8) = .{},
    hovered_item: ?usize = null,

    on_page_changed: ?*const fn (self: *StackSidebar, index: usize) void = null,

    bg_color: math.Color = math.Color.hex(0xF8FAFCFF),
    item_bg_color: math.Color = math.Color.hex(0xF1F5F9FF),
    item_active_color: math.Color = math.Color.hex(0x3B82F614),
    item_hover_color: math.Color = math.Color.hex(0xE2E8F0FF),
    border_color: math.Color = math.Color.hex(0xE2E8F0FF),
    text_color: math.Color = math.Color.hex(0x0F172AFF),
    active_text_color: math.Color = math.Color.hex(0x2563EBFF),
    active_indicator_color: math.Color = math.Color.hex(0x3B82F6FF),
    subtitle_color: math.Color = math.Color.hex(0x64748BFF),

    item_height: f32 = 44,
    item_padding: f32 = 16,
    item_spacing: f32 = 2,
    sidebar_width: f32 = 220,
    active_indicator_width: f32 = 3,
    title_font_size: f32 = 14,
    subtitle_font_size: f32 = 11,

    const Self = @This();

    pub fn create(allocator: std.mem.Allocator, opts: struct {
        stack: ?*Stack = null,
        sidebar_width: f32 = 220,
        item_height: f32 = 44,
        bg_color: math.Color = math.Color.hex(0xF8FAFCFF),
        text_color: math.Color = math.Color.hex(0x0F172AFF),
        on_page_changed: ?*const fn (self: *StackSidebar, index: usize) void = null,
    }) !*StackSidebar {
        const self = try allocator.create(StackSidebar);
        self.* = .{
            .base = .{
                .vtable = &vtable,
                .id = widget_mod.genWidgetId(),
            },
            .allocator = allocator,
            .stack = opts.stack,
            .sidebar_width = opts.sidebar_width,
            .item_height = opts.item_height,
            .bg_color = opts.bg_color,
            .text_color = opts.text_color,
            .on_page_changed = opts.on_page_changed,
        };
        self.base.accessibility = .{ .role = .list_box };
        self.base.cursor = .default;
        return self;
    }

    pub fn destroy(self: *Self, allocator: std.mem.Allocator) void {
        for (self.page_titles.items) |title| {
            allocator.free(title);
        }
        self.page_titles.deinit(allocator);
        self.base.background.deinit(allocator);
        self.base.children.deinit(allocator);
        allocator.destroy(self);
    }

    /// 关联 Stack
    pub fn setStack(self: *Self, stack: *Stack) void {
        self.stack = stack;
        self.base.markLayoutDirty();
        self.base.markDirty();
    }

    /// 添加页面标题
    pub fn addPageTitle(self: *Self, title: []const u8) !void {
        const dup = try self.allocator.dupe(u8, title);
        try self.page_titles.append(self.allocator, dup);
        self.base.markLayoutDirty();
        self.base.markDirty();
    }

    /// 设置页面标题
    pub fn setPageTitle(self: *Self, index: usize, title: []const u8) !void {
        if (index >= self.page_titles.items.len) return;
        self.allocator.free(self.page_titles.items[index]);
        const dup = try self.allocator.dupe(u8, title);
        self.page_titles.items[index] = dup;
        self.base.markDirty();
    }

    /// 获取页面数量
    fn getPageCount(self: *const Self) usize {
        if (self.page_titles.items.len > 0) {
            return self.page_titles.items.len;
        }
        if (self.stack) |s| {
            return s.base.children.items.len;
        }
        return 0;
    }

    /// 获取当前页面索引
    fn getCurrentPage(self: *const Self) usize {
        if (self.stack) |s| {
            return s.visible_index;
        }
        return 0;
    }

    /// 切换到指定页面
    fn switchToPage(self: *Self, index: usize) void {
        const page_count = self.getPageCount();
        if (index >= page_count) return;

        if (self.stack) |s| {
            if (index < s.base.children.items.len) {
                s.setVisibleIndex(index);
            }
        }

        if (self.on_page_changed) |cb| {
            cb(self, index);
        }
        self.base.markDirty();
    }

    /// 获取点击位置的条目索引
    fn findItemAt(self: *const Self, y: f32) ?usize {
        const page_count = self.getPageCount();
        if (page_count == 0) return null;

        const pc_f: f32 = @floatFromInt(page_count);
        const total_h = pc_f * (self.item_height + self.item_spacing);
        if (y < 0 or y >= total_h) return null;

        const idx_f = y / (self.item_height + self.item_spacing);
        const idx: usize = @intFromFloat(idx_f);
        if (idx < page_count) return idx;
        return null;
    }

    /// 获取条目标题
    fn getPageTitle(self: *const Self, index: usize) []const u8 {
        if (index < self.page_titles.items.len) {
            return self.page_titles.items[index];
        }
        if (self.stack) |s| {
            if (index < s.base.children.items.len) {
                const child = s.base.children.items[index];
                if (child.accessibility.label.len > 0) {
                    return child.accessibility.label;
                }
            }
        }
        return "";
    }

    // ── VTable ──────────────────────────────────────────────────────────────

    const vtable = Widget.VTable{
        .type_name = "stack_sidebar",
        .measure = measure,
        .paint = paint,
        .on_event = onEvent,
        .focusable = true,
        .destroy = destroyVTable,
    };

    fn destroyVTable(w: *Widget, allocator: std.mem.Allocator) void {
        const self: *Self = @fieldParentPtr("base", w);
        self.destroy(allocator);
    }

    fn measure(w: *Widget, ctx: *PaintContext, constraints: layout_mod.Constraints) math.Size(f32) {
        const self: *Self = @fieldParentPtr("base", w);
        _ = ctx;

        const page_count = self.getPageCount();
        const pc_f: f32 = @floatFromInt(page_count);
        const total_h = pc_f * (self.item_height + self.item_spacing);

        const w_out = if (constraints.max_width < std.math.inf(f32))
            constraints.max_width
        else
            self.sidebar_width;
        const h_out = if (constraints.max_height < std.math.inf(f32))
            constraints.max_height
        else
            total_h;

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

        ctx.renderer.fillRect(
            .{ .x = rx + w.rect.width - 1, .y = ry, .width = 1, .height = w.rect.height },
            self.border_color,
        ) catch {};

        const page_count = self.getPageCount();
        const current = self.getCurrentPage();

        var cur_y = ry;
        for (0..page_count) |i| {
            const title = self.getPageTitle(i);
            const is_active = (i == current);
            const is_hovered = (self.hovered_item == i);

            if (is_active) {
                ctx.renderer.fillRect(
                    .{ .x = rx, .y = cur_y, .width = self.active_indicator_width, .height = self.item_height },
                    self.active_indicator_color,
                ) catch {};
                ctx.renderer.fillRect(
                    .{
                        .x = rx + self.active_indicator_width,
                        .y = cur_y,
                        .width = w.rect.width - self.active_indicator_width,
                        .height = self.item_height,
                    },
                    self.item_active_color,
                ) catch {};
            } else if (is_hovered) {
                ctx.renderer.fillRect(
                    .{ .x = rx, .y = cur_y, .width = w.rect.width, .height = self.item_height },
                    self.item_hover_color,
                ) catch {};
            }

            const text_color = if (is_active) self.active_text_color else self.text_color;
            const title_size = styled_text.measureText(ctx.allocator, title, .{
                .font_size = self.title_font_size,
            });
            const text_y = cur_y + (self.item_height - title_size.height) / 2;
            styled_text.drawText(
                ctx.renderer,
                ctx.allocator,
                title,
                rx + self.item_padding + if (is_active) self.active_indicator_width + 8 else 8,
                text_y,
                .{ .font_size = self.title_font_size, .color = text_color, .font_weight = if (is_active) 600 else 400 },
            );

            cur_y += self.item_height + self.item_spacing;
        }
    }

    fn onEvent(w: *Widget, event: *const pal.Event, ectx: *EventContext) EventResult {
        const self: *Self = @fieldParentPtr("base", w);
        _ = ectx;

        switch (event.*) {
            .mouse_move => |mm| {
                const my: f32 = @floatFromInt(mm.y);
                const hovered = self.findItemAt(my);
                if (hovered != self.hovered_item) {
                    self.hovered_item = hovered;
                    self.base.markDirty();
                }
                return if (hovered != null) .handled else .ignored;
            },
            .mouse_button => |mb| {
                if (mb.button == .left and mb.state == .pressed) {
                    const my: f32 = @floatFromInt(mb.y);
                    if (self.findItemAt(my)) |idx| {
                        self.switchToPage(idx);
                        return .handled;
                    }
                }
            },
            .key => |key| {
                if (key.state == .pressed) {
                    const current = self.getCurrentPage();
                    const page_count = self.getPageCount();
                    if (page_count == 0) return .ignored;

                    if (key.key == .up or key.key == .arrow_up) {
                        if (current > 0) {
                            self.switchToPage(current - 1);
                            return .handled;
                        }
                    } else if (key.key == .down or key.key == .arrow_down) {
                        if (current < page_count - 1) {
                            self.switchToPage(current + 1);
                            return .handled;
                        }
                    } else if (key.key == .home) {
                        self.switchToPage(0);
                        return .handled;
                    } else if (key.key == .end and page_count > 0) {
                        self.switchToPage(page_count - 1);
                        return .handled;
                    }
                }
            },
            .mouse_leave => {
                self.hovered_item = null;
                self.base.markDirty();
            },
            else => {},
        }
        return .ignored;
    }
};
