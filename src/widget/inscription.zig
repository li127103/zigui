//! Inscription 控件 - GTK4 简单文本显示控件
//!
//! 对应 GtkInscription: GTK4 新增的轻量级文本显示控件,
//! 是 Label 的简化版。重点特点:
//! - 支持 min_chars / nat_chars / min_lines / nat_lines 控制最小/自然尺寸
//! - 支持文字溢出 (overflow) 时的省略号显示
//! - 支持 wrap 模式
//! - 比 Label 更简单, 不支持可选择/可点击, 仅用于展示

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

/// 文字溢出模式
pub const InscriptionOverflow = enum {
    /// 正常显示, 不截断 (可能超出控件)
    normal,
    /// 在开头用省略号截断
    start,
    /// 在中间用省略号截断
    middle,
    /// 在末尾用省略号截断 (默认)
    end,
};

/// 文字对齐方式
pub const InscriptionAlign = enum {
    fill,
    start,
    center,
    end,
    baseline,
};

pub const Inscription = struct {
    base: Widget,
    allocator: std.mem.Allocator,
    text: []const u8 = "",

    min_chars: u32 = 0,
    nat_chars: u32 = 0,
    min_lines: u32 = 1,
    nat_lines: u32 = 1,

    xalign: f32 = 0, // 0=start, 0.5=center, 1=end
    yalign: f32 = 0.5,
    overflow: InscriptionOverflow = .end,
    wrap: bool = false,

    text_color: math.Color = math.Color.hex(0x0F172AFF),
    font_size: f32 = 14,
    font_weight: u32 = 400,
    italic: bool = false,
    font_family: []const u8 = "",

    const Self = @This();

    pub fn create(allocator: std.mem.Allocator, opts: struct {
        text: []const u8 = "",
        min_chars: u32 = 0,
        nat_chars: u32 = 0,
        min_lines: u32 = 1,
        nat_lines: u32 = 1,
        xalign: f32 = 0,
        yalign: f32 = 0.5,
        overflow: InscriptionOverflow = .end,
        wrap: bool = false,
        text_color: math.Color = math.Color.hex(0x0F172AFF),
        font_size: f32 = 14,
        font_weight: u32 = 400,
        italic: bool = false,
        font_family: []const u8 = "",
    }) !*Inscription {
        const text_dup = try allocator.dupe(u8, opts.text);
        const self = try allocator.create(Inscription);
        self.* = .{
            .base = .{
                .vtable = &vtable,
                .id = widget_mod.genWidgetId(),
            },
            .allocator = allocator,
            .text = text_dup,
            .min_chars = opts.min_chars,
            .nat_chars = opts.nat_chars,
            .min_lines = opts.min_lines,
            .nat_lines = opts.nat_lines,
            .xalign = opts.xalign,
            .yalign = opts.yalign,
            .overflow = opts.overflow,
            .wrap = opts.wrap,
            .text_color = opts.text_color,
            .font_size = opts.font_size,
            .font_weight = opts.font_weight,
            .italic = opts.italic,
            .font_family = opts.font_family,
        };
        self.base.accessibility = .{ .role = .label, .label = text_dup };
        return self;
    }

    pub fn destroy(self: *Self, allocator: std.mem.Allocator) void {
        allocator.free(self.text);
        self.base.background.deinit(allocator);
        self.base.children.deinit(allocator);
        allocator.destroy(self);
    }

    pub fn setText(self: *Self, new_text: []const u8) !void {
        self.allocator.free(self.text);
        self.text = try self.allocator.dupe(u8, new_text);
        self.base.accessibility.label = self.text;
        self.base.markLayoutDirty();
        self.base.markDirty();
    }

    pub fn getText(self: *const Self) []const u8 {
        return self.text;
    }

    pub fn setOverflow(self: *Self, overflow: InscriptionOverflow) void {
        self.overflow = overflow;
        self.base.markDirty();
    }

    pub fn setWrap(self: *Self, wrap: bool) void {
        self.wrap = wrap;
        self.base.markLayoutDirty();
        self.base.markDirty();
    }

    pub fn setAlign(self: *Self, xalign: f32, yalign: f32) void {
        self.xalign = xalign;
        self.yalign = yalign;
        self.base.markDirty();
    }

    fn measureTextSize(self: *const Self, alloc: std.mem.Allocator, max_w: ?f32) math.Size(f32) {
        const opts: styled_text.TextOptions = .{
            .font_size = self.font_size,
            .font_weight = self.font_weight,
            .italic = self.italic,
            .font_family = self.font_family,
            .max_width = if (self.wrap) max_w else null,
        };
        return styled_text.measureText(alloc, self.text, opts);
    }

    // 根据 min_chars / nat_chars / min_lines / nat_lines 计算基础尺寸
    fn computeBaseSize(self: *const Self) math.Size(f32) {
        // 用字符 'x' 估算宽度 (平均字符宽度)
        const avg_char_w: f32 = self.font_size * 0.6;
        const line_h: f32 = self.font_size * 1.25;

        const mc: f32 = @floatFromInt(@max(self.min_chars, self.nat_chars));
        const ml: f32 = @floatFromInt(@max(self.min_lines, self.nat_lines));

        var bw = mc * avg_char_w;
        var bh = ml * line_h;

        if (mc == 0 and self.text.len > 0) {
            // 没有设置 min/nat chars 时, 按实际文本估算
            const estimated_chars: f32 = @floatFromInt(self.text.len);
            if (self.wrap == false) {
                bw = estimated_chars * avg_char_w;
            }
        }
        if (ml == 0) {
            bh = line_h;
        }
        return .{ .width = bw, .height = bh };
    }

    /// 根据 overflow 模式截取字符串并加省略号
    fn applyOverflow(self: *const Self, alloc: std.mem.Allocator, text: []const u8, max_w: f32) []const u8 {
        if (max_w <= 0) return text;
        const text_size = self.measureTextSize(alloc, null);
        if (text_size.width <= max_w) return text;

        const ellipsis = "\u{2026}";
        const ell_size = self.measureTextSize(alloc, null);

        _ = ell_size;
        const target_w = max_w;

        // 先按 overflow 模式处理
        switch (self.overflow) {
            .normal => return text,
            .end => {
                // 二分查找最长能放的字符数
                var lo: usize = 0;
                var hi = text.len;
                var best: usize = 0;
                const max_iter: usize = 20;
                for (0..max_iter) |_| {
                    const mid = (lo + hi) / 2;
                    const sub = text[0..mid];
                    // 加省略号一起测
                    var tmp = std.ArrayList(u8).init(alloc);
                    defer tmp.deinit();
                    tmp.appendSlice(sub) catch break;
                    tmp.appendSlice(ellipsis) catch break;
                    const combined = tmp.items;
                    const sz = styled_text.measureText(alloc, combined, .{
                        .font_size = self.font_size,
                        .font_weight = self.font_weight,
                        .italic = self.italic,
                    });
                    if (sz.width <= target_w) {
                        best = mid;
                        lo = mid + 1;
                        if (lo >= hi) break;
                    } else {
                        if (mid == 0) break;
                        hi = mid - 1;
                    }
                }
                if (best == 0 and text.len > 0) return text;
                const result = alloc.alloc(u8, best + ellipsis.len) catch return text;
                @memcpy(result[0..best], text[0..best]);
                @memcpy(result[best..], ellipsis);
                return result;
            },
            .start => {
                // 类似 end, 但从开头省略
                var lo: usize = 0;
                var hi = text.len;
                var best: usize = text.len;
                const max_iter: usize = 20;
                for (0..max_iter) |_| {
                    const mid = (lo + hi) / 2;
                    const sub = text[mid..text.len];
                    var tmp = std.ArrayList(u8).init(alloc);
                    defer tmp.deinit();
                    tmp.appendSlice(ellipsis) catch break;
                    tmp.appendSlice(sub) catch break;
                    const combined = tmp.items;
                    const sz = styled_text.measureText(alloc, combined, .{
                        .font_size = self.font_size,
                        .font_weight = self.font_weight,
                        .italic = self.italic,
                    });
                    if (sz.width <= target_w) {
                        best = mid;
                        if (mid == 0) break;
                        hi = mid - 1;
                    } else {
                        lo = mid + 1;
                        if (lo >= hi) break;
                    }
                }
                if (best >= text.len) return text;
                const sub_len = text.len - best;
                const result = alloc.alloc(u8, sub_len + ellipsis.len) catch return text;
                @memcpy(result[0..ellipsis.len], ellipsis);
                @memcpy(result[ellipsis.len..], text[best..]);
                return result;
            },
            .middle => {
                // 简单处理: 截末尾
                var lo: usize = 0;
                var hi = text.len;
                var best: usize = 0;
                const max_iter: usize = 20;
                for (0..max_iter) |_| {
                    const mid = (lo + hi) / 2;
                    const half = mid / 2;
                    const sub1 = text[0..half];
                    const sub2 = text[text.len - half..];
                    var tmp = std.ArrayList(u8).init(alloc);
                    defer tmp.deinit();
                    tmp.appendSlice(sub1) catch break;
                    tmp.appendSlice(ellipsis) catch break;
                    tmp.appendSlice(sub2) catch break;
                    const combined = tmp.items;
                    const sz = styled_text.measureText(alloc, combined, .{
                        .font_size = self.font_size,
                        .font_weight = self.font_weight,
                        .italic = self.italic,
                    });
                    if (sz.width <= target_w) {
                        best = half;
                        lo = mid + 1;
                        if (lo >= hi) break;
                    } else {
                        if (mid == 0) break;
                        hi = mid - 1;
                    }
                }
                if (best == 0 and text.len > 0) return text;
                const half2 = best;
                const result = alloc.alloc(u8, half2 * 2 + ellipsis.len) catch return text;
                @memcpy(result[0..half2], text[0..half2]);
                @memcpy(result[half2..][0..ellipsis.len], ellipsis);
                @memcpy(result[half2 + ellipsis.len ..], text[text.len - half2 ..]);
                return result;
            },
        }
    }

    // ── VTable 实现 ──────────────────────────────────────────────────────────

    const vtable = Widget.VTable{
        .type_name = "inscription",
        .measure = measure,
        .paint = paint,
        .on_event = null,
        .focusable = false,
        .destroy = destroyVTable,
    };

    fn destroyVTable(w: *Widget, allocator: std.mem.Allocator) void {
        const self: *Self = @fieldParentPtr("base", w);
        self.destroy(allocator);
    }

    fn measure(w: *Widget, ctx: *PaintContext, constraints: layout_mod.Constraints) math.Size(f32) {
        const self: *Self = @fieldParentPtr("base", w);

        const text_sz = self.measureTextSize(ctx.allocator, if (self.wrap) constraints.max_width else null);
        const base_sz = self.computeBaseSize();

        const w_out = @max(text_sz.width, base_sz.width);
        const h_out = @max(text_sz.height, base_sz.height);

        const final_w = if (constraints.max_width < std.math.inf(f32))
            @max(constraints.min_width, @min(w_out, constraints.max_width))
        else
            @max(constraints.min_width, w_out);
        const final_h = if (constraints.max_height < std.math.inf(f32))
            @max(constraints.min_height, @min(h_out, constraints.max_height))
        else
            @max(constraints.min_height, h_out);
        return .{ .width = final_w, .height = final_h };
    }

    fn paint(w: *Widget, ctx: *PaintContext) void {
        const self: *Self = @fieldParentPtr("base", w);
        if (self.text.len == 0) return;

        const rx = ctx.offset_x + w.rect.x;
        const ry = ctx.offset_y + w.rect.y;

        const max_text_w = w.rect.width;
        var text_to_draw = self.text;
        var is_owned = false;
        defer if (is_owned) self.allocator.free(text_to_draw);

        if (!self.wrap and self.overflow != .normal) {
            const processed = self.applyOverflow(ctx.allocator, self.text, max_text_w);
            if (processed.ptr != self.text.ptr) {
                text_to_draw = processed;
                is_owned = true;
            }
        }

        const text_sz = self.measureTextSize(ctx.allocator, if (self.wrap) max_text_w else null);

        var draw_x: f32 = rx;
        var draw_y: f32 = ry;

        // 根据 xalign 调整
        if (text_sz.width < w.rect.width) {
            const diff = w.rect.width - text_sz.width;
            draw_x = rx + self.xalign * diff;
        }
        if (text_sz.height < w.rect.height) {
            const diff = w.rect.height - text_sz.height;
            draw_y = ry + self.yalign * diff;
        }

        styled_text.drawText(ctx.renderer, ctx.allocator, text_to_draw, draw_x, draw_y, .{
            .font_size = self.font_size,
            .font_weight = self.font_weight,
            .italic = self.italic,
            .color = self.text_color,
            .font_family = self.font_family,
            .max_width = if (self.wrap) max_text_w else null,
        });
    }
};
