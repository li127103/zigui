//! ListItemFactory / SignalListItemFactory — GTK4 列表项工厂
//!
//! GTK4 对应: GtkListItemFactory / GtkSignalListItemFactory / GtkListItem
//!
//! 用法:
//! 1. 创建 `SignalListItemFactory`
//! 2. 注册 setup 回调: 为每个 ListItem 创建子控件 (Labels, Pictures, ...)
//! 3. 注册 bind 回调: 把 model item 的数据绑定到 ListItem 的控件
//! 4. (可选) 注册 unbind / teardown 回调
//! 5. 把 factory 赋给 ColumnView / GridView / ListView
//!
//! 对 ZigUI 做了简化: 不强制通过 ListItem widget 管理，factory 的回调会得到
//! `ListItem` 对象，内含 index、item指针、以及 userdata 给使用者操作。

const std = @import("std");
const Allocator = std.mem.Allocator;

/// ListItem 对应 GtkListItem — 一个可被工厂 setup/bind 的抽象句柄
pub const ListItem = struct {
    /// 在 model 中的位置
    position: usize = 0,
    /// 指向 model item 的指针 (T 类型可直接强转)
    item: ?*anyopaque = null,
    /// 是否已选中
    selected: bool = false,
    /// 是否被激活 (激活 = 双击 / Enter)
    activatable: bool = true,
    /// 是否可选中
    selectable: bool = true,
    /// factory 管理的 userdata (比如 Label* 数组 / 自定义渲染数据)
    userdata: ?*anyopaque = null,
    /// factory 管理的 userdata 的销毁函数 (可选)
    destroy_userdata: ?*const fn (data: ?*anyopaque) void = null,
};

/// Setup/Bind/Unbind/Teardown 回调签名
/// - setup:   创建渲染控件，结果存在 list_item.userdata
/// - bind:    把 item 的数据拷贝到控件显示
/// - unbind:  解绑数据 (控件可保留，等待 reuse)
/// - teardown: 销毁 list_item.userdata
pub const SetupFn = *const fn (factory_userdata: ?*anyopaque, list_item: *ListItem) void;
pub const BindFn = *const fn (factory_userdata: ?*anyopaque, list_item: *ListItem) void;
pub const UnbindFn = ?*const fn (factory_userdata: ?*anyopaque, list_item: *ListItem) void;
pub const TeardownFn = ?*const fn (factory_userdata: ?*anyopaque, list_item: *ListItem) void;

/// Factory 接口 (vtable)
pub const ListItemFactoryIface = struct {
    setupFn: SetupFn,
    bindFn: BindFn,
    unbindFn: UnbindFn = null,
    teardownFn: TeardownFn = null,
};

/// 擦除类型的工厂胖指针
pub const ListItemFactory = struct {
    iface: *const ListItemFactoryIface,
    userdata: ?*anyopaque = null,

    pub fn setup(self: ListItemFactory, li: *ListItem) void {
        self.iface.setupFn(self.userdata, li);
    }
    pub fn bind(self: ListItemFactory, li: *ListItem) void {
        self.iface.bindFn(self.userdata, li);
    }
    pub fn unbind(self: ListItemFactory, li: *ListItem) void {
        if (self.iface.unbindFn) |f| f(self.userdata, li);
    }
    pub fn teardown(self: ListItemFactory, li: *ListItem) void {
        if (self.iface.teardownFn) |f| f(self.userdata, li);
        if (li.destroy_userdata) |d| d(li.userdata);
    }
};

/// SignalListItemFactory: 简单的 4 槽位回调工厂
pub const SignalListItemFactory = struct {
    const Self = @This();

    iface_instance: ListItemFactoryIface,
    userdata: ?*anyopaque = null,
    on_setup: SetupFn,
    on_bind: BindFn,
    on_unbind: UnbindFn = null,
    on_teardown: TeardownFn = null,

    pub const NewOpts = struct {
        on_unbind: UnbindFn = null,
        on_teardown: TeardownFn = null,
        userdata: ?*anyopaque = null,
    };

    pub fn new(
        on_setup: SetupFn,
        on_bind: BindFn,
        opts: NewOpts,
    ) Self {
        return Self{
            .iface_instance = .{
                .setupFn = &setupProxy,
                .bindFn = &bindProxy,
                .unbindFn = if (opts.on_unbind != null) &unbindProxy else null,
                .teardownFn = if (opts.on_teardown != null) &teardownProxy else null,
            },
            .userdata = opts.userdata,
            .on_setup = on_setup,
            .on_bind = on_bind,
            .on_unbind = opts.on_unbind,
            .on_teardown = opts.on_teardown,
        };
    }

    /// 得到工厂胖指针 (iface 指向内部)
    pub fn asFactory(self: *Self) ListItemFactory {
        return .{
            .iface = &self.iface_instance,
            .userdata = self,
        };
    }

    fn selfFrom(userdata: ?*anyopaque) *Self {
        return @ptrCast(@alignCast(userdata orelse @panic("factory null userdata")));
    }

    fn setupProxy(userdata: ?*anyopaque, li: *ListItem) void {
        const s = selfFrom(userdata);
        s.on_setup(s.userdata, li);
    }
    fn bindProxy(userdata: ?*anyopaque, li: *ListItem) void {
        const s = selfFrom(userdata);
        s.on_bind(s.userdata, li);
    }
    fn unbindProxy(userdata: ?*anyopaque, li: *ListItem) void {
        const s = selfFrom(userdata);
        if (s.on_unbind) |f| f(s.userdata, li);
    }
    fn teardownProxy(userdata: ?*anyopaque, li: *ListItem) void {
        const s = selfFrom(userdata);
        if (s.on_teardown) |f| f(s.userdata, li);
    }
};

/// 一个最简单的内置工厂: 把 model 的字符串 item 直接显示为 label 文本
/// 通过 PaintContext 绘制，适合默认的 ColumnView / GridView 列
pub const SimpleTextFactory = struct {
    const State = struct {
        text_fn: *const fn (item: ?*anyopaque) []const u8,
    };

    state: State,
    signal_factory: SignalListItemFactory,

    pub fn new(
        text_from_item: *const fn (item: ?*anyopaque) []const u8,
    ) SimpleTextFactory {
        var f = SimpleTextFactory{
            .state = .{ .text_fn = text_from_item },
            .signal_factory = undefined,
        };
        f.signal_factory = SignalListItemFactory.new(
            &simpleSetup,
            &simpleBind,
            .{ .userdata = &f.state },
        );
        return f;
    }

    pub fn asFactory(self: *SimpleTextFactory) ListItemFactory {
        return self.signal_factory.asFactory();
    }

    fn simpleSetup(_: ?*anyopaque, _: *ListItem) void {
        // no-op (text factory 不需要 setup 任何控件，bind 时直接画到 ctx)
    }

    fn simpleBind(userdata: ?*anyopaque, li: *ListItem) void {
        const state: *State = @ptrCast(@alignCast(userdata orelse return));
        // 把文本存进 userdata，后续 paint 回调调用 text_fn(item)
        // 这里什么都不做，等待 View 在 paint 时调用 state.text_fn(li.item)
        _ = state;
        _ = li;
    }
};

/// ListHeader 对应 GtkListHeader - 列表分组头
/// 持有一个 child Widget 和该分组在 model 中的起止索引
pub const ListHeader = struct {
    /// 分组在 model 中的起始位置
    start: usize = 0,
    /// 分组在 model 中的结束位置（exclusive）
    end: usize = 0,
    /// 该分组对应的 item（通常是第一个 item，用于生成标题）
    item: ?*anyopaque = null,
    /// factory 管理的 child widget userdata
    child: ?*anyopaque = null,
    /// child widget 的销毁函数
    destroy_child: ?*const fn (child: ?*anyopaque) void = null,

    pub fn getNItems(self: *const ListHeader) usize {
        if (self.end <= self.start) return 0;
        return self.end - self.start;
    }

    pub fn contains(self: *const ListHeader, position: usize) bool {
        return position >= self.start and position < self.end;
    }

    pub fn destroy(self: *ListHeader) void {
        if (self.destroy_child) |d| d(self.child);
        self.child = null;
    }
};

// ──────────────────────────────────────────────────────────────────────────────
// BuilderListItemFactory (GTK4: GtkBuilderListItemFactory)
// 基于 UI builder 描述（JSON/XML）的列表项工厂
// 从 UI 描述字符串解析控件模板，为每个 ListItem 创建控件并绑定属性
// ──────────────────────────────────────────────────────────────────────────────

pub const BuilderListItemFactory = struct {
    base: ListItemFactoryIface,
    allocator: std.mem.Allocator,
    /// UI 描述字符串（JSON 格式，与 builder.zig 兼容）
    ui_description: []const u8,
    /// 预解析的属性绑定规则
    bindings: std.ArrayListUnmanaged(PropertyBinding) = .empty,
    /// scope 回调（用于 closure 表达式）
    scope_data: ?*anyopaque = null,

    const Self = @This();

    /// 属性绑定规则：从 model item 提取值并设置到控件属性
    pub const PropertyBinding = struct {
        /// 控件在 UI 描述中的 id
        widget_id: []const u8,
        /// 要设置的属性名
        property_name: []const u8,
        /// 从 item 提取值的函数
        extract_fn: *const fn (item: ?*anyopaque, out: *[]const u8) void,
    };

    pub fn create(allocator: std.mem.Allocator, ui_description: []const u8) !*Self {
        const self = try allocator.create(Self);
        self.* = .{
            .base = .{
                .create_item = createItem,
                .bind_item = bindItem,
                .unbind_item = unbindItem,
                .teardown_item = teardownItem,
                .create_header = null,
                .bind_header = null,
                .iface_ptr = undefined,
            },
            .allocator = allocator,
            .ui_description = ui_description,
        };
        self.base.iface_ptr = @ptrCast(@alignCast(self));
        return self;
    }

    pub fn destroy(self: *Self) void {
        self.bindings.deinit(self.allocator);
        self.allocator.destroy(self);
    }

    /// 添加属性绑定规则
    pub fn addBinding(self: *Self, binding: PropertyBinding) !void {
        try self.bindings.append(self.allocator, binding);
    }

    /// 设置 scope 数据（供 closure 表达式使用）
    pub fn setScope(self: *Self, data: ?*anyopaque) void {
        self.scope_data = data;
    }

    fn createItem(iface: *ListItemFactoryIface, allocator: std.mem.Allocator, li: *ListItem) void {
        _ = iface;
        // 简化：创建一个 Label 占位控件
        // 实际实现应解析 ui_description 并构建控件树
        const label_mod = @import("../widget/label.zig");
        const label = label_mod.Label.create(allocator, "", .{}) catch return;
        li.child = &label.base;
        li.item = null;
    }

    fn bindItem(iface: *ListItemFactoryIface, li: *ListItem) void {
        const self: *Self = @ptrCast(@alignCast(iface.iface_ptr));
        if (li.child == null) return;

        // 对每个绑定规则，从 item 提取值并设置到控件
        for (self.bindings.items) |binding| {
            if (li.item) |item| {
                var value_str: []const u8 = "";
                binding.extract_fn(item, &value_str);
                binding.property_name.len; // 标记使用
            }
        }
    }

    fn unbindItem(iface: *ListItemFactoryIface, li: *ListItem) void {
        _ = iface;
        _ = li;
    }

    fn teardownItem(iface: *ListItemFactoryIface, allocator: std.mem.Allocator, li: *ListItem) void {
        _ = iface;
        if (li.child) |child| {
            child.destroy(allocator);
            li.child = null;
        }
    }
};
