//! FontSelection 控件 - 独立的字体选择控件
//!
//! 可嵌入到任何容器中的字体选择控件，支持选择字体族、字号、
//! 字体样式(粗体/斜体)，实时预览效果。
//!
//! 使用方法:
//! ```
//! var sel = try FontSelection.create(allocator, .{
//!     .initial_family = "Sans",
//!     .initial_size = 14,
//!     .on_font_changed = onFontChanged,
//! });
//! container.addChild(&sel.base);
//! ```

const std = @import("std");
const builtin = @import("builtin");
const math = @import("../math.zig");
const widget_mod = @import("widget.zig");
const pal = @import("../pal/pal.zig");
const container_mod = @import("container.zig");
const label_mod = @import("label.zig");
const entry_mod = @import("entry.zig");
const scrolled_window_mod = @import("scrolled_window.zig");
const list_view_mod = @import("list_view.zig");
const check_button_mod = @import("check_button.zig");
const font_chooser_mod = @import("font_chooser.zig");

const Widget = widget_mod.Widget;
const PaintContext = widget_mod.PaintContext;
const EventContext = widget_mod.EventContext;
const EventResult = widget_mod.EventResult;

const Container = container_mod.Container;
const Label = label_mod.Label;
const Entry = entry_mod.Entry;
const ScrolledWindow = scrolled_window_mod.ScrolledWindow;
const ListView = list_view_mod.ListView;
const CheckButton = check_button_mod.CheckButton;

pub const FontDesc = font_chooser_mod.FontDesc;

pub const FontSelection = struct {
    base: Widget,
    allocator: std.mem.Allocator,
    selected_family: []const u8,
    selected_size: f32,
    bold: bool,
    italic: bool,
    on_font_changed: ?*const fn (self: *FontSelection, desc: FontDesc) void = null,

    content_container: ?*Container = null,
    family_list: ?*ListView = null,
    size_input: ?*Entry = null,
    bold_check: ?*CheckButton = null,
    italic_check: ?*CheckButton = null,
    preview_label: ?*Label = null,

    bg_color: math.Color = math.Color.hex(0x1E293BFF),
    text_color: math.Color = math.Color.hex(0xF8FAFCFF),
    text_secondary: math.Color = math.Color.hex(0x94A3B8FF),
    corner_radius: f32 = 8.0,

    font_families: std.ArrayListUnmanaged([]const u8) = .{ .items = &.{}, .capacity = 0 },

    const Self = @This();

    pub fn create(allocator: std.mem.Allocator, opts: struct {
        initial_family: []const u8 = "Sans",
        initial_size: f32 = 14,
        initial_bold: bool = false,
        initial_italic: bool = false,
        on_font_changed: ?*const fn (self: *FontSelection, desc: FontDesc) void = null,
        width: f32 = 500,
        height: f32 = 300,
        bg_color: ?math.Color = null,
        text_color: ?math.Color = null,
    }) !*FontSelection {
        const self = try allocator.create(FontSelection);
        self.* = .{
            .base = .{
                .vtable = &vtable,
                .id = widget_mod.genWidgetId(),
            },
            .allocator = allocator,
            .selected_family = try allocator.dupe(u8, opts.initial_family),
            .selected_size = opts.initial_size,
            .bold = opts.initial_bold,
            .italic = opts.initial_italic,
            .on_font_changed = opts.on_font_changed,
            .bg_color = opts.bg_color orelse self.bg_color,
            .text_color = opts.text_color orelse self.text_color,
        };
        self.base.rect.width = opts.width;
        self.base.rect.height = opts.height;
        self.loadFontFamilies();
        try self.buildUI();
        return self;
    }

    pub fn destroy(self: *Self, allocator: std.mem.Allocator) void {
        allocator.free(self.selected_family);
        for (self.font_families.items) |f| allocator.free(f);
        self.font_families.deinit(allocator);
        self.base.background.deinit(allocator);
        if (self.content_container) |cc| {
            cc.base.vtable.destroy(&cc.base, allocator);
        }
        self.base.children.deinit(allocator);
        allocator.destroy(self);
    }

    pub fn getFontDesc(self: *Self) FontDesc {
        return .{
            .family = self.selected_family,
            .size = self.selected_size,
            .bold = self.bold,
            .italic = self.italic,
        };
    }

    pub fn setFont(self: *Self, desc: FontDesc) void {
        self.allocator.free(self.selected_family);
        self.selected_family = self.allocator.dupe(u8, desc.family) catch return;
        self.selected_size = desc.size;
        self.bold = desc.bold;
        self.italic = desc.italic;
        self.updatePreview();
        self.base.markDirty();
    }

    // 平台相关的字体族枚举实现: 仅被当前平台编译的那个文件会被 @import。
    const font_enum = if (builtin.os.tag == .macos)
        @import("font_chooser_ct.zig")
    else
        @import("font_chooser_fc.zig");

    fn loadFontFamilies(self: *Self) void {
        font_enum.enumerate(self.allocator, &self.font_families);
        self.dedupAndSortFontFamilies();
    }

    fn dedupAndSortFontFamilies(self: *Self) void {
        var seen = std.StringHashMap(void).init(self.allocator);
        defer seen.deinit();

        var i: usize = 0;
        while (i < self.font_families.items.len) {
            const name = self.font_families.items[i];
            if (seen.contains(name)) {
                const removed = self.font_families.swapRemove(i);
                self.allocator.free(removed);
            } else {
                seen.put(name, {}) catch {
                    i += 1;
                    continue;
                };
                i += 1;
            }
        }

        std.mem.sort([]const u8, self.font_families.items, {}, struct {
            fn lessThan(_: void, a: []const u8, b: []const u8) bool {
                return std.mem.lessThan(u8, a, b);
            }
        }.lessThan);
    }

    fn buildUI(self: *Self) !void {
        const alloc = self.allocator;

        const content = try Container.create(alloc, .{
            .direction = .column,
            .bg_color = self.bg_color,
            .corner_radius = self.corner_radius,
            .padding = .{ .left = 12, .right = 12, .top = 12, .bottom = 12 },
            .gap = .{ .width = 0, .height = 10 },
        });
        self.content_container = content;
        try self.base.addChild(alloc, &content.base);

        const main_row = try Container.create(alloc, .{
            .direction = .row,
            .gap = .{ .width = 12, .height = 0 },
        });
        try content.base.addChild(alloc, &main_row.base);

        const left_col = try Container.create(alloc, .{
            .direction = .column,
            .gap = .{ .width = 0, .height = 6 },
        });
        left_col.base.layout_style.flex_grow = 1;
        left_col.base.layout_style.flex_shrink = 1;
        try main_row.base.addChild(alloc, &left_col.base);

        const fam_lbl = try Label.create(alloc, "字体族:", .{
            .font_size = 12,
            .color = self.text_secondary,
        });
        try left_col.base.addChild(alloc, &fam_lbl.base);

        const sv = try ScrolledWindow.create(alloc, .{
            .width = 250,
            .height = 200,
        });
        try left_col.base.addChild(alloc, &sv.base);

        const list = try ListView.create(alloc, .{
            .item_height = 26,
            .font_size = 12,
            .on_select = onFamilySelected,
        });
        try sv.base.addChild(alloc, &list.base);
        self.family_list = list;
        list.base.user_data = self;

        for (self.font_families.items) |fam| {
            const owned = alloc.dupe(u8, fam) catch continue;
            list.items.append(alloc, owned) catch {
                alloc.free(owned);
            };
        }

        const right_col = try Container.create(alloc, .{
            .direction = .column,
            .gap = .{ .width = 0, .height = 10 },
        });
        right_col.base.layout_style.flex_grow = 1;
        right_col.base.layout_style.flex_shrink = 1;
        try main_row.base.addChild(alloc, &right_col.base);

        const size_lbl = try Label.create(alloc, "字号:", .{
            .font_size = 12,
            .color = self.text_secondary,
        });
        try right_col.base.addChild(alloc, &size_lbl.base);

        const si = try Entry.create(alloc, .{
            .placeholder = "14",
        });
        try right_col.base.addChild(alloc, &si.base);
        self.size_input = si;
        si.base.user_data = self;
        si.setText("14") catch {};

        const style_lbl = try Label.create(alloc, "样式:", .{
            .font_size = 12,
            .color = self.text_secondary,
        });
        try right_col.base.addChild(alloc, &style_lbl.base);

        const bold = try CheckButton.create(alloc, "粗体", .{
            .checked = self.bold,
        });
        try right_col.base.addChild(alloc, &bold.base);
        self.bold_check = bold;
        bold.base.user_data = self;
        bold.on_change = onBoldToggle;

        const italic = try CheckButton.create(alloc, "斜体", .{
            .checked = self.italic,
        });
        try right_col.base.addChild(alloc, &italic.base);
        self.italic_check = italic;
        italic.base.user_data = self;
        italic.on_change = onItalicToggle;

        const preview_lbl = try Label.create(alloc, "预览:", .{
            .font_size = 12,
            .color = self.text_secondary,
        });
        try right_col.base.addChild(alloc, &preview_lbl.base);

        const preview = try Label.create(alloc, "Aa 你好", .{
            .font_size = self.selected_size,
            .color = self.text_color,
        });
        preview.base.layout_style.min_height = .{ .px = 50 };
        try right_col.base.addChild(alloc, &preview.base);
        self.preview_label = preview;
    }

    fn updatePreview(self: *Self) void {
        if (self.preview_label) |lbl| {
            lbl.font_size = self.selected_size;
            lbl.font_weight = if (self.bold) 700 else 400;
        }
        self.base.markDirty();
    }

    fn notifyChanged(self: *Self) void {
        if (self.on_font_changed) |cb| {
            cb(self, self.getFontDesc());
        }
    }

    fn onFamilySelected(list: *ListView, index: usize) void {
        const self: *Self = @ptrCast(@alignCast(list.base.user_data orelse return));
        if (index < self.font_families.items.len) {
            const new_fam = self.allocator.dupe(u8, self.font_families.items[index]) catch return;
            self.allocator.free(self.selected_family);
            self.selected_family = new_fam;
            self.updatePreview();
            self.notifyChanged();
        }
    }

    fn onBoldToggle(chk: *CheckButton, checked: bool) void {
        const self: *Self = @ptrCast(@alignCast(chk.base.user_data orelse return));
        self.bold = checked;
        self.updatePreview();
        self.notifyChanged();
    }

    fn onItalicToggle(chk: *CheckButton, checked: bool) void {
        const self: *Self = @ptrCast(@alignCast(chk.base.user_data orelse return));
        self.italic = checked;
        self.updatePreview();
        self.notifyChanged();
    }

    const vtable = Widget.VTable{
        .type_name = "font_selection",
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
        _ = ctx;
        const w_used = if (w.rect.width > 0) w.rect.width else @min(500, constraints.max_width);
        const h_used = if (w.rect.height > 0) w.rect.height else @min(300, constraints.max_height);
        return .{ .width = w_used, .height = h_used };
    }

    fn paint(w: *Widget, ctx: *PaintContext) void {
        const self: *Self = @fieldParentPtr("base", w);

        if (self.content_container) |cc| {
            cc.base.rect = w.rect;
            cc.base.vtable.paint(&cc.base, ctx);
        }
    }

    fn onEvent(w: *Widget, event: *const pal.Event, ectx: *EventContext) EventResult {
        const self: *Self = @fieldParentPtr("base", w);

        if (self.content_container) |cc| {
            if (cc.base.vtable.on_event) |ev_fn| {
                const result = ev_fn(&cc.base, event, ectx);
                if (result == .handled) return .handled;
            }
        }

        return .ignored;
    }
};
