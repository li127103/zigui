//! Metal GPU 后端 (macOS) - 通过 ObjC helper 层

const c = @cImport({
    @cInclude("metal_backend.h");
});

pub const Vertex2D = extern struct {
    pos: [2]f32,
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
};
