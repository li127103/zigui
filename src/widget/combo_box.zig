//! ComboBox 控件 - 下拉选择

const std = @import("std");
const math = @import("../math.zig");
const widget_mod = @import("widget.zig");
const layout_mod = @import("../layout/engine.zig");
const pal = @import("../pal/pal.zig");
const text_layout = @import("../text/layout.zig");
const coretext = @import("../text/coretext.zig");

const Widget = widget_mod.Widget;
const PaintContext = widget_mod.PaintContext;
const EventContext = widget_mod.EventContext;
const EventResult = widget_mod.EventResult;

pub const ComboBox = struct {
    base: Widget,
    allocator: std.mem.Allocator,
    items: std.ArrayListUnmanaged([]const u8),
    selected: usize = 0,
    open: bool = false,
    hovered_item: ?usize = null,
    font_size: f32,
    on_change: ?*const fn (self: *ComboBox, index: usize) void,
    // 样式
    bg_color: math.Color = math.Color.hex(0x1E293BFF),
    border_color: math.Color = math.Color.hex(0x334155FF),
    focus_border: math.Color = math.Color.hex(0x3B82F6FF),
    text_color: math.Color = math.Color.hex(0xF8FAFCFF),
    dropdown_bg: math.Color = math.Color.hex(0x1E293BFF),
    item_hover_bg: math.Color = math.Color.hex(0x334155FF),
    corner_radius: f32 = 8.0,
    item_height: f32 = 32.0,
    padding_h: f32 = 12.0,

    pub fn create(allocator: std.mem.Allocator, opts: struct {
        font_size: f32 = 14.0,
        on_change: ?*const fn (self: *ComboBox, index: usize) void = null,
    }) !*ComboBox {
        const self = try allocator.create(ComboBox);
        self.* = .{
            .base = .{
                .vtable = &vtable,
                .id = widget_mod.genWidgetId(),
            },
            .allocator = allocator,
            .items = .{ .items = &.{}, .capacity = 0 },
            .font_size = opts.font_size,
            .on_change = opts.on_change,
        };
        return self;
    }

    pub fn destroy(self: *ComboBox, allocator: std.mem.Allocator) void {
        self.items.deinit(allocator);
        self.base.children.deinit(allocator);
        allocator.destroy(self);
    }

    pub fn addItem(self: *ComboBox, item: []const u8) !void {
        try self.items.append(self.allocator, item);
    }

    pub fn setSelected(self: *ComboBox, index: usize) void {
        if (index < self.items.items.len and index != self.selected) {
            self.selected = index;
            self.base.markDirty();
            if (self.on_change) |cb| cb(self, index);
        }
    }

    pub fn getSelectedText(self: *const ComboBox) []const u8 {
        if (self.selected < self.items.items.len) {
            return self.items.items[self.selected];
        }
        return "";
    }

    // ── VTable ──────────────────────────────────────────────────────────────

    const vtable = Widget.VTable{
        .type_name = "combo_box",
        .measure = measure,
        .paint = paint,
        .on_event = onEvent,
        .focusable = true,
        .destroy = destroyVTable,
    };

    fn destroyVTable(w: *Widget, allocator: std.mem.Allocator) void {
        const self: *ComboBox = @fieldParentPtr("base", w);
        self.destroy(allocator);
    }

    fn measure(w: *Widget, ctx: *PaintContext, constraints: layout_mod.Constraints) math.Size(f32) {
        const self: *ComboBox = @fieldParentPtr("base", w);
        _ = ctx;
        _ = constraints;
        return .{ .width = 200, .height = self.font_size + 20 };
    }

    fn paint(w: *Widget, ctx: *PaintContext) void {
        const self: *ComboBox = @fieldParentPtr("base", w);
        const rx = ctx.offset_x + w.rect.x;
        const ry = ctx.offset_y + w.rect.y;
        const rw = w.rect.width;
        const rh = w.rect.height;

        // 主框
        const border_c = if (w.state.focused or self.open) self.focus_border else self.border_color;
        ctx.renderer.fillRoundedRect(.{ .x = rx, .y = ry, .width = rw, .height = rh }, self.corner_radius, border_c) catch {};
        ctx.renderer.fillRoundedRect(.{ .x = rx + 1.5, .y = ry + 1.5, .width = rw - 3, .height = rh - 3 }, self.corner_radius - 1, self.bg_color) catch {};

        // 选中文本
        self.drawLabel(ctx, self.getSelectedText(), rx + self.padding_h, ry + (rh - self.font_size * 1.2) / 2.0, self.text_color);

        // 下拉箭头
        const arrow_x = rx + rw - 24;
        const arrow_y = ry + rh / 2.0 - 3;
        ctx.renderer.fillRoundedRect(.{ .x = arrow_x, .y = arrow_y, .width = 8, .height = 2 }, 1, math.Color.hex(0x94A3B8FF)) catch {};
        ctx.renderer.fillRoundedRect(.{ .x = arrow_x + 2, .y = arrow_y + 3, .width = 4, .height = 2 }, 1, math.Color.hex(0x94A3B8FF)) catch {};

        // 下拉列表
        if (self.open) {
            const list_y = ry + rh + 4;
            const list_h: f32 = @floatFromInt(self.items.items.len);
            const total_h = list_h * self.item_height + 8;

            // 阴影/背景
            ctx.renderer.fillRoundedRect(
                .{ .x = rx, .y = list_y, .width = rw, .height = total_h },
                self.corner_radius,
                self.dropdown_bg,
            ) catch {};
            // 边框
            ctx.renderer.fillRoundedRect(.{ .x = rx, .y = list_y, .width = rw, .height = total_h }, self.corner_radius, self.border_color) catch {};
            ctx.renderer.fillRoundedRect(.{ .x = rx + 1, .y = list_y + 1, .width = rw - 2, .height = total_h - 2 }, self.corner_radius - 1, self.dropdown_bg) catch {};

            // 选项
            for (self.items.items, 0..) |item, i| {
                const item_y = list_y + 4 + @as(f32, @floatFromInt(i)) * self.item_height;

                // hover / selected 背景
                if (self.hovered_item != null and self.hovered_item.? == i) {
                    ctx.renderer.fillRoundedRect(
                        .{ .x = rx + 4, .y = item_y, .width = rw - 8, .height = self.item_height - 2 },
                        4,
                        self.item_hover_bg,
                    ) catch {};
                } else if (i == self.selected) {
                    ctx.renderer.fillRoundedRect(
                        .{ .x = rx + 4, .y = item_y, .width = rw - 8, .height = self.item_height - 2 },
                        4,
                        math.Color.hex(0x3B82F622),
                    ) catch {};
                }

                self.drawLabel(ctx, item, rx + self.padding_h, item_y + (self.item_height - self.font_size * 1.2) / 2.0, self.text_color);
            }
        }
    }

    fn drawLabel(self: *ComboBox, ctx: *PaintContext, text: []const u8, x: f32, y: f32, color: math.Color) void {
        if (text.len == 0) return;
        var font = coretext.CtFont.create(null, self.font_size, 400) catch return;
        defer font.destroy();

        var tl = text_layout.TextLayout.layout(
            ctx.allocator,
            &ctx.renderer.glyph_atlas.?,
            ctx.renderer.device,
            text,
            .{ .font = &font, .font_size = self.font_size },
        ) catch return;
        defer tl.deinit();

        ctx.renderer.drawText(&tl, x, y, color) catch {};
    }

    fn onEvent(w: *Widget, event: *const pal.Event, ectx: *EventContext) EventResult {
        const self: *ComboBox = @fieldParentPtr("base", w);
        _ = ectx;

        switch (event.*) {
            .mouse_button => |mb| {
                if (mb.button != .left or mb.state != .pressed) return .ignored;

                const mx: f32 = @floatFromInt(mb.x);
                const my: f32 = @floatFromInt(mb.y);

                if (self.open) {
                    // 检查是否点击了下拉列表中的选项
                    const list_y = w.rect.height + 4;
                    if (my >= list_y and mx >= 0 and mx < w.rect.width) {
                        const rel_y = my - list_y - 4;
                        const idx: usize = @intFromFloat(rel_y / self.item_height);
                        if (idx < self.items.items.len) {
                            self.setSelected(idx);
                            self.open = false;
                            self.base.markDirty();
                            return .handled;
                        }
                    }
                    // 点击外部关闭
                    self.open = false;
                    self.base.markDirty();
                    return .handled;
                } else {
                    // 打开下拉
                    if (mx >= 0 and my >= 0 and mx < w.rect.width and my < w.rect.height) {
                        self.open = true;
                        self.base.markDirty();
                        return .handled;
                    }
                }
            },
            .mouse_move => |mm| {
                if (self.open) {
                    const my: f32 = @floatFromInt(mm.y);
                    const list_y = w.rect.height + 4;
                    if (my >= list_y) {
                        const rel_y = my - list_y - 4;
                        const idx: usize = @intFromFloat(rel_y / self.item_height);
                        const new_hover: ?usize = if (idx < self.items.items.len) idx else null;
                        if (new_hover != self.hovered_item) {
                            self.hovered_item = new_hover;
                            self.base.markDirty();
                        }
                    }
                }
            },
            .key => |k| {
                if (k.state != .pressed or !w.state.focused) return .ignored;
                switch (k.key) {
                    .up => {
                        if (self.selected > 0) {
                            self.setSelected(self.selected - 1);
                        }
                        return .handled;
                    },
                    .down => {
                        if (self.selected + 1 < self.items.items.len) {
                            self.setSelected(self.selected + 1);
                        }
                        return .handled;
                    },
                    .enter, .space => {
                        self.open = !self.open;
                        self.base.markDirty();
                        return .handled;
                    },
                    .escape => {
                        self.open = false;
                        self.base.markDirty();
                        return .handled;
                    },
                    else => {},
                }
            },
            else => {},
        }
        return .ignored;
    }
};
