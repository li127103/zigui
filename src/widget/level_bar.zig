//! LevelBar 控件 - 等级指示器
//!
//! 显示等级/强度的控件，支持连续模式和离散模式（多个块），
//! 常用于音量、信号强度、电池电量等。
//!
//! 使用方法:
//! ```
//! var lb = try LevelBar.create(allocator, .{
//!     .value = 0.7,
//!     .max_value = 1.0,
//!     .mode = .discrete,
//!     .num_blocks = 5,
//! });
//! lb.setValue(0.8);
//! ```

const std = @import("std");
const math = @import("../math.zig");
const widget_mod = @import("widget.zig");
const layout_mod = @import("../layout/engine.zig");

const Widget = widget_mod.Widget;
const PaintContext = widget_mod.PaintContext;
const EventContext = widget_mod.EventContext;
const EventResult = widget_mod.EventResult;

pub const LevelBarMode = enum {
    continuous,
    discrete,
};

pub const LevelBar = struct {
    base: Widget,
    value: f32 = 0,
    min_value: f32 = 0,
    max_value: f32 = 1,
    mode: LevelBarMode = .continuous,
    num_blocks: u32 = 5,
    inverted: bool = false,
    vertical: bool = false,

    track_color: math.Color = math.Color.hex(0x334155FF),
    fill_color: math.Color = math.Color.hex(0x22C55EFF),
    high_color: ?math.Color = null,
    high_threshold: f32 = 0.8,
    low_color: ?math.Color = null,
    low_threshold: f32 = 0.2,
    corner_radius: f32 = 2.0,
    block_gap: f32 = 3.0,
    min_block_size: f32 = 12.0,

    const Self = @This();

    pub fn create(allocator: std.mem.Allocator, opts: struct {
        value: f32 = 0,
        min_value: f32 = 0,
        max_value: f32 = 1,
        mode: LevelBarMode = .continuous,
        num_blocks: u32 = 5,
        inverted: bool = false,
        vertical: bool = false,
        track_color: ?math.Color = null,
        fill_color: ?math.Color = null,
        corner_radius: f32 = 2.0,
    }) !*LevelBar {
        const self = try allocator.create(LevelBar);
        self.* = .{
            .base = .{
                .vtable = &vtable,
                .id = widget_mod.genWidgetId(),
            },
            .value = std.math.clamp(opts.value, opts.min_value, opts.max_value),
            .min_value = opts.min_value,
            .max_value = opts.max_value,
            .mode = opts.mode,
            .num_blocks = @max(1, opts.num_blocks),
            .inverted = opts.inverted,
            .vertical = opts.vertical,
            .corner_radius = opts.corner_radius,
            .track_color = opts.track_color orelse self.track_color,
            .fill_color = opts.fill_color orelse self.fill_color,
        };
        return self;
    }

    pub fn destroy(self: *Self, allocator: std.mem.Allocator) void {
        self.base.background.deinit(allocator);
        self.base.children.deinit(allocator);
        allocator.destroy(self);
    }

    pub fn setValue(self: *Self, v: f32) void {
        const clamped = std.math.clamp(v, self.min_value, self.max_value);
        if (clamped != self.value) {
            self.value = clamped;
            self.base.markDirty();
        }
    }

    pub fn getValue(self: *const Self) f32 {
        return self.value;
    }

    pub fn setInverted(self: *Self, inverted: bool) void {
        if (self.inverted != inverted) {
            self.inverted = inverted;
            self.base.markDirty();
        }
    }

    fn fraction(self: *const Self) f32 {
        if (self.max_value <= self.min_value) return 0;
        return (self.value - self.min_value) / (self.max_value - self.min_value);
    }

    fn getFillColor(self: *const Self) math.Color {
        const frac = self.fraction();
        if (frac >= self.high_threshold and self.high_color != null) {
            return self.high_color.?;
        }
        if (frac <= self.low_threshold and self.low_color != null) {
            return self.low_color.?;
        }
        return self.fill_color;
    }

    // ── VTable ──────────────────────────────────────────────────────────────

    const vtable = Widget.VTable{
        .type_name = "level_bar",
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
        if (self.vertical) {
            const h_used = if (w.rect.height > 0) w.rect.height else @min(150, constraints.max_height);
            const w_used = if (w.rect.width > 0) w.rect.width else self.min_block_size * 2;
            return .{ .width = w_used, .height = h_used };
        } else {
            const w_used = if (w.rect.width > 0) w.rect.width else @min(150, constraints.max_width);
            const h_used = if (w.rect.height > 0) w.rect.height else self.min_block_size;
            return .{ .width = w_used, .height = h_used };
        }
    }

    fn paint(w: *Widget, ctx: *PaintContext) void {
        const self: *Self = @fieldParentPtr("base", w);
        const rx = ctx.offset_x + w.rect.x;
        const ry = ctx.offset_y + w.rect.y;
        const rw = w.rect.width;
        const rh = w.rect.height;

        const frac = self.fraction();
        const fill_color = self.getFillColor();
        const display_frac = if (self.inverted) 1.0 - frac else frac;

        if (self.mode == .continuous) {
            const track_rect = math.Rect(f32){ .x = rx, .y = ry, .width = rw, .height = rh };
            ctx.renderer.fillRoundedRect(track_rect, self.corner_radius, self.track_color) catch {};

            if (display_frac > 0) {
                if (self.vertical) {
                    const fill_h = rh * display_frac;
                    const fill_y = ry + rh - fill_h;
                    const fill_rect = math.Rect(f32){
                        .x = rx,
                        .y = fill_y,
                        .width = rw,
                        .height = fill_h,
                    };
                    ctx.renderer.fillRoundedRect(fill_rect, self.corner_radius, fill_color) catch {};
                } else {
                    const fill_w = rw * display_frac;
                    const fill_rect = math.Rect(f32){
                        .x = rx,
                        .y = ry,
                        .width = fill_w,
                        .height = rh,
                    };
                    ctx.renderer.fillRoundedRect(fill_rect, self.corner_radius, fill_color) catch {};
                }
            }
        } else {
            const n = self.num_blocks;
            const nf: f32 = @floatFromInt(n);
            const filled_blocks: u32 = @intFromFloat(@round(display_frac * nf));

            if (self.vertical) {
                const total_gap = self.block_gap * (nf - 1);
                const block_h = @max(self.min_block_size, (rh - total_gap) / nf);
                const actual_h = block_h * nf + total_gap;
                const start_y = ry + (rh - actual_h) / 2;

                for (0..n) |i| {
                    const idx: u32 = @intCast(i);
                    const block_idx = if (self.inverted) idx else n - 1 - idx;
                    const is_filled = block_idx < filled_blocks;
                    const by = start_y + @as(f32, @floatFromInt(idx)) * (block_h + self.block_gap);
                    const block_rect = math.Rect(f32){
                        .x = rx,
                        .y = by,
                        .width = rw,
                        .height = block_h,
                    };
                    const color = if (is_filled) fill_color else self.track_color;
                    ctx.renderer.fillRoundedRect(block_rect, self.corner_radius, color) catch {};
                }
            } else {
                const total_gap = self.block_gap * (nf - 1);
                const block_w = @max(self.min_block_size, (rw - total_gap) / nf);
                const actual_w = block_w * nf + total_gap;
                const start_x = rx + (rw - actual_w) / 2;

                for (0..n) |i| {
                    const idx: u32 = @intCast(i);
                    const is_filled = idx < filled_blocks;
                    const bx = start_x + @as(f32, @floatFromInt(idx)) * (block_w + self.block_gap);
                    const block_rect = math.Rect(f32){
                        .x = bx,
                        .y = ry,
                        .width = block_w,
                        .height = rh,
                    };
                    const color = if (is_filled) fill_color else self.track_color;
                    ctx.renderer.fillRoundedRect(block_rect, self.corner_radius, color) catch {};
                }
            }
        }
    }
};
