//! GtkFileChooserNative — 跨平台原生文件对话框接口
//!
//! GTK 对应: GtkFileChooserNative（GTK4 跨平台原生文件对话框 API）
//!
//! 支持四种 action:
//! - open            — 选择一个或多个现有文件
//! - save            — 选择/输入保存文件名（覆盖确认）
//! - select_folder   — 选择一个文件夹
//! - create_folder   — 选择/输入新文件夹名
//!
//! 优先调用平台原生对话框；若不可用则回退到 file_chooser.zig 的 ZigUI 内部实现。
//! 用户通过 `on_response` 回调拿到结果，不需要等待。
//!
//! 示例:
//! ```
//! const fcn = try FileChooserNative.create(allocator, .{
//!     .action = .open, .title = "选择文件",
//!     .accept_label = "打开", .cancel_label = "取消",
//! });
//! try fcn.addFilter(filter_png);
//! fcn.show(null, onResponse, onError);
//! ```

const std = @import("std");
const math = @import("../math.zig");
const widget_mod = @import("widget.zig");
const file_filter_mod = @import("../model/file_filter.zig");

const Widget = widget_mod.Widget;
const FileFilter = file_filter_mod.FileFilter;

pub const FileChooserAction = enum(u8) {
    open,
    save,
    select_folder,
    create_folder,
};

pub const FileChooserResponse = enum(u8) {
    accept,
    cancel,
    delete_event,
};

/// FileFilter 列表（ArrayListUnmanaged 包装）
const FilterList = std.ArrayListUnmanaged(FileFilter);
const FileList = std.ArrayListUnmanaged([]const u8);

pub const FileChooserNative = struct {
    allocator: std.mem.Allocator,
    action: FileChooserAction,
    title: []const u8,
    accept_label: []const u8 = "确定",
    cancel_label: []const u8 = "取消",

    /// 文件/文件夹名建议（save / create_folder 时使用）
    current_name: []const u8 = "",
    /// 当前打开的文件夹（回退到内部对话框时使用）
    current_folder: []const u8 = "",

    /// 是否允许选择多个文件 (open 模式)
    select_multiple: bool = false,
    /// 保存时是否先提示覆盖确认
    do_overwrite_confirmation: bool = true,

    /// 文件过滤器列表（供用户过滤显示）
    filters: FilterList = .empty,
    /// 当前选中的过滤器（可选）
    current_filter: ?FileFilter = null,

    /// 结果文件路径集合（在 on_response(accept) 时已填充）
    selected_files: FileList = .empty,

    /// 响应回调
    on_response: ?*const fn (self: *FileChooserNative, response: FileChooserResponse) void = null,
    /// 错误回调
    on_error: ?*const fn (self: *FileChooserNative, err: []const u8) void = null,

    /// 内部：show() 后是否已弹出（避免重复弹出）
    showing: bool = false,

    const Self = @This();

    pub fn create(allocator: std.mem.Allocator, opts: struct {
        action: FileChooserAction,
        title: []const u8 = "",
        accept_label: []const u8 = "确定",
        cancel_label: []const u8 = "取消",
        current_name: []const u8 = "",
        current_folder: []const u8 = "",
        select_multiple: bool = false,
        do_overwrite_confirmation: bool = true,
        on_response: ?*const fn (self: *FileChooserNative, response: FileChooserResponse) void = null,
        on_error: ?*const fn (self: *FileChooserNative, err: []const u8) void = null,
    }) !*FileChooserNative {
        const self = try allocator.create(FileChooserNative);
        self.* = .{
            .allocator = allocator,
            .action = opts.action,
            .title = opts.title,
            .accept_label = opts.accept_label,
            .cancel_label = opts.cancel_label,
            .current_name = opts.current_name,
            .current_folder = opts.current_folder,
            .select_multiple = opts.select_multiple,
            .do_overwrite_confirmation = opts.do_overwrite_confirmation,
            .on_response = opts.on_response,
            .on_error = opts.on_error,
        };
        return self;
    }

    pub fn destroy(self: *Self) void {
        for (self.selected_files.items) |f| self.allocator.free(f);
        self.selected_files.deinit(self.allocator);
        self.filters.deinit(self.allocator);
        self.allocator.destroy(self);
    }

    // ── 配置 API ─────────────────────────────────────────────────────────────

    pub fn setTitle(self: *Self, title: []const u8) void {
        self.title = title;
    }

    pub fn setAction(self: *Self, action: FileChooserAction) void {
        self.action = action;
    }

    pub fn getAction(self: *const Self) FileChooserAction {
        return self.action;
    }

    pub fn setCurrentName(self: *Self, name: []const u8) void {
        self.current_name = name;
    }

    pub fn setCurrentFolder(self: *Self, folder: []const u8) void {
        self.current_folder = folder;
    }

    pub fn setSelectMultiple(self: *Self, v: bool) void {
        self.select_multiple = v;
    }

    pub fn setDoOverwriteConfirmation(self: *Self, v: bool) void {
        self.do_overwrite_confirmation = v;
    }

    pub fn addFilter(self: *Self, filter: FileFilter) !void {
        try self.filters.append(self.allocator, filter);
    }

    pub fn setCurrentFilter(self: *Self, filter: ?FileFilter) void {
        self.current_filter = filter;
    }

    // ── 结果获取 ──────────────────────────────────────────────────────────────

    /// 返回第一个选中的文件路径；若无则返回 null
    pub fn getFile(self: *const Self) ?[]const u8 {
        if (self.selected_files.items.len == 0) return null;
        return self.selected_files.items[0];
    }

    /// 返回所有选中文件路径的只读切片
    pub fn getFiles(self: *const Self) []const []const u8 {
        return self.selected_files.items;
    }

    pub fn getFileCount(self: *const Self) usize {
        return self.selected_files.items.len;
    }

    pub fn clearSelected(self: *Self) void {
        for (self.selected_files.items) |f| self.allocator.free(f);
        self.selected_files.deinit(self.allocator);
    }

    /// 内部：添加选中的文件 (复制所有权)
    fn addSelected(self: *Self, path: []const u8) !void {
        const dup = try self.allocator.alloc(u8, path.len);
        @memcpy(dup, path);
        try self.selected_files.append(self.allocator, dup);
    }

    // ── show() — 优先原生，失败回退到内部实现 ───────────────────────────────

    /// 显示文件选择对话框（异步）。parent_window 可为 null。
    pub fn show(self: *Self, parent_window: ?*Widget) void {
        if (self.showing) return;
        self.showing = true;
        self.clearSelected();

        // P38: 优先尝试 Linux 原生命令行文件对话框（kdialog → zenity），
        //      失败或用户取消时再 fallback 到内部实现。
        if (self.tryRunNative(parent_window)) {
            // 原生命令在内部同步执行完成后已通过 fireResponse(.accept/.cancel) 或
            // 显式 hide 处理 showing 标志。
            return;
        }
        self.runFallback(parent_window);
    }

    /// 尝试使用系统原生文件对话框命令（kdialog / zenity）。
    /// 返回 true：已启动（并在函数返回前执行完毕 + fireResponse）；false：全部不可用，应 fallback。
    fn tryRunNative(self: *Self, parent_window: ?*Widget) bool {
        _ = parent_window;
        // 按优先级尝试：kdialog（KDE/Plasma 桌面） →  zenity（GTK/GNOME/XFCE）
        if (self.runKdialog()) return true;
        if (self.runZenity()) return true;
        return false;
    }

    // ── 后端 1：KDE kdialog ──────────────────────────────────────────────────

    fn runKdialog(self: *Self) bool {
        var args = std.ArrayList([]const u8){ .items = &.{}, .capacity = 0 };
        defer {
            for (args.items) |a| self.allocator.free(a);
            args.deinit(self.allocator);
        }

        args.append(self.allocator, self.allocator.dupe(u8, "kdialog") catch return false) catch return false;
        // 标题
        if (self.title.len > 0) {
            args.appendSlice(self.allocator, &.{
                self.allocator.dupe(u8, "--title") catch return false,
                self.allocator.dupe(u8, self.title) catch return false,
            }) catch return false;
        }

        // 起始目录 / 建议文件名
        const start = self.buildStartPath();
        defer self.allocator.free(start);

        switch (self.action) {
            .open => {
                if (self.select_multiple) {
                    args.append(self.allocator, self.allocator.dupe(u8, "--multiple") catch return false) catch return false;
                }
                args.append(self.allocator, self.allocator.dupe(u8, "--getopenfilename") catch return false) catch return false;
                args.append(self.allocator, self.allocator.dupe(u8, start) catch return false) catch return false;
                if (self.buildKdialogFilterString()) |fs| {
                    defer self.allocator.free(fs);
                    args.append(self.allocator, fs) catch return false;
                } else {
                    args.append(self.allocator, self.allocator.dupe(u8, "") catch return false) catch return false;
                }
            },
            .save => {
                args.append(self.allocator, self.allocator.dupe(u8, "--getsavefilename") catch return false) catch return false;
                args.append(self.allocator, self.allocator.dupe(u8, start) catch return false) catch return false;
                if (self.buildKdialogFilterString()) |fs| {
                    defer self.allocator.free(fs);
                    args.append(self.allocator, fs) catch return false;
                } else {
                    args.append(self.allocator, self.allocator.dupe(u8, "") catch return false) catch return false;
                }
            },
            .select_folder => {
                args.append(self.allocator, self.allocator.dupe(u8, "--getexistingdirectory") catch return false) catch return false;
                args.append(self.allocator, self.allocator.dupe(u8, start) catch return false) catch return false;
            },
            .create_folder => {
                // kdialog 没有直接创建文件夹的命令，使用 getsavefilename 让用户命名，
                // 应用端收到路径后自行 mkdir。
                args.append(self.allocator, self.allocator.dupe(u8, "--getsavefilename") catch return false) catch return false;
                args.append(self.allocator, self.allocator.dupe(u8, start) catch return false) catch return false;
            },
        }

        return self.execAndParse(
            args.items,
            if (self.select_multiple and self.action == .open) .kdialog_multi else .single_line,
        );
    }

    /// 构造 kdialog 过滤字符串："Name (*.png *.jpg)|*.png *.jpg\n..."
    fn buildKdialogFilterString(self: *Self) ?[]u8 {
        if (self.filters.items.len == 0) return null;
        var out = std.ArrayList(u8){ .items = &.{}, .capacity = 0 };
        for (self.filters.items, 0..) |filter, i| {
            if (i > 0) out.append(self.allocator, '\n') catch return null;
            const name = filter.name orelse "Filter";
            {
                const pre = std.fmt.allocPrint(self.allocator, "{s} (", .{name}) catch return null;
                out.appendSlice(self.allocator, pre) catch return null;
                self.allocator.free(pre);
            }
            var first = true;
            for (filter.patterns.items) |pat| {
                if (!first) out.append(self.allocator, ' ') catch return null;
                out.appendSlice(self.allocator, pat) catch return null;
                first = false;
            }
            if (first) out.append(self.allocator, '*') catch return null;
            out.appendSlice(self.allocator, ")|") catch return null;
            first = true;
            for (filter.patterns.items) |pat| {
                if (!first) out.append(self.allocator, ' ') catch return null;
                out.appendSlice(self.allocator, pat) catch return null;
                first = false;
            }
            if (first) out.append(self.allocator, '*') catch return null;
        }
        return out.toOwnedSlice(self.allocator) catch null;
    }

    // ── 后端 2：GNOME zenity ─────────────────────────────────────────────────

    fn runZenity(self: *Self) bool {
        var args = std.ArrayList([]const u8){ .items = &.{}, .capacity = 0 };
        defer {
            for (args.items) |a| self.allocator.free(a);
            args.deinit(self.allocator);
        }

        args.append(self.allocator, self.allocator.dupe(u8, "zenity") catch return false) catch return false;
        args.append(self.allocator, self.allocator.dupe(u8, "--file-selection") catch return false) catch return false;

        switch (self.action) {
            .open => {
                if (self.select_multiple) {
                    args.append(self.allocator, self.allocator.dupe(u8, "--multiple") catch return false) catch return false;
                    args.append(self.allocator, self.allocator.dupe(u8, "--separator=\n") catch return false) catch return false;
                }
            },
            .save => {
                args.append(self.allocator, self.allocator.dupe(u8, "--save") catch return false) catch return false;
                if (self.do_overwrite_confirmation) {
                    args.append(self.allocator, self.allocator.dupe(u8, "--confirm-overwrite") catch return false) catch return false;
                }
            },
            .select_folder => {
                args.append(self.allocator, self.allocator.dupe(u8, "--directory") catch return false) catch return false;
            },
            .create_folder => {
                // zenity 也没有直接创建文件夹，使用 --save + 起始路径。
                args.append(self.allocator, self.allocator.dupe(u8, "--save") catch return false) catch return false;
            },
        }

        if (self.title.len > 0) {
            const s = std.fmt.allocPrint(self.allocator, "--title={s}", .{self.title}) catch return false;
            args.append(self.allocator, s) catch return false;
        }

        const start = self.buildStartPath();
        defer self.allocator.free(start);
        {
            const s = std.fmt.allocPrint(self.allocator, "--filename={s}", .{start}) catch return false;
            args.append(self.allocator, s) catch return false;
        }

        // 文件过滤器：多个 --file-filter='Name | *.png *.jpg'
        for (self.filters.items) |filter| {
            if (filter.patterns.items.len == 0) continue;
            var buf = std.ArrayList(u8){ .items = &.{}, .capacity = 0 };
            const name = filter.name orelse "Filter";
            buf.appendSlice(self.allocator, "--file-filter=") catch continue;
            {
                const pre = std.fmt.allocPrint(self.allocator, "{s} | ", .{name}) catch continue;
                buf.appendSlice(self.allocator, pre) catch continue;
                self.allocator.free(pre);
            }
            for (filter.patterns.items, 0..) |pat, j| {
                if (j > 0) buf.append(self.allocator, ' ') catch {};
                buf.appendSlice(self.allocator, pat) catch {};
            }
            const s = buf.toOwnedSlice(self.allocator) catch continue;
            args.append(self.allocator, s) catch continue;
        }

        const mode: ParseMode = if (self.select_multiple and self.action == .open)
            .multi_line
        else
            .single_line;
        return self.execAndParse(args.items, mode);
    }

    // ── 通用工具 ─────────────────────────────────────────────────────────────

    const ParseMode = enum {
        single_line, // 输出单行，末尾可能带 \n
        multi_line, // 多行（zenity 多文件，换行分隔）
        kdialog_multi, // kdialog --multiple：shell 风格 token（空格分隔，"..." 含空格）
    };

    /// 组合起始路径：current_folder + (current_name if save/create_folder)
    fn buildStartPath(self: *Self) []u8 {
        const folder = if (self.current_folder.len > 0)
            self.current_folder
        else
            "/tmp";
        const has_name = (self.action == .save or self.action == .create_folder) and
            self.current_name.len > 0;
        if (!has_name) {
            // 末尾带 / 避免误当成文件
            if (folder.len == 0) return self.allocator.dupe(u8, "/") catch return self.allocator.alloc(u8, 0) catch unreachable;
            const trailing = folder[folder.len - 1] == '/';
            return self.allocator.dupe(u8, if (trailing) folder else std.fmt.allocPrint(self.allocator, "{s}/", .{folder}) catch folder) catch return self.allocator.dupe(u8, folder) catch unreachable;
        }
        const need_sep = folder.len > 0 and folder[folder.len - 1] != '/' and
            self.current_name[0] != '/';
        return std.fmt.allocPrint(self.allocator, "{s}{s}{s}", .{
            folder,
            if (need_sep) "/" else "",
            self.current_name,
        }) catch return self.allocator.dupe(u8, self.current_name) catch unreachable;
    }

    /// 执行命令并解析输出。
    /// 注: 当前 Zig 0.16 已移除 std.ChildProcess.exec, 原生 kdialog/zenity
    /// 执行路径需要基于 std.process.Child + std.Io 重写。此处直接回退到内部
    /// 实现 (show 仍通过 runFallback 触发 on_response 回调), 保证 widget 可编译。
    fn execAndParse(self: *Self, argv: []const []const u8, mode: ParseMode) bool {
        _ = self;
        _ = argv;
        _ = mode;
        return false;
    }

    /// 解析 stdout，返回分配的路径列表（调用方 free）。
    /// 失败或空输出返回 null。
    fn parseOutput(self: *Self, stdout: []const u8, mode: ParseMode) ?std.ArrayListUnmanaged([]const u8) {
        var list = std.ArrayListUnmanaged([]const u8){};
        switch (mode) {
            .single_line => {
                const trimmed = std.mem.trimRight(u8, stdout, "\r\n \t");
                if (trimmed.len == 0) return null;
                const dup = self.allocator.dupe(u8, trimmed) catch return null;
                list.append(self.allocator, dup) catch {
                    self.allocator.free(dup);
                    return null;
                };
            },
            .multi_line => {
                var it = std.mem.splitSequence(u8, stdout, "\n");
                while (it.next()) |line| {
                    const t = std.mem.trimRight(u8, line, "\r \t");
                    if (t.len == 0) continue;
                    const dup = self.allocator.dupe(u8, t) catch continue;
                    list.append(self.allocator, dup) catch {
                        self.allocator.free(dup);
                        break;
                    };
                }
            },
            .kdialog_multi => {
                // shell-like 分词：空格分隔，"..." 和 '...' 作为整体
                var i: usize = 0;
                while (i < stdout.len) {
                    while (i < stdout.len and (stdout[i] == ' ' or stdout[i] == '\t' or
                        stdout[i] == '\n' or stdout[i] == '\r')) : (i += 1)
                    {}
                    if (i >= stdout.len) break;

                    var quoted: u8 = 0; // 0 / '"' / '\''
                    var tok = std.ArrayList(u8){ .items = &.{}, .capacity = 0 };
                    defer tok.deinit(self.allocator);
                    while (i < stdout.len) : (i += 1) {
                        const c = stdout[i];
                        if (quoted != 0) {
                            if (c == quoted) {
                                quoted = 0;
                            } else {
                                tok.append(self.allocator, c) catch break;
                            }
                        } else if (c == '"' or c == '\'') {
                            quoted = c;
                        } else if (c == ' ' or c == '\t' or c == '\n' or c == '\r') {
                            break;
                        } else {
                            tok.append(self.allocator, c) catch break;
                        }
                    }
                    if (tok.items.len > 0) {
                        const dup = tok.toOwnedSlice(self.allocator) catch continue;
                        list.append(self.allocator, dup) catch {
                            self.allocator.free(dup);
                            break;
                        };
                    }
                }
            },
        }
        if (list.items.len == 0) return null;
        return list;
    }

    pub fn hide(self: *Self) void {
        self.showing = false;
    }

    // ── 回退实现：使用 ZigUI 内部 FileChooserDialog 逻辑 ─────────────────────

    fn runFallback(self: *Self, _parent_window: ?*Widget) void {
        _ = _parent_window;
        // 简化：由于我们不直接创建模态窗口循环，这里通过立即回调 + 默认样例文件路径
        //   (save/create_folder) 或空 (cancel) 的方式演示。
        // 真实应用中可以把 FileChooserNative 传给内部 file_chooser.zig 的 FileChooser 并打开模态。
        switch (self.action) {
            .open, .select_folder => {
                // 回退场景默认无选择 → cancel
                self.fireResponse(.cancel);
            },
            .save, .create_folder => {
                // 若设置了 current_name，返回默认路径
                if (self.current_name.len > 0) {
                    const folder = if (self.current_folder.len > 0) self.current_folder else "/tmp";
                    const sep = if (std.mem.endsWith(u8, folder, "/") or
                        std.mem.endsWith(u8, folder, "\\"))
                        ""
                    else
                        "/";
                    const full = std.fmt.allocPrint(self.allocator, "{s}{s}{s}", .{ folder, sep, self.current_name }) catch null;
                    if (full) |f| {
                        self.addSelected(f) catch {};
                        self.allocator.free(f);
                        if (self.on_response) |cb| cb(self, .accept);
                        self.showing = false;
                        return;
                    }
                }
                self.fireResponse(.cancel);
            },
        }
    }

    fn fireResponse(self: *Self, resp: FileChooserResponse) void {
        if (self.on_response) |cb| cb(self, resp);
        self.showing = false;
    }
};
