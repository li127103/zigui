//! LockButton 控件 - 锁定按钮
//!
//! 类似 GtkLockButton: 用于权限管理的锁定/解锁按钮。
//! 显示锁的图标状态，点击时需要验证（此处简化为点击切换，实际可接权限验证回调）。
//!
//! 支持:
//! - 锁定/解锁状态切换
//! - 悬停效果
//! - 自定义锁定/解锁文本提示
//! - 验证回调

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

pub const LockButton = struct {
    base: Widget,
    allocator: std.mem.Allocator,

    locked: bool = true,
    locked_text: []const u8 = "Locked",
    unlocked_text: []const u8 = "Unlocked",
    show_text: bool = true,

    on_toggle: ?*const fn (self: *LockButton, locked: bool) void = null,

    size: f32 = 34,
    icon_size: f32 = 18,
    corner_radius: f32 = 8,

    locked_bg: math.Color = math.Color.hex(0xDC2626FF),
    locked_bg_hover: math.Color = math.Color.hex(0xB91C1CFF),
    locked_text_color: math.Color = math.Color.hex(0xFFFFFFFF),
    unlocked_bg: math.Color = math.Color.hex(0x16A34AFF),
    unlocked_bg_hover: math.Color = math.Color.hex(0x15803DFF),
    unlocked_text_color: math.Color = math.Color.hex(0xFFFFFFFF),

    hovered: bool = false,
    pressed: bool = false,

    const Self = @This();

    pub fn create(allocator: std.mem.Allocator, opts: struct {
        locked: bool = true,
        show_text: bool = true,
        locked_text: []const u8 = "Locked",
        unlocked_text: []const u8 = "Unlocked",
        size: f32 = 34,
        icon_size: f32 = 18,
        corner_radius: f32 = 8,
        on_toggle: ?*const fn (self: *LockButton, locked: bool) void = null,
    }) !*LockButton {
        const self = try allocator.create(LockButton);
        self.* = .{
            .base = .{
                .vtable = &vtable,
                .id = widget_mod.genWidgetId(),
            },
            .allocator = allocator,
            .locked = opts.locked,
            .show_text = opts.show_text,
            .locked_text = opts.locked_text,
            .unlocked_text = opts.unlocked_text,
            .size = opts.size,
            .icon_size = opts.icon_size,
            .corner_radius = opts.corner_radius,
            .on_toggle = opts.on_toggle,
        };
        self.base.accessibility = .{
            .role = .toggle_button,
            .label = if (opts.locked) opts.locked_text else opts.unlocked_text,
        };
        self.base.cursor = .pointing_hand;
        return self;
    }

    pub fn destroy(self: *Self, allocator: std.mem.Allocator) void {
        self.base.background.deinit(allocator);
        self.base.children.deinit(allocator);
        allocator.destroy(self);
    }

    pub fn setLocked(self: *Self, locked: bool) void {
        if (self.locked != locked) {
            self.locked = locked;
            self.base.accessibility.label = if (locked) self.locked_text else self.unlocked_text;
            self.base.markDirty();
        }
    }

    pub fn isLocked(self: *const Self) bool {
        return self.locked;
    }

    pub fn toggle(self: *Self) void {
        self.setLocked(!self.locked);
        if (self.on_toggle) |cb| {
            cb(self, self.locked);
        }
    }

    /// 绘制锁图标
    fn drawLockIcon(_: *Self, r2d: anytype, x: f32, y: f32, s: f32, color: math.Color) void {
        const body_w = s * 0.85;
        const body_h = s * 0.6;
        const body_x = x + (s - body_w) / 2;
        const body_y = y + s * 0.45;
        const stroke: f32 = s * 0.1;

        // 锁身
        r2d.fillRoundedRect(.{
            .x = body_x,
            .y = body_y,
            .width = body_w,
            .height = body_h,
        }, s * 0.08, color) catch {};

        // 锁梁
        r2d.strokeRect(.{
            .x = x + s * 0.28,
            .y = y + s * 0.12,
            .width = s * 0.44,
            .height = s * 0.45,
        }, stroke, color) catch {};

        // 锁孔
        const cy = body_y + body_h * 0.5;
        const dot_x = x + s * 0.5;
        const hole_color = math.Color.hex(0xFFFFFFFF);
        r2d.fillRect(.{
            .x = dot_x - s * 0.05,
            .y = cy - s * 0.02,
            .width = s * 0.1,
            .height = s * 0.14,
        }, hole_color) catch {};
        const r: f32 = s * 0.09;
        r2d.fillCircle(dot_x, cy - s * 0.02, r, hole_color) catch {};
    }

    // ── VTable ──────────────────────────────────────────────────────────────

    const vtable = Widget.VTable{
        .type_name = "lock_button",
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
        _ = constraints;

        var total_w = self.size;
        if (self.show_text) {
            const text = if (self.locked) self.locked_text else self.unlocked_text;
            const ts = styled_text.measureText(self.allocator, text, .{ .font_size = 13 });
            total_w = self.size + ts.width + 16;
        }
        return .{ .width = total_w, .height = self.size };
    }

    fn paint(w: *Widget, ctx: *PaintContext) void {
        const self: *Self = @fieldParentPtr("base", w);
        const rx = ctx.offset_x + w.rect.x;
        const ry = ctx.offset_y + w.rect.y;

        const bg = if (self.locked)
            if (self.hovered) self.locked_bg_hover else self.locked_bg
        else
            if (self.hovered) self.unlocked_bg_hover else self.unlocked_bg;
        const tcolor = if (self.locked) self.locked_text_color else self.unlocked_text_color;

        ctx.renderer.fillRoundedRect(
            .{ .x = rx, .y = ry, .width = w.rect.width, .height = w.rect.height },
            self.corner_radius,
            bg,
        ) catch {};

        // 画锁图标
        const ix = rx + (self.size - self.icon_size) / 2;
        const iy = ry + (self.size - self.icon_size) / 2;
        self.drawLockIcon(ctx.renderer, ix, iy, self.icon_size, tcolor);

        if (self.show_text) {
            const text = if (self.locked) self.locked_text else self.unlocked_text;
            const tsize = styled_text.measureText(ctx.allocator, text, .{ .font_size = 13 });
            const ty = ry + (w.rect.height - tsize.height) / 2;
            const tx = rx + self.size + 4;
            styled_text.drawText(ctx.renderer, ctx.allocator, text, tx, ty, .{
                .font_size = 13,
                .color = tcolor,
                .font_weight = 600,
            });
        }
    }

    fn onEvent(w: *Widget, event: *const pal.Event, ectx: *EventContext) EventResult {
        const self: *Self = @fieldParentPtr("base", w);
        _ = ectx;

        switch (event.*) {
            .mouse_move => |mm| {
                const mx: f32 = @floatFromInt(mm.x);
                const my: f32 = @floatFromInt(mm.y);

                const inside = mx >= 0 and mx < w.rect.width and my >= 0 and my < w.rect.height;
                if (inside != self.hovered) {
                    self.hovered = inside;
                    self.base.markDirty();
                }
                return if (inside) .handled else .ignored;
            },
            .mouse_button => |mb| {
                if (mb.button == .left) {
                    const mx: f32 = @floatFromInt(mb.x);
                    const my: f32 = @floatFromInt(mb.y);
                    const inside = mx >= 0 and mx < w.rect.width and my >= 0 and my < w.rect.height;

                    if (mb.state == .pressed) {
                        if (inside) {
                            self.pressed = true;
                            self.base.markDirty();
                            return .handled;
                        }
                    } else if (mb.state == .released) {
                        const was = self.pressed;
                        self.pressed = false;
                        self.base.markDirty();
                        if (inside and was) {
                            self.toggle();
                            return .handled;
                        }
                    }
                }
            },
            .key => |key| {
                if (key.state == .pressed and (key.key == .enter or key.key == .space)) {
                    self.toggle();
                    return .handled;
                }
            },
            .mouse_leave => {
                self.hovered = false;
                self.pressed = false;
                self.base.markDirty();
            },
            else => {},
        }
        return .ignored;
    }
};
