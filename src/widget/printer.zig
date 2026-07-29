//! Printer — GTK4 GtkPrinter 打印机对象
//!
//! 表示一个系统级打印机或虚拟打印机（如 "Save as PDF"）。
//! 供 GtkPrintUnixDialog（print_unix_dialog.zig）展示列表并供 PrintJob 调用。
//! PaperSize/PrintSettings/PageSetup 等数据类型复用 model/print.zig。
//!

const std = @import("std");
const Allocator = std.mem.Allocator;
const print_mod = @import("../model/print.zig");

pub const PaperSize = print_mod.PaperSize;

const StatusChangedFn = *const fn (ud: ?*anyopaque, state_message: []const u8) void;

pub const Printer = struct {
    allocator: Allocator,

    name: []const u8,
    backend: []const u8, // "cups" / "file" / "lpr" / "win32" / "macos-print"
    icon_name: []const u8,

    is_virtual: bool = false,   // file: 导出为 PDF
    is_default: bool = false,   // 默认打印机
    is_active: bool = true,     // 可连通
    is_paused: bool = false,    // 队列暂停

    accepts_pdf: bool = true,
    accepts_ps: bool = true,

    supports_custom_paper_sizes: bool = false,
    hard_margins_top: f32 = 6.35,     // mm
    hard_margins_right: f32 = 6.35,
    hard_margins_bottom: f32 = 6.35,
    hard_margins_left: f32 = 6.35,

    state_message: ?[]const u8 = null,
    location: []const u8,

    paper_sizes: std.ArrayListUnmanaged(PaperSize) = .{},
    media_gap: f32 = 0,

    on_status_changed: ?StatusChangedFn = null,
    on_status_changed_ud: ?*anyopaque = null,

    // 全局枚举单例列表（PAL 可注入）
    var g_printers: std.ArrayListUnmanaged(*Printer) = .{};
    var g_default_printer: ?*Printer = null;

    const Self = @This();

    pub fn create(allocator: Allocator, name: []const u8, backend: []const u8, location: []const u8) !*Self {
        const self = try allocator.create(Self);
        const name_c = try allocator.dupe(u8, name);
        const backend_c = try allocator.dupe(u8, backend);
        const loc_c = try allocator.dupe(u8, location);
        self.* = .{
            .allocator = allocator,
            .name = name_c,
            .backend = backend_c,
            .icon_name = "printer",
            .location = loc_c,
            .state_message = try allocator.dupe(u8, "idle"),
        };
        return self;
    }

    pub fn destroy(self: *Self) void {
        const a = self.allocator;
        a.free(self.name);
        a.free(self.backend);
        a.free(self.location);
        if (self.state_message) |m| a.free(m);
        self.paper_sizes.deinit(a);
        a.destroy(self);
    }

    pub fn getName(self: *const Self) []const u8 { return self.name; }
    pub fn getBackend(self: *const Self) []const u8 { return self.backend; }
    pub fn isDefault(self: *const Self) bool { return self.is_default; }
    pub fn isActive(self: *const Self) bool { return self.is_active; }
    pub fn isPaused(self: *const Self) bool { return self.is_paused; }
    pub fn isVirtual(self: *const Self) bool { return self.is_virtual; }

    pub fn listPapers(self: *const Self) []const PaperSize { return self.paper_sizes.items; }

    pub fn addPaperSize(self: *Self, sz: PaperSize) void {
        self.paper_sizes.append(self.allocator, sz) catch @panic("oom");
    }

    pub fn supportsPaper(self: *const Self, sz: PaperSize) bool {
        for (self.paper_sizes.items) |p| {
            if (std.mem.eql(u8, p.name, sz.name)) return true;
        }
        return false;
    }

    pub fn getHardMarginsMm(self: *const Self) struct { top: f32, right: f32, bottom: f32, left: f32 } {
        return .{ .top = self.hard_margins_top, .right = self.hard_margins_right, .bottom = self.hard_margins_bottom, .left = self.hard_margins_left };
    }

    pub fn isSame(self: *const Self, other: *const Self) bool {
        return std.mem.eql(u8, self.name, other.name) and std.mem.eql(u8, self.backend, other.backend);
    }

    pub fn setStateMessage(self: *Self, msg: []const u8) void {
        const a = self.allocator;
        if (self.state_message) |m| a.free(m);
        const c = a.dupe(u8, msg) catch return;
        self.state_message = c;
        if (self.on_status_changed) |cb| cb(self.on_status_changed_ud, c);
    }

    pub fn setOnStatusChanged(self: *Self, cb: ?StatusChangedFn, ud: ?*anyopaque) void {
        self.on_status_changed = cb;
        self.on_status_changed_ud = ud;
    }

    pub fn setDefault(self: *Self, def: bool) void {
        self.is_default = def;
        if (def) g_default_printer = self;
    }

    // ── 全局列表 ──────────────────────────────────────────────────────────

    /// 枚举所有可用打印机。真实实现应由 PAL 注入 CUPS/Win32/MacOS 返回。
    pub fn enumerateAll(allocator: Allocator) !std.ArrayList(*Self) {
        _ = allocator;
        var list = try std.ArrayList(*Self).initCapacity(g_printers.allocator, g_printers.items.len);
        for (g_printers.items) |p| try list.append(p);
        return list;
    }

    pub fn getDefault() ?*Self { return g_default_printer; }

    pub fn registerPrinter(printer: *Self) void {
        g_printers.append(g_printers.allocator, printer) catch @panic("oom");
    }
};
