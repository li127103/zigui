//! Spinner 控件 - 加载指示器 (环形渐隐旋转点, 需每帧调用 tick 推进动画)

const std = @import("std");
const math = @import("../math.zig");
const widget_mod = @import("widget.zig");
const layout_mod = @import("../layout/engine.zig");

const Widget = widget_mod.Widget;
const PaintContext = widget_mod.PaintContext;

pub const Spinner = struct {
    base: Widget,
    progress: f32, // 0..1 旋转相位
    speed: f32, // 圈/秒
    spoke_count: usize,
    color: math.Color,
    dot_radius: f32,

    pub fn create(allocator: std.mem.Allocator, opts: struct {
        speed: f32 = 1.5,
        spoke_count: usize = 12,
        color: math.Color = math.Color.hex(0x3B82F6FF),
        dot_radius: f32 = 3.0,
        size: f32 = 32.0,
    }) !*Spinner {
        const self = try allocator.create(Spinner);
        self.* = .{
            .base = .{
                .vtable = &vtable,
                .id = widget_mod.genWidgetId(),
            },
            .progress = 0,
            .speed = opts.speed,
            .spoke_count = @max(3, opts.spoke_count),
            .color = opts.color,
            .dot_radius = opts.dot_radius,
        };
        self.base.rect.width = opts.size;
        self.base.rect.height = opts.size;
        self.base.accessibility = .{ .role = .progress, .label = "loading" };
        return self;
    }

    pub fn destroy(self: *Spinner, allocator: std.mem.Allocator) void {
        self.base.background.deinit(allocator);
        self.base.children.deinit(allocator);
        allocator.destroy(self);
    }

    /// 推进动画 (每帧由应用调用, delta_ms 为帧间隔)
    pub fn tick(self: *Spinner, delta_ms: u32) void {
        const delta = @as(f32, @floatFromInt(delta_ms)) / 1000.0 * self.speed;
        self.progress += delta;
        self.progress -= @floor(self.progress);
        self.base.markDirty();
    }

    // ── VTable 实现 ──────────────────────────────────────────────────────────

    const vtable = Widget.VTable{
        .type_name = "spinner",
        .measure = measure,
        .paint = paint,
        .on_event = null,
        .tick = tickVTable,
        .focusable = false,
        .destroy = destroyVTable,
    };

    fn destroyVTable(w: *Widget, allocator: std.mem.Allocator) void {
        const self: *Spinner = @fieldParentPtr("base", w);
        self.destroy(allocator);
    }

    fn tickVTable(w: *Widget, delta_ms: u32) void {
        const self: *Spinner = @fieldParentPtr("base", w);
        self.tick(delta_ms);
    }

    fn measure(w: *Widget, ctx: *PaintContext, constraints: layout_mod.Constraints) math.Size(f32) {
        _ = ctx;
        _ = constraints;
        return .{ .width = w.rect.width, .height = w.rect.height };
    }

    fn paint(w: *Widget, ctx: *PaintContext) void {
        const self: *Spinner = @fieldParentPtr("base", w);
        const rx = ctx.offset_x + w.rect.x;
        const ry = ctx.offset_y + w.rect.y;

        const cx = rx + w.rect.width / 2.0;
        const cy = ry + w.rect.height / 2.0;
        const ring_r = @min(w.rect.width, w.rect.height) / 2.0 - self.dot_radius;
        if (ring_r <= 0) return;

        const two_pi = std.math.pi * 2.0;
        const n_f: f32 = @floatFromInt(self.spoke_count);

        var i: usize = 0;
        while (i < self.spoke_count) : (i += 1) {
            const frac = @as(f32, @floatFromInt(i)) / n_f;
            // 头部在 progress 相位, 尾部按 frac 逆序渐隐
            const angle = self.progress * two_pi - frac * two_pi;
            const dx = cx + ring_r * @cos(angle);
            const dy = cy + ring_r * @sin(angle);
            // 头部 (i=0) 最不透明, 尾部渐隐至 ~15%
            const alpha = 1.0 - frac * 0.85;
            const color = math.Color{
                .r = self.color.r,
                .g = self.color.g,
                .b = self.color.b,
                .a = @intFromFloat(alpha * @as(f32, @floatFromInt(self.color.a))),
            };
            const r = self.dot_radius;
            ctx.renderer.fillRoundedRect(
                .{ .x = dx - r, .y = dy - r, .width = r * 2, .height = r * 2 },
                r,
                color,
            ) catch {};
        }
    }
};

// ── Tests ──────────────────────────────────────────────────────────────────

test "spinner tick advances and wraps phase" {
    const sp = try Spinner.create(std.testing.allocator, .{ .speed = 1.0 });
    defer sp.destroy(std.testing.allocator);

    try std.testing.expectEqual(@as(f32, 0), sp.progress);
    // speed=1 圈/秒, 500ms → 0.5
    sp.tick(500);
    try std.testing.expectApproxEqAbs(@as(f32, 0.5), sp.progress, 0.0001);
    // 再 600ms → 1.1 → 回绕到 0.1
    sp.tick(600);
    try std.testing.expectApproxEqAbs(@as(f32, 0.1), sp.progress, 0.0001);
}

test "spinner enforces minimum spoke count" {
    const sp = try Spinner.create(std.testing.allocator, .{ .spoke_count = 1 });
    defer sp.destroy(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 3), sp.spoke_count);
}

test "spinner create sets explicit size" {
    const sp = try Spinner.create(std.testing.allocator, .{ .size = 48 });
    defer sp.destroy(std.testing.allocator);
    try std.testing.expectEqual(@as(f32, 48), sp.base.rect.width);
    try std.testing.expectEqual(@as(f32, 48), sp.base.rect.height);
}
