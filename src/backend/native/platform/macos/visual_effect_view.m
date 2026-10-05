#import <AppKit/AppKit.h>
#import <QuartzCore/CAGradientLayer.h>
#import <QuartzCore/CAShapeLayer.h>
#import <QuartzCore/CATransaction.h>

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
#import <objc/message.h>
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
            /* Full screen in a Space of its own, as the main window goes: the main window's monitor
             * follows it there and back (`macos_monitor.watch`, `window_monitor.m`). */
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
        /* Either in a fullscreen Space of its own: the two are on different Spaces, and ordering
         * one against the other would pull it across. */
        if ((([window styleMask] | [main styleMask]) & NSWindowStyleMaskFullScreen) != 0) return;
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

/* The identifier the carry window's Liquid Glass goes by (`carryLiquidGlass`). */
static NSString *const carry_glass_id = @"fizzy.carry.glass";

/*
 * Liquid Glass's lens: what is behind it refracted through it, unblurred, bent and drawn in at its
 * rim — a drop of water, as the app's own glass is (`core.LiquidField`). AppKit's public styles are
 * both frosted (Regular dark, Clear light); this is one of the glass's private variants
 * (`_variant`, 2 by default), measured on macOS 26.5 over a striped window, in the window and
 * behind it alike: 11 the lens, 6 a bright frost, 13 no glass at all. Set only on the macOS it was
 * measured on — a variant renumbered later would leave the carried view with no glass — and only
 * where the setter is there.
 */
static const long carry_glass_lens_variant = 11;
/* The glass's own variant, its Clear style's frost: what a window's material is closest to. */
static const long carry_glass_frost_variant = 2;

static void carryGlassVariant(NSView *glass, long variant) {
    if ([[NSProcessInfo processInfo] operatingSystemVersion].majorVersion != 26) return;
    SEL set_variant = sel_registerName("set_variant:");
    if (![glass respondsToSelector:set_variant]) return;
    ((void (*)(id, SEL, long))objc_msgSend)(glass, set_variant, variant);
}

static void carryGlassLens(NSView *glass) {
    carryGlassVariant(glass, carry_glass_lens_variant);
}

/*
 * The carry window's material from macOS 26: Apple's Liquid Glass (`NSGlassEffectView`) as a lens
 * (`carryGlassLens`), else its Clear style — the light one — with its own rim and its continuous
 * corners, which the window's shape sets (`fizzy_macos_viewport_carry_shape`). Nil before macOS 26,
 * for the vibrancy material instead. Looked up by name, and its properties set by key, so fizzy
 * builds against SDKs from before it: Liquid Glass is the OS's, not the SDK's.
 */
static NSView *carryLiquidGlass(NSRect rect) {
    if (@available(macOS 26.0, *)) {
        Class cls = NSClassFromString(@"NSGlassEffectView");
        if (cls == nil) return nil;
        NSView *glass = [[cls alloc] initWithFrame:rect];
        if (glass == nil) return nil;
        /* NSGlassEffectViewStyleClear. */
        [glass setValue:@(1) forKey:@"style"];
        carryGlassLens(glass);
        [glass setIdentifier:carry_glass_id];
        [glass setAutoresizingMask:NSViewWidthSizable | NSViewHeightSizable];
#if !__has_feature(objc_arc)
        [glass autorelease];
#endif
        return glass;
    }
    return nil;
}

/*
 * A window that carries a view past every window of the app's, over the desktop
 * (`SDLBackend.viewportOpenCarry`): a round window of its own — Liquid Glass from macOS 26
 * (`carryLiquidGlass`), the main window's material before — in the shape of what is carried
 * (`fizzy_macos_viewport_carry_shape`), the OS's shadow round it — the pointer passing through it
 * to what is under it, above every window (a pop-up menu's level), on every Space, in no window list
 * or switcher, and no OS animation.
 */
void fizzy_macos_viewport_carry(void *nswindow, void *main_nswindow, long material) {
    @autoreleasepool {
        NSWindow *window = (__bridge NSWindow *)nswindow;
        if (window == nil) return;
        NSWindow *main = (__bridge NSWindow *)main_nswindow;
        if (main != nil) [window setAppearance:[main appearance]];
        [window setOpaque:NO];
        [window setBackgroundColor:[NSColor clearColor]];
        /* The OS's shadow, round the material's shape (`fizzy_macos_viewport_carry_shape`). */
        [window setHasShadow:YES];
        NSView *content = [window contentView];
        NSView *frame = [content superview];
        if (content != nil && frame != nil) {
            NSView *glass = carryLiquidGlass([content frame]);
            if (glass != nil) {
                [frame addSubview:glass positioned:NSWindowBelow relativeTo:content];
            } else {
                NSVisualEffectView *effect = [[FizzyViewportGlassView alloc] initWithFrame:[content frame]];
                [effect setBlendingMode:NSVisualEffectBlendingModeBehindWindow];
                [effect setState:NSVisualEffectStateActive];
                [effect setMaterial:(NSVisualEffectMaterial)material];
                [effect setAutoresizingMask:NSViewWidthSizable | NSViewHeightSizable];
                [frame addSubview:effect positioned:NSWindowBelow relativeTo:content];
#if !__has_feature(objc_arc)
                [effect release];
#endif
            }
        }
        [window setIgnoresMouseEvents:YES];
        [window setAnimationBehavior:NSWindowAnimationBehaviorNone];
        [window setLevel:NSPopUpMenuWindowLevel];
        [window setExcludedFromWindowsMenu:YES];
        [window setCollectionBehavior:NSWindowCollectionBehaviorCanJoinAllSpaces | NSWindowCollectionBehaviorTransient |
                                      NSWindowCollectionBehaviorIgnoresCycle | NSWindowCollectionBehaviorFullScreenAuxiliary];
    }
}

/*
 * Points from a titled window's left edge past its traffic lights: the zoom button's right edge,
 * and as much again as the close button stands in from the window's edge. 0 with none showing.
 */
double fizzy_macos_window_buttons_width(void *nswindow) {
    @autoreleasepool {
        NSWindow *window = (__bridge NSWindow *)nswindow;
        if (window == nil) return 0;
        NSButton *close = [window standardWindowButton:NSWindowCloseButton];
        NSButton *zoom = [window standardWindowButton:NSWindowZoomButton];
        if (close == nil || zoom == nil || [zoom isHidden] || [zoom superview] == nil) return 0;
        const NSRect c = [close convertRect:[close bounds] toView:nil];
        const NSRect z = [zoom convertRect:[zoom bounds] toView:nil];
        return NSMaxX(z) + NSMinX(c);
    }
}

/*
 * A titled window's corner radius, points — what the carried glass grows into as a float's window
 * opens out of it. AppKit says it nowhere; measured from the windows' own pictures: 16 points from
 * macOS 26, 10 before.
 */
double fizzy_macos_window_corner_radius(void) {
    /* A titled window with a compact toolbar (`fizzy_macos_window_liquid_glass`, macOS 26): 20; a
     * titled window with none, 16 — measured from the windows' own pictures. */
    if (@available(macOS 26.0, *)) return 20;
    return 10;
}

/*
 * The carry window's Liquid Glass as the lens (`carryGlassLens`) or as frost — a float's window
 * growing out of it is frost, as its own material is. Nothing where it is not Liquid Glass.
 */
void fizzy_macos_viewport_carry_lens(void *nswindow, int lens) {
    @autoreleasepool {
        NSWindow *window = (__bridge NSWindow *)nswindow;
        if (window == nil) return;
        NSView *frame = [[window contentView] superview];
        for (NSView *v in [frame subviews]) {
            if (![[v identifier] isEqualToString:carry_glass_id]) continue;
            carryGlassVariant(v, lens ? carry_glass_lens_variant : carry_glass_frost_variant);
        }
    }
}

/*
 * The drag's glass as one overlay of Liquid Glass (macOS 26): a window over a whole display
 * (`SDLBackend.viewportOpenOverlay`) holding an `NSGlassEffectContainerView`, its pieces of glass
 * one view each, which the container runs together where they come within its spacing — the
 * carried drop into the bubble it is aimed at, its head into its tail. Under SDL's view, which holds
 * what only fizzy draws: the carried photograph.
 */
@interface FizzyOverlayGlassHolder : NSView
@end

@implementation FizzyOverlayGlassHolder
/* From the top left, as fizzy places the glass. */
- (BOOL)isFlipped {
    return YES;
}
- (NSView *)hitTest:(NSPoint)point {
    (void)point;
    return nil;
}
@end

/* The overlay's two layers of glass, under and over (`fizzy_macos_viewport_overlay_glass`), and
 * the window's colour beneath them both. */
static NSString *const overlay_glass_ids[2] = {@"fizzy.overlay.glass.under", @"fizzy.overlay.glass.over"};
static NSString *const overlay_fill_id = @"fizzy.overlay.fill";

/* Whether the OS has Liquid Glass, and the container that merges it: macOS 26. */
int fizzy_macos_liquid_glass_available(void) {
    if (@available(macOS 26.0, *)) {
        return NSClassFromString(@"NSGlassEffectView") != nil && NSClassFromString(@"NSGlassEffectContainerView") != nil;
    }
    return 0;
}

void fizzy_macos_viewport_overlay(void *nswindow, void *main_nswindow) {
    @autoreleasepool {
        NSWindow *window = (__bridge NSWindow *)nswindow;
        if (window == nil) return;
        NSWindow *main = (__bridge NSWindow *)main_nswindow;
        if (main != nil) [window setAppearance:[main appearance]];
        [window setOpaque:NO];
        [window setBackgroundColor:[NSColor clearColor]];
        /* Clear but for its glass, which draws its own edge: no window shadow round the display. */
        [window setHasShadow:NO];
        NSView *content = [window contentView];
        NSView *frame = [content superview];
        Class container_class = NSClassFromString(@"NSGlassEffectContainerView");
        /* From the bottom, each added directly under SDL's view so over the one before: the lens,
         * frost — two layers of the same glass, crossfaded to blend two of its materials — and the
         * window's colour over them (`fizzy_macos_viewport_overlay_glass`). */
        for (int k = 0; k < 3 && content != nil && frame != nil; k++) {
            if (k == 2) {
                FizzyOverlayGlassHolder *fill = [[FizzyOverlayGlassHolder alloc] initWithFrame:[content frame]];
                [fill setIdentifier:overlay_fill_id];
                [fill setAutoresizingMask:NSViewWidthSizable | NSViewHeightSizable];
                [fill setWantsLayer:YES];
                [frame addSubview:fill positioned:NSWindowBelow relativeTo:content];
#if !__has_feature(objc_arc)
                [fill release];
#endif
                continue;
            }
            if (container_class == nil) continue;
            NSView *container = [[container_class alloc] initWithFrame:[content frame]];
            [container setIdentifier:overlay_glass_ids[k]];
            [container setAutoresizingMask:NSViewWidthSizable | NSViewHeightSizable];
            FizzyOverlayGlassHolder *holder = [[FizzyOverlayGlassHolder alloc] initWithFrame:[container bounds]];
            [holder setAutoresizingMask:NSViewWidthSizable | NSViewHeightSizable];
            [container setValue:holder forKey:@"contentView"];
            [frame addSubview:container positioned:NSWindowBelow relativeTo:content];
#if !__has_feature(objc_arc)
            [holder release];
            [container release];
#endif
        }
        [window setIgnoresMouseEvents:YES];
        [window setAnimationBehavior:NSWindowAnimationBehaviorNone];
        [window setLevel:NSPopUpMenuWindowLevel];
        [window setExcludedFromWindowsMenu:YES];
        [window setCollectionBehavior:NSWindowCollectionBehaviorCanJoinAllSpaces | NSWindowCollectionBehaviorTransient |
                                      NSWindowCollectionBehaviorIgnoresCycle | NSWindowCollectionBehaviorFullScreenAuxiliary];
    }
}

/* A piece of the overlay's glass, as `SDLBackend.GlassShape` lays it out: points from the window's
 * top left. */
typedef struct {
    double x, y, w, h, radius, lit, alpha;
} FizzyGlassShape;

/* What the overlay's glass is, as `SDLBackend.GlassLook` lays it out: each layer's variant and
 * style, how much of the over one there is, how much glass there is at all, the window's colour
 * over the lens (its opacity last), what a lit piece goes toward (how far last), and each piece's
 * clearing bevel (`core.glass_look.band`): a share of its shorter half, at most a cap in points,
 * clear for a share of that. */
typedef struct {
    long under_variant, under_style, over_variant, over_style;
    double over_share;
    double glass;
    double fill[4];
    double lit_toward[4];
    double bevel, bevel_cap, bevel_clear;
} FizzyGlassLook;

/*
 * The window's colour in the overlay's glass: one shape layer for the union of every piece that
 * is all there (the first), so where pieces overlap — the carried drop's head and tail, the drop
 * snapped onto a bubble — the colour is drawn once, as the glass runs them into one; a layer of
 * its own for a piece still coming or going (its opacity its own), and for a lit piece, its light
 * over the union toward `lit_toward`. A layer per piece drew overlaps twice: the tail read as a
 * darker circle inside the head (the user). Over the lens and the frost, faded out across each
 * piece's clearing bevel (`overlayBevelMask`): under the lens it was a disc the lens bent, where the
 * surface being dragged over should be; flat over all the glass it muted the rim's shine; under the
 * frost, the frost's light lifted it, and the glass grew darker as it went at the top.
 * Nothing between pieces where the glass bridges them: a neck drawn there showed past the bridge
 * as a dark bar.
 */
static void overlayFill(NSView *holder, const FizzyGlassShape *shapes, long n, double spacing, const FizzyGlassLook *look) {
    (void)spacing;
    CALayer *root = [holder layer];
    if (root == nil) return;
    [root setGeometryFlipped:YES];
    NSMutableArray<CALayer *> *pool = [NSMutableArray arrayWithArray:[root sublayers] ?: @[]];
    while ([pool count] < (NSUInteger)(n + 1)) {
        CAShapeLayer *layer = [CAShapeLayer layer];
        [root addSublayer:layer];
        [pool addObject:layer];
    }
    const double opacity = fmin(fmax(look->fill[3], 0), 1);
    const double lit_amount = fmin(fmax(look->lit_toward[3], 0), 1);
    CGColorSpaceRef srgb = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
    CGMutablePathRef whole = CGPathCreateMutable();
    for (long i = 0; i < n; i++) {
        const FizzyGlassShape a = shapes[i];
        const double ra = fmin(a.radius, fmin(a.w, a.h) / 2);
        const CGRect rect = CGRectMake(a.x, a.y, a.w, a.h);
        CAShapeLayer *layer = (CAShapeLayer *)pool[(NSUInteger)i + 1];
        const double mix = lit_amount * fmin(fmax(a.lit, 0), 1);
        const BOOL coming = a.alpha < 0.99;
        if (!coming && a.alpha > 0.01) CGPathAddRoundedRect(whole, NULL, rect, ra, ra);
        double alpha = 0;
        CGFloat comps[4] = {0, 0, 0, 0};
        if (coming) {
            /* Its own colour, at its own opacity, lit as it is. */
            alpha = opacity + mix * (1 - opacity);
            comps[0] = (CGFloat)(look->fill[0] + (look->lit_toward[0] - look->fill[0]) * mix);
            comps[1] = (CGFloat)(look->fill[1] + (look->lit_toward[1] - look->fill[1]) * mix);
            comps[2] = (CGFloat)(look->fill[2] + (look->lit_toward[2] - look->fill[2]) * mix);
        } else if (mix > 0.004) {
            /* Its light, over the union's colour. */
            alpha = mix;
            comps[0] = (CGFloat)look->lit_toward[0];
            comps[1] = (CGFloat)look->lit_toward[1];
            comps[2] = (CGFloat)look->lit_toward[2];
        }
        comps[3] = (CGFloat)alpha;
        [layer setHidden:alpha <= 0.004 || a.alpha <= 0.01];
        if ([layer isHidden]) continue;
        [layer setFrame:[root bounds]];
        CGPathRef path = CGPathCreateWithRoundedRect(rect, ra, ra, NULL);
        [layer setPath:path];
        CGPathRelease(path);
        CGColorRef color = CGColorCreate(srgb, comps);
        [layer setFillColor:color];
        CGColorRelease(color);
        [layer setOpacity:coming ? (float)fmin(fmax(a.alpha, 0), 1) : 1];
    }
    CAShapeLayer *union_layer = (CAShapeLayer *)pool[0];
    [union_layer setFrame:[root bounds]];
    [union_layer setPath:whole];
    [union_layer setFillRule:kCAFillRuleNonZero];
    [union_layer setHidden:opacity <= 0.004];
    const CGFloat union_comps[4] = {(CGFloat)look->fill[0], (CGFloat)look->fill[1], (CGFloat)look->fill[2], (CGFloat)opacity};
    CGColorRef union_color = CGColorCreate(srgb, union_comps);
    [union_layer setFillColor:union_color];
    CGColorRelease(union_color);
    CGPathRelease(whole);
    CGColorSpaceRelease(srgb);
    for (NSUInteger i = (NSUInteger)n + 1; i < [pool count]; i++) [pool[i] setHidden:YES];
}

/* One layer of the overlay's glass: a view per shape in `container`'s holder, made as needed and
 * kept for the next frame, the rest hidden; all of them `variant` and `style`. */
static void overlayGlassLayer(NSView *container, const FizzyGlassShape *shapes, long n, double spacing, long variant, long style) {
    NSView *holder = [container valueForKey:@"contentView"];
    if (holder == nil) return;
    ((void (*)(id, SEL, CGFloat))objc_msgSend)(container, sel_registerName("setSpacing:"), (CGFloat)spacing);
    NSArray<NSView *> *pool = [[holder subviews] copy];
    const SEL set_radius = sel_registerName("setCornerRadius:");
    const SEL get_variant = sel_registerName("_variant");
    for (long i = 0; i < n; i++) {
        NSView *glass = (NSUInteger)i < [pool count] ? pool[(NSUInteger)i] : nil;
        if (glass == nil) {
            glass = carryLiquidGlass(NSZeroRect);
            if (glass == nil) break;
            [glass setAutoresizingMask:NSViewNotSizable];
            [holder addSubview:glass];
        }
        const FizzyGlassShape sh = shapes[i];
        [glass setHidden:sh.alpha <= 0.01];
        [glass setFrame:NSMakeRect(sh.x, sh.y, sh.w, sh.h)];
        ((void (*)(id, SEL, CGFloat))objc_msgSend)(glass, set_radius, (CGFloat)fmin(sh.radius, fmin(sh.w, sh.h) / 2));
        [glass setAlphaValue:(CGFloat)sh.alpha];
        if ([[glass valueForKey:@"style"] longValue] != style) [glass setValue:@(style) forKey:@"style"];
        if (![glass respondsToSelector:get_variant] || ((long (*)(id, SEL))objc_msgSend)(glass, get_variant) != variant)
            carryGlassVariant(glass, variant);
    }
    for (NSUInteger i = (NSUInteger)(n < 0 ? 0 : n); i < [pool count]; i++) [pool[i] setHidden:YES];
}

static CGImageRef bevelImage(double radius, double clear, double feather, double scale, double *edge);

/* A rounded rect's clearing bevel (`bevelImage`), kept by its shape for the frames after: a
 * carried card's corners, which a radial gradient left clear. A few kept at a time — a shape
 * morphing between a drop and a card makes a new one each frame. */
static CGImageRef overlayBevelImage(double radius, double clear, double feather, double scale, double *edge) {
    static NSMutableDictionary<NSString *, id> *kept = nil;
    if (kept == nil) kept = [[NSMutableDictionary alloc] init];
    NSString *key = [NSString stringWithFormat:@"%.2f/%.2f/%.2f/%.2f", radius, clear, feather, scale];
    *edge = ceil(clear + feather + radius);
    id image = [kept objectForKey:key];
    if (image != nil) return (__bridge CGImageRef)image;
    CGImageRef made = bevelImage(radius, clear, feather, scale, edge);
    if (made == NULL) return NULL;
    if ([kept count] >= 16) [kept removeAllObjects];
    [kept setObject:(__bridge id)made forKey:key];
    CGImageRelease(made);
    return (__bridge CGImageRef)[kept objectForKey:key];
}

/*
 * `view`'s layer faded out across each piece's clearing bevel (`core.glass_look.band`, from
 * `look`): a mask with a slot per piece, opaque in its middle and clear along its edge — a share of
 * its shorter half, at most a cap in points, so the band hugs the rim of a small piece — so the
 * glass's rim is the clear lens beneath, bending the surface behind it, its rim light bright, and
 * only its middle takes the frost and the colour, as the app's own glass does. A round piece's slot
 * is a radial gradient; a rounded rect's, the bevel's nine-sliced image (`overlayBevelImage`). On
 * the frost's container, not on each piece, so the container still runs the pieces together; a
 * bridge between two, near both their edges, stays clear. The colour's view masked the same way.
 */
static void overlayBevelMask(NSView *view, const FizzyGlassShape *shapes, long n, const FizzyGlassLook *look) {
    CALayer *root = [view layer];
    if (root == nil) return;
    CALayer *mask = [root mask];
    if (mask == nil) {
        mask = [CALayer layer];
        [root setMask:mask];
    }
    [mask setFrame:[root bounds]];
    /* The pieces are placed from the top left: a layer flipped already (the colour's holder) is
     * not flipped again. */
    [mask setGeometryFlipped:![root isGeometryFlipped]];
    const double scale = [[view window] backingScaleFactor] > 0 ? [[view window] backingScaleFactor] : 2;
    NSMutableArray<CALayer *> *pool = [NSMutableArray arrayWithArray:[mask sublayers] ?: @[]];
    while ([pool count] < (NSUInteger)(n < 0 ? 0 : n)) {
        CALayer *slot = [CALayer layer];
        CAGradientLayer *g = [CAGradientLayer layer];
        [g setType:kCAGradientLayerRadial];
        [g setStartPoint:CGPointMake(0.5, 0.5)];
        [g setEndPoint:CGPointMake(1, 1)];
        [g setColors:@[(id)[[NSColor blackColor] CGColor], (id)[[NSColor blackColor] CGColor], (id)[[NSColor clearColor] CGColor]]];
        [slot addSublayer:g];
        CALayer *sliced = [CALayer layer];
        [sliced setContentsGravity:kCAGravityResize];
        [slot addSublayer:sliced];
        [mask addSublayer:slot];
        [pool addObject:slot];
    }
    for (long i = 0; i < n; i++) {
        const FizzyGlassShape sh = shapes[i];
        CALayer *slot = pool[(NSUInteger)i];
        CAGradientLayer *g = (CAGradientLayer *)[[slot sublayers] objectAtIndex:0];
        CALayer *sliced = [[slot sublayers] objectAtIndex:1];
        const double r = fmin(sh.w, sh.h) / 2;
        const double band = fmin(look->bevel * fmax(r, 0), look->bevel_cap);
        const double clear = band * look->bevel_clear;
        [slot setHidden:sh.alpha <= 0.01 || r <= clear];
        [slot setFrame:CGRectMake(sh.x, sh.y, sh.w, sh.h)];
        const double corner = fmin(fmax(sh.radius, 0), r);
        double edge = ceil(band + corner);
        CGImageRef image = NULL;
        if (corner < r - 0.5 && 2 * edge + 1 <= 2 * r) image = overlayBevelImage(corner, clear, band - clear, scale, &edge);
        [g setHidden:image != NULL];
        [sliced setHidden:image == NULL];
        if (image != NULL) {
            const CGFloat side = (CGFloat)(2 * edge + 1);
            if ((__bridge id)image != [sliced contents]) [sliced setContents:(__bridge id)image];
            [sliced setContentsScale:(CGFloat)scale];
            [sliced setContentsCenter:CGRectMake(edge / side, edge / side, 1 / side, 1 / side)];
            [sliced setFrame:[slot bounds]];
        } else {
            [g setFrame:[slot bounds]];
            const double outer = r > 0 ? fmax(0, (r - clear) / r) : 0;
            const double inner = r > 0 ? fmin(outer, fmax(0, (r - band) / r)) : 0;
            [g setLocations:@[@0, @(inner), @(outer)]];
        }
    }
    for (NSUInteger i = (NSUInteger)(n < 0 ? 0 : n); i < [pool count]; i++) [pool[i] setHidden:YES];
}

/*
 * The overlay's glass this frame: two layers of the same pieces (`overlayGlassLayer`), the under
 * one `look`'s under material (the lens) whole and the over one its over material (frost) over it
 * at its share, the window's colour over both, frost and colour faded out across each piece's
 * clearing bevel (`overlayBevelMask`) — the glass has no blur to turn, so the way from the clear lens to
 * frost is the frost coming in over it (`Popout.glassLook`), its rim the lens throughout; a layer
 * with nothing to show is hidden, costing nothing. Each layer's pieces alike — the container runs together only glass that is: a piece
 * in the glass's pressed look (`_interactionState`) never merged with its neighbours, so a lit
 * piece is lit in fizzy's picture over it instead (`Popout.glassBase`). Called in the transaction
 * the window's picture is presented in (`SDLBackend.renderPresent`), with implicit animations off,
 * so glass and picture change together.
 */
void fizzy_macos_viewport_overlay_glass(void *nswindow, const FizzyGlassShape *shapes, long n, double spacing, const FizzyGlassLook *look) {
    @autoreleasepool {
        NSWindow *window = (__bridge NSWindow *)nswindow;
        if (window == nil || look == NULL) return;
        NSView *frame = [[window contentView] superview];
        NSView *layers[2] = {nil, nil};
        NSView *fill = nil;
        for (NSView *v in [frame subviews]) {
            for (int k = 0; k < 2; k++) {
                if ([[v identifier] isEqualToString:overlay_glass_ids[k]]) layers[k] = v;
            }
            if ([[v identifier] isEqualToString:overlay_fill_id]) fill = v;
        }
        [CATransaction setDisableActions:YES];
        if (fill != nil) {
            overlayFill(fill, shapes, n, spacing, look);
            overlayBevelMask(fill, shapes, n, look);
        }
        const double share = fmin(fmax(look->over_share, 0), 1);
        const double glass = fmin(fmax(look->glass, 0), 1);
        /* The under layer whole; the over one over it at its share, faded out toward the pieces'
         * edges (`overlayBevelMask`) so the under one's rim shows round it. */
        const double alphas[2] = {glass, share * glass};
        const long variants[2] = {look->under_variant, look->over_variant};
        const long styles[2] = {look->under_style, look->over_style};
        for (int k = 0; k < 2; k++) {
            if (layers[k] == nil) continue;
            const BOOL shows = alphas[k] > 0.01;
            [layers[k] setHidden:!shows];
            [layers[k] setAlphaValue:(CGFloat)alphas[k]];
            overlayGlassLayer(layers[k], shapes, shows ? n : 0, spacing, variants[k], styles[k]);
            if (k == 1) overlayBevelMask(layers[k], shapes, shows ? n : 0, look);
        }
    }
}

/* A titled window's Liquid Glass (`fizzy_macos_window_liquid_glass`), from the bottom: the lens,
 * and in the body frost, the plain blur behind the window and the window's colour; then the colour
 * again over all of it, for the top of the slider. */
enum { window_glass_under, window_glass_over, window_glass_blur, window_glass_fill, window_glass_top, window_glass_parts };
static NSString *const window_glass_ids[window_glass_parts] = {@"fizzy.window.glass.under", @"fizzy.window.glass.over", @"fizzy.window.blur", @"fizzy.window.fill", @"fizzy.window.top"};

static NSView *windowGlassPart(NSWindow *window, int k) {
    NSView *frame = [[window contentView] superview];
    for (NSView *v in [frame subviews]) {
        if ([[v identifier] isEqualToString:window_glass_ids[k]]) return v;
    }
    return nil;
}

/* The plain blur behind a window of Liquid Glass, in its body: the vibrancy fizzy's windows wore
 * before (`platform.window.ns_visual_effect_material`). Never in the way of a press. */
@interface FizzyWindowBlurView : NSVisualEffectView
@end

@implementation FizzyWindowBlurView
- (NSView *)hitTest:(NSPoint)point {
    (void)point;
    return nil;
}
@end

/*
 * A window with a toolbar keeps it in full screen — a bar across the top of the Space, over the
 * app — unless the window's delegate asks for it to hide with the menu bar. SDL's delegate passes
 * on the options AppKit proposes; fizzy's answer, over it, adds the toolbar's hiding where AppKit
 * allows that: in full screen, with the menu bar hiding by itself.
 */
static IMP g_sdl_full_screen_options = NULL;

static NSApplicationPresentationOptions fizzy_full_screen_options(id self, SEL cmd, NSWindow *window, NSApplicationPresentationOptions proposed) {
    typedef NSApplicationPresentationOptions (*OptionsFn)(id, SEL, NSWindow *, NSApplicationPresentationOptions);
    NSApplicationPresentationOptions options = g_sdl_full_screen_options != NULL
        ? ((OptionsFn)g_sdl_full_screen_options)(self, cmd, window, proposed)
        : proposed;
    if ([window toolbar] != nil && (options & NSApplicationPresentationFullScreen) != 0 &&
        (options & NSApplicationPresentationAutoHideMenuBar) != 0)
        options |= NSApplicationPresentationAutoHideToolbar;
    return options;
}

/* Once per delegate class (idempotent): `window`'s toolbar hides with the menu bar in full screen. */
static void windowAutoHidesToolbar(NSWindow *window) {
    id delegate = [window delegate];
    if (delegate == nil) return;
    const SEL sel = @selector(window:willUseFullScreenPresentationOptions:);
    Class cls = [delegate class];
    if (class_getMethodImplementation(cls, sel) == (IMP)fizzy_full_screen_options) return;
    Method existing = class_getInstanceMethod(cls, sel);
    const char *types = existing != NULL ? method_getTypeEncoding(existing) : "Q@:@Q";
    IMP was = class_replaceMethod(cls, sel, (IMP)fizzy_full_screen_options, types);
    if (g_sdl_full_screen_options == NULL) g_sdl_full_screen_options = was;
}

/* Whether `nswindow` stands on Liquid Glass (`fizzy_macos_window_liquid_glass`). */
int fizzy_macos_window_has_liquid_glass(void *nswindow) {
    NSWindow *window = (__bridge NSWindow *)nswindow;
    return window != nil && windowGlassPart(window, window_glass_under) != nil;
}

/*
 * One of fizzy's titled windows — the main window, a float's — as a window of Liquid Glass (macOS
 * 26): beside SDL's view in the window's frame view, under it, the clear lens, and over it the
 * body — frost, the plain blur behind the window, the window's colour — fading out across the
 * window's clearing bevel, so its edge stays the lens bending the desktop; then the colour over
 * all of it, which comes in only as the glass goes at the very top.
 * `fizzy_macos_window_liquid_glass_look` sets them each frame from the one slider. The window clear but
 * for them, and a compact toolbar's corners — what macOS 26 rounds a window by is whether it has a
 * toolbar: none, 16 points; compact, 20 (and a 40-point title bar for 32); unified, 27 (and 66).
 * Any vibrancy beside SDL's view (a float's) goes. Once per window; 1 where it is (or was already)
 * Liquid Glass, 0 where the OS has none.
 */
int fizzy_macos_window_liquid_glass(void *nswindow, long blur_material) {
    @autoreleasepool {
        NSWindow *window = (__bridge NSWindow *)nswindow;
        if (window == nil || !fizzy_macos_liquid_glass_available()) return 0;
        if (windowGlassPart(window, window_glass_under) != nil) return 1;
        NSView *content = [window contentView];
        NSView *frame = [content superview];
        if (content == nil || frame == nil) return 0;
        for (NSView *v in [[frame subviews] copy]) {
            if ([v isKindOfClass:[FizzyViewportGlassView class]]) [v removeFromSuperview];
        }
        [window setOpaque:NO];
        [window setBackgroundColor:[NSColor clearColor]];
        /* Each added directly under SDL's view, so over the one before. */
        for (int k = 0; k < window_glass_parts; k++) {
            NSView *part = nil;
            if (k == window_glass_under || k == window_glass_over) {
                part = carryLiquidGlass([content frame]);
                if (part == nil) return 0;
                if (k == window_glass_over) carryGlassVariant(part, carry_glass_frost_variant);
            } else if (k == window_glass_blur) {
                FizzyWindowBlurView *blur = [[FizzyWindowBlurView alloc] initWithFrame:[content frame]];
                [blur setBlendingMode:NSVisualEffectBlendingModeBehindWindow];
                [blur setState:NSVisualEffectStateActive];
                [blur setMaterial:(NSVisualEffectMaterial)blur_material];
                [blur setHidden:YES];
                part = blur;
#if !__has_feature(objc_arc)
                [blur autorelease];
#endif
            } else {
                FizzyOverlayGlassHolder *fill = [[FizzyOverlayGlassHolder alloc] initWithFrame:[content frame]];
                part = fill;
#if !__has_feature(objc_arc)
                [fill autorelease];
#endif
            }
            [part setIdentifier:window_glass_ids[k]];
            [part setAutoresizingMask:NSViewWidthSizable | NSViewHeightSizable];
            /* Its own layer, which keeps the feather's mask: one AppKit lends a view not asking
             * for a layer (the glass, the blur) drops the mask set on it. */
            [part setWantsLayer:YES];
            [frame addSubview:part positioned:NSWindowBelow relativeTo:content];
        }
        if ([window toolbar] == nil) {
            /* Added, a toolbar grows the window by its height to keep the content's area: kept
             * where it was instead, or a float's window — restored from its saved frame each
             * launch — grew by 30 points every time. */
            const NSRect was = [window frame];
            NSToolbar *toolbar = [[NSToolbar alloc] initWithIdentifier:@"fizzy.window"];
            [window setToolbar:toolbar];
            [window setToolbarStyle:NSWindowToolbarStyleUnifiedCompact];
            if (!NSEqualRects([window frame], was)) [window setFrame:was display:NO];
#if !__has_feature(objc_arc)
            [toolbar release];
#endif
        }
        [window setTitlebarSeparatorStyle:NSTitlebarSeparatorStyleNone];
        windowAutoHidesToolbar(window);
        return 1;
    }
}

/* A window's Liquid Glass this frame, as `platform.window.WindowGlass` lays it out
 * (`core.glass_look.Window`): each glass layer's variant and style; the body's frost and blur; how
 * much glass there is; the window's colour (its opacity in the body last) and its opacity over all
 * of it; the window's corner radius, and its clearing bevel — clear, then the body coming in over
 * the feather — in points. */
typedef struct {
    long under_variant, under_style, over_variant, over_style;
    double frost, blur, glass;
    double fill[4];
    double top_fill, radius, clear, feather;
} FizzyWindowGlass;

/*
 * The window's body fading out across its clearing bevel: alpha 0 `rim` points in from the edge,
 * rising on a smoothstep to 1 `feather` points further in, its rounded corners following the window's (and
 * tightening inward, as nested rounded rects do). A small image, nine-sliced — its middle pixel
 * stretched to the window's size — so it is drawn again only when the radius, the band or the
 * window's scale change, never as the window resizes. `edge` is each slice's side, points.
 */
static CGImageRef bevelImage(double radius, double rim, double feather, double scale, double *edge) {
    *edge = ceil(rim + feather + radius);
    const double side = 2 * *edge + 1;
    const size_t px = (size_t)ceil(side * scale);
    CGContextRef ctx = CGBitmapContextCreate(NULL, px, px, 8, 0, NULL, (CGBitmapInfo)kCGImageAlphaOnly);
    if (ctx == NULL) return NULL;
    CGContextScaleCTM(ctx, (CGFloat)scale, (CGFloat)scale);
    CGContextSetBlendMode(ctx, kCGBlendModeCopy);
    const CGRect all = CGRectMake(0, 0, side, side);
    const int steps = 32;
    for (int i = 0; i <= steps; i++) {
        const double t = (double)i / steps;
        const double inset = rim + feather * t;
        const double r = fmax(1, radius - inset * 0.5);
        CGPathRef path = CGPathCreateWithRoundedRect(CGRectInset(all, inset, inset), r, r, NULL);
        CGContextAddPath(ctx, path);
        CGContextSetGrayFillColor(ctx, 0, t * t * (3 - 2 * t));
        CGContextFillPath(ctx);
        CGPathRelease(path);
    }
    CGImageRef image = CGBitmapContextCreateImage(ctx);
    CGContextRelease(ctx);
    return image;
}

/* `layer` masked by the feather (`bevelImage`), the mask kept to its bounds. */
static void windowFeatherMask(CALayer *layer, CGImageRef image, double edge, double scale) {
    CALayer *mask = [layer mask];
    if (image != NULL || mask == nil) {
        if (mask == nil) {
            mask = [CALayer layer];
            [layer setMask:mask];
        }
        const CGFloat side = (CGFloat)(2 * edge + 1);
        [mask setContents:(__bridge id)image];
        [mask setContentsScale:(CGFloat)scale];
        [mask setContentsGravity:kCAGravityResize];
        [mask setContentsCenter:CGRectMake(edge / side, edge / side, 1 / side, 1 / side)];
    }
    if (!CGRectEqualToRect([mask frame], [layer bounds])) [mask setFrame:[layer bounds]];
}

/*
 * `nswindow`'s Liquid Glass this frame (`fizzy_macos_window_liquid_glass`): the lens whole, and the
 * body over it — frost, the plain blur, the window's colour — fading out across the clearing
 * bevel; the glass going at the very top of the slider and the colour over all of it then. Its
 * corners the window's.
 */
void fizzy_macos_window_liquid_glass_look(void *nswindow, const FizzyWindowGlass *g) {
    @autoreleasepool {
        NSWindow *window = (__bridge NSWindow *)nswindow;
        if (window == nil || g == NULL) return;
        NSView *parts[window_glass_parts];
        for (int k = 0; k < window_glass_parts; k++) {
            parts[k] = windowGlassPart(window, k);
            if (parts[k] == nil) return;
        }
        [CATransaction begin];
        [CATransaction setDisableActions:YES];
        CGColorSpaceRef srgb = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
        const double fills[2] = {g->fill[3], g->top_fill};
        NSView *colored[2] = {parts[window_glass_fill], parts[window_glass_top]};
        for (int k = 0; k < 2; k++) {
            const CGFloat comps[4] = {(CGFloat)g->fill[0], (CGFloat)g->fill[1], (CGFloat)g->fill[2], (CGFloat)fmin(fmax(fills[k], 0), 1)};
            CGColorRef color = CGColorCreate(srgb, comps);
            [[colored[k] layer] setBackgroundColor:color];
            CGColorRelease(color);
        }
        CGColorSpaceRelease(srgb);

        /* The bevel's mask, drawn again only when its key changes; the key kept on the frost's mask. */
        const double scale = [window backingScaleFactor] > 0 ? [window backingScaleFactor] : 2;
        NSString *key = [NSString stringWithFormat:@"%.2f/%.2f/%.2f/%.2f", g->radius, g->clear, g->feather, scale];
        CALayer *over_layer = [parts[window_glass_over] layer];
        double edge = ceil(g->clear + g->feather + g->radius);
        CGImageRef bevel = NULL;
        if (over_layer != nil && ![[[over_layer mask] valueForKey:@"fizzyBevel"] isEqual:key]) {
            bevel = bevelImage(g->radius, g->clear, g->feather, scale, &edge);
        }
        if (over_layer != nil) {
            windowFeatherMask(over_layer, bevel, edge, scale);
            [[over_layer mask] setValue:key forKey:@"fizzyBevel"];
        }
        windowFeatherMask([parts[window_glass_fill] layer], bevel, edge, scale);
        if (bevel != NULL) {
            NSImage *mask = [[NSImage alloc] initWithCGImage:bevel size:NSMakeSize(2 * edge + 1, 2 * edge + 1)];
            [mask setCapInsets:NSEdgeInsetsMake(edge, edge, edge, edge)];
            [mask setResizingMode:NSImageResizingModeStretch];
            [(NSVisualEffectView *)parts[window_glass_blur] setMaskImage:mask];
#if !__has_feature(objc_arc)
            [mask release];
#endif
            CGImageRelease(bevel);
        }
        const double blur = fmin(fmax(g->blur, 0), 1);
        [parts[window_glass_blur] setHidden:blur <= 0.01];
        [parts[window_glass_blur] setAlphaValue:(CGFloat)blur];

        const double glass = fmin(fmax(g->glass, 0), 1);
        const double alphas[2] = {glass, fmin(fmax(g->frost, 0), 1) * glass};
        const long variants[2] = {g->under_variant, g->over_variant};
        const long styles[2] = {g->under_style, g->over_style};
        NSView *layers[2] = {parts[window_glass_under], parts[window_glass_over]};
        const SEL set_radius = sel_registerName("setCornerRadius:");
        const SEL get_radius = sel_registerName("cornerRadius");
        const SEL get_variant = sel_registerName("_variant");
        for (int k = 0; k < 2; k++) {
            NSView *v = layers[k];
            [v setHidden:alphas[k] <= 0.01];
            [v setAlphaValue:(CGFloat)alphas[k]];
            if (![v respondsToSelector:get_radius] || ((CGFloat (*)(id, SEL))objc_msgSend)(v, get_radius) != (CGFloat)g->radius)
                ((void (*)(id, SEL, CGFloat))objc_msgSend)(v, set_radius, (CGFloat)g->radius);
            if ([[v valueForKey:@"style"] longValue] != styles[k]) [v setValue:@(styles[k]) forKey:@"style"];
            if (![v respondsToSelector:get_variant] || ((long (*)(id, SEL))objc_msgSend)(v, get_variant) != variants[k])
                carryGlassVariant(v, variants[k]);
        }
        [CATransaction commit];
    }
}

/*
 * The carry window's shape: its material masked to a rounded rect of `radius` points filling the
 * window — a circle for a drop, a card for a tab — and its shadow made again round it. Called in the
 * transaction the window's place and picture change in (`SDLBackend.renderPresent`), so the shape
 * changes with them.
 */
void fizzy_macos_viewport_carry_shape(void *nswindow, double radius, double w, double h, double alpha) {
    @autoreleasepool {
        NSWindow *window = (__bridge NSWindow *)nswindow;
        if (window == nil) return;
        /* Hidden: nothing of it — its clear picture alone left its material showing, square. */
        if (radius < 0) {
            [window setAlphaValue:0];
            return;
        }
        [window setAlphaValue:alpha];
        NSView *frame = [[window contentView] superview];
        if (frame == nil) return;
        NSVisualEffectView *effect = nil;
        NSView *glass = nil;
        for (NSView *v in [frame subviews]) {
            if ([v isKindOfClass:[FizzyViewportGlassView class]]) effect = (NSVisualEffectView *)v;
            if ([[v identifier] isEqualToString:carry_glass_id]) glass = v;
        }
        const CGFloat r = (CGFloat)fmin(radius, fmin(w, h) / 2);
        if (glass != nil) {
            /* Liquid Glass draws its own shape: its corners, and the rim along them. */
            [glass setValue:@(r) forKey:@"cornerRadius"];
        } else if (effect != nil) {
            /* Drawn at the window's size, not stretched: a circle's corners are all of it, and a
             * stretchable image's caps came to more than the window — no mask, the material square. */
            const NSSize size = NSMakeSize(w, h);
            NSImage *mask = [NSImage imageWithSize:size
                                           flipped:NO
                                    drawingHandler:^BOOL(NSRect dst) {
                                        [[NSColor blackColor] set];
                                        [[NSBezierPath bezierPathWithRoundedRect:dst xRadius:r yRadius:r] fill];
                                        return YES;
                                    }];
            [effect setMaskImage:mask];
            [effect displayIfNeeded];
        } else return;
        /* And the picture, SDL's view: what is carried fills the window only to its shape, but a
         * glass's frost writes the rect it reads, a little past the shape — over the app, in the main
         * window, that is the app again; here, the blur of the window's own base, a square round the
         * orb. The window is the shape, all of it. */
        NSView *content = [window contentView];
        if (content != nil) {
            [content setWantsLayer:YES];
            CALayer *layer = [content layer];
            [layer setCornerRadius:r];
            [layer setMasksToBounds:YES];
        }
        [window invalidateShadow];
    }
}
