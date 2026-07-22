//! Tooltip 控件 - 工具提示

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

pub const Tooltip = struct {
    base: Widget,
    text: []const u8,
    visible: bool = false,
    pos_x: f32 = 0,
    pos_y: f32 = 0,
    delay_ms: u32 = 500,
    hover_ms: u32 = 0,
    font_size: f32 = 12.0,
    // 样式
    bg_color: math.Color = math.Color.hex(0x334155FF),
    text_color: math.Color = math.Color.hex(0xF8FAFCFF),
    corner_radius: f32 = 6.0,
    padding_h: f32 = 10.0,
    padding_v: f32 = 6.0,

    pub fn create(allocator: std.mem.Allocator, text: []const u8) !*Tooltip {
        const self = try allocator.create(Tooltip);
        self.* = .{
            .base = .{
                .vtable = &vtable,
                .id = widget_mod.genWidgetId(),
            },
            .text = text,
        };
        return self;
    }

    pub fn destroy(self: *Tooltip, allocator: std.mem.Allocator) void {
        self.base.background.deinit(allocator);
        self.base.children.deinit(allocator);
        allocator.destroy(self);
    }

    pub fn showAt(self: *Tooltip, x: f32, y: f32) void {
        self.pos_x = x;
        self.pos_y = y;
        self.visible = true;
        self.base.markDirty();
    }

    pub fn hideTooltip(self: *Tooltip) void {
        self.visible = false;
        self.hover_ms = 0;
        self.base.markDirty();
    }

    // ── VTable ──────────────────────────────────────────────────────────────

    const vtable = Widget.VTable{
        .type_name = "tooltip",
        .measure = measure,
        .paint = paint,
        .on_event = null,
        .focusable = false,
        .destroy = destroyVTable,
    };

    fn destroyVTable(w: *Widget, allocator: std.mem.Allocator) void {
        const self: *Tooltip = @fieldParentPtr("base", w);
        self.destroy(allocator);
    }

    fn measure(w: *Widget, ctx: *PaintContext, constraints: layout_mod.Constraints) math.Size(f32) {
        _ = w;
        _ = ctx;
        _ = constraints;
        return .{ .width = 0, .height = 0 };
    }

    fn paint(w: *Widget, ctx: *PaintContext) void {
        const self: *Tooltip = @fieldParentPtr("base", w);
        if (!self.visible or self.text.len == 0) return;

        // 测量文本
        var font = coretext.CtFont.create(null, self.font_size, 400) catch return;
        defer font.destroy();
        const text_w = font.measureText(self.text);

        const tw = text_w + self.padding_h * 2;
        const th = self.font_size * 1.2 + self.padding_v * 2;

        // 定位 (在鼠标上方)
        const tx = ctx.offset_x + self.pos_x - tw / 2.0;
        const ty = ctx.offset_y + self.pos_y - th - 8;

        // 背景
        ctx.renderer.fillRoundedRect(.{ .x = tx, .y = ty, .width = tw, .height = th }, self.corner_radius, self.bg_color) catch {};

        // 小三角 (简化: 小矩形)
        ctx.renderer.fillRect(.{ .x = ctx.offset_x + self.pos_x - 4, .y = ty + th, .width = 8, .height = 4 }, self.bg_color) catch {};

        // 文本
        var tl = text_layout.TextLayout.layout(
            ctx.allocator,
            &ctx.renderer.glyph_atlas.?,
            ctx.renderer.device,
            self.text,
            .{ .font = &font, .font_size = self.font_size },
        ) catch return;
        defer tl.deinit();

        ctx.renderer.drawText(&tl, tx + self.padding_h, ty + self.padding_v, self.text_color) catch {};
    }
};
