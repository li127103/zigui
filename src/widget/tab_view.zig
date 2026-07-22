//! TabView 控件 - 标签页容器

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

pub const TabView = struct {
    base: Widget,
    allocator: std.mem.Allocator,
    tabs: std.ArrayListUnmanaged(Tab),
    active: usize = 0,
    font_size: f32,
    on_change: ?*const fn (self: *TabView, index: usize) void,
    // 样式
    tab_bg: math.Color = math.Color.hex(0x1E293BFF),
    tab_active_bg: math.Color = math.Color.hex(0x0F172AFF),
    tab_text: math.Color = math.Color.hex(0x94A3B8FF),
    tab_active_text: math.Color = math.Color.hex(0xF8FAFCFF),
    indicator_color: math.Color = math.Color.hex(0x3B82F6FF),
    tab_height: f32 = 40.0,
    tab_padding_h: f32 = 20.0,
    corner_radius: f32 = 8.0,

    pub const Tab = struct {
        title: []const u8,
        content: ?*Widget = null,
    };

    pub fn create(allocator: std.mem.Allocator, opts: struct {
        font_size: f32 = 14.0,
        on_change: ?*const fn (self: *TabView, index: usize) void = null,
    }) !*TabView {
        const self = try allocator.create(TabView);
        self.* = .{
            .base = .{
                .vtable = &vtable,
                .id = widget_mod.genWidgetId(),
            },
            .allocator = allocator,
            .tabs = .{ .items = &.{}, .capacity = 0 },
            .font_size = opts.font_size,
            .on_change = opts.on_change,
        };
        return self;
    }

    pub fn destroy(self: *TabView, allocator: std.mem.Allocator) void {
        self.base.background.deinit(allocator);
        self.tabs.deinit(allocator);
        self.base.children.deinit(allocator);
        allocator.destroy(self);
    }

    pub fn addTab(self: *TabView, title: []const u8, content: ?*Widget) !void {
        try self.tabs.append(self.allocator, .{ .title = title, .content = content });
        self.base.markDirty();
    }

    pub fn setActive(self: *TabView, index: usize) void {
        if (index < self.tabs.items.len and index != self.active) {
            self.active = index;
            self.base.markDirty();
            if (self.on_change) |cb| cb(self, index);
        }
    }

    // ── VTable ──────────────────────────────────────────────────────────────

    const vtable = Widget.VTable{
        .type_name = "tab_view",
        .measure = measure,
        .paint = paint,
        .on_event = onEvent,
        .focusable = false,
        .destroy = destroyVTable,
    };

    fn destroyVTable(w: *Widget, allocator: std.mem.Allocator) void {
        const self: *TabView = @fieldParentPtr("base", w);
        self.destroy(allocator);
    }

    fn measure(w: *Widget, ctx: *PaintContext, constraints: layout_mod.Constraints) math.Size(f32) {
        const self: *TabView = @fieldParentPtr("base", w);
        _ = ctx;
        _ = constraints;
        _ = self;
        return .{ .width = 400, .height = 300 };
    }

    fn paint(w: *Widget, ctx: *PaintContext) void {
        const self: *TabView = @fieldParentPtr("base", w);
        const rx = ctx.offset_x + w.rect.x;
        const ry = ctx.offset_y + w.rect.y;
        const rw = w.rect.width;

        // 标签栏背景
        ctx.renderer.fillRect(
            .{ .x = rx, .y = ry, .width = rw, .height = self.tab_height },
            self.tab_bg,
        ) catch {};

        // 各标签
        var tab_x: f32 = rx;
        for (self.tabs.items, 0..) |tab, i| {
            const title_w = self.measureText(ctx, tab.title);
            const tab_w = title_w + self.tab_padding_h * 2;

            if (i == self.active) {
                // 活跃标签背景
                ctx.renderer.fillRect(
                    .{ .x = tab_x, .y = ry, .width = tab_w, .height = self.tab_height },
                    self.tab_active_bg,
                ) catch {};
                // 底部指示条
                ctx.renderer.fillRect(
                    .{ .x = tab_x, .y = ry + self.tab_height - 3, .width = tab_w, .height = 3 },
                    self.indicator_color,
                ) catch {};
            }

            // 标签文本
            const text_color = if (i == self.active) self.tab_active_text else self.tab_text;
            self.drawLabel(ctx, tab.title, tab_x + self.tab_padding_h, ry + (self.tab_height - self.font_size * 1.2) / 2.0, text_color);

            tab_x += tab_w;
        }

        // 内容区分隔线
        ctx.renderer.fillRect(
            .{ .x = rx, .y = ry + self.tab_height, .width = rw, .height = 1 },
            math.Color.hex(0x334155FF),
        ) catch {};
    }

    fn measureText(self: *TabView, ctx: *PaintContext, text: []const u8) f32 {
        var font = coretext.CtFont.create(null, self.font_size, 500) catch return 60;
        defer font.destroy();
        _ = ctx;
        return font.measureText(text);
    }

    fn drawLabel(self: *TabView, ctx: *PaintContext, text: []const u8, x: f32, y: f32, color: math.Color) void {
        var font = coretext.CtFont.create(null, self.font_size, 500) catch return;
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
        const self: *TabView = @fieldParentPtr("base", w);
        _ = ectx;

        switch (event.*) {
            .mouse_button => |mb| {
                if (mb.button == .left and mb.state == .pressed) {
                    const mx: f32 = @floatFromInt(mb.x);
                    const my: f32 = @floatFromInt(mb.y);

                    // 只在标签栏区域响应
                    if (my >= 0 and my < self.tab_height) {
                        var tab_x: f32 = 0;
                        for (self.tabs.items, 0..) |tab, i| {
                            const title_w = self.measureTextStatic(tab.title);
                            const tab_w = title_w + self.tab_padding_h * 2;
                            if (mx >= tab_x and mx < tab_x + tab_w) {
                                self.setActive(i);
                                return .handled;
                            }
                            tab_x += tab_w;
                        }
                    }
                }
            },
            else => {},
        }
        return .ignored;
    }

    fn measureTextStatic(text: []const u8) f32 {
        var font = coretext.CtFont.create(null, 14.0, 500) catch return 60;
        defer font.destroy();
        return font.measureText(text);
    }
};
