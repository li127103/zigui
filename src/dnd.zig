//! 拖拽 (Drag and Drop) 系统
//!
//! 用法:
//!   // 注册 drop 目标
//!   widget.drop_target = try DropTarget.create(alloc, &.{"text/plain"}, onDrop, ctx);
//!
//!   // 开始拖拽 (在 mouse_down + move 时调用)
//!   app.startDrag(.{ .text = "拖拽的文本" });
//!
//!   // App 在 mouse_move 时自动 hitTest drop targets
//!   // mouse_release 时自动触发 on_drop

const std = @import("std");
const math = @import("math.zig");

/// 拖拽数据
pub const DragData = union(enum) {
    text: []const u8,
    custom: struct {
        data: *anyopaque,
        mime: []const u8,
    },
};

/// Drop 目标 (附加到 Widget 上)
pub const DropTarget = struct {
    mime_types: []const []const u8,
    on_drop: *const fn (ctx: ?*anyopaque, data: DragData, x: f32, y: f32) void,
    ctx: ?*anyopaque = null,
    /// 当前是否被悬停 (拖拽经过时高亮)
    hovered: bool = false,

    pub fn create(
        mime_types: []const []const u8,
        on_drop: *const fn (ctx: ?*anyopaque, data: DragData, x: f32, y: f32) void,
        ctx: ?*anyopaque,
    ) DropTarget {
        return .{
            .mime_types = mime_types,
            .on_drop = on_drop,
            .ctx = ctx,
        };
    }

    pub fn accepts(self: *const DropTarget, mime: []const u8) bool {
        for (self.mime_types) |m| {
            if (std.mem.eql(u8, m, mime)) return true;
        }
        return false;
    }
};

/// 拖拽状态
pub const DragState = struct {
    active: bool = false,
    data: ?DragData = null,
    /// 拖拽源 widget (启动拖拽的控件)
    source: ?*anyopaque = null,
    /// 拖拽起始坐标
    start_x: f32 = 0,
    start_y: f32 = 0,
    /// 当前坐标
    cur_x: f32 = 0,
    cur_y: f32 = 0,
    /// 拖拽阈值 (超过此距离才真正开始拖拽)
    threshold: f32 = 5.0,
    /// 是否已越过阈值 (真正进入拖拽)
    dragging: bool = false,

    pub fn isActive(self: *const DragState) bool {
        return self.active and self.dragging;
    }

    /// 开始一个潜在的拖拽操作 (mouse_down 时调用)
    pub fn begin(self: *DragState, x: f32, y: f32, source: ?*anyopaque) void {
        self.active = true;
        self.dragging = false;
        self.data = null;
        self.source = source;
        self.start_x = x;
        self.start_y = y;
        self.cur_x = x;
        self.cur_y = y;
    }

    /// 设置拖拽数据并正式启动拖拽
    pub fn setData(self: *DragState, data: DragData) void {
        self.data = data;
        self.dragging = true;
    }

    /// 更新位置 (mouse_move 时调用), 返回是否刚越过阈值
    pub fn update(self: *DragState, x: f32, y: f32) bool {
        self.cur_x = x;
        self.cur_y = y;
        if (!self.active or self.dragging) return false;
        const dx = x - self.start_x;
        const dy = y - self.start_y;
        if (dx * dx + dy * dy > self.threshold * self.threshold) {
            return true; // 超过阈值, 调用者应设置 data 并开始拖拽
        }
        return false;
    }

    /// 结束拖拽 (mouse_release 时调用)
    pub fn end(self: *DragState) ?DragData {
        const result = if (self.dragging) self.data else null;
        self.active = false;
        self.dragging = false;
        self.data = null;
        self.source = null;
        return result;
    }

    /// 取消拖拽
    pub fn cancel(self: *DragState) void {
        self.active = false;
        self.dragging = false;
        self.data = null;
        self.source = null;
    }
};
