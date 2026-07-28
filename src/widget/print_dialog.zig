//! PrintDialog 控件 - 打印对话框
//!
//! 打印参数配置对话框，支持选择打印机、份数、页面范围、
//! 纸张方向、边距等设置。
//!
//! 使用方法:
//! ```
//! var dlg = try PrintDialog.create(allocator, .{
//!     .on_print = onPrint,
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
const text_input_mod = @import("text_input.zig");
const combo_box_mod = @import("combo_box.zig");
const checkbox_mod = @import("checkbox.zig");
const spin_button_mod = @import("spin_button.zig");
const separator_mod = @import("separator.zig");
const scroll_view_mod = @import("scroll_view.zig");
const layout_mod = @import("../layout/engine.zig");

const Widget = widget_mod.Widget;
const PaintContext = widget_mod.PaintContext;
const EventContext = widget_mod.EventContext;
const EventResult = widget_mod.EventResult;

const Container = container_mod.Container;
const Label = label_mod.Label;
const Button = button_mod.Button;
const TextInput = text_input_mod.TextInput;
const ComboBox = combo_box_mod.ComboBox;
const Checkbox = checkbox_mod.Checkbox;
const Separator = separator_mod.Separator;
const ScrollView = scroll_view_mod.ScrollView;

pub const PrintSettings = struct {
    printer_name: []const u8 = "",
    num_copies: u32 = 1,
    page_range_all: bool = true,
    page_range_from: u32 = 1,
    page_range_to: u32 = 1,
    orientation: enum { portrait, landscape } = .portrait,
    paper_size: enum { a4, letter, legal, a3, a5 } = .a4,
    color_mode: enum { color, grayscale } = .color,
    duplex: enum { none, long_edge, short_edge } = .none,
    margin_top: f32 = 25.4,
    margin_bottom: f32 = 25.4,
    margin_left: f32 = 25.4,
    margin_right: f32 = 25.4,
    collate: bool = true,
    reverse: bool = false,
};

pub const PrintDialog = struct {
    base: Widget,
    allocator: std.mem.Allocator,
    visible: bool = false,
    settings: PrintSettings = .{},
    on_print: ?*const fn (self: *PrintDialog, settings: *const PrintSettings) void = null,
    on_cancel: ?*const fn (self: *PrintDialog) void = null,

    content_container: ?*Container = null,
    copies_spin: ?*TextInput = null,
    range_all_check: ?*Checkbox = null,
    range_custom_check: ?*Checkbox = null,
    range_from_input: ?*TextInput = null,
    range_to_input: ?*TextInput = null,
    orientation_combo: ?*ComboBox = null,
    paper_combo: ?*ComboBox = null,
    color_combo: ?*ComboBox = null,
    duplex_combo: ?*ComboBox = null,
    collate_check: ?*Checkbox = null,
    reverse_check: ?*Checkbox = null,

    overlay_color: math.Color = math.Color.hex(0x000000AA),
    bg_color: math.Color = math.Color.hex(0x1E293BFF),
    text_color: math.Color = math.Color.hex(0xF8FAFCFF),
    text_secondary: math.Color = math.Color.hex(0x94A3B8FF),
    corner_radius: f32 = 14.0,
    dialog_width: f32 = 560,
    dialog_height: f32 = 520,
    title_size: f32 = 18.0,

    const Self = @This();

    pub fn create(allocator: std.mem.Allocator, opts: struct {
        title: []const u8 = "打印",
        settings: PrintSettings = .{},
        on_print: ?*const fn (self: *PrintDialog, settings: *const PrintSettings) void = null,
        on_cancel: ?*const fn (self: *PrintDialog) void = null,
    }) !*PrintDialog {
        const self = try allocator.create(PrintDialog);
        self.* = .{
            .base = .{
                .vtable = &vtable,
                .id = widget_mod.genWidgetId(),
            },
            .allocator = allocator,
            .settings = opts.settings,
            .on_print = opts.on_print,
            .on_cancel = opts.on_cancel,
        };
        try self.buildUI(opts.title);
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
    }

    pub fn hide(self: *Self) void {
        self.visible = false;
        self.base.markDirty();
    }

    fn buildUI(self: *Self, title: []const u8) !void {
        const alloc = self.allocator;

        const content = try Container.create(alloc, .{
            .direction = .column,
            .bg_color = self.bg_color,
            .corner_radius = self.corner_radius,
            .padding = .{ .left = 20, .right = 20, .top = 20, .bottom = 20 },
            .gap = .{ .width = 0, .height = 14 },
        });
        self.content_container = content;
        try self.base.addChild(alloc, &content.base);

        const title_lbl = try Label.create(alloc, title, .{
            .font_size = self.title_size,
            .color = self.text_color,
        });
        try content.base.addChild(alloc, &title_lbl.base);

        const sv = try ScrollView.create(alloc, .{
            .width = 520,
            .height = 380,
        });
        try content.base.addChild(alloc, &sv.base);

        const inner = try Container.create(alloc, .{
            .direction = .column,
            .gap = .{ .width = 0, .height = 16 },
            .padding = .{ .left = 4, .right = 4, .top = 4, .bottom = 4 },
        });
        try sv.base.addChild(alloc, &inner.base);

        // 打印机
        const printer_row = try self.createLabelRow(alloc, "打印机:");
        try inner.base.addChild(alloc, &printer_row.base);

        const printer_combo = try ComboBox.create(alloc, .{
            .items = &.{"默认打印机"},
        });
        try printer_row.base.addChild(alloc, &printer_combo.base);
        printer_combo.base.layout_style.flex_grow = 1;

        try inner.base.addChild(alloc, &(try Separator.create(alloc, .{ .orientation = .horizontal })).base);

        // 份数
        const copies_row = try self.createLabelRow(alloc, "份数:");
        try inner.base.addChild(alloc, &copies_row.base);

        const copies = try TextInput.create(alloc, .{
            .placeholder = "1",
            .initial_text = "1",
        });
        try copies_row.base.addChild(alloc, &copies.base);
        copies.base.layout_style.flex_grow = 1;
        self.copies_spin = copies;

        const collate = try Checkbox.create(alloc, "自动分页", .{ .checked = true });
        try inner.base.addChild(alloc, &collate.base);
        self.collate_check = collate;

        const reverse = try Checkbox.create(alloc, "逆序打印", .{});
        try inner.base.addChild(alloc, &reverse.base);
        self.reverse_check = reverse;

        try inner.base.addChild(alloc, &(try Separator.create(alloc, .{ .orientation = .horizontal })).base);

        // 页面范围
        const range_lbl = try Label.create(alloc, "页面范围:", .{
            .font_size = 13,
            .color = self.text_color,
        });
        try inner.base.addChild(alloc, &range_lbl.base);

        const range_all_check = try Checkbox.create(alloc, "全部", .{ .checked = true });
        try inner.base.addChild(alloc, &range_all_check.base);
        self.range_all_check = range_all_check;
        range_all_check.on_toggle = onRangeAllToggle;
        range_all_check.base.user_data = self;

        const range_custom_check = try Checkbox.create(alloc, "页码范围:", .{});
        try inner.base.addChild(alloc, &range_custom_check.base);
        self.range_custom_check = range_custom_check;
        range_custom_check.on_toggle = onRangeCustomToggle;
        range_custom_check.base.user_data = self;

        const range_row = try Container.create(alloc, .{
            .direction = .row,
            .gap = .{ .width = 8, .height = 0 },
            .padding = .{ .left = 24, .right = 0, .top = 0, .bottom = 0 },
        });
        try inner.base.addChild(alloc, &range_row.base);

        const from_lbl = try Label.create(alloc, "从:", .{
            .font_size = 12,
            .color = self.text_secondary,
        });
        try range_row.base.addChild(alloc, &from_lbl.base);

        const from_input = try TextInput.create(alloc, .{ .placeholder = "1" });
        try range_row.base.addChild(alloc, &from_input.base);
        from_input.base.layout_style.flex_grow = 1;
        self.range_from_input = from_input;

        const to_lbl = try Label.create(alloc, "到:", .{
            .font_size = 12,
            .color = self.text_secondary,
        });
        try range_row.base.addChild(alloc, &to_lbl.base);

        const to_input = try TextInput.create(alloc, .{ .placeholder = "1" });
        try range_row.base.addChild(alloc, &to_input.base);
        to_input.base.layout_style.flex_grow = 1;
        self.range_to_input = to_input;

        try inner.base.addChild(alloc, &(try Separator.create(alloc, .{ .orientation = .horizontal })).base);

        // 方向和纸张
        const orient_row = try self.createLabelRow(alloc, "方向:");
        try inner.base.addChild(alloc, &orient_row.base);

        const orient_combo = try ComboBox.create(alloc, .{
            .items = &.{ "纵向", "横向" },
        });
        try orient_row.base.addChild(alloc, &orient_combo.base);
        orient_combo.base.layout_style.flex_grow = 1;
        self.orientation_combo = orient_combo;

        const paper_row = try self.createLabelRow(alloc, "纸张大小:");
        try inner.base.addChild(alloc, &paper_row.base);

        const paper_combo = try ComboBox.create(alloc, .{
            .items = &.{ "A4", "Letter", "Legal", "A3", "A5" },
        });
        try paper_row.base.addChild(alloc, &paper_combo.base);
        paper_combo.base.layout_style.flex_grow = 1;
        self.paper_combo = paper_combo;

        const color_row = try self.createLabelRow(alloc, "颜色:");
        try inner.base.addChild(alloc, &color_row.base);

        const color_combo = try ComboBox.create(alloc, .{
            .items = &.{ "彩色", "黑白" },
        });
        try color_row.base.addChild(alloc, &color_combo.base);
        color_combo.base.layout_style.flex_grow = 1;
        self.color_combo = color_combo;

        const duplex_row = try self.createLabelRow(alloc, "双面打印:");
        try inner.base.addChild(alloc, &duplex_row.base);

        const duplex_combo = try ComboBox.create(alloc, .{
            .items = &.{ "无", "长边翻转", "短边翻转" },
        });
        try duplex_row.base.addChild(alloc, &duplex_combo.base);
        duplex_combo.base.layout_style.flex_grow = 1;
        self.duplex_combo = duplex_combo;

        const sep = try Separator.create(alloc, .{ .orientation = .horizontal });
        try content.base.addChild(alloc, &sep.base);

        // 按钮
        const btn_row = try Container.create(alloc, .{
            .direction = .row,
            .gap = .{ .width = 8, .height = 0 },
        });
        try content.base.addChild(alloc, &btn_row.base);

        const cancel_btn = try Button.create(alloc, "取消", .{});
        try btn_row.base.addChild(alloc, &cancel_btn.base);
        cancel_btn.on_click = onCancelClick;
        cancel_btn.base.user_data = self;

        const print_btn = try Button.create(alloc, "打印", .{});
        try btn_row.base.addChild(alloc, &print_btn.base);
        print_btn.on_click = onPrintClick;
        print_btn.base.user_data = self;
    }

    fn createLabelRow(self: *Self, alloc: std.mem.Allocator, label_text: []const u8) !*Container {
        const row = try Container.create(alloc, .{
            .direction = .row,
            .gap = .{ .width = 12, .height = 0 },
            .alignment = .center,
        });
        const lbl = try Label.create(alloc, label_text, .{
            .font_size = 12,
            .color = self.text_secondary,
        });
        lbl.base.layout_style.min_width = .{ .px = 80 };
        try row.base.addChild(alloc, &lbl.base);
        return row;
    }

    fn onRangeAllToggle(chk: *Checkbox, checked: bool) void {
        const self: *Self = @ptrCast(@alignCast(chk.base.user_data orelse return));
        if (checked) {
            self.settings.page_range_all = true;
            if (self.range_custom_check) |rc| rc.checked = false;
        }
    }

    fn onRangeCustomToggle(chk: *Checkbox, checked: bool) void {
        const self: *Self = @ptrCast(@alignCast(chk.base.user_data orelse return));
        if (checked) {
            self.settings.page_range_all = false;
            if (self.range_all_check) |ra| ra.checked = false;
        }
    }

    fn onCancelClick(btn: *Button) void {
        const self: *Self = @ptrCast(@alignCast(btn.base.user_data orelse return));
        self.hide();
        if (self.on_cancel) |cb| cb(self);
    }

    fn onPrintClick(btn: *Button) void {
        const self: *Self = @ptrCast(@alignCast(btn.base.user_data orelse return));
        self.collectSettings();
        self.hide();
        if (self.on_print) |cb| cb(self, &self.settings);
    }

    fn collectSettings(self: *Self) void {
        if (self.copies_spin) |ti| {
            const text = ti.getText();
            self.settings.num_copies = std.fmt.parseInt(u32, text, 10) catch 1;
        }
        if (self.range_all_check) |chk| {
            self.settings.page_range_all = chk.checked;
        }
        if (self.range_from_input) |ti| {
            const text = ti.getText();
            self.settings.page_range_from = std.fmt.parseInt(u32, text, 10) catch 1;
        }
        if (self.range_to_input) |ti| {
            const text = ti.getText();
            self.settings.page_range_to = std.fmt.parseInt(u32, text, 10) catch 1;
        }
        if (self.orientation_combo) |cb| {
            self.settings.orientation = if (cb.selected_index == 1) .landscape else .portrait;
        }
        if (self.paper_combo) |cb| {
            self.settings.paper_size = switch (cb.selected_index) {
                1 => .letter,
                2 => .legal,
                3 => .a3,
                4 => .a5,
                else => .a4,
            };
        }
        if (self.color_combo) |cb| {
            self.settings.color_mode = if (cb.selected_index == 1) .grayscale else .color;
        }
        if (self.duplex_combo) |cb| {
            self.settings.duplex = switch (cb.selected_index) {
                1 => .long_edge,
                2 => .short_edge,
                else => .none,
            };
        }
        if (self.collate_check) |chk| {
            self.settings.collate = chk.checked;
        }
        if (self.reverse_check) |chk| {
            self.settings.reverse = chk.checked;
        }
    }

    // ── VTable ──────────────────────────────────────────────────────────────

    const vtable = Widget.VTable{
        .type_name = "print_dialog",
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

    fn measure(w: *Widget, ctx: *PaintContext, constraints: layout_mod.Constraints) math.Size(f32) {
        _ = w;
        _ = ctx;
        return .{ .width = constraints.max_width, .height = constraints.max_height };
    }

    fn paint(w: *Widget, ctx: *PaintContext) void {
        const self: *Self = @fieldParentPtr("base", w);
        if (!self.visible) return;

        const rect = w.rect;
        ctx.renderer.fillRect(rect, self.overlay_color) catch {};

        const dl_w = self.dialog_width;
        const dl_h = self.dialog_height;
        const dl_x = rect.x + (rect.width - dl_w) / 2;
        const dl_y = rect.y + (rect.height - dl_h) / 2;

        if (self.content_container) |cc| {
            cc.base.rect = .{ .x = dl_x, .y = dl_y, .width = dl_w, .height = dl_h };
            cc.base.vtable.paint(&cc.base, ctx);
        }
    }

    fn onEvent(w: *Widget, event: *const pal.Event, ectx: *EventContext) EventResult {
        const self: *Self = @fieldParentPtr("base", w);
        if (!self.visible) return .ignored;

        if (self.content_container) |cc| {
            if (cc.base.vtable.on_event) |ev_fn| {
                const result = ev_fn(&cc.base, event, ectx);
                if (result == .handled) return .handled;
            }
        }

        if (event.* == .key and event.key.state == .pressed and event.key.key == .escape) {
            self.hide();
            if (self.on_cancel) |cb| cb(self);
            return .handled;
        }

        return .handled;
    }
};
