//! Direct3D 12 GPU 后端 (Windows)
//! 面向 2D UI 渲染优化: 纯色几何 + 纹理文本/图片
//!
//! 接口与 Vulkan/Metal 后端对齐, 由 gpu 层在 Windows 平台下选择使用。
//! 仅在 Windows 下编译; 非 Windows 平台提供桩实现以保持源码可解析。

const std = @import("std");
const builtin = @import("builtin");
const is_windows = builtin.os.tag == .windows;
const math = @import("../math.zig");

const d3d12 = if (is_windows) @cImport({
    @cDefine("WIN32_LEAN_AND_MEAN", "1");
    @cInclude("windows.h");
    @cInclude("d3d12.h");
    @cInclude("dxgi1_4.h");
    @cInclude("d3dcompiler.h");
}) else struct {};

pub const Vertex2D = extern struct {
    pos: [2]f32,
    color: [4]f32,
};

pub const TextVertex = extern struct {
    pos: [2]f32,
    uv: [2]f32,
    color: [4]f32,
};

/// GPU 纹理句柄 (DEFAULT heap 资源 + SRV 描述符 + 持久 upload 缓冲)
pub const TextureHandle = struct {
    resource: *anyopaque = undefined,
    srv_cpu: *anyopaque = undefined,
    srv_gpu: *anyopaque = undefined,
    upload: ?*anyopaque = null,
    width: u32 = 0,
    height: u32 = 0,
    is_rgba: bool = false,
};

const max_vertices: u32 = 65536;
const frames_in_flight: u32 = 2;
const max_textures: u32 = 16;

// ── HLSL 着色器源码 (运行时用 D3DCompile 编译) ───────────────────────────────
// D3D NDC: 左上角原点, Y 向下为正; 与 Vulkan (Y 向上) 相反, 顶点着色器翻转 Y。

const solid_vs_src =
    \\cbuffer ScreenCB : register(b0) { float2 u_screen_size; };
    \\struct VS_IN { float2 pos : POSITION; float4 color : COLOR; };
    \\struct VS_OUT { float4 pos : SV_POSITION; float4 color : COLOR; };
    \\VS_OUT main(VS_IN i) {
    \\    VS_OUT o;
    \\    o.pos = float4(i.pos.x / u_screen_size.x * 2.0 - 1.0,
    \\                   1.0 - i.pos.y / u_screen_size.y * 2.0, 0.0, 1.0);
    \\    o.color = i.color;
    \\    return o;
    \\}
;

const solid_ps_src =
    \\struct PS_IN { float4 pos : SV_POSITION; float4 color : COLOR; };
    \\float4 main(PS_IN i) : SV_TARGET { return i.color; }
;

const textured_vs_src =
    \\cbuffer ScreenCB : register(b0) { float2 u_screen_size; };
    \\struct VS_IN { float2 pos : POSITION; float2 uv : TEXCOORD0; float4 color : COLOR; };
    \\struct VS_OUT { float4 pos : SV_POSITION; float2 uv : TEXCOORD0; float4 color : COLOR; };
    \\VS_OUT main(VS_IN i) {
    \\    VS_OUT o;
    \\    o.pos = float4(i.pos.x / u_screen_size.x * 2.0 - 1.0,
    \\                   1.0 - i.pos.y / u_screen_size.y * 2.0, 0.0, 1.0);
    \\    o.uv = i.uv;
    \\    o.color = i.color;
    \\    return o;
    \\}
;

// 文本管线: R8 glyph atlas (swizzle 为 1,1,1,R), 输出预乘 alpha
const textured_ps_src =
    \\Texture2D<float4> tex : register(t0);
    \\SamplerState samp : register(s0);
    \\struct PS_IN { float4 pos : SV_POSITION; float2 uv : TEXCOORD0; float4 color : COLOR; };
    \\float4 main(PS_IN i) : SV_TARGET {
    \\    float4 t = tex.Sample(samp, i.uv);
    \\    float alpha = t.a * i.color.a;
    \\    return float4(i.color.rgb * alpha, alpha);
    \\}
;

// 图片管线: RGBA8, 保留纹理 RGB, 输出预乘 alpha
const image_ps_src =
    \\Texture2D<float4> tex : register(t0);
    \\SamplerState samp : register(s0);
    \\struct PS_IN { float4 pos : SV_POSITION; float2 uv : TEXCOORD0; float4 color : COLOR; };
    \\float4 main(PS_IN i) : SV_TARGET {
    \\    float4 t = tex.Sample(samp, i.uv);
    \\    float alpha = t.a * i.color.a;
    \\    return float4(t.rgb * i.color.rgb * alpha, alpha);
    \\}
;

pub const D3D12Device = if (is_windows) struct {
    allocator: std.mem.Allocator,
    device: ?*d3d12.ID3D12Device = null,
    command_queue: ?*d3d12.ID3D12CommandQueue = null,
    swap_chain: ?*d3d12.IDXGISwapChain3 = null,
    factory: ?*d3d12.IDXGIFactory4 = null,

    // RTV 描述符堆 (非 shader 可见)
    rtv_heap: ?*d3d12.ID3D12DescriptorHeap = null,
    rtv_descriptor_size: u32 = 0,
    rtv_cpu_start: d3d12.D3D12_CPU_DESCRIPTOR_HANDLE = .{ .ptr = 0 },
    render_targets: [2]?*d3d12.ID3D12Resource = .{ null, null },

    // SRV/CBV 描述符堆 (shader 可见)
    srv_heap: ?*d3d12.ID3D12DescriptorHeap = null,
    srv_descriptor_size: u32 = 0,
    srv_cpu_start: d3d12.D3D12_CPU_DESCRIPTOR_HANDLE = .{ .ptr = 0 },
    srv_gpu_start: d3d12.D3D12_GPU_DESCRIPTOR_HANDLE = .{ .ptr = 0 },
    next_srv_slot: u32 = 0,
    free_srv_slots: std.ArrayListUnmanaged(u32) = .{ .items = &.{}, .capacity = 0 },

    // 命令
    cmd_allocators: [2]?*d3d12.ID3D12CommandAllocator = .{ null, null },
    cmd_list: ?*d3d12.ID3D12GraphicsCommandList = null,
    upload_cmd_allocator: ?*d3d12.ID3D12CommandAllocator = null,
    upload_cmd_list: ?*d3d12.ID3D12GraphicsCommandList = null,

    // 同步
    fences: [2]?*d3d12.ID3D12Fence = .{ null, null },
    fence_values: [2]u64 = .{ 0, 0 },
    upload_fence: ?*d3d12.ID3D12Fence = null,
    upload_fence_value: u64 = 0,
    fence_event: ?*anyopaque = null,

    // 管线
    root_signature: ?*d3d12.ID3D12RootSignature = null,
    solid_pso: ?*d3d12.ID3D12PipelineState = null,
    textured_pso: ?*d3d12.ID3D12PipelineState = null,
    image_pso: ?*d3d12.ID3D12PipelineState = null,

    // 顶点缓冲 (upload heap, 持久映射, ring buffer: frames_in_flight 段)
    vertex_buffer: ?*d3d12.ID3D12Resource = null,
    vertex_mapped: [*]u8 = undefined,
    vertex_gpu_addr: u64 = 0,
    vertex_cursors: [frames_in_flight]usize = .{ 0, 0 },
    text_vertex_buffer: ?*d3d12.ID3D12Resource = null,
    text_vertex_mapped: [*]u8 = undefined,
    text_vertex_gpu_addr: u64 = 0,
    text_vertex_cursors: [frames_in_flight]usize = .{ 0, 0 },

    // 状态
    current_frame: u32 = 0,
    fb_width: u32 = 0, // 逻辑尺寸
    fb_height: u32 = 0,
    swapchain_width: u32 = 0, // 物理尺寸
    swapchain_height: u32 = 0,
    needs_resize: bool = false,
    /// 内容缩放因子 (HiDPI): 逻辑像素 × scale = 物理像素
    content_scale: f32 = 1.0,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator, hwnd: *anyopaque, width: u32, height: u32) !Self {
        var self: Self = .{ .allocator = allocator };
        errdefer self.deinit();

        // 1. DXGI Factory
        var factory: ?*d3d12.IDXGIFactory4 = null;
        const fhr = d3d12.CreateDXGIFactory2(0, &d3d12.IID_IDXGIFactory4, @ptrCast(&factory));
        if (fhr != d3d12.S_OK) return error.FactoryCreationFailed;
        self.factory = factory;

        // 2. Device
        var dev: ?*d3d12.ID3D12Device = null;
        const dhr = d3d12.D3D12CreateDevice(null, d3d12.D3D_FEATURE_LEVEL_11_0, &d3d12.IID_ID3D12Device, @ptrCast(&dev));
        if (dhr != d3d12.S_OK) return error.DeviceCreationFailed;
        self.device = dev;

        // 3. Command queue
        var q_desc: d3d12.D3D12_COMMAND_QUEUE_DESC = std.mem.zeroes(d3d12.D3D12_COMMAND_QUEUE_DESC);
        q_desc.Type = d3d12.D3D12_COMMAND_LIST_TYPE_DIRECT;
        var queue: ?*d3d12.ID3D12CommandQueue = null;
        const qhr = dev.?.*.lpVtbl.*.CreateCommandQueue.?(dev.?, &q_desc, &d3d12.IID_ID3D12CommandQueue, @ptrCast(&queue));
        if (qhr != d3d12.S_OK) return error.QueueCreationFailed;
        self.command_queue = queue;

        // 4. Swap chain (flip model, 2 buffers)
        try self.createSwapChain(hwnd, width, height);

        // 5. RTV heap + render targets
        try self.createRtvHeap();

        // 6. SRV heap
        try self.createSrvHeap();

        // 7. 命令分配器 + 命令列表
        try self.createCommandResources();

        // 8. 同步
        try self.createSyncObjects();

        // 9. 根签名 + PSO
        self.root_signature = createRootSignature(dev.?) orelse return error.RootSignatureFailed;
        self.solid_pso = createPipelineState(dev.?, self.root_signature.?, solid_vs_src, solid_ps_src, false, false) orelse return error.PsoCreationFailed;
        self.textured_pso = createPipelineState(dev.?, self.root_signature.?, textured_vs_src, textured_ps_src, true, false) orelse return error.PsoCreationFailed;
        self.image_pso = createPipelineState(dev.?, self.root_signature.?, textured_vs_src, image_ps_src, true, false) orelse return error.PsoCreationFailed;

        // 10. 顶点缓冲
        const vb = createUploadBuffer(dev.?, @as(u64, max_vertices) * @sizeOf(Vertex2D) * frames_in_flight) orelse return error.VertexBufferFailed;
        self.vertex_buffer = vb.resource;
        self.vertex_mapped = vb.mapped;
        self.vertex_gpu_addr = vb.resource.?.*.lpVtbl.*.GetGPUVirtualAddress.?(vb.resource.?);

        const tvb = createUploadBuffer(dev.?, @as(u64, max_vertices) * @sizeOf(TextVertex) * frames_in_flight) orelse return error.VertexBufferFailed;
        self.text_vertex_buffer = tvb.resource;
        self.text_vertex_mapped = tvb.mapped;
        self.text_vertex_gpu_addr = tvb.resource.?.*.lpVtbl.*.GetGPUVirtualAddress.?(tvb.resource.?);

        self.fb_width = width;
        self.fb_height = height;
        return self;
    }

    pub fn deinit(self: *Self) void {
        self.waitForQueueIdle();

        if (self.vertex_buffer) |b| {
            _ = b.*.lpVtbl.*.Release.?(b);
        }
        if (self.text_vertex_buffer) |b| {
            _ = b.*.lpVtbl.*.Release.?(b);
        }

        if (self.solid_pso) |p| {
            _ = p.*.lpVtbl.*.Release.?(p);
        }
        if (self.textured_pso) |p| {
            _ = p.*.lpVtbl.*.Release.?(p);
        }
        if (self.image_pso) |p| {
            _ = p.*.lpVtbl.*.Release.?(p);
        }
        if (self.root_signature) |r| {
            _ = r.*.lpVtbl.*.Release.?(r);
        }

        if (self.upload_cmd_list) |c| {
            _ = c.*.lpVtbl.*.Release.?(c);
        }
        if (self.upload_cmd_allocator) |a| {
            _ = a.*.lpVtbl.*.Release.?(a);
        }
        if (self.cmd_list) |c| {
            _ = c.*.lpVtbl.*.Release.?(c);
        }
        for (0..frames_in_flight) |i| {
            if (self.cmd_allocators[i]) |a| {
                _ = a.*.lpVtbl.*.Release.?(a);
            }
        }

        for (0..frames_in_flight) |i| {
            if (self.fences[i]) |f| {
                _ = f.*.lpVtbl.*.Release.?(f);
            }
        }
        if (self.upload_fence) |f| {
            _ = f.*.lpVtbl.*.Release.?(f);
        }
        if (self.fence_event) |e| _ = d3d12.CloseHandle(e);

        self.free_srv_slots.deinit(self.allocator);
        if (self.srv_heap) |h| {
            _ = h.*.lpVtbl.*.Release.?(h);
        }
        if (self.rtv_heap) |h| {
            _ = h.*.lpVtbl.*.Release.?(h);
        }
        for (0..2) |i| {
            if (self.render_targets[i]) |r| {
                _ = r.*.lpVtbl.*.Release.?(r);
            }
        }
        if (self.swap_chain) |s| {
            _ = s.*.lpVtbl.*.Release.?(s);
        }
        if (self.command_queue) |q| {
            _ = q.*.lpVtbl.*.Release.?(q);
        }
        if (self.device) |d| {
            _ = d.*.lpVtbl.*.Release.?(d);
        }
        if (self.factory) |f| {
            _ = f.*.lpVtbl.*.Release.?(f);
        }
    }

    fn createSwapChain(self: *Self, hwnd: *anyopaque, width: u32, height: u32) !void {
        const phys_w: u32 = @intFromFloat(@as(f32, @floatFromInt(width)) * self.content_scale);
        const phys_h: u32 = @intFromFloat(@as(f32, @floatFromInt(height)) * self.content_scale);
        var sc_desc: d3d12.DXGI_SWAP_CHAIN_DESC1 = std.mem.zeroes(d3d12.DXGI_SWAP_CHAIN_DESC1);
        sc_desc.Width = phys_w;
        sc_desc.Height = phys_h;
        sc_desc.Format = d3d12.DXGI_FORMAT_R8G8B8A8_UNORM;
        sc_desc.SampleDesc.Count = 1;
        sc_desc.BufferUsage = d3d12.DXGI_USAGE_RENDER_TARGET_OUTPUT;
        sc_desc.BufferCount = 2;
        sc_desc.Scaling = d3d12.DXGI_SCALING_STRETCH;
        sc_desc.SwapEffect = d3d12.DXGI_SWAP_EFFECT_FLIP_DISCARD;
        sc_desc.AlphaMode = d3d12.DXGI_ALPHA_MODE_IGNORE;

        var sc1: ?*d3d12.IDXGISwapChain1 = null;
        const hwnd_t: d3d12.HWND = @ptrCast(hwnd);
        const shr = self.factory.?.*.lpVtbl.*.CreateSwapChainForHwnd.?(self.factory.?, @ptrCast(self.command_queue), hwnd_t, &sc_desc, null, null, &sc1);
        if (shr != d3d12.S_OK) return error.SwapChainCreationFailed;

        var sc3: ?*d3d12.IDXGISwapChain3 = null;
        const qhr = sc1.?.*.lpVtbl.*.QueryInterface.?(sc1.?, &d3d12.IID_IDXGISwapChain3, @ptrCast(&sc3));
        _ = sc1.?.*.lpVtbl.*.Release.?(sc1.?);
        if (qhr != d3d12.S_OK) return error.SwapChainQueryFailed;
        self.swap_chain = sc3;
        self.swapchain_width = phys_w;
        self.swapchain_height = phys_h;
    }

    fn createRtvHeap(self: *Self) !void {
        var desc: d3d12.D3D12_DESCRIPTOR_HEAP_DESC = std.mem.zeroes(d3d12.D3D12_DESCRIPTOR_HEAP_DESC);
        desc.Type = d3d12.D3D12_DESCRIPTOR_HEAP_TYPE_RTV;
        desc.NumDescriptors = 2;
        desc.Flags = d3d12.D3D12_DESCRIPTOR_HEAP_FLAG_NONE;
        var heap: ?*d3d12.ID3D12DescriptorHeap = null;
        const hr = self.device.?.*.lpVtbl.*.CreateDescriptorHeap.?(self.device.?, &desc, &d3d12.IID_ID3D12DescriptorHeap, @ptrCast(&heap));
        if (hr != d3d12.S_OK) return error.RtvHeapCreationFailed;
        self.rtv_heap = heap;
        self.rtv_descriptor_size = self.device.?.*.lpVtbl.*.GetDescriptorHandleIncrementSize.?(self.device.?, d3d12.D3D12_DESCRIPTOR_HEAP_TYPE_RTV);
        _ = heap.?.*.lpVtbl.*.GetCPUDescriptorHandleForHeapStart.?(heap.?, &self.rtv_cpu_start);
        try self.updateRenderTargets();
    }

    fn updateRenderTargets(self: *Self) !void {
        for (0..2) |i| {
            if (self.render_targets[i]) |r| {
                _ = r.*.lpVtbl.*.Release.?(r);
                self.render_targets[i] = null;
            }
            var buf: ?*d3d12.ID3D12Resource = null;
            const hr = self.swap_chain.?.*.lpVtbl.*.GetBuffer.?(self.swap_chain.?, @intCast(i), &d3d12.IID_ID3D12Resource, @ptrCast(&buf));
            if (hr != d3d12.S_OK) return error.GetBufferFailed;
            self.render_targets[i] = buf;
            const cpu = d3d12.D3D12_CPU_DESCRIPTOR_HANDLE{ .ptr = self.rtv_cpu_start.ptr + i * self.rtv_descriptor_size };
            self.device.?.*.lpVtbl.*.CreateRenderTargetView.?(self.device.?, buf, null, cpu);
        }
    }

    fn createSrvHeap(self: *Self) !void {
        var desc: d3d12.D3D12_DESCRIPTOR_HEAP_DESC = std.mem.zeroes(d3d12.D3D12_DESCRIPTOR_HEAP_DESC);
        desc.Type = d3d12.D3D12_DESCRIPTOR_HEAP_TYPE_CBV_SRV_UAV;
        desc.NumDescriptors = max_textures;
        desc.Flags = d3d12.D3D12_DESCRIPTOR_HEAP_FLAG_SHADER_VISIBLE;
        var heap: ?*d3d12.ID3D12DescriptorHeap = null;
        const hr = self.device.?.*.lpVtbl.*.CreateDescriptorHeap.?(self.device.?, &desc, &d3d12.IID_ID3D12DescriptorHeap, @ptrCast(&heap));
        if (hr != d3d12.S_OK) return error.SrvHeapCreationFailed;
        self.srv_heap = heap;
        self.srv_descriptor_size = self.device.?.*.lpVtbl.*.GetDescriptorHandleIncrementSize.?(self.device.?, d3d12.D3D12_DESCRIPTOR_HEAP_TYPE_CBV_SRV_UAV);
        _ = heap.?.*.lpVtbl.*.GetCPUDescriptorHandleForHeapStart.?(heap.?, &self.srv_cpu_start);
        _ = heap.?.*.lpVtbl.*.GetGPUDescriptorHandleForHeapStart.?(heap.?, &self.srv_gpu_start);
    }

    fn createCommandResources(self: *Self) !void {
        for (0..frames_in_flight) |i| {
            var alloc: ?*d3d12.ID3D12CommandAllocator = null;
            const hr = self.device.?.*.lpVtbl.*.CreateCommandAllocator.?(self.device.?, d3d12.D3D12_COMMAND_LIST_TYPE_DIRECT, &d3d12.IID_ID3D12CommandAllocator, @ptrCast(&alloc));
            if (hr != d3d12.S_OK) return error.CommandAllocatorFailed;
            self.cmd_allocators[i] = alloc;
        }
        var cmd_list: ?*d3d12.ID3D12GraphicsCommandList = null;
        const chr = self.device.?.*.lpVtbl.*.CreateCommandList.?(self.device.?, 0, d3d12.D3D12_COMMAND_LIST_TYPE_DIRECT, self.cmd_allocators[0].?, null, &d3d12.IID_ID3D12GraphicsCommandList, @ptrCast(&cmd_list));
        if (chr != d3d12.S_OK) return error.CommandListFailed;
        _ = cmd_list.?.*.lpVtbl.*.Close.?(cmd_list.?);
        self.cmd_list = cmd_list;

        var ualloc: ?*d3d12.ID3D12CommandAllocator = null;
        const uahr = self.device.?.*.lpVtbl.*.CreateCommandAllocator.?(self.device.?, d3d12.D3D12_COMMAND_LIST_TYPE_DIRECT, &d3d12.IID_ID3D12CommandAllocator, @ptrCast(&ualloc));
        if (uahr != d3d12.S_OK) return error.CommandAllocatorFailed;
        self.upload_cmd_allocator = ualloc;
        var ucmd: ?*d3d12.ID3D12GraphicsCommandList = null;
        const uchr = self.device.?.*.lpVtbl.*.CreateCommandList.?(self.device.?, 0, d3d12.D3D12_COMMAND_LIST_TYPE_DIRECT, ualloc.?, null, &d3d12.IID_ID3D12GraphicsCommandList, @ptrCast(&ucmd));
        if (uchr != d3d12.S_OK) return error.CommandListFailed;
        _ = ucmd.?.*.lpVtbl.*.Close.?(ucmd.?);
        self.upload_cmd_list = ucmd;
    }

    fn createSyncObjects(self: *Self) !void {
        for (0..frames_in_flight) |i| {
            var fence: ?*d3d12.ID3D12Fence = null;
            const hr = self.device.?.*.lpVtbl.*.CreateFence.?(self.device.?, 0, d3d12.D3D12_FENCE_FLAG_NONE, &d3d12.IID_ID3D12Fence, @ptrCast(&fence));
            if (hr != d3d12.S_OK) return error.FenceCreationFailed;
            self.fences[i] = fence;
        }
        var ufence: ?*d3d12.ID3D12Fence = null;
        const uhr = self.device.?.*.lpVtbl.*.CreateFence.?(self.device.?, 0, d3d12.D3D12_FENCE_FLAG_NONE, &d3d12.IID_ID3D12Fence, @ptrCast(&ufence));
        if (uhr != d3d12.S_OK) return error.FenceCreationFailed;
        self.upload_fence = ufence;
        self.fence_event = @ptrCast(d3d12.CreateEventW(null, 0, 0, null));
        if (self.fence_event == null) return error.EventCreationFailed;
    }

    /// 开始帧: 等待 fence, 重置命令, 设置 RTV/视口/裁剪, 返回逻辑 framebuffer 尺寸
    pub fn beginFrame(self: *Self) ?[2]u32 {
        if (self.needs_resize) {
            self.resizeSwapChain() catch return null;
            self.needs_resize = false;
        }

        const frame = self.current_frame;
        self.waitForFence(self.fences[frame].?, self.fence_values[frame]);

        const back_index = self.swap_chain.?.*.lpVtbl.*.GetCurrentBackBufferIndex.?(self.swap_chain.?);

        _ = self.cmd_allocators[frame].?.*.lpVtbl.*.Reset.?(self.cmd_allocators[frame].?);
        _ = self.cmd_list.?.*.lpVtbl.*.Reset.?(self.cmd_list.?, self.cmd_allocators[frame].?, null);

        const cmd = self.cmd_list.?;
        // 绑定 SRV 描述符堆
        var heaps = [_]?*d3d12.ID3D12DescriptorHeap{self.srv_heap};
        cmd.*.lpVtbl.*.SetDescriptorHeaps.?(cmd, 1, &heaps);

        // 屏障: PRESENT -> RENDER_TARGET
        self.transitionBarrier(cmd, self.render_targets[back_index].?, d3d12.D3D12_RESOURCE_STATE_PRESENT, d3d12.D3D12_RESOURCE_STATE_RENDER_TARGET);

        const rtv = d3d12.D3D12_CPU_DESCRIPTOR_HANDLE{ .ptr = self.rtv_cpu_start.ptr + back_index * self.rtv_descriptor_size };
        cmd.*.lpVtbl.*.OMSetRenderTargets.?(cmd, 1, &rtv, 0, null);

        const clear_color = [_]f32{ 0.0, 0.0, 0.0, 1.0 };
        cmd.*.lpVtbl.*.ClearRenderTargetView.?(cmd, rtv, &clear_color, 0, null);

        const viewport = d3d12.D3D12_VIEWPORT{
            .TopLeftX = 0,
            .TopLeftY = 0,
            .Width = @floatFromInt(self.swapchain_width),
            .Height = @floatFromInt(self.swapchain_height),
            .MinDepth = 0,
            .MaxDepth = 1,
        };
        cmd.*.lpVtbl.*.RSSetViewports.?(cmd, 1, &viewport);
        const scissor = d3d12.D3D12_RECT{ .left = 0, .top = 0, .right = @intCast(self.swapchain_width), .bottom = @intCast(self.swapchain_height) };
        cmd.*.lpVtbl.*.RSSetScissorRects.?(cmd, 1, &scissor);

        // 重置当前帧顶点游标
        self.vertex_cursors[frame] = 0;
        self.text_vertex_cursors[frame] = 0;

        return .{ self.fb_width, self.fb_height };
    }

    /// 结束帧: 关闭并提交命令, 信号 fence, present
    pub fn endFrame(self: *Self) void {
        const frame = self.current_frame;
        const cmd = self.cmd_list.?;
        const back_index = self.swap_chain.?.*.lpVtbl.*.GetCurrentBackBufferIndex.?(self.swap_chain.?);

        // 屏障: RENDER_TARGET -> PRESENT
        self.transitionBarrier(cmd, self.render_targets[back_index].?, d3d12.D3D12_RESOURCE_STATE_RENDER_TARGET, d3d12.D3D12_RESOURCE_STATE_PRESENT);

        _ = cmd.*.lpVtbl.*.Close.?(cmd);
        var lists = [_]?*d3d12.ID3D12CommandList{@ptrCast(cmd)};
        self.command_queue.?.*.lpVtbl.*.ExecuteCommandLists.?(self.command_queue.?, 1, &lists);

        self.fence_values[frame] += 1;
        _ = self.command_queue.?.*.lpVtbl.*.Signal.?(self.command_queue.?, self.fences[frame].?, self.fence_values[frame]);

        _ = self.swap_chain.?.*.lpVtbl.*.Present.?(self.swap_chain.?, 1, 0);

        self.current_frame = (self.current_frame + 1) % frames_in_flight;
    }

    /// 更新纯色顶点数据 (ring buffer 追加写入, 返回字节偏移)
    pub fn updateVertices(self: *Self, vertices: []const Vertex2D) u64 {
        if (vertices.len == 0) return 0;
        const size = vertices.len * @sizeOf(Vertex2D);
        const frame = self.current_frame;
        const frame_base = @as(usize, max_vertices) * @sizeOf(Vertex2D) * frame;
        const offset = self.vertex_cursors[frame];
        @memcpy(self.vertex_mapped[frame_base + offset .. frame_base + offset + size], std.mem.sliceAsBytes(vertices));
        self.vertex_cursors[frame] += size;
        return @intCast(frame_base + offset);
    }

    /// 绘制纯色三角形 (vertex_offset 为顶点缓冲字节偏移)
    pub fn drawTriangles(self: *Self, vertex_count: u32, vertex_offset: u64) void {
        if (vertex_count == 0) return;
        const cmd = self.cmd_list.?;
        cmd.*.lpVtbl.*.SetPipelineState.?(cmd, self.solid_pso.?);
        cmd.*.lpVtbl.*.SetGraphicsRootSignature.?(cmd, self.root_signature.?);
        const screen_size = [2]f32{ @floatFromInt(self.fb_width), @floatFromInt(self.fb_height) };
        cmd.*.lpVtbl.*.SetGraphicsRoot32BitConstants.?(cmd, 0, 2, &screen_size, 0);
        self.bindVertexBuffer(cmd, self.vertex_gpu_addr, vertex_offset, @sizeOf(Vertex2D));
        cmd.*.lpVtbl.*.DrawInstanced.?(cmd, vertex_count, 1, 0, 0);
    }

    /// 更新文本顶点数据 (ring buffer 追加写入, 返回字节偏移)
    pub fn updateTextVertices(self: *Self, vertices: []const TextVertex) u64 {
        if (vertices.len == 0) return 0;
        const size = vertices.len * @sizeOf(TextVertex);
        const frame = self.current_frame;
        const frame_base = @as(usize, max_vertices) * @sizeOf(TextVertex) * frame;
        const offset = self.text_vertex_cursors[frame];
        @memcpy(self.text_vertex_mapped[frame_base + offset .. frame_base + offset + size], std.mem.sliceAsBytes(vertices));
        self.text_vertex_cursors[frame] += size;
        return @intCast(frame_base + offset);
    }

    /// 使用文本纹理管线绘制 (R8 glyph atlas)
    pub fn drawTextured(self: *Self, vertex_count: u32, texture: TextureHandle, vertex_offset: u64) void {
        self.drawTexturedPipeline(vertex_count, texture, vertex_offset, self.textured_pso.?);
    }

    /// 绘制图片 (RGBA 纹理, 使用 image 管线)
    pub fn drawImage(self: *Self, vertices: []const TextVertex, texture: TextureHandle) void {
        const offset = self.updateTextVertices(vertices);
        self.drawTexturedPipeline(@intCast(vertices.len), texture, offset, self.image_pso.?);
    }

    /// 立即绘制纯色顶点 (走 ring buffer, 不另设共享缓冲覆盖)
    pub fn drawTrianglesImmediate(self: *Self, vertices: []const Vertex2D) void {
        if (vertices.len == 0) return;
        const offset = self.updateVertices(vertices);
        self.drawTriangles(@intCast(vertices.len), offset);
    }

    /// 立即绘制文本纹理顶点
    pub fn drawTexturedImmediate(self: *Self, vertices: []const TextVertex, texture: TextureHandle) void {
        if (vertices.len == 0) return;
        const offset = self.updateTextVertices(vertices);
        self.drawTextured(@intCast(vertices.len), texture, offset);
    }

    fn drawTexturedPipeline(self: *Self, vertex_count: u32, texture: TextureHandle, vertex_offset: u64, pso: *d3d12.ID3D12PipelineState) void {
        if (vertex_count == 0) return;
        const cmd = self.cmd_list.?;
        cmd.*.lpVtbl.*.SetPipelineState.?(cmd, pso);
        cmd.*.lpVtbl.*.SetGraphicsRootSignature.?(cmd, self.root_signature.?);
        const screen_size = [2]f32{ @floatFromInt(self.fb_width), @floatFromInt(self.fb_height) };
        cmd.*.lpVtbl.*.SetGraphicsRoot32BitConstants.?(cmd, 0, 2, &screen_size, 0);
        const gpu_handle = d3d12.D3D12_GPU_DESCRIPTOR_HANDLE{ .ptr = @intFromPtr(texture.srv_gpu) };
        cmd.*.lpVtbl.*.SetGraphicsRootDescriptorTable.?(cmd, 1, gpu_handle);
        self.bindVertexBuffer(cmd, self.text_vertex_gpu_addr, vertex_offset, @sizeOf(TextVertex));
        cmd.*.lpVtbl.*.DrawInstanced.?(cmd, vertex_count, 1, 0, 0);
    }

    fn bindVertexBuffer(self: *Self, cmd: *d3d12.ID3D12GraphicsCommandList, base_addr: u64, offset: u64, stride: u32) void {
        _ = self;
        const total = @as(u64, stride) * max_vertices * frames_in_flight;
        var vb_view: d3d12.D3D12_VERTEX_BUFFER_VIEW = std.mem.zeroes(d3d12.D3D12_VERTEX_BUFFER_VIEW);
        vb_view.BufferLocation = base_addr + offset;
        vb_view.StrideInBytes = stride;
        vb_view.SizeInBytes = @intCast(total - offset);
        cmd.*.lpVtbl.*.IASetVertexBuffers.?(cmd, 0, 1, &vb_view);
    }

    /// 设置裁剪矩形 (夹紧到 swapchain 范围; null 恢复全屏)。
    /// 输入为逻辑坐标, 内部乘以 content_scale 转为物理像素。
    pub fn setScissor(self: *Self, rect: ?math.Rect(f32)) void {
        const cmd = self.cmd_list.?;
        const scissor = if (rect) |r| blk: {
            const fw: i32 = @intCast(self.swapchain_width);
            const fh: i32 = @intCast(self.swapchain_height);
            const s = self.content_scale;
            var x0: i32 = @intFromFloat(@floor(r.x * s));
            var y0: i32 = @intFromFloat(@floor(r.y * s));
            var x1: i32 = @intFromFloat(@ceil((r.x + r.width) * s));
            var y1: i32 = @intFromFloat(@ceil((r.y + r.height) * s));
            if (x0 < 0) x0 = 0;
            if (y0 < 0) y0 = 0;
            if (x1 > fw) x1 = fw;
            if (y1 > fh) y1 = fh;
            if (x1 < x0) x1 = x0;
            if (y1 < y0) y1 = y0;
            break :blk d3d12.D3D12_RECT{ .left = x0, .top = y0, .right = x1, .bottom = y1 };
        } else d3d12.D3D12_RECT{ .left = 0, .top = 0, .right = @intCast(self.swapchain_width), .bottom = @intCast(self.swapchain_height) };
        cmd.*.lpVtbl.*.RSSetScissorRects.?(cmd, 1, &scissor);
    }

    /// 窗口尺寸变化 (逻辑尺寸)
    pub fn setDrawableSize(self: *Self, width: u32, height: u32) void {
        if (width == 0 or height == 0) return;
        if (width == self.fb_width and height == self.fb_height) return;
        self.fb_width = width;
        self.fb_height = height;
        self.needs_resize = true;
    }

    /// 设置内容缩放因子 (HiDPI)
    pub fn setContentScale(self: *Self, scale: f32) void {
        if (scale <= 0.0) return;
        if (scale == self.content_scale) return;
        self.content_scale = scale;
        self.needs_resize = true;
    }

    fn resizeSwapChain(self: *Self) !void {
        self.waitForQueueIdle();
        for (0..2) |i| {
            if (self.render_targets[i]) |r| {
                _ = r.*.lpVtbl.*.Release.?(r);
                self.render_targets[i] = null;
            }
        }
        const phys_w: u32 = @intFromFloat(@as(f32, @floatFromInt(self.fb_width)) * self.content_scale);
        const phys_h: u32 = @intFromFloat(@as(f32, @floatFromInt(self.fb_height)) * self.content_scale);
        const hr = self.swap_chain.?.*.lpVtbl.*.ResizeBuffers.?(self.swap_chain.?, 2, phys_w, phys_h, d3d12.DXGI_FORMAT_R8G8B8A8_UNORM, 0);
        if (hr != d3d12.S_OK) return error.ResizeFailed;
        self.swapchain_width = phys_w;
        self.swapchain_height = phys_h;
        try self.updateRenderTargets();
    }

    // ── Texture (glyph atlas / image) ──────────────────────────────────────

    /// 创建 R8Unorm 纹理 (glyph atlas)
    pub fn createTexture(self: *Self, width: u32, height: u32) ?TextureHandle {
        return self.createTextureImpl(width, height, d3d12.DXGI_FORMAT_R8_UNORM, false);
    }

    /// 创建 RGBA8Unorm 纹理 (图片)
    pub fn createTextureRGBA(self: *Self, width: u32, height: u32) ?TextureHandle {
        return self.createTextureImpl(width, height, d3d12.DXGI_FORMAT_R8G8B8A8_UNORM, true);
    }

    fn createTextureImpl(self: *Self, width: u32, height: u32, format: d3d12.DXGI_FORMAT, is_rgba: bool) ?TextureHandle {
        const slot = self.allocSrvSlot() orelse return null;
        errdefer self.freeSrvSlot(slot);

        // DEFAULT heap 资源 (初始 COPY_DEST, 准备接收上传)
        var heap_props: d3d12.D3D12_HEAP_PROPERTIES = std.mem.zeroes(d3d12.D3D12_HEAP_PROPERTIES);
        heap_props.Type = d3d12.D3D12_HEAP_TYPE_DEFAULT;
        var tex_desc: d3d12.D3D12_RESOURCE_DESC = std.mem.zeroes(d3d12.D3D12_RESOURCE_DESC);
        tex_desc.Dimension = d3d12.D3D12_RESOURCE_DIMENSION_TEXTURE2D;
        tex_desc.Width = width;
        tex_desc.Height = height;
        tex_desc.DepthOrArraySize = 1;
        tex_desc.MipLevels = 1;
        tex_desc.Format = format;
        tex_desc.SampleDesc.Count = 1;
        tex_desc.Layout = d3d12.D3D12_TEXTURE_LAYOUT_UNKNOWN;

        var resource: ?*d3d12.ID3D12Resource = null;
        const rhr = self.device.?.*.lpVtbl.*.CreateCommittedResource.?(self.device.?, &heap_props, 0, &tex_desc, d3d12.D3D12_RESOURCE_STATE_COPY_DEST, null, &d3d12.IID_ID3D12Resource, @ptrCast(&resource));
        if (rhr != d3d12.S_OK) return null;

        // SRV (R8 swizzle 为 1,1,1,R; RGBA 用默认映射)
        var srv_desc: d3d12.D3D12_SHADER_RESOURCE_VIEW_DESC = std.mem.zeroes(d3d12.D3D12_SHADER_RESOURCE_VIEW_DESC);
        srv_desc.Format = format;
        srv_desc.ViewDimension = d3d12.D3D12_SRV_DIMENSION_TEXTURE2D;
        srv_desc.Shader4ComponentMapping = if (is_rgba) d3d12.D3D12_DEFAULT_SHADER_4_COMPONENT_MAPPING else encodeComponentMapping(5, 5, 5, 0);
        srv_desc.unnamed_0.Texture2D.MostDetailedMip = 0;
        srv_desc.unnamed_0.Texture2D.MipLevels = 1;
        srv_desc.unnamed_0.Texture2D.PlaneSlice = 0;
        srv_desc.unnamed_0.Texture2D.ResourceMinLODClamp = 0;
        const cpu = self.cpuHandleAt(slot);
        self.device.?.*.lpVtbl.*.CreateShaderResourceView.?(self.device.?, resource, &srv_desc, cpu);

        // 持久 upload 缓冲 (按整纹理对齐行距分配, 覆盖任意子区域上传)
        const bpp: u32 = if (is_rgba) 4 else 1;
        const row_pitch = alignUp(@as(u64, width) * bpp, d3d12.D3D12_TEXTURE_DATA_PITCH_ALIGNMENT);
        const upload_size = row_pitch * height;
        const upload = createUploadBuffer(self.device.?, upload_size) orelse {
            _ = resource.?.*.lpVtbl.*.Release.?(resource.?);
            return null;
        };

        return .{
            .resource = @ptrCast(resource.?),
            .srv_cpu = @ptrFromInt(cpu.ptr),
            .srv_gpu = @ptrFromInt(self.gpuHandleAt(slot).ptr),
            .upload = @ptrCast(upload.resource),
            .width = width,
            .height = height,
            .is_rgba = is_rgba,
        };
    }

    pub fn destroyTexture(self: *Self, texture: TextureHandle) void {
        const resource: *d3d12.ID3D12Resource = @ptrCast(@alignCast(texture.resource));
        if (texture.upload) |u| {
            const up: *d3d12.ID3D12Resource = @ptrCast(@alignCast(u));
            _ = up.*.lpVtbl.*.Release.?(up);
        }
        _ = resource.*.lpVtbl.*.Release.?(resource);
        // 由 srv_cpu 反推 slot 索引释放
        const slot: u32 = @intCast((@intFromPtr(texture.srv_cpu) - self.srv_cpu_start.ptr) / self.srv_descriptor_size);
        self.freeSrvSlot(slot);
    }

    /// 初始转换为 COPY_DEST (D3D12 资源创建时已是 COPY_DEST, 此处为接口对齐)
    pub fn initTextureForTransfer(self: *Self, texture: TextureHandle) void {
        _ = self;
        _ = texture;
    }

    /// 从 PIXEL_SHADER_RESOURCE 转回 COPY_DEST (用于上传)
    pub fn prepareTextureForTransfer(self: *Self, texture: TextureHandle) void {
        const resource: *d3d12.ID3D12Resource = @ptrCast(@alignCast(texture.resource));
        self.beginUpload();
        self.transitionBarrier(self.upload_cmd_list.?, resource, d3d12.D3D12_RESOURCE_STATE_PIXEL_SHADER_RESOURCE, d3d12.D3D12_RESOURCE_STATE_COPY_DEST);
        self.endUpload();
    }

    /// 从 COPY_DEST 转为 PIXEL_SHADER_RESOURCE (用于采样)
    pub fn prepareTextureForSampling(self: *Self, texture: TextureHandle) void {
        const resource: *d3d12.ID3D12Resource = @ptrCast(@alignCast(texture.resource));
        self.beginUpload();
        self.transitionBarrier(self.upload_cmd_list.?, resource, d3d12.D3D12_RESOURCE_STATE_COPY_DEST, d3d12.D3D12_RESOURCE_STATE_PIXEL_SHADER_RESOURCE);
        self.endUpload();
    }

    /// 更新 R8 纹理子区域
    pub fn updateTextureRegion(self: *Self, texture: TextureHandle, x: u32, y: u32, w: u32, h: u32, data: []const u8, data_stride: u32) void {
        self.updateTextureRegionImpl(texture, x, y, w, h, data, data_stride, 1);
    }

    /// 更新 RGBA 纹理子区域
    pub fn updateTextureRegionRGBA(self: *Self, texture: TextureHandle, x: u32, y: u32, w: u32, h: u32, data: []const u8, data_stride: u32) void {
        self.updateTextureRegionImpl(texture, x, y, w, h, data, data_stride, 4);
    }

    fn updateTextureRegionImpl(self: *Self, texture: TextureHandle, x: u32, y: u32, w: u32, h: u32, data: []const u8, data_stride: u32, bpp: u32) void {
        if (w == 0 or h == 0) return;
        const row_pitch = alignUp(@as(u64, w) * bpp, d3d12.D3D12_TEXTURE_DATA_PITCH_ALIGNMENT);
        const upload: *d3d12.ID3D12Resource = @ptrCast(@alignCast(texture.upload orelse return));

        var mapped: ?*anyopaque = null;
        const read_range = d3d12.D3D12_RANGE{ .Begin = 0, .End = 0 };
        const mhr = upload.*.lpVtbl.*.Map.?(upload, 0, &read_range, &mapped);
        if (mhr != d3d12.S_OK) return;
        const dst: [*]u8 = @ptrCast(mapped);
        var row: u32 = 0;
        while (row < h) : (row += 1) {
            const src_off: usize = @as(usize, row) * data_stride;
            const dst_off: usize = @as(usize, row) * row_pitch;
            const copy_bytes: usize = @as(usize, w) * bpp;
            @memcpy(dst[dst_off .. dst_off + copy_bytes], data[src_off .. src_off + copy_bytes]);
        }
        upload.*.lpVtbl.*.Unmap.?(upload, 0, null);

        // 源: upload 缓冲 (placed footprint), 目的: 纹理 (subresource index)
        var footprint: d3d12.D3D12_PLACED_SUBRESOURCE_FOOTPRINT = std.mem.zeroes(d3d12.D3D12_PLACED_SUBRESOURCE_FOOTPRINT);
        footprint.Offset = 0;
        footprint.Footprint.Format = if (texture.is_rgba) d3d12.DXGI_FORMAT_R8G8B8A8_UNORM else d3d12.DXGI_FORMAT_R8_UNORM;
        footprint.Footprint.Width = w;
        footprint.Footprint.Height = h;
        footprint.Footprint.Depth = 1;
        footprint.Footprint.RowPitch = @intCast(row_pitch);

        var src_loc: d3d12.D3D12_TEXTURE_COPY_LOCATION = std.mem.zeroes(d3d12.D3D12_TEXTURE_COPY_LOCATION);
        src_loc.pResource = upload;
        src_loc.Type = d3d12.D3D12_TEXTURE_COPY_TYPE_PLACED_FOOTPRINT;
        src_loc.unnamed_0.PlacedFootprint = footprint;

        var dst_loc: d3d12.D3D12_TEXTURE_COPY_LOCATION = std.mem.zeroes(d3d12.D3D12_TEXTURE_COPY_LOCATION);
        dst_loc.pResource = @ptrCast(@alignCast(texture.resource));
        dst_loc.Type = d3d12.D3D12_TEXTURE_COPY_TYPE_SUBRESOURCE_INDEX;
        dst_loc.unnamed_0.SubresourceIndex = 0;

        self.beginUpload();
        self.upload_cmd_list.?.*.lpVtbl.*.CopyTextureRegion.?(self.upload_cmd_list.?, &dst_loc, @intCast(x), @intCast(y), 0, &src_loc, null);
        self.endUpload();
    }

    // ── 内部辅助 ───────────────────────────────────────────────────────────

    fn transitionBarrier(self: *Self, cmd: *d3d12.ID3D12GraphicsCommandList, resource: *d3d12.ID3D12Resource, before: d3d12.D3D12_RESOURCE_STATES, after: d3d12.D3D12_RESOURCE_STATES) void {
        _ = self;
        var barrier: d3d12.D3D12_RESOURCE_BARRIER = std.mem.zeroes(d3d12.D3D12_RESOURCE_BARRIER);
        barrier.Type = d3d12.D3D12_RESOURCE_BARRIER_TYPE_TRANSITION;
        barrier.Flags = d3d12.D3D12_RESOURCE_BARRIER_FLAG_NONE;
        barrier.unnamed_0.Transition.pResource = resource;
        barrier.unnamed_0.Transition.Subresource = d3d12.D3D12_RESOURCE_BARRIER_ALL_SUBRESOURCES;
        barrier.unnamed_0.Transition.StateBefore = before;
        barrier.unnamed_0.Transition.StateAfter = after;
        cmd.*.lpVtbl.*.ResourceBarrier.?(cmd, 1, &barrier);
    }

    fn beginUpload(self: *Self) void {
        _ = self.upload_cmd_allocator.?.*.lpVtbl.*.Reset.?(self.upload_cmd_allocator.?);
        _ = self.upload_cmd_list.?.*.lpVtbl.*.Reset.?(self.upload_cmd_list.?, self.upload_cmd_allocator.?, null);
    }

    fn endUpload(self: *Self) void {
        _ = self.upload_cmd_list.?.*.lpVtbl.*.Close.?(self.upload_cmd_list.?);
        var lists = [_]?*d3d12.ID3D12CommandList{@ptrCast(self.upload_cmd_list.?)};
        self.command_queue.?.*.lpVtbl.*.ExecuteCommandLists.?(self.command_queue.?, 1, &lists);
        self.upload_fence_value += 1;
        _ = self.command_queue.?.*.lpVtbl.*.Signal.?(self.command_queue.?, self.upload_fence.?, self.upload_fence_value);
        self.waitForFence(self.upload_fence.?, self.upload_fence_value);
    }

    fn waitForFence(self: *Self, fence: *d3d12.ID3D12Fence, value: u64) void {
        if (fence.*.lpVtbl.*.GetCompletedValue.?(fence) >= value) return;
        _ = fence.*.lpVtbl.*.SetEventOnCompletion.?(fence, value, self.fence_event);
        _ = d3d12.WaitForSingleObject(self.fence_event, d3d12.INFINITE);
    }

    fn waitForQueueIdle(self: *Self) void {
        self.upload_fence_value += 1;
        _ = self.command_queue.?.*.lpVtbl.*.Signal.?(self.command_queue.?, self.upload_fence.?, self.upload_fence_value);
        self.waitForFence(self.upload_fence.?, self.upload_fence_value);
    }

    fn allocSrvSlot(self: *Self) ?u32 {
        if (self.free_srv_slots.pop()) |s| return s;
        if (self.next_srv_slot >= max_textures) return null;
        const s = self.next_srv_slot;
        self.next_srv_slot += 1;
        return s;
    }

    fn freeSrvSlot(self: *Self, slot: u32) void {
        self.free_srv_slots.append(self.allocator, slot) catch {};
    }

    fn cpuHandleAt(self: *Self, slot: u32) d3d12.D3D12_CPU_DESCRIPTOR_HANDLE {
        return .{ .ptr = self.srv_cpu_start.ptr + slot * self.srv_descriptor_size };
    }

    fn gpuHandleAt(self: *Self, slot: u32) d3d12.D3D12_GPU_DESCRIPTOR_HANDLE {
        return .{ .ptr = self.srv_gpu_start.ptr + slot * self.srv_descriptor_size };
    }
} else struct {
    pub fn init(allocator: std.mem.Allocator, hwnd: *anyopaque, width: u32, height: u32) !D3D12Device {
        _ = allocator;
        _ = hwnd;
        _ = width;
        _ = height;
        return error.NotImplemented;
    }
    pub fn deinit(self: *D3D12Device) void {
        _ = self;
    }
    pub fn beginFrame(self: *D3D12Device) ?[2]u32 {
        _ = self;
        return null;
    }
    pub fn endFrame(self: *D3D12Device) void {
        _ = self;
    }
    pub fn updateVertices(self: *D3D12Device, vertices: []const Vertex2D) u64 {
        _ = self;
        _ = vertices;
        return 0;
    }
    pub fn drawTriangles(self: *D3D12Device, vertex_count: u32, vertex_offset: u64) void {
        _ = self;
        _ = vertex_count;
        _ = vertex_offset;
    }
    pub fn updateTextVertices(self: *D3D12Device, vertices: []const TextVertex) u64 {
        _ = self;
        _ = vertices;
        return 0;
    }
    pub fn drawTextured(self: *D3D12Device, vertex_count: u32, texture: TextureHandle, vertex_offset: u64) void {
        _ = self;
        _ = vertex_count;
        _ = texture;
        _ = vertex_offset;
    }
    pub fn drawImage(self: *D3D12Device, vertices: []const TextVertex, texture: TextureHandle) void {
        _ = self;
        _ = vertices;
        _ = texture;
    }
    pub fn drawTrianglesImmediate(self: *D3D12Device, vertices: []const Vertex2D) void {
        _ = self;
        _ = vertices;
    }
    pub fn drawTexturedImmediate(self: *D3D12Device, vertices: []const TextVertex, texture: TextureHandle) void {
        _ = self;
        _ = vertices;
        _ = texture;
    }
    pub fn setScissor(self: *D3D12Device, rect: ?math.Rect(f32)) void {
        _ = self;
        _ = rect;
    }
    pub fn setDrawableSize(self: *D3D12Device, width: u32, height: u32) void {
        _ = self;
        _ = width;
        _ = height;
    }
    pub fn setContentScale(self: *D3D12Device, scale: f32) void {
        _ = self;
        _ = scale;
    }
    pub fn createTexture(self: *D3D12Device, width: u32, height: u32) ?TextureHandle {
        _ = self;
        _ = width;
        _ = height;
        return null;
    }
    pub fn createTextureRGBA(self: *D3D12Device, width: u32, height: u32) ?TextureHandle {
        _ = self;
        _ = width;
        _ = height;
        return null;
    }
    pub fn destroyTexture(self: *D3D12Device, texture: TextureHandle) void {
        _ = self;
        _ = texture;
    }
    pub fn updateTextureRegion(self: *D3D12Device, texture: TextureHandle, x: u32, y: u32, w: u32, h: u32, data: []const u8, data_stride: u32) void {
        _ = self;
        _ = texture;
        _ = x;
        _ = y;
        _ = w;
        _ = h;
        _ = data;
        _ = data_stride;
    }
    pub fn updateTextureRegionRGBA(self: *D3D12Device, texture: TextureHandle, x: u32, y: u32, w: u32, h: u32, data: []const u8, data_stride: u32) void {
        _ = self;
        _ = texture;
        _ = x;
        _ = y;
        _ = w;
        _ = h;
        _ = data;
        _ = data_stride;
    }
    pub fn prepareTextureForSampling(self: *D3D12Device, texture: TextureHandle) void {
        _ = self;
        _ = texture;
    }
    pub fn initTextureForTransfer(self: *D3D12Device, texture: TextureHandle) void {
        _ = self;
        _ = texture;
    }
    pub fn prepareTextureForTransfer(self: *D3D12Device, texture: TextureHandle) void {
        _ = self;
        _ = texture;
    }
};

// ── D3D12 辅助函数 (仅 Windows) ─────────────────────────────────────────────

fn alignUp(value: u64, alignment: u64) u64 {
    return (value + alignment - 1) & ~(alignment - 1);
}

/// D3D12_SHADER_COMPONENT_MAPPING 编码 (含 ALWAYS_SET_BIT)
fn encodeComponentMapping(s0: u32, s1: u32, s2: u32, s3: u32) u32 {
    const always_set_bit: u32 = 1 << 12;
    return (s0 & 0x7) | ((s1 & 0x7) << 3) | ((s2 & 0x7) << 6) | ((s3 & 0x7) << 9) | always_set_bit;
}

fn compileShader(src: []const u8, target: [*:0]const u8) ?*d3d12.ID3DBlob {
    var code: ?*d3d12.ID3DBlob = null;
    var err: ?*d3d12.ID3DBlob = null;
    const hr = d3d12.D3DCompile(@ptrCast(src.ptr), src.len, null, null, null, "main", target, 0, 0, &code, &err);
    if (err) |e| _ = e.*.lpVtbl.*.Release.?(e);
    if (hr != d3d12.S_OK) {
        if (code) |c| _ = c.*.lpVtbl.*.Release.?(c);
        return null;
    }
    return code;
}

fn createRootSignature(dev: *d3d12.ID3D12Device) ?*d3d12.ID3D12RootSignature {
    var params: [2]d3d12.D3D12_ROOT_PARAMETER = std.mem.zeroes([2]d3d12.D3D12_ROOT_PARAMETER);
    // 参数 0: root constants (2 个 float = screen_size, b0, 顶点阶段)
    params[0].ParameterType = d3d12.D3D12_ROOT_PARAMETER_TYPE_32BIT_CONSTANTS;
    params[0].ShaderVisibility = d3d12.D3D12_SHADER_VISIBILITY_VERTEX;
    params[0].unnamed_0.Constants.Num32BitValues = 2;
    params[0].unnamed_0.Constants.RegisterSpace = 0;
    params[0].unnamed_0.Constants.ShaderRegister = 0;
    // 参数 1: descriptor table (SRV t0, 像素阶段)
    params[1].ParameterType = d3d12.D3D12_ROOT_PARAMETER_TYPE_DESCRIPTOR_TABLE;
    params[1].ShaderVisibility = d3d12.D3D12_SHADER_VISIBILITY_PIXEL;
    var range: d3d12.D3D12_DESCRIPTOR_RANGE = std.mem.zeroes(d3d12.D3D12_DESCRIPTOR_RANGE);
    range.RangeType = d3d12.D3D12_DESCRIPTOR_RANGE_TYPE_SRV;
    range.NumDescriptors = 1;
    range.BaseShaderRegister = 0;
    range.RegisterSpace = 0;
    range.OffsetInDescriptorsFromTableStart = 0;
    params[1].unnamed_0.DescriptorTable.NumDescriptorRanges = 1;
    params[1].unnamed_0.DescriptorTable.pDescriptorRanges = &range;

    // 静态采样器 (s0, 线性过滤, clamp to edge)
    var sampler: d3d12.D3D12_STATIC_SAMPLER_DESC = std.mem.zeroes(d3d12.D3D12_STATIC_SAMPLER_DESC);
    sampler.Filter = d3d12.D3D12_FILTER_MIN_MAG_MIP_LINEAR;
    sampler.AddressU = d3d12.D3D12_TEXTURE_ADDRESS_MODE_CLAMP;
    sampler.AddressV = d3d12.D3D12_TEXTURE_ADDRESS_MODE_CLAMP;
    sampler.AddressW = d3d12.D3D12_TEXTURE_ADDRESS_MODE_CLAMP;
    sampler.MipLODBias = 0;
    sampler.MaxAnisotropy = 0;
    sampler.ComparisonFunc = d3d12.D3D12_COMPARISON_FUNC_NEVER;
    sampler.BorderColor = d3d12.D3D12_STATIC_BORDER_COLOR_OPAQUE_BLACK;
    sampler.MinLOD = 0;
    sampler.MaxLOD = 3.402823466e38;
    sampler.ShaderRegister = 0;
    sampler.RegisterSpace = 0;
    sampler.ShaderVisibility = d3d12.D3D12_SHADER_VISIBILITY_PIXEL;

    var desc: d3d12.D3D12_ROOT_SIGNATURE_DESC = std.mem.zeroes(d3d12.D3D12_ROOT_SIGNATURE_DESC);
    desc.NumParameters = 2;
    desc.pParameters = &params;
    desc.NumStaticSamplers = 1;
    desc.pStaticSamplers = &sampler;
    desc.Flags = d3d12.D3D12_ROOT_SIGNATURE_FLAG_NONE;

    var blob: ?*d3d12.ID3DBlob = null;
    var err: ?*d3d12.ID3DBlob = null;
    const shr = d3d12.D3D12SerializeRootSignature(&desc, d3d12.D3D_ROOT_SIGNATURE_VERSION_1_0, &blob, &err);
    if (err) |e| _ = e.*.lpVtbl.*.Release.?(e);
    if (shr != d3d12.S_OK or blob == null) return null;
    defer _ = blob.?.*.lpVtbl.*.Release.?(blob.?);
    const data = blob.?.*.lpVtbl.*.GetBufferPointer.?(blob.?);
    const size = blob.?.*.lpVtbl.*.GetBufferSize.?(blob.?);

    var rs: ?*d3d12.ID3D12RootSignature = null;
    const dhr = dev.*.lpVtbl.*.CreateRootSignature.?(dev, 0, data, size, &d3d12.IID_ID3D12RootSignature, @ptrCast(&rs));
    if (dhr != d3d12.S_OK) return null;
    return rs;
}

fn createPipelineState(dev: *d3d12.ID3D12Device, root_sig: *d3d12.ID3D12RootSignature, vs_src: []const u8, ps_src: []const u8, has_uv: bool, is_image: bool) ?*d3d12.ID3D12PipelineState {
    _ = is_image;
    const vs_blob = compileShader(vs_src, "vs_5_0") orelse return null;
    defer _ = vs_blob.*.lpVtbl.*.Release.?(vs_blob);
    const ps_blob = compileShader(ps_src, "ps_5_0") orelse return null;
    defer _ = ps_blob.*.lpVtbl.*.Release.?(ps_blob);

    var desc: d3d12.D3D12_GRAPHICS_PIPELINE_STATE_DESC = std.mem.zeroes(d3d12.D3D12_GRAPHICS_PIPELINE_STATE_DESC);
    desc.pRootSignature = root_sig;
    desc.VS = bytecodeOf(vs_blob);
    desc.PS = bytecodeOf(ps_blob);

    // 混合 (预乘 alpha: ONE, INV_SRC_ALPHA)
    desc.BlendState.AlphaToCoverageEnable = 0;
    desc.BlendState.IndependentBlendEnable = 0;
    desc.BlendState.RenderTarget[0].BlendEnable = 1;
    desc.BlendState.RenderTarget[0].SrcBlend = d3d12.D3D12_BLEND_ONE;
    desc.BlendState.RenderTarget[0].DestBlend = d3d12.D3D12_BLEND_INV_SRC_ALPHA;
    desc.BlendState.RenderTarget[0].BlendOp = d3d12.D3D12_BLEND_OP_ADD;
    desc.BlendState.RenderTarget[0].SrcBlendAlpha = d3d12.D3D12_BLEND_ONE;
    desc.BlendState.RenderTarget[0].DestBlendAlpha = d3d12.D3D12_BLEND_INV_SRC_ALPHA;
    desc.BlendState.RenderTarget[0].BlendOpAlpha = d3d12.D3D12_BLEND_OP_ADD;
    desc.BlendState.RenderTarget[0].RenderTargetWriteMask = d3d12.D3D12_COLOR_WRITE_ENABLE_ALL;
    desc.SampleMask = std.math.maxInt(u32);

    // 光栅化
    desc.RasterizerState.FillMode = d3d12.D3D12_FILL_MODE_SOLID;
    desc.RasterizerState.CullMode = d3d12.D3D12_CULL_MODE_NONE;
    desc.RasterizerState.FrontCounterClockwise = 0;
    desc.RasterizerState.DepthBias = 0;
    desc.RasterizerState.DepthBiasClamp = 0;
    desc.RasterizerState.SlopeScaledDepthBias = 0;
    desc.RasterizerState.DepthClipEnable = 0;
    desc.RasterizerState.MultisampleEnable = 0;
    desc.RasterizerState.AntialiasedLineEnable = 0;
    desc.RasterizerState.ConservativeRaster = 0;

    // 输入布局
    var elements: [3]d3d12.D3D12_INPUT_ELEMENT_DESC = std.mem.zeroes([3]d3d12.D3D12_INPUT_ELEMENT_DESC);
    elements[0].SemanticName = "POSITION";
    elements[0].SemanticIndex = 0;
    elements[0].Format = d3d12.DXGI_FORMAT_R32G32_SFLOAT;
    elements[0].InputSlot = 0;
    elements[0].AlignedByteOffset = 0;
    elements[0].InputSlotClass = d3d12.D3D12_INPUT_CLASSIFICATION_PER_VERTEX_DATA;
    elements[0].InstanceDataStepRate = 0;
    var elem_count: u32 = 1;
    if (has_uv) {
        elements[1].SemanticName = "TEXCOORD";
        elements[1].SemanticIndex = 0;
        elements[1].Format = d3d12.DXGI_FORMAT_R32G32_SFLOAT;
        elements[1].InputSlot = 0;
        elements[1].AlignedByteOffset = 8;
        elements[1].InputSlotClass = d3d12.D3D12_INPUT_CLASSIFICATION_PER_VERTEX_DATA;
        elements[1].InstanceDataStepRate = 0;
        elements[2].SemanticName = "COLOR";
        elements[2].SemanticIndex = 0;
        elements[2].Format = d3d12.DXGI_FORMAT_R32G32B32A32_SFLOAT;
        elements[2].InputSlot = 0;
        elements[2].AlignedByteOffset = 16;
        elements[2].InputSlotClass = d3d12.D3D12_INPUT_CLASSIFICATION_PER_VERTEX_DATA;
        elements[2].InstanceDataStepRate = 0;
        elem_count = 3;
    } else {
        elements[1].SemanticName = "COLOR";
        elements[1].SemanticIndex = 0;
        elements[1].Format = d3d12.DXGI_FORMAT_R32G32B32A32_SFLOAT;
        elements[1].InputSlot = 0;
        elements[1].AlignedByteOffset = 8;
        elements[1].InputSlotClass = d3d12.D3D12_INPUT_CLASSIFICATION_PER_VERTEX_DATA;
        elements[1].InstanceDataStepRate = 0;
        elem_count = 2;
    }
    desc.InputLayout.pInputElementDescs = &elements;
    desc.InputLayout.NumElements = elem_count;

    desc.PrimitiveTopologyType = d3d12.D3D12_PRIMITIVE_TOPOLOGY_TYPE_TRIANGLE;
    desc.NumRenderTargets = 1;
    desc.RTVFormats[0] = d3d12.DXGI_FORMAT_R8G8B8A8_UNORM;
    desc.SampleDesc.Count = 1;
    desc.SampleDesc.Quality = 0;

    var pso: ?*d3d12.ID3D12PipelineState = null;
    const hr = dev.*.lpVtbl.*.CreatePipelineState.?(dev, &desc, &d3d12.IID_ID3D12PipelineState, @ptrCast(&pso));
    if (hr != d3d12.S_OK) return null;
    return pso;
}

fn bytecodeOf(blob: *d3d12.ID3DBlob) d3d12.D3D12_SHADER_BYTECODE {
    return .{
        .pShaderBytecode = blob.*.lpVtbl.*.GetBufferPointer.?(blob),
        .BytecodeLength = blob.*.lpVtbl.*.GetBufferSize.?(blob),
    };
}

const UploadBuffer = struct {
    resource: *d3d12.ID3D12Resource,
    mapped: [*]u8,
};

fn createUploadBuffer(dev: *d3d12.ID3D12Device, size: u64) ?UploadBuffer {
    var heap_props: d3d12.D3D12_HEAP_PROPERTIES = std.mem.zeroes(d3d12.D3D12_HEAP_PROPERTIES);
    heap_props.Type = d3d12.D3D12_HEAP_TYPE_UPLOAD;
    var desc: d3d12.D3D12_RESOURCE_DESC = std.mem.zeroes(d3d12.D3D12_RESOURCE_DESC);
    desc.Dimension = d3d12.D3D12_RESOURCE_DIMENSION_BUFFER;
    desc.Width = size;
    desc.Height = 1;
    desc.DepthOrArraySize = 1;
    desc.MipLevels = 1;
    desc.SampleDesc.Count = 1;
    desc.Layout = d3d12.D3D12_TEXTURE_LAYOUT_ROW_MAJOR;

    var resource: ?*d3d12.ID3D12Resource = null;
    const hr = dev.*.lpVtbl.*.CreateCommittedResource.?(dev, &heap_props, 0, &desc, d3d12.D3D12_RESOURCE_STATE_GENERIC_READ, null, &d3d12.IID_ID3D12Resource, @ptrCast(&resource));
    if (hr != d3d12.S_OK) return null;

    var mapped: ?*anyopaque = null;
    const mhr = resource.?.*.lpVtbl.*.Map.?(resource.?, 0, null, &mapped);
    if (mhr != d3d12.S_OK) {
        _ = resource.?.*.lpVtbl.*.Release.?(resource.?);
        return null;
    }
    return .{ .resource = resource.?, .mapped = @ptrCast(mapped) };
}
