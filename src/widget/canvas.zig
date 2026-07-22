//! Canvas 控件 - 自定义绘制载体
//!
//! 用于承载无法用 Label/Container 表达的复杂绘制 (代码高亮、动画曲线、
//! 进度条、列表内容等)。背景仍由框架通过 background 属性自动绘制,
//! paint_fn 仅负责背景之上的内容绘制。

const std = @import("std");
const math = @import("../math.zig");
const widget_mod = @import("widget.zig");
const layout_mod = @import("../layout/engine.zig");

const Widget = widget_mod.Widget;
const PaintContext = widget_mod.PaintContext;

/// 自定义绘制回调 (在框架绘制完背景后调用)
pub const PaintFn = *const fn (w: *Widget, ctx: *PaintContext) void;

pub const Canvas = struct {
    base: Widget,
    paint_fn: PaintFn,
    /// 固有内容尺寸 (measure 返回该尺寸)
    content_width: f32,
    content_height: f32,

    pub fn create(allocator: std.mem.Allocator, opts: struct {
        width: f32 = 0,
        height: f32 = 0,
        bg_color: ?math.Color = null,
        corner_radius: f32 = 0,
        paint_fn: PaintFn,
    }) !*Canvas {
        var bg: widget_mod.BackgroundStyle = .{ .corner_radius = opts.corner_radius };
        if (opts.bg_color) |c| {
            bg.bg = .{ .color = c };
        }

        const self = try allocator.create(Canvas);
        self.* = .{
            .base = .{
                .vtable = &vtable,
                .id = widget_mod.genWidgetId(),
            },
            .paint_fn = opts.paint_fn,
            .content_width = opts.width,
            .content_height = opts.height,
        };
        self.base.background = bg;
        self.base.layout_style.width = .{ .px = opts.width };
        self.base.layout_style.height = .{ .px = opts.height };
        return self;
    }

    pub fn destroy(self: *Canvas, allocator: std.mem.Allocator) void {
        self.base.background.deinit(allocator);
        // 递归销毁子项 (Canvas 一般无子项, 保险起见)
        for (self.base.children.items) |child| {
            child.vtable.destroy(child, allocator);
        }
        self.base.children.deinit(allocator);
        allocator.destroy(self);
    }

    /// 更新固有内容尺寸
    pub fn setSize(self: *Canvas, width: f32, height: f32) void {
        self.content_width = width;
        self.content_height = height;
        self.base.layout_style.width = .{ .px = width };
        self.base.layout_style.height = .{ .px = height };
        self.base.markLayoutDirty();
    }

    // ── VTable 实现 ──────────────────────────────────────────────────────────

    const vtable = Widget.VTable{
        .type_name = "canvas",
        .measure = measure,
        .paint = paint,
        .on_event = null,
        .focusable = false,
        .destroy = destroyVTable,
    };

    fn destroyVTable(w: *Widget, allocator: std.mem.Allocator) void {
        const self: *Canvas = @fieldParentPtr("base", w);
        self.destroy(allocator);
    }

    fn measure(w: *Widget, ctx: *PaintContext, constraints: layout_mod.Constraints) math.Size(f32) {
        const self: *Canvas = @fieldParentPtr("base", w);
        _ = ctx;
        _ = constraints;
        return .{ .width = self.content_width, .height = self.content_height };
    }

    fn paint(w: *Widget, ctx: *PaintContext) void {
        const self: *Canvas = @fieldParentPtr("base", w);
        self.paint_fn(w, ctx);
    }
};
