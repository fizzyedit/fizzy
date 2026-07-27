#import <AppKit/AppKit.h>
#import <stdbool.h>

/* Called from Zig when a native menu item is chosen. The int is the item's tag: its depth-first
 * index among `menu_model`'s command items. Zig resolves it back to a command id and runs it.
 * This replaced fourteen one-line forwarding methods, one per `NativeMenuAction` variant — the
 * enum and the methods existed only to carry this integer across the boundary. */
extern void FizzyNativeMenuAction(int tag);

/* Called from Zig for plugin-contributed native menu items (see `genericMenuAction:` below).
 * Zig looks the tag up against `host.native_menu_items`, resolved fresh at click time. */
extern void FizzyNativeMenuGenericAction(int tag);

/* Whether the model item with this tag is currently actionable (an active document, a non-empty
 * selection, …). Backed by the same predicate the dvui menu greys its row with. */
extern bool FizzyNativeMenuActionEnabled(int tag);

/* Current title for the model item with this tag, or NULL to leave it alone. AppKit menus are
 * retained state, so a label that depends on app state ("Show Explorer" / "Hide Explorer") has
 * to be refreshed; validation runs just before a menu displays, which is exactly the moment. */
extern const char *FizzyNativeMenuItemTitle(int tag);

/* True while the app is capturing a key chord (the Keyboard Shortcuts settings pane). AppKit
 * fires a menu item's key equivalent before the key reaches SDL, so blocking dvui events is not
 * enough — every item has to report disabled, which stops the key equivalent from performing. */
extern bool FizzyNativeMenuInputBlocked(void);

/* Called from Zig when a Recent Folders item is chosen; the tag is an index into the recents. */
extern void FizzyNativeRecentFolderAction(int index);

/* The app menu's "About fizzy" item is created by AppKit, not from the model, so it has no tag
 * to carry. It runs the same command as the Help menu's entry. */
extern void FizzyNativeMenuAboutAction(void);

@interface FizzyMenuTarget : NSObject <NSMenuItemValidation>
- (void)menuAction:(id)sender;
- (void)genericMenuAction:(id)sender;
- (void)recentFolderAction:(id)sender;
- (void)about:(id)sender;
@end

@implementation FizzyMenuTarget
- (void)menuAction:(id)sender {
    NSMenuItem *item = (NSMenuItem *)sender;
    FizzyNativeMenuAction((int)[item tag]);
}
- (void)genericMenuAction:(id)sender {
    NSMenuItem *item = (NSMenuItem *)sender;
    FizzyNativeMenuGenericAction((int)[item tag]);
}
- (void)recentFolderAction:(id)sender {
    NSMenuItem *item = (NSMenuItem *)sender;
    FizzyNativeRecentFolderAction((int)[item tag]);
}
/* The app menu's "About fizzy" is created by AppKit, not by the model, so it keeps its own
 * selector. It runs the same command as the Help menu's entry. */
- (void)about:(id)sender {
    (void)sender;
    FizzyNativeMenuAboutAction();
}
- (BOOL)validateMenuItem:(NSMenuItem *)menuItem {
    /* Checked before anything else so plugin and recents items are blocked too. */
    if (FizzyNativeMenuInputBlocked()) {
        return NO;
    }
    if ([menuItem action] == @selector(genericMenuAction:) ||
        [menuItem action] == @selector(recentFolderAction:) ||
        [menuItem action] == @selector(about:)) {
        return YES;
    }
    if ([menuItem action] != @selector(menuAction:)) {
        return YES;
    }
    const char *title = FizzyNativeMenuItemTitle((int)[menuItem tag]);
    if (title != NULL && title[0] != '\0') {
        [menuItem setTitle:[NSString stringWithUTF8String:title]];
    }
    return FizzyNativeMenuActionEnabled((int)[menuItem tag]) ? YES : NO;
}
@end

/* So Zig can get the SEL for setAction: without linking the Objective-C runtime directly. */
void *FizzyGetSelector(const char *name) {
    return (void *)sel_registerName(name);
}
