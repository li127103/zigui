//! StackSwitcher 控件 - Stack 页面切换器
//!
//! 类似 GtkStackSwitcher: 一排按钮, 点击切换关联 Stack 的当前页面。

const std = @import("std");
const math = @import("../math.zig");
const widget_mod = @import("widget.zig");
const layout_mod = @import("../layout/engine.zig");
const pal = @import("../pal/pal.zig");
const stack_mod = @import("stack.zig");

const Widget = widget_mod.Widget;
const PaintContext = widget_mod.PaintContext;
const EventContext = widget_mod.EventContext;
const EventResult = widget_mod.EventResult;

pub const StackSwitcher = struct {
    base: Widget,
    allocator: std.mem.Allocator,
    stack: ?*stack_mod.Stack = null,
    labels: std.ArrayListUnmanaged([]const u8) = .{ .items = &.{}, .capacity = 0 },
    hover_index: ?usize = null,
    bar_color: math.Color = math.Color.hex(0x1E293BFF),
    active_color: math.Color = math.Color.hex(0x3B82F6FF),
    hover_color: math.Color = math.Color.hex(0x334155FF),
    text_color: math.Color = math.Color.hex(0xF8FAFCFF),
    button_spacing: f32 = 2,

    pub fn create(allocator: std.mem.Allocator, opts: struct {
        stack: ?*stack_mod.Stack = null,
        bar_color: ?math.Color = null,
        active_color: ?math.Color = null,
        text_color: ?math.Color = null,
        height: f32 = 40,
    }) !*StackSwitcher {
        const self = try allocator.create(StackSwitcher);
        self.* = .{
            .base = .{
                .vtable = &vtable,
                .id = widget_mod.genWidgetId(),
            },
            .allocator = allocator,
            .stack = opts.stack,
        };
        if (opts.bar_color) |c| self.bar_color = c;
        if (opts.active_color) |c| self.active_color = c;
        if (opts.text_color) |c| self.text_color = c;
        self.base.rect.height = opts.height;
        self.base.accessibility = .{ .role = .button };
        return self;
    }

    pub fn destroy(self: *StackSwitcher, allocator: std.mem.Allocator) void {
        for (self.labels.items) |label| {
            allocator.free(label);
        }
        self.labels.deinit(allocator);
        self.base.background.deinit(allocator);
        self.base.children.deinit(allocator);
        allocator.destroy(self);
    }

    /// 关联 Stack
    pub fn setStack(self: *StackSwitcher, stack: *stack_mod.Stack) void {
        self.stack = stack;
        self.base.markLayoutDirty();
        self.base.markDirty();
    }

    /// 添加页面标签
    pub fn addPageLabel(self: *StackSwitcher, label: []const u8) !void {
        const dup = try self.allocator.dupe(u8, label);
        try self.labels.append(self.allocator, dup);
        self.base.markLayoutDirty();
        self.base.markDirty();
    }

    fn buttonWidth(self: *const StackSwitcher) f32 {
        const n = @max(1, self.labels.items.len);
        const total_spacing = self.button_spacing * @as(f32, @floatFromInt(n - 1));
        return @max(0, (self.base.rect.width - total_spacing) / @as(f32, @floatFromInt(n)));
    }

    fn indexAt(self: *const StackSwitcher, x: f32) ?usize {
        const n = self.labels.items.len;
        if (n == 0) return null;
        const bw = self.buttonWidth();
        const idx: usize = @intFromFloat(@floor(x / (bw + self.button_spacing)));
        if (idx >= n) return null;
        const bx = @as(f32, @floatFromInt(idx)) * (bw + self.button_spacing);
        if (x >= bx and x < bx + bw) return idx;
        return null;
    }

    // ── VTable 实现 ──────────────────────────────────────────────────────────

    const vtable = Widget.VTable{
        .type_name = "stack_switcher",
        .measure = measure,
        .paint = paint,
        .on_event = onEvent,
        .focusable = false,
        .destroy = destroyVTable,
    };

    fn destroyVTable(w: *Widget, allocator: std.mem.Allocator) void {
        const self: *StackSwitcher = @fieldParentPtr("base", w);
        self.destroy(allocator);
    }

    fn measure(w: *Widget, ctx: *PaintContext, constraints: layout_mod.Constraints) math.Size(f32) {
        const self: *StackSwitcher = @fieldParentPtr("base", w);
        _ = ctx;

        const n = self.labels.items.len;
        const min_w = 60.0 * @as(f32, @floatFromInt(@max(1, n)));
        const h = w.rect.height;
        return .{
            .width = @max(min_w, @min(constraints.max_width, min_w)),
            .height = h,
        };
    }

    fn paint(w: *Widget, ctx: *PaintContext) void {
        const self: *StackSwitcher = @fieldParentPtr("base", w);
        const r = w.rect;

        const styled_text = @import("../text/styled_text.zig");

        // 背景条
        ctx.renderer.fillRoundedRect(
            .{ .x = ctx.offset_x + r.x, .y = ctx.offset_y + r.y, .width = r.width, .height = r.height },
            6,
            self.bar_color,
        ) catch {};

        const n = self.labels.items.len;
        if (n == 0) return;

        const bw = self.buttonWidth();
        const active_idx = if (self.stack) |s| s.getVisibleIndex() else 0;

        for (self.labels.items, 0..) |label, i| {
            const bx = r.x + @as(f32, @floatFromInt(i)) * (bw + self.button_spacing);
            const by = r.y;

            // 激活态背景
            if (i == active_idx) {
                ctx.renderer.fillRoundedRect(
                    .{ .x = ctx.offset_x + bx + 2, .y = ctx.offset_y + by + 2, .width = bw - 4, .height = r.height - 4 },
                    4,
                    self.active_color,
                ) catch {};
            } else if (self.hover_index == i) {
                ctx.renderer.fillRoundedRect(
                    .{ .x = ctx.offset_x + bx + 2, .y = ctx.offset_y + by + 2, .width = bw - 4, .height = r.height - 4 },
                    4,
                    self.hover_color,
                ) catch {};
            }

            // 文字 (居中)
            const text_size = styled_text.measureText(ctx.allocator, label, .{
                .font_size = 14,
                .font_weight = 500,
            });
            const tx = bx + (bw - text_size.width) / 2;
            const ty = by + (r.height - text_size.height) / 2;

            styled_text.drawText(
                ctx.renderer,
                ctx.allocator,
                label,
                ctx.offset_x + tx,
                ctx.offset_y + ty,
                .{
                    .font_size = 14,
                    .font_weight = 500,
                    .color = self.text_color,
                    .text_align = .center,
                    .max_width = bw,
                },
            );
        }
    }

    fn onEvent(w: *Widget, event: *const pal.Event, ectx: *EventContext) EventResult {
        const self: *StackSwitcher = @fieldParentPtr("base", w);
        _ = ectx;

        switch (event.*) {
            .mouse_move => |ev| {
                const local_x: f32 = @as(f32, @floatFromInt(ev.x)) - w.rect.x;
                const local_y: f32 = @as(f32, @floatFromInt(ev.y)) - w.rect.y;
                if (local_x >= 0 and local_x < w.rect.width and local_y >= 0 and local_y < w.rect.height) {
                    const idx = self.indexAt(local_x);
                    if (idx != self.hover_index) {
                        self.hover_index = idx;
                        self.base.markDirty();
                    }
                    return .handled;
                } else {
                    if (self.hover_index != null) {
                        self.hover_index = null;
                        self.base.markDirty();
                    }
                    return .ignored;
                }
            },
            .mouse_button => |ev| {
                if (ev.button != .left) return .ignored;
                const local_x: f32 = @as(f32, @floatFromInt(ev.x)) - w.rect.x;
                const local_y: f32 = @as(f32, @floatFromInt(ev.y)) - w.rect.y;
                if (local_x >= 0 and local_x < w.rect.width and local_y >= 0 and local_y < w.rect.height) {
                    if (self.indexAt(local_x)) |idx| {
                        if (self.stack) |s| {
                            s.setVisibleIndex(idx);
                        }
                        self.base.markDirty();
                        return .handled;
                    }
                }
                return .ignored;
            },
            else => return .ignored,
        }
    }
};
