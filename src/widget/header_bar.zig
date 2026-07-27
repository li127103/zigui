//! HeaderBar 控件 - 标题栏容器
//!
//! 类似 GtkHeaderBar: 窗口标题栏, 包含标题文本和操作按钮。
//! 水平布局: 左侧按钮 | 中间标题 | 右侧按钮

const std = @import("std");
const math = @import("../math.zig");
const widget_mod = @import("widget.zig");
const layout_mod = @import("../layout/engine.zig");
const styled_text = @import("../text/styled_text.zig");

const Widget = widget_mod.Widget;
const PaintContext = widget_mod.PaintContext;

pub const HeaderBar = struct {
    base: Widget,
    allocator: std.mem.Allocator,
    title: []const u8 = "",
    title_color: math.Color = math.Color.hex(0xF8FAFCFF),
    title_size: f32 = 14,
    title_weight: u16 = 600,
    /// 标题是否居中
    centered: bool = true,

    pub fn create(allocator: std.mem.Allocator, opts: struct {
        title: []const u8 = "",
        bg_color: ?math.Color = null,
        title_color: ?math.Color = null,
        title_size: f32 = 14,
        title_weight: u16 = 600,
        height: f32 = 46,
        spacing: f32 = 8,
        padding: f32 = 12,
        centered: bool = true,
    }) !*HeaderBar {
        const self = try allocator.create(HeaderBar);
        self.* = .{
            .base = .{
                .vtable = &vtable,
                .id = widget_mod.genWidgetId(),
            },
            .allocator = allocator,
            .title = opts.title,
            .title_size = opts.title_size,
            .title_weight = opts.title_weight,
            .centered = opts.centered,
        };
        if (opts.bg_color) |c| {
            self.base.background.bg = .{ .color = c };
        }
        if (opts.title_color) |c| self.title_color = c;
        self.base.layout_style.direction = .row;
        self.base.layout_style.align_items = .center;
        self.base.layout_style.gap = .{ .width = opts.spacing, .height = 0 };
        self.base.layout_style.padding = .{
            .top = opts.padding,
            .bottom = opts.padding,
            .left = opts.padding,
            .right = opts.padding,
        };
        self.base.rect.height = opts.height;
        self.base.layout_style.height = .{ .px = opts.height };
        self.base.accessibility = .{ .role = .title_bar };
        return self;
    }

    pub fn destroy(self: *HeaderBar, allocator: std.mem.Allocator) void {
        self.base.background.deinit(allocator);
        for (self.base.children.items) |child| {
            child.vtable.destroy(child, allocator);
        }
        self.base.children.deinit(allocator);
        allocator.destroy(self);
    }

    pub fn setTitle(self: *HeaderBar, title: []const u8) void {
        self.title = title;
        self.base.markDirty();
    }

    pub fn addChild(self: *HeaderBar, child: *Widget) !void {
        try self.base.addChild(self.allocator, child);
    }

    // ── VTable 实现 ──────────────────────────────────────────────────────────

    const vtable = Widget.VTable{
        .type_name = "header_bar",
        .measure = measure,
        .paint = paint,
        .on_event = null,
        .focusable = false,
        .destroy = destroyVTable,
    };

    fn destroyVTable(w: *Widget, allocator: std.mem.Allocator) void {
        const self: *HeaderBar = @fieldParentPtr("base", w);
        self.destroy(allocator);
    }

    fn measure(w: *Widget, ctx: *PaintContext, constraints: layout_mod.Constraints) math.Size(f32) {
        _ = ctx;
        return .{
            .width = constraints.max_width,
            .height = w.rect.height,
        };
    }

    fn paint(w: *Widget, ctx: *PaintContext) void {
        const self: *HeaderBar = @fieldParentPtr("base", w);
        if (self.title.len == 0) return;

        const r = w.rect;
        const pad = w.layout_style.padding;

        const text_size = styled_text.measureText(ctx.allocator, self.title, .{
            .font_size = self.title_size,
            .font_weight = self.title_weight,
        });

        var tx: f32 = 0;
        const ty = r.y + (r.height - text_size.height) / 2;

        if (self.centered) {
            tx = r.x + (r.width - text_size.width) / 2;
        } else {
            tx = r.x + pad.left;
            // 如果有左侧子元素, 从左子元素后面开始
            if (w.children.items.len > 0) {
                const first = w.children.items[0];
                tx = @max(tx, first.rect.x + first.rect.width + 8);
            }
        }

        styled_text.drawText(
            ctx.renderer,
            ctx.allocator,
            self.title,
            ctx.offset_x + tx,
            ctx.offset_y + ty,
            .{
                .font_size = self.title_size,
                .font_weight = self.title_weight,
                .color = self.title_color,
            },
        );
    }
};
