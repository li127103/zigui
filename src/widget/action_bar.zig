//! ActionBar 控件 - 操作栏容器
//!
//! 类似 GtkActionBar: 底部操作栏, 子元素水平排列, 可通过 packStart/packEnd 添加到两端。

const std = @import("std");
const math = @import("../math.zig");
const widget_mod = @import("widget.zig");
const layout_mod = @import("../layout/engine.zig");

const Widget = widget_mod.Widget;
const PaintContext = widget_mod.PaintContext;

pub const ActionBar = struct {
    base: Widget,
    allocator: std.mem.Allocator,

    pub fn create(allocator: std.mem.Allocator, opts: struct {
        bg_color: ?math.Color = null,
        height: f32 = 48,
        spacing: f32 = 8,
        padding: f32 = 12,
    }) !*ActionBar {
        const self = try allocator.create(ActionBar);
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
        self.base.layout_style.direction = .row;
        self.base.layout_style.justify_content = .space_between;
        self.base.layout_style.align_items = .center;
        self.base.layout_style.gap = .{ .width = opts.spacing, .height = 0 };
        self.base.layout_style.padding = .{
            .top = opts.padding,
            .bottom = opts.padding,
            .left = opts.padding,
            .right = opts.padding,
        };
        self.base.rect.height = opts.height;
        self.base.layout_style.height = .{ .px = opts.height };
        self.base.accessibility = .{ .role = .container, .label = "action bar" };
        return self;
    }

    pub fn destroy(self: *ActionBar, allocator: std.mem.Allocator) void {
        self.base.background.deinit(allocator);
        for (self.base.children.items) |child| {
            child.vtable.destroy(child, allocator);
        }
        self.base.children.deinit(allocator);
        allocator.destroy(self);
    }

    pub fn addChild(self: *ActionBar, child: *Widget) !void {
        try self.base.addChild(self.allocator, child);
    }

    // ── VTable 实现 ──────────────────────────────────────────────────────────

    const vtable = Widget.VTable{
        .type_name = "action_bar",
        .measure = measure,
        .paint = paint,
        .on_event = null,
        .focusable = false,
        .destroy = destroyVTable,
    };

    fn destroyVTable(w: *Widget, allocator: std.mem.Allocator) void {
        const self: *ActionBar = @fieldParentPtr("base", w);
        self.destroy(allocator);
    }

    fn measure(w: *Widget, ctx: *PaintContext, constraints: layout_mod.Constraints) math.Size(f32) {
        _ = ctx;
        return .{
            .width = constraints.max_width,
            .height = w.rect.height,
        };
    }

    fn paint(w: *Widget, ctx: *PaintContext) void {
        _ = w;
        _ = ctx;
    }
};
