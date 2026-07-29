//! Statusbar 控件 - 状态栏
//!
//! 窗口底部的状态栏，用于显示状态信息，支持多个区域（栈）。
//!
//! 使用方法:
//! ```
//! var sb = try Statusbar.create(allocator, .{});
//! sb.push("就绪", null);
//! sb.pop(null);
//! ```

const std = @import("std");
const math = @import("../math.zig");
const widget_mod = @import("widget.zig");
const container_mod = @import("container.zig");
const label_mod = @import("label.zig");
const separator_mod = @import("separator.zig");
const layout_mod = @import("../layout/engine.zig");

const Widget = widget_mod.Widget;
const PaintContext = widget_mod.PaintContext;
const EventContext = widget_mod.EventContext;
const EventResult = widget_mod.EventResult;

const Container = container_mod.Container;
const Label = label_mod.Label;
const Separator = separator_mod.Separator;

const StatusItem = struct {
    text: []const u8,
    context_id: ?u32 = null,
};

pub const Statusbar = struct {
    base: Widget,
    allocator: std.mem.Allocator,

    items: std.ArrayListUnmanaged(StatusItem) = .{ .items = &.{}, .capacity = 0 },
    content_container: ?*Container = null,
    status_label: ?*Label = null,

    bg_color: math.Color = math.Color.hex(0x1E293BFF),
    text_color: math.Color = math.Color.hex(0x94A3B8FF),
    border_color: math.Color = math.Color.hex(0x334155FF),
    border_top: f32 = 1.0,
    height: f32 = 28.0,
    padding: f32 = 12.0,
    font_size: f32 = 12.0,

    const Self = @This();

    pub fn create(allocator: std.mem.Allocator, opts: struct {
        bg_color: ?math.Color = null,
        text_color: ?math.Color = null,
        height: f32 = 28.0,
        font_size: f32 = 12.0,
        initial_text: []const u8 = "",
        text: []const u8 = "",
    }) !*Statusbar {
        const self = try allocator.create(Statusbar);
        const actual_text = if (opts.text.len > 0) opts.text else opts.initial_text;
        self.* = .{
            .base = .{
                .vtable = &vtable,
                .id = widget_mod.genWidgetId(),
            },
            .allocator = allocator,
            .bg_color = opts.bg_color orelse self.bg_color,
            .text_color = opts.text_color orelse self.text_color,
            .height = opts.height,
            .font_size = opts.font_size,
        };
        try self.buildUI(actual_text);
        return self;
    }

    pub fn destroy(self: *Self, allocator: std.mem.Allocator) void {
        for (self.items.items) |*item| {
            allocator.free(item.text);
        }
        self.items.deinit(allocator);
        self.base.background.deinit(allocator);
        if (self.content_container) |cc| {
            cc.base.vtable.destroy(&cc.base, allocator);
        }
        self.base.children.deinit(allocator);
        allocator.destroy(self);
    }

    fn buildUI(self: *Self, initial_text: []const u8) !void {
        const alloc = self.allocator;

        const content = try Container.create(alloc, .{
            .direction = .row,
            .bg_color = self.bg_color,
            .padding = .{ .left = self.padding, .right = self.padding, .top = 4, .bottom = 4 },
            .gap = .{ .width = 8, .height = 0 },
        });
        self.content_container = content;
        try self.base.addChild(alloc, &content.base);

        const sep = try Separator.create(alloc, .{ .orientation = .vertical });
        try content.base.addChild(alloc, &sep.base);

        const label = try Label.create(alloc, initial_text, .{
            .font_size = self.font_size,
            .color = self.text_color,
        });
        label.base.layout_style.flex_grow = 1;
        try content.base.addChild(alloc, &label.base);
        self.status_label = label;
    }

    pub fn push(self: *Self, text: []const u8, context_id: ?u32) void {
        const owned = self.allocator.dupe(u8, text) catch return;
        self.items.append(self.allocator, .{
            .text = owned,
            .context_id = context_id,
        }) catch {
            self.allocator.free(owned);
            return;
        };
        self.updateLabel();
    }

    pub fn pop(self: *Self, context_id: ?u32) void {
        if (self.items.items.len == 0) return;

        if (context_id) |cid| {
            var i = self.items.items.len;
            while (i > 0) {
                i -= 1;
                if (self.items.items[i].context_id == cid) {
                    self.allocator.free(self.items.items[i].text);
                    _ = self.items.orderedRemove(i);
                    self.updateLabel();
                    return;
                }
            }
        } else {
            const last = self.items.pop();
            self.allocator.free(last.text);
            self.updateLabel();
        }
    }

    pub fn setText(self: *Self, text: []const u8) void {
        if (self.status_label) |lbl| {
            lbl.setText(text);
        }
        self.base.markDirty();
    }

    pub fn getText(self: *const Self) []const u8 {
        if (self.items.items.len > 0) {
            return self.items.items[self.items.items.len - 1].text;
        }
        return "";
    }

    fn updateLabel(self: *Self) void {
        if (self.status_label) |lbl| {
            const text = self.getText();
            lbl.setText(text) catch {};
        }
        self.base.markDirty();
    }

    // ── VTable ──────────────────────────────────────────────────────────────

    const vtable = Widget.VTable{
        .type_name = "statusbar",
        .measure = measure,
        .paint = paint,
        .on_event = null,
        .focusable = false,
        .destroy = destroyVTable,
    };

    fn destroyVTable(w: *Widget, allocator: std.mem.Allocator) void {
        const self: *Self = @fieldParentPtr("base", w);
        self.destroy(allocator);
    }

    fn measure(w: *Widget, ctx: *PaintContext, constraints: layout_mod.Constraints) math.Size(f32) {
        const self: *Self = @fieldParentPtr("base", w);
        _ = ctx;
        const h = if (w.rect.height > 0) w.rect.height else self.height;
        return .{ .width = constraints.max_width, .height = h };
    }

    fn paint(w: *Widget, ctx: *PaintContext) void {
        const self: *Self = @fieldParentPtr("base", w);
        const rx = ctx.offset_x + w.rect.x;
        const ry = ctx.offset_y + w.rect.y;
        const rw = w.rect.width;
        const rh = w.rect.height;

        ctx.renderer.fillRect(.{ .x = rx, .y = ry, .width = rw, .height = rh }, self.bg_color) catch {};

        if (self.border_top > 0) {
            ctx.renderer.fillRect(
                .{ .x = rx, .y = ry, .width = rw, .height = self.border_top },
                self.border_color,
            ) catch {};
        }

        if (self.content_container) |cc| {
            cc.base.rect = .{ .x = rx, .y = ry, .width = rw, .height = rh };
            cc.base.vtable.paint(&cc.base, ctx);
        }
    }
};

pub const StatusBar = Statusbar;
