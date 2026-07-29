//! WidgetPaintable — 将 Widget 渲染为 Paintable（屏幕快照/缩略图）
//!
//! 对标 GTK4 `GtkWidgetPaintable`：实现 `GdkPaintable` 接口，把 Widget 的
//! paintTree 输出作为 Paintable 的 snapshot 内容，用于缩略图、打印预览等场景。
//!

const std = @import("std");
const math = @import("../math.zig");
const widget_mod = @import("widget.zig");
const Widget = widget_mod.Widget;
const paintable_mod = @import("paintable.zig");
const Paintable = paintable_mod.Paintable;
const PaintableIface = paintable_mod.PaintableIface;
const PaintableFlags = paintable_mod.PaintableFlags;

const RectF = math.Rect(f32);

pub const WidgetPaintable = struct {
    allocator: std.mem.Allocator,
    widget: ?*Widget = null,
    // 若指定 > 0，则快照尺寸固定；否则用 widget 的 rect
    explicit_width: i32 = 0,
    explicit_height: i32 = 0,
    user_data: ?*anyopaque = null,

    // 信号占位 (真实实现会维护监听列表)
    on_invalidate_contents: ?*const fn (ud: ?*anyopaque, rect: ?*const RectF) void = null,
    on_invalidate_contents_ud: ?*anyopaque = null,
    on_invalidate_size: ?*const fn (ud: ?*anyopaque) void = null,
    on_invalidate_size_ud: ?*anyopaque = null,

    const Self = @This();

    pub fn create(allocator: std.mem.Allocator, widget: ?*Widget) !*Self {
        const self = try allocator.create(Self);
        self.* = .{ .allocator = allocator, .widget = widget };
        return self;
    }

    pub fn destroy(self: *Self) void {
        const a = self.allocator;
        a.destroy(self);
    }

    pub fn setWidget(self: *Self, widget: ?*Widget) void {
        if (self.widget != widget) {
            self.widget = widget;
            self.invalidateSize();
            self.invalidateContents(null);
        }
    }

    pub fn getWidget(self: *const Self) ?*Widget { return self.widget; }

    pub fn setSize(self: *Self, w: i32, h: i32) void {
        if (self.explicit_width != w or self.explicit_height != h) {
            self.explicit_width = w;
            self.explicit_height = h;
            self.invalidateSize();
        }
    }

    fn effSize(self: *const Self) struct { w: i32, h: i32 } {
        if (self.explicit_width > 0 or self.explicit_height > 0)
            return .{ .w = self.explicit_width, .h = self.explicit_height };
        if (self.widget) |w| {
            return .{
                .w = @intFromFloat(@max(1.0, w.rect.width)),
                .h = @intFromFloat(@max(1.0, w.rect.height)),
            };
        }
        return .{ .w = 0, .h = 0 };
    }

    // ── Paintable 信号 ────────────────────────────────────────────────────

    pub fn invalidateContents(self: *Self, rect: ?*const RectF) void {
        if (self.on_invalidate_contents) |cb| cb(self.on_invalidate_contents_ud, rect);
    }
    pub fn invalidateSize(self: *Self) void {
        if (self.on_invalidate_size) |cb| cb(self.on_invalidate_size_ud);
    }

    pub fn setOnInvalidateContents(self: *Self, cb: ?*const fn (ud: ?*anyopaque, rect: ?*const RectF) void, ud: ?*anyopaque) void {
        self.on_invalidate_contents = cb; self.on_invalidate_contents_ud = ud;
    }
    pub fn setOnInvalidateSize(self: *Self, cb: ?*const fn (ud: ?*anyopaque) void, ud: ?*anyopaque) void {
        self.on_invalidate_size = cb; self.on_invalidate_size_ud = ud;
    }

    // ── PaintableIface 实现 ───────────────────────────────────────────────

    fn paintGetCurrentImage(sp: ?*anyopaque) ?*anyopaque {
        _ = sp; return null;
    }
    fn paintGetFlags(sp: ?*anyopaque) PaintableFlags {
        _ = sp; return .{};
    }
    fn paintGetWidth(sp: ?*anyopaque) i32 {
        const s: *Self = @ptrCast(@alignCast(sp orelse return 0));
        return s.effSize().w;
    }
    fn paintGetHeight(sp: ?*anyopaque) i32 {
        const s: *Self = @ptrCast(@alignCast(sp orelse return 0));
        return s.effSize().h;
    }
    fn paintGetAspectRatio(sp: ?*anyopaque) f32 {
        const s: *Self = @ptrCast(@alignCast(sp orelse return 1.0));
        const sz = s.effSize();
        if (sz.h == 0) return 1.0;
        return @as(f32, @floatFromInt(sz.w)) / @as(f32, @floatFromInt(sz.h));
    }
    fn paintSnapshot(sp: ?*anyopaque, snapshot_ptr: ?*anyopaque, w: f32, h: f32) void {
        const s: *Self = @ptrCast(@alignCast(sp orelse return));
        const wid = s.widget orelse {
            // 无 widget：占位（后续 GPU 实现可绘制空矩形）
            return;
        };
        // 真正实现：调用 Widget.paintTree 输出到 snapshot。
        _ = wid;
        _ = snapshot_ptr;
        _ = w;
        _ = h;
    }

    pub fn asPaintable(self: *Self) Paintable {
        const iface = PaintableIface{
            .snapshot = paintSnapshot,
            .get_current_image = paintGetCurrentImage,
            .get_flags = paintGetFlags,
            .get_intrinsic_width = paintGetWidth,
            .get_intrinsic_height = paintGetHeight,
            .get_intrinsic_aspect_ratio = paintGetAspectRatio,
        };
        return Paintable.wrap(self, iface);
    }
};
