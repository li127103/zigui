#ifndef ZIGUI_METAL_BACKEND_H
#define ZIGUI_METAL_BACKEND_H

#include <stdint.h>
#include <stdbool.h>

typedef struct ZiguiMetalDevice ZiguiMetalDevice;

/* Solid-color vertex: pos(2f) + color(4f) = 24 bytes */
typedef struct {
    float pos[2];
    float color[4];
} ZiguiVertex2D;

/* Textured vertex: pos(2f) + uv(2f) + color(4f) = 32 bytes */
typedef struct {
    float pos[2];
    float uv[2];
    float color[4];
} ZiguiTextVertex;

/* ── Device lifecycle ─────────────────────────────────────────────────────── */

ZiguiMetalDevice *zigui_metal_init(void *metal_layer, uint32_t max_vertices);
void zigui_metal_destroy(ZiguiMetalDevice *dev);

/* ── Frame lifecycle ──────────────────────────────────────────────────────── */

bool zigui_metal_begin_frame(ZiguiMetalDevice *dev, uint32_t *out_width, uint32_t *out_height);
/* Dirty-rect frame: render into persistent offscreen canvas with scissor */
bool zigui_metal_begin_frame_dirty(ZiguiMetalDevice *dev,
                                   int32_t dirty_x, int32_t dirty_y,
                                   int32_t dirty_w, int32_t dirty_h,
                                   uint32_t *out_width, uint32_t *out_height);
void zigui_metal_end_frame(ZiguiMetalDevice *dev);
void zigui_metal_set_drawable_size(ZiguiMetalDevice *dev, uint32_t width, uint32_t height);

/* ── Solid-color drawing ──────────────────────────────────────────────────── */

void zigui_metal_update_vertices(ZiguiMetalDevice *dev, const ZiguiVertex2D *vertices, uint32_t count);
void zigui_metal_draw(ZiguiMetalDevice *dev, uint32_t vertex_count);

/* ── Texture management (glyph atlas) ─────────────────────────────────────── */

/* Create an R8Unorm texture atlas, returns texture pointer or NULL */
void *zigui_metal_create_texture(ZiguiMetalDevice *dev, uint32_t width, uint32_t height);
void zigui_metal_destroy_texture(ZiguiMetalDevice *dev, void *texture);

/* Update a sub-region of the texture (data = row-major R8 pixels) */
void zigui_metal_update_texture_region(ZiguiMetalDevice *dev, void *texture,
                                        uint32_t x, uint32_t y,
                                        uint32_t w, uint32_t h,
                                        const uint8_t *data, uint32_t data_stride);

/* ── Textured drawing (text/glyphs) ───────────────────────────────────────── */

void zigui_metal_update_text_vertices(ZiguiMetalDevice *dev, const ZiguiTextVertex *vertices, uint32_t count);
void zigui_metal_draw_textured(ZiguiMetalDevice *dev, uint32_t vertex_count, void *texture);

/* ── Image pipeline (RGBA textures) ───────────────────────────────────────── */

/* Create an RGBA8Unorm texture (images), returns texture pointer or NULL */
void *zigui_metal_create_texture_rgba(ZiguiMetalDevice *dev, uint32_t width, uint32_t height);

/* Draw image quads; vertices uploaded via setVertexBytes (no shared buffer) */
void zigui_metal_draw_image(ZiguiMetalDevice *dev, const ZiguiTextVertex *vertices,
                            uint32_t count, void *texture);

/* Immediate draws (setVertexBytes chunked upload, safe for mid-frame flush;
   unlike update_vertices+draw they never overwrite the shared vertex buffers) */
void zigui_metal_draw_solid_immediate(ZiguiMetalDevice *dev, const ZiguiVertex2D *vertices,
                                      uint32_t count);
void zigui_metal_draw_textured_immediate(ZiguiMetalDevice *dev, const ZiguiTextVertex *vertices,
                                         uint32_t count, void *texture);

#endif
