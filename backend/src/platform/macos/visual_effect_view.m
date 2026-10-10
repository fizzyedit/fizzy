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

/* SDL's view hands a left press on to SDL — its next responder, SDL's window listener — as it hands
 * on a right one, itself: it inherited NSView's -mouseDown:, which in a full-screen window kept the
 * press. A float's window in full screen took hover, right presses and even left releases, and no
 * left press (the user); traced, the press reached the view and went no further. */
static void fizzy_sdl_view_mouse_down(id self, SEL cmd, NSEvent *event) {
    (void)cmd;
    [[self nextResponder] mouseDown:event];
}

/* Once per window (idempotent): answers -mouseDownCanMoveWindow from `interactive_at` for
 * `nswindow`. Replaced on SDL's view class, not swizzled onto the instance (which KVO's own
 * subclassing would fight); other windows get SDL's answer. And SDL's view passes a left press on
 * itself (`fizzy_sdl_view_mouse_down`), on every window of the app. */
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
    /* Added only where SDL's view has none of its own. */
    class_addMethod([view class], @selector(mouseDown:), (IMP)fizzy_sdl_view_mouse_down, "v@:@");
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

/*
 * A popped-out float's window dressed as the main window is, whatever it stands on — Liquid Glass
 * or vibrancy (`fizzy_macos_viewport_glass`). Skipped with Liquid Glass, a float's window had no
 * shadow, and with it none of the 1-point outline the OS draws round a titled window — dark against
 * a light background, light against a dark one — that the main window has (the user).
 */
static void viewportDress(NSWindow *window, NSWindow *main) {
    /* The vibrancy reads light or dark by the window's appearance: the main window's, which
     * follows the app's theme, not the system's. */
    if (main != nil) [window setAppearance:[main appearance]];
    [window setOpaque:NO];
    [window setBackgroundColor:[NSColor clearColor]];
    /* Titled (`SDLBackend.viewportOpen`): dressed as the main window is — its content under a
     * transparent title bar, the title's text hidden (the float's header shows it), the OS's
     * shadow, outline and corners. Borderless: no AppKit shadow; the float draws its own in the
     * clear margin round its glass. */
    const BOOL titled = ([window styleMask] & NSWindowStyleMaskTitled) != 0;
    if (titled) {
        [window setStyleMask:[window styleMask] | NSWindowStyleMaskFullSizeContentView];
        [window setTitlebarAppearsTransparent:YES];
        [window setTitleVisibility:NSWindowTitleHidden];
        /* Full screen in a Space of its own, as the main window goes: the main window's monitor
         * follows it there and back (`macos_monitor.watch`, `window_monitor.m`). */
    }
    if ([window hasShadow] != titled) [window setHasShadow:titled];
    /* No OS animation as it shows or closes: it appears and goes exactly where its float is
     * drawn, in the frame it changes in. AppKit's show and close animations never finished
     * under fizzy's frame loop, and the window they stood in for stayed on screen — shrunk
     * while the float was out, and after it had gone, where it first opened. */
    [window setAnimationBehavior:NSWindowAnimationBehaviorNone];
}

void fizzy_macos_viewport_dress(void *nswindow, void *main_nswindow) {
    @autoreleasepool {
        NSWindow *window = (__bridge NSWindow *)nswindow;
        if (window == nil) return;
        viewportDress(window, (__bridge NSWindow *)main_nswindow);
    }
}

void fizzy_macos_viewport_glass(void *nswindow, void *main_nswindow, double inset, double radius, long material) {
    @autoreleasepool {
        NSWindow *window = (__bridge NSWindow *)nswindow;
        if (window == nil) return;
        viewportDress(window, (__bridge NSWindow *)main_nswindow);
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
 * A popped-out float's window put over the main window, once (`SDLBackend`): as it first shows —
 * SDL orders a window it shows without activating it *below* the key window, the main one — and as
 * the main window first shows, the app activating at launch bringing it over the floats restored
 * with it. Not kept there: a float's window stacks as any window does (the user) — a press on the
 * main window brings it in front of the floats, and a press on a float brings that one forward. A
 * float kept over the main window came back over it at every press there, and the part of the main
 * window under it could not be worked in.
 */
/* The app's first activation, once it has come (`fizzy_macos_took_first_activation`). AppKit brings
 * the key window — the main one — in front of the app's others as it activates, and at launch that
 * comes after the floats restored with it were put over it: they came up under it (the user). SDL
 * says nothing of it (its listener ignores the first activation), so it is watched for here. */
static int g_first_activation_pending = 0;

void fizzy_macos_watch_first_activation(void) {
    static BOOL watching = NO;
    if (watching) return;
    watching = YES;
    @autoreleasepool {
        __block id token = nil;
        token = [[NSNotificationCenter defaultCenter] addObserverForName:NSApplicationDidBecomeActiveNotification
                                                                  object:nil
                                                                   queue:[NSOperationQueue mainQueue]
                                                              usingBlock:^(__unused NSNotification *note) {
            g_first_activation_pending = 1;
            [[NSNotificationCenter defaultCenter] removeObserver:token];
        }];
#if !__has_feature(objc_arc)
        [token retain];
#endif
    }
}

/* Whether the app's first activation came since this was last asked (`fizzy_macos_watch_first_activation`). */
int fizzy_macos_took_first_activation(void) {
    const int was = g_first_activation_pending;
    g_first_activation_pending = 0;
    return was;
}

void fizzy_macos_viewport_over_main(void *nswindow, void *main_nswindow) {
    @autoreleasepool {
        NSWindow *window = (__bridge NSWindow *)nswindow;
        NSWindow *main = (__bridge NSWindow *)main_nswindow;
        if (window == nil || main == nil) return;
        if (![window isVisible] || ![main isVisible] || [main isMiniaturized]) return;
        /* Either in a fullscreen Space of its own: the two are on different Spaces, and ordering
         * one against the other would pull it across. */
        if ((([window styleMask] | [main styleMask]) & NSWindowStyleMaskFullScreen) != 0) return;
        /* Whatever `orderedIndex` says: it lags the window server just after the stacking changes.
         * At launch the app's activation brought the main window forward, the index still read the
         * float as in front of it, and floats restored with the layout stayed under the main
         * window (the user). Asked only when a float first shows and when the main window is shown
         * or first focused, so ordering it there every time costs nothing. */
        [window orderWindow:NSWindowAbove relativeTo:[main windowNumber]];
    }
}

/*
 * Whether `nswindow` lies under the main window in the app's stacking: a float's window clicked
 * behind it. Not while either is hidden or in a fullscreen Space of its own.
 */
int fizzy_macos_viewport_under_main(void *nswindow, void *main_nswindow) {
    @autoreleasepool {
        NSWindow *window = (__bridge NSWindow *)nswindow;
        NSWindow *main = (__bridge NSWindow *)main_nswindow;
        if (window == nil || main == nil) return 0;
        if (![window isVisible] || ![main isVisible] || [main isMiniaturized]) return 0;
        if ((([window styleMask] | [main styleMask]) & NSWindowStyleMaskFullScreen) != 0) return 0;
        return [window orderedIndex] > [main orderedIndex];
    }
}

/*
 * The windows AppKit holds for the app (`NSApp.windows`), and how many of them are on screen: the
 * health counters' check on windows SDL let go of that something kept alive (`Health.Snapshot`).
 * Asked only when a snapshot is taken.
 */
void fizzy_macos_window_counts(unsigned *all, unsigned *visible) {
    @autoreleasepool {
        NSArray<NSWindow *> *windows = [NSApp windows];
        unsigned shown = 0;
        for (NSWindow *w in windows) if ([w isVisible]) shown++;
        *all = (unsigned)[windows count];
        *visible = shown;
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
static NSString *const overlay_blur_id = @"fizzy.overlay.blur";
static NSString *const overlay_photo_id = @"fizzy.overlay.photo";

/*
 * A plain blur of what is behind the window: Core Animation's backdrop layer, which the OS's own
 * materials are built from, with a Gaussian blur on it and nothing else — none of a material's
 * tint, which pulls everything toward its own grey (`core.glass_look.drop_blur`). Private: nil
 * where the OS has no such layer, or it does not take these, and the glass keeps its frost.
 */
static CALayer *overlayBlurLayer(void) {
    Class backdrop = NSClassFromString(@"CABackdropLayer");
    Class filter = NSClassFromString(@"CAFilter");
    const SEL make = sel_registerName("filterWithType:");
    const SEL server = sel_registerName("setWindowServerAware:");
    if (backdrop == nil || filter == nil || ![filter respondsToSelector:make]) return nil;
    @try {
        CALayer *layer = [backdrop layer];
        /* What is behind the window, not only what is under it in it. */
        if (![layer respondsToSelector:server]) return nil;
        ((void (*)(id, SEL, BOOL))objc_msgSend)(layer, server, YES);
        id blur = ((id (*)(id, SEL, id))objc_msgSend)(filter, make, @"gaussianBlur");
        if (blur == nil) return nil;
        [blur setValue:@(0) forKey:@"inputRadius"];
        [blur setValue:@YES forKey:@"inputNormalizeEdges"];
        [layer setFilters:@[ blur ]];
        return layer;
    } @catch (NSException *e) {
        (void)e;
        return nil;
    }
}

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
                /* The plain blur over the frost's place (`overlayBlurLayer`), sized to the glass each
                 * frame; hidden until then. */
                CALayer *blur_layer = overlayBlurLayer();
                if (blur_layer != nil) {
                    NSView *blur = [[NSView alloc] initWithFrame:NSZeroRect];
                    [blur setIdentifier:overlay_blur_id];
                    [blur setLayer:blur_layer];
                    [blur setWantsLayer:YES];
                    [blur setHidden:YES];
                    [frame addSubview:blur positioned:NSWindowBelow relativeTo:content];
#if !__has_feature(objc_arc)
                    [blur release];
#endif
                }
                /* Over the glass's frost, the carried view's picture (`fizzy_macos_viewport_overlay_photo`):
                 * its content on the drop's frosted glass, as a bubble's icon is on its own. */
                FizzyOverlayGlassHolder *photo = [[FizzyOverlayGlassHolder alloc] initWithFrame:[content frame]];
                [photo setIdentifier:overlay_photo_id];
                [photo setAutoresizingMask:NSViewWidthSizable | NSViewHeightSizable];
                [photo setWantsLayer:YES];
                [frame addSubview:photo positioned:NSWindowBelow relativeTo:content];
#if !__has_feature(objc_arc)
                [photo release];
#endif
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
    double x, y, w, h, radius, lit, alpha, frost;
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
    double blur;
} FizzyGlassLook;

/*
 * The window's colour in the overlay's glass: one shape layer for the union of every piece that
 * is all there (the first), so where pieces overlap — the carried drop's head and tail, the drop
 * snapped onto a bubble — the colour is drawn once, as the glass runs them into one; a layer of
 * its own for a piece still coming or going (its opacity its own), and in a lit piece a soft glow
 * toward `lit_toward`, gone before its edge. A layer per piece drew overlaps twice: the tail read as a
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
        /* Its own colour while it comes or goes, at its own opacity; lit, a soft glow in it,
         * brightest in the middle and gone before the edge — a filled light read as a disc under
         * the glass (the user). */
        CAGradientLayer *glow = (CAGradientLayer *)[[layer sublayers] firstObject];
        if (glow == nil) {
            glow = [CAGradientLayer layer];
            [glow setType:kCAGradientLayerRadial];
            [glow setStartPoint:CGPointMake(0.5, 0.5)];
            [glow setEndPoint:CGPointMake(1, 1)];
            [glow setLocations:@[@0, @0.5, @1]];
            [layer addSublayer:glow];
        }
        const double fill_alpha = coming ? opacity : 0;
        const BOOL lit = mix > 0.004;
        [layer setHidden:a.alpha <= 0.01 || (fill_alpha <= 0.004 && !lit)];
        if ([layer isHidden]) continue;
        [layer setFrame:[root bounds]];
        CGPathRef path = CGPathCreateWithRoundedRect(rect, ra, ra, NULL);
        [layer setPath:path];
        CGPathRelease(path);
        const CGFloat fill_comps[4] = {(CGFloat)look->fill[0], (CGFloat)look->fill[1], (CGFloat)look->fill[2], (CGFloat)fill_alpha};
        CGColorRef fill_color = CGColorCreate(srgb, fill_comps);
        [layer setFillColor:fill_color];
        CGColorRelease(fill_color);
        [glow setHidden:!lit];
        if (lit) {
            [glow setFrame:rect];
            CGColorRef stops[3];
            const double alphas[3] = {0.55 * mix, 0.28 * mix, 0};
            for (int k = 0; k < 3; k++) {
                const CGFloat c[4] = {(CGFloat)look->lit_toward[0], (CGFloat)look->lit_toward[1], (CGFloat)look->lit_toward[2], (CGFloat)alphas[k]};
                stops[k] = CGColorCreate(srgb, c);
            }
            [glow setColors:@[(__bridge id)stops[0], (__bridge id)stops[1], (__bridge id)stops[2]]];
            for (int k = 0; k < 3; k++) CGColorRelease(stops[k]);
        }
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
static void overlayBevelMask(NSView *view, const FizzyGlassShape *shapes, long n, const FizzyGlassLook *look, BOOL by_frost, double ox, double oy) {
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
        /* The frost's own: as much of it as the piece takes (`FizzyGlassShape.frost`) — none over
         * the carried view, a clear lens over its picture. */
        const double frost = by_frost ? fmin(fmax(sh.frost, 0), 1) : 1;
        [slot setHidden:sh.alpha <= 0.01 || r <= clear || frost <= 0.01];
        [slot setOpacity:(float)frost];
        [slot setFrame:CGRectMake(sh.x - ox, sh.y - oy, sh.w, sh.h)];
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
/* Points inside its drop's edge the carried view's picture stops, so the rim stays glass. */
static const double photo_rim = 4;

/* The carried view's picture in the overlay's glass, as `SDLBackend.OverlayPhoto` lays it out. */
typedef struct {
    double x, y, w, h, radius;
    double image[4];
    double fill[4];
    double alpha, blur;
} FizzyOverlayPhoto;

static NSView *overlayPart(NSWindow *window, NSString *ident) {
    NSView *frame = [[window contentView] superview];
    for (NSView *v in [frame subviews]) {
        if ([[v identifier] isEqualToString:ident]) return v;
    }
    return nil;
}

/* The photo's two layers in its holder: the rounded rect it shows in, and the image in that. */
static CALayer *overlayPhotoLayers(NSView *holder, CALayer **image) {
    CALayer *root = [holder layer];
    if (root == nil) return nil;
    [root setGeometryFlipped:YES];
    CALayer *shape = [[root sublayers] firstObject];
    if (shape == nil) {
        shape = [CALayer layer];
        [shape setMasksToBounds:YES];
        [shape setHidden:YES];
        CALayer *pic = [CALayer layer];
        [pic setContentsGravity:kCAGravityResize];
        /* Shrunk to the drop several times over: mipmapped, or every move of a fraction of a pixel
         * picks other pixels of it, and it shimmers. */
        [pic setMinificationFilter:kCAFilterTrilinear];
        [shape addSublayer:pic];
        [root addSublayer:shape];
    }
    *image = [[shape sublayers] firstObject];
    return shape;
}

/*
 * The image of the carried view's picture under overlay `nswindow`'s glass: premultiplied RGBA rows,
 * `w` by `h`, copied into an image the layer keeps; NULL clears it. Set once a drag — after that
 * the picture only moves (`fizzy_macos_viewport_overlay_photo`), nothing presented for it.
 */
void fizzy_macos_viewport_overlay_photo_image(void *nswindow, const unsigned char *rgba, long w, long h) {
    @autoreleasepool {
        NSWindow *window = (__bridge NSWindow *)nswindow;
        if (window == nil) return;
        NSView *holder = overlayPart(window, overlay_photo_id);
        if (holder == nil) return;
        CALayer *image = nil;
        if (overlayPhotoLayers(holder, &image) == nil || image == nil) return;
        [CATransaction setDisableActions:YES];
        if (rgba == NULL || w <= 0 || h <= 0) {
            [image setContents:nil];
            return;
        }
        CFDataRef data = CFDataCreate(NULL, rgba, (CFIndex)(w * h * 4));
        CGDataProviderRef provider = CGDataProviderCreateWithCFData(data);
        CGColorSpaceRef srgb = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
        CGImageRef made = CGImageCreate((size_t)w, (size_t)h, 8, 32, (size_t)w * 4, srgb,
                                        kCGImageAlphaPremultipliedLast | kCGBitmapByteOrderDefault, provider, NULL, false,
                                        kCGRenderingIntentDefault);
        [image setContents:(__bridge id)made];
        if (made != NULL) CGImageRelease(made);
        CGColorSpaceRelease(srgb);
        CGDataProviderRelease(provider);
        CFRelease(data);
    }
}

/*
 * Where the carried view's picture is on overlay `nswindow`'s glass this frame: in its drop's rounded
 * rect, a little inside its rim, on its fill (none, for a picture on frosted glass), its image laid
 * where it is told — fitted to what it shows, so it may reach past the rect, cut off there —
 * `blur` points blurred, as opaque as it is told. NULL hides it. Over the glass's frost, in the
 * same window: it moves with the glass in one transaction, as a window of its own presented every
 * frame did not.
 */
void fizzy_macos_viewport_overlay_photo(void *nswindow, const FizzyOverlayPhoto *p) {
    @autoreleasepool {
        NSWindow *window = (__bridge NSWindow *)nswindow;
        if (window == nil) return;
        NSView *holder = overlayPart(window, overlay_photo_id);
        if (holder == nil) return;
        CALayer *image = nil;
        CALayer *shape = overlayPhotoLayers(holder, &image);
        if (shape == nil || image == nil) return;
        [CATransaction setDisableActions:YES];
        if (p == NULL || p->alpha <= 0.01) {
            [shape setHidden:YES];
            return;
        }
        [shape setHidden:NO];
        /* Inside the drop's rim, which stays its glass. */
        const double in = fmin(photo_rim, fmin(p->w, p->h) / 4);
        [shape setFrame:CGRectMake(p->x + in, p->y + in, fmax(p->w - 2 * in, 1), fmax(p->h - 2 * in, 1))];
        [shape setCornerRadius:fmax(0, fmin(fmax(p->radius - in, 0), fmin(p->w, p->h) / 2 - in))];
        [shape setOpacity:(float)fmin(p->alpha, 1)];
        CGColorSpaceRef srgb = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
        const CGFloat comps[4] = {(CGFloat)p->fill[0], (CGFloat)p->fill[1], (CGFloat)p->fill[2], (CGFloat)p->fill[3]};
        CGColorRef fill = CGColorCreate(srgb, comps);
        [shape setBackgroundColor:fill];
        CGColorRelease(fill);
        CGColorSpaceRelease(srgb);
        [image setFrame:CGRectMake(p->image[0] - in, p->image[1] - in, p->image[2], p->image[3])];
        /* Blurred as the bubbles' glass blurs (`overlayBlurLayer`'s filter, on the picture itself):
         * a plain blur, none of a material's grey — `blur` points of the image as it lies here. */
        const double radius = fmax(p->blur, 0);
        @try {
            if (radius <= 0.01) {
                if ([[image filters] count] > 0) [image setFilters:nil];
            } else {
                if ([[image filters] count] == 0) {
                    Class filter = NSClassFromString(@"CAFilter");
                    const SEL make = sel_registerName("filterWithType:");
                    id blur = (filter != nil && [filter respondsToSelector:make]) ? ((id (*)(id, SEL, id))objc_msgSend)(filter, make, @"gaussianBlur") : nil;
                    /* Not normalised at its edges, as the backdrop's is: over a picture mostly clear —
                     * a view captured alone — that turned everything clear in it black. */
                    if (blur != nil) [image setFilters:@[ blur ]];
                }
                NSNumber *was = [image valueForKeyPath:@"filters.gaussianBlur.inputRadius"];
                if ([[image filters] count] > 0 && (was == nil || fabs([was doubleValue] - radius) > 0.01))
                    [image setValue:@(radius) forKeyPath:@"filters.gaussianBlur.inputRadius"];
            }
        } @catch (NSException *e) {
            (void)e;
        }
    }
}

/*
 * The plain blur in the overlay's glass (`overlayBlurLayer`): one view over every piece that takes
 * frost, as big as they are together — the blur is of all it covers, every frame — `radius` points,
 * `alpha` opaque, through the frost's fade toward each piece's edge (`overlayBevelMask`). None, and
 * it is hidden. `area` is SDL's view's frame, which the pieces are placed in from its top left.
 */
static void overlayBlur(NSView *blur, NSRect area, const FizzyGlassShape *shapes, long n, const FizzyGlassLook *look, double radius, double alpha) {
    CGRect u = CGRectNull;
    for (long i = 0; i < n; i++) {
        const FizzyGlassShape sh = shapes[i];
        if (sh.alpha <= 0.01 || sh.frost <= 0.01) continue;
        u = CGRectUnion(u, CGRectMake(sh.x, sh.y, sh.w, sh.h));
    }
    const BOOL shows = radius > 0 && alpha > 0.01 && !CGRectIsNull(u);
    [blur setHidden:!shows];
    if (!shows) return;
    u = CGRectIntegral(CGRectInset(u, -2, -2));
    [blur setFrame:NSMakeRect(area.origin.x + u.origin.x, area.origin.y + area.size.height - CGRectGetMaxY(u), u.size.width, u.size.height)];
    CALayer *layer = [blur layer];
    @try {
        NSNumber *was = [layer valueForKeyPath:@"filters.gaussianBlur.inputRadius"];
        if (was == nil || fabs([was doubleValue] - radius) > 0.01) [layer setValue:@(radius) forKeyPath:@"filters.gaussianBlur.inputRadius"];
    } @catch (NSException *e) {
        (void)e;
    }
    [layer setOpacity:(float)alpha];
    overlayBevelMask(blur, shapes, n, look, YES, u.origin.x, u.origin.y);
}

void fizzy_macos_viewport_overlay_glass(void *nswindow, const FizzyGlassShape *shapes, long n, double spacing, const FizzyGlassLook *look) {
    @autoreleasepool {
        NSWindow *window = (__bridge NSWindow *)nswindow;
        if (window == nil || look == NULL) return;
        NSView *frame = [[window contentView] superview];
        NSView *layers[2] = {nil, nil};
        NSView *fill = nil;
        NSView *blur = nil;
        for (NSView *v in [frame subviews]) {
            for (int k = 0; k < 2; k++) {
                if ([[v identifier] isEqualToString:overlay_glass_ids[k]]) layers[k] = v;
            }
            if ([[v identifier] isEqualToString:overlay_fill_id]) fill = v;
            if ([[v identifier] isEqualToString:overlay_blur_id]) blur = v;
        }
        [CATransaction setDisableActions:YES];
        if (fill != nil) {
            overlayFill(fill, shapes, n, spacing, look);
            overlayBevelMask(fill, shapes, n, look, NO, 0, 0);
        }
        const double share = fmin(fmax(look->over_share, 0), 1);
        const double glass = fmin(fmax(look->glass, 0), 1);
        /* The under layer whole; over it in each piece's body a plain blur (`overlayBlurLayer`) where
         * there is one, the frost at its share (`glass_look`'s `drop_frost`) where there is not —
         * either faded out toward the pieces' edges (`overlayBevelMask`) so the under one's rim shows
         * round it, and over each piece as much as it takes. */
        const double radius = fmax(look->blur, 0);
        const BOOL blurs = blur != nil && radius > 0;
        const double alphas[2] = {glass, blurs ? 0 : share * glass};
        if (blur != nil) overlayBlur(blur, [[window contentView] frame], shapes, n, look, blurs ? radius : 0, glass);
        const long variants[2] = {look->under_variant, look->over_variant};
        const long styles[2] = {look->under_style, look->over_style};
        for (int k = 0; k < 2; k++) {
            if (layers[k] == nil) continue;
            const BOOL shows = alphas[k] > 0.01;
            [layers[k] setHidden:!shows];
            [layers[k] setAlphaValue:(CGFloat)alphas[k]];
            overlayGlassLayer(layers[k], shapes, shows ? n : 0, spacing, variants[k], styles[k]);
            if (k == 1) overlayBevelMask(layers[k], shapes, shows ? n : 0, look, YES, 0, 0);
        }
    }
}

/* A titled window's Liquid Glass (`fizzy_macos_window_liquid_glass`), from the bottom: the window's
 * colour all over, for the top of the slider; the lens; and in the body frost, the plain blur
 * behind the window and the colour again. */
enum { window_glass_top, window_glass_under, window_glass_over, window_glass_blur, window_glass_fill, window_glass_parts };
static NSString *const window_glass_ids[window_glass_parts] = {@"fizzy.window.top", @"fizzy.window.glass.under", @"fizzy.window.glass.over", @"fizzy.window.blur", @"fizzy.window.fill"};

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
 * 26): beside SDL's view in the window's frame view, under it, the window's colour all over, which
 * comes in only near full opacity; the clear lens over it; and over the lens the body —
 * frost, the plain blur behind the window, the colour again — fading out across the window's
 * clearing bevel, so its edge stays the lens bending the desktop.
 * `fizzy_macos_window_liquid_glass_look` sets them each frame from the window's two sliders. The
 * window clear but for them, and a compact toolbar's corners — what macOS 26 rounds a window by is
 * whether it has a toolbar: none, 16 points; compact, 20 (and a 40-point title bar for 32);
 * unified, 27 (and 66).
 * Any vibrancy beside SDL's view (a float's) goes. Once per window; 1 where it is (or was already)
 * Liquid Glass, 0 where the OS has none.
 */
/* The glass parts beside SDL's view in `window`'s frame view (`window_glass_ids`), once; 1 where they
 * are (or already were), 0 where the OS has no Liquid Glass. A titled window's and a menu's alike. */
static int windowGlassInstall(NSWindow *window, long blur_material) {
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
    return 1;
}

int fizzy_macos_window_liquid_glass(void *nswindow, long blur_material) {
    @autoreleasepool {
        NSWindow *window = (__bridge NSWindow *)nswindow;
        if (window == nil || !fizzy_macos_liquid_glass_available()) return 0;
        if (windowGlassPart(window, window_glass_under) != nil) return 1;
        if (!windowGlassInstall(window, blur_material)) return 0;
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

/*
 * A menu's window (`SDLBackend.viewportOpenMenu`): dressed as a float's window is
 * (`viewportDress`), but borderless, with the OS's shadow round its shape, kept above every window
 * by its level, on every Space, in no window list — and taking the pointer, unlike a carry window.
 * On Liquid Glass where the OS has it — the window's glass parts, whose look the app sets each frame
 * (`fizzy_macos_window_liquid_glass_look`), rounded to the menu's corners — 1; vibrancy before, its
 * mask rounded by `radius` points, 0.
 */
int fizzy_macos_viewport_menu(void *nswindow, void *main_nswindow, long material, double radius, int dialog) {
    @autoreleasepool {
        NSWindow *window = (__bridge NSWindow *)nswindow;
        if (window == nil) return 0;
        viewportDress(window, (__bridge NSWindow *)main_nswindow);
        [window setHasShadow:YES];
        /* A dialog rides in the main window's stacking, as its child (`SDLBackend`), other apps'
         * windows going over both; a menu is above every window, on every Space. */
        [window setLevel:dialog ? NSNormalWindowLevel : NSPopUpMenuWindowLevel];
        [window setExcludedFromWindowsMenu:YES];
        const NSWindowCollectionBehavior every_space = dialog ? 0 : NSWindowCollectionBehaviorCanJoinAllSpaces;
        [window setCollectionBehavior:every_space | NSWindowCollectionBehaviorTransient |
                                      NSWindowCollectionBehaviorIgnoresCycle | NSWindowCollectionBehaviorFullScreenAuxiliary];
        [window setIgnoresMouseEvents:NO];
        [NSApp removeWindowsItem:window];
        if (windowGlassInstall(window, material)) return 1;
        /* A hair of inset: with none the vibrancy is left whole for the OS to round, as a titled
         * window's is, and a borderless one it does not round. */
        fizzy_macos_viewport_glass(nswindow, main_nswindow, 0.01, radius, material);
        return 0;
    }
}

/*
 * `nswindow` just above `other` in the stacking, where it is not already: a growing float's
 * picture over the overlay holding the glass it grows out of (`Popout.growDrops`), both at a popup's
 * level, where whichever was ordered last is in front.
 */
void fizzy_macos_viewport_order_above(void *nswindow, void *other) {
    @autoreleasepool {
        NSWindow *window = (__bridge NSWindow *)nswindow;
        NSWindow *below = (__bridge NSWindow *)other;
        if (window == nil || below == nil || ![window isVisible]) return;
        NSArray<NSNumber *> *order = [NSWindow windowNumbersWithOptions:0];
        const NSUInteger mine = [order indexOfObject:@([window windowNumber])];
        const NSUInteger theirs = [order indexOfObject:@([below windowNumber])];
        if (mine != NSNotFound && theirs != NSNotFound && mine < theirs) return;
        [window orderWindow:NSWindowAbove relativeTo:[below windowNumber]];
    }
}

/*
 * `nswindow` at `other`'s level and just above it: a float's window born of a drop, over the drag's
 * overlay while the glass in it goes (`Popout.liftOver`) — under it, the overlay's lens bent the
 * window's picture. `fizzy_macos_viewport_settle` puts it back at a window's own level.
 */
void fizzy_macos_viewport_lift(void *nswindow, void *other) {
    @autoreleasepool {
        NSWindow *window = (__bridge NSWindow *)nswindow;
        NSWindow *below = (__bridge NSWindow *)other;
        if (window == nil || below == nil) return;
        if ([window level] < [below level]) [window setLevel:[below level]];
        fizzy_macos_viewport_order_above(nswindow, other);
    }
}

/*
 * Back at a window's own level, from over the drag's glass (`fizzy_macos_viewport_lift`): and over
 * the main window, as a window just opened is. Dropped to its level and left there, it went under
 * the main window it had grown over — the float a view let go over its own place opens (the user).
 */
void fizzy_macos_viewport_settle(void *nswindow, void *main_nswindow) {
    @autoreleasepool {
        NSWindow *window = (__bridge NSWindow *)nswindow;
        if (window == nil || [window level] == NSNormalWindowLevel) return;
        [window setLevel:NSNormalWindowLevel];
        /* It was over every window up there, and comes down over the main one, whatever
         * `orderedIndex` says: just after the level changes it still reads the window as in front,
         * while AppKit has put it back where it was shown among the normal windows — under the
         * main one (SDL shows a window it does not activate below the key window). Asked first, a
         * float let go from a drop came up and went behind the main window as it settled. */
        NSWindow *main = (__bridge NSWindow *)main_nswindow;
        if (main == nil || ![window isVisible] || ![main isVisible] || [main isMiniaturized]) return;
        if ((([window styleMask] | [main styleMask]) & NSWindowStyleMaskFullScreen) != 0) return;
        [window orderWindow:NSWindowAbove relativeTo:[main windowNumber]];
    }
}

/*
 * A menu's window made its parent's child (`SDLBackend`, `Viewport.follow_main`), so the OS moves it
 * with the parent: AppKit put it at the parent's level as it did, under every window kept above the
 * main one. Back at a menu's.
 */
void fizzy_macos_viewport_menu_attached(void *nswindow) {
    @autoreleasepool {
        NSWindow *window = (__bridge NSWindow *)nswindow;
        if (window == nil) return;
        [window setLevel:NSPopUpMenuWindowLevel];
    }
}

/*
 * A window of Liquid Glass's toolbar (`fizzy_macos_window_liquid_glass`) is there for the corners
 * a compact toolbar gives a window, and in full screen there are none: shown there, it stayed at
 * the top after the window had gone full screen, then went (the user). Hidden from the moment the
 * window sets out for a Space (`on` 0) and shown again once it is back (`on` 1), the window's frame
 * kept as it was — showing or hiding it, AppKit grows or shrinks the window by its height.
 */
void fizzy_macos_window_glass_toolbar(void *nswindow, int on) {
    @autoreleasepool {
        NSWindow *window = (__bridge NSWindow *)nswindow;
        if (window == nil || windowGlassPart(window, window_glass_under) == nil) return;
        NSToolbar *toolbar = [window toolbar];
        if (toolbar == nil || [toolbar isVisible] == (on != 0)) return;
        const BOOL full = ([window styleMask] & NSWindowStyleMaskFullScreen) != 0;
        const NSRect was = [window frame];
        [toolbar setVisible:on != 0];
        if (!full && !NSEqualRects([window frame], was)) [window setFrame:was display:NO];
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
 * A body fading out across its clearing bevel — a window's, a carried card's: alpha 0 `rim` points
 * in from the edge, rising quickly and then easing to 1 `feather` points further in, its rounded
 * corners following the shape's (and tightening inward, as nested rounded rects do). A small image, nine-sliced — its middle pixel
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
        /* Out of the edge quickly: strong most of the way to it, gone at it. */
        CGContextSetGrayFillColor(ctx, 0, 1 - (1 - t) * (1 - t));
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

extern int fizzy_macos_window_space_picture_in_window(void *nswindow, NSRect *rect, double *fullness);

/* Where a float's window standing still on its way into or out of full screen has its picture
 * (`fizzy_macos_window_space_still`), in its frame view, and how far it is into full screen. NO
 * when it is on no such way. */
static BOOL windowGlassPicture(NSWindow *window, NSRect *in_frame_view, double *fullness) {
    NSRect r;
    if (!fizzy_macos_window_space_picture_in_window((__bridge void *)window, &r, fullness)) return NO;
    NSView *frame = [[window contentView] superview];
    if (frame == nil) return NO;
    *in_frame_view = [frame convertRect:r fromView:nil];
    return YES;
}

/* The glass behind a float's window — its vibrancy, or its Liquid Glass — where the float is drawn:
 * only where its picture is while the window stands still on its way into or out of full screen,
 * all of the window otherwise. Each step of the way, and as it ends. */
void fizzy_macos_window_glass_follow(void *nswindow) {
    @autoreleasepool {
        NSWindow *window = (__bridge NSWindow *)nswindow;
        NSView *content = [window contentView];
        NSView *frame = [content superview];
        if (content == nil || frame == nil) return;
        NSRect picture;
        const BOOL still = windowGlassPicture(window, &picture, NULL);
        [CATransaction begin];
        [CATransaction setDisableActions:YES];
        for (NSView *v in [frame subviews]) {
            if (![v isKindOfClass:[FizzyViewportGlassView class]]) continue;
            const NSRect want = still ? picture : [content frame];
            if (!NSEqualRects([v frame], want)) [v setFrame:want];
        }
        for (int k = 0; k < window_glass_parts; k++) {
            NSView *part = windowGlassPart(window, k);
            const NSRect want = still ? picture : [frame bounds];
            if (part != nil && !NSEqualRects([part frame], want)) [part setFrame:want];
        }
        [CATransaction commit];
    }
}

/*
 * `nswindow`'s Liquid Glass this frame (`fizzy_macos_window_liquid_glass`): the colour all over at
 * the top of the slider, the lens over it, and the body over that — frost, the plain blur, the
 * window's colour — fading out across the clearing bevel. Its corners the window's, every part
 * where SDL's view is: made before a float's window had its full-size content, they stayed a title
 * bar lower than it, the title bar clear of glass and the glass past the bottom.
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
        /* All of the window: in full screen SDL's view stops short of its top. Square there. */
        NSRect content = [[[window contentView] superview] bounds];
        const BOOL full = ([window styleMask] & NSWindowStyleMaskFullScreen) != 0;
        double radius = full ? 0 : g->radius;
        /* A float's window standing still on its way into or out of full screen: the glass only
         * where the float is drawn, its corners squaring off as it goes, on half points so the
         * bevel is drawn again only as often as that shows. */
        NSRect picture;
        double fullness = 0;
        const BOOL still = windowGlassPicture(window, &picture, &fullness);
        if (still) {
            content = picture;
            radius = round(g->radius * (1 - fullness) * 2) / 2;
        }
        BOOL moved = NO;
        for (int k = 0; k < window_glass_parts; k++) {
            if (!NSEqualRects([parts[k] frame], content)) {
                [parts[k] setFrame:content];
                moved = YES;
            }
        }
        /* A clear window's shadow and edge are the OS's reading of what it showed: read again,
         * or a float's kept the shape its glass had a title bar out of place. A borderless window's
         * (a menu's) is read from its picture, so again whenever its size changes — a menu sliding
         * open — where a titled window's follows its frame. */
        if (([window styleMask] & NSWindowStyleMaskTitled) == 0) {
            NSString *size = NSStringFromSize(content.size);
            CALayer *top_layer = [parts[window_glass_top] layer];
            if (![[top_layer valueForKey:@"fizzySize"] isEqual:size]) {
                [top_layer setValue:size forKey:@"fizzySize"];
                moved = YES;
            }
        }
        /* Not each step of a still window's way: its shadow is its frame's, which stands still. */
        if (moved && !still) [window invalidateShadow];
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
        NSString *key = [NSString stringWithFormat:@"%.2f/%.2f/%.2f/%.2f", radius, g->clear, g->feather, scale];
        CALayer *over_layer = [parts[window_glass_over] layer];
        double edge = ceil(g->clear + g->feather + radius);
        CGImageRef bevel = NULL;
        if (over_layer != nil && ![[[over_layer mask] valueForKey:@"fizzyBevel"] isEqual:key]) {
            bevel = bevelImage(radius, g->clear, g->feather, scale, &edge);
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
            if (![v respondsToSelector:get_radius] || ((CGFloat (*)(id, SEL))objc_msgSend)(v, get_radius) != (CGFloat)radius)
                ((void (*)(id, SEL, CGFloat))objc_msgSend)(v, set_radius, (CGFloat)radius);
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
