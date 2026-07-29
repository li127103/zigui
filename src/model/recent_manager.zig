//! RecentManager - GTK4 GtkRecentManager 风格：管理最近使用的文件/URI 列表
//!
//! 核心功能：
//! - `addItem(uri, display_name, mimeType)` 添加最近项
//! - `removeItem(uri)` 按 URI 删除
//! - `getItems()` 返回按访问时间排序的列表
//! - `purgeItems(age_days)` 清理超期项
//! - 内置单例 `getDefault()` 返回全局默认管理器
//! - 保存/加载到本地文件 (XDG_CACHE_HOME/recently-used.xbel 格式简化版)

const std = @import("std");
const Allocator = std.mem.Allocator;
const time = std.time;

/// 最近使用条目
pub const RecentInfo = struct {
    /// URI (file:// 或任意标识字符串)
    uri: []const u8,
    /// 显示名称 (通常是文件名)
    display_name: []const u8,
    /// MIME 类型 (可选)
    mime_type: ?[]const u8 = null,
    /// 应用程序名 (可选, 记录添加者)
    app_name: ?[]const u8 = null,
    /// 最后访问时间戳 (秒, Unix epoch)
    modified: i64,
    /// 访问次数
    visited: u32 = 1,
    /// 分组标签 (可选)
    groups: std.ArrayListUnmanaged([]const u8) = .empty,
    /// 是否为私有项 (不显示在全局最近列表)
    is_private: bool = false,

    pub fn deinit(self: *RecentInfo, allocator: Allocator) void {
        allocator.free(self.uri);
        allocator.free(self.display_name);
        if (self.mime_type) |m| allocator.free(m);
        if (self.app_name) |a| allocator.free(a);
        for (self.groups.items) |g| allocator.free(g);
        self.groups.deinit(allocator);
        self.* = undefined;
    }
};

/// GTK4: GtkRecentManager
pub const RecentManager = struct {
    allocator: Allocator,
    items: std.ArrayListUnmanaged(RecentInfo) = .empty,
    /// 最大条目数 (默认 50, 超出后丢弃最久未访问)
    max_items: usize = 50,
    /// 变更回调 (可选)
    on_changed: ?*const fn (self: *RecentManager) void = null,

    /// 全局默认管理器 (懒加载单例)
    var default_instance: ?*RecentManager = null;

    pub fn init(allocator: Allocator) RecentManager {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *RecentManager) void {
        for (self.items.items) |*it| {
            var tmp = it.*;
            tmp.deinit(self.allocator);
        }
        self.items.deinit(self.allocator);
        self.* = undefined;
    }

    /// 获取默认全局管理器 (线程安全简化版)
    pub fn getDefault() !*RecentManager {
        if (default_instance == null) {
            const alloc = std.heap.c_allocator;
            const inst = try alloc.create(RecentManager);
            inst.* = RecentManager.init(alloc);
            default_instance = inst;
        }
        return default_instance.?;
    }

    /// GTK4: gtk_recent_manager_add_item
    /// 返回 true 表示新增, false 表示更新已有
    pub fn addItem(
        self: *RecentManager,
        uri: []const u8,
        opts: struct {
            display_name: ?[]const u8 = null,
            mime_type: ?[]const u8 = null,
            app_name: ?[]const u8 = null,
            groups: ?[]const []const u8 = null,
            is_private: bool = false,
        },
    ) !bool {
        // 查找是否存在相同 URI
        for (self.items.items, 0..) |*it, idx| {
            if (std.mem.eql(u8, it.uri, uri)) {
                // 更新已有项
                it.modified = time.timestamp();
                it.visited += 1;
                it.is_private = opts.is_private;
                // 更新可选字段
                if (opts.display_name) |dn| {
                    self.allocator.free(it.display_name);
                    it.display_name = try self.allocator.dupe(u8, dn);
                }
                if (opts.mime_type) |mt| {
                    if (it.mime_type) |old| self.allocator.free(old);
                    it.mime_type = try self.allocator.dupe(u8, mt);
                }
                if (opts.app_name) |an| {
                    if (it.app_name) |old| self.allocator.free(old);
                    it.app_name = try self.allocator.dupe(u8, an);
                }
                // 移动到最前 (最新)
                const item = self.items.orderedRemove(idx);
                try self.items.insertAt(self.allocator, 0, item);
                self.notifyChanged();
                return false;
            }
        }
        // 新增项
        const owned_uri = try self.allocator.dupe(u8, uri);
        errdefer self.allocator.free(owned_uri);
        const dn = opts.display_name orelse std.fs.path.basename(uri);
        const owned_dn = try self.allocator.dupe(u8, dn);
        errdefer self.allocator.free(owned_dn);
        const owned_mt = if (opts.mime_type) |mt| try self.allocator.dupe(u8, mt) else null;
        errdefer if (owned_mt) |m| self.allocator.free(m);
        const owned_an = if (opts.app_name) |an| try self.allocator.dupe(u8, an) else null;
        errdefer if (owned_an) |a| self.allocator.free(a);

        var groups = std.ArrayListUnmanaged([]const u8){};
        if (opts.groups) |gs| {
            for (gs) |g| {
                const og = try self.allocator.dupe(u8, g);
                groups.append(self.allocator, og) catch |e| {
                    self.allocator.free(og);
                    return e;
                };
            }
        }

        try self.items.insertAt(self.allocator, 0, .{
            .uri = owned_uri,
            .display_name = owned_dn,
            .mime_type = owned_mt,
            .app_name = owned_an,
            .modified = time.timestamp(),
            .visited = 1,
            .groups = groups,
            .is_private = opts.is_private,
        });
        // 超出容量时清理尾部
        while (self.items.items.len > self.max_items) {
            var old = self.items.pop();
            old.deinit(self.allocator);
        }
        self.notifyChanged();
        return true;
    }

    /// GTK4: gtk_recent_manager_remove_item
    pub fn removeItem(self: *RecentManager, uri: []const u8) bool {
        for (self.items.items, 0..) |_, idx| {
            if (std.mem.eql(u8, self.items.items[idx].uri, uri)) {
                var old = self.items.orderedRemove(idx);
                old.deinit(self.allocator);
                self.notifyChanged();
                return true;
            }
        }
        return false;
    }

    /// GTK4: gtk_recent_manager_has_item
    pub fn hasItem(self: *const RecentManager, uri: []const u8) bool {
        for (self.items.items) |it| {
            if (std.mem.eql(u8, it.uri, uri)) return true;
        }
        return false;
    }

    /// GTK4: gtk_recent_manager_lookup_item
    pub fn lookupItem(self: *const RecentManager, uri: []const u8) ?*const RecentInfo {
        for (self.items.items, 0..) |_, idx| {
            if (std.mem.eql(u8, self.items.items[idx].uri, uri)) {
                return &self.items.items[idx];
            }
        }
        return null;
    }

    /// 返回只读条目切片 (按最后访问时间排序, 最新在前)
    pub fn getItems(self: *const RecentManager) []const RecentInfo {
        return self.items.items;
    }

    /// 获取非私有条目
    pub fn getPublicItems(self: *const RecentManager, out: *std.ArrayListUnmanaged(*const RecentInfo)) void {
        for (self.items.items) |*it| {
            if (!it.is_private) {
                out.append(self.allocator, it) catch {};
            }
        }
    }

    /// 清理 age_days 天未访问的项
    pub fn purgeItems(self: *RecentManager, age_days: u32) usize {
        const cutoff = time.timestamp() - @as(i64, age_days) * 86400;
        var removed: usize = 0;
        var i: usize = self.items.items.len;
        while (i > 0) : (i -= 1) {
            const idx = i - 1;
            if (self.items.items[idx].modified < cutoff) {
                var old = self.items.orderedRemove(idx);
                old.deinit(self.allocator);
                removed += 1;
            }
        }
        if (removed > 0) self.notifyChanged();
        return removed;
    }

    /// GTK4: gtk_recent_manager_purge_items (无参数: 清理所有项)
    pub fn purgeAll(self: *RecentManager) usize {
        const n = self.items.items.len;
        for (self.items.items) |*it| {
            var tmp = it.*;
            tmp.deinit(self.allocator);
        }
        self.items.clearRetainingCapacity();
        if (n > 0) self.notifyChanged();
        return n;
    }

    pub fn setMaxItems(self: *RecentManager, n: usize) void {
        self.max_items = n;
        while (self.items.items.len > self.max_items) {
            var old = self.items.pop();
            old.deinit(self.allocator);
        }
    }

    pub fn itemCount(self: *const RecentManager) usize {
        return self.items.items.len;
    }

    fn notifyChanged(self: *RecentManager) void {
        if (self.on_changed) |cb| cb(self);
    }

    // ── 持久化 (简化格式, JSON Lines) ─────────────────────────────────────
    // 文件每行: {"uri":"...","display":"...","mime":"...","ts":12345,"v":1}

    /// 保存到指定文件 (简化 JSONL 格式)
    pub fn saveToFile(self: *RecentManager, path: []const u8) !void {
        const file = try std.fs.cwd().createFile(path, .{});
        defer file.close();
        const writer = file.writer();
        for (self.items.items) |it| {
            const mime = it.mime_type orelse "";
            const app = it.app_name orelse "";
            try writer.print(
                "{{\"uri\":\"{}\",\"display\":\"{}\",\"mime\":\"{}\",\"app\":\"{}\",\"ts\":{},\"v\":{},\"private\":{}}}\n",
                .{
                    std.zig.fmtEscapes(it.uri),
                    std.zig.fmtEscapes(it.display_name),
                    std.zig.fmtEscapes(mime),
                    std.zig.fmtEscapes(app),
                    it.modified,
                    it.visited,
                    it.is_private,
                },
            );
        }
    }

    /// 从指定文件加载 (兼容 saveToFile 格式)
    pub fn loadFromFile(self: *RecentManager, path: []const u8) !usize {
        const file = std.fs.cwd().openFile(path, .{}) catch return 0;
        defer file.close();
        const content = try file.readToEndAlloc(self.allocator, 10 * 1024 * 1024);
        defer self.allocator.free(content);
        var count: usize = 0;
        var lines = std.mem.splitScalar(u8, content, '\n');
        while (lines.next()) |line| {
            if (line.len == 0) continue;
            if (parseJsonlLine(self, line)) count += 1;
        }
        return count;
    }

    fn parseJsonlLine(self: *RecentManager, line: []const u8) bool {
        // 简单手动解析 (避免依赖 json 库)
        const uri = extractJsonStringField(line, "uri") orelse return false;
        const display = extractJsonStringField(line, "display") orelse uri;
        const mime = extractJsonStringField(line, "mime");
        const app = extractJsonStringField(line, "app");
        const ts = extractJsonIntField(line, "ts") orelse time.timestamp();
        const v: u32 = @intCast(extractJsonIntField(line, "v") orelse 1);
        const priv_field = extractJsonBoolField(line, "private") orelse false;

        const owned_uri = self.allocator.dupe(u8, uri) catch return false;
        errdefer self.allocator.free(owned_uri);
        const owned_dn = self.allocator.dupe(u8, display) catch {
            self.allocator.free(owned_uri);
            return false;
        };
        errdefer self.allocator.free(owned_dn);
        const owned_mt = if (mime) |m| if (m.len > 0) self.allocator.dupe(u8, m) catch null else null else null;
        const owned_an = if (app) |a| if (a.len > 0) self.allocator.dupe(u8, a) catch null else null else null;

        self.items.append(self.allocator, .{
            .uri = owned_uri,
            .display_name = owned_dn,
            .mime_type = owned_mt,
            .app_name = owned_an,
            .modified = ts,
            .visited = v,
            .is_private = priv_field,
        }) catch {
            if (owned_mt) |mm| self.allocator.free(mm);
            if (owned_an) |aa| self.allocator.free(aa);
            return false;
        };
        return true;
    }

    fn extractJsonStringField(line: []const u8, field: []const u8) ?[]const u8 {
        const key = "\"" ++ field ++ "\":";
        const idx = std.mem.indexOf(u8, line, key) orelse return null;
        const start = idx + key.len;
        // 跳过空白
        var i = start;
        while (i < line.len and (line[i] == ' ' or line[i] == '\t')) : (i += 1) {}
        if (i >= line.len or line[i] != '"') return null;
        i += 1;
        const val_start = i;
        while (i < line.len and line[i] != '"') : (i += 1) {
            if (line[i] == '\\' and i + 1 < line.len) i += 1; // 跳过转义
        }
        if (i >= line.len) return null;
        const raw = line[val_start..i];
        // 简单反转义 (只处理 \", \\, \/)
        var buf: [4096]u8 = undefined;
        if (raw.len > buf.len) return raw;
        var out_i: usize = 0;
        var j: usize = 0;
        while (j < raw.len) : (j += 1) {
            if (raw[j] == '\\' and j + 1 < raw.len) {
                const c = raw[j + 1];
                buf[out_i] = switch (c) {
                    '"' => '"',
                    '\\' => '\\',
                    '/' => '/',
                    'n' => '\n',
                    't' => '\t',
                    'r' => '\r',
                    else => c,
                };
                j += 1;
            } else {
                buf[out_i] = raw[j];
            }
            out_i += 1;
        }
        return buf[0..out_i];
    }

    fn extractJsonIntField(line: []const u8, field: []const u8) ?i64 {
        const key = "\"" ++ field ++ "\":";
        const idx = std.mem.indexOf(u8, line, key) orelse return null;
        const start = idx + key.len;
        var i = start;
        while (i < line.len and (line[i] == ' ' or line[i] == '\t')) : (i += 1) {}
        if (i >= line.len) return null;
        const neg = line[i] == '-';
        if (neg) i += 1;
        const num_start = i;
        while (i < line.len and std.ascii.isDigit(line[i])) : (i += 1) {}
        if (i == num_start) return null;
        const val = std.fmt.parseInt(i64, line[num_start..i], 10) catch return null;
        return if (neg) -val else val;
    }

    fn extractJsonBoolField(line: []const u8, field: []const u8) ?bool {
        const key = "\"" ++ field ++ "\":";
        const idx = std.mem.indexOf(u8, line, key) orelse return null;
        const start = idx + key.len;
        var i = start;
        while (i < line.len and (line[i] == ' ' or line[i] == '\t')) : (i += 1) {}
        if (i + 3 < line.len and std.mem.eql(u8, line[i .. i + 4], "true")) return true;
        if (i + 4 < line.len and std.mem.eql(u8, line[i .. i + 5], "false")) return false;
        return null;
    }
};
