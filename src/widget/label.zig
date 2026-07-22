//! Label 控件 - 静态文本显示

const std = @import("std");
const math = @import("../math.zig");
const widget_mod = @import("widget.zig");
const layout_mod = @import("../layout/engine.zig");
const styled_text = @import("../text/styled_text.zig");

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
    /// 文本水平对齐方式 (默认左对齐)
    text_align: styled_text.TextAlign = .left,

    pub fn create(allocator: std.mem.Allocator, text: []const u8, opts: struct {
        font_size: f32 = 14.0,
        font_weight: u16 = 400,
        color: math.Color = math.Color.hex(0xF8FAFCFF),
        text_align: styled_text.TextAlign = .left,
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
            .text_align = opts.text_align,
        };
        return self;
    }

    pub fn destroy(self: *Label, allocator: std.mem.Allocator) void {
        self.base.background.deinit(allocator);
        self.base.children.deinit(allocator);
        allocator.destroy(self);
    }

    pub fn setText(self: *Label, text: []const u8) void {
        self.text = text;
        self.base.markDirty();
        self.base.markLayoutDirty();
    }

    /// 设置文本对齐方式 (左/居中/右/两端对齐)
    pub fn setTextAlign(self: *Label, alignment: styled_text.TextAlign) void {
        self.text_align = alignment;
        self.base.markDirty();
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
        _ = constraints;

        return styled_text.measureText(ctx.allocator, self.text, .{
            .font_size = self.font_size,
            .font_weight = self.font_weight,
        });
    }

    fn paint(w: *Widget, ctx: *PaintContext) void {
        const self: *Label = @fieldParentPtr("base", w);
        if (self.text.len == 0) return;

        // 对齐需要容器宽度; 左对齐 (默认) 不传 max_width, 保持原单行行为
        const max_w: ?f32 = if (self.text_align != .left) w.rect.width else null;

        styled_text.drawText(
            ctx.renderer,
            ctx.allocator,
            self.text,
            ctx.offset_x + w.rect.x,
            ctx.offset_y + w.rect.y,
            .{
                .font_size = self.font_size,
                .font_weight = self.font_weight,
                .color = self.color,
                .text_align = self.text_align,
                .max_width = max_w,
            },
        );
    }
};
