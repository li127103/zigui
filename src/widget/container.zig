//! Container 控件 - Flexbox 布局容器

const std = @import("std");
const math = @import("../math.zig");
const widget_mod = @import("widget.zig");
const layout_mod = @import("../layout/engine.zig");

const Widget = widget_mod.Widget;
const PaintContext = widget_mod.PaintContext;
const EventContext = widget_mod.EventContext;
const EventResult = widget_mod.EventResult;

pub const Container = struct {
    base: Widget,
    bg_color: ?math.Color,
    corner_radius: f32,
    border_color: ?math.Color,
    border_width: f32,

    pub fn create(allocator: std.mem.Allocator, opts: struct {
        bg_color: ?math.Color = null,
        corner_radius: f32 = 0,
        border_color: ?math.Color = null,
        border_width: f32 = 1.0,
        direction: layout_mod.FlexDirection = .column,
        padding: math.EdgeInsets = .{},
        gap: math.Size(f32) = .{ .width = 0, .height = 0 },
        width: layout_mod.Dimension = .{ .auto = {} },
        height: layout_mod.Dimension = .{ .auto = {} },
    }) !*Container {
        const self = try allocator.create(Container);
        self.* = .{
            .base = .{
                .vtable = &vtable,
                .id = widget_mod.genWidgetId(),
            },
            .bg_color = opts.bg_color,
            .corner_radius = opts.corner_radius,
            .border_color = opts.border_color,
            .border_width = opts.border_width,
        };
        self.base.layout_style.direction = opts.direction;
        self.base.layout_style.padding = opts.padding;
        self.base.layout_style.gap = opts.gap;
        self.base.layout_style.width = opts.width;
        self.base.layout_style.height = opts.height;
        return self;
    }

    pub fn destroy(self: *Container, allocator: std.mem.Allocator) void {
        // 递归销毁子项
        for (self.base.children.items) |child| {
            child.vtable.destroy(child, allocator);
        }
        self.base.children.deinit(allocator);
        allocator.destroy(self);
    }

    // ── VTable 实现 ──────────────────────────────────────────────────────────

    const vtable = Widget.VTable{
        .type_name = "container",
        .measure = measure,
        .paint = paint,
        .on_event = null,
        .focusable = false,
        .destroy = destroyVTable,
    };

    fn destroyVTable(w: *Widget, allocator: std.mem.Allocator) void {
        const self: *Container = @fieldParentPtr("base", w);
        self.destroy(allocator);
    }

    fn measure(w: *Widget, ctx: *PaintContext, constraints: layout_mod.Constraints) math.Size(f32) {
        const self: *Container = @fieldParentPtr("base", w);
        _ = self;

        const pad = w.layout_style.padding;
        const is_row = w.layout_style.direction == .row or w.layout_style.direction == .row_reverse;
        const gap: f32 = if (is_row) w.layout_style.gap.width else w.layout_style.gap.height;

        var total_main: f32 = 0;
        var max_cross: f32 = 0;
        var count: usize = 0;

        for (w.children.items) |child| {
            const child_size = child.vtable.measure(child, ctx, constraints);
            const cm = child.layout_style.margin;

            if (is_row) {
                total_main += child_size.width + cm.left + cm.right;
                max_cross = @max(max_cross, child_size.height + cm.top + cm.bottom);
            } else {
                total_main += child_size.height + cm.top + cm.bottom;
                max_cross = @max(max_cross, child_size.width + cm.left + cm.right);
            }
            count += 1;
        }

        if (count > 1) total_main += gap * @as(f32, @floatFromInt(count - 1));

        if (is_row) {
            return .{
                .width = total_main + pad.left + pad.right,
                .height = max_cross + pad.top + pad.bottom,
            };
        } else {
            return .{
                .width = max_cross + pad.left + pad.right,
                .height = total_main + pad.top + pad.bottom,
            };
        }
    }

    fn paint(w: *Widget, ctx: *PaintContext) void {
        const self: *Container = @fieldParentPtr("base", w);

        const rx = ctx.offset_x + w.rect.x;
        const ry = ctx.offset_y + w.rect.y;

        // 背景
        if (self.bg_color) |bg| {
            if (self.corner_radius > 0) {
                ctx.renderer.fillRoundedRect(
                    .{ .x = rx, .y = ry, .width = w.rect.width, .height = w.rect.height },
                    self.corner_radius,
                    bg,
                ) catch {};
            } else {
                ctx.renderer.fillRect(
                    .{ .x = rx, .y = ry, .width = w.rect.width, .height = w.rect.height },
                    bg,
                ) catch {};
            }
        }

        // 边框 (简化: 用两个圆角矩形模拟)
        if (self.border_color) |bc| {
            if (self.border_width > 0) {
                const bw = self.border_width;
                // 外框
                ctx.renderer.fillRoundedRect(
                    .{ .x = rx, .y = ry, .width = w.rect.width, .height = w.rect.height },
                    self.corner_radius,
                    bc,
                ) catch {};
                // 内部挖空 (用背景色覆盖)
                if (self.bg_color) |bg| {
                    ctx.renderer.fillRoundedRect(
                        .{ .x = rx + bw, .y = ry + bw, .width = w.rect.width - bw * 2, .height = w.rect.height - bw * 2 },
                        @max(0, self.corner_radius - bw),
                        bg,
                    ) catch {};
                }
            }
        }
    }
};
