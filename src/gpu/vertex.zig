//! 2D UI 渲染顶点格式

/// 2D UI 渲染统一顶点格式 (24 bytes)
pub const Vertex2D = packed struct {
    pos: [2]f32, // 屏幕坐标 (像素)
    uv: [2]f32, // 纹理坐标
    color: [4]u8, // RGBA (premultiplied alpha)
    flags: u32, // 渲染模式标志
};

pub const RenderMode = enum(u4) {
    solid_color = 0,
    textured = 1,
    text_sdf = 2,
    linear_gradient = 3,
    radial_gradient = 4,
};

pub fn makeFlags(mode: RenderMode) u32 {
    return @intFromEnum(mode);
}

comptime {
    if (@sizeOf(Vertex2D) != 24) @compileError("Vertex2D must be 24 bytes");
}
