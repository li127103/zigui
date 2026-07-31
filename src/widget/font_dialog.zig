//! FontDialog 控件 - GTK4 字体选择对话框
//!
//! GTK4 新版简化 API (替代 GtkFontChooserDialog)。
//! 与 FontDialogButton 配合使用。
//!
//! GTK4 对应: GtkFontDialog

const std = @import("std");
const math = @import("../math.zig");
const widget_mod = @import("widget.zig");
const layout_mod = @import("../layout/engine.zig");
const pal = @import("../pal/pal.zig");

const Widget = widget_mod.Widget;
const PaintContext = widget_mod.PaintContext;
const Allocator = std.mem.Allocator;

pub const FontResult = struct {
    family: []const u8,
    size: f32,
    bold: bool,
    italic: bool,
};

pub const FontDialogResult = union(enum) {
    ok: FontResult,
    cancel: void,
};

pub const FontDialog = struct {
    base: Widget,
    allocator: Allocator,
    title: []const u8 = "Choose Font",
    title_dup: []const u8 = &.{},
    modal: bool = true,
    accept_label: []const u8 = "Select",
    cancel_label: []const u8 = "Cancel",

    selected_family: []const u8 = "Sans",
    family_dup: []const u8 = &.{},
    selected_size: f32 = 14,
    selected_bold: bool = false,
    selected_italic: bool = false,

    on_response: ?*const fn (self: *FontDialog, result: FontDialogResult) void = null,

    pub fn new(allocator: Allocator, title: []const u8) !*FontDialog {
        const self = try allocator.create(FontDialog);
        const title_dup = try allocator.dupe(u8, title);
        const family_dup = try allocator.dupe(u8, "Sans");
        self.* = .{
            .base = .{
                .vtable = &vtable,
                .id = widget_mod.genWidgetId(),
            },
            .allocator = allocator,
            .title = title_dup,
            .title_dup = title_dup,
            .selected_family = family_dup,
            .family_dup = family_dup,
        };
        self.base.accessibility = .{ .role = .dialog, .label = self.title };
        return self;
    }

    pub fn destroy(self: *FontDialog, allocator: Allocator) void {
        if (self.title_dup.len > 0) allocator.free(self.title_dup);
        if (self.family_dup.len > 0) allocator.free(self.family_dup);
        self.base.background.deinit(allocator);
        self.base.children.deinit(allocator);
        allocator.destroy(self);
    }

    pub fn setTitle(self: *FontDialog, title: []const u8) void {
        if (self.title_dup.len > 0) self.allocator.free(self.title_dup);
        self.title_dup = self.allocator.dupe(u8, title) catch return;
        self.title = self.title_dup;
        self.base.accessibility.label = self.title;
    }

    pub fn setInitialFont(self: *FontDialog, family: []const u8, size: f32, bold: bool, italic: bool) void {
        if (self.family_dup.len > 0) self.allocator.free(self.family_dup);
        self.family_dup = self.allocator.dupe(u8, family) catch return;
        self.selected_family = self.family_dup;
        self.selected_size = size;
        self.selected_bold = bold;
        self.selected_italic = italic;
    }

    pub fn chooseFont(self: *FontDialog, callback: ?*const fn (ud: ?*anyopaque, result: FontDialogResult) void, userdata: ?*anyopaque) void {
        const result: FontDialogResult = .{
            .ok = .{
                .family = self.selected_family,
                .size = self.selected_size,
                .bold = self.selected_bold,
                .italic = self.selected_italic,
            },
        };
        if (callback) |cb| cb(userdata, result);
        if (self.on_response) |cb| cb(self, result);
    }
};

const vtable = Widget.VTable{
    .type_name = "font_dialog",
    .measure = measure,
    .paint = paint,
    .on_event = null,
    .focusable = false,
    .destroy = destroyVTable,
};

fn destroyVTable(w: *Widget, allocator: Allocator) void {
    const self: *FontDialog = @fieldParentPtr("base", w);
    self.destroy(allocator);
}

fn measure(w: *Widget, ctx: *PaintContext, constraints: layout_mod.Constraints) math.Size(f32) {
    _ = w;
    _ = ctx;
    _ = constraints;
    return .{ .width = 520, .height = 520 };
}

fn paint(w: *Widget, ctx: *PaintContext) void {
    _ = w;
    _ = ctx;
}
