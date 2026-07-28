//! ColorChooserDialog 控件 - 颜色选择对话框
//!
//! 提供调色板和 RGBA 滑块, 支持选择颜色。
//!
//! 使用方法:
//! ```
//! var dlg = try ColorChooserDialog.create(allocator, .{
//!     .initial_color = math.Color.hex(0x3B82F6FF),
//!     .on_color_selected = onColorSelected,
//! });
//! dlg.show();
//! ```

const std = @import("std");
const math = @import("../math.zig");
const widget_mod = @import("widget.zig");
const pal = @import("../pal/pal.zig");
const container_mod = @import("container.zig");
const label_mod = @import("label.zig");
const button_mod = @import("button.zig");
const separator_mod = @import("separator.zig");

const Widget = widget_mod.Widget;
const PaintContext = widget_mod.PaintContext;
const EventContext = widget_mod.EventContext;
const EventResult = widget_mod.EventResult;
const Container = container_mod.Container;
const Label = label_mod.Label;
const Button = button_mod.Button;
const Separator = separator_mod.Separator;
const SeparatorOrientation = separator_mod.SeparatorOrientation;

pub const ColorChooserDialog = struct {
    base: Widget,
    allocator: std.mem.Allocator,
    title: []const u8,
    visible: bool = false,
    current_color: math.Color,
    on_color_selected: ?*const fn (self: *ColorChooserDialog, color: math.Color) void = null,
    on_cancel: ?*const fn (self: *ColorChooserDialog) void = null,

    // 子控件
    content_container: ?*Container = null,
    preview_rect: ?*Container = null,

    // 样式
    overlay_color: math.Color = math.Color.hex(0x000000AA),
    bg_color: math.Color = math.Color.hex(0x1E293BFF),
    text_color: math.Color = math.Color.hex(0xF8FAFCFF),
    text_secondary: math.Color = math.Color.hex(0x94A3B8FF),
    corner_radius: f32 = 14.0,
    dialog_width: f32 = 420,
    dialog_height: f32 = 520,
    title_size: f32 = 18.0,

    // 预设颜色调色板
    const palette = [_]math.Color{
        math.Color.hex(0xEF4444FF), // red
        math.Color.hex(0xF97316FF), // orange
        math.Color.hex(0xEAB308FF), // yellow
        math.Color.hex(0x22C55EFF), // green
        math.Color.hex(0x06B6D4FF), // cyan
        math.Color.hex(0x3B82F6FF), // blue
        math.Color.hex(0x8B5CF6FF), // purple
        math.Color.hex(0xEC4899FF), // pink
        math.Color.hex(0xFFFFFFFF), // white
        math.Color.hex(0xD1D5DBFF), // gray 300
        math.Color.hex(0x6B7280FF), // gray 500
        math.Color.hex(0x1F2937FF), // gray 800
        math.Color.hex(0x000000FF), // black
        math.Color.hex(0x7C2D12FF), // brown
        math.Color.hex(0x065F46FF), // teal
        math.Color.hex(0x1E3A8AFF), // indigo
        math.Color.hex(0xFCA5A5FF), // red 300
        math.Color.hex(0xFDBA74FF), // orange 300
        math.Color.hex(0xFDE047FF), // yellow 300
        math.Color.hex(0x86EFACFF), // green 300
        math.Color.hex(0x67E8F9FF), // cyan 300
        math.Color.hex(0x93C5FDFF), // blue 300
        math.Color.hex(0xC4B5FDFF), // purple 300
        math.Color.hex(0xF9A8D4FF), // pink 300
    };

    const Self = @This();

    pub fn create(allocator: std.mem.Allocator, opts: struct {
        title: []const u8 = "选择颜色",
        initial_color: math.Color = math.Color.hex(0x3B82F6FF),
        on_color_selected: ?*const fn (self: *ColorChooserDialog, color: math.Color) void = null,
        on_cancel: ?*const fn (self: *ColorChooserDialog) void = null,
    }) !*ColorChooserDialog {
        const self = try allocator.create(ColorChooserDialog);
        self.* = .{
            .base = .{
                .vtable = &vtable,
                .id = widget_mod.genWidgetId(),
            },
            .allocator = allocator,
            .title = opts.title,
            .current_color = opts.initial_color,
            .on_color_selected = opts.on_color_selected,
            .on_cancel = opts.on_cancel,
        };
        try self.buildUI();
        return self;
    }

    pub fn destroy(self: *Self, allocator: std.mem.Allocator) void {
        self.base.background.deinit(allocator);
        if (self.content_container) |cc| {
            cc.base.vtable.destroy(&cc.base, allocator);
        }
        self.base.children.deinit(allocator);
        allocator.destroy(self);
    }

    pub fn show(self: *Self) void {
        self.visible = true;
        self.base.markDirty();
        self.updatePreview();
    }

    pub fn hide(self: *Self) void {
        self.visible = false;
        self.base.markDirty();
    }

    fn buildUI(self: *Self) !void {
        const alloc = self.allocator;

        // 主内容容器
        const content = try Container.create(alloc, .{
            .direction = .column,
            .bg_color = self.bg_color,
            .corner_radius = self.corner_radius,
            .padding = .{ .left = 16, .right = 16, .top = 16, .bottom = 16 },
            .gap = .{ .width = 0, .height = 12 },
        });
        self.content_container = content;
        try self.base.addChild(alloc, &content.base);

        // 标题
        const title_lbl = try Label.create(alloc, self.title, .{
            .font_size = self.title_size,
            .color = self.text_color,
        });
        try content.base.addChild(alloc, &title_lbl.base);

        // 颜色预览
        const preview = try Container.create(alloc, .{
            .direction = .row,
            .bg_color = self.current_color,
            .corner_radius = 8,
            .padding = .{ .left = 0, .right = 0, .top = 0, .bottom = 0 },
        });
        preview.base.layout_style.height = .{ .px = 48 };
        try content.base.addChild(alloc, &preview.base);
        self.preview_rect = preview;

        // 分隔线
        const sep1 = try Separator.create(alloc, .{ .orientation = .horizontal });
        try content.base.addChild(alloc, &sep1.base);

        // 调色板标题
        const pal_title = try Label.create(alloc, "调色板", .{
            .font_size = 13,
            .color = self.text_secondary,
        });
        try content.base.addChild(alloc, &pal_title.base);

        // 调色板 (4行 x 6列 = 24色)
        const palette_grid = try Container.create(alloc, .{
            .direction = .column,
            .gap = .{ .width = 0, .height = 6 },
        });
        try content.base.addChild(alloc, &palette_grid.base);

        const cols: usize = 6;
        const rows = palette.len / cols;

        var row_idx: usize = 0;
        while (row_idx < rows) : (row_idx += 1) {
            const row = try Container.create(alloc, .{
                .direction = .row,
                .gap = .{ .width = 6, .height = 0 },
            });
            try palette_grid.base.addChild(alloc, &row.base);

            var col_idx: usize = 0;
            while (col_idx < cols) : (col_idx += 1) {
                const idx = row_idx * cols + col_idx;
                if (idx >= palette.len) break;

                const color_btn = try createPaletteButton(alloc, palette[idx], idx);
                try row.base.addChild(alloc, &color_btn.base);
                color_btn.base.user_data = self;
            }
        }

        // 分隔线
        const sep2 = try Separator.create(alloc, .{ .orientation = .horizontal });
        try content.base.addChild(alloc, &sep2.base);

        // 当前颜色 hex 显示
        const hex_row = try Container.create(alloc, .{
            .direction = .row,
            .gap = .{ .width = 8, .height = 0 },
        });
        try content.base.addChild(alloc, &hex_row.base);

        const hex_lbl = try Label.create(alloc, "HEX:", .{
            .font_size = 13,
            .color = self.text_secondary,
        });
        try hex_row.base.addChild(alloc, &hex_lbl.base);

        // 按钮行
        const btn_row = try Container.create(alloc, .{
            .direction = .row,
            .gap = .{ .width = 8, .height = 0 },
        });
        try content.base.addChild(alloc, &btn_row.base);

        const cancel_btn = try Button.create(alloc, "取消", .{});
        try btn_row.base.addChild(alloc, &cancel_btn.base);
        cancel_btn.on_click = onCancelClick;
        cancel_btn.base.user_data = self;

        const ok_btn = try Button.create(alloc, "确定", .{});
        try btn_row.base.addChild(alloc, &ok_btn.base);
        ok_btn.on_click = onOkClick;
        ok_btn.base.user_data = self;
    }

    fn createPaletteButton(alloc: std.mem.Allocator, color: math.Color, idx: usize) !*Button {
        _ = idx;
        const btn = try Button.create(alloc, "", .{
            .bg_color = color,
            .bg_hover = color,
            .bg_pressed = color,
            .corner_radius = 4,
            .padding_h = 0,
            .padding_v = 0,
        });
        btn.base.layout_style.width = .{ .px = 40 };
        btn.base.layout_style.height = .{ .px = 40 };
        btn.on_click = onPaletteButtonClick;
        return btn;
    }

    fn onPaletteButtonClick(btn: *Button) void {
        const self: *Self = @ptrCast(@alignCast(btn.base.user_data orelse return));
        self.current_color = btn.bg_color;
        self.updatePreview();
    }

    fn updatePreview(self: *Self) void {
        if (self.preview_rect) |pr| {
            pr.base.background.bg = .{ .color = self.current_color };
        }
        self.base.markDirty();
    }

    fn onCancelClick(btn: *Button) void {
        const self: *Self = @ptrCast(@alignCast(btn.base.user_data orelse return));
        self.hide();
        if (self.on_cancel) |cb| cb(self);
    }

    fn onOkClick(btn: *Button) void {
        const self: *Self = @ptrCast(@alignCast(btn.base.user_data orelse return));
        self.hide();
        if (self.on_color_selected) |cb| cb(self, self.current_color);
    }

    // ── VTable ──────────────────────────────────────────────────────────────

    const vtable = Widget.VTable{
        .type_name = "color_chooser_dialog",
        .measure = measure,
        .paint = paint,
        .on_event = onEvent,
        .focusable = false,
        .destroy = destroyVTable,
    };

    fn destroyVTable(w: *Widget, allocator: std.mem.Allocator) void {
        const self: *Self = @fieldParentPtr("base", w);
        self.destroy(allocator);
    }

    fn measure(w: *Widget, ctx: *PaintContext, constraints: @import("../layout/engine.zig").Constraints) math.Size(f32) {
        _ = w;
        _ = ctx;
        return .{ .width = constraints.max_width, .height = constraints.max_height };
    }

    fn paint(w: *Widget, ctx: *PaintContext) void {
        const self: *Self = @fieldParentPtr("base", w);
        if (!self.visible) return;

        const rect = w.rect;

        // 半透明遮罩
        ctx.renderer.fillRect(rect, self.overlay_color) catch {};

        // 居中计算对话框位置
        const dl_w = self.dialog_width;
        const dl_h = self.dialog_height;
        const dl_x = rect.x + (rect.width - dl_w) / 2;
        const dl_y = rect.y + (rect.height - dl_h) / 2;

        // 设置内容容器的位置和尺寸
        if (self.content_container) |cc| {
            cc.base.rect = .{ .x = dl_x, .y = dl_y, .width = dl_w, .height = dl_h };
            cc.base.vtable.paint(&cc.base, ctx);
        }
    }

    fn onEvent(w: *Widget, event: *const pal.Event, ectx: *EventContext) EventResult {
        const self: *Self = @fieldParentPtr("base", w);
        if (!self.visible) return .ignored;

        // 先让子控件处理事件
        if (self.content_container) |cc| {
            if (cc.base.vtable.on_event) |ev_fn| {
                const result = ev_fn(&cc.base, event, ectx);
                if (result == .handled) return .handled;
            }
        }

        // ESC 关闭
        if (event.* == .key and event.key.state == .pressed and event.key.key == .escape) {
            self.hide();
            if (self.on_cancel) |cb| cb(self);
            return .handled;
        }

        return .handled;
    }
};
