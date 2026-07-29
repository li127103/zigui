//! MediaFile — GTK4 GtkMediaFile（从文件/URI 加载 MediaStream）
//!
//! MediaStream 子类：首字段 `stream: MediaStream` → @ptrCast 可转为 MediaStream。
//! 通过 `setFilename` / `setUri` 加载；占位：`backend_state` 记录后端加载流程状态。
//!

const std = @import("std");
const ms_mod = @import("media_stream.zig");

pub const MediaStream = ms_mod.MediaStream;

const BackendState = enum(u3) {
    closed,
    open,
    loading,
    ready,
    failed,
};

pub const MediaFile = struct {
    stream: MediaStream,

    file_path: ?[]const u8 = null,
    owned_path: bool = false,

    uri: ?[]const u8 = null,
    owned_uri: bool = false,

    backend_state: BackendState = .closed,

    const Self = @This();

    // ── 构造 / 析构 ───────────────────────────────────────────────────────

    pub fn create(allocator: std.mem.Allocator) !*Self {
        const self = try allocator.create(Self);
        self.* = .{ .stream = .{ .allocator = allocator } };
        return self;
    }

    pub fn destroy(self: *Self) void {
        const a = self.stream.allocator;
        self.clear();
        // MediaStream 内部字段清理
        if (self.stream.error_msg) |e| if (self.stream.owned_error_msg) a.free(e);
        self.stream.error_msg = null;
        a.destroy(self);
    }

    pub fn asMediaStream(self: *Self) *MediaStream {
        return &self.stream;
    }

    // ── 路径设置 ──────────────────────────────────────────────────────────

    pub fn setFilename(self: *Self, allocator: std.mem.Allocator, path: []const u8) void {
        self.clear();
        const copy = allocator.dupe(u8, path) catch {
            self.stream.setError("alloc failed");
            self.backend_state = .failed;
            return;
        };
        self.file_path = copy;
        self.owned_path = true;
        self.tryOpen();
    }

    pub fn setUri(self: *Self, allocator: std.mem.Allocator, uri: []const u8) void {
        self.clear();
        const copy = allocator.dupe(u8, uri) catch {
            self.stream.setError("alloc failed");
            self.backend_state = .failed;
            return;
        };
        self.uri = copy;
        self.owned_uri = true;
        self.tryOpen();
    }

    pub fn clear(self: *Self) void {
        const a = self.stream.allocator;
        // stream 重置为初始态
        self.stream.stop();
        self.stream.setPrepared(false);
        self.stream.setDuration(-1);
        if (self.stream.error_msg) |e| if (self.stream.owned_error_msg) a.free(e);
        self.stream.error_msg = null;

        if (self.file_path) |p| if (self.owned_path) a.free(p);
        self.file_path = null;
        self.owned_path = false;

        if (self.uri) |u| if (self.owned_uri) a.free(u);
        self.uri = null;
        self.owned_uri = false;

        self.backend_state = .closed;
    }

    pub fn getFilename(self: *const Self) ?[]const u8 {
        return self.file_path;
    }
    pub fn getUri(self: *const Self) ?[]const u8 {
        return self.uri;
    }

    // ── 打开占位 ──────────────────────────────────────────────────────────

    /// 占位解析：真实实现应调用 gstreamer / ffmpeg 后端。
    /// 这里仅根据字符串是否合法切换状态并给出合理默认。
    fn tryOpen(self: *Self) void {
        self.backend_state = .loading;

        const has_something = (self.file_path != null) or (self.uri != null);
        if (!has_something) {
            self.backend_state = .failed;
            self.stream.setError("no filename or uri set");
            return;
        }

        // URI 合法性占位
        if (self.uri) |u| {
            if (u.len < 5 or !std.mem.containsAtLeast(u8, u, 1, "://")) {
                self.backend_state = .failed;
                self.stream.setError("invalid uri");
                return;
            }
        }

        // 文件路径占位：若路径为空，失败
        if (self.file_path) |p| {
            if (p.len == 0) {
                self.backend_state = .failed;
                self.stream.setError("empty filename");
                return;
            }
        }

        // 模拟就绪
        self.backend_state = .ready;
        self.stream.has_audio = true;
        self.stream.has_video = true;
        self.stream.seekable = true;
        self.stream.setDuration(60 * 1_000_000); // 默认 60 秒占位（UI 可渲染）
        self.stream.setPrepared(true);
    }
};
