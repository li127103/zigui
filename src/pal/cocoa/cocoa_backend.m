#import <Cocoa/Cocoa.h>
#import <QuartzCore/QuartzCore.h>
#include "cocoa_backend.h"

/* NSEventType constants (avoid deprecation warnings from old names) */
enum {
    ZG_NSEventTypeLeftMouseDown      = 1,
    ZG_NSEventTypeLeftMouseUp        = 2,
    ZG_NSEventTypeRightMouseDown     = 3,
    ZG_NSEventTypeRightMouseUp       = 4,
    ZG_NSEventTypeMouseMoved         = 5,
    ZG_NSEventTypeLeftMouseDragged   = 6,
    ZG_NSEventTypeRightMouseDragged  = 7,
    ZG_NSEventTypeOtherMouseDown     = 25,
    ZG_NSEventTypeOtherMouseUp       = 26,
    ZG_NSEventTypeKeyDown            = 10,
    ZG_NSEventTypeKeyUp              = 11,
    ZG_NSEventTypeFlagsChanged       = 12,
    ZG_NSEventTypeScrollWheel        = 22,
    ZG_NSEventTypeWindowDidResize    = 104,
};

static bool g_should_quit = false;

/* ── App Delegate ─────────────────────────────────────────────────────────── */

@interface ZiguiAppDelegate : NSObject <NSApplicationDelegate>
@end

@implementation ZiguiAppDelegate

- (NSApplicationTerminateReply)applicationShouldTerminate:(NSApplication *)sender {
    (void)sender;
    g_should_quit = true;
    return NSTerminateCancel;
}

- (BOOL)applicationShouldTerminateAfterLastWindowClosed:(NSApplication *)sender {
    (void)sender;
    return YES;
}

@end

/* ── Window Delegate ──────────────────────────────────────────────────────── */

@interface ZiguiWindowDelegate : NSObject <NSWindowDelegate>
@end

@implementation ZiguiWindowDelegate

- (BOOL)windowShouldClose:(NSWindow *)sender {
    g_should_quit = true;
    [sender orderOut:nil];
    return NO;
}

@end

static ZiguiWindowDelegate *g_window_delegate = nil;

/* ── Lifecycle ────────────────────────────────────────────────────────────── */

int zigui_cocoa_init(void) {
    @autoreleasepool {
        [NSApplication sharedApplication];
        [NSApp setActivationPolicy:NSApplicationActivationPolicyRegular];

        ZiguiAppDelegate *delegate = [[ZiguiAppDelegate alloc] init];
        [NSApp setDelegate:delegate];

        [NSApp activateIgnoringOtherApps:YES];
    }
    return 0;
}

ZiguiWindowHandle zigui_cocoa_create_window(const char *title, int width, int height) {
    ZiguiWindowHandle handle = {0};

    NSUInteger styleMask = NSWindowStyleMaskTitled
                         | NSWindowStyleMaskClosable
                         | NSWindowStyleMaskMiniaturizable
                         | NSWindowStyleMaskResizable;

    NSRect frame = NSMakeRect(0, 0, width, height);
    NSWindow *window = [[NSWindow alloc] initWithContentRect:frame
                                                   styleMask:styleMask
                                                     backing:NSBackingStoreBuffered
                                                       defer:NO];

    /* Content view with CAMetalLayer */
    NSView *contentView = [[NSView alloc] initWithFrame:frame];
    [contentView setWantsLayer:YES];
    [contentView setLayerContentsRedrawPolicy:NSViewLayerContentsRedrawOnSetNeedsDisplay];

    CAMetalLayer *metalLayer = [CAMetalLayer layer];
    metalLayer.frame = contentView.bounds;
    metalLayer.autoresizingMask = kCALayerWidthSizable | kCALayerHeightSizable;
    metalLayer.contentsScale = [[NSScreen mainScreen] backingScaleFactor];
    [contentView setLayer:metalLayer];

    [window setContentView:contentView];

    /* Title */
    NSString *nsTitle = [NSString stringWithUTF8String:title];
    [window setTitle:nsTitle];

    /* Min size */
    [window setContentMinSize:NSMakeSize(200, 150)];

    /* Delegate */
    if (!g_window_delegate) {
        g_window_delegate = [[ZiguiWindowDelegate alloc] init];
    }
    [window setDelegate:g_window_delegate];

    /* Accept mouse-moved events without requiring a button held */
    [window setAcceptsMouseMovedEvents:YES];

    /* Show */
    [window center];
    [window makeKeyAndOrderFront:nil];

    handle.ns_window    = (__bridge void *)window;
    handle.content_view = (__bridge void *)contentView;
    handle.metal_layer  = (__bridge void *)metalLayer;
    handle.width        = (uint32_t)width;
    handle.height       = (uint32_t)height;
    handle.scale_factor = (float)[[NSScreen mainScreen] backingScaleFactor];

    return handle;
}

int zigui_cocoa_poll_events(ZiguiEvent *events, int max_events) {
    __block int count = 0;
    @autoreleasepool {
    NSEvent *event;
    while (count < max_events &&
           (event = [NSApp nextEventMatchingMask:NSEventMaskAny
                                       untilDate:[NSDate distantPast]
                                          inMode:NSDefaultRunLoopMode
                                         dequeue:YES]) != nil) {
        ZiguiEventType type = ZIGUI_EVENT_NONE;
        ZiguiEvent ev;
        memset(&ev, 0, sizeof(ev));

        switch ((int)[event type]) {

        case ZG_NSEventTypeWindowDidResize: {
            NSWindow *w = [event window];
            if (w) {
                NSRect cr = [[w contentView] bounds];
                ev.type = ZIGUI_EVENT_RESIZE;
                ev.resize.width  = (uint32_t)cr.size.width;
                ev.resize.height = (uint32_t)cr.size.height;
                count++;
                events[count - 1] = ev;
            }
            break;
        }

        case ZG_NSEventTypeLeftMouseDown:
        case ZG_NSEventTypeRightMouseDown:
        case ZG_NSEventTypeOtherMouseDown:
        case ZG_NSEventTypeLeftMouseUp:
        case ZG_NSEventTypeRightMouseUp:
        case ZG_NSEventTypeOtherMouseUp: {
            int et = (int)[event type];
            NSPoint loc = [event locationInWindow];
            NSWindow *w = [event window];
            if (!w) break;
            NSRect cr = [[w contentView] bounds];
            ev.type = ZIGUI_EVENT_MOUSE_BUTTON;
            ev.mouse_button.x = (float)loc.x;
            ev.mouse_button.y = (float)(cr.size.height - loc.y);
            ev.mouse_button.pressed = (et == ZG_NSEventTypeLeftMouseDown ||
                                       et == ZG_NSEventTypeRightMouseDown ||
                                       et == ZG_NSEventTypeOtherMouseDown) ? 1 : 0;
            if (et == ZG_NSEventTypeLeftMouseDown || et == ZG_NSEventTypeLeftMouseUp)
                ev.mouse_button.button = 0;
            else if (et == ZG_NSEventTypeRightMouseDown || et == ZG_NSEventTypeRightMouseUp)
                ev.mouse_button.button = 1;
            else
                ev.mouse_button.button = (int)[event buttonNumber];
            count++;
            events[count - 1] = ev;
            break;
        }

        case ZG_NSEventTypeMouseMoved:
        case ZG_NSEventTypeLeftMouseDragged:
        case ZG_NSEventTypeRightMouseDragged: {
            NSPoint loc = [event locationInWindow];
            NSWindow *w = [event window];
            if (!w) break;
            NSRect cr = [[w contentView] bounds];
            ev.type = ZIGUI_EVENT_MOUSE_MOVE;
            ev.mouse_move.x = (float)loc.x;
            ev.mouse_move.y = (float)(cr.size.height - loc.y);
            count++;
            events[count - 1] = ev;
            break;
        }

        case ZG_NSEventTypeScrollWheel: {
            ev.type = ZIGUI_EVENT_SCROLL;
            ev.scroll.dx = (float)[event scrollingDeltaX];
            ev.scroll.dy = (float)[event scrollingDeltaY];
            if ([event hasPreciseScrollingDeltas]) {
                ev.scroll.dx *= 0.1f;
                ev.scroll.dy *= 0.1f;
            }
            count++;
            events[count - 1] = ev;
            break;
        }

        case ZG_NSEventTypeKeyDown:
        case ZG_NSEventTypeKeyUp: {
            ev.type = ZIGUI_EVENT_KEY;
            ev.key.keycode = [event keyCode];
            ev.key.pressed = ((int)[event type] == ZG_NSEventTypeKeyDown) ? 1 : 0;
            NSUInteger flags = [event modifierFlags];
            ev.key.mods_shift = (flags & NSEventModifierFlagShift)   ? 1 : 0;
            ev.key.mods_ctrl  = (flags & NSEventModifierFlagControl) ? 1 : 0;
            ev.key.mods_alt   = (flags & NSEventModifierFlagOption)  ? 1 : 0;
            ev.key.mods_super = (flags & NSEventModifierFlagCommand) ? 1 : 0;
            count++;
            events[count - 1] = ev;

            /* Also emit text input for printable characters */
            if (ev.key.pressed) {
                NSString *chars = [event characters];
                if (chars && [chars length] > 0) {
                    unichar ch = [chars characterAtIndex:0];
                    if (ch >= 32 && ch != 127) {
                        ZiguiEvent tev;
                        memset(&tev, 0, sizeof(tev));
                        tev.type = ZIGUI_EVENT_TEXT_INPUT;
                        tev.text_input.codepoint = (uint32_t)ch;
                        if (count < max_events) {
                            count++;
                            events[count - 1] = tev;
                        }
                    }
                }
            }
            break;
        }

        default:
            break;
        }
    }
    } /* @autoreleasepool */
    return count;
}

bool zigui_cocoa_should_quit(void) {
    return g_should_quit;
}

/* ── Clipboard ────────────────────────────────────────────────────────────── */

int zigui_cocoa_get_clipboard(char *buf, int buf_size) {
    NSPasteboard *pb = [NSPasteboard generalPasteboard];
    NSString *str = [pb stringForType:NSPasteboardTypeString];
    if (!str) return -1;
    const char *utf8 = [str UTF8String];
    if (!utf8) return -1;
    int len = (int)strlen(utf8);
    if (len >= buf_size) len = buf_size - 1;
    memcpy(buf, utf8, len);
    buf[len] = '\0';
    return len;
}

void zigui_cocoa_set_clipboard(const char *text) {
    NSPasteboard *pb = [NSPasteboard generalPasteboard];
    [pb clearContents];
    NSString *str = [NSString stringWithUTF8String:text];
    [pb setString:str forType:NSPasteboardTypeString];
}

/* ── Cursor ───────────────────────────────────────────────────────────────── */

void zigui_cocoa_set_cursor(int cursor_type) {
    NSCursor *cursor;
    switch (cursor_type) {
        case 1:  cursor = [NSCursor IBeamCursor];       break;
        case 2:  cursor = [NSCursor crosshairCursor];   break;
        case 3:  cursor = [NSCursor pointingHandCursor]; break;
        case 4:  cursor = [NSCursor resizeLeftRightCursor]; break;
        case 5:  cursor = [NSCursor resizeUpDownCursor]; break;
        default: cursor = [NSCursor arrowCursor];       break;
    }
    [cursor set];
}
