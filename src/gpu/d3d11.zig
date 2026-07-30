//! Direct3D 11 GPU 后端 (Windows) - D3D12 不可用时的回退后端
//!
//! 面向 2D UI 渲染优化: 纯色几何 + 纹理文本/图片
//! 接口与 D3D12/Vulkan/Metal 后端对齐。
//! 仅在 Windows 下编译; 非 Windows 平台提供桩实现以保持源码可解析。

const std = @import("std");
const builtin = @import("builtin");
const is_windows = builtin.os.tag == .windows;
const math = @import("../math.zig");

const d3d11 = if (is_windows) @cImport({
    @cDefine("WIN32_LEAN_AND_MEAN", "1");
    @cInclude("windows.h");
    @cInclude("d3d11.h");
    @cInclude("d3dcommon.h");
    @cInclude("dxgi.h");
    @cInclude("d3dcompiler.h");
}) else struct {};

// 与 D3D12 后端共享顶点布局类型。D3DBackend 在运行时把顶点切片分发给
// D3D11 / D3D12 两种后端, 若两者各自定义独立 struct, Zig 会因类型不同而
// 在 Windows 下编译失败。共享同一份定义即可消除该类型不匹配。
const d3d12_mod = @import("d3d12.zig");
pub const Vertex2D = d3d12_mod.Vertex2D;
pub const TextVertex = d3d12_mod.TextVertex;

/// GPU 纹理句柄 (D3D11 资源 + SRV)
pub const TextureHandle = struct {
    texture: *anyopaque = undefined,
    srv: *anyopaque = undefined,
    width: u32 = 0,
    height: u32 = 0,
    is_rgba: bool = false,
};

const max_vertices: u32 = 65536;

// ── HLSL 着色器源码 (与 D3D12 后端一致, 运行时用 D3DCompile 编译) ───────────
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

pub const D3D11Device = if (is_windows) struct {
    allocator: std.mem.Allocator,
    device: ?*d3d11.ID3D11Device = null,
    context: ?*d3d11.ID3D11DeviceContext = null,
    swap_chain: ?*d3d11.IDXGISwapChain = null,
    rtv: ?*d3d11.ID3D11RenderTargetView = null,

    // 着色器
    solid_vs: ?*d3d11.ID3D11VertexShader = null,
    solid_ps: ?*d3d11.ID3D11PixelShader = null,
    textured_vs: ?*d3d11.ID3D11VertexShader = null,
    textured_ps: ?*d3d11.ID3D11PixelShader = null,
    image_ps: ?*d3d11.ID3D11PixelShader = null,

    // 输入布局
    solid_layout: ?*d3d11.ID3D11InputLayout = null,
    textured_layout: ?*d3d11.ID3D11InputLayout = null,

    // 顶点缓冲 (DYNAMIC, 每帧 Map WRITE_DISCARD)
    solid_vb: ?*d3d11.ID3D11Buffer = null,
    text_vb: ?*d3d11.ID3D11Buffer = null,
    // 立即绘制用的小顶点缓冲
    immediate_vb: ?*d3d11.ID3D11Buffer = null,
    immediate_text_vb: ?*d3d11.ID3D11Buffer = null,

    // 常量缓冲 (screen_size)
    cb_screen: ?*d3d11.ID3D11Buffer = null,

    // 混合状态 & 采样器
    blend_state: ?*d3d11.ID3D11BlendState = null,
    sampler_state: ?*d3d11.ID3D11SamplerState = null,
    // 启用 scissor 的光栅化状态 (D3D11 默认不裁剪, 必须显式启用才能生效)
    raster_state_scissor: ?*d3d11.ID3D11RasterizerState = null,

    // 状态
    fb_width: u32 = 0,
    fb_height: u32 = 0,
    content_scale: f32 = 1.0,
    needs_resize: bool = false,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator, hwnd: *anyopaque, width: u32, height: u32) !Self {
        var self = Self{ .allocator = allocator };

        // 1. 创建 DXGI Factory
        var factory: ?*d3d11.IDXGIFactory = null;
        if (d3d11.CreateDXGIFactory1(@ptrCast(&d3d11.IID_IDXGIFactory), @ptrCast(&factory)) != d3d11.S_OK) {
            return error.DxgiFactoryFailed;
        }

        // 2. 创建 D3D11 设备 + 交换链
        const swapchain_desc = d3d11.DXGI_SWAP_CHAIN_DESC{
            .BufferDesc = .{
                .Width = width,
                .Height = height,
                .RefreshRate = .{ .Numerator = 60, .Denominator = 1 },
                .Format = d3d11.DXGI_FORMAT_R8G8B8A8_UNORM,
                .ScanlineOrdering = d3d11.DXGI_MODE_SCANLINE_ORDER_UNSPECIFIED,
                .Scaling = d3d11.DXGI_MODE_SCALING_UNSPECIFIED,
            },
            .SampleDesc = .{ .Count = 1, .Quality = 0 },
            .BufferUsage = d3d11.DXGI_USAGE_RENDER_TARGET_OUTPUT,
            .BufferCount = 2,
            .OutputWindow = @alignCast(@ptrCast(hwnd)),
            .Windowed = d3d11.TRUE,
            .SwapEffect = d3d11.DXGI_SWAP_EFFECT_DISCARD,
            .Flags = 0,
        };

        const feature_levels = [_]d3d11.D3D_FEATURE_LEVEL{
            d3d11.D3D_FEATURE_LEVEL_11_1,
            d3d11.D3D_FEATURE_LEVEL_11_0,
            d3d11.D3D_FEATURE_LEVEL_10_1,
            d3d11.D3D_FEATURE_LEVEL_10_0,
        };

        var device: ?*d3d11.ID3D11Device = null;
        var context: ?*d3d11.ID3D11DeviceContext = null;
        var swap_chain: ?*d3d11.IDXGISwapChain = null;
        var feature_level: d3d11.D3D_FEATURE_LEVEL = d3d11.D3D_FEATURE_LEVEL_11_0;

        const hr = d3d11.D3D11CreateDeviceAndSwapChain(
            null,
            d3d11.D3D_DRIVER_TYPE_HARDWARE,
            null,
            0, // flags (可加 D3D11_CREATE_DEVICE_DEBUG)
            @ptrCast(&feature_levels),
            @intCast(feature_levels.len),
            d3d11.D3D11_SDK_VERSION,
            &swapchain_desc,
            &swap_chain,
            &device,
            &feature_level,
            &context,
        );
        if (hr != d3d11.S_OK) {
            // 尝试 WARP 软件回退
            const hr2 = d3d11.D3D11CreateDeviceAndSwapChain(
                null,
                d3d11.D3D_DRIVER_TYPE_WARP,
                null,
                0,
                @ptrCast(&feature_levels),
                @intCast(feature_levels.len),
                d3d11.D3D11_SDK_VERSION,
                &swapchain_desc,
                &swap_chain,
                &device,
                &feature_level,
                &context,
            );
            if (hr2 != d3d11.S_OK) return error.DeviceCreationFailed;
        }

        if (factory) |f| _ = f.*.lpVtbl.*.Release.?(f);
        self.device = device;
        self.context = context;
        self.swap_chain = swap_chain;
        self.fb_width = width;
        self.fb_height = height;

        // 3. 创建 Render Target View
        var back_buffer: ?*d3d11.ID3D11Texture2D = null;
        _ = swap_chain.?.*.lpVtbl.*.GetBuffer.?(swap_chain, 0, @ptrCast(&d3d11.IID_ID3D11Texture2D), @ptrCast(&back_buffer));
        if (back_buffer) |bb| {
            _ = device.?.*.lpVtbl.*.CreateRenderTargetView.?(device, @ptrCast(bb), null, &self.rtv);
            _ = bb.*.lpVtbl.*.Release.?(bb);
        }

        // 4. 编译着色器并创建管线状态
        try self.createShaders(device.?);

        // 5. 创建顶点缓冲 (DYNAMIC)
        self.solid_vb = createDynamicBuffer(device.?, max_vertices * @sizeOf(Vertex2D), d3d11.D3D11_BIND_VERTEX_BUFFER);
        self.text_vb = createDynamicBuffer(device.?, max_vertices * @sizeOf(TextVertex), d3d11.D3D11_BIND_VERTEX_BUFFER);
        self.immediate_vb = createDynamicBuffer(device.?, 4096 * @sizeOf(Vertex2D), d3d11.D3D11_BIND_VERTEX_BUFFER);
        self.immediate_text_vb = createDynamicBuffer(device.?, 4096 * @sizeOf(TextVertex), d3d11.D3D11_BIND_VERTEX_BUFFER);

        // 6. 创建常量缓冲 (screen_size: 2 floats = 8 bytes, 但 CB 需要 16 字节对齐)
        {
            const cbd = d3d11.D3D11_BUFFER_DESC{
                .ByteWidth = 16, // 16 字节对齐
                .Usage = d3d11.D3D11_USAGE_DYNAMIC,
                .BindFlags = d3d11.D3D11_BIND_CONSTANT_BUFFER,
                .CPUAccessFlags = d3d11.D3D11_CPU_ACCESS_WRITE,
                .MiscFlags = 0,
                .StructureByteStride = 0,
            };
            _ = device.?.*.lpVtbl.*.CreateBuffer.?(device, &cbd, null, &self.cb_screen);
        }

        // 7. 创建混合状态 (预乘 alpha: ONE, INV_SRC_ALPHA)
        {
            const bd = d3d11.D3D11_BLEND_DESC{
                .AlphaToCoverageEnable = d3d11.FALSE,
                .IndependentBlendEnable = d3d11.FALSE,
                .RenderTarget = [_]d3d11.D3D11_RENDER_TARGET_BLEND_DESC{.{
                    .BlendEnable = d3d11.TRUE,
                    .SrcBlend = d3d11.D3D11_BLEND_ONE,
                    .DestBlend = d3d11.D3D11_BLEND_INV_SRC_ALPHA,
                    .BlendOp = d3d11.D3D11_BLEND_OP_ADD,
                    .SrcBlendAlpha = d3d11.D3D11_BLEND_ONE,
                    .DestBlendAlpha = d3d11.D3D11_BLEND_INV_SRC_ALPHA,
                    .BlendOpAlpha = d3d11.D3D11_BLEND_OP_ADD,
                    .RenderTargetWriteMask = d3d11.D3D11_COLOR_WRITE_ENABLE_ALL,
                }} ++ [_]d3d11.D3D11_RENDER_TARGET_BLEND_DESC{.{}} ** 7,
            };
            _ = device.?.*.lpVtbl.*.CreateBlendState.?(device, &bd, &self.blend_state);
        }

        // 8. 创建采样器状态
        {
            const sd = d3d11.D3D11_SAMPLER_DESC{
                .Filter = d3d11.D3D11_FILTER_MIN_MAG_MIP_LINEAR,
                .AddressU = d3d11.D3D11_TEXTURE_ADDRESS_CLAMP,
                .AddressV = d3d11.D3D11_TEXTURE_ADDRESS_CLAMP,
                .AddressW = d3d11.D3D11_TEXTURE_ADDRESS_CLAMP,
                .MipLODBias = 0,
                .MaxAnisotropy = 1,
                .ComparisonFunc = d3d11.D3D11_COMPARISON_NEVER,
                .BorderColor = .{ 0, 0, 0, 0 },
                .MinLOD = 0,
                .MaxLOD = d3d11.D3D11_FLOAT32_MAX,
            };
            _ = device.?.*.lpVtbl.*.CreateSamplerState.?(device, &sd, &self.sampler_state);
        }

        // 9. 创建启用 scissor 的光栅化状态 (裁剪矩形由 setScissor 控制)
        {
            const rs = d3d11.D3D11_RASTERIZER_DESC{
                .FillMode = d3d11.D3D11_FILL_SOLID,
                .CullMode = d3d11.D3D11_CULL_NONE,
                .FrontCounterClockwise = d3d11.FALSE,
                .DepthBias = 0,
                .DepthBiasClamp = 0,
                .SlopeScaledDepthBias = 0,
                .DepthClipEnable = d3d11.TRUE,
                .ScissorEnable = d3d11.TRUE,
                .MultisampleEnable = d3d11.FALSE,
                .AntialiasedLineEnable = d3d11.FALSE,
            };
            _ = device.?.*.lpVtbl.*.CreateRasterizerState.?(device, &rs, &self.raster_state_scissor);
        }

        return self;
    }

    fn createShaders(self: *Self, dev: *d3d11.ID3D11Device) !void {
        // 编译 solid VS
        const solid_vs_blob = compileShader(solid_vs_src, "vs_5_0", "main") orelse return error.ShaderCompileFailed;
        defer _ = solid_vs_blob.*.lpVtbl.*.Release.?(solid_vs_blob);
        const solid_ps_blob = compileShader(solid_ps_src, "ps_5_0", "main") orelse return error.ShaderCompileFailed;
        defer _ = solid_ps_blob.*.lpVtbl.*.Release.?(solid_ps_blob);
        const textured_vs_blob = compileShader(textured_vs_src, "vs_5_0", "main") orelse return error.ShaderCompileFailed;
        defer _ = textured_vs_blob.*.lpVtbl.*.Release.?(textured_vs_blob);
        const textured_ps_blob = compileShader(textured_ps_src, "ps_5_0", "main") orelse return error.ShaderCompileFailed;
        defer _ = textured_ps_blob.*.lpVtbl.*.Release.?(textured_ps_blob);
        const image_ps_blob = compileShader(image_ps_src, "ps_5_0", "main") orelse return error.ShaderCompileFailed;
        defer _ = image_ps_blob.*.lpVtbl.*.Release.?(image_ps_blob);

        // 创建顶点/像素着色器
        _ = dev.*.lpVtbl.*.CreateVertexShader.?(dev, @ptrCast(solid_vs_blob.*.lpVtbl.*.GetBufferPointer.?(solid_vs_blob)), solid_vs_blob.*.lpVtbl.*.GetBufferSize.?(solid_vs_blob), null, &self.solid_vs);
        _ = dev.*.lpVtbl.*.CreatePixelShader.?(dev, @ptrCast(solid_ps_blob.*.lpVtbl.*.GetBufferPointer.?(solid_ps_blob)), solid_ps_blob.*.lpVtbl.*.GetBufferSize.?(solid_ps_blob), null, &self.solid_ps);
        _ = dev.*.lpVtbl.*.CreateVertexShader.?(dev, @ptrCast(textured_vs_blob.*.lpVtbl.*.GetBufferPointer.?(textured_vs_blob)), textured_vs_blob.*.lpVtbl.*.GetBufferSize.?(textured_vs_blob), null, &self.textured_vs);
        _ = dev.*.lpVtbl.*.CreatePixelShader.?(dev, @ptrCast(textured_ps_blob.*.lpVtbl.*.GetBufferPointer.?(textured_ps_blob)), textured_ps_blob.*.lpVtbl.*.GetBufferSize.?(textured_ps_blob), null, &self.textured_ps);
        _ = dev.*.lpVtbl.*.CreatePixelShader.?(dev, @ptrCast(image_ps_blob.*.lpVtbl.*.GetBufferPointer.?(image_ps_blob)), image_ps_blob.*.lpVtbl.*.GetBufferSize.?(image_ps_blob), null, &self.image_ps);

        // 创建输入布局
        const solid_elements = [_]d3d11.D3D11_INPUT_ELEMENT_DESC{
            .{ .SemanticName = "POSITION", .SemanticIndex = 0, .Format = d3d11.DXGI_FORMAT_R32G32_FLOAT, .InputSlot = 0, .AlignedByteOffset = 0, .InputSlotClass = d3d11.D3D11_INPUT_PER_VERTEX_DATA, .InstanceDataStepRate = 0 },
            .{ .SemanticName = "COLOR", .SemanticIndex = 0, .Format = d3d11.DXGI_FORMAT_R32G32B32A32_FLOAT, .InputSlot = 0, .AlignedByteOffset = 8, .InputSlotClass = d3d11.D3D11_INPUT_PER_VERTEX_DATA, .InstanceDataStepRate = 0 },
        };
        const textured_elements = [_]d3d11.D3D11_INPUT_ELEMENT_DESC{
            .{ .SemanticName = "POSITION", .SemanticIndex = 0, .Format = d3d11.DXGI_FORMAT_R32G32_FLOAT, .InputSlot = 0, .AlignedByteOffset = 0, .InputSlotClass = d3d11.D3D11_INPUT_PER_VERTEX_DATA, .InstanceDataStepRate = 0 },
            .{ .SemanticName = "TEXCOORD", .SemanticIndex = 0, .Format = d3d11.DXGI_FORMAT_R32G32_FLOAT, .InputSlot = 0, .AlignedByteOffset = 8, .InputSlotClass = d3d11.D3D11_INPUT_PER_VERTEX_DATA, .InstanceDataStepRate = 0 },
            .{ .SemanticName = "COLOR", .SemanticIndex = 0, .Format = d3d11.DXGI_FORMAT_R32G32B32A32_FLOAT, .InputSlot = 0, .AlignedByteOffset = 16, .InputSlotClass = d3d11.D3D11_INPUT_PER_VERTEX_DATA, .InstanceDataStepRate = 0 },
        };

        _ = dev.*.lpVtbl.*.CreateInputLayout.?(dev, &solid_elements, @intCast(solid_elements.len), @ptrCast(solid_vs_blob.*.lpVtbl.*.GetBufferPointer.?(solid_vs_blob)), solid_vs_blob.*.lpVtbl.*.GetBufferSize.?(solid_vs_blob), &self.solid_layout);
        _ = dev.*.lpVtbl.*.CreateInputLayout.?(dev, &textured_elements, @intCast(textured_elements.len), @ptrCast(textured_vs_blob.*.lpVtbl.*.GetBufferPointer.?(textured_vs_blob)), textured_vs_blob.*.lpVtbl.*.GetBufferSize.?(textured_vs_blob), &self.textured_layout);
    }

    pub fn deinit(self: *Self) void {
        if (self.sampler_state) |s| _ = s.*.lpVtbl.*.Release.?(s);
        if (self.raster_state_scissor) |r| _ = r.*.lpVtbl.*.Release.?(r);
        if (self.blend_state) |b| _ = b.*.lpVtbl.*.Release.?(b);
        if (self.cb_screen) |c| _ = c.*.lpVtbl.*.Release.?(c);
        if (self.immediate_text_vb) |b| _ = b.*.lpVtbl.*.Release.?(b);
        if (self.immediate_vb) |b| _ = b.*.lpVtbl.*.Release.?(b);
        if (self.text_vb) |b| _ = b.*.lpVtbl.*.Release.?(b);
        if (self.solid_vb) |b| _ = b.*.lpVtbl.*.Release.?(b);
        if (self.textured_layout) |l| _ = l.*.lpVtbl.*.Release.?(l);
        if (self.solid_layout) |l| _ = l.*.lpVtbl.*.Release.?(l);
        if (self.image_ps) |s| _ = s.*.lpVtbl.*.Release.?(s);
        if (self.textured_ps) |s| _ = s.*.lpVtbl.*.Release.?(s);
        if (self.textured_vs) |s| _ = s.*.lpVtbl.*.Release.?(s);
        if (self.solid_ps) |s| _ = s.*.lpVtbl.*.Release.?(s);
        if (self.solid_vs) |s| _ = s.*.lpVtbl.*.Release.?(s);
        if (self.rtv) |r| _ = r.*.lpVtbl.*.Release.?(r);
        if (self.swap_chain) |s| _ = s.*.lpVtbl.*.Release.?(s);
        if (self.context) |c| _ = c.*.lpVtbl.*.Release.?(c);
        if (self.device) |d| _ = d.*.lpVtbl.*.Release.?(d);
    }

    pub fn beginFrame(self: *Self) ?[2]u32 {
        if (self.needs_resize) {
            self.doResize();
            self.needs_resize = false;
        }

        const ctx = self.context.?;
        const dev = self.device.?;

        // 更新常量缓冲 (screen_size)
        if (self.cb_screen) |cb| {
            var mapped: d3d11.D3D11_MAPPED_SUBRESOURCE = undefined;
            if (ctx.*.lpVtbl.*.Map.?(ctx, @ptrCast(cb), 0, d3d11.D3D11_MAP_WRITE_DISCARD, 0, &mapped) == d3d11.S_OK) {
                const data: *[4]f32 = @ptrCast(@alignCast(mapped.pData));
                data[0] = @floatFromInt(self.fb_width);
                data[1] = @floatFromInt(self.fb_height);
                data[2] = 0;
                data[3] = 0;
                ctx.*.lpVtbl.*.Unmap.?(ctx, @ptrCast(cb), 0);
            }
        }

        // 清除 & 设置 RTV
        const clear_color = [_]f32{ 0.0, 0.0, 0.0, 1.0 };
        ctx.*.lpVtbl.*.ClearRenderTargetView.?(ctx, self.rtv.?, &clear_color);
        ctx.*.lpVtbl.*.OMSetRenderTargets.?(ctx, 1, &self.rtv, null);

        // 设置视口
        const vp = d3d11.D3D11_VIEWPORT{
            .TopLeftX = 0,
            .TopLeftY = 0,
            .Width = @floatFromInt(self.fb_width),
            .Height = @floatFromInt(self.fb_height),
            .MinDepth = 0,
            .MaxDepth = 1,
        };
        ctx.*.lpVtbl.*.RSSetViewports.?(ctx, 1, &vp);

        // 设置混合状态
        ctx.*.lpVtbl.*.OMSetBlendState.?(ctx, self.blend_state, &[_]f32{ 0, 0, 0, 0 }, 0xFFFFFFFF);

        // 启用 scissor 裁剪 (裁剪矩形由 setScissor 设置; 无裁剪时设全屏矩形)
        if (self.raster_state_scissor) |rs| {
            ctx.*.lpVtbl.*.RSSetState.?(ctx, rs);
        }

        // 设置采样器
        ctx.*.lpVtbl.*.PSSetSamplers.?(ctx, 0, 1, &self.sampler_state);

        _ = dev;
        return .{ self.fb_width, self.fb_height };
    }

    pub fn endFrame(self: *Self) void {
        _ = self.swap_chain.?.*.lpVtbl.*.Present.?(self.swap_chain, 1, 0); // vsync
    }

    pub fn updateVertices(self: *Self, vertices: []const Vertex2D) u64 {
        if (vertices.len == 0) return 0;
        const ctx = self.context.?;
        var mapped: d3d11.D3D11_MAPPED_SUBRESOURCE = undefined;
        if (ctx.*.lpVtbl.*.Map.?(ctx, @ptrCast(self.solid_vb), 0, d3d11.D3D11_MAP_WRITE_DISCARD, 0, &mapped) != d3d11.S_OK) return 0;
        const dst: [*]u8 = @ptrCast(mapped.pData);
        @memcpy(dst[0 .. vertices.len * @sizeOf(Vertex2D)], std.mem.sliceAsBytes(vertices));
        ctx.*.lpVtbl.*.Unmap.?(ctx, @ptrCast(self.solid_vb), 0);
        return 0;
    }

    pub fn drawTriangles(self: *Self, vertex_count: u32, vertex_offset: u64) void {
        if (vertex_count == 0) return;
        _ = vertex_offset; // D3D11 不使用 ring buffer offset
        const ctx = self.context.?;
        const stride: u32 = @sizeOf(Vertex2D);
        const offset: u32 = 0;
        ctx.*.lpVtbl.*.IASetVertexBuffers.?(ctx, 0, 1, &self.solid_vb, &stride, &offset);
        ctx.*.lpVtbl.*.IASetInputLayout.?(ctx, self.solid_layout);
        ctx.*.lpVtbl.*.IASetPrimitiveTopology.?(ctx, d3d11.D3D11_PRIMITIVE_TOPOLOGY_TRIANGLELIST);
        ctx.*.lpVtbl.*.VSSetShader.?(ctx, self.solid_vs, null, 0);
        ctx.*.lpVtbl.*.VSSetConstantBuffers.?(ctx, 0, 1, &self.cb_screen);
        ctx.*.lpVtbl.*.PSSetShader.?(ctx, self.solid_ps, null, 0);
        ctx.*.lpVtbl.*.Draw.?(ctx, vertex_count, 0);
    }

    pub fn updateTextVertices(self: *Self, vertices: []const TextVertex) u64 {
        if (vertices.len == 0) return 0;
        const ctx = self.context.?;
        var mapped: d3d11.D3D11_MAPPED_SUBRESOURCE = undefined;
        if (ctx.*.lpVtbl.*.Map.?(ctx, @ptrCast(self.text_vb), 0, d3d11.D3D11_MAP_WRITE_DISCARD, 0, &mapped) != d3d11.S_OK) return 0;
        const dst: [*]u8 = @ptrCast(mapped.pData);
        @memcpy(dst[0 .. vertices.len * @sizeOf(TextVertex)], std.mem.sliceAsBytes(vertices));
        ctx.*.lpVtbl.*.Unmap.?(ctx, @ptrCast(self.text_vb), 0);
        return 0;
    }

    pub fn drawTextured(self: *Self, vertex_count: u32, texture: TextureHandle, vertex_offset: u64) void {
        if (vertex_count == 0) return;
        _ = vertex_offset;
        const ctx = self.context.?;
        const stride: u32 = @sizeOf(TextVertex);
        const offset: u32 = 0;
        ctx.*.lpVtbl.*.IASetVertexBuffers.?(ctx, 0, 1, &self.text_vb, &stride, &offset);
        ctx.*.lpVtbl.*.IASetInputLayout.?(ctx, self.textured_layout);
        ctx.*.lpVtbl.*.IASetPrimitiveTopology.?(ctx, d3d11.D3D11_PRIMITIVE_TOPOLOGY_TRIANGLELIST);
        ctx.*.lpVtbl.*.VSSetShader.?(ctx, self.textured_vs, null, 0);
        ctx.*.lpVtbl.*.VSSetConstantBuffers.?(ctx, 0, 1, &self.cb_screen);
        ctx.*.lpVtbl.*.PSSetShader.?(ctx, self.textured_ps, null, 0);
        const srv: ?*d3d11.ID3D11ShaderResourceView = @alignCast(@ptrCast(texture.srv));
        ctx.*.lpVtbl.*.PSSetShaderResources.?(ctx, 0, 1, &srv);
        ctx.*.lpVtbl.*.Draw.?(ctx, vertex_count, 0);
    }

    pub fn drawImage(self: *Self, vertices: []const TextVertex, texture: TextureHandle) void {
        if (vertices.len == 0) return;
        const ctx = self.context.?;
        // 更新文本顶点缓冲
        _ = self.updateTextVertices(vertices);
        const stride: u32 = @sizeOf(TextVertex);
        const offset: u32 = 0;
        ctx.*.lpVtbl.*.IASetVertexBuffers.?(ctx, 0, 1, &self.text_vb, &stride, &offset);
        ctx.*.lpVtbl.*.IASetInputLayout.?(ctx, self.textured_layout);
        ctx.*.lpVtbl.*.IASetPrimitiveTopology.?(ctx, d3d11.D3D11_PRIMITIVE_TOPOLOGY_TRIANGLELIST);
        ctx.*.lpVtbl.*.VSSetShader.?(ctx, self.textured_vs, null, 0);
        ctx.*.lpVtbl.*.VSSetConstantBuffers.?(ctx, 0, 1, &self.cb_screen);
        ctx.*.lpVtbl.*.PSSetShader.?(ctx, self.image_ps, null, 0);
        const srv: ?*d3d11.ID3D11ShaderResourceView = @alignCast(@ptrCast(texture.srv));
        ctx.*.lpVtbl.*.PSSetShaderResources.?(ctx, 0, 1, &srv);
        ctx.*.lpVtbl.*.Draw.?(ctx, @intCast(vertices.len), 0);
    }

    pub fn drawTrianglesImmediate(self: *Self, vertices: []const Vertex2D) void {
        if (vertices.len == 0) return;
        const ctx = self.context.?;
        var mapped: d3d11.D3D11_MAPPED_SUBRESOURCE = undefined;
        if (ctx.*.lpVtbl.*.Map.?(ctx, @ptrCast(self.immediate_vb), 0, d3d11.D3D11_MAP_WRITE_DISCARD, 0, &mapped) != d3d11.S_OK) return;
        const dst: [*]u8 = @ptrCast(mapped.pData);
        @memcpy(dst[0 .. vertices.len * @sizeOf(Vertex2D)], std.mem.sliceAsBytes(vertices));
        ctx.*.lpVtbl.*.Unmap.?(ctx, @ptrCast(self.immediate_vb), 0);
        const stride: u32 = @sizeOf(Vertex2D);
        const offset: u32 = 0;
        ctx.*.lpVtbl.*.IASetVertexBuffers.?(ctx, 0, 1, &self.immediate_vb, &stride, &offset);
        ctx.*.lpVtbl.*.IASetInputLayout.?(ctx, self.solid_layout);
        ctx.*.lpVtbl.*.IASetPrimitiveTopology.?(ctx, d3d11.D3D11_PRIMITIVE_TOPOLOGY_TRIANGLELIST);
        ctx.*.lpVtbl.*.VSSetShader.?(ctx, self.solid_vs, null, 0);
        ctx.*.lpVtbl.*.VSSetConstantBuffers.?(ctx, 0, 1, &self.cb_screen);
        ctx.*.lpVtbl.*.PSSetShader.?(ctx, self.solid_ps, null, 0);
        ctx.*.lpVtbl.*.Draw.?(ctx, @intCast(vertices.len), 0);
    }

    pub fn drawTexturedImmediate(self: *Self, vertices: []const TextVertex, texture: TextureHandle) void {
        if (vertices.len == 0) return;
        const ctx = self.context.?;
        var mapped: d3d11.D3D11_MAPPED_SUBRESOURCE = undefined;
        if (ctx.*.lpVtbl.*.Map.?(ctx, @ptrCast(self.immediate_text_vb), 0, d3d11.D3D11_MAP_WRITE_DISCARD, 0, &mapped) != d3d11.S_OK) return;
        const dst: [*]u8 = @ptrCast(mapped.pData);
        @memcpy(dst[0 .. vertices.len * @sizeOf(TextVertex)], std.mem.sliceAsBytes(vertices));
        ctx.*.lpVtbl.*.Unmap.?(ctx, @ptrCast(self.immediate_text_vb), 0);
        const stride: u32 = @sizeOf(TextVertex);
        const offset: u32 = 0;
        ctx.*.lpVtbl.*.IASetVertexBuffers.?(ctx, 0, 1, &self.immediate_text_vb, &stride, &offset);
        ctx.*.lpVtbl.*.IASetInputLayout.?(ctx, self.textured_layout);
        ctx.*.lpVtbl.*.IASetPrimitiveTopology.?(ctx, d3d11.D3D11_PRIMITIVE_TOPOLOGY_TRIANGLELIST);
        ctx.*.lpVtbl.*.VSSetShader.?(ctx, self.textured_vs, null, 0);
        ctx.*.lpVtbl.*.VSSetConstantBuffers.?(ctx, 0, 1, &self.cb_screen);
        ctx.*.lpVtbl.*.PSSetShader.?(ctx, self.textured_ps, null, 0);
        const srv: ?*d3d11.ID3D11ShaderResourceView = @ptrCast(texture.srv);
        ctx.*.lpVtbl.*.PSSetShaderResources.?(ctx, 0, 1, &srv);
        ctx.*.lpVtbl.*.Draw.?(ctx, @intCast(vertices.len), 0);
    }

    pub fn setScissor(self: *Self, rect: ?math.Rect(f32)) void {
        const ctx = self.context.?;
        if (rect) |r| {
            const fw: i32 = @intCast(self.fb_width);
            const fh: i32 = @intCast(self.fb_height);
            const s = self.content_scale;
            var x0: i32 = @intFromFloat(@floor(r.x * s));
            var y0: i32 = @intFromFloat(@floor(r.y * s));
            var x1: i32 = @intFromFloat(@ceil((r.x + r.width) * s));
            var y1: i32 = @intFromFloat(@ceil((r.y + r.height) * s));
            if (x0 < 0) x0 = 0;
            if (y0 < 0) y0 = 0;
            if (x1 > fw) x1 = fw;
            if (y1 > fh) y1 = fh;
            const w: u32 = if (x1 > x0) @intCast(x1 - x0) else 0;
            const h: u32 = if (y1 > y0) @intCast(y1 - y0) else 0;
            if (w == 0 or h == 0) {
                // 空 scissor: 设置 1x1 避免完全无输出
                const empty = d3d11.D3D11_RECT{ .left = 0, .top = 0, .right = 1, .bottom = 1 };
                ctx.*.lpVtbl.*.RSSetScissorRects.?(ctx, 1, &empty);
            } else {
                const sc = d3d11.D3D11_RECT{ .left = x0, .top = y0, .right = x1, .bottom = y1 };
                ctx.*.lpVtbl.*.RSSetScissorRects.?(ctx, 1, &sc);
            }
            // D3D11 默认不启用 scissor test, 需要通过 RSSetState 启用.
            // 这里通过视口裁剪替代: D3D11 的 scissor rect 在没有 rasterizer state 时不生效.
            // 设置 scissor-enabled rasterizer state:
            // (简化: 直接设置 scissor rect, 多数情况下 D3D11 仍会遵循)
        } else {
            const full = d3d11.D3D11_RECT{ .left = 0, .top = 0, .right = @intCast(self.fb_width), .bottom = @intCast(self.fb_height) };
            ctx.*.lpVtbl.*.RSSetScissorRects.?(ctx, 1, &full);
        }
    }

    pub fn setDrawableSize(self: *Self, width: u32, height: u32) void {
        if (width == 0 or height == 0) return;
        if (width == self.fb_width and height == self.fb_height) return;
        self.fb_width = width;
        self.fb_height = height;
        self.needs_resize = true;
    }

    pub fn setContentScale(self: *Self, scale: f32) void {
        if (scale <= 0.0) return;
        self.content_scale = scale;
    }

    fn doResize(self: *Self) void {
        const ctx = self.context.?;
        // 释放旧 RTV
        if (self.rtv) |r| {
            _ = r.*.lpVtbl.*.Release.?(r);
            self.rtv = null;
        }
        // resize swapchain
        _ = self.swap_chain.?.*.lpVtbl.*.ResizeBuffers.?(self.swap_chain, 0, self.fb_width, self.fb_height, d3d11.DXGI_FORMAT_UNKNOWN, 0);
        // 重建 RTV
        var back_buffer: ?*d3d11.ID3D11Texture2D = null;
        _ = self.swap_chain.?.*.lpVtbl.*.GetBuffer.?(self.swap_chain, 0, @ptrCast(&d3d11.IID_ID3D11Texture2D), @ptrCast(&back_buffer));
        if (back_buffer) |bb| {
            _ = self.device.?.*.lpVtbl.*.CreateRenderTargetView.?(self.device, @ptrCast(bb), null, &self.rtv);
            _ = bb.*.lpVtbl.*.Release.?(bb);
        }
        _ = ctx;
    }

    // ── Texture ──────────────────────────────────────────────────────────────

    pub fn createTexture(self: *Self, width: u32, height: u32) ?TextureHandle {
        return self.createTextureInternal(width, height, false);
    }

    pub fn createTextureRGBA(self: *Self, width: u32, height: u32) ?TextureHandle {
        return self.createTextureInternal(width, height, true);
    }

    fn createTextureInternal(self: *Self, width: u32, height: u32, is_rgba: bool) ?TextureHandle {
        const dev = self.device.?;
        const format: u32 = if (is_rgba) d3d11.DXGI_FORMAT_R8G8B8A8_UNORM else d3d11.DXGI_FORMAT_R8_UNORM;
        const desc = d3d11.D3D11_TEXTURE2D_DESC{
            .Width = width,
            .Height = height,
            .MipLevels = 1,
            .ArraySize = 1,
            .Format = format,
            .SampleDesc = .{ .Count = 1, .Quality = 0 },
            .Usage = d3d11.D3D11_USAGE_DEFAULT,
            .BindFlags = d3d11.D3D11_BIND_SHADER_RESOURCE,
            .CPUAccessFlags = 0,
            .MiscFlags = 0,
        };
        var texture: ?*d3d11.ID3D11Texture2D = null;
        if (dev.*.lpVtbl.*.CreateTexture2D.?(dev, &desc, null, &texture) != d3d11.S_OK) return null;

        // 创建 SRV
        const srv_desc = d3d11.D3D11_SHADER_RESOURCE_VIEW_DESC{
            .Format = format,
            .ViewDimension = d3d11.D3D11_SRV_DIMENSION_TEXTURE2D,
            .unnamed_0 = .{ .Texture2D = .{ .MostDetailedMip = 0, .MipLevels = 1 } },
        };
        var srv: ?*d3d11.ID3D11ShaderResourceView = null;
        if (dev.*.lpVtbl.*.CreateShaderResourceView.?(dev, @ptrCast(texture), &srv_desc, &srv) != d3d11.S_OK) {
            _ = texture.?.*.lpVtbl.*.Release.?(texture);
            return null;
        }

        return .{
            .texture = @ptrCast(texture),
            .srv = @ptrCast(srv),
            .width = width,
            .height = height,
            .is_rgba = is_rgba,
        };
    }

    pub fn destroyTexture(self: *Self, texture: TextureHandle) void {
        _ = self;
        const srv: ?*d3d11.ID3D11ShaderResourceView = @alignCast(@ptrCast(texture.srv));
        const tex: ?*d3d11.ID3D11Texture2D = @alignCast(@ptrCast(texture.texture));
        if (srv) |s| _ = s.*.lpVtbl.*.Release.?(s);
        if (tex) |t| _ = t.*.lpVtbl.*.Release.?(t);
    }

    pub fn updateTextureRegion(self: *Self, texture: TextureHandle, x: u32, y: u32, w: u32, h: u32, data: []const u8, data_stride: u32) void {
        self.updateTextureInternal(texture, x, y, w, h, data, data_stride);
    }

    pub fn updateTextureRegionRGBA(self: *Self, texture: TextureHandle, x: u32, y: u32, w: u32, h: u32, data: []const u8, data_stride: u32) void {
        self.updateTextureInternal(texture, x, y, w, h, data, data_stride);
    }

    fn updateTextureInternal(self: *Self, texture: TextureHandle, x: u32, y: u32, w: u32, h: u32, data: []const u8, data_stride: u32) void {
        const ctx = self.context.?;
        const tex: ?*d3d11.ID3D11Texture2D = @alignCast(@ptrCast(texture.texture));
        const box = d3d11.D3D11_BOX{
            .left = x,
            .top = y,
            .front = 0,
            .right = x + w,
            .bottom = y + h,
            .back = 1,
        };
        // 遵循调用方提供的源行距 data_stride, 正确处理子区域 / 非紧凑排列上传
        // (字形图集部分上传时源缓冲区行距往往等于整图行距, 而非 w*bpp)
        const row_pitch = data_stride;
        ctx.*.lpVtbl.*.UpdateSubresource.?(ctx, @ptrCast(tex), 0, &box, data.ptr, row_pitch, 0);
    }

    pub fn prepareTextureForSampling(self: *Self, texture: TextureHandle) void {
        _ = self;
        _ = texture;
    }

    pub fn initTextureForTransfer(self: *Self, texture: TextureHandle) void {
        _ = self;
        _ = texture;
    }

    pub fn prepareTextureForTransfer(self: *Self, texture: TextureHandle) void {
        _ = self;
        _ = texture;
    }
} else struct {
    pub fn init(allocator: std.mem.Allocator, hwnd: *anyopaque, width: u32, height: u32) !D3D11Device {
        _ = allocator;
        _ = hwnd;
        _ = width;
        _ = height;
        return error.NotImplemented;
    }
    pub fn deinit(self: *D3D11Device) void {
        _ = self;
    }
    pub fn beginFrame(self: *D3D11Device) ?[2]u32 {
        _ = self;
        return null;
    }
    pub fn endFrame(self: *D3D11Device) void {
        _ = self;
    }
    pub fn updateVertices(self: *D3D11Device, vertices: []const Vertex2D) u64 {
        _ = self;
        _ = vertices;
        return 0;
    }
    pub fn drawTriangles(self: *D3D11Device, vertex_count: u32, vertex_offset: u64) void {
        _ = self;
        _ = vertex_count;
        _ = vertex_offset;
    }
    pub fn updateTextVertices(self: *D3D11Device, vertices: []const TextVertex) u64 {
        _ = self;
        _ = vertices;
        return 0;
    }
    pub fn drawTextured(self: *D3D11Device, vertex_count: u32, texture: TextureHandle, vertex_offset: u64) void {
        _ = self;
        _ = vertex_count;
        _ = texture;
        _ = vertex_offset;
    }
    pub fn drawImage(self: *D3D11Device, vertices: []const TextVertex, texture: TextureHandle) void {
        _ = self;
        _ = vertices;
        _ = texture;
    }
    pub fn drawTrianglesImmediate(self: *D3D11Device, vertices: []const Vertex2D) void {
        _ = self;
        _ = vertices;
    }
    pub fn drawTexturedImmediate(self: *D3D11Device, vertices: []const TextVertex, texture: TextureHandle) void {
        _ = self;
        _ = vertices;
        _ = texture;
    }
    pub fn setScissor(self: *D3D11Device, rect: ?math.Rect(f32)) void {
        _ = self;
        _ = rect;
    }
    pub fn setDrawableSize(self: *D3D11Device, width: u32, height: u32) void {
        _ = self;
        _ = width;
        _ = height;
    }
    pub fn setContentScale(self: *D3D11Device, scale: f32) void {
        _ = self;
        _ = scale;
    }
    pub fn createTexture(self: *D3D11Device, width: u32, height: u32) ?TextureHandle {
        _ = self;
        _ = width;
        _ = height;
        return null;
    }
    pub fn createTextureRGBA(self: *D3D11Device, width: u32, height: u32) ?TextureHandle {
        _ = self;
        _ = width;
        _ = height;
        return null;
    }
    pub fn destroyTexture(self: *D3D11Device, texture: TextureHandle) void {
        _ = self;
        _ = texture;
    }
    pub fn updateTextureRegion(self: *D3D11Device, texture: TextureHandle, x: u32, y: u32, w: u32, h: u32, data: []const u8, data_stride: u32) void {
        _ = self;
        _ = texture;
        _ = x;
        _ = y;
        _ = w;
        _ = h;
        _ = data;
        _ = data_stride;
    }
    pub fn updateTextureRegionRGBA(self: *D3D11Device, texture: TextureHandle, x: u32, y: u32, w: u32, h: u32, data: []const u8, data_stride: u32) void {
        _ = self;
        _ = texture;
        _ = x;
        _ = y;
        _ = w;
        _ = h;
        _ = data;
        _ = data_stride;
    }
    pub fn prepareTextureForSampling(self: *D3D11Device, texture: TextureHandle) void {
        _ = self;
        _ = texture;
    }
    pub fn initTextureForTransfer(self: *D3D11Device, texture: TextureHandle) void {
        _ = self;
        _ = texture;
    }
    pub fn prepareTextureForTransfer(self: *D3D11Device, texture: TextureHandle) void {
        _ = self;
        _ = texture;
    }
};

// ── D3D11 辅助函数 (仅 Windows) ─────────────────────────────────────────────

fn createDynamicBuffer(dev: *d3d11.ID3D11Device, size: usize, bind_flags: u32) ?*d3d11.ID3D11Buffer {
    const desc = d3d11.D3D11_BUFFER_DESC{
        .ByteWidth = @intCast(size),
        .Usage = d3d11.D3D11_USAGE_DYNAMIC,
        .BindFlags = bind_flags,
        .CPUAccessFlags = d3d11.D3D11_CPU_ACCESS_WRITE,
        .MiscFlags = 0,
        .StructureByteStride = 0,
    };
    var buffer: ?*d3d11.ID3D11Buffer = null;
    if (dev.*.lpVtbl.*.CreateBuffer.?(dev, &desc, null, &buffer) != d3d11.S_OK) return null;
    return buffer;
}

fn compileShader(src: []const u8, profile: [*:0]const u8, entry: [*:0]const u8) ?*d3d11.ID3DBlob {
    var blob: ?*d3d11.ID3DBlob = null;
    var error_blob: ?*d3d11.ID3DBlob = null;
    const hr = d3d11.D3DCompile(
        src.ptr,
        src.len,
        null,
        null,
        null,
        entry,
        profile,
        0,
        0,
        &blob,
        &error_blob,
    );
    if (error_blob) |eb| {
        _ = eb.*.lpVtbl.*.Release.?(eb);
    }
    if (hr != d3d11.S_OK) return null;
    return blob;
}
