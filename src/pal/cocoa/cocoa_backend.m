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

/* ── IME 事件队列 ─────────────────────────────────────────────────────────── */
/* NSTextInputClient 回调在事件分发期间同步触发, 产生的事件先入此队列,
   再由 zigui_cocoa_poll_events 排出, 汇入统一事件流。 */

#define ZG_IME_QUEUE_MAX 256
static ZiguiEvent g_ime_queue[ZG_IME_QUEUE_MAX];
static int g_ime_head = 0;
static int g_ime_tail = 0;

static void zgPushImeEvent(ZiguiEvent ev) {
    int next = (g_ime_tail + 1) % ZG_IME_QUEUE_MAX;
    if (next == g_ime_head) return; /* 队列满, 丢弃 */
    g_ime_queue[g_ime_tail] = ev;
    g_ime_tail = next;
}

static int zgDrainImeEvents(ZiguiEvent *out, int max) {
    int n = 0;
    while (g_ime_head != g_ime_tail && n < max) {
        out[n++] = g_ime_queue[g_ime_head];
        g_ime_head = (g_ime_head + 1) % ZG_IME_QUEUE_MAX;
    }
    return n;
}

/* ── 触摸点身份映射 (NSTouch.identity → 稳定 u32 id) ─────────────────────── */

#define ZG_MAX_TOUCHES 16
static struct { const void *identity; uint32_t id; } g_touch_map[ZG_MAX_TOUCHES];
static uint32_t g_next_touch_id = 1;

static uint32_t zgTouchId(const void *identity, int allocate) {
    for (int i = 0; i < ZG_MAX_TOUCHES; i++) {
        if (g_touch_map[i].identity == identity) return g_touch_map[i].id;
    }
    if (!allocate) return 0;
    for (int i = 0; i < ZG_MAX_TOUCHES; i++) {
        if (g_touch_map[i].identity == NULL) {
            g_touch_map[i].identity = identity;
            g_touch_map[i].id = g_next_touch_id++;
            return g_touch_map[i].id;
        }
    }
    return 0; /* 触点满, 丢弃 */
}

static void zgTouchRelease(const void *identity) {
    for (int i = 0; i < ZG_MAX_TOUCHES; i++) {
        if (g_touch_map[i].identity == identity) {
            g_touch_map[i].identity = NULL;
            return;
        }
    }
}

static void zgPushKeyEvent(NSEvent *event, int pressed) {
    ZiguiEvent ev;
    memset(&ev, 0, sizeof(ev));
    ev.type = ZIGUI_EVENT_KEY;
    ev.key.keycode = [event keyCode];
    ev.key.pressed = pressed;
    NSUInteger flags = [event modifierFlags];
    ev.key.mods_shift = (flags & NSEventModifierFlagShift)   ? 1 : 0;
    ev.key.mods_ctrl  = (flags & NSEventModifierFlagControl) ? 1 : 0;
    ev.key.mods_alt   = (flags & NSEventModifierFlagOption)  ? 1 : 0;
    ev.key.mods_super = (flags & NSEventModifierFlagCommand) ? 1 : 0;
    zgPushImeEvent(ev);
}

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
@class ZiguiContentView;
static ZiguiContentView *g_content_view = nil;

/* ── Content View (NSTextInputClient, IME 支持) ───────────────────────────── */

@interface ZiguiContentView : NSView <NSTextInputClient> {
    NSMutableString *_markedText;
    NSRange _selectedRange;
    BOOL _hasMarkedText;
}
- (NSString *)ziguiMarkedText;
@end

@implementation ZiguiContentView

- (instancetype)initWithFrame:(NSRect)frame {
    self = [super initWithFrame:frame];
    if (self) {
        _markedText = [[NSMutableString alloc] init];
        _selectedRange = NSMakeRange(0, 0);
        _hasMarkedText = NO;
        /* 注册文件拖放 */
        [self registerForDraggedTypes:@[ NSPasteboardTypeFileURL ]];
        /* 触摸: 只报告活动触点 ( resting 静止点不上报 ) */
        [self setWantsRestingTouches:NO];
    }
    return self;
}

- (BOOL)acceptsFirstResponder { return YES; }
- (BOOL)canBecomeKeyView { return YES; }

- (BOOL)becomeFirstResponder {
    BOOL ok = [super becomeFirstResponder];
    if (ok) {
        /* 手动轮询事件循环下 AppKit 不会自动激活输入上下文,
           须显式 activate, 否则 interpretKeyEvents 不触发 IME/insertText。 */
        NSTextInputContext *ctx = [self inputContext];
        [ctx activate];
        [ctx invalidateCharacterCoordinates];
    }
    return ok;
}

- (void)keyDown:(NSEvent *)event {
    /* 组字期间按键交给输入法处理, 不向应用层发送原始 KEY 事件,
       避免拼音阶段的退格/方向键被应用误消费。 */
    if (!_hasMarkedText) {
        zgPushKeyEvent(event, 1);
    }
    [self interpretKeyEvents:@[event]];
}

- (void)keyUp:(NSEvent *)event {
    if (!_hasMarkedText) {
        zgPushKeyEvent(event, 0);
    }
}

/* ── NSTextInputClient 协议 ── */

- (void)insertText:(id)string replacementRange:(NSRange)replacementRange {
    (void)replacementRange;
    NSString *str = [string isKindOfClass:[NSAttributedString class]] ? [string string] : (NSString *)string;

    /* 逐码点发送 TEXT_INPUT (处理 UTF-16 代理对) */
    NSUInteger len = [str length];
    NSUInteger i = 0;
    while (i < len) {
        unichar hi = [str characterAtIndex:i];
        uint32_t cp;
        if (hi >= 0xD800 && hi <= 0xDBFF && i + 1 < len) {
            unichar lo = [str characterAtIndex:i + 1];
            if (lo >= 0xDC00 && lo <= 0xDFFF) {
                cp = 0x10000u + (((uint32_t)hi - 0xD800u) << 10) + ((uint32_t)lo - 0xDC00u);
                i += 2;
            } else { cp = hi; i += 1; }
        } else { cp = hi; i += 1; }

        ZiguiEvent ev;
        memset(&ev, 0, sizeof(ev));
        ev.type = ZIGUI_EVENT_TEXT_INPUT;
        ev.text_input.codepoint = cp;
        zgPushImeEvent(ev);
    }

    /* 提交后结束组字状态 */
    if (_hasMarkedText) {
        _hasMarkedText = NO;
        [_markedText setString:@""];
        ZiguiEvent cev;
        memset(&cev, 0, sizeof(cev));
        cev.type = ZIGUI_EVENT_IME_COMMIT;
        zgPushImeEvent(cev);
    }
}

- (void)setMarkedText:(id)string selectedRange:(NSRange)selectedRange replacementRange:(NSRange)replacementRange {
    (void)replacementRange;
    NSString *str = [string isKindOfClass:[NSAttributedString class]] ? [string string] : (NSString *)string;
    [_markedText setString:str];
    _selectedRange = selectedRange;
    _hasMarkedText = YES;

    ZiguiEvent ev;
    memset(&ev, 0, sizeof(ev));
    ev.type = ZIGUI_EVENT_IME_COMPOSITION;
    ev.ime_composition.cursor_start = (uint32_t)selectedRange.location;
    ev.ime_composition.cursor_end = (uint32_t)(selectedRange.location + selectedRange.length);
    zgPushImeEvent(ev);
}

- (void)unmarkText {
    _hasMarkedText = NO;
    [_markedText setString:@""];
    ZiguiEvent ev;
    memset(&ev, 0, sizeof(ev));
    ev.type = ZIGUI_EVENT_IME_CANCEL;
    zgPushImeEvent(ev);
}

- (BOOL)hasMarkedText { return _hasMarkedText; }

- (NSString *)ziguiMarkedText { return _markedText; }

- (NSRange)markedRange {
    return _hasMarkedText ? NSMakeRange(0, _markedText.length) : NSMakeRange(NSNotFound, 0);
}

- (NSRange)selectedRange { return _selectedRange; }

- (NSRect)firstRectForCharacterRange:(NSRange)range actualRange:(NSRangePointer)actualRange {
    (void)range;
    if (actualRange) *actualRange = NSMakeRange(0, 0);
    /* 候选窗定位: 返回视图在屏幕坐标系中的 frame */
    NSRect inWindow = [self convertRect:self.bounds toView:nil];
    return [[self window] convertRectToScreen:inWindow];
}

- (NSUInteger)characterIndexForPoint:(NSPoint)point {
    (void)point;
    return 0;
}

- (NSAttributedString *)attributedSubstringForProposedRange:(NSRange)range actualRange:(NSRangePointer)actualRange {
    (void)range;
    if (actualRange) *actualRange = NSMakeRange(0, 0);
    return nil;
}

- (NSArray *)validAttributesForMarkedText { return @[]; }

- (void)doCommandBySelector:(SEL)selector {
    /* 命令键 (方向/删除等) 的 KEY 事件已在 keyDown 中发出, 此处无需重复处理 */
    (void)selector;
}

/* ── NSDraggingDestination (文件拖放) ── */

- (NSDragOperation)draggingEntered:(id<NSDraggingInfo>)sender {
    (void)sender;
    return NSDragOperationCopy;
}

- (NSDragOperation)draggingUpdated:(id<NSDraggingInfo>)sender {
    (void)sender;
    return NSDragOperationCopy;
}

- (BOOL)performDragOperation:(id<NSDraggingInfo>)sender {
    NSPasteboard *pb = [sender draggingPasteboard];
    NSArray<NSURL *> *urls = [pb readObjectsForClasses:@[ [NSURL class] ]
                                               options:@{ NSPasteboardURLReadingFileURLsOnlyKey: @YES }];
    if (urls.count == 0) return NO;

    /* 拖放坐标 (view 坐标系, 左下原点) → device px (左上原点) */
    NSPoint loc = [sender draggingLocation];
    CGFloat scale = [[self window] backingScaleFactor];
    float dx = (float)(loc.x * scale);
    float dy = (float)((self.bounds.size.height - loc.y) * scale);

    for (NSURL *url in urls) {
        NSString *path = [url path];
        if (!path) continue;
        const char *utf8 = [path fileSystemRepresentation];
        if (!utf8) continue;
        size_t n = strlen(utf8);
        if (n > 1023) n = 1023;

        ZiguiEvent ev;
        memset(&ev, 0, sizeof(ev));
        ev.type = ZIGUI_EVENT_FILE_DROP;
        ev.file_drop.x = dx;
        ev.file_drop.y = dy;
        memcpy(ev.file_drop.path, utf8, n);
        ev.file_drop.path_len = (uint32_t)n;
        zgPushImeEvent(ev);
    }
    return YES;
}

/* ── 触摸事件 (触控板 NSTouch) ── */

- (void)touchesBeganWithEvent:(NSEvent *)event {
    [self zgReportTouches:event nsPhase:NSTouchPhaseBegan zgPhase:0];
}

- (void)touchesMovedWithEvent:(NSEvent *)event {
    [self zgReportTouches:event nsPhase:NSTouchPhaseMoved zgPhase:1];
}

- (void)touchesEndedWithEvent:(NSEvent *)event {
    [self zgReportTouches:event nsPhase:NSTouchPhaseEnded zgPhase:2];
}

- (void)touchesCancelledWithEvent:(NSEvent *)event {
    [self zgReportTouches:event nsPhase:NSTouchPhaseCancelled zgPhase:3];
}

- (void)zgReportTouches:(NSEvent *)event nsPhase:(NSTouchPhase)nsPhase zgPhase:(int)zgPhase {
    CGFloat scale = [[self window] backingScaleFactor];
    for (NSTouch *t in [event touchesMatchingPhase:nsPhase inView:self]) {
        const void *identity = (__bridge const void *)[t identity];
        uint32_t tid = zgTouchId(identity, zgPhase == 0);
        if (tid == 0) continue;
        if (zgPhase == 2 || zgPhase == 3) zgTouchRelease(identity);

        /* normalizedPosition 为 0..1 (左下原点) → 视图 device px (左上原点) */
        NSPoint np = [t normalizedPosition];
        ZiguiEvent ev;
        memset(&ev, 0, sizeof(ev));
        ev.type = ZIGUI_EVENT_TOUCH;
        ev.touch.id = tid;
        ev.touch.phase = zgPhase;
        ev.touch.x = (float)(np.x * self.bounds.size.width * scale);
        ev.touch.y = (float)((1.0 - np.y) * self.bounds.size.height * scale);
        zgPushImeEvent(ev);
    }
}

@end

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

    /* Content view with CAMetalLayer (ZiguiContentView 支持 IME) */
    ZiguiContentView *contentView = [[ZiguiContentView alloc] initWithFrame:frame];
    g_content_view = contentView;
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
    [window makeFirstResponder:contentView];

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
    /* 先排出内部队列 (IME / 文件拖放等回调在 sendEvent 期间同步产生) */
    count += zgDrainImeEvents(&events[count], max_events - count);

    NSEvent *event;
    while (count < max_events &&
           (event = [NSApp nextEventMatchingMask:NSEventMaskAny
                                       untilDate:[NSDate distantPast]
                                          inMode:NSDefaultRunLoopMode
                                         dequeue:YES]) != nil) {
        /* 统一交还 AppKit 分发, 保证标准窗口管理行为可用
           (关闭/最小化/缩放按钮、窗口拖动等)。此前仅键盘事件 sendEvent,
           关闭按钮点击被出队后 AppKit 未处理, windowShouldClose 永不触发。 */
        [NSApp sendEvent:event];

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
            /* locationInWindow 为 points; 渲染器 viewport 为设备像素 (drawableSize),
               Retina 下须乘 backingScaleFactor 才能与绘制坐标对齐 (否则命中检测错位)。 */
            CGFloat scale = [w backingScaleFactor];
            ev.type = ZIGUI_EVENT_MOUSE_BUTTON;
            ev.mouse_button.x = (float)(loc.x * scale);
            ev.mouse_button.y = (float)((cr.size.height - loc.y) * scale);
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
            CGFloat scale = [w backingScaleFactor];
            ev.type = ZIGUI_EVENT_MOUSE_MOVE;
            ev.mouse_move.x = (float)(loc.x * scale);
            ev.mouse_move.y = (float)((cr.size.height - loc.y) * scale);
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
            /* 键事件已在循环顶部 sendEvent 分发 (视图 keyDown:/keyUp: →
               interpretKeyEvents 驱动输入法)。KEY / TEXT_INPUT / IME 事件由
               视图的 NSTextInputClient 回调推入 IME 队列, 此处排出汇入事件流。 */
            count += zgDrainImeEvents(&events[count], max_events - count);
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

int zigui_cocoa_get_marked_text(char *buf, int buf_size, uint32_t *sel_start, uint32_t *sel_end) {
    if (sel_start) *sel_start = 0;
    if (sel_end) *sel_end = 0;
    if (buf_size <= 0) return 0;
    buf[0] = '\0';

    int result = 0;
    @autoreleasepool {
        if (!g_content_view || ![g_content_view hasMarkedText]) return 0;
        NSString *mt = [g_content_view ziguiMarkedText];
        if (!mt || mt.length == 0) return 0;
        const char *utf8 = [mt UTF8String];
        if (!utf8) return 0;
        int len = (int)strlen(utf8);
        if (len >= buf_size) len = buf_size - 1;
        memcpy(buf, utf8, len);
        buf[len] = '\0';
        NSRange sr = [g_content_view selectedRange];
        if (sel_start) *sel_start = (uint32_t)sr.location;
        if (sel_end) *sel_end = (uint32_t)(sr.location + sr.length);
        result = len;
    }
    return result;
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
