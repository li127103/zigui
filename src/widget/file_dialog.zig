//! FileDialog 控件 - GTK4 文件选择对话框
//!
//! GTK4 新版简化 API (替代 GtkFileChooserDialog)。
//! 与 FileChooserButton 配合使用。
//!
//! GTK4 对应: GtkFileDialog

const std = @import("std");
const math = @import("../math.zig");
const widget_mod = @import("widget.zig");
const layout_mod = @import("../layout/engine.zig");
const pal = @import("../pal/pal.zig");

const Widget = widget_mod.Widget;
const PaintContext = widget_mod.PaintContext;
const Allocator = std.mem.Allocator;

pub const FileDialogMode = enum { open, save, select_folder };

pub const FileFilter = struct {
    name: []const u8 = "",
    patterns: []const []const u8 = &.{},
};

pub const FileDialogResult = union(enum) {
    open: []const u8,      // 选中的文件路径
    save: []const u8,      // 保存的目标路径
    folder: []const u8,    // 选中的文件夹路径
    multi_open: [][]const u8, // 多选文件 (暂保留)
    cancel: void,
};

pub const FileDialog = struct {
    base: Widget,
    allocator: Allocator,
    title: []const u8 = "Open File",
    title_dup: []const u8 = &.{},
    modal: bool = true,
    accept_label: []const u8 = "Open",
    cancel_label: []const u8 = "Cancel",
    mode: FileDialogMode = .open,

    initial_folder: []const u8 = "",
    initial_folder_dup: []const u8 = &.{},
    initial_name: []const u8 = "",
    initial_name_dup: []const u8 = &.{},

    filters: []const FileFilter = &.{},
    on_response: ?*const fn (self: *FileDialog, result: FileDialogResult) void = null,

    pub fn new(allocator: Allocator, title: []const u8) !*FileDialog {
        const self = try allocator.create(FileDialog);
        const title_dup = try allocator.dupe(u8, title);
        self.* = .{
            .base = .{
                .vtable = &vtable,
                .id = widget_mod.genWidgetId(),
            },
            .allocator = allocator,
            .title = title_dup,
            .title_dup = title_dup,
        };
        self.base.accessibility = .{ .role = .dialog, .label = self.title };
        return self;
    }

    pub fn destroy(self: *FileDialog, allocator: Allocator) void {
        if (self.title_dup.len > 0) allocator.free(self.title_dup);
        if (self.initial_folder_dup.len > 0) allocator.free(self.initial_folder_dup);
        if (self.initial_name_dup.len > 0) allocator.free(self.initial_name_dup);
        self.base.background.deinit(allocator);
        self.base.children.deinit(allocator);
        allocator.destroy(self);
    }

    pub fn setTitle(self: *FileDialog, title: []const u8) void {
        if (self.title_dup.len > 0) self.allocator.free(self.title_dup);
        self.title_dup = self.allocator.dupe(u8, title) catch return;
        self.title = self.title_dup;
        self.base.accessibility.label = self.title;
    }

    pub fn setMode(self: *FileDialog, mode: FileDialogMode) void {
        self.mode = mode;
    }

    pub fn setInitialFolder(self: *FileDialog, folder: []const u8) void {
        if (self.initial_folder_dup.len > 0) self.allocator.free(self.initial_folder_dup);
        self.initial_folder_dup = self.allocator.dupe(u8, folder) catch return;
        self.initial_folder = self.initial_folder_dup;
    }

    pub fn setInitialName(self: *FileDialog, name: []const u8) void {
        if (self.initial_name_dup.len > 0) self.allocator.free(self.initial_name_dup);
        self.initial_name_dup = self.allocator.dupe(u8, name) catch return;
        self.initial_name = self.initial_name_dup;
    }

    pub fn setFilters(self: *FileDialog, filters: []const FileFilter) void {
        self.filters = filters;
    }

    pub fn openFile(self: *FileDialog, callback: ?*const fn (ud: ?*anyopaque, result: FileDialogResult) void, userdata: ?*anyopaque) void {
        const folder = if (self.initial_folder.len > 0) self.initial_folder else "/home";
        const result: FileDialogResult = .{ .open = folder };
        if (callback) |cb| cb(userdata, result);
        if (self.on_response) |cb| cb(self, result);
    }

    pub fn saveFile(self: *FileDialog, callback: ?*const fn (ud: ?*anyopaque, result: FileDialogResult) void, userdata: ?*anyopaque) void {
        const name = if (self.initial_name.len > 0) self.initial_name else "Untitled";
        const result: FileDialogResult = .{ .save = name };
        if (callback) |cb| cb(userdata, result);
        if (self.on_response) |cb| cb(self, result);
    }

    pub fn selectFolder(self: *FileDialog, callback: ?*const fn (ud: ?*anyopaque, result: FileDialogResult) void, userdata: ?*anyopaque) void {
        const folder = if (self.initial_folder.len > 0) self.initial_folder else "/home";
        const result: FileDialogResult = .{ .folder = folder };
        if (callback) |cb| cb(userdata, result);
        if (self.on_response) |cb| cb(self, result);
    }
};

const vtable = Widget.VTable{
    .type_name = "file_dialog",
    .measure = measure,
    .paint = paint,
    .on_event = null,
    .focusable = false,
    .destroy = destroyVTable,
};

fn destroyVTable(w: *Widget, allocator: Allocator) void {
    const self: *FileDialog = @fieldParentPtr("base", w);
    self.destroy(allocator);
}

fn measure(w: *Widget, ctx: *PaintContext, constraints: layout_mod.Constraints) math.Size(f32) {
    _ = w;
    _ = ctx;
    _ = constraints;
    return .{ .width = 720, .height = 520 };
}

fn paint(w: *Widget, ctx: *PaintContext) void {
    _ = w;
    _ = ctx;
}
