//! Drag and Drop 拖放系统
//!
//! 提供拖放操作的基础框架，支持拖拽源 (DragSource) 和
//! 拖放目标 (DropTarget)，以及拖放数据格式定义。
//!
//! 使用方法:
//! ```
//! // 拖拽源
//! var source = try DragSource.create(allocator, .{
//!     .target = &widget.base,
//!     .data_type = .text,
//!     .on_drag_begin = onDragBegin,
//! });
//!
//! // 拖放目标
//! var target = try DropTarget.create(allocator, .{
//!     .target = &widget.base,
//!     .accepted_types = &.{.text},
//!     .on_drop = onDrop,
//! });
//! ```

const std = @import("std");
const math = @import("../math.zig");
const widget_mod = @import("widget.zig");

const Widget = widget_mod.Widget;

pub const DragDataType = enum(u8) {
    none = 0,
    text = 1,
    image = 2,
    file = 4,
    custom = 8,
};

pub const DragData = struct {
    data_type: DragDataType = .text,
    text: []const u8 = "",
    custom_type: []const u8 = "",
    custom_data: []const u8 = "",
    files: []const []const u8 = &.{},
    user_data: ?*anyopaque = null,
};

pub const DragOperation = enum {
    none,
    copy,
    move,
    link,
};

pub const DragState = struct {
    active: bool = false,
    source_widget: ?*Widget = null,
    target_widget: ?*Widget = null,
    data: DragData = .{},
    operation: DragOperation = .copy,
    x: f32 = 0,
    y: f32 = 0,
    offset_x: f32 = 0,
    offset_y: f32 = 0,
};

pub const DragSource = struct {
    widget: *Widget,
    enabled: bool = true,
    data_types: []const DragDataType = &.{.text},
    default_operation: DragOperation = .copy,
    on_drag_begin: ?*const fn (self: *DragSource, x: f32, y: f32) ?DragData = null,
    on_drag_end: ?*const fn (self: *DragSource, operation: DragOperation) void = null,

    const Self = @This();

    pub fn create(allocator: std.mem.Allocator, opts: struct {
        widget: *Widget,
        data_types: []const DragDataType = &.{.text},
        on_drag_begin: ?*const fn (self: *DragSource, x: f32, y: f32) ?DragData = null,
        on_drag_end: ?*const fn (self: *DragSource, operation: DragOperation) void = null,
    }) !*DragSource {
        const self = try allocator.create(DragSource);
        self.* = .{
            .widget = opts.widget,
            .data_types = opts.data_types,
            .on_drag_begin = opts.on_drag_begin,
            .on_drag_end = opts.on_drag_end,
        };
        return self;
    }

    pub fn destroy(self: *Self, allocator: std.mem.Allocator) void {
        allocator.destroy(self);
    }

    pub fn setEnabled(self: *Self, enabled: bool) void {
        self.enabled = enabled;
    }

    pub fn startDrag(self: *Self, x: f32, y: f32) ?DragData {
        if (!self.enabled) return null;
        if (self.on_drag_begin) |cb| {
            return cb(self, x, y);
        }
        return null;
    }
};

pub const DropTarget = struct {
    widget: *Widget,
    enabled: bool = true,
    accepted_types: []const DragDataType = &.{.text},
    supported_operations: []const DragOperation = &.{ .copy, .move, .link },
    on_drag_enter: ?*const fn (self: *DropTarget, x: f32, y: f32, data: *const DragData) DragOperation = null,
    on_drag_move: ?*const fn (self: *DropTarget, x: f32, y: f32, data: *const DragData) DragOperation = null,
    on_drag_leave: ?*const fn (self: *DropTarget) void = null,
    on_drop: ?*const fn (self: *DropTarget, x: f32, y: f32, data: *const DragData) bool = null,

    const Self = @This();

    pub fn create(allocator: std.mem.Allocator, opts: struct {
        widget: *Widget,
        accepted_types: []const DragDataType = &.{.text},
        on_drag_enter: ?*const fn (self: *DropTarget, x: f32, y: f32, data: *const DragData) DragOperation = null,
        on_drag_move: ?*const fn (self: *DropTarget, x: f32, y: f32, data: *const DragData) DragOperation = null,
        on_drag_leave: ?*const fn (self: *DropTarget) void = null,
        on_drop: ?*const fn (self: *DropTarget, x: f32, y: f32, data: *const DragData) bool = null,
    }) !*DropTarget {
        const self = try allocator.create(DropTarget);
        self.* = .{
            .widget = opts.widget,
            .accepted_types = opts.accepted_types,
            .on_drag_enter = opts.on_drag_enter,
            .on_drag_move = opts.on_drag_move,
            .on_drag_leave = opts.on_drag_leave,
            .on_drop = opts.on_drop,
        };
        return self;
    }

    pub fn destroy(self: *Self, allocator: std.mem.Allocator) void {
        allocator.destroy(self);
    }

    pub fn setEnabled(self: *Self, enabled: bool) void {
        self.enabled = enabled;
    }

    pub fn acceptsType(self: *const Self, data_type: DragDataType) bool {
        for (self.accepted_types) |t| {
            if (t == data_type) return true;
        }
        return false;
    }

    pub fn dragEnter(self: *Self, x: f32, y: f32, data: *const DragData) DragOperation {
        if (!self.enabled) return .none;
        if (!self.acceptsType(data.data_type)) return .none;
        if (self.on_drag_enter) |cb| {
            return cb(self, x, y, data);
        }
        return self.supported_operations[0];
    }

    pub fn dragMove(self: *Self, x: f32, y: f32, data: *const DragData) DragOperation {
        if (!self.enabled) return .none;
        if (self.on_drag_move) |cb| {
            return cb(self, x, y, data);
        }
        return self.supported_operations[0];
    }

    pub fn dragLeave(self: *Self) void {
        if (self.on_drag_leave) |cb| {
            cb(self);
        }
    }

    pub fn drop(self: *Self, x: f32, y: f32, data: *const DragData) bool {
        if (!self.enabled) return false;
        if (!self.acceptsType(data.data_type)) return false;
        if (self.on_drop) |cb| {
            return cb(self, x, y, data);
        }
        return false;
    }
};

/// 全局拖放管理器
pub const DragDropManager = struct {
    state: DragState = .{},
    drag_sources: std.AutoHashMapUnmanaged(*Widget, *DragSource) = .{},
    drop_targets: std.AutoHashMapUnmanaged(*Widget, *DropTarget) = .{},

    var instance: ?*DragDropManager = null;

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator) !*DragDropManager {
        if (instance) |inst| return inst;
        const self = try allocator.create(DragDropManager);
        self.* = .{};
        instance = self;
        return self;
    }

    pub fn deinit(self: *Self, allocator: std.mem.Allocator) void {
        self.drag_sources.deinit(allocator);
        self.drop_targets.deinit(allocator);
        allocator.destroy(self);
        if (instance == self) instance = null;
    }

    pub fn getInstance() ?*DragDropManager {
        return instance;
    }

    pub fn registerSource(self: *Self, allocator: std.mem.Allocator, source: *DragSource) !void {
        try self.drag_sources.put(allocator, source.widget, source);
    }

    pub fn unregisterSource(self: *Self, widget: *Widget) void {
        _ = self.drag_sources.remove(widget);
    }

    pub fn registerTarget(self: *Self, allocator: std.mem.Allocator, target: *DropTarget) !void {
        try self.drop_targets.put(allocator, target.widget, target);
    }

    pub fn unregisterTarget(self: *Self, widget: *Widget) void {
        _ = self.drop_targets.remove(widget);
    }

    pub fn getSource(self: *Self, widget: *Widget) ?*DragSource {
        return self.drag_sources.get(widget);
    }

    pub fn getTarget(self: *Self, widget: *Widget) ?*DropTarget {
        return self.drop_targets.get(widget);
    }

    pub fn isDragging(self: *const Self) bool {
        return self.state.active;
    }

    pub fn beginDrag(self: *Self, source: *DragSource, x: f32, y: f32, data: DragData, offset_x: f32, offset_y: f32) void {
        self.state = .{
            .active = true,
            .source_widget = source.widget,
            .data = data,
            .operation = source.default_operation,
            .x = x,
            .y = y,
            .offset_x = offset_x,
            .offset_y = offset_y,
        };
    }

    pub fn updateDrag(self: *Self, x: f32, y: f32) void {
        if (!self.state.active) return;
        self.state.x = x;
        self.state.y = y;
    }

    pub fn endDrag(self: *Self, operation: DragOperation) void {
        if (!self.state.active) return;
        if (self.state.source_widget) |src_widget| {
            if (self.getSource(src_widget)) |source| {
                if (source.on_drag_end) |cb| {
                    cb(source, operation);
                }
            }
        }
        self.state = .{};
    }

    pub fn findDropTargetAt(self: *Self, root: *Widget, x: f32, y: f32) ?*DropTarget {
        _ = x;
        _ = y;
        if (self.getTarget(root)) |dt| {
            return dt;
        }
        return null;
    }
};
