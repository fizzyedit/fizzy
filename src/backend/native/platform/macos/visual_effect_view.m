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

/*
 * The vibrancy behind a popped-out float's glass: never in the way of a press, which goes to
 * SDL's view above it.
 */
@interface FizzyViewportGlassView : NSVisualEffectView
@end

@implementation FizzyViewportGlassView
- (NSView *)hitTest:(NSPoint)point {
    (void)point;
    return nil;
}
@end

/*
 * A float popped out of the main window into a window of its own (fizzy's viewports): its glass
 * shows the desktop behind it through vibrancy, as the main window's chrome does, so the float's
 * frost reads it the way it reads the app inside the main window — and nothing else of the window
 * does: the clear margin round the glass, where fizzy draws the float's shadow, stays clear. The
 * vibrancy view sits beside SDL's view, under it, in the window's frame view, masked to the
 * glass's rounded rect `inset` points in from the window's edge with `radius` corners; the mask
 * stretches with the window as it is resized. SDL's view stays SDL's window's content view, so
 * SDL tears down the window it made. No AppKit shadow: fizzy draws the float's own. Idempotent:
 * called again, it updates the mask.
 *
 * Both functions are called from the frame loop, outside any autorelease pool of SDL's: without
 * their own, what AppKit autoreleases here (the subview arrays among it) was never released, and
 * the window SDL closed stayed alive in the window server.
 */
void fizzy_macos_viewport_glass(void *nswindow, void *main_nswindow, double inset, double radius, long material) {
    @autoreleasepool {
        NSWindow *window = (__bridge NSWindow *)nswindow;
        if (window == nil) return;
        /* The vibrancy reads light or dark by the window's appearance: the main window's, which
         * follows the app's theme, not the system's. */
        NSWindow *main = (__bridge NSWindow *)main_nswindow;
        if (main != nil) [window setAppearance:[main appearance]];
        [window setOpaque:NO];
        [window setBackgroundColor:[NSColor clearColor]];
        [window setHasShadow:NO];
        /* No OS animation as it shows or closes: it appears and goes exactly where its float is
         * drawn, in the frame it changes in. AppKit's show and close animations never finished
         * under fizzy's frame loop, and the window they stood in for stayed on screen — shrunk
         * while the float was out, and after it had gone, where it first opened. */
        [window setAnimationBehavior:NSWindowAnimationBehaviorNone];
        NSView *content = [window contentView];
        NSView *frame = [content superview];
        if (content == nil || frame == nil) return;
        NSVisualEffectView *effect = nil;
        for (NSView *v in [frame subviews]) {
            if ([v isKindOfClass:[FizzyViewportGlassView class]]) effect = (NSVisualEffectView *)v;
        }
        if (effect == nil) {
            effect = [[FizzyViewportGlassView alloc] initWithFrame:[content frame]];
            [effect setBlendingMode:NSVisualEffectBlendingModeBehindWindow];
            [effect setState:NSVisualEffectStateActive];
            [effect setAutoresizingMask:NSViewWidthSizable | NSViewHeightSizable];
            [frame addSubview:effect positioned:NSWindowBelow relativeTo:content];
#if !__has_feature(objc_arc)
            /* Held by the frame view now; this file is built without ARC. */
            [effect release];
#endif
        }
        [effect setFrame:[content frame]];
        [effect setMaterial:(NSVisualEffectMaterial)material];
        const CGFloat in = (CGFloat)inset;
        const CGFloat r = (CGFloat)radius;
        const CGFloat edge = in + r;
        NSImage *mask = [NSImage imageWithSize:NSMakeSize(edge * 2 + 1, edge * 2 + 1)
                                       flipped:NO
                                drawingHandler:^BOOL(NSRect dst) {
                                    [[NSColor blackColor] set];
                                    [[NSBezierPath bezierPathWithRoundedRect:NSInsetRect(dst, in, in) xRadius:r yRadius:r] fill];
                                    return YES;
                                }];
        [mask setCapInsets:NSEdgeInsetsMake(edge, edge, edge, edge)];
        [mask setResizingMode:NSImageResizingModeStretch];
        [effect setMaskImage:mask];
    }
}

/* Undo `fizzy_macos_viewport_glass` before SDL destroys the window: the vibrancy view gone, and
 * its Window menu item (`fizzy_macos_viewport_windows_item`). */
void fizzy_macos_viewport_unglass(void *nswindow) {
    @autoreleasepool {
        NSWindow *window = (__bridge NSWindow *)nswindow;
        if (window == nil) return;
        [NSApp removeWindowsItem:window];
        NSView *frame = [[window contentView] superview];
        if (frame == nil) return;
        NSArray *views = [[frame subviews] copy];
        for (NSView *v in views) {
            if ([v isKindOfClass:[FizzyViewportGlassView class]]) [v removeFromSuperview];
        }
#if !__has_feature(objc_arc)
        [views release];
#endif
    }
}

/*
 * A popped-out float's window stays over the main window, as a window the main one owns does on
 * Windows — without being made its child window, which AppKit would move with it (the pop-out
 * plan's decision 2: the main window moving leaves the windows that came out of it where they
 * are). SDL orders a window it shows without activating it *below* the key window, the main one:
 * this orders it back above, and again whenever the main window has come in front of it (a press
 * on the main window brings it forward). Cheap when nothing is out of order: one comparison of the
 * app's window order. Other apps' windows still go over it, as over the main window.
 */
void fizzy_macos_viewport_keep_above(void *nswindow, void *main_nswindow) {
    @autoreleasepool {
        NSWindow *window = (__bridge NSWindow *)nswindow;
        NSWindow *main = (__bridge NSWindow *)main_nswindow;
        if (window == nil || main == nil) return;
        if (![window isVisible] || ![main isVisible] || [main isMiniaturized]) return;
        if ([window orderedIndex] < [main orderedIndex]) return;
        [window orderWindow:NSWindowAbove relativeTo:[main windowNumber]];
    }
}

/*
 * A popped-out float's window in the Window menu — and so in the Dock's menu for the app —
 * called `title`, as a titled window is listed by itself: AppKit lists no borderless window
 * unasked. Again whenever its title changes (the view it shows). `fizzy_macos_viewport_unglass`
 * takes it out.
 */
void fizzy_macos_viewport_windows_item(void *nswindow, const char *title) {
    @autoreleasepool {
        NSWindow *window = (__bridge NSWindow *)nswindow;
        if (window == nil || title == NULL) return;
        NSString *t = [NSString stringWithUTF8String:title];
        if (t == nil) return;
        [window setExcludedFromWindowsMenu:NO];
        [NSApp changeWindowsItem:window title:t filename:NO];
    }
}
