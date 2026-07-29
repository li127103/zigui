//! FontDialogButton 控件 - GTK4 字体对话框按钮
//!
//! 对应 GtkFontDialogButton: 显示当前字体名称和样式的按钮,
//! 点击弹出字体选择对话框。GTK4 新版替代 FontButton。

const std = @import("std");
const math = @import("../math.zig");
const widget_mod = @import("widget.zig");
const layout_mod = @import("../layout/engine.zig");
const pal = @import("../pal/pal.zig");
const font_selection_mod = @import("font_selection.zig");
const styled_text = @import("../text/styled_text.zig");
const icons_mod = @import("icons.zig");

const Widget = widget_mod.Widget;
const PaintContext = widget_mod.PaintContext;
const EventContext = widget_mod.EventContext;
const EventResult = widget_mod.EventResult;

pub const FontDialogButton = struct {
    base: Widget,
    allocator: std.mem.Allocator,
    font_family: []const u8 = "Sans",
    font_size: f32 = 14,
    bold: bool = false,
    italic: bool = false,
    show_preview: bool = true,

    on_font_changed: ?*const fn (self: *FontDialogButton, family: []const u8, size: f32, bold: bool, italic: bool) void = null,

    min_width: f32 = 200,
    height: f32 = 40,
    corner_radius: f32 = 8,

    bg_color: math.Color = math.Color.hex(0xFFFFFFFF),
    bg_hover: math.Color = math.Color.hex(0xF1F5F9FF),
    border_color: math.Color = math.Color.hex(0xCBD5E1FF),
    border_hover: math.Color = math.Color.hex(0x94A3B8FF),
    text_color: math.Color = math.Color.hex(0x0F172AFF),
    sub_color: math.Color = math.Color.hex(0x64748BFF),
    icon_color: math.Color = math.Color.hex(0x64748BFF),

    hovered: bool = false,
    pressed: bool = false,
    icon_size: f32 = 18,

    const Self = @This();

    pub fn create(allocator: std.mem.Allocator, opts: struct {
        font_family: []const u8 = "Sans",
        font_size: f32 = 14,
        bold: bool = false,
        italic: bool = false,
        show_preview: bool = true,
        min_width: f32 = 200,
        height: f32 = 40,
        corner_radius: f32 = 8,
        on_font_changed: ?*const fn (self: *FontDialogButton, family: []const u8, size: f32, bold: bool, italic: bool) void = null,
    }) !*FontDialogButton {
        const family_dup = try allocator.dupe(u8, opts.font_family);
        const self = try allocator.create(FontDialogButton);
        self.* = .{
            .base = .{
                .vtable = &vtable,
                .id = widget_mod.genWidgetId(),
            },
            .allocator = allocator,
            .font_family = family_dup,
            .font_size = opts.font_size,
            .bold = opts.bold,
            .italic = opts.italic,
            .show_preview = opts.show_preview,
            .min_width = opts.min_width,
            .height = opts.height,
            .corner_radius = opts.corner_radius,
            .on_font_changed = opts.on_font_changed,
        };
        self.base.accessibility = .{
            .role = .button,
            .label = family_dup,
        };
        self.base.cursor = .pointing_hand;
        return self;
    }

    pub fn destroy(self: *Self, allocator: std.mem.Allocator) void {
        allocator.free(self.font_family);
        self.base.background.deinit(allocator);
        self.base.children.deinit(allocator);
        allocator.destroy(self);
    }

    pub fn setFont(self: *Self, family: []const u8, size: f32, bold: bool, italic: bool) !void {
        self.allocator.free(self.font_family);
        self.font_family = try self.allocator.dupe(u8, family);
        self.font_size = size;
        self.bold = bold;
        self.italic = italic;
        self.base.accessibility.label = self.font_family;
        self.base.markDirty();
        if (self.on_font_changed) |cb| cb(self, self.font_family, size, bold, italic);
    }

    fn fmtSize(self: *const Self) [8]u8 {
        var buf: [8]u8 = undefined;
        const s = std.fmt.bufPrint(&buf, "{d:.1}", .{self.font_size}) catch {
            buf[0] = '0';
            return buf;
        };
        var out: [8]u8 = undefined;
        @memset(&out, 0);
        @memcpy(out[0..s.len], s);
        return out;
    }

    // ── VTable ──────────────────────────────────────────────────────────────

    const vtable = Widget.VTable{
        .type_name = "font_dialog_button",
        .measure = measure,
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
        _ = ctx;

        const w_out = if (constraints.max_width < std.math.inf(f32))
            constraints.max_width
        else
            self.min_width;
        const h_out = self.height;
        return .{ .width = w_out, .height = h_out };
    }

    fn paint(w: *Widget, ctx: *PaintContext) void {
        const self: *Self = @fieldParentPtr("base", w);
        const rx = ctx.offset_x + w.rect.x;
        const ry = ctx.offset_y + w.rect.y;

        const bg = if (self.pressed) self.bg_color else if (self.hovered) self.bg_hover else self.bg_color;
        const border = if (self.hovered) self.border_hover else self.border_color;

        ctx.renderer.fillRoundedRect(
            .{ .x = rx, .y = ry, .width = w.rect.width, .height = w.rect.height },
            self.corner_radius,
            bg,
        ) catch {};
        ctx.renderer.strokeRoundedRect(
            .{ .x = rx, .y = ry, .width = w.rect.width, .height = w.rect.height },
            self.corner_radius,
            1,
            border,
        ) catch {};

        // 字体图标
        const ix = rx + 12;
        const iy = ry + (self.height - self.icon_size) / 2;
        const icon = icons_mod.IconName.font;
        icons_mod.drawIcon(ctx.renderer, ix, iy, self.icon_size, self.icon_color, icon) catch {};

        const text_start = ix + self.icon_size + 10;
        const icon_end = rx + w.rect.width - self.icon_size - 12;

        // 主文本：字体名称
        const title_ts = styled_text.measureText(ctx.allocator, self.font_family, .{
            .font_size = 13,
            .font_weight = if (self.bold) 700 else 400,
        });
        const title_y = ry + 8;
        styled_text.drawText(ctx.renderer, ctx.allocator, self.font_family, text_start, title_y, .{
            .font_size = 13,
            .color = self.text_color,
            .font_weight = if (self.bold) 700 else 400,
            .italic = self.italic,
            .max_width = icon_end - text_start - 8,
        });

        // 副文本：字号
        const size_buf = self.fmtSize();
        const size_len: usize = for (0..size_buf.len) |i| {
            if (size_buf[i] == 0) break i;
        } else size_buf.len;
        const size_str: []const u8 = size_buf[0..size_len];

        var sub_buf: [32]u8 = undefined;
        var sub_len: usize = 0;
        const prefix = if (self.bold) "Bold " else "";
        const it = if (self.italic) "Italic " else "";
        @memcpy(sub_buf[sub_len..][0..prefix.len], prefix);
        sub_len += prefix.len;
        @memcpy(sub_buf[sub_len..][0..it.len], it);
        sub_len += it.len;
        @memcpy(sub_buf[sub_len..][0..size_len], size_str);
        sub_len += size_len;
        const pt = "pt";
        @memcpy(sub_buf[sub_len..][0..pt.len], pt);
        sub_len += pt.len;

        const sub_str: []const u8 = sub_buf[0..sub_len];
        const sub_y = title_y + title_ts.height + 2;
        styled_text.drawText(ctx.renderer, ctx.allocator, sub_str, text_start, sub_y, .{
            .font_size = 11,
            .color = self.sub_color,
        });

        // 右侧箭头图标
        const ax = icon_end;
        const ay = ry + (self.height - self.icon_size) / 2;
        icons_mod.drawIcon(ctx.renderer, ax, ay, self.icon_size, self.icon_color, icons_mod.IconName.arrow_down) catch {};
    }

    fn onEvent(w: *Widget, event: *const pal.Event, ectx: *EventContext) EventResult {
        const self: *Self = @fieldParentPtr("base", w);
        _ = ectx;

        switch (event.*) {
            .mouse_move => |mm| {
                const mx: f32 = @floatFromInt(mm.x);
                const my: f32 = @floatFromInt(mm.y);
                const inside = mx >= 0 and mx < w.rect.width and my >= 0 and my < w.rect.height;
                if (inside != self.hovered) {
                    self.hovered = inside;
                    self.base.markDirty();
                }
                return if (inside) .handled else .ignored;
            },
            .mouse_button => |mb| {
                if (mb.button == .left) {
                    const mx: f32 = @floatFromInt(mb.x);
                    const my: f32 = @floatFromInt(mb.y);
                    const inside = mx >= 0 and mx < w.rect.width and my >= 0 and my < w.rect.height;

                    if (mb.state == .pressed and inside) {
                        self.pressed = true;
                        self.base.markDirty();
                        return .handled;
                    } else if (mb.state == .released) {
                        const was = self.pressed;
                        self.pressed = false;
                        self.base.markDirty();
                        if (inside and was) {
                            // 循环切换字体
                            const families = [_][]const u8{ "Sans", "Serif", "Mono", "Arial", "Courier New" };
                            const sizes = [_]f32{ 10, 11, 12, 13, 14, 16, 18, 20, 24 };
                            var cur_idx: usize = 0;
                            for (families, 0..) |f, i| {
                                if (std.mem.eql(u8, f, self.font_family)) cur_idx = i;
                            }
                            const next_idx = (cur_idx + 1) % families.len;
                            const next_size = sizes[(cur_idx + 2) % sizes.len];
                            self.setFont(families[next_idx], next_size, !self.bold, (cur_idx % 3) == 0) catch {};
                            return .handled;
                        }
                    }
                }
            },
            .key => |key| {
                if (key.state == .pressed and (key.key == .enter or key.key == .space)) {
                    self.setFont("Serif", 16, !self.bold, false) catch {};
                    return .handled;
                }
            },
            .mouse_leave => {
                self.hovered = false;
                self.pressed = false;
                self.base.markDirty();
            },
            else => {},
        }
        return .ignored;
    }
};
