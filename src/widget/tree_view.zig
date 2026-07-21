//! TreeView 控件 - 可展开/折叠的树形视图
//!
//! 递归节点结构, 按展开状态扁平化为可见行并虚拟化渲染。
//! 支持点击展开/折叠 (展开三角形)、选中、键盘导航。

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

/// 树节点 (递归)
pub const Node = struct {
    label: []const u8,
    expanded: bool = true,
    children: std.ArrayListUnmanaged(*Node) = .{ .items = &.{}, .capacity = 0 },
};

/// 扁平化后的可见行
const Row = struct {
    node: *Node,
    depth: u32,
};

pub const TreeView = struct {
    base: Widget,
    allocator: std.mem.Allocator,
    roots: std.ArrayListUnmanaged(*Node),
    selected: ?*Node = null,
    hovered: ?*Node = null,
    scroll_offset: f32 = 0,
    row_height: f32,
    indent: f32,
    font_size: f32,
    on_select: ?*const fn (self: *TreeView, node: *Node) void,
    // 样式
    bg_color: math.Color = math.Color.hex(0x0F172AFF),
    hover_bg: math.Color = math.Color.hex(0x334155FF),
    selected_bg: math.Color = math.Color.hex(0x3B82F633),
    text_color: math.Color = math.Color.hex(0xF8FAFCFF),
    triangle_color: math.Color = math.Color.hex(0x94A3B8FF),
    scrollbar_color: math.Color = math.Color.hex(0x475569FF),
    corner_radius: f32 = 10.0,

    pub fn create(allocator: std.mem.Allocator, opts: struct {
        row_height: f32 = 32.0,
        indent: f32 = 20.0,
        font_size: f32 = 14.0,
        on_select: ?*const fn (self: *TreeView, node: *Node) void = null,
    }) !*TreeView {
        const self = try allocator.create(TreeView);
        self.* = .{
            .base = .{
                .vtable = &vtable,
                .id = widget_mod.genWidgetId(),
            },
            .allocator = allocator,
            .roots = .{ .items = &.{}, .capacity = 0 },
            .row_height = opts.row_height,
            .indent = opts.indent,
            .font_size = opts.font_size,
            .on_select = opts.on_select,
        };
        return self;
    }

    pub fn destroy(self: *TreeView, allocator: std.mem.Allocator) void {
        for (self.roots.items) |r| freeNode(allocator, r);
        self.roots.deinit(allocator);
        self.base.children.deinit(allocator);
        allocator.destroy(self);
    }

    pub fn freeNode(allocator: std.mem.Allocator, node: *Node) void {
        for (node.children.items) |c| freeNode(allocator, c);
        node.children.deinit(allocator);
        allocator.destroy(node);
    }

    /// 添加根节点
    pub fn addRoot(self: *TreeView, label: []const u8) !*Node {
        const node = try self.allocator.create(Node);
        node.* = .{ .label = label };
        try self.roots.append(self.allocator, node);
        self.base.markDirty();
        return node;
    }

    /// 为指定节点添加子节点
    pub fn addChild(self: *TreeView, parent: *Node, label: []const u8) !*Node {
        const node = try self.allocator.create(Node);
        node.* = .{ .label = label };
        try parent.children.append(self.allocator, node);
        self.base.markDirty();
        return node;
    }

    /// 按展开状态扁平化为可见行 (调用方负责 deinit)
    fn flattenVisible(self: *TreeView, out: *std.ArrayListUnmanaged(Row)) !void {
        for (self.roots.items) |r| {
            try flattenNode(self.allocator, out, r, 0);
        }
    }

    fn flattenNode(alloc: std.mem.Allocator, out: *std.ArrayListUnmanaged(Row), node: *Node, depth: u32) !void {
        try out.append(alloc, .{ .node = node, .depth = depth });
        if (node.expanded) {
            for (node.children.items) |c| {
                try flattenNode(alloc, out, c, depth + 1);
            }
        }
    }

    fn rowCount(self: *TreeView) usize {
        var list: std.ArrayListUnmanaged(Row) = .{ .items = &.{}, .capacity = 0 };
        defer list.deinit(self.allocator);
        self.flattenVisible(&list) catch return 0;
        return list.items.len;
    }

    fn totalHeight(self: *TreeView) f32 {
        return @as(f32, @floatFromInt(self.rowCount())) * self.row_height;
    }

    fn maxScroll(self: *TreeView) f32 {
        return @max(0, self.totalHeight() - self.base.rect.height);
    }

    // ── VTable ──────────────────────────────────────────────────────────────

    const vtable = Widget.VTable{
        .type_name = "tree_view",
        .measure = measure,
        .paint = paint,
        .on_event = onEvent,
        .focusable = true,
        .destroy = destroyVTable,
    };

    fn destroyVTable(w: *Widget, allocator: std.mem.Allocator) void {
        const self: *TreeView = @fieldParentPtr("base", w);
        self.destroy(allocator);
    }

    fn measure(w: *Widget, ctx: *PaintContext, constraints: layout_mod.Constraints) math.Size(f32) {
        _ = ctx;
        _ = constraints;
        _ = w;
        return .{ .width = 300, .height = 400 };
    }

    fn paint(w: *Widget, ctx: *PaintContext) void {
        const self: *TreeView = @fieldParentPtr("base", w);
        const rx = ctx.offset_x + w.rect.x;
        const ry = ctx.offset_y + w.rect.y;
        const rw = w.rect.width;
        const rh = w.rect.height;

        ctx.renderer.fillRoundedRect(.{ .x = rx, .y = ry, .width = rw, .height = rh }, self.corner_radius, self.bg_color) catch {};

        var rows: std.ArrayListUnmanaged(Row) = .{ .items = &.{}, .capacity = 0 };
        defer rows.deinit(self.allocator);
        self.flattenVisible(&rows) catch return;

        const start: usize = @intFromFloat(@max(0, @floor(self.scroll_offset / self.row_height)));
        const end = @min(rows.items.len, start + @as(usize, @intFromFloat(@ceil(rh / self.row_height))) + 1);

        var i: usize = start;
        while (i < end) : (i += 1) {
            const row = rows.items[i];
            const row_y = ry + @as(f32, @floatFromInt(i)) * self.row_height - self.scroll_offset;
            if (row_y + self.row_height < ry or row_y > ry + rh) continue;

            // 选中 / 悬停背景
            if (self.selected != null and self.selected.? == row.node) {
                ctx.renderer.fillRoundedRect(.{ .x = rx + 4, .y = row_y, .width = rw - 12, .height = self.row_height }, 6, self.selected_bg) catch {};
            } else if (self.hovered != null and self.hovered.? == row.node) {
                ctx.renderer.fillRoundedRect(.{ .x = rx + 4, .y = row_y, .width = rw - 12, .height = self.row_height }, 6, self.hover_bg) catch {};
            }

            const indent_x = rx + 8 + @as(f32, @floatFromInt(row.depth)) * self.indent;
            const cy = row_y + self.row_height / 2.0;

            // 展开三角形 (仅有子节点时)
            if (row.node.children.items.len > 0) {
                self.drawDisclosure(ctx, indent_x, cy, row.node.expanded);
            }

            // 标签文本
            const text_x = indent_x + self.indent * 0.7;
            self.drawLabel(ctx, row.node.label, text_x, row_y + (self.row_height - self.font_size * 1.2) / 2.0, self.text_color);
        }

        // 滚动条
        const total = self.totalHeight();
        if (total > rh) {
            const sb_h = @max(20.0, rh * (rh / total));
            const sb_y = ry + (self.scroll_offset / self.maxScroll()) * (rh - sb_h);
            ctx.renderer.fillRoundedRect(.{ .x = rx + rw - 5, .y = sb_y, .width = 3, .height = sb_h }, 1.5, self.scrollbar_color) catch {};
        }
    }

    /// 用水平切片近似绘制展开三角形 (▼ 展开 / ▶ 折叠)
    fn drawDisclosure(self: *TreeView, ctx: *PaintContext, x: f32, cy: f32, expanded: bool) void {
        const size: f32 = 8.0;
        const slices: u32 = 4;
        const slice_h = size / @as(f32, @floatFromInt(slices));
        var s: u32 = 0;
        while (s < slices) : (s += 1) {
            const f = @as(f32, @floatFromInt(s)) / @as(f32, @floatFromInt(slices));
            // 展开(▼): 上宽下窄; 折叠(▶): 上窄下宽 (近似右指向)
            const frac = if (expanded) (1.0 - f) else (f * 0.6 + 0.2);
            const w = size * frac;
            const yy = cy - size / 2.0 + @as(f32, @floatFromInt(s)) * slice_h;
            const xx = if (expanded) x + (size - w) / 2.0 else x;
            ctx.renderer.fillRect(.{ .x = xx, .y = yy, .width = w, .height = slice_h + 0.5 }, self.triangle_color) catch {};
        }
    }

    fn drawLabel(self: *TreeView, ctx: *PaintContext, text: []const u8, x: f32, y: f32, color: math.Color) void {
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
        const self: *TreeView = @fieldParentPtr("base", w);
        _ = ectx;

        switch (event.*) {
            .scroll => |sc| {
                self.scroll_offset = std.math.clamp(self.scroll_offset - sc.delta * 30.0, 0, self.maxScroll());
                self.base.markDirty();
                return .handled;
            },
            .mouse_move => |mm| {
                const my: f32 = @floatFromInt(mm.y);
                const node = self.nodeAtY(my);
                if (node != self.hovered) {
                    self.hovered = node;
                    self.base.markDirty();
                }
            },
            .mouse_button => |mb| {
                if (mb.button == .left and mb.state == .pressed) {
                    const mx: f32 = @floatFromInt(mb.x);
                    const my: f32 = @floatFromInt(mb.y);
                    if (self.rowAtY(my)) |idx| {
                        var rows: std.ArrayListUnmanaged(Row) = .{ .items = &.{}, .capacity = 0 };
                        defer rows.deinit(self.allocator);
                        self.flattenVisible(&rows) catch return .ignored;
                        if (idx >= rows.items.len) return .ignored;
                        const row = rows.items[idx];

                        // 点击展开三角形区域 → 切换展开/折叠
                        const indent_x = 8 + @as(f32, @floatFromInt(row.depth)) * self.indent;
                        if (row.node.children.items.len > 0 and mx >= indent_x and mx < indent_x + self.indent * 0.7) {
                            row.node.expanded = !row.node.expanded;
                            self.base.markDirty();
                            return .handled;
                        }
                        // 否则选中
                        self.selected = row.node;
                        self.base.markDirty();
                        if (self.on_select) |cb| cb(self, row.node);
                        return .handled;
                    }
                }
            },
            .key => |k| {
                if (k.state != .pressed or !w.state.focused) return .ignored;
                switch (k.key) {
                    .up => return self.moveSelection(-1),
                    .down => return self.moveSelection(1),
                    .left => {
                        if (self.selected) |sel| {
                            if (sel.expanded and sel.children.items.len > 0) {
                                sel.expanded = false;
                                self.base.markDirty();
                                return .handled;
                            }
                        }
                    },
                    .right => {
                        if (self.selected) |sel| {
                            if (!sel.expanded and sel.children.items.len > 0) {
                                sel.expanded = true;
                                self.base.markDirty();
                                return .handled;
                            }
                        }
                    },
                    else => {},
                }
            },
            else => {},
        }
        return .ignored;
    }

    /// 键盘上下移动选中 (在可见行间)
    fn moveSelection(self: *TreeView, dir: i32) EventResult {
        var rows: std.ArrayListUnmanaged(Row) = .{ .items = &.{}, .capacity = 0 };
        defer rows.deinit(self.allocator);
        self.flattenVisible(&rows) catch return .ignored;
        if (rows.items.len == 0) return .ignored;

        var cur: usize = 0;
        if (self.selected) |sel| {
            for (rows.items, 0..) |r, i| {
                if (r.node == sel) {
                    cur = i;
                    break;
                }
            }
            const next_i: i32 = @as(i32, @intCast(cur)) + dir;
            if (next_i < 0 or next_i >= @as(i32, @intCast(rows.items.len))) return .handled;
            cur = @intCast(next_i);
        }
        self.selected = rows.items[cur].node;
        self.scrollToVisible(cur);
        self.base.markDirty();
        return .handled;
    }

    fn rowAtY(self: *TreeView, y: f32) ?usize {
        if (y < 0 or y >= self.base.rect.height) return null;
        const idx: usize = @intFromFloat((y + self.scroll_offset) / self.row_height);
        if (idx < self.rowCount()) return idx;
        return null;
    }

    fn nodeAtY(self: *TreeView, y: f32) ?*Node {
        const idx = self.rowAtY(y) orelse return null;
        var rows: std.ArrayListUnmanaged(Row) = .{ .items = &.{}, .capacity = 0 };
        defer rows.deinit(self.allocator);
        self.flattenVisible(&rows) catch return null;
        if (idx < rows.items.len) return rows.items[idx].node;
        return null;
    }

    fn scrollToVisible(self: *TreeView, index: usize) void {
        const top = @as(f32, @floatFromInt(index)) * self.row_height;
        const bottom = top + self.row_height;
        const view_h = self.base.rect.height;
        if (top < self.scroll_offset) {
            self.scroll_offset = top;
        } else if (bottom > self.scroll_offset + view_h) {
            self.scroll_offset = bottom - view_h;
        }
        self.scroll_offset = std.math.clamp(self.scroll_offset, 0, self.maxScroll());
    }
};

// ── 测试 ──────────────────────────────────────────────────────────────────

test "tree_view flatten respects expanded" {
    const alloc = std.testing.allocator;
    var tv = TreeView{
        .base = .{ .vtable = undefined, .id = 1 },
        .allocator = alloc,
        .roots = .{ .items = &.{}, .capacity = 0 },
        .row_height = 32,
        .indent = 20,
        .font_size = 14,
        .on_select = null,
    };
    defer {
        for (tv.roots.items) |r| TreeView.freeNode(alloc, r);
        tv.roots.deinit(alloc);
    }

    const root = try tv.addRoot("root");
    const c1 = try tv.addChild(root, "c1");
    _ = try tv.addChild(c1, "c1.1");
    _ = try tv.addChild(root, "c2");

    // 全部展开: root, c1, c1.1, c2 = 4 行
    try std.testing.expectEqual(@as(usize, 4), tv.rowCount());

    // 折叠 root: 仅 root = 1 行
    root.expanded = false;
    try std.testing.expectEqual(@as(usize, 1), tv.rowCount());

    // 展开 root, 折叠 c1: root, c1, c2 = 3 行
    root.expanded = true;
    c1.expanded = false;
    try std.testing.expectEqual(@as(usize, 3), tv.rowCount());
}
