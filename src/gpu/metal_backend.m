#import <Metal/Metal.h>
#import <QuartzCore/CAMetalLayer.h>
#include <string.h>
#include "metal_backend.h"

/* ── MSL Shader Source ────────────────────────────────────────────────────── */

static const char *kShaderSource =
    "#include <metal_stdlib>\n"
    "using namespace metal;\n"
    "\n"
    "/* ── Solid-color pipeline ── */\n"
    "struct VertexIn {\n"
    "    float2 position [[attribute(0)]];\n"
    "    float4 color    [[attribute(1)]];\n"
    "};\n"
    "\n"
    "struct VertexOut {\n"
    "    float4 position [[position]];\n"
    "    float4 color;\n"
    "};\n"
    "\n"
    "vertex VertexOut vertex_main(VertexIn in [[stage_in]],\n"
    "                             constant float2 &viewport [[buffer(1)]]) {\n"
    "    VertexOut out;\n"
    "    float x = in.position.x / viewport.x * 2.0 - 1.0;\n"
    "    float y = 1.0 - in.position.y / viewport.y * 2.0;\n"
    "    out.position = float4(x, y, 0.0, 1.0);\n"
    "    out.color = in.color;\n"
    "    return out;\n"
    "}\n"
    "\n"
    "fragment float4 fragment_main(VertexOut in [[stage_in]]) {\n"
    "    return in.color;\n"
    "}\n"
    "\n"
    "/* ── Textured pipeline (text/glyphs) ── */\n"
    "struct TextVertexIn {\n"
    "    float2 position [[attribute(0)]];\n"
    "    float2 uv       [[attribute(1)]];\n"
    "    float4 color    [[attribute(2)]];\n"
    "};\n"
    "\n"
    "struct TextVertexOut {\n"
    "    float4 position [[position]];\n"
    "    float2 uv;\n"
    "    float4 color;\n"
    "};\n"
    "\n"
    "vertex TextVertexOut text_vertex_main(TextVertexIn in [[stage_in]],\n"
    "                                      constant float2 &viewport [[buffer(1)]]) {\n"
    "    TextVertexOut out;\n"
    "    float x = in.position.x / viewport.x * 2.0 - 1.0;\n"
    "    float y = 1.0 - in.position.y / viewport.y * 2.0;\n"
    "    out.position = float4(x, y, 0.0, 1.0);\n"
    "    out.uv = in.uv;\n"
    "    out.color = in.color;\n"
    "    return out;\n"
    "}\n"
    "\n"
    "fragment float4 text_fragment_main(TextVertexOut in [[stage_in]],\n"
    "                                   texture2d<float> atlas [[texture(0)]],\n"
    "                                   sampler smp [[sampler(0)]]) {\n"
    "    float coverage = atlas.sample(smp, in.uv).r;\n"
    "    return float4(in.color.rgb * coverage, in.color.a * coverage);\n"
    "}\n"
    "\n"
    "/* ── Image pipeline (RGBA textures) ── */\n"
    "fragment float4 image_fragment_main(TextVertexOut in [[stage_in]],\n"
    "                                    texture2d<float> tex [[texture(0)]],\n"
    "                                    sampler smp [[sampler(0)]]) {\n"
    "    float4 c = tex.sample(smp, in.uv);\n"
    "    float a = c.a * in.color.a;\n"
    "    return float4(c.rgb * in.color.rgb * a, a);\n"
    "}\n";

/* ── Device Struct ────────────────────────────────────────────────────────── */

struct ZiguiMetalDevice {
    id<MTLDevice>           device;
    id<MTLCommandQueue>     commandQueue;
    CAMetalLayer           *layer;

    /* Solid pipeline */
    id<MTLRenderPipelineState> pipelineState;
    id<MTLBuffer>           vertexBuffer;
    uint32_t                maxVertices;

    /* Textured pipeline (text) */
    id<MTLRenderPipelineState> textPipelineState;
    id<MTLBuffer>           textVertexBuffer;
    uint32_t                maxTextVertices;
    id<MTLSamplerState>     samplerState;

    /* Image pipeline (RGBA textures) */
    id<MTLRenderPipelineState> imagePipelineState;

    /* Per-frame state */
    id<CAMetalDrawable>     currentDrawable;
    id<MTLCommandBuffer>    currentCmdBuf;
    id<MTLRenderCommandEncoder> currentEncoder;
    dispatch_semaphore_t    semaphore;
    uint32_t                fbWidth;
    uint32_t                fbHeight;

    /* Dirty-rect rendering: 持久离屏画布, 每帧 scissor 重绘脏区后 blit 到 drawable */
    id<MTLTexture>          offscreen;
    bool                    frameOnOffscreen;
};

/* ── Init / Destroy ───────────────────────────────────────────────────────── */

ZiguiMetalDevice *zigui_metal_init(void *metal_layer, uint32_t max_vertices) {
    @autoreleasepool {
        id<MTLDevice> device = MTLCreateSystemDefaultDevice();
        if (!device) return NULL;

        CAMetalLayer *layer = (__bridge CAMetalLayer *)metal_layer;
        layer.device = device;
        layer.pixelFormat = MTLPixelFormatBGRA8Unorm;
        layer.maximumDrawableCount = 3;
        layer.displaySyncEnabled = YES;

        id<MTLCommandQueue> queue = [device newCommandQueue];

        /* Compile shaders */
        NSString *src = [NSString stringWithUTF8String:kShaderSource];
        NSError *err = nil;
        id<MTLLibrary> lib = [device newLibraryWithSource:src options:nil error:&err];
        if (!lib) {
            NSLog(@"zigui: shader compile failed: %@", err);
            return NULL;
        }

        /* ── Solid pipeline ── */
        MTLVertexDescriptor *vd = [MTLVertexDescriptor vertexDescriptor];
        vd.attributes[0].format = MTLVertexFormatFloat2;
        vd.attributes[0].offset = 0;
        vd.attributes[0].bufferIndex = 0;
        vd.attributes[1].format = MTLVertexFormatFloat4;
        vd.attributes[1].offset = 8;
        vd.attributes[1].bufferIndex = 0;
        vd.layouts[0].stride = 24;
        vd.layouts[0].stepRate = 1;
        vd.layouts[0].stepFunction = MTLVertexStepFunctionPerVertex;

        id<MTLFunction> vs = [lib newFunctionWithName:@"vertex_main"];
        id<MTLFunction> fs = [lib newFunctionWithName:@"fragment_main"];

        MTLRenderPipelineDescriptor *pd = [[MTLRenderPipelineDescriptor alloc] init];
        pd.vertexFunction = vs;
        pd.fragmentFunction = fs;
        pd.vertexDescriptor = vd;
        pd.colorAttachments[0].pixelFormat = MTLPixelFormatBGRA8Unorm;
        pd.colorAttachments[0].blendingEnabled = YES;
        pd.colorAttachments[0].sourceRGBBlendFactor = MTLBlendFactorOne;
        pd.colorAttachments[0].destinationRGBBlendFactor = MTLBlendFactorOneMinusSourceAlpha;
        pd.colorAttachments[0].rgbBlendOperation = MTLBlendOperationAdd;
        pd.colorAttachments[0].sourceAlphaBlendFactor = MTLBlendFactorOne;
        pd.colorAttachments[0].destinationAlphaBlendFactor = MTLBlendFactorOneMinusSourceAlpha;
        pd.colorAttachments[0].alphaBlendOperation = MTLBlendOperationAdd;

        id<MTLRenderPipelineState> ps = [device newRenderPipelineStateWithDescriptor:pd error:&err];
        if (!ps) {
            NSLog(@"zigui: solid pipeline creation failed: %@", err);
            return NULL;
        }

        /* ── Textured pipeline (text) ── */
        MTLVertexDescriptor *tvd = [MTLVertexDescriptor vertexDescriptor];
        tvd.attributes[0].format = MTLVertexFormatFloat2;
        tvd.attributes[0].offset = 0;
        tvd.attributes[0].bufferIndex = 0;
        tvd.attributes[1].format = MTLVertexFormatFloat2;
        tvd.attributes[1].offset = 8;
        tvd.attributes[1].bufferIndex = 0;
        tvd.attributes[2].format = MTLVertexFormatFloat4;
        tvd.attributes[2].offset = 16;
        tvd.attributes[2].bufferIndex = 0;
        tvd.layouts[0].stride = 32;
        tvd.layouts[0].stepRate = 1;
        tvd.layouts[0].stepFunction = MTLVertexStepFunctionPerVertex;

        id<MTLFunction> tvs = [lib newFunctionWithName:@"text_vertex_main"];
        id<MTLFunction> tfs = [lib newFunctionWithName:@"text_fragment_main"];

        MTLRenderPipelineDescriptor *tpd = [[MTLRenderPipelineDescriptor alloc] init];
        tpd.vertexFunction = tvs;
        tpd.fragmentFunction = tfs;
        tpd.vertexDescriptor = tvd;
        tpd.colorAttachments[0].pixelFormat = MTLPixelFormatBGRA8Unorm;
        tpd.colorAttachments[0].blendingEnabled = YES;
        tpd.colorAttachments[0].sourceRGBBlendFactor = MTLBlendFactorOne;
        tpd.colorAttachments[0].destinationRGBBlendFactor = MTLBlendFactorOneMinusSourceAlpha;
        tpd.colorAttachments[0].rgbBlendOperation = MTLBlendOperationAdd;
        tpd.colorAttachments[0].sourceAlphaBlendFactor = MTLBlendFactorOne;
        tpd.colorAttachments[0].destinationAlphaBlendFactor = MTLBlendFactorOneMinusSourceAlpha;
        tpd.colorAttachments[0].alphaBlendOperation = MTLBlendOperationAdd;

        id<MTLRenderPipelineState> tps = [device newRenderPipelineStateWithDescriptor:tpd error:&err];
        if (!tps) {
            NSLog(@"zigui: text pipeline creation failed: %@", err);
            return NULL;
        }

        /* ── Image pipeline (RGBA textures, 复用 text 顶点布局) ── */
        id<MTLFunction> ifs = [lib newFunctionWithName:@"image_fragment_main"];

        MTLRenderPipelineDescriptor *ipd = [[MTLRenderPipelineDescriptor alloc] init];
        ipd.vertexFunction = tvs;
        ipd.fragmentFunction = ifs;
        ipd.vertexDescriptor = tvd;
        ipd.colorAttachments[0].pixelFormat = MTLPixelFormatBGRA8Unorm;
        ipd.colorAttachments[0].blendingEnabled = YES;
        ipd.colorAttachments[0].sourceRGBBlendFactor = MTLBlendFactorOne;
        ipd.colorAttachments[0].destinationRGBBlendFactor = MTLBlendFactorOneMinusSourceAlpha;
        ipd.colorAttachments[0].rgbBlendOperation = MTLBlendOperationAdd;
        ipd.colorAttachments[0].sourceAlphaBlendFactor = MTLBlendFactorOne;
        ipd.colorAttachments[0].destinationAlphaBlendFactor = MTLBlendFactorOneMinusSourceAlpha;
        ipd.colorAttachments[0].alphaBlendOperation = MTLBlendOperationAdd;

        id<MTLRenderPipelineState> ips = [device newRenderPipelineStateWithDescriptor:ipd error:&err];
        if (!ips) {
            NSLog(@"zigui: image pipeline creation failed: %@", err);
            return NULL;
        }

        /* Sampler for glyph atlas */
        MTLSamplerDescriptor *sd = [[MTLSamplerDescriptor alloc] init];
        sd.minFilter = MTLSamplerMinMagFilterLinear;
        sd.magFilter = MTLSamplerMinMagFilterLinear;
        sd.sAddressMode = MTLSamplerAddressModeClampToEdge;
        sd.tAddressMode = MTLSamplerAddressModeClampToEdge;
        id<MTLSamplerState> sampler = [device newSamplerStateWithDescriptor:sd];

        /* Vertex buffers */
        id<MTLBuffer> vb = [device newBufferWithLength:sizeof(ZiguiVertex2D) * max_vertices
                                              options:MTLResourceStorageModeShared];
        uint32_t max_text_vertices = max_vertices;
        id<MTLBuffer> tvb = [device newBufferWithLength:sizeof(ZiguiTextVertex) * max_text_vertices
                                               options:MTLResourceStorageModeShared];

        ZiguiMetalDevice *dev = (ZiguiMetalDevice *)calloc(1, sizeof(ZiguiMetalDevice));
        dev->device = device;
        dev->commandQueue = queue;
        dev->layer = layer;
        dev->pipelineState = ps;
        dev->vertexBuffer = vb;
        dev->maxVertices = max_vertices;
        dev->textPipelineState = tps;
        dev->textVertexBuffer = tvb;
        dev->maxTextVertices = max_text_vertices;
        dev->samplerState = sampler;
        dev->imagePipelineState = ips;
        dev->semaphore = dispatch_semaphore_create(3);

        return dev;
    }
}

void zigui_metal_destroy(ZiguiMetalDevice *dev) {
    if (!dev) return;
    dev->pipelineState = nil;
    dev->textPipelineState = nil;
    dev->imagePipelineState = nil;
    dev->vertexBuffer = nil;
    dev->textVertexBuffer = nil;
    dev->samplerState = nil;
    dev->offscreen = nil;
    dev->commandQueue = nil;
    dev->device = nil;
    free(dev);
}

/* ── Frame Lifecycle ──────────────────────────────────────────────────────── */

bool zigui_metal_begin_frame(ZiguiMetalDevice *dev, uint32_t *out_w, uint32_t *out_h) {
    dev->frameOnOffscreen = false;
    dispatch_semaphore_wait(dev->semaphore, dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.0 * NSEC_PER_SEC)));

    @autoreleasepool {
        id<CAMetalDrawable> drawable = [dev->layer nextDrawable];
        if (!drawable) {
            dispatch_semaphore_signal(dev->semaphore);
            return false;
        }
        dev->currentDrawable = drawable;

        CGSize ds = dev->layer.drawableSize;
        dev->fbWidth  = (uint32_t)ds.width;
        dev->fbHeight = (uint32_t)ds.height;
        if (out_w) *out_w = dev->fbWidth;
        if (out_h) *out_h = dev->fbHeight;

        MTLRenderPassDescriptor *rpd = [MTLRenderPassDescriptor renderPassDescriptor];
        rpd.colorAttachments[0].texture = drawable.texture;
        rpd.colorAttachments[0].loadAction = MTLLoadActionClear;
        rpd.colorAttachments[0].storeAction = MTLStoreActionStore;
        rpd.colorAttachments[0].clearColor = MTLClearColorMake(0.0, 0.0, 0.0, 1.0);

        dev->currentCmdBuf = [dev->commandQueue commandBuffer];
        dev->currentEncoder = [dev->currentCmdBuf renderCommandEncoderWithDescriptor:rpd];
    }
    return true;
}

/* 脏矩形帧: 渲染到持久离屏画布, scissor 限定重绘像素。
   画布首建或尺寸变化时整帧 Clear, 否则 Load 保留历史内容,
   仅脏区被重写 (应用需先绘制背景覆盖脏区)。 */
bool zigui_metal_begin_frame_dirty(ZiguiMetalDevice *dev,
                                   int32_t dirty_x, int32_t dirty_y,
                                   int32_t dirty_w, int32_t dirty_h,
                                   uint32_t *out_w, uint32_t *out_h) {
    dev->frameOnOffscreen = true;
    dispatch_semaphore_wait(dev->semaphore, dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.0 * NSEC_PER_SEC)));

    @autoreleasepool {
        id<CAMetalDrawable> drawable = [dev->layer nextDrawable];
        if (!drawable) {
            dispatch_semaphore_signal(dev->semaphore);
            dev->frameOnOffscreen = false;
            return false;
        }
        dev->currentDrawable = drawable;

        CGSize ds = dev->layer.drawableSize;
        dev->fbWidth  = (uint32_t)ds.width;
        dev->fbHeight = (uint32_t)ds.height;
        if (out_w) *out_w = dev->fbWidth;
        if (out_h) *out_h = dev->fbHeight;

        /* 离屏画布 (持久, 尺寸不匹配时重建) */
        bool fresh = false;
        if (!dev->offscreen ||
            dev->offscreen.width  != dev->fbWidth ||
            dev->offscreen.height != dev->fbHeight) {
            MTLTextureDescriptor *td =
                [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatBGRA8Unorm
                                                                   width:dev->fbWidth
                                                                  height:dev->fbHeight
                                                               mipmapped:NO];
            td.usage = MTLTextureUsageRenderTarget | MTLTextureUsageShaderRead;
            td.storageMode = MTLStorageModePrivate;
            dev->offscreen = [dev->device newTextureWithDescriptor:td];
            fresh = true;
        }

        /* 夹紧脏矩形; 无效或首帧 → 全屏 */
        uint32_t sx, sy, sw, sh;
        if (fresh || dirty_w <= 0 || dirty_h <= 0) {
            sx = 0; sy = 0; sw = dev->fbWidth; sh = dev->fbHeight;
        } else {
            int32_t x0 = dirty_x < 0 ? 0 : dirty_x;
            int32_t y0 = dirty_y < 0 ? 0 : dirty_y;
            int32_t x1 = dirty_x + dirty_w > (int32_t)dev->fbWidth  ? (int32_t)dev->fbWidth  : dirty_x + dirty_w;
            int32_t y1 = dirty_y + dirty_h > (int32_t)dev->fbHeight ? (int32_t)dev->fbHeight : dirty_y + dirty_h;
            if (x1 <= x0 || y1 <= y0) {
                sx = 0; sy = 0; sw = dev->fbWidth; sh = dev->fbHeight;
            } else {
                sx = (uint32_t)x0; sy = (uint32_t)y0;
                sw = (uint32_t)(x1 - x0); sh = (uint32_t)(y1 - y0);
            }
        }

        MTLRenderPassDescriptor *rpd = [MTLRenderPassDescriptor renderPassDescriptor];
        rpd.colorAttachments[0].texture = dev->offscreen;
        rpd.colorAttachments[0].loadAction = fresh ? MTLLoadActionClear : MTLLoadActionLoad;
        rpd.colorAttachments[0].storeAction = MTLStoreActionStore;
        rpd.colorAttachments[0].clearColor = MTLClearColorMake(0.0, 0.0, 0.0, 1.0);

        dev->currentCmdBuf = [dev->commandQueue commandBuffer];
        dev->currentEncoder = [dev->currentCmdBuf renderCommandEncoderWithDescriptor:rpd];

        MTLScissorRect scissor = { sx, sy, sw, sh };
        [dev->currentEncoder setScissorRect:scissor];
    }
    return true;
}

void zigui_metal_update_vertices(ZiguiMetalDevice *dev, const ZiguiVertex2D *vertices, uint32_t count) {
    if (count == 0) return;
    size_t bytes = sizeof(ZiguiVertex2D) * count;
    if (bytes > sizeof(ZiguiVertex2D) * dev->maxVertices) return;
    memcpy([dev->vertexBuffer contents], vertices, bytes);
}

void zigui_metal_draw(ZiguiMetalDevice *dev, uint32_t vertex_count) {
    if (!dev->currentEncoder || vertex_count == 0) return;
    [dev->currentEncoder setRenderPipelineState:dev->pipelineState];
    [dev->currentEncoder setVertexBuffer:dev->vertexBuffer offset:0 atIndex:0];

    float viewport[2] = { (float)dev->fbWidth, (float)dev->fbHeight };
    [dev->currentEncoder setVertexBytes:viewport length:sizeof(viewport) atIndex:1];

    [dev->currentEncoder drawPrimitives:MTLPrimitiveTypeTriangle
                            vertexStart:0
                            vertexCount:vertex_count];
}

/* ── Texture Management ───────────────────────────────────────────────────── */

void *zigui_metal_create_texture(ZiguiMetalDevice *dev, uint32_t width, uint32_t height) {
    @autoreleasepool {
        MTLTextureDescriptor *td = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatR8Unorm
                                                                                     width:width
                                                                                    height:height
                                                                                 mipmapped:NO];
        td.usage = MTLTextureUsageShaderRead;
        td.storageMode = MTLStorageModeShared;
        id<MTLTexture> tex = [dev->device newTextureWithDescriptor:td];
        if (!tex) return NULL;
        return (__bridge_retained void *)tex;
    }
}

void zigui_metal_destroy_texture(ZiguiMetalDevice *dev, void *texture) {
    (void)dev;
    if (!texture) return;
    id<MTLTexture> tex = (__bridge_transfer id<MTLTexture>)texture;
    tex = nil;
}

void zigui_metal_update_texture_region(ZiguiMetalDevice *dev, void *texture,
                                        uint32_t x, uint32_t y,
                                        uint32_t w, uint32_t h,
                                        const uint8_t *data, uint32_t data_stride) {
    (void)dev;
    if (!texture || !data || w == 0 || h == 0) return;
    id<MTLTexture> tex = (__bridge id<MTLTexture>)texture;
    MTLRegion region = MTLRegionMake2D(x, y, w, h);
    [tex replaceRegion:region mipmapLevel:0 withBytes:data bytesPerRow:data_stride];
}

/* ── Textured Drawing ─────────────────────────────────────────────────────── */

void zigui_metal_update_text_vertices(ZiguiMetalDevice *dev, const ZiguiTextVertex *vertices, uint32_t count) {
    if (count == 0) return;
    size_t bytes = sizeof(ZiguiTextVertex) * count;
    if (bytes > sizeof(ZiguiTextVertex) * dev->maxTextVertices) return;
    memcpy([dev->textVertexBuffer contents], vertices, bytes);
}

void zigui_metal_draw_textured(ZiguiMetalDevice *dev, uint32_t vertex_count, void *texture) {
    if (!dev->currentEncoder || vertex_count == 0 || !texture) return;
    id<MTLTexture> tex = (__bridge id<MTLTexture>)texture;

    [dev->currentEncoder setRenderPipelineState:dev->textPipelineState];
    [dev->currentEncoder setVertexBuffer:dev->textVertexBuffer offset:0 atIndex:0];

    float viewport[2] = { (float)dev->fbWidth, (float)dev->fbHeight };
    [dev->currentEncoder setVertexBytes:viewport length:sizeof(viewport) atIndex:1];

    [dev->currentEncoder setFragmentTexture:tex atIndex:0];
    [dev->currentEncoder setFragmentSamplerState:dev->samplerState atIndex:0];

    [dev->currentEncoder drawPrimitives:MTLPrimitiveTypeTriangle
                            vertexStart:0
                            vertexCount:vertex_count];
}

void zigui_metal_end_frame(ZiguiMetalDevice *dev) {
    if (!dev->currentEncoder) return;

    [dev->currentEncoder endEncoding];

    if (dev->frameOnOffscreen && dev->offscreen) {
        /* 离屏画布 → drawable 整帧拷贝
           (drawable 三缓冲轮换, 复用到的 drawable 只含 3 帧前内容,
            部分拷贝会残留过期像素, 故必须整帧 blit) */
        id<MTLBlitCommandEncoder> blit = [dev->currentCmdBuf blitCommandEncoder];
        [blit copyFromTexture:dev->offscreen
                  sourceSlice:0
                  sourceLevel:0
                 sourceOrigin:MTLOriginMake(0, 0, 0)
                   sourceSize:MTLSizeMake(dev->fbWidth, dev->fbHeight, 1)
                    toTexture:dev->currentDrawable.texture
             destinationSlice:0
             destinationLevel:0
            destinationOrigin:MTLOriginMake(0, 0, 0)];
        [blit endEncoding];
    }

    [dev->currentCmdBuf presentDrawable:dev->currentDrawable];

    dispatch_semaphore_t sem = dev->semaphore;
    [dev->currentCmdBuf addCompletedHandler:^(id<MTLCommandBuffer> _Nonnull buf) {
        (void)buf;
        dispatch_semaphore_signal(sem);
    }];
    [dev->currentCmdBuf commit];

    dev->currentEncoder  = nil;
    dev->currentCmdBuf   = nil;
    dev->currentDrawable = nil;
    dev->frameOnOffscreen = false;
}

void zigui_metal_set_drawable_size(ZiguiMetalDevice *dev, uint32_t width, uint32_t height) {
    dev->layer.drawableSize = CGSizeMake(width, height);
}

/* ── Image Pipeline (RGBA textures) ───────────────────────────────────────── */

void *zigui_metal_create_texture_rgba(ZiguiMetalDevice *dev, uint32_t width, uint32_t height) {
    @autoreleasepool {
        MTLTextureDescriptor *td = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA8Unorm
                                                                                     width:width
                                                                                    height:height
                                                                                 mipmapped:NO];
        td.usage = MTLTextureUsageShaderRead;
        td.storageMode = MTLStorageModeShared;
        id<MTLTexture> tex = [dev->device newTextureWithDescriptor:td];
        if (!tex) return NULL;
        return (__bridge_retained void *)tex;
    }
}

void zigui_metal_draw_image(ZiguiMetalDevice *dev, const ZiguiTextVertex *vertices,
                            uint32_t count, void *texture) {
    if (!dev->currentEncoder || count == 0 || !texture) return;
    id<MTLTexture> tex = (__bridge id<MTLTexture>)texture;

    [dev->currentEncoder setRenderPipelineState:dev->imagePipelineState];
    [dev->currentEncoder setFragmentTexture:tex atIndex:0];
    [dev->currentEncoder setFragmentSamplerState:dev->samplerState atIndex:0];

    float viewport[2] = { (float)dev->fbWidth, (float)dev->fbHeight };
    [dev->currentEncoder setVertexBytes:viewport length:sizeof(viewport) atIndex:1];

    /* 顶点经 setVertexBytes 分块上传 (上限 4KB = 128 个 TextVertex),
       不复用共享 textVertexBuffer, 避免 GPU 执行期间 CPU memcpy 覆盖未消费数据 */
    const uint32_t chunk_max = 128;
    uint32_t offset = 0;
    while (offset < count) {
        uint32_t n = count - offset;
        if (n > chunk_max) n = chunk_max;
        [dev->currentEncoder setVertexBytes:&vertices[offset]
                                     length:sizeof(ZiguiTextVertex) * n
                                    atIndex:0];
        [dev->currentEncoder drawPrimitives:MTLPrimitiveTypeTriangle
                                vertexStart:0
                                vertexCount:n];
        offset += n;
    }
}
