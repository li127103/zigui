//! AspectFrame 控件 - 保持宽高比的容器
//!
//! 子控件按指定比例 (width/height) 缩放, 可配置对齐方式。
//! 类似 GTK 的 GtkAspectFrame。

const std = @import("std");
const math = @import("../math.zig");
const widget_mod = @import("widget.zig");
const layout_mod = @import("../layout/engine.zig");

const Widget = widget_mod.Widget;
const PaintContext = widget_mod.PaintContext;

pub const AspectFrame = struct {
    base: Widget,
    allocator: std.mem.Allocator,

    ratio: f32,

    xalign: f32,
    yalign: f32,

    obey_child: bool,

    pub fn create(allocator: std.mem.Allocator, opts: struct {
        ratio: f32 = 1.0,
        xalign: f32 = 0.5,
        yalign: f32 = 0.5,
        obey_child: bool = false,
        padding: math.EdgeInsets = .{},
        bg_color: ?math.Color = null,
        corner_radius: f32 = 0,
        width: layout_mod.Dimension = .{ .auto = {} },
        height: layout_mod.Dimension = .{ .auto = {} },
    }) !*AspectFrame {
        const self = try allocator.create(AspectFrame);
        self.* = .{
            .base = .{
                .vtable = &vtable,
                .id = widget_mod.genWidgetId(),
            },
            .allocator = allocator,
            .ratio = opts.ratio,
            .xalign = std.math.clamp(opts.xalign, 0.0, 1.0),
            .yalign = std.math.clamp(opts.yalign, 0.0, 1.0),
            .obey_child = opts.obey_child,
        };
        if (opts.bg_color) |c| {
            self.base.background.bg = .{ .color = c };
        }
        self.base.background.corner_radius = opts.corner_radius;
        self.base.layout_style.padding = opts.padding;
        self.base.layout_style.width = opts.width;
        self.base.layout_style.height = opts.height;
        self.base.accessibility = .{ .role = .container };
        return self;
    }

    pub fn destroy(self: *AspectFrame, allocator: std.mem.Allocator) void {
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

    pub fn setChild(self: *AspectFrame, child: *Widget) !void {
        while (self.base.children.items.len > 0) {
            _ = self.base.children.pop();
        }
        try self.base.addChild(self.allocator, child);
    }

    pub fn setRatio(self: *AspectFrame, ratio: f32) void {
        self.ratio = ratio;
        self.base.markLayoutDirty();
    }

    pub fn setAlign(self: *AspectFrame, xalign: f32, yalign: f32) void {
        self.xalign = std.math.clamp(xalign, 0.0, 1.0);
        self.yalign = std.math.clamp(yalign, 0.0, 1.0);
        self.base.markLayoutDirty();
    }

    pub fn setObeyChild(self: *AspectFrame, obey: bool) void {
        self.obey_child = obey;
        self.base.markLayoutDirty();
    }

    fn effectiveRatio(self: *AspectFrame, ctx: *PaintContext) f32 {
        if (!self.obey_child) return self.ratio;

        for (self.base.children.items) |child| {
            if (!child.state.visible) continue;
            const child_constraints = layout_mod.Constraints{
                .max_width = std.math.inf(f32),
                .max_height = std.math.inf(f32),
            };
            const child_size = child.vtable.measure(child, ctx, child_constraints);
            if (child_size.height > 0) {
                return child_size.width / child_size.height;
            }
            break;
        }
        return self.ratio;
    }

    // ── VTable ──────────────────────────────────────────────────────────────

    const vtable = Widget.VTable{
        .type_name = "aspect_frame",
        .measure = measure,
        .paint = paint,
        .on_event = null,
        .perform_layout = performLayout,
        .focusable = false,
        .destroy = destroyVTable,
    };

    fn destroyVTable(w: *Widget, allocator: std.mem.Allocator) void {
        const self: *AspectFrame = @fieldParentPtr("base", w);
        self.destroy(allocator);
    }

    fn measure(w: *Widget, ctx: *PaintContext, constraints: layout_mod.Constraints) math.Size(f32) {
        const self: *AspectFrame = @fieldParentPtr("base", w);
        const pad = w.layout_style.padding;

        const avail_w = constraints.max_width - pad.left - pad.right;
        const avail_h = constraints.max_height - pad.top - pad.bottom;

        const r = self.effectiveRatio(ctx);

        var child_w: f32 = 0;
        var child_h: f32 = 0;

        for (w.children.items) |child| {
            if (!child.state.visible) continue;
            const child_size = child.vtable.measure(child, ctx, constraints);
            child_w = child_size.width;
            child_h = child_size.height;
            break;
        }

        var content_w: f32 = 0;
        var content_h: f32 = 0;

        if (child_w > 0 and child_h > 0) {
            const child_ratio = child_w / child_h;

            if (child_ratio > r) {
                content_w = @min(avail_w, child_w);
                content_h = content_w / r;
            } else {
                content_h = @min(avail_h, child_h);
                content_w = content_h * r;
            }
        } else {
            content_w = @min(avail_w, r * avail_h);
            content_h = @min(avail_h, avail_w / r);
        }

        return .{
            .width = content_w + pad.left + pad.right,
            .height = content_h + pad.top + pad.bottom,
        };
    }

    fn paint(w: *Widget, ctx: *PaintContext) void {
        _ = w;
        _ = ctx;
    }

    fn performLayout(w: *Widget, ctx: *PaintContext) void {
        const self: *AspectFrame = @fieldParentPtr("base", w);
        const pad = w.layout_style.padding;

        const inner_w = w.rect.width - pad.left - pad.right;
        const inner_h = w.rect.height - pad.top - pad.bottom;

        const r = self.effectiveRatio(ctx);

        var child_w: f32 = inner_w;
        var child_h: f32 = inner_w / r;

        if (child_h > inner_h) {
            child_h = inner_h;
            child_w = inner_h * r;
        }

        const offset_x = pad.left + (inner_w - child_w) * self.xalign;
        const offset_y = pad.top + (inner_h - child_h) * self.yalign;

        for (w.children.items) |child| {
            if (!child.state.visible) continue;
            if (child.layout_style.position == .absolute) {
                w.layoutAbsolute(child, ctx);
                continue;
            }

            child.rect.x = w.rect.x + offset_x;
            child.rect.y = w.rect.y + offset_y;
            child.rect.width = child_w;
            child.rect.height = child_h;

            if (child.children.items.len > 0) {
                child.layoutSubtree(ctx);
            }
        }
    }
};
