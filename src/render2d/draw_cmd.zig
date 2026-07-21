//! 绘制命令

const math = @import("../math.zig");
const path_mod = @import("path.zig");

pub const FillRule = enum { non_zero, even_odd };
pub const StrokeCap = enum { butt, round, square };
pub const StrokeJoin = enum { miter, round, bevel };

pub const DrawCmd = union(enum) {
    fill: struct {
        path: *const path_mod.Path,
        brush: Brush,
        rule: FillRule = .non_zero,
    },
    stroke: struct {
        path: *const path_mod.Path,
        brush: Brush,
        width: f32,
        cap: StrokeCap = .butt,
        join: StrokeJoin = .miter,
        miter_limit: f32 = 4.0,
    },
    draw_image: struct {
        texture_handle: u64,
        src_rect: math.Rect(f32),
        dst_rect: math.Rect(f32),
        tint: math.Color = .white,
        corner_radius: [4]f32 = .{ 0, 0, 0, 0 },
    },
    push_clip: math.Rect(f32),
    pop_clip: void,
    push_transform: math.Mat3x2,
    pop_transform: void,
    push_opacity: f32,
    pop_opacity: void,
};

pub const Brush = union(enum) {
    solid: math.Color,
    linear_gradient: LinearGradient,
    radial_gradient: RadialGradient,
};

pub const LinearGradient = struct {
    start: [2]f32,
    end: [2]f32,
    stops: []const GradientStop,
};

pub const RadialGradient = struct {
    center: [2]f32,
    radius: f32,
    stops: []const GradientStop,
};

pub const GradientStop = struct {
    offset: f32,
    color: math.Color,
};
