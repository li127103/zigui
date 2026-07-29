//! GdkClipboard — GTK4 剪贴板（widget 层 GTK 命名包装）
//!
//! 底层委托 `pal/clipboard.zig` 的跨平台 OS 剪贴板（pbcopy/wl-copy/xclip …），
//! 提供 GTK4 风格 API：`readText / setText / setContent / on_content_changed`。
//!

const std = @import("std");
const pal_clipboard = @import("../pal/clipboard.zig");

const display_mod = @import("display.zig");
const GdkDisplay = display_mod.GdkDisplay;

// ═══════════════════════════════════════════════════════════════════════════════
//  GdkClipboard
// ═══════════════════════════════════════════════════════════════════════════════

pub const GdkClipboard = struct {
    /// 关联 Display（可选）；用于多显示/多 Seat 场景下区分不同剪贴板
    display: ?*const GdkDisplay = null,
    /// 内容变化回调钩子（用户代码 setText / setContent 之后立刻触发）
    on_content_changed: ?*const fn (ud: ?*anyopaque) void = null,
    on_content_changed_ud: ?*anyopaque = null,
    /// 上次 text 缓存（只读；避免读文本调用失败时再返回 null 更一致）
    last_text_cache: []const u8 = "",
    last_text_owned: bool = false, // true → 下次 set/clear 需要 free
    _cache_allocator: ?std.mem.Allocator = null,

    const Self = @This();

    // ── 单例：默认剪贴板（与 Display 无关，供便捷使用） ──────────────────────

    var _default_clip: GdkClipboard = .{};

    pub fn getDefault() *Self { return &_default_clip; }

    // ── 构造 / 析构 ────────────────────────────────────────────────────────

    pub fn initForDisplay(display: ?*const GdkDisplay) Self {
        return .{ .display = display };
    }

    pub fn deinit(self: *Self) void {
        if (self.last_text_owned and self._cache_allocator) |a| {
            a.free(self.last_text_cache);
        }
        self.* = undefined;
    }

    // ── 文本读写 ──────────────────────────────────────────────────────────

    /// 写入文本 → 系统剪贴板
    pub fn setText(self: *Self, allocator: std.mem.Allocator, str: []const u8) void {
        pal_clipboard.setText(str) catch {};
        self.updateTextCache(allocator, str);
        self.emitChanged();
    }

    /// 读取文本（调用者释放；读失败 → null）
    pub fn readText(self: *Self, allocator: std.mem.Allocator) ?[]u8 {
        const got = pal_clipboard.getText(allocator) catch return null;
        // 同步缓存
        self.updateTextCache(allocator, got);
        return got;
    }

    // ── 通用内容读写（MIME） —— 当前 text/plain 走 setText；其余类型占位 ─────

    pub const ContentProvider = struct {
        /// mime 类型数组（如 `&.{"text/plain", "text/uri-list"}`）
        mime_types: []const []const u8 = &.{},
        /// 获取某 mime 的字节；不支持返回 null
        get_bytes: *const fn (ud: ?*anyopaque, mime: []const u8) ?[]const u8,
        user_data: ?*anyopaque = null,
    };

    /// 设置内容（text/plain → 立刻写到 OS 剪贴板；其余 MIME 先存储在 provider 中）
    pub fn setContent(self: *Self, allocator: std.mem.Allocator, provider: ContentProvider) void {
        // 尝试 text/plain 立刻落盘到 OS
        for (provider.mime_types) |mt| {
            if (std.mem.eql(u8, mt, "text/plain")) {
                const bytes = provider.get_bytes(provider.user_data, mt) orelse continue;
                self.setText(allocator, bytes);
                return;
            }
        }
        // 其他 MIME：触发 changed 钩子（真实 OS 剪贴板暂不支持，先占位）
        self.emitChanged();
    }

    // ── 回调钩子 ──────────────────────────────────────────────────────────

    pub fn setOnContentChanged(self: *Self, cb: ?*const fn (ud: ?*anyopaque) void, ud: ?*anyopaque) void {
        self.on_content_changed = cb;
        self.on_content_changed_ud = ud;
    }

    fn emitChanged(self: *Self) void {
        if (self.on_content_changed) |cb| cb(self.on_content_changed_ud);
    }

    // ── 内部：缓存 text 副本，保证 readText 失败也能读取上次内容 ──────────────

    fn updateTextCache(self: *Self, allocator: std.mem.Allocator, new_text: []const u8) void {
        // free old owned
        if (self.last_text_owned and self._cache_allocator) |a| a.free(self.last_text_cache);
        const dup = allocator.dupe(u8, new_text) catch {
            self.last_text_cache = new_text;
            self.last_text_owned = false;
            return;
        };
        self.last_text_cache = dup;
        self.last_text_owned = true;
        self._cache_allocator = allocator;
    }
};

// 命名别名（与 GDK 风格一致）
pub const Clipboard = GdkClipboard;
