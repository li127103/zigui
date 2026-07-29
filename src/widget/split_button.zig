//! SplitButton 控件 - GTK4 分割按钮
//!
//! 左侧主按钮 + 右侧下拉箭头, 中间有竖线分隔。
//! 点击主按钮触发 on_clicked, 点击箭头展开关联的 Popover/Menu。
//!
//! GTK4 对应: GtkSplitButton

const std = @import("std");
const math = @import("../math.zig");
const widget_mod = @import("widget.zig");
const layout_mod = @import("../layout/engine.zig");
const pal = @import("../pal/pal.zig");
const styled_text = @import("../text/styled_text.zig");
const icons_mod = @import("icons.zig");
const popover_mod = @import("popover.zig");
const menu_mod = @import("menu.zig");

const Widget = widget_mod.Widget;
const PaintContext = widget_mod.PaintContext;
const EventContext = widget_mod.EventContext;
const EventResult = widget_mod.EventResult;
const Allocator = std.mem.Allocator;
const Event = pal.event_mod.Event;
const Popover = popover_mod.Popover;
const Menu = menu_mod.Menu;

pub const ArrowDirection = enum { up, down, left, right };

pub const SplitButton = struct {
    base: Widget,
    allocator: Allocator,
    label: []const u8 = "",
    font_size: f32 = 14,
    icon_name: ?icons_mod.IconName = null,
    icon_size: f32 = 16,

    popover: ?*Popover = null,
    menu_model: ?*Menu = null,
    arrow_direction: ArrowDirection = .down,

    on_clicked: ?*const fn (self: *SplitButton) void = null,

    hover_main: bool = false,
    hover_arrow: bool = false,
    pressed_main: bool = false,
    pressed_arrow: bool = false,
    is_open: bool = false,

    bg_color: math.Color = math.Color.hex(0x334155FF),
    bg_hover: math.Color = math.Color.hex(0x475569FF),
    bg_pressed: math.Color = math.Color.hex(0x1E293BFF),
    text_color: math.Color = math.Color.hex(0xF8FAFCFF),
    border_color: math.Color = math.Color.hex(0x475569FF),
    divider_color: math.Color = math.Color.hex(0x64748BFF),
    corner_radius: f32 = 8,
    padding_h: f32 = 14,
    padding_v: f32 = 9,
    arrow_area_w: f32 = 28,
    divider_width: f32 = 1,

    label_dup: []const u8 = &.{},

    pub fn new(allocator: Allocator) !*SplitButton {
        return try newWithLabel(allocator, "");
    }

    pub fn newWithLabel(allocator: Allocator, label_text: []const u8) !*SplitButton {
        const self = try allocator.create(SplitButton);
        const duped = if (label_text.len > 0) try allocator.dupe(u8, label_text) else &.{};
        self.* = .{
            .base = .{
                .vtable = &vtable,
                .id = widget_mod.genWidgetId(),
                .cursor = .pointing_hand,
            },
            .allocator = allocator,
            .label = duped,
            .label_dup = duped,
        };
        self.base.accessibility = .{ .role = .split_button, .label = self.label };
        return self;
    }

    pub fn destroy(self: *SplitButton, allocator: Allocator) void {
        if (self.label_dup.len > 0) allocator.free(self.label_dup);
        self.base.background.deinit(allocator);
        self.base.children.deinit(allocator);
        allocator.destroy(self);
    }

    pub fn setLabel(self: *SplitButton, label_text: []const u8) void {
        if (self.label_dup.len > 0) {
            self.allocator.free(self.label_dup);
            self.label_dup = &.{};
        }
        self.label_dup = if (label_text.len > 0) self.allocator.dupe(u8, label_text) catch return else &.{};
        self.label = self.label_dup;
        self.base.accessibility.label = self.label;
        self.base.markLayoutDirty();
        self.base.markDirty();
    }

    pub fn setIconName(self: *SplitButton, name: icons_mod.IconName) void {
        self.icon_name = name;
        self.base.markLayoutDirty();
        self.base.markDirty();
    }

    pub fn setMenuModel(self: *SplitButton, menu: ?*Menu) void {
        self.menu_model = menu;
        self.popover = null;
    }

    pub fn setPopover(self: *SplitButton, popover: ?*Popover) void {
        self.popover = popover;
        if (popover) |p| p.setRelativeTo(&self.base);
        self.menu_model = null;
    }

    pub fn setArrowDirection(self: *SplitButton, dir: ArrowDirection) void {
        self.arrow_direction = dir;
        self.base.markDirty();
    }

    const HitPart = enum { main, arrow, none };

    fn hitPart(self: *SplitButton, rel_x: f32) HitPart {
        const r = self.base.rect;
        const arrow_x = r.width - self.arrow_area_w;
        if (rel_x < 0 or rel_x > r.width) return .none;
        return if (rel_x < arrow_x) .main else .arrow;
    }

    fn togglePopover(self: *SplitButton) void {
        if (self.popover) |p| {
            if (p.isVisible()) {
                p.hide();
                self.is_open = false;
            } else {
                p.show();
                self.is_open = true;
            }
        } else if (self.menu_model) |_| {
            self.is_open = !self.is_open;
        }
    }
};

const vtable = Widget.VTable{
    .type_name = "split_button",
    .measure = measure,
    .paint = paint,
    .on_event = onEvent,
    .focusable = true,
    .destroy = destroyVTable,
};

fn destroyVTable(w: *Widget, allocator: Allocator) void {
    const self: *SplitButton = @fieldParentPtr("base", w);
    self.destroy(allocator);
}

fn measure(w: *Widget, ctx: *PaintContext, constraints: layout_mod.Constraints) math.Size {
    const self: *SplitButton = @fieldParentPtr("base", w);
    var mw: f32 = self.padding_h * 2 + self.arrow_area_w;
    var mh: f32 = self.padding_v * 2;
    var text_h: f32 = self.font_size;
    const max_w_available = if (constraints.max_width < std.math.inf(f32))
        constraints.max_width - self.padding_h * 2 - self.arrow_area_w
    else
        0;

    if (self.label.len > 0) {
        const ts = styled_text.measureText(ctx.allocator, self.label, .{
            .font_size = self.font_size,
            .max_width = max_w_available,
        });
        mw += ts.width;
        text_h = @max(text_h, ts.height);
    }
    const ih: f32 = if (self.icon_name != null) self.icon_size else 0;
    if (self.icon_name != null) {
        mw += self.icon_size + (if (self.label.len > 0) @as(f32, 6) else 0);
    }
    mh += @max(ih, text_h);
    return .{ .width = mw, .height = @max(mh, 32) };
}

fn paint(w: *Widget, ctx: *PaintContext) void {
    const self: *SplitButton = @fieldParentPtr("base", w);
    const rx = ctx.offset_x + w.rect.x;
    const ry = ctx.offset_y + w.rect.y;
    const rw = w.rect.width;
    const rh = w.rect.height;
    const enabled = !w.isDisabled();
    const arrow_x_val = rw - self.arrow_area_w;
    const divider_x_val = arrow_x_val - self.divider_width;

    const main_bg: math.Color = if (!enabled)
        self.bg_color
    else if (self.pressed_main)
        self.bg_pressed
    else if (self.hover_main)
        self.bg_hover
    else
        self.bg_color;

    const arrow_bg: math.Color = if (!enabled)
        self.bg_color
    else if (self.pressed_arrow)
        self.bg_pressed
    else if (self.hover_arrow or self.is_open)
        self.bg_hover
    else
        self.bg_color;

    // 主按钮区背景 (左圆角)
    {
        const x = rx;
        const y = ry;
        const w_bg = arrow_x_val;
        const h_bg = rh;
        const r_val = self.corner_radius;
        ctx.renderer.fillRoundedRect(.{ .x = x, .y = y, .width = w_bg, .height = h_bg }, r_val, main_bg) catch {};
        // 手动把右边两个角画平：用矩形覆盖右边缘
        ctx.renderer.fillRect(.{ .x = x + w_bg - r_val, .y = y, .width = r_val, .height = h_bg }, main_bg) catch {};
    }
    // 箭头区背景 (右圆角)
    {
        const x = rx + arrow_x_val;
        const y = ry;
        const w_bg = self.arrow_area_w;
        const h_bg = rh;
        const r_val = self.corner_radius;
        ctx.renderer.fillRoundedRect(.{ .x = x, .y = y, .width = w_bg, .height = h_bg }, r_val, arrow_bg) catch {};
        ctx.renderer.fillRect(.{ .x = x, .y = y, .width = r_val, .height = h_bg }, arrow_bg) catch {};
    }
    // 外边框
    ctx.renderer.strokeRoundedRect(.{ .x = rx, .y = ry, .width = rw, .height = rh }, self.corner_radius, 1, self.border_color) catch {};
    // 分割线
    ctx.renderer.fillRect(.{
        .x = rx + divider_x_val,
        .y = ry + self.padding_v / 2,
        .width = self.divider_width,
        .height = rh - self.padding_v,
    }, self.divider_color) catch {};

    // 内容: 图标 + 文本
    const content_w = rw - self.arrow_area_w - self.padding_h * 2;
    var content_x = rx + self.padding_h;
    const content_h = rh - self.padding_v * 2;
    const content_y = ry + self.padding_v;
    const has_icon = self.icon_name != null;
    const has_text = self.label.len > 0;

    var total_cw: f32 = 0;
    if (has_icon) total_cw += self.icon_size;
    if (has_icon and has_text) total_cw += 6;
    if (has_text) {
        const ts = styled_text.measureText(ctx.allocator, self.label, .{ .font_size = self.font_size });
        total_cw += ts.width;
    }
    if (total_cw < content_w) content_x += (content_w - total_cw) / 2;

    const tc: math.Color = if (enabled) self.text_color else self.text_color.withAlpha(0.5);
    if (has_icon) {
        const iy = content_y + (content_h - self.icon_size) / 2;
        icons_mod.drawIcon(ctx.allocator, ctx.renderer, self.icon_name.?, .{
            .x = content_x,
            .y = iy,
            .size = self.icon_size,
            .color = tc,
        }) catch {};
        content_x += self.icon_size + 6;
    }
    if (has_text) {
        const ts = styled_text.measureText(ctx.allocator, self.label, .{ .font_size = self.font_size });
        const ty = content_y + (content_h - ts.height) / 2;
        styled_text.drawText(ctx, self.label, .{
            .x = content_x,
            .y = ty,
            .color = tc,
            .font_size = self.font_size,
        });
    }

    // 箭头
    const arrow_cx = rx + arrow_x_val + self.arrow_area_w / 2;
    const arrow_cy = ry + rh / 2;
    const arrow_size_val: f32 = 8;
    const ac: math.Color = if (enabled) tc else tc.withAlpha(0.5);
    const arrow_icon: icons_mod.IconName = switch (self.arrow_direction) {
        .down => icons_mod.IconName.chevron_down,
        .up => icons_mod.IconName.chevron_up,
        .left => icons_mod.IconName.chevron_left,
        .right => icons_mod.IconName.chevron_right,
    };
    icons_mod.drawIcon(ctx.allocator, ctx.renderer, arrow_icon, .{
        .x = arrow_cx - arrow_size_val / 2,
        .y = arrow_cy - arrow_size_val / 2,
        .size = arrow_size_val,
        .color = ac,
    }) catch {};
}

fn onEvent(w: *Widget, event: *const Event, ectx: *EventContext) EventResult {
    const self: *SplitButton = @fieldParentPtr("base", w);
    const abs_rect = w.absoluteRect();
    const enabled = !w.isDisabled();
    if (!enabled) return .ignored;

    switch (event.*) {
        .mouse_move => |m| {
            const mx: f32 = @floatFromInt(m.x);
            const my: f32 = @floatFromInt(m.y);
            const rel_x = mx - abs_rect.x;
            const rel_y = my - abs_rect.y;
            const inside = rel_x >= 0 and rel_x <= abs_rect.width and rel_y >= 0 and rel_y <= abs_rect.height;
            if (inside) {
                const part = self.hitPart(rel_x);
                const hm_new = part == .main;
                const ha_new = part == .arrow;
                if (hm_new != self.hover_main or ha_new != self.hover_arrow) {
                    self.hover_main = hm_new;
                    self.hover_arrow = ha_new;
                    w.markDirty();
                }
                return .handled;
            } else {
                if (self.hover_main or self.hover_arrow) {
                    self.hover_main = false;
                    self.hover_arrow = false;
                    w.markDirty();
                }
            }
        },
        .mouse_button => |mb| {
            if (mb.button == .left) {
                const mx: f32 = @floatFromInt(mb.x);
                const my: f32 = @floatFromInt(mb.y);
                const rel_x = mx - abs_rect.x;
                const rel_y = my - abs_rect.y;
                const inside = rel_x >= 0 and rel_x <= abs_rect.width and rel_y >= 0 and rel_y <= abs_rect.height;
                if (mb.state == .pressed) {
                    if (inside) {
                        const part = self.hitPart(rel_x);
                        switch (part) {
                            .main => self.pressed_main = true,
                            .arrow => self.pressed_arrow = true,
                            .none => return .ignored,
                        }
                        w.markDirty();
                        return .handled;
                    }
                } else {
                    if (inside) {
                        const part = self.hitPart(rel_x);
                        if (self.pressed_main and part == .main) {
                            if (self.on_clicked) |cb| cb(self);
                        }
                        if (self.pressed_arrow and part == .arrow) {
                            self.togglePopover();
                        }
                    }
                    self.pressed_main = false;
                    self.pressed_arrow = false;
                    w.markDirty();
                    if (inside) return .handled;
                }
            }
        },
        .key => |k| {
            if (k.state == .pressed) {
                if (k.key == .space or k.key == .enter or k.key == .kp_enter) {
                    if (self.on_clicked) |cb| cb(self);
                    return .handled;
                }
                if (k.key == .down) {
                    self.togglePopover();
                    return .handled;
                }
            }
            _ = ectx;
        },
        else => {},
    }
    return .ignored;
}
