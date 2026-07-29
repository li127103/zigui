//! TreeExpander 控件 - GTK4 树形展开器
//!
//! GTK4 新型树控件 (用于替代 TreeView 的轻量级方案之一)。
//! 包装内容控件, 左侧显示一个展开箭头, 点击可切换展开/折叠状态。
//!
//! 与 ListBox / ListView 配合使用, 构建多级嵌套的树结构。
//!
//! GTK4 对应: GtkTreeExpander

const std = @import("std");
const math = @import("../math.zig");
const widget_mod = @import("widget.zig");
const layout_mod = @import("../layout/engine.zig");
const pal = @import("../pal/pal.zig");
const icons_mod = @import("icons.zig");
const tree_model = @import("../model/tree_list_model.zig");

const Widget = widget_mod.Widget;
const PaintContext = widget_mod.PaintContext;
const EventContext = widget_mod.EventContext;
const EventResult = widget_mod.EventResult;
const Allocator = std.mem.Allocator;
const Event = pal.event_mod.Event;

/// TreeListRow — 树形行状态 (GTK4 对应 GtkTreeListRow)
/// 独立定义，保持与 model.TreeListModel 相同的字段布局以便互转 (不是别名)。
pub const TreeListRow = struct {
    /// 原始的 item 指针 (来自源模型; 若不需要可空)
    item: ?*anyopaque = null,
    /// 深度 (顶层 = 0)
    depth: u32 = 0,
    /// 是否有子项
    has_children: bool = false,
    /// 当前是否展开
    expanded: bool = false,
    /// 是否为占位行
    is_placeholder: bool = false,
    /// 自定义指针
    userdata: ?*anyopaque = null,
};

const EXPANDER_SIZE: f32 = 20; // 展开图标区域
const EXPANDER_ICON: f32 = 12; // 图标实际尺寸

pub const TreeExpander = struct {
    base: Widget,
    allocator: Allocator,
    child: ?*Widget = null,

    indent_for_icon: bool = true, // 即使没子节点也预留图标缩进
    hide_expander: bool = false, // 强制隐藏展开按钮 (不管行有没有子节点)

    list_row: TreeListRow = .{},

    on_toggle: ?*const fn (self: *TreeExpander, expanded: bool) void = null,

    hover_expander: bool = false,

    pub fn new(allocator: Allocator) !*TreeExpander {
        const self = try allocator.create(TreeExpander);
        self.* = .{
            .base = .{
                .vtable = &vtable,
                .id = widget_mod.genWidgetId(),
                .cursor = .pointing_hand,
            },
            .allocator = allocator,
        };
        self.base.accessibility = .{ .role = .row, .label = "Tree Expander" };
        return self;
    }

    pub fn destroy(self: *TreeExpander, allocator: Allocator) void {
        self.base.background.deinit(allocator);
        self.base.children.deinit(allocator);
        allocator.destroy(self);
    }

    pub fn setChild(self: *TreeExpander, child: ?*Widget) void {
        self.child = child;
        self.base.children.deinit(self.allocator);
        if (child) |c| self.base.children.append(self.allocator, c) catch {};
        self.base.markLayoutDirty();
        self.base.markDirty();
    }

    pub fn setListRow(self: *TreeExpander, row: TreeListRow) void {
        self.list_row = row;
        self.base.markLayoutDirty();
        self.base.markDirty();
    }

    /// 直接从 *TreeListRow (指针) 拷贝 (widget 层)
    pub fn setListRowPtr(self: *TreeExpander, row: *const TreeListRow) void {
        self.list_row = row.*;
        self.base.markLayoutDirty();
        self.base.markDirty();
    }

    /// 从 model 层的 TreeListRow 拷贝 (GTK4 兼容: TreeListModel → TreeExpander)
    pub fn setFromModelRow(self: *TreeExpander, model_row: *const tree_model.TreeListRow) void {
        self.list_row.item = model_row.item;
        self.list_row.depth = model_row.depth;
        self.list_row.has_children = model_row.has_children;
        self.list_row.expanded = model_row.expanded;
        self.list_row.is_placeholder = model_row.is_placeholder;
        self.list_row.userdata = model_row.userdata;
        self.base.markLayoutDirty();
        self.base.markDirty();
    }

    /// 便捷: 同时设置 item / depth / has_children / expanded (GTK4 常见组合)
    pub fn setRowDetails(self: *TreeExpander, opts: struct {
        item: ?*anyopaque = null,
        depth: u32 = 0,
        has_children: bool = false,
        expanded: bool = false,
        is_placeholder: bool = false,
    }) void {
        self.list_row.item = opts.item;
        self.list_row.depth = opts.depth;
        self.list_row.has_children = opts.has_children;
        self.list_row.expanded = opts.expanded;
        self.list_row.is_placeholder = opts.is_placeholder;
        self.base.markLayoutDirty();
        self.base.markDirty();
    }

    pub fn getListRow(self: *const TreeExpander) TreeListRow {
        return self.list_row;
    }

    pub fn getListRowPtr(self: *TreeExpander) *TreeListRow {
        return &self.list_row;
    }

    pub fn setExpanded(self: *TreeExpander, expanded: bool) void {
        if (self.list_row.expanded != expanded) {
            self.list_row.expanded = expanded;
            self.base.markDirty();
            if (self.on_toggle) |cb| cb(self, expanded);
        }
    }

    pub fn isExpanded(self: *const TreeExpander) bool {
        return self.list_row.expanded;
    }

    pub fn toggleExpanded(self: *TreeExpander) void {
        self.setExpanded(!self.list_row.expanded);
    }

    pub fn setDepth(self: *TreeExpander, depth: u32) void {
        self.list_row.depth = depth;
        self.base.markLayoutDirty();
    }

    pub fn setHasChildren(self: *TreeExpander, has: bool) void {
        self.list_row.has_children = has;
        self.base.markDirty();
        self.base.markDirty();
    }

    fn indentPx(self: *const TreeExpander) f32 {
        return @as(f32, @floatFromInt(self.list_row.depth)) * 20;
    }

    const EXPANDER_SIZE: f32 = 20; // 展开图标的区域尺寸
    const EXPANDER_ICON: f32 = 12; // 图标的实际绘制尺寸
};

const vtable = Widget.VTable{
    .type_name = "tree_expander",
    .measure = measure,
    .paint = paint,
    .on_event = onEvent,
    .focusable = true,
    .destroy = destroyVTable,
};

fn destroyVTable(w: *Widget, allocator: Allocator) void {
    const self: *TreeExpander = @fieldParentPtr("base", w);
    self.destroy(allocator);
}

fn measure(w: *Widget, ctx: *PaintContext, constraints: layout_mod.Constraints) math.Size {
    const self: *TreeExpander = @fieldParentPtr("base", w);
    const indent = self.indentPx();
    var mw: f32 = indent;
    var mh: f32 = EXPANDER_SIZE;
    const show_exp = !self.hide_expander and (self.list_row.has_children or self.indent_for_icon);
    if (show_exp) mw += EXPANDER_SIZE;

    if (self.child) |c| {
        const c_avail: math.Size = .{
            .width = @max(0, constraints.max_width - mw),
            .height = constraints.max_height,
        };
        const sz = Widget.measureChild(c, c_avail);
        mw += sz.width;
        mh = @max(mh, sz.height);
    }
    _ = ctx;
    return .{ .width = mw, .height = mh };
}

fn paint(w: *Widget, ctx: *PaintContext) void {
    const self: *TreeExpander = @fieldParentPtr("base", w);
    const rx = ctx.offset_x + w.rect.x;
    const ry = ctx.offset_y + w.rect.y;
    const rw = w.rect.width;
    const rh = w.rect.height;
    const indent = self.indentPx();
    const show_exp = !self.hide_expander and (self.list_row.has_children or self.indent_for_icon);

    // 绘制背景
    const bg = math.Color.hex(0x0F172A00);
    if (bg.a > 0) ctx.renderer.fillRect(.{ .x = rx, .y = ry, .width = rw, .height = rh }, bg) catch {};

    var x_cursor = rx + indent;

    // 绘制展开箭头
    if (show_exp) {
        const icon_box_x = x_cursor;
        const icon_box_y = ry + (rh - EXPANDER_SIZE) / 2;
        if (self.hover_expander and self.list_row.has_children) {
            ctx.renderer.fillRoundedRect(.{
                .x = icon_box_x,
                .y = icon_box_y,
                .width = EXPANDER_SIZE,
                .height = EXPANDER_SIZE,
            }, 4, math.Color.hex(0x33415566)) catch {};
        }
        if (self.list_row.has_children) {
            const icon: icons_mod.IconName = if (self.list_row.expanded) icons_mod.IconName.chevron_down else icons_mod.IconName.chevron_right;
            const ix = icon_box_x + (EXPANDER_SIZE - EXPANDER_ICON) / 2;
            const iy = icon_box_y + (EXPANDER_SIZE - EXPANDER_ICON) / 2;
            icons_mod.drawIcon(ctx.allocator, ctx.renderer, icon, .{
                .x = ix,
                .y = iy,
                .size = EXPANDER_ICON,
                .color = math.Color.hex(0x94A3B8FF),
            }) catch {};
        }
        x_cursor += EXPANDER_SIZE;
    }

    // 绘制 child 内容
    if (self.child) |c| {
        const cw = rw - (x_cursor - rx);
        const ch = rh;
        c.rect = .{ .x = 0, .y = 0, .width = cw, .height = ch };
        var child_ctx = ctx.*;
        child_ctx.offset_x = x_cursor;
        child_ctx.offset_y = ry;
        c.paintTree(&child_ctx);
    }
}

fn onEvent(w: *Widget, event: *const Event, ectx: *EventContext) EventResult {
    const self: *TreeExpander = @fieldParentPtr("base", w);
    const abs_rect = w.absoluteRect();

    switch (event.*) {
        .mouse_move => |m| {
            const mx: f32 = @floatFromInt(m.x);
            const my: f32 = @floatFromInt(m.y);
            const rel_x = mx - abs_rect.x;
            const rel_y = my - abs_rect.y;
            const inside = rel_x >= 0 and rel_x <= abs_rect.width and rel_y >= 0 and rel_y <= abs_rect.height;
            const indent = self.indentPx();
            const show_exp = !self.hide_expander and (self.list_row.has_children or self.indent_for_icon);
            const exp_hit = show_exp and self.list_row.has_children and
                rel_x >= indent and rel_x <= indent + EXPANDER_SIZE;
            const new_hover = exp_hit and inside;
            if (new_hover != self.hover_expander) {
                self.hover_expander = new_hover;
                w.markDirty();
            }
            if (inside and exp_hit) return .handled;
        },
        .mouse_button => |mb| {
            if (mb.button == .left) {
                const mx: f32 = @floatFromInt(mb.x);
                const my: f32 = @floatFromInt(mb.y);
                const rel_x = mx - abs_rect.x;
                const rel_y = my - abs_rect.y;
                const inside = rel_x >= 0 and rel_x <= abs_rect.width and rel_y >= 0 and rel_y <= abs_rect.height;
                const indent = self.indentPx();
                const show_exp = !self.hide_expander and (self.list_row.has_children or self.indent_for_icon);
                const exp_hit = show_exp and self.list_row.has_children and
                    rel_x >= indent and rel_x <= indent + EXPANDER_SIZE;
                if (mb.state == .pressed and inside and exp_hit) {
                    self.toggleExpanded();
                    return .handled;
                }
            }
        },
        .key => |k| {
            if (k.state == .pressed) {
                if (k.key == .left and self.list_row.expanded and self.list_row.has_children) {
                    self.setExpanded(false);
                    return .handled;
                }
                if (k.key == .right and !self.list_row.expanded and self.list_row.has_children) {
                    self.setExpanded(true);
                    return .handled;
                }
                if (k.key == .space and self.list_row.has_children) {
                    self.toggleExpanded();
                    return .handled;
                }
            }
        },
        else => {},
    }

    // 未处理的事件交给 child
    if (self.child) |c| {
        return Widget.dispatchEvent(c, event, ectx);
    }
    return .ignored;
}
