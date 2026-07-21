#ifndef ZIGUI_CORETEXT_BACKEND_H
#define ZIGUI_CORETEXT_BACKEND_H

#include <stdint.h>
#include <stdbool.h>

typedef struct ZiguiCtFont ZiguiCtFont;

/* Shaped glyph output */
typedef struct {
    uint32_t glyph_id;
    uint32_t cluster;      /* byte offset in source UTF-8 text */
    float x_advance;
    float y_advance;
    float x_offset;
    float y_offset;
} ZiguiShapedGlyph;

/* Font metrics */
typedef struct {
    float ascent;
    float descent;
    float leading;
    float line_height;
    float underline_position;
    float underline_thickness;
    float cap_height;
    float x_height;
} ZiguiFontMetrics;

/* Glyph bitmap metrics */
typedef struct {
    int32_t width;
    int32_t height;
    int32_t bearing_x;   /* left offset from pen position */
    int32_t bearing_y;   /* top offset from baseline (positive = up) */
    int32_t advance;     /* horizontal advance in pixels */
} ZiguiGlyphBitmapMetrics;

/* ── Font lifecycle ───────────────────────────────────────────────────────── */

/* Create a CTFont. family can be NULL for system default. weight: 100-900. */
ZiguiCtFont *zigui_ct_create_font(const char *family, float size, uint16_t weight);
void zigui_ct_destroy_font(ZiguiCtFont *font);

/* Get font metrics */
void zigui_ct_get_metrics(ZiguiCtFont *font, ZiguiFontMetrics *out);

/* ── Shaping ──────────────────────────────────────────────────────────────── */

/* Shape UTF-8 text into positioned glyphs. Returns number of glyphs written. */
int zigui_ct_shape_text(ZiguiCtFont *font, const char *text, int text_len,
                        ZiguiShapedGlyph *out_glyphs, int max_glyphs);

/* Measure text width (sum of advances) */
float zigui_ct_measure_text(ZiguiCtFont *font, const char *text, int text_len);

/* ── Glyph rasterization ──────────────────────────────────────────────────── */

/* Rasterize a single glyph to 8-bit grayscale bitmap.
 * buf must be pre-allocated by caller (width * height bytes).
 * Returns true on success. Metrics are always filled. */
bool zigui_ct_rasterize_glyph(ZiguiCtFont *font, uint32_t glyph_id,
                               uint8_t *buf, int buf_size,
                               ZiguiGlyphBitmapMetrics *out_metrics);

#endif
