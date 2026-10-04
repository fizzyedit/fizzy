#import <AppKit/AppKit.h>
#import <QuartzCore/CAMetalLayer.h>
#import <QuartzCore/CATransaction.h>

/* macOS helpers for fizzy's native backend (`SDLBackend.zig`). Started as a copy of dvui's
 * `src/backends/macos_monitor.m`; the symbols carry fizzy's prefix so the two never collide.
 *
 * Scroll-source classifier:
 * SDL3's wheel event doesn't expose `[NSEvent hasPreciseScrollingDeltas]`, and the
 * magnitude-based heuristic in `Window.scrollWheelIndicated` can't reliably tell a
 * classic mouse wheel from a trackpad on macOS — AppKit splits a single wheel click
 * into many momentum-smoothed events, so the per-event delta isn't a stable signal.
 *
 * We install an NSEvent local monitor that runs ahead of SDL's event pump, reads the
 * precision flag verbatim from the NSEvent, and stashes it for the Zig side to query.
 * The handler returns the event unchanged so SDL still sees it. This updates per
 * scroll event, so users who switch between a trackpad and a mouse mid-session get
 * accurate classification on the very next scroll. */

static int g_is_precise = -1;

void fizzy_native_monitor_install(void) {
    static int installed = 0;
    if (installed) return;
    installed = 1;
    [NSEvent addLocalMonitorForEventsMatchingMask:NSEventMaskScrollWheel
                                          handler:^NSEvent * _Nullable(NSEvent * _Nonnull event) {
        g_is_precise = [event hasPreciseScrollingDeltas] ? 1 : 0;
        return event;
    }];
}

/* Returns -1 if no scroll event has been seen yet, 0 for classic mouse wheel,
 * 1 for trackpad / Magic Trackpad / Magic Mouse (any precise-deltas source). */
int fizzy_native_monitor_last_scroll_precise(void) {
    return g_is_precise;
}

/* AppKit draws a 1px separator under the titlebar by default
 * (NSTitlebarSeparatorStyleAutomatic). It's a fixed dark overlay, so it's
 * invisible over light window content but shows as a stark black hairline
 * over dark content/themes, independent of anything dvui paints there. */
void fizzy_native_disable_titlebar_separator(void *nswindow) {
    if (@available(macOS 11.0, *)) {
        ((NSWindow *)nswindow).titlebarSeparatorStyle = NSTitlebarSeparatorStyleNone;
    }
}

/* Whether AppKit is resizing the window under the user's pointer. Its tracking loop is then
 * running, and SDL runs frames from inside it: from its live-resize timer, and with
 * `SDL_VIDEO_MAC_SYNC_LIVE_RESIZE` from each resize step. */
int fizzy_native_in_live_resize(void *nswindow) {
    if (!nswindow) return 0;
    return ((__bridge NSWindow *)nswindow).inLiveResize ? 1 : 0;
}

/* The Metal view SDL adds under the window's content view when the window is claimed, whose
 * CAMetalLayer SDL_GPU presents into. SDL keeps no public handle to either. */
static NSView *find_metal_view(NSView *view) {
    if ([view.layer isKindOfClass:[CAMetalLayer class]]) return view;
    for (NSView *sub in view.subviews) {
        NSView *found = find_metal_view(sub);
        if (found) return found;
    }
    return nil;
}

static CAMetalLayer *find_metal_layer(NSView *view) {
    NSView *found = find_metal_view(view);
    return found ? (CAMetalLayer *)found.layer : nil;
}

/* fizzyedit/SDL's window listener (the window's delegate), with its live-resize patches. */
@protocol FizzySDLLiveResizeListener
- (BOOL)drawsLiveResizeInView:(NSView *)view;
@end

/* The Metal view, when SDL draws this window's live resize from AppKit's display of it
 * (`SDL_VIDEO_MAC_SYNC_LIVE_RESIZE` and fizzyedit/SDL's patches) and a live resize is running. */
static NSView *live_resize_drawn_view(void *nswindow) {
    if (!nswindow) return nil;
    NSWindow *window = (__bridge NSWindow *)nswindow;
    if (!window.inLiveResize || !window.contentView) return nil;
    NSView *view = find_metal_view(window.contentView);
    id delegate = window.delegate;
    if (!view || ![delegate respondsToSelector:@selector(drawsLiveResizeInView:)]) return nil;
    return [(id<FizzySDLLiveResizeListener>)delegate drawsLiveResizeInView:view] ? view : nil;
}

/* The next frame of a live resize when no resize step draws it (docs/MACOS_LIVE_RESIZE.md,
 * "Animating while no step comes").
 *
 * Inside AppKit's tracking loop SDL draws a frame at each resize step, from the Metal view's
 * display, and otherwise only from its 60 Hz timer, which asks for that display on a tick only
 * when no frame has started for a whole tick. The frame it asks for starts just after the tick,
 * so the next tick finds a little less than a tick since it and skips: as few as 30 frames a
 * second while the pointer rests, or pushes past the window's minimum size, whatever the app
 * wants. Nothing moves there, usually; but a fast drag to the minimum width folds the explorer
 * away just before reaching it, and its whole slide played at a quarter of a ProMotion display's
 * rate.
 *
 * So after each frame in a live resize the app says when it wants the next (`wait_s`, dvui's
 * wait; negative for not until an event), and this asks AppKit to display the view then, no
 * sooner than a display refresh after the frame began (`since_start_s` ago) — through the same
 * display a step draws from, so the frame is presented with its transaction like every other.
 * A frame that comes first (a step) re-arms it. After a step, the next one is given until a
 * second refresh to come: a drag's steps arrive about a refresh apart, and drawing just ahead of
 * each would double the frames the drag waits on. */
static NSTimer *g_live_resize_frame_timer = nil;
static NSSize g_live_resize_frame_size = {0, 0};

void fizzy_native_live_resize_next_frame(void *nswindow, double wait_s, double since_start_s) {
    [g_live_resize_frame_timer invalidate];
    g_live_resize_frame_timer = nil;
    NSView *view = live_resize_drawn_view(nswindow);
    if (!view) return;

    const NSSize size = view.bounds.size;
    const BOOL stepped = !NSEqualSizes(size, g_live_resize_frame_size);
    g_live_resize_frame_size = size;
    if (wait_s < 0) return;

    NSInteger fps = 60;
    if (@available(macOS 12.0, *)) {
        const NSInteger screen_fps = view.window.screen.maximumFramesPerSecond;
        if (screen_fps > 0) fps = screen_fps;
    }
    const double refresh_s = 1.0 / (double)fps;
    const double pace_s = stepped ? 2 * refresh_s : refresh_s;
    const double delay_s = MAX(0.0, MAX(wait_s, pace_s - since_start_s));

    g_live_resize_frame_timer = [NSTimer timerWithTimeInterval:delay_s
                                                       repeats:NO
                                                         block:^(NSTimer *timer) {
        if (timer != g_live_resize_frame_timer) return;
        g_live_resize_frame_timer = nil;
        [live_resize_drawn_view(nswindow) setNeedsDisplay:YES];
    }];
    [[NSRunLoop mainRunLoop] addTimer:g_live_resize_frame_timer forMode:NSRunLoopCommonModes];
}

static CAMetalLayer *metal_layer_of(void *nswindow) {
    if (!nswindow) return nil;
    NSWindow *window = (__bridge NSWindow *)nswindow;
    if (!window.contentView) return nil;
    return find_metal_layer(window.contentView);
}

/* The swapchain layer as SDL's Metal renderer kept it. SDL_GPU tags it sRGB
 * (`SwapchainCompositionToColorSpace`, on claim and on every
 * `SDL_SetGPUSwapchainParameters`); the renderer leaves it nil. A tagged layer is
 * colour-matched by the compositor, which shifts every colour against what the old backend
 * showed, so it goes back to nil. Call after claiming and after each swapchain-parameter
 * change. (A transparent window's layer is already not opaque: SDL makes the Metal view so.) */
void fizzy_native_metal_layer_prepare(void *nswindow) {
    CAMetalLayer *layer = metal_layer_of(nswindow);
    if (!layer) return;
    layer.colorspace = nil;
}

/* The swapchain layer's drawable size, which is what SDL's Metal renderer reports as its
 * output size (and what fizzy's AppKit sync keeps current mid-animation). 0 when there is
 * no layer yet. */
int fizzy_native_metal_drawable_size(void *nswindow, int *out_w, int *out_h) {
    CAMetalLayer *layer = metal_layer_of(nswindow);
    if (!layer) return 0;
    CGSize size = layer.drawableSize;
    if (size.width < 1.0 || size.height < 1.0) return 0;
    *out_w = (int)size.width;
    *out_h = (int)size.height;
    return 1;
}

/* A popped-out float's window put where its float is drawn this frame, in the Core Animation
 * transaction its picture there is presented in (`SDLBackend.renderPresent`): the window's frame
 * and the picture drawn for it change together. Moving and sizing it in two calls (SDL's position,
 * then its size) showed it moved and not yet sized for a moment, and a picture presented on its own
 * reached the screen a composite or more after the frame it was drawn for — both as jitter, worst
 * on the slow frames a resize brings. `fizzy_native_transaction_begin` before, the frame with
 * `fizzy_native_viewport_set_frame` (one `setFrame:`, SDL's top-left screen coordinates converted
 * as SDL converts them), present, `fizzy_native_viewport_presented`, then
 * `fizzy_native_transaction_commit`. SDL learns the window's new place and size from its own
 * listener, as it does a move or resize by the user. */
void fizzy_native_transaction_begin(void) {
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
}

void fizzy_native_transaction_commit(void) {
    [CATransaction commit];
}

void fizzy_native_viewport_transact(void *nswindow);

void fizzy_native_viewport_set_frame(void *nswindow, double x, double y, double w, double h) {
    @autoreleasepool {
        NSWindow *window = (__bridge NSWindow *)nswindow;
        if (window == nil) return;
        const CGFloat top = (CGFloat)CGDisplayPixelsHigh(kCGDirectMainDisplay);
        [window setFrame:NSMakeRect(x, top - y - h, w, h) display:NO animate:NO];
        fizzy_native_viewport_transact(nswindow);
    }
}

/* Its picture this frame presented in the open transaction, with whatever else changes about its
 * window in it (shown, ordered): `fizzy_native_viewport_presented` puts it back. */
void fizzy_native_viewport_transact(void *nswindow) {
    CAMetalLayer *layer = metal_layer_of(nswindow);
    if (layer) layer.presentsWithTransaction = YES;
}


void fizzy_native_viewport_presented(void *nswindow) {
    CAMetalLayer *layer = metal_layer_of(nswindow);
    if (layer) layer.presentsWithTransaction = NO;
}


