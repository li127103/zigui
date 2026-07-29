//! Application + ApplicationWindow — GTK4 风格应用层
//!
//! 对标 GTK4:
//!   - GtkApplication (GApplication)：跨窗口的动作 (app.*)、menubar、窗口管理、activate/open 信号
//!   - GtkApplicationWindow：带 win.* 作用域动作、可显示菜单栏的窗口
//!
//! 典型用法:
//! ```
//! var app = try Application.create(alloc, "org.example.App", .{});
//! defer app.destroy();
//! app.addActionSimple("quit", &onAppQuit, app);
//!
//! var win = try ApplicationWindow.create(app, my_window);
//! defer win.destroy();
//! win.addActionSimple("new", &onFileNew, win);
//! win.setShowMenubar(true);
//! app.addWindow(win);
//!
//! app.activate(); // 触发 on_activate
//! while (running) { ... processEvents ... }
//! ```

const std = @import("std");
const Allocator = std.mem.Allocator;
const ArrayListUnmanaged = std.ArrayListUnmanaged;

const WindowType = @import("window.zig").Window;
const model_mod = @import("model/menu_model.zig");
const ModelMenu = model_mod.Menu;
const action_mod = @import("model/action.zig");
const ActionGroup = action_mod.ActionGroup;
const SimpleActionGroup = action_mod.SimpleActionGroup;
const ActionValue = action_mod.ActionValue;
const SimpleAction = action_mod.SimpleAction;

pub const ActivateFn = *const fn (app: *Application) void;
pub const OpenFn = *const fn (app: *Application, files: []const []const u8, hint: []const u8) void;
pub const ShutdownFn = *const fn (app: *Application) void;
pub const SimpleActivateFn = *const fn (ud: ?*anyopaque) void;

/// GtkApplication (GApplication) 简化版
pub const Application = struct {
    const Self = @This();

    allocator: Allocator,
    /// D-Bus 风格的应用 id (如 "org.example.MyApp")
    application_id: []const u8,
    /// app.* 作用域动作
    app_actions: *SimpleActionGroup,
    /// 菜单栏 (若设置, ApplicationWindow.showMenubar=true 时会显示)
    menubar: ?*ModelMenu = null,
    /// 窗口列表
    windows: ArrayListUnmanaged(?*ApplicationWindow) = .{},
    /// 当前激活窗口
    active_window: ?*ApplicationWindow = null,
    /// 运行状态 (quit() 会置 false)
    is_running: bool = false,
    /// 回调
    on_activate: ?ActivateFn = null,
    on_open: ?OpenFn = null,
    on_shutdown: ?ShutdownFn = null,
    on_activate_userdata: ?*anyopaque = null,
    on_open_userdata: ?*anyopaque = null,
    on_shutdown_userdata: ?*anyopaque = null,

    /// 创建 Application
    pub fn create(allocator: Allocator, application_id: []const u8, opts: struct {
        on_activate: ?ActivateFn = null,
        on_open: ?OpenFn = null,
        on_shutdown: ?ShutdownFn = null,
        on_activate_userdata: ?*anyopaque = null,
        on_open_userdata: ?*anyopaque = null,
        on_shutdown_userdata: ?*anyopaque = null,
    }) !*Self {
        const id_dup = try allocator.dupe(u8, application_id);
        const app = try allocator.create(Self);
        const sags = try SimpleActionGroup.create(allocator);
        app.* = .{
            .allocator = allocator,
            .application_id = id_dup,
            .app_actions = sags,
            .on_activate = opts.on_activate,
            .on_open = opts.on_open,
            .on_shutdown = opts.on_shutdown,
            .on_activate_userdata = opts.on_activate_userdata,
            .on_open_userdata = opts.on_open_userdata,
            .on_shutdown_userdata = opts.on_shutdown_userdata,
        };
        return app;
    }

    pub fn destroy(self: *Self) void {
        // destroy 所有 windows
        for (self.windows.items) |opt_win| {
            if (opt_win) |w| {
                // 释放其动作 (注意不要回删, 因为正在迭代)
                w.application = null;
                w.destroyActionsOnly();
            }
        }
        self.windows.deinit(self.allocator);
        self.app_actions.destroy();
        self.allocator.free(self.application_id);
        self.allocator.destroy(self);
    }

    pub fn getApplicationId(self: *const Self) []const u8 {
        return self.application_id;
    }

    /// 获取 app.* 作用域的 ActionGroup (用于 "app.cut" 等前缀)
    pub fn getAppActionGroup(self: *Self) ActionGroup {
        return self.app_actions.asGroup();
    }

    // ── Actions (app.*) ──────────────────────────────────────────────────

    /// 添加无参数 activate 回调的便捷 API
    pub fn addStatelessActivate(self: *Self, name: []const u8, cb: *const fn (?*anyopaque) void, userdata: ?*anyopaque) !void {
        const act = try SimpleAction.newStateless(self.allocator, name, null);
        act.on_activate = cb;
        act.on_activate_userdata = userdata;
        try self.app_actions.addAction(act);
    }

    /// 添加无参数 activate 便捷方法 (别名 addStatelessActivate)
    pub fn addActionSimple(self: *Self, name: []const u8, cb: *const fn (?*anyopaque) void, userdata: ?*anyopaque) !void {
        try self.addStatelessActivate(name, cb, userdata);
    }

    /// 简化版: 直接添加一个已构建的 SimpleAction
    pub fn addAction(self: *Self, action: *SimpleAction) !void {
        try self.app_actions.addAction(action);
    }

    /// 添加有状态的 toggle action (如 boolean state)
    pub fn addToggle(self: *Self, name: []const u8, initial_state: bool, on_toggled: *const fn (ud: ?*anyopaque, new_state: bool) void, userdata: ?*anyopaque) !void {
        const act = try SimpleAction.newToggle(self.allocator, name, initial_state, .{
            .on_toggled = on_toggled,
            .on_toggled_userdata = userdata,
        });
        try self.app_actions.addAction(act);
    }

    // ── 窗口管理 ──────────────────────────────────────────────────────────

    pub fn addWindow(self: *Self, win: *ApplicationWindow) !void {
        win.application = self;
        try self.windows.append(self.allocator, win);
        if (self.active_window == null) self.active_window = win;
    }

    pub fn removeWindow(self: *Self, win: *ApplicationWindow) void {
        for (self.windows.items, 0..) |opt, i| {
            if (opt == win) {
                _ = self.windows.orderedRemove(i);
                if (self.active_window == win) {
                    self.active_window = if (self.windows.items.len > 0) self.windows.items[0] else null;
                }
                win.application = null;
                return;
            }
        }
    }

    pub fn getWindows(self: *const Self) []const ?*ApplicationWindow {
        return self.windows.items;
    }

    pub fn getActiveWindow(self: *const Self) ?*ApplicationWindow {
        return self.active_window;
    }

    pub fn setActiveWindow(self: *Self, win: ?*ApplicationWindow) void {
        self.active_window = win;
    }

    // ── 菜单栏 ────────────────────────────────────────────────────────────

    pub fn setMenubar(self: *Self, mb: ?*ModelMenu) void {
        self.menubar = mb;
        // 通知所有打开的窗口刷新菜单栏
        for (self.windows.items) |opt| {
            if (opt) |w| w.requestMenubarRedraw();
        }
    }

    pub fn getMenubar(self: *const Self) ?*ModelMenu {
        return self.menubar;
    }

    // ── 生命周期 ──────────────────────────────────────────────────────────

    /// 发送 activate 信号
    pub fn activate(self: *Self) void {
        self.is_running = true;
        if (self.on_activate) |cb| {
            cb(self);
        }
    }

    /// 发送 open 信号
    pub fn open(self: *Self, files: []const []const u8, hint: []const u8) void {
        if (self.on_open) |cb| cb(self, files, hint);
    }

    /// 请求退出 (is_running=false, 发送 shutdown)
    pub fn quit(self: *Self) void {
        self.is_running = false;
        if (self.on_shutdown) |cb| cb(self);
    }

    /// 便捷: 创建一个绑定 "app.quit" 的内置动作
    pub fn installQuitAction(self: *Self) !void {
        try self.addStatelessActivate("quit", struct {
            fn quitApp(ud: ?*anyopaque) void {
                const app: *Self = @ptrCast(@alignCast(ud orelse return));
                app.quit();
            }
        }.quitApp, @ptrCast(self));
    }
};

/// GtkApplicationWindow 简化版
/// 持有底层 Window (GtkWindow) + win.* 作用域 ActionGroup
pub const ApplicationWindow = struct {
    const Self = @This();

    allocator: Allocator,
    /// 关联的底层窗口
    window: *WindowType,
    /// 所属 Application (可有可无; addWindow 时自动赋值)
    application: ?*Application = null,
    /// win.* 作用域动作
    win_actions: *SimpleActionGroup,
    /// 是否显示菜单栏 (若为 true 且 Application 有 menubar, 顶部显示)
    show_menubar: bool = false,
    /// 请求菜单栏重绘标记 (由 setMenubar 设置, UI 循环每帧可消费)
    menubar_dirty: bool = false,

    user_data: ?*anyopaque = null,
    on_close: ?*const fn (win: *Self) void = null,

    pub fn create(app_or_alloc: anytype, win: *WindowType) !*Self {
        // 兼容两种创建方式:
        //   create(app: *Application, win) — add to app
        //   create(allocator, win) — 独立, 不关联 app
        const allocator: Allocator = if (@TypeOf(app_or_alloc) == *Application)
            app_or_alloc.allocator
        else
            app_or_alloc;
        const self = try allocator.create(Self);
        const sags = try SimpleActionGroup.create(allocator);
        self.* = .{
            .allocator = allocator,
            .window = win,
            .win_actions = sags,
        };
        if (@TypeOf(app_or_alloc) == *Application) {
            try app_or_alloc.addWindow(self);
        }
        return self;
    }

    pub fn destroy(self: *Self) void {
        self.destroyActionsOnly();
        self.allocator.destroy(self);
    }

    /// 只销毁 actions (由 Application 批量调用, 避免双 free)
    pub fn destroyActionsOnly(self: *Self) void {
        self.win_actions.destroy();
    }

    pub fn getWindow(self: *Self) *WindowType {
        return self.window;
    }

    pub fn getApplication(self: *Self) ?*Application {
        return self.application;
    }

    /// 获取 win.* 作用域 ActionGroup
    pub fn getWinActionGroup(self: *Self) ActionGroup {
        return self.win_actions.asGroup();
    }

    // ── win.* Actions ────────────────────────────────────────────────────

    pub fn addAction(self: *Self, action: *SimpleAction) !void {
        try self.win_actions.addAction(action);
    }

    pub fn addStatelessActivate(self: *Self, name: []const u8, cb: *const fn (?*anyopaque) void, userdata: ?*anyopaque) !void {
        const act = try SimpleAction.newStateless(self.allocator, name, null);
        act.on_activate = cb;
        act.on_activate_userdata = userdata;
        try self.win_actions.addAction(act);
    }

    pub fn addToggle(self: *Self, name: []const u8, initial_state: bool, on_toggled: *const fn (ud: ?*anyopaque, new_state: bool) void, userdata: ?*anyopaque) !void {
        const act = try SimpleAction.newToggle(self.allocator, name, initial_state, .{
            .on_toggled = on_toggled,
            .on_toggled_userdata = userdata,
        });
        try self.win_actions.addAction(act);
    }

    // ── 菜单栏显示 ────────────────────────────────────────────────────────

    pub fn setShowMenubar(self: *Self, v: bool) void {
        self.show_menubar = v;
        self.menubar_dirty = true;
    }

    pub fn getShowMenubar(self: *const Self) bool {
        return self.show_menubar;
    }

    pub fn requestMenubarRedraw(self: *Self) void {
        self.menubar_dirty = true;
    }

    /// 消费 dirty 标记 (UI 循环每帧调用, 返回 true 表示需要重建菜单栏 UI)
    pub fn consumeMenubarDirty(self: *Self) bool {
        const d = self.menubar_dirty;
        self.menubar_dirty = false;
        return d;
    }
};
