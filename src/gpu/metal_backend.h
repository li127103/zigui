#ifndef ZIGUI_METAL_BACKEND_H
#define ZIGUI_METAL_BACKEND_H

#include <stdint.h>
#include <stdbool.h>

typedef struct ZiguiMetalDevice ZiguiMetalDevice;

typedef struct {
    float pos[2];
    float color[4];
} ZiguiVertex2D;

ZiguiMetalDevice *zigui_metal_init(void *metal_layer, uint32_t max_vertices);
void zigui_metal_destroy(ZiguiMetalDevice *dev);

bool zigui_metal_begin_frame(ZiguiMetalDevice *dev, uint32_t *out_width, uint32_t *out_height);
void zigui_metal_update_vertices(ZiguiMetalDevice *dev, const ZiguiVertex2D *vertices, uint32_t count);
void zigui_metal_draw(ZiguiMetalDevice *dev, uint32_t vertex_count);
void zigui_metal_end_frame(ZiguiMetalDevice *dev);
void zigui_metal_set_drawable_size(ZiguiMetalDevice *dev, uint32_t width, uint32_t height);

#endif
