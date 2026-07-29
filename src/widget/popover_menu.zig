//! PopoverMenu 控件 - GTK4 弹出式菜单 (气泡菜单)
//!
//! GTK4 对应: GtkPopoverMenu
//!
//! 与旧 Menu 区别:
//! - 弹出风格是圆角气泡 Popover (带指向箭头)
//! - 声明式 MenuModel 支持 + ActionGroup 绑定
//! - 点击菜单项自动激活 action 并关闭
//!
//! 典型用法:
//! ```
//! var menu = try zigui.model.menu_model.Menu.init(alloc);
//! try menu.append("New", "app.new", null, null);
//! try menu.append("Open", "app.open", null, null);
//!
//! var pmenu = try PopoverMenu.create(alloc, .{
//!     .relative_to = button_widget,
//!     .position = .bottom,
//! });
//! try pmenu.setMenuModel(&menu);
//! pmenu.setActionGroup(app.app_actions.group()); // app-level actions
//! pmenu.popup();
//! ```

const std = @import("std");
const math = @import("../math.zig");
const widget_mod = @import("widget.zig");
const layout_mod = @import("../layout/engine.zig");
const pal = @import("../pal/pal.zig");
const popover_mod = @import("popover.zig");
const menu_mod = @import("menu.zig");
const styled_text = @import("../text/styled_text.zig");
const model_mod = @import("../root.zig").model;
const action_mod = @import("../model/action.zig");

const Widget = widget_mod.Widget;
const PaintContext = widget_mod.PaintContext;
const EventContext = widget_mod.EventContext;
const EventResult = widget_mod.EventResult;
const Allocator = std.mem.Allocator;
const Popover = popover_mod.Popover;
const PopoverPosition = popover_mod.PopoverPosition;
const Menu = menu_mod.Menu;
const ActionGroup = action_mod.ActionGroup;
const ModelMenu = model_mod.menu_model.Menu;
const ModelMenuItem = model_mod.menu_model.MenuItem;
const ActionValue = action_mod.ActionValue;

/// 菜单项点击时激活 Action 的上下文（用 userdata 携带）
const ActionClickCtx = struct {
    action_group: ActionGroup,
    action_name: []const u8,
    action_target: ActionValue,
    self_menu: ?*Menu = null,
    menu_owner: ?*anyopaque = null, // PopoverMenu 指针 (销毁用)
    cb_on_click: ?*const fn(ctx: *ActionClickCtx) void = onMenuItemClickActivate,
};

fn onMenuItemClickActivate(ctx: *ActionClickCtx) void {
    // 激活 Action
    if (ctx.action_group.activateAction(ctx.action_name, ctx.action_target)) {
        // 激活成功后关闭 popover
        const owner: *PopoverMenu = @ptrCast(@alignCast(ctx.menu_owner orelse return));
        owner.popdown();
    }
}

pub const PopoverMenu = struct {
    base: Widget,
    allocator: Allocator,
    /// 内部 Popover 气泡
    popover: *Popover,
    /// 当前显示的菜单控件 (destroy 时自动 destroy 自己创建的)
    menu: ?*Menu = null,
    /// 声明式菜单模型
    menu_model: ?*ModelMenu = null,
    /// Action 执行器
    action_group: ?ActionGroup = null,
    /// 由 setMenuModel 分配的子菜单控件
    owned_widget_menus: std.ArrayListUnmanaged(*Menu) = .{},
    /// 由 setMenuModel 分配的 ActionClickCtx
    owned_action_ctxs: std.ArrayListUnmanaged(*ActionClickCtx) = .{},

    on_menu_open: ?*const fn (self: *PopoverMenu) void = null,
    on_menu_close: ?*const fn (self: *PopoverMenu) void = null,

    const Self = @This();

    pub fn create(allocator: Allocator, opts: struct {
        relative_to: ?*Widget = null,
        position: PopoverPosition = .bottom,
        bg_color: ?math.Color = null,
        corner_radius: f32 = 8,
        arrow_size: f32 = 8,
        auto_close: bool = true,
        width: layout_mod.Dimension = .{ .px = 220 },
        on_menu_open: ?*const fn (self: *Self) void = null,
        on_menu_close: ?*const fn (self: *Self) void = null,
    }) !*PopoverMenu {
        const self = try allocator.create(PopoverMenu);
        self.* = .{
            .base = .{
                .vtable = &vtable,
                .id = widget_mod.genWidgetId(),
            },
            .allocator = allocator,
            .popover = undefined,
            .on_menu_open = opts.on_menu_open,
            .on_menu_close = opts.on_menu_close,
        };
        const pop = try Popover.create(allocator, .{
            .relative_to = opts.relative_to,
            .position = opts.position,
            .bg_color = opts.bg_color,
            .corner_radius = opts.corner_radius,
            .arrow_size = opts.arrow_size,
            .auto_close = opts.auto_close,
            .width = opts.width,
        });
        self.popover = pop;
        try self.base.addChild(allocator, &pop.base);
        self.base.accessibility = .{ .role = .menu };
        return self;
    }

    pub fn destroy(self: *Self, allocator: Allocator) void {
        // 销毁所有 setMenuModel 分配的资源
        for (self.owned_widget_menus.items) |wm| wm.destroy(allocator);
        self.owned_widget_menus.deinit(allocator);
        for (self.owned_action_ctxs.items) |c| allocator.destroy(c);
        self.owned_action_ctxs.deinit(allocator);
        // 销毁 popover (它会 destroy 自己的 children, 包括 menu 我们已经 destroy 过了? 不, popover 不 destroy 子控件)
        self.popover.base.vtable.destroy(&self.popover.base, allocator);
        self.base.background.deinit(allocator);
        self.base.children.deinit(allocator);
        allocator.destroy(self);
    }

    pub fn popup(self: *Self) void {
        self.popover.popup();
        if (self.on_menu_open) |cb| cb(self);
    }

    pub fn popdown(self: *Self) void {
        self.popover.popdown();
        if (self.on_menu_close) |cb| cb(self);
    }

    pub fn isOpen(self: *const Self) bool {
        return self.popover.is_open;
    }

    pub fn getPopover(self: *Self) *Popover {
        return self.popover;
    }

    /// 返回当前显示的 Menu 控件 (若存在)
    pub fn getMenu(self: *const Self) ?*Menu {
        return self.menu;
    }

    pub fn setRelativeTo(self: *Self, w: ?*Widget) void {
        self.popover.relative_to = w;
    }

    pub fn setPosition(self: *Self, pos: PopoverPosition) void {
        self.popover.position = pos;
    }

    pub fn setActionGroup(self: *Self, ag: ?ActionGroup) void {
        self.action_group = ag;
    }

    /// 直接设置菜单控件 (低级 API)
    pub fn setMenu(self: *Self, m: ?*Menu) void {
        // 移除旧的 menu child (若在 popover 里)
        // 简单做法: 把 popover 的 children 清空 (只保留 menu)
        // 先不 remove 旧的, 直接加新的覆盖
        if (m) |mm| {
            self.menu = mm;
            self.popover.addChild(&mm.base) catch {};
        }
    }

    /// 声明式设置 MenuModel (GTK4: gtk_popover_menu_set_menu_model)
    /// 将 MenuModel 转换为实际 Menu 控件，菜单项点击时通过 action_group.activateAction 激活
    pub fn setMenuModel(self: *Self, menu: ?*ModelMenu) !void {
        const a = self.allocator;
        // 清上一次
        for (self.owned_widget_menus.items) |wm| wm.destroy(a);
        self.owned_widget_menus.clearRetainingCapacity();
        for (self.owned_action_ctxs.items) |c| a.destroy(c);
        self.owned_action_ctxs.clearRetainingCapacity();

        self.menu_model = menu;
        if (menu) |m| {
            const wm = try a.create(Menu);
            wm.* = try Menu.init(a, .{ .corner_radius = 4 });
            try self.owned_widget_menus.append(a, wm);

            const count = m.getNItems();
            var i: usize = 0;
            while (i < count) : (i += 1) {
                const item = m.getItem(i) orelse continue;
                switch (item.kind) {
                    .section, .submenu => {
                        // 子菜单/分组: 简化只加 label + separator
                        try wm.addItem(a, .{
                            .label = if (item.label.len > 0) item.label else "—",
                            .disabled = true,
                        });
                    },
                    .separator => {
                        try wm.addSeparator(a);
                    },
                    .normal => {
                        // 普通菜单项: action 激活
                        const act_name = item.action_name orelse "";
                        const act_target = item.action_target orelse .{ .bool_val = false };
                        if (act_name.len > 0) {
                            const ctx = try a.create(ActionClickCtx);
                            ctx.* = .{
                                .action_group = self.action_group orelse ActionGroup{
                                    .iface = undefined,
                                    .userdata = null,
                                },
                                .action_name = act_name,
                                .action_target = act_target,
                                .menu_owner = @ptrCast(@alignCast(self)),
                            };
                            try self.owned_action_ctxs.append(a, ctx);
                            try wm.addItemWithData(a, .{
                                .label = item.label,
                                .icon = item.icon,
                                .shortcut = item.shortcut,
                                .disabled = item.disabled or (item.action_name != null and self.action_group == null),
                                .on_click = null, // 由 data_ptr 的 cb 触发
                                .data_ptr = @ptrCast(ctx),
                                .on_click_with_data = (struct {
                                    fn cb(data: ?*anyopaque) void {
                                        const c: *ActionClickCtx = @ptrCast(@alignCast(data orelse return));
                                        if (c.cb_on_click) |fn_cb| fn_cb(c);
                                    }
                                }).cb,
                            });
                        } else {
                            try wm.addItem(a, .{
                                .label = item.label,
                                .icon = item.icon,
                                .shortcut = item.shortcut,
                                .disabled = item.disabled,
                                .on_click = item.on_activate,
                            });
                        }
                    },
                }
            }
            // 放入 popover
            self.menu = wm;
            try self.popover.addChild(&wm.base);
        } else {
            self.menu = null;
        }
    }

    // ── Widget vtable (简单代理 Popover) ─────────────────────────────
    fn measure(
        widget: *Widget,
        ctx: *const PaintContext,
        available_w: f32,
        available_h: f32,
    ) math.Vec2 {
        const self: *Self = @ptrCast(@alignCast(widget));
        return self.popover.base.vtable.measure(&self.popover.base, ctx, available_w, available_h);
    }

    fn layout(widget: *Widget, rect: math.Rect, ctx: *const PaintContext) void {
        const self: *Self = @ptrCast(@alignCast(widget));
        self.popover.base.vtable.layout(&self.popover.base, rect, ctx);
    }

    fn paint(widget: *Widget, ctx: *const PaintContext, rect: math.Rect) void {
        const self: *Self = @ptrCast(@alignCast(widget));
        self.popover.base.vtable.paint(&self.popover.base, ctx, rect);
    }

    fn onEvent(widget: *Widget, ev: *const Widget.Event, ctx: *const EventContext) EventResult {
        const self: *Self = @ptrCast(@alignCast(widget));
        return self.popover.base.vtable.on_event(&self.popover.base, ev, ctx) orelse .ignored;
    }

    const vtable = Widget.VTable{
        .type_name = "PopoverMenu",
        .measure = measure,
        .layout = layout,
        .paint = paint,
        .on_event = onEvent,
        .focusable = false,
        .destroy = destroy,
    };
};
