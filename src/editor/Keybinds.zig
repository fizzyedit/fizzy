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
    .id = "shell",
    .display_name = "Fizzy",
};

const shell_vtable: sdk.Plugin.VTable = .{};

fn ed(state: *anyopaque) *Editor {
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
    native_menu_on_macos: bool = false,
};

const shell_commands = [_]ShellCommand{
    .{ .id = "shell.openFolder", .title = "Open Folder…", .bind = "open_folder", .run = cmdOpenFolder, .native_menu_on_macos = true },
    .{ .id = "shell.openFiles", .title = "Open Files…", .bind = "open_files", .run = cmdOpenFiles, .native_menu_on_macos = true },
    .{ .id = "shell.newFile", .title = "New File…", .bind = "new_file", .run = cmdNewFile, .native_menu_on_macos = true },
    .{ .id = "shell.save", .title = "Save", .bind = "save", .run = cmdSave, .native_menu_on_macos = true },
    .{ .id = "shell.saveAs", .title = "Save As…", .bind = "save_as", .run = cmdSaveAs },
    .{ .id = "shell.saveAll", .title = "Save All", .bind = "save_all", .run = cmdSaveAll },
    .{ .id = "shell.undo", .title = "Undo", .bind = "undo", .run = cmdUndo, .native_menu_on_macos = true },
    .{ .id = "shell.redo", .title = "Redo", .bind = "redo", .run = cmdRedo, .native_menu_on_macos = true },
    .{ .id = "shell.copy", .title = "Copy", .bind = "copy", .run = cmdCopy, .native_menu_on_macos = true },
    .{ .id = "shell.paste", .title = "Paste", .bind = "paste", .run = cmdPaste, .native_menu_on_macos = true },
    .{ .id = "shell.toggleExplorer", .title = "Toggle Explorer", .bind = "explorer", .run = cmdToggleExplorer, .native_menu_on_macos = true },
    .{ .id = "shell.deleteSelection", .title = "Delete Selection", .bind = "delete_selection_contents", .run = cmdDeleteSelection },
    .{ .id = "shell.accept", .title = "Accept", .bind = "activate", .run = cmdAccept },
    .{ .id = "shell.cancel", .title = "Cancel", .bind = "cancel", .run = cmdCancel },
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
    const editor = ed(state);
    if (try dvui.dialogNativeFolderSelect(dvui.currentWindow().arena(), .{
        .title = "Open Project Folder",
    })) |folder| {
        try editor.setProjectFolder(folder);
    }
}

fn cmdOpenFiles(state: *anyopaque) anyerror!void {
    const editor = ed(state);
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
    ed(state).requestNewFileDialog();
}
fn cmdSave(state: *anyopaque) anyerror!void {
    try ed(state).save();
}
fn cmdSaveAs(state: *anyopaque) anyerror!void {
    ed(state).requestSaveAs();
}
fn cmdSaveAll(state: *anyopaque) anyerror!void {
    try ed(state).saveAll();
}
fn cmdUndo(state: *anyopaque) anyerror!void {
    try ed(state).undo();
}
fn cmdRedo(state: *anyopaque) anyerror!void {
    try ed(state).redo();
}
fn cmdCopy(state: *anyopaque) anyerror!void {
    try ed(state).copy();
}
fn cmdPaste(state: *anyopaque) anyerror!void {
    try ed(state).paste();
}
fn cmdDeleteSelection(state: *anyopaque) anyerror!void {
    ed(state).deleteSelectedContents();
}
fn cmdAccept(state: *anyopaque) anyerror!void {
    try ed(state).accept();
}
fn cmdCancel(state: *anyopaque) anyerror!void {
    try ed(state).cancel();
}

fn cmdToggleExplorer(state: *anyopaque) anyerror!void {
    const editor = ed(state);
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
/// This also closes a real gap. `shell.undo` already routes through `activeDoc().owner.undo`,
/// so undo works for *any* document-owning plugin — but its only keyboard binding came from
/// pixi registering the name, meaning Ctrl+Z did nothing on an install without pixi.
const vscode_defaults = [_]DefaultBind{
    .{ .command = "shell.save", .keys = "mod+s" },
    .{ .command = "shell.saveAs", .keys = "mod+shift+s" },
    .{ .command = "shell.saveAll", .keys = "mod+alt+s" },
    .{ .command = "shell.newFile", .keys = "mod+n" },
    .{ .command = "shell.openFolder", .keys = "mod+f" },
    .{ .command = "shell.openFiles", .keys = "mod+o" },
    .{ .command = "shell.toggleExplorer", .keys = "mod+e" },
    .{ .command = "shell.undo", .keys = "mod+z" },
    // VSCode uses Ctrl+Y on Windows/Linux and Cmd+Shift+Z on macOS.
    .{ .command = "shell.redo", .keys = "ctrl+y", .keys_mac = "mod+shift+z" },
};

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

    // Layer 3 (highest): the user's own `keybinds.zon`.
    try loadUserOverrides(editor);

    // Mirror user overrides back onto the built-in bind names dvui's widgets and the menus read.
    projectUserOverrides(editor);
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
/// `shell.save` also updates the accelerator `Menu.zig` renders next to "Save".
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
    };
}

// These keybinds are available regardless of the currently focused widget.
// Any binds that need to be consumed by a specific widget do not need to trigger here.
pub fn tick() !void {
    const editor = fizzy.editor;
    const ctx = currentContext(editor);

    for (dvui.events()) |e| {
        if (e.handled) continue;

        switch (e.evt) {
            .key => |ke| {
                if (ke.action != .down and ke.action != .repeat) continue;

                const chord = adapter.chordFrom(ke) orelse continue;
                switch (editor.keymap.resolve(chord, ctx)) {
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
                        if (builtin.os.tag == .macos and isNativeMenuCommandOnMacOS(id)) continue;

                        // Repeat only makes sense for the actions that were previously wired to
                        // accept it; everything else fires once per press.
                        if (ke.action == .repeat and
                            !std.mem.eql(u8, id, "shell.undo") and
                            !std.mem.eql(u8, id, "shell.redo")) continue;

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
