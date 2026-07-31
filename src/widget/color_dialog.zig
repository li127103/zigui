//! ColorDialog 控件 - GTK4 颜色选择对话框
//!
//! GTK4 新版简化 API (替代 GtkColorChooserDialog)。
//! 与 ColorDialogButton 配合使用。
//!
//! GTK4 对应: GtkColorDialog

const std = @import("std");
const math = @import("../math.zig");
const widget_mod = @import("widget.zig");
const layout_mod = @import("../layout/engine.zig");
const pal = @import("../pal/pal.zig");

const Widget = widget_mod.Widget;
const PaintContext = widget_mod.PaintContext;
const EventContext = widget_mod.EventContext;
const EventResult = widget_mod.EventResult;
const Allocator = std.mem.Allocator;
const Event = pal.Event;

pub const ColorDialogResult = union(enum) {
    ok: math.Color,
    cancel: void,
};

pub const ColorDialog = struct {
    base: Widget,
    allocator: Allocator,
    title: []const u8 = "Choose Color",
    title_dup: []const u8 = &.{},
    modal: bool = true,
    accept_label: []const u8 = "Select",
    cancel_label: []const u8 = "Cancel",
    selected_color: math.Color = math.Color.hex(0x3B82F6FF),
    on_response: ?*const fn (self: *ColorDialog, result: ColorDialogResult) void = null,

    pub fn new(allocator: Allocator, title: []const u8) !*ColorDialog {
        const self = try allocator.create(ColorDialog);
        const title_dup = try allocator.dupe(u8, title);
        self.* = .{
            .base = .{
                .vtable = &vtable,
                .id = widget_mod.genWidgetId(),
            },
            .allocator = allocator,
            .title = title_dup,
            .title_dup = title_dup,
        };
        self.base.accessibility = .{ .role = .dialog, .label = self.title };
        return self;
    }

    pub fn destroy(self: *ColorDialog, allocator: Allocator) void {
        if (self.title_dup.len > 0) allocator.free(self.title_dup);
        self.base.background.deinit(allocator);
        self.base.children.deinit(allocator);
        allocator.destroy(self);
    }

    pub fn setTitle(self: *ColorDialog, title: []const u8) void {
        if (self.title_dup.len > 0) self.allocator.free(self.title_dup);
        self.title_dup = self.allocator.dupe(u8, title) catch return;
        self.title = self.title_dup;
        self.base.accessibility.label = self.title;
    }

    pub fn setInitialColor(self: *ColorDialog, c: math.Color) void {
        self.selected_color = c;
    }

    pub fn getSelectedColor(self: *const ColorDialog) math.Color {
        return self.selected_color;
    }

    /// 简化版异步 API: 直接触发 callback (实际项目中会弹出对话框, 用户选择后再回调)
    pub fn chooseRgba(self: *ColorDialog, initial: ?math.Color, callback: ?*const fn (userdata: ?*anyopaque, result: ColorDialogResult) void, userdata: ?*anyopaque) void {
        if (initial) |c| self.selected_color = c;
        const result: ColorDialogResult = .{ .ok = self.selected_color };
        if (callback) |cb| cb(userdata, result);
        if (self.on_response) |cb| cb(self, result);
    }
};

const vtable = Widget.VTable{
    .type_name = "color_dialog",
    .measure = measure,
    .paint = paint,
    .on_event = null,
    .focusable = false,
    .destroy = destroyVTable,
};

fn destroyVTable(w: *Widget, allocator: Allocator) void {
    const self: *ColorDialog = @fieldParentPtr("base", w);
    self.destroy(allocator);
}

fn measure(w: *Widget, ctx: *PaintContext, constraints: layout_mod.Constraints) math.Size(f32) {
    _ = w;
    _ = ctx;
    _ = constraints;
    return .{ .width = 400, .height = 500 };
}

fn paint(w: *Widget, ctx: *PaintContext) void {
    _ = w;
    _ = ctx;
}
