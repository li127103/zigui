//! GdkDisplayManager + GdkDisplay + GdkMonitor — GTK4 显示/屏幕抽象
//!
//! 对标 GDK4：
//!   - GdkDisplayManager：单例，持有 Display 列表，管理默认显示
//!   - GdkDisplay：连接到某一 X11/Wayland/Cocoa/Win32 显示服务器，包含若干 Monitor
//!   - GdkMonitor：物理显示器（位置/尺寸/缩放/刷新率/是否主屏）
//!
//! 本实现为 vtable + self_ptr 类型擦除接口，PAL/平台层可注入具体实现。
//!

const std = @import("std");
const math = @import("../math.zig");

// ═══════════════════════════════════════════════════════════════════════════════
//  GdkMonitor
// ═══════════════════════════════════════════════════════════════════════════════

pub const GdkMonitor = struct {
    /// 制造商（EDID；未知留空）
    manufacturer: []const u8 = "",
    /// 型号（EDID；未知留空）
    model: []const u8 = "",
    /// 整个屏幕（全局桌面坐标系下的几何区域）
    geometry: math.Rect(i32) = .{ .x = 0, .y = 0, .width = 1920, .height = 1080 },
    /// 工作区（去掉 taskbar/dock 后）
    workarea: math.Rect(i32) = .{ .x = 0, .y = 0, .width = 1920, .height = 1040 },
    /// 整数缩放：1 / 2 / 3 ...
    scale_factor: i32 = 1,
    /// 刷新率（单位 mHz，60Hz = 60_000 mHz）
    refresh_rate: i32 = 60_000,
    /// 是否主显示器
    is_primary: bool = false,
    /// 所属 Display 裸指针（类型擦除，可转回 *GdkDisplay）
    display: ?*anyopaque = null,
    /// 描述性名称（如 `DP-1` / `内置显示器` / `DELL U2723QE`）
    connector: []const u8 = "",
};

// ═══════════════════════════════════════════════════════════════════════════════
//  GdkDisplayIface + 类型擦除 GdkDisplay
// ═══════════════════════════════════════════════════════════════════════════════

pub const GdkDisplayIface = struct {
    get_n_monitors: *const fn (self_ptr: ?*anyopaque) u32 = defaultGetNMonitors,
    get_monitor: *const fn (self_ptr: ?*anyopaque, idx: u32) ?*const GdkMonitor = defaultGetMonitor,
    get_default_monitor: *const fn (self_ptr: ?*anyopaque) ?*const GdkMonitor = defaultGetDefaultMonitor,
    get_name: *const fn (self_ptr: ?*anyopaque) []const u8 = defaultGetName,
    is_closed: *const fn (self_ptr: ?*anyopaque) bool = defaultIsClosed,
    sync: *const fn (self_ptr: ?*anyopaque) void = defaultSync,
    make_default: *const fn (self_ptr: ?*anyopaque) void = defaultMakeDefault,
    beep: *const fn (self_ptr: ?*anyopaque) void = defaultBeep,
    // 可选：Seat（键盘/鼠标/触控板/手写板聚合）；默认返回 null
    get_default_seat: *const fn (self_ptr: ?*anyopaque) ?*anyopaque = defaultGetDefaultSeat,

    // ── 默认实现（占位） ────────────────────────────────────────────────
    fn defaultGetNMonitors(_: ?*anyopaque) u32 {
        return 0;
    }
    fn defaultGetMonitor(_: ?*anyopaque, _: u32) ?*const GdkMonitor {
        return null;
    }
    fn defaultGetDefaultMonitor(s: ?*anyopaque) ?*const GdkMonitor {
        if (defaultGetNMonitors(s) == 0) return null;
        return defaultGetMonitor(s, 0);
    }
    fn defaultGetName(_: ?*anyopaque) []const u8 {
        return "";
    }
    fn defaultIsClosed(_: ?*anyopaque) bool {
        return false;
    }
    fn defaultSync(_: ?*anyopaque) void {}
    fn defaultMakeDefault(_: ?*anyopaque) void {}
    fn defaultBeep(_: ?*anyopaque) void {}
    fn defaultGetDefaultSeat(_: ?*anyopaque) ?*anyopaque {
        return null;
    }
};

pub const GdkDisplay = struct {
    iface: GdkDisplayIface = .{},
    self_ptr: ?*anyopaque = null,
    user_data: ?*anyopaque = null,

    pub fn wrap(obj_ptr: ?*anyopaque, iface: GdkDisplayIface) GdkDisplay {
        return .{ .iface = iface, .self_ptr = obj_ptr };
    }

    // ── 转发 ──────────────────────────────────────────────────────────────
    pub fn getNMonitors(self: *const GdkDisplay) u32 {
        return self.iface.get_n_monitors(self.self_ptr);
    }
    pub fn getMonitor(self: *const GdkDisplay, idx: u32) ?*const GdkMonitor {
        return self.iface.get_monitor(self.self_ptr, idx);
    }
    pub fn getDefaultMonitor(self: *const GdkDisplay) ?*const GdkMonitor {
        return self.iface.get_default_monitor(self.self_ptr);
    }
    pub fn getName(self: *const GdkDisplay) []const u8 {
        return self.iface.get_name(self.self_ptr);
    }
    pub fn isClosed(self: *const GdkDisplay) bool {
        return self.iface.is_closed(self.self_ptr);
    }
    pub fn sync(self: *const GdkDisplay) void {
        self.iface.sync(self.self_ptr);
    }
    pub fn makeDefault(self: *const GdkDisplay) void {
        self.iface.make_default(self.self_ptr);
    }
    pub fn beep(self: *const GdkDisplay) void {
        self.iface.beep(self.self_ptr);
    }
    pub fn getDefaultSeat(self: *const GdkDisplay) ?*anyopaque {
        return self.iface.get_default_seat(self.self_ptr);
    }
};

// ═══════════════════════════════════════════════════════════════════════════════
//  简易 FakeDisplay：零启动成本、可填充 N 个 GdkMonitor 的纯数据实现
//  （测试 / 无显示环境 可直接用；PAL 实现可注入真实后端）
// ═══════════════════════════════════════════════════════════════════════════════

pub const FakeDisplay = struct {
    name: []const u8 = "fake-0",
    closed: bool = false,
    monitors: std.ArrayListUnmanaged(GdkMonitor) = .{},

    const Fake = @This();

    /// 构造一个默认 1080p FakeDisplay（含 1 个主显示器）
    pub fn createDefault(allocator: std.mem.Allocator, primary_scale: i32) !Fake {
        var monitors = std.ArrayListUnmanaged(GdkMonitor){};
        try monitors.append(allocator, .{
            .manufacturer = "Fake",
            .model = "Fake-27inch-1080p",
            .connector = "Fake-1",
            .is_primary = true,
            .scale_factor = primary_scale,
            .geometry = .{ .x = 0, .y = 0, .width = 1920, .height = 1080 },
            .workarea = .{ .x = 0, .y = 0, .width = 1920, .height = 1040 },
            .refresh_rate = 60_000,
        });
        return .{ .name = "fake-0", .monitors = monitors };
    }

    pub fn deinit(self: *Fake, allocator: std.mem.Allocator) void {
        self.monitors.deinit(allocator);
    }

    // ── 若以 Fake 作为 self_ptr → 这些函数可直接挂到 GdkDisplayIface ─────
    pub fn ifaceGetNMonitors(self_ptr: ?*anyopaque) u32 {
        const s: *Fake = @ptrCast(@alignCast(self_ptr orelse return 0));
        return s.monitors.items.len;
    }
    pub fn ifaceGetMonitor(self_ptr: ?*anyopaque, idx: u32) ?*const GdkMonitor {
        const s: *Fake = @ptrCast(@alignCast(self_ptr orelse return null));
        if (idx >= s.monitors.items.len) return null;
        return &s.monitors.items[idx];
    }
    pub fn ifaceGetDefaultMonitor(self_ptr: ?*anyopaque) ?*const GdkMonitor {
        const s: *Fake = @ptrCast(@alignCast(self_ptr orelse return null));
        for (s.monitors.items) |*m| if (m.is_primary) return m;
        return if (s.monitors.items.len > 0) &s.monitors.items[0] else null;
    }
    pub fn ifaceGetName(self_ptr: ?*anyopaque) []const u8 {
        const s: *Fake = @ptrCast(@alignCast(self_ptr orelse return ""));
        return s.name;
    }
    pub fn ifaceIsClosed(self_ptr: ?*anyopaque) bool {
        const s: *Fake = @ptrCast(@alignCast(self_ptr orelse return true));
        return s.closed;
    }

    /// 把 FakeDisplay 自身打包成一个类型擦除的 GdkDisplay（可直接放到 DisplayManager）
    pub fn asGdkDisplay(self: *Fake) GdkDisplay {
        const iface = GdkDisplayIface{
            .get_n_monitors = ifaceGetNMonitors,
            .get_monitor = ifaceGetMonitor,
            .get_default_monitor = ifaceGetDefaultMonitor,
            .get_name = ifaceGetName,
            .is_closed = ifaceIsClosed,
        };
        return GdkDisplay.wrap(self, iface);
    }
};

// ═══════════════════════════════════════════════════════════════════════════════
//  GdkDisplayManager 单例
// ═══════════════════════════════════════════════════════════════════════════════

var _dm_instance: GdkDisplayManager = .{};

pub const GdkDisplayManager = struct {
    /// 已打开 Display 列表（内部持有，生存期 ≈ DisplayManager 自身）
    displays: std.ArrayListUnmanaged(GdkDisplay) = .{},
    /// 当前默认显示索引；null → 第一个（若存在）
    default_index: ?u32 = null,

    pub const Self = @This();

    /// 单例入口（thread-local 简化版）
    pub fn get() *Self {
        return &_dm_instance;
    }

    // ── 列表管理 ────────────────────────────────────────────────────────

    pub fn getNDisplays(self: *const Self) u32 {
        return self.displays.items.len;
    }

    pub fn getDisplay(self: *const Self, idx: u32) ?*const GdkDisplay {
        if (idx >= self.displays.items.len) return null;
        return &self.displays.items[idx];
    }

    pub fn getDefaultDisplay(self: *const Self) ?*const GdkDisplay {
        if (self.displays.items.len == 0) return null;
        const idx = self.default_index orelse 0;
        if (idx >= self.displays.items.len) return &self.displays.items[0];
        return &self.displays.items[idx];
    }

    pub fn setDefaultDisplay(self: *Self, idx: u32) !void {
        if (idx >= self.displays.items.len) return error.IndexOutOfRange;
        self.default_index = idx;
        self.displays.items[idx].makeDefault();
    }

    /// 注册一个 GdkDisplay（一般由 PAL/平台层在打开显示时调用）
    pub fn addDisplay(self: *Self, allocator: std.mem.Allocator, d: GdkDisplay) !u32 {
        const idx = self.displays.items.len;
        try self.displays.append(allocator, d);
        if (self.default_index == null) self.default_index = idx;
        return idx;
    }

    pub fn removeDisplay(self: *Self, allocator: std.mem.Allocator, idx: u32) void {
        if (idx >= self.displays.items.len) return;
        _ = self.displays.orderedRemove(idx, allocator);
        // 若删的是 default_index，回落到 0（如果还有）
        if (self.default_index) |di| {
            if (di == idx) self.default_index = if (self.displays.items.len > 0) 0 else null else if (di > idx) self.default_index = di - 1;
        }
    }

    // ── 便捷：根据名字查找 Display（= 打开的连接名） ──────────────────────

    pub fn openDisplay(self: *Self, allocator: std.mem.Allocator, name: []const u8) ?*const GdkDisplay {
        // 简化：若已有同名则返回已打开的；否则新建一个 FakeDisplay 占位
        for (self.displays.items, 0..) |*d, i| {
            if (std.mem.eql(u8, d.getName(), name)) return &self.displays.items[i];
        }
        // 懒创建：挂一个 FakeDisplay，name = name
        var fake_box = allocator.create(FakeDisplay) catch return null;
        fake_box.* = .{ .name = name };
        const gd = fake_box.asGdkDisplay();
        const idx = self.addDisplay(allocator, gd) catch {
            allocator.destroy(fake_box);
            return null;
        };
        return &self.displays.items[idx];
    }
};

// ═══════════════════════════════════════════════════════════════════════════════
//  GTK4 命名别名顶层函数（方便与 C API 对照）
// ═══════════════════════════════════════════════════════════════════════════════

pub fn gdk_display_manager_get() *GdkDisplayManager {
    return GdkDisplayManager.get();
}
pub fn gdk_display_manager_get_default_display(dm: *GdkDisplayManager) ?*const GdkDisplay {
    return dm.getDefaultDisplay();
}
