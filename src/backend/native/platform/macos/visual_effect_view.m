#import <AppKit/AppKit.h>

/**
 * Subclass of NSVisualEffectView that passes hit-testing through to its content subview
 * so right-click and all mouse events go to the subview (SDL). Also overrides
 * menuForEvent: to return nil so the system doesn't show a context menu and
 * delivers rightMouseDown to the hit-tested view.
 */
@interface FizzyVisualEffectView : NSVisualEffectView
@end

@implementation FizzyVisualEffectView

- (NSView *)hitTest:(NSPoint)point {
    NSView *subview = self.subviews.firstObject;
    if (subview != nil && NSPointInRect(point, self.bounds)) {
        /* Always return the content subview so all mouse events (including right-click) are delivered to it (SDL). */
        return subview;
    }
    return [super hitTest:point];
}

- (NSMenu *)menuForEvent:(NSEvent *)event {
    /* Return nil so the system doesn't show a context menu and delivers rightMouseDown to the hit-tested view (SDL). */
    return nil;
}

@end

/*
 * Presses over what fizzy draws in the transparent titlebar's region — a dialog dragged up
 * there, an open menu — are the app's. SDL's view answers -mouseDownCanMoveWindow YES
 * everywhere, so AppKit took every press in that region to move the window and the app never
 * saw it. The app says each frame where it is interactive (`titlebar.zig`); for its window the
 * view under the pointer now answers NO there, as Chromium's and Electron's no-drag regions do,
 * and SDL's own answer everywhere else — the empty strip still drags and double-click zooms.
 */
#import <objc/runtime.h>

static bool (*g_titlebar_interactive_at)(double x_px, double y_px) = NULL;
static void *g_titlebar_window = NULL;
static IMP g_sdl_can_move_window = NULL;

static BOOL fizzy_mouseDownCanMoveWindow(id self, SEL cmd) {
    NSWindow *window = [self window];
    if (window != nil && (__bridge void *)window == g_titlebar_window && g_titlebar_interactive_at != NULL) {
        /* Window coordinates, from the bottom left in points; the app's are from the top left in
         * pixels. The content view is full size, so the window's frame is the content's. */
        NSPoint p = [window mouseLocationOutsideOfEventStream];
        CGFloat s = [window backingScaleFactor];
        CGFloat h = NSHeight([[window contentView] frame]);
        if (g_titlebar_interactive_at(p.x * s, (h - p.y) * s)) return NO;
    }
    if (g_sdl_can_move_window != NULL) return ((BOOL (*)(id, SEL))g_sdl_can_move_window)(self, cmd);
    return YES;
}

/* Once per window (idempotent): answers -mouseDownCanMoveWindow from `interactive_at` for
 * `nswindow`. Replaced on SDL's view class, not swizzled onto the instance (which KVO's own
 * subclassing would fight); other windows get SDL's answer. */
void fizzy_macos_titlebar_hit_test_install(void *nswindow, bool (*interactive_at)(double, double)) {
    g_titlebar_window = nswindow;
    g_titlebar_interactive_at = interactive_at;
    if (g_sdl_can_move_window != NULL) return;
    NSWindow *window = (__bridge NSWindow *)nswindow;
    NSView *view = [window contentView];
    /* Under fizzy's vibrancy wrapper, SDL's view is its first subview. */
    if ([view isKindOfClass:[FizzyVisualEffectView class]] && view.subviews.firstObject != nil) {
        view = view.subviews.firstObject;
    }
    if (view == nil) return;
    g_sdl_can_move_window = class_replaceMethod([view class], @selector(mouseDownCanMoveWindow),
                                                (IMP)fizzy_mouseDownCanMoveWindow, "c@:");
    if (g_sdl_can_move_window == NULL) {
        /* The class only inherited it: NSView's answer is what it gave. */
        g_sdl_can_move_window = class_getMethodImplementation([NSView class], @selector(mouseDownCanMoveWindow));
    }
}
