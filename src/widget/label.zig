//! Label 控件 - 静态文本显示

const std = @import("std");
const math = @import("../math.zig");
const widget_mod = @import("widget.zig");
const layout_mod = @import("../layout/engine.zig");
const text_layout = @import("../text/layout.zig");
const coretext = @import("../text/coretext.zig");

const Widget = widget_mod.Widget;
const PaintContext = widget_mod.PaintContext;
const EventContext = widget_mod.EventContext;
const EventResult = widget_mod.EventResult;

pub const Label = struct {
    base: Widget,
    text: []const u8,
    font_size: f32,
    font_weight: u16,
    color: math.Color,

    pub fn create(allocator: std.mem.Allocator, text: []const u8, opts: struct {
        font_size: f32 = 14.0,
        font_weight: u16 = 400,
        color: math.Color = math.Color.hex(0xF8FAFCFF),
    }) !*Label {
        const self = try allocator.create(Label);
        self.* = .{
            .base = .{
                .vtable = &vtable,
                .id = widget_mod.genWidgetId(),
            },
            .text = text,
            .font_size = opts.font_size,
            .font_weight = opts.font_weight,
            .color = opts.color,
        };
        return self;
    }

    pub fn destroy(self: *Label, allocator: std.mem.Allocator) void {
        self.base.children.deinit(allocator);
        allocator.destroy(self);
    }

    pub fn setText(self: *Label, text: []const u8) void {
        self.text = text;
        self.base.markDirty();
        self.base.markLayoutDirty();
    }

    // ── VTable 实现 ──────────────────────────────────────────────────────────

    const vtable = Widget.VTable{
        .type_name = "label",
        .measure = measure,
        .paint = paint,
        .on_event = null,
        .focusable = false,
        .destroy = destroyVTable,
    };

    fn destroyVTable(w: *Widget, allocator: std.mem.Allocator) void {
        const self: *Label = @fieldParentPtr("base", w);
        self.destroy(allocator);
    }

    fn measure(w: *Widget, ctx: *PaintContext, constraints: layout_mod.Constraints) math.Size(f32) {
        const self: *Label = @fieldParentPtr("base", w);
        _ = ctx;

        // 使用 CoreText 测量文本宽度
        var font = coretext.CtFont.create(null, self.font_size, self.font_weight) catch {
            return .{ .width = 0, .height = self.font_size * 1.2 };
        };
        defer font.destroy();

        const text_w = font.measureText(self.text);
        const metrics = font.getMetrics();
        const text_h = metrics.line_height;

        _ = constraints;
        return .{ .width = text_w, .height = text_h };
    }

    fn paint(w: *Widget, ctx: *PaintContext) void {
        const self: *Label = @fieldParentPtr("base", w);
        if (self.text.len == 0) return;

        var font = coretext.CtFont.create(null, self.font_size, self.font_weight) catch return;
        defer font.destroy();

        var tl = text_layout.TextLayout.layout(
            ctx.allocator,
            &ctx.renderer.glyph_atlas.?,
            ctx.renderer.device,
            self.text,
            .{ .font = &font, .font_size = self.font_size },
        ) catch return;
        defer tl.deinit();

        ctx.renderer.drawText(
            &tl,
            ctx.offset_x + w.rect.x,
            ctx.offset_y + w.rect.y,
            self.color,
        ) catch {};
    }
};
