#import <AppKit/AppKit.h>
#import <QuartzCore/QuartzCore.h>
#include <stdlib.h>
#include <string.h>

/* A live resize seen from the inside, with FIZZY_LIVE_RESIZE_TRACE=1 (docs/MACOS_LIVE_RESIZE.md):
 * one line on stderr per resize step (the window monitor's NSWindowDidResize observer) and per
 * frame drawn inside AppKit's tracking loop (SDLBackend.live_resize_trace), on CACurrentMediaTime's
 * clock — the host clock a ScreenCaptureKit recording stamps its frames with, so the two line up
 * (scripts/live-resize/). */

static int g_trace = -1;

int fizzy_live_resize_trace_enabled(void) {
    if (g_trace < 0) {
        const char *v = getenv("FIZZY_LIVE_RESIZE_TRACE");
        g_trace = (v && v[0] && strcmp(v, "0") != 0) ? 1 : 0;
    }
    return g_trace;
}

double fizzy_live_resize_now(void) {
    return CACurrentMediaTime();
}

static CAMetalLayer *trace_find_metal_layer(NSView *view) {
    if ([view.layer isKindOfClass:[CAMetalLayer class]]) return (CAMetalLayer *)view.layer;
    for (NSView *sub in view.subviews) {
        CAMetalLayer *found = trace_find_metal_layer(sub);
        if (found) return found;
    }
    return nil;
}

/* out: window frame w,h (points); Metal layer bounds w,h (points); its drawableSize w,h (pixels);
 * its presentsWithTransaction, which is on only for a frame SDL draws from AppKit's display of
 * the view; and the window's inLiveResize. */
void fizzy_live_resize_probe(void *nswindow, double *out) {
    for (int i = 0; i < 8; i++) out[i] = 0;
    if (!nswindow) return;
    NSWindow *window = (__bridge NSWindow *)nswindow;
    out[0] = window.frame.size.width;
    out[1] = window.frame.size.height;
    CAMetalLayer *layer = window.contentView ? trace_find_metal_layer(window.contentView) : nil;
    if (layer) {
        out[2] = layer.bounds.size.width;
        out[3] = layer.bounds.size.height;
        out[4] = layer.drawableSize.width;
        out[5] = layer.drawableSize.height;
        out[6] = layer.presentsWithTransaction ? 1 : 0;
    }
    out[7] = window.inLiveResize ? 1 : 0;
}

void fizzy_live_resize_trace_step(void *nswindow) {
    if (!fizzy_live_resize_trace_enabled() || !nswindow) return;
    NSWindow *window = (__bridge NSWindow *)nswindow;
    if (!window.inLiveResize) return;
    double p[8];
    fizzy_live_resize_probe(nswindow, p);
    fprintf(stderr, "[lr] %.6f step  win=%.0fx%.0f layer=%.0fx%.0f drawable=%.0fx%.0f\n",
            CACurrentMediaTime(), p[0], p[1], p[2], p[3], p[4], p[5]);
}
