//! `fizzy-integration-tests` artifact under `zig build test-integration`.
//!
//! These tests run real fizzy drawing functions against a *headless*
//! `dvui.Window` provided by dvui's testing backend. The shim in
//! `fizzy_shim.zig` brings up just enough of `fizzy.app` / `fizzy.editor`
//! for the code paths exercised here to read the globals they need
//! without booting the full editor (no assets, no themes, no SDL).
//!
//! The same step also runs `fizzy-sdk-tests` (rooted at `src/sdk/sdk.zig`)
//! for SDK/dylib/settings coverage that needs dvui — see `build/app.zig`.
//!
//! Pixel-art-specific coverage (`Internal.File`, `Layer`, `Packer`,
//! `Animation`, grid/pack/flood-fill regressions) moved out with the
//! pixi plugin extraction — pixi now ships from its own repo
//! (`fizzyedit/pixi`) and owns that coverage there. This target keeps
//! the headless dvui harness alive for future fizzy-shell-level
//! integration tests (workbench, text, image, menu/sidebar flows).
//!
//! See `tests/README.md` for the overall layering.

const std = @import("std");
const dvui = @import("dvui");
const fizzy = @import("fizzy");
const shim = @import("fizzy_shim.zig");
const TextEntryWidget = @import("text").TextEntryWidget;

test "shim brings up a dvui.testing window with usable fizzy globals" {
    var ctx = try shim.init(std.testing.allocator);
    defer ctx.deinit(std.testing.allocator);

    const arena = dvui.currentWindow().arena();
    const buf = try arena.alloc(u8, 16);
    @memset(buf, 0);

    try std.testing.expect(fizzy.app == ctx.app);
    try std.testing.expect(fizzy.editor == ctx.editor);
}

// -- menu accelerators -------------------------------------------------------------------------

// The regression that made every plugin menu row show a blank accelerator: a chord that exists
// only in the keymap — which is every chord a user assigns in the Keyboard Shortcuts pane, and
// every plugin command's chord — used to be looked up in `dvui.Window.keybinds` under a *bind
// name* the command has no entry for, so the row rendered nothing while the key itself worked.
test "a menu row shows a chord the keymap has and dvui's bind map does not" {
    var ctx = try shim.init(std.testing.allocator);
    defer ctx.deinit(std.testing.allocator);

    const editor = ctx.editor;
    defer editor.keymap.deinit(editor.host.allocator);

    try editor.keymap.add(editor.host.allocator, .{
        .stroke = .{ .first = .{ .key = .f, .mods = .{ .command = true } } },
        .command = "text.format",
        .source = .user,
    });

    // The premise: nothing in dvui's flat bind namespace answers for this command.
    try std.testing.expect(!dvui.currentWindow().keybinds.contains("format"));

    const kb = fizzy.Editor.Keybinds.menuKeybindFor(editor, "text.format");
    try std.testing.expectEqual(dvui.enums.Key.f, kb.key.?);
    try std.testing.expectEqual(true, kb.command.?);
    try std.testing.expectEqual(false, kb.shift.?);

    // A command with no binding at all still draws nothing.
    const unbound = fizzy.Editor.Keybinds.menuKeybindFor(editor, "text.nosuchcommand");
    try std.testing.expect(unbound.key == null);
}

// On macOS a menu item's key equivalent *is* the dispatch path, and two items holding the same
// one is a coin flip AppKit resolves by menu order rather than by keymap layer. So the shadowed
// command has to give the chord up — otherwise binding `cmd+f` to Format Document (over the
// profile's Open Folder) leaves both menus advertising `⌘F` and the wrong one firing.
test "a shell command shadowed by a user binding gives up its native chord" {
    var ctx = try shim.init(std.testing.allocator);
    defer ctx.deinit(std.testing.allocator);

    const editor = ctx.editor;
    defer editor.keymap.deinit(editor.host.allocator);

    try editor.keymap.add(editor.host.allocator, .{
        .stroke = .{ .first = .{ .key = .f, .mods = .{ .command = true } } },
        .command = "fizzy.openFolder",
        .source = .profile,
    });
    try editor.keymap.add(editor.host.allocator, .{
        .stroke = .{ .first = .{ .key = .f, .mods = .{ .command = true } } },
        .command = "text.format",
        .source = .user,
    });

    // The winner keeps the chord in both menu bars; the loser shows none and holds no macOS key
    // equivalent, so neither menu can advertise — or fire — a shortcut that runs something else.
    try std.testing.expectEqual(dvui.enums.Key.f, fizzy.Editor.Keybinds.menuKeybindFor(editor, "text.format").key.?);
    try std.testing.expect(fizzy.Editor.Keybinds.menuKeybindFor(editor, "fizzy.openFolder").key == null);
    try std.testing.expect(!fizzy.Editor.Keybinds.chordShadowed(editor, "text.format"));
    try std.testing.expect(fizzy.Editor.Keybinds.chordShadowed(editor, "fizzy.openFolder"));
}

// -- text editing: auto-closing pairs + auto-indent Enter ---------------------------------------
//
// These drive the real `TextEntryWidget` through real frames and real key/text events, because
// what they cover is the half of the behavior that has no pure-logic seam: applying a decision
// from `textcore.pairs` to the buffer and the selection. The decisions themselves (when to
// close, step over, surround, or stay out of the way) are unit-tested in
// `src/plugins/text/src/textcore/pairs.zig`.

/// Backing buffer for `textEntryFrame` — file-scope because `dvui.App.frameFunction` takes no
/// arguments, and the widget struct is rebuilt from this buffer every frame anyway.
var te_text: std.ArrayListUnmanaged(u8) = .empty;
/// Selection to force at the start of the next frame, as `{start, cursor, end}`. Consumed (set
/// back to null) by the frame that applies it, so later frames keep whatever editing produced.
var te_pending_sel: ?[3]usize = null;
/// The bracket pair the last drawn frame highlighted — copied out of the widget (which is a
/// stack local rebuilt every frame) so tests can assert on what was actually drawn.
var te_last_bracket_match: ?[2]usize = null;
/// Matches what `TextEditor.zig` passes: the editor draws with layout caching on, and it
/// changes which bytes get emitted per frame, so the harness has to run the same way.
var te_cache_layout: bool = true;

fn textEntryFrame() !dvui.App.Result {
    var te: TextEntryWidget = undefined;
    te.init(@src(), .{
        .multiline = true,
        .break_lines = false,
        .scroll_horizontal = true,
        .text = .{ .array_list = .{
            .backing = &te_text,
            .allocator = std.testing.allocator,
            .limit = 64 * 1024,
        } },
        .cache_layout = te_cache_layout,
        .tab_inserts_indent = true,
        .tab_size = 4,
        .insert_spaces = true,
        .auto_indent_newline = true,
        .auto_close_pairs = true,
        .highlight_matching_bracket = true,
    }, .{ .expand = .both });

    dvui.focusWidget(te.data().id, null, null);

    if (te_pending_sel) |s| {
        const sel = te.textLayout.selectionGet(te.len);
        sel.start = s[0];
        sel.cursor = s[1];
        sel.end = s[2];
        te_pending_sel = null;
    }

    te.processEvents();
    if (te_scroll_to) |fraction| {
        const si = te.scroll.si;
        si.viewport.y = fraction * @max(0, si.virtual_size.h - si.viewport.h);
    }
    te.draw();
    te_last_bracket_match = te.bracket_match;
    te_highlight_range = te.highlightByteRange();
    te_byte_heights = te.textLayout.byte_heights;
    te_viewport = te.scroll.si.viewport;
    te.deinit();
    return .ok;
}

/// Brings up a headless window with `te_text` seeded to `text` and the caret at `cursor`, then
/// runs one settling frame so the widget exists and holds focus before events are sent.
fn textEntryCtx(text: []const u8, cursor: usize) !dvui.testing {
    te_text.clearRetainingCapacity();
    try te_text.appendSlice(std.testing.allocator, text);
    te_pending_sel = .{ cursor, cursor, cursor };

    var t = try dvui.testing.init(.{ .allocator = std.testing.allocator });
    errdefer t.deinit();
    try dvui.testing.settle(textEntryFrame);
    return t;
}

fn deinitTextEntry(t: *dvui.testing) void {
    t.deinit();
    te_text.deinit(std.testing.allocator);
    te_text = .empty;
}

test "typing an opening brace inserts its closer and leaves the caret between them" {
    var t = try textEntryCtx("pub const Test = struct ", 24);
    defer deinitTextEntry(&t);

    try dvui.testing.writeText("{");
    try dvui.testing.settle(textEntryFrame);

    try std.testing.expectEqualStrings("pub const Test = struct {}", te_text.items);
}

test "Enter between a brace pair puts the closer on its own dedented line" {
    // The caret sits between `{` and `}` on an already-indented line — VSCode's three-line
    // split: opener line, indented empty line with the caret, closer back at the outer indent.
    var t = try textEntryCtx("    const S = struct {}", 22);
    defer deinitTextEntry(&t);

    try dvui.testing.pressKey(.enter, .none);
    try dvui.testing.settle(textEntryFrame);

    try std.testing.expectEqualStrings("    const S = struct {\n        \n    }", te_text.items);
}

test "typing a closer steps over the auto-inserted one instead of doubling it" {
    var t = try textEntryCtx("call", 4);
    defer deinitTextEntry(&t);

    try dvui.testing.writeText("(");
    try dvui.testing.settle(textEntryFrame);
    try std.testing.expectEqualStrings("call()", te_text.items);

    try dvui.testing.writeText("1");
    try dvui.testing.settle(textEntryFrame);
    try dvui.testing.writeText(")");
    try dvui.testing.settle(textEntryFrame);

    try std.testing.expectEqualStrings("call(1)", te_text.items);
}

test "typing an opener directly before a word does not auto-close" {
    var t = try textEntryCtx("foo", 0);
    defer deinitTextEntry(&t);

    try dvui.testing.writeText("(");
    try dvui.testing.settle(textEntryFrame);

    try std.testing.expectEqualStrings("(foo", te_text.items);
}

test "Backspace between an empty pair deletes both halves" {
    var t = try textEntryCtx("call()", 5);
    defer deinitTextEntry(&t);

    try dvui.testing.pressKey(.backspace, .none);
    try dvui.testing.settle(textEntryFrame);

    try std.testing.expectEqualStrings("call", te_text.items);
}

test "Backspace next to a non-empty pair deletes one character" {
    var t = try textEntryCtx("call(1)", 5);
    defer deinitTextEntry(&t);

    try dvui.testing.pressKey(.backspace, .none);
    try dvui.testing.settle(textEntryFrame);

    try std.testing.expectEqualStrings("call1)", te_text.items);
}

test "the matched bracket pair is highlighted while the caret sits next to one" {
    // `fn f() {` … the caret goes right after the `(`.
    var t = try textEntryCtx("fn f() {}", 5);
    defer deinitTextEntry(&t);

    try std.testing.expectEqual(@as(?[2]usize, .{ 4, 5 }), te_last_bracket_match);

    // Both halves of the pair land in the same emitted chunk here, which is the case that
    // splits one chunk twice — reaching `addTextDone`'s bytes_seen assert without tripping it
    // is the point of drawing this frame at all.
    te_pending_sel = .{ 8, 8, 8 };
    try dvui.testing.settle(textEntryFrame);
    try std.testing.expectEqual(@as(?[2]usize, .{ 7, 8 }), te_last_bracket_match);
}

test "no bracket highlight away from a bracket or while text is selected" {
    var t = try textEntryCtx("fn f() {}", 2);
    defer deinitTextEntry(&t);
    try std.testing.expectEqual(@as(?[2]usize, null), te_last_bracket_match);

    // A selection means the selection highlight is what the eye tracks — stay out of its way.
    te_pending_sel = .{ 4, 6, 6 };
    try dvui.testing.settle(textEntryFrame);
    try std.testing.expectEqual(@as(?[2]usize, null), te_last_bracket_match);
}

test "an unmatched bracket is not highlighted" {
    var t = try textEntryCtx("fn f( {}", 5);
    defer deinitTextEntry(&t);

    try std.testing.expectEqual(@as(?[2]usize, null), te_last_bracket_match);
}

test "editing stays correct on a frame that highlighted a bracket pair" {
    // The caret sits inside `()` — so the frame before each keystroke splits that chunk for the
    // highlight. If the splice desynced `bytes_seen`, the caret would drift and these
    // characters would land somewhere other than between the parens.
    var t = try textEntryCtx("call()", 5);
    defer deinitTextEntry(&t);

    try dvui.testing.writeText("a");
    try dvui.testing.settle(textEntryFrame);
    try dvui.testing.writeText("b");
    try dvui.testing.settle(textEntryFrame);

    try std.testing.expectEqualStrings("call(ab)", te_text.items);
}

test "typing an opener with a selection wraps it instead of replacing it" {
    var t = try textEntryCtx("wrap me", 0);
    defer deinitTextEntry(&t);

    te_pending_sel = .{ 0, 4, 4 };
    try dvui.testing.settle(textEntryFrame);

    try dvui.testing.writeText("(");
    try dvui.testing.settle(textEntryFrame);

    try std.testing.expectEqualStrings("(wrap) me", te_text.items);
}

// -- syntax-highlight query range ---------------------------------------------------------------

/// The highlight range the last drawn frame chose, plus dvui's own record of where each byte
/// landed vertically — enough to check the range against ground truth rather than against the
/// same formula that produced it.
var te_highlight_range: ?TextEntryWidget.ByteRange = null;
var te_byte_heights: []const dvui.TextLayoutWidget.ByteHeight = &.{};
var te_viewport: dvui.Rect = .{};
var te_scroll_to: ?f32 = null;

test "the highlight query range covers every byte the viewport shows" {
    // A document tall enough that the viewport is a small fraction of it — the case where
    // querying only the visible slice matters, and where getting the mapping wrong would leave
    // most of the screen uncolored.
    const line = "    const value: u32 = call(arg) + other[idx]; // comment\n";
    var doc: std.ArrayListUnmanaged(u8) = .empty;
    defer doc.deinit(std.testing.allocator);
    for (0..600) |_| try doc.appendSlice(std.testing.allocator, line);

    var t = try textEntryCtx(doc.items, 0);
    defer deinitTextEntry(&t);

    // Several scroll positions, including one far from the caret (which is what used to drag
    // the range back toward byte 0 and made scrolling cost more the further you got).
    for ([_]f32{ 0, 0.25, 0.5, 0.9 }) |fraction| {
        te_scroll_to = fraction;
        for (0..3) |_| _ = try dvui.testing.step(textEntryFrame);

        const range = te_highlight_range orelse {
            // No layout data yet is a valid answer only before anything has been drawn.
            try std.testing.expect(te_byte_heights.len == 0);
            continue;
        };

        // Ground truth: dvui recorded, for real, which byte sits at which height. Every byte
        // whose recorded height falls inside the viewport must be inside the queried range, or
        // that text draws unhighlighted. Note the resolution limit — dvui records one entry per
        // `ByteHeight.dist` (200) logical pixels, so this catches a range in the wrong
        // coordinate space or off by a screenful, not one off by a few lines. The full-viewport
        // pad is what covers that margin.
        var checked: usize = 0;
        for (te_byte_heights) |bh| {
            if (bh.height < te_viewport.y or bh.height > te_viewport.y + te_viewport.h) continue;
            checked += 1;
            if (bh.byte < range.start or bh.byte > range.end) {
                std.debug.print(
                    "  visible byte {d} (height {d}) fell outside the queried range {d}..{d} " ++
                        "at scroll {d} (viewport y={d} h={d}) — that text would draw uncolored\n",
                    .{ bh.byte, bh.height, range.start, range.end, fraction, te_viewport.y, te_viewport.h },
                );
            }
            try std.testing.expect(bh.byte >= range.start);
            try std.testing.expect(bh.byte <= range.end);
        }
        // The assertions above pass trivially if nothing was in view — make sure something was.
        try std.testing.expect(checked > 0);
    }
    te_scroll_to = null;
}
