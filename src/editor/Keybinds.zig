//! Shell keybindings: the default bind table, the shell's own commands, and key dispatch.
//!
//! Keys used to be wired straight to `fizzy.editor.*` calls by a hardcoded if-chain, which meant
//! nothing was addressable by id and so nothing could be rebound. Now every shell action is a
//! registered `Command`, and `tick()` resolves a key event to a command id through
//! `keymap.Keymap` and runs it via the Host registry — the same registry plugin commands live
//! in, which is what makes a single rebindable table (and, later, a command palette) possible.
//!
//! **Migration shape.** dvui's `Window.keybinds` map is still the source of the *default* key
//! for each action: dvui seeds its own binds, `register()` below adds the shell's, and plugins
//! add theirs via `contributeKeybinds` — see `Editor.rebuildKeybinds`. `buildKeymap` then walks
//! that finished map and lifts every entry named in `command_binds` into a `Keymap` binding.
//! Keeping that direction means plugin-contributed binds (workbench's `save`, `open_folder`, …)
//! keep working untouched; they move to `Command.default_keys` in a later step.

const std = @import("std");
const builtin = @import("builtin");

const fizzy = @import("../fizzy.zig");
const dvui = @import("dvui");
const sdk = @import("fizzy_sdk");
const keymap = @import("keymap/keymap.zig");
const adapter = @import("keymap/dvui_adapter.zig");

pub const Keybinds = @This();

const Editor = @import("Editor.zig");
const KeybindSettings = @import("KeybindSettings.zig");

/// Register the shell's own global / navigation / region binds. File-management
/// binds and pixel-art editing binds are contributed by the workbench and
/// pixel-art plugins (their `contributeKeybinds`), which `Editor.postInit` invokes
/// after the plugins register. This runs during `Editor.init`, before postInit, so
/// the shell binds land first; the split is disjoint, so no `putNoClobber` clashes.
///
/// **That disjointness is load-bearing, and plugins claim more names than this repo shows.**
/// pixi (an out-of-tree plugin) registers `undo`, `redo` and `delete_selection_contents` in its
/// own `contributeKeybinds`; adding any of them here panics at startup on every install that has
/// pixi, because `putNoClobber` asserts. A first-come-first-served hash map has no way to express
/// "shell default unless a plugin wants it" — that needs the layered `Command.default_keys`
/// resolution in step C, not another entry in this function.
///
/// Runtime mac detection — `builtin.os.tag.isDarwin()` is `false` for
/// wasm32-freestanding, so macOS web users would otherwise get the Windows (Ctrl)
/// bindings. `fizzy.platform.isMacOS()` reads DVUI's `navigator.platform`-derived
/// choice on web and uses `os.tag` on native.
pub fn register() !void {
    const window = dvui.currentWindow();

    // Region toggles (explorer / workspace) and "New File" — Command on macOS, Control
    // elsewhere. "New File" is a generic shell action (see `Host.requestNewDocument`),
    // not owned by whichever editor plugin happens to be installed.
    //
    // "zoom" is the trackpad-scheme canvas modifier (cmd/ctrl + scroll to zoom). Shared
    // by every `CanvasWidget` consumer (image viewer, pixi, etc.) — not plugin-specific.
    if (fizzy.platform.isMacOS()) {
        try window.keybinds.putNoClobber(window.gpa, "explorer", .{ .command = true, .key = .e });
        try window.keybinds.putNoClobber(window.gpa, "workspace", .{ .command = true, .key = .w });
        try window.keybinds.putNoClobber(window.gpa, "new_file", .{ .command = true, .key = .n });
        try window.keybinds.putNoClobber(window.gpa, "zoom", .{ .command = true });
    } else {
        try window.keybinds.putNoClobber(window.gpa, "explorer", .{ .control = true, .key = .e });
        try window.keybinds.putNoClobber(window.gpa, "workspace", .{ .control = true, .key = .w });
        try window.keybinds.putNoClobber(window.gpa, "new_file", .{ .control = true, .key = .n });
        try window.keybinds.putNoClobber(window.gpa, "zoom", .{ .control = true });
    }

    try window.keybinds.putNoClobber(window.gpa, "shift", .{ .shift = true });

    try window.keybinds.putNoClobber(window.gpa, "up", .{ .key = .up });
    try window.keybinds.putNoClobber(window.gpa, "down", .{ .key = .down });
    try window.keybinds.putNoClobber(window.gpa, "left", .{ .key = .left });
    try window.keybinds.putNoClobber(window.gpa, "right", .{ .key = .right });

    try window.keybinds.putNoClobber(window.gpa, "cancel", .{ .key = .escape });
}

// ---- shell commands ---------------------------------------------------------------------------

/// `Host.runCommand` passes `owner.state` to `run`, so the shell needs *a* `Plugin` to hang its
/// commands off. This is that pseudo-plugin: never added to `host.plugins`, so no lifecycle hook
/// ever fires on it and `removeOwned` never touches its commands. The alternative — adding a
/// `state` field to `sdk.regions.Command` — would move the ABI fingerprint and force every
/// third-party plugin to be rebuilt, which isn't worth it for a pointer we can supply this way.
var shell_plugin: sdk.Plugin = .{
    .state = undefined, // set to the Editor in `registerCommands`
    .vtable = &shell_vtable,
    .id = "fizzy",
    .display_name = "Fizzy",
};

const shell_vtable: sdk.Plugin.VTable = .{};

fn editorFromState(state: *anyopaque) *Editor {
    return @ptrCast(@alignCast(state));
}

/// One shell action. `native_menu_on_macos` marks the commands macOS also fires through NSMenu
/// (`FizzyNativeMenuAction`): SDL still delivers the same key event, so dispatching it here too
/// would run the action twice. This preserves exactly the `builtin.os.tag != .macos` guards the
/// old if-chain had, per action rather than in one lump.
const ShellCommand = struct {
    id: []const u8,
    title: []const u8,
    /// dvui keybind name this action's default key comes from, or null when it has no default.
    bind: ?[]const u8,
    run: *const fn (state: *anyopaque) anyerror!void,
    isEnabled: ?*const fn (state: *anyopaque) bool = null,
    native_menu_on_macos: bool = false,
};

const shell_commands = [_]ShellCommand{
    .{ .id = "fizzy.openFolder", .title = "Open Folder…", .bind = "open_folder", .run = cmdOpenFolder, .native_menu_on_macos = true },
    .{ .id = "fizzy.openFiles", .title = "Open Files…", .bind = "open_files", .run = cmdOpenFiles, .native_menu_on_macos = true },
    .{ .id = "fizzy.newFile", .title = "New File…", .bind = "new_file", .run = cmdNewFile, .native_menu_on_macos = true },
    .{ .id = "fizzy.save", .title = "Save", .bind = "save", .run = cmdSave, .native_menu_on_macos = true },
    .{ .id = "fizzy.saveAs", .title = "Save As…", .bind = "save_as", .run = cmdSaveAs },
    .{ .id = "fizzy.saveAll", .title = "Save All", .bind = "save_all", .run = cmdSaveAll },
    .{ .id = "fizzy.undo", .title = "Undo", .bind = "undo", .run = cmdUndo, .isEnabled = cmdUndoEnabled, .native_menu_on_macos = true },
    .{ .id = "fizzy.redo", .title = "Redo", .bind = "redo", .run = cmdRedo, .isEnabled = cmdRedoEnabled, .native_menu_on_macos = true },
    .{ .id = "fizzy.copy", .title = "Copy", .bind = "copy", .run = cmdCopy, .isEnabled = cmdCopyEnabled, .native_menu_on_macos = true },
    .{ .id = "fizzy.paste", .title = "Paste", .bind = "paste", .run = cmdPaste, .isEnabled = cmdPasteEnabled, .native_menu_on_macos = true },
    .{ .id = "fizzy.toggleExplorer", .title = "Toggle Explorer", .bind = "explorer", .run = cmdToggleExplorer, .native_menu_on_macos = true },
    .{ .id = "fizzy.deleteSelection", .title = "Delete Selection", .bind = "delete_selection_contents", .run = cmdDeleteSelection, .isEnabled = cmdDeleteSelectionEnabled },
    .{ .id = "fizzy.accept", .title = "Accept", .bind = "activate", .run = cmdAccept, .isEnabled = cmdAcceptEnabled },
    .{ .id = "fizzy.cancel", .title = "Cancel", .bind = "cancel", .run = cmdCancel, .isEnabled = cmdCancelEnabled },
    // No dvui bind name — these are new, so their defaults come purely from the profile table.
    .{ .id = "fizzy.quickOpen", .title = "Go to File…", .bind = null, .run = cmdQuickOpen },
    .{ .id = "fizzy.commandPalette", .title = "Show All Commands", .bind = null, .run = cmdCommandPalette },
};

// Ids and bind names must both be unique: a duplicate id would make `Host.runCommand`
// dispatch to whichever was registered first, and a duplicate bind would silently give two
// commands the same key. Comptime because the table is comptime — a test would be strictly
// weaker than just refusing to compile.
comptime {
    for (shell_commands, 0..) |a, i| {
        for (shell_commands[i + 1 ..]) |b| {
            if (std.mem.eql(u8, a.id, b.id)) {
                @compileError("duplicate shell command id: " ++ a.id);
            }
            const a_bind = a.bind orelse continue;
            const b_bind = b.bind orelse continue;
            if (std.mem.eql(u8, a_bind, b_bind)) {
                @compileError("shell commands '" ++ a.id ++ "' and '" ++ b.id ++
                    "' both claim keybind '" ++ a_bind ++ "'");
            }
        }
    }
}

fn cmdOpenFolder(state: *anyopaque) anyerror!void {
    const editor = editorFromState(state);
    if (try dvui.dialogNativeFolderSelect(dvui.currentWindow().arena(), .{
        .title = "Open Project Folder",
    })) |folder| {
        try editor.setProjectFolder(folder);
    }
}

fn cmdOpenFiles(state: *anyopaque) anyerror!void {
    const editor = editorFromState(state);
    if (try dvui.dialogNativeFileOpenMultiple(
        dvui.currentWindow().arena(),
        .{ .title = "Open Files..." },
    )) |files| {
        for (files) |file| {
            _ = editor.openFilePath(file, editor.currentGroupingID()) catch {
                std.log.err("Failed to open file: {s}", .{file});
            };
        }
    }
}

fn cmdNewFile(state: *anyopaque) anyerror!void {
    editorFromState(state).requestNewFileDialog();
}
fn cmdSave(state: *anyopaque) anyerror!void {
    try editorFromState(state).save();
}
fn cmdSaveAs(state: *anyopaque) anyerror!void {
    editorFromState(state).requestSaveAs();
}
fn cmdSaveAll(state: *anyopaque) anyerror!void {
    try editorFromState(state).saveAll();
}
fn cmdUndo(state: *anyopaque) anyerror!void {
    try editorFromState(state).undo();
}
fn cmdRedo(state: *anyopaque) anyerror!void {
    try editorFromState(state).redo();
}
fn cmdCopy(state: *anyopaque) anyerror!void {
    try editorFromState(state).copy();
}
fn cmdPaste(state: *anyopaque) anyerror!void {
    try editorFromState(state).paste();
}
fn cmdDeleteSelection(state: *anyopaque) anyerror!void {
    editorFromState(state).deleteSelectedContents();
}
fn cmdAccept(state: *anyopaque) anyerror!void {
    try editorFromState(state).accept();
}
fn cmdCancel(state: *anyopaque) anyerror!void {
    try editorFromState(state).cancel();
}

fn cmdUndoEnabled(state: *anyopaque) bool {
    const doc = editorFromState(state).activeDoc() orelse return false;
    return doc.owner.canUndo(doc);
}
fn cmdRedoEnabled(state: *anyopaque) bool {
    const doc = editorFromState(state).activeDoc() orelse return false;
    return doc.owner.canRedo(doc);
}
fn cmdCopyEnabled(state: *anyopaque) bool {
    return editorFromState(state).activeDocCommandEnabled("copy");
}
fn cmdPasteEnabled(state: *anyopaque) bool {
    return editorFromState(state).activeDocCommandEnabled("paste");
}
fn cmdDeleteSelectionEnabled(state: *anyopaque) bool {
    return editorFromState(state).activeDocCommandEnabled("deleteSelection");
}
fn cmdAcceptEnabled(state: *anyopaque) bool {
    return editorFromState(state).activeDocCommandEnabled("acceptEdit");
}
fn cmdCancelEnabled(state: *anyopaque) bool {
    return editorFromState(state).activeDocCommandEnabled("cancelEdit");
}

fn cmdQuickOpen(state: *anyopaque) anyerror!void {
    editorFromState(state).command_palette.toggle(.files);
}
fn cmdCommandPalette(state: *anyopaque) anyerror!void {
    editorFromState(state).command_palette.toggle(.commands);
}

fn cmdToggleExplorer(state: *anyopaque) anyerror!void {
    const editor = editorFromState(state);
    if (editor.explorer.closed) editor.explorer.open() else editor.explorer.close();
}

/// Register every shell action in the Host command registry. Called once during `Editor.init`.
pub fn registerCommands(editor: *Editor) !void {
    shell_plugin.state = editor;
    inline for (shell_commands) |c| {
        try editor.host.registerCommand(.{
            .id = c.id,
            .owner = &shell_plugin,
            .title = c.title,
            .run = c.run,
            .isEnabled = c.isEnabled,
        });
    }
}

// ---- default profile ----------------------------------------------------------------------------

/// Which default keymap to start from. Only `vscode` ships today; the enum exists so adding
/// another is a data change rather than a structural one.
pub const Profile = enum { vscode };

/// A default binding, resolved per platform. `mod` is Command on macOS and Control elsewhere
/// (see `keymap.chord`), so most entries need only one spelling.
const DefaultBind = struct {
    command: []const u8,
    keys: []const u8,
    /// Overrides `keys` on macOS when the platforms genuinely differ (redo, mostly).
    keys_mac: ?[]const u8 = null,
};

/// VSCode-compatible shell defaults.
///
/// These live here rather than in `dvui.Window.keybinds` on purpose. That map is a flat global
/// namespace claimed with `putNoClobber`, so a default the shell wants and a plugin also wants
/// is a startup panic, not a conflict — which is exactly how registering `undo` here crashed
/// every install with pixi. The keymap is layered instead: a plugin's binding and a shell
/// default can both exist, and `Keymap.best` picks by source.
///
/// This also closes a real gap. `fizzy.undo` already routes through `activeDoc().owner.undo`,
/// so undo works for *any* document-owning plugin — but its only keyboard binding came from
/// pixi registering the name, meaning Ctrl+Z did nothing on an install without pixi.
const vscode_defaults = [_]DefaultBind{
    .{ .command = "fizzy.save", .keys = "mod+s" },
    .{ .command = "fizzy.saveAs", .keys = "mod+shift+s" },
    .{ .command = "fizzy.saveAll", .keys = "mod+alt+s" },
    .{ .command = "fizzy.newFile", .keys = "mod+n" },
    .{ .command = "fizzy.openFolder", .keys = "mod+f" },
    .{ .command = "fizzy.openFiles", .keys = "mod+o" },
    .{ .command = "fizzy.toggleExplorer", .keys = "mod+e" },
    .{ .command = "fizzy.undo", .keys = "mod+z" },
    // VSCode uses Ctrl+Y on Windows/Linux and Cmd+Shift+Z on macOS.
    .{ .command = "fizzy.redo", .keys = "ctrl+y", .keys_mac = "mod+shift+z" },
    .{ .command = "fizzy.quickOpen", .keys = "mod+p" },
    .{ .command = "fizzy.commandPalette", .keys = "mod+shift+p" },
};

/// C2-lite bridge: owner-scoped plugin defaults that still can't live on `Command.default_keys`
/// (ABI-gated). Added only when the Host command is registered. `owner_id` gates the binding
/// so shell profile chords (e.g. Quick Open on `mod+p`) win unless that plugin's document is
/// active. Retire these when C2 ships.
const plugin_owner_defaults = [_]struct {
    command: []const u8,
    owner_id: []const u8,
    keys: []const u8,
}{
    .{ .command = "pixi.export", .owner_id = "pixi", .keys = "mod+p" },
};

/// Document verbs: Fizzy owns the user-facing entry via `fizzy_id` (Copy, Paste, …), and a
/// plugin registers `"<owner>.<action>"` as the implementation that `runActiveDocCommand`
/// dispatches to. The chord is bound to the *Fizzy* command — `cmd+c` runs `fizzy.copy`, which
/// forwards to `pixi.copy` — so the plugin's own command genuinely has no binding of its own.
/// Both the palette (which hides the duplicate rows) and the Keyboard Shortcuts pane (which
/// shows the inherited chord) key off this table.
///
/// Verbs with `fizzy_id == null` (Transform, Grid Layout, …) have no universal Fizzy entry;
/// there is nothing for them to inherit.
pub const DocumentVerb = struct {
    action: []const u8,
    fizzy_id: ?[]const u8,
};

pub const document_verbs = [_]DocumentVerb{
    .{ .action = "copy", .fizzy_id = "fizzy.copy" },
    .{ .action = "paste", .fizzy_id = "fizzy.paste" },
    .{ .action = "undo", .fizzy_id = "fizzy.undo" },
    .{ .action = "redo", .fizzy_id = "fizzy.redo" },
    .{ .action = "deleteSelection", .fizzy_id = "fizzy.deleteSelection" },
    .{ .action = "acceptEdit", .fizzy_id = "fizzy.accept" },
    .{ .action = "cancelEdit", .fizzy_id = "fizzy.cancel" },
    .{ .action = "transform", .fizzy_id = null },
    .{ .action = "gridLayout", .fizzy_id = null },
};

pub fn commandActionSuffix(id: []const u8) []const u8 {
    if (std.mem.lastIndexOfScalar(u8, id, '.')) |dot| return id[dot + 1 ..];
    return id;
}

/// The Fizzy command whose chord actually reaches `id`, when `id` is a plugin's implementation
/// of a document verb and has no chord of its own. Null for shell commands and for verbs with
/// no universal Fizzy entry.
pub fn inheritedChordSource(id: []const u8) ?[]const u8 {
    // A `fizzy.*` command is the source, never the inheritor.
    if (std.mem.startsWith(u8, id, "fizzy.")) return null;
    const suffix = commandActionSuffix(id);
    for (document_verbs) |v| {
        if (!std.mem.eql(u8, v.action, suffix)) continue;
        return v.fizzy_id;
    }
    return null;
}

fn defaultsFor(profile: Profile) []const DefaultBind {
    return switch (profile) {
        .vscode => &vscode_defaults,
    };
}

// ---- keymap assembly --------------------------------------------------------------------------

/// Look up a shell command by the dvui bind name it defaults to.
fn shellCommandForBind(name: []const u8) ?ShellCommand {
    inline for (shell_commands) |c| {
        if (c.bind) |b| {
            if (std.mem.eql(u8, b, name)) return c;
        }
    }
    return null;
}

/// Shell command ↔ menu-bar item, for the items whose chord the user can rebind. Only these
/// need syncing: `dispatch` skips exactly this set on macOS (the native menu already ran them),
/// so their `NSMenu` key equivalent *is* the dispatch, not just the label.
const native_menu_bindings = [_]struct {
    command: []const u8,
    action: fizzy.backend.NativeMenuAction,
}{
    .{ .command = "fizzy.openFolder", .action = .open_folder },
    .{ .command = "fizzy.openFiles", .action = .open_files },
    .{ .command = "fizzy.newFile", .action = .new_file },
    .{ .command = "fizzy.save", .action = .save },
    .{ .command = "fizzy.saveAs", .action = .save_as },
    .{ .command = "fizzy.saveAll", .action = .save_all },
    .{ .command = "fizzy.copy", .action = .copy },
    .{ .command = "fizzy.paste", .action = .paste },
    .{ .command = "fizzy.undo", .action = .undo },
    .{ .command = "fizzy.redo", .action = .redo },
    .{ .command = "fizzy.toggleExplorer", .action = .toggle_explorer },
};

/// The AppKit key-equivalent character for a key, or null for keys a plain `NSMenuItem`
/// shortcut can't express (function keys, arrows, keypad). Lowercase throughout: AppKit takes
/// shift from the modifier mask, and an uppercase character would demand shift on its own.
fn nsKeyEquivalent(key: keymap.Key) ?[]const u8 {
    return switch (key) {
        .a => "a", .b => "b", .c => "c", .d => "d", .e => "e", .f => "f", .g => "g",
        .h => "h", .i => "i", .j => "j", .k => "k", .l => "l", .m => "m", .n => "n",
        .o => "o", .p => "p", .q => "q", .r => "r", .s => "s", .t => "t", .u => "u",
        .v => "v", .w => "w", .x => "x", .y => "y", .z => "z",
        .zero => "0", .one => "1", .two => "2", .three => "3", .four => "4",
        .five => "5", .six => "6", .seven => "7", .eight => "8", .nine => "9",
        .grave => "`", .minus => "-", .equal => "=", .left_bracket => "[",
        .right_bracket => "]", .backslash => "\\", .semicolon => ";",
        .apostrophe => "'", .comma => ",", .period => ".", .slash => "/",
        .space => " ", .tab => "\t", .enter => "\r", .backspace => "\u{8}",
        else => null,
    };
}

/// Push each menu-bar item's chord from the keymap onto the `NSMenuItem`. Called at the end of
/// every keymap rebuild, so a rebind in the settings pane takes effect immediately instead of
/// only after a restart — and, just as importantly, the *old* chord stops working.
fn syncNativeMenuShortcuts(editor: *Editor) void {
    if (comptime builtin.os.tag != .macos) return;

    for (native_menu_bindings) |nb| {
        const binding = bestBinding(editor, nb.command) orelse {
            // Unbound: clear the shortcut so a stale one can't keep firing.
            fizzy.backend.setNativeMenuShortcut(nb.action, null, 0);
            continue;
        };

        // A two-stroke chord has nowhere to live on a menu item. Clearing is the honest
        // outcome: `dispatch` stops skipping the command once the menu no longer claims it.
        if (binding.stroke.second != null) {
            fizzy.backend.setNativeMenuShortcut(nb.action, null, 0);
            continue;
        }

        const chord = binding.stroke.first;
        const key = nsKeyEquivalent(chord.key) orelse {
            fizzy.backend.setNativeMenuShortcut(nb.action, null, 0);
            continue;
        };

        var mask: c_ulong = 0;
        if (chord.mods.command) mask |= fizzy.backend.modifier_command;
        if (chord.mods.ctrl) mask |= fizzy.backend.modifier_control;
        if (chord.mods.alt) mask |= fizzy.backend.modifier_option;
        if (chord.mods.shift) mask |= fizzy.backend.modifier_shift;
        fizzy.backend.setNativeMenuShortcut(nb.action, key, mask);
    }
}

/// Highest-precedence binding for `command` (user > plugin > profile > dvui), or null.
fn bestBinding(editor: *Editor, command: []const u8) ?keymap.Binding {
    var best: ?keymap.Binding = null;
    for (editor.keymap.bindings.items) |b| {
        const cmd = b.command orelse continue;
        if (!std.mem.eql(u8, cmd, command)) continue;
        if (best) |cur| {
            if (@intFromEnum(b.source) >= @intFromEnum(cur.source)) best = b;
        } else best = b;
    }
    return best;
}

/// Whether a macOS menu item currently owns this command's chord. False once the chord is one
/// AppKit can't express as a key equivalent (a two-stroke chord, a function key), in which case
/// `dispatch` has to handle it after all — otherwise nothing would.
pub fn nativeMenuOwnsChord(editor: *Editor, id: []const u8) bool {
    if (comptime builtin.os.tag != .macos) return false;
    if (!isNativeMenuCommandOnMacOS(id)) return false;
    for (native_menu_bindings) |nb| {
        if (!std.mem.eql(u8, nb.command, id)) continue;
        const binding = bestBinding(editor, id) orelse return false;
        if (binding.stroke.second != null) return false;
        return nsKeyEquivalent(binding.stroke.first.key) != null;
    }
    // Flagged as a native-menu command but not in the sync table — the menu still owns it.
    return true;
}

pub fn isNativeMenuCommandOnMacOS(id: []const u8) bool {
    inline for (shell_commands) |c| {
        if (std.mem.eql(u8, c.id, id)) return c.native_menu_on_macos;
    }
    return false;
}

/// Rebuild `editor.keymap` from the finished `dvui.Window.keybinds` map. Called at the end of
/// `Editor.rebuildKeybinds`, so it sees dvui's defaults, the shell's binds, and every loaded
/// plugin's contributions in one pass.
pub fn buildKeymap(editor: *Editor) !void {
    const gpa = editor.host.allocator;
    const window = dvui.currentWindow();

    editor.keymap.deinit(gpa);
    editor.keymap = .{};

    if (editor.keybind_conflicts) |prev| {
        gpa.free(prev);
        editor.keybind_conflicts = null;
    }

    // Layer 1 (lowest): whatever ended up in dvui's bind map — dvui's own defaults, the shell's
    // `register()`, and every loaded plugin's `contributeKeybinds`.
    var it = window.keybinds.iterator();
    while (it.next()) |kv| {
        const cmd = shellCommandForBind(kv.key_ptr.*) orelse continue;
        // Modifier-only binds ("shift", "zoom", "ctrl/cmd") have no key and can't be a chord.
        const chord = adapter.fromKeybind(kv.value_ptr.*) orelse continue;
        try editor.keymap.add(gpa, .{
            .stroke = .{ .first = chord },
            .command = cmd.id,
            .source = .dvui,
        });
    }

    // Layer 2: the shell's default profile.
    const platform: keymap.Platform = if (fizzy.platform.isMacOS()) .mac else .other;
    for (defaultsFor(editor.keybind_profile)) |d| {
        const text = if (platform == .mac) (d.keys_mac orelse d.keys) else d.keys;
        const stroke = keymap.parseKeys(text, platform) catch |err| {
            dvui.log.err("default keybind '{s}' for '{s}' is invalid: {s}", .{ text, d.command, @errorName(err) });
            continue;
        };
        try editor.keymap.add(gpa, .{ .stroke = stroke, .command = d.command, .source = .profile });
    }

    // Layer 2b: owner-scoped plugin defaults (C2-lite). Higher source than profile so they win
    // when their owner is active; `owner_id` keeps them inert otherwise.
    for (plugin_owner_defaults) |d| {
        if (editor.host.command(d.command) == null) continue;
        const stroke = keymap.parseKeys(d.keys, platform) catch |err| {
            dvui.log.err("plugin keybind '{s}' for '{s}' is invalid: {s}", .{ d.keys, d.command, @errorName(err) });
            continue;
        };
        try editor.keymap.add(gpa, .{
            .stroke = stroke,
            .command = d.command,
            .source = .plugin,
            .owner_id = d.owner_id,
        });
    }

    // Layer 3 (highest): the user's own `keybinds.zon`.
    try loadUserOverrides(editor);

    // Mirror user overrides back onto the built-in bind names dvui's widgets and the menus read.
    projectUserOverrides(editor);

    // Push the resolved chords onto the macOS menu bar. These items *are* the dispatch path for
    // their commands, so a rebind that doesn't reach them takes effect nowhere.
    syncNativeMenuShortcuts(editor);

    // Cache conflicts for the Keyboard Shortcuts settings pane.
    editor.keybind_conflicts = editor.keymap.conflicts(gpa) catch |err| blk: {
        dvui.log.err("keybind conflicts() failed: {s}", .{@errorName(err)});
        break :blk null;
    };
    if (editor.keybind_conflicts) |cs| {
        for (cs) |c| {
            const keys = keymap.formatKeys(gpa, c.stroke, platform) catch continue;
            defer gpa.free(keys);
            dvui.log.warn("keybind conflict on '{s}': '{s}' shadows '{s}'", .{ keys, c.winner, c.loser });
        }
    }
}

/// Read and apply `<config>/keybinds.zon`. A missing file is the normal case — defaults are
/// never written out, so a user who has rebound nothing has no file at all.
fn loadUserOverrides(editor: *Editor) !void {
    if (comptime builtin.target.cpu.arch == .wasm32) return;
    const gpa = editor.host.allocator;

    if (editor.keybinds_overrides) |*f| {
        f.deinit(gpa);
        editor.keybinds_overrides = null;
    }

    const path = try std.fs.path.join(gpa, &.{ editor.config_folder, "keybinds.zon" });
    defer gpa.free(path);

    const text = std.Io.Dir.cwd().readFileAllocOptions(
        dvui.io,
        path,
        gpa,
        .limited(1024 * 1024),
        .of(u8),
        0,
    ) catch |err| switch (err) {
        error.FileNotFound => return,
        else => {
            dvui.log.err("keybinds.zon read failed: {s}", .{@errorName(err)});
            return;
        },
    };
    defer gpa.free(text);

    const platform: keymap.Platform = if (fizzy.platform.isMacOS()) .mac else .other;
    var file = try keymap.zon.parse(gpa, text, platform);
    errdefer file.deinit(gpa);

    for (file.diagnostics) |d| {
        dvui.log.err("keybinds.zon:{d}:{d}: {s}", .{ d.line, d.column, d.message });
    }

    const view = try file.toBindings(gpa, .user);
    defer gpa.free(view);
    for (view) |b| try editor.keymap.add(gpa, b);

    // The keymap borrows this File's strings, so it has to outlive the keymap.
    editor.keybinds_overrides = file;
}

// ---- projection back into dvui's bind map -------------------------------------------------------

/// Reserved command prefix for rebinding a **built-in editing bind** — the names dvui's own
/// widgets match on (`char_left`, `word_right_select`, `line_start`, …). Writing
/// `.{ .keys = "alt+b", .command = "bind.word_left" }` in keybinds.zon moves that motion.
///
/// This exists because cursor motion cannot go through the command registry without becoming
/// worse. `TextEntryWidget` resolves motion *in-frame* against the byte buffer (see
/// `textcore/movement.zig`); routing it through `host.runCommand` would have to hand the result
/// back via `Document.pending_sel`, reintroducing exactly the one-frame lag that made navigation
/// feel fragile in the first place. So the widget keeps matching bind names, and the keymap
/// rewrites what those names mean.
pub const bind_override_prefix = "bind.";

/// The dvui bind name a shell command's key should be mirrored onto, so rebinding e.g.
/// `fizzy.save` also updates the accelerator `Menu.zig` renders next to "Save".
fn shellBindForCommand(id: []const u8) ?[]const u8 {
    inline for (shell_commands) |c| {
        if (std.mem.eql(u8, c.id, id)) return c.bind;
    }
    return null;
}

/// Push user-layer bindings back into `dvui.Window.keybinds`.
///
/// Only names **already present** in the map are updated. That's both a sanity check (you can
/// only rebind something that exists) and a lifetime guarantee: `StringHashMap.put` keeps the
/// existing key allocation, so the map never ends up holding a pointer into a `keybinds.zon`
/// parse that a later rebuild frees.
fn projectUserOverrides(editor: *Editor) void {
    const window = dvui.currentWindow();

    for (editor.keymap.bindings.items) |b| {
        if (b.source != .user) continue;
        const command = b.command orelse continue;

        const name = if (std.mem.startsWith(u8, command, bind_override_prefix))
            command[bind_override_prefix.len..]
        else
            shellBindForCommand(command) orelse continue;

        if (b.stroke.second != null) {
            // `dvui.enums.Keybind` is one key plus modifier flags; there is nowhere to put the
            // second stroke. Chords still work for real commands, just not for built-in binds.
            dvui.log.err(
                "keybinds.zon: '{s}' cannot be bound to a chord (built-in binds are single-stroke)",
                .{command},
            );
            continue;
        }

        if (!window.keybinds.contains(name)) {
            dvui.log.err("keybinds.zon: unknown built-in bind '{s}'", .{name});
            continue;
        }
        window.keybinds.put(window.gpa, name, adapter.toKeybind(b.stroke.first)) catch |err| {
            dvui.log.err("keybind projection for '{s}' failed: {s}", .{ name, @errorName(err) });
        };
    }
}

// ---- dispatch ---------------------------------------------------------------------------------

/// Context flags for `when` matching. Only what the shell can answer today; grows as bindings
/// need finer gates.
fn currentContext(editor: *Editor) keymap.When {
    return .{
        .editor_focused = editor.activeDoc() != null,
        .explorer_focused = !editor.explorer.closed,
        .modal_open = editor.command_palette.open,
    };
}

fn activeOwnerId(editor: *Editor) ?[]const u8 {
    const doc = editor.activeDoc() orelse return null;
    return doc.owner.id;
}

// These keybinds are available regardless of the currently focused widget.
// Any binds that need to be consumed by a specific widget do not need to trigger here.
pub fn tick() !void {
    const editor = fizzy.editor;
    // While the palette is open it owns the keyboard entirely — otherwise Escape would also run
    // `fizzy.cancel`, and a typed character could trip a single-key binding.
    if (editor.command_palette.open) return;
    // Likewise while the settings pane is capturing a chord: the whole point is that the keys
    // being pressed are data, not commands.
    if (KeybindSettings.isRecording()) return;
    const ctx = currentContext(editor);
    const active_owner = activeOwnerId(editor);

    for (dvui.events()) |e| {
        if (e.handled) continue;

        switch (e.evt) {
            .key => |ke| {
                if (ke.action != .down and ke.action != .repeat) continue;

                const chord = adapter.chordFrom(ke) orelse continue;
                switch (editor.keymap.resolve(chord, ctx, active_owner)) {
                    .none => {},
                    // `pending` (first half of a chord) and `unbound` both *claim* the key, and
                    // ought to mark the event handled so it doesn't also reach a widget. Neither
                    // can occur yet — every binding built by `buildKeymap` is single-stroke and
                    // none are unbinds — and `Event.handle` needs a `*WidgetData` the shell has
                    // no sensible value for. Left as a no-op deliberately: this stays behaviour-
                    // identical to the if-chain it replaced, which never marked events handled
                    // either. Revisit when chords or user unbinds actually land (step C/D).
                    .pending, .unbound => {},
                    .command => |id| {
                        // macOS delivers these twice — once as an NSMenu key equivalent (which
                        // already ran the action) and once as an SDL key event. Let the native
                        // menu own them there.
                        if (nativeMenuOwnsChord(editor, id)) continue;

                        // Repeat only makes sense for the actions that were previously wired to
                        // accept it; everything else fires once per press.
                        if (ke.action == .repeat and
                            !std.mem.eql(u8, id, "fizzy.undo") and
                            !std.mem.eql(u8, id, "fizzy.redo")) continue;

                        editor.host.runCommand(id) catch |err| {
                            dvui.log.err("command '{s}' failed: {s}", .{ id, @errorName(err) });
                        };
                    },
                }
            },
            else => {},
        }
    }
}

// ---- user overrides (Keyboard Shortcuts pane) -----------------------------------------------

fn ownerIdForCommand(command: []const u8) ?[]const u8 {
    if (std.mem.startsWith(u8, command, "fizzy.")) return null;
    if (std.mem.startsWith(u8, command, bind_override_prefix)) return null;
    const dot = std.mem.indexOfScalar(u8, command, '.') orelse return null;
    return command[0..dot];
}

fn keybindsPath(editor: *Editor, gpa: std.mem.Allocator) ![]u8 {
    return try std.fs.path.join(gpa, &.{ editor.config_folder, "keybinds.zon" });
}

/// Rewrite `keybinds.zon` from `bindings`, then rebuild the live keymap.
fn writeAndReload(editor: *Editor, bindings: []const keymap.zon.OwnedBinding) !void {
    if (comptime builtin.target.cpu.arch == .wasm32) return;
    const gpa = editor.host.allocator;
    const path = try keybindsPath(editor, gpa);
    defer gpa.free(path);

    const text = try keymap.zon.format(gpa, bindings);
    defer gpa.free(text);

    if (bindings.len == 0) {
        std.Io.Dir.cwd().deleteFile(dvui.io, path) catch |err| switch (err) {
            error.FileNotFound => {},
            else => return err,
        };
    } else {
        try std.Io.Dir.cwd().writeFile(dvui.io, .{ .sub_path = path, .data = text });
    }

    editor.rebuildKeybinds();
}

fn collectCurrentOverrides(editor: *Editor, gpa: std.mem.Allocator) !std.ArrayList(keymap.zon.OwnedBinding) {
    var out: std.ArrayList(keymap.zon.OwnedBinding) = .empty;
    errdefer {
        for (out.items) |*b| b.deinit(gpa);
        out.deinit(gpa);
    }

    if (editor.keybinds_overrides) |file| {
        for (file.bindings) |b| {
            try out.append(gpa, .{
                .keys = try gpa.dupe(u8, b.keys),
                .stroke = b.stroke,
                .command = if (b.command) |c| try gpa.dupe(u8, c) else null,
                .when = b.when,
                .when_text = if (b.when_text) |w| try gpa.dupe(u8, w) else null,
                .owner_id = if (b.owner_id) |o| try gpa.dupe(u8, o) else null,
            });
        }
    }
    return out;
}

/// Set (or replace) the user override for `command`. `keys` is VSCode grammar (`mod+p`).
pub fn setUserBinding(editor: *Editor, command: []const u8, keys: []const u8) !void {
    if (comptime builtin.target.cpu.arch == .wasm32) return;
    const gpa = editor.host.allocator;
    const platform: keymap.Platform = if (fizzy.platform.isMacOS()) .mac else .other;
    const stroke = try keymap.parseKeys(keys, platform);

    var list = try collectCurrentOverrides(editor, gpa);
    defer {
        for (list.items) |*b| b.deinit(gpa);
        list.deinit(gpa);
    }

    // Drop any prior override for this command (including unbinds).
    var i: usize = 0;
    while (i < list.items.len) {
        if (list.items[i].command) |c| {
            if (std.mem.eql(u8, c, command)) {
                var removed = list.orderedRemove(i);
                removed.deinit(gpa);
                continue;
            }
        }
        i += 1;
    }

    const owner = ownerIdForCommand(command);
    try list.append(gpa, .{
        .keys = try gpa.dupe(u8, keys),
        .stroke = stroke,
        .command = try gpa.dupe(u8, command),
        .owner_id = if (owner) |o| try gpa.dupe(u8, o) else null,
    });

    try writeAndReload(editor, list.items);
}

/// Remove the user override for `command`, restoring the profile/plugin default.
pub fn clearUserBinding(editor: *Editor, command: []const u8) !void {
    if (comptime builtin.target.cpu.arch == .wasm32) return;
    const gpa = editor.host.allocator;

    var list = try collectCurrentOverrides(editor, gpa);
    defer {
        for (list.items) |*b| b.deinit(gpa);
        list.deinit(gpa);
    }

    var i: usize = 0;
    var changed = false;
    while (i < list.items.len) {
        if (list.items[i].command) |c| {
            if (std.mem.eql(u8, c, command)) {
                var removed = list.orderedRemove(i);
                removed.deinit(gpa);
                changed = true;
                continue;
            }
        }
        i += 1;
    }
    if (!changed) return;
    try writeAndReload(editor, list.items);
}

/// True when `command` has a user-layer override in the live keymap.
pub fn hasUserOverride(editor: *Editor, command: []const u8) bool {
    for (editor.keymap.bindings.items) |b| {
        if (b.source != .user) continue;
        const c = b.command orelse continue;
        if (std.mem.eql(u8, c, command)) return true;
    }
    return false;
}
