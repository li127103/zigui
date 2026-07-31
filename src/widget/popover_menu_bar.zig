//! PopoverMenuBar 控件 - GTK4 弹出式菜单栏
//!
//! GTK4 对应: GtkPopoverMenuBar
//!
//! 与旧 MenuBar 区别:
//! - 菜单项点击后弹出 Popover 风格的菜单 (圆角气泡 + 指向箭头)
//! - 更现代的深色/浅色外观
//! - 支持下划线键盘快捷键 (如 "_File" → Alt+F 打开)
//! - 支持菜单项 hover 后自动展开 (当 active_menu 不为空时)

const std = @import("std");
const math = @import("../math.zig");
const widget_mod = @import("widget.zig");
const layout_mod = @import("../layout/engine.zig");
const pal = @import("../pal/pal.zig");
const menu_mod = @import("menu.zig");
const styled_text = @import("../text/styled_text.zig");
const action_mod = @import("../model/action.zig");

const Widget = widget_mod.Widget;
const PaintContext = widget_mod.PaintContext;
const EventContext = widget_mod.EventContext;
const EventResult = widget_mod.EventResult;
const Allocator = std.mem.Allocator;
const Event = pal.Event;
const ActionGroup = action_mod.ActionGroup;
const ModelMenu = menu_mod.Menu;
const ModelMenuItem = menu_mod.MenuItem;
const ActionValue = action_mod.ActionValue;

pub const PopoverMenuItem = struct {
    label: []const u8,
    underline_index: ?usize = null, // 哪个字符作为下划线快捷键 (Alt+char)
    menu: *menu_mod.Menu,
};

/// 菜单项点击时激活 Action 的上下文（闭包替代：通过 ctx 字段同时携带 self + action_group + action_name + action_target）
const ActionClickCtx = struct {
    action_group: ActionGroup,
    action_name: []const u8,
    action_target: ActionValue,
};

const LayoutResult = struct { xs: [64]f32, ws: [64]f32, count: usize };

pub const PopoverMenuBar = struct {
    base: Widget,
    allocator: Allocator,
    items: std.ArrayListUnmanaged(PopoverMenuItem)  = .{ .items = &.{}, .capacity = 0 },
    label_dups: std.ArrayListUnmanaged([]const u8)  = .{ .items = &.{}, .capacity = 0 },

    active_menu: ?usize = null,
    hovered_item: ?usize = null,

    font_size: f32 = 13,
    height: f32 = 32,
    item_padding_h: f32 = 14,
    item_spacing: f32 = 2,
    item_radius: f32 = 6,

    /// 菜单项点击后的弹出定位
    popover_gap: f32 = 4,
    popover_arrow: f32 = 0, // 弹出菜单项通常不需要指向箭头

    on_menu_open: ?*const fn (self: *PopoverMenuBar, index: usize) void = null,
    on_menu_close: ?*const fn (self: *PopoverMenuBar) void = null,

    // 样式 (深色)
    bg_color: math.Color = math.Color.hex(0x0F172AFF),
    text_color: math.Color = math.Color.hex(0xE2E8F0FF),
    hover_bg: math.Color = math.Color.hex(0x1E293BFF),
    active_bg: math.Color = math.Color.hex(0x3B82F6AA),
    active_text: math.Color = math.Color.hex(0xFFFFFFFF),
    underline_color: math.Color = math.Color.hex(0xE2E8F0FF),
    border_color: math.Color = math.Color.hex(0x1E293BFF),

    // 快捷键 Alt 状态
    alt_pressed: bool = false,

    // MenuModel 支持
    menu_model: ?*ModelMenu = null,
    action_group: ?ActionGroup = null,
    /// 由 setMenuModel 分配的子菜单控件 (destroy 时释放)
    owned_widget_menus: std.ArrayListUnmanaged(*menu_mod.Menu)  = .{ .items = &.{}, .capacity = 0 },
    /// 由 setMenuModel 分配的 ActionClickCtx (destroy 时释放)
    owned_action_ctxs: std.ArrayListUnmanaged(*ActionClickCtx)  = .{ .items = &.{}, .capacity = 0 },

    pub fn new(allocator: Allocator, opts: struct {
        font_size: f32 = 13,
        height: f32 = 32,
        item_padding_h: f32 = 14,
        bg_color: ?math.Color = null,
        text_color: ?math.Color = null,
        on_menu_open: ?*const fn (self: *PopoverMenuBar, index: usize) void = null,
        on_menu_close: ?*const fn (self: *PopoverMenuBar) void = null,
    }) !*PopoverMenuBar {
        const self = try allocator.create(PopoverMenuBar);
        self.* = .{
            .base = .{
                .vtable = &vtable,
                .id = widget_mod.genWidgetId(),
            },
            .allocator = allocator,
            .font_size = opts.font_size,
            .height = opts.height,
            .item_padding_h = opts.item_padding_h,
            .on_menu_open = opts.on_menu_open,
            .on_menu_close = opts.on_menu_close,
        };
        if (opts.bg_color) |c| self.bg_color = c;
        if (opts.text_color) |c| self.text_color = c;
        self.base.accessibility = .{ .role = .menu, .label = "Menu Bar" };
        return self;
    }

    pub fn destroy(self: *PopoverMenuBar, allocator: Allocator) void {
        // 销毁自己分配的 widget.Menu 子菜单
        for (self.owned_widget_menus.items) |wm| wm.destroy(allocator);
        self.owned_widget_menus.deinit(allocator);
        // 销毁 ActionClickCtx
        for (self.owned_action_ctxs.items) |c| allocator.destroy(c);
        self.owned_action_ctxs.deinit(allocator);
        // 不 destroy 外部传入的菜单 (和 MenuBar 保持一致, 用户自己管理)
        self.items.deinit(allocator);
        for (self.label_dups.items) |l| allocator.free(l);
        self.label_dups.deinit(allocator);
        self.base.background.deinit(allocator);
        self.base.children.deinit(allocator);
        allocator.destroy(self);
    }

    pub fn setActionGroup(self: *PopoverMenuBar, ag: ?ActionGroup) void {
        self.action_group = ag;
    }

    /// 声明式设置菜单模型。传入 null 时清空所有自动生成的菜单。
    pub fn setMenuModel(self: *PopoverMenuBar, menu: ?*ModelMenu) !void {
        const a = self.allocator;
        // 清掉上一次分配的资源
        for (self.owned_widget_menus.items) |wm| wm.destroy(a);
        self.owned_widget_menus.clearRetainingCapacity();
        for (self.owned_action_ctxs.items) |c| a.destroy(c);
        self.owned_action_ctxs.clearRetainingCapacity();
        // 清掉已添加的 PopoverMenuItem 及标签 dup
        self.items.clearRetainingCapacity();
        for (self.label_dups.items) |l| a.free(l);
        self.label_dups.clearRetainingCapacity();

        self.menu_model = menu;
        if (menu) |m| {
            const n = m.len();
            var i: usize = 0;
            while (i < n) : (i += 1) {
                const mi = m.get(i) orelse continue;
                // 如果 item 本身带 submenu → 作为菜单栏顶层条目 (如 "_File")
                if (mi.submenu) |sub_ptr| {
                    const sub_model: *ModelMenu = @ptrCast(@alignCast(sub_ptr));
                    const widget_menu = try self.buildWidgetMenuFromModel(sub_model);
                    try self.addMenu(mi.label, widget_menu);
                } else {
                    // 顶层无 submenu: 建一个空弹出菜单 (或点击即触发 action)
                    const widget_menu = try menu_mod.Menu.create(a, .{ .font_size = self.font_size });
                    try self.owned_widget_menus.append(a, widget_menu);
                    // 如果有 action_name, 把 action 作为单独菜单项再填进去
                    if (mi.action_name) |an| {
                        const ctx = try self.makeActionClickCtx(an, mi.action_target);
                        try widget_menu.addItem(.{
                            .label = mi.label,
                            .disabled = !mi.enabled,
                            .on_click = struct { fn wrapper(p: ?*anyopaque) void {
                                const c: *ActionClickCtx = @ptrCast(@alignCast(p orelse return));
                                _ = c.action_group.activateAction(c.action_name, c.action_target);
                            } }.wrapper,
                            .ctx = @ptrCast(ctx),
                        });
                    }
                    try self.addMenu(mi.label, widget_menu);
                }
            }
        }
        self.base.markLayoutDirty();
        self.base.markDirty();
    }

    // ── 内部: Model → Widget 递归转换 ──────────────────────────────────

    fn buildWidgetMenuFromModel(self: *PopoverMenuBar, mm: *ModelMenu) !*menu_mod.Menu {
        const a = self.allocator;
        const wm = try menu_mod.Menu.create(a, .{ .font_size = self.font_size });
        try self.owned_widget_menus.append(a, wm);
        const n = mm.len();
        var i: usize = 0;
        while (i < n) : (i += 1) {
            const mi = mm.get(i) orelse continue;
            if (mi.isSeparator()) {
                try wm.addSeparator();
                continue;
            }
            // 子菜单
            var sub: ?*menu_mod.Menu = null;
            if (mi.submenu) |sub_ptr| {
                const sub_model: *ModelMenu = @ptrCast(@alignCast(sub_ptr));
                sub = try self.buildWidgetMenuFromModel(sub_model);
            }
            const on_click_wrap: ?*const fn (ctx: ?*anyopaque) void = if (mi.action_name != null)
                struct { fn wrapper(p: ?*anyopaque) void {
                    const c: *ActionClickCtx = @ptrCast(@alignCast(p orelse return));
                    _ = c.action_group.activateAction(c.action_name, c.action_target);
                } }.wrapper
            else
                null;
            var ctx_ptr: ?*anyopaque = null;
            if (mi.action_name) |an| {
                const actx = try self.makeActionClickCtx(an, mi.action_target);
                ctx_ptr = @ptrCast(actx);
            }
            try wm.addItem(.{
                .label = mi.label,
                .is_separator = false,
                .disabled = !mi.enabled,
                .on_click = on_click_wrap,
                .ctx = ctx_ptr,
                .submenu = sub,
            });
        }
        return wm;
    }

    fn makeActionClickCtx(self: *PopoverMenuBar, name: []const u8, target: ActionValue) !*ActionClickCtx {
        const a = self.allocator;
        const ctx = try a.create(ActionClickCtx);
        const ag = self.action_group orelse ActionGroup{
            .iface = &empty_ag_iface,
            .userdata = null,
        };
        ctx.* = .{
            .action_group = ag,
            .action_name = name,
            .action_target = target,
        };
        try self.owned_action_ctxs.append(a, ctx);
        return ctx;
    }

    const empty_ag_iface: action_mod.ActionGroupIface = .{
        .listActionsFn = emptyListActions,
        .queryActionFn = emptyQueryAction,
        .hasActionFn = emptyHasAction,
        .activateActionFn = emptyActivateAction,
        .changeActionStateFn = emptyChangeActionState,
        .actionGetEnabledFn = emptyActionGetEnabled,
        .actionGetStateFn = emptyActionGetState,
    };
    fn emptyListActions(_: ?*anyopaque, _: *std.ArrayListUnmanaged([]const u8)) void {}
    fn emptyQueryAction(_: ?*anyopaque, _: []const u8) ?action_mod.Action { return null; }
    fn emptyHasAction(_: ?*anyopaque, _: []const u8) bool { return false; }
    fn emptyActivateAction(_: ?*anyopaque, _: []const u8, _: ActionValue) bool { return false; }
    fn emptyChangeActionState(_: ?*anyopaque, _: []const u8, _: ActionValue) bool { return false; }
    fn emptyActionGetEnabled(_: ?*anyopaque, _: []const u8) ?bool { return null; }
    fn emptyActionGetState(_: ?*anyopaque, _: []const u8) ?ActionValue { return null; }

    /// 添加菜单项, 若 label 以 "_X" 开头, 会自动设置 X 为快捷键字符
    pub fn addMenu(self: *PopoverMenuBar, label: []const u8, menu: *menu_mod.Menu) !void {
        var underline: ?usize = null;
        var display_label: []const u8 = label;
        // 处理 GTK4 风格的 "_" 前缀下划线
        for (label, 0..) |ch, i| {
            if (ch == '_' and i + 1 < label.len) {
                underline = i;
                display_label = label;
                break;
            }
        }
        const dup = try self.allocator.dupe(u8, display_label);
        try self.label_dups.append(self.allocator, dup);
        try self.items.append(self.allocator, .{
            .label = dup,
            .underline_index = underline,
            .menu = menu,
        });
        // 确保菜单 start_closed
        menu.open = false;
        self.base.markLayoutDirty();
        self.base.markDirty();
    }

    pub fn closeAll(self: *PopoverMenuBar) void {
        if (self.active_menu) |idx| {
            self.items.items[idx].menu.open = false;
        }
        if (self.active_menu != null) {
            self.active_menu = null;
            if (self.on_menu_close) |cb| cb(self);
        }
        self.base.markDirty();
    }

    pub fn openMenu(self: *PopoverMenuBar, index: usize) void {
        if (index >= self.items.items.len) return;
        self.closeAll();
        self.active_menu = index;
        self.items.items[index].menu.open = true;
        if (self.on_menu_open) |cb| cb(self, index);
        self.base.markDirty();
    }

    /// 计算每项 x+宽度数组
    fn layoutItems(self: *const PopoverMenuBar, alloc: std.mem.Allocator, bar_w: f32) LayoutResult {
        var res: LayoutResult = .{
            .xs = [_]f32{0} ** 64,
            .ws = [_]f32{0} ** 64,
            .count = 0,
        };
        const n = @min(self.items.items.len, 64);
        res.count = n;
        var x: f32 = 4;
        for (0..n) |i| {
            const label = self.items.items[i].label;
            const ts = styled_text.measureText(alloc, label, .{ .font_size = self.font_size });
            const w = ts.width + self.item_padding_h * 2;
            res.xs[i] = x;
            res.ws[i] = w;
            x += w + self.item_spacing;
        }
        _ = bar_w;
        return res;
    }

    fn findItemAt(self: *const PopoverMenuBar, alloc: std.mem.Allocator, x: f32, bar_w: f32) ?usize {
        const L = self.layoutItems(alloc, bar_w);
        for (0..L.count) |i| {
            if (x >= L.xs[i] and x < L.xs[i] + L.ws[i]) return i;
        }
        return null;
    }
};

const vtable = Widget.VTable{
    .type_name = "popover_menu_bar",
    .measure = measure,
    .paint = paint,
    .on_event = onEvent,
    .focusable = true,
    .destroy = destroyVTable,
};

fn destroyVTable(w: *Widget, allocator: Allocator) void {
    const self: *PopoverMenuBar = @fieldParentPtr("base", w);
    self.destroy(allocator);
}

fn measure(w: *Widget, ctx: *PaintContext, constraints: layout_mod.Constraints) math.Size(f32) {
    const self: *PopoverMenuBar = @fieldParentPtr("base", w);
    const L = self.layoutItems(ctx.allocator, constraints.max_width);
    var total_w: f32 = 4;
    for (0..L.count) |i| {
        total_w += L.ws[i] + if (i + 1 < L.count) self.item_spacing else 4;
    }
    const max_w = if (constraints.max_width < std.math.inf(f32)) constraints.max_width else 1200;
    return .{
        .width = @max(100, @min(total_w, max_w)),
        .height = self.height,
    };
}

fn paint(w: *Widget, ctx: *PaintContext) void {
    const self: *PopoverMenuBar = @fieldParentPtr("base", w);
    const rx = ctx.offset_x + w.rect.x;
    const ry = ctx.offset_y + w.rect.y;
    const rw = w.rect.width;
    const rh = w.rect.height;
    const R = ctx.renderer;
    const alloc = ctx.allocator;

    R.fillRoundedRect(.{ .x = rx, .y = ry, .width = rw, .height = rh }, 0, self.bg_color) catch {};

    const L = self.layoutItems(ctx.allocator, rw);
    for (0..L.count) |i| {
        const item = self.items.items[i];
        const ix = rx + L.xs[i];
        const iy = ry + (rh - (rh - 4)) / 2;
        const iw = L.ws[i];
        const ih = rh - 4;
        const is_active = if (self.active_menu) |a| a == i else false;
        const is_hover = if (self.hovered_item) |h| h == i else false;

        // 背景
        if (is_active) {
            R.fillRoundedRect(.{ .x = ix, .y = iy, .width = iw, .height = ih }, self.item_radius, self.active_bg) catch {};
        } else if (is_hover) {
            R.fillRoundedRect(.{ .x = ix, .y = iy, .width = iw, .height = ih }, self.item_radius, self.hover_bg) catch {};
        }

        // 文本
        const ts = styled_text.measureText(alloc, item.label, .{ .font_size = self.font_size });
        const ty = ry + (rh - ts.height) / 2;
        const tx = ix + self.item_padding_h;
        const tc: math.Color = if (is_active) self.active_text else self.text_color;
        styled_text.drawText(ctx.renderer, ctx.allocator, item.label, tx, ty, .{
            .color = tc,
            .font_size = self.font_size,
        });

        // 下划线快捷键
        if (self.alt_pressed) {
            if (item.underline_index) |ui| {
                var prefix_len: usize = 0;
                var char_count: usize = 0;
                for (item.label, 0..) |_, bi| {
                    // 假设 ASCII, 每字节 1 字符
                    if (char_count == ui) {
                        prefix_len = bi;
                        break;
                    }
                    char_count += 1;
                } else {
                    prefix_len = item.label.len;
                }
                const prefix = item.label[0..prefix_len];
                const prefix_ts = styled_text.measureText(alloc, prefix, .{ .font_size = self.font_size });
                const ch_start = tx + prefix_ts.width;
                const ch_end_label = if (prefix_len + 1 <= item.label.len) item.label[0 .. prefix_len + 1] else item.label;
                const ch_end_ts = styled_text.measureText(alloc, ch_end_label, .{ .font_size = self.font_size });
                const ch_w = ch_end_ts.width - prefix_ts.width;
                R.fillRect(.{
                    .x = ch_start,
                    .y = ry + rh - 6,
                    .width = @max(4, ch_w),
                    .height = 1,
                }, tc) catch {};
            }
        }
    }
    // 底部分隔线
    R.fillRect(.{ .x = rx, .y = ry + rh - 1, .width = rw, .height = 1 }, self.border_color) catch {};
}

fn onEvent(w: *Widget, event: *const Event, ectx: *EventContext) EventResult {
    _ = ectx;
    const self: *PopoverMenuBar = @fieldParentPtr("base", w);
    const abs_rect = w.absoluteRect();

    switch (event.*) {
        .key => |k| {
            // Alt 键按下/释放
            if (k.key == .left_alt or k.key == .right_alt) {
                const is_down = k.state == .pressed;
                if (self.alt_pressed != is_down) {
                    self.alt_pressed = is_down;
                    w.markDirty();
                }
                // Alt+F 打开 File 菜单
                if (is_down) {
                    // 等待字符键
                }
                return .handled;
            }
            // 有 Alt 按下且菜单项有快捷键
            if (self.alt_pressed and k.state == .pressed) {
                var ch: ?u8 = null;
                switch (k.key) {
                    .a => ch = 'A',
                    .b => ch = 'B',
                    .c => ch = 'C',
                    .d => ch = 'D',
                    .e => ch = 'E',
                    .f => ch = 'F',
                    .g => ch = 'G',
                    .h => ch = 'H',
                    .i => ch = 'I',
                    .j => ch = 'J',
                    .k => ch = 'K',
                    .l => ch = 'L',
                    .m => ch = 'M',
                    .n => ch = 'N',
                    .o => ch = 'O',
                    .p => ch = 'P',
                    .q => ch = 'Q',
                    .r => ch = 'R',
                    .s => ch = 'S',
                    .t => ch = 'T',
                    .u => ch = 'U',
                    .v => ch = 'V',
                    .w => ch = 'W',
                    .x => ch = 'X',
                    .y => ch = 'Y',
                    .z => ch = 'Z',
                    else => {},
                }
                if (ch) |c| {
                    for (self.items.items, 0..) |item, i| {
                        if (item.underline_index) |ui| {
                            if (ui < item.label.len) {
                                const lch = item.label[ui];
                                const up = if (lch >= 'a' and lch <= 'z') lch - 32 else lch;
                                if (up == c) {
                                    self.openMenu(i);
                                    return .handled;
                                }
                            }
                        }
                    }
                }
            }
            // 方向键导航
            if (k.state == .pressed) {
                const n = self.items.items.len;
                const cur = self.active_menu orelse self.hovered_item orelse 0;
                if (k.key == .left and n > 0) {
                    const next = if (cur == 0) n - 1 else cur - 1;
                    self.hovered_item = next;
                    if (self.active_menu != null) {
                        self.openMenu(next);
                    }
                    w.markDirty();
                    return .handled;
                }
                if (k.key == .right and n > 0) {
                    const next = (cur + 1) % n;
                    self.hovered_item = next;
                    if (self.active_menu != null) {
                        self.openMenu(next);
                    }
                    w.markDirty();
                    return .handled;
                }
                if (k.key == .down or k.key == .enter or k.key == .space or k.key == .kp_enter) {
                    if (self.active_menu == null and n > 0) {
                        self.openMenu(self.hovered_item orelse 0);
                    } else if (self.active_menu) |idx| {
                        // 传给子菜单 - 通过设置焦点 / 返回 ignored 让下一个 widget 接手
                        _ = idx;
                    }
                    return .handled;
                }
                if (k.key == .escape) {
                    self.closeAll();
                    return .handled;
                }
            }
        },
        .mouse_move => |m| {
            const mx: f32 = @floatFromInt(m.x);
            const my: f32 = @floatFromInt(m.y);
            const rel_x = mx - abs_rect.x;
            const rel_y = my - abs_rect.y;
            if (rel_x >= 0 and rel_x < abs_rect.width and rel_y >= 0 and rel_y < abs_rect.height) {
                const idx = self.findItemAt(self.allocator, rel_x, abs_rect.width);
                if (idx != self.hovered_item) {
                    self.hovered_item = idx;
                    // 若已经有活动菜单, hover 切换菜单
                    if (self.active_menu != null and idx != null and idx != self.active_menu) {
                        self.openMenu(idx.?);
                    }
                    w.markDirty();
                }
                return .handled;
            } else {
                if (self.hovered_item != null) {
                    self.hovered_item = null;
                    w.markDirty();
                }
            }
        },
        .mouse_button => |mb| {
            if (mb.button == .left and mb.state == .pressed) {
                const mx: f32 = @floatFromInt(mb.x);
                const my: f32 = @floatFromInt(mb.y);
                const rel_x = mx - abs_rect.x;
                const rel_y = my - abs_rect.y;
                if (rel_x >= 0 and rel_x < abs_rect.width and rel_y >= 0 and rel_y < abs_rect.height) {
                    const idx = self.findItemAt(self.allocator, rel_x, abs_rect.width);
                    if (idx) |i| {
                        if (self.active_menu) |a| {
                            if (a == i) {
                                self.closeAll();
                            } else {
                                self.openMenu(i);
                            }
                        } else {
                            self.openMenu(i);
                        }
                        return .handled;
                    }
                } else {
                    // 点击 bar 外部 (若菜单打开, 先让父控件处理)
                    if (self.active_menu != null) {
                        // 不关闭, 由 Popover / Menu 的外部点击关闭
                    }
                }
            }
        },
        else => {},
    }
    return .ignored;
}
