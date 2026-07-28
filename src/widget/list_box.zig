//! ListBox 控件 - 列表框容器
//!
//! 类似 GtkListBox: 垂直排列的列表容器, 每个子项是一行, 支持选择、激活、键盘导航。
//! 比 ListView 更简单, 适合静态或少量数据的列表展示。

const std = @import("std");
const math = @import("../math.zig");
const widget_mod = @import("widget.zig");
const layout_mod = @import("../layout/engine.zig");
const pal = @import("../pal/pal.zig");

const Widget = widget_mod.Widget;
const PaintContext = widget_mod.PaintContext;
const EventContext = widget_mod.EventContext;
const EventResult = widget_mod.EventResult;

pub const ListBoxSelectionMode = enum {
    none,
    single,
    browse,
    multiple,
};

pub const ListBoxRow = struct {
    child: *Widget,
    selected: bool = false,
    activatable: bool = true,
    selectable: bool = true,
};

pub const ListBox = struct {
    base: Widget,
    allocator: std.mem.Allocator,
    rows: std.ArrayListUnmanaged(ListBoxRow),
    selection_mode: ListBoxSelectionMode = .single,
    selected_row: ?usize = null,
    hovered_row: ?usize = null,
    row_gap: f32 = 0,
    padding: math.EdgeInsets = .{},
    activate_on_single_click: bool = true,

    on_row_selected: ?*const fn (self: *ListBox, row: usize, widget: *Widget) void = null,
    on_row_activated: ?*const fn (self: *ListBox, row: usize, widget: *Widget) void = null,

    const Self = @This();

    pub fn create(allocator: std.mem.Allocator, opts: struct {
        selection_mode: ListBoxSelectionMode = .single,
        row_gap: f32 = 0,
        padding: math.EdgeInsets = .{},
        bg_color: ?math.Color = null,
        corner_radius: f32 = 0,
        width: layout_mod.Dimension = .{ .auto = {} },
        height: layout_mod.Dimension = .{ .auto = {} },
        activate_on_single_click: bool = true,
    }) !*ListBox {
        const self = try allocator.create(ListBox);
        self.* = .{
            .base = .{
                .vtable = &vtable,
                .id = widget_mod.genWidgetId(),
            },
            .allocator = allocator,
            .rows = .{ .items = &.{}, .capacity = 0 },
            .selection_mode = opts.selection_mode,
            .row_gap = opts.row_gap,
            .padding = opts.padding,
            .activate_on_single_click = opts.activate_on_single_click,
        };
        if (opts.bg_color) |c| {
            self.base.background.bg = .{ .color = c };
        }
        self.base.background.corner_radius = opts.corner_radius;
        self.base.layout_style.width = opts.width;
        self.base.layout_style.height = opts.height;
        self.base.accessibility = .{ .role = .list };
        return self;
    }

    pub fn destroy(self: *Self, allocator: std.mem.Allocator) void {
        for (self.rows.items) |row| {
            row.child.vtable.destroy(row.child, allocator);
        }
        self.rows.deinit(allocator);
        self.base.background.deinit(allocator);
        self.base.children.deinit(allocator);
        allocator.destroy(self);
    }

    pub fn append(self: *Self, child: *Widget) !void {
        try self.rows.append(self.allocator, .{
            .child = child,
        });
        try self.base.addChild(self.allocator, child);
        self.base.markLayoutDirty();
    }

    pub fn insert(self: *Self, index: usize, child: *Widget) !void {
        try self.rows.insert(self.allocator, index, .{
            .child = child,
        });
        try self.base.addChild(self.allocator, child);
        self.base.markLayoutDirty();
    }

    pub fn remove(self: *Self, index: usize) void {
        if (index >= self.rows.items.len) return;
        const row = self.rows.items[index];
        row.child.vtable.destroy(row.child, self.allocator);
        self.rows.orderedRemove(index);
        self.base.markLayoutDirty();
    }

    pub fn getRowAtIndex(self: *Self, index: usize) ?*Widget {
        if (index >= self.rows.items.len) return null;
        return self.rows.items[index].child;
    }

    pub fn getRowCount(self: *Self) usize {
        return self.rows.items.len;
    }

    pub fn getSelectedRow(self: *Self) ?usize {
        return self.selected_row;
    }

    pub fn selectRow(self: *Self, index: ?usize) void {
        if (self.selection_mode == .none) return;

        if (self.selected_row) |prev| {
            if (prev < self.rows.items.len) {
                self.rows.items[prev].selected = false;
            }
        }

        self.selected_row = index;
        if (index) |idx| {
            if (idx < self.rows.items.len) {
                self.rows.items[idx].selected = true;
            }
        }

        self.base.markDirty();

        if (index) |idx| {
            if (self.on_row_selected) |cb| {
                cb(self, idx, self.rows.items[idx].child);
            }
        }
    }

    pub fn getRowAtY(self: *Self, y: f32) ?usize {
        const pad = self.padding;
        var current_y = pad.top;

        for (self.rows.items, 0..) |row, i| {
            if (!row.child.state.visible) continue;
            const h = row.child.rect.height;
            if (y >= current_y and y < current_y + h) {
                return i;
            }
            current_y += h + self.row_gap;
        }
        return null;
    }

    fn selectRowAtY(self: *Self, y: f32) void {
        if (self.selection_mode == .none) return;
        if (self.getRowAtY(y)) |row| {
            if (self.rows.items[row].selectable) {
                self.selectRow(row);
            }
        }
    }

    fn activateRow(self: *Self, index: usize) void {
        if (index >= self.rows.items.len) return;
        if (!self.rows.items[index].activatable) return;
        if (self.on_row_activated) |cb| {
            cb(self, index, self.rows.items[index].child);
        }
    }

    const vtable = Widget.VTable{
        .type_name = "list_box",
        .measure = measure,
        .perform_layout = performLayout,
        .paint = paint,
        .on_event = onEvent,
        .focusable = true,
        .destroy = destroyVTable,
    };

    fn destroyVTable(w: *Widget, allocator: std.mem.Allocator) void {
        const self: *Self = @fieldParentPtr("base", w);
        self.destroy(allocator);
    }

    fn measure(w: *Widget, ctx: *PaintContext, constraints: layout_mod.Constraints) math.Size(f32) {
        const self: *Self = @fieldParentPtr("base", w);
        const pad = self.padding;

        var total_height: f32 = pad.top + pad.bottom;
        var max_width: f32 = 0;
        var first = true;

        const inner_w = @max(0, constraints.max_width - pad.left - pad.right);
        const inner_h = @max(0, constraints.max_height - pad.top - pad.bottom);
        const inner_constraint = layout_mod.Constraints{
            .max_width = inner_w,
            .max_height = inner_h,
        };

        for (self.rows.items) |row| {
            if (!row.child.state.visible) continue;
            if (row.child.layout_style.position == .absolute) continue;

            const size = row.child.vtable.measure(row.child, ctx, inner_constraint);
            var cw = size.width;
            var ch = size.height;
            if (row.child.layout_style.width.resolve(inner_w)) |ew| cw = ew;
            if (row.child.layout_style.height.resolve(inner_h)) |eh| ch = eh;
            const cm = row.child.layout_style.margin;

            if (cw + cm.left + cm.right > max_width) {
                max_width = cw + cm.left + cm.right;
            }
            if (!first) total_height += self.row_gap;
            total_height += ch + cm.top + cm.bottom;
            first = false;
        }

        return .{
            .width = max_width + pad.left + pad.right,
            .height = total_height,
        };
    }

    fn performLayout(w: *Widget, ctx: *PaintContext) void {
        const self: *Self = @fieldParentPtr("base", w);
        const pad = self.padding;
        const avail_w = @max(0, w.rect.width - pad.left - pad.right);

        var y = pad.top;

        for (self.rows.items) |*row| {
            if (!row.child.state.visible) continue;
            if (row.child.layout_style.position == .absolute) continue;

            const cm = row.child.layout_style.margin;
            const size = row.child.vtable.measure(row.child, ctx, .{
                .max_width = avail_w - cm.left - cm.right,
                .max_height = 10000,
            });

            var cw = size.width;
            var ch = size.height;
            if (row.child.layout_style.width.resolve(avail_w - cm.left - cm.right)) |ew| cw = ew;
            if (row.child.layout_style.height.resolve(10000)) |eh| ch = eh;

            row.child.rect.x = pad.left + cm.left;
            row.child.rect.y = y + cm.top;
            row.child.rect.width = @max(0, avail_w - cm.left - cm.right);
            row.child.rect.height = @max(0, ch);
            row.child.layoutSubtree(ctx);

            y += ch + cm.top + cm.bottom + self.row_gap;
        }
    }

    fn paint(w: *Widget, ctx: *PaintContext) void {
        const self: *Self = @fieldParentPtr("base", w);
        const r = w.rect;
        const r2d = ctx.renderer;

        const x = ctx.offset_x + r.x;
        const y = ctx.offset_y + r.y;

        if (self.selected_row) |idx| {
            if (idx < self.rows.items.len) {
                const row = self.rows.items[idx];
                if (row.child.state.visible) {
                    const row_rect = math.Rect(f32){
                        .x = x + self.padding.left,
                        .y = y + row.child.rect.y,
                        .width = r.width - self.padding.left - self.padding.right,
                        .height = row.child.rect.height,
                    };
                    r2d.fillRect(row_rect, math.Color.hex(0x3B82F640)) catch {};
                }
            }
        }

        if (self.hovered_row) |idx| {
            if (idx < self.rows.items.len) {
                const row = self.rows.items[idx];
                if (row.child.state.visible and (self.selected_row == null or self.selected_row.? != idx)) {
                    const row_rect = math.Rect(f32){
                        .x = x + self.padding.left,
                        .y = y + row.child.rect.y,
                        .width = r.width - self.padding.left - self.padding.right,
                        .height = row.child.rect.height,
                    };
                    r2d.fillRect(row_rect, math.Color.hex(0xFFFFFF10)) catch {};
                }
            }
        }
    }

    fn onEvent(w: *Widget, event: *const pal.Event, ectx: *EventContext) EventResult {
        const self: *Self = @fieldParentPtr("base", w);

        for (self.rows.items) |row| {
            const result = row.child.dispatchEvent(event, ectx);
            if (result == .handled) return .handled;
        }

        switch (event.*) {
            .mouse_button => |mb| {
                if (mb.button == .left) {
                    if (mb.state == .pressed) {
                        const local_y = @as(f32, @floatFromInt(mb.y)) - w.absoluteRect().y;
                        const row_idx = self.getRowAtY(local_y);
                        self.selectRow(row_idx);
                        w.setFocus();
                        return .handled;
                    } else {
                        if (self.activate_on_single_click) {
                            const local_y = @as(f32, @floatFromInt(mb.y)) - w.absoluteRect().y;
                            if (self.getRowAtY(local_y)) |row_idx| {
                                self.activateRow(row_idx);
                                return .handled;
                            }
                        }
                    }
                }
                return .handled;
            },
            .mouse_move => |mm| {
                const local_y = @as(f32, @floatFromInt(mm.y)) - w.absoluteRect().y;
                const hovered = self.getRowAtY(local_y);
                if (hovered != self.hovered_row) {
                    self.hovered_row = hovered;
                    w.markDirty();
                }
                return .handled;
            },
            .mouse_leave => {
                if (self.hovered_row != null) {
                    self.hovered_row = null;
                    w.markDirty();
                }
                return .ignored;
            },
            .key => |key| {
                if (key.state == .pressed) {
                    switch (key.keycode) {
                        .up => {
                            if (self.selected_row) |idx| {
                                var new_idx = idx;
                                while (new_idx > 0) {
                                    new_idx -= 1;
                                    if (self.rows.items[new_idx].selectable and self.rows.items[new_idx].child.state.visible) {
                                        self.selectRow(new_idx);
                                        break;
                                    }
                                }
                            } else if (self.rows.items.len > 0) {
                                self.selectRow(0);
                            }
                            return .handled;
                        },
                        .down => {
                            if (self.selected_row) |idx| {
                                var new_idx = idx;
                                while (new_idx + 1 < self.rows.items.len) {
                                    new_idx += 1;
                                    if (self.rows.items[new_idx].selectable and self.rows.items[new_idx].child.state.visible) {
                                        self.selectRow(new_idx);
                                        break;
                                    }
                                }
                            } else if (self.rows.items.len > 0) {
                                self.selectRow(0);
                            }
                            return .handled;
                        },
                        .home => {
                            for (self.rows.items, 0..) |row, i| {
                                if (row.selectable and row.child.state.visible) {
                                    self.selectRow(i);
                                    break;
                                }
                            }
                            return .handled;
                        },
                        .end => {
                            var i = self.rows.items.len;
                            while (i > 0) {
                                i -= 1;
                                if (self.rows.items[i].selectable and self.rows.items[i].child.state.visible) {
                                    self.selectRow(i);
                                    break;
                                }
                            }
                            return .handled;
                        },
                        .enter, .kp_enter => {
                            if (self.selected_row) |idx| {
                                self.activateRow(idx);
                                return .handled;
                            }
                        },
                        else => {},
                    }
                }
                return .ignored;
            },
            .double_click => |dc| {
                if (dc.button == .left) {
                    const local_y = @as(f32, @floatFromInt(dc.y)) - w.absoluteRect().y;
                    if (self.getRowAtY(local_y)) |row_idx| {
                        self.activateRow(row_idx);
                        return .handled;
                    }
                }
                return .ignored;
            },
            else => return .ignored,
        }
    }
};
