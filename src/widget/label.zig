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

pub const EllipsizeMode = enum { none, end };

pub const Label = struct {
    base: Widget,
    text: []const u8,
    font_size: f32,
    font_weight: u16,
    color: math.Color,
    /// 文本水平对齐方式 (默认左对齐)
    text_align: styled_text.TextAlign = .left,
    /// 是否解析富文本标记 (<b>/<i>/<color>/<size>)
    use_markup: bool = false,
    /// 是否自动换行 (按容器宽度)
    wrap: bool = false,
    /// 省略模式 (none=不截断, end=末尾加省略号)
    ellipsize: EllipsizeMode = .none,
    /// 最大行数 (0=无限; 仅 wrap 时生效)
    max_lines: u32 = 0,
    /// 解析后的 span 缓存
    cached_spans: ?[]styled_text.TextSpan = null,
    cached_spans_allocator: ?std.mem.Allocator = null,

    pub fn create(allocator: std.mem.Allocator, text: []const u8, opts: struct {
        font_size: f32 = 14.0,
        font_weight: u16 = 400,
        color: math.Color = math.Color.hex(0xF8FAFCFF),
        text_align: styled_text.TextAlign = .left,
        use_markup: bool = false,
        wrap: bool = false,
        ellipsize: EllipsizeMode = .none,
        max_lines: u32 = 0,
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
            .use_markup = opts.use_markup,
            .wrap = opts.wrap,
            .ellipsize = opts.ellipsize,
            .max_lines = opts.max_lines,
        };
        return self;
    }

    pub fn destroy(self: *Label, allocator: std.mem.Allocator) void {
        if (self.cached_spans) |spans| {
            self.cached_spans_allocator.?.free(spans);
        }
        self.base.background.deinit(allocator);
        self.base.children.deinit(allocator);
        allocator.destroy(self);
    }

    pub fn setText(self: *Label, text: []const u8) void {
        self.text = text;
        self.invalidateSpans();
        self.base.markDirty();
        self.base.markLayoutDirty();
    }

    pub fn setTextAlign(self: *Label, alignment: styled_text.TextAlign) void {
        self.text_align = alignment;
        self.base.markDirty();
    }

    /// 启用/禁用富文本标记解析
    pub fn setUseMarkup(self: *Label, enable: bool) void {
        self.use_markup = enable;
        self.invalidateSpans();
        self.base.markDirty();
        self.base.markLayoutDirty();
    }

    fn invalidateSpans(self: *Label) void {
        if (self.cached_spans) |spans| {
            self.cached_spans_allocator.?.free(spans);
            self.cached_spans = null;
            self.cached_spans_allocator = null;
        }
    }

    fn ensureSpans(self: *Label, allocator: std.mem.Allocator) []const styled_text.TextSpan {
        if (self.cached_spans == null) {
            const base_style = styled_text.TextStyle{
                .font_size = self.font_size,
                .font_weight = self.font_weight,
                .color = self.color,
            };
            self.cached_spans = styled_text.parseMarkup(allocator, self.text, base_style) catch &.{};
            self.cached_spans_allocator = allocator;
        }
        return self.cached_spans.?;
    }

    // ── VTable 实现 ──────────────────────────────────────────────────────────

    const vtable = Widget.VTable{
        .type_name = "label",
        .measure = measure,
        .measure_height_for_width = measureHeightForWidth,
        .get_baseline = getBaseline,
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

        if (self.use_markup) {
            const spans = self.ensureSpans(ctx.allocator);
            return styled_text.measureSpans(ctx.allocator, spans);
        }

        // wrap: 传入 max_width 启用自动换行
        const max_w: ?f32 = if (self.wrap and constraints.max_width < std.math.inf(f32))
            constraints.max_width
        else if (self.ellipsize == .end and constraints.max_width < std.math.inf(f32))
            constraints.max_width
        else if (self.text_align != .left and constraints.max_width < std.math.inf(f32))
            constraints.max_width
        else
            null;

        return styled_text.measureText(ctx.allocator, self.text, .{
            .font_size = self.font_size,
            .font_weight = self.font_weight,
            .max_width = max_w,
            .text_align = self.text_align,
        });
    }

    fn measureHeightForWidth(w: *Widget, ctx: *PaintContext, width: f32) f32 {
        const self: *Label = @fieldParentPtr("base", w);

        if (self.use_markup) {
            const spans = self.ensureSpans(ctx.allocator);
            const size = styled_text.measureSpans(ctx.allocator, spans);
            return size.height;
        }

        const max_w: ?f32 = if (self.wrap or self.ellipsize == .end or self.text_align != .left) width else null;

        const size = styled_text.measureText(ctx.allocator, self.text, .{
            .font_size = self.font_size,
            .font_weight = self.font_weight,
            .max_width = max_w,
            .text_align = self.text_align,
        });
        return size.height;
    }

    fn getBaseline(w: *Widget, ctx: *PaintContext, height: f32) f32 {
        const self: *Label = @fieldParentPtr("base", w);
        _ = height;
        return styled_text.getFontAscent(ctx.allocator, self.font_size, self.font_weight);
    }

    fn paint(w: *Widget, ctx: *PaintContext) void {
        const self: *Label = @fieldParentPtr("base", w);
        if (self.text.len == 0) return;

        const rx = ctx.offset_x + w.rect.x;
        const ry = ctx.offset_y + w.rect.y;

        if (self.use_markup) {
            const spans = self.ensureSpans(ctx.allocator);
            // 居中对齐时计算偏移
            const total_size = styled_text.measureSpans(ctx.allocator, spans);
            var draw_x = rx;
            if (self.text_align == .center) {
                draw_x = rx + (w.rect.width - total_size.width) / 2.0;
            } else if (self.text_align == .right) {
                draw_x = rx + (w.rect.width - total_size.width);
            }
            const draw_y = ry + (w.rect.height - total_size.height) / 2.0;
            styled_text.drawSpans(ctx.renderer, ctx.allocator, spans, draw_x, draw_y);
            return;
        }

        // 对齐/wrap/ellipsize 需要容器宽度
        const max_w: ?f32 = if (self.wrap or self.ellipsize == .end or self.text_align != .left) w.rect.width else null;

        if (self.ellipsize == .end) {
            _ = styled_text.drawTextClipped(
                ctx.renderer,
                ctx.allocator,
                self.text,
                rx,
                ry,
                .{
                    .font_size = self.font_size,
                    .font_weight = self.font_weight,
                    .color = self.color,
                    .text_align = self.text_align,
                    .max_width = max_w,
                },
                max_w orelse w.rect.width,
            );
        } else {
            styled_text.drawText(
                ctx.renderer,
                ctx.allocator,
                self.text,
                rx,
                ry,
                .{
                    .font_size = self.font_size,
                    .font_weight = self.font_weight,
                    .color = self.color,
                    .text_align = self.text_align,
                    .max_width = max_w,
                },
            );
        }
    }
};
