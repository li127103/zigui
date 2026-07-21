//! 控件系统基类

const math = @import("../math.zig");
const pal = @import("../pal/pal.zig");

pub const WidgetId = u64;

var next_id: WidgetId = 1;

pub fn genWidgetId() WidgetId {
    const id = next_id;
    next_id += 1;
    return id;
}

pub const WidgetState = packed struct(u16) {
    hovered: bool = false,
    focused: bool = false,
    pressed: bool = false,
    disabled: bool = false,
    visible: bool = true,
    dirty: bool = true,
    layout_dirty: bool = true,
    _padding: u9 = 0,
};

pub const LayoutResult = struct {
    x: f32 = 0,
    y: f32 = 0,
    width: f32 = 0,
    height: f32 = 0,

    pub fn contentRect(self: LayoutResult, padding: math.EdgeInsets) math.Rect(f32) {
        return .{
            .x = self.x + padding.left,
            .y = self.y + padding.top,
            .width = self.width - padding.left - padding.right,
            .height = self.height - padding.top - padding.bottom,
        };
    }
};

pub const EventResult = enum { handled, ignored };

pub const MeasureContext = struct {
    // M2: text_engine, theme 引用
    _placeholder: void = {},
};

pub const PaintContext = struct {
    // M2: render2d engine 引用
    _placeholder: void = {},
};

pub const Widget = struct {
    vtable: *const VTable,
    id: WidgetId,
    parent: ?*Widget = null,
    children: std.ArrayListUnmanaged(*Widget) = .{},
    layout: LayoutResult = .{},
    state: WidgetState = .{},

    pub const VTable = struct {
        type_name: []const u8,
        measure: *const fn (self: *Widget, ctx: *MeasureContext) math.Size(f32),
        paint: *const fn (self: *Widget, ctx: *PaintContext) void,
        on_event: ?*const fn (self: *Widget, event: *const pal.Event) EventResult = null,
        focusable: bool = false,
        destroy: *const fn (self: *Widget, allocator: std.mem.Allocator) void,
    };

    pub fn addChild(self: *Widget, allocator: std.mem.Allocator, child: *Widget) !void {
        try self.children.append(allocator, child);
        child.parent = self;
    }

    pub fn markDirty(self: *Widget) void {
        var current: ?*Widget = self;
        while (current) |w| {
            if (w.state.dirty) break;
            w.state.dirty = true;
            current = w.parent;
        }
    }

    pub fn markLayoutDirty(self: *Widget) void {
        var current: ?*Widget = self;
        while (current) |w| {
            if (w.state.layout_dirty) break;
            w.state.layout_dirty = true;
            current = w.parent;
        }
    }
};

const std = @import("std");
