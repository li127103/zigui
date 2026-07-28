//! Popover 控件 - 弹出气泡容器
//!
//! 类似 GtkPopover: 附着在某个控件上的气泡式弹出窗口, 带有指向关联控件的小三角。
//! 支持上下左右四个方向, 点击外部自动关闭。

const std = @import("std");
const math = @import("../math.zig");
const widget_mod = @import("widget.zig");
const layout_mod = @import("../layout/engine.zig");
const pal = @import("../pal/pal.zig");

const Widget = widget_mod.Widget;
const PaintContext = widget_mod.PaintContext;
const EventContext = widget_mod.EventContext;
const EventResult = widget_mod.EventResult;

pub const PopoverPosition = enum {
    top,
    bottom,
    left,
    right,
};

pub const Popover = struct {
    base: Widget,
    allocator: std.mem.Allocator,
    relative_to: ?*Widget = null,
    position: PopoverPosition = .bottom,
    is_open: bool = false,
    bg_color: math.Color = math.Color.hex(0x1E293BFF),
    corner_radius: f32 = 8,
    arrow_size: f32 = 8,
    /// 点击外部时是否自动关闭
    auto_close: bool = true,

    pub fn create(allocator: std.mem.Allocator, opts: struct {
        relative_to: ?*Widget = null,
        position: PopoverPosition = .bottom,
        bg_color: ?math.Color = null,
        corner_radius: f32 = 8,
        arrow_size: f32 = 8,
        auto_close: bool = true,
        width: layout_mod.Dimension = .{ .px = 200 },
        height: layout_mod.Dimension = .{ .auto = {} },
    }) !*Popover {
        const self = try allocator.create(Popover);
        self.* = .{
            .base = .{
                .vtable = &vtable,
                .id = widget_mod.genWidgetId(),
            },
            .allocator = allocator,
            .relative_to = opts.relative_to,
            .position = opts.position,
            .corner_radius = opts.corner_radius,
            .arrow_size = opts.arrow_size,
            .auto_close = opts.auto_close,
        };
        if (opts.bg_color) |c| self.bg_color = c;
        self.base.layout_style.width = opts.width;
        self.base.layout_style.height = opts.height;
        self.base.state.visible = false;
        self.base.accessibility = .{ .role = .dialog };
        return self;
    }

    pub fn destroy(self: *Popover, allocator: std.mem.Allocator) void {
        self.base.background.deinit(allocator);
        for (self.base.children.items) |child| {
            child.vtable.destroy(child, allocator);
        }
        self.base.children.deinit(allocator);
        allocator.destroy(self);
    }

    pub fn setRelativeTo(self: *Popover, widget: *Widget) void {
        self.relative_to = widget;
    }

    pub fn setPosition(self: *Popover, pos: PopoverPosition) void {
        self.position = pos;
        self.base.markDirty();
    }

    pub fn popup(self: *Popover) void {
        self.is_open = true;
        self.base.state.visible = true;
        self.updatePosition();
        self.base.markLayoutDirty();
        self.base.markDirty();
    }

    pub fn popdown(self: *Popover) void {
        self.is_open = false;
        self.base.state.visible = false;
        self.base.markDirty();
    }

    pub fn addChild(self: *Popover, child: *Widget) !void {
        try self.base.addChild(self.allocator, child);
    }

    fn updatePosition(self: *Popover) void {
        const rel = self.relative_to orelse return;
        const parent = self.base.parent orelse return;

        // 获取 relative_to 在父坐标系中的位置
        var rel_x = rel.rect.x;
        var rel_y = rel.rect.y;
        var current = rel.parent;
        while (current) |p| {
            if (p == parent) break;
            rel_x += p.rect.x;
            rel_y += p.rect.y;
            current = p.parent;
        }

        const rel_w = rel.rect.width;
        const rel_h = rel.rect.height;
        const pw = self.base.rect.width;
        const ph = self.base.rect.height;

        switch (self.position) {
            .bottom => {
                self.base.rect.x = rel_x + (rel_w - pw) / 2;
                self.base.rect.y = rel_y + rel_h + self.arrow_size;
            },
            .top => {
                self.base.rect.x = rel_x + (rel_w - pw) / 2;
                self.base.rect.y = rel_y - ph - self.arrow_size;
            },
            .right => {
                self.base.rect.x = rel_x + rel_w + self.arrow_size;
                self.base.rect.y = rel_y + (rel_h - ph) / 2;
            },
            .left => {
                self.base.rect.x = rel_x - pw - self.arrow_size;
                self.base.rect.y = rel_y + (rel_h - ph) / 2;
            },
        }
    }

    // ── VTable 实现 ──────────────────────────────────────────────────────────

    const vtable = Widget.VTable{
        .type_name = "popover",
        .measure = measure,
        .perform_layout = performLayout,
        .paint = paint,
        .on_event = onEvent,
        .focusable = true,
        .destroy = destroyVTable,
    };

    fn destroyVTable(w: *Widget, allocator: std.mem.Allocator) void {
        const self: *Popover = @fieldParentPtr("base", w);
        self.destroy(allocator);
    }

    fn measure(w: *Widget, ctx: *PaintContext, constraints: layout_mod.Constraints) math.Size(f32) {
        const self: *Popover = @fieldParentPtr("base", w);
        const children = self.base.children.items;
        const pad = w.layout_style.padding;
        const arrow_pad = self.arrow_size;

        if (children.len == 0) {
            return .{
                .width = pad.left + pad.right + arrow_pad * 2,
                .height = pad.top + pad.bottom + arrow_pad * 2,
            };
        }

        var max_w: f32 = 0;
        var max_h: f32 = 0;
        const inner_w = @max(0, constraints.max_width - pad.left - pad.right);
        const inner_h = @max(0, constraints.max_height - pad.top - pad.bottom);
        const inner_constraint = layout_mod.Constraints{
            .max_width = inner_w,
            .max_height = inner_h,
        };

        for (children) |child| {
            if (child.layout_style.position == .absolute) continue;
            const size = child.vtable.measure(child, ctx, inner_constraint);
            var cw = size.width;
            var ch = size.height;
            if (child.layout_style.width.resolve(inner_w)) |ew| cw = ew;
            if (child.layout_style.height.resolve(inner_h)) |eh| ch = eh;
            const cm = child.layout_style.margin;
            if (cw + cm.left + cm.right > max_w) max_w = cw + cm.left + cm.right;
            if (ch + cm.top + cm.bottom > max_h) max_h = ch + cm.top + cm.bottom;
        }

        return .{
            .width = max_w + pad.left + pad.right,
            .height = max_h + pad.top + pad.bottom,
        };
    }

    fn performLayout(w: *Widget, ctx: *PaintContext) void {
        const self: *Popover = @fieldParentPtr("base", w);
        const children = self.base.children.items;
        if (children.len == 0) return;

        const pad = w.layout_style.padding;
        const avail_w = @max(0, w.rect.width - pad.left - pad.right);
        const avail_h = @max(0, w.rect.height - pad.top - pad.bottom);

        for (children) |child| {
            if (child.layout_style.position == .absolute) continue;

            const cm = child.layout_style.margin;
            child.rect.x = pad.left + cm.left;
            child.rect.y = pad.top + cm.top;
            child.rect.width = @max(0, avail_w - cm.left - cm.right);
            child.rect.height = @max(0, avail_h - cm.top - cm.bottom);
            child.layoutSubtree(ctx);
        }
    }

    fn paint(w: *Widget, ctx: *PaintContext) void {
        const self: *Popover = @fieldParentPtr("base", w);
        const r = w.rect;
        const r2d = ctx.renderer;

        const x = ctx.offset_x + r.x;
        const y = ctx.offset_y + r.y;
        const w_ = r.width;
        const h_ = r.height;
        const s = self.arrow_size;

        // 气泡主体 (圆角矩形)
        var body_rect: math.Rect(f32) = undefined;
        switch (self.position) {
            .bottom => body_rect = .{ .x = x, .y = y + s, .width = w_, .height = h_ - s },
            .top => body_rect = .{ .x = x, .y = y, .width = w_, .height = h_ - s },
            .right => body_rect = .{ .x = x + s, .y = y, .width = w_ - s, .height = h_ },
            .left => body_rect = .{ .x = x, .y = y, .width = w_ - s, .height = h_ },
        }

        r2d.fillRoundedRect(body_rect, self.corner_radius, self.bg_color) catch {};

        // 箭头: 用一个小方块 (近似效果, 等路径填充 API 完善后改为三角形)
        const center_x = x + w_ / 2;
        const center_y = y + h_ / 2;
        const arrow_s = s * 0.8;

        switch (self.position) {
            .bottom => {
                r2d.fillRect(.{
                    .x = center_x - arrow_s / 2,
                    .y = y + s - arrow_s / 2,
                    .width = arrow_s,
                    .height = arrow_s,
                }, self.bg_color) catch {};
            },
            .top => {
                r2d.fillRect(.{
                    .x = center_x - arrow_s / 2,
                    .y = y + h_ - s - arrow_s / 2,
                    .width = arrow_s,
                    .height = arrow_s,
                }, self.bg_color) catch {};
            },
            .right => {
                r2d.fillRect(.{
                    .x = x + s - arrow_s / 2,
                    .y = center_y - arrow_s / 2,
                    .width = arrow_s,
                    .height = arrow_s,
                }, self.bg_color) catch {};
            },
            .left => {
                r2d.fillRect(.{
                    .x = x + w_ - s - arrow_s / 2,
                    .y = center_y - arrow_s / 2,
                    .width = arrow_s,
                    .height = arrow_s,
                }, self.bg_color) catch {};
            },
        }
    }

    fn onEvent(w: *Widget, event: *const pal.Event, ectx: *EventContext) EventResult {
        const self: *Popover = @fieldParentPtr("base", w);

        if (!self.is_open) return .ignored;

        // 先让子元素处理
        for (self.base.children.items) |child| {
            const result = child.dispatchEvent(event, ectx);
            if (result == .handled) return .handled;
        }

        switch (event.*) {
            .mouse_button => |mb| {
                if (self.auto_close) {
                    // 检查是否点击在 Popover 外面
                    const abs = w.absoluteRect();
                    const px = @as(f32, @floatFromInt(mb.x));
                    const py = @as(f32, @floatFromInt(mb.y));
                    if (px < abs.x or px > abs.x + w.rect.width or py < abs.y or py > abs.y + w.rect.height) {
                        self.popdown();
                        return .handled;
                    }
                }
                return .handled;
            },
            else => return .ignored,
        }
    }
};
