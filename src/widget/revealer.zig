//! Revealer 控件 - 可展开/收起的容器
//!
//! 支持从上下左右四个方向展开/收起子控件。
//! 类似 GTK 的 GtkRevealer。
//! 支持平滑过渡动画, 每帧调用 tick() 推进。

const std = @import("std");
const math = @import("../math.zig");
const widget_mod = @import("widget.zig");

const Widget = widget_mod.Widget;
const PaintContext = widget_mod.PaintContext;

pub const RevealerTransition = enum {
    none,
    slide_left,
    slide_right,
    slide_up,
    slide_down,
};

pub const Revealer = struct {
    base: Widget,
    allocator: std.mem.Allocator,
    reveal_child: bool,
    transition_type: RevealerTransition,
    transition_duration_ms: u32 = 250,
    progress: f32,
    target_progress: f32,

    pub fn create(allocator: std.mem.Allocator, opts: struct {
        transition_type: RevealerTransition = .slide_down,
        transition_duration_ms: u32 = 250,
        reveal_child: bool = false,
        bg_color: ?math.Color = null,
        corner_radius: f32 = 0,
    }) !*Revealer {
        const self = try allocator.create(Revealer);
        self.* = .{
            .base = .{
                .vtable = &vtable,
                .id = widget_mod.genWidgetId(),
            },
            .allocator = allocator,
            .reveal_child = opts.reveal_child,
            .transition_type = opts.transition_type,
            .transition_duration_ms = opts.transition_duration_ms,
            .progress = if (opts.reveal_child) 1.0 else 0.0,
            .target_progress = if (opts.reveal_child) 1.0 else 0.0,
        };
        if (opts.bg_color) |c| {
            self.base.background.bg = .{ .color = c };
        }
        self.base.background.corner_radius = opts.corner_radius;
        self.base.clip_children = .{ .x = 0, .y = 0, .width = 0, .height = 0 };
        self.base.accessibility = .{ .role = .container };
        return self;
    }

    pub fn destroy(self: *Revealer, allocator: std.mem.Allocator) void {
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

    pub fn setChild(self: *Revealer, child: *Widget) !void {
        try self.base.addChild(self.allocator, child);
    }

    pub fn setRevealChild(self: *Revealer, reveal: bool) void {
        if (self.reveal_child == reveal) return;
        self.reveal_child = reveal;
        self.target_progress = if (reveal) 1.0 else 0.0;
        self.base.markLayoutDirty();
        self.base.markDirty();
    }

    pub fn getRevealChild(self: *Revealer) bool {
        return self.reveal_child;
    }

    /// 推进展开/收起动画 (每帧调用, delta_ms 为帧间隔)
    pub fn tick(self: *Revealer, delta_ms: u32) void {
        if (self.progress == self.target_progress) return;
        if (self.transition_duration_ms == 0) {
            self.progress = self.target_progress;
            self.base.markLayoutDirty();
            self.base.markDirty();
            return;
        }

        const delta = @as(f32, @floatFromInt(delta_ms)) / @as(f32, @floatFromInt(self.transition_duration_ms));
        if (self.target_progress > self.progress) {
            self.progress = @min(1.0, self.progress + delta);
        } else {
            self.progress = @max(0.0, self.progress - delta);
        }

        // ease_out_cubic
        _ = self.easedProgress();

        self.base.markLayoutDirty();
        self.base.markDirty();
    }

    fn easedProgress(self: *const Revealer) f32 {
        const t = std.math.clamp(self.progress, 0.0, 1.0);
        return 1.0 - std.math.pow(f32, 1.0 - t, 3);
    }

    // ── VTable ──────────────────────────────────────────────────────────────

    const vtable = Widget.VTable{
        .type_name = "revealer",
        .measure = measure,
        .paint = paint,
        .on_event = null,
        .perform_layout = performLayout,
        .tick = tickVTable,
        .focusable = false,
        .destroy = destroyVTable,
    };

    fn destroyVTable(w: *Widget, allocator: std.mem.Allocator) void {
        const self: *Revealer = @fieldParentPtr("base", w);
        self.destroy(allocator);
    }

    fn tickVTable(w: *Widget, delta_ms: u32) void {
        const self: *Revealer = @fieldParentPtr("base", w);
        self.tick(delta_ms);
    }

    fn measure(w: *Widget, ctx: *PaintContext, constraints: @import("../layout/engine.zig").Constraints) math.Size(f32) {
        const self: *Revealer = @fieldParentPtr("base", w);

        var child_w: f32 = 0;
        var child_h: f32 = 0;

        for (w.children.items) |child| {
            if (!child.state.visible) continue;
            const child_size = child.vtable.measure(child, ctx, constraints);
            child_w = child_size.width;
            child_h = child_size.height;
            break;
        }

        const t = self.easedProgress();

        switch (self.transition_type) {
            .slide_left, .slide_right => {
                return .{ .width = child_w * t, .height = child_h };
            },
            .slide_up, .slide_down => {
                return .{ .width = child_w, .height = child_h * t };
            },
            .none => {
                return .{ .width = child_w, .height = child_h };
            },
        }
    }

    fn paint(w: *Widget, ctx: *PaintContext) void {
        _ = w;
        _ = ctx;
    }

    fn performLayout(w: *Widget, ctx: *PaintContext) void {
        const self: *Revealer = @fieldParentPtr("base", w);

        // 更新裁剪矩形为 Revealer 的可见区域 (绝对坐标)
        const t = self.easedProgress();
        if (t < 1.0 and w.children.items.len > 0) {
            const abs = w.absoluteRect();
            self.base.clip_children = math.Rect(f32){
                .x = abs.x,
                .y = abs.y,
                .width = w.rect.width,
                .height = w.rect.height,
            };
        } else {
            self.base.clip_children = null;
        }

        for (w.children.items) |child| {
            if (!child.state.visible) continue;
            if (child.layout_style.position == .absolute) {
                w.layoutAbsolute(child, ctx);
                continue;
            }

            const child_constraints = @import("../layout/engine.zig").Constraints{
                .max_width = w.rect.width,
                .max_height = w.rect.height,
            };
            const child_size = child.vtable.measure(child, ctx, child_constraints);

            // 根据过渡类型定位子元素
            var cx = w.rect.x;
            var cy = w.rect.y;

            switch (self.transition_type) {
                .slide_left => {
                    cx = w.rect.x - child_size.width * (1.0 - self.easedProgress());
                },
                .slide_right => {
                    cx = w.rect.x + w.rect.width - child_size.width * self.easedProgress();
                },
                .slide_up => {
                    cy = w.rect.y - child_size.height * (1.0 - self.easedProgress());
                },
                .slide_down => {
                    cy = w.rect.y + w.rect.height - child_size.height * self.easedProgress();
                },
                .none => {},
            }

            child.rect.x = cx;
            child.rect.y = cy;
            child.rect.width = child_size.width;
            child.rect.height = child_size.height;

            if (child.children.items.len > 0) {
                child.layoutSubtree(ctx);
            }
        }
    }
};
