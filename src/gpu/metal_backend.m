#import <Metal/Metal.h>
#import <QuartzCore/CAMetalLayer.h>
#include <string.h>
#include "metal_backend.h"

/* ── MSL Shader Source ────────────────────────────────────────────────────── */

static const char *kShaderSource =
    "#include <metal_stdlib>\n"
    "using namespace metal;\n"
    "\n"
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
    "}\n";

/* ── Device Struct ────────────────────────────────────────────────────────── */

struct ZiguiMetalDevice {
    id<MTLDevice>           device;
    id<MTLCommandQueue>     commandQueue;
    CAMetalLayer           *layer;
    id<MTLRenderPipelineState> pipelineState;
    id<MTLBuffer>           vertexBuffer;
    uint32_t                maxVertices;

    /* Per-frame state */
    id<CAMetalDrawable>     currentDrawable;
    id<MTLCommandBuffer>    currentCmdBuf;
    id<MTLRenderCommandEncoder> currentEncoder;
    dispatch_semaphore_t    semaphore;
    uint32_t                fbWidth;
    uint32_t                fbHeight;
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

        /* Vertex descriptor: pos(2f) + color(4f) = 24 bytes */
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

        /* Compile shaders */
        NSString *src = [NSString stringWithUTF8String:kShaderSource];
        NSError *err = nil;
        id<MTLLibrary> lib = [device newLibraryWithSource:src options:nil error:&err];
        if (!lib) {
            NSLog(@"zigui: shader compile failed: %@", err);
            return NULL;
        }

        id<MTLFunction> vs = [lib newFunctionWithName:@"vertex_main"];
        id<MTLFunction> fs = [lib newFunctionWithName:@"fragment_main"];

        MTLRenderPipelineDescriptor *pd = [[MTLRenderPipelineDescriptor alloc] init];
        pd.vertexFunction = vs;
        pd.fragmentFunction = fs;
        pd.vertexDescriptor = vd;
        pd.colorAttachments[0].pixelFormat = MTLPixelFormatBGRA8Unorm;
        /* Premultiplied alpha blending */
        pd.colorAttachments[0].blendingEnabled = YES;
        pd.colorAttachments[0].sourceRGBBlendFactor = MTLBlendFactorOne;
        pd.colorAttachments[0].destinationRGBBlendFactor = MTLBlendFactorOneMinusSourceAlpha;
        pd.colorAttachments[0].rgbBlendOperation = MTLBlendOperationAdd;
        pd.colorAttachments[0].sourceAlphaBlendFactor = MTLBlendFactorOne;
        pd.colorAttachments[0].destinationAlphaBlendFactor = MTLBlendFactorOneMinusSourceAlpha;
        pd.colorAttachments[0].alphaBlendOperation = MTLBlendOperationAdd;

        id<MTLRenderPipelineState> ps = [device newRenderPipelineStateWithDescriptor:pd error:&err];
        if (!ps) {
            NSLog(@"zigui: pipeline creation failed: %@", err);
            return NULL;
        }

        /* Vertex buffer */
        id<MTLBuffer> vb = [device newBufferWithLength:sizeof(ZiguiVertex2D) * max_vertices
                                              options:MTLResourceStorageModeShared];

        ZiguiMetalDevice *dev = (ZiguiMetalDevice *)calloc(1, sizeof(ZiguiMetalDevice));
        dev->device = device;
        dev->commandQueue = queue;
        dev->layer = layer;
        dev->pipelineState = ps;
        dev->vertexBuffer = vb;
        dev->maxVertices = max_vertices;
        dev->semaphore = dispatch_semaphore_create(3);

        return dev;
    }
}

void zigui_metal_destroy(ZiguiMetalDevice *dev) {
    if (!dev) return;
    dev->pipelineState = nil;
    dev->vertexBuffer = nil;
    dev->commandQueue = nil;
    dev->device = nil;
    free(dev);
}

/* ── Frame Lifecycle ──────────────────────────────────────────────────────── */

bool zigui_metal_begin_frame(ZiguiMetalDevice *dev, uint32_t *out_w, uint32_t *out_h) {
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

    /* Pass viewport size as buffer(1) */
    float viewport[2] = { (float)dev->fbWidth, (float)dev->fbHeight };
    [dev->currentEncoder setVertexBytes:viewport length:sizeof(viewport) atIndex:1];

    [dev->currentEncoder drawPrimitives:MTLPrimitiveTypeTriangle
                            vertexStart:0
                            vertexCount:vertex_count];
}

void zigui_metal_end_frame(ZiguiMetalDevice *dev) {
    if (!dev->currentEncoder) return;

    [dev->currentEncoder endEncoding];
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
}

void zigui_metal_set_drawable_size(ZiguiMetalDevice *dev, uint32_t width, uint32_t height) {
    dev->layer.drawableSize = CGSizeMake(width, height);
}
