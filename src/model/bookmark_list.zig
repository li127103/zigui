//! BookmarkList — 书签列表模型 (对标 GtkBookmarkList)
//!
//! 读取 XDG 标准的 GTK 书签文件（`$XDG_CONFIG_HOME/gtk-3.0/bookmarks` 或
//! `~/.config/gtk-3.0/bookmarks`），解析每行 `file:///URI [DisplayName]` 格式。
//! 同时也读取 XDG user-dirs（用户目录：桌面/下载/文档/音乐/视频等）。
//!
//! 实现 ListModelIface，每个 item 是 *BookmarkInfo，可被 ListView/ColumnView 消费。
//!
//! 用法:
//! ```
//! var bm = try m.BookmarkList.create(alloc, .{ .include_user_dirs = true });
//! defer bm.destroy();
//! for (0..bm.nItems()) |i| {
//!     const info: *BookmarkInfo = @ptrCast(@alignCast(bm.model().getItem(i).?));
//!     // info.uri / info.label / info.path
//! }
//! ```

const std = @import("std");
const Allocator = std.mem.Allocator;
const builtin = @import("builtin");
const os = std.os;
const list_model = @import("list_model.zig");
const ListModel = list_model.ListModel;
const ListModelIface = list_model.ListModelIface;
const ItemsChangedFn = list_model.ItemsChangedFn;

/// 书签项
pub const BookmarkInfo = struct {
    /// 原始 URI (file:///...)，已 dup
    uri: []const u8,
    /// 本地路径 (从 URI 解码，若可解析则非空；否则为 uri)，已 dup
    path: []const u8,
    /// 显示名称 (书签后的可选 DisplayName；否则用 path 的 basename)，已 dup
    label: []const u8,
    /// 是否来自 XDG user-dirs (不是 bookmarks 文件)
    is_user_dir: bool = false,
    /// 名称 (如 "Desktop"、"Downloads"，仅 user-dirs 有，否则同 label)，已 dup
    xdg_name: []const u8 = "",
};

pub const BookmarkList = struct {
    allocator: Allocator,
    items: std.ArrayListUnmanaged(*BookmarkInfo) = .{},
    include_user_dirs: bool,

    on_items_changed: ?ItemsChangedFn = null,
    on_items_changed_userdata: ?*anyopaque = null,

    const static_iface = ListModelIface{
        .getItemFn = getItemFn,
        .getNItemsFn = getNItemsFn,
        .getItemTypeFn = getTypeFn,
    };

    const Self = @This();

    pub fn create(allocator: Allocator, opts: struct {
        /// 是否包含 XDG 标准用户目录
        include_user_dirs: bool = true,
        /// 是否同时读取 gtk-3.0 bookmarks 文件
        include_gtk_bookmarks: bool = true,
        auto_load: bool = true,
    }) !*Self {
        const self = try allocator.create(Self);
        self.* = .{
            .allocator = allocator,
            .include_user_dirs = opts.include_user_dirs,
        };
        if (opts.auto_load) {
            self.load(opts.include_user_dirs, opts.include_gtk_bookmarks) catch |e| {
                if (e == error.OutOfMemory) return e;
                // 读不到文件不是致命错误
            };
        }
        return self;
    }

    pub fn destroy(self: *Self) void {
        self.freeItems();
        self.items.deinit(self.allocator);
        self.allocator.destroy(self);
    }

    pub fn model(self: *Self) ListModel {
        return .{ .iface = &static_iface, .userdata = self };
    }

    /// 重新加载
    pub fn reload(self: *Self, include_user_dirs: bool, include_gtk_bookmarks: bool) !void {
        const old = self.items.items.len;
        self.freeItems();
        if (old > 0) self.emitChanged(0, old, 0);
        try self.load(include_user_dirs, include_gtk_bookmarks);
        const n = self.items.items.len;
        if (n > 0) self.emitChanged(0, 0, n);
    }

    /// 追加一个自定义书签 (运行时添加，不写入磁盘)
    pub fn append(self: *Self, uri: []const u8, label: ?[]const u8) !void {
        const info = try self.makeInfo(uri, label, false, "");
        const pos = self.items.items.len;
        try self.items.append(self.allocator, info);
        self.emitChanged(pos, 0, 1);
    }

    /// 在位置 idx 移除书签 (仅内存；如需同步到磁盘需外部实现)
    pub fn removeAt(self: *Self, idx: usize) void {
        if (idx >= self.items.items.len) return;
        const info = self.items.orderedRemove(idx);
        self.allocator.free(info.uri);
        self.allocator.free(info.path);
        self.allocator.free(info.label);
        if (info.xdg_name.len > 0) self.allocator.free(info.xdg_name);
        self.allocator.destroy(info);
        self.emitChanged(idx, 1, 0);
    }

    // ── 内部 ───────────────────────────────────────────────────────────────

    fn load(self: *Self, include_user_dirs: bool, include_gtk_bookmarks: bool) !void {
        if (builtin.os.tag == .windows) return;

        if (include_user_dirs) {
            try self.loadUserDirs();
        }
        if (include_gtk_bookmarks) {
            try self.loadGtkBookmarks();
        }
    }

    /// XDG user-dirs: 读取 $XDG_CONFIG_HOME/user-dirs.dirs，或 fallback 硬编码
    fn loadUserDirs(self: *Self) !void {
        const home = std.process.getEnvVarOwned(self.allocator, "HOME") catch |e| blk: {
            if (e == error.EnvironmentVariableNotFound) break :blk "" else return e;
        };
        defer if (home.len > 0) self.allocator.free(home);
        if (home.len == 0) return;

        // 1) 尝试读 user-dirs.dirs
        const xdg_config = std.process.getEnvVarOwned(self.allocator, "XDG_CONFIG_HOME") catch |e| blk: {
            if (e == error.EnvironmentVariableNotFound) break :blk "" else return e;
        };
        const user_dirs_path: []const u8 = if (xdg_config.len > 0)
            try std.fmt.allocPrint(self.allocator, "{s}/user-dirs.dirs", .{xdg_config})
        else
            try std.fmt.allocPrint(self.allocator, "{s}/.config/user-dirs.dirs", .{home});
        defer self.allocator.free(user_dirs_path);
        defer if (xdg_config.len > 0) self.allocator.free(xdg_config);

        // 定义要找的 XDG user dir 键
        const dir_keys = [_]struct { key: []const u8, label: []const u8 }{
            .{ .key = "XDG_DESKTOP_DIR", .label = "Desktop" },
            .{ .key = "XDG_DOWNLOAD_DIR", .label = "Downloads" },
            .{ .key = "XDG_DOCUMENTS_DIR", .label = "Documents" },
            .{ .key = "XDG_MUSIC_DIR", .label = "Music" },
            .{ .key = "XDG_PICTURES_DIR", .label = "Pictures" },
            .{ .key = "XDG_VIDEOS_DIR", .label = "Videos" },
            .{ .key = "XDG_PUBLICSHARE_DIR", .label = "Public" },
            .{ .key = "XDG_TEMPLATES_DIR", .label = "Templates" },
        };

        // 简化: 用一个哈希
        var gpa = std.heap.GeneralPurposeAllocator(.{}){};
        defer _ = gpa.deinit();
        var vals = std.StringHashMap([]const u8).init(gpa.allocator());
        defer vals.deinit();

        const file = std.fs.cwd().openFile(user_dirs_path, .{}) catch {
            // fallback: 硬编码路径
            for (dir_keys) |dk| {
                const lower = dk.label;
                const p = try std.fmt.allocPrint(self.allocator, "{s}/{s}", .{ home, lower });
                const uri = try std.fmt.allocPrint(self.allocator, "file://{s}", .{p});
                const label_dup = try self.allocator.dupe(u8, dk.label);
                const info = try self.allocator.create(BookmarkInfo);
                info.* = .{
                    .uri = uri,
                    .path = p,
                    .label = label_dup,
                    .is_user_dir = true,
                    .xdg_name = try self.allocator.dupe(u8, dk.label),
                };
                self.items.append(self.allocator, info) catch |e| {
                    self.freeInfo(info);
                    return e;
                };
            }
            return;
        };
        defer file.close();

        const content = file.readToEndAlloc(self.allocator, 1 << 20) catch |e| {
            if (e == error.OutOfMemory) return e;
            return;
        };
        defer self.allocator.free(content);

        // 解析: XDG_DESKTOP_DIR="$HOME/Desktop"
        var line_it = std.mem.tokenizeScalar(u8, content, '\n');
        while (line_it.next()) |raw_line| {
            const line = std.mem.trim(u8, raw_line, " \t\r");
            if (line.len == 0 or line[0] == '#') continue;
            const eq = std.mem.indexOfScalar(u8, line, '=') orelse continue;
            const key = std.mem.trim(u8, line[0..eq], " \t");
            var val = std.mem.trim(u8, line[eq + 1 ..], " \t");
            // 去掉前后引号
            if (val.len >= 2 and (val[0] == '"' and val[val.len - 1] == '"')) {
                val = val[1 .. val.len - 1];
            }
            // 替换 $HOME
            const expanded = try replaceHome(self.allocator, val, home);
            try vals.put(self.allocator.dupe(u8, key) catch &.{}, expanded);
        }

        for (dir_keys) |dk| {
            if (vals.get(dk.key)) |p| {
                const uri = try std.fmt.allocPrint(self.allocator, "file://{s}", .{p});
                const label_dup = try self.allocator.dupe(u8, dk.label);
                const info = try self.allocator.create(BookmarkInfo);
                info.* = .{
                    .uri = uri,
                    .path = try self.allocator.dupe(u8, p),
                    .label = label_dup,
                    .is_user_dir = true,
                    .xdg_name = try self.allocator.dupe(u8, dk.label),
                };
                self.items.append(self.allocator, info) catch |e| {
                    self.freeInfo(info);
                    return e;
                };
            }
        }
    }

    fn replaceHome(allocator: Allocator, s: []const u8, home: []const u8) ![]const u8 {
        if (std.mem.startsWith(u8, s, "$HOME")) {
            const rest = s["$HOME".len..];
            return try std.fmt.allocPrint(allocator, "{s}{s}", .{ home, rest });
        }
        return try allocator.dupe(u8, s);
    }

    /// 读取 gtk-3.0 bookmarks
    fn loadGtkBookmarks(self: *Self) !void {
        const bm_path = self.resolveGtkBookmarksPath() orelse return;
        defer self.allocator.free(bm_path);

        const file = std.fs.cwd().openFile(bm_path, .{}) catch return;
        defer file.close();

        const content = file.readToEndAlloc(self.allocator, 1 << 20) catch |e| {
            if (e == error.OutOfMemory) return e;
            return;
        };
        defer self.allocator.free(content);

        var it = std.mem.tokenizeScalar(u8, content, '\n');
        while (it.next()) |raw_line| {
            const line = std.mem.trim(u8, raw_line, " \t\r");
            if (line.len == 0) continue;
            // 按第一个空白分割 uri 和 label
            const sp = std.mem.indexOfAny(u8, line, " \t") orelse line.len;
            const uri = line[0..sp];
            const label = if (sp < line.len) std.mem.trim(u8, line[sp + 1 ..], " \t") else null;
            const info = self.makeInfo(uri, label, false, "") catch continue;
            self.items.append(self.allocator, info) catch |e| {
                self.freeInfo(info);
                if (e == error.OutOfMemory) return e;
            };
        }
    }

    fn resolveGtkBookmarksPath(self: *Self) ?[]const u8 {
        if (builtin.os.tag == .windows) return null;
        const xdg_config = std.process.getEnvVarOwned(self.allocator, "XDG_CONFIG_HOME") catch |e| blk: {
            if (e == error.EnvironmentVariableNotFound) break :blk "" else return null;
        };
        const home = std.process.getEnvVarOwned(self.allocator, "HOME") catch |e| blk: {
            if (e == error.EnvironmentVariableNotFound) break :blk "" else {
                if (xdg_config.len > 0) self.allocator.free(xdg_config);
                return null;
            }
        };

        const p: []const u8 = if (xdg_config.len > 0)
            std.fmt.allocPrint(self.allocator, "{s}/gtk-3.0/bookmarks", .{xdg_config}) catch {
                self.allocator.free(xdg_config);
                self.allocator.free(home);
                return null;
            }
        else
            std.fmt.allocPrint(self.allocator, "{s}/.config/gtk-3.0/bookmarks", .{home}) catch {
                self.allocator.free(home);
                return null;
            };
        if (xdg_config.len > 0) self.allocator.free(xdg_config);
        self.allocator.free(home);
        return p;
    }

    fn makeInfo(
        self: *Self,
        uri: []const u8,
        opt_label: ?[]const u8,
        is_user_dir: bool,
        xdg_name: []const u8,
    ) !*BookmarkInfo {
        const uri_dup = try self.allocator.dupe(u8, uri);
        errdefer self.allocator.free(uri_dup);

        // 解码 file:// URI 为路径: 去掉前缀，%xx 解码
        const path_dup = decodeFileUri(self.allocator, uri_dup) catch |e| {
            if (e == error.OutOfMemory) return e;
            try self.allocator.dupe(u8, uri);
        };
        errdefer self.allocator.free(path_dup);

        // 取 basename 当 fallback label
        const basename = basenameOf(path_dup);

        const label_src: []const u8 = opt_label orelse basename;
        const label_dup = try self.allocator.dupe(u8, label_src);
        errdefer self.allocator.free(label_dup);

        const xdg_dup: []const u8 = if (xdg_name.len > 0) try self.allocator.dupe(u8, xdg_name) else "";
        errdefer if (xdg_dup.len > 0) self.allocator.free(xdg_dup);

        const info = try self.allocator.create(BookmarkInfo);
        info.* = .{
            .uri = uri_dup,
            .path = path_dup,
            .label = label_dup,
            .is_user_dir = is_user_dir,
            .xdg_name = xdg_dup,
        };
        return info;
    }

    fn freeInfo(self: *Self, info: *BookmarkInfo) void {
        self.allocator.free(info.uri);
        self.allocator.free(info.path);
        self.allocator.free(info.label);
        if (info.xdg_name.len > 0) self.allocator.free(info.xdg_name);
        self.allocator.destroy(info);
    }

    fn freeItems(self: *Self) void {
        for (self.items.items) |info| self.freeInfo(info);
        self.items.clearRetainingCapacity();
    }

    inline fn emitChanged(self: *Self, pos: usize, removed: usize, added: usize) void {
        if (self.on_items_changed) |cb| {
            cb(self.on_items_changed_userdata, pos, removed, added);
        }
    }

    // ── ListModelIface ─────────────────────────────────────────────────────

    fn getItemFn(userdata: ?*anyopaque, position: usize) ?*anyopaque {
        const self: *Self = @ptrCast(@alignCast(userdata orelse return null));
        if (position >= self.items.items.len) return null;
        return self.items.items[position];
    }

    fn getNItemsFn(userdata: ?*anyopaque) usize {
        const self: *Self = @ptrCast(@alignCast(userdata orelse return 0));
        return self.items.items.len;
    }

    fn getTypeFn(_: ?*anyopaque) []const u8 {
        return "BookmarkInfo";
    }
};

// ── 工具函数 ──────────────────────────────────────────────────────────────────

fn basenameOf(path: []const u8) []const u8 {
    const p = if (path.len > 1 and path[path.len - 1] == '/') path[0 .. path.len - 1] else path;
    const last_slash = std.mem.lastIndexOfScalar(u8, p, '/') orelse return p;
    return p[last_slash + 1 ..];
}

/// 把 file:///path/to/some%20file 解码成路径；失败则返回原字符串 dup
fn decodeFileUri(allocator: Allocator, uri: []const u8) ![]const u8 {
    const trimmed = if (std.mem.startsWith(u8, uri, "file://"))
        uri["file://".len..]
    else
        return try allocator.dupe(u8, uri);
    // 去掉 host 部分: file://localhost/... → /...
    const body = if (trimmed.len > 0 and trimmed[0] != '/') blk: {
        const first_slash = std.mem.indexOfScalar(u8, trimmed, '/') orelse return try allocator.dupe(u8, trimmed);
        break :blk trimmed[first_slash..];
    } else trimmed;

    // 预分配 buf
    var out = try std.ArrayListUnmanaged(u8).initCapacity(allocator, body.len);
    errdefer out.deinit(allocator);

    var i: usize = 0;
    while (i < body.len) {
        const c = body[i];
        if (c == '%' and i + 2 < body.len) {
            const hex = body[i + 1 .. i + 3];
            if (std.fmt.parseInt(u8, hex, 16)) |byte| {
                out.appendAssumeCapacity(byte);
                i += 3;
                continue;
            } else |_| {}
        }
        out.appendAssumeCapacity(c);
        i += 1;
    }
    return try out.toOwnedSlice(allocator);
}
