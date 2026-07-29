//! 菜单模型系统 (对标 GMenuModel / GMenu / GMenuItem)
//!
//! 提供声明式的菜单项定义，可被 PopoverMenuBar / MenuButton 自动消费生成控件。
//!
//!   MenuItem: 单个菜单项 —— label + icon + action(action_name + action_target) + submenu
//!   Menu:     具体的菜单容器 (items 的列表)
//!   MenuModel:统一接口 (getNItems / getItem / isMutable)
//!
//! 典型用法:
//!   const menu = Menu.new(allocator);
//!   defer menu.destroy();
//!   menu.appendItem(MenuItem.new("New", "app.new"));
//!   menu.appendItem(MenuItem.newSeparator());
//!   const sub = Menu.new(allocator);
//!   sub.appendItem(MenuItem.newToggle("Dark Mode", "app.dark-mode", false));
//!   menu.appendSubmenu("Theme", sub);
//!
//!   popover_menu_bar.setMenuModel(menu);

const std = @import("std");
const Allocator = std.mem.Allocator;
const ArrayListUnmanaged = std.ArrayListUnmanaged;

pub const ActionValue = @import("action.zig").ActionValue;

// ── MenuItem ───────────────────────────────────────────────────────────────

pub const MenuItemKind = enum { normal, separator, submenu };

pub const MenuItem = struct {
    kind: MenuItemKind = .normal,
    /// 菜单文字 (owned)
    label: []const u8 = "",
    /// 可选图标名称 (GTK icon-name 或用户自定义语义)
    icon_name: ?[]const u8 = null,
    /// 要激活的 action 名 (完整名: "group.action" 格式; 或简单 "action" 格式)
    action_name: ?[]const u8 = null,
    /// action 参数 (对于需要参数的 action)
    action_target: ActionValue = .none,
    /// toggle/radio 动作的初始状态 (如果动作本身是 stateful, 则以动作状态为准)
    toggle_state: ?bool = null,
    /// 子菜单 (normal 模式下若有子菜单, kind 会被自动识别为 submenu)
    submenu: ?*anyopaque = null,
    /// 是否启用
    enabled: bool = true,
    /// 是否为分割线标记 (与 kind=separator 等价)
    is_separator: bool = false,

    pub fn new(label: []const u8, action: ?[]const u8) MenuItem {
        return .{
            .label = label,
            .action_name = action,
        };
    }

    pub fn newSeparator() MenuItem {
        return .{ .kind = .separator, .is_separator = true };
    }

    pub fn newWithIcon(label: []const u8, action: []const u8, icon_name: []const u8) MenuItem {
        return .{
            .label = label,
            .action_name = action,
            .icon_name = icon_name,
        };
    }

    /// 创建带 toggle 标记的菜单项 (初始 state 显示, 实际动作状态以 ActionGroup 为准)
    pub fn newToggle(label: []const u8, action: []const u8, default_on: bool) MenuItem {
        return .{
            .label = label,
            .action_name = action,
            .toggle_state = default_on,
        };
    }

    /// 创建带 submenu 的菜单项 (submenu 指针: *Menu)
    pub fn newSubmenu(label: []const u8, submenu_ptr: anytype) MenuItem {
        return .{
            .kind = .submenu,
            .label = label,
            .submenu = @ptrCast(submenu_ptr),
        };
    }

    pub fn hasSubmenu(self: *const MenuItem) bool {
        return self.submenu != null or self.kind == .submenu;
    }

    pub fn isSeparator(self: *const MenuItem) bool {
        return self.kind == .separator or self.is_separator;
    }
};

// ── MenuModel (接口) ───────────────────────────────────────────────────────

pub const MenuModelIface = struct {
    getNItemsFn: *const fn (userdata: ?*anyopaque) usize,
    getItemFn: *const fn (userdata: ?*anyopaque, index: usize) ?*const MenuItem,
    isMutableFn: *const fn (userdata: ?*anyopaque) bool,
};

pub const MenuModel = struct {
    iface: *const MenuModelIface,
    userdata: ?*anyopaque,

    pub fn getNItems(self: MenuModel) usize {
        return self.iface.getNItemsFn(self.userdata);
    }
    pub fn getItem(self: MenuModel, index: usize) ?*const MenuItem {
        return self.iface.getItemFn(self.userdata, index);
    }
    pub fn isMutable(self: MenuModel) bool {
        return self.iface.isMutableFn(self.userdata);
    }
};

// ── Menu (具体实现, 对标 GMenu) ────────────────────────────────────────────

pub const Menu = struct {
    pub const Self = @This();

    pub const iface: MenuModelIface = .{
        .getNItemsFn = implGetNItems,
        .getItemFn = implGetItem,
        .isMutableFn = implIsMutable,
    };

    allocator: Allocator,
    items: ArrayListUnmanaged(MenuItem) = .{},

    pub fn new(allocator: Allocator) *Self {
        const s = allocator.create(Self) catch @panic("OOM Menu");
        s.* = .{ .allocator = allocator };
        return s;
    }

    pub fn destroy(self: *Self) void {
        const a = self.allocator;
        // 释放所有 dup 的 label / icon / action_name
        // 目前我们只拥有自己 dup 过的字符串的所有权. 这里为了简单,
        // 假设调用方传入的是静态字符串 (最常用场景); 如果要 dup 可提供 dup 版本.
        self.items.deinit(a);
        a.destroy(self);
    }

    pub fn toModel(self: *Self) MenuModel {
        return .{ .iface = &iface, .userdata = self };
    }

    // ── 修改方法 (Mutators) ────────────────────────────────────────────

    /// 在末尾追加一个已构造的 MenuItem
    pub fn appendItem(self: *Self, item: MenuItem) void {
        self.items.append(self.allocator, item) catch @panic("OOM Menu.appendItem");
    }

    /// 在末尾追加普通项: label + action_name (简单快捷方式)
    pub fn append(self: *Self, label: []const u8, action: ?[]const u8) void {
        self.appendItem(MenuItem.new(label, action));
    }

    pub fn appendSeparator(self: *Self) void {
        self.appendItem(MenuItem.newSeparator());
    }

    /// 追加子菜单项
    pub fn appendSubmenu(self: *Self, label: []const u8, submenu: *Self) void {
        self.appendItem(MenuItem.newSubmenu(label, submenu));
    }

    pub fn appendToggle(self: *Self, label: []const u8, action: []const u8, default_on: bool) void {
        self.appendItem(MenuItem.newToggle(label, action, default_on));
    }

    pub fn insert(self: *Self, position: usize, item: MenuItem) void {
        self.items.insert(self.allocator, position, item) catch @panic("OOM Menu.insert");
    }

    pub fn remove(self: *Self, position: usize) void {
        if (position < self.items.items.len) {
            _ = self.items.orderedRemove(position);
        }
    }

    pub fn clear(self: *Self) void {
        self.items.clearRetainingCapacity();
    }

    pub fn len(self: *const Self) usize {
        return self.items.items.len;
    }

    pub fn get(self: *Self, index: usize) ?*MenuItem {
        if (index >= self.items.items.len) return null;
        return &self.items.items[index];
    }

    // ── Iface impls ────────────────────────────────────────────────────

    fn implGetNItems(ud: ?*anyopaque) usize {
        const self: *Self = @ptrCast(@alignCast(ud orelse return 0));
        return self.items.items.len;
    }
    fn implGetItem(ud: ?*anyopaque, index: usize) ?*const MenuItem {
        const self: *Self = @ptrCast(@alignCast(ud orelse return null));
        if (index >= self.items.items.len) return null;
        return &self.items.items[index];
    }
    fn implIsMutable(_: ?*anyopaque) bool {
        return true;
    }
};
