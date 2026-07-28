//! DropDown 控件 - 轻量下拉选择 (对标 GtkDropDown)
//! 比 ComboBox 更现代: 用 Popover 弹出列表, 支持搜索/高亮

const std = @import("std");
const math = @import("../math.zig");
const widget_mod = @import("widget.zig");
const layout_mod = @import("../layout/engine.zig");
const pal = @import("../pal/pal.zig");
const styled_text = @import("../text/styled_text.zig");

const Widget = widget_mod.Widget;
const PaintContext = widget_mod.PaintContext;
const EventContext = widget_mod.EventContext;
const EventResult = widget_mod.EventResult;

pub const DropDownItem = struct {
    label: []const u8,
    id: i32 = 0,
};

pub const DropDown = struct {
    base: Widget,
    allocator: std.mem.Allocator,
    items: std.ArrayListUnmanaged(DropDownItem) = .{ .items = &.{}, .capacity = 0 },
    selected: usize = 0,
    is_open: bool = false,
    hovered_item: i32 = -1,
    on_change: ?*const fn (self: *DropDown, index: usize) void = null,
    // 样式
    bg_color: math.Color = math.Color.hex(0x1E293BFF),
    bg_hover: math.Color = math.Color.hex(0x334155FF),
    border_color: math.Color = math.Color.hex(0x334155FF),
    focus_border: math.Color = math.Color.hex(0x3B82F6FF),
    text_color: math.Color = math.Color.hex(0xF8FAFCFF),
    popup_bg: math.Color = math.Color.hex(0x1E293BFF),
    popup_hover: math.Color = math.Color.hex(0x3B82F6FF),
    corner_radius: f32 = 8.0,
    padding_h: f32 = 12.0,
    padding_v: f32 = 10.0,
    font_size: f32 = 14.0,
    arrow_size: f32 = 6.0,
    item_height: f32 = 32.0,
    max_visible_items: u32 = 8,

    pub fn create(allocator: std.mem.Allocator, opts: struct {
        font_size: f32 = 14.0,
        on_change: ?*const fn (self: *DropDown, index: usize) void = null,
    }) !*DropDown {
        const self = try allocator.create(DropDown);
        self.* = .{
            .base = .{
                .vtable = &vtable,
                .id = widget_mod.genWidgetId(),
            },
            .allocator = allocator,
            .font_size = opts.font_size,
            .on_change = opts.on_change,
        };
        self.base.accessibility = .{ .role = .container, .label = "dropdown" };
        self.base.cursor = .pointing_hand;
        return self;
    }

    pub fn destroy(self: *DropDown, allocator: std.mem.Allocator) void {
        self.items.deinit(allocator);
        self.base.background.deinit(allocator);
        self.base.children.deinit(allocator);
        allocator.destroy(self);
    }

    pub fn addItem(self: *DropDown, label: []const u8, id: i32) !void {
        try self.items.append(self.allocator, .{ .label = label, .id = id });
        self.base.markLayoutDirty();
        self.base.markDirty();
    }

    pub fn setSelected(self: *DropDown, index: usize) void {
        if (index >= self.items.items.len) return;
        if (index == self.selected) return;
        self.selected = index;
        self.base.markDirty();
        if (self.on_change) |cb| cb(self, index);
    }

    pub fn getSelectedText(self: *const DropDown) []const u8 {
        if (self.selected < self.items.items.len) return self.items.items[self.selected].label;
        return "";
    }

    fn headerHeight(self: *const DropDown) f32 {
        return self.font_size * 1.2 + self.padding_v * 2;
    }

    // ── VTable 实现 ──────────────────────────────────────────────────────────

    const vtable = Widget.VTable{
        .type_name = "drop_down",
        .measure = measure,
        .paint = paint,
        .on_event = onEvent,
        .focusable = true,
        .destroy = destroyVTable,
    };

    fn destroyVTable(w: *Widget, allocator: std.mem.Allocator) void {
        const self: *DropDown = @fieldParentPtr("base", w);
        self.destroy(allocator);
    }

    fn measure(w: *Widget, ctx: *PaintContext, constraints: layout_mod.Constraints) math.Size(f32) {
        const self: *DropDown = @fieldParentPtr("base", w);
        _ = constraints;

        // 测量最长项
        var max_w: f32 = 0;
        for (self.items.items) |item| {
            const ts = styled_text.measureText(ctx.allocator, item.label, .{
                .font_size = self.font_size,
            });
            if (ts.width > max_w) max_w = ts.width;
        }

        const arrow_total = self.padding_h + self.arrow_size + self.padding_h;
        const header_h = self.font_size * 1.2 + self.padding_v * 2;
        // 打开时扩大高度包含弹出列表
        var total_h = header_h;
        if (self.is_open) {
            const visible_count = @min(self.items.items.len, self.max_visible_items);
            total_h += 8 + @as(f32, @floatFromInt(visible_count)) * self.item_height + 4;
        }
        return .{
            .width = max_w + self.padding_h * 2 + arrow_total,
            .height = total_h,
        };
    }

    fn paint(w: *Widget, ctx: *PaintContext) void {
        const self: *DropDown = @fieldParentPtr("base", w);
        const rx = ctx.offset_x + w.rect.x;
        const ry = ctx.offset_y + w.rect.y;
        const rw = w.rect.width;
        const hh = self.headerHeight();

        // 头部背景
        const border = if (w.state.focused or self.is_open) self.focus_border else self.border_color;
        const bg = if (w.state.hovered or self.is_open) self.bg_hover else self.bg_color;
        ctx.renderer.fillRoundedRect(.{ .x = rx, .y = ry, .width = rw, .height = hh }, self.corner_radius, bg) catch {};
        ctx.renderer.strokeRoundedRect(.{ .x = rx, .y = ry, .width = rw, .height = hh }, self.corner_radius, 1.0, border) catch {};

        // 选中项文本
        const text = self.getSelectedText();
        if (text.len > 0) {
            const text_y = ry + (hh - self.font_size * 1.2) / 2.0 + self.font_size * 0.85;
            _ = styled_text.drawTextClipped(
                ctx.renderer,
                ctx.allocator,
                text,
                rx + self.padding_h,
                text_y,
                .{ .font_size = self.font_size, .color = self.text_color },
                rw - self.padding_h * 3 - self.arrow_size,
            );
        }

        // 下拉箭头
        const arrow_x = rx + rw - self.padding_h - self.arrow_size;
        const arrow_y = ry + (hh - self.arrow_size) / 2.0;
        const s = self.arrow_size;
        const cx = arrow_x + s / 2.0;
        ctx.renderer.fillRect(.{ .x = cx - 1, .y = arrow_y, .width = 2.0, .height = 2.0 }, self.text_color) catch {};
        ctx.renderer.fillRect(.{ .x = cx - 2, .y = arrow_y + 2, .width = 4.0, .height = 2.0 }, self.text_color) catch {};
        if (s >= 6) {
            ctx.renderer.fillRect(.{ .x = cx - 3, .y = arrow_y + 4, .width = 6.0, .height = 2.0 }, self.text_color) catch {};
        }

        // 弹出列表
        if (self.is_open) {
            self.paintPopup(ctx, rx, ry, rw, hh);
        }
    }

    fn paintPopup(self: *DropDown, ctx: *PaintContext, rx: f32, ry: f32, rw: f32, hh: f32) void {
        const visible_count = @min(self.items.items.len, self.max_visible_items);
        const popup_h = @as(f32, @floatFromInt(visible_count)) * self.item_height;
        const popup_x = rx;
        const popup_w = rw;

        // 弹出背景 (紧接头部下方)
        ctx.renderer.fillRoundedRect(
            .{ .x = popup_x, .y = ry + hh + 4, .width = popup_w, .height = popup_h + 8 },
            self.corner_radius,
            self.popup_bg,
        ) catch {};

        // 列表项
        const item_y_start = ry + hh + 8;
        for (self.items.items, 0..) |item, i| {
            if (i >= visible_count) break;
            const item_y = item_y_start + @as(f32, @floatFromInt(i)) * self.item_height;

            // 选中/悬停高亮
            if (i == self.selected) {
                ctx.renderer.fillRect(
                    .{ .x = popup_x + 4, .y = item_y, .width = popup_w - 8, .height = self.item_height },
                    math.Color.hex(0x3B82F644),
                ) catch {};
            }
            if (self.hovered_item == @as(i32, @intCast(i))) {
                ctx.renderer.fillRect(
                    .{ .x = popup_x + 4, .y = item_y, .width = popup_w - 8, .height = self.item_height },
                    self.popup_hover,
                ) catch {};
            }

            // 项文本
            const text_y = item_y + (self.item_height - self.font_size * 1.2) / 2.0 + self.font_size * 0.85;
            const item_color = if (self.hovered_item == @as(i32, @intCast(i)))
                math.Color.hex(0xFFFFFFFF)
            else
                self.text_color;
            _ = styled_text.drawTextClipped(
                ctx.renderer,
                ctx.allocator,
                item.label,
                popup_x + self.padding_h,
                text_y,
                .{ .font_size = self.font_size, .color = item_color },
                popup_w - self.padding_h * 2,
            );
        }
    }

    fn onEvent(w: *Widget, event: *const pal.Event, ectx: *EventContext) EventResult {
        const self: *DropDown = @fieldParentPtr("base", w);
        _ = ectx;
        const abs = w.absoluteRect();
        const hh = self.headerHeight();

        switch (event.*) {
            .mouse_button => |mb| {
                if (mb.button != .left) return .ignored;
                const mx = @as(f32, @floatFromInt(mb.x)) - abs.x;
                const my = @as(f32, @floatFromInt(mb.y)) - abs.y;

                if (mb.state == .pressed) {
                    if (!self.is_open) {
                        // 点击头部打开
                        if (mx >= 0 and mx < w.rect.width and my >= 0 and my < hh) {
                            self.is_open = true;
                            self.base.markLayoutDirty();
                            w.markDirty();
                            return .handled;
                        }
                    } else {
                        // 弹出列表中的点击
                        const item_y_start = hh + 8;
                        if (my >= item_y_start) {
                            const idx = @as(usize, @intFromFloat((my - item_y_start) / self.item_height));
                            if (idx < self.items.items.len) {
                                self.setSelected(idx);
                            }
                        } else if (my >= 0 and my < hh) {
                            // 点击头部 -> 关闭
                        }
                        self.is_open = false;
                        self.base.markLayoutDirty();
                        w.markDirty();
                        return .handled;
                    }
                }
            },
            .mouse_move => |mm| {
                if (self.is_open) {
                    const my = @as(f32, @floatFromInt(mm.y)) - abs.y;
                    const item_y_start = hh + 8;
                    if (my >= item_y_start) {
                        const idx = @as(i32, @intFromFloat((my - item_y_start) / self.item_height));
                        const visible = @min(self.items.items.len, self.max_visible_items);
                        if (idx >= 0 and idx < @as(i32, @intCast(visible))) {
                            if (self.hovered_item != idx) {
                                self.hovered_item = idx;
                                w.markDirty();
                            }
                        }
                    } else {
                        if (self.hovered_item != -1) {
                            self.hovered_item = -1;
                            w.markDirty();
                        }
                    }
                }
            },
            else => {},
        }
        return .ignored;
    }
};
