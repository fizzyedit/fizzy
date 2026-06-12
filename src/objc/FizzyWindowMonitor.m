#import <AppKit/AppKit.h>
#import <QuartzCore/QuartzCore.h>
#import <objc/runtime.h>

/* macOS window/Space monitor for fizzy's SDL3 window (chrome hidden, content
 * wrapped in an NSVisualEffectView — stock SDL windows don't need any of this).
 *
 * Green-button maximize uses a native fullscreen Space (menu bar hidden).
 * SDL3 ignores resize notifications while a Space transition animates, so a
 * 60Hz NSTimer pump renders live frames during the morph.  The Zig side
 * (src/backend_native.zig) pushes live contentView bounds into SDL before each
 * frame so the Metal drawable and layout stay paired.
 *
 * The fizzy_macos_window_* callbacks below are exported from
 * src/backend_native.zig; everything else is self-contained. */

extern void fizzy_macos_window_resize_cb(void);
extern void fizzy_macos_window_pump_frame(void);
extern void fizzy_macos_window_reset_sync_cache(void);
extern void fizzy_macos_window_request_clear_frames(int frames);
extern void fizzy_macos_window_commit_steady_state(void);
/* Pure window-frame decisions live in window_layout.zig (unit-tested); see
 * backend_native.zig for the C-ABI wrappers. */
extern int fizzy_macos_constrain_is_menu_bar_nudge(double rx, double ry, double rw, double rh,
                                                   double cx, double cy, double cw, double ch,
                                                   double visible_top);
extern int fizzy_macos_origin_nudged(double cap_x, double cap_y, double cur_x, double cur_y);
void fizzy_macos_window_sync_content_views(void *nswindow);

static BOOL g_zoom_state_valid = NO;
static BOOL g_was_zoomed = NO;
static BOOL g_unzoom_animating = NO;
static BOOL g_manual_live_resize = NO;
static BOOL g_space_transition = NO;
static int g_transition_gen = 0;
static BOOL g_in_pump = NO;
static int g_pump_frames = 0;
static NSTimer *g_pump_timer = nil;
static void *g_pump_window = NULL;
static BOOL g_space_entering = NO;
/* Frames remaining in the post-fullscreen-exit settle during which we re-assert
 * the pre-fullscreen origin every pump tick, so AppKit's menu-bar nudge never
 * reaches the screen (see pump_tick_inner). */
static int g_exit_origin_guard = 0;
static NSRect g_exit_window_frame = {{0, 0}, {0, 0}};
static BOOL g_exit_window_frame_valid = NO;
static double g_windowed_titlebar_inset = 0;


static BOOL live_resize_active(void) {
    return g_space_transition || g_unzoom_animating || g_pump_frames > 0;
}

static double titlebar_inset_for_window(NSWindow *window);

static BOOL window_in_fullscreen_space(NSWindow *window) {
    return (window.styleMask & NSWindowStyleMaskFullScreen) != 0;
}

/* Capture the windowed NSWindow.frame to restore the origin after a fullscreen
 * exit and to persist on quit-while-fullscreen. Skips while in a Space (the frame
 * is the fullscreen one) or before the content view has real bounds. */
static void store_exit_target(NSWindow *window) {
    if (!window || window_in_fullscreen_space(window)) return;
    NSView *content = window.contentView;
    if (!content) return;
    NSSize bounds = content.bounds.size;
    if (bounds.width >= 1.0 && bounds.height >= 1.0) {
        g_exit_window_frame = window.frame;
        g_exit_window_frame_valid = YES;
    }
}

/* Bug A: at the top of the screen AppKit nudges the window DOWN by a titlebar on
 * fullscreen exit — it keeps a normal window's titlebar below the menu bar, but
 * our full-size content window legitimately allowed the frame top at the screen
 * top. You cannot move a window inside a Space, so the origin captured at
 * willEnter (g_exit_window_frame.origin) is authoritative. Correct ONLY the
 * origin via setFrameOrigin — never setFrame the size: AppKit restores the
 * windowed frame through its own content = frame − titlebar model, so forcing our
 * captured full-size frame on top of that overshoots by a titlebar (the window
 * grows upward). A pure origin move cannot change the size. Only undo a small
 * nudge so we never fight a real position change. */
static void restore_pre_fullscreen_origin_if_nudged(NSWindow *window) {
    if (!window || !g_exit_window_frame_valid) return;
    if (window_in_fullscreen_space(window)) return;
    NSPoint want = g_exit_window_frame.origin;
    NSPoint have = window.frame.origin;
    if (fizzy_macos_origin_nudged(want.x, want.y, have.x, have.y)) {
        [window setFrameOrigin:want];
    }
}

static NSView *app_render_host_view(NSWindow *window) {
    NSView *content = window.contentView;
    if (!content) return NULL;
    if ([content isKindOfClass:[NSVisualEffectView class]]) {
        for (NSView *sub in content.subviews) {
            if (sub.bounds.size.width >= 1.0 && sub.bounds.size.height >= 1.0) return sub;
        }
    }
    return content;
}

static void sync_subview_frames(NSView *view, NSRect frame, BOOL force) {
    const BOOL changed = force || !NSEqualRects(view.frame, frame);
    if (changed) {
        [view setFrame:frame];
        [view setNeedsLayout:YES];
        [view setNeedsDisplay:YES];
    }
    NSRect child = NSMakeRect(0, 0, frame.size.width, frame.size.height);
    for (NSView *sub in view.subviews) {
        sync_subview_frames(sub, child, force);
    }
}

static void sync_metal_layers(NSView *view) {
    if ([view.layer isKindOfClass:[CAMetalLayer class]]) {
        CAMetalLayer *metal = (CAMetalLayer *)view.layer;
        /* Scale the backbuffer to fill the view whenever drawable and bounds can
         * diverge (Space morph, manual live resize, zoom). Center gravity letterboxes
         * a lagging drawable and makes left-anchored UI jitter asymmetrically. */
        metal.contentsGravity = kCAGravityResize;
    }
    for (NSView *sub in view.subviews) {
        sync_metal_layers(sub);
    }
}

static void content_size_points(NSWindow *window, CGFloat *out_w, CGFloat *out_h) {
    if (out_w) *out_w = 0;
    if (out_h) *out_h = 0;
    if (!window) return;
    NSView *content = window.contentView;
    if (!content) return;
    NSSize bounds = content.bounds.size;
    if (out_w) *out_w = bounds.width;
    if (out_h) *out_h = bounds.height;
}

static void stop_pump_if_idle(void) {
    if (g_space_transition || g_pump_frames > 0) return;
    [g_pump_timer invalidate];
    g_pump_timer = nil;
    g_unzoom_animating = NO;
}

static void pump_tick_inner(void);

static void pump_tick(void) {
    if (g_in_pump) return;
    g_in_pump = YES;
    pump_tick_inner();
    g_in_pump = NO;
}

static void pump_tick_inner(void) {
    if (!g_pump_window) {
        stop_pump_if_idle();
        return;
    }
    if (!live_resize_active()) {
        stop_pump_if_idle();
        return;
    }
    // Pump live DVUI frames through the WHOLE transition — enter and exit. We sync
    // the live contentView bounds into SDL every tick and the metal layer uses
    // kCAGravityResize, so the drawable scales to fill the morphing view (the same
    // path that makes EXIT look right). Previously the ENTER morph let AppKit scale
    // a frozen snapshot, which raced our one priming frame and gave inconsistent
    // results (sometimes a stale strip-reserved snapshot scaled up). Rendering live
    // during enter removes that race; the titlebar strip is already collapsed via
    // g_space_entering, so there is no strip-gap to morph.
    if (g_pump_frames > 0) g_pump_frames--;

    // While settling after a fullscreen EXIT, re-assert the pre-fullscreen origin
    // BEFORE rendering each frame. AppKit's exit restore nudges a top-anchored
    // window down a titlebar (it bypasses our constrainFrameRect override), and a
    // one-shot async correction shows that nudged frame for a beat ("pop down then
    // up"). Correcting every tick means the nudge never reaches the screen. The
    // helper no-ops once the origin already matches, so it cannot fight AppKit.
    if (g_exit_origin_guard > 0) {
        g_exit_origin_guard--;
        restore_pre_fullscreen_origin_if_nudged((__bridge NSWindow *)g_pump_window);
    }

    fizzy_macos_window_sync_content_views(g_pump_window);
    fizzy_macos_window_pump_frame();
}

static void request_resize_pump(void *nswindow, int frames) {
    if (!nswindow) return;
    g_pump_window = nswindow;
    if (frames > g_pump_frames) g_pump_frames = frames;

    if (g_pump_timer) return;

    const NSTimeInterval interval = 1.0 / 60.0;
    g_pump_timer = [NSTimer timerWithTimeInterval:interval
                                          repeats:YES
                                            block:^(__unused NSTimer *timer) {
        pump_tick();
    }];
    [[NSRunLoop mainRunLoop] addTimer:g_pump_timer forMode:NSRunLoopCommonModes];
}

/* Track green-button zoom (non-Space maximize). On un-zoom, drive the pump so
 * the content keeps up with AppKit's resize animation. */
static void note_zoom_state(NSWindow *window) {
    BOOL zoomed = window.zoomed;
    if (g_zoom_state_valid && zoomed != g_was_zoomed) {
        if (g_was_zoomed && !zoomed) g_unzoom_animating = YES;
        request_resize_pump((__bridge void *)window, 120);
    }
    g_was_zoomed = zoomed;
    g_zoom_state_valid = YES;
}

static void pump_now(void) {
    if ([NSThread isMainThread]) {
        pump_tick();
    } else {
        dispatch_async(dispatch_get_main_queue(), ^{
            pump_tick();
        });
    }
}

static void schedule_transition_watchdog(void *nswindow) {
    const int gen = g_transition_gen;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(3.0 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        if (gen != g_transition_gen) return;
        if (!g_space_transition) return;
        // The transition never reported did-enter/exit within the timeout —
        // typically toggleFullScreen: was dropped during app activation, which
        // leaves us pumping target-sized frames into a still-windowed window
        // (the "stretched window behind" artifact). Clear the stuck flags and
        // snap SDL/Metal back to the window's real content bounds.
        g_space_transition = NO;
        g_space_entering = NO;
        g_unzoom_animating = NO;
        fizzy_macos_window_commit_steady_state();
        request_resize_pump(nswindow, 30);
    });
}

void fizzy_macos_window_space_stage(int stage, void *nswindow) {
    void *win = nswindow ?: g_pump_window;
    if (win) g_pump_window = win;
    g_transition_gen++;

    switch (stage) {
        case 0: // willEnter
            g_space_transition = YES;
            g_space_entering = YES;
            g_unzoom_animating = NO;
            schedule_transition_watchdog(win);
            if (win) {
                NSWindow *w = (__bridge NSWindow *)win;
                store_exit_target(w);
                double inset = titlebar_inset_for_window(w);
                g_windowed_titlebar_inset = (inset > 0 && inset <= 100.0) ? inset : 0;
            }
            fizzy_macos_window_reset_sync_cache();
            fizzy_macos_window_request_clear_frames(5);
            request_resize_pump(win, 90);
            break;
        case 1: // didEnter
            g_space_transition = NO;
            g_space_entering = NO;
            fizzy_macos_window_commit_steady_state();
            fizzy_macos_window_request_clear_frames(5);
            request_resize_pump(win, 15);
            break;
        case 2: // willExit
            g_space_transition = YES;
            g_space_entering = NO;
            g_unzoom_animating = YES;
            fizzy_macos_window_reset_sync_cache();
            fizzy_macos_window_request_clear_frames(5);
            request_resize_pump(win, 90);
            schedule_transition_watchdog(win);
            break;
        case 3: // didExit
            g_space_transition = NO;
            g_space_entering = NO;
            g_unzoom_animating = NO;
            // Re-assert the pre-fullscreen origin on every pump tick for the settle
            // window, so AppKit's menu-bar nudge is corrected before each frame is
            // rendered and the "pop down then up" never reaches the screen. Origin
            // only — never size (forcing our captured full-size frame overshoots by
            // a titlebar; AppKit restores the correct size itself).
            g_exit_origin_guard = 30;
            fizzy_macos_window_commit_steady_state();
            fizzy_macos_window_request_clear_frames(5);
            request_resize_pump(win, 30);
            dispatch_async(dispatch_get_main_queue(), ^{
                if (win) {
                    NSWindow *exit_win = (__bridge NSWindow *)win;
                    restore_pre_fullscreen_origin_if_nudged(exit_win);
                    store_exit_target(exit_win);
                }
                fizzy_macos_window_commit_steady_state();
                fizzy_macos_window_resize_cb();
            });
            break;
        default:
            break;
    }
    pump_now();
}

void fizzy_macos_window_prefer_fullscreen_space(void *nswindow) {
    if (!nswindow) return;
    NSWindow *window = (__bridge NSWindow *)nswindow;
    NSWindowCollectionBehavior behavior = [window collectionBehavior];
    behavior |= NSWindowCollectionBehaviorFullScreenPrimary;
    [window setCollectionBehavior:behavior];
}

int fizzy_macos_window_chrome_hidden(void *nswindow) {
    if (!nswindow) return 0;
    return window_in_fullscreen_space((__bridge NSWindow *)nswindow) ? 1 : 0;
}

/* Layout titlebar spacer: collapsed only for native fullscreen Space (menu bar
 * hidden). Zoom/maximize without a Space keeps the strip — traffic lights stay
 * visible. Expanded early on Space exit so buttons don't overlap content. */
int fizzy_macos_window_titlebar_strip_collapsed(void *nswindow) {
    if (!nswindow) return 0;
    NSWindow *window = (__bridge NSWindow *)nswindow;

    if (g_unzoom_animating) return 0;
    if (g_space_transition && !g_space_entering) return 0;

    if (g_space_entering) return 1;
    if (window_in_fullscreen_space(window)) return 1;

    return 0;
}

int fizzy_macos_window_space_transition_active(void) {
    return g_space_transition ? 1 : 0;
}

int fizzy_macos_window_space_entering(void) {
    return g_space_entering ? 1 : 0;
}

int fizzy_macos_window_space_has_target(void) {
    return g_space_transition ? 1 : 0;
}

double fizzy_macos_window_saved_titlebar_inset(void) {
    return g_windowed_titlebar_inset > 0 ? g_windowed_titlebar_inset : 0;
}

int fizzy_macos_window_in_fullscreen_space(void *nswindow) {
    if (!nswindow) return 0;
    return window_in_fullscreen_space((__bridge NSWindow *)nswindow) ? 1 : 0;
}

int fizzy_macos_window_is_zoomed(void *nswindow) {
    if (!nswindow) return 0;
    NSWindow *window = (__bridge NSWindow *)nswindow;
    return window.zoomed ? 1 : 0;
}

int fizzy_macos_window_perform_zoom(void *nswindow) {
    if (!nswindow) return 0;
    NSWindow *window = (__bridge NSWindow *)nswindow;
    if (window.zoomed) return 1;
    [window performZoom:nil];
    return window.zoomed ? 1 : 0;
}

int fizzy_macos_window_resize_pump_active(void) {
    return live_resize_active() ? 1 : 0;
}

int fizzy_macos_window_unzoom_animating(void *nswindow) {
    (void)nswindow;
    return g_unzoom_animating ? 1 : 0;
}

void fizzy_macos_window_point_size(void *nswindow, int *out_w, int *out_h) {
    if (out_w) *out_w = 0;
    if (out_h) *out_h = 0;
    if (!nswindow) return;
    NSWindow *window = (__bridge NSWindow *)nswindow;
    CGFloat w = 0, h = 0;
    content_size_points(window, &w, &h);
    if (out_w) *out_w = (int)lrint(w);
    if (out_h) *out_h = (int)lrint(h);
}

/* Fizzy owns geometry for its custom (frame == content) window: dvui's
 * content-based model can't represent it. These three expose the NSWindow frame
 * and connected-screen frames so backend_native.zig can persist/restore the
 * actual window frame (AppKit bottom-left points) instead of a content rect. */

/* The last windowed frame: while in a Space, the frame captured before entering
 * (you can't resize in a Space); otherwise the live window.frame. out4 = x,y,w,h. */
void fizzy_macos_window_current_windowed_frame(void *nswindow, double *out4) {
    if (!out4) return;
    for (int i = 0; i < 4; i++) out4[i] = 0;
    if (!nswindow) return;
    NSWindow *window = (__bridge NSWindow *)nswindow;
    NSRect f;
    if (window_in_fullscreen_space(window) && g_exit_window_frame_valid) {
        f = g_exit_window_frame;
    } else {
        f = window.frame;
    }
    out4[0] = f.origin.x; out4[1] = f.origin.y; out4[2] = f.size.width; out4[3] = f.size.height;
}

void fizzy_macos_window_set_frame(void *nswindow, double x, double y, double w, double h) {
    if (!nswindow || w < 1.0 || h < 1.0) return;
    NSWindow *window = (__bridge NSWindow *)nswindow;
    [window setFrame:NSMakeRect(x, y, w, h) display:NO];
    store_exit_target(window);
}

/* Fills out (x,y,w,h per screen) with up to `max` connected-screen frames;
 * returns the count written. */
int fizzy_macos_copy_screen_frames(double *out, int max) {
    if (!out || max <= 0) return 0;
    NSArray<NSScreen *> *screens = [NSScreen screens];
    int n = 0;
    for (NSScreen *s in screens) {
        if (n >= max) break;
        NSRect f = s.frame;
        out[n * 4 + 0] = f.origin.x;
        out[n * 4 + 1] = f.origin.y;
        out[n * 4 + 2] = f.size.width;
        out[n * 4 + 3] = f.size.height;
        n++;
    }
    return n;
}

void fizzy_macos_window_pixel_size(void *nswindow, int *out_w, int *out_h) {
    if (out_w) *out_w = 0;
    if (out_h) *out_h = 0;
    if (!nswindow) return;
    NSWindow *window = (__bridge NSWindow *)nswindow;
    CGFloat w = 0, h = 0;
    content_size_points(window, &w, &h);
    CGFloat scale = window.backingScaleFactor;
    if (out_w) *out_w = (int)lrint(w * scale);
    if (out_h) *out_h = (int)lrint(h * scale);
}

static double titlebar_inset_for_window(NSWindow *window) {
    if (!window) return 0;
    if (window_in_fullscreen_space(window)) return 0;
    NSView *content = window.contentView;
    if (!content) return 0;

    if (@available(macOS 11.0, *)) {
        CGFloat top = content.safeAreaInsets.top;
        if (top > 0) return top;
        for (NSView *sub in content.subviews) {
            top = sub.safeAreaInsets.top;
            if (top > 0) return top;
        }
    }

    NSRect windowContent = [window contentRectForFrameRect:window.frame];
    NSRect layout = [window contentLayoutRect];
    NSRect layoutLocal = [window convertRectFromScreen:layout];
    CGFloat inset = NSMaxY(windowContent) - NSMaxY(layoutLocal);
    return inset > 0 ? inset : 0;
}

double fizzy_macos_window_titlebar_inset(void *nswindow) {
    if (!nswindow) return 0;
    return titlebar_inset_for_window((__bridge NSWindow *)nswindow);
}

void fizzy_macos_window_sync_content_views(void *nswindow) {
    if (!nswindow) return;
    NSWindow *window = (__bridge NSWindow *)nswindow;
    NSView *content = window.contentView;
    if (!content) return;

    NSSize bounds = content.bounds.size;
    if (bounds.width < 1.0 || bounds.height < 1.0) return;
    NSRect frame = NSMakeRect(0, 0, bounds.width, bounds.height);
    BOOL force = live_resize_active();
    NSView *host = app_render_host_view(window);
    if (host) {
        sync_subview_frames(host, frame, force);
    } else {
        for (NSView *sub in content.subviews) {
            sync_subview_frames(sub, frame, force);
        }
    }
    sync_metal_layers(content);
    if (force) {
        [content setNeedsLayout:YES];
    }
}

/* AppKit's default -constrainFrameRect:toScreen: keeps a TITLED window's titlebar
 * below the menu bar. SDL's window is titled (it needs the titlebar for traffic
 * lights / resize / native fullscreen), but our full-size content view draws
 * under the titlebar, so the frame may legitimately reach the top of the usable
 * area. The default constraint — re-applied by AppKit when restoring the windowed
 * frame on fullscreen EXIT — nudges our window DOWN by a titlebar (the source of
 * Bug A and the one-frame exit flash). We override it on SDL's window class to
 * undo ONLY that nudge: keep AppKit's result except when it merely lowered a
 * top-anchored frame by up to a titlebar, in which case keep the requested top.
 * All other constraints (off-screen, width, x) are preserved. */
static IMP g_nswindow_constrain_imp = NULL;

static NSRect fizzy_constrain_frame_rect(id self, SEL _cmd, NSRect frameRect, NSScreen *screen) {
    typedef NSRect (*ConstrainFn)(id, SEL, NSRect, NSScreen *);
    NSRect constrained = g_nswindow_constrain_imp
        ? ((ConstrainFn)g_nswindow_constrain_imp)(self, _cmd, frameRect, screen)
        : frameRect;
    if (!screen) return constrained;

    // Restore the requested top edge only when AppKit's result is the menu-bar
    // nudge of a top-anchored frame (decision + thresholds in window_layout.zig).
    const double visible_top = NSMaxY(screen.visibleFrame);
    if (fizzy_macos_constrain_is_menu_bar_nudge(frameRect.origin.x, frameRect.origin.y,
                                                frameRect.size.width, frameRect.size.height,
                                                constrained.origin.x, constrained.origin.y,
                                                constrained.size.width, constrained.size.height,
                                                visible_top)) {
        constrained.origin.y = frameRect.origin.y;
        constrained.size.height = frameRect.size.height;
    }
    return constrained;
}

/* Install fizzy_constrain_frame_rect on the concrete (SDL) window class so only
 * this app's window is affected, never every NSWindow. Idempotent. */
static void install_constrain_override(NSWindow *window) {
    Class cls = object_getClass(window);
    SEL sel = @selector(constrainFrameRect:toScreen:);
    if (class_getMethodImplementation(cls, sel) == (IMP)fizzy_constrain_frame_rect) return;
    Method base = class_getInstanceMethod([NSWindow class], sel);
    if (!base) return;
    g_nswindow_constrain_imp = method_getImplementation(base);
    const char *types = method_getTypeEncoding(base);
    if (!class_addMethod(cls, sel, (IMP)fizzy_constrain_frame_rect, types)) {
        // The class already defines it (e.g. an SDL override) — replace in place.
        Method existing = class_getInstanceMethod(cls, sel);
        if (existing) {
            g_nswindow_constrain_imp = method_getImplementation(existing);
            method_setImplementation(existing, (IMP)fizzy_constrain_frame_rect);
        }
    }
}

void fizzy_macos_window_install_resize_observer(void *nswindow) {
    if (!nswindow) return;
    static char installed = 0;
    if (installed) return;
    installed = 1;
    g_pump_window = nswindow;
    NSWindow *window = (__bridge NSWindow *)nswindow;
    install_constrain_override(window);
    store_exit_target(window);
    NSNotificationCenter *center = [NSNotificationCenter defaultCenter];
    NSOperationQueue *main = [NSOperationQueue mainQueue];

    [center addObserverForName:NSWindowWillEnterFullScreenNotification
                        object:window
                         queue:main
                    usingBlock:^(__unused NSNotification *note) {
        fizzy_macos_window_space_stage(0, nswindow);
        fizzy_macos_window_resize_cb();
    }];
    [center addObserverForName:NSWindowDidEnterFullScreenNotification
                        object:window
                         queue:main
                    usingBlock:^(__unused NSNotification *note) {
        fizzy_macos_window_space_stage(1, nswindow);
        fizzy_macos_window_resize_cb();
    }];
    [center addObserverForName:NSWindowWillExitFullScreenNotification
                        object:window
                         queue:main
                    usingBlock:^(__unused NSNotification *note) {
        fizzy_macos_window_space_stage(2, nswindow);
        fizzy_macos_window_resize_cb();
    }];
    [center addObserverForName:NSWindowDidExitFullScreenNotification
                        object:window
                         queue:main
                    usingBlock:^(__unused NSNotification *note) {
        fizzy_macos_window_space_stage(3, nswindow);
        fizzy_macos_window_resize_cb();
    }];

    for (NSString *name in @[
             NSWindowDidResizeNotification,
             NSWindowDidMoveNotification,
             NSWindowWillStartLiveResizeNotification,
             NSWindowDidEndLiveResizeNotification,
         ]) {
        [center addObserverForName:name
                            object:window
                             queue:main
                        usingBlock:^(__unused NSNotification *note) {
            NSWindow *w = (__bridge NSWindow *)nswindow;
            // AppKit's exit nudge is a window MOVE; correct it the instant it lands
            // (not just on the next pump tick) so the nudged frame is never shown.
            // The helper no-ops once the origin matches, so the setFrameOrigin it
            // issues — which re-fires this notification — terminates immediately.
            if (g_exit_origin_guard > 0) {
                restore_pre_fullscreen_origin_if_nudged(w);
            }
            if ([name isEqualToString:NSWindowWillStartLiveResizeNotification]) {
                g_manual_live_resize = YES;
            } else if ([name isEqualToString:NSWindowDidEndLiveResizeNotification]) {
                fizzy_macos_window_sync_content_views(nswindow);
                g_manual_live_resize = NO;
            }
            note_zoom_state(w);
            if (g_space_transition || g_unzoom_animating) {
                request_resize_pump(nswindow, 120);
                pump_tick();
            } else if (g_manual_live_resize) {
                /* Vibrancy host only — SDL resizes its subviews during live resize. */
                fizzy_macos_window_sync_content_views(nswindow);
            }
        }];
    }
}
