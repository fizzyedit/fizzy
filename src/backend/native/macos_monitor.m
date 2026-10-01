#import <AppKit/AppKit.h>
#import <QuartzCore/CAMetalLayer.h>

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

/* The CAMetalLayer SDL_GPU presents into: the layer of the Metal view SDL adds under the
 * window's content view when the window is claimed. SDL keeps no public handle to it. */
static CAMetalLayer *find_metal_layer(NSView *view) {
    if ([view.layer isKindOfClass:[CAMetalLayer class]]) return (CAMetalLayer *)view.layer;
    for (NSView *sub in view.subviews) {
        CAMetalLayer *found = find_metal_layer(sub);
        if (found) return found;
    }
    return nil;
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
 * showed, so it goes back to nil. And a transparent window's layer must not be opaque: SDL
 * made the Metal view while the window was claimed as an opaque one (`GpuRenderer`'s
 * `liftTransparentFlag`). Call after claiming and after each swapchain-parameter change. */
void fizzy_native_metal_layer_prepare(void *nswindow, int transparent) {
    CAMetalLayer *layer = metal_layer_of(nswindow);
    if (!layer) return;
    layer.colorspace = nil;
    if (transparent) layer.opaque = NO;
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
