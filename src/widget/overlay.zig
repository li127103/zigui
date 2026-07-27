//! Overlay 控件 - 叠加层布局容器
//!
//! 类似 GtkOverlay: 第一个子控件为主内容, 后续子控件叠加在其上。
//! 叠加子控件可通过 layout_style 的 top/right/bottom/left/position:absolute
//! 进行定位, 支持浮动按钮、加载遮罩、Toast 提示等场景。

const std = @import("std");
const math = @import("../math.zig");
const widget_mod = @import("widget.zig");
const layout_mod = @import("../layout/engine.zig");
const pal = @import("../pal/pal.zig");

const Widget = widget_mod.Widget;
const PaintContext = widget_mod.PaintContext;

pub const Overlay = struct {
    base: Widget,
    allocator: std.mem.Allocator,

    pub fn create(allocator: std.mem.Allocator, opts: struct {
        bg_color: ?math.Color = null,
        corner_radius: f32 = 0,
        width: layout_mod.Dimension = .{ .auto = {} },
        height: layout_mod.Dimension = .{ .auto = {} },
    }) !*Overlay {
        const self = try allocator.create(Overlay);
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
        self.base.layout_style.width = opts.width;
        self.base.layout_style.height = opts.height;
        self.base.accessibility = .{ .role = .container };
        return self;
    }

    pub fn destroy(self: *Overlay, allocator: std.mem.Allocator) void {
        self.base.background.deinit(allocator);
        for (self.base.children.items) |child| {
            child.vtable.destroy(child, allocator);
        }
        self.base.children.deinit(allocator);
        allocator.destroy(self);
    }

    /// 添加子控件 (第一个为主内容, 后续为叠加层)
    pub fn addChild(self: *Overlay, child: *Widget) !void {
        try self.base.addChild(self.allocator, child);
    }

    /// 设置主内容 (第一个子控件)
    pub fn setChild(self: *Overlay, child: *Widget) !void {
        while (self.base.children.items.len > 0) {
            _ = self.base.children.pop();
        }
        try self.base.addChild(self.allocator, child);
    }

    /// 添加叠加层
    pub fn addOverlay(self: *Overlay, child: *Widget) !void {
        child.layout_style.position = .absolute;
        try self.base.addChild(self.allocator, child);
    }

    // ── VTable 实现 ──────────────────────────────────────────────────────────

    const vtable = Widget.VTable{
        .type_name = "overlay",
        .measure = measure,
        .perform_layout = performLayout,
        .paint = paint,
        .on_event = onEvent,
        .focusable = false,
        .destroy = destroyVTable,
    };

    fn destroyVTable(w: *Widget, allocator: std.mem.Allocator) void {
        const self: *Overlay = @fieldParentPtr("base", w);
        self.destroy(allocator);
    }

    fn measure(w: *Widget, ctx: *PaintContext, constraints: layout_mod.Constraints) math.Size(f32) {
        const self: *Overlay = @fieldParentPtr("base", w);
        const children = self.base.children.items;
        const pad = w.layout_style.padding;
        if (children.len == 0) {
            return .{ .width = pad.left + pad.right, .height = pad.top + pad.bottom };
        }

        const inner_w = @max(0, constraints.max_width - pad.left - pad.right);
        const inner_h = @max(0, constraints.max_height - pad.top - pad.bottom);
        const inner_constraints = layout_mod.Constraints{
            .max_width = inner_w,
            .max_height = inner_h,
        };

        const main_child = children[0];
        var main_w: f32 = 0;
        var main_h: f32 = 0;
        if (main_child.state.visible and main_child.layout_style.position != .absolute) {
            const main_size = main_child.vtable.measure(main_child, ctx, inner_constraints);
            var cw = main_size.width;
            var ch = main_size.height;
            if (main_child.layout_style.width.resolve(inner_w)) |ew| cw = ew;
            if (main_child.layout_style.height.resolve(inner_h)) |eh| ch = eh;
            const cm = main_child.layout_style.margin;
            main_w = cw + cm.left + cm.right;
            main_h = ch + cm.top + cm.bottom;
        }

        var max_w = main_w;
        var max_h = main_h;

        for (children[1..]) |child| {
            if (!child.state.visible) continue;
            if (child.layout_style.position == .absolute) continue;
            const size = child.vtable.measure(child, ctx, inner_constraints);
            var cw = size.width;
            var ch = size.height;
            if (child.layout_style.width.resolve(inner_w)) |ew| cw = ew;
            if (child.layout_style.height.resolve(inner_h)) |eh| ch = eh;
            const cm = child.layout_style.margin;
            if (cw + cm.left + cm.right > max_w) max_w = cw + cm.left + cm.right;
            if (ch + cm.top + cm.bottom > max_h) max_h = ch + cm.top + cm.bottom;
        }

        return .{
            .width = @min(max_w + pad.left + pad.right, constraints.max_width),
            .height = @min(max_h + pad.top + pad.bottom, constraints.max_height),
        };
    }

    fn performLayout(w: *Widget, ctx: *PaintContext) void {
        const self: *Overlay = @fieldParentPtr("base", w);
        const children = self.base.children.items;
        if (children.len == 0) return;

        const pad = w.layout_style.padding;
        const avail_w = @max(0, w.rect.width - pad.left - pad.right);
        const avail_h = @max(0, w.rect.height - pad.top - pad.bottom);

        const main = children[0];
        if (main.state.visible and main.layout_style.position != .absolute) {
            const cm = main.layout_style.margin;
            const avail_main_w = @max(0, avail_w - cm.left - cm.right);
            const avail_main_h = @max(0, avail_h - cm.top - cm.bottom);
            const size = main.vtable.measure(main, ctx, .{
                .max_width = avail_main_w,
                .max_height = avail_main_h,
            });
            var cw = size.width;
            var ch = size.height;
            if (main.layout_style.width.resolve(avail_main_w)) |ew| {
                cw = ew;
            } else {
                cw = avail_main_w;
            }
            if (main.layout_style.height.resolve(avail_main_h)) |eh| {
                ch = eh;
            } else {
                ch = avail_main_h;
            }
            main.rect.x = pad.left + cm.left;
            main.rect.y = pad.top + cm.top;
            main.rect.width = cw;
            main.rect.height = ch;
            main.layoutSubtree(ctx);
        }

        for (children[1..]) |child| {
            if (!child.state.visible) continue;

            const size = child.vtable.measure(child, ctx, .{
                .max_width = avail_w,
                .max_height = avail_h,
            });

            const style = child.layout_style;
            const cm = child.layout_style.margin;

            var child_w = size.width;
            var child_h = size.height;
            if (style.width.resolve(avail_w)) |ew| child_w = ew;
            if (style.height.resolve(avail_h)) |eh| child_h = eh;

            var x: f32 = pad.left + cm.left;
            var y: f32 = pad.top + cm.top;

            if (style.left) |l| x = pad.left + l + cm.left;
            if (style.top) |t| y = pad.top + t + cm.top;
            if (style.right) |r| x = pad.left + avail_w - child_w - r - cm.right;
            if (style.bottom) |b| y = pad.top + avail_h - child_h - b - cm.bottom;

            if (style.left != null and style.right != null) {
                child_w = @max(0, avail_w - style.left.? - style.right.? - cm.left - cm.right);
            }
            if (style.top != null and style.bottom != null) {
                child_h = @max(0, avail_h - style.top.? - style.bottom.? - cm.top - cm.bottom);
            }

            child.rect.x = x;
            child.rect.y = y;
            child.rect.width = child_w;
            child.rect.height = child_h;
            child.layoutSubtree(ctx);
        }
    }

    fn paint(w: *Widget, ctx: *PaintContext) void {
        _ = w;
        _ = ctx;
    }

    fn onEvent(w: *Widget, event: *const pal.Event, ectx: *widget_mod.EventContext) widget_mod.EventResult {
        const self: *Overlay = @fieldParentPtr("base", w);
        const children = self.base.children.items;
        var i = children.len;
        while (i > 0) {
            i -= 1;
            const child = children[i];
            if (!child.state.visible) continue;
            const result = child.dispatchEvent(event, ectx);
            if (result == .handled) return .handled;
        }
        return .ignored;
    }
};

// ── Tests ──────────────────────────────────────────────────────────────────

test "overlay create" {
    const o = try Overlay.create(std.testing.allocator, .{});
    defer o.destroy(std.testing.allocator);
    try std.testing.expectEqualStrings("overlay", o.base.vtable.type_name);
}
