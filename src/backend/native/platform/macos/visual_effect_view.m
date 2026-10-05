#import <AppKit/AppKit.h>
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
    if (@available(macOS 26.0, *)) return 16;
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
        /* The window's colour first, under the glass: what the glass bends and lights, as it does
         * whatever is behind it. */
        if (content != nil && frame != nil) {
            FizzyOverlayGlassHolder *fill = [[FizzyOverlayGlassHolder alloc] initWithFrame:[content frame]];
            [fill setIdentifier:overlay_fill_id];
            [fill setAutoresizingMask:NSViewWidthSizable | NSViewHeightSizable];
            [fill setWantsLayer:YES];
            [frame addSubview:fill positioned:NSWindowBelow relativeTo:content];
#if !__has_feature(objc_arc)
            [fill release];
#endif
        }
        /* Two layers of the same glass, the over one above the under, crossfaded to blend two of
         * the glass's materials (`fizzy_macos_viewport_overlay_glass`). */
        for (int k = 0; k < 2 && content != nil && frame != nil && container_class != nil; k++) {
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
 * under it (its opacity last), and what a lit piece goes toward (how far last). */
typedef struct {
    long under_variant, under_style, over_variant, over_style;
    double over_share;
    double glass;
    double fill[4];
    double lit_toward[4];
} FizzyGlassLook;

/*
 * The window's colour under the overlay's glass: a shape layer per piece, in its shape, lit pieces
 * toward `lit_toward`. Under the glass, not over it: over it, the colour muted the glass's shine
 * all the way up the slider. Nothing between pieces where the glass bridges them: a neck drawn
 * there showed past the glass's bridge as a dark bar (the user's capture).
 */
static void overlayFill(NSView *holder, const FizzyGlassShape *shapes, long n, double spacing, const FizzyGlassLook *look) {
    CALayer *root = [holder layer];
    if (root == nil) return;
    [root setGeometryFlipped:YES];
    NSMutableArray<CALayer *> *pool = [NSMutableArray arrayWithArray:[root sublayers] ?: @[]];
    /* The first is unused (it held the necks). */
    while ([pool count] < (NSUInteger)(n + 1)) {
        CAShapeLayer *layer = [CAShapeLayer layer];
        [root addSublayer:layer];
        [pool addObject:layer];
    }
    const double opacity = fmin(fmax(look->fill[3], 0), 1);
    const double lit_amount = fmin(fmax(look->lit_toward[3], 0), 1);
    CGColorSpaceRef srgb = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
    for (long i = 0; i < n; i++) {
        const FizzyGlassShape a = shapes[i];
        const double ra = fmin(a.radius, fmin(a.w, a.h) / 2);
        CAShapeLayer *layer = (CAShapeLayer *)pool[(NSUInteger)i + 1];
        const double mix = lit_amount * fmin(fmax(a.lit, 0), 1);
        const double alpha = opacity + mix * (1 - opacity);
        [layer setHidden:alpha <= 0.004 || a.alpha <= 0.01];
        [layer setFrame:[root bounds]];
        CGPathRef path = CGPathCreateWithRoundedRect(CGRectMake(a.x, a.y, a.w, a.h), ra, ra, NULL);
        [layer setPath:path];
        CGPathRelease(path);
        const CGFloat comps[4] = {
            (CGFloat)(look->fill[0] + (look->lit_toward[0] - look->fill[0]) * mix),
            (CGFloat)(look->fill[1] + (look->lit_toward[1] - look->fill[1]) * mix),
            (CGFloat)(look->fill[2] + (look->lit_toward[2] - look->fill[2]) * mix),
            (CGFloat)alpha,
        };
        CGColorRef color = CGColorCreate(srgb, comps);
        [layer setFillColor:color];
        CGColorRelease(color);
        [layer setOpacity:(float)fmin(fmax(a.alpha, 0), 1)];
    }
    [pool[0] setHidden:YES];
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

/*
 * The overlay's glass this frame: two layers of the same pieces (`overlayGlassLayer`), the under
 * one `look`'s under material and the over one its over material, crossfaded by its share — the
 * glass has no blur to turn, so the way from the clear lens to heavy frost is a blend of the two
 * materials either side (`Popout.glassLook`); a layer with nothing to show is hidden, costing
 * nothing. Each layer's pieces alike — the container runs together only glass that is: a piece
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
        if (fill != nil) overlayFill(fill, shapes, n, spacing, look);
        const double share = fmin(fmax(look->over_share, 0), 1);
        const double glass = fmin(fmax(look->glass, 0), 1);
        const double alphas[2] = {(1 - share) * glass, share * glass};
        const long variants[2] = {look->under_variant, look->over_variant};
        const long styles[2] = {look->under_style, look->over_style};
        for (int k = 0; k < 2; k++) {
            if (layers[k] == nil) continue;
            const BOOL shows = alphas[k] > 0.01;
            [layers[k] setHidden:!shows];
            [layers[k] setAlphaValue:(CGFloat)alphas[k]];
            overlayGlassLayer(layers[k], shapes, shows ? n : 0, spacing, variants[k], styles[k]);
        }
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
