//! FlowBox 控件 - 流式布局容器
//!
//! 类似 GtkFlowBox / CSS flex-wrap: wrap:
//! 子控件按行 (或列) 排列, 空间不足时自动换行。
//! 支持行间距、列间距、对齐方式。

const std = @import("std");
const math = @import("../math.zig");
const widget_mod = @import("widget.zig");
const layout_mod = @import("../layout/engine.zig");
const pal = @import("../pal/pal.zig");

const Widget = widget_mod.Widget;
const PaintContext = widget_mod.PaintContext;

pub const FlowBox = struct {
    base: Widget,
    allocator: std.mem.Allocator,
    direction: layout_mod.FlexDirection,
    row_gap: f32,
    col_gap: f32,
    padding: math.EdgeInsets,
    justify: layout_mod.JustifyContent,
    align_items: layout_mod.AlignItems,

    pub fn create(allocator: std.mem.Allocator, opts: struct {
        direction: layout_mod.FlexDirection = .row,
        row_gap: f32 = 8,
        col_gap: f32 = 8,
        padding: math.EdgeInsets = .{},
        justify: layout_mod.JustifyContent = .start,
        align_items: layout_mod.AlignItems = .stretch,
        bg_color: ?math.Color = null,
        corner_radius: f32 = 0,
        width: layout_mod.Dimension = .{ .auto = {} },
        height: layout_mod.Dimension = .{ .auto = {} },
    }) !*FlowBox {
        const self = try allocator.create(FlowBox);
        self.* = .{
            .base = .{
                .vtable = &vtable,
                .id = widget_mod.genWidgetId(),
            },
            .allocator = allocator,
            .direction = opts.direction,
            .row_gap = opts.row_gap,
            .col_gap = opts.col_gap,
            .padding = opts.padding,
            .justify = opts.justify,
            .align_items = opts.align_items,
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

    pub fn destroy(self: *FlowBox, allocator: std.mem.Allocator) void {
        self.base.background.deinit(allocator);
        for (self.base.children.items) |child| {
            child.vtable.destroy(child, allocator);
        }
        self.base.children.deinit(allocator);
        allocator.destroy(self);
    }

    pub fn addChild(self: *FlowBox, child: *Widget) !void {
        try self.base.addChild(self.allocator, child);
    }

    // ── VTable 实现 ──────────────────────────────────────────────────────────

    const vtable = Widget.VTable{
        .type_name = "flow_box",
        .measure = measure,
        .perform_layout = performLayout,
        .paint = paint,
        .on_event = onEvent,
        .focusable = false,
        .destroy = destroyVTable,
    };

    fn destroyVTable(w: *Widget, allocator: std.mem.Allocator) void {
        const self: *FlowBox = @fieldParentPtr("base", w);
        self.destroy(allocator);
    }

    fn isRow(self: *const FlowBox) bool {
        return self.direction == .row or self.direction == .row_reverse;
    }

    fn measure(w: *Widget, ctx: *PaintContext, constraints: layout_mod.Constraints) math.Size(f32) {
        const self: *FlowBox = @fieldParentPtr("base", w);
        const children = self.base.children.items;
        if (children.len == 0) {
            const pad = self.padding;
            return .{ .width = pad.left + pad.right, .height = pad.top + pad.bottom };
        }

        const row = self.isRow();
        const pad = self.padding;

        const inner_w = @max(0, constraints.max_width - pad.left - pad.right);
        const inner_h = @max(0, constraints.max_height - pad.top - pad.bottom);

        var total_main: f32 = 0;
        var total_cross: f32 = 0;
        var line_main: f32 = 0;
        var line_cross: f32 = 0;
        var first_in_line = true;

        for (children) |child| {
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
            const cm = child.layout_style.margin;

            const child_main = if (row) cw + cm.left + cm.right else ch + cm.top + cm.bottom;
            const child_cross = if (row) ch + cm.top + cm.bottom else cw + cm.left + cm.right;
            const gap_main = if (row) self.col_gap else self.row_gap;
            const max_main = if (row) inner_w else inner_h;

            if (!first_in_line and line_main + gap_main + child_main > max_main and max_main > 0) {
                total_cross += line_cross + (if (row) self.row_gap else self.col_gap);
                if (line_main > total_main) total_main = line_main;
                line_main = child_main;
                line_cross = child_cross;
            } else {
                if (!first_in_line) line_main += gap_main;
                line_main += child_main;
                if (child_cross > line_cross) line_cross = child_cross;
                first_in_line = false;
            }
        }

        if (line_main > total_main) total_main = line_main;
        total_cross += line_cross;

        if (row) {
            return .{
                .width = @min(total_main + pad.left + pad.right, constraints.max_width),
                .height = @min(total_cross + pad.top + pad.bottom, constraints.max_height),
            };
        } else {
            return .{
                .width = @min(total_cross + pad.left + pad.right, constraints.max_width),
                .height = @min(total_main + pad.top + pad.bottom, constraints.max_height),
            };
        }
    }

    const LineInfo = struct {
        start: usize,
        count: usize,
        main_size: f32,
        cross_size: f32,
    };

    fn performLayout(w: *Widget, ctx: *PaintContext) void {
        const self: *FlowBox = @fieldParentPtr("base", w);
        const children = self.base.children.items;
        if (children.len == 0) return;

        const row = self.isRow();
        const pad = self.padding;
        const inner_w = @max(0, w.rect.width - pad.left - pad.right);
        const inner_h = @max(0, w.rect.height - pad.top - pad.bottom);
        const max_main = if (row) inner_w else inner_h;
        const gap_main = if (row) self.col_gap else self.row_gap;
        const gap_cross = if (row) self.row_gap else self.col_gap;

        var sizes: [256]math.Size(f32) = undefined;
        var margins: [256]math.EdgeInsets = undefined;
        const count = @min(children.len, sizes.len);

        for (0..count) |i| {
            const child = children[i];
            if (child.state.visible and child.layout_style.position != .absolute) {
                const size = child.vtable.measure(child, ctx, .{
                    .max_width = inner_w,
                    .max_height = inner_h,
                });
                var cw = size.width;
                var ch = size.height;
                if (child.layout_style.width.resolve(inner_w)) |ew| cw = ew;
                if (child.layout_style.height.resolve(inner_h)) |eh| ch = eh;
                sizes[i] = .{ .width = cw, .height = ch };
                margins[i] = child.layout_style.margin;
            } else {
                sizes[i] = .{ .width = 0, .height = 0 };
                margins[i] = .{};
            }
        }

        var lines: [64]LineInfo = undefined;
        var line_count: usize = 0;

        if (count > 0) {
            var line_start: usize = 0;
            var line_main: f32 = 0;
            var line_cross: f32 = 0;
            var first_in_line = true;

            for (0..count) |i| {
                const child = children[i];
                if (!child.state.visible) continue;
                if (child.layout_style.position == .absolute) continue;

                const size = sizes[i];
                const cm = margins[i];
                const child_main = if (row) size.width + cm.left + cm.right else size.height + cm.top + cm.bottom;
                const child_cross = if (row) size.height + cm.top + cm.bottom else size.width + cm.left + cm.right;

                if (!first_in_line and line_main + gap_main + child_main > max_main and max_main > 0) {
                    lines[line_count] = .{
                        .start = line_start,
                        .count = i - line_start,
                        .main_size = line_main,
                        .cross_size = line_cross,
                    };
                    line_count += 1;
                    line_start = i;
                    line_main = child_main;
                    line_cross = child_cross;
                } else {
                    if (!first_in_line) line_main += gap_main;
                    line_main += child_main;
                    if (child_cross > line_cross) line_cross = child_cross;
                    first_in_line = false;
                }
            }

            if (!first_in_line) {
                lines[line_count] = .{
                    .start = line_start,
                    .count = count - line_start,
                    .main_size = line_main,
                    .cross_size = line_cross,
                };
                line_count += 1;
            }
        }

        var total_cross: f32 = 0;
        for (0..line_count) |li| {
            total_cross += lines[li].cross_size;
        }
        if (line_count > 1) total_cross += gap_cross * @as(f32, @floatFromInt(line_count - 1));

        var cross_offset: f32 = pad.top;
        if (!row) cross_offset = pad.left;

        for (0..line_count) |li| {
            const line = lines[li];
            const extra_main = max_main - line.main_size;

            var main_offset: f32 = switch (self.justify) {
                .start => 0,
                .center => extra_main / 2.0,
                .end => extra_main,
                .space_between => if (line.count > 1) 0 else 0,
                .space_around => if (line.count > 0) extra_main / @as(f32, @floatFromInt(line.count)) / 2.0 else 0,
                .space_evenly => if (line.count > 0) extra_main / @as(f32, @floatFromInt(line.count + 1)) else 0,
            };

            var item_gap = gap_main;
            if (self.justify == .space_between and line.count > 1) {
                item_gap = gap_main + extra_main / @as(f32, @floatFromInt(line.count - 1));
            } else if (self.justify == .space_around and line.count > 0) {
                item_gap = gap_main + extra_main / @as(f32, @floatFromInt(line.count));
            } else if (self.justify == .space_evenly and line.count > 0) {
                item_gap = gap_main + extra_main / @as(f32, @floatFromInt(line.count + 1));
            }

            for (0..line.count) |i_in_line| {
                const idx = line.start + i_in_line;
                if (idx >= count) break;
                const child = children[idx];
                if (!child.state.visible) continue;
                if (child.layout_style.position == .absolute) continue;

                const size = sizes[idx];
                const cm = margins[idx];
                const child_main = if (row) size.width + cm.left + cm.right else size.height + cm.top + cm.bottom;
                const child_cross = if (row) size.height + cm.top + cm.bottom else size.width + cm.left + cm.right;

                const cross_align = child.layout_style.align_self orelse self.align_items;
                const cross_in_line = switch (cross_align) {
                    .start => cross_offset,
                    .center => cross_offset + (line.cross_size - child_cross) / 2.0,
                    .end => cross_offset + line.cross_size - child_cross,
                    .stretch, .baseline => cross_offset,
                };

                if (row) {
                    child.rect.x = pad.left + main_offset + cm.left;
                    child.rect.y = cross_in_line + cm.top;
                    child.rect.width = size.width;
                    child.rect.height = if (self.align_items == .stretch) line.cross_size - cm.top - cm.bottom else size.height;
                } else {
                    child.rect.x = cross_in_line + cm.left;
                    child.rect.y = pad.top + main_offset + cm.top;
                    child.rect.width = if (self.align_items == .stretch) line.cross_size - cm.left - cm.right else size.width;
                    child.rect.height = size.height;
                }

                child.layoutSubtree(ctx);
                main_offset += child_main + item_gap;
            }

            cross_offset += line.cross_size + gap_cross;
        }
    }

    fn paint(w: *Widget, ctx: *PaintContext) void {
        _ = w;
        _ = ctx;
    }

    fn onEvent(w: *Widget, event: *const pal.Event, ectx: *widget_mod.EventContext) widget_mod.EventResult {
        const self: *FlowBox = @fieldParentPtr("base", w);
        const children = self.base.children.items;
        for (children) |child| {
            if (!child.state.visible) continue;
            const result = child.dispatchEvent(event, ectx);
            if (result == .handled) return .handled;
        }
        return .ignored;
    }
};

// ── Tests ──────────────────────────────────────────────────────────────────

test "flow_box create" {
    const fb = try FlowBox.create(std.testing.allocator, .{});
    defer fb.destroy(std.testing.allocator);
    try std.testing.expectEqualStrings("flow_box", fb.base.vtable.type_name);
    try std.testing.expectEqual(layout_mod.FlexDirection.row, fb.direction);
}

test "flow_box row gap" {
    const fb = try FlowBox.create(std.testing.allocator, .{
        .row_gap = 10,
        .col_gap = 5,
    });
    defer fb.destroy(std.testing.allocator);
    try std.testing.expectEqual(@as(f32, 10), fb.row_gap);
    try std.testing.expectEqual(@as(f32, 5), fb.col_gap);
}
