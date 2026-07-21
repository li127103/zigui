//! Metal GPU 后端 (macOS) - 通过 ObjC helper 层

const c = @cImport({
    @cInclude("metal_backend.h");
});

pub const Vertex2D = extern struct {
    pos: [2]f32,
    color: [4]f32,
};

pub const TextVertex = extern struct {
    pos: [2]f32,
    uv: [2]f32,
    color: [4]f32,
};

pub const MetalDevice = struct {
    handle: *c.ZiguiMetalDevice,

    pub fn init(metal_layer: *anyopaque, max_vertices: u32) !MetalDevice {
        const handle = c.zigui_metal_init(metal_layer, max_vertices) orelse return error.MetalInitFailed;
        return .{ .handle = handle };
    }

    pub fn deinit(self: *MetalDevice) void {
        c.zigui_metal_destroy(self.handle);
    }

    /// 获取当前 drawable 并创建 render encoder，返回 framebuffer 尺寸
    pub fn beginFrame(self: *MetalDevice) ?[2]u32 {
        var w: u32 = 0;
        var h: u32 = 0;
        if (c.zigui_metal_begin_frame(self.handle, &w, &h)) {
            return .{ w, h };
        }
        return null;
    }

    /// 更新顶点数据
    pub fn updateVertices(self: *MetalDevice, vertices: []const Vertex2D) void {
        if (vertices.len == 0) return;
        c.zigui_metal_update_vertices(
            self.handle,
            @ptrCast(vertices.ptr),
            @intCast(vertices.len),
        );
    }

    /// 绘制三角形
    pub fn drawTriangles(self: *MetalDevice, vertex_count: u32) void {
        if (vertex_count == 0) return;
        c.zigui_metal_draw(self.handle, vertex_count);
    }

    /// 结束帧，提交 GPU 并 present
    pub fn endFrame(self: *MetalDevice) void {
        c.zigui_metal_end_frame(self.handle);
    }

    /// 窗口尺寸变化时更新 drawable 大小
    pub fn setDrawableSize(self: *MetalDevice, width: u32, height: u32) void {
        c.zigui_metal_set_drawable_size(self.handle, width, height);
    }

    // ── Texture (glyph atlas) ────────────────────────────────────────────────

    /// 创建 R8Unorm 纹理，返回不透明纹理句柄
    pub fn createTexture(self: *MetalDevice, width: u32, height: u32) ?*anyopaque {
        return c.zigui_metal_create_texture(self.handle, width, height);
    }

    pub fn destroyTexture(self: *MetalDevice, texture: *anyopaque) void {
        c.zigui_metal_destroy_texture(self.handle, texture);
    }

    /// 更新纹理子区域 (data = 逐行 R8 像素)
    pub fn updateTextureRegion(self: *MetalDevice, texture: *anyopaque, x: u32, y: u32, w: u32, h: u32, data: []const u8, data_stride: u32) void {
        c.zigui_metal_update_texture_region(self.handle, texture, x, y, w, h, data.ptr, data_stride);
    }

    // ── Textured drawing (text) ──────────────────────────────────────────────

    /// 更新文本顶点数据
    pub fn updateTextVertices(self: *MetalDevice, vertices: []const TextVertex) void {
        if (vertices.len == 0) return;
        c.zigui_metal_update_text_vertices(
            self.handle,
            @ptrCast(vertices.ptr),
            @intCast(vertices.len),
        );
    }

    /// 使用纹理管线绘制
    pub fn drawTextured(self: *MetalDevice, vertex_count: u32, texture: *anyopaque) void {
        if (vertex_count == 0) return;
        c.zigui_metal_draw_textured(self.handle, vertex_count, texture);
    }
};
