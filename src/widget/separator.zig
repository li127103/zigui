//! Separator 控件 - 分隔线 (水平或垂直)

const std = @import("std");
const math = @import("../math.zig");
const widget_mod = @import("widget.zig");
const layout_mod = @import("../layout/engine.zig");

const Widget = widget_mod.Widget;
const PaintContext = widget_mod.PaintContext;

pub const SeparatorOrientation = enum { horizontal, vertical };

pub const Separator = struct {
    base: Widget,
    orientation: SeparatorOrientation,
    thickness: f32,
    color: math.Color,
    margin: f32,

    pub fn create(allocator: std.mem.Allocator, opts: struct {
        orientation: SeparatorOrientation = .horizontal,
        thickness: f32 = 1,
        color: math.Color = math.Color.hex(0xE2E8F0FF),
        margin: f32 = 8,
    }) !*Separator {
        const self = try allocator.create(Separator);
        self.* = .{
            .base = .{
                .vtable = &vtable,
                .id = widget_mod.genWidgetId(),
            },
            .orientation = opts.orientation,
            .thickness = opts.thickness,
            .color = opts.color,
            .margin = opts.margin,
        };
        self.base.accessibility = .{ .role = .none };
        return self;
    }

    pub fn destroy(self: *Separator, allocator: std.mem.Allocator) void {
        self.base.background.deinit(allocator);
        self.base.children.deinit(allocator);
        allocator.destroy(self);
    }

    pub fn setColor(self: *Separator, color: math.Color) void {
        self.color = color;
        self.base.markDirty();
    }

    // ── VTable 实现 ──────────────────────────────────────────────────────────

    const vtable = Widget.VTable{
        .type_name = "separator",
        .measure = measure,
        .paint = paint,
        .on_event = null,
        .focusable = false,
        .destroy = destroyVTable,
    };

    fn destroyVTable(w: *Widget, allocator: std.mem.Allocator) void {
        const self: *Separator = @fieldParentPtr("base", w);
        self.destroy(allocator);
    }

    fn measure(w: *Widget, ctx: *PaintContext, constraints: layout_mod.Constraints) math.Size(f32) {
        const self: *Separator = @fieldParentPtr("base", w);
        _ = ctx;
        return switch (self.orientation) {
            .horizontal => .{
                .width = if (constraints.max_width < std.math.inf(f32)) constraints.max_width else 100,
                .height = self.thickness + self.margin * 2,
            },
            .vertical => .{
                .width = self.thickness + self.margin * 2,
                .height = if (constraints.max_height < std.math.inf(f32)) constraints.max_height else 100,
            },
        };
    }

    fn paint(w: *Widget, ctx: *PaintContext) void {
        const self: *Separator = @fieldParentPtr("base", w);
        const rx = ctx.offset_x + w.rect.x;
        const ry = ctx.offset_y + w.rect.y;

        switch (self.orientation) {
            .horizontal => {
                const line_y = ry + self.margin;
                ctx.renderer.fillRect(
                    .{ .x = rx, .y = line_y, .width = w.rect.width, .height = self.thickness },
                    self.color,
                ) catch {};
            },
            .vertical => {
                const line_x = rx + self.margin;
                ctx.renderer.fillRect(
                    .{ .x = line_x, .y = ry, .width = self.thickness, .height = w.rect.height },
                    self.color,
                ) catch {};
            },
        }
    }
};

// ── Tests ──────────────────────────────────────────────────────────────────

test "separator horizontal measure" {
    const s = try Separator.create(std.testing.allocator, .{
        .orientation = .horizontal,
        .thickness = 2,
        .margin = 4,
    });
    defer s.destroy(std.testing.allocator);

    try std.testing.expectEqual(SeparatorOrientation.horizontal, s.orientation);
    try std.testing.expectEqual(@as(f32, 2), s.thickness);
}

test "separator vertical measure" {
    const s = try Separator.create(std.testing.allocator, .{
        .orientation = .vertical,
        .thickness = 1,
        .margin = 8,
    });
    defer s.destroy(std.testing.allocator);

    try std.testing.expectEqual(SeparatorOrientation.vertical, s.orientation);
    try std.testing.expectEqual(@as(f32, 1), s.thickness);
}

test "separator setColor" {
    const s = try Separator.create(std.testing.allocator, .{});
    defer s.destroy(std.testing.allocator);

    const new_color = math.Color.hex(0xFF0000FF);
    s.setColor(new_color);
    try std.testing.expectEqual(new_color.r, s.color.r);
}

test "separator default values" {
    const s = try Separator.create(std.testing.allocator, .{});
    defer s.destroy(std.testing.allocator);

    try std.testing.expectEqual(SeparatorOrientation.horizontal, s.orientation);
    try std.testing.expectEqual(@as(f32, 1), s.thickness);
    try std.testing.expectEqual(@as(f32, 8), s.margin);
}
