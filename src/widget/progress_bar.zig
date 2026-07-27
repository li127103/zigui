//! ProgressBar 控件 - 进度条 (确定进度展示, 可选百分比文本)

const std = @import("std");
const math = @import("../math.zig");
const widget_mod = @import("widget.zig");
const layout_mod = @import("../layout/engine.zig");
const styled_text = @import("../text/styled_text.zig");

const Widget = widget_mod.Widget;
const PaintContext = widget_mod.PaintContext;

pub const ProgressBar = struct {
    base: Widget,
    value: f32,
    min: f32,
    max: f32,
    show_label: bool,
    font_size: f32,
    // 样式
    track_color: math.Color,
    fill_color: math.Color,
    text_color: math.Color,
    bar_height: f32,
    corner_radius: f32,

    pub fn create(allocator: std.mem.Allocator, opts: struct {
        value: f32 = 0,
        min: f32 = 0,
        max: f32 = 1,
        show_label: bool = false,
        font_size: f32 = 12.0,
        track_color: math.Color = math.Color.hex(0x334155FF),
        fill_color: math.Color = math.Color.hex(0x3B82F6FF),
        text_color: math.Color = math.Color.hex(0xF8FAFCFF),
        bar_height: f32 = 10.0,
        corner_radius: f32 = 5.0,
    }) !*ProgressBar {
        const self = try allocator.create(ProgressBar);
        self.* = .{
            .base = .{
                .vtable = &vtable,
                .id = widget_mod.genWidgetId(),
            },
            .value = std.math.clamp(opts.value, opts.min, opts.max),
            .min = opts.min,
            .max = opts.max,
            .show_label = opts.show_label,
            .font_size = opts.font_size,
            .track_color = opts.track_color,
            .fill_color = opts.fill_color,
            .text_color = opts.text_color,
            .bar_height = opts.bar_height,
            .corner_radius = opts.corner_radius,
        };
        self.base.accessibility = .{ .role = .progress };
        return self;
    }

    pub fn destroy(self: *ProgressBar, allocator: std.mem.Allocator) void {
        self.base.background.deinit(allocator);
        self.base.children.deinit(allocator);
        allocator.destroy(self);
    }

    pub fn setValue(self: *ProgressBar, v: f32) void {
        const clamped = std.math.clamp(v, self.min, self.max);
        if (clamped != self.value) {
            self.value = clamped;
            self.base.markDirty();
        }
    }

    pub fn normalized(self: *const ProgressBar) f32 {
        if (self.max <= self.min) return 0;
        return (self.value - self.min) / (self.max - self.min);
    }

    // ── VTable 实现 ──────────────────────────────────────────────────────────

    const vtable = Widget.VTable{
        .type_name = "progress_bar",
        .measure = measure,
        .paint = paint,
        .on_event = null,
        .focusable = false,
        .destroy = destroyVTable,
    };

    fn destroyVTable(w: *Widget, allocator: std.mem.Allocator) void {
        const self: *ProgressBar = @fieldParentPtr("base", w);
        self.destroy(allocator);
    }

    fn measure(w: *Widget, ctx: *PaintContext, constraints: layout_mod.Constraints) math.Size(f32) {
        const self: *ProgressBar = @fieldParentPtr("base", w);
        _ = ctx;
        var h = self.bar_height;
        if (self.show_label) h = @max(h, self.font_size * 1.2);
        const width = if (constraints.max_width < std.math.inf(f32)) constraints.max_width else 200;
        return .{ .width = width, .height = h };
    }

    fn paint(w: *Widget, ctx: *PaintContext) void {
        const self: *ProgressBar = @fieldParentPtr("base", w);
        const rx = ctx.offset_x + w.rect.x;
        const ry = ctx.offset_y + w.rect.y;
        const rw = w.rect.width;

        const bar_y = ry + (w.rect.height - self.bar_height) / 2.0;

        // 轨道
        ctx.renderer.fillRoundedRect(
            .{ .x = rx, .y = bar_y, .width = rw, .height = self.bar_height },
            self.corner_radius,
            self.track_color,
        ) catch {};

        // 填充
        const norm = std.math.clamp(self.normalized(), 0.0, 1.0);
        const fill_w = rw * norm;
        if (fill_w > self.corner_radius * 2) {
            ctx.renderer.fillRoundedRect(
                .{ .x = rx, .y = bar_y, .width = fill_w, .height = self.bar_height },
                self.corner_radius,
                self.fill_color,
            ) catch {};
        } else if (fill_w > 0) {
            // 进度过小时用直角矩形避免圆角畸变
            ctx.renderer.fillRect(
                .{ .x = rx, .y = bar_y, .width = fill_w, .height = self.bar_height },
                self.fill_color,
            ) catch {};
        }

        // 百分比文本 (居中)
        if (self.show_label) {
            var buf: [16]u8 = undefined;
            const pct = @as(i32, @intFromFloat(@round(norm * 100.0)));
            const label = std.fmt.bufPrint(&buf, "{d}%", .{pct}) catch "0%";
            const text_size = styled_text.measureText(ctx.allocator, label, .{
                .font_size = self.font_size,
            });
            const text_x = rx + (rw - text_size.width) / 2.0;
            const text_y = ry + (w.rect.height - text_size.height) / 2.0;
            styled_text.drawText(
                ctx.renderer,
                ctx.allocator,
                label,
                text_x,
                text_y,
                .{ .font_size = self.font_size, .color = self.text_color },
            );
        }
    }
};

// ── Tests ──────────────────────────────────────────────────────────────────

test "progress_bar normalized maps value to 0..1" {
    const pb = try ProgressBar.create(std.testing.allocator, .{ .value = 5, .min = 0, .max = 10 });
    defer pb.destroy(std.testing.allocator);
    try std.testing.expectApproxEqAbs(@as(f32, 0.5), pb.normalized(), 0.0001);
}

test "progress_bar setValue clamps to range" {
    const pb = try ProgressBar.create(std.testing.allocator, .{ .min = 0, .max = 1 });
    defer pb.destroy(std.testing.allocator);

    pb.setValue(2.0);
    try std.testing.expectEqual(@as(f32, 1.0), pb.value);
    pb.setValue(-1.0);
    try std.testing.expectEqual(@as(f32, 0.0), pb.value);
}

test "progress_bar create clamps initial value" {
    const pb = try ProgressBar.create(std.testing.allocator, .{ .value = 99, .min = 0, .max = 1 });
    defer pb.destroy(std.testing.allocator);
    try std.testing.expectEqual(@as(f32, 1.0), pb.value);
}

test "progress_bar normalized guards zero range" {
    const pb = try ProgressBar.create(std.testing.allocator, .{ .value = 5, .min = 5, .max = 5 });
    defer pb.destroy(std.testing.allocator);
    try std.testing.expectEqual(@as(f32, 0), pb.normalized());
}
