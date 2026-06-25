#import <AppKit/AppKit.h>

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
