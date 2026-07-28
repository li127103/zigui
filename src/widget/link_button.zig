//! LinkButton 控件 - 超链接按钮 (文本样式, 带下划线)

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

pub const LinkButton = struct {
    base: Widget,
    text: []const u8,
    url: ?[]const u8,
    font_size: f32,
    font_weight: u16,
    color: math.Color,
    hover_color: math.Color,
    visited_color: math.Color,
    visited: bool,
    underline: bool,
    on_click: ?*const fn (self: *LinkButton) void,

    pub fn create(allocator: std.mem.Allocator, text: []const u8, opts: struct {
        url: ?[]const u8 = null,
        font_size: f32 = 14.0,
        font_weight: u16 = 400,
        color: math.Color = math.Color.hex(0x2563EBFF),
        hover_color: math.Color = math.Color.hex(0x1D4ED8FF),
        visited_color: math.Color = math.Color.hex(0x7C3AEDFF),
        underline: bool = true,
        visited: bool = false,
        on_click: ?*const fn (self: *LinkButton) void = null,
    }) !*LinkButton {
        const self = try allocator.create(LinkButton);
        self.* = .{
            .base = .{
                .vtable = &vtable,
                .id = widget_mod.genWidgetId(),
            },
            .text = text,
            .url = opts.url,
            .font_size = opts.font_size,
            .font_weight = opts.font_weight,
            .color = opts.color,
            .hover_color = opts.hover_color,
            .visited_color = opts.visited_color,
            .visited = opts.visited,
            .underline = opts.underline,
            .on_click = opts.on_click,
        };
        self.base.accessibility = .{ .role = .button, .label = text };
        self.base.cursor = .pointing_hand;
        return self;
    }

    pub fn destroy(self: *LinkButton, allocator: std.mem.Allocator) void {
        self.base.background.deinit(allocator);
        self.base.children.deinit(allocator);
        allocator.destroy(self);
    }

    pub fn setText(self: *LinkButton, text: []const u8) void {
        self.text = text;
        self.base.markDirty();
    }

    pub fn setVisited(self: *LinkButton, visited: bool) void {
        self.visited = visited;
        self.base.markDirty();
    }

    fn currentColor(self: *const LinkButton, hovered: bool) math.Color {
        if (hovered) return self.hover_color;
        if (self.visited) return self.visited_color;
        return self.color;
    }

    // ── VTable ──────────────────────────────────────────────────────────────

    const vtable = Widget.VTable{
        .type_name = "link_button",
        .measure = measure,
        .paint = paint,
        .on_event = onEvent,
        .focusable = true,
        .destroy = destroyVTable,
    };

    fn destroyVTable(w: *Widget, allocator: std.mem.Allocator) void {
        const self: *LinkButton = @fieldParentPtr("base", w);
        self.destroy(allocator);
    }

    fn measure(w: *Widget, ctx: *PaintContext, constraints: layout_mod.Constraints) math.Size(f32) {
        const self: *LinkButton = @fieldParentPtr("base", w);
        _ = constraints;

        const text_size = styled_text.measureText(ctx.allocator, self.text, .{
            .font_size = self.font_size,
            .font_weight = self.font_weight,
        });

        return .{ .width = text_size.width, .height = text_size.height + 2 };
    }

    fn paint(w: *Widget, ctx: *PaintContext) void {
        const self: *LinkButton = @fieldParentPtr("base", w);
        const color = self.currentColor(w.state.hovered);

        const rx = ctx.offset_x + w.rect.x;
        const ry = ctx.offset_y + w.rect.y;

        // 文本
        styled_text.drawText(
            ctx.renderer,
            ctx.allocator,
            self.text,
            rx,
            ry,
            .{ .font_size = self.font_size, .font_weight = self.font_weight, .color = color },
        );

        // 下划线
        if (self.underline) {
            const text_size = styled_text.measureText(ctx.allocator, self.text, .{
                .font_size = self.font_size,
                .font_weight = self.font_weight,
            });
            const line_y = ry + text_size.height - 1;
            ctx.renderer.fillRect(
                .{ .x = rx, .y = line_y, .width = text_size.width, .height = 1 },
                color,
            ) catch {};
        }

        // 焦点环
        if (w.state.focused) {
            const text_size = styled_text.measureText(ctx.allocator, self.text, .{
                .font_size = self.font_size,
                .font_weight = self.font_weight,
            });
            ctx.renderer.strokeRoundedRect(
                .{ .x = rx - 2, .y = ry - 2, .width = text_size.width + 4, .height = w.rect.height + 2 },
                2,
                1,
                math.Color.hex(0x3B82F688),
            ) catch {};
        }
    }

    fn onEvent(w: *Widget, event: *const pal.Event, ectx: *EventContext) EventResult {
        const self: *LinkButton = @fieldParentPtr("base", w);
        _ = ectx;

        switch (event.*) {
            .mouse_button => |mb| {
                if (mb.button == .left) {
                    if (mb.state == .pressed) {
                        w.state.pressed = true;
                        w.markDirty();
                        return .handled;
                    } else {
                        if (w.state.pressed) {
                            w.state.pressed = false;
                            self.visited = true;
                            w.markDirty();
                            if (self.on_click) |cb| {
                                cb(self);
                            }
                            return .handled;
                        }
                    }
                }
            },
            .mouse_move => |mm| {
                const lx: f32 = @floatFromInt(mm.x);
                const ly: f32 = @floatFromInt(mm.y);
                const inside = lx >= 0 and ly >= 0 and lx < w.rect.width and ly < w.rect.height;
                if (inside != w.state.hovered) {
                    w.state.hovered = inside;
                    w.markDirty();
                }
                return .ignored;
            },
            .key => |k| {
                if (k.state == .pressed and (k.key == .space or k.key == .enter)) {
                    if (w.state.focused) {
                        self.visited = true;
                        w.markDirty();
                        if (self.on_click) |cb| cb(self);
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

test "link_button create with text" {
    const lb = try LinkButton.create(std.testing.allocator, "Click here", .{});
    defer lb.destroy(std.testing.allocator);

    try std.testing.expectEqualStrings("Click here", lb.text);
    try std.testing.expectEqual(false, lb.visited);
}

test "link_button hover color differs from normal" {
    const lb = try LinkButton.create(std.testing.allocator, "Link", .{});
    defer lb.destroy(std.testing.allocator);

    const normal = lb.currentColor(false);
    const hovered = lb.currentColor(true);

    try std.testing.expect(normal.r != hovered.r or normal.g != hovered.g or normal.b != hovered.b);
}

test "link_button visited color differs from normal" {
    const lb = try LinkButton.create(std.testing.allocator, "Link", .{ .visited = true });
    defer lb.destroy(std.testing.allocator);

    const visited = lb.currentColor(false);
    const lb2 = try LinkButton.create(std.testing.allocator, "Link", .{});
    defer lb2.destroy(std.testing.allocator);
    const normal = lb2.currentColor(false);

    try std.testing.expect(visited.r != normal.r or visited.g != normal.g or visited.b != normal.b);
}

test "link_button setVisited updates state" {
    const lb = try LinkButton.create(std.testing.allocator, "Link", .{});
    defer lb.destroy(std.testing.allocator);

    try std.testing.expectEqual(false, lb.visited);
    lb.setVisited(true);
    try std.testing.expectEqual(true, lb.visited);
}

test "link_button setText updates" {
    const lb = try LinkButton.create(std.testing.allocator, "Old", .{});
    defer lb.destroy(std.testing.allocator);

    lb.setText("New");
    try std.testing.expectEqualStrings("New", lb.text);
}
