//! CenterBox 控件 - 三栏式居中布局容器
//!
//! 类似 GtkCenterBox / CSS justify-content: space-between 模式:
//! 三个区域 (start / center / end), 中间区域居中显示。
//! 支持水平和垂直方向。

const std = @import("std");
const math = @import("../math.zig");
const widget_mod = @import("widget.zig");
const layout_mod = @import("../layout/engine.zig");
const pal = @import("../pal/pal.zig");

const Widget = widget_mod.Widget;
const PaintContext = widget_mod.PaintContext;

pub const CenterBox = struct {
    base: Widget,
    allocator: std.mem.Allocator,
    direction: layout_mod.FlexDirection,
    start_child: ?*Widget = null,
    center_child: ?*Widget = null,
    end_child: ?*Widget = null,

    pub fn create(allocator: std.mem.Allocator, opts: struct {
        direction: layout_mod.FlexDirection = .row,
        bg_color: ?math.Color = null,
        corner_radius: f32 = 0,
        width: layout_mod.Dimension = .{ .auto = {} },
        height: layout_mod.Dimension = .{ .auto = {} },
    }) !*CenterBox {
        const self = try allocator.create(CenterBox);
        self.* = .{
            .base = .{
                .vtable = &vtable,
                .id = widget_mod.genWidgetId(),
            },
            .allocator = allocator,
            .direction = opts.direction,
        };
        if (opts.bg_color) |c| {
            self.base.background.bg = .{ .color = c };
        }
        self.base.background.corner_radius = opts.corner_radius;
        self.base.layout_style.width = opts.width;
        self.base.layout_style.height = opts.height;
        self.base.accessibility = .{ .role = .container };
        return self;
    }

    pub fn destroy(self: *CenterBox, allocator: std.mem.Allocator) void {
        self.base.background.deinit(allocator);
        for (self.base.children.items) |child| {
            child.vtable.destroy(child, allocator);
        }
        self.base.children.deinit(allocator);
        allocator.destroy(self);
    }

    pub fn setStart(self: *CenterBox, child: *Widget) !void {
        self.start_child = child;
        try self.base.addChild(self.allocator, child);
    }

    pub fn setCenter(self: *CenterBox, child: *Widget) !void {
        self.center_child = child;
        try self.base.addChild(self.allocator, child);
    }

    pub fn setEnd(self: *CenterBox, child: *Widget) !void {
        self.end_child = child;
        try self.base.addChild(self.allocator, child);
    }

    // ── VTable 实现 ──────────────────────────────────────────────────────────

    const vtable = Widget.VTable{
        .type_name = "center_box",
        .measure = measure,
        .perform_layout = performLayout,
        .paint = paint,
        .on_event = onEvent,
        .focusable = false,
        .destroy = destroyVTable,
    };

    fn destroyVTable(w: *Widget, allocator: std.mem.Allocator) void {
        const self: *CenterBox = @fieldParentPtr("base", w);
        self.destroy(allocator);
    }

    fn isRow(self: *const CenterBox) bool {
        return self.direction == .row or self.direction == .row_reverse;
    }

    fn measure(w: *Widget, ctx: *PaintContext, constraints: layout_mod.Constraints) math.Size(f32) {
        const self: *CenterBox = @fieldParentPtr("base", w);
        const row = self.isRow();
        const pad = w.layout_style.padding;

        const inner_w = @max(0, constraints.max_width - pad.left - pad.right);
        const inner_h = @max(0, constraints.max_height - pad.top - pad.bottom);
        const inner_constraints = layout_mod.Constraints{
            .max_width = inner_w,
            .max_height = inner_h,
        };

        var total_main: f32 = 0;
        var max_cross: f32 = 0;

        const children = [_]?*Widget{ self.start_child, self.center_child, self.end_child };
        for (children) |child_opt| {
            if (child_opt) |child| {
                if (!child.state.visible) continue;
                if (child.layout_style.position == .absolute) continue;
                const size = child.vtable.measure(child, ctx, inner_constraints);
                var cw = size.width;
                var ch = size.height;
                if (child.layout_style.width.resolve(inner_w)) |ew| cw = ew;
                if (child.layout_style.height.resolve(inner_h)) |eh| ch = eh;
                const cm = child.layout_style.margin;
                if (row) {
                    total_main += cw + cm.left + cm.right;
                    if (ch + cm.top + cm.bottom > max_cross) max_cross = ch + cm.top + cm.bottom;
                } else {
                    total_main += ch + cm.top + cm.bottom;
                    if (cw + cm.left + cm.right > max_cross) max_cross = cw + cm.left + cm.right;
                }
            }
        }

        if (row) {
            return .{
                .width = @min(total_main + pad.left + pad.right, constraints.max_width),
                .height = @min(max_cross + pad.top + pad.bottom, constraints.max_height),
            };
        } else {
            return .{
                .width = @min(max_cross + pad.left + pad.right, constraints.max_width),
                .height = @min(total_main + pad.top + pad.bottom, constraints.max_height),
            };
        }
    }

    fn performLayout(w: *Widget, ctx: *PaintContext) void {
        const self: *CenterBox = @fieldParentPtr("base", w);
        const row = self.isRow();
        const pad = w.layout_style.padding;
        const total_w = w.rect.width;
        const total_h = w.rect.height;

        const inner_w = @max(0, total_w - pad.left - pad.right);
        const inner_h = @max(0, total_h - pad.top - pad.bottom);

        const children = [_]?*Widget{ self.start_child, self.center_child, self.end_child };
        var sizes: [3]math.Size(f32) = [_]math.Size(f32){.{ .width = 0, .height = 0 }} ** 3;
        var margins: [3]math.EdgeInsets = [_]math.EdgeInsets{.{}} ** 3;

        for (children, 0..) |child_opt, i| {
            if (child_opt) |child| {
                if (!child.state.visible) continue;
                if (child.layout_style.position == .absolute) continue;
                const sub_constraints = layout_mod.Constraints{
                    .max_width = inner_w,
                    .max_height = inner_h,
                };
                const size = child.vtable.measure(child, ctx, sub_constraints);
                var cw = size.width;
                var ch = size.height;
                if (child.layout_style.width.resolve(inner_w)) |ew| cw = ew;
                if (child.layout_style.height.resolve(inner_h)) |eh| ch = eh;
                sizes[i] = .{ .width = cw, .height = ch };
                margins[i] = child.layout_style.margin;
            }
        }

        if (row) {
            const center_w = sizes[1].width + margins[1].left + margins[1].right;
            const end_w = sizes[2].width + margins[2].left + margins[2].right;

            const start_x = pad.left;
            const center_x = pad.left + (inner_w - center_w) / 2.0;
            const end_x = pad.left + inner_w - end_w;

            const cross_align = w.layout_style.align_items;

            if (self.start_child) |child| {
                if (child.state.visible and child.layout_style.position != .absolute) {
                    child.rect.x = start_x + margins[0].left;
                    child.rect.width = sizes[0].width;
                    const cross = child.layout_style.align_self orelse cross_align;
                    switch (cross) {
                        .stretch => {
                            child.rect.y = pad.top + margins[0].top;
                            if (child.layout_style.height == .auto) {
                                child.rect.height = inner_h - margins[0].top - margins[0].bottom;
                            } else {
                                child.rect.y = pad.top + margins[0].top + (inner_h - margins[0].top - margins[0].bottom - sizes[0].height) / 2;
                                child.rect.height = sizes[0].height;
                            }
                        },
                        .center => {
                            child.rect.y = pad.top + margins[0].top + (inner_h - margins[0].top - margins[0].bottom - sizes[0].height) / 2;
                            child.rect.height = sizes[0].height;
                        },
                        .end => {
                            child.rect.y = pad.top + inner_h - sizes[0].height - margins[0].bottom;
                            child.rect.height = sizes[0].height;
                        },
                        .start, .baseline => {
                            child.rect.y = pad.top + margins[0].top;
                            child.rect.height = sizes[0].height;
                        },
                    }
                    child.layoutSubtree(ctx);
                }
            }
            if (self.center_child) |child| {
                if (child.state.visible and child.layout_style.position != .absolute) {
                    child.rect.x = center_x + margins[1].left;
                    child.rect.width = sizes[1].width;
                    const cross = child.layout_style.align_self orelse cross_align;
                    switch (cross) {
                        .stretch => {
                            child.rect.y = pad.top + margins[1].top;
                            if (child.layout_style.height == .auto) {
                                child.rect.height = inner_h - margins[1].top - margins[1].bottom;
                            } else {
                                child.rect.y = pad.top + margins[1].top + (inner_h - margins[1].top - margins[1].bottom - sizes[1].height) / 2;
                                child.rect.height = sizes[1].height;
                            }
                        },
                        .center => {
                            child.rect.y = pad.top + margins[1].top + (inner_h - margins[1].top - margins[1].bottom - sizes[1].height) / 2;
                            child.rect.height = sizes[1].height;
                        },
                        .end => {
                            child.rect.y = pad.top + inner_h - sizes[1].height - margins[1].bottom;
                            child.rect.height = sizes[1].height;
                        },
                        .start, .baseline => {
                            child.rect.y = pad.top + margins[1].top;
                            child.rect.height = sizes[1].height;
                        },
                    }
                    child.layoutSubtree(ctx);
                }
            }
            if (self.end_child) |child| {
                if (child.state.visible and child.layout_style.position != .absolute) {
                    child.rect.x = end_x + margins[2].left;
                    child.rect.width = sizes[2].width;
                    const cross = child.layout_style.align_self orelse cross_align;
                    switch (cross) {
                        .stretch => {
                            child.rect.y = pad.top + margins[2].top;
                            if (child.layout_style.height == .auto) {
                                child.rect.height = inner_h - margins[2].top - margins[2].bottom;
                            } else {
                                child.rect.y = pad.top + margins[2].top + (inner_h - margins[2].top - margins[2].bottom - sizes[2].height) / 2;
                                child.rect.height = sizes[2].height;
                            }
                        },
                        .center => {
                            child.rect.y = pad.top + margins[2].top + (inner_h - margins[2].top - margins[2].bottom - sizes[2].height) / 2;
                            child.rect.height = sizes[2].height;
                        },
                        .end => {
                            child.rect.y = pad.top + inner_h - sizes[2].height - margins[2].bottom;
                            child.rect.height = sizes[2].height;
                        },
                        .start, .baseline => {
                            child.rect.y = pad.top + margins[2].top;
                            child.rect.height = sizes[2].height;
                        },
                    }
                    child.layoutSubtree(ctx);
                }
            }
        } else {
            const center_h = sizes[1].height + margins[1].top + margins[1].bottom;
            const end_h = sizes[2].height + margins[2].top + margins[2].bottom;

            const start_y = pad.top;
            const center_y = pad.top + (inner_h - center_h) / 2.0;
            const end_y = pad.top + inner_h - end_h;

            const cross_align = w.layout_style.align_items;

            if (self.start_child) |child| {
                if (child.state.visible and child.layout_style.position != .absolute) {
                    child.rect.y = start_y + margins[0].top;
                    child.rect.height = sizes[0].height;
                    const cross = child.layout_style.align_self orelse cross_align;
                    switch (cross) {
                        .stretch => {
                            child.rect.x = pad.left + margins[0].left;
                            if (child.layout_style.width == .auto) {
                                child.rect.width = inner_w - margins[0].left - margins[0].right;
                            } else {
                                child.rect.x = pad.left + margins[0].left + (inner_w - margins[0].left - margins[0].right - sizes[0].width) / 2;
                                child.rect.width = sizes[0].width;
                            }
                        },
                        .center => {
                            child.rect.x = pad.left + margins[0].left + (inner_w - margins[0].left - margins[0].right - sizes[0].width) / 2;
                            child.rect.width = sizes[0].width;
                        },
                        .end => {
                            child.rect.x = pad.left + inner_w - sizes[0].width - margins[0].right;
                            child.rect.width = sizes[0].width;
                        },
                        .start, .baseline => {
                            child.rect.x = pad.left + margins[0].left;
                            child.rect.width = sizes[0].width;
                        },
                    }
                    child.layoutSubtree(ctx);
                }
            }
            if (self.center_child) |child| {
                if (child.state.visible and child.layout_style.position != .absolute) {
                    child.rect.y = center_y + margins[1].top;
                    child.rect.height = sizes[1].height;
                    const cross = child.layout_style.align_self orelse cross_align;
                    switch (cross) {
                        .stretch => {
                            child.rect.x = pad.left + margins[1].left;
                            if (child.layout_style.width == .auto) {
                                child.rect.width = inner_w - margins[1].left - margins[1].right;
                            } else {
                                child.rect.x = pad.left + margins[1].left + (inner_w - margins[1].left - margins[1].right - sizes[1].width) / 2;
                                child.rect.width = sizes[1].width;
                            }
                        },
                        .center => {
                            child.rect.x = pad.left + margins[1].left + (inner_w - margins[1].left - margins[1].right - sizes[1].width) / 2;
                            child.rect.width = sizes[1].width;
                        },
                        .end => {
                            child.rect.x = pad.left + inner_w - sizes[1].width - margins[1].right;
                            child.rect.width = sizes[1].width;
                        },
                        .start, .baseline => {
                            child.rect.x = pad.left + margins[1].left;
                            child.rect.width = sizes[1].width;
                        },
                    }
                    child.layoutSubtree(ctx);
                }
            }
            if (self.end_child) |child| {
                if (child.state.visible and child.layout_style.position != .absolute) {
                    child.rect.y = end_y + margins[2].top;
                    child.rect.height = sizes[2].height;
                    const cross = child.layout_style.align_self orelse cross_align;
                    switch (cross) {
                        .stretch => {
                            child.rect.x = pad.left + margins[2].left;
                            if (child.layout_style.width == .auto) {
                                child.rect.width = inner_w - margins[2].left - margins[2].right;
                            } else {
                                child.rect.x = pad.left + margins[2].left + (inner_w - margins[2].left - margins[2].right - sizes[2].width) / 2;
                                child.rect.width = sizes[2].width;
                            }
                        },
                        .center => {
                            child.rect.x = pad.left + margins[2].left + (inner_w - margins[2].left - margins[2].right - sizes[2].width) / 2;
                            child.rect.width = sizes[2].width;
                        },
                        .end => {
                            child.rect.x = pad.left + inner_w - sizes[2].width - margins[2].right;
                            child.rect.width = sizes[2].width;
                        },
                        .start, .baseline => {
                            child.rect.x = pad.left + margins[2].left;
                            child.rect.width = sizes[2].width;
                        },
                    }
                    child.layoutSubtree(ctx);
                }
            }
        }
    }

    fn paint(w: *Widget, ctx: *PaintContext) void {
        _ = w;
        _ = ctx;
    }

    fn onEvent(w: *Widget, event: *const pal.Event, ectx: *widget_mod.EventContext) widget_mod.EventResult {
        const self: *CenterBox = @fieldParentPtr("base", w);
        const children = [_]?*Widget{ self.start_child, self.center_child, self.end_child };
        for (children) |child_opt| {
            if (child_opt) |child| {
                const result = child.dispatchEvent(event, ectx);
                if (result == .handled) return .handled;
            }
        }
        return .ignored;
    }
};

// ── Tests ──────────────────────────────────────────────────────────────────

test "center_box create" {
    const cb = try CenterBox.create(std.testing.allocator, .{});
    defer cb.destroy(std.testing.allocator);
    try std.testing.expectEqualStrings("center_box", cb.base.vtable.type_name);
    try std.testing.expectEqual(layout_mod.FlexDirection.row, cb.direction);
}

test "center_box row direction" {
    const cb = try CenterBox.create(std.testing.allocator, .{ .direction = .column });
    defer cb.destroy(std.testing.allocator);
    try std.testing.expectEqual(layout_mod.FlexDirection.column, cb.direction);
}
