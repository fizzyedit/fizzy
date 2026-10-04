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
static NSImage *glassMask(double inset, double radius);

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
        /* Titled (`SDLBackend.viewportOpen`): dressed as the main window is — its content under a
         * transparent title bar, the title's text hidden (the float's header shows it), the OS's
         * shadow and corners. Borderless: no AppKit shadow; the float draws its own in the clear
         * margin round its glass. */
        const BOOL titled = ([window styleMask] & NSWindowStyleMaskTitled) != 0;
        if (titled) {
            [window setStyleMask:[window styleMask] | NSWindowStyleMaskFullSizeContentView];
            [window setTitlebarAppearsTransparent:YES];
            [window setTitleVisibility:NSWindowTitleHidden];
        }
        [window setHasShadow:titled];
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
        [effect setMaskImage:glassMask(inset, radius)];
    }
}

/* The glass's rounded rect, `inset` points in from the window's edge with `radius` corners, as a
 * mask that stretches with the window. */
static NSImage *glassMask(double inset, double radius) {
    /* The glass is the whole window, framed by the OS, which rounds its corners: all of it. */
    if (inset <= 0) return nil;
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
    return mask;
}

/*
 * The material behind a popped-out float's glass kept out of `ex, ey, ew, eh` (window points from
 * its top left, a rounded rect of radius `er`): the main window's interior under the window. The
 * main window shows its own material there through a hole it leaves in its picture
 * (`core.FrameTarget.hole`), so the glass shows through itself exactly what it does in the main
 * window; the window's own, over it, tinted it a second time — a step in colour as the float split
 * out. Kept over `kx, ky, kw, kh` all the same — the main window's traffic lights — and, as the
 * caller leaves it out of the rect, a strip along the main window's edges: what AppKit draws there,
 * which the hole does not take away, is blurred rather than sharp through the glass. An empty rect:
 * the whole glass, as `fizzy_macos_viewport_glass` set it. Called inside the transaction the
 * window's place and picture change in (`SDLBackend.renderPresent`), and drawn now, so they change
 * together.
 */
void fizzy_macos_viewport_glass_mask(void *nswindow, double inset, double radius, double ex, double ey, double ew, double eh, double er, double kx, double ky, double kw, double kh) {
    @autoreleasepool {
        NSWindow *window = (__bridge NSWindow *)nswindow;
        if (window == nil) return;
        NSView *frame = [[window contentView] superview];
        if (frame == nil) return;
        NSVisualEffectView *effect = nil;
        for (NSView *v in [frame subviews]) {
            if ([v isKindOfClass:[FizzyViewportGlassView class]]) effect = (NSVisualEffectView *)v;
        }
        if (effect == nil) return;
        if (ew <= 0 || eh <= 0) {
            [effect setMaskImage:glassMask(inset, radius)];
        } else {
            const NSSize size = [effect bounds].size;
            const CGFloat in = (CGFloat)inset;
            const CGFloat r = (CGFloat)radius;
            /* The image's origin is its bottom left; the rects came from the top left. */
            const NSRect cut = NSMakeRect(ex, size.height - ey - eh, ew, eh);
            const NSRect keep = NSMakeRect(kx, size.height - ky - kh, kw, kh);
            const CGFloat cut_r = (CGFloat)er;
            NSImage *mask = [NSImage imageWithSize:size
                                           flipped:NO
                                    drawingHandler:^BOOL(NSRect dst) {
                                        NSBezierPath *glass = in <= 0 ? [NSBezierPath bezierPathWithRect:dst] : [NSBezierPath bezierPathWithRoundedRect:NSInsetRect(dst, in, in) xRadius:r yRadius:r];
                                        [[NSColor blackColor] set];
                                        [glass fill];
                                        [[NSGraphicsContext currentContext] saveGraphicsState];
                                        [[NSGraphicsContext currentContext] setCompositingOperation:NSCompositingOperationClear];
                                        [[NSBezierPath bezierPathWithRoundedRect:cut xRadius:cut_r yRadius:cut_r] fill];
                                        [[NSGraphicsContext currentContext] restoreGraphicsState];
                                        if (keep.size.width > 0 && keep.size.height > 0) {
                                            [glass addClip];
                                            [[NSColor blackColor] set];
                                            NSRectFill(keep);
                                        }
                                        return YES;
                                    }];
            [effect setMaskImage:mask];
        }
        [effect displayIfNeeded];
    }
}

/*
 * Where `nswindow`'s traffic lights are, together: window points from its content's top left (SDL's
 * place for the window). 0 when it has none showing.
 */
int fizzy_macos_window_buttons(void *nswindow, double *x, double *y, double *w, double *h) {
    @autoreleasepool {
        NSWindow *window = (__bridge NSWindow *)nswindow;
        if (window == nil) return 0;
        NSRect all = NSZeroRect;
        const NSWindowButton kinds[3] = {NSWindowCloseButton, NSWindowMiniaturizeButton, NSWindowZoomButton};
        for (int i = 0; i < 3; i++) {
            NSButton *b = [window standardWindowButton:kinds[i]];
            if (b == nil || [b isHidden] || [b superview] == nil) continue;
            const NSRect r = [b convertRect:[b bounds] toView:nil];
            all = NSIsEmptyRect(all) ? r : NSUnionRect(all, r);
        }
        if (NSIsEmptyRect(all)) return 0;
        /* Window coordinates run from the frame's bottom left; SDL's place is the content's top left. */
        const NSRect f = [window frame];
        NSRect content = [window contentRectForFrameRect:f];
        content.origin.x -= f.origin.x;
        content.origin.y -= f.origin.y;
        *x = all.origin.x - content.origin.x;
        *y = (content.origin.y + content.size.height) - (all.origin.y + all.size.height);
        *w = all.size.width;
        *h = all.size.height;
        return 1;
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
