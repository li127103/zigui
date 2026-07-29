//! Action 动作系统 (对标 GSimpleAction / GActionMap / GActionGroup)
//!
//! 核心概念:
//!   - Action       : 带名字的可执行动作, 可带 parameter_type 和 state (开关/单选/任意值)
//!   - SimpleAction : 最常用实现, 支持 on_activate / on_change_state 回调
//!   - ActionMap    : 动作注册容器 (add/remove/lookup)
//!   - ActionGroup  : 按名字查询和触发一组动作 (list/lookup/query/activate/changeState)
//!   - SimpleActionGroup : 同时实现 ActionMap + ActionGroup

const std = @import("std");
const Allocator = std.mem.Allocator;
const ArrayListUnmanaged = std.ArrayListUnmanaged;
const StringHashMapUnmanaged = std.StringHashMapUnmanaged;

// ── ActionValue (Variant 的简化替代) ───────────────────────────────────────

/// 动作参数/状态值的简单联合体 (对标 GVariant 的常用子集)
pub const ActionValue = union(enum) {
    none,
    bool: bool,
    int: i64,
    float: f64,
    string: []const u8,
    /// 任意指针 (由调用方管理生命周期/类型安全)
    pointer: ?*anyopaque,

    pub fn asBool(self: ActionValue) ?bool {
        return if (self == .bool) self.bool else null;
    }
    pub fn asInt(self: ActionValue) ?i64 {
        return if (self == .int) self.int else null;
    }
    pub fn asFloat(self: ActionValue) ?f64 {
        return if (self == .float) self.float else null;
    }
    pub fn asString(self: ActionValue) ?[]const u8 {
        return if (self == .string) self.string else null;
    }
};

// ── ActionIface (虚函数表) ─────────────────────────────────────────────────

pub const ActivateFn = *const fn (userdata: ?*anyopaque, parameter: ActionValue) void;
pub const ChangeStateFn = *const fn (userdata: ?*anyopaque, value: ActionValue) void;

pub const ActionIface = struct {
    /// 动作名
    getNameFn: *const fn (userdata: ?*anyopaque) []const u8,
    isEnabledFn: *const fn (userdata: ?*anyopaque) bool,
    setEnabledFn: ?*const fn (userdata: ?*anyopaque, enabled: bool) void = null,
    getStateFn: ?*const fn (userdata: ?*anyopaque) ActionValue = null,
    setStateFn: ?*const fn (userdata: ?*anyopaque, value: ActionValue) void = null,
    getParameterTypeFn: ?*const fn (userdata: ?*anyopaque) []const u8 = null,
    getStateTypeFn: ?*const fn (userdata: ?*anyopaque) []const u8 = null,
    activateFn: ActivateFn,
    changeStateFn: ?ChangeStateFn = null,
};

/// 胖指针 (对标 GAction*)
pub const Action = struct {
    iface: *const ActionIface,
    userdata: ?*anyopaque,

    pub fn getName(self: Action) []const u8 {
        return self.iface.getNameFn(self.userdata);
    }
    pub fn isEnabled(self: Action) bool {
        return self.iface.isEnabledFn(self.userdata);
    }
    pub fn setEnabled(self: Action, enabled: bool) void {
        if (self.iface.setEnabledFn) |f| f(self.userdata, enabled);
    }
    pub fn getState(self: Action) ?ActionValue {
        return if (self.iface.getStateFn) |f| f(self.userdata) else null;
    }
    pub fn setState(self: Action, value: ActionValue) void {
        if (self.iface.setStateFn) |f| f(self.userdata, value);
    }
    pub fn activate(self: Action, parameter: ActionValue) void {
        self.iface.activateFn(self.userdata, parameter);
    }
    pub fn changeState(self: Action, value: ActionValue) void {
        if (self.iface.changeStateFn) |f| f(self.userdata, value) else self.setState(value);
    }
};

// ── SimpleAction (对标 GSimpleAction) ──────────────────────────────────────

pub const SimpleAction = struct {
    pub const Self = @This();
    /// 静态虚函数表 (整个类型共享一份)
    pub const vtable: ActionIface = .{
        .getNameFn = implGetName,
        .isEnabledFn = implIsEnabled,
        .setEnabledFn = implSetEnabled,
        .getStateFn = implGetState,
        .setStateFn = implSetState,
        .activateFn = implActivate,
        .changeStateFn = implChangeState,
    };

    /// 固定虚表指针 (必须在首字段)
    iface_ptr: *const ActionIface = &vtable,

    name: []const u8,
    enabled: bool = true,
    parameter_type: []const u8 = "", // "" 表示无参数, 或用类型名标识 (b/s/i/d)
    state_type: []const u8 = "", // "" 表示无状态
    state: ActionValue = .none,
    /// activate 回调
    on_activate: ?*const fn (self: *Self, parameter: ActionValue) void = null,
    on_activate_userdata: ?*anyopaque = null,
    /// change-state 回调 (由用户手动设置 state 的最终值)
    on_change_state: ?*const fn (self: *Self, value: ActionValue) void = null,
    on_change_state_userdata: ?*anyopaque = null,
    /// state 改变后的通知
    on_state_changed: ?*const fn (self: *Self, new_state: ActionValue) void = null,
    on_state_changed_userdata: ?*anyopaque = null,
    /// 便捷: 针对 bool 状态的 toggled 回调 (与 on_state_changed 互斥, 但都可被同时调用)
    on_toggled: ?*const fn (self: *Self, new_value: bool) void = null,

    /// 动作分配器 (由创建者负责销毁时调用 destroy)
    allocator: Allocator,
    /// name 是否为堆分配 (dup 过的字符串需要 free)
    owned_name: bool = false,

    // ---------- 构造 ----------

    /// 创建一个无状态动作
    pub fn newStateless(
        allocator: Allocator,
        name: []const u8,
        on_activate: *const fn (self: *Self, parameter: ActionValue) void,
    ) !*Self {
        const s = try allocator.create(Self);
        s.* = .{
            .allocator = allocator,
            .name = name,
            .on_activate = on_activate,
        };
        return s;
    }

    /// 创建一个布尔开关动作 (stateful, type=bool)
    pub fn newToggle(
        allocator: Allocator,
        name: []const u8,
        default_state: bool,
        on_toggled: ?*const fn (self: *Self, new_value: bool) void,
    ) !*Self {
        const s = try allocator.create(Self);
        s.* = .{
            .allocator = allocator,
            .name = name,
            .state_type = "b",
            .state = .{ .bool = default_state },
            .on_toggled = on_toggled,
        };
        return s;
    }

    /// 用户自定义回调的布尔开关动作 (使用更直接的字段, 避免上述复杂闭包问题)
    pub fn newToggleSimple(
        allocator: Allocator,
        name: []const u8,
        default_state: bool,
    ) !*Self {
        const s = try allocator.create(Self);
        s.* = .{
            .allocator = allocator,
            .name = name,
            .state_type = "b",
            .state = .{ .bool = default_state },
        };
        return s;
    }

    pub fn destroy(self: *Self) void {
        const a = self.allocator;
        if (self.owned_name) a.free(self.name);
        a.destroy(self);
    }

    pub fn toAction(self: *Self) Action {
        return .{ .iface = &vtable, .userdata = self };
    }

    // ---------- 便捷方法 ----------

    pub fn setEnabled(self: *Self, enabled: bool) void {
        self.enabled = enabled;
    }

    pub fn getStateBool(self: *const Self) ?bool {
        return self.state.asBool();
    }

    /// 对于 toggle 动作: 切换布尔状态并触发 changeState
    pub fn toggle(self: *Self) void {
        if (self.state == .bool) {
            self.changeState(.{ .bool = !self.state.bool });
        }
    }

    pub fn changeState(self: *Self, value: ActionValue) void {
        if (self.on_change_state) |cb| {
            cb(self, value);
        } else {
            // 默认行为: 直接设置并通知
            self.state = value;
        }
        if (self.on_state_changed) |cb| cb(self, self.state);
        if (self.on_toggled) |cb| {
            if (self.state == .bool) cb(self, self.state.bool);
        }
    }

    pub fn activate(self: *Self, parameter: ActionValue) void {
        if (!self.enabled) return;
        // 对 toggle 动作: 默认 activate 切换开关
        if (self.state == .bool and self.on_activate == null) {
            self.toggle();
            return;
        }
        if (self.on_activate) |cb| cb(self, parameter);
    }

    // ---------- Iface impls ----------

    fn implGetName(ud: ?*anyopaque) []const u8 {
        const self: *Self = @ptrCast(@alignCast(ud orelse return ""));
        return self.name;
    }
    fn implIsEnabled(ud: ?*anyopaque) bool {
        const self: *Self = @ptrCast(@alignCast(ud orelse return false));
        return self.enabled;
    }
    fn implSetEnabled(ud: ?*anyopaque, enabled: bool) void {
        const self: *Self = @ptrCast(@alignCast(ud orelse return));
        self.enabled = enabled;
    }
    fn implGetState(ud: ?*anyopaque) ActionValue {
        const self: *Self = @ptrCast(@alignCast(ud orelse return .none));
        return self.state;
    }
    fn implSetState(ud: ?*anyopaque, value: ActionValue) void {
        const self: *Self = @ptrCast(@alignCast(ud orelse return));
        self.state = value;
    }
    fn implActivate(ud: ?*anyopaque, parameter: ActionValue) void {
        const self: *Self = @ptrCast(@alignCast(ud orelse return));
        self.activate(parameter);
    }
    fn implChangeState(ud: ?*anyopaque, value: ActionValue) void {
        const self: *Self = @ptrCast(@alignCast(ud orelse return));
        self.changeState(value);
    }
};

// ── ActionGroupIface ───────────────────────────────────────────────────────

pub const ActionGroupIface = struct {
    listActionsFn: *const fn (userdata: ?*anyopaque, out: *ArrayListUnmanaged([]const u8)) void,
    queryActionFn: *const fn (userdata: ?*anyopaque, name: []const u8) ?Action,
    hasActionFn: *const fn (userdata: ?*anyopaque, name: []const u8) bool,
    activateActionFn: *const fn (userdata: ?*anyopaque, name: []const u8, parameter: ActionValue) bool,
    changeActionStateFn: *const fn (userdata: ?*anyopaque, name: []const u8, value: ActionValue) bool,
    actionGetEnabledFn: *const fn (userdata: ?*anyopaque, name: []const u8) ?bool,
    actionGetStateFn: *const fn (userdata: ?*anyopaque, name: []const u8) ?ActionValue,
};

pub const ActionGroup = struct {
    iface: *const ActionGroupIface,
    userdata: ?*anyopaque,

    pub fn hasAction(self: ActionGroup, name: []const u8) bool {
        return self.iface.hasActionFn(self.userdata, name);
    }
    pub fn lookupAction(self: ActionGroup, name: []const u8) ?Action {
        return self.iface.queryActionFn(self.userdata, name);
    }
    pub fn listActions(self: ActionGroup, out: *ArrayListUnmanaged([]const u8)) void {
        self.iface.listActionsFn(self.userdata, out);
    }
    pub fn activateAction(self: ActionGroup, name: []const u8, parameter: ActionValue) bool {
        return self.iface.activateActionFn(self.userdata, name, parameter);
    }
    pub fn changeActionState(self: ActionGroup, name: []const u8, value: ActionValue) bool {
        return self.iface.changeActionStateFn(self.userdata, name, value);
    }
};

// ── ActionMapIface ─────────────────────────────────────────────────────────

pub const ActionMapIface = struct {
    addActionFn: *const fn (userdata: ?*anyopaque, action: Action) void,
    removeActionFn: *const fn (userdata: ?*anyopaque, name: []const u8) ?Action,
    lookupActionFn: *const fn (userdata: ?*anyopaque, name: []const u8) ?Action,
};

pub const ActionMap = struct {
    iface: *const ActionMapIface,
    userdata: ?*anyopaque,

    pub fn addAction(self: ActionMap, action: Action) void {
        self.iface.addActionFn(self.userdata, action);
    }
    pub fn removeAction(self: ActionMap, name: []const u8) ?Action {
        return self.iface.removeActionFn(self.userdata, name);
    }
    pub fn lookupAction(self: ActionMap, name: []const u8) ?Action {
        return self.iface.lookupActionFn(self.userdata, name);
    }
};

// ── SimpleActionGroup (同时实现 ActionMap + ActionGroup) ──────────────────

pub const SimpleActionGroup = struct {
    pub const Self = @This();

    pub const group_vtable: ActionGroupIface = .{
        .listActionsFn = implListActions,
        .queryActionFn = implQueryAction,
        .hasActionFn = implHasAction,
        .activateActionFn = implActivateAction,
        .changeActionStateFn = implChangeActionState,
        .actionGetEnabledFn = implActionGetEnabled,
        .actionGetStateFn = implActionGetState,
    };

    pub const map_vtable: ActionMapIface = .{
        .addActionFn = implAddAction,
        .removeActionFn = implRemoveAction,
        .lookupActionFn = implLookupAction,
    };

    allocator: Allocator,
    actions: StringHashMapUnmanaged(Action) = .{},
    /// 保存 SimpleAction* 便于 destroy（若创建时拥有所有权）
    owned_simple: ArrayListUnmanaged(*SimpleAction) = .{},

    pub fn create(allocator: Allocator) *Self {
        const s = allocator.create(Self) catch @panic("OOM SimpleActionGroup");
        s.* = .{ .allocator = allocator };
        return s;
    }

    pub fn destroy(self: *Self) void {
        const a = self.allocator;
        var it = self.owned_simple.iterator(a);
        while (it.next()) |sa| sa.destroy();
        self.owned_simple.deinit(a);
        self.actions.deinit(a);
        a.destroy(self);
    }

    pub fn asActionGroup(self: *Self) ActionGroup {
        return .{ .iface = &group_vtable, .userdata = self };
    }

    pub fn asActionMap(self: *Self) ActionMap {
        return .{ .iface = &map_vtable, .userdata = self };
    }

    /// 便捷: 直接注册 SimpleAction* (SimpleActionGroup 拥有所有权, destroy 时释放)
    pub fn addSimple(self: *Self, sa: *SimpleAction) void {
        self.actions.put(self.allocator, sa.name, sa.toAction()) catch @panic("OOM addSimple");
        self.owned_simple.append(self.allocator, sa) catch @panic("OOM addSimple owned");
    }

    pub fn addRaw(self: *Self, action: Action) void {
        self.actions.put(self.allocator, action.getName(), action) catch @panic("OOM addRaw");
    }

    pub fn hasAction(self: *const Self, name: []const u8) bool {
        return self.actions.contains(name);
    }

    pub fn lookupAction(self: *const Self, name: []const u8) ?Action {
        return self.actions.get(name);
    }

    pub fn removeAction(self: *Self, name: []const u8) ?Action {
        const old = self.actions.fetchRemove(name);
        return if (old) |kv| kv.value else null;
    }

    pub fn activateAction(self: *Self, name: []const u8, parameter: ActionValue) bool {
        const a = self.actions.get(name) orelse return false;
        a.activate(parameter);
        return true;
    }

    pub fn changeActionState(self: *Self, name: []const u8, value: ActionValue) bool {
        const a = self.actions.get(name) orelse return false;
        a.changeState(value);
        return true;
    }

    pub fn listActions(self: *const Self, out: *ArrayListUnmanaged([]const u8)) void {
        var it = self.actions.keyIterator();
        while (it.next()) |k| {
            out.append(self.allocator, k.*) catch @panic("OOM listActions");
        }
    }

    // ── Iface impls ──────────────────────────────────────────────────────

    fn implListActions(ud: ?*anyopaque, out: *ArrayListUnmanaged([]const u8)) void {
        const self: *Self = @ptrCast(@alignCast(ud orelse return));
        self.listActions(out);
    }
    fn implQueryAction(ud: ?*anyopaque, name: []const u8) ?Action {
        const self: *Self = @ptrCast(@alignCast(ud orelse return null));
        return self.lookupAction(name);
    }
    fn implHasAction(ud: ?*anyopaque, name: []const u8) bool {
        const self: *Self = @ptrCast(@alignCast(ud orelse return false));
        return self.hasAction(name);
    }
    fn implActivateAction(ud: ?*anyopaque, name: []const u8, parameter: ActionValue) bool {
        const self: *Self = @ptrCast(@alignCast(ud orelse return false));
        return self.activateAction(name, parameter);
    }
    fn implChangeActionState(ud: ?*anyopaque, name: []const u8, value: ActionValue) bool {
        const self: *Self = @ptrCast(@alignCast(ud orelse return false));
        return self.changeActionState(name, value);
    }
    fn implActionGetEnabled(ud: ?*anyopaque, name: []const u8) ?bool {
        const self: *Self = @ptrCast(@alignCast(ud orelse return null));
        const a = self.actions.get(name) orelse return null;
        return a.isEnabled();
    }
    fn implActionGetState(ud: ?*anyopaque, name: []const u8) ?ActionValue {
        const self: *Self = @ptrCast(@alignCast(ud orelse return null));
        const a = self.actions.get(name) orelse return null;
        return a.getState();
    }
    fn implAddAction(ud: ?*anyopaque, action: Action) void {
        const self: *Self = @ptrCast(@alignCast(ud orelse return));
        self.addRaw(action);
    }
    fn implRemoveAction(ud: ?*anyopaque, name: []const u8) ?Action {
        const self: *Self = @ptrCast(@alignCast(ud orelse return null));
        return self.removeAction(name);
    }
    fn implLookupAction(ud: ?*anyopaque, name: []const u8) ?Action {
        const self: *Self = @ptrCast(@alignCast(ud orelse return null));
        return self.lookupAction(name);
    }
};
