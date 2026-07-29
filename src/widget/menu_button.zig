//! MenuButton 控件 - 菜单按钮 (对标 GtkMenuButton)
//! 点击后弹出关联的 Popover/Menu, 再次点击关闭

const std = @import("std");
const math = @import("../math.zig");
const widget_mod = @import("widget.zig");
const layout_mod = @import("../layout/engine.zig");
const pal = @import("../pal/pal.zig");
const styled_text = @import("../text/styled_text.zig");
const popover_mod = @import("popover.zig");
const menu_widget_mod = @import("menu.zig");
const menu_model_mod = @import("../model/menu_model.zig");
const action_mod = @import("../model/action.zig");

const Widget = widget_mod.Widget;
const PaintContext = widget_mod.PaintContext;
const EventContext = widget_mod.EventContext;
const EventResult = widget_mod.EventResult;
const Popover = popover_mod.Popover;
const ModelMenu = menu_model_mod.Menu;
const ActionGroup = action_mod.ActionGroup;
const ActionValue = action_mod.ActionValue;
const WidgetMenu = menu_widget_mod.Menu;
const Allocator = std.mem.Allocator;

const ClickCtx = struct {
    action_group: ActionGroup,
    action_name: []const u8,
    action_target: ActionValue,
};

pub const MenuButton = struct {
    base: Widget,
    label: []const u8,
    font_size: f32,
    popover: ?*Popover = null,
    is_open: bool = false,
    on_click: ?*const fn (self: *MenuButton) void = null,
    // 样式
    bg_color: math.Color = math.Color.hex(0x334155FF),
    bg_hover: math.Color = math.Color.hex(0x475569FF),
    bg_pressed: math.Color = math.Color.hex(0x1E293BFF),
    text_color: math.Color = math.Color.hex(0xF8FAFCFF),
    corner_radius: f32 = 8.0,
    padding_h: f32 = 14.0,
    padding_v: f32 = 10.0,
    arrow_size: f32 = 6.0,
    label_arrow_gap: f32 = 8.0,

    // MenuModel 支持
    menu_model: ?*ModelMenu = null,
    action_group: ?ActionGroup = null,
    owned_popover: ?*Popover = null, // 由 setMenuModel 分配
    owned_menu: ?*WidgetMenu = null,
    owned_ctxs: std.ArrayListUnmanaged(*ClickCtx) = .{ .items = &.{}, .capacity = 0 },

    pub fn create(allocator: std.mem.Allocator, label_text: []const u8, opts: struct {
        font_size: f32 = 14.0,
        on_click: ?*const fn (self: *MenuButton) void = null,
        bg_color: math.Color = math.Color.hex(0x334155FF),
        bg_hover: math.Color = math.Color.hex(0x475569FF),
        bg_pressed: math.Color = math.Color.hex(0x1E293BFF),
        text_color: math.Color = math.Color.hex(0xF8FAFCFF),
        corner_radius: f32 = 8.0,
    }) !*MenuButton {
        const self = try allocator.create(MenuButton);
        self.* = .{
            .base = .{
                .vtable = &vtable,
                .id = widget_mod.genWidgetId(),
            },
            .label = label_text,
            .font_size = opts.font_size,
            .on_click = opts.on_click,
            .bg_color = opts.bg_color,
            .bg_hover = opts.bg_hover,
            .bg_pressed = opts.bg_pressed,
            .text_color = opts.text_color,
            .corner_radius = opts.corner_radius,
        };
        self.base.accessibility = .{ .role = .button, .label = label_text };
        self.base.cursor = .pointing_hand;
        return self;
    }

    pub fn destroy(self: *MenuButton, allocator: std.mem.Allocator) void {
        // 释放自己分配的资源
        for (self.owned_ctxs.items) |c| allocator.destroy(c);
        self.owned_ctxs.deinit(allocator);
        if (self.owned_menu) |m| m.destroy(allocator);
        if (self.owned_popover) |p| p.destroy(allocator);
        self.base.background.deinit(allocator);
        self.base.children.deinit(allocator);
        allocator.destroy(self);
    }

    pub fn setActionGroup(self: *MenuButton, ag: ?ActionGroup) void {
        self.action_group = ag;
    }

    pub fn setPopover(self: *MenuButton, popover: *Popover) void {
        self.popover = popover;
        popover.setRelativeTo(&self.base);
    }

    /// 声明式设置菜单模型 (自动构建 Popover + WidgetMenu 并绑定 action)
    pub fn setMenuModel(self: *MenuButton, allocator: Allocator, menu: ?*ModelMenu) !void {
        // 清旧资源
        for (self.owned_ctxs.items) |c| allocator.destroy(c);
        self.owned_ctxs.clearRetainingCapacity();
        if (self.owned_menu) |m| {
            m.destroy(allocator);
            self.owned_menu = null;
        }
        if (self.owned_popover) |p| {
            p.destroy(allocator);
            self.owned_popover = null;
        }
        self.popover = null;

        self.menu_model = menu;
        if (menu) |m| {
            const wm = try self.buildWidgetMenu(allocator, m);
            self.owned_menu = wm;
            const pop = try Popover.create(allocator, .{ .relative_to = &self.base, .position = .bottom });
            try pop.addChild(&wm.base);
            self.owned_popover = pop;
            self.popover = pop;
        }
    }

    fn buildWidgetMenu(self: *MenuButton, a: Allocator, mm: *ModelMenu) !*WidgetMenu {
        const wm = try WidgetMenu.create(a, .{});
        const n = mm.len();
        var i: usize = 0;
        while (i < n) : (i += 1) {
            const mi = mm.get(i) orelse continue;
            if (mi.isSeparator()) {
                try wm.addSeparator();
                continue;
            }
            var sub: ?*WidgetMenu = null;
            if (mi.submenu) |sp| {
                const sm: *ModelMenu = @ptrCast(@alignCast(sp));
                sub = try self.buildWidgetMenu(a, sm);
            }
            var on_click: ?*const fn (ctx: ?*anyopaque) void = null;
            var ctx_ptr: ?*anyopaque = null;
            if (mi.action_name) |an| {
                on_click = struct {
                    fn wrapper(p: ?*anyopaque) void {
                        const c: *ClickCtx = @ptrCast(@alignCast(p orelse return));
                        _ = c.action_group.activateAction(c.action_name, c.action_target);
                    }
                }.wrapper;
                const ag = self.action_group orelse ActionGroup{
                    .iface = &empty_ag,
                    .userdata = null,
                };
                const ctx = try a.create(ClickCtx);
                ctx.* = .{ .action_group = ag, .action_name = an, .action_target = mi.action_target };
                try self.owned_ctxs.append(a, ctx);
                ctx_ptr = @ptrCast(ctx);
            }
            try wm.addItem(.{
                .label = mi.label,
                .is_separator = false,
                .disabled = !mi.enabled,
                .submenu = sub,
                .on_click = on_click,
                .ctx = ctx_ptr,
            });
        }
        return wm;
    }

    const empty_ag: action_mod.ActionGroupIface = .{
        .listActionsFn = struct {
            fn f(_: ?*anyopaque, _: *std.ArrayListUnmanaged([]const u8)) void {}
        }.f,
        .queryActionFn = struct {
            fn f(_: ?*anyopaque, _: []const u8) ?action_mod.Action {
                return null;
            }
        }.f,
        .hasActionFn = struct {
            fn f(_: ?*anyopaque, _: []const u8) bool {
                return false;
            }
        }.f,
        .activateActionFn = struct {
            fn f(_: ?*anyopaque, _: []const u8, _: ActionValue) bool {
                return false;
            }
        }.f,
        .changeActionStateFn = struct {
            fn f(_: ?*anyopaque, _: []const u8, _: ActionValue) bool {
                return false;
            }
        }.f,
        .actionGetEnabledFn = struct {
            fn f(_: ?*anyopaque, _: []const u8) ?bool {
                return null;
            }
        }.f,
        .actionGetStateFn = struct {
            fn f(_: ?*anyopaque, _: []const u8) ?ActionValue {
                return null;
            }
        }.f,
    };

    pub fn isOpen(self: *MenuButton) bool {
        return self.is_open;
    }

    // ── VTable 实现 ──────────────────────────────────────────────────────────

    const vtable = Widget.VTable{
        .type_name = "menu_button",
        .measure = measure,
        .paint = paint,
        .on_event = onEvent,
        .focusable = true,
        .destroy = destroyVTable,
    };

    fn destroyVTable(w: *Widget, allocator: std.mem.Allocator) void {
        const self: *MenuButton = @fieldParentPtr("base", w);
        self.destroy(allocator);
    }

    fn measure(w: *Widget, ctx: *PaintContext, constraints: layout_mod.Constraints) math.Size(f32) {
        const self: *MenuButton = @fieldParentPtr("base", w);
        _ = constraints;

        const text_size = styled_text.measureText(ctx.allocator, self.label, .{
            .font_size = self.font_size,
            .font_weight = 500,
        });

        // 文本 + 间距 + 下拉箭头
        const arrow_total = self.label_arrow_gap + self.arrow_size;
        return .{
            .width = text_size.width + self.padding_h * 2 + arrow_total,
            .height = text_size.height + self.padding_v * 2,
        };
    }

    fn paint(w: *Widget, ctx: *PaintContext) void {
        const self: *MenuButton = @fieldParentPtr("base", w);

        const bg = if (w.state.pressed or self.is_open)
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

        // 文本
        if (self.label.len > 0) {
            const text_size = styled_text.measureText(ctx.allocator, self.label, .{
                .font_size = self.font_size,
                .font_weight = 500,
            });
            const arrow_total = self.label_arrow_gap + self.arrow_size;
            const content_w = text_size.width + arrow_total;
            const text_x = rx + (w.rect.width - content_w) / 2.0;
            const text_y = ry + (w.rect.height - text_size.height) / 2.0;

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

            // 下拉箭头 (向下三角形)
            const arrow_x = text_x + text_size.width + self.label_arrow_gap;
            const arrow_y = ry + (w.rect.height - self.arrow_size) / 2.0;
            self.drawArrow(ctx, arrow_x, arrow_y);
        }
    }

    fn drawArrow(self: *MenuButton, ctx: *PaintContext, x: f32, y: f32) void {
        const s = self.arrow_size;
        // 用三个矩形拼三角形 (简化)
        // 行1: 1 个方块
        ctx.renderer.fillRect(.{ .x = x + s / 2 - 1, .y = y, .width = 2.0, .height = 2.0 }, self.text_color) catch {};
        // 行2: 3 个方块
        ctx.renderer.fillRect(.{ .x = x + s / 2 - 2, .y = y + 2, .width = 4.0, .height = 2.0 }, self.text_color) catch {};
        // 行3: 5 个方块
        if (s >= 6) {
            ctx.renderer.fillRect(.{ .x = x + s / 2 - 3, .y = y + 4, .width = 6.0, .height = 2.0 }, self.text_color) catch {};
        }
    }

    fn onEvent(w: *Widget, event: *const pal.Event, ectx: *EventContext) EventResult {
        const self: *MenuButton = @fieldParentPtr("base", w);
        _ = ectx;

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
                            // 切换弹出
                            if (self.popover) |p| {
                                if (self.is_open) {
                                    p.popdown();
                                    self.is_open = false;
                                } else {
                                    p.popup();
                                    self.is_open = true;
                                }
                            }
                            if (self.on_click) |cb| cb(self);
                            w.markDirty();
                            return .handled;
                        }
                    }
                }
            },
            .mouse_move => |mm| {
                _ = mm;
                // hover 由 dispatchEvent/hitTest 处理
            },
            else => {},
        }
        return .ignored;
    }
};
