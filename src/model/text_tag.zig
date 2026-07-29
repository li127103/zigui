//! TextTag + TextTagTable - GTK4 GtkTextTag / GtkTextTagTable 风格富文本标签
//!
//! GtkTextTag 是应用到文本区域 (TextBuffer) 的样式标签，支持：
//! - 基本样式: 前景色/背景色/下划线/删除线/斜体/粗体/字号/字体
//! - 缩进与对齐: indent / justification / left_margin / right_margin / pixels_above_lines
//! - 特殊属性: 可编辑性(editable) / 可选择性(editable) / 超链接(hyperlink)
//! - 包裹模式: wrap_mode / stretch
//!
//! TextTagTable 管理多个 TextTag 集合 (按名称查找、唯一性检查、标签添加/移除回调)
//!
//! 使用方式：
//! 1. 创建 TextTagTable，添加若干命名 TextTag
//! 2. TextBuffer.applyTagByName(name, start, end) 将标签应用到字符范围
//! 3. 渲染阶段根据每个字符的激活标签组合应用样式

const std = @import("std");
const Allocator = std.mem.Allocator;
const math = @import("../math.zig");
const Color = math.Color;

/// GTK4: GtkUnderline
pub const Underline = enum {
    none,
    single,
    double_,
    low,
    /// GTK_UNDERLINE_ERROR —— 波浪下划线 (拼写错误提示)
    error_line,
};

/// GTK4: GtkJustification
pub const Justification = enum {
    left,
    right,
    center,
    fill,
};

/// GTK4: GtkWrapMode
pub const WrapMode = enum {
    none,
    word,
    char,
    word_char,
};

/// GTK4: GtkTextTag —— 应用到文本范围的样式标签
pub const TextTag = struct {
    allocator: Allocator,
    /// 标签名称 (在 Table 中唯一)
    name: []const u8,
    /// 标签优先级 (在 Table 中设置; 数值高覆盖数值低)
    priority: i32 = 0,

    // ── 样式属性 (每个字段都用 Optional: null 表示不修改该属性) ──

    /// 文本颜色 (foreground / foreground_rgba)
    foreground: ?Color = null,
    /// 背景色 (background / background_rgba)
    background: ?Color = null,
    /// 粗体
    weight_bold: ?bool = null,
    /// 斜体
    style_italic: ?bool = null,
    /// 下划线
    underline: ?Underline = null,
    /// 下划线颜色 (null = 同前景色)
    underline_color: ?Color = null,
    /// 删除线
    strikethrough: ?bool = null,
    /// 删除线颜色
    strikethrough_color: ?Color = null,
    /// 字号 (px)
    font_size: ?f32 = null,
    /// 字体名 (例如 "Sans", "Monospace")
    font_family: ?[]const u8 = null,
    /// 字间距 (px)
    letter_spacing: ?f32 = null,
    /// 行高倍数 (1.0 = 正常)
    line_height: ?f32 = null,

    // 段落级别属性
    /// 对齐方式
    justification: ?Justification = null,
    /// 左缩进 (px)
    left_margin: ?f32 = null,
    /// 右缩进 (px)
    right_margin: ?f32 = null,
    /// 首行缩进 (px)
    indent: ?f32 = null,
    /// 段前间距 (px)
    pixels_above_lines: ?f32 = null,
    /// 段后间距 (px)
    pixels_below_lines: ?f32 = null,
    /// 行内间距 (px)
    pixels_inside_wrap: ?f32 = null,

    // 行为属性
    /// 该范围文本是否可编辑
    editable: ?bool = null,
    /// 该范围文本是否可选择
    selectable: ?bool = null,
    /// 超链接 URI (非 null 表示可点击链接)
    hyperlink_uri: ?[]const u8 = null,
    /// 包裹模式
    wrap_mode: ?WrapMode = null,

    /// 回调: 当标签被添加到 Table 时
    on_added: ?*const fn (self: *TextTag, table: *TextTagTable) void = null,
    /// 回调: 当标签从 Table 移除时
    on_removed: ?*const fn (self: *TextTag, table: *TextTagTable) void = null,
    /// 回调: 标签属性被修改时
    on_changed: ?*const fn (self: *TextTag, size_changed: bool) void = null,

    pub fn init(allocator: Allocator, name: []const u8, opts: struct {
        foreground: ?Color = null,
        background: ?Color = null,
        weight_bold: ?bool = null,
        style_italic: ?bool = null,
        underline: ?Underline = null,
        underline_color: ?Color = null,
        strikethrough: ?bool = null,
        strikethrough_color: ?Color = null,
        font_size: ?f32 = null,
        font_family: ?[]const u8 = null,
        letter_spacing: ?f32 = null,
        line_height: ?f32 = null,
        justification: ?Justification = null,
        left_margin: ?f32 = null,
        right_margin: ?f32 = null,
        indent: ?f32 = null,
        pixels_above_lines: ?f32 = null,
        pixels_below_lines: ?f32 = null,
        pixels_inside_wrap: ?f32 = null,
        editable: ?bool = null,
        selectable: ?bool = null,
        hyperlink_uri: ?[]const u8 = null,
        wrap_mode: ?WrapMode = null,
    }) !TextTag {
        const owned_name = try allocator.dupe(u8, name);
        errdefer allocator.free(owned_name);
        const owned_ff = if (opts.font_family) |ff| try allocator.dupe(u8, ff) else null;
        errdefer if (owned_ff) |x| allocator.free(x);
        const owned_uri = if (opts.hyperlink_uri) |u| try allocator.dupe(u8, u) else null;
        errdefer if (owned_uri) |x| allocator.free(x);

        return .{
            .allocator = allocator,
            .name = owned_name,
            .foreground = opts.foreground,
            .background = opts.background,
            .weight_bold = opts.weight_bold,
            .style_italic = opts.style_italic,
            .underline = opts.underline,
            .underline_color = opts.underline_color,
            .strikethrough = opts.strikethrough,
            .strikethrough_color = opts.strikethrough_color,
            .font_size = opts.font_size,
            .font_family = owned_ff,
            .letter_spacing = opts.letter_spacing,
            .line_height = opts.line_height,
            .justification = opts.justification,
            .left_margin = opts.left_margin,
            .right_margin = opts.right_margin,
            .indent = opts.indent,
            .pixels_above_lines = opts.pixels_above_lines,
            .pixels_below_lines = opts.pixels_below_lines,
            .pixels_inside_wrap = opts.pixels_inside_wrap,
            .editable = opts.editable,
            .selectable = opts.selectable,
            .hyperlink_uri = owned_uri,
            .wrap_mode = opts.wrap_mode,
        };
    }

    pub fn deinit(self: *TextTag) void {
        self.allocator.free(self.name);
        if (self.font_family) |ff| self.allocator.free(ff);
        if (self.hyperlink_uri) |u| self.allocator.free(u);
        self.* = undefined;
    }

    /// 修改属性时调用; 触发 on_changed
    pub fn notifyChanged(self: *TextTag, size_changed: bool) void {
        if (self.on_changed) |cb| cb(self, size_changed);
    }

    /// GTK4: gtk_text_tag_event —— 当该标签范围内发生事件时调用
    /// (简化版: 只返回是否应被作为链接处理)
    pub fn handleEvent(self: *const TextTag, event_type: enum { mouse_over, mouse_out, click }, uri_out: ?*[]const u8) bool {
        _ = event_type;
        if (self.hyperlink_uri) |u| {
            if (uri_out) |out| out.* = u;
            return true;
        }
        return false;
    }

    // ── 常用预设快速构造器 ────────────────────────────────────────────────

    /// 构造 "bold" 标签
    pub fn newBold(allocator: Allocator) !TextTag {
        return init(allocator, "bold", .{ .weight_bold = true });
    }
    /// 构造 "italic" 标签
    pub fn newItalic(allocator: Allocator) !TextTag {
        return init(allocator, "italic", .{ .style_italic = true });
    }
    /// 构造 "underline" 标签
    pub fn newUnderline(allocator: Allocator) !TextTag {
        return init(allocator, "underline", .{ .underline = .single });
    }
    /// 构造 "strikethrough" 标签
    pub fn newStrikethrough(allocator: Allocator) !TextTag {
        return init(allocator, "strikethrough", .{ .strikethrough = true });
    }
    /// 构造彩色前景标签
    pub fn newForeground(allocator: Allocator, name: []const u8, color: Color) !TextTag {
        return init(allocator, name, .{ .foreground = color });
    }
    /// 构造超链接标签
    pub fn newLink(allocator: Allocator, uri: []const u8) !TextTag {
        return init(allocator, "link", .{
            .foreground = Color.hex(0x3B82F6FF),
            .underline = .single,
            .hyperlink_uri = uri,
        });
    }
    /// 构造标题标签 (加大号字 + 粗体)
    pub fn newHeading(allocator: Allocator, level: u8) !TextTag {
        const buf: [8]u8 = undefined;
        _ = buf;
        const size: f32 = switch (level) {
            1 => 32.0,
            2 => 26.0,
            3 => 22.0,
            4 => 19.0,
            5 => 17.0,
            else => 15.0,
        };
        const name = try std.fmt.allocPrint(allocator, "heading{d}", .{level});
        defer allocator.free(name);
        return init(allocator, name, .{
            .weight_bold = true,
            .font_size = size,
            .pixels_above_lines = 8.0,
            .pixels_below_lines = 4.0,
        });
    }
};

/// GTK4: GtkTextTagTable —— 管理若干 TextTag 的集合 (名称唯一)
pub const TextTagTable = struct {
    allocator: Allocator,
    tags: std.ArrayListUnmanaged(*TextTag) = .empty,
    /// 变化时回调 (可选)
    on_tag_changed: ?*const fn (self: *TextTagTable, tag: *TextTag, size_changed: bool) void = null,
    on_tag_added: ?*const fn (self: *TextTagTable, tag: *TextTag) void = null,
    on_tag_removed: ?*const fn (self: *TextTagTable, tag: *TextTag) void = null,

    pub fn init(allocator: Allocator) TextTagTable {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *TextTagTable) void {
        for (self.tags.items) |t| {
            t.deinit();
            self.allocator.destroy(t);
        }
        self.tags.deinit(self.allocator);
        self.* = undefined;
    }

    /// GTK4: gtk_text_tag_table_add —— 添加标签; 返回 false 表示重名失败
    pub fn add(self: *TextTagTable, tag: *TextTag) bool {
        // 名称唯一
        for (self.tags.items) |t| {
            if (std.mem.eql(u8, t.name, tag.name)) return false;
        }
        self.tags.append(self.allocator, tag) catch return false;
        tag.priority = @as(i32, @intCast(self.tags.items.len - 1));
        if (tag.on_added) |cb| cb(tag, self);
        if (self.on_tag_added) |cb| cb(self, tag);
        return true;
    }

    /// GTK4: gtk_text_tag_table_remove —— 按指针移除
    pub fn remove(self: *TextTagTable, tag: *TextTag) bool {
        for (self.tags.items, 0..) |t, i| {
            if (t == tag) {
                _ = self.tags.orderedRemove(i);
                if (tag.on_removed) |cb| cb(tag, self);
                if (self.on_tag_removed) |cb| cb(self, tag);
                return true;
            }
        }
        return false;
    }

    /// GTK4: gtk_text_tag_table_lookup —— 按名称查找
    pub fn lookup(self: *const TextTagTable, name: []const u8) ?*TextTag {
        for (self.tags.items) |t| {
            if (std.mem.eql(u8, t.name, name)) return t;
        }
        return null;
    }

    /// GTK4: gtk_text_tag_table_get_size —— 标签数量
    pub fn size(self: *const TextTagTable) usize {
        return self.tags.items.len;
    }

    /// 按索引获取
    pub fn getTagAt(self: *const TextTagTable, idx: usize) ?*TextTag {
        if (idx >= self.tags.items.len) return null;
        return self.tags.items[idx];
    }

    /// GTK4: gtk_text_tag_table_foreach —— 遍历每个标签
    pub fn forEach(self: *const TextTagTable, ctx: anytype, cb: *const fn (ctx2: @TypeOf(ctx), tag: *TextTag) bool) void {
        for (self.tags.items) |t| {
            if (!cb(ctx, t)) break;
        }
    }

    /// 便捷: 创建 + 添加 + 返回
    pub fn createAndAdd(self: *TextTagTable, name: []const u8, opts: anytype) !?*TextTag {
        const tag = try self.allocator.create(TextTag);
        tag.* = try TextTag.init(self.allocator, name, opts);
        if (!self.add(tag)) {
            tag.deinit();
            self.allocator.destroy(tag);
            return null;
        }
        return tag;
    }
};
