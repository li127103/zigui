//! GtkSettings — GTK4 全局样式/字体/动画设置单例
//!
//! 对标 GTK4 GtkSettings：所有 gtk 相关全局设置统一存放，
//! Widget/Application/Render 等层按需读取。单例模式：`Settings.getDefault()`。
//!
//! 注：当前未引入 GSettings/dconf，字段采用直接读写 + 可选字符串键 get/set。
//!

const std = @import("std");

// ═══════════════════════════════════════════════════════════════════════════════
//  单例持有（thread-local 简化版，多线程场景由上层保证）
// ═══════════════════════════════════════════════════════════════════════════════

var _default_settings: Settings = .{};

// ═══════════════════════════════════════════════════════════════════════════════
//  GtkSettings 结构
// ═══════════════════════════════════════════════════════════════════════════════

pub const Settings = struct {
    // ── 字体 / 主题 ────────────────────────────────────────────────────────
    /// 默认 UI 字体（Pango font name，如 `Inter 12` / `Cantarell Bold 11`）
    gtk_font_name: []const u8 = "Inter 12",
    /// 主题名：`Adwaita`/`Adwaita-dark`/`HighContrast` 等
    gtk_theme_name: []const u8 = "Adwaita",
    /// 图标主题名（如 `Adwaita` / `Tela` / `Papirus`）
    gtk_icon_theme_name: []const u8 = "Adwaita",
    /// Xft DPI（1/1024 inch；常规屏幕 96 = 1.0×，192 = 2.0×）
    gtk_xft_dpi: i32 = 96 * 1024,

    // ── 视觉开关 ──────────────────────────────────────────────────────────
    /// 是否偏好深色主题（Adwaita 自动切换 dark 变体的快捷开关）
    gtk_application_prefer_dark_theme: bool = false,
    /// 对话框默认使用 HeaderBar（替代传统 ActionArea + ActionWidget）
    gtk_dialogs_use_header: bool = true,
    /// 是否启用覆盖式滚动条（Overlay scrolling；false = 常驻可见滚动条）
    gtk_overlay_scrolling: bool = true,
    /// 是否闪烁文本光标
    gtk_cursor_blink: bool = true,

    // ── 动画 / 时间阈值 ──────────────────────────────────────────────────
    /// 是否启用 UI 动画（Transition/Spinner/等过渡效果的全局开关）
    gtk_enable_animations: bool = true,
    /// 光标闪烁周期（ms，开↔关总时长）
    gtk_cursor_blink_time: i32 = 1200,
    /// 双击判定间隔（ms）
    gtk_double_click_time: i32 = 400,
    /// 双击判定距离（px）
    gtk_double_click_distance: i32 = 5,

    // ── 拖拽 / 触控时长 ───────────────────────────────────────────────────
    /// 拖拽起始阈值（鼠标移动超过该像素才认定为 drag，避免与 click 冲突）
    gtk_dnd_drag_threshold: i32 = 8,
    /// 长按触发时长（ms）
    gtk_long_press_timeout: i32 = 500,

    // ── Entry / 滚动行为默认值 ────────────────────────────────────────────
    /// Entry 点击空白区域是否把光标置于行尾
    gtk_gtk_entry_select_on_focus: bool = false, // 注：字段名对齐 GTK4 gsettings key
    /// 滚动条是否在指针靠近时自动出现（与 gtk_overlay_scrolling 配合）
    gtk_scrollbar_activate_on_single_click: bool = true,

    // ── 备用：用户自定义任意键值 ───────────────────────────────────────────
    /// 通用存储（key=字符串键；value=?*anyopaque 裸指针交由调用方管理生命周期）
    extras: std.StringHashMapUnmanaged(?*anyopaque) = .{},

    const Self = @This();

    // ── 单例入口 ──────────────────────────────────────────────────────────

    /// 获取全局默认 Settings（单例）
    pub fn getDefault() *Self {
        return &_default_settings;
    }

    /// 重置为工厂默认值（保留 extras）
    pub fn resetToDefaults(self: *Self) void {
        const saved_extras = self.extras;
        self.* = .{};
        self.extras = saved_extras;
    }

    // ── 通用 extras 键值读写 ───────────────────────────────────────────────

    /// 存自定义键值（value 可为任意不透明指针；生命周期由调用方负责）
    pub fn setExtra(self: *Self, allocator: std.mem.Allocator, key: []const u8, value: ?*anyopaque) !void {
        const gop = try self.extras.getOrPut(allocator, key);
        gop.value_ptr.* = value;
    }

    /// 取自定义键值，不存在返回 null
    pub fn getExtra(self: *const Self, key: []const u8) ?*anyopaque {
        return self.extras.get(key) orelse null;
    }

    // ── 便捷：DPI → 浮点 scale ─────────────────────────────────────────────

    /// gtk_xft_dpi → 以 96*1024 为基准的 scale factor (f32)
    pub fn getScaleFactor(self: *const Self) f32 {
        const base: f32 = @floatFromInt(96 * 1024);
        return @as(f32, @floatFromInt(self.gtk_xft_dpi)) / base;
    }

    /// 以 scale_factor (1.0/1.25/1.5/2.0 ...) 反写 gtk_xft_dpi
    pub fn setScaleFactor(self: *Self, scale: f32) void {
        const base: f32 = @floatFromInt(96 * 1024);
        self.gtk_xft_dpi = @intFromFloat(scale * base);
    }
};

// ═══════════════════════════════════════════════════════════════════════════════
//  便捷顶层函数：直接返回默认单例指针，与 GTK API `gtk_settings_get_default()` 对齐
// ═══════════════════════════════════════════════════════════════════════════════

pub fn gtk_settings_get_default() *Settings {
    return Settings.getDefault();
}
