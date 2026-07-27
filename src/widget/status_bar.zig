//! StatusBar 控件 - 底部状态栏

const std = @import("std");
const math = @import("../math.zig");
const widget_mod = @import("widget.zig");
const layout_mod = @import("../layout/engine.zig");
const styled_text = @import("../text/styled_text.zig");

const Widget = widget_mod.Widget;
const PaintContext = widget_mod.PaintContext;

pub const StatusBar = struct {
    base: Widget,
    text: []const u8,
    text_owned: bool,
    allocator: std.mem.Allocator,
    text_color: math.Color,
    bg_color: math.Color,
    border_color: math.Color,
    font_size: f32,
    padding: math.EdgeInsets,
    height: f32,

    pub fn create(allocator: std.mem.Allocator, opts: struct {
        text: []const u8 = "",
        text_color: math.Color = math.Color.hex(0x475569FF),
        bg_color: math.Color = math.Color.hex(0xF1F5FFFF),
        border_color: math.Color = math.Color.hex(0xE2E8F0FF),
        font_size: f32 = 12.0,
        height: f32 = 28,
        padding: math.EdgeInsets = .{ .left = 12, .right = 12 },
    }) !*StatusBar {
        const self = try allocator.create(StatusBar);
        self.* = .{
            .base = .{
                .vtable = &vtable,
                .id = widget_mod.genWidgetId(),
            },
            .text = opts.text,
            .text_owned = false,
            .allocator = allocator,
            .text_color = opts.text_color,
            .bg_color = opts.bg_color,
            .border_color = opts.border_color,
            .font_size = opts.font_size,
            .padding = opts.padding,
            .height = opts.height,
        };
        self.base.layout_style.direction = .row;
        self.base.layout_style.padding = opts.padding;
        self.base.accessibility = .{ .role = .status };
        return self;
    }

    pub fn destroy(self: *StatusBar, allocator: std.mem.Allocator) void {
        if (self.text_owned and self.text.len > 0) {
            allocator.free(self.text);
        }
        self.base.background.deinit(allocator);
        for (self.base.children.items) |child| {
            child.vtable.destroy(child, allocator);
        }
        self.base.children.deinit(allocator);
        allocator.destroy(self);
    }

    pub fn setText(self: *StatusBar, text: []const u8) !void {
        if (self.text_owned and self.text.len > 0) {
            self.allocator.free(self.text);
        }
        self.text = try self.allocator.dupe(u8, text);
        self.text_owned = true;
        self.base.markDirty();
    }

    pub fn getText(self: *const StatusBar) []const u8 {
        return self.text;
    }

    // ── VTable 实现 ──────────────────────────────────────────────────────────

    const vtable = Widget.VTable{
        .type_name = "status_bar",
        .measure = measure,
        .paint = paint,
        .on_event = null,
        .focusable = false,
        .destroy = destroyVTable,
    };

    fn destroyVTable(w: *Widget, allocator: std.mem.Allocator) void {
        const self: *StatusBar = @fieldParentPtr("base", w);
        self.destroy(allocator);
    }

    fn measure(w: *Widget, ctx: *PaintContext, constraints: layout_mod.Constraints) math.Size(f32) {
        const self: *StatusBar = @fieldParentPtr("base", w);
        _ = ctx;
        const w_out = if (constraints.max_width < std.math.inf(f32)) constraints.max_width else 400;
        return .{ .width = w_out, .height = self.height };
    }

    fn paint(w: *Widget, ctx: *PaintContext) void {
        const self: *StatusBar = @fieldParentPtr("base", w);
        const rx = ctx.offset_x + w.rect.x;
        const ry = ctx.offset_y + w.rect.y;

        // 背景
        ctx.renderer.fillRect(
            .{ .x = rx, .y = ry, .width = w.rect.width, .height = w.rect.height },
            self.bg_color,
        ) catch {};

        // 顶部边框
        ctx.renderer.fillRect(
            .{ .x = rx, .y = ry, .width = w.rect.width, .height = 1 },
            self.border_color,
        ) catch {};

        // 状态文本 (左对齐, 垂直居中)
        if (self.text.len > 0) {
            const text_y = ry + (w.rect.height - self.font_size * 1.2) / 2.0;
            styled_text.drawText(
                ctx.renderer,
                ctx.allocator,
                self.text,
                rx + self.padding.left,
                text_y,
                .{ .font_size = self.font_size, .color = self.text_color },
            );
        }
    }
};

// ── Tests ──────────────────────────────────────────────────────────────────

test "status_bar create with text" {
    const sb = try StatusBar.create(std.testing.allocator, .{ .text = "Ready" });
    defer sb.destroy(std.testing.allocator);

    try std.testing.expectEqualStrings("Ready", sb.getText());
}

test "status_bar setText updates" {
    const sb = try StatusBar.create(std.testing.allocator, .{ .text = "A" });
    defer sb.destroy(std.testing.allocator);

    try sb.setText("Hello");
    try std.testing.expectEqualStrings("Hello", sb.getText());
}

test "status_bar default height" {
    const sb = try StatusBar.create(std.testing.allocator, .{});
    defer sb.destroy(std.testing.allocator);

    try std.testing.expectEqual(@as(f32, 28), sb.height);
}

test "status_bar setText multiple times" {
    const sb = try StatusBar.create(std.testing.allocator, .{});
    defer sb.destroy(std.testing.allocator);

    try sb.setText("first");
    try sb.setText("second");
    try sb.setText("third");
    try std.testing.expectEqualStrings("third", sb.getText());
}
