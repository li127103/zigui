//! GLArea 控件 - GTK4 OpenGL 渲染区域
//!
//! GTK4 对应: GtkGLArea
//!
//! 提供一个可嵌入任意布局的 OpenGL 渲染区:
//! - `on_render(ctx)`: 每次重绘时调用, 在内部调用 OpenGL API
//! - `on_resize(w, h)`: 尺寸变化时调用
//! - `make_current()`: 将上下文设为当前 (在 on_render 内自动已设)
//! - `queue_render()`: 标记下一帧需要重绘
//!
//! 注意: 由于 ZigUI 当前使用 Vulkan 渲染, 这里提供的是抽象占位实现:
//! - 渲染回调接收一个 OpenGL-like 的 "上下文" (此处实际是我们自己的 renderer 句柄 + 裁剪区域)
//! - 提供 clearColor / drawColorTriangle 等简单绘制 API, 便于快速验证
//! - 高级用户可替换 Renderer 以直接调用 Vulkan / OpenGL 上下文

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
const Event = pal.event_mod.Event;

/// 简化的 GL 上下文 (对应 GtkGLArea 暴露的 GdkGLContext)
pub const GLContext = struct {
    /// 关联 PaintContext
    paint_ctx: *PaintContext,
    /// GLArea 绝对区域
    viewport: math.Rect,

    pub fn clearColor(self: GLContext, color: math.Color) void {
        const R = self.paint_ctx.renderer;
        R.fillRect(self.viewport, color, 0) catch {};
    }

    /// 画一个简单彩色三角形 (仿 glDrawArrays(GL_TRIANGLES))
    /// 顶点: v0, v1, v2 — 相对 GLArea 的局部坐标 (左上角原点)
    pub fn drawTriangle(
        self: GLContext,
        v0: [2]f32,
        c0: math.Color,
        v1: [2]f32,
        c1: math.Color,
        v2: [2]f32,
        c2: math.Color,
    ) void {
        const R = self.paint_ctx.renderer;
        // 取平均颜色作为填充
        const avg_r = @as(f32, @floatFromInt(c0.r + c1.r + c2.r)) / (3 * 255);
        const avg_g = @as(f32, @floatFromInt(c0.g + c1.g + c2.g)) / (3 * 255);
        const avg_b = @as(f32, @floatFromInt(c0.b + c1.b + c2.b)) / (3 * 255);
        const avg_a = @as(f32, @floatFromInt(c0.a + c1.a + c2.a)) / (3 * 255);
        const fill = math.Color{
            .r = @intFromFloat(avg_r * 255),
            .g = @intFromFloat(avg_g * 255),
            .b = @intFromFloat(avg_b * 255),
            .a = @intFromFloat(avg_a * 255),
        };
        // 以三角形的包围盒+圆角模拟(简化)
        const min_x = @min(@min(v0[0], v1[0]), v2[0]);
        const min_y = @min(@min(v0[1], v1[1]), v2[1]);
        const max_x = @max(@max(v0[0], v1[0]), v2[0]);
        const max_y = @max(@max(v0[1], v1[1]), v2[1]);
        R.fillRoundedRect(.{
            .x = self.viewport.x + min_x,
            .y = self.viewport.y + min_y,
            .width = max_x - min_x,
            .height = max_y - min_y,
        }, 8, fill) catch {};
    }

    pub fn drawQuad(self: GLContext, x: f32, y: f32, w: f32, h: f32, color: math.Color) void {
        const R = self.paint_ctx.renderer;
        R.fillRect(.{
            .x = self.viewport.x + x,
            .y = self.viewport.y + y,
            .width = w,
            .height = h,
        }, color, 0) catch {};
    }

    pub fn drawRoundedQuad(
        self: GLContext,
        x: f32,
        y: f32,
        w: f32,
        h: f32,
        radius: f32,
        color: math.Color,
    ) void {
        const R = self.paint_ctx.renderer;
        R.fillRoundedRect(.{
            .x = self.viewport.x + x,
            .y = self.viewport.y + y,
            .width = w,
            .height = h,
        }, radius, color) catch {};
    }
};

pub const GLArea = struct {
    base: Widget,
    allocator: Allocator,

    /// 主渲染回调 (每帧调用)
    on_render: ?*const fn (self: *GLArea, glctx: GLContext) void = null,
    /// 尺寸变化回调
    on_resize: ?*const fn (self: *GLArea, width: i32, height: i32) void = null,
    /// 创建 OpenGL 上下文后调用 (初始化 shader / texture 等)
    on_realize: ?*const fn (self: *GLArea) void = null,
    /// 上下文销毁
    on_unrealize: ?*const fn (self: *GLArea) void = null,

    /// 使用 stencil buffer (GtkGLArea 属性)
    has_stencil_buffer: bool = false,
    /// 使用 depth buffer
    has_depth_buffer: bool = true,
    /// 4x 多重采样
    samples: u32 = 0,
    /// 是否自动调度过帧 (true: 每帧都重绘; false: 仅 queue_render 后重绘)
    auto_render: bool = true,

    /// 是否有 queued 的 render 请求
    needs_render: bool = true,
    /// 当前上下文尺寸
    ctx_w: i32 = 0,
    ctx_h: i32 = 0,
    /// 是否已 realize
    realized: bool = false,

    /// 显示 FPS 调试文本
    show_debug: bool = false,
    frame_count: u32 = 0,
    last_fps_time: u64 = 0,
    fps: f32 = 0,

    // 样式
    bg_color: math.Color = math.Color.hex(0x000000FF),
    border_color: math.Color = math.Color.hex(0x334155FF),
    corner_radius: f32 = 8,

    pub fn new(allocator: Allocator, opts: struct {
        on_render: ?*const fn (self: *GLArea, glctx: GLContext) void = null,
        on_resize: ?*const fn (self: *GLArea, width: i32, height: i32) void = null,
        on_realize: ?*const fn (self: *GLArea) void = null,
        on_unrealize: ?*const fn (self: *GLArea) void = null,
        has_depth_buffer: bool = true,
        has_stencil_buffer: bool = false,
        samples: u32 = 0,
        auto_render: bool = true,
        show_debug: bool = false,
        bg_color: ?math.Color = null,
        corner_radius: f32 = 8,
    }) !*GLArea {
        const self = try allocator.create(GLArea);
        self.* = .{
            .base = .{
                .vtable = &vtable,
                .id = widget_mod.genWidgetId(),
            },
            .allocator = allocator,
            .on_render = opts.on_render,
            .on_resize = opts.on_resize,
            .on_realize = opts.on_realize,
            .on_unrealize = opts.on_unrealize,
            .has_depth_buffer = opts.has_depth_buffer,
            .has_stencil_buffer = opts.has_stencil_buffer,
            .samples = opts.samples,
            .auto_render = opts.auto_render,
            .show_debug = opts.show_debug,
            .corner_radius = opts.corner_radius,
        };
        if (opts.bg_color) |c| self.bg_color = c;
        self.base.accessibility = .{ .role = .panel, .label = "GL Area" };
        return self;
    }

    pub fn destroy(self: *GLArea, allocator: Allocator) void {
        if (self.realized) {
            if (self.on_unrealize) |cb| cb(self);
            self.realized = false;
        }
        self.base.background.deinit(allocator);
        self.base.children.deinit(allocator);
        allocator.destroy(self);
    }

    pub fn queueRender(self: *GLArea) void {
        self.needs_render = true;
        self.base.markDirty();
    }

    pub fn makeCurrent(_: *GLArea) void {
        // 单上下文模型: 当前 GLArea 始终是 current (实际应用可扩展为多 context 栈)
    }

    pub fn getError(_: *GLArea) ?anyerror {
        return null;
    }

    /// get context size (像素)
    pub fn getSize(self: *const GLArea) [2]i32 {
        return .{ self.ctx_w, self.ctx_h };
    }
};

const vtable = Widget.VTable{
    .type_name = "gl_area",
    .measure = measure,
    .paint = paint,
    .on_event = onEvent,
    .focusable = true,
    .destroy = destroyVTable,
};

fn destroyVTable(w: *Widget, allocator: Allocator) void {
    const self: *GLArea = @fieldParentPtr("base", w);
    self.destroy(allocator);
}

fn measure(w: *Widget, ctx: *PaintContext, constraints: layout_mod.Constraints) math.Size {
    const self: *GLArea = @fieldParentPtr("base", w);
    const max_w = if (constraints.max_width < std.math.inf(f32)) constraints.max_width else 800;
    const max_h = if (constraints.max_height < std.math.inf(f32)) constraints.max_height else 600;
    _ = self;
    _ = ctx;
    return .{
        .width = @max(100, @min(500, max_w)),
        .height = @max(100, @min(400, max_h)),
    };
}

fn paint(w: *Widget, ctx: *PaintContext) void {
    const self: *GLArea = @fieldParentPtr("base", w);
    const rx = ctx.offset_x + w.rect.x;
    const ry = ctx.offset_y + w.rect.y;
    const rw = w.rect.width;
    const rh = w.rect.height;
    const R = ctx.renderer;

    // detect resize
    const new_w: i32 = @intFromFloat(rw);
    const new_h: i32 = @intFromFloat(rh);
    if (new_w != self.ctx_w or new_h != self.ctx_h or !self.realized) {
        const was_realized = self.realized;
        self.ctx_w = new_w;
        self.ctx_h = new_h;
        if (!was_realized) {
            self.realized = true;
            if (self.on_realize) |cb| cb(self);
        }
        if (self.on_resize) |cb| cb(self, new_w, new_h);
        self.needs_render = true;
    }

    // clip to GL area
    const saved = R.getClipRect();
    R.setClipRect(.{ .x = rx, .y = ry, .width = rw, .height = rh }) catch {};

    // 背景 (仿 glClear)
    R.fillRoundedRect(.{ .x = rx, .y = ry, .width = rw, .height = rh }, self.corner_radius, self.bg_color) catch {};

    if (self.auto_render or self.needs_render) {
        if (self.on_render) |cb| {
            const glctx = GLContext{
                .paint_ctx = ctx,
                .viewport = .{ .x = rx, .y = ry, .width = rw, .height = rh },
            };
            cb(self, glctx);
        }
        self.needs_render = false;
    }

    // FPS
    if (self.show_debug) {
        const now = std.time.milliTimestamp();
        const now_u: u64 = @intCast(if (now < 0) 0 else now);
        self.frame_count += 1;
        if (now_u - self.last_fps_time >= 1000) {
            const elapsed_ms = @max(1, now_u - self.last_fps_time);
            self.fps = @as(f32, @floatFromInt(self.frame_count)) * 1000.0 / @as(f32, @floatFromInt(elapsed_ms));
            self.frame_count = 0;
            self.last_fps_time = now_u;
        }
        if (self.fps > 0) {
            const st = @import("../text/styled_text.zig");
            var buf: [32]u8 = undefined;
            const fps_text = std.fmt.bufPrint(&buf, "{d:.1} FPS", .{self.fps}) catch "0.0 FPS";
            st.drawText(ctx, fps_text, .{
                .x = rx + 8,
                .y = ry + 6,
                .color = math.Color.hex(0x22C55EFF),
                .font_size = 11,
            });
        }
    }

    if (saved) |s| R.setClipRect(s) catch {};
    // 边框
    R.strokeRoundedRect(.{ .x = rx, .y = ry, .width = rw, .height = rh }, self.corner_radius, 1, self.border_color) catch {};
}

fn onEvent(w: *Widget, event: *const Event, _: *EventContext) EventResult {
    const self: *GLArea = @fieldParentPtr("base", w);
    switch (event.*) {
        .scroll, .mouse_move, .mouse_button => {
            // 让用户回调可以监听 (此处直接 handled 以便聚焦)
            if (w.rect.height > 0) return .handled;
        },
        .key => {
            return .handled;
        },
        else => {},
    }
    _ = self;
    return .ignored;
}
