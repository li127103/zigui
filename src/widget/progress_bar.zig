//! ProgressBar 控件 - 进度条
//!
//! 显示操作进度的控件，支持确定模式 (0-100%) 和不确定模式 (脉冲动画)。
//!
//! 使用方法:
//! ```
//! var pb = try ProgressBar.create(allocator, .{
//!     .fraction = 0.5,
//!     .show_text = true,
//! });
//! pb.setFraction(0.7);
//! ```

const std = @import("std");
const math = @import("../math.zig");
const widget_mod = @import("widget.zig");
const layout_mod = @import("../layout/engine.zig");
const styled_text = @import("../text/styled_text.zig");

const Widget = widget_mod.Widget;
const PaintContext = widget_mod.PaintContext;
const EventContext = widget_mod.EventContext;
const EventResult = widget_mod.EventResult;

pub const ProgressBar = struct {
    base: Widget,
    fraction: f32 = 0,
    show_text: bool = false,
    text: []const u8 = "",
    pulse: bool = false,
    pulse_pos: f32 = 0,

    track_color: math.Color = math.Color.hex(0x334155FF),
    fill_color: math.Color = math.Color.hex(0x3B82F6FF),
    text_color: math.Color = math.Color.hex(0xF8FAFCFF),
    corner_radius: f32 = 4.0,
    min_height: f32 = 18.0,
    min_width: f32 = 150.0,

    const Self = @This();

    pub fn create(allocator: std.mem.Allocator, opts: struct {
        fraction: f32 = 0,
        show_text: bool = false,
        text: []const u8 = "",
        pulse: bool = false,
        track_color: ?math.Color = null,
        fill_color: ?math.Color = null,
        corner_radius: f32 = 4.0,
        min_height: f32 = 18.0,
    }) !*ProgressBar {
        const self = try allocator.create(ProgressBar);
        self.* = .{
            .base = .{
                .vtable = &vtable,
                .id = widget_mod.genWidgetId(),
            },
            .fraction = std.math.clamp(opts.fraction, 0, 1),
            .show_text = opts.show_text,
            .pulse = opts.pulse,
            .corner_radius = opts.corner_radius,
            .min_height = opts.min_height,
            .track_color = opts.track_color orelse self.track_color,
            .fill_color = opts.fill_color orelse self.fill_color,
        };
        if (opts.text.len > 0) {
            self.text = try allocator.dupe(u8, opts.text);
        }
        return self;
    }

    pub fn destroy(self: *Self, allocator: std.mem.Allocator) void {
        if (self.text.len > 0) {
            allocator.free(self.text);
        }
        self.base.background.deinit(allocator);
        self.base.children.deinit(allocator);
        allocator.destroy(self);
    }

    pub fn setFraction(self: *Self, f: f32) void {
        const clamped = std.math.clamp(f, 0, 1);
        if (clamped != self.fraction) {
            self.fraction = clamped;
            self.base.markDirty();
        }
    }

    pub fn getFraction(self: *const Self) f32 {
        return self.fraction;
    }

    pub fn setPulse(self: *Self, enabled: bool) void {
        if (self.pulse != enabled) {
            self.pulse = enabled;
            self.pulse_pos = 0;
            self.base.markDirty();
        }
    }

    pub fn setText(self: *Self, allocator: std.mem.Allocator, text: []const u8) void {
        if (self.text.len > 0) {
            allocator.free(self.text);
            self.text = "";
        }
        if (text.len > 0) {
            self.text = allocator.dupe(u8, text) catch return;
        }
        self.base.markDirty();
    }

    pub fn pulseStep(self: *Self, delta: f32) void {
        if (!self.pulse) return;
        self.pulse_pos += delta;
        if (self.pulse_pos > 1.2) {
            self.pulse_pos = -0.2;
        }
        self.base.markDirty();
    }

    // ── VTable ──────────────────────────────────────────────────────────────

    const vtable = Widget.VTable{
        .type_name = "progress_bar",
        .measure = measure,
        .paint = paint,
        .on_event = null,
        .focusable = false,
        .destroy = destroyVTable,
    };

    fn destroyVTable(w: *Widget, allocator: std.mem.Allocator) void {
        const self: *Self = @fieldParentPtr("base", w);
        self.destroy(allocator);
    }

    fn measure(w: *Widget, ctx: *PaintContext, constraints: layout_mod.Constraints) math.Size(f32) {
        const self: *Self = @fieldParentPtr("base", w);
        _ = ctx;
        const w_used = if (w.rect.width > 0) w.rect.width else @min(self.min_width, constraints.max_width);
        const h_used = if (w.rect.height > 0) w.rect.height else self.min_height;
        return .{ .width = w_used, .height = h_used };
    }

    fn paint(w: *Widget, ctx: *PaintContext) void {
        const self: *Self = @fieldParentPtr("base", w);
        const rx = ctx.offset_x + w.rect.x;
        const ry = ctx.offset_y + w.rect.y;
        const rw = w.rect.width;
        const rh = w.rect.height;

        const track_rect = math.Rect(f32){ .x = rx, .y = ry, .width = rw, .height = rh };
        ctx.renderer.fillRoundedRect(track_rect, self.corner_radius, self.track_color) catch {};

        if (self.pulse) {
            const pulse_w = rw * 0.3;
            const pulse_x = rx + (rw + pulse_w) * self.pulse_pos - pulse_w;
            const clamped_x = @max(rx, pulse_x);
            const clamped_w = @min(rx + rw - clamped_x, pulse_w);
            if (clamped_w > 0) {
                const fill_rect = math.Rect(f32){
                    .x = clamped_x,
                    .y = ry,
                    .width = clamped_w,
                    .height = rh,
                };
                ctx.renderer.fillRoundedRect(fill_rect, self.corner_radius, self.fill_color) catch {};
            }
        } else {
            const fill_w = rw * self.fraction;
            if (fill_w > 0) {
                const fill_rect = math.Rect(f32){
                    .x = rx,
                    .y = ry,
                    .width = fill_w,
                    .height = rh,
                };
                ctx.renderer.fillRoundedRect(fill_rect, self.corner_radius, self.fill_color) catch {};
            }
        }

        if (self.show_text) {
            var buf: [32]u8 = undefined;
            const display_text = if (self.text.len > 0)
                self.text
            else label: {
                const pct: i32 = @intFromFloat(@round(self.fraction * 100));
                const len = std.fmt.bufPrint(&buf, "{}%", .{pct}) catch break :label "";
                break :label len;
            };

            if (display_text.len > 0) {
                const font_size = @min(12, rh * 0.6);
                const text_size = styled_text.measureText(ctx.allocator, display_text, .{
                    .font_size = font_size,
                });
                const text_x = rx + (rw - text_size.width) / 2;
                const text_y = ry + (rh - text_size.height) / 2;
                styled_text.drawText(
                    ctx.renderer,
                    ctx.allocator,
                    display_text,
                    text_x,
                    text_y,
                    .{ .font_size = font_size, .color = self.text_color },
                );
            }
        }
    }
};
