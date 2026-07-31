//! GraphicsOffload — GTK4.14 GtkGraphicsOffload 离屏容器
//!
//! 单控件容器：若 enabled=true，先将子控件树离屏绘制到 GPU 纹理，再一次贴图。
//! 性能场景：复杂且稳定的 UI 区域（如地图、游戏画面、canvas）。
//! 若 enabled=false，退化为普通子控件绘制（不影响正确性）。
//!

const std = @import("std");
const math = @import("../math.zig");
const widget_mod = @import("widget.zig");
const layout_mod = @import("../layout/engine.zig");

const Widget = widget_mod.Widget;
const PaintContext = widget_mod.PaintContext;
const EventContext = widget_mod.EventContext;
const EventResult = widget_mod.EventResult;
const Constraints = layout_mod.Constraints;
const SizeF = math.Size(f32);
const RectF = math.Rect(f32);

pub const GraphicsOffload = struct {
    base: Widget,
    allocator: std.mem.Allocator,
    child: ?*Widget = null,

    enabled: bool = true,
    area: RectF = .{ .x = 0, .y = 0, .width = 0, .height = 0 },
    // 真实实现：vulkan texture / GL FBO / cairo_surface 句柄
    gpu_handle: ?*anyopaque = null,
    needs_redraw: bool = true,

    const Self = @This();

    pub fn create(allocator: std.mem.Allocator) !*Self {
        const self = try allocator.create(Self);
        self.* = .{
            .base = .{
                .vtable = &vtable,
                .id = widget_mod.genWidgetId(),
            },
            .allocator = allocator,
        };
        return self;
    }

    pub fn destroy(self: *Self) void {
        const a = self.allocator;
        // 若 child 由 us 拥有（此处非强所有权模型），不释放 child
        a.destroy(self);
    }

    pub fn getChild(self: *const Self) ?*Widget {
        return self.child;
    }

    pub fn setChild(self: *Self, child: ?*Widget) void {
        self.child = child;
        self.needs_redraw = true;
    }

    pub fn setEnabled(self: *Self, v: bool) void {
        if (self.enabled != v) {
            self.enabled = v;
            self.needs_redraw = true;
        }
    }
    pub fn getEnabled(self: *const Self) bool {
        return self.enabled;
    }

    pub fn getArea(self: *const Self) RectF {
        return self.area;
    }
    pub fn markRedraw(self: *Self) void {
        self.needs_redraw = true;
    }

    // ── VTable ───────────────────────────────────────────────────────────

    const vtable = Widget.VTable{
        .type_name = "graphics_offload",
        .measure = measure,
        .paint = paint,
        .on_event = onEvent,
        .destroy = destroyVTable,
    };

    fn destroyVTable(w: *Widget, a: std.mem.Allocator) void {
        const s: *Self = @fieldParentPtr("base", w);
        _ = a;
        s.destroy();
    }

    fn measure(w: *Widget, ctx: *PaintContext, c: Constraints) SizeF {
        const s: *Self = @fieldParentPtr("base", w);
        if (s.child) |ch| {
            const sz = ch.vtable.measure(ch, ctx, c);
            s.area = .{ .x = 0, .y = 0, .width = sz.width, .height = sz.height };
            return c.constrain(sz);
        }
        return c.constrain(.{ .width = 0, .height = 0 });
    }

    fn paint(w: *Widget, ctx: *PaintContext) void {
        const s: *Self = @fieldParentPtr("base", w);
        const ch = s.child orelse return;
        if (s.enabled) {
            // enabled = 真实实现：先把 ch.paintTree 绘制到离屏纹理
            //   需要新建纹理（若 gpu_handle=null 或 needs_redraw=true）→ 然后一次贴图
            // 占位：直接渲染；性能优化由后端实现
            _ = s.needs_redraw;
            _ = s.gpu_handle;
        }
        // 否则直接 paint；此处两种情况都按直接 paint 调用（占位正确）
        Widget.paintTree(ch, ctx);
    }

    fn onEvent(w: *Widget, event: *const @import("../pal/pal.zig").Event, ectx: *EventContext) EventResult {
        const s: *Self = @fieldParentPtr("base", w);
        // 事件仍转发给 child（离屏纹理不影响交互）
        const ch = s.child orelse return .ignored;
        return Widget.dispatchEvent(ch, event, ectx);
    }
};
