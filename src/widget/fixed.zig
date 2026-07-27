//! Fixed 控件 - 绝对定位容器
//!
//! 子控件通过 left/top/right/bottom 绝对定位, 不参与 flex 流。
//! 类似 GTK 的 GtkFixed。

const std = @import("std");
const math = @import("../math.zig");
const widget_mod = @import("widget.zig");

const Widget = widget_mod.Widget;
const PaintContext = widget_mod.PaintContext;

pub const Fixed = struct {
    base: Widget,
    allocator: std.mem.Allocator,

    pub fn create(allocator: std.mem.Allocator, opts: struct {
        bg_color: ?math.Color = null,
        corner_radius: f32 = 0,
    }) !*Fixed {
        const self = try allocator.create(Fixed);
        self.* = .{
            .base = .{
                .vtable = &vtable,
                .id = widget_mod.genWidgetId(),
            },
            .allocator = allocator,
        };
        if (opts.bg_color) |c| {
            self.base.background.bg = .{ .color = c };
        }
        self.base.background.corner_radius = opts.corner_radius;
        self.base.accessibility = .{ .role = .container };
        return self;
    }

    pub fn destroy(self: *Fixed, allocator: std.mem.Allocator) void {
        var i = self.base.children.items.len;
        while (i > 0) {
            i -= 1;
            const child = self.base.children.items[i];
            child.vtable.destroy(child, allocator);
        }
        self.base.background.deinit(allocator);
        self.base.children.deinit(allocator);
        allocator.destroy(self);
    }

    /// 添加绝对定位的子控件
    pub fn addChild(self: *Fixed, child: *Widget, opts: struct {
        left: ?f32 = null,
        top: ?f32 = null,
        right: ?f32 = null,
        bottom: ?f32 = null,
        width: ?f32 = null,
        height: ?f32 = null,
    }) !void {
        child.layout_style.position = .absolute;
        child.layout_style.left = opts.left;
        child.layout_style.top = opts.top;
        child.layout_style.right = opts.right;
        child.layout_style.bottom = opts.bottom;
        if (opts.width) |w| child.layout_style.width = .{ .px = w };
        if (opts.height) |h| child.layout_style.height = .{ .px = h };
        try self.base.addChild(self.allocator, child);
    }

    // ── VTable ──────────────────────────────────────────────────────────────

    const vtable = Widget.VTable{
        .type_name = "fixed",
        .measure = measure,
        .paint = paint,
        .on_event = null,
        .perform_layout = performLayout,
        .focusable = false,
        .destroy = destroyVTable,
    };

    fn destroyVTable(w: *Widget, allocator: std.mem.Allocator) void {
        const self: *Fixed = @fieldParentPtr("base", w);
        self.destroy(allocator);
    }

    fn measure(w: *Widget, ctx: *PaintContext, constraints: @import("../layout/engine.zig").Constraints) math.Size(f32) {
        const self: *Fixed = @fieldParentPtr("base", w);
        _ = self;

        var max_w: f32 = 0;
        var max_h: f32 = 0;

        for (w.children.items) |child| {
            if (!child.state.visible) continue;
            const child_size = child.vtable.measure(child, ctx, constraints);
            const cm = child.layout_style.margin;
            const right = (child.layout_style.left orelse 0) + child_size.width + cm.left + cm.right;
            const bottom = (child.layout_style.top orelse 0) + child_size.height + cm.top + cm.bottom;
            if (right > max_w) max_w = right;
            if (bottom > max_h) max_h = bottom;
        }

        return .{
            .width = @min(max_w, constraints.max_width),
            .height = @min(max_h, constraints.max_height),
        };
    }

    fn paint(w: *Widget, ctx: *PaintContext) void {
        _ = w;
        _ = ctx;
    }

    fn performLayout(w: *Widget, ctx: *PaintContext) void {
        const self: *Fixed = @fieldParentPtr("base", w);
        _ = self;

        for (w.children.items) |child| {
            if (!child.state.visible) continue;
            w.layoutAbsolute(child, ctx);
        }
    }
};
