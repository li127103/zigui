//! FileDialog 控件 - GTK4 文件选择对话框
//!
//! GTK4 新版简化 API (替代 GtkFileChooserDialog)，对应 GtkFileDialog。
//!
//! 与 GTK4 一致，FileDialog 不是一个嵌入窗口的控件 (Widget)，而是一个独立的
//! 对话框对象：调用 openFile / saveFile / selectFolder 会以**原生文件对话框
//! 形式打开一个新窗口**（优先系统原生 kdialog/zenity，失败回退内部实现），
//! 用户选择/取消后通过回调返回结果。这正是"文件选择框一般打开新的窗口"的语义。

const std = @import("std");
const model_filter = @import("../model/file_filter.zig");
const FileChooserNative = @import("file_chooser_native.zig").FileChooserNative;
const FileChooserAction = @import("file_chooser_native.zig").FileChooserAction;

const Allocator = std.mem.Allocator;

pub const FileDialogMode = enum { open, save, select_folder };

/// 过滤器 (简化版: 名称 + glob 模式列表)
pub const FileFilter = struct {
    name: []const u8 = "",
    patterns: []const []const u8 = &.{},
};

pub const FileDialogResult = union(enum) {
    open: []const u8,
    save: []const u8,
    folder: []const u8,
    multi_open: [][]const u8,
    cancel: void,
};

pub const FileDialog = struct {
    allocator: Allocator,
    title: []const u8,
    title_dup: []const u8 = &.{},
    modal: bool = true,
    accept_label: []const u8 = "Open",
    cancel_label: []const u8 = "Cancel",
    mode: FileDialogMode = .open,

    initial_folder: []const u8 = "",
    initial_folder_dup: []const u8 = &.{},
    initial_name: []const u8 = "",
    initial_name_dup: []const u8 = &.{},

    select_multiple: bool = false,
    filters: []const FileFilter = &.{},

    on_response: ?*const fn (self: *FileDialog, result: FileDialogResult) void = null,

    /// 上一次结果中由本对象分配并拥有的路径；destroy / 下次打开时释放
    last_result: FileDialogResult = .cancel,

    const Self = @This();

    pub fn new(allocator: Allocator, title: []const u8) !*FileDialog {
        const self = try allocator.create(FileDialog);
        const title_dup = try allocator.dupe(u8, title);
        self.* = .{
            .allocator = allocator,
            .title = title_dup,
            .title_dup = title_dup,
        };
        return self;
    }

    pub fn destroy(self: *Self, allocator: Allocator) void {
        self.freeResult(self.last_result);
        if (self.title_dup.len > 0) allocator.free(self.title_dup);
        if (self.initial_folder_dup.len > 0) allocator.free(self.initial_folder_dup);
        if (self.initial_name_dup.len > 0) allocator.free(self.initial_name_dup);
        allocator.destroy(self);
    }

    pub fn setTitle(self: *Self, title: []const u8) void {
        if (self.title_dup.len > 0) self.allocator.free(self.title_dup);
        self.title_dup = self.allocator.dupe(u8, title) catch return;
        self.title = self.title_dup;
    }

    pub fn setMode(self: *Self, mode: FileDialogMode) void {
        self.mode = mode;
    }

    pub fn setInitialFolder(self: *Self, folder: []const u8) void {
        if (self.initial_folder_dup.len > 0) self.allocator.free(self.initial_folder_dup);
        self.initial_folder_dup = self.allocator.dupe(u8, folder) catch return;
        self.initial_folder = self.initial_folder_dup;
    }

    pub fn setInitialName(self: *Self, name: []const u8) void {
        if (self.initial_name_dup.len > 0) self.allocator.free(self.initial_name_dup);
        self.initial_name_dup = self.allocator.dupe(u8, name) catch return;
        self.initial_name = self.initial_name_dup;
    }

    pub fn setFilters(self: *Self, filters: []const FileFilter) void {
        self.filters = filters;
    }

    pub fn setSelectMultiple(self: *Self, v: bool) void {
        self.select_multiple = v;
    }

    // ── 打开对话框（同步：原生窗口关闭后返回） ─────────────────────────────

    pub fn openFile(self: *Self, callback: ?*const fn (ud: ?*anyopaque, result: FileDialogResult) void, userdata: ?*anyopaque) void {
        self.run(.open, callback, userdata);
    }

    pub fn saveFile(self: *Self, callback: ?*const fn (ud: ?*anyopaque, result: FileDialogResult) void, userdata: ?*anyopaque) void {
        self.run(.save, callback, userdata);
    }

    pub fn selectFolder(self: *Self, callback: ?*const fn (ud: ?*anyopaque, result: FileDialogResult) void, userdata: ?*anyopaque) void {
        self.run(.select_folder, callback, userdata);
    }

    fn run(self: *Self, mode: FileDialogMode, callback: ?*const fn (ud: ?*anyopaque, result: FileDialogResult) void, userdata: ?*anyopaque) void {
        const action: FileChooserAction = switch (mode) {
            .open => .open,
            .save => .save,
            .select_folder => .select_folder,
        };
        const native = FileChooserNative.create(self.allocator, .{
            .action = action,
            .title = self.title,
            .accept_label = self.accept_label,
            .cancel_label = self.cancel_label,
            .current_name = self.initial_name,
            .current_folder = self.initial_folder,
            .select_multiple = self.select_multiple,
        }) catch {
            self.fireResult(.cancel, callback, userdata);
            return;
        };

        // 将简化版 FileFilter 转换为 model.FileFilter 交给原生对话框
        for (self.filters) |f| {
            var mf = model_filter.FileFilter.init(self.allocator, if (f.name.len > 0) f.name else null);
            for (f.patterns) |p| mf.addPattern(p) catch {};
            // addFilter 已按值拷入 native.filters，堆上 patterns 归 native 所有；
            // 切勿调用 mf.deinit()（会释放共享缓冲）。mf 局部作用域结束即可。
            native.addFilter(mf) catch {};
        }

        // 打开原生窗口（同步：用户关闭后返回）
        native.show(null);

        // 转换结果：有选中文件 => accept；否则 => cancel
        const result: FileDialogResult = blk: {
            if (native.getFileCount() == 0) break :blk .cancel;
            if (self.select_multiple and mode == .open) {
                var list: std.ArrayList([]const u8) = .{ .items = &.{}, .capacity = 0 };
                for (native.getFiles()) |p| {
                    list.append(self.allocator, self.allocator.dupe(u8, p) catch continue) catch {};
                }
                break :blk .{ .multi_open = list.toOwnedSlice(self.allocator) catch &.{} };
            } else {
                const p = native.getFile() orelse break :blk .cancel;
                const dup = self.allocator.dupe(u8, p) catch break :blk .cancel;
                break :blk switch (mode) {
                    .open => .{ .open = dup },
                    .save => .{ .save = dup },
                    .select_folder => .{ .folder = dup },
                };
            }
        };

        native.destroy();
        self.fireResult(result, callback, userdata);
    }

    fn fireResult(self: *Self, result: FileDialogResult, callback: ?*const fn (ud: ?*anyopaque, result: FileDialogResult) void, userdata: ?*anyopaque) void {
        // 释放上一次结果拥有的路径，接管本次结果所有权
        self.freeResult(self.last_result);
        self.last_result = result;
        if (callback) |cb| cb(userdata, result);
        if (self.on_response) |cb| cb(self, result);
    }

    fn freeResult(self: *Self, r: FileDialogResult) void {
        switch (r) {
            .open => |p| self.allocator.free(p),
            .save => |p| self.allocator.free(p),
            .folder => |p| self.allocator.free(p),
            .multi_open => |ps| {
                for (ps) |p| self.allocator.free(p);
                self.allocator.free(ps);
            },
            .cancel => {},
        }
    }
};
