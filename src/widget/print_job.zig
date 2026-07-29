//! PrintJob — GTK4 GtkPrintJob 打印作业
//!
//! 一次打印任务：标题 + 打印机 + PrintSettings + PageSetup + 状态机。
//! send() 触发状态从 initial → pending → generating_data → sending_data → printing → finished，
//! 可通过 tick(delta_us) 异步推进进度。
//!

const std = @import("std");
const Allocator = std.mem.Allocator;
const printer_mod = @import("printer.zig");
const print_mod = @import("../model/print.zig");

pub const Printer = printer_mod.Printer;
pub const PrintSettings = print_mod.PrintSettings;
pub const PageSetup = print_mod.PageSetup;

/// GTK4 GtkPrintStatus
pub const PrintStatus = enum(u4) {
    initial,
    pending,
    generating_data,
    sending_data,
    pending_issue,
    printing,
    finished,
    finished_aborted,
    finished_with_error,
};

const StatusChangedFn = *const fn (ud: ?*anyopaque, status: PrintStatus) void;
const PrintErrorFn = *const fn (ud: ?*anyopaque, error_msg: []const u8) void;

pub const PrintJob = struct {
    allocator: Allocator,

    title: []const u8,
    printer: ?*Printer,
    settings: *PrintSettings,
    page_setup: *PageSetup,

    status: PrintStatus = .initial,
    status_message: ?[]const u8 = null,

    pages: std.ArrayListUnmanaged(i32) = .{},
    n_copies: i32 = 1,
    collate: bool = true,
    reverse: bool = false,
    rotate: bool = false,
    scale: f32 = 1.0,
    num_pages: i32 = 0,

    track_print_status: bool = true,

    surface: ?*anyopaque = null, // = 真实渲染表面句柄
    progress: f32 = 0, // 0.0 - 1.0
    start_us: i64 = 0,

    on_status_changed: ?StatusChangedFn = null,
    on_status_changed_ud: ?*anyopaque = null,
    on_error: ?PrintErrorFn = null,
    on_error_ud: ?*anyopaque = null,

    const Self = @This();

    pub fn create(allocator: Allocator, title: []const u8, printer: ?*Printer, settings: *PrintSettings, page_setup: *PageSetup) !*Self {
        const self = try allocator.create(Self);
        const title_c = try allocator.dupe(u8, title);
        self.* = .{
            .allocator = allocator,
            .title = title_c,
            .printer = printer,
            .settings = settings,
            .page_setup = page_setup,
            .status_message = try allocator.dupe(u8, "Ready"),
        };
        return self;
    }

    pub fn destroy(self: *Self) void {
        const a = self.allocator;
        a.free(self.title);
        if (self.status_message) |m| a.free(m);
        self.pages.deinit(a);
        a.destroy(self);
    }

    pub fn getTitle(self: *const Self) []const u8 {
        return self.title;
    }
    pub fn getPrinter(self: *const Self) ?*Printer {
        return self.printer;
    }
    pub fn getSettings(self: *const Self) *PrintSettings {
        return self.settings;
    }
    pub fn getPageSetup(self: *const Self) *PageSetup {
        return self.page_setup;
    }
    pub fn getStatus(self: *const Self) PrintStatus {
        return self.status;
    }
    pub fn getProgress(self: *const Self) f32 {
        return self.progress;
    }

    pub fn setSurface(self: *Self, ptr: ?*anyopaque) void {
        self.surface = ptr;
    }
    pub fn getSurface(self: *const Self) ?*anyopaque {
        return self.surface;
    }

    pub fn setPages(self: *Self, indices: []const i32) void {
        self.pages.resize(self.allocator, indices.len) catch @panic("oom");
        for (indices, 0..) |i, idx| self.pages.items[idx] = i;
    }

    pub fn setCopies(self: *Self, n: i32) void {
        self.n_copies = n;
    }
    pub fn setCollate(self: *Self, v: bool) void {
        self.collate = v;
    }
    pub fn setReverse(self: *Self, v: bool) void {
        self.reverse = v;
    }
    pub fn setRotate(self: *Self, v: bool) void {
        self.rotate = v;
    }
    pub fn setScale(self: *Self, s: f32) void {
        self.scale = s;
    }

    pub fn setOnStatusChanged(self: *Self, cb: ?StatusChangedFn, ud: ?*anyopaque) void {
        self.on_status_changed = cb;
        self.on_status_changed_ud = ud;
    }
    pub fn setOnError(self: *Self, cb: ?PrintErrorFn, ud: ?*anyopaque) void {
        self.on_error = cb;
        self.on_error_ud = ud;
    }

    fn switchStatus(self: *Self, s: PrintStatus) void {
        if (self.status == s) return;
        self.status = s;
        if (self.on_status_changed) |cb| cb(self.on_status_changed_ud, s);
    }

    fn setMsg(self: *Self, m: []const u8) void {
        const a = self.allocator;
        if (self.status_message) |old| a.free(old);
        const c = a.dupe(u8, m) catch return;
        self.status_message = c;
    }

    /// 开始发送（同步启动状态机；真实作业应异步 tick 推进）
    pub fn send(self: *Self) bool {
        if (self.printer == null) {
            self.setError("No printer selected");
            return false;
        }
        self.progress = 0;
        self.start_us = 0;
        self.switchStatus(.pending);
        self.setMsg("Pending");
        return true;
    }

    /// 每帧推进状态；打印耗时占位：假设总共 3s 走完四个阶段
    pub fn tick(self: *Self, delta_us: i64) void {
        if (self.status == .finished or self.status == .finished_aborted or self.status == .finished_with_error) return;
        if (self.status == .initial) return;
        self.start_us += delta_us;
        const total_us_est: i64 = 3_000_000;
        const ratio: f32 = @as(f32, @floatFromInt(@min(self.start_us, total_us_est))) / @as(f32, @floatFromInt(total_us_est));
        self.progress = ratio;
        if (ratio < 0.20) self.switchStatus(.generating_data) else if (ratio < 0.45) self.switchStatus(.sending_data) else if (ratio < 1.00) self.switchStatus(.printing) else {
            self.switchStatus(.finished);
            self.progress = 1.0;
            self.setMsg("Done");
        }
    }

    pub fn cancel(self: *Self) void {
        switch (self.status) {
            .finished, .finished_aborted, .finished_with_error => {},
            else => {
                self.switchStatus(.finished_aborted);
                self.setMsg("Cancelled");
            },
        }
    }

    pub fn setError(self: *Self, error_msg: []const u8) void {
        self.switchStatus(.finished_with_error);
        self.setMsg(error_msg);
        if (self.on_error) |cb| cb(self.on_error_ud, error_msg);
    }
};
