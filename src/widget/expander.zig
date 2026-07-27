//! Expander 控件 - 可折叠面板 (点击标题展开/收起内容)

const std = @import("std");
const math = @import("../math.zig");
const widget_mod = @import("widget.zig");
const layout_mod = @import("../layout/engine.zig");
const pal = @import("../pal/pal.zig");
const styled_text = @import("../text/styled_text.zig");

const Widget = widget_mod.Widget;
const PaintContext = widget_mod.PaintContext;
const EventContext = widget_mod.EventContext;
const EventResult = widget_mod.EventResult;

pub const Expander = struct {
    base: Widget,
    title: []const u8,
    title_owned: bool,
    allocator: std.mem.Allocator,
    expanded: bool,
    font_size: f32,
    text_color: math.Color,
    header_bg: math.Color,
    header_hover_bg: math.Color,
    border_color: math.Color,
    header_height: f32,
    padding: math.EdgeInsets,
    content_height: f32,
    on_toggle: ?*const fn (self: *Expander, expanded: bool) void,

    progress: f32,
    target_progress: f32,
    transition_duration_ms: u32,

    pub fn create(allocator: std.mem.Allocator, title: []const u8, opts: struct {
        expanded: bool = false,
        font_size: f32 = 14.0,
        text_color: math.Color = math.Color.hex(0x1E293BFF),
        header_bg: math.Color = math.Color.hex(0xF1F5FFFF),
        header_hover_bg: math.Color = math.Color.hex(0xE2E8F0FF),
        border_color: math.Color = math.Color.hex(0xE2E8F0FF),
        header_height: f32 = 40,
        padding: math.EdgeInsets = .{ .left = 12, .right = 12, .top = 8, .bottom = 8 },
        on_toggle: ?*const fn (self: *Expander, expanded: bool) void = null,
        transition_duration_ms: u32 = 200,
    }) !*Expander {
        const self = try allocator.create(Expander);
        const init_progress: f32 = if (opts.expanded) 1.0 else 0.0;
        self.* = .{
            .base = .{
                .vtable = &vtable,
                .id = widget_mod.genWidgetId(),
            },
            .title = title,
            .title_owned = false,
            .allocator = allocator,
            .expanded = opts.expanded,
            .font_size = opts.font_size,
            .text_color = opts.text_color,
            .header_bg = opts.header_bg,
            .header_hover_bg = opts.header_hover_bg,
            .border_color = opts.border_color,
            .header_height = opts.header_height,
            .padding = opts.padding,
            .content_height = 0,
            .on_toggle = opts.on_toggle,
            .progress = init_progress,
            .target_progress = init_progress,
            .transition_duration_ms = opts.transition_duration_ms,
        };
        self.base.layout_style.direction = .column;
        self.base.accessibility = .{ .role = .button, .label = title, .expanded = opts.expanded };
        return self;
    }

    pub fn destroy(self: *Expander, allocator: std.mem.Allocator) void {
        if (self.title_owned and self.title.len > 0) {
            allocator.free(self.title);
        }
        self.base.background.deinit(allocator);
        for (self.base.children.items) |child| {
            child.vtable.destroy(child, allocator);
        }
        self.base.children.deinit(allocator);
        allocator.destroy(self);
    }

    pub fn setExpanded(self: *Expander, expanded: bool) void {
        if (self.expanded != expanded) {
            self.expanded = expanded;
            self.target_progress = if (expanded) 1.0 else 0.0;
            self.base.accessibility.expanded = expanded;
            self.base.markLayoutDirty();
            self.base.markDirty();
            if (self.on_toggle) |cb| {
                cb(self, expanded);
            }
        }
    }

    pub fn tick(self: *Expander, delta_ms: u32) void {
        if (self.progress == self.target_progress) return;
        const delta = @as(f32, @floatFromInt(delta_ms)) / @as(f32, @floatFromInt(self.transition_duration_ms));
        if (self.target_progress > self.progress) {
            self.progress = @min(1.0, self.progress + delta);
        } else {
            self.progress = @max(0.0, self.progress - delta);
        }
        self.base.markLayoutDirty();
        self.base.markDirty();
    }

    fn easedProgress(self: *Expander) f32 {
        const t = self.progress;
        return 1.0 - std.math.pow(f32, 1.0 - t, 3);
    }

    pub fn toggle(self: *Expander) void {
        self.setExpanded(!self.expanded);
    }

    pub fn setTitle(self: *Expander, title: []const u8) !void {
        if (self.title_owned and self.title.len > 0) {
            self.allocator.free(self.title);
        }
        self.title = try self.allocator.dupe(u8, title);
        self.title_owned = true;
        self.base.markDirty();
    }

    // ── VTable 实现 ──────────────────────────────────────────────────────────

    const vtable = Widget.VTable{
        .type_name = "expander",
        .measure = measure,
        .paint = paint,
        .on_event = onEvent,
        .perform_layout = performLayout,
        .tick = tickVTable,
        .focusable = true,
        .destroy = destroyVTable,
    };

    fn destroyVTable(w: *Widget, allocator: std.mem.Allocator) void {
        const self: *Expander = @fieldParentPtr("base", w);
        self.destroy(allocator);
    }

    fn tickVTable(w: *Widget, delta_ms: u32) void {
        const self: *Expander = @fieldParentPtr("base", w);
        self.tick(delta_ms);
    }

    fn measure(w: *Widget, ctx: *PaintContext, constraints: layout_mod.Constraints) math.Size(f32) {
        const self: *Expander = @fieldParentPtr("base", w);

        const w_out = if (constraints.max_width < std.math.inf(f32)) constraints.max_width else 300;
        var h: f32 = self.header_height;

        var full_content_h: f32 = 0;
        if (w.children.items.len > 0) {
            const inner_c = constraints.deflate(.{
                .left = self.padding.left,
                .right = self.padding.right,
                .top = 0,
                .bottom = 0,
            });
            for (w.children.items) |child| {
                if (!child.state.visible) continue;
                if (child.layout_style.position == .absolute) continue;
                const cs = child.vtable.measure(child, ctx, inner_c);
                full_content_h += cs.height + child.layout_style.margin.top + child.layout_style.margin.bottom;
            }
            full_content_h += self.padding.top + self.padding.bottom;
        }

        self.content_height = full_content_h;
        h += full_content_h * self.easedProgress();

        return .{ .width = w_out, .height = h };
    }

    fn performLayout(_w: *Widget, ctx: *PaintContext) void {
        const self: *Expander = @fieldParentPtr("base", _w);

        const content_top = self.header_height + self.padding.top;
        const content_h = self.content_height;
        const eased = self.easedProgress();

        // 更新裁剪矩形为内容区域 (绝对坐标)
        if (eased < 1.0 and _w.children.items.len > 0) {
            const abs = _w.absoluteRect();
            self.base.clip_children = math.Rect(f32){
                .x = abs.x + self.padding.left,
                .y = abs.y + content_top,
                .width = _w.rect.width - self.padding.left - self.padding.right,
                .height = content_h * eased,
            };
        } else {
            self.base.clip_children = null;
        }

        // 布局子项
        var y_offset: f32 = content_top;
        for (_w.children.items) |child| {
            if (!child.state.visible) continue;
            if (child.layout_style.position == .absolute) {
                _w.layoutAbsolute(child, ctx);
                continue;
            }

            const cm = child.layout_style.margin;
            const child_w = _w.rect.width - self.padding.left - self.padding.right - cm.left - cm.right;
            const child_constraints = layout_mod.Constraints{
                .max_width = child_w,
                .max_height = std.math.inf(f32),
            };
            const child_size = child.vtable.measure(child, ctx, child_constraints);

            child.rect.x = self.padding.left + cm.left;
            child.rect.y = y_offset + cm.top;
            child.rect.width = child_w;
            child.rect.height = child_size.height;

            if (child.children.items.len > 0) {
                child.layoutSubtree(ctx);
            }

            y_offset += child_size.height + cm.top + cm.bottom;
        }
    }

    fn paint(w: *Widget, ctx: *PaintContext) void {
        const self: *Expander = @fieldParentPtr("base", w);
        const rx = ctx.offset_x + w.rect.x;
        const ry = ctx.offset_y + w.rect.y;

        // 整体背景
        ctx.renderer.fillRect(
            .{ .x = rx, .y = ry, .width = w.rect.width, .height = w.rect.height },
            math.Color.hex(0xFFFFFFFF),
        ) catch {};

        // 边框
        ctx.renderer.strokeRoundedRect(
            .{ .x = rx, .y = ry, .width = w.rect.width, .height = w.rect.height },
            6,
            1,
            self.border_color,
        ) catch {};

        // 头部背景
        const header_bg_color = if (w.state.hovered) self.header_hover_bg else self.header_bg;
        ctx.renderer.fillRoundedRect(
            .{ .x = rx, .y = ry, .width = w.rect.width, .height = self.header_height },
            6,
            header_bg_color,
        ) catch {};
        // 清除底部圆角 (头部和内容之间需要直角连接)
        if (self.progress > 0.01 and w.children.items.len > 0) {
            ctx.renderer.fillRect(
                .{ .x = rx, .y = ry + self.header_height - 6, .width = w.rect.width, .height = 6 },
                header_bg_color,
            ) catch {};
        }

        // 展开箭头 (用文本字符绘制)
        const arrow_char = if (self.progress > 0.5) "▼" else "▶";
        const arrow_size = styled_text.measureText(ctx.allocator, arrow_char, .{ .font_size = 12 });
        const arrow_x = rx + self.padding.left;
        const arrow_y = ry + (self.header_height - arrow_size.height) / 2.0;
        styled_text.drawText(
            ctx.renderer,
            ctx.allocator,
            arrow_char,
            arrow_x,
            arrow_y,
            .{ .font_size = 12, .color = self.text_color },
        );

        // 标题文本
        const text_x = arrow_x + 16;
        const text_y = ry + (self.header_height - self.font_size * 1.2) / 2;
        styled_text.drawText(
            ctx.renderer,
            ctx.allocator,
            self.title,
            text_x,
            text_y,
            .{ .font_size = self.font_size, .color = self.text_color, .font_weight = 500 },
        );
    }

    fn onEvent(w: *Widget, event: *const pal.Event, ectx: *EventContext) EventResult {
        const self: *Expander = @fieldParentPtr("base", w);
        _ = ectx;
        const abs = w.absoluteRect();

        switch (event.*) {
            .mouse_button => |mb| {
                if (mb.button == .left) {
                    const ly = @as(f32, @floatFromInt(mb.y)) - abs.y;
                    if (mb.state == .pressed) {
                        // 只响应头部点击
                        if (ly >= 0 and ly < self.header_height) {
                            w.state.pressed = true;
                            w.markDirty();
                            return .handled;
                        }
                    } else {
                        if (w.state.pressed) {
                            w.state.pressed = false;
                            w.markDirty();
                            if (ly >= 0 and ly < self.header_height) {
                                self.toggle();
                            }
                            return .handled;
                        }
                    }
                }
            },
            .mouse_move => |mm| {
                const ly = @as(f32, @floatFromInt(mm.y)) - abs.y;
                if (ly >= 0 and ly < self.header_height) {
                    if (!w.state.hovered) {
                        w.state.hovered = true;
                        w.markDirty();
                    }
                } else {
                    if (w.state.hovered) {
                        w.state.hovered = false;
                        w.markDirty();
                    }
                }
                return .ignored;
            },
            .key => |key| {
                if (key.state == .pressed and (key.key == .space or key.key == .enter)) {
                    if (w.state.focused) {
                        self.toggle();
                        return .handled;
                    }
                }
                return .ignored;
            },
            else => return .ignored,
        }
        return .ignored;
    }
};

// ── Tests ──────────────────────────────────────────────────────────────────

test "expander create defaults to collapsed" {
    const e = try Expander.create(std.testing.allocator, "Section", .{});
    defer e.destroy(std.testing.allocator);

    try std.testing.expectEqual(false, e.expanded);
}

test "expander setExpanded toggles" {
    const e = try Expander.create(std.testing.allocator, "Section", .{});
    defer e.destroy(std.testing.allocator);

    e.setExpanded(true);
    try std.testing.expectEqual(true, e.expanded);
    try std.testing.expectEqual(true, e.base.accessibility.expanded);

    e.setExpanded(true);
    try std.testing.expectEqual(true, e.expanded);
}

test "expander toggle flips state" {
    const e = try Expander.create(std.testing.allocator, "Section", .{ .expanded = true });
    defer e.destroy(std.testing.allocator);

    e.toggle();
    try std.testing.expectEqual(false, e.expanded);

    e.toggle();
    try std.testing.expectEqual(true, e.expanded);
}

test "expander setTitle updates" {
    const e = try Expander.create(std.testing.allocator, "Old", .{});
    defer e.destroy(std.testing.allocator);

    try e.setTitle("New Title");
    try std.testing.expectEqualStrings("New Title", e.title);
}
