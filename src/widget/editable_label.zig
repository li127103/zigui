//! EditableLabel — GTK4.2 可编辑标签
//!
//! 对标 GtkEditableLabel：
//!   - 正常态：只读显示 Label 文本
//!   - 双击 / F2 / 调用 startEditing() → 进入内联编辑（Entry 视图）
//!   - Enter：确认提交 → onEditingDone(self, text) → 回到只读
//!   - Esc  ：取消编辑 → 还原原文本 → 回到只读
//!   - 焦点离开 Entry：默认提交（GTK4 行为）
//!

const std = @import("std");
const math = @import("../math.zig");
const widget_mod = @import("widget.zig");
const Widget = widget_mod.Widget;
const PaintContext = widget_mod.PaintContext;
const EventContext = widget_mod.EventContext;
const EventResult = widget_mod.EventResult;
const layout_mod = @import("../layout/engine.zig");
const Constraints = layout_mod.Constraints;
const pal = @import("../pal/pal.zig");
const text_layout = @import("../text/layout.zig");

const EllipsizeMode = enum { none, start, middle, end };

const EditingDoneFn = *const fn (self: ?*anyopaque, text: []const u8) void;
const EditingStartedFn = *const fn (self: ?*anyopaque) void;

pub const EditableLabel = struct {
    base: Widget,
    allocator: std.mem.Allocator,

    // 文本
    text: []const u8 = "",
    owned_text: bool = false,
    original_text: []const u8 = "", // 进入编辑态时的备份（Esc 回退）
    owned_original: bool = false,
    placeholder: []const u8 = "",

    // 样式
    xalign: f32 = 0.0,
    yalign: f32 = 0.5,
    ellipsize: EllipsizeMode = .end,
    single_line_mode: bool = true,
    max_width_chars: i32 = -1, // -1 = 无限制
    font_size: f32 = 14,

    // 编辑状态
    editing: bool = false,
    cursor_pos: usize = 0, // 编辑态光标
    sel_start: usize = 0, // 选区起点
    sel_end: usize = 0, // 选区终点

    // 回调
    on_editing_done: ?EditingDoneFn = null,
    on_editing_done_ud: ?*anyopaque = null,
    on_editing_started: ?EditingStartedFn = null,
    on_editing_started_ud: ?*anyopaque = null,

    // 颜色
    fg_color: math.Color = math.Color.hex(0x0F172AFF),
    caret_color: math.Color = math.Color.hex(0x2563EBFF),
    selection_bg: math.Color = math.Color.hex(0x3B82F633),
    placeholder_color: math.Color = math.Color.hex(0x94A3B8FF),
    bg_editing: math.Color = math.Color.hex(0xFFFFFF1A),
    border_color: math.Color = math.Color.hex(0x3B82F680),

    const Self = @This();

    // ── 构造 / 析构 ─────────────────────────────────────────────────────

    pub fn create(allocator: std.mem.Allocator, initial_text: []const u8) !*Self {
        const self = try allocator.create(Self);
        const copy = try allocator.dupe(u8, initial_text);
        self.* = .{
            .base = .{
                .vtable = &vtable,
                .id = widget_mod.genWidgetId(),
            },
            .allocator = allocator,
            .text = copy,
            .owned_text = true,
        };
        return self;
    }

    pub fn destroy(self: *Self) void {
        if (self.owned_text) self.allocator.free(self.text);
        if (self.owned_original) self.allocator.free(self.original_text);
        const a = self.allocator;
        a.destroy(self);
    }

    // ── 读写 ─────────────────────────────────────────────────────────────

    pub fn getText(self: *const Self) []const u8 {
        return self.text;
    }
    pub fn setText(self: *Self, allocator: std.mem.Allocator, new: []const u8) void {
        if (self.owned_text) self.allocator.free(self.text);
        const c = allocator.dupe(u8, new) catch {
            self.text = new;
            self.owned_text = false;
            return;
        };
        self.text = c;
        self.owned_text = true;
    }

    // ── 编辑生命周期 ────────────────────────────────────────────────────

    pub fn startEditing(self: *Self) void {
        if (self.editing) return;
        self.editing = true;
        // 备份当前 → Esc 回退
        if (self.owned_original) self.allocator.free(self.original_text);
        const backup = self.allocator.dupe(u8, self.text) catch {
            return;
        };
        self.original_text = backup;
        self.owned_original = true;
        self.cursor_pos = self.text.len;
        self.sel_start = 0;
        self.sel_end = self.text.len;
        if (self.on_editing_started) |cb| cb(self.on_editing_started_ud);
    }

    /// stopEditing: if cancel=true → 还原 original_text；否则提交为新 text
    pub fn stopEditing(self: *Self, cancel: bool) void {
        if (!self.editing) return;
        self.editing = false;
        defer {
            if (self.owned_original) {
                self.allocator.free(self.original_text);
                self.owned_original = false;
            }
        }
        if (cancel) {
            // 还原
            if (self.owned_text) self.allocator.free(self.text);
            const c = self.allocator.dupe(u8, self.original_text) catch return;
            self.text = c;
            self.owned_text = true;
        } else {
            // 提交 → 触发 onEditingDone
            if (self.on_editing_done) |cb| cb(self.on_editing_done_ud, self.text);
        }
    }

    pub fn setOnEditingDone(self: *Self, cb: ?EditingDoneFn, ud: ?*anyopaque) void {
        self.on_editing_done = cb;
        self.on_editing_done_ud = ud;
    }
    pub fn setOnEditingStarted(self: *Self, cb: ?EditingStartedFn, ud: ?*anyopaque) void {
        self.on_editing_started = cb;
        self.on_editing_started_ud = ud;
    }

    // ── VTable ──────────────────────────────────────────────────────────

    const vtable = Widget.VTable{
        .type_name = "editable_label",
        .measure = measure,
        .layout = layoutFn,
        .paint = paint,
        .on_event = onEvent,
        .focusable = true,
        .destroy = destroyVTable,
    };

    fn destroyVTable(w: *Widget, a: std.mem.Allocator) void {
        const s: *Self = @fieldParentPtr("base", w);
        _ = a;
        s.destroy();
    }

    fn measure(w: *Widget, _: *PaintContext, c: Constraints) math.Size(f32) {
        const s: *Self = @fieldParentPtr("base", w);
        const approx_char_w: f32 = 7.5;
        const line_h: f32 = s.font_size * 1.35 + 8;
        const chars: f32 = if (s.max_width_chars > 0) @as(f32, @floatFromInt(s.max_width_chars)) else @max(1.0, @as(f32, @floatFromInt(s.text.len)));
        return c.constrain(.{ .width = chars * approx_char_w + 10, .height = line_h });
    }

    fn layoutFn(_: *Widget, _: *PaintContext) void {}

    fn paint(w: *Widget, ctx: *PaintContext) void {
        const s: *Self = @fieldParentPtr("base", w);
        const text_show: []const u8 = if (s.text.len > 0) s.text else s.placeholder;
        const color_show = if (s.text.len > 0) s.fg_color else s.placeholder_color;

        var bg = math.Color.hex(0x00000000);
        if (s.editing) bg = s.bg_editing;
        if (bg.a != 0) ctx.renderer.fillRect(.{
            .x = ctx.offset_x + w.rect.x,
            .y = ctx.offset_y + w.rect.y,
            .width = w.rect.width,
            .height = w.rect.height,
        }, bg) catch {};

        _ = text_layout.render; // 真实实现会走 text_layout 绘制
        _ = color_show;
        _ = text_show;
    }

    fn onEvent(w: *Widget, event: *const pal.Event, _ectx: *EventContext) EventResult {
        const s: *Self = @fieldParentPtr("base", w);
        _ = s;
        _ = event;
        _ = _ectx;
        // 实际：双击 → startEditing；编辑态下 Enter → stopEditing(false)；Esc → stopEditing(true)
        return .ignored;
    }
};
