#import <AppKit/AppKit.h>
#import <QuartzCore/QuartzCore.h>
#import <objc/runtime.h>
#include <stdbool.h>

/* macOS window/Space monitor for fizzy's SDL3 window (chrome hidden, content
 * wrapped in an NSVisualEffectView — stock SDL windows don't need any of this).
 *
 * Green-button maximize uses a native fullscreen Space (menu bar hidden).
 * SDL3 ignores resize notifications while a Space transition animates, so a
 * 60Hz NSTimer pump renders live frames during the morph.  The Zig side
 * (src/backend/backend_native.zig) pushes live contentView bounds into SDL before each
 * frame so the Metal drawable and layout stay paired.
 *
 * The fizzy_macos_window_* callbacks below are exported from
 * src/backend/backend_native.zig; everything else is self-contained. */

extern void fizzy_macos_window_resize_cb(void *nswindow);
extern void fizzy_macos_window_pump_sync(void *nswindow);
extern void fizzy_macos_window_pump_render(void);
extern void fizzy_macos_window_reset_sync_cache(void *nswindow);
extern void fizzy_macos_window_request_clear_frames(void *nswindow, int frames);
extern void fizzy_macos_window_commit_steady_state(void *nswindow);
extern void fizzy_macos_window_glass_toolbar(void *nswindow, int on);
extern void fizzy_macos_window_live_resize_vsync(void *nswindow, int active);
extern bool SDL_GetHintBoolean(const char *name, bool default_value);
extern void fizzy_live_resize_trace_step(void *nswindow);
/* Pure window-frame decisions live in window_layout.zig (unit-tested); see
 * backend/backend_native.zig for the C-ABI wrappers. */
extern int fizzy_macos_constrain_is_menu_bar_nudge(double rx, double ry, double rw, double rh,
                                                   double cx, double cy, double cw, double ch,
                                                   double visible_top);
extern int fizzy_macos_origin_nudged(double cap_x, double cap_y, double cur_x, double cur_y);
void fizzy_macos_window_sync_content_views(void *nswindow);

/* One window's way through Spaces, zooms and live resizes: the main window's, and each float's
 * own window's (fizzy's viewports) — the same machinery for every window fizzy dresses, so a
 * float's window goes full screen in a Space of its own as the main window does. Found by its
 * window (`monitor_of`); the blocks observing a window hold the window, never the record. */
typedef struct WindowMonitor {
    void *window; /* NSWindow, not retained: forgotten before it goes (`fizzy_macos_window_uninstall_monitor`) */
    BOOL zoom_state_valid;
    BOOL was_zoomed;
    BOOL unzoom_animating;
    BOOL manual_live_resize;
    BOOL space_transition;
    BOOL space_entering;
    int transition_gen;
    /* Frames the pump still renders for it. */
    int pump_frames;
    /* Frames remaining in the post-fullscreen-exit settle during which the pre-fullscreen origin
     * is re-asserted every pump tick, so AppKit's menu-bar nudge never reaches the screen (see
     * pump_tick_inner). */
    int exit_origin_guard;
    NSRect exit_window_frame;
    BOOL exit_window_frame_valid;
    double windowed_titlebar_inset;
    /* Its notification observers, retained, removed when it is forgotten. */
    id observers[12];
    int observer_count;
} WindowMonitor;

/* The main window and up to SDLBackend's eight viewports, with room to spare. */
#define FIZZY_MAX_MONITORS 16
static WindowMonitor g_monitors[FIZZY_MAX_MONITORS];

static WindowMonitor *monitor_of(void *nswindow) {
    if (!nswindow) return NULL;
    for (int i = 0; i < FIZZY_MAX_MONITORS; i++) {
        if (g_monitors[i].window == nswindow) return &g_monitors[i];
    }
    return NULL;
}

/* One pump for every window: a 60Hz timer while any of them animates. */
static BOOL g_in_pump = NO;
static NSTimer *g_pump_timer = nil;


/* Whether SDL draws this window's live resize itself, each step from AppKit's display of it and
 * presented with that step's transaction: fizzyedit/SDL's live-resize patches, asked for with
 * `SDL_VIDEO_MAC_SYNC_LIVE_RESIZE` (`macos_monitor.zig`, `docs/MACOS_LIVE_RESIZE.md`). Its
 * window listener, the window's delegate, answers `drawsLiveResizeInView:` only with them. Such a
 * frame's present waits for nothing but the GPU to schedule it, so vsync is left as it is. */
static BOOL sdl_draws_live_resize(NSWindow *window) {
    if (!SDL_GetHintBoolean("SDL_VIDEO_MAC_SYNC_LIVE_RESIZE", false)) return NO;
    id delegate = window.delegate;
    return delegate != nil && [delegate respondsToSelector:@selector(drawsLiveResizeInView:)];
}

int fizzy_macos_window_sdl_draws_live_resize(void *nswindow) {
    if (!nswindow) return 0;
    return sdl_draws_live_resize((__bridge NSWindow *)nswindow) ? 1 : 0;
}

static BOOL monitor_active(const WindowMonitor *m) {
    return m && m->window && (m->space_transition || m->unzoom_animating || m->pump_frames > 0);
}

static BOOL any_monitor_active(void) {
    for (int i = 0; i < FIZZY_MAX_MONITORS; i++) {
        if (monitor_active(&g_monitors[i])) return YES;
    }
    return NO;
}

static double titlebar_inset_for_window(NSWindow *window);

static BOOL window_in_fullscreen_space(NSWindow *window) {
    return (window.styleMask & NSWindowStyleMaskFullScreen) != 0;
}

/* Capture the windowed NSWindow.frame to restore the origin after a fullscreen
 * exit and to persist on quit-while-fullscreen. Skips while in a Space (the frame
 * is the fullscreen one) or before the content view has real bounds. */
static void store_exit_target(NSWindow *window) {
    WindowMonitor *m = monitor_of((__bridge void *)window);
    if (!m || window_in_fullscreen_space(window)) return;
    NSView *content = window.contentView;
    if (!content) return;
    NSSize bounds = content.bounds.size;
    if (bounds.width >= 1.0 && bounds.height >= 1.0) {
        m->exit_window_frame = window.frame;
        m->exit_window_frame_valid = YES;
    }
}

/* Bug A: at the top of the screen AppKit nudges the window DOWN by a titlebar on
 * fullscreen exit — it keeps a normal window's titlebar below the menu bar, but
 * our full-size content window legitimately allowed the frame top at the screen
 * top. You cannot move a window inside a Space, so the origin captured at
 * willEnter (exit_window_frame.origin) is authoritative. Correct ONLY the
 * origin via setFrameOrigin — never setFrame the size: AppKit restores the
 * windowed frame through its own content = frame − titlebar model, so forcing our
 * captured full-size frame on top of that overshoots by a titlebar (the window
 * grows upward). A pure origin move cannot change the size. Only undo a small
 * nudge so we never fight a real position change. */
static void restore_pre_fullscreen_origin_if_nudged(NSWindow *window) {
    WindowMonitor *m = monitor_of((__bridge void *)window);
    if (!window || !m || !m->exit_window_frame_valid) return;
    if (window_in_fullscreen_space(window)) return;
    NSPoint want = m->exit_window_frame.origin;
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
    if (any_monitor_active()) return;
    [g_pump_timer invalidate];
    g_pump_timer = nil;
}

static void pump_tick_inner(void);

static void pump_tick(void) {
    if (g_in_pump) return;
    g_in_pump = YES;
    pump_tick_inner();
    g_in_pump = NO;
}

static void pump_tick_inner(void) {
    // Pump live DVUI frames through the WHOLE transition — enter and exit — of every window
    // animating. We sync the live contentView bounds into SDL every tick and the metal layer uses
    // kCAGravityResize, so the drawable scales to fill the morphing view (the same path that makes
    // EXIT look right). Previously the ENTER morph let AppKit scale a frozen snapshot, which raced
    // our one priming frame and gave inconsistent results (sometimes a stale strip-reserved
    // snapshot scaled up). Rendering live during enter removes that race; the titlebar strip is
    // already collapsed via space_entering, so there is no strip-gap to morph.
    BOOL any = NO;
    BOOL manual = NO;
    for (int i = 0; i < FIZZY_MAX_MONITORS; i++) {
        WindowMonitor *m = &g_monitors[i];
        if (!monitor_active(m)) continue;
        any = YES;
        if (m->pump_frames > 0) {
            m->pump_frames--;
            /* An un-zoom's animation is over with its frames, outside a Space transition: it
             * kept the pump (and every frame of the app) running for good once it ran out. */
            if (m->pump_frames == 0 && !m->space_transition) m->unzoom_animating = NO;
        }
        // While settling after a fullscreen EXIT, re-assert the pre-fullscreen origin
        // BEFORE rendering each frame. AppKit's exit restore nudges a top-anchored
        // window down a titlebar (it bypasses our constrainFrameRect override), and a
        // one-shot async correction shows that nudged frame for a beat ("pop down then
        // up"). Correcting every tick means the nudge never reaches the screen. The
        // helper no-ops once the origin already matches, so it cannot fight AppKit.
        if (m->exit_origin_guard > 0) {
            m->exit_origin_guard--;
            restore_pre_fullscreen_origin_if_nudged((__bridge NSWindow *)m->window);
        }
        fizzy_macos_window_sync_content_views(m->window);
        fizzy_macos_window_pump_sync(m->window);
        if (m->manual_live_resize) manual = YES;
    }
    if (!any) {
        stop_pump_if_idle();
        return;
    }
    /* One frame of the app a tick, whichever windows are animating: it draws them all. A manual
     * drag is already driven by SDL's own live-resize timer; a second frame per tick from here
     * only blocks the tracking loop on present. */
    if (!manual) fizzy_macos_window_pump_render();
}

static void request_resize_pump(void *nswindow, int frames) {
    WindowMonitor *m = monitor_of(nswindow);
    if (!m) return;
    if (frames > m->pump_frames) m->pump_frames = frames;

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
    WindowMonitor *m = monitor_of((__bridge void *)window);
    if (!m) return;
    BOOL zoomed = window.zoomed;
    if (m->zoom_state_valid && zoomed != m->was_zoomed) {
        /* Dragging a corner of a zoomed window un-zooms it too, but by hand: AppKit
         * animates nothing, and SDL's live-resize timer already renders every tick. */
        if (!m->manual_live_resize) {
            if (m->was_zoomed && !zoomed) m->unzoom_animating = YES;
            request_resize_pump((__bridge void *)window, 120);
        }
    }
    m->was_zoomed = zoomed;
    m->zoom_state_valid = YES;
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
    WindowMonitor *m = monitor_of(nswindow);
    if (!m) return;
    const int gen = m->transition_gen;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(3.0 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        WindowMonitor *w = monitor_of(nswindow);
        if (!w || gen != w->transition_gen) return;
        if (!w->space_transition) return;
        // The transition never reported did-enter/exit within the timeout —
        // typically toggleFullScreen: was dropped during app activation, which
        // leaves us pumping target-sized frames into a still-windowed window
        // (the "stretched window behind" artifact). Clear the stuck flags and
        // snap SDL/Metal back to the window's real content bounds.
        w->space_transition = NO;
        w->space_entering = NO;
        w->unzoom_animating = NO;
        fizzy_macos_window_commit_steady_state(nswindow);
        request_resize_pump(nswindow, 30);
    });
}

void fizzy_macos_window_space_stage(int stage, void *nswindow) {
    WindowMonitor *m = monitor_of(nswindow);
    if (!m) return;
    void *win = nswindow;
    m->transition_gen++;

    switch (stage) {
        case 0: // willEnter
            m->space_transition = YES;
            m->space_entering = YES;
            m->unzoom_animating = NO;
            schedule_transition_watchdog(win);
            {
                NSWindow *w = (__bridge NSWindow *)win;
                store_exit_target(w);
                double inset = titlebar_inset_for_window(w);
                m->windowed_titlebar_inset = (inset > 0 && inset <= 100.0) ? inset : 0;
            }
            /* After the windowed title bar's height is kept for the way back. */
            fizzy_macos_window_glass_toolbar(win, 0);
            fizzy_macos_window_reset_sync_cache(win);
            fizzy_macos_window_request_clear_frames(win, 5);
            request_resize_pump(win, 90);
            break;
        case 1: // didEnter
            m->space_transition = NO;
            m->space_entering = NO;
            fizzy_macos_window_commit_steady_state(win);
            fizzy_macos_window_request_clear_frames(win, 5);
            request_resize_pump(win, 15);
            break;
        case 2: // willExit
            m->space_transition = YES;
            m->space_entering = NO;
            m->unzoom_animating = YES;
            fizzy_macos_window_reset_sync_cache(win);
            fizzy_macos_window_request_clear_frames(win, 5);
            request_resize_pump(win, 90);
            schedule_transition_watchdog(win);
            break;
        case 3: // didExit
            m->space_transition = NO;
            m->space_entering = NO;
            m->unzoom_animating = NO;
            // Re-assert the pre-fullscreen origin on every pump tick for the settle
            // window, so AppKit's menu-bar nudge is corrected before each frame is
            // rendered and the "pop down then up" never reaches the screen. Origin
            // only — never size (forcing our captured full-size frame overshoots by
            // a titlebar; AppKit restores the correct size itself).
            m->exit_origin_guard = 30;
            fizzy_macos_window_commit_steady_state(win);
            fizzy_macos_window_request_clear_frames(win, 5);
            request_resize_pump(win, 30);
            dispatch_async(dispatch_get_main_queue(), ^{
                if (!monitor_of(win)) return;
                NSWindow *exit_win = (__bridge NSWindow *)win;
                restore_pre_fullscreen_origin_if_nudged(exit_win);
                fizzy_macos_window_glass_toolbar(win, 1);
                store_exit_target(exit_win);
                fizzy_macos_window_commit_steady_state(win);
                fizzy_macos_window_resize_cb(win);
                /* Frames for the window's opacity to fade in once AppKit has settled it: drawn only
                 * through the transition, the window sat opaque until the mouse moved. */
                request_resize_pump(win, 40);
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
    behavior &= ~(NSWindowCollectionBehavior)(NSWindowCollectionBehaviorFullScreenNone | NSWindowCollectionBehaviorFullScreenAuxiliary);
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
    WindowMonitor *m = monitor_of(nswindow);

    if (m && m->unzoom_animating) return 0;
    if (m && m->space_transition && !m->space_entering) return 0;

    if (m && m->space_entering) return 1;
    if (window_in_fullscreen_space(window)) return 1;

    return 0;
}

int fizzy_macos_window_space_transition_active(void *nswindow) {
    WindowMonitor *m = monitor_of(nswindow);
    return m && m->space_transition ? 1 : 0;
}

int fizzy_macos_window_space_entering(void *nswindow) {
    WindowMonitor *m = monitor_of(nswindow);
    return m && m->space_entering ? 1 : 0;
}

int fizzy_macos_window_space_has_target(void *nswindow) {
    WindowMonitor *m = monitor_of(nswindow);
    return m && m->space_transition ? 1 : 0;
}

double fizzy_macos_window_saved_titlebar_inset(void *nswindow) {
    WindowMonitor *m = monitor_of(nswindow);
    return m && m->windowed_titlebar_inset > 0 ? m->windowed_titlebar_inset : 0;
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
    return any_monitor_active() ? 1 : 0;
}

int fizzy_macos_window_unzoom_animating(void *nswindow) {
    WindowMonitor *m = monitor_of(nswindow);
    return m && m->unzoom_animating ? 1 : 0;
}

/* Whether `nswindow` is moving through a Space transition or an un-zoom: its live sizes are the
 * ones to push into SDL before each frame. */
int fizzy_macos_window_transition_sync_active(void *nswindow) {
    WindowMonitor *m = monitor_of(nswindow);
    return m && (m->space_transition || m->unzoom_animating) ? 1 : 0;
}

/* `nswindow`'s top left in SDL's global coordinates (points, from the top left of the primary
 * display): where SDL is told it is while AppKit moves it through a Space transition. */
void fizzy_macos_window_top_left(void *nswindow, int *out_x, int *out_y) {
    if (out_x) *out_x = 0;
    if (out_y) *out_y = 0;
    if (!nswindow) return;
    NSWindow *window = (__bridge NSWindow *)nswindow;
    NSRect f = window.frame;
    const CGFloat top = (CGFloat)CGDisplayPixelsHigh(kCGDirectMainDisplay);
    if (out_x) *out_x = (int)lrint(f.origin.x);
    if (out_y) *out_y = (int)lrint(top - (f.origin.y + f.size.height));
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
    WindowMonitor *m = monitor_of(nswindow);
    if (window_in_fullscreen_space(window) && m && m->exit_window_frame_valid) {
        f = m->exit_window_frame;
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
    BOOL force = monitor_active(monitor_of(nswindow));
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

/* Keep `token`, an observer `m` added, to remove when the window is forgotten. */
static void keep_observer(WindowMonitor *m, id token) {
    if (!m || !token || m->observer_count >= (int)(sizeof(m->observers) / sizeof(m->observers[0]))) return;
#if !__has_feature(objc_arc)
    [token retain];
#endif
    m->observers[m->observer_count++] = token;
}

/* Follow `nswindow` through Spaces, zooms and live resizes: the main window, and each float's own
 * window (fizzy's viewports), which go full screen in Spaces of their own as it does. Idempotent:
 * once per window. */
void fizzy_macos_window_install_resize_observer(void *nswindow) {
    if (!nswindow || monitor_of(nswindow)) return;
    WindowMonitor *m = NULL;
    for (int i = 0; i < FIZZY_MAX_MONITORS && !m; i++) {
        if (g_monitors[i].window == NULL) m = &g_monitors[i];
    }
    if (!m) return;
    memset(m, 0, sizeof(*m));
    m->window = nswindow;
    NSWindow *window = (__bridge NSWindow *)nswindow;
    install_constrain_override(window);
    store_exit_target(window);
    NSNotificationCenter *center = [NSNotificationCenter defaultCenter];
    NSOperationQueue *main = [NSOperationQueue mainQueue];

    keep_observer(m, [center addObserverForName:NSWindowWillEnterFullScreenNotification
                                         object:window
                                          queue:main
                                     usingBlock:^(__unused NSNotification *note) {
        fizzy_macos_window_space_stage(0, nswindow);
        fizzy_macos_window_resize_cb(nswindow);
    }]);
    keep_observer(m, [center addObserverForName:NSWindowDidEnterFullScreenNotification
                                         object:window
                                          queue:main
                                     usingBlock:^(__unused NSNotification *note) {
        fizzy_macos_window_space_stage(1, nswindow);
        fizzy_macos_window_resize_cb(nswindow);
    }]);
    keep_observer(m, [center addObserverForName:NSWindowWillExitFullScreenNotification
                                         object:window
                                          queue:main
                                     usingBlock:^(__unused NSNotification *note) {
        fizzy_macos_window_space_stage(2, nswindow);
        fizzy_macos_window_resize_cb(nswindow);
    }]);
    keep_observer(m, [center addObserverForName:NSWindowDidExitFullScreenNotification
                                         object:window
                                          queue:main
                                     usingBlock:^(__unused NSNotification *note) {
        fizzy_macos_window_space_stage(3, nswindow);
        fizzy_macos_window_resize_cb(nswindow);
    }]);

    for (NSString *name in @[
             NSWindowDidResizeNotification,
             NSWindowDidMoveNotification,
             NSWindowWillStartLiveResizeNotification,
             NSWindowDidEndLiveResizeNotification,
         ]) {
        keep_observer(m, [center addObserverForName:name
                                             object:window
                                              queue:main
                                         usingBlock:^(__unused NSNotification *note) {
            WindowMonitor *wm = monitor_of(nswindow);
            if (!wm) return;
            NSWindow *w = (__bridge NSWindow *)nswindow;
            // AppKit's exit nudge is a window MOVE; correct it the instant it lands
            // (not just on the next pump tick) so the nudged frame is never shown.
            // The helper no-ops once the origin matches, so the setFrameOrigin it
            // issues — which re-fires this notification — terminates immediately.
            if (wm->exit_origin_guard > 0) {
                restore_pre_fullscreen_origin_if_nudged(w);
            }
            if ([name isEqualToString:NSWindowDidResizeNotification]) fizzy_live_resize_trace_step(nswindow);
            if ([name isEqualToString:NSWindowWillStartLiveResizeNotification]) {
                wm->manual_live_resize = YES;
                if (!sdl_draws_live_resize(w)) fizzy_macos_window_live_resize_vsync(nswindow, 1);
            } else if ([name isEqualToString:NSWindowDidEndLiveResizeNotification]) {
                fizzy_macos_window_sync_content_views(nswindow);
                wm->manual_live_resize = NO;
                fizzy_macos_window_live_resize_vsync(nswindow, 0);
            }
            note_zoom_state(w);
            if (wm->manual_live_resize) {
                /* Vibrancy host only — SDL resizes its subviews and renders the
                 * frames during a manual live resize. */
                fizzy_macos_window_sync_content_views(nswindow);
            } else if (wm->space_transition || wm->unzoom_animating) {
                request_resize_pump(nswindow, 120);
                pump_tick();
            }
        }]);
    }
}

/* Stop following `nswindow` (a float's window, closing): its observers removed, its record free
 * for the next. */
void fizzy_macos_window_uninstall_monitor(void *nswindow) {
    WindowMonitor *m = monitor_of(nswindow);
    if (!m) return;
    NSNotificationCenter *center = [NSNotificationCenter defaultCenter];
    for (int i = 0; i < m->observer_count; i++) {
        [center removeObserver:m->observers[i]];
#if !__has_feature(objc_arc)
        [m->observers[i] release];
#endif
        m->observers[i] = nil;
    }
    memset(m, 0, sizeof(*m));
    stop_pump_if_idle();
}
