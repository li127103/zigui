//! Frame 控件 - 带标题的边框分组容器
//!
//! 类似 GtkFrame: 围绕子控件绘制带标题的边框, 用于视觉分组。
//! 标题嵌入到上边框中, 支持自定义标签位置 (左/中/右)。

const std = @import("std");
const math = @import("../math.zig");
const widget_mod = @import("widget.zig");
const layout_mod = @import("../layout/engine.zig");
const styled_text = @import("../text/styled_text.zig");
const pal = @import("../pal/pal.zig");

const Widget = widget_mod.Widget;
const PaintContext = widget_mod.PaintContext;

pub const FrameLabelAlign = enum { left, center, right };

pub const Frame = struct {
    base: Widget,
    allocator: std.mem.Allocator,
    label: []const u8,
    label_align: FrameLabelAlign,
    label_font_size: f32,
    label_color: math.Color,
    border_color: math.Color,
    border_width: f32,
    corner_radius: f32,
    padding: math.EdgeInsets,

    pub fn create(allocator: std.mem.Allocator, label: []const u8, opts: struct {
        bg_color: ?math.Color = null,
        border_color: math.Color = math.Color.hex(0x334155FF),
        border_width: f32 = 1,
        corner_radius: f32 = 8,
        label_align: FrameLabelAlign = .left,
        label_font_size: f32 = 12,
        label_color: math.Color = math.Color.hex(0x94A3B8FF),
        padding: math.EdgeInsets = .{ .left = 12, .top = 16, .right = 12, .bottom = 12 },
        width: layout_mod.Dimension = .{ .auto = {} },
        height: layout_mod.Dimension = .{ .auto = {} },
    }) !*Frame {
        const self = try allocator.create(Frame);
        self.* = .{
            .base = .{
                .vtable = &vtable,
                .id = widget_mod.genWidgetId(),
            },
            .allocator = allocator,
            .label = label,
            .label_align = opts.label_align,
            .label_font_size = opts.label_font_size,
            .label_color = opts.label_color,
            .border_color = opts.border_color,
            .border_width = opts.border_width,
            .corner_radius = opts.corner_radius,
            .padding = opts.padding,
        };
        if (opts.bg_color) |c| {
            self.base.background.bg = .{ .color = c };
        }
        self.base.background.corner_radius = opts.corner_radius;
        self.base.layout_style.width = opts.width;
        self.base.layout_style.height = opts.height;
        self.base.accessibility = .{ .role = .container, .label = label };
        return self;
    }

    pub fn destroy(self: *Frame, allocator: std.mem.Allocator) void {
        self.base.background.deinit(allocator);
        for (self.base.children.items) |child| {
            child.vtable.destroy(child, allocator);
        }
        self.base.children.deinit(allocator);
        allocator.destroy(self);
    }

    /// 设置子内容 (Frame 只包含一个子控件)
    pub fn setChild(self: *Frame, child: *Widget) !void {
        while (self.base.children.items.len > 0) {
            _ = self.base.children.pop();
        }
        try self.base.addChild(self.allocator, child);
    }

    /// 设置标题文字
    pub fn setLabel(self: *Frame, label: []const u8) void {
        self.label = label;
        self.base.markLayoutDirty();
    }

    // ── VTable 实现 ──────────────────────────────────────────────────────────

    const vtable = Widget.VTable{
        .type_name = "frame",
        .measure = measure,
        .perform_layout = performLayout,
        .paint = paint,
        .on_event = onEvent,
        .focusable = false,
        .destroy = destroyVTable,
    };

    fn destroyVTable(w: *Widget, allocator: std.mem.Allocator) void {
        const self: *Frame = @fieldParentPtr("base", w);
        self.destroy(allocator);
    }

    fn measure(w: *Widget, ctx: *PaintContext, constraint: layout_mod.Constraints) math.Size(f32) {
        const self: *Frame = @fieldParentPtr("base", w);
        const children = self.base.children.items;

        const label_h = self.label_font_size + 6;
        const pad = self.padding;
        const extra_w = pad.left + pad.right;
        const extra_h = label_h + pad.top + pad.bottom;

        var child_w: f32 = 0;
        var child_h: f32 = 0;

        if (children.len > 0) {
            const child = children[0];
            if (!child.state.visible) {
                return .{ .width = extra_w, .height = extra_h };
            }
            const inner_w = @max(0, constraint.max_width - extra_w);
            const inner_h = @max(0, constraint.max_height - extra_h);
            const sub_constraint = layout_mod.Constraints{
                .max_width = inner_w,
                .max_height = inner_h,
            };
            const size = child.vtable.measure(child, ctx, sub_constraint);
            var cw = size.width;
            var ch = size.height;
            if (child.layout_style.width.resolve(inner_w)) |ew| cw = ew;
            if (child.layout_style.height.resolve(inner_h)) |eh| ch = eh;
            const cm = child.layout_style.margin;
            child_w = cw + cm.left + cm.right;
            child_h = ch + cm.top + cm.bottom;
        }

        return .{
            .width = @min(child_w + extra_w, constraint.max_width),
            .height = @min(child_h + extra_h, constraint.max_height),
        };
    }

    fn performLayout(w: *Widget, ctx: *PaintContext) void {
        const self: *Frame = @fieldParentPtr("base", w);
        const children = self.base.children.items;
        if (children.len == 0) return;

        const label_h = self.label_font_size + 6;
        const pad = self.padding;

        const child = children[0];
        if (!child.state.visible) return;
        if (child.layout_style.position == .absolute) return;

        const inner_w = @max(0, w.rect.width - pad.left - pad.right);
        const inner_h = @max(0, w.rect.height - label_h - pad.top - pad.bottom);
        const cm = child.layout_style.margin;

        const avail_w = @max(0, inner_w - cm.left - cm.right);
        const avail_h = @max(0, inner_h - cm.top - cm.bottom);

        const size = child.vtable.measure(child, ctx, .{
            .max_width = avail_w,
            .max_height = avail_h,
        });

        var cw = size.width;
        var ch = size.height;

        if (child.layout_style.width.resolve(avail_w)) |ew| {
            cw = ew;
        } else {
            cw = avail_w;
        }

        if (child.layout_style.height.resolve(avail_h)) |eh| {
            ch = eh;
        } else {
            ch = avail_h;
        }

        child.rect.x = pad.left + cm.left;
        child.rect.y = label_h + pad.top + cm.top;
        child.rect.width = cw;
        child.rect.height = ch;

        child.layoutSubtree(ctx);
    }

    fn paint(w: *Widget, ctx: *PaintContext) void {
        const self: *Frame = @fieldParentPtr("base", w);
        const r = w.rect;
        const renderer = ctx.renderer;
        const ox = ctx.offset_x;
        const oy = ctx.offset_y;

        const label_h = self.label_font_size + 6;
        const half_label_h = label_h / 2.0;

        const bg = self.base.background;
        if (bg.bg == .color) {
            renderer.fillRoundedRect(
                .{ .x = ox + r.x, .y = oy + r.y + half_label_h, .width = r.width, .height = r.height - half_label_h },
                self.corner_radius,
                bg.bg.color,
            ) catch {};
        }

        const top_y = oy + r.y + half_label_h;

        // 左边框
        renderer.fillRect(
            .{ .x = ox + r.x, .y = top_y, .width = self.border_width, .height = r.height - half_label_h },
            self.border_color,
        ) catch {};
        // 右边框
        renderer.fillRect(
            .{ .x = ox + r.x + r.width - self.border_width, .y = top_y, .width = self.border_width, .height = r.height - half_label_h },
            self.border_color,
        ) catch {};
        // 下边框
        renderer.fillRect(
            .{ .x = ox + r.x, .y = oy + r.y + r.height - self.border_width, .width = r.width, .height = self.border_width },
            self.border_color,
        ) catch {};

        var label_width: f32 = 0;
        var label_height: f32 = 0;
        if (self.label.len > 0) {
            const label_size = styled_text.measureText(ctx.allocator, self.label, .{
                .font_size = self.label_font_size,
                .font_weight = 600,
            });
            label_width = label_size.width + 16;
            label_height = label_size.height;
        }

        const label_x = switch (self.label_align) {
            .left => ox + r.x + 12,
            .center => ox + r.x + (r.width - label_width) / 2.0,
            .right => ox + r.x + r.width - label_width - 12,
        };

        const label_y = oy + r.y + (label_h - label_height) / 2.0;

        // 上边框: 左段
        if (label_x > ox + r.x + self.corner_radius) {
            renderer.fillRect(
                .{ .x = ox + r.x + self.corner_radius, .y = top_y, .width = label_x - ox - r.x - self.corner_radius, .height = self.border_width },
                self.border_color,
            ) catch {};
        }
        // 上边框: 右段
        const label_right = label_x + label_width;
        if (label_right < ox + r.x + r.width - self.corner_radius) {
            renderer.fillRect(
                .{ .x = label_right, .y = top_y, .width = ox + r.x + r.width - self.corner_radius - label_right, .height = self.border_width },
                self.border_color,
            ) catch {};
        }

        // 绘制标签文字
        if (self.label.len > 0 and label_width > 16) {
            styled_text.drawText(
                ctx.renderer,
                ctx.allocator,
                self.label,
                label_x + 8,
                label_y,
                .{
                    .font_size = self.label_font_size,
                    .font_weight = 600,
                    .color = self.label_color,
                },
            );
        }
    }

    fn onEvent(w: *Widget, event: *const pal.Event, ectx: *widget_mod.EventContext) widget_mod.EventResult {
        const self: *Frame = @fieldParentPtr("base", w);
        const children = self.base.children.items;
        if (children.len == 0) return .ignored;
        return children[0].dispatchEvent(event, ectx);
    }
};

// ── Tests ──────────────────────────────────────────────────────────────────

test "frame create" {
    const f = try Frame.create(std.testing.allocator, "Settings", .{});
    defer f.destroy(std.testing.allocator);
    try std.testing.expectEqualStrings("Settings", f.label);
    try std.testing.expectEqual(FrameLabelAlign.left, f.label_align);
    try std.testing.expectEqualStrings("frame", f.base.vtable.type_name);
}

test "frame set label" {
    const f = try Frame.create(std.testing.allocator, "Old", .{});
    defer f.destroy(std.testing.allocator);
    f.setLabel("New Label");
    try std.testing.expectEqualStrings("New Label", f.label);
}
