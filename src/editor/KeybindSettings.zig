//! Keyboard Shortcuts settings pane — searchable via the settings tree under Fizzy.
//!
//! Lists every Host command with its current chord(s), lets the user click to record a new
//! binding (written to `keybinds.zon`), reset to default, and surfaces `Keymap.conflicts()`.
const std = @import("std");
const builtin = @import("builtin");
const dvui = @import("dvui");
const fizzy = @import("../fizzy.zig");
const keymap = @import("keymap/keymap.zig");
const adapter = @import("keymap/dvui_adapter.zig");
const Keybinds = @import("Keybinds.zig");

/// Command id currently waiting for a key press, or null when idle. Points into
/// `host.commands` (stable for the session while the plugin stays loaded).
var recording: ?[]const u8 = null;

/// Whether a chord is being captured right now.
///
/// While this is true the app has to stop treating keys as commands, on both of the paths that
/// can consume one before `pollRecording` ever sees it:
///
///  - dvui events — `Keybinds.tick` and every plugin's `tickKeybinds` are skipped by the frame
///    loop, the same way they are while the command palette owns the keyboard.
///  - the macOS menu bar — AppKit matches an `NSMenu` key equivalent and fires its action
///    *before* the key ever reaches SDL, so no amount of dvui-side event handling can stop it.
///    `FizzyNativeMenuActionEnabled` reports every item disabled while recording, and AppKit
///    will not perform a disabled item's key equivalent. Without this, recording `cmd+o` opened
///    the folder picker instead of being captured.
pub fn isRecording() bool {
    return recording != null;
}

pub fn draw() void {
    if (comptime builtin.target.cpu.arch == .wasm32) {
        dvui.label(@src(), "Keybindings are not available on the web build.", .{}, .{
            .color_text = dvui.themeGet().color(.window, .text).opacity(0.6),
        });
        return;
    }

    const editor = fizzy.editor;
    const theme = dvui.themeGet();
    const platform: keymap.Platform = if (fizzy.platform.isMacOS()) .mac else .other;
    const arena = dvui.currentWindow().arena();

    drawConflicts(editor, platform, theme);

    if (recording) |id| {
        drawRecordingBanner(id, theme);
        if (pollRecording(editor, id, platform)) {
            recording = null;
        }
    }

    // Group by owner id prefix (fizzy / plugin id).
    var owners: std.ArrayListUnmanaged([]const u8) = .empty;
    for (editor.host.commands.items) |c| {
        const owner = ownerPrefix(c.id);
        var seen = false;
        for (owners.items) |o| {
            if (std.mem.eql(u8, o, owner)) {
                seen = true;
                break;
            }
        }
        if (!seen) owners.append(arena, owner) catch {};
    }

    for (owners.items, 0..) |owner, oi| {
        var section = dvui.box(@src(), .{ .dir = .vertical }, .{
            .id_extra = oi,
            .expand = .horizontal,
            .margin = .{ .y = 6, .h = 2 },
        });
        defer section.deinit();

        dvui.label(@src(), "{s}", .{ownerLabel(owner)}, .{
            .font = dvui.Font.theme(.heading),
            .expand = .horizontal,
            .padding = .{ .y = 4, .h = 2 },
        });

        for (editor.host.commands.items, 0..) |c, ci| {
            if (!std.mem.eql(u8, ownerPrefix(c.id), owner)) continue;
            drawCommandRow(editor, c, ci, platform, theme);
        }
    }
}

/// Solid dot, drawn rather than iconified — lucide's circles are stroked outlines, and a
/// recording indicator wants a filled disc.
fn recordingDot() void {
    const size = dvui.Font.theme(.body).textHeight() * 0.55;
    var b = dvui.box(@src(), .{ .dir = .horizontal }, .{
        .min_size_content = .{ .w = size, .h = size },
        .expand = .none,
        .gravity_y = 0.5,
        .margin = .{ .x = 2, .w = 6 },
        .padding = dvui.Rect.all(0),
    });
    defer b.deinit();

    const r = b.data().borderRectScale().r;
    r.fill(.all(r.h / 2), .{ .color = dvui.themeGet().color(.err, .fill) });
}

fn drawRecordingBanner(id: []const u8, theme: dvui.Theme) void {
    var box = dvui.box(@src(), .{ .dir = .horizontal }, .{
        .expand = .horizontal,
        .background = true,
        .color_fill = theme.color(.err, .fill).opacity(0.18),
        .corners = .all(6),
        .padding = dvui.Rect.all(6),
        .margin = .{ .y = 2, .h = 6 },
    });
    defer box.deinit();

    recordingDot();
    dvui.labelNoFmt(@src(), "Recording", .{}, .{
        .gravity_y = 0.5,
        .font = dvui.Font.theme(.heading),
        .color_text = theme.color(.err, .fill),
    });
    dvui.label(@src(), "Press a key combination for \"{s}\" — Esc to cancel", .{id}, .{
        .gravity_y = 0.5,
        .expand = .horizontal,
        .margin = .{ .x = 8 },
        .color_text = theme.color(.window, .text).opacity(0.8),
    });
}

fn ownerPrefix(id: []const u8) []const u8 {
    return if (std.mem.indexOfScalar(u8, id, '.')) |dot| id[0..dot] else id;
}

fn ownerLabel(owner: []const u8) []const u8 {
    if (std.mem.eql(u8, owner, "fizzy")) return "Fizzy";
    const editor = fizzy.editor;
    if (editor.host.pluginById(owner)) |p| return p.display_name;
    return owner;
}

fn drawConflicts(editor: *fizzy.Editor, platform: keymap.Platform, theme: dvui.Theme) void {
    const conflicts = editor.keybind_conflicts orelse return;
    if (conflicts.len == 0) return;

    var box = dvui.box(@src(), .{ .dir = .vertical }, .{
        .expand = .horizontal,
        .background = true,
        .color_fill = theme.color(.err, .fill).opacity(0.25),
        .corners = .all(6),
        .padding = dvui.Rect.all(6),
        .margin = .{ .h = 8 },
    });
    defer box.deinit();

    dvui.label(@src(), "Conflicts", .{}, .{
        .font = dvui.Font.theme(.heading),
        .expand = .horizontal,
    });
    for (conflicts, 0..) |c, i| {
        const keys = keymap.formatKeys(dvui.currentWindow().arena(), c.stroke, platform) catch "?";
        dvui.label(@src(), "{s}: {s} shadows {s}", .{ keys, c.winner, c.loser }, .{
            .id_extra = i,
            .expand = .horizontal,
            .color_text = theme.color(.window, .text).opacity(0.85),
        });
    }
}

fn drawCommandRow(
    editor: *fizzy.Editor,
    c: fizzy.sdk.Host.Command,
    id_extra: usize,
    platform: keymap.Platform,
    theme: dvui.Theme,
) void {
    var row = dvui.box(@src(), .{ .dir = .horizontal }, .{
        .id_extra = id_extra,
        .expand = .horizontal,
        .padding = .{ .y = 2, .h = 2 },
        .min_size_content = .{ .w = 0, .h = 28 },
    });
    defer row.deinit();

    {
        var left = dvui.box(@src(), .{ .dir = .vertical }, .{ .expand = .horizontal, .gravity_y = 0.5 });
        defer left.deinit();
        dvui.label(@src(), "{s}", .{c.title}, .{ .expand = .horizontal });
        dvui.label(@src(), "{s}", .{c.id}, .{
            .expand = .horizontal,
            .color_text = theme.color(.window, .text).opacity(0.45),
        });
    }

    const shortcut = shortcutFor(editor, c.id, platform);
    const keys_text = if (shortcut) |s| s.keys else "—";
    const inherited = if (shortcut) |s| s.inherited else false;
    const is_recording = if (recording) |r| std.mem.eql(u8, r, c.id) else false;

    // Hand-built rather than `dvui.button` so the recording state can put a dot next to the
    // label. Same widget id either way, so starting a recording doesn't reset the button's
    // hover/press state.
    const clicked = blk: {
        var bw: dvui.ButtonWidget = undefined;
        bw.init(@src(), .{}, .{
            .gravity_y = 0.5,
            .min_size_content = .{ .w = 120, .h = 0 },
        });
        defer bw.deinit();
        bw.processEvents();
        bw.drawBackground();

        {
            var inner = dvui.box(@src(), .{ .dir = .horizontal }, .{
                .expand = .horizontal,
                .margin = .all(0),
                .padding = .all(0),
            });
            defer inner.deinit();

            if (is_recording) recordingDot();
            dvui.labelNoFmt(@src(), if (is_recording) "Recording" else keys_text, .{}, .{
                .gravity_x = if (is_recording) 0.0 else 0.5,
                .gravity_y = 0.5,
                .expand = .horizontal,
                .color_text = if (is_recording)
                    theme.color(.err, .fill)
                else if (inherited)
                    theme.color(.control, .text).opacity(0.55)
                else
                    null,
            });
        }

        break :blk bw.clicked();
    };
    if (clicked) {
        recording = if (is_recording) null else c.id;
    }

    if (Keybinds.hasUserOverride(editor, c.id)) {
        if (dvui.button(@src(), "Reset", .{}, .{
            .gravity_y = 0.5,
            .margin = .{ .x = 4 },
        })) {
            Keybinds.clearUserBinding(editor, c.id) catch |err| {
                dvui.log.err("clear keybind for '{s}' failed: {s}", .{ c.id, @errorName(err) });
            };
            if (recording) |r| {
                if (std.mem.eql(u8, r, c.id)) recording = null;
            }
        }
    }
}

const Shortcut = struct {
    keys: []const u8,
    /// The chord belongs to a Fizzy forwarder this command is reached through, not to this
    /// command. Drawn dimmed so it doesn't read as an override the Reset button could clear.
    inherited: bool = false,
};

fn shortcutFor(editor: *fizzy.Editor, id: []const u8, platform: keymap.Platform) ?Shortcut {
    if (directShortcut(editor, id, platform)) |keys| return .{ .keys = keys };

    // A plugin's document verb (`pixi.copy`) is invoked through the Fizzy forwarder that owns
    // the chord (`fizzy.copy` on `cmd+c`), so it has no binding of its own to find. Showing the
    // forwarder's chord is the truth about what key runs this command; showing "—" implied it
    // had no shortcut at all.
    const source = Keybinds.inheritedChordSource(id) orelse return null;
    const keys = directShortcut(editor, source, platform) orelse return null;
    return .{ .keys = keys, .inherited = true };
}

fn directShortcut(editor: *fizzy.Editor, id: []const u8, platform: keymap.Platform) ?[]const u8 {
    const arena = dvui.currentWindow().arena();
    const found = editor.keymap.bindingsFor(arena, id) catch return null;
    if (found.len == 0) return null;
    // Prefer the highest-source binding (user > plugin > profile > dvui).
    var best = found[0];
    for (found[1..]) |b| {
        if (@intFromEnum(b.source) >= @intFromEnum(best.source)) best = b;
    }
    return keymap.formatKeys(arena, best.stroke, platform) catch null;
}

/// Returns true when recording finished (bound or cancelled).
fn pollRecording(editor: *fizzy.Editor, command: []const u8, platform: keymap.Platform) bool {
    for (dvui.events()) |*e| {
        if (e.handled) continue;
        if (e.evt != .key) continue;
        const ke = e.evt.key;
        if (ke.action != .down) continue;

        if (ke.code == .escape) {
            e.handle(@src(), dvui.currentWindow().data());
            return true;
        }

        const chord = adapter.chordFrom(ke) orelse continue;
        if (keymap.keyIsModifier(chord.key)) continue;

        e.handle(@src(), dvui.currentWindow().data());
        const keys = keymap.formatKeys(editor.host.allocator, .{ .first = chord }, platform) catch return true;
        defer editor.host.allocator.free(keys);
        Keybinds.setUserBinding(editor, command, keys) catch |err| {
            dvui.log.err("set keybind for '{s}' failed: {s}", .{ command, @errorName(err) });
        };
        return true;
    }
    return false;
}
