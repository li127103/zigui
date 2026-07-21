//! GPU 类型定义

pub const PixelFormat = enum {
    rgba8_unorm,
    bgra8_unorm,
    r8_unorm,
    rg8_unorm,
    rgba8_srgb,
    bgra8_srgb,
    depth32_float,
};

pub const BufferUsage = packed struct(u8) {
    vertex: bool = false,
    index: bool = false,
    uniform: bool = false,
    storage: bool = false,
    transfer_src: bool = false,
    transfer_dst: bool = false,
    _padding: u2 = 0,
};

pub const MemoryType = enum {
    device_local,
    host_visible,
    host_coherent,
};

pub const BufferDesc = struct {
    size: u64,
    usage: BufferUsage = .{},
    memory: MemoryType = .device_local,
};

pub const TextureUsage = packed struct(u8) {
    sampled: bool = false,
    render_target: bool = false,
    transfer_src: bool = false,
    transfer_dst: bool = false,
    _padding: u4 = 0,
};

pub const TextureDesc = struct {
    width: u32,
    height: u32,
    format: PixelFormat = .rgba8_unorm,
    usage: TextureUsage = .{},
    mip_levels: u32 = 1,
    sample_count: u32 = 1,
};

pub const BlendFactor = enum {
    zero,
    one,
    src_alpha,
    one_minus_src_alpha,
    dst_alpha,
    one_minus_dst_alpha,
    src_color,
    dst_color,
};

pub const BlendOp = enum {
    add,
    subtract,
    reverse_subtract,
    min,
    max,
};

pub const BlendState = struct {
    enabled: bool = true,
    src_color: BlendFactor = .src_alpha,
    dst_color: BlendFactor = .one_minus_src_alpha,
    op_color: BlendOp = .add,
    src_alpha: BlendFactor = .one,
    dst_alpha: BlendFactor = .one_minus_src_alpha,
    op_alpha: BlendOp = .add,
};

pub const PrimitiveTopology = enum {
    triangle_list,
    triangle_strip,
    line_list,
    line_strip,
    point_list,
};

pub const VertexFormat = enum {
    float2,
    float3,
    float4,
    ubyte4,
    ubyte4_norm,
};

pub const VertexAttribute = struct {
    location: u32,
    format: VertexFormat,
    offset: u32,
};

pub const VertexLayout = struct {
    stride: u32,
    attributes: []const VertexAttribute,
};

pub const PipelineDesc = struct {
    vertex_shader: []const u8,
    fragment_shader: []const u8,
    vertex_layout: VertexLayout,
    blend: BlendState = .{},
    topology: PrimitiveTopology = .triangle_list,
    push_constant_size: u32 = 0,
};

pub const SamplerDesc = struct {
    filter: Filter = .linear,
    address_u: AddressMode = .clamp,
    address_v: AddressMode = .clamp,

    pub const Filter = enum { nearest, linear };
    pub const AddressMode = enum { clamp, repeat, mirror };
};

pub const IndexType = enum { u16, u32 };

pub const Viewport = struct {
    x: f32 = 0,
    y: f32 = 0,
    width: f32,
    height: f32,
    min_depth: f32 = 0,
    max_depth: f32 = 1,
};
