//! Launcher 系列 —— GTK4.10+ 新版异步启动器 API
//!
//! GTK4 已弃用 GtkFileChooserDialog / GtkColorChooserDialog 等旧式同步对话框，
//! 改为使用 GtkFileLauncher / GtkUriLauncher / GtkColorDialogLauncher 等
//! 异步模式 (基于 GAsyncReady 回调)。
//!
//! 这里提供 ZigUI 版本：回调模式而非 GAsyncResult，接口一致：
//! - `launch(parent_window, callback)` 启动操作
//! - 回调在用户选择/取消后调用 (使用 Result 风格返回)
//!
//! 内容：
//! - FileLauncher —— 打开/保存单个文件 (包裹 FileDialog)
//! - UriLauncher —— 使用系统默认程序打开 URI (http://、mailto:、file://)
//! - ColorDialogLauncher —— 选择颜色 (包裹 ColorDialog)
//! - FontDialogLauncher —— 选择字体 (包裹 FontDialog)
//! - AlertDialogLauncher —— 显示消息/警告 (包裹 AlertDialog)

const std = @import("std");
const Allocator = std.mem.Allocator;
const math = @import("../math.zig");
const Color = math.Color;

pub const FileLauncherError = error{
    Cancelled,
    NoParent,
    DialogFailed,
    InvalidUri,
};

/// GTK4: GtkFileLauncher —— 打开文件 (gtk_file_launcher_launch / open_containing_folder)
pub const FileLauncher = struct {
    allocator: Allocator,
    /// 初始文件夹 (nullable)
    initial_folder: ?[]const u8 = null,
    /// 初始文件名 (保存时用)
    initial_name: ?[]const u8 = null,
    /// 文件过滤器 (指针，外部管理)
    filter: ?*@import("../model/file_filter.zig").FileFilter = null,
    /// 对话框标题
    title: []const u8 = "选择文件",
    /// 模式: open 或 save
    mode: enum { open, save } = .open,
    /// 是否可选择多个 (GTK4 GtkFileLauncher.select_multiple)
    select_multiple: bool = false,
    /// 成功回调: 返回选中文件的完整路径 (slice owned by caller)
    on_result: ?*const fn (self: *FileLauncher, result: FileLauncherResult) void = null,

    pub const FileLauncherResult = union(enum) {
        /// 单选: 一个路径 (owned, 需要调用者 free)
        file: []const u8,
        /// 多选: 多个路径 (slice 元素和数组本身都 owned)
        files: [][]const u8,
        /// 失败原因
        err: FileLauncherError,
    };

    pub fn init(allocator: Allocator, opts: struct {
        title: []const u8 = "选择文件",
        mode: enum { open, save } = .open,
        initial_folder: ?[]const u8 = null,
        initial_name: ?[]const u8 = null,
        filter: ?*@import("../model/file_filter.zig").FileFilter = null,
        select_multiple: bool = false,
        on_result: ?*const fn (self: *FileLauncher, result: FileLauncherResult) void = null,
    }) !FileLauncher {
        const owned_folder = if (opts.initial_folder) |f| try allocator.dupe(u8, f) else null;
        errdefer if (owned_folder) |x| allocator.free(x);
        const owned_name = if (opts.initial_name) |n| try allocator.dupe(u8, n) else null;
        errdefer if (owned_name) |x| allocator.free(x);
        return .{
            .allocator = allocator,
            .title = opts.title,
            .mode = opts.mode,
            .initial_folder = owned_folder,
            .initial_name = owned_name,
            .filter = opts.filter,
            .select_multiple = opts.select_multiple,
            .on_result = opts.on_result,
        };
    }

    pub fn deinit(self: *FileLauncher) void {
        if (self.initial_folder) |f| self.allocator.free(f);
        if (self.initial_name) |n| self.allocator.free(n);
        self.* = undefined;
    }

    /// GTK4: gtk_file_launcher_launch —— 启动文件选择
    ///
    /// parent_window: 可选父窗口 (Widget 指针)；实际显示由 UI 层完成。
    /// 简化版：立即触发 on_result.err = Cancelled，
    /// 如果用户在 FileChooser 对话框中实际选择，由对话框手动调用 emitResult。
    pub fn launch(self: *FileLauncher, parent_window: ?*anyopaque) void {
        _ = self;
        _ = parent_window;
        // 真实实现: 创建 FileChooser 对话框，挂到 parent_window，
        // 选择完成/取消后调用 emitResult。
        // 这里只提供接口占位，等待实际窗口系统集成。
    }

    /// 发射结果 (供 UI 层对话框回调调用)
    pub fn emitResult(self: *FileLauncher, result: FileLauncherResult) void {
        if (self.on_result) |cb| cb(self, result);
    }

    /// GTK4: gtk_file_launcher_open_containing_folder —— 打开文件所在文件夹
    pub fn openContainingFolder(self: *FileLauncher, parent: ?*anyopaque, file_path: []const u8) void {
        _ = self;
        _ = parent;
        // 系统调用: 打开文件管理器 (Linux: xdg-open dirname, macOS: open -R, Windows: explorer /select,)
        launchSystemFileManager(file_path) catch {};
    }
};

/// GTK4: GtkUriLauncher —— 使用系统默认程序打开 URI
pub const UriLauncher = struct {
    allocator: Allocator,
    uri: ?[]const u8 = null,
    /// 完成回调: bool = 是否成功
    on_done: ?*const fn (self: *UriLauncher, success: bool) void = null,

    pub fn init(allocator: Allocator, uri: ?[]const u8) !UriLauncher {
        const owned = if (uri) |u| try allocator.dupe(u8, u) else null;
        return .{ .allocator = allocator, .uri = owned };
    }

    pub fn deinit(self: *UriLauncher) void {
        if (self.uri) |u| self.allocator.free(u);
        self.* = undefined;
    }

    /// GTK4: gtk_uri_launcher_launch —— 启动
    pub fn launch(self: *UriLauncher, parent_window: ?*anyopaque) void {
        _ = parent_window;
        const u = self.uri orelse {
            if (self.on_done) |cb| cb(self, false);
            return;
        };
        const ok = launchSystemUri(u);
        if (self.on_done) |cb| cb(self, ok);
    }

    /// GTK4: gtk_uri_launcher_set_uri
    pub fn setUri(self: *UriLauncher, uri: ?[]const u8) !void {
        if (self.uri) |u| self.allocator.free(u);
        self.uri = if (uri) |u| try self.allocator.dupe(u8, u) else null;
    }
    pub fn getUri(self: *const UriLauncher) ?[]const u8 {
        return self.uri;
    }
};

/// GTK4: GtkColorDialogLauncher —— 异步颜色选择
pub const ColorDialogLauncher = struct {
    allocator: Allocator,
    /// 初始颜色
    initial_color: ?Color = null,
    /// 是否支持 alpha
    with_alpha: bool = false,
    /// 标题
    title: []const u8 = "选择颜色",
    /// 结果回调: ?Color = null 表示取消
    on_result: ?*const fn (self: *ColorDialogLauncher, color: ?Color) void = null,

    pub fn init(allocator: Allocator, opts: struct {
        title: []const u8 = "选择颜色",
        initial_color: ?Color = null,
        with_alpha: bool = false,
        on_result: ?*const fn (self: *ColorDialogLauncher, color: ?Color) void = null,
    }) ColorDialogLauncher {
        return .{
            .allocator = allocator,
            .title = opts.title,
            .initial_color = opts.initial_color,
            .with_alpha = opts.with_alpha,
            .on_result = opts.on_result,
        };
    }

    pub fn deinit(self: *ColorDialogLauncher) void {
        self.* = undefined;
    }

    /// GTK4: gtk_color_dialog_launcher_launch
    pub fn launch(self: *ColorDialogLauncher, parent_window: ?*anyopaque) void {
        _ = self;
        _ = parent_window;
        // 占位: 应显示 ColorDialog 并在关闭时调用 emit
    }

    pub fn emitResult(self: *ColorDialogLauncher, color: ?Color) void {
        if (self.on_result) |cb| cb(self, color);
    }
};

/// GTK4: GtkFontDialogLauncher —— 异步字体选择
pub const FontDialogLauncher = struct {
    allocator: Allocator,
    /// 初始字体描述 ("Sans 12" 等)
    initial_font: ?[]const u8 = null,
    title: []const u8 = "选择字体",
    /// 结果回调: ?[]const u8 = null 表示取消，返回字体描述
    on_result: ?*const fn (self: *FontDialogLauncher, font_desc: ?[]const u8) void = null,

    pub fn init(allocator: Allocator, opts: struct {
        title: []const u8 = "选择字体",
        initial_font: ?[]const u8 = null,
        on_result: ?*const fn (self: *FontDialogLauncher, font_desc: ?[]const u8) void = null,
    }) !FontDialogLauncher {
        const owned = if (opts.initial_font) |f| try allocator.dupe(u8, f) else null;
        return .{
            .allocator = allocator,
            .title = opts.title,
            .initial_font = owned,
            .on_result = opts.on_result,
        };
    }

    pub fn deinit(self: *FontDialogLauncher) void {
        if (self.initial_font) |f| self.allocator.free(f);
        self.* = undefined;
    }

    pub fn launch(self: *FontDialogLauncher, parent_window: ?*anyopaque) void {
        _ = self;
        _ = parent_window;
        // 占位: 显示 FontDialog 并回调
    }

    pub fn emitResult(self: *FontDialogLauncher, font_desc: ?[]const u8) void {
        if (self.on_result) |cb| cb(self, font_desc);
    }
};

/// 简化版 AlertDialogLauncher —— GTK4 GtkAlertDialog 异步消息框
pub const AlertDialogLauncher = struct {
    allocator: Allocator,
    title: []const u8,
    message: []const u8,
    /// 按钮标签 (最多 3 个，index 作为 response id; 最后一个作为 Cancel/Destructive)
    buttons: []const []const u8 = &.{"OK"},
    /// 默认按钮 response_id (0-based)
    default_button: ?usize = 0,
    /// 取消按钮 id (Esc 时返回); null = 使用最后一个按钮
    cancel_button: ?usize = null,
    /// 模态
    modal: bool = true,
    /// 回调: usize = response button index
    on_response: ?*const fn (self: *AlertDialogLauncher, response: usize) void = null,

    pub fn init(allocator: Allocator, title: []const u8, message: []const u8) AlertDialogLauncher {
        return .{
            .allocator = allocator,
            .title = title,
            .message = message,
        };
    }

    pub fn launch(self: *AlertDialogLauncher, parent_window: ?*anyopaque) void {
        _ = self;
        _ = parent_window;
        // 占位: 显示 AlertDialog 并回调
    }

    pub fn emitResponse(self: *AlertDialogLauncher, response: usize) void {
        if (self.on_response) |cb| cb(self, response);
    }
};

// ── 系统 URI / 文件管理器调用 (平台适配层占位) ────────────────────────────

fn launchSystemUri(uri: []const u8) bool {
    if (uri.len == 0) return false;
    // 检测平台: Linux -> xdg-open; macOS -> open; Windows -> start
    const ZIGUI_TARGET = @import("builtin").target.os.tag;
    if (ZIGUI_TARGET == .linux) {
        return spawnAndForget(&.{ "xdg-open", uri });
    } else if (ZIGUI_TARGET == .macos) {
        return spawnAndForget(&.{ "open", uri });
    } else if (ZIGUI_TARGET == .windows) {
        // Windows: cmd /c start "" "uri"
        return spawnAndForget(&.{ "cmd", "/c", "start", "\"\"", uri });
    }
    return false;
}

fn launchSystemFileManager(file_path: []const u8) !void {
    const dirname = std.fs.path.dirname(file_path) orelse return;
    const ZIGUI_TARGET = @import("builtin").target.os.tag;
    if (ZIGUI_TARGET == .linux) {
        _ = spawnAndForget(&.{ "xdg-open", dirname });
    } else if (ZIGUI_TARGET == .macos) {
        // macOS: open -R path (Reveal in Finder)
        _ = spawnAndForget(&.{ "open", "-R", file_path });
    } else if (ZIGUI_TARGET == .windows) {
        // Windows: explorer /select,path
        var buf: [4096]u8 = undefined;
        const cmd = try std.fmt.bufPrint(&buf, "/select,{s}", .{file_path});
        _ = spawnAndForget(&.{ "explorer.exe", cmd });
    }
}

fn spawnAndForget(argv: []const []const u8) bool {
    if (argv.len == 0) return false;
    const result = std.process.Child.run(.{
        .argv = argv,
        .allocator = std.heap.page_allocator,
    }) catch return false;
    // 不等待子进程 (fire-and-forget). 实际上在 Linux/macOS 上 xdg-open 会后台返回。
    return result.term == std.process.Child.Term{ .exited = 0 };
}
