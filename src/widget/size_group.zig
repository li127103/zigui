//! SizeGroup 尺寸分组
//!
//! 类似 GtkSizeGroup: 将多个控件分为一组, 使它们具有相同的宽度或高度。
//! 支持 horizontal (统一宽度)、vertical (统一高度)、both (统一宽高) 三种模式。
//!
//! 使用方式:
//!   1. 创建 SizeGroup
//!   2. 添加 widget 到组中
//!   3. 在容器 measure 之前调用 sizeGroup.apply(ctx)
//!
//! SizeGroup 通过设置 widget 的 min_width/min_height 来实现统一尺寸。

const std = @import("std");
const math = @import("../math.zig");
const widget_mod = @import("widget.zig");
const layout_mod = @import("../layout/engine.zig");

const Widget = widget_mod.Widget;
const PaintContext = widget_mod.PaintContext;

pub const SizeGroupMode = enum {
    horizontal,
    vertical,
    both,
};

pub const SizeGroup = struct {
    allocator: std.mem.Allocator,
    mode: SizeGroupMode,
    widgets: std.ArrayListUnmanaged(*Widget) = .{ .items = &.{}, .capacity = 0 },

    pub fn create(allocator: std.mem.Allocator, mode: SizeGroupMode) !*SizeGroup {
        const self = try allocator.create(SizeGroup);
        self.* = .{
            .allocator = allocator,
            .mode = mode,
        };
        return self;
    }

    pub fn destroy(self: *SizeGroup) void {
        self.widgets.deinit(self.allocator);
        self.allocator.destroy(self);
    }

    pub fn setMode(self: *SizeGroup, mode: SizeGroupMode) void {
        self.mode = mode;
    }

    pub fn addWidget(self: *SizeGroup, widget: *Widget) !void {
        try self.widgets.append(self.allocator, widget);
    }

    pub fn removeWidget(self: *SizeGroup, widget: *Widget) void {
        for (self.widgets.items, 0..) |w, i| {
            if (w == widget) {
                _ = self.widgets.orderedRemove(i);
                break;
            }
        }
    }

    /// 应用尺寸分组: 测量组内所有 widget, 取最大值设置为 min_width/min_height
    /// 调用方应在容器 measure 之前调用此方法
    pub fn apply(self: *SizeGroup, ctx: *PaintContext, constraints: layout_mod.Constraints) void {
        if (self.widgets.items.len == 0) return;

        var max_w: f32 = 0;
        var max_h: f32 = 0;

        // 第一轮: 测量所有 widget, 找到最大尺寸
        for (self.widgets.items) |w| {
            const size = w.vtable.measure(w, ctx, constraints);
            var cw = size.width;
            var ch = size.height;

            if (w.layout_style.width.resolve(constraints.max_width)) |ew| cw = ew;
            if (w.layout_style.height.resolve(constraints.max_height)) |eh| ch = eh;

            const cm = w.layout_style.margin;
            const total_w = cw + cm.left + cm.right;
            const total_h = ch + cm.top + cm.bottom;

            if (total_w > max_w) max_w = total_w;
            if (total_h > max_h) max_h = total_h;
        }

        // 第二轮: 将最大尺寸应用为 min_width/min_height
        for (self.widgets.items) |w| {
            const cm = w.layout_style.margin;

            if (self.mode == .horizontal or self.mode == .both) {
                const inner_min_w = @max(0, max_w - cm.left - cm.right);
                w.layout_style.min_width = .{ .px = inner_min_w };
            }

            if (self.mode == .vertical or self.mode == .both) {
                const inner_min_h = @max(0, max_h - cm.top - cm.bottom);
                w.layout_style.min_height = .{ .px = inner_min_h };
            }
        }
    }

    /// 清除尺寸分组的效果 (恢复 min_width/min_height 为 auto)
    pub fn reset(self: *SizeGroup) void {
        for (self.widgets.items) |w| {
            if (self.mode == .horizontal or self.mode == .both) {
                w.layout_style.min_width = .{ .auto = {} };
            }
            if (self.mode == .vertical or self.mode == .both) {
                w.layout_style.min_height = .{ .auto = {} };
            }
        }
    }
};
