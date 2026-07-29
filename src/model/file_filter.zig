const std = @import("std");
const Allocator = std.mem.Allocator;

/// 自定义过滤器函数签名
pub const CustomFilterFn = *const fn (filename: []const u8, mime_type: ?[]const u8, userdata: ?*anyopaque) bool;

/// 对齐 GTK4: GtkFileFilter
/// 按 mime-type / glob pattern / suffix / custom 函数 检查文件是否通过过滤器
pub const FileFilter = struct {
    allocator: Allocator,
    /// 显示名称，例："C Source Files"
    name: ?[]const u8 = null,
    /// MIME 类型列表，例："text/plain", "image/png"
    mime_types: std.ArrayListUnmanaged([]const u8) = .empty,
    /// glob 模式列表，例："*.txt", "*.{c,h}"
    patterns: std.ArrayListUnmanaged([]const u8) = .empty,
    /// 后缀匹配列表 (简单模式, 例: ".c", ".h")
    suffixes: std.ArrayListUnmanaged([]const u8) = .empty,
    /// 自定义过滤器
    custom_fn: ?CustomFilterFn = null,
    custom_userdata: ?*anyopaque = null,

    pub fn init(allocator: Allocator, name: ?[]const u8) FileFilter {
        return .{
            .allocator = allocator,
            .name = if (name) |n| allocator.dupe(u8, n) catch null else null,
        };
    }

    pub fn deinit(self: *FileFilter) void {
        if (self.name) |n| self.allocator.free(n);
        for (self.mime_types.items) |s| self.allocator.free(s);
        for (self.patterns.items) |s| self.allocator.free(s);
        for (self.suffixes.items) |s| self.allocator.free(s);
        self.mime_types.deinit(self.allocator);
        self.patterns.deinit(self.allocator);
        self.suffixes.deinit(self.allocator);
        self.* = undefined;
    }

    pub fn setName(self: *FileFilter, name: ?[]const u8) !void {
        if (self.name) |n| self.allocator.free(n);
        self.name = if (name) |n| try self.allocator.dupe(u8, n) else null;
    }

    pub fn getName(self: *const FileFilter) ?[]const u8 {
        return self.name;
    }

    /// 添加 MIME 类型
    pub fn addMimeType(self: *FileFilter, mime: []const u8) !void {
        try self.mime_types.append(self.allocator, try self.allocator.dupe(u8, mime));
    }

    /// 添加 glob 模式 (支持 *, ?, [..], {a,b})
    pub fn addPattern(self: *FileFilter, pattern: []const u8) !void {
        try self.patterns.append(self.allocator, try self.allocator.dupe(u8, pattern));
    }

    /// 添加后缀过滤 (例如 ".c", ".txt")
    pub fn addSuffix(self: *FileFilter, suffix: []const u8) !void {
        try self.suffixes.append(self.allocator, try self.allocator.dupe(u8, suffix));
    }

    pub fn addPixbufFormats(self: *FileFilter) !void {
        try self.addMimeType("image/png");
        try self.addMimeType("image/jpeg");
        try self.addMimeType("image/gif");
        try self.addMimeType("image/bmp");
        try self.addMimeType("image/svg+xml");
        try self.addMimeType("image/webp");
        try self.addPattern("*.png");
        try self.addPattern("*.jpg");
        try self.addPattern("*.jpeg");
        try self.addPattern("*.gif");
        try self.addPattern("*.bmp");
        try self.addPattern("*.svg");
        try self.addPattern("*.webp");
    }

    /// 设置自定义过滤函数
    pub fn setCustomFilter(self: *FileFilter, cb: ?CustomFilterFn, userdata: ?*anyopaque) void {
        self.custom_fn = cb;
        self.custom_userdata = userdata;
    }

    /// GTK4: gtk_file_filter_match
    /// 判断给定文件名 / mime 类型是否匹配
    pub fn match(self: *const FileFilter, filename: []const u8, mime_type: ?[]const u8) bool {
        // 如果没有任何规则, 视为全匹配 (GTK 行为: 空 filter 匹配一切)
        if (self.mime_types.items.len == 0 and
            self.patterns.items.len == 0 and
            self.suffixes.items.len == 0 and
            self.custom_fn == null) return true;

        // mime type 匹配
        if (mime_type) |mt| {
            for (self.mime_types.items) |m| {
                if (std.mem.eql(u8, m, mt)) return true;
                // "text/*" glob 匹配
                if (m.len > 1 and m[m.len - 1] == '*' and m[m.len - 2] == '/') {
                    if (mt.len >= m.len - 1 and std.mem.eql(u8, m[0 .. m.len - 2], mt[0 .. m.len - 2]))
                        return true;
                }
            }
        }

        // glob 模式匹配
        const basename = std.fs.path.basename(filename);
        for (self.patterns.items) |p| {
            if (globMatch(p, basename)) return true;
        }

        // 后缀匹配
        for (self.suffixes.items) |suf| {
            if (basename.len >= suf.len and std.mem.eql(u8, basename[basename.len - suf.len ..], suf))
                return true;
        }

        // 自定义函数
        if (self.custom_fn) |cb| {
            if (cb(filename, mime_type, self.custom_userdata)) return true;
        }

        return false;
    }

    /// 简单 glob 匹配: 支持 * ? [abc] {a,b,c}
    pub fn globMatch(pattern: []const u8, text: []const u8) bool {
        return globMatchImpl(pattern, 0, text, 0);
    }

    fn globMatchImpl(p: []const u8, pi: usize, t: []const u8, ti: usize) bool {
        var i = pi;
        var j = ti;
        while (i < p.len) : (i += 1) {
            const c = p[i];
            switch (c) {
                '*' => {
                    // 跳过连续 *
                    while (i < p.len and p[i] == '*') : (i += 1) {}
                    if (i == p.len) return true; // 尾部 * 匹配全部
                    // 尝试所有匹配点
                    var k = j;
                    while (k <= t.len) : (k += 1) {
                        if (globMatchImpl(p, i, t, k)) return true;
                    }
                    return false;
                },
                '?' => {
                    if (j >= t.len) return false;
                    j += 1;
                },
                '[' => {
                    if (j >= t.len) return false;
                    i += 1;
                    var not = false;
                    if (i < p.len and p[i] == '!') {
                        not = true;
                        i += 1;
                    }
                    var matched = false;
                    var last: u8 = 0;
                    var in_range = false;
                    while (i < p.len and p[i] != ']') : (i += 1) {
                        if (p[i] == '-' and i + 1 < p.len and p[i + 1] != ']') {
                            in_range = true;
                            continue;
                        }
                        if (in_range) {
                            if (t[j] >= last and t[j] <= p[i]) matched = true;
                            in_range = false;
                        } else {
                            last = p[i];
                            if (t[j] == last) matched = true;
                        }
                    }
                    if (not) matched = !matched;
                    if (!matched) return false;
                    j += 1;
                },
                '{' => {
                    // 解析 {a,b,c} 分支
                    i += 1;
                    // 查找闭合 }
                    var depth: usize = 1;
                    var end = i;
                    while (end < p.len and depth > 0) : (end += 1) {
                        if (p[end] == '{') depth += 1 else if (p[end] == '}') depth -= 1;
                    }
                    if (depth != 0) return false; // 格式错误
                    // end-1 指向 }
                    const content = p[i .. end - 1];
                    // 按顶级 , 分割
                    var start: usize = 0;
                    var cur_depth: usize = 0;
                    for (content, 0..) |ch, idx| {
                        if (ch == '{') cur_depth += 1 else if (ch == '}') cur_depth -= 1 else if (ch == ',' and cur_depth == 0) {
                            const alt = content[start..idx];
                            // 合并 alt + 剩余 pattern
                            var buf: [512]u8 = undefined;
                            const alt_len = @min(alt.len, buf.len);
                            @memcpy(buf[0..alt_len], alt[0..alt_len]);
                            const rest = p[end..];
                            const rest_len = @min(rest.len, buf.len - alt_len);
                            @memcpy(buf[alt_len .. alt_len + rest_len], rest[0..rest_len]);
                            const full_alt = buf[0 .. alt_len + rest_len];
                            if (globMatchImpl(full_alt, 0, t, j)) return true;
                            start = idx + 1;
                        }
                    }
                    // 最后一个 alternative
                    const alt = content[start..];
                    var buf2: [512]u8 = undefined;
                    const alt_len2 = @min(alt.len, buf2.len);
                    @memcpy(buf2[0..alt_len2], alt[0..alt_len2]);
                    const rest2 = p[end..];
                    const rest_len2 = @min(rest2.len, buf2.len - alt_len2);
                    @memcpy(buf2[alt_len2 .. alt_len2 + rest_len2], rest2[0..rest_len2]);
                    const full_alt2 = buf2[0 .. alt_len2 + rest_len2];
                    if (globMatchImpl(full_alt2, 0, t, j)) return true;
                    return false;
                },
                '\\' => {
                    if (i + 1 < p.len) i += 1;
                    if (j >= t.len or t[j] != p[i]) return false;
                    j += 1;
                },
                else => {
                    if (j >= t.len or t[j] != c) return false;
                    j += 1;
                },
            }
        }
        return j == t.len;
    }
};
