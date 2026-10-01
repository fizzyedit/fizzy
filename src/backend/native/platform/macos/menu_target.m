#import <AppKit/AppKit.h>
#import <stdbool.h>

/* The menu bar's target (`platform/menu.zig`). Every item the app builds is in one part of the bar
 * — its fixed menus, what it added at run time, or a list submenu — told apart by the item's
 * action, and carries the app's tag for it; those two numbers are all that crosses to Zig. */

enum { section_bar = 0, section_extra = 1, section_list = 2 };

/* An item chosen. `from_key`: by its key equivalent, not a click — AppKit then also hands the
 * keystroke on to the window, so the app must not synthesize a second one. */
extern void FizzyMenuActivated(int section, int tag, bool from_key);
/* Whether the item can be chosen now: asked just before its menu shows, the only way to grey an
 * NSMenuItem (and a disabled one does not perform its key equivalent). */
extern bool FizzyMenuEnabled(int section, int tag);
/* The item's title now, or NULL to leave it: menus are retained state, so a label that follows
 * the app has to be refreshed, and validation is the moment before it shows. */
extern const char *FizzyMenuTitle(int section, int tag);
/* True while the app must not act on keys (capturing a shortcut): every item reports disabled. */
extern bool FizzyMenuInputBlocked(void);
/* The app menu's About, which AppKit creates and the app routes to its own. */
extern void FizzyMenuAbout(void);

@interface FizzyMenuTarget : NSObject <NSMenuItemValidation>
- (void)barAction:(id)sender;
- (void)extraAction:(id)sender;
- (void)listAction:(id)sender;
- (void)about:(id)sender;
@end

static bool fromKey(void) {
    NSEvent *ev = [NSApp currentEvent];
    return ev != nil && [ev type] == NSEventTypeKeyDown;
}

@implementation FizzyMenuTarget
- (void)barAction:(id)sender {
    FizzyMenuActivated(section_bar, (int)[(NSMenuItem *)sender tag], fromKey());
}
- (void)extraAction:(id)sender {
    FizzyMenuActivated(section_extra, (int)[(NSMenuItem *)sender tag], fromKey());
}
- (void)listAction:(id)sender {
    FizzyMenuActivated(section_list, (int)[(NSMenuItem *)sender tag], false);
}
- (void)about:(id)sender {
    (void)sender;
    FizzyMenuAbout();
}
- (BOOL)validateMenuItem:(NSMenuItem *)menuItem {
    /* Before anything else, so every part of the bar is blocked. */
    if (FizzyMenuInputBlocked()) return NO;
    SEL action = [menuItem action];
    int section;
    if (action == @selector(barAction:)) section = section_bar;
    else if (action == @selector(extraAction:)) section = section_extra;
    else return YES; /* lists and About are always there to choose */
    const char *title = FizzyMenuTitle(section, (int)[menuItem tag]);
    if (title != NULL && title[0] != '\0') [menuItem setTitle:[NSString stringWithUTF8String:title]];
    return FizzyMenuEnabled(section, (int)[menuItem tag]) ? YES : NO;
}
@end

/* So Zig can get a SEL for setAction: without linking the Objective-C runtime directly. */
void *FizzyGetSelector(const char *name) {
    return (void *)sel_registerName(name);
}
