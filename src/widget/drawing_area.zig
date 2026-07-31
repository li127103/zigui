//! DrawingArea 控件 (对标 GtkDrawingArea)
//!
//! 提供一个可自定义绘制的矩形画布。调用方通过 setDrawFunc()
//! 注册绘制回调，在回调中使用 PaintContext (cr) 画任意 2D 内容。
//!
//! 典型用法:
//!   const da = try DrawingArea.create(allocator, .{ .content_width = 640, .content_height = 480 });
//!   da.setDrawFunc(&drawChart, my_chart);
//!   ...
//!   fn drawChart(cr: *PaintContext, w: f32, h: f32, userdata: ?*anyopaque) void {
//!       const chart: *Chart = @ptrCast(@alignCast(userdata orelse return));
//!       _ = chart;
//!       cr.fillRect(.{ .x = 0, .y = 0, .width = w, .height = h }, Color.white) catch {};
//!       cr.fillRoundedRect(.{...}, 8, Color.hex(0x3B82F6FF)) catch {};
//!   }

const std = @import("std");
const math = @import("../math.zig");
const widget_mod = @import("widget.zig");
const layout_mod = @import("../layout/engine.zig");

const Widget = widget_mod.Widget;
const PaintContext = widget_mod.PaintContext;
const EventContext = widget_mod.EventContext;
const EventResult = widget_mod.EventResult;
const Allocator = std.mem.Allocator;

/// 绘制回调签名: (PaintContext*, width, height, userdata)
pub const DrawFunc = *const fn (cr: *PaintContext, width: f32, height: f32, userdata: ?*anyopaque) void;

pub const DrawingArea = struct {
    pub const Self = @This();

    base: Widget,
    /// 内容请求宽度 (measure 时用)
    content_width: f32 = 200,
    /// 内容请求高度 (measure 时用)
    content_height: f32 = 200,
    /// 最小内容宽高
    min_width: f32 = 0,
    min_height: f32 = 0,
    /// 绘制函数
    draw_func: ?DrawFunc = null,
    draw_func_userdata: ?*anyopaque = null,
    /// 可选: destroy(userdata) — 在 DrawingArea.destroy 时被调用
    destroy_userdata: ?*const fn (data: ?*anyopaque) void = null,

    pub fn create(allocator: Allocator, opts: struct {
        content_width: f32 = 200,
        content_height: f32 = 200,
        min_width: f32 = 0,
        min_height: f32 = 0,
        draw_func: ?DrawFunc = null,
        draw_func_userdata: ?*anyopaque = null,
    }) !*Self {
        const self = try allocator.create(Self);
        self.* = .{
            .base = .{
                .vtable = &vtable,
                .id = widget_mod.genWidgetId(),
            },
            .content_width = opts.content_width,
            .content_height = opts.content_height,
            .min_width = opts.min_width,
            .min_height = opts.min_height,
            .draw_func = opts.draw_func,
            .draw_func_userdata = opts.draw_func_userdata,
        };
        return self;
    }

    pub fn destroy(self: *Self, allocator: Allocator) void {
        if (self.destroy_userdata) |f| f(self.draw_func_userdata);
        self.base.background.deinit(allocator);
        self.base.children.deinit(allocator);
        allocator.destroy(self);
    }

    /// 注册绘制回调 (设置后需要刷新可调用 queueDraw)
    pub fn setDrawFunc(self: *Self, f: ?DrawFunc, userdata: ?*anyopaque) void {
        self.draw_func = f;
        self.draw_func_userdata = userdata;
        self.base.markDirty();
    }

    /// 请求重绘 (等同 markDirty)
    pub fn queueDraw(self: *Self) void {
        self.base.markDirty();
    }

    /// 设置内容请求尺寸 (下次 measure 时生效)
    pub fn setContentSize(self: *Self, w: f32, h: f32) void {
        self.content_width = w;
        self.content_height = h;
        self.base.markDirty();
    }

    // ── VTable ──────────────────────────────────────────────────────────────

    const vtable = Widget.VTable{
        .type_name = "drawing_area",
        .measure = measure,
        .paint = paint,
        .on_event = onEvent,
        .focusable = true,
        .destroy = destroyVTable,
    };

    fn destroyVTable(w: *Widget, allocator: Allocator) void {
        const self: *Self = @fieldParentPtr("base", w);
        self.destroy(allocator);
    }

    fn measure(w: *Widget, _: *PaintContext, constraints: layout_mod.Constraints) math.Size(f32) {
        const self: *Self = @fieldParentPtr("base", w);
        const cw = @max(self.content_width, self.min_width);
        const ch = @max(self.content_height, self.min_height);
        return constraints.constrain(.{ .width = cw, .height = ch });
    }

    fn paint(w: *Widget, ctx: *PaintContext) void {
        const self: *Self = @fieldParentPtr("base", w);
        if (self.draw_func) |f| {
            const prev_ox = ctx.offset_x;
            const prev_oy = ctx.offset_y;
            // 把 ctx 坐标原点平移到控件左上角, 用户可以直接从 (0,0) 开始画
            ctx.offset_x = prev_ox + w.rect.x;
            ctx.offset_y = prev_oy + w.rect.y;
            defer {
                ctx.offset_x = prev_ox;
                ctx.offset_y = prev_oy;
            }
            f(ctx, w.rect.width, w.rect.height, self.draw_func_userdata);
        }
    }

    fn onEvent(_: *Widget, _: *const @import("../pal/pal.zig").Event, _: *EventContext) EventResult {
        // DrawingArea 不自带交互逻辑, 用户可自行在外部或通过子类化扩展
        return .ignored;
    }
};
