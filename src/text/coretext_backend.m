#import <CoreText/CoreText.h>
#import <CoreGraphics/CoreGraphics.h>
#import <CoreFoundation/CoreFoundation.h>
#include <string.h>
#include <stdlib.h>
#include "coretext_backend.h"

/* ── Font Struct ──────────────────────────────────────────────────────────── */

struct ZiguiCtFont {
    CTFontRef   ct_font;
    float       size;
    uint16_t    weight;
};

/* ── Helpers ──────────────────────────────────────────────────────────────── */

static CFStringRef createCFString(const char *utf8, int len) {
    if (len < 0) len = (int)strlen(utf8);
    return CFStringCreateWithBytes(kCFAllocatorDefault,
                                   (const UInt8 *)utf8, len,
                                   kCFStringEncodingUTF8, false);
}

static CTFontRef createCTFont(const char *family, float size, uint16_t weight) {
    CTFontRef font = NULL;

    if (family && family[0] != '\0') {
        CFStringRef family_cf = createCFString(family, -1);
        CTFontDescriptorRef desc = CTFontDescriptorCreateWithNameAndSize(family_cf, size);
        if (desc) {
            font = CTFontCreateWithFontDescriptor(desc, size, NULL);
            CFRelease(desc);
        }
        CFRelease(family_cf);
    }

    if (!font) {
        /* Fallback: system font with weight */
        CGFloat ct_weight;
        if (weight <= 100) ct_weight = -0.8;
        else if (weight <= 200) ct_weight = -0.6;
        else if (weight <= 300) ct_weight = -0.4;
        else if (weight <= 400) ct_weight = 0.0;
        else if (weight <= 500) ct_weight = 0.23;
        else if (weight <= 600) ct_weight = 0.3;
        else if (weight <= 700) ct_weight = 0.4;
        else if (weight <= 800) ct_weight = 0.56;
        else ct_weight = 0.62;

        CFNumberRef weight_num = CFNumberCreate(kCFAllocatorDefault, kCFNumberCGFloatType, &ct_weight);
        CFStringRef keys[] = { kCTFontWeightTrait };
        CFTypeRef values[] = { weight_num };
        CFDictionaryRef traits = CFDictionaryCreate(kCFAllocatorDefault,
            (const void **)keys, (const void **)values, 1,
            &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);

        CFStringRef attr_keys[] = { kCTFontTraitsAttribute };
        CFTypeRef attr_values[] = { traits };
        CFDictionaryRef attrs = CFDictionaryCreate(kCFAllocatorDefault,
            (const void **)attr_keys, (const void **)attr_values, 1,
            &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);

        CTFontDescriptorRef desc = CTFontDescriptorCreateWithAttributes(attrs);
        font = CTFontCreateWithFontDescriptor(desc, size, NULL);

        CFRelease(desc);
        CFRelease(attrs);
        CFRelease(traits);
        CFRelease(weight_num);
    }

    return font;
}

/* ── Font Lifecycle ───────────────────────────────────────────────────────── */

ZiguiCtFont *zigui_ct_create_font(const char *family, float size, uint16_t weight) {
    @autoreleasepool {
        CTFontRef ct_font = createCTFont(family, size, weight);
        if (!ct_font) return NULL;

        ZiguiCtFont *font = (ZiguiCtFont *)calloc(1, sizeof(ZiguiCtFont));
        font->ct_font = ct_font;
        font->size = size;
        font->weight = weight;
        return font;
    }
}

void zigui_ct_destroy_font(ZiguiCtFont *font) {
    if (!font) return;
    if (font->ct_font) CFRelease(font->ct_font);
    free(font);
}

void zigui_ct_get_metrics(ZiguiCtFont *font, ZiguiFontMetrics *out) {
    if (!font || !out) return;
    CTFontRef f = font->ct_font;
    out->ascent = (float)CTFontGetAscent(f);
    out->descent = (float)CTFontGetDescent(f);
    out->leading = (float)CTFontGetLeading(f);
    out->line_height = out->ascent + out->descent + out->leading;
    out->underline_position = (float)CTFontGetUnderlinePosition(f);
    out->underline_thickness = (float)CTFontGetUnderlineThickness(f);
    out->cap_height = (float)CTFontGetCapHeight(f);
    out->x_height = (float)CTFontGetXHeight(f);
}

/* ── Shaping ──────────────────────────────────────────────────────────────── */

int zigui_ct_shape_text(ZiguiCtFont *font, const char *text, int text_len,
                        ZiguiShapedGlyph *out_glyphs, int max_glyphs) {
    if (!font || !text || text_len == 0 || !out_glyphs || max_glyphs == 0) return 0;

    @autoreleasepool {
        CFStringRef str = createCFString(text, text_len);
        if (!str) return 0;

        /* Build attributed string with our font */
        CFMutableAttributedStringRef attr_str = CFAttributedStringCreateMutable(kCFAllocatorDefault, 0);
        CFAttributedStringReplaceString(attr_str, CFRangeMake(0, 0), str);
        CFAttributedStringSetAttribute(attr_str, CFRangeMake(0, CFAttributedStringGetLength(attr_str)),
                                       kCTFontAttributeName, font->ct_font);

        /* Create CTLine for shaping */
        CTLineRef line = CTLineCreateWithAttributedString(attr_str);
        if (!line) {
            CFRelease(attr_str);
            CFRelease(str);
            return 0;
        }

        CFArrayRef runs = CTLineGetGlyphRuns(line);
        CFIndex run_count = CFArrayGetCount(runs);
        int total_glyphs = 0;

        for (CFIndex ri = 0; ri < run_count && total_glyphs < max_glyphs; ri++) {
            CTRunRef run = (CTRunRef)CFArrayGetValueAtIndex(runs, ri);
            CFIndex glyph_count = CTRunGetGlyphCount(run);
            if (glyph_count == 0) continue;

            /* Get run attributes to find string range for cluster mapping */
            CFRange run_range = CTRunGetStringRange(run);

            /* Get glyphs and positions */
            CGGlyph *glyphs = (CGGlyph *)malloc(sizeof(CGGlyph) * glyph_count);
            CGPoint *positions = (CGPoint *)malloc(sizeof(CGPoint) * glyph_count);
            CGSize *advances = (CGSize *)malloc(sizeof(CGSize) * glyph_count);
            CFIndex *string_indices = (CFIndex *)malloc(sizeof(CFIndex) * glyph_count);

            CTRunGetGlyphs(run, CFRangeMake(0, 0), glyphs);
            CTRunGetPositions(run, CFRangeMake(0, 0), positions);
            CTRunGetAdvances(run, CFRangeMake(0, 0), advances);
            CTRunGetStringIndices(run, CFRangeMake(0, 0), string_indices);

            for (CFIndex gi = 0; gi < glyph_count && total_glyphs < max_glyphs; gi++) {
                ZiguiShapedGlyph *sg = &out_glyphs[total_glyphs];
                sg->glyph_id = (uint32_t)glyphs[gi];
                sg->cluster = (uint32_t)(run_range.location + string_indices[gi]);
                sg->x_advance = (float)advances[gi].width;
                sg->y_advance = (float)advances[gi].height;
                sg->x_offset = (float)positions[gi].x;
                sg->y_offset = (float)positions[gi].y;
                total_glyphs++;
            }

            free(glyphs);
            free(positions);
            free(advances);
            free(string_indices);
        }

        CFRelease(line);
        CFRelease(attr_str);
        CFRelease(str);
        return total_glyphs;
    }
}

float zigui_ct_measure_text(ZiguiCtFont *font, const char *text, int text_len) {
    if (!font || !text || text_len == 0) return 0.0f;

    @autoreleasepool {
        CFStringRef str = createCFString(text, text_len);
        if (!str) return 0.0f;

        CFMutableAttributedStringRef attr_str = CFAttributedStringCreateMutable(kCFAllocatorDefault, 0);
        CFAttributedStringReplaceString(attr_str, CFRangeMake(0, 0), str);
        CFAttributedStringSetAttribute(attr_str, CFRangeMake(0, CFAttributedStringGetLength(attr_str)),
                                       kCTFontAttributeName, font->ct_font);

        CTLineRef line = CTLineCreateWithAttributedString(attr_str);
        float width = 0.0f;
        if (line) {
            CGFloat ascent, descent, leading;
            width = (float)CTLineGetTypographicBounds(line, &ascent, &descent, &leading);
            CFRelease(line);
        }

        CFRelease(attr_str);
        CFRelease(str);
        return width;
    }
}

/* ── Glyph Rasterization ──────────────────────────────────────────────────── */

bool zigui_ct_rasterize_glyph(ZiguiCtFont *font, uint32_t glyph_id,
                               uint8_t *buf, int buf_size,
                               ZiguiGlyphBitmapMetrics *out_metrics) {
    if (!font || !out_metrics) return false;

    @autoreleasepool {
        CTFontRef f = font->ct_font;
        CGGlyph glyph = (CGGlyph)glyph_id;

        /* Get glyph bounding box */
        CGRect bounds;
        CTFontGetBoundingRectsForGlyphs(f, kCTFontOrientationDefault, &glyph, &bounds, 1);

        /* Get advance */
        CGSize advance;
        CTFontGetAdvancesForGlyphs(f, kCTFontOrientationDefault, &glyph, &advance, 1);

        /* Calculate bitmap dimensions with padding for anti-aliasing */
        int pad = 2;
        int w = (int)ceil(bounds.size.width) + pad * 2;
        int h = (int)ceil(bounds.size.height) + pad * 2;

        /* Fill metrics */
        out_metrics->width = w;
        out_metrics->height = h;
        out_metrics->bearing_x = (int32_t)floor(bounds.origin.x) - pad;
        out_metrics->bearing_y = (int32_t)ceil(bounds.origin.y + bounds.size.height) + pad;
        out_metrics->advance = (int32_t)round(advance.width);

        if (w <= 0 || h <= 0) {
            /* Space or zero-width glyph */
            out_metrics->width = 0;
            out_metrics->height = 0;
            return true;
        }

        if (w * h > buf_size) return false;

        /* Clear buffer */
        memset(buf, 0, w * h);

        /* Create grayscale bitmap context */
        CGColorSpaceRef cs = CGColorSpaceCreateDeviceGray();
        CGContextRef ctx = CGBitmapContextCreate(buf, w, h, 8, w, cs,
                                                  (CGBitmapInfo)kCGImageAlphaNone);
        CGColorSpaceRelease(cs);
        if (!ctx) return false;

        /* CoreGraphics has origin at bottom-left, flip Y */
        CGContextTranslateCTM(ctx, 0, h);
        CGContextScaleCTM(ctx, 1.0, -1.0);

        /* Position glyph: translate so that glyph origin maps correctly */
        CGContextTranslateCTM(ctx, -bounds.origin.x + pad, -bounds.origin.y + pad);

        /* Draw glyph path */
        CGContextSetGrayFillColor(ctx, 1.0, 1.0);
        CGPathRef path = CTFontCreatePathForGlyph(f, glyph, NULL);
        if (path) {
            CGContextAddPath(ctx, path);
            CGContextFillPath(ctx);
            CGPathRelease(path);
        }

        CGContextRelease(ctx);
        return true;
    }
}
