//! Spinner 控件 - 加载动画 (对标 GtkSpinner)

const std = @import("std");
const math = @import("../math.zig");
const widget_mod = @import("widget.zig");
const layout_mod = @import("../layout/engine.zig");
const pal = @import("../pal/pal.zig");

const Widget = widget_mod.Widget;
const PaintContext = widget_mod.PaintContext;
const EventContext = widget_mod.EventContext;
const EventResult = widget_mod.EventResult;

pub const Spinner = struct {
    base: Widget,
    /// 是否处于活动状态（旋转中）
    active: bool,
    /// 尺寸（宽高相同）
    size: f32,
    /// 线条宽度
    stroke_width: f32,
    /// 主色调
    color: math.Color,
    /// 背景弧颜色
    track_color: math.Color,
    /// 旋转速度倍数 (1.0 = 默认)
    speed: f32,
    /// 当前旋转角度（弧度）
    angle: f32 = 0,
    /// 弧长（弧度，0.2~0.8 之间脉动）
    arc_length: f32 = 0.5,
    arc_phase: f32 = 0,

    pub fn create(allocator: std.mem.Allocator, opts: struct {
        active: bool = true,
        size: f32 = 24,
        stroke_width: f32 = 2.5,
        color: math.Color = math.Color.hex(0x3B82F6FF),
        track_color: math.Color = math.Color.hex(0xE2E8F0FF),
        speed: f32 = 1.0,
        dot_radius: f32 = 0,
    }) !*Spinner {
        const self = try allocator.create(Spinner);
        const sw = if (opts.dot_radius > 0) opts.dot_radius * 2 else opts.stroke_width;
        self.* = .{
            .base = .{
                .vtable = &vtable,
                .id = widget_mod.genWidgetId(),
            },
            .active = opts.active,
            .size = opts.size,
            .stroke_width = sw,
            .color = opts.color,
            .track_color = opts.track_color,
            .speed = opts.speed,
        };
        return self;
    }

    pub fn destroy(self: *Spinner, allocator: std.mem.Allocator) void {
        self.base.background.deinit(allocator);
        self.base.children.deinit(allocator);
        allocator.destroy(self);
    }

    pub fn start(self: *Spinner) void {
        self.active = true;
        self.base.markDirty();
    }

    pub fn stop(self: *Spinner) void {
        self.active = false;
        self.base.markDirty();
    }

    pub fn tick(self: *Spinner, delta_ms: u32) void {
        if (!self.active) return;

        const dt = @as(f32, @floatFromInt(delta_ms)) / 1000.0;
        self.angle += dt * 3.0 * std.math.tau * self.speed;
        self.angle = std.math.mod(f32, self.angle, std.math.tau) catch 0;

        self.arc_phase += dt * 1.5 * self.speed;
        const pulse = 0.5 + 0.5 * @sin(self.arc_phase);
        self.arc_length = 0.25 + pulse * 0.45;

        self.base.markDirty();
    }

    const vtable = Widget.VTable{
        .type_name = "spinner",
        .measure = measure,
        .paint = paint,
        .tick = tickVTable,
        .destroy = destroyVTable,
    };

    fn destroyVTable(w: *Widget, allocator: std.mem.Allocator) void {
        const self: *Spinner = @fieldParentPtr("base", w);
        self.destroy(allocator);
    }

    fn measure(w: *Widget, ctx: *PaintContext, constraints: layout_mod.Constraints) math.Size(f32) {
        const self: *Spinner = @fieldParentPtr("base", w);
        _ = constraints;
        _ = ctx;
        return .{
            .width = self.size,
            .height = self.size,
        };
    }

    fn tickVTable(w: *Widget, delta_ms: u32) void {
        const self: *Spinner = @fieldParentPtr("base", w);
        self.tick(delta_ms);
    }

    fn drawArc(
        renderer: anytype,
        cx: f32,
        cy: f32,
        radius: f32,
        start_angle: f32,
        end_angle: f32,
        width: f32,
        color: math.Color,
    ) !void {
        const segments: usize = 48;
        var i: usize = 0;
        while (i < segments) : (i += 1) {
            const t1 = @as(f32, @floatFromInt(i)) / @as(f32, @floatFromInt(segments));
            const t2 = @as(f32, @floatFromInt(i + 1)) / @as(f32, @floatFromInt(segments));
            const a1 = start_angle + t1 * (end_angle - start_angle);
            const a2 = start_angle + t2 * (end_angle - start_angle);

            const x1o = cx + (radius + width / 2.0) * @cos(a1);
            const y1o = cy + (radius + width / 2.0) * @sin(a1);
            const x2o = cx + (radius + width / 2.0) * @cos(a2);
            const y2o = cy + (radius + width / 2.0) * @sin(a2);
            const x1i = cx + (radius - width / 2.0) * @cos(a1);
            const y1i = cy + (radius - width / 2.0) * @sin(a1);
            const x2i = cx + (radius - width / 2.0) * @cos(a2);
            const y2i = cy + (radius - width / 2.0) * @sin(a2);

            const pts = [_][2]f32{
                .{ x1o, y1o },
                .{ x2o, y2o },
                .{ x2i, y2i },
                .{ x1i, y1i },
            };
            try renderer.fillConvexPolygon(&pts, color);
        }
    }

    fn paint(w: *Widget, ctx: *PaintContext) void {
        const self: *Spinner = @fieldParentPtr("base", w);

        const rx = ctx.offset_x + w.rect.x;
        const ry = ctx.offset_y + w.rect.y;

        const cx = rx + w.rect.width / 2.0;
        const cy = ry + w.rect.height / 2.0;
        const radius = @min(w.rect.width, w.rect.height) / 2.0 - self.stroke_width;

        drawArc(
            ctx.renderer,
            cx,
            cy,
            radius,
            0,
            std.math.tau,
            self.stroke_width,
            self.track_color,
        ) catch {};

        if (self.active) {
            const start_angle = self.angle;
            const end_angle = self.angle + self.arc_length * std.math.tau;
            drawArc(
                ctx.renderer,
                cx,
                cy,
                radius,
                start_angle,
                end_angle,
                self.stroke_width,
                self.color,
            ) catch {};
        }
    }
};
