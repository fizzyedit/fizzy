#import <AppKit/AppKit.h>
#import <QuartzCore/QuartzCore.h>

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
void fizzy_macos_window_sync_content_views(void *nswindow);

static BOOL g_zoom_state_valid = NO;
static BOOL g_was_zoomed = NO;
static BOOL g_unzoom_animating = NO;
static BOOL g_manual_live_resize = NO;
static BOOL g_space_transition = NO;
static BOOL g_enter_requested = NO;
static double g_enter_request_time = 0;
static int g_enter_attempts = 0;
static int g_transition_gen = 0;
static BOOL g_in_pump = NO;
static int g_pump_frames = 0;
static NSTimer *g_pump_timer = nil;
static void *g_pump_window = NULL;
static BOOL g_space_entering = NO;
static BOOL g_launch_space_restore = NO;
static BOOL g_enter_pending = NO;
static NSSize g_windowed_content_points = {0, 0};
static NSSize g_exit_target_points = {0, 0};
static NSRect g_exit_window_frame = {{0, 0}, {0, 0}};
static BOOL g_exit_window_frame_valid = NO;
static double g_windowed_titlebar_inset = 0;

void fizzy_macos_window_seed_windowed_content_points(double w, double h) {
    if (w >= 1.0 && h >= 1.0) {
        NSSize sz = NSMakeSize(w, h);
        g_windowed_content_points = sz;
        g_exit_target_points = sz;
    }
}

static BOOL live_resize_active(void) {
    return g_space_transition || g_unzoom_animating || g_pump_frames > 0;
}

static double titlebar_inset_for_window(NSWindow *window);

static BOOL window_in_fullscreen_space(NSWindow *window) {
    return (window.styleMask & NSWindowStyleMaskFullScreen) != 0;
}

static NSSize exit_content_size_for_window(NSWindow *window) {
    if (g_exit_target_points.width >= 1.0 && g_exit_target_points.height >= 1.0) {
        return g_exit_target_points;
    }
    if (g_exit_window_frame_valid && window) {
        NSRect content = [window contentRectForFrameRect:g_exit_window_frame];
        if (content.size.width >= 1.0 && content.size.height >= 1.0) {
            return content.size;
        }
    }
    if (g_windowed_content_points.width >= 1.0 && g_windowed_content_points.height >= 1.0) {
        return g_windowed_content_points;
    }
    return (NSSize){0, 0};
}

static void store_exit_target(NSWindow *window) {
    if (!window || window_in_fullscreen_space(window)) return;
    NSView *content = window.contentView;
    if (!content) return;
    NSSize bounds = content.bounds.size;
    if (bounds.width >= 1.0 && bounds.height >= 1.0) {
        g_windowed_content_points = bounds;
        g_exit_target_points = bounds;
        g_exit_window_frame = window.frame;
        g_exit_window_frame_valid = YES;
    }
}

static void note_windowed_content_size(NSWindow *window) {
    if (!window || window_in_fullscreen_space(window) || g_space_transition) return;
    NSView *content = window.contentView;
    if (!content) return;
    NSSize bounds = content.bounds.size;
    if (bounds.width >= 1.0 && bounds.height >= 1.0) {
        g_windowed_content_points = bounds;
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
    if (g_pump_frames > 0) g_pump_frames--;

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
        g_space_transition = NO;
        g_space_entering = NO;
        g_enter_pending = NO;
        g_unzoom_animating = NO;
        request_resize_pump(nswindow, 30);
    });
}

void fizzy_macos_window_space_stage(int stage, void *nswindow) {
    void *win = nswindow ?: g_pump_window;
    if (win) g_pump_window = win;
    g_transition_gen++;

    switch (stage) {
        case 0: // willEnter
            g_enter_requested = NO;
            g_enter_attempts = 0;
            g_enter_pending = NO;
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
            g_enter_requested = NO;
            g_space_transition = NO;
            g_space_entering = NO;
            g_enter_pending = NO;
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
            if (win) {
                store_exit_target((__bridge NSWindow *)win);
            }
            fizzy_macos_window_commit_steady_state();
            fizzy_macos_window_request_clear_frames(5);
            request_resize_pump(win, 30);
            dispatch_async(dispatch_get_main_queue(), ^{
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

void fizzy_macos_window_begin_launch_space_restore(void) {
    g_launch_space_restore = YES;
    g_enter_requested = NO;
    g_enter_attempts = 0;
}

void fizzy_macos_window_end_launch_space_restore(void) {
    g_launch_space_restore = NO;
}

void fizzy_macos_window_pump_launch(void *nswindow) {
    if (nswindow) g_pump_window = nswindow;
    pump_tick();
    [[NSRunLoop mainRunLoop] runMode:NSDefaultRunLoopMode
                          beforeDate:[NSDate dateWithTimeIntervalSinceNow:1.0 / 120.0]];
}

int fizzy_macos_window_enter_fullscreen_space(void *nswindow) {
    if (!nswindow) return 0;
    NSWindow *window = (__bridge NSWindow *)nswindow;
    BOOL launch = g_launch_space_restore;
    if (window_in_fullscreen_space(window)) {
        g_enter_requested = NO;
        g_enter_attempts = 0;
        g_enter_pending = NO;
        return 1;
    }
    if (g_space_transition) {
        return launch ? 0 : 1;
    }

    double now = CACurrentMediaTime();
    if (g_enter_requested) {
        if (launch) return 0;
        if ((now - g_enter_request_time) < 0.5) {
            return 0;
        }
    }
    if (g_enter_attempts >= (launch ? 8 : 4)) {
        g_enter_requested = NO;
        g_enter_pending = NO;
        return 1;
    }
    if (!window.isVisible && !launch) return 0;

    [NSApp activateIgnoringOtherApps:YES];
    [window makeKeyAndOrderFront:nil];
    g_enter_requested = YES;
    g_enter_request_time = now;
    g_enter_attempts++;
    g_enter_pending = YES;
    store_exit_target(window);
    {
        double inset = titlebar_inset_for_window(window);
        g_windowed_titlebar_inset = (inset > 0 && inset <= 100.0) ? inset : 0;
    }
    [window toggleFullScreen:nil];
    request_resize_pump(nswindow, 90);
    return 0;
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
    if (g_space_transition && !g_space_entering && !g_enter_pending) return 0;

    if (g_space_entering || g_enter_pending) return 1;
    if (window_in_fullscreen_space(window)) return 1;

    return 0;
}

int fizzy_macos_window_space_transition_active(void) {
    return g_space_transition ? 1 : 0;
}

int fizzy_macos_window_space_entering(void) {
    return (g_space_entering || g_enter_pending) ? 1 : 0;
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

void fizzy_macos_window_read_windowed_bounds(void *nswindow, double *out_w, double *out_h) {
    if (out_w) *out_w = 0;
    if (out_h) *out_h = 0;
    if (!nswindow) return;
    NSWindow *window = (__bridge NSWindow *)nswindow;
    if (window_in_fullscreen_space(window) || g_space_transition) return;
    NSView *content = window.contentView;
    if (!content) return;
    NSSize bounds = content.bounds.size;
    if (out_w) *out_w = bounds.width;
    if (out_h) *out_h = bounds.height;
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

void fizzy_macos_window_install_resize_observer(void *nswindow) {
    if (!nswindow) return;
    static char installed = 0;
    if (installed) return;
    installed = 1;
    g_pump_window = nswindow;
    NSWindow *window = (__bridge NSWindow *)nswindow;
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
             NSWindowWillStartLiveResizeNotification,
             NSWindowDidEndLiveResizeNotification,
         ]) {
        [center addObserverForName:name
                            object:window
                             queue:main
                        usingBlock:^(__unused NSNotification *note) {
            NSWindow *w = (__bridge NSWindow *)nswindow;
            if ([name isEqualToString:NSWindowWillStartLiveResizeNotification]) {
                g_manual_live_resize = YES;
            } else if ([name isEqualToString:NSWindowDidEndLiveResizeNotification]) {
                fizzy_macos_window_sync_content_views(nswindow);
                g_manual_live_resize = NO;
            }
            note_windowed_content_size(w);
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
