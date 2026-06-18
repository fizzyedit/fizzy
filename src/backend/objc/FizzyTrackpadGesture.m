#import <AppKit/AppKit.h>

// Trackpad pinch (NSEventTypeMagnify) is a macOS-specific NSEvent that does NOT come
// through SDL — SDL3 dropped the SDL2 multi-gesture API and never replaced it. We tap
// into AppKit directly with an application-wide local event monitor and forward the
// per-event magnification delta into Zig, which accumulates it for the canvas widget
// to drain each frame.
//
// Local monitors run on the thread that pumps NSApp events. SDL runs that pump on the
// main thread, which is also where Zig consumes the accumulator — so the callback is
// effectively single-threaded from the consumer's perspective. We still return the
// event from the handler (rather than nil) so SDL keeps receiving it; SDL3 ignores
// magnify events, so this is purely defensive against future SDL changes.

extern void FizzyTrackpadMagnification(double delta);

static id g_magnify_monitor = nil;

void FizzyInstallTrackpadGestureMonitor(void) {
    if (g_magnify_monitor != nil) return;
    g_magnify_monitor = [NSEvent addLocalMonitorForEventsMatchingMask:NSEventMaskMagnify
                                                              handler:^NSEvent *(NSEvent *event) {
        double m = (double)[event magnification];
        if (m != 0.0) {
            FizzyTrackpadMagnification(m);
        }
        return event;
    }];
}
