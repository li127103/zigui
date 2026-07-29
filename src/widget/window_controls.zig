//! WindowControls 控件 - 窗口控制按钮
//!
//! 类似 GtkWindowControls: 窗口标题栏按钮组, 包含最小化、最大化/还原、关闭按钮。
//! 通常放在 HeaderBar 的左侧或右侧, 带有操作系统风格的外观。
//!
//! 支持:
//! - 最小化按钮
//! - 最大化/还原切换按钮
//! - 关闭按钮
//! - 可配置显示哪些按钮
//! - 可配置左右布局
//! - 悬停/按下状态样式

const std = @import("std");
const math = @import("../math.zig");
const widget_mod = @import("widget.zig");
const layout_mod = @import("../layout/engine.zig");
const pal = @import("../pal/pal.zig");

const Widget = widget_mod.Widget;
const PaintContext = widget_mod.PaintContext;
const EventContext = widget_mod.EventContext;
const EventResult = widget_mod.EventResult;

/// 按钮排列侧
pub const WindowControlsSide = enum {
    left,
    right,
};

pub const WindowControls = struct {
    base: Widget,
    allocator: std.mem.Allocator,

    show_minimize: bool = true,
    show_maximize: bool = true,
    show_close: bool = true,
    side: WindowControlsSide = .right,

    on_minimize: ?*const fn (self: *WindowControls) void = null,
    on_maximize: ?*const fn (self: *WindowControls, maximized: bool) void = null,
    on_close: ?*const fn (self: *WindowControls) void = null,

    is_maximized: bool = false,

    button_size: f32 = 36,
    button_spacing: f32 = 2,
    icon_size: f32 = 14,

    minimize_hovered: bool = false,
    minimize_pressed: bool = false,
    maximize_hovered: bool = false,
    maximize_pressed: bool = false,
    close_hovered: bool = false,
    close_pressed: bool = false,

    minimize_bg: math.Color = math.Color.hex(0xE2E8F0FF),
    minimize_color: math.Color = math.Color.hex(0x334155FF),
    maximize_bg: math.Color = math.Color.hex(0xE2E8F0FF),
    maximize_color: math.Color = math.Color.hex(0x334155FF),
    close_bg: math.Color = math.Color.hex(0xEF4444FF),
    close_color: math.Color = math.Color.hex(0xFFFFFFFF),

    hover_minimize_bg: math.Color = math.Color.hex(0x3B82F6FF),
    hover_minimize_color: math.Color = math.Color.hex(0xFFFFFFFF),
    hover_maximize_bg: math.Color = math.Color.hex(0x22C55EFF),
    hover_maximize_color: math.Color = math.Color.hex(0xFFFFFFFF),
    hover_close_bg: math.Color = math.Color.hex(0xDC2626FF),
    hover_close_color: math.Color = math.Color.hex(0xFFFFFFFF),

    const Self = @This();

    pub fn create(allocator: std.mem.Allocator, opts: struct {
        show_minimize: bool = true,
        show_maximize: bool = true,
        show_close: bool = true,
        side: WindowControlsSide = .right,
        button_size: f32 = 36,
        button_spacing: f32 = 2,
        icon_size: f32 = 14,
        is_maximized: bool = false,
        on_minimize: ?*const fn (self: *WindowControls) void = null,
        on_maximize: ?*const fn (self: *WindowControls, maximized: bool) void = null,
        on_close: ?*const fn (self: *WindowControls) void = null,
    }) !*WindowControls {
        const self = try allocator.create(WindowControls);
        self.* = .{
            .base = .{
                .vtable = &vtable,
                .id = widget_mod.genWidgetId(),
            },
            .allocator = allocator,
            .show_minimize = opts.show_minimize,
            .show_maximize = opts.show_maximize,
            .show_close = opts.show_close,
            .side = opts.side,
            .button_size = opts.button_size,
            .button_spacing = opts.button_spacing,
            .icon_size = opts.icon_size,
            .is_maximized = opts.is_maximized,
            .on_minimize = opts.on_minimize,
            .on_maximize = opts.on_maximize,
            .on_close = opts.on_close,
        };
        self.base.accessibility = .{ .role = .group };
        self.base.cursor = .pointing_hand;
        return self;
    }

    pub fn destroy(self: *Self, allocator: std.mem.Allocator) void {
        self.base.background.deinit(allocator);
        self.base.children.deinit(allocator);
        allocator.destroy(self);
    }

    /// 设置最大化状态
    pub fn setMaximized(self: *Self, maximized: bool) void {
        self.is_maximized = maximized;
        self.base.markDirty();
    }

    fn getButtonCount(self: *const Self) usize {
        var count: usize = 0;
        if (self.show_minimize) count += 1;
        if (self.show_maximize) count += 1;
        if (self.show_close) count += 1;
        return count;
    }

    /// 获取按钮矩形
    fn getButtonRect(self: *const Self, index: usize) math.Rect(f32) {
        var idx: usize = 0;
        var x: f32 = 0;

        const button_order = if (self.side == .right) [_]enum { min, max, close }{ .min, .max, .close } else [_]enum { min, max, close }{ .close, .max, .min };

        for (button_order) |btype| {
            const show = switch (btype) {
                .min => self.show_minimize,
                .max => self.show_maximize,
                .close => self.show_close,
            };
            if (show) {
                if (idx == index) {
                    return .{
                        .x = x,
                        .y = (self.base.rect.height - self.button_size) / 2,
                        .width = self.button_size,
                        .height = self.button_size,
                    };
                }
                idx += 1;
                x += self.button_size + self.button_spacing;
            }
        }
        return .{ .x = 0, .y = 0, .width = 0, .height = 0 };
    }

    /// 获取指定位置的按钮索引和类型
    fn findButtonAt(self: *const Self, x: f32, y: f32) ?struct { usize, enum { min, max, close } } {
        const button_order = if (self.side == .right) [_]enum { min, max, close }{ .min, .max, .close } else [_]enum { min, max, close }{ .close, .max, .min };
        var idx: usize = 0;
        var bx: f32 = 0;

        for (button_order) |btype| {
            const show = switch (btype) {
                .min => self.show_minimize,
                .max => self.show_maximize,
                .close => self.show_close,
            };
            if (show) {
                const by = (self.base.rect.height - self.button_size) / 2;
                if (x >= bx and x < bx + self.button_size and
                    y >= by and y < by + self.button_size)
                {
                    return .{ idx, btype };
                }
                idx += 1;
                bx += self.button_size + self.button_spacing;
            }
        }
        return null;
    }

    /// 绘制最小化图标
    fn drawMinimizeIcon(_: *Self, r2d: anytype, x: f32, y: f32, size: f32, color: math.Color) void {
        const w = size;
        const h = size * 0.12;
        const ix = x;
        const iy = y + size * 0.5;
        r2d.fillRect(.{ .x = ix, .y = iy, .width = w, .height = h }, color) catch {};
    }

    /// 绘制最大化/还原图标
    fn drawMaximizeIcon(self: *Self, r2d: anytype, x: f32, y: f32, size: f32, color: math.Color) void {
        const stroke = size * 0.12;
        if (self.is_maximized) {
            const inner_w = size * 0.65;
            const inner_h = size * 0.65;
            r2d.strokeRect(.{
                .x = x + size * 0.2,
                .y = y + size * 0.2,
                .width = inner_w,
                .height = inner_h,
            }, stroke, color) catch {};
            r2d.fillRect(.{
                .x = x + size * 0.0,
                .y = y + size * 0.0,
                .width = inner_w,
                .height = stroke,
            }, color) catch {};
            r2d.fillRect(.{
                .x = x + size * 0.0,
                .y = y + size * 0.0,
                .width = stroke,
                .height = inner_h * 0.7,
            }, color) catch {};
            r2d.fillRect(.{
                .x = x + size * 0.0,
                .y = y + inner_h * 0.6,
                .width = inner_w * 0.7,
                .height = stroke,
            }, color) catch {};
        } else {
            r2d.strokeRect(.{ .x = x, .y = y, .width = size, .height = size }, stroke, color) catch {};
        }
    }

    /// 绘制关闭图标
    fn drawCloseIcon(_: *Self, r2d: anytype, x: f32, y: f32, size: f32, color: math.Color) void {
        const stroke = size * 0.16;
        const pad = size * 0.2;

        const x1 = x + pad;
        const y1 = y + pad;
        const x2 = x + size - pad;
        const y2 = y + size - pad;

        const dx = x2 - x1;
        const dy = y2 - y1;
        const len = @sqrt(dx * dx + dy * dy);
        const half = stroke / 2.0;
        const nx = -dy / len * half;
        const ny = dx / len * half;

        const p1 = [2]f32{ x1 + nx, y1 + ny };
        const p2 = [2]f32{ x2 + nx, y2 + ny };
        const p3 = [2]f32{ x2 - nx, y2 - ny };
        const p4 = [2]f32{ x1 - nx, y1 - ny };
        const line1 = [4][2]f32{ p1, p2, p3, p4 };

        const a1 = [2]f32{ x2 + nx, y1 - ny };
        const a2 = [2]f32{ x1 + nx, y2 - ny };
        const a3 = [2]f32{ x1 - nx, y2 + ny };
        const a4 = [2]f32{ x2 - nx, y1 + ny };
        const line2 = [4][2]f32{ a1, a2, a3, a4 };

        r2d.fillConvexPolygon(&line1, color) catch {};
        r2d.fillConvexPolygon(&line2, color) catch {};
    }

    // ── VTable ──────────────────────────────────────────────────────────────

    const vtable = Widget.VTable{
        .type_name = "window_controls",
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
        _ = ctx;
        const bcnt = self.getButtonCount();
        const total_w = @as(f32, @floatFromInt(bcnt)) * self.button_size +
            @as(f32, @floatFromInt(@max(0, bcnt - 1))) * self.button_spacing;
        const total_h = self.button_size;

        const w_out = if (constraints.max_width < std.math.inf(f32))
            constraints.max_width
        else
            total_w;
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

        const button_order = if (self.side == .right) [_]enum { min, max, close }{ .min, .max, .close } else [_]enum { min, max, close }{ .close, .max, .min };
        var idx: usize = 0;
        var bx: f32 = rx;

        for (button_order) |btype| {
            const show = switch (btype) {
                .min => self.show_minimize,
                .max => self.show_maximize,
                .close => self.show_close,
            };
            if (!show) continue;

            const by = ry + (w.rect.height - self.button_size) / 2;
            const is_hovered = switch (btype) {
                .min => self.minimize_hovered,
                .max => self.maximize_hovered,
                .close => self.close_hovered,
            };
            const is_pressed = switch (btype) {
                .min => self.minimize_pressed,
                .max => self.maximize_pressed,
                .close => self.close_pressed,
            };

            const bg = if (is_pressed)
                self.hoverCloseOr(btype, true)
            else if (is_hovered)
                self.hoverCloseOr(btype, false)
            else
                self.defaultBg(btype);

            ctx.renderer.fillRoundedRect(
                .{ .x = bx, .y = by, .width = self.button_size, .height = self.button_size },
                6,
                bg,
            ) catch {};

            const icon_x = bx + (self.button_size - self.icon_size) / 2;
            const icon_y = by + (self.button_size - self.icon_size) / 2;
            const color = if (is_hovered or is_pressed) self.hoverColor(btype) else self.defaultColor(btype);

            switch (btype) {
                .min => self.drawMinimizeIcon(ctx.renderer, icon_x, icon_y, self.icon_size, color),
                .max => self.drawMaximizeIcon(ctx.renderer, icon_x, icon_y, self.icon_size, color),
                .close => self.drawCloseIcon(ctx.renderer, icon_x, icon_y, self.icon_size, color),
            }

            idx += 1;
            bx += self.button_size + self.button_spacing;
        }
    }

    fn defaultBg(self: *const Self, btype: enum { min, max, close }) math.Color {
        return switch (btype) {
            .min => self.minimize_bg,
            .max => self.maximize_bg,
            .close => self.close_bg,
        };
    }

    fn defaultColor(self: *const Self, btype: enum { min, max, close }) math.Color {
        return switch (btype) {
            .min => self.minimize_color,
            .max => self.maximize_color,
            .close => self.close_color,
        };
    }

    fn hoverColor(self: *const Self, btype: enum { min, max, close }) math.Color {
        return switch (btype) {
            .min => self.hover_minimize_color,
            .max => self.hover_maximize_color,
            .close => self.hover_close_color,
        };
    }

    fn hoverCloseOr(self: *const Self, btype: enum { min, max, close }, pressed: bool) math.Color {
        const base = switch (btype) {
            .min => self.hover_minimize_bg,
            .max => self.hover_maximize_bg,
            .close => self.hover_close_bg,
        };
        if (!pressed) return base;
        const f = 0.85;
        const ri: f32 = base.r * f;
        const gi: f32 = base.g * f;
        const bi: f32 = base.b * f;
        return .{
            .r = if (ri > 255) 255 else @intFromFloat(ri),
            .g = if (gi > 255) 255 else @intFromFloat(gi),
            .b = if (bi > 255) 255 else @intFromFloat(bi),
            .a = base.a,
        };
    }

    fn onEvent(w: *Widget, event: *const pal.Event, ectx: *EventContext) EventResult {
        const self: *Self = @fieldParentPtr("base", w);
        _ = ectx;

        switch (event.*) {
            .mouse_move => |mm| {
                const mx: f32 = @floatFromInt(mm.x);
                const my: f32 = @floatFromInt(mm.y);

                const found = self.findButtonAt(mx, my);

                var min_h = false;
                var max_h = false;
                var clo_h = false;
                if (found) |f| {
                    switch (f[1]) {
                        .min => min_h = true,
                        .max => max_h = true,
                        .close => clo_h = true,
                    }
                }

                if (min_h != self.minimize_hovered or max_h != self.maximize_hovered or clo_h != self.close_hovered) {
                    self.minimize_hovered = min_h;
                    self.maximize_hovered = max_h;
                    self.close_hovered = clo_h;
                    self.base.markDirty();
                }

                return if (found != null) .handled else .ignored;
            },
            .mouse_button => |mb| {
                if (mb.button == .left) {
                    const mx: f32 = @floatFromInt(mb.x);
                    const my: f32 = @floatFromInt(mb.y);

                    if (mb.state == .pressed) {
                        if (self.findButtonAt(mx, my)) |f| {
                            switch (f[1]) {
                                .min => self.minimize_pressed = true,
                                .max => self.maximize_pressed = true,
                                .close => self.close_pressed = true,
                            }
                            self.base.markDirty();
                            return .handled;
                        }
                    } else if (mb.state == .released) {
                        if (self.findButtonAt(mx, my)) |f| {
                            const was_pressed = switch (f[1]) {
                                .min => self.minimize_pressed,
                                .max => self.maximize_pressed,
                                .close => self.close_pressed,
                            };
                            if (was_pressed) {
                                switch (f[1]) {
                                    .min => {
                                        if (self.on_minimize) |cb| cb(self);
                                    },
                                    .max => {
                                        self.is_maximized = !self.is_maximized;
                                        if (self.on_maximize) |cb| cb(self, self.is_maximized);
                                    },
                                    .close => {
                                        if (self.on_close) |cb| cb(self);
                                    },
                                }
                            }
                        }
                        self.minimize_pressed = false;
                        self.maximize_pressed = false;
                        self.close_pressed = false;
                        self.base.markDirty();
                        return .handled;
                    }
                }
            },
            .mouse_leave => {
                self.minimize_hovered = false;
                self.minimize_pressed = false;
                self.maximize_hovered = false;
                self.maximize_pressed = false;
                self.close_hovered = false;
                self.close_pressed = false;
                self.base.markDirty();
            },
            else => {},
        }
        return .ignored;
    }
};
