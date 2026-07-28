//! The menu bar, once.
//!
//! Both menu bars are rendered from this one tree: `Menu.zig` draws it with dvui, and
//! `backend_native.buildMenuBar` builds the macOS `NSMenu` from it. Neither owns a list of
//! items, so an entry added here appears in both by construction — which is the whole point.
//! Before this, every item was written out in both places (plus an `NSMenuItem` selector, an
//! `NativeMenuAction` variant, and an Objective-C forwarding method), and the two had already
//! drifted: the macOS View menu said "Show Explorer" even when the explorer was open, and
//! Recent Folders existed only in the dvui menu.
//!
//! An item names a **command** and nothing else — see `Keybinds.shell_commands`. Titles,
//! enablement and shortcuts are either declared here once or derived from the command, never
//! restated per platform.

const std = @import("std");
const dvui = @import("dvui");
const fizzy = @import("../fizzy.zig");

const Editor = @import("Editor.zig");

/// A label that depends on state ("Show Explorer" / "Hide Explorer").
pub const Title = union(enum) {
    // Null-terminated: these strings are handed straight to `NSString stringWithUTF8String:`.
    static: [:0]const u8,
    dynamic: *const fn (*Editor) [:0]const u8,

    pub fn resolve(self: Title, editor: *Editor) [:0]const u8 {
        return switch (self) {
            .static => |s| s,
            .dynamic => |f| f(editor),
        };
    }

    /// Title to stamp on a menu item at build time, before there is an `Editor` to ask. A
    /// dynamic title gets refreshed by `FizzyNativeMenuItemTitle` each time the menu opens, so
    /// this placeholder is only ever on screen if that path fails.
    pub fn resolveStatic(self: Title) [:0]const u8 {
        return switch (self) {
            .static => |s| s,
            .dynamic => "",
        };
    }
};

pub const CommandItem = struct {
    /// Registered command id. `Menu.zig` and the menu-bar click path both just run this.
    id: []const u8,
    title: Title,
    /// SF Symbol name for the macOS item. dvui rows don't draw icons today.
    sf_symbol: ?[:0]const u8 = null,
    /// Hidden entirely when false. The dvui menu is immediate-mode so it simply skips the row;
    /// AppKit menus are retained, so the native side disables the item instead of rebuilding
    /// the whole bar every frame.
    visible: ?*const fn (*Editor) bool = null,
    /// Greyed out when false. Null means always enabled.
    enabled: ?*const fn (*Editor) bool = null,
    /// Keep the macOS item enabled even when `enabled` says otherwise.
    ///
    /// A disabled `NSMenuItem` does not perform its key equivalent, and on macOS that key
    /// equivalent is the *only* way `cmd+c` reaches the app at all — AppKit consumes it before
    /// SDL sees it. Greying Copy out because the active document can't copy would therefore also
    /// stop Copy from reaching a focused search box or the Output Panel, which handle it
    /// themselves. The dvui menu has no such constraint and greys them normally.
    native_always_enabled: bool = false,
};

pub const Submenu = struct {
    /// Host `MenuContribution` id. Namespaced `fizzy.` like every other shell-owned id — the
    /// commands (`fizzy.copy`), the pseudo-plugin (`.id = "fizzy"`), all of it. These were
    /// `shell.menu.*` (and, for File, `workbench.menu.file`, a leftover from when the File menu
    /// really was a workbench contribution), which meant the same owner went by three names.
    id: []const u8,
    /// Ids this menu used to have. Plugins target a menu by `parent_menu_id`, and that is a
    /// published contract — `sdk/regions.zig` documents the old spellings and shipped plugins
    /// use them — so renaming without accepting the old names would silently drop a
    /// third-party plugin's menu section with no error anywhere.
    aliases: []const []const u8 = &.{},
    title: [:0]const u8,
    items: []const Item,
};

pub const Item = union(enum) {
    command: CommandItem,
    separator,
    submenu: Submenu,
    /// The recents list, filled at draw time from `editor.recents`.
    recent_folders,
    /// Plugin-contributed section parented to this menu id (e.g. "fizzy.menu.edit").
    plugin_section: []const u8,
};

// ---- predicates -------------------------------------------------------------------------------
//
// One copy each. These used to exist twice over: as inline expressions in `Menu.zig` and again
// as arms of `FizzyNativeMenuActionEnabled`, whose own doc comment admitted it "mirrors the exact
// greying conditions `Menu.zig` already computes".

fn hasActiveDoc(editor: *Editor) bool {
    return editor.activeDoc() != null;
}

fn canSave(editor: *Editor) bool {
    const doc = editor.activeDoc() orelse return false;
    return doc.owner.isDirty(doc) or !doc.owner.documentHasRecognizedSaveExtension(doc);
}

fn canSaveAll(editor: *Editor) bool {
    for (editor.open_files.values()) |doc| {
        if (doc.owner.isDirty(doc) and doc.owner.documentHasRecognizedSaveExtension(doc)) return true;
    }
    return false;
}

fn canUndo(editor: *Editor) bool {
    const doc = editor.activeDoc() orelse return false;
    return doc.owner.canUndo(doc);
}

fn canRedo(editor: *Editor) bool {
    const doc = editor.activeDoc() orelse return false;
    return doc.owner.canRedo(doc);
}

fn hasCopy(editor: *Editor) bool {
    return editor.activeDocHasCommand("copy");
}

fn hasPaste(editor: *Editor) bool {
    return editor.activeDocHasCommand("paste");
}

/// Mirrors `Keybinds.cmdCopyEnabled`/`cmdPasteEnabled`: the document owner reports its verb
/// enabled only while its own editor holds focus, so a focused non-document text input is the
/// other case where Edit > Copy/Paste still does something (`Keybinds.clipboardVerb`).
fn copyEnabled(editor: *Editor) bool {
    return editor.activeDocCommandEnabled("copy") or editor.text_input_focused;
}

fn pasteEnabled(editor: *Editor) bool {
    return editor.activeDocCommandEnabled("paste") or editor.text_input_focused;
}

fn explorerTitle(editor: *Editor) [:0]const u8 {
    return if (editor.explorer.closed) "Show Explorer" else "Hide Explorer";
}

// ---- the menu bar -----------------------------------------------------------------------------

const file_items = [_]Item{
    .{ .command = .{ .id = "fizzy.newFile", .title = .{ .static = "New File…" }, .sf_symbol = "doc.badge.plus" } },
    .{ .command = .{ .id = "fizzy.openFolder", .title = .{ .static = "Open Folder" }, .sf_symbol = "folder" } },
    // Not "doc.on.doc": that is the system's Copy glyph, which the Edit menu below uses.
    .{ .command = .{ .id = "fizzy.openFiles", .title = .{ .static = "Open Files" }, .sf_symbol = "doc.text" } },
    .separator,
    .recent_folders,
    .separator,
    .{ .command = .{ .id = "fizzy.save", .title = .{ .static = "Save" }, .sf_symbol = "square.and.arrow.down", .enabled = canSave } },
    .{ .command = .{ .id = "fizzy.saveAs", .title = .{ .static = "Save As…" }, .sf_symbol = "arrow.down.doc", .enabled = hasActiveDoc } },
    .{ .command = .{ .id = "fizzy.saveAll", .title = .{ .static = "Save All" }, .sf_symbol = "square.and.arrow.down.on.square", .enabled = canSaveAll } },
};

// The four SF Symbols below are the ones AppKit's own Edit menus use, so a fizzy Edit menu sits
// next to Finder's and TextEdit's without looking foreign.
const edit_items = [_]Item{
    .{ .command = .{
        .id = "fizzy.copy",
        .title = .{ .static = "Copy" },
        .sf_symbol = "doc.on.doc",
        .visible = hasCopy,
        .enabled = copyEnabled,
        .native_always_enabled = true,
    } },
    .{ .command = .{
        .id = "fizzy.paste",
        .title = .{ .static = "Paste" },
        .sf_symbol = "doc.on.clipboard",
        .visible = hasPaste,
        .enabled = pasteEnabled,
        .native_always_enabled = true,
    } },
    .separator,
    .{ .command = .{ .id = "fizzy.undo", .title = .{ .static = "Undo" }, .sf_symbol = "arrow.uturn.backward", .enabled = canUndo } },
    .{ .command = .{ .id = "fizzy.redo", .title = .{ .static = "Redo" }, .sf_symbol = "arrow.uturn.forward", .enabled = canRedo } },
    // Transform / Grid Layout are pixel-art concepts, not shell ones — pixi parents its own
    // section here rather than the shell knowing about them.
    .{ .plugin_section = "fizzy.menu.edit" },
};

const view_items = [_]Item{
    .{ .command = .{ .id = "fizzy.toggleExplorer", .title = .{ .dynamic = explorerTitle } } },
    .{ .plugin_section = "fizzy.menu.view" },
    .separator,
    .{ .command = .{ .id = "fizzy.showDvuiDemo", .title = .{ .static = "Show DVUI Demo" } } },
};

const help_items = [_]Item{
    // The About dialog hosts the update check and install controls, which is why this and the
    // macOS app menu's "About fizzy" are the same command.
    .{ .command = .{ .id = "fizzy.about", .title = .{ .static = "Check for Updates…" } } },
    .separator,
    .{ .command = .{ .id = "fizzy.reportBug", .title = .{ .static = "Report Bug…" }, .sf_symbol = "ant.fill" } },
};

pub const menu_bar = [_]Submenu{
    .{ .id = "fizzy.menu.file", .aliases = &.{"workbench.menu.file"}, .title = "File", .items = &file_items },
    .{ .id = "fizzy.menu.edit", .aliases = &.{"shell.menu.edit"}, .title = "Edit", .items = &edit_items },
    .{ .id = "fizzy.menu.view", .aliases = &.{"shell.menu.view"}, .title = "View", .items = &view_items },
    .{ .id = "fizzy.menu.help", .aliases = &.{"shell.menu.help"}, .title = "Help", .items = &help_items },
};

/// Whether a plugin's `parent_menu_id` refers to `sub`, under its current id or a legacy one.
pub fn menuMatches(sub: Submenu, parent_menu_id: []const u8) bool {
    if (std.mem.eql(u8, sub.id, parent_menu_id)) return true;
    for (sub.aliases) |a| {
        if (std.mem.eql(u8, a, parent_menu_id)) return true;
    }
    return false;
}

/// The menu a plugin's `parent_menu_id` targets, or null.
pub fn submenuFor(parent_menu_id: []const u8) ?Submenu {
    for (menu_bar) |sub| {
        if (menuMatches(sub, parent_menu_id)) return sub;
    }
    return null;
}

// ---- flat command index -----------------------------------------------------------------------
//
// The macOS side needs one integer per item to carry across the C boundary (an `NSMenuItem` tag),
// which is what `NativeMenuAction` and its fourteen Objective-C forwarding methods used to be.
// A depth-first index into this tree serves the same purpose and costs nothing to maintain: a new
// menu item is one line above, not a line here plus an enum variant plus a selector plus a method.

fn countCommands(items: []const Item) usize {
    var n: usize = 0;
    for (items) |it| {
        switch (it) {
            .command => n += 1,
            .submenu => |s| n += countCommands(s.items),
            else => {},
        }
    }
    return n;
}

fn appendCommands(out: []CommandItem, at: *usize, items: []const Item) void {
    for (items) |it| {
        switch (it) {
            .command => |c| {
                out[at.*] = c;
                at.* += 1;
            },
            .submenu => |s| appendCommands(out, at, s.items),
            else => {},
        }
    }
}

/// Every command item, depth-first in menu order. The index *is* the macOS tag.
pub const flat_commands: []const CommandItem = blk: {
    var total: usize = 0;
    for (menu_bar) |m| total += countCommands(m.items);

    var out: [total]CommandItem = undefined;
    var at: usize = 0;
    for (menu_bar) |m| appendCommands(&out, &at, m.items);
    const frozen = out;
    break :blk &frozen;
};

/// The command item a macOS tag refers to, or null if the tag is stale.
pub fn byTag(tag: usize) ?CommandItem {
    if (tag >= flat_commands.len) return null;
    return flat_commands[tag];
}

/// Whether `id` appears in the menu bar at all. On macOS this answers "does an `NSMenuItem` key
/// equivalent already dispatch this command", which `Keybinds.dispatch` needs so it doesn't run
/// the action a second time.
pub fn contains(id: []const u8) bool {
    for (flat_commands) |c| {
        if (std.mem.eql(u8, c.id, id)) return true;
    }
    return false;
}
