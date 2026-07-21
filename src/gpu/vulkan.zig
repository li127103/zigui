//! Vulkan GPU 后端 (Linux)
//! 面向 2D UI 渲染优化: 纯色几何 + 纹理文本/图片

const std = @import("std");

const vk = @cImport({
    @cDefine("VK_USE_PLATFORM_XCB_KHR", "1");
    @cDefine("VK_USE_PLATFORM_WAYLAND_KHR", "1");
    @cInclude("vulkan/vulkan.h");
});

const xcb = @cImport({
    @cInclude("xcb/xcb.h");
});

// 公开类型别名 (避免跨 cImport 的 opaque 类型不兼容)
pub const VkImageView = vk.VkImageView;
pub const VkDevice = vk.VkDevice;
pub const VkImage = vk.VkImage;

/// GPU 纹理句柄 (包含 image + view + memory)
pub const TextureHandle = struct {
    image: vk.VkImage,
    view: vk.VkImageView,
    memory: vk.VkDeviceMemory,
};

pub const Vertex2D = extern struct {
    pos: [2]f32,
    color: [4]f32,
};

pub const TextVertex = extern struct {
    pos: [2]f32,
    uv: [2]f32,
    color: [4]f32,
};

const max_vertices = 65536;
const frames_in_flight: u32 = 2;

pub const VulkanDevice = struct {
    allocator: std.mem.Allocator,
    instance: vk.VkInstance,
    physical_device: vk.VkPhysicalDevice,
    device: vk.VkDevice,
    queue: vk.VkQueue,
    queue_family: u32,
    surface: vk.VkSurfaceKHR,
    swapchain: vk.VkSwapchainKHR,
    swapchain_images: []vk.VkImage,
    swapchain_views: []vk.VkImageView,
    swapchain_format: vk.VkFormat,
    swapchain_extent: vk.VkExtent2D,
    render_pass: vk.VkRenderPass,
    // 管线
    solid_pipeline: vk.VkPipeline,
    solid_pipeline_layout: vk.VkPipelineLayout,
    textured_pipeline: vk.VkPipeline,
    textured_pipeline_layout: vk.VkPipelineLayout,
    // 纹理
    sampler: vk.VkSampler,
    desc_set_layout: vk.VkDescriptorSetLayout,
    desc_pool: vk.VkDescriptorPool,
    desc_set: vk.VkDescriptorSet,
    // 帧缓冲
    framebuffers: []vk.VkFramebuffer,
    // 命令
    cmd_pool: vk.VkCommandPool,
    cmd_buffers: []vk.VkCommandBuffer,
    // 顶点缓冲 (host-visible)
    vertex_buffer: vk.VkBuffer,
    vertex_memory: vk.VkDeviceMemory,
    vertex_mapped: [*]u8,
    text_vertex_buffer: vk.VkBuffer,
    text_vertex_memory: vk.VkDeviceMemory,
    text_vertex_mapped: [*]u8,
    // 同步
    image_available: [frames_in_flight]vk.VkSemaphore,
    render_finished: [frames_in_flight]vk.VkSemaphore,
    in_flight: [frames_in_flight]vk.VkFence,
    current_frame: u32 = 0,
    image_index: u32 = 0,
    // 状态
    fb_width: u32,
    fb_height: u32,

    pub fn init(allocator: std.mem.Allocator, xcb_conn_ptr: *anyopaque, window_id: u32, width: u32, height: u32) !VulkanDevice {
        // 1. 创建 Instance
        const instance = try createInstance(allocator);

        // 2. 创建 XCB Surface
        const surface = try createXcbSurface(instance, xcb_conn_ptr, window_id);

        // 3. 选择物理设备
        const phys_result = try selectPhysicalDevice(instance, surface);
        const physical_device = phys_result.device;
        const queue_family = phys_result.queue_family;

        // 4. 创建逻辑设备
        const device_result = try createLogicalDevice(physical_device, queue_family);
        const device = device_result.device;
        const queue = device_result.queue;

        // 5. 创建 Swapchain
        const swapchain_result = try createSwapchain(allocator, physical_device, device, surface, width, height);

        // 6. 创建 Render Pass
        const render_pass = try createRenderPass(device, swapchain_result.format);

        // 7. 创建 Descriptor Set (纹理管线用)
        const desc = try createDescriptorSet(device);

        // 8. 创建管线
        const solid_pipe = try createSolidPipeline(device, render_pass, swapchain_result.extent);
        const textured_pipe = try createTexturedPipeline(device, render_pass, swapchain_result.extent, desc.layout);

        // 8. 创建 Framebuffers
        const framebuffers = try createFramebuffers(allocator, device, render_pass, swapchain_result.views, swapchain_result.extent);

        // 9. 创建 Command Pool & Buffers
        const cmd_pool = try createCommandPool(device, queue_family);
        const cmd_buffers = try allocateCommandBuffers(allocator, device, cmd_pool, frames_in_flight);

        // 10. 创建顶点缓冲
        const vertex_result = try createVertexBuffer(physical_device, device, max_vertices * @sizeOf(Vertex2D));
        const text_vertex_result = try createVertexBuffer(physical_device, device, max_vertices * @sizeOf(TextVertex));

        // 11. 创建同步对象
        const sync = try createSyncObjects(device);

        // 12. 创建 Sampler
        const sampler = try createSampler(device);

        return .{
            .allocator = allocator,
            .instance = instance,
            .physical_device = physical_device,
            .device = device,
            .queue = queue,
            .queue_family = queue_family,
            .surface = surface,
            .swapchain = swapchain_result.swapchain,
            .swapchain_images = swapchain_result.images,
            .swapchain_views = swapchain_result.views,
            .swapchain_format = swapchain_result.format,
            .swapchain_extent = swapchain_result.extent,
            .render_pass = render_pass,
            .solid_pipeline = solid_pipe.pipeline,
            .solid_pipeline_layout = solid_pipe.layout,
            .textured_pipeline = textured_pipe.pipeline,
            .textured_pipeline_layout = textured_pipe.layout,
            .sampler = sampler,
            .desc_set_layout = desc.layout,
            .desc_pool = desc.pool,
            .desc_set = desc.set,
            .framebuffers = framebuffers,
            .cmd_pool = cmd_pool,
            .cmd_buffers = cmd_buffers,
            .vertex_buffer = vertex_result.buffer,
            .vertex_memory = vertex_result.memory,
            .vertex_mapped = vertex_result.mapped,
            .text_vertex_buffer = text_vertex_result.buffer,
            .text_vertex_memory = text_vertex_result.memory,
            .text_vertex_mapped = text_vertex_result.mapped,
            .image_available = sync.image_available,
            .render_finished = sync.render_finished,
            .in_flight = sync.in_flight,
            .fb_width = swapchain_result.extent.width,
            .fb_height = swapchain_result.extent.height,
        };
    }

    /// Wayland 初始化入口
    pub fn initWayland(allocator: std.mem.Allocator, wl_display_ptr: *anyopaque, wl_surface_ptr: *anyopaque, width: u32, height: u32) !VulkanDevice {
        const instance = try createInstance(allocator);
        const surface = try createWaylandSurface(instance, wl_display_ptr, wl_surface_ptr);
        return initWithSurface(allocator, instance, surface, width, height);
    }

    /// 共享初始化逻辑 (surface 已创建)
    fn initWithSurface(allocator: std.mem.Allocator, instance: vk.VkInstance, surface: vk.VkSurfaceKHR, width: u32, height: u32) !VulkanDevice {
        const phys_result = try selectPhysicalDevice(instance, surface);
        const physical_device = phys_result.device;
        const queue_family = phys_result.queue_family;
        const device_result = try createLogicalDevice(physical_device, queue_family);
        const device = device_result.device;
        const queue = device_result.queue;
        const swapchain_result = try createSwapchain(allocator, physical_device, device, surface, width, height);
        const render_pass = try createRenderPass(device, swapchain_result.format);
        const desc = try createDescriptorSet(device);
        const solid_pipe = try createSolidPipeline(device, render_pass, swapchain_result.extent);
        const textured_pipe = try createTexturedPipeline(device, render_pass, swapchain_result.extent, desc.layout);
        const framebuffers = try createFramebuffers(allocator, device, render_pass, swapchain_result.views, swapchain_result.extent);
        const cmd_pool = try createCommandPool(device, queue_family);
        const cmd_buffers = try allocateCommandBuffers(allocator, device, cmd_pool, frames_in_flight);
        const vertex_result = try createVertexBuffer(physical_device, device, max_vertices * @sizeOf(Vertex2D));
        const text_vertex_result = try createVertexBuffer(physical_device, device, max_vertices * @sizeOf(TextVertex));
        const sync = try createSyncObjects(device);
        const sampler = try createSampler(device);

        return .{
            .allocator = allocator,
            .instance = instance,
            .physical_device = physical_device,
            .device = device,
            .queue = queue,
            .queue_family = queue_family,
            .surface = surface,
            .swapchain = swapchain_result.swapchain,
            .swapchain_images = swapchain_result.images,
            .swapchain_views = swapchain_result.views,
            .swapchain_format = swapchain_result.format,
            .swapchain_extent = swapchain_result.extent,
            .render_pass = render_pass,
            .solid_pipeline = solid_pipe.pipeline,
            .solid_pipeline_layout = solid_pipe.layout,
            .textured_pipeline = textured_pipe.pipeline,
            .textured_pipeline_layout = textured_pipe.layout,
            .sampler = sampler,
            .desc_set_layout = desc.layout,
            .desc_pool = desc.pool,
            .desc_set = desc.set,
            .framebuffers = framebuffers,
            .cmd_pool = cmd_pool,
            .cmd_buffers = cmd_buffers,
            .vertex_buffer = vertex_result.buffer,
            .vertex_memory = vertex_result.memory,
            .vertex_mapped = vertex_result.mapped,
            .text_vertex_buffer = text_vertex_result.buffer,
            .text_vertex_memory = text_vertex_result.memory,
            .text_vertex_mapped = text_vertex_result.mapped,
            .image_available = sync.image_available,
            .render_finished = sync.render_finished,
            .in_flight = sync.in_flight,
            .fb_width = swapchain_result.extent.width,
            .fb_height = swapchain_result.extent.height,
        };
    }

    pub fn deinit(self: *VulkanDevice) void {
        _ = vk.vkDeviceWaitIdle(self.device);

        // 销毁同步对象
        for (0..frames_in_flight) |i| {
            vk.vkDestroySemaphore(self.device, self.image_available[i], null);
            vk.vkDestroySemaphore(self.device, self.render_finished[i], null);
            vk.vkDestroyFence(self.device, self.in_flight[i], null);
        }

        // 销毁顶点缓冲
        vk.vkDestroyBuffer(self.device, self.vertex_buffer, null);
        vk.vkFreeMemory(self.device, self.vertex_memory, null);
        vk.vkDestroyBuffer(self.device, self.text_vertex_buffer, null);
        vk.vkFreeMemory(self.device, self.text_vertex_memory, null);

        // 销毁命令池 (同时释放 command buffers)
        vk.vkDestroyCommandPool(self.device, self.cmd_pool, null);
        self.allocator.free(self.cmd_buffers);

        // 销毁 framebuffers
        for (self.framebuffers) |fb| {
            vk.vkDestroyFramebuffer(self.device, fb, null);
        }
        self.allocator.free(self.framebuffers);

        // 销毁管线
        vk.vkDestroyPipeline(self.device, self.solid_pipeline, null);
        vk.vkDestroyPipelineLayout(self.device, self.solid_pipeline_layout, null);
        vk.vkDestroyPipeline(self.device, self.textured_pipeline, null);
        vk.vkDestroyPipelineLayout(self.device, self.textured_pipeline_layout, null);

        // 销毁 render pass
        vk.vkDestroyRenderPass(self.device, self.render_pass, null);

        // 销毁 sampler
        vk.vkDestroySampler(self.device, self.sampler, null);

        // 销毁 descriptor set
        vk.vkDestroyDescriptorPool(self.device, self.desc_pool, null);
        vk.vkDestroyDescriptorSetLayout(self.device, self.desc_set_layout, null);

        // 销毁 swapchain
        for (self.swapchain_views) |view| {
            vk.vkDestroyImageView(self.device, view, null);
        }
        self.allocator.free(self.swapchain_views);
        self.allocator.free(self.swapchain_images);
        vk.vkDestroySwapchainKHR(self.device, self.swapchain, null);

        // 销毁设备
        vk.vkDestroyDevice(self.device, null);
        vk.vkDestroySurfaceKHR(self.instance, self.surface, null);
        vk.vkDestroyInstance(self.instance, null);
    }

    /// 开始帧: 获取 swapchain image, 返回 framebuffer 尺寸
    pub fn beginFrame(self: *VulkanDevice) ?[2]u32 {
        // 等待 fence
        _ = vk.vkWaitForFences(self.device, 1, &self.in_flight[self.current_frame], vk.VK_TRUE, std.math.maxInt(u64));
        _ = vk.vkResetFences(self.device, 1, &self.in_flight[self.current_frame]);

        // 获取 image
        var image_index: u32 = 0;
        const result = vk.vkAcquireNextImageKHR(
            self.device,
            self.swapchain,
            std.math.maxInt(u64),
            self.image_available[self.current_frame],
            null,
            &image_index,
        );
        if (result != vk.VK_SUCCESS and result != vk.VK_SUBOPTIMAL_KHR) return null;
        self.image_index = image_index;

        // 重置命令缓冲
        _ = vk.vkResetCommandBuffer(self.cmd_buffers[self.current_frame], 0);

        // 开始命令缓冲
        const begin_info = vk.VkCommandBufferBeginInfo{
            .sType = vk.VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO,
            .pNext = null,
            .flags = vk.VK_COMMAND_BUFFER_USAGE_ONE_TIME_SUBMIT_BIT,
            .pInheritanceInfo = null,
        };
        _ = vk.vkBeginCommandBuffer(self.cmd_buffers[self.current_frame], &begin_info);

        // 开始 render pass
        const clear_value = vk.VkClearValue{ .color = .{ .float32 = .{ 0.0, 0.0, 0.0, 1.0 } } };
        const rp_begin = vk.VkRenderPassBeginInfo{
            .sType = vk.VK_STRUCTURE_TYPE_RENDER_PASS_BEGIN_INFO,
            .pNext = null,
            .renderPass = self.render_pass,
            .framebuffer = self.framebuffers[image_index],
            .renderArea = .{ .offset = .{ .x = 0, .y = 0 }, .extent = self.swapchain_extent },
            .clearValueCount = 1,
            .pClearValues = &clear_value,
        };
        vk.vkCmdBeginRenderPass(self.cmd_buffers[self.current_frame], &rp_begin, vk.VK_SUBPASS_CONTENTS_INLINE);

        // 设置视口和裁剪
        const viewport = vk.VkViewport{
            .x = 0,
            .y = 0,
            .width = @floatFromInt(self.swapchain_extent.width),
            .height = @floatFromInt(self.swapchain_extent.height),
            .minDepth = 0,
            .maxDepth = 1,
        };
        vk.vkCmdSetViewport(self.cmd_buffers[self.current_frame], 0, 1, &viewport);
        const scissor = vk.VkRect2D{
            .offset = .{ .x = 0, .y = 0 },
            .extent = self.swapchain_extent,
        };
        vk.vkCmdSetScissor(self.cmd_buffers[self.current_frame], 0, 1, &scissor);

        return .{ self.swapchain_extent.width, self.swapchain_extent.height };
    }

    /// 更新纯色顶点数据
    pub fn updateVertices(self: *VulkanDevice, vertices: []const Vertex2D) void {
        if (vertices.len == 0) return;
        const size = vertices.len * @sizeOf(Vertex2D);
        @memcpy(self.vertex_mapped[0..size], std.mem.sliceAsBytes(vertices));
    }

    /// 绘制纯色三角形
    pub fn drawTriangles(self: *VulkanDevice, vertex_count: u32) void {
        if (vertex_count == 0) return;
        const cmd = self.cmd_buffers[self.current_frame];

        vk.vkCmdBindPipeline(cmd, vk.VK_PIPELINE_BIND_POINT_GRAPHICS, self.solid_pipeline);

        // Push constants (screen size)
        const screen_size = [2]f32{ @floatFromInt(self.swapchain_extent.width), @floatFromInt(self.swapchain_extent.height) };
        vk.vkCmdPushConstants(cmd, self.solid_pipeline_layout, vk.VK_SHADER_STAGE_VERTEX_BIT, 0, 8, &screen_size);

        // 绑定顶点缓冲
        const buffers = [_]vk.VkBuffer{self.vertex_buffer};
        const offsets = [_]vk.VkDeviceSize{0};
        vk.vkCmdBindVertexBuffers(cmd, 0, 1, &buffers, &offsets);

        vk.vkCmdDraw(cmd, vertex_count, 1, 0, 0);
    }

    /// 更新文本顶点数据
    pub fn updateTextVertices(self: *VulkanDevice, vertices: []const TextVertex) void {
        if (vertices.len == 0) return;
        const size = vertices.len * @sizeOf(TextVertex);
        @memcpy(self.text_vertex_mapped[0..size], std.mem.sliceAsBytes(vertices));
    }

    /// 使用纹理管线绘制
    pub fn drawTextured(self: *VulkanDevice, vertex_count: u32, texture: vk.VkImageView) void {
        if (vertex_count == 0) return;
        const cmd = self.cmd_buffers[self.current_frame];

        // 更新 descriptor set 绑定纹理
        const image_info = vk.VkDescriptorImageInfo{
            .sampler = self.sampler,
            .imageView = texture,
            .imageLayout = vk.VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL,
        };
        const write = vk.VkWriteDescriptorSet{
            .sType = vk.VK_STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET,
            .pNext = null,
            .dstSet = self.desc_set,
            .dstBinding = 0,
            .dstArrayElement = 0,
            .descriptorCount = 1,
            .descriptorType = vk.VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER,
            .pImageInfo = &image_info,
            .pBufferInfo = null,
            .pTexelBufferView = null,
        };
        vk.vkUpdateDescriptorSets(self.device, 1, &write, 0, null);

        vk.vkCmdBindPipeline(cmd, vk.VK_PIPELINE_BIND_POINT_GRAPHICS, self.textured_pipeline);

        // Push constants
        const screen_size = [2]f32{ @floatFromInt(self.swapchain_extent.width), @floatFromInt(self.swapchain_extent.height) };
        vk.vkCmdPushConstants(cmd, self.textured_pipeline_layout, vk.VK_SHADER_STAGE_VERTEX_BIT, 0, 8, &screen_size);

        // 绑定 descriptor set
        vk.vkCmdBindDescriptorSets(cmd, vk.VK_PIPELINE_BIND_POINT_GRAPHICS, self.textured_pipeline_layout, 0, 1, &self.desc_set, 0, null);

        // 绑定顶点缓冲
        const buffers = [_]vk.VkBuffer{self.text_vertex_buffer};
        const offsets = [_]vk.VkDeviceSize{0};
        vk.vkCmdBindVertexBuffers(cmd, 0, 1, &buffers, &offsets);

        vk.vkCmdDraw(cmd, vertex_count, 1, 0, 0);
    }

    /// 更新纹理 descriptor set (仅在纹理创建/更换时调用一次)
    pub fn updateTextureDescriptor(self: *VulkanDevice, texture_view: vk.VkImageView) void {
        const image_info = vk.VkDescriptorImageInfo{
            .sampler = self.sampler,
            .imageView = texture_view,
            .imageLayout = vk.VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL,
        };
        const write = vk.VkWriteDescriptorSet{
            .sType = vk.VK_STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET,
            .pNext = null,
            .dstSet = self.desc_set,
            .dstBinding = 0,
            .dstArrayElement = 0,
            .descriptorCount = 1,
            .descriptorType = vk.VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER,
            .pImageInfo = &image_info,
            .pBufferInfo = null,
            .pTexelBufferView = null,
        };
        vk.vkUpdateDescriptorSets(self.device, 1, &write, 0, null);
    }

    /// 结束帧: 提交命令并 present
    pub fn endFrame(self: *VulkanDevice) void {
        const cmd = self.cmd_buffers[self.current_frame];
        vk.vkCmdEndRenderPass(cmd);
        _ = vk.vkEndCommandBuffer(cmd);

        // 提交
        const wait_semaphores = [_]vk.VkSemaphore{self.image_available[self.current_frame]};
        const wait_stages = [_]vk.VkPipelineStageFlags{vk.VK_PIPELINE_STAGE_COLOR_ATTACHMENT_OUTPUT_BIT};
        const signal_semaphores = [_]vk.VkSemaphore{self.render_finished[self.current_frame]};
        const cmd_buffers = [_]vk.VkCommandBuffer{cmd};

        const submit_info = vk.VkSubmitInfo{
            .sType = vk.VK_STRUCTURE_TYPE_SUBMIT_INFO,
            .pNext = null,
            .waitSemaphoreCount = 1,
            .pWaitSemaphores = &wait_semaphores,
            .pWaitDstStageMask = &wait_stages,
            .commandBufferCount = 1,
            .pCommandBuffers = &cmd_buffers,
            .signalSemaphoreCount = 1,
            .pSignalSemaphores = &signal_semaphores,
        };
        const submit_result = vk.vkQueueSubmit(self.queue, 1, &submit_info, self.in_flight[self.current_frame]);
        if (submit_result != vk.VK_SUCCESS) {
            std.debug.print("[VK] vkQueueSubmit failed: {d}\n", .{submit_result});
        }

        // Present
        const swapchains = [_]vk.VkSwapchainKHR{self.swapchain};
        const present_info = vk.VkPresentInfoKHR{
            .sType = vk.VK_STRUCTURE_TYPE_PRESENT_INFO_KHR,
            .pNext = null,
            .waitSemaphoreCount = 1,
            .pWaitSemaphores = &signal_semaphores,
            .swapchainCount = 1,
            .pSwapchains = &swapchains,
            .pImageIndices = &self.image_index,
            .pResults = null,
        };
        const present_result = vk.vkQueuePresentKHR(self.queue, &present_info);
        if (present_result != vk.VK_SUCCESS and present_result != vk.VK_SUBOPTIMAL_KHR) {
            std.debug.print("[VK] vkQueuePresentKHR failed: {d}\n", .{present_result});
        }

        self.current_frame = (self.current_frame + 1) % frames_in_flight;
    }

    /// 窗口尺寸变化时重建 swapchain
    pub fn setDrawableSize(self: *VulkanDevice, width: u32, height: u32) void {
        if (width == 0 or height == 0) return;
        if (width == self.fb_width and height == self.fb_height) return;
        // TODO: 重建 swapchain
        self.fb_width = width;
        self.fb_height = height;
    }

    // ── Texture (glyph atlas) ────────────────────────────────────────────────

    /// 创建 R8Unorm 纹理 (glyph atlas)
    pub fn createTexture(self: *VulkanDevice, width: u32, height: u32) ?TextureHandle {
        const device = self.device;

        // 创建 image
        const image_info = vk.VkImageCreateInfo{
            .sType = vk.VK_STRUCTURE_TYPE_IMAGE_CREATE_INFO,
            .pNext = null,
            .flags = 0,
            .imageType = vk.VK_IMAGE_TYPE_2D,
            .format = vk.VK_FORMAT_R8_UNORM,
            .extent = .{ .width = width, .height = height, .depth = 1 },
            .mipLevels = 1,
            .arrayLayers = 1,
            .samples = vk.VK_SAMPLE_COUNT_1_BIT,
            .tiling = vk.VK_IMAGE_TILING_OPTIMAL,
            .usage = vk.VK_IMAGE_USAGE_SAMPLED_BIT | vk.VK_IMAGE_USAGE_TRANSFER_DST_BIT,
            .sharingMode = vk.VK_SHARING_MODE_EXCLUSIVE,
            .queueFamilyIndexCount = 0,
            .pQueueFamilyIndices = null,
            .initialLayout = vk.VK_IMAGE_LAYOUT_UNDEFINED,
        };

        var image: vk.VkImage = undefined;
        if (vk.vkCreateImage(device, &image_info, null, &image) != vk.VK_SUCCESS) return null;

        // 分配 device-local 内存
        var mem_reqs: vk.VkMemoryRequirements = undefined;
        vk.vkGetImageMemoryRequirements(device, image, &mem_reqs);
        const mem_type = findMemoryType(self.physical_device, mem_reqs.memoryTypeBits, vk.VK_MEMORY_PROPERTY_DEVICE_LOCAL_BIT) orelse return null;

        const alloc_info = vk.VkMemoryAllocateInfo{
            .sType = vk.VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO,
            .pNext = null,
            .allocationSize = mem_reqs.size,
            .memoryTypeIndex = mem_type,
        };
        var memory: vk.VkDeviceMemory = undefined;
        if (vk.vkAllocateMemory(device, &alloc_info, null, &memory) != vk.VK_SUCCESS) return null;
        _ = vk.vkBindImageMemory(device, image, memory, 0);

        // 创建 image view (swizzle: R→alpha, 其仙通道=1, 用于文本渲染)
        const view_info = vk.VkImageViewCreateInfo{
            .sType = vk.VK_STRUCTURE_TYPE_IMAGE_VIEW_CREATE_INFO,
            .pNext = null,
            .flags = 0,
            .image = image,
            .viewType = vk.VK_IMAGE_VIEW_TYPE_2D,
            .format = vk.VK_FORMAT_R8_UNORM,
            .components = .{ .r = vk.VK_COMPONENT_SWIZZLE_ONE, .g = vk.VK_COMPONENT_SWIZZLE_ONE, .b = vk.VK_COMPONENT_SWIZZLE_ONE, .a = vk.VK_COMPONENT_SWIZZLE_R },
            .subresourceRange = .{
                .aspectMask = vk.VK_IMAGE_ASPECT_COLOR_BIT,
                .baseMipLevel = 0,
                .levelCount = 1,
                .baseArrayLayer = 0,
                .layerCount = 1,
            },
        };
        var view: vk.VkImageView = undefined;
        if (vk.vkCreateImageView(device, &view_info, null, &view) != vk.VK_SUCCESS) return null;

        // 转换布局: UNDEFINED → TRANSFER_DST_OPTIMAL (准备接收数据)
        self.transitionImageLayout(image, vk.VK_IMAGE_LAYOUT_UNDEFINED, vk.VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL);

        return .{ .image = image, .view = view, .memory = memory };
    }

    pub fn destroyTexture(self: *VulkanDevice, texture: TextureHandle) void {
        vk.vkDestroyImageView(self.device, texture.view, null);
        vk.vkDestroyImage(self.device, texture.image, null);
        vk.vkFreeMemory(self.device, texture.memory, null);
    }

    /// 将纹理从 UNDEFINED 转换为 TRANSFER_DST (初始上传用)
    pub fn initTextureForTransfer(self: *VulkanDevice, texture: TextureHandle) void {
        self.transitionImageLayout(texture.image, vk.VK_IMAGE_LAYOUT_UNDEFINED, vk.VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL);
    }

    /// 将纹理从 TRANSFER_DST 转换为 SHADER_READ_ONLY (用于采样)
    pub fn prepareTextureForSampling(self: *VulkanDevice, texture: TextureHandle) void {
        self.transitionImageLayout(texture.image, vk.VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL, vk.VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL);
    }

    /// DEBUG: 读回纹理数据验证 GPU 端内容
    pub fn readbackTexture(self: *VulkanDevice, texture: TextureHandle, x: u32, y: u32, w: u32, h: u32, out: []u8) void {
        const device = self.device;
        const buf_size: usize = @as(usize, w) * @as(usize, h);
        if (out.len < buf_size) return;

        // 先转回 TRANSFER_SRC
        self.transitionImageLayout(texture.image, vk.VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL, vk.VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL);

        // 创建 readback buffer
        const rb_info = vk.VkBufferCreateInfo{
            .sType = vk.VK_STRUCTURE_TYPE_BUFFER_CREATE_INFO,
            .pNext = null,
            .flags = 0,
            .size = buf_size,
            .usage = vk.VK_BUFFER_USAGE_TRANSFER_DST_BIT,
            .sharingMode = vk.VK_SHARING_MODE_EXCLUSIVE,
            .queueFamilyIndexCount = 0,
            .pQueueFamilyIndices = null,
        };
        var rb_buf: vk.VkBuffer = undefined;
        if (vk.vkCreateBuffer(device, &rb_info, null, &rb_buf) != vk.VK_SUCCESS) return;
        var mem_reqs: vk.VkMemoryRequirements = undefined;
        vk.vkGetBufferMemoryRequirements(device, rb_buf, &mem_reqs);
        const mem_type = findMemoryType(self.physical_device, mem_reqs.memoryTypeBits, vk.VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT | vk.VK_MEMORY_PROPERTY_HOST_COHERENT_BIT) orelse return;
        const alloc_info = vk.VkMemoryAllocateInfo{
            .sType = vk.VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO,
            .pNext = null,
            .allocationSize = mem_reqs.size,
            .memoryTypeIndex = mem_type,
        };
        var rb_mem: vk.VkDeviceMemory = undefined;
        if (vk.vkAllocateMemory(device, &alloc_info, null, &rb_mem) != vk.VK_SUCCESS) return;
        _ = vk.vkBindBufferMemory(device, rb_buf, rb_mem, 0);

        // one-time cmd: image → buffer
        const cmd_alloc = vk.VkCommandBufferAllocateInfo{
            .sType = vk.VK_STRUCTURE_TYPE_COMMAND_BUFFER_ALLOCATE_INFO,
            .pNext = null,
            .commandPool = self.cmd_pool,
            .level = vk.VK_COMMAND_BUFFER_LEVEL_PRIMARY,
            .commandBufferCount = 1,
        };
        var cmd_buf: vk.VkCommandBuffer = undefined;
        _ = vk.vkAllocateCommandBuffers(device, &cmd_alloc, &cmd_buf);
        const begin_info = vk.VkCommandBufferBeginInfo{
            .sType = vk.VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO,
            .pNext = null,
            .flags = vk.VK_COMMAND_BUFFER_USAGE_ONE_TIME_SUBMIT_BIT,
            .pInheritanceInfo = null,
        };
        _ = vk.vkBeginCommandBuffer(cmd_buf, &begin_info);
        const region = vk.VkBufferImageCopy{
            .bufferOffset = 0,
            .bufferRowLength = 0,
            .bufferImageHeight = 0,
            .imageSubresource = .{ .aspectMask = vk.VK_IMAGE_ASPECT_COLOR_BIT, .mipLevel = 0, .baseArrayLayer = 0, .layerCount = 1 },
            .imageOffset = .{ .x = @intCast(x), .y = @intCast(y), .z = 0 },
            .imageExtent = .{ .width = w, .height = h, .depth = 1 },
        };
        vk.vkCmdCopyImageToBuffer(cmd_buf, texture.image, vk.VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL, rb_buf, 1, &region);
        _ = vk.vkEndCommandBuffer(cmd_buf);
        const submit_info = vk.VkSubmitInfo{
            .sType = vk.VK_STRUCTURE_TYPE_SUBMIT_INFO,
            .pNext = null,
            .waitSemaphoreCount = 0,
            .pWaitSemaphores = null,
            .pWaitDstStageMask = null,
            .commandBufferCount = 1,
            .pCommandBuffers = &cmd_buf,
            .signalSemaphoreCount = 0,
            .pSignalSemaphores = null,
        };
        _ = vk.vkQueueSubmit(self.queue, 1, &submit_info, null);
        _ = vk.vkQueueWaitIdle(self.queue);
        vk.vkFreeCommandBuffers(device, self.cmd_pool, 1, &cmd_buf);

        // 读回数据
        var mapped: ?*anyopaque = null;
        if (vk.vkMapMemory(device, rb_mem, 0, buf_size, 0, &mapped) == vk.VK_SUCCESS) {
            const src: [*]const u8 = @ptrCast(mapped);
            @memcpy(out[0..buf_size], src[0..buf_size]);
            vk.vkUnmapMemory(device, rb_mem);
        }

        // 转回 SHADER_READ_ONLY
        self.transitionImageLayout(texture.image, vk.VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL, vk.VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL);

        vk.vkDestroyBuffer(device, rb_buf, null);
        vk.vkFreeMemory(device, rb_mem, null);
    }

    /// 将纹理从 SHADER_READ_ONLY 转回 TRANSFER_DST (用于上传)
    pub fn prepareTextureForTransfer(self: *VulkanDevice, texture: TextureHandle) void {
        self.transitionImageLayout(texture.image, vk.VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL, vk.VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL);
    }

    /// 更新纹理子区域 (staging buffer 方式)
    pub fn updateTextureRegion(self: *VulkanDevice, texture: TextureHandle, x: u32, y: u32, w: u32, h: u32, data: []const u8, data_stride: u32) void {
        const device = self.device;
        const buf_size: usize = @as(usize, w) * @as(usize, h);
        if (data.len < buf_size) return;
        _ = data_stride;

        // 创建 staging buffer
        const staging_info = vk.VkBufferCreateInfo{
            .sType = vk.VK_STRUCTURE_TYPE_BUFFER_CREATE_INFO,
            .pNext = null,
            .flags = 0,
            .size = buf_size,
            .usage = vk.VK_BUFFER_USAGE_TRANSFER_SRC_BIT,
            .sharingMode = vk.VK_SHARING_MODE_EXCLUSIVE,
            .queueFamilyIndexCount = 0,
            .pQueueFamilyIndices = null,
        };
        var staging_buf: vk.VkBuffer = undefined;
        if (vk.vkCreateBuffer(device, &staging_info, null, &staging_buf) != vk.VK_SUCCESS) return;

        var mem_reqs: vk.VkMemoryRequirements = undefined;
        vk.vkGetBufferMemoryRequirements(device, staging_buf, &mem_reqs);
        const mem_type = findMemoryType(self.physical_device, mem_reqs.memoryTypeBits, vk.VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT | vk.VK_MEMORY_PROPERTY_HOST_COHERENT_BIT) orelse return;

        const alloc_info = vk.VkMemoryAllocateInfo{
            .sType = vk.VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO,
            .pNext = null,
            .allocationSize = mem_reqs.size,
            .memoryTypeIndex = mem_type,
        };
        var staging_mem: vk.VkDeviceMemory = undefined;
        if (vk.vkAllocateMemory(device, &alloc_info, null, &staging_mem) != vk.VK_SUCCESS) return;
        _ = vk.vkBindBufferMemory(device, staging_buf, staging_mem, 0);

        // 复制数据到 staging buffer
        var mapped: ?*anyopaque = null;
        if (vk.vkMapMemory(device, staging_mem, 0, buf_size, 0, &mapped) != vk.VK_SUCCESS) return;
        const dst: [*]u8 = @ptrCast(mapped);
        @memcpy(dst[0..buf_size], data[0..buf_size]);
        vk.vkUnmapMemory(device, staging_mem);

        // 使用 one-time command buffer 复制
        self.copyBufferToImage(staging_buf, texture.image, x, y, w, h);

        // 清理 staging
        vk.vkDestroyBuffer(device, staging_buf, null);
        vk.vkFreeMemory(device, staging_mem, null);
    }

    /// 一次性 command buffer: buffer → image 复制
    fn copyBufferToImage(self: *VulkanDevice, buffer: vk.VkBuffer, image: vk.VkImage, x: u32, y: u32, w: u32, h: u32) void {
        const device = self.device;

        // 分配 one-time command buffer
        const alloc_info = vk.VkCommandBufferAllocateInfo{
            .sType = vk.VK_STRUCTURE_TYPE_COMMAND_BUFFER_ALLOCATE_INFO,
            .pNext = null,
            .commandPool = self.cmd_pool,
            .level = vk.VK_COMMAND_BUFFER_LEVEL_PRIMARY,
            .commandBufferCount = 1,
        };
        var cmd_buf: vk.VkCommandBuffer = undefined;
        _ = vk.vkAllocateCommandBuffers(device, &alloc_info, &cmd_buf);

        const begin_info = vk.VkCommandBufferBeginInfo{
            .sType = vk.VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO,
            .pNext = null,
            .flags = vk.VK_COMMAND_BUFFER_USAGE_ONE_TIME_SUBMIT_BIT,
            .pInheritanceInfo = null,
        };
        _ = vk.vkBeginCommandBuffer(cmd_buf, &begin_info);

        // 执行 buffer → image 复制
        const region = vk.VkBufferImageCopy{
            .bufferOffset = 0,
            .bufferRowLength = 0,
            .bufferImageHeight = 0,
            .imageSubresource = .{
                .aspectMask = vk.VK_IMAGE_ASPECT_COLOR_BIT,
                .mipLevel = 0,
                .baseArrayLayer = 0,
                .layerCount = 1,
            },
            .imageOffset = .{ .x = @intCast(x), .y = @intCast(y), .z = 0 },
            .imageExtent = .{ .width = w, .height = h, .depth = 1 },
        };
        vk.vkCmdCopyBufferToImage(cmd_buf, buffer, image, vk.VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL, 1, &region);

        _ = vk.vkEndCommandBuffer(cmd_buf);

        // 提交并等待
        const submit_info = vk.VkSubmitInfo{
            .sType = vk.VK_STRUCTURE_TYPE_SUBMIT_INFO,
            .pNext = null,
            .waitSemaphoreCount = 0,
            .pWaitSemaphores = null,
            .pWaitDstStageMask = null,
            .commandBufferCount = 1,
            .pCommandBuffers = &cmd_buf,
            .signalSemaphoreCount = 0,
            .pSignalSemaphores = null,
        };
        _ = vk.vkQueueSubmit(self.queue, 1, &submit_info, null);
        _ = vk.vkQueueWaitIdle(self.queue);
        vk.vkFreeCommandBuffers(device, self.cmd_pool, 1, &cmd_buf);
    }

    /// 图像布局转换
    fn transitionImageLayout(self: *VulkanDevice, image: vk.VkImage, old_layout: vk.VkImageLayout, new_layout: vk.VkImageLayout) void {
        const device = self.device;

        const alloc_info = vk.VkCommandBufferAllocateInfo{
            .sType = vk.VK_STRUCTURE_TYPE_COMMAND_BUFFER_ALLOCATE_INFO,
            .pNext = null,
            .commandPool = self.cmd_pool,
            .level = vk.VK_COMMAND_BUFFER_LEVEL_PRIMARY,
            .commandBufferCount = 1,
        };
        var cmd_buf: vk.VkCommandBuffer = undefined;
        _ = vk.vkAllocateCommandBuffers(device, &alloc_info, &cmd_buf);

        const begin_info = vk.VkCommandBufferBeginInfo{
            .sType = vk.VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO,
            .pNext = null,
            .flags = vk.VK_COMMAND_BUFFER_USAGE_ONE_TIME_SUBMIT_BIT,
            .pInheritanceInfo = null,
        };
        _ = vk.vkBeginCommandBuffer(cmd_buf, &begin_info);

        var barrier = vk.VkImageMemoryBarrier{
            .sType = vk.VK_STRUCTURE_TYPE_IMAGE_MEMORY_BARRIER,
            .pNext = null,
            .srcAccessMask = 0,
            .dstAccessMask = 0,
            .oldLayout = old_layout,
            .newLayout = new_layout,
            .srcQueueFamilyIndex = vk.VK_QUEUE_FAMILY_IGNORED,
            .dstQueueFamilyIndex = vk.VK_QUEUE_FAMILY_IGNORED,
            .image = image,
            .subresourceRange = .{
                .aspectMask = vk.VK_IMAGE_ASPECT_COLOR_BIT,
                .baseMipLevel = 0,
                .levelCount = 1,
                .baseArrayLayer = 0,
                .layerCount = 1,
            },
        };

        var src_stage: vk.VkPipelineStageFlags = 0;
        var dst_stage: vk.VkPipelineStageFlags = 0;

        if (old_layout == vk.VK_IMAGE_LAYOUT_UNDEFINED and new_layout == vk.VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL) {
            barrier.srcAccessMask = 0;
            barrier.dstAccessMask = vk.VK_ACCESS_TRANSFER_WRITE_BIT;
            src_stage = vk.VK_PIPELINE_STAGE_TOP_OF_PIPE_BIT;
            dst_stage = vk.VK_PIPELINE_STAGE_TRANSFER_BIT;
        } else if (old_layout == vk.VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL and new_layout == vk.VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL) {
            barrier.srcAccessMask = vk.VK_ACCESS_TRANSFER_WRITE_BIT;
            barrier.dstAccessMask = vk.VK_ACCESS_SHADER_READ_BIT;
            src_stage = vk.VK_PIPELINE_STAGE_TRANSFER_BIT;
            dst_stage = vk.VK_PIPELINE_STAGE_FRAGMENT_SHADER_BIT;
        } else if (old_layout == vk.VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL and new_layout == vk.VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL) {
            barrier.srcAccessMask = vk.VK_ACCESS_SHADER_READ_BIT;
            barrier.dstAccessMask = vk.VK_ACCESS_TRANSFER_WRITE_BIT;
            src_stage = vk.VK_PIPELINE_STAGE_FRAGMENT_SHADER_BIT;
            dst_stage = vk.VK_PIPELINE_STAGE_TRANSFER_BIT;
        } else if (old_layout == vk.VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL and new_layout == vk.VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL) {
            barrier.srcAccessMask = vk.VK_ACCESS_SHADER_READ_BIT;
            barrier.dstAccessMask = vk.VK_ACCESS_TRANSFER_READ_BIT;
            src_stage = vk.VK_PIPELINE_STAGE_FRAGMENT_SHADER_BIT;
            dst_stage = vk.VK_PIPELINE_STAGE_TRANSFER_BIT;
        } else if (old_layout == vk.VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL and new_layout == vk.VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL) {
            barrier.srcAccessMask = vk.VK_ACCESS_TRANSFER_READ_BIT;
            barrier.dstAccessMask = vk.VK_ACCESS_SHADER_READ_BIT;
            src_stage = vk.VK_PIPELINE_STAGE_TRANSFER_BIT;
            dst_stage = vk.VK_PIPELINE_STAGE_FRAGMENT_SHADER_BIT;
        } else {
            barrier.srcAccessMask = 0;
            barrier.dstAccessMask = 0;
            src_stage = vk.VK_PIPELINE_STAGE_TOP_OF_PIPE_BIT;
            dst_stage = vk.VK_PIPELINE_STAGE_BOTTOM_OF_PIPE_BIT;
        }

        vk.vkCmdPipelineBarrier(cmd_buf, src_stage, dst_stage, 0, 0, null, 0, null, 1, &barrier);

        _ = vk.vkEndCommandBuffer(cmd_buf);

        const submit_info = vk.VkSubmitInfo{
            .sType = vk.VK_STRUCTURE_TYPE_SUBMIT_INFO,
            .pNext = null,
            .waitSemaphoreCount = 0,
            .pWaitSemaphores = null,
            .pWaitDstStageMask = null,
            .commandBufferCount = 1,
            .pCommandBuffers = &cmd_buf,
            .signalSemaphoreCount = 0,
            .pSignalSemaphores = null,
        };
        _ = vk.vkQueueSubmit(self.queue, 1, &submit_info, null);
        _ = vk.vkQueueWaitIdle(self.queue);
        vk.vkFreeCommandBuffers(device, self.cmd_pool, 1, &cmd_buf);
    }

    /// 创建 RGBA8Unorm 纹理 (图片)
    pub fn createTextureRGBA(self: *VulkanDevice, width: u32, height: u32) ?vk.VkImageView {
        _ = self;
        _ = width;
        _ = height;
        // TODO: 创建 RGBA 纹理
        return null;
    }

    /// 绘制图片
    pub fn drawImage(self: *VulkanDevice, vertices: []const TextVertex, texture: vk.VkImageView) void {
        self.updateTextVertices(vertices);
        self.drawTextured(@intCast(vertices.len), texture);
    }
};

// ── Vulkan 初始化辅助函数 ──────────────────────────────────────────────────

fn createInstance(allocator: std.mem.Allocator) !vk.VkInstance {
    _ = allocator;
    const app_info = vk.VkApplicationInfo{
        .sType = vk.VK_STRUCTURE_TYPE_APPLICATION_INFO,
        .pNext = null,
        .pApplicationName = "zigui",
        .applicationVersion = vk.VK_MAKE_VERSION(0, 1, 0),
        .pEngineName = "zigui",
        .engineVersion = vk.VK_MAKE_VERSION(0, 1, 0),
        .apiVersion = vk.VK_API_VERSION_1_1,
    };

    const extensions = [_][*:0]const u8{
        "VK_KHR_surface",
        "VK_KHR_xcb_surface",
        "VK_KHR_wayland_surface",
    };

    const create_info = vk.VkInstanceCreateInfo{
        .sType = vk.VK_STRUCTURE_TYPE_INSTANCE_CREATE_INFO,
        .pNext = null,
        .flags = 0,
        .pApplicationInfo = &app_info,
        .enabledLayerCount = 0,
        .ppEnabledLayerNames = null,
        .enabledExtensionCount = extensions.len,
        .ppEnabledExtensionNames = &extensions,
    };

    var instance: vk.VkInstance = undefined;
    const result = vk.vkCreateInstance(&create_info, null, &instance);
    if (result != vk.VK_SUCCESS) return error.InstanceCreationFailed;
    return instance;
}

fn createXcbSurface(instance: vk.VkInstance, xcb_conn_ptr: *anyopaque, window_id: u32) !vk.VkSurfaceKHR {
    const create_info = vk.VkXcbSurfaceCreateInfoKHR{
        .sType = vk.VK_STRUCTURE_TYPE_XCB_SURFACE_CREATE_INFO_KHR,
        .pNext = null,
        .flags = 0,
        .connection = @ptrCast(@alignCast(xcb_conn_ptr)),
        .window = window_id,
    };

    var surface: vk.VkSurfaceKHR = undefined;
    const result = vk.vkCreateXcbSurfaceKHR(instance, &create_info, null, &surface);
    if (result != vk.VK_SUCCESS) return error.SurfaceCreationFailed;
    return surface;
}

fn createWaylandSurface(instance: vk.VkInstance, wl_display_ptr: *anyopaque, wl_surface_ptr: *anyopaque) !vk.VkSurfaceKHR {
    const create_info = vk.VkWaylandSurfaceCreateInfoKHR{
        .sType = vk.VK_STRUCTURE_TYPE_WAYLAND_SURFACE_CREATE_INFO_KHR,
        .pNext = null,
        .flags = 0,
        .display = @ptrCast(wl_display_ptr),
        .surface = @ptrCast(wl_surface_ptr),
    };

    var surface: vk.VkSurfaceKHR = undefined;
    const result = vk.vkCreateWaylandSurfaceKHR(instance, &create_info, null, &surface);
    if (result != vk.VK_SUCCESS) return error.SurfaceCreationFailed;
    return surface;
}

const PhysicalDeviceResult = struct {
    device: vk.VkPhysicalDevice,
    queue_family: u32,
};

fn selectPhysicalDevice(instance: vk.VkInstance, surface: vk.VkSurfaceKHR) !PhysicalDeviceResult {
    var count: u32 = 0;
    _ = vk.vkEnumeratePhysicalDevices(instance, &count, null);
    if (count == 0) return error.NoPhysicalDevice;

    var devices: [16]vk.VkPhysicalDevice = undefined;
    _ = vk.vkEnumeratePhysicalDevices(instance, &count, &devices);

    for (devices[0..count]) |device| {
        var queue_count: u32 = 0;
        vk.vkGetPhysicalDeviceQueueFamilyProperties(device, &queue_count, null);
        var queue_families: [16]vk.VkQueueFamilyProperties = undefined;
        vk.vkGetPhysicalDeviceQueueFamilyProperties(device, &queue_count, &queue_families);

        for (0..queue_count) |i| {
            if (queue_families[i].queueFlags & vk.VK_QUEUE_GRAPHICS_BIT != 0) {
                var present_support: vk.VkBool32 = vk.VK_FALSE;
                _ = vk.vkGetPhysicalDeviceSurfaceSupportKHR(device, @intCast(i), surface, &present_support);
                if (present_support == vk.VK_TRUE) {
                    return .{ .device = device, .queue_family = @intCast(i) };
                }
            }
        }
    }
    return error.NoSuitableDevice;
}

const LogicalDeviceResult = struct {
    device: vk.VkDevice,
    queue: vk.VkQueue,
};

fn createLogicalDevice(physical_device: vk.VkPhysicalDevice, queue_family: u32) !LogicalDeviceResult {
    const queue_priority: f32 = 1.0;
    const queue_create_info = vk.VkDeviceQueueCreateInfo{
        .sType = vk.VK_STRUCTURE_TYPE_DEVICE_QUEUE_CREATE_INFO,
        .pNext = null,
        .flags = 0,
        .queueFamilyIndex = queue_family,
        .queueCount = 1,
        .pQueuePriorities = &queue_priority,
    };

    const extensions = [_][*:0]const u8{vk.VK_KHR_SWAPCHAIN_EXTENSION_NAME};

    const create_info = vk.VkDeviceCreateInfo{
        .sType = vk.VK_STRUCTURE_TYPE_DEVICE_CREATE_INFO,
        .pNext = null,
        .flags = 0,
        .queueCreateInfoCount = 1,
        .pQueueCreateInfos = &queue_create_info,
        .enabledLayerCount = 0,
        .ppEnabledLayerNames = null,
        .enabledExtensionCount = extensions.len,
        .ppEnabledExtensionNames = &extensions,
        .pEnabledFeatures = null,
    };

    var device: vk.VkDevice = undefined;
    const result = vk.vkCreateDevice(physical_device, &create_info, null, &device);
    if (result != vk.VK_SUCCESS) return error.DeviceCreationFailed;

    var queue: vk.VkQueue = undefined;
    vk.vkGetDeviceQueue(device, queue_family, 0, &queue);

    return .{ .device = device, .queue = queue };
}

const SwapchainResult = struct {
    swapchain: vk.VkSwapchainKHR,
    images: []vk.VkImage,
    views: []vk.VkImageView,
    format: vk.VkFormat,
    extent: vk.VkExtent2D,
};

fn createSwapchain(allocator: std.mem.Allocator, physical_device: vk.VkPhysicalDevice, device: vk.VkDevice, surface: vk.VkSurfaceKHR, width: u32, height: u32) !SwapchainResult {
    var capabilities: vk.VkSurfaceCapabilitiesKHR = undefined;
    _ = vk.vkGetPhysicalDeviceSurfaceCapabilitiesKHR(physical_device, surface, &capabilities);

    // 选择格式
    var format_count: u32 = 0;
    _ = vk.vkGetPhysicalDeviceSurfaceFormatsKHR(physical_device, surface, &format_count, null);
    var formats: [64]vk.VkSurfaceFormatKHR = undefined;
    if (format_count > 64) format_count = 64;
    _ = vk.vkGetPhysicalDeviceSurfaceFormatsKHR(physical_device, surface, &format_count, &formats);

    var selected_format: vk.VkSurfaceFormatKHR = formats[0];
    for (formats[0..format_count]) |f| {
        if (f.format == vk.VK_FORMAT_B8G8R8A8_SRGB and f.colorSpace == vk.VK_COLOR_SPACE_SRGB_NONLINEAR_KHR) {
            selected_format = f;
            break;
        }
    }

    const extent = vk.VkExtent2D{
        .width = @max(capabilities.minImageExtent.width, @min(capabilities.maxImageExtent.width, width)),
        .height = @max(capabilities.minImageExtent.height, @min(capabilities.maxImageExtent.height, height)),
    };

    var image_count = capabilities.minImageCount + 1;
    if (capabilities.maxImageCount > 0 and image_count > capabilities.maxImageCount) {
        image_count = capabilities.maxImageCount;
    }

    const create_info = vk.VkSwapchainCreateInfoKHR{
        .sType = vk.VK_STRUCTURE_TYPE_SWAPCHAIN_CREATE_INFO_KHR,
        .pNext = null,
        .flags = 0,
        .surface = surface,
        .minImageCount = image_count,
        .imageFormat = selected_format.format,
        .imageColorSpace = selected_format.colorSpace,
        .imageExtent = extent,
        .imageArrayLayers = 1,
        .imageUsage = vk.VK_IMAGE_USAGE_COLOR_ATTACHMENT_BIT,
        .imageSharingMode = vk.VK_SHARING_MODE_EXCLUSIVE,
        .queueFamilyIndexCount = 0,
        .pQueueFamilyIndices = null,
        .preTransform = capabilities.currentTransform,
        .compositeAlpha = vk.VK_COMPOSITE_ALPHA_OPAQUE_BIT_KHR,
        .presentMode = vk.VK_PRESENT_MODE_FIFO_KHR,
        .clipped = vk.VK_TRUE,
        .oldSwapchain = null,
    };

    var swapchain: vk.VkSwapchainKHR = undefined;
    if (vk.vkCreateSwapchainKHR(device, &create_info, null, &swapchain) != vk.VK_SUCCESS) {
        return error.SwapchainCreationFailed;
    }

    // 获取 images
    var swap_image_count: u32 = 0;
    _ = vk.vkGetSwapchainImagesKHR(device, swapchain, &swap_image_count, null);
    const images = try allocator.alloc(vk.VkImage, swap_image_count);
    _ = vk.vkGetSwapchainImagesKHR(device, swapchain, &swap_image_count, images.ptr);

    // 创建 image views
    const views = try allocator.alloc(vk.VkImageView, swap_image_count);
    for (0..swap_image_count) |i| {
        const view_info = vk.VkImageViewCreateInfo{
            .sType = vk.VK_STRUCTURE_TYPE_IMAGE_VIEW_CREATE_INFO,
            .pNext = null,
            .flags = 0,
            .image = images[i],
            .viewType = vk.VK_IMAGE_VIEW_TYPE_2D,
            .format = selected_format.format,
            .components = .{ .r = vk.VK_COMPONENT_SWIZZLE_IDENTITY, .g = vk.VK_COMPONENT_SWIZZLE_IDENTITY, .b = vk.VK_COMPONENT_SWIZZLE_IDENTITY, .a = vk.VK_COMPONENT_SWIZZLE_IDENTITY },
            .subresourceRange = .{ .aspectMask = vk.VK_IMAGE_ASPECT_COLOR_BIT, .baseMipLevel = 0, .levelCount = 1, .baseArrayLayer = 0, .layerCount = 1 },
        };
        if (vk.vkCreateImageView(device, &view_info, null, &views[i]) != vk.VK_SUCCESS) {
            return error.ImageViewCreationFailed;
        }
    }

    return .{
        .swapchain = swapchain,
        .images = images,
        .views = views,
        .format = selected_format.format,
        .extent = extent,
    };
}

fn createRenderPass(device: vk.VkDevice, format: vk.VkFormat) !vk.VkRenderPass {
    const color_attachment = vk.VkAttachmentDescription{
        .flags = 0,
        .format = format,
        .samples = vk.VK_SAMPLE_COUNT_1_BIT,
        .loadOp = vk.VK_ATTACHMENT_LOAD_OP_CLEAR,
        .storeOp = vk.VK_ATTACHMENT_STORE_OP_STORE,
        .stencilLoadOp = vk.VK_ATTACHMENT_LOAD_OP_DONT_CARE,
        .stencilStoreOp = vk.VK_ATTACHMENT_STORE_OP_DONT_CARE,
        .initialLayout = vk.VK_IMAGE_LAYOUT_UNDEFINED,
        .finalLayout = vk.VK_IMAGE_LAYOUT_PRESENT_SRC_KHR,
    };

    const color_ref = vk.VkAttachmentReference{
        .attachment = 0,
        .layout = vk.VK_IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL,
    };

    const subpass = vk.VkSubpassDescription{
        .flags = 0,
        .pipelineBindPoint = vk.VK_PIPELINE_BIND_POINT_GRAPHICS,
        .inputAttachmentCount = 0,
        .pInputAttachments = null,
        .colorAttachmentCount = 1,
        .pColorAttachments = &color_ref,
        .pResolveAttachments = null,
        .pDepthStencilAttachment = null,
        .preserveAttachmentCount = 0,
        .pPreserveAttachments = null,
    };

    const dependency = vk.VkSubpassDependency{
        .srcSubpass = vk.VK_SUBPASS_EXTERNAL,
        .dstSubpass = 0,
        .srcStageMask = vk.VK_PIPELINE_STAGE_COLOR_ATTACHMENT_OUTPUT_BIT,
        .dstStageMask = vk.VK_PIPELINE_STAGE_COLOR_ATTACHMENT_OUTPUT_BIT,
        .srcAccessMask = 0,
        .dstAccessMask = vk.VK_ACCESS_COLOR_ATTACHMENT_WRITE_BIT,
        .dependencyFlags = 0,
    };

    const create_info = vk.VkRenderPassCreateInfo{
        .sType = vk.VK_STRUCTURE_TYPE_RENDER_PASS_CREATE_INFO,
        .pNext = null,
        .flags = 0,
        .attachmentCount = 1,
        .pAttachments = &color_attachment,
        .subpassCount = 1,
        .pSubpasses = &subpass,
        .dependencyCount = 1,
        .pDependencies = &dependency,
    };

    var render_pass: vk.VkRenderPass = undefined;
    if (vk.vkCreateRenderPass(device, &create_info, null, &render_pass) != vk.VK_SUCCESS) {
        return error.RenderPassCreationFailed;
    }
    return render_pass;
}

const PipelineResult = struct {
    pipeline: vk.VkPipeline,
    layout: vk.VkPipelineLayout,
};

fn createSolidPipeline(device: vk.VkDevice, render_pass: vk.VkRenderPass, extent: vk.VkExtent2D) !PipelineResult {
    // Push constant range (screen size)
    const push_range = vk.VkPushConstantRange{
        .stageFlags = vk.VK_SHADER_STAGE_VERTEX_BIT,
        .offset = 0,
        .size = 8,
    };

    const layout_info = vk.VkPipelineLayoutCreateInfo{
        .sType = vk.VK_STRUCTURE_TYPE_PIPELINE_LAYOUT_CREATE_INFO,
        .pNext = null,
        .flags = 0,
        .setLayoutCount = 0,
        .pSetLayouts = null,
        .pushConstantRangeCount = 1,
        .pPushConstantRanges = &push_range,
    };

    var layout: vk.VkPipelineLayout = undefined;
    if (vk.vkCreatePipelineLayout(device, &layout_info, null, &layout) != vk.VK_SUCCESS) {
        return error.PipelineLayoutCreationFailed;
    }

    // 加载嵌入的 SPIR-V shader (4 字节对齐)
    const vert_spv align(4) = @embedFile("spirv/solid_vert.spv");
    const frag_spv align(4) = @embedFile("spirv/solid_frag.spv");

    const vert_module = createShaderModule(device, vert_spv) orelse return error.ShaderModuleCreationFailed;
    const frag_module = createShaderModule(device, frag_spv) orelse return error.ShaderModuleCreationFailed;
    defer vk.vkDestroyShaderModule(device, vert_module, null);
    defer vk.vkDestroyShaderModule(device, frag_module, null);

    // Shader stages
    const stages = [_]vk.VkPipelineShaderStageCreateInfo{
        .{ .sType = vk.VK_STRUCTURE_TYPE_PIPELINE_SHADER_STAGE_CREATE_INFO, .pNext = null, .flags = 0, .stage = vk.VK_SHADER_STAGE_VERTEX_BIT, .module = vert_module, .pName = "main", .pSpecializationInfo = null },
        .{ .sType = vk.VK_STRUCTURE_TYPE_PIPELINE_SHADER_STAGE_CREATE_INFO, .pNext = null, .flags = 0, .stage = vk.VK_SHADER_STAGE_FRAGMENT_BIT, .module = frag_module, .pName = "main", .pSpecializationInfo = null },
    };

    // Vertex input: pos [2]f32 + color [4]f32 = 24 bytes
    const binding = vk.VkVertexInputBindingDescription{ .binding = 0, .stride = @sizeOf(Vertex2D), .inputRate = vk.VK_VERTEX_INPUT_RATE_VERTEX };
    const attributes = [_]vk.VkVertexInputAttributeDescription{
        .{ .location = 0, .binding = 0, .format = vk.VK_FORMAT_R32G32_SFLOAT, .offset = 0 },
        .{ .location = 1, .binding = 0, .format = vk.VK_FORMAT_R32G32B32A32_SFLOAT, .offset = 8 },
    };
    const vertex_input = vk.VkPipelineVertexInputStateCreateInfo{
        .sType = vk.VK_STRUCTURE_TYPE_PIPELINE_VERTEX_INPUT_STATE_CREATE_INFO, .pNext = null, .flags = 0,
        .vertexBindingDescriptionCount = 1, .pVertexBindingDescriptions = &binding,
        .vertexAttributeDescriptionCount = attributes.len, .pVertexAttributeDescriptions = &attributes,
    };

    const pipeline = try createGraphicsPipeline(device, &stages, &vertex_input, render_pass, layout, extent);
    return .{ .pipeline = pipeline, .layout = layout };
}

fn createTexturedPipeline(device: vk.VkDevice, render_pass: vk.VkRenderPass, extent: vk.VkExtent2D, desc_set_layout: vk.VkDescriptorSetLayout) !PipelineResult {
    const push_range = vk.VkPushConstantRange{
        .stageFlags = vk.VK_SHADER_STAGE_VERTEX_BIT,
        .offset = 0,
        .size = 8,
    };

    const set_layouts = [_]vk.VkDescriptorSetLayout{desc_set_layout};
    const layout_info = vk.VkPipelineLayoutCreateInfo{
        .sType = vk.VK_STRUCTURE_TYPE_PIPELINE_LAYOUT_CREATE_INFO,
        .pNext = null,
        .flags = 0,
        .setLayoutCount = 1,
        .pSetLayouts = &set_layouts,
        .pushConstantRangeCount = 1,
        .pPushConstantRanges = &push_range,
    };

    var layout: vk.VkPipelineLayout = undefined;
    if (vk.vkCreatePipelineLayout(device, &layout_info, null, &layout) != vk.VK_SUCCESS) {
        return error.PipelineLayoutCreationFailed;
    }

    const vert_spv align(4) = @embedFile("spirv/textured_vert.spv");
    const frag_spv align(4) = @embedFile("spirv/textured_frag.spv");

    const vert_module = createShaderModule(device, vert_spv) orelse return error.ShaderModuleCreationFailed;
    const frag_module = createShaderModule(device, frag_spv) orelse return error.ShaderModuleCreationFailed;
    defer vk.vkDestroyShaderModule(device, vert_module, null);
    defer vk.vkDestroyShaderModule(device, frag_module, null);

    const stages = [_]vk.VkPipelineShaderStageCreateInfo{
        .{ .sType = vk.VK_STRUCTURE_TYPE_PIPELINE_SHADER_STAGE_CREATE_INFO, .pNext = null, .flags = 0, .stage = vk.VK_SHADER_STAGE_VERTEX_BIT, .module = vert_module, .pName = "main", .pSpecializationInfo = null },
        .{ .sType = vk.VK_STRUCTURE_TYPE_PIPELINE_SHADER_STAGE_CREATE_INFO, .pNext = null, .flags = 0, .stage = vk.VK_SHADER_STAGE_FRAGMENT_BIT, .module = frag_module, .pName = "main", .pSpecializationInfo = null },
    };

    // TextVertex: pos [2]f32 + uv [2]f32 + color [4]f32 = 32 bytes
    const binding = vk.VkVertexInputBindingDescription{ .binding = 0, .stride = @sizeOf(TextVertex), .inputRate = vk.VK_VERTEX_INPUT_RATE_VERTEX };
    const attributes = [_]vk.VkVertexInputAttributeDescription{
        .{ .location = 0, .binding = 0, .format = vk.VK_FORMAT_R32G32_SFLOAT, .offset = 0 },
        .{ .location = 1, .binding = 0, .format = vk.VK_FORMAT_R32G32_SFLOAT, .offset = 8 },
        .{ .location = 2, .binding = 0, .format = vk.VK_FORMAT_R32G32B32A32_SFLOAT, .offset = 16 },
    };
    const vertex_input = vk.VkPipelineVertexInputStateCreateInfo{
        .sType = vk.VK_STRUCTURE_TYPE_PIPELINE_VERTEX_INPUT_STATE_CREATE_INFO, .pNext = null, .flags = 0,
        .vertexBindingDescriptionCount = 1, .pVertexBindingDescriptions = &binding,
        .vertexAttributeDescriptionCount = attributes.len, .pVertexAttributeDescriptions = &attributes,
    };

    const pipeline = try createGraphicsPipeline(device, &stages, &vertex_input, render_pass, layout, extent);
    return .{ .pipeline = pipeline, .layout = layout };
}

fn createShaderModule(device: vk.VkDevice, spv: []const u8) ?vk.VkShaderModule {
    // pCode 需要 u32 对齐; 复制到对齐缓冲区
    const aligned_len = (spv.len + 3) & ~@as(usize, 3);
    var buf: [65536]u8 align(4) = undefined;
    if (aligned_len > buf.len) return null;
    @memcpy(buf[0..spv.len], spv);
    const code_ptr: [*]const u32 = @ptrCast(@alignCast(&buf));
    const create_info = vk.VkShaderModuleCreateInfo{
        .sType = vk.VK_STRUCTURE_TYPE_SHADER_MODULE_CREATE_INFO,
        .pNext = null,
        .flags = 0,
        .codeSize = spv.len,
        .pCode = code_ptr,
    };
    var module: vk.VkShaderModule = undefined;
    if (vk.vkCreateShaderModule(device, &create_info, null, &module) != vk.VK_SUCCESS) return null;
    return module;
}

fn createGraphicsPipeline(device: vk.VkDevice, stages: []const vk.VkPipelineShaderStageCreateInfo, vertex_input: *const vk.VkPipelineVertexInputStateCreateInfo, render_pass: vk.VkRenderPass, pipeline_layout: vk.VkPipelineLayout, extent: vk.VkExtent2D) !vk.VkPipeline {
    const input_assembly = vk.VkPipelineInputAssemblyStateCreateInfo{
        .sType = vk.VK_STRUCTURE_TYPE_PIPELINE_INPUT_ASSEMBLY_STATE_CREATE_INFO, .pNext = null, .flags = 0,
        .topology = vk.VK_PRIMITIVE_TOPOLOGY_TRIANGLE_LIST, .primitiveRestartEnable = vk.VK_FALSE,
    };

    const viewport = vk.VkViewport{ .x = 0, .y = 0, .width = @floatFromInt(extent.width), .height = @floatFromInt(extent.height), .minDepth = 0, .maxDepth = 1 };
    const scissor = vk.VkRect2D{ .offset = .{ .x = 0, .y = 0 }, .extent = extent };
    const viewport_state = vk.VkPipelineViewportStateCreateInfo{
        .sType = vk.VK_STRUCTURE_TYPE_PIPELINE_VIEWPORT_STATE_CREATE_INFO, .pNext = null, .flags = 0,
        .viewportCount = 1, .pViewports = &viewport, .scissorCount = 1, .pScissors = &scissor,
    };

    const rasterizer = vk.VkPipelineRasterizationStateCreateInfo{
        .sType = vk.VK_STRUCTURE_TYPE_PIPELINE_RASTERIZATION_STATE_CREATE_INFO, .pNext = null, .flags = 0,
        .depthClampEnable = vk.VK_FALSE, .rasterizerDiscardEnable = vk.VK_FALSE,
        .polygonMode = vk.VK_POLYGON_MODE_FILL, .cullMode = vk.VK_CULL_MODE_NONE,
        .frontFace = vk.VK_FRONT_FACE_CLOCKWISE, .depthBiasEnable = vk.VK_FALSE,
        .depthBiasConstantFactor = 0, .depthBiasClamp = 0, .depthBiasSlopeFactor = 0, .lineWidth = 1.0,
    };

    const multisampling = vk.VkPipelineMultisampleStateCreateInfo{
        .sType = vk.VK_STRUCTURE_TYPE_PIPELINE_MULTISAMPLE_STATE_CREATE_INFO, .pNext = null, .flags = 0,
        .rasterizationSamples = vk.VK_SAMPLE_COUNT_1_BIT, .sampleShadingEnable = vk.VK_FALSE,
        .minSampleShading = 1.0, .pSampleMask = null, .alphaToCoverageEnable = vk.VK_FALSE, .alphaToOneEnable = vk.VK_FALSE,
    };

    const color_blend_attachment = vk.VkPipelineColorBlendAttachmentState{
        .blendEnable = vk.VK_TRUE,
        .srcColorBlendFactor = vk.VK_BLEND_FACTOR_ONE,
        .dstColorBlendFactor = vk.VK_BLEND_FACTOR_ONE_MINUS_SRC_ALPHA,
        .colorBlendOp = vk.VK_BLEND_OP_ADD,
        .srcAlphaBlendFactor = vk.VK_BLEND_FACTOR_ONE,
        .dstAlphaBlendFactor = vk.VK_BLEND_FACTOR_ONE_MINUS_SRC_ALPHA,
        .alphaBlendOp = vk.VK_BLEND_OP_ADD,
        .colorWriteMask = vk.VK_COLOR_COMPONENT_R_BIT | vk.VK_COLOR_COMPONENT_G_BIT | vk.VK_COLOR_COMPONENT_B_BIT | vk.VK_COLOR_COMPONENT_A_BIT,
    };
    const color_blending = vk.VkPipelineColorBlendStateCreateInfo{
        .sType = vk.VK_STRUCTURE_TYPE_PIPELINE_COLOR_BLEND_STATE_CREATE_INFO, .pNext = null, .flags = 0,
        .logicOpEnable = vk.VK_FALSE, .logicOp = vk.VK_LOGIC_OP_COPY,
        .attachmentCount = 1, .pAttachments = &color_blend_attachment,
        .blendConstants = .{ 0, 0, 0, 0 },
    };

    const dynamic_states = [_]vk.VkDynamicState{
        vk.VK_DYNAMIC_STATE_VIEWPORT,
        vk.VK_DYNAMIC_STATE_SCISSOR,
    };
    const dynamic_state = vk.VkPipelineDynamicStateCreateInfo{
        .sType = vk.VK_STRUCTURE_TYPE_PIPELINE_DYNAMIC_STATE_CREATE_INFO,
        .pNext = null,
        .flags = 0,
        .dynamicStateCount = dynamic_states.len,
        .pDynamicStates = &dynamic_states,
    };

    const pipeline_info = vk.VkGraphicsPipelineCreateInfo{
        .sType = vk.VK_STRUCTURE_TYPE_GRAPHICS_PIPELINE_CREATE_INFO, .pNext = null, .flags = 0,
        .stageCount = @intCast(stages.len), .pStages = stages.ptr,
        .pVertexInputState = vertex_input, .pInputAssemblyState = &input_assembly,
        .pTessellationState = null, .pViewportState = &viewport_state,
        .pRasterizationState = &rasterizer, .pMultisampleState = &multisampling,
        .pDepthStencilState = null, .pColorBlendState = &color_blending,
        .pDynamicState = &dynamic_state, .layout = pipeline_layout,
        .renderPass = render_pass, .subpass = 0,
        .basePipelineHandle = null, .basePipelineIndex = -1,
    };

    var pipeline: vk.VkPipeline = undefined;
    if (vk.vkCreateGraphicsPipelines(device, null, 1, &pipeline_info, null, &pipeline) != vk.VK_SUCCESS) {
        return error.PipelineCreationFailed;
    }
    return pipeline;
}

fn createFramebuffers(allocator: std.mem.Allocator, device: vk.VkDevice, render_pass: vk.VkRenderPass, views: []vk.VkImageView, extent: vk.VkExtent2D) ![]vk.VkFramebuffer {
    const framebuffers = try allocator.alloc(vk.VkFramebuffer, views.len);
    for (0..views.len) |i| {
        const attachments = [_]vk.VkImageView{views[i]};
        const fb_info = vk.VkFramebufferCreateInfo{
            .sType = vk.VK_STRUCTURE_TYPE_FRAMEBUFFER_CREATE_INFO,
            .pNext = null,
            .flags = 0,
            .renderPass = render_pass,
            .attachmentCount = 1,
            .pAttachments = &attachments,
            .width = extent.width,
            .height = extent.height,
            .layers = 1,
        };
        if (vk.vkCreateFramebuffer(device, &fb_info, null, &framebuffers[i]) != vk.VK_SUCCESS) {
            return error.FramebufferCreationFailed;
        }
    }
    return framebuffers;
}

fn createCommandPool(device: vk.VkDevice, queue_family: u32) !vk.VkCommandPool {
    const pool_info = vk.VkCommandPoolCreateInfo{
        .sType = vk.VK_STRUCTURE_TYPE_COMMAND_POOL_CREATE_INFO,
        .pNext = null,
        .flags = vk.VK_COMMAND_POOL_CREATE_RESET_COMMAND_BUFFER_BIT,
        .queueFamilyIndex = queue_family,
    };
    var pool: vk.VkCommandPool = undefined;
    if (vk.vkCreateCommandPool(device, &pool_info, null, &pool) != vk.VK_SUCCESS) {
        return error.CommandPoolCreationFailed;
    }
    return pool;
}

fn allocateCommandBuffers(allocator: std.mem.Allocator, device: vk.VkDevice, pool: vk.VkCommandPool, count: u32) ![]vk.VkCommandBuffer {
    const buffers = try allocator.alloc(vk.VkCommandBuffer, count);
    const alloc_info = vk.VkCommandBufferAllocateInfo{
        .sType = vk.VK_STRUCTURE_TYPE_COMMAND_BUFFER_ALLOCATE_INFO,
        .pNext = null,
        .commandPool = pool,
        .level = vk.VK_COMMAND_BUFFER_LEVEL_PRIMARY,
        .commandBufferCount = count,
    };
    if (vk.vkAllocateCommandBuffers(device, &alloc_info, buffers.ptr) != vk.VK_SUCCESS) {
        return error.CommandBufferAllocationFailed;
    }
    return buffers;
}

const VertexBufferResult = struct {
    buffer: vk.VkBuffer,
    memory: vk.VkDeviceMemory,
    mapped: [*]u8,
};

fn createVertexBuffer(physical_device: vk.VkPhysicalDevice, device: vk.VkDevice, size: usize) !VertexBufferResult {
    const buffer_info = vk.VkBufferCreateInfo{
        .sType = vk.VK_STRUCTURE_TYPE_BUFFER_CREATE_INFO,
        .pNext = null,
        .flags = 0,
        .size = size,
        .usage = vk.VK_BUFFER_USAGE_VERTEX_BUFFER_BIT,
        .sharingMode = vk.VK_SHARING_MODE_EXCLUSIVE,
        .queueFamilyIndexCount = 0,
        .pQueueFamilyIndices = null,
    };

    var buffer: vk.VkBuffer = undefined;
    if (vk.vkCreateBuffer(device, &buffer_info, null, &buffer) != vk.VK_SUCCESS) {
        return error.BufferCreationFailed;
    }

    var mem_reqs: vk.VkMemoryRequirements = undefined;
    vk.vkGetBufferMemoryRequirements(device, buffer, &mem_reqs);

    // 查找 host-visible memory type
    const mem_type_index = findMemoryType(physical_device, mem_reqs.memoryTypeBits, vk.VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT | vk.VK_MEMORY_PROPERTY_HOST_COHERENT_BIT) orelse return error.NoSuitableMemoryType;

    const alloc_info = vk.VkMemoryAllocateInfo{
        .sType = vk.VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO,
        .pNext = null,
        .allocationSize = mem_reqs.size,
        .memoryTypeIndex = mem_type_index,
    };

    var memory: vk.VkDeviceMemory = undefined;
    if (vk.vkAllocateMemory(device, &alloc_info, null, &memory) != vk.VK_SUCCESS) {
        return error.MemoryAllocationFailed;
    }

    _ = vk.vkBindBufferMemory(device, buffer, memory, 0);

    var mapped: ?*anyopaque = null;
    if (vk.vkMapMemory(device, memory, 0, size, 0, &mapped) != vk.VK_SUCCESS) {
        return error.MemoryMapFailed;
    }

    return .{
        .buffer = buffer,
        .memory = memory,
        .mapped = @ptrCast(mapped),
    };
}

/// 查找满足要求的内存类型
fn findMemoryType(physical_device: vk.VkPhysicalDevice, type_filter: u32, properties: vk.VkMemoryPropertyFlags) ?u32 {
    var mem_props: vk.VkPhysicalDeviceMemoryProperties = undefined;
    vk.vkGetPhysicalDeviceMemoryProperties(physical_device, &mem_props);
    var i: u32 = 0;
    while (i < mem_props.memoryTypeCount) : (i += 1) {
        if ((type_filter & (@as(u32, 1) << @intCast(i))) != 0 and
            (mem_props.memoryTypes[i].propertyFlags & properties) == properties)
        {
            return i;
        }
    }
    return null;
}

const SyncObjects = struct {
    image_available: [frames_in_flight]vk.VkSemaphore,
    render_finished: [frames_in_flight]vk.VkSemaphore,
    in_flight: [frames_in_flight]vk.VkFence,
};

fn createSyncObjects(device: vk.VkDevice) !SyncObjects {
    var result: SyncObjects = undefined;

    const sem_info = vk.VkSemaphoreCreateInfo{
        .sType = vk.VK_STRUCTURE_TYPE_SEMAPHORE_CREATE_INFO,
        .pNext = null,
        .flags = 0,
    };

    const fence_info = vk.VkFenceCreateInfo{
        .sType = vk.VK_STRUCTURE_TYPE_FENCE_CREATE_INFO,
        .pNext = null,
        .flags = vk.VK_FENCE_CREATE_SIGNALED_BIT,
    };

    for (0..frames_in_flight) |i| {
        if (vk.vkCreateSemaphore(device, &sem_info, null, &result.image_available[i]) != vk.VK_SUCCESS) {
            return error.SyncCreationFailed;
        }
        if (vk.vkCreateSemaphore(device, &sem_info, null, &result.render_finished[i]) != vk.VK_SUCCESS) {
            return error.SyncCreationFailed;
        }
        if (vk.vkCreateFence(device, &fence_info, null, &result.in_flight[i]) != vk.VK_SUCCESS) {
            return error.SyncCreationFailed;
        }
    }

    return result;
}

fn createSampler(device: vk.VkDevice) !vk.VkSampler {
    const sampler_info = vk.VkSamplerCreateInfo{
        .sType = vk.VK_STRUCTURE_TYPE_SAMPLER_CREATE_INFO,
        .pNext = null,
        .flags = 0,
        .magFilter = vk.VK_FILTER_LINEAR,
        .minFilter = vk.VK_FILTER_LINEAR,
        .mipmapMode = vk.VK_SAMPLER_MIPMAP_MODE_LINEAR,
        .addressModeU = vk.VK_SAMPLER_ADDRESS_MODE_CLAMP_TO_EDGE,
        .addressModeV = vk.VK_SAMPLER_ADDRESS_MODE_CLAMP_TO_EDGE,
        .addressModeW = vk.VK_SAMPLER_ADDRESS_MODE_CLAMP_TO_EDGE,
        .mipLodBias = 0,
        .anisotropyEnable = vk.VK_FALSE,
        .maxAnisotropy = 1,
        .compareEnable = vk.VK_FALSE,
        .compareOp = vk.VK_COMPARE_OP_ALWAYS,
        .minLod = 0,
        .maxLod = 0,
        .borderColor = vk.VK_BORDER_COLOR_INT_OPAQUE_BLACK,
        .unnormalizedCoordinates = vk.VK_FALSE,
    };

    var sampler: vk.VkSampler = undefined;
    if (vk.vkCreateSampler(device, &sampler_info, null, &sampler) != vk.VK_SUCCESS) {
        return error.SamplerCreationFailed;
    }
    return sampler;
}

const DescriptorResult = struct {
    layout: vk.VkDescriptorSetLayout,
    pool: vk.VkDescriptorPool,
    set: vk.VkDescriptorSet,
};

fn createDescriptorSet(device: vk.VkDevice) !DescriptorResult {
    // Descriptor set layout: binding=0, combined image sampler, fragment stage
    const binding = vk.VkDescriptorSetLayoutBinding{
        .binding = 0,
        .descriptorType = vk.VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER,
        .descriptorCount = 1,
        .stageFlags = vk.VK_SHADER_STAGE_FRAGMENT_BIT,
        .pImmutableSamplers = null,
    };
    const layout_info = vk.VkDescriptorSetLayoutCreateInfo{
        .sType = vk.VK_STRUCTURE_TYPE_DESCRIPTOR_SET_LAYOUT_CREATE_INFO,
        .pNext = null,
        .flags = 0,
        .bindingCount = 1,
        .pBindings = &binding,
    };
    var layout: vk.VkDescriptorSetLayout = undefined;
    if (vk.vkCreateDescriptorSetLayout(device, &layout_info, null, &layout) != vk.VK_SUCCESS) {
        return error.DescriptorSetLayoutFailed;
    }

    // Descriptor pool
    const pool_size = vk.VkDescriptorPoolSize{
        .type = vk.VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER,
        .descriptorCount = 4,
    };
    const pool_info = vk.VkDescriptorPoolCreateInfo{
        .sType = vk.VK_STRUCTURE_TYPE_DESCRIPTOR_POOL_CREATE_INFO,
        .pNext = null,
        .flags = vk.VK_DESCRIPTOR_POOL_CREATE_FREE_DESCRIPTOR_SET_BIT,
        .maxSets = 4,
        .poolSizeCount = 1,
        .pPoolSizes = &pool_size,
    };
    var pool: vk.VkDescriptorPool = undefined;
    if (vk.vkCreateDescriptorPool(device, &pool_info, null, &pool) != vk.VK_SUCCESS) {
        vk.vkDestroyDescriptorSetLayout(device, layout, null);
        return error.DescriptorPoolFailed;
    }

    // Allocate descriptor set
    const alloc_info = vk.VkDescriptorSetAllocateInfo{
        .sType = vk.VK_STRUCTURE_TYPE_DESCRIPTOR_SET_ALLOCATE_INFO,
        .pNext = null,
        .descriptorPool = pool,
        .descriptorSetCount = 1,
        .pSetLayouts = &layout,
    };
    var set: vk.VkDescriptorSet = undefined;
    if (vk.vkAllocateDescriptorSets(device, &alloc_info, &set) != vk.VK_SUCCESS) {
        vk.vkDestroyDescriptorPool(device, pool, null);
        vk.vkDestroyDescriptorSetLayout(device, layout, null);
        return error.DescriptorSetAllocFailed;
    }

    return .{ .layout = layout, .pool = pool, .set = set };
}
