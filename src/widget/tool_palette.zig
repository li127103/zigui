//! ToolPalette 控件 - 工具面板
//!
//! 可分组的工具按钮面板，每个组可以展开/折叠，
//! 组内按钮以网格方式排列。
//!
//! 使用方法:
//! ```
//! var palette = try ToolPalette.create(allocator, .{});
//! var grp = try palette.addGroup("绘图工具");
//! try grp.addItem("pen", "画笔", onToolClick);
//! try grp.addItem("brush", "画刷", onToolClick);
//! ```

const std = @import("std");
const math = @import("../math.zig");
const widget_mod = @import("widget.zig");
const container_mod = @import("container.zig");
const label_mod = @import("label.zig");
const button_mod = @import("button.zig");
const expander_mod = @import("expander.zig");
const layout_mod = @import("../layout/engine.zig");

const Widget = widget_mod.Widget;
const PaintContext = widget_mod.PaintContext;
const EventContext = widget_mod.EventContext;
const EventResult = widget_mod.EventResult;

const Container = container_mod.Container;
const Label = label_mod.Label;
const Button = button_mod.Button;
const Expander = expander_mod.Expander;

pub const ToolPaletteItem = struct {
    name: []const u8,
    label: []const u8,
    icon_text: []const u8 = "",
    user_data: ?*anyopaque = null,
    button: ?*Button = null,
};

pub const ToolPaletteGroup = struct {
    palette: *ToolPalette,
    name: []const u8,
    items: std.ArrayListUnmanaged(ToolPaletteItem) = .{ .items = &.{}, .capacity = 0 },
    expander: ?*Expander = null,
    content_container: ?*Container = null,

    const Self = @This();

    pub fn addItem(
        self: *Self,
        name: []const u8,
        label: []const u8,
        on_click: ?*const fn (item: *ToolPaletteItem) void,
    ) !void {
        const alloc = self.palette.allocator;

        const owned_name = try alloc.dupe(u8, name);
        const owned_label = try alloc.dupe(u8, label);
        errdefer {
            alloc.free(owned_name);
            alloc.free(owned_label);
        }

        const btn = try Button.create(alloc, owned_label, .{
            .font_size = 12,
            .min_width = self.palette.item_width,
            .height = self.palette.item_height,
            .corner_radius = 4,
        });

        var item = ToolPaletteItem{
            .name = owned_name,
            .label = owned_label,
            .button = btn,
        };

        btn.base.user_data = @ptrCast(&item);
        _ = on_click;

        try self.items.append(alloc, item);

        if (self.content_container) |cc| {
            try cc.base.addChild(alloc, &btn.base);
        }
    }

    pub fn deinit(self: *Self, allocator: std.mem.Allocator) void {
        for (self.items.items) |*it| {
            allocator.free(it.name);
            allocator.free(it.label);
            if (it.icon_text.len > 0) allocator.free(it.icon_text);
        }
        self.items.deinit(allocator);
        allocator.free(self.name);
    }
};

pub const ToolPalette = struct {
    base: Widget,
    allocator: std.mem.Allocator,

    groups: std.ArrayListUnmanaged(*ToolPaletteGroup) = .{ .items = &.{}, .capacity = 0 },
    content_container: ?*Container = null,

    item_width: f32 = 80,
    item_height: f32 = 32,
    columns: u32 = 2,

    bg_color: math.Color = math.Color.hex(0x0F172AFF),
    group_bg_color: math.Color = math.Color.hex(0x1E293BFF),
    text_color: math.Color = math.Color.hex(0xF1F5FFFF),
    text_secondary: math.Color = math.Color.hex(0x94A3B8FF),

    const Self = @This();

    pub fn create(allocator: std.mem.Allocator, opts: struct {
        item_width: f32 = 80,
        item_height: f32 = 32,
        columns: u32 = 2,
        bg_color: ?math.Color = null,
        group_bg_color: ?math.Color = null,
    }) !*ToolPalette {
        const self = try allocator.create(ToolPalette);
        self.* = .{
            .base = .{
                .vtable = &vtable,
                .id = widget_mod.genWidgetId(),
            },
            .allocator = allocator,
            .item_width = opts.item_width,
            .item_height = opts.item_height,
            .columns = opts.columns,
            .bg_color = opts.bg_color orelse self.bg_color,
            .group_bg_color = opts.group_bg_color orelse self.group_bg_color,
        };
        try self.buildUI();
        return self;
    }

    pub fn destroy(self: *Self, allocator: std.mem.Allocator) void {
        for (self.groups.items) |grp| {
            grp.deinit(allocator);
            allocator.destroy(grp);
        }
        self.groups.deinit(allocator);
        self.base.background.deinit(allocator);
        if (self.content_container) |cc| {
            cc.base.vtable.destroy(&cc.base, allocator);
        }
        self.base.children.deinit(allocator);
        allocator.destroy(self);
    }

    fn buildUI(self: *Self) !void {
        const alloc = self.allocator;

        const content = try Container.create(alloc, .{
            .direction = .column,
            .bg_color = self.bg_color,
            .padding = .{ .left = 8, .right = 8, .top = 8, .bottom = 8 },
            .gap = .{ .width = 0, .height = 8 },
            .scrollable = true,
        });
        self.content_container = content;
        try self.base.addChild(alloc, &content.base);
    }

    pub fn addGroup(self: *Self, name: []const u8) !*ToolPaletteGroup {
        const alloc = self.allocator;

        const grp = try alloc.create(ToolPaletteGroup);
        grp.* = .{
            .palette = self,
            .name = try alloc.dupe(u8, name),
        };
        errdefer {
            alloc.destroy(grp);
        }

        const content = try Container.create(alloc, .{
            .direction = .row,
            .wrap = true,
            .gap = .{ .width = 6, .height = 6 },
            .padding = .{ .left = 8, .right = 8, .top = 8, .bottom = 8 },
        });
        grp.content_container = content;

        const exp = try Expander.create(alloc, name, .{
            .bg_color = self.group_bg_color,
            .text_color = self.text_color,
            .corner_radius = 6,
        });
        grp.expander = exp;
        try exp.setContent(&content.base);

        if (self.content_container) |cc| {
            try cc.base.addChild(alloc, &exp.base);
        }

        try self.groups.append(alloc, grp);
        return grp;
    }

    // ── VTable ──────────────────────────────────────────────────────────────

    const vtable = Widget.VTable{
        .type_name = "tool_palette",
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
        _ = ctx;
        const w_used = if (w.rect.width > 0) w.rect.width else @min(250, constraints.max_width);
        const h_used = if (w.rect.height > 0) w.rect.height else @min(400, constraints.max_height);
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

const pal = @import("../pal/pal.zig");
