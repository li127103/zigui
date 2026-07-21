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
    /* CoreText 对本 run 实际使用的字体 (CFRetained)。中文/emoji 等会回退到
       其它字体, 此时 glyph_id 是相对该回退字体的, 光栅化必须用它而非主字体,
       否则 glyph_id 错位导致乱码。Latin run 即主字体本身。用后须 release。 */
    void *run_font;
    /* run_font 的稳定标识 (CFHash), 与实例地址无关, 用作 atlas 缓存键 */
    uint64_t font_id;
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

/* Get the underlying CTFontRef (borrowed) and a stable id (CFHash) for it. */
void *zigui_ct_native(ZiguiCtFont *font);
uint64_t zigui_ct_font_id(ZiguiCtFont *font);

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

/* Same, but rasterize with an explicit native CTFontRef (e.g. the per-run
 * fallback font carried by ZiguiShapedGlyph.run_font). */
bool zigui_ct_rasterize_glyph_with_font(void *ct_font, uint32_t glyph_id,
                                        uint8_t *buf, int buf_size,
                                        ZiguiGlyphBitmapMetrics *out_metrics);

/* Release a native CTFontRef previously retained (e.g. ZiguiShapedGlyph.run_font). */
void zigui_ct_release_font(void *ct_font);

#endif
