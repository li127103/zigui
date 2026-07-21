#ifndef ZIGUI_COCOA_BACKEND_H
#define ZIGUI_COCOA_BACKEND_H

#include <stdint.h>
#include <stdbool.h>

typedef struct {
    void *ns_window;
    void *content_view;
    void *metal_layer;
    uint32_t width;
    uint32_t height;
    float scale_factor;
} ZiguiWindowHandle;

typedef enum {
    ZIGUI_EVENT_NONE = 0,
    ZIGUI_EVENT_CLOSE_REQUESTED,
    ZIGUI_EVENT_RESIZE,
    ZIGUI_EVENT_MOUSE_MOVE,
    ZIGUI_EVENT_MOUSE_BUTTON,
    ZIGUI_EVENT_SCROLL,
    ZIGUI_EVENT_KEY,
    ZIGUI_EVENT_TEXT_INPUT,
    ZIGUI_EVENT_IME_COMPOSITION,
    ZIGUI_EVENT_IME_COMMIT,
    ZIGUI_EVENT_IME_CANCEL,
    ZIGUI_EVENT_FILE_DROP,
    ZIGUI_EVENT_TOUCH,
} ZiguiEventType;

typedef struct {
    ZiguiEventType type;
    union {
        struct { uint32_t width; uint32_t height; } resize;
        struct { float x; float y; } mouse_move;
        struct { int button; int pressed; float x; float y; } mouse_button;
        struct { float dx; float dy; } scroll;
        struct { uint16_t keycode; int pressed; int mods_shift; int mods_ctrl; int mods_alt; int mods_super; } key;
        struct { uint32_t codepoint; } text_input;
        struct { uint32_t cursor_start; uint32_t cursor_end; } ime_composition;
        struct { float x; float y; char path[1024]; uint32_t path_len; } file_drop;
        struct { uint32_t id; int phase; float x; float y; } touch;
    };
} ZiguiEvent;

/* Lifecycle */
int zigui_cocoa_init(void);
ZiguiWindowHandle zigui_cocoa_create_window(const char *title, int width, int height);
int zigui_cocoa_poll_events(ZiguiEvent *events, int max_events);
bool zigui_cocoa_should_quit(void);

/* Clipboard */
int zigui_cocoa_get_clipboard(char *buf, int buf_size);
void zigui_cocoa_set_clipboard(const char *text);

/* IME: 查询当前组字中的 marked text (如拼音), 返回写入的 UTF-8 字节数 (无组字返回 0) */
int zigui_cocoa_get_marked_text(char *buf, int buf_size, uint32_t *sel_start, uint32_t *sel_end);

/* Cursor */
void zigui_cocoa_set_cursor(int cursor_type);

#endif
