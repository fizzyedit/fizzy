#import <AppKit/AppKit.h>
#import <stdbool.h>

/* Called from Zig when a native menu item is chosen. Zig exports this and sets a pending action. */
extern void FizzyNativeMenuAction(int id);

/* Called from Zig for plugin-contributed native menu items (see `genericMenuAction:` below).
 * Zig looks the tag up against `host.native_menu_items`, resolved fresh at click time. */
extern void FizzyNativeMenuGenericAction(int tag);

/* Called from Zig's `validateMenuItem:` below with the clicked item's `tag` (a `NativeMenuAction`
 * value, set on each fixed item by `addNativeMenuItem`/`setupMacOSMenuBar`) — returns whether
 * that action currently does anything (an active document, a non-empty selection, …). */
extern bool FizzyNativeMenuActionEnabled(int id);

@interface FizzyMenuTarget : NSObject <NSMenuItemValidation>
- (void)newFile:(id)sender;
- (void)openFolder:(id)sender;
- (void)openFiles:(id)sender;
- (void)save:(id)sender;
- (void)saveAs:(id)sender;
- (void)saveAll:(id)sender;
- (void)copy:(id)sender;
- (void)paste:(id)sender;
- (void)undo:(id)sender;
- (void)redo:(id)sender;
- (void)toggleExplorer:(id)sender;
- (void)showDvuiDemo:(id)sender;
- (void)about:(id)sender;
- (void)checkForUpdates:(id)sender;
- (void)reportBug:(id)sender;
- (void)genericMenuAction:(id)sender;
@end

@implementation FizzyMenuTarget
- (void)newFile:(id)sender       { (void)sender; FizzyNativeMenuAction(11); }
- (void)openFolder:(id)sender     { (void)sender; FizzyNativeMenuAction(0); }
- (void)openFiles:(id)sender     { (void)sender; FizzyNativeMenuAction(1); }
- (void)save:(id)sender          { (void)sender; FizzyNativeMenuAction(2); }
- (void)saveAs:(id)sender        { (void)sender; FizzyNativeMenuAction(10); }
- (void)saveAll:(id)sender       { (void)sender; FizzyNativeMenuAction(16); }
- (void)copy:(id)sender          { (void)sender; FizzyNativeMenuAction(3); }
- (void)paste:(id)sender         { (void)sender; FizzyNativeMenuAction(4); }
- (void)undo:(id)sender          { (void)sender; FizzyNativeMenuAction(5); }
- (void)redo:(id)sender         { (void)sender; FizzyNativeMenuAction(6); }
- (void)toggleExplorer:(id)sender { (void)sender; FizzyNativeMenuAction(8); }
- (void)showDvuiDemo:(id)sender  { (void)sender; FizzyNativeMenuAction(9); }
- (void)about:(id)sender         { (void)sender; FizzyNativeMenuAction(13); }
- (void)checkForUpdates:(id)sender { (void)sender; FizzyNativeMenuAction(14); }
- (void)reportBug:(id)sender    { (void)sender; FizzyNativeMenuAction(15); }
- (void)genericMenuAction:(id)sender {
    NSMenuItem *item = (NSMenuItem *)sender;
    FizzyNativeMenuGenericAction((int)[item tag]);
}
- (BOOL)validateMenuItem:(NSMenuItem *)menuItem {
    /* Plugin-contributed items (Transform, Grid Layout, …) share this same target but tag
     * themselves with an index into `host.native_menu_items`, not a `NativeMenuAction` — greying
     * those out isn't part of this validator. */
    if ([menuItem action] == @selector(genericMenuAction:)) {
        return YES;
    }
    return FizzyNativeMenuActionEnabled((int)[menuItem tag]) ? YES : NO;
}
@end

/* So Zig can get the SEL for setAction: without linking the Objective-C runtime directly. */
void *FizzyGetSelector(const char *name) {
    return (void *)sel_registerName(name);
}
