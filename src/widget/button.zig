//! Button 控件 - 可点击按钮

const std = @import("std");
const math = @import("../math.zig");
const widget_mod = @import("widget.zig");
const layout_mod = @import("../layout/engine.zig");
const pal = @import("../pal/pal.zig");
const styled_text = @import("../text/styled_text.zig");
const icons = @import("icons.zig");

const Widget = widget_mod.Widget;
const PaintContext = widget_mod.PaintContext;
const EventContext = widget_mod.EventContext;
const EventResult = widget_mod.EventResult;

pub const Button = struct {
    base: Widget,
    label: []const u8,
    font_size: f32,
    on_click: ?*const fn (self: *Button) void,
    /// 图标 (null = 无图标, 纯文本按钮)
    icon: ?icons.IconName = null,
    /// 图标边长 (px, 图标在 16×16 坐标系内等比缩放)
    icon_size: f32 = 16.0,
    /// 图标与文本之间的间距
    icon_gap: f32 = 8.0,
    /// 图标颜色 (默认跟随 text_color)
    icon_color: ?math.Color = null,
    // 样式
    bg_color: math.Color,
    bg_hover: math.Color,
    bg_pressed: math.Color,
    text_color: math.Color,
    corner_radius: f32,
    padding_h: f32,
    padding_v: f32,
    /// 自定义子控件 (setChild 设置)
    custom_child: ?*Widget = null,
    /// 是否解析助记符下划线
    use_underline: bool = false,

    pub fn create(allocator: std.mem.Allocator, label_text: []const u8, opts: struct {
        font_size: f32 = 14.0,
        on_click: ?*const fn (self: *Button) void = null,
        icon: ?icons.IconName = null,
        icon_size: f32 = 16.0,
        icon_color: ?math.Color = null,
        bg_color: math.Color = math.Color.hex(0x3B82F6FF),
        bg_hover: math.Color = math.Color.hex(0x60A5FAFF),
        bg_pressed: math.Color = math.Color.hex(0x2563EBFF),
        text_color: math.Color = math.Color.hex(0xFFFFFFFF),
        corner_radius: f32 = 8.0,
        padding_h: f32 = 16.0,
        padding_v: f32 = 10.0,
        min_width: ?f32 = null,
        width: ?f32 = null,
        min_height: ?f32 = null,
        height: ?f32 = null,
        padding: ?math.EdgeInsets = null,
    }) !*Button {
        const self = try allocator.create(Button);
        const eff_padding_h = if (opts.padding) |p| (p.left + p.right) / 2.0 else opts.padding_h;
        const eff_padding_v = if (opts.padding) |p| (p.top + p.bottom) / 2.0 else opts.padding_v;
        self.* = .{
            .base = .{
                .vtable = &vtable,
                .id = widget_mod.genWidgetId(),
            },
            .label = label_text,
            .font_size = opts.font_size,
            .on_click = opts.on_click,
            .icon = opts.icon,
            .icon_size = opts.icon_size,
            .icon_gap = 8.0,
            .icon_color = opts.icon_color,
            .bg_color = opts.bg_color,
            .bg_hover = opts.bg_hover,
            .bg_pressed = opts.bg_pressed,
            .text_color = opts.text_color,
            .corner_radius = opts.corner_radius,
            .padding_h = eff_padding_h,
            .padding_v = eff_padding_v,
        };
        if (opts.min_width) |w| self.base.layout_style.min_width = .{ .px = w };
        if (opts.width) |w| self.base.layout_style.width = .{ .px = w };
        if (opts.min_height) |h| self.base.layout_style.min_height = .{ .px = h };
        if (opts.height) |h| self.base.layout_style.height = .{ .px = h };
        self.base.accessibility = .{ .role = .button, .label = label_text };
        self.base.cursor = .pointing_hand;
        return self;
    }

    // ── GTK4 兼容构造 (gtk_button_new_with_label / new_from_icon_name) ────────

    /// GTK4: gtk_button_new_with_label
    pub fn newWithLabel(allocator: std.mem.Allocator, label_text: []const u8) !*Button {
        return create(allocator, label_text, .{});
    }
    /// GTK4: gtk_button_new_with_mnemonic (下划线助记，简化版与 with_label 同)
    pub fn newWithMnemonic(allocator: std.mem.Allocator, label_text: []const u8) !*Button {
        return create(allocator, label_text, .{});
    }
    /// GTK4: gtk_button_new_from_icon_name — 图标按钮 (label="")
    pub fn newFromIconName(allocator: std.mem.Allocator, icon_name: icons.IconName, icon_size: f32) !*Button {
        return create(allocator, "", .{ .icon = icon_name, .icon_size = icon_size });
    }

    /// GTK4: gtk_button_set_label
    pub fn setLabel(self: *Button, label: []const u8) void {
        self.label = label;
        self.base.accessibility.label = label;
        self.base.markLayoutDirty();
        self.base.markDirty();
    }
    /// GTK4: gtk_button_get_label
    pub fn getLabel(self: *const Button) []const u8 {
        return self.label;
    }

    /// GTK4: gtk_button_set_icon_name (setIcon 的别名)
    pub fn setIconName(self: *Button, name: ?icons.IconName) void {
        self.setIcon(name);
    }
    /// GTK4: gtk_button_get_icon_name
    pub fn getIconName(self: *const Button) ?icons.IconName {
        return self.icon;
    }

    /// 设置/清除图标 (运行时切换)
    pub fn setIcon(self: *Button, icon: ?icons.IconName) void {
        self.icon = icon;
        self.base.markLayoutDirty();
        self.base.markDirty();
    }

    // ── GTK4 兼容 setter ────────────────────────────────────────────────────

    /// GTK4: gtk_button_set_child - 设置任意子控件
    pub fn setChild(self: *Button, child: *Widget) void {
        self.custom_child = child;
        self.base.markDirty();
    }

    /// GTK4: gtk_button_get_child - 获取子控件
    pub fn getChild(self: *Button) ?*Widget {
        return self.custom_child;
    }

    /// GTK4: gtk_button_set_use_underline - 设置助记符下划线解析
    pub fn setUseUnderline(self: *Button, v: bool) void {
        self.use_underline = v;
        self.base.markDirty();
    }

    pub fn destroy(self: *Button, allocator: std.mem.Allocator) void {
        self.base.background.deinit(allocator);
        self.base.children.deinit(allocator);
        allocator.destroy(self);
    }

    // ── VTable 实现 ──────────────────────────────────────────────────────────

    const vtable = Widget.VTable{
        .type_name = "button",
        .measure = measure,
        .paint = paint,
        .on_event = onEvent,
        .focusable = true,
        .destroy = destroyVTable,
    };

    fn destroyVTable(w: *Widget, allocator: std.mem.Allocator) void {
        const self: *Button = @fieldParentPtr("base", w);
        self.destroy(allocator);
    }

    fn measure(w: *Widget, ctx: *PaintContext, constraints: layout_mod.Constraints) math.Size(f32) {
        const self: *Button = @fieldParentPtr("base", w);
        _ = constraints;

        const text_size = styled_text.measureText(ctx.allocator, self.label, .{
            .font_size = self.font_size,
            .font_weight = 500,
        });

        // 内容宽度: 图标 (+间距) + 文本
        var content_w = text_size.width;
        var icon_w: f32 = 0;
        if (self.icon) |ic| {
            if (ic != .none) {
                icon_w = self.icon_size;
                content_w += icon_w;
                if (self.label.len > 0) content_w += self.icon_gap;
            }
        }
        // 内容高度: max(文本, 图标)
        const content_h = if (icon_w > 0) @max(text_size.height, self.icon_size) else text_size.height;

        return .{
            .width = content_w + self.padding_h * 2,
            .height = content_h + self.padding_v * 2,
        };
    }

    fn paint(w: *Widget, ctx: *PaintContext) void {
        const self: *Button = @fieldParentPtr("base", w);

        // 选择背景色
        const bg = if (w.state.pressed)
            self.bg_pressed
        else if (w.state.hovered)
            self.bg_hover
        else
            self.bg_color;

        const rx = ctx.offset_x + w.rect.x;
        const ry = ctx.offset_y + w.rect.y;

        // 背景
        ctx.renderer.fillRoundedRect(
            .{ .x = rx, .y = ry, .width = w.rect.width, .height = w.rect.height },
            self.corner_radius,
            bg,
        ) catch {};

        // 焦点环
        if (w.state.focused) {
            ctx.renderer.fillRoundedRect(
                .{ .x = rx - 2, .y = ry - 2, .width = w.rect.width + 4, .height = w.rect.height + 4 },
                self.corner_radius + 2,
                math.Color.hex(0x3B82F644),
            ) catch {};
        }

        // 测量内容以居中布局 [图标 (间距) 文本]
        const text_size = styled_text.measureText(ctx.allocator, self.label, .{
            .font_size = self.font_size,
            .font_weight = 500,
        });

        const has_icon = if (self.icon) |ic| (ic != .none) else false;
        var icon_w: f32 = 0;
        if (has_icon) icon_w = self.icon_size;
        const gap: f32 = if (has_icon and self.label.len > 0) self.icon_gap else 0;
        const content_w = icon_w + gap + text_size.width;
        const content_h = if (has_icon) @max(text_size.height, self.icon_size) else text_size.height;

        // 内容起始 x (整体居中)
        const start_x = rx + (w.rect.width - content_w) / 2.0;
        const content_top = ry + (w.rect.height - content_h) / 2.0;

        // 绘制图标
        if (has_icon) {
            const icon_x = start_x;
            const icon_y = content_top + (content_h - self.icon_size) / 2.0;
            const ic = self.icon.?;
            const ic_color = self.icon_color orelse self.text_color;
            icons.drawIcon(ctx.renderer, icon_x, icon_y, self.icon_size, ic_color, ic) catch {};
        }

        // 绘制文本 (图标右侧)
        if (self.label.len > 0) {
            const text_x = start_x + icon_w + gap;
            const text_y = content_top + (content_h - text_size.height) / 2.0;
            styled_text.drawText(
                ctx.renderer,
                ctx.allocator,
                self.label,
                text_x,
                text_y,
                .{
                    .font_size = self.font_size,
                    .font_weight = 500,
                    .color = self.text_color,
                },
            );
        }
    }

    fn onEvent(w: *Widget, event: *const pal.Event, ectx: *EventContext) EventResult {
        const self: *Button = @fieldParentPtr("base", w);

        switch (event.*) {
            .mouse_button => |mb| {
                if (mb.button == .left) {
                    if (mb.state == .pressed) {
                        w.state.pressed = true;
                        w.markDirty();
                        return .handled;
                    } else {
                        if (w.state.pressed) {
                            w.state.pressed = false;
                            w.markDirty();
                            // 触发点击
                            if (self.on_click) |cb| {
                                cb(self);
                            }
                            return .handled;
                        }
                    }
                }
            },
            .mouse_move => |mm| {
                const lx: f32 = @floatFromInt(mm.x);
                const ly: f32 = @floatFromInt(mm.y);
                const inside = lx >= 0 and ly >= 0 and lx < w.rect.width and ly < w.rect.height;
                if (inside != w.state.hovered) {
                    w.state.hovered = inside;
                    w.markDirty();
                }
            },
            else => {},
        }
        _ = ectx;
        return .ignored;
    }
};
