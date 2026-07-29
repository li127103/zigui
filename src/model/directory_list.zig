//! DirectoryList — 目录枚举 ListModel (对标 GtkDirectoryList)
//!
//! 通过 libc opendir/readdir 枚举指定目录，生成文件信息（FileInfo）列表。
//! 实现 ListModelIface，可直接被 ColumnView / GridView / SelectionModel 消费。
//!
//! 每个 item 是 *FileInfo，包含文件名/大小/修改时间/是否为目录等元数据。
//!
//! 典型用法:
//! ```
//! var dir = try m.DirectoryList.create(alloc, "/home/user/Documents", .{});
//! defer dir.destroy();
//! var sel = try m.SingleSelection.create(alloc, dir.model(), .{});
//! col_view.setSelectionModel(sel);
//! ```

const std = @import("std");
const Allocator = std.mem.Allocator;
const builtin = @import("builtin");
const list_model = @import("list_model.zig");
const ListModel = list_model.ListModel;
const ListModelIface = list_model.ListModelIface;
const ItemsChangedFn = list_model.ItemsChangedFn;

/// 文件信息（每个 model item 都是 *FileInfo）
pub const FileInfo = struct {
    /// 文件名 (不含路径，已 dup，所有者为 DirectoryList)
    name: []const u8,
    /// 完整路径 (已 dup)
    full_path: []const u8,
    /// 是否为目录
    is_dir: bool,
    /// 是否为符号链接
    is_symlink: bool,
    /// 是否为常规文件
    is_regular: bool,
    /// 文件大小 (字节，目录/不可读时为 0)
    size: u64,
    /// 修改时间 (unix 秒，不可用时为 0)
    mtime_sec: i64,
    /// 访问时间
    atime_sec: i64,
    /// 创建时间 (不可用时为 0)
    ctime_sec: i64,
    /// 所有者 uid (-1 表示不可用)
    uid: i64 = -1,
    /// 模式位 (权限，0 表示不可用)
    mode: u32 = 0,
};

pub const DirectoryList = struct {
    allocator: Allocator,
    /// 当前目录路径 (已 dup)
    path: []const u8,
    /// 文件项列表
    items: std.ArrayListUnmanaged(*FileInfo) = .{},
    /// 是否包含隐藏文件 (以 . 开头)
    show_hidden: bool,
    /// 排序方式
    sort_by: enum { name, size, mtime, none } = .name,
    /// 排序方向
    sort_order: enum { ascending, descending } = .ascending,
    /// 目录优先级 (目录排在文件前面)
    dirs_first: bool = true,

    on_items_changed: ?ItemsChangedFn = null,
    on_items_changed_userdata: ?*anyopaque = null,

    const static_iface = ListModelIface{
        .getItemFn = getItemFn,
        .getNItemsFn = getNItemsFn,
        .getItemTypeFn = getTypeFn,
    };

    const Self = @This();

    pub fn create(
        allocator: Allocator,
        path: []const u8,
        opts: struct {
            show_hidden: bool = false,
            sort_by: enum { name, size, mtime, none } = .name,
            sort_order: enum { ascending, descending } = .ascending,
            dirs_first: bool = true,
            auto_load: bool = true,
        },
    ) !*Self {
        const owned_path = try allocator.dupe(u8, path);
        const self = try allocator.create(Self);
        self.* = .{
            .allocator = allocator,
            .path = owned_path,
            .show_hidden = opts.show_hidden,
            .sort_by = opts.sort_by,
            .sort_order = opts.sort_order,
            .dirs_first = opts.dirs_first,
        };
        if (opts.auto_load) {
            self.load() catch |e| {
                // 加载失败不致命，仅保留空列表
                if (e == error.OutOfMemory) return e;
            };
        }
        return self;
    }

    pub fn destroy(self: *Self) void {
        self.freeItems();
        self.allocator.free(self.path);
        self.items.deinit(self.allocator);
        self.allocator.destroy(self);
    }

    /// 返回 ListModel 胖指针 (item = *FileInfo)
    pub fn model(self: *Self) ListModel {
        return .{ .iface = &static_iface, .userdata = self };
    }

    /// 重新设置路径，自动重枚举
    pub fn setPath(self: *Self, new_path: []const u8) !void {
        const old_count = self.items.items.len;
        self.freeItems();
        if (old_count > 0) self.emitChanged(0, old_count, 0);

        self.allocator.free(self.path);
        self.path = try self.allocator.dupe(u8, new_path);
        try self.load();
        const new_count = self.items.items.len;
        if (new_count > 0) self.emitChanged(0, 0, new_count);
    }

    pub fn getPath(self: *const Self) []const u8 {
        return self.path;
    }

    pub fn setShowHidden(self: *Self, v: bool) !void {
        if (self.show_hidden == v) return;
        self.show_hidden = v;
        try self.reload();
    }

    pub fn setSorting(self: *Self, by: enum { name, size, mtime, none }, order: enum { ascending, descending }) !void {
        if (self.sort_by == by and self.sort_order == order) return;
        self.sort_by = by;
        self.sort_order = order;
        try self.reload();
    }

    pub fn setDirsFirst(self: *Self, v: bool) !void {
        if (self.dirs_first == v) return;
        self.dirs_first = v;
        try self.reload();
    }

    /// 重新枚举目录
    pub fn reload(self: *Self) !void {
        const old_count = self.items.items.len;
        self.freeItems();
        if (old_count > 0) self.emitChanged(0, old_count, 0);
        try self.load();
        const new_count = self.items.items.len;
        if (new_count > 0) self.emitChanged(0, 0, new_count);
    }

    // ── 内部: 枚举目录 ────────────────────────────────────────────────────

    fn load(self: *Self) !void {
        // 只在 POSIX 系统支持目录枚举
        if (builtin.os.tag == .windows) return;

        const c_path = try self.allocator.allocSentinel(u8, self.path.len, 0);
        defer self.allocator.free(c_path);
        @memcpy(c_path[0..self.path.len], self.path);

        const dir = std.c.opendir(c_path) orelse return;
        defer _ = std.c.closedir(dir);

        while (true) {
            std.c.errno = 0;
            const entry = std.c.readdir(dir) orelse {
                if (std.c.errno != 0) continue;
                break;
            };
            const name_ptr: [*:0]const u8 = @ptrCast(&entry.d_name);
            const name_len = std.mem.len(name_ptr);
            const name = name_ptr[0..name_len];

            // 跳过 . 和 ..
            if (std.mem.eql(u8, name, ".") or std.mem.eql(u8, name, "..")) continue;
            // 隐藏文件 (以 . 开头)
            if (!self.show_hidden and name.len > 0 and name[0] == '.') continue;

            // 构造完整路径
            const has_sep = self.path.len > 0 and self.path[self.path.len - 1] == '/';
            const full = try std.fmt.allocPrint(self.allocator, "{s}{s}{s}", .{
                self.path,
                if (has_sep) "" else "/",
                name,
            });
            errdefer self.allocator.free(full);

            // stat 获取详细信息
            var st: std.c.stat_t = undefined;
            const stat_ok = if (std.c.lstat(full.ptr, &st) == 0) true else false;

            const owned_name = try self.allocator.dupe(u8, name);
            errdefer self.allocator.free(owned_name);

            const fi = try self.allocator.create(FileInfo);
            fi.* = .{
                .name = owned_name,
                .full_path = full,
                .is_dir = if (stat_ok) (st.mode & std.c.S_IFMT) == std.c.S_IFDIR else false,
                .is_symlink = if (stat_ok) (st.mode & std.c.S_IFMT) == std.c.S_IFLNK else false,
                .is_regular = if (stat_ok) (st.mode & std.c.S_IFMT) == std.c.S_IFREG else false,
                .size = if (stat_ok) @intCast(st.size) else 0,
                .mtime_sec = if (stat_ok) st.mtime else 0,
                .atime_sec = if (stat_ok) st.atime else 0,
                .ctime_sec = if (stat_ok) st.ctime else 0,
                .uid = if (stat_ok) @intCast(st.uid) else -1,
                .mode = if (stat_ok) @intCast(st.mode & 0o7777) else 0,
            };
            self.items.append(self.allocator, fi) catch |e| {
                self.allocator.free(owned_name);
                self.allocator.free(full);
                self.allocator.destroy(fi);
                return e;
            };
        }

        // 排序
        if (self.sort_by != .none or self.dirs_first) {
            self.sortItems();
        }
    }

    fn sortItems(self: *Self) void {
        const ctx = self;
        std.sort.pdq(*FileInfo, self.items.items, ctx, cmpFileInfo);
    }

    fn cmpFileInfo(ctx: *const Self, a: *FileInfo, b: *FileInfo) bool {
        // dirs_first
        if (ctx.dirs_first) {
            if (a.is_dir and !b.is_dir) return ctx.sort_order == .ascending;
            if (!a.is_dir and b.is_dir) return ctx.sort_order != .ascending;
        }
        const order: std.math.Order = switch (ctx.sort_by) {
            .name => blk: {
                const cmp = std.ascii.compareIgnoreCase(a.name, b.name);
                break :blk cmp;
            },
            .size => std.math.order(a.size, b.size),
            .mtime => std.math.order(a.mtime_sec, b.mtime_sec),
            .none => return false, // 保持相对位置
        };
        const asc = order == .lt;
        return if (ctx.sort_order == .ascending) asc else !asc;
    }

    fn freeItems(self: *Self) void {
        for (self.items.items) |fi| {
            self.allocator.free(fi.name);
            self.allocator.free(fi.full_path);
            self.allocator.destroy(fi);
        }
        self.items.clearRetainingCapacity();
    }

    inline fn emitChanged(self: *Self, pos: usize, removed: usize, added: usize) void {
        if (self.on_items_changed) |cb| {
            cb(self.on_items_changed_userdata, pos, removed, added);
        }
    }

    // ── ListModelIface 实现 ────────────────────────────────────────────────

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
        return "FileInfo";
    }
};
