//! `fizzy-integration-tests` artifact under `zig build test-integration`.
//!
//! These tests run real fizzy drawing functions against a *headless*
//! `dvui.Window` provided by dvui's testing backend. The shim in
//! `fizzy_shim.zig` brings up just enough of `fizzy.entry()` / `fizzy.editor()`
//! for the code paths exercised here to read the globals they need
//! without booting the full editor (no assets, no themes, no SDL).
//!
//! The same step also runs `fizzy-sdk-tests` (rooted at `sdk/src/sdk.zig`)
//! for SDK/dylib/settings coverage that needs dvui — see `build/app.zig`.
//!
//! See `tests/README.md` for the overall layering.

const std = @import("std");
const builtin = @import("builtin");
const dvui = @import("dvui");
const fizzy = @import("fizzy");
const Tracks = @import("app").Tracks;
const shim = @import("fizzy_shim.zig");
const TextEntryWidget = @import("text").TextEntryWidget;
const sdk = @import("fizzy_sdk");

test "shim brings up a dvui.testing window with usable fizzy globals" {
    var ctx = try shim.init(std.testing.allocator);
    defer ctx.deinit(std.testing.allocator);

    const arena = dvui.currentWindow().arena();
    const buf = try arena.alloc(u8, 16);
    @memset(buf, 0);

    try std.testing.expect(fizzy.entry() == ctx.app);
    try std.testing.expect(fizzy.editor() == ctx.editor);
}

// Windows' backend arms `ReadDirectoryChangesW` on a directory handle only, so watching a
// document's file used to fail with `WatchFailed` there (and every external edit went unseen).
test "an open document's file can be watched" {
    var ctx = try shim.init(std.testing.allocator);
    defer ctx.deinit(std.testing.allocator);
    const gpa = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(dvui.io, .{ .sub_path = "doc.txt", .data = "a" });
    var root_buf: [std.fs.max_path_bytes]u8 = undefined;
    const root = root_buf[0..try tmp.dir.realPath(dvui.io, &root_buf)];
    const path = try std.fs.path.join(gpa, &.{ root, "doc.txt" });
    defer gpa.free(path);

    var w: fizzy.Editor.DocumentWatcher = .init(gpa);
    try w.start();
    defer w.stop();
    try w.watchPath(path);
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
    defer editor.app.keymap.deinit(editor.app.host.allocator);

    try editor.app.keymap.add(editor.app.host.allocator, .{
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
    defer editor.app.keymap.deinit(editor.app.host.allocator);

    try editor.app.keymap.add(editor.app.host.allocator, .{
        .stroke = .{ .first = .{ .key = .f, .mods = .{ .command = true } } },
        .command = "fizzy.openFolder",
        .source = .profile,
    });
    try editor.app.keymap.add(editor.app.host.allocator, .{
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
// `plugins/text/src/textcore/pairs.zig`.

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
    if (te_scroll_x_to) |fraction| {
        const si = te.scroll.si;
        si.viewport.x = fraction * @max(0, si.virtual_size.w - si.viewport.w);
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

test "keystrokes typed inside a pair closed in the same frame land, and do not crash" {
    // Several keystrokes in one frame — a hitch, a fast typist, a live tape — where one closes a
    // pair and the next lands between its halves: inside bytes this frame already added, which
    // the layout cache's changed-interval bookkeeping once underflowed on.
    var t = try textEntryCtx("", 0);
    defer deinitTextEntry(&t);

    for ([_][]const u8{ "f", "(", "\"", "x", "\"", ")", ";" }) |key| try dvui.testing.writeText(key);
    try dvui.testing.settle(textEntryFrame);

    try std.testing.expectEqualStrings("f(\"x\");", te_text.items);
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
var te_byte_heights: []const dvui.TextLayoutWidget.BytePos = &.{};
var te_viewport: dvui.Rect = .{};
var te_scroll_to: ?f32 = null;
var te_scroll_x_to: ?f32 = null;

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
        // `BytePos.y_sep` (200) logical pixels, so this catches a range in the wrong
        // coordinate space or off by a screenful, not one off by a few lines. The half-screen
        // pad is what covers that margin. (Entries with a negative `dist` are positions across a
        // line wider than the view, which this document has none of.)
        var checked: usize = 0;
        for (te_byte_heights) |bh| {
            if (bh.dist < 0) continue;
            if (bh.dist < te_viewport.y or bh.dist > te_viewport.y + te_viewport.h) continue;
            checked += 1;
            if (bh.byte < range.start or bh.byte > range.end) {
                std.debug.print(
                    "  visible byte {d} (height {d}) fell outside the queried range {d}..{d} " ++
                        "at scroll {d} (viewport y={d} h={d}) — that text would draw uncolored\n",
                    .{ bh.byte, bh.dist, range.start, range.end, fraction, te_viewport.y, te_viewport.h },
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

// -- a line far wider than the view -------------------------------------------------------------

/// One line of `n` bytes of code-shaped text, with a short line either side of it.
fn longLineDoc(n: usize) ![]u8 {
    var doc: std.ArrayListUnmanaged(u8) = .empty;
    errdefer doc.deinit(std.testing.allocator);
    try doc.appendSlice(std.testing.allocator, "const a = 1;\n");
    const unit = "call(arg) + other[idx], ";
    while (doc.items.len < n) try doc.appendSlice(std.testing.allocator, unit);
    try doc.appendSlice(std.testing.allocator, "\nconst b = 2;\n");
    return doc.toOwnedSlice(std.testing.allocator);
}

/// Scrolls the long line across, start to end, a few frames at each stop, checking it draws.
fn scrollAcrossLongLine() !void {
    for ([_]f32{ 0, 0.5, 1, 0.25 }) |fraction| {
        te_scroll_x_to = fraction;
        for (0..3) |_| _ = try dvui.testing.step(textEntryFrame);
    }
    te_scroll_x_to = null;
}

// A minified file's one line can be far longer than one draw can number vertices for
// (`Vertex.Index` is u16 on every target, four vertices a glyph — 16k glyphs), and laying all of
// it out each frame is what made such a file crawl. dvui lays out only the stretches of a line
// near the view, recording positions across it as it goes, and each run it draws is about a
// view wide.
test "a line far wider than the view draws at every scroll position" {
    const doc = try longLineDoc(60_000);
    defer std.testing.allocator.free(doc);

    var t = try textEntryCtx(doc, 0);
    defer deinitTextEntry(&t);

    try scrollAcrossLongLine();

    var across: usize = 0;
    for (te_byte_heights) |bp| {
        if (bp.dist < 0) across += 1;
    }
    try std.testing.expect(across > 10);
}

// The frames where layout caching is off — the first after the document is replaced under the
// editor (`Document.pending_sel`), or after an edit made outside it — lay the whole line out.
// It still has to draw.
test "a line far wider than the view draws with layout caching off" {
    const doc = try longLineDoc(60_000);
    defer std.testing.allocator.free(doc);

    te_cache_layout = false;
    defer te_cache_layout = true;

    var t = try textEntryCtx(doc, 0);
    defer deinitTextEntry(&t);

    try scrollAcrossLongLine();
}

// -- content-swap reveal ------------------------------------------------------------------------

// `core.anim.reveal` hides the one frame dvui needs to size newly-swapped content, then fades it
// in (see `core/reveal.zig`). The phase machine is unit-tested on its own; what needs a real
// window is the wiring — that the phases actually reach `dvui`'s alpha, that the animation is
// registered and completes, and that a settled pane ends fully opaque instead of stuck dim.

var reveal_key: u64 = 1;
var reveal_alpha: f32 = -1;

fn revealFrame() !dvui.App.Result {
    var b = dvui.box(@src(), .{ .dir = .vertical }, .{ .expand = .both });
    defer b.deinit();

    const rv = fizzy.core.anim.reveal(b.data().id, reveal_key, .{});
    defer rv.deinit();

    // Sampled inside the reveal's scope — this is what any content drawn here would be scaled by.
    reveal_alpha = dvui.currentWindow().alpha;
    return .ok;
}

test "a content swap hides one frame, fades in, and settles fully opaque" {
    var ctx = try shim.init(std.testing.allocator);
    defer ctx.deinit(std.testing.allocator);

    reveal_key = 1;

    // Frame 1: brand-new content. Laid out (so dvui can measure it) but not drawn.
    _ = try dvui.testing.step(revealFrame);
    try std.testing.expectEqual(@as(f32, 0), reveal_alpha);

    // Frame 2: measuring is done and the fade is registered, so this frame draws its first
    // value — the start of the ramp, still 0.
    _ = try dvui.testing.step(revealFrame);
    try std.testing.expectEqual(@as(f32, 0), reveal_alpha);

    // Frame 3: `testing.step` advances 100ms per frame, so the 120ms fade is partway up.
    _ = try dvui.testing.step(revealFrame);
    try std.testing.expect(reveal_alpha > 0);
    try std.testing.expect(reveal_alpha < 1);

    // And done by the next one.
    _ = try dvui.testing.step(revealFrame);
    try std.testing.expectEqual(@as(f32, 1), reveal_alpha);

    // Same key, no re-reveal: a pane redrawing unchanged content must not keep flickering.
    _ = try dvui.testing.step(revealFrame);
    try std.testing.expectEqual(@as(f32, 1), reveal_alpha);
}

test "switching to different content re-reveals" {
    var ctx = try shim.init(std.testing.allocator);
    defer ctx.deinit(std.testing.allocator);

    reveal_key = 1;
    for (0..4) |_| _ = try dvui.testing.step(revealFrame);
    try std.testing.expectEqual(@as(f32, 1), reveal_alpha);

    // A different document / store page / center provider.
    reveal_key = 2;
    _ = try dvui.testing.step(revealFrame);
    try std.testing.expectEqual(@as(f32, 0), reveal_alpha);

    for (0..4) |_| _ = try dvui.testing.step(revealFrame);
    try std.testing.expectEqual(@as(f32, 1), reveal_alpha);
}

// -- center-provider cross-fade -----------------------------------------------------------------

// Swapping center providers can't be a fade-in: each provider paints its own pane (square and
// full-bleed for a document canvas, a rounded card for the homepage / pack window / store page),
// so fading the incoming one up exposes the window behind it and changes the corner shape
// mid-swap. Instead the *outgoing* provider draws one more time into a texture, and that snapshot
// blurs out over the incoming one — see `core.anim.transition` and `Editor.drawActiveCenter`.
//
// What matters here is the draw bookkeeping: the outgoing provider gets exactly one extra draw,
// on the swap frame, and never again. On the testing backend (no render targets) that extra draw
// is skipped entirely — the same fallback the web build takes.

var center_a_draws: usize = 0;
var center_b_draws: usize = 0;

fn centerADraw(_: ?*anyopaque) anyerror!dvui.App.Result {
    center_a_draws += 1;
    return .ok;
}

fn centerBDraw(_: ?*anyopaque) anyerror!dvui.App.Result {
    center_b_draws += 1;
    return .ok;
}

var center_frame_ctx: *fizzy.Editor = undefined;

fn centerFrame() !dvui.App.Result {
    var b = dvui.box(@src(), .{ .dir = .vertical }, .{ .expand = .both });
    defer b.deinit();
    return fizzy.Editor.drawActiveCenter(center_frame_ctx);
}

test "a provider swap degrades cleanly when the backend has no render targets" {
    // dvui's testing backend returns an error from `textureCreateTarget`, so `Picture.start`
    // yields null and the capture never happens — the same path the web build takes. What that
    // must degrade to is the *old* behaviour (an instant swap), not a broken one: the outgoing
    // provider is not redrawn, nothing is retained, and no snapshot is left stuck over the new
    // content. The capture path itself needs a real GPU backend and is verified in the app.
    var ctx = try shim.init(std.testing.allocator);
    defer ctx.deinit(std.testing.allocator);

    const editor = ctx.editor;
    center_frame_ctx = editor;
    // Only the transition: every host registry a `registerSurface` touches comes down with
    // `ctx.deinit`'s `host.deinit`.
    defer editor.app.layout.center_transition.discard();

    try editor.app.host.registerSurface(.{ .id = "test.center.a", .title = "A", .keywords = fizzy.sdk.keywords.ide.main, .draw = centerADraw });
    try editor.app.host.registerSurface(.{ .id = "test.center.b", .title = "B", .keywords = fizzy.sdk.keywords.ide.main, .draw = centerBDraw });

    editor.app.host.setSelectionFor(fizzy.sdk.keywords.ide.main, "test.center.a");
    center_a_draws = 0;
    center_b_draws = 0;

    _ = try dvui.testing.step(centerFrame);
    _ = try dvui.testing.step(centerFrame);
    try std.testing.expectEqual(@as(usize, 2), center_a_draws);
    try std.testing.expectEqual(@as(usize, 0), center_b_draws);

    editor.app.host.setSelectionFor(fizzy.sdk.keywords.ide.main, "test.center.b");
    _ = try dvui.testing.step(centerFrame);
    _ = try dvui.testing.step(centerFrame);

    // B took over immediately; A stopped dead; nothing is being held on to.
    try std.testing.expectEqual(@as(usize, 2), center_a_draws);
    try std.testing.expectEqual(@as(usize, 2), center_b_draws);
    try std.testing.expect(editor.app.layout.center_transition.cross_fade.texture == null);
}

test "a center provider that disappears is not drawn for its own cross-fade" {
    // A plugin can be unloaded between frames, which is why the outgoing provider is looked up
    // again by id rather than cached — a stale `draw` pointer would be called on a dylib that is
    // no longer mapped.
    var ctx = try shim.init(std.testing.allocator);
    defer ctx.deinit(std.testing.allocator);

    const editor = ctx.editor;
    center_frame_ctx = editor;
    // Only the transition: every host registry a `registerSurface` touches comes down with
    // `ctx.deinit`'s `host.deinit`.
    defer editor.app.layout.center_transition.discard();

    try editor.app.host.registerSurface(.{ .id = "test.center.a", .title = "A", .keywords = fizzy.sdk.keywords.ide.main, .draw = centerADraw });
    try editor.app.host.registerSurface(.{ .id = "test.center.b", .title = "B", .keywords = fizzy.sdk.keywords.ide.main, .draw = centerBDraw });
    editor.app.host.setSelectionFor(fizzy.sdk.keywords.ide.main, "test.center.a");
    _ = try dvui.testing.step(centerFrame);

    center_a_draws = 0;
    center_b_draws = 0;

    // A goes away and B takes over in the same breath.
    _ = editor.app.host.surfaces.orderedRemove(0);
    editor.app.host.setSelectionFor(fizzy.sdk.keywords.ide.main, "test.center.b");
    _ = try dvui.testing.step(centerFrame);

    try std.testing.expectEqual(@as(usize, 0), center_a_draws);
    try std.testing.expectEqual(@as(usize, 1), center_b_draws);
}

// -- markdown preview virtualization ------------------------------------------------------------

// The markdown preview lays out only the blocks near the viewport (`render_ast.renderTopLevel`),
// which is the difference between ~34ms and ~2.5ms per frame on docs/PLUGINS.md in Debug. The
// whole optimization rests on one claim: skipping a block changes nothing the user can see,
// because its wrapper still reports the height the block had when it was last drawn.
//
// So compare layout, not widget counts: every top-level block's height, and the scroll
// container's resulting virtual size, must come out the same whether the blocks were all laid
// out or only the on-screen ones were. If a remembered height ever drifted from the measured
// one, the document below it would shift and the scrollbar would lie — and that is exactly what
// these two numbers catch. (Comparing rendered pixels would be better still, but dvui's testing
// backend has no render targets, so `dvui.testing.capturePng` is unavailable here.)
const markdown = @import("markdown");
const md_render_ast = markdown.render_ast;

var md_preview: markdown.Preview = .{};
var md_doc: []const u8 = "";
const md_sample = @embedFile("markdown_sample");
/// Table-heavy (`tests/data/markdown_sample_tables.md`, generated by the script beside it): one of
/// its tables is 48KB on its own, which is what makes it the document that exercises row culling
/// inside a table rather than only block skipping around it. Its cells wrap over many lines, and
/// that is not decoration. A frozen copy of an old plan doc stood here before it, and its tables'
/// cells mostly fit on a line or two — so a table whose height came out a few lines different
/// laid out than measured off screen passed every test here while the reader saw it move.
const md_sample_tables = @embedFile("markdown_sample_tables");
/// Image-heavy. Both samples above are prose and tables, so without this one no test in this file
/// ever laid out an image block — the block kind whose height nothing in the source predicts, and
/// which rescales with the pane right up until the pane is wider than the image. Its images point
/// at real files in `assets/`, which is what makes the heights below real numbers rather than
/// placeholder text.
const md_sample_images = @embedFile("markdown_sample_images");

fn markdownFrame() !dvui.App.Result {
    var b = dvui.box(@src(), .{ .dir = .vertical }, .{ .expand = .both });
    defer b.deinit();
    markdown.drawPreview(&md_preview, md_doc, std.testing.allocator, .{
        .io = dvui.io,
        // The directory the image fixture actually lives in, because that is what the app passes:
        // `image_base_dir` is the *document's* directory, so a document's relative image links
        // have to resolve from there. Passing the repo root here instead made the fixture's links
        // work in tests and break in the app — the fixture is opened both ways, and only one of
        // them was being checked.
        .image_base_dir = "tests/data",
        .id_extra = 0,
    });
    return .ok;
}

/// Steps until the layout has stopped moving: every block height settled, and no off-screen table
/// row still owed a measuring pass. Takes a while by design — the preview re-measures only a few
/// off-screen blocks and a few KB of table text per frame (`render_ast.resettle_budget`,
/// `render_ast.table_measure_bytes`), and the first real width arrives on frame two, when the
/// scroll viewport is known.
///
/// `pending_measure` is part of the condition and not just a nicety: a table block stops being
/// re-measured as soon as it has a height to stand on, long before its off-screen rows have been
/// measured, so waiting on block heights alone stops while the table is still hundreds of points
/// short of its real size.
///
/// "Settled" here means every block has stopped wanting a re-measure — `.settled` proper, or
/// `.deferred` (an off-screen table whose height can only be answered by scrolling to it). See
/// `block_heights.Height.State`.
fn markdownSettle() !void {
    for (0..600) |_| {
        _ = try dvui.testing.step(markdownFrame);
        var all = md_preview.rs.blocks.heights.items.len > 0;
        for (md_preview.rs.blocks.heights.items) |e| {
            if (e.wantsMeasure()) all = false;
        }
        if (all and md_render_ast.stats.pending_measure == 0) return;
    }
    // `MarkdownPreviewNeverSettled` on its own says nothing about *why*, and the answer is
    // always the same shape: which blocks are still owed a measure, and in what state. Printing
    // the tally is what turned "the layout never settles" into "164 of 185 blocks were never
    // measured once, because the resettle budget was gated on being near the viewport".
    var counts = @as([4]usize, @splat(0));
    for (md_preview.rs.blocks.heights.items) |e| counts[@backingInt(e.state)] += 1;
    std.debug.print(
        "\nnever settled: blocks={d} estimated={d} measured={d} settled={d} deferred={d} pending_measure={d}\n",
        .{ md_preview.rs.blocks.heights.items.len, counts[0], counts[1], counts[2], counts[3], md_render_ast.stats.pending_measure },
    );
    var shown: usize = 0;
    for (md_preview.rs.blocks.heights.items, 0..) |e, i| {
        if (!e.wantsMeasure()) continue;
        if (shown >= 10) break;
        shown += 1;
        std.debug.print("  block {d}: h={d:.2} state={s}\n", .{ i, e.h, @tagName(e.state) });
    }
    return error.MarkdownPreviewNeverSettled;
}

const MarkdownLayout = struct {
    heights: []f32,
    virtual_h: f32,

    fn deinit(self: MarkdownLayout, gpa: std.mem.Allocator) void {
        gpa.free(self.heights);
    }
};

/// Lays the document out scrolled `wheel_ticks` from the top and reports the resulting geometry.
fn markdownLayout(gpa: std.mem.Allocator, virtualize: bool, wheel_ticks: f32) !MarkdownLayout {
    md_render_ast.virtualize_blocks = virtualize;
    // Window first, so its `defer` runs *last*. `Preview.deinit` is what joins a background
    // parse worker, and that worker holds the window pointer it wakes on completion — tearing
    // the window down first left it refreshing freed memory.
    var t = try dvui.testing.init(.{ .allocator = gpa, .window_size = .{ .w = 900, .h = 700 } });
    defer t.deinit();

    md_preview = .{};
    defer md_preview.deinit();

    try markdownSettle();

    if (wheel_ticks != 0) {
        const cw = dvui.currentWindow();
        _ = try cw.addEventMouseMotion(.{ .pt = .{ .x = 400, .y = 300 } });
        _ = try cw.addEventMouseWheel(wheel_ticks, .vertical, null);
        try markdownSettle();
    }

    const heights = try gpa.alloc(f32, md_preview.rs.blocks.heights.items.len);
    for (md_preview.rs.blocks.heights.items, heights) |entry, *out| out.* = entry.h;
    return .{ .heights = heights, .virtual_h = md_preview.scroll.virtual_size.h };
}

test "markdown preview: skipping off-screen blocks lays the document out identically" {
    const gpa = std.testing.allocator;
    defer md_render_ast.virtualize_blocks = true;

    // Top, a screen or so down, and far enough that most of the document is behind the viewport.
    for ([_][]const u8{ md_sample, md_sample_tables, md_sample_images }) |sample| for ([_]f32{ 0, -1200, -6000 }) |ticks| {
        md_doc = sample;
        const full = try markdownLayout(gpa, false, ticks);
        defer full.deinit(gpa);
        const virtualized = try markdownLayout(gpa, true, ticks);
        defer virtualized.deinit(gpa);

        try std.testing.expect(full.heights.len > 30); // the samples really are long documents
        try std.testing.expectEqualSlices(f32, full.heights, virtualized.heights);
        // …and the scroll container's total is exactly those blocks plus the column's padding.
        // Deliberately *not* compared against the full render's total: drawing every block lets
        // each table's grid — a scroll container in its own right — ask the scroll area for more
        // room than the block actually occupies, which is why that number comes out ~20% larger
        // than the document really is.
        //
        // Within f32's precision at the document's size: both totals are f32 sums of hundreds of
        // heights, and at ~40000 pt one rounding step is already 0.004, so an absolute tolerance
        // failed whenever docs/PLUGINS.md (this sample) grew.
        var sum: f32 = 0;
        for (virtualized.heights) |h| sum += h;
        try std.testing.expectApproxEqRel(sum + 16, virtualized.virtual_h, 1e-6);
    };
}

/// Steps until the document has been parsed and placed. The parse runs on a worker thread, so a
/// fixed number of frames guarantees nothing about whether there is a document yet.
fn markdownAwaitParse() !void {
    for (0..600) |_| {
        _ = try dvui.testing.step(markdownFrame);
        if (md_preview.rs.blocks.len() > 0) return;
    }
    return error.MarkdownPreviewNeverParsed;
}

/// Scrolls by `ticks` and runs a fixed number of frames *without* waiting for settle — the point
/// is what the reader experiences mid-scroll, not the steady state they eventually reach.
fn markdownScroll(ticks: f32, frames: usize) !void {
    const cw = dvui.currentWindow();
    _ = try cw.addEventMouseMotion(.{ .pt = .{ .x = 400, .y = 300 } });
    _ = try cw.addEventMouseWheel(ticks, .vertical, null);
    for (0..frames) |_| _ = try dvui.testing.step(markdownFrame);
}

// The user-visible complaint these two encode: on plans/PLUGIN_MANIFEST_PLAN.md, scrolling about
// three quarters of the way down went unstable — the document jumped under the reader and the
// scrollbar jumped with it, and scrolling back up landed near the top of the document instead of
// where they had been.
//
// Both symptoms are the same defect seen from two ends: the document's total height was mostly
// low-biased *estimates* (blocks far from the viewport were never measured, so their guesses
// stood in for real heights), and an absolute `viewport.y` measured against a total that grows as
// you scroll into it cannot mean the same thing from one frame to the next.

test "markdown preview: the document's height stops moving once settled" {
    const gpa = std.testing.allocator;
    md_doc = md_sample_tables;
    // Window first, so its `defer` runs *last*. `Preview.deinit` is what joins a background
    // parse worker, and that worker holds the window pointer it wakes on completion — tearing
    // the window down first left it refreshing freed memory.
    var t = try dvui.testing.init(.{ .allocator = gpa, .window_size = .{ .w = 900, .h = 700 } });
    defer t.deinit();

    md_preview = .{};
    defer md_preview.deinit();
    try markdownSettle();

    // Every block measured, so no block may still be standing on a guess. An `.estimated` block
    // here is a block whose height the scrollbar is lying about.
    for (md_preview.rs.blocks.heights.items, 0..) |e, i| {
        if (e.state == .estimated) {
            std.debug.print("block {d} never measured (h={d:.2})\n", .{ i, e.h });
            return error.BlockLeftAtEstimate;
        }
    }

    // Scrolling a settled document must not change how tall it is. When it does, every scroll
    // position below the change means something different than it did the frame before — which
    // is exactly what "the scrollbar jumps while I scroll" is.
    const before = md_preview.scroll.virtual_size.h;
    try markdownScroll(-4000, 30);
    try std.testing.expectApproxEqAbs(before, md_preview.scroll.virtual_size.h, 1.0);
    try markdownScroll(-4000, 30);
    try std.testing.expectApproxEqAbs(before, md_preview.scroll.virtual_size.h, 1.0);
}

test "markdown preview: scrolling deep and back returns to the same place" {
    const gpa = std.testing.allocator;
    md_doc = md_sample_tables;
    // Window first, so its `defer` runs *last*. `Preview.deinit` is what joins a background
    // parse worker, and that worker holds the window pointer it wakes on completion — tearing
    // the window down first left it refreshing freed memory.
    var t = try dvui.testing.init(.{ .allocator = gpa, .window_size = .{ .w = 900, .h = 700 } });
    defer t.deinit();

    md_preview = .{};
    defer md_preview.deinit();
    try markdownSettle();

    // Three quarters of the way down — the region the instability was reported in.
    const max_scroll = md_preview.scroll.virtual_size.h - md_preview.scroll.viewport.h;
    try std.testing.expect(max_scroll > 2000); // it really is a long document
    md_preview.scroll.scrollToOffset(.vertical, max_scroll * 0.75);
    for (0..30) |_| _ = try dvui.testing.step(markdownFrame);

    const parked = md_preview.scroll.viewport.y;
    // The scroll must actually have taken effect — see the note in the rapid-scrolling test.
    try std.testing.expect(parked > max_scroll * 0.5);
    // A settled document must not drift while merely being looked at.
    for (0..30) |_| _ = try dvui.testing.step(markdownFrame);
    try std.testing.expectApproxEqAbs(parked, md_preview.scroll.viewport.y, 1.0);

    // Down a screen and back up the same amount: a round trip must be a no-op. It was not — the
    // heights discovered on the way down changed what the offset meant on the way back.
    try markdownScroll(-1500, 20);
    try markdownScroll(1500, 20);
    try std.testing.expectApproxEqAbs(parked, md_preview.scroll.viewport.y, 2.0);
}

// The case the anchor exists for. Every other test here holds the geometry still, which is
// precisely the condition under which the old absolute-offset scheme also looked fine.
//
// Here the reader parks three quarters of the way down and *then* the column reflows under them.
// Every height above them changes, so the pixel offset they were sitting at now points somewhere
// else entirely. Holding position through that is the whole reason scroll state is a source line
// rather than a number of pixels.
test "markdown preview: the reader holds position when the column reflows" {
    const gpa = std.testing.allocator;
    md_doc = md_sample_tables;
    // Window first, so its `defer` runs *last*. `Preview.deinit` is what joins a background
    // parse worker, and that worker holds the window pointer it wakes on completion — tearing
    // the window down first left it refreshing freed memory.
    var t = try dvui.testing.init(.{ .allocator = gpa, .window_size = .{ .w = 900, .h = 700 } });
    defer t.deinit();

    md_preview = .{};
    defer md_preview.deinit();

    try markdownSettle();

    // Park deep in the document. Growth *below* the reader moves nothing, so a reader near the
    // top would sit still even with no anchoring at all — the position has to be far enough down
    // that a reflow changes a lot of height above them.
    const max_before = md_preview.scroll.virtual_size.h - md_preview.scroll.viewport.h;
    try std.testing.expect(max_before > 2000);
    md_preview.scroll.scrollToOffset(.vertical, max_before * 0.75);
    for (0..5) |_| _ = try dvui.testing.step(markdownFrame);
    try std.testing.expect(md_preview.scroll.viewport.y > max_before * 0.5);

    const anchor = md_preview.anchor orelse return error.NoAnchor;
    try std.testing.expect(!anchor.at_end);
    const height_before = md_preview.scroll.virtual_size.h;

    // Narrow the window hard: every wrapped block reflows taller, including everything above the
    // reader. This is a sash drag, and it is the cleanest way to move a lot of height at once.
    // The testing backend reports its size from these fields, so writing them *is* a resize.
    t.backend.size = .{ .w = 450, .h = 700 };
    t.backend.size_pixels = .{ .w = 900, .h = 1400 };
    // One explicit frame before settling. `dvui.testing.step` ends with `Window.begin`, which is
    // what re-reads the backend size — so on the first step the frame still runs at the *old*
    // width, and `markdownSettle` would see an already-settled layout and return immediately,
    // before the resize had changed anything.
    _ = try dvui.testing.step(markdownFrame);
    try markdownSettle();

    // The document really did change size underneath them — otherwise this proves nothing.
    const height_after = md_preview.scroll.virtual_size.h;
    try std.testing.expect(@abs(height_after - height_before) > 500);

    // ...and they are still on the same source line, at the same offset into it. An absolute
    // pixel offset could not survive this: the content that used to be at that offset is now
    // hundreds of points further down.
    const now = md_preview.anchor.?;
    try std.testing.expectEqual(anchor.line, now.line);
    try std.testing.expectApproxEqAbs(anchor.offset_px, now.offset_px, 2.0);
}

// The symptom that outlasted the anchor: scrolling past the end of the big table, and into the
// next one, snapped and jumped.
//
// The anchor holds a reader against a *block*, so it cannot help when the block itself changes
// size — and a table's measured height was a function of where the reader was scrolled. Its rows
// are culled to what is on screen, and a row that had never been measured stood in with a
// placeholder, so the grid reported a different total depending on which rows happened to be real
// that frame. Every such change moved everything below it.
//
// The invariant that has to hold, and what this asserts: **a block's height is a function of the
// document, not of the scroll position.**
test "markdown preview: block heights do not depend on where the reader is" {
    const gpa = std.testing.allocator;
    md_doc = md_sample_tables;
    var t = try dvui.testing.init(.{ .allocator = gpa, .window_size = .{ .w = 900, .h = 700 } });
    defer t.deinit();
    md_preview = .{};
    defer md_preview.deinit();

    try markdownSettle();
    const base = try gpa.alloc(f32, md_preview.rs.blocks.heights.items.len);
    defer gpa.free(base);
    for (md_preview.rs.blocks.heights.items, base) |e, *o| o.* = e.h;
    const total_base = md_preview.scroll.virtual_size.h;
    try std.testing.expect(total_base > 10_000); // the sample really is a long document

    md_preview.scroll.scrollToOffset(.vertical, 0);
    try markdownSettle();

    // Wheel all the way down in steps, two frames each — no settling between them, which is what
    // a real scroll looks like and what the earlier tests here never exercised.
    var step_i: usize = 0;
    while (step_i < 90) : (step_i += 1) {
        try markdownScroll(-300, 2);
        for (md_preview.rs.blocks.heights.items, base, 0..) |e, b, bi| {
            if (@abs(e.h - b) > 1.0) {
                std.debug.print(
                    "\nblock {d} changed height while scrolling: {d:.1} -> {d:.1} (state {s}) at y={d:.1}\n",
                    .{ bi, b, e.h, @tagName(e.state), md_preview.scroll.viewport.y },
                );
                return error.BlockHeightDependsOnScroll;
            }
        }
    }

    // ...and the document is the same size at the bottom as it was at the top.
    try std.testing.expectApproxEqAbs(total_base, md_preview.scroll.virtual_size.h, 1.0);
}

// Rapidly scrolling up and down through the tables made the preview jump wildly, and it survived
// both the anchor and the "block heights do not depend on scroll position" fix. Two distinct
// causes, neither visible to a test that scrolls gently in one direction:
//
//  1. A table's *emitted* height was still unstable even when its recorded height was not. The
//     scroll container builds `virtual_size` from widgets, not from the height table, so refusing
//     to record a bad measurement did not stop it reaching the scrollbar. Block 5 emitted 46pt on
//     one frame and 29,995pt on another against a real ~6,132.
//  2. The anchor was re-derived every frame, so any single frame of bad geometry became the
//     reader's stored position permanently.
test "markdown preview: rapid scrolling up and down does not move the document" {
    const gpa = std.testing.allocator;
    md_doc = md_sample_tables;
    var t = try dvui.testing.init(.{ .allocator = gpa, .window_size = .{ .w = 900, .h = 700 } });
    defer t.deinit();
    md_preview = .{};
    defer md_preview.deinit();

    try markdownSettle();
    const max = md_preview.scroll.virtual_size.h - md_preview.scroll.viewport.h;
    try std.testing.expect(max > 5000);

    // Park inside the big table.
    md_preview.scroll.scrollToOffset(.vertical, max * 0.6);
    try markdownSettle();
    const parked = md_preview.scroll.viewport.y;
    // Guard against the test silently running at the top: an anchor that overwrote the offset
    // between frames used to discard `scrollToOffset` entirely, which made several tests here
    // pass while asserting nothing.
    try std.testing.expect(parked > max * 0.5);

    const total = md_preview.scroll.virtual_size.h;

    // Thrash: one frame per direction change, which is what outruns every budget in the renderer.
    var round: usize = 0;
    while (round < 12) : (round += 1) {
        try markdownScroll(-2000, 1);
        try markdownScroll(2000, 1);
        try std.testing.expectApproxEqAbs(parked, md_preview.scroll.viewport.y, 1.0);
        try std.testing.expectApproxEqAbs(total, md_preview.scroll.virtual_size.h, 1.0);
    }
}

// Dragging the split-pane sash: every cached height is invalidated on every frame of the drag,
// which is the harshest thing that happens to this renderer. Two things must hold at once, and
// they pull against each other — the document has to actually reflow, and the reader must not
// move while it does.
//
// Getting the second one by freezing everything is not a pass: an earlier version pinned table
// blocks so hard they could never relearn their height (a pinned block measures exactly its pin,
// so it agrees with itself forever), and the document silently stopped reflowing. Hence the
// explicit assertion that the total really did change.
test "markdown preview: the reader holds position while the sash is dragged" {
    const gpa = std.testing.allocator;
    md_doc = md_sample_tables;
    var t = try dvui.testing.init(.{ .allocator = gpa, .window_size = .{ .w = 900, .h = 700 } });
    defer t.deinit();
    md_preview = .{};
    defer md_preview.deinit();

    try markdownSettle();
    const max = md_preview.scroll.virtual_size.h - md_preview.scroll.viewport.h;
    md_preview.scroll.scrollToOffset(.vertical, max * 0.6);
    try markdownSettle();

    const start = md_preview.anchor orelse return error.NoAnchor;
    try std.testing.expect(md_preview.scroll.viewport.y > max * 0.5); // really did park
    const total_before = md_preview.scroll.virtual_size.h;

    // 900 -> 500 in 10pt steps, one frame each: a drag, not a jump.
    var w: f32 = 900;
    var i: usize = 0;
    while (i < 40) : (i += 1) {
        w -= 10;
        t.backend.size = .{ .w = w, .h = 700 };
        t.backend.size_pixels = .{ .w = w * 2, .h = 1400 };
        _ = try dvui.testing.step(markdownFrame);

        // Checked every frame, not just at the end: the failure this guards against was the
        // reader creeping a little on each frame of the drag.
        const now = md_preview.anchor orelse return error.NoAnchor;
        try std.testing.expectEqual(start.line, now.line);
        try std.testing.expectApproxEqAbs(start.offset_px, now.offset_px, 2.0);

        // The pane must still be *drawing* while it is dragged. Skipping work during a resize is
        // the obvious way to make one fast, and an over-eager version of exactly that (zeroing
        // the table's on-screen row budget along with its off-screen one) made every visible row
        // cull itself, so the table rendered blank for the whole drag while the timings looked
        // excellent. Cheap frames that draw nothing are not the goal.
        try std.testing.expect(md_render_ast.stats.add_text_bytes > 500);
    }

    // The column really did narrow, and the document really did get taller for it.
    try std.testing.expect(md_preview.rs.blocks.layout_width < 550);
    try std.testing.expect(md_preview.scroll.virtual_size.h > total_before + 500);
}

/// How tall a block has to be before only a decoded image can explain it. Prose blocks in the
/// image fixture wrap to something on the order of 100pt at the widths used here; a "file not
/// found" placeholder is a single line of text. A 512x512 image lands at 512pt and a 1024x1024
/// one at the 540pt display ceiling, so this threshold sits in a wide empty gap between the two
/// populations rather than close to either.
const md_image_block_min_h: f32 = 400;

fn mdTallBlockCount() usize {
    var n: usize = 0;
    for (md_preview.rs.blocks.heights.items) |e| {
        if (e.h > md_image_block_min_h) n += 1;
    }
    return n;
}

// Guards every other image test in this file against passing vacuously.
//
// The image fixture's stability claims are only worth something if the images behind them are
// actually being decoded and laid out. If the harness cannot resolve `assets/fox.png` — a
// different working directory, a moved asset, a change to how `image_base_dir` is joined — then
// every image in the document renders as a one-line "image not found" placeholder, the document
// becomes ordinary prose, and a stability test over it passes while testing nothing at all.
//
// So this asserts the fixture is live *before* anything asserts it is stable: three of its images
// point at real square PNGs in `assets/`, and a decoded square image is hundreds of points tall.
// Nothing else in the document can produce a block that size.
test "markdown preview: the image fixture's images really decode" {
    const gpa = std.testing.allocator;
    md_doc = md_sample_images;
    var t = try dvui.testing.init(.{ .allocator = gpa, .window_size = .{ .w = 900, .h = 700 } });
    defer t.deinit();
    md_preview = .{};
    defer md_preview.deinit();

    try markdownSettle();

    // assets/fox.png and assets/fox_bg.png are 512x512, assets/icon.png is 1024x1024 and is
    // capped at the 540pt display ceiling.
    const tall = mdTallBlockCount();
    if (tall < 3) {
        std.debug.print(
            "\nonly {d} block(s) tall enough to be a decoded image — images are not loading, " ++
                "so every image test over this fixture is vacuous\n",
            .{tall},
        );
        for (md_preview.rs.blocks.heights.items, 0..) |e, i| {
            if (i >= 12) break;
            std.debug.print("  block {d}: h={d:.2} state={s}\n", .{ i, e.h, @tagName(e.state) });
        }
        return error.ImagesNotLoading;
    }
}

// The condition the user named: dragging the sash, on a document with images in it.
//
// The table fixture already covers this, but an image is the harder case and was never covered.
// A table's height is width-dependent because its cells re-wrap; an image's is width-dependent by
// construction — a square image occupies the full column width until the column is wider than the
// image, so every image above the reader loses height on every frame of a narrowing drag, and the
// anchor has to absorb all of it at once. The blank-pane bug this whole area started from was
// exactly an image: a measured 540pt block crushed to its ~14pt source estimate mid-drag.
//
// Images are also the one block kind the pin at `render_ast.zig` does not cover — it is scoped to
// blocks containing a table — so nothing holds an image's emitted height steady on its behalf.
test "markdown preview: the reader holds position while the sash is dragged past images" {
    const gpa = std.testing.allocator;
    md_doc = md_sample_images;
    var t = try dvui.testing.init(.{ .allocator = gpa, .window_size = .{ .w = 900, .h = 700 } });
    defer t.deinit();
    md_preview = .{};
    defer md_preview.deinit();

    try markdownSettle();
    try std.testing.expect(mdTallBlockCount() >= 3); // fixture is live; see the test above

    const max = md_preview.scroll.virtual_size.h - md_preview.scroll.viewport.h;
    md_preview.scroll.scrollToOffset(.vertical, max * 0.6);
    try markdownSettle();

    const start = md_preview.anchor orelse return error.NoAnchor;
    try std.testing.expect(md_preview.scroll.viewport.y > max * 0.4); // really did park

    // Snapshot the image blocks so the end of the test can prove the drag actually squeezed them.
    // Recorded as heights rather than checked against a fixed threshold: at a 500pt window the
    // column is still ~470pt, so a 512pt image only falls to ~470 and any absolute cutoff either
    // sits inside the prose population or above the squeezed images. What matters is that they
    // moved, not where they landed.
    var img_before = std.ArrayList(struct { index: usize, h: f32 }).empty;
    defer img_before.deinit(gpa);
    for (md_preview.rs.blocks.heights.items, 0..) |e, idx| {
        if (e.h > md_image_block_min_h) try img_before.append(gpa, .{ .index = idx, .h = e.h });
    }

    // 900 -> 400 in 10pt steps, one frame each: a drag, not a jump.
    //
    // It has to travel this far to be a real test. The fixture's images are 512pt and 1024pt
    // square, and an image only starts losing height once the column is narrower than it is —
    // so a drag that stops at 500 leaves the 512pt images still sitting at their natural size,
    // and the only block under any pressure is the one that was pinned to the 540pt display
    // ceiling. Going to 400 puts every image in the document under the column.
    var w: f32 = 900;
    var i: usize = 0;
    while (i < 50) : (i += 1) {
        w -= 10;
        t.backend.size = .{ .w = w, .h = 700 };
        t.backend.size_pixels = .{ .w = w * 2, .h = 1400 };
        _ = try dvui.testing.step(markdownFrame);

        // Checked every frame rather than only at the end: the failure mode is the reader
        // creeping a little on each frame of the drag, which a before/after comparison would
        // report as one small discrepancy instead of forty.
        const now = md_preview.anchor orelse return error.NoAnchor;
        if (start.line != now.line or @abs(start.offset_px - now.offset_px) > 2.0) {
            std.debug.print(
                "\nreader moved on drag frame {d} (w={d:.0}): line {d}+{d:.2} -> {d}+{d:.2}\n",
                .{ i, w, start.line, start.offset_px, now.line, now.offset_px },
            );
            return error.ReaderMovedDuringSashDrag;
        }

        // The pane must still be drawing while it is dragged — see the table version of this
        // test, where an over-eager budget cut rendered the table blank for the whole drag while
        // the timings looked excellent.
        try std.testing.expect(md_render_ast.stats.add_text_bytes > 500);
    }

    // The drag has to have actually done something to the images, or the test above is holding
    // the reader still against no pressure at all. Every image the fixture loads is wider than
    // the narrowed column, so every one of them has to have given up height.
    try std.testing.expect(md_preview.rs.blocks.layout_width < 450);
    // Let the drag's aftermath finish before judging the heights: off-screen blocks are
    // re-measured on a per-frame budget, so an image above the reader is legitimately still
    // carrying its pre-drag height on the frame the drag ends. What is not legitimate is it
    // still carrying that height once nothing is asking to be measured any more.
    try markdownSettle();
    for (img_before.items) |b| {
        const now = md_preview.rs.blocks.heights.items[b.index].h;
        if (b.h - now < 20) {
            std.debug.print(
                "\nimage block {d} went {d:.2} -> {d:.2} across a 900->{d:.0} drag: the images " ++
                    "did not rescale, so this test held the reader still against no pressure\n",
                .{ b.index, b.h, now, w },
            );
            return error.ImagesDidNotRescale;
        }
    }
}

// An image must never be drawn wider than the column it is in, on ANY frame — including the
// frames of a pane slide, which is where it was going wrong.
//
// The wrapper's content rect, which is what the image was sized from, lags while the pane is
// being resized (measured at two frames behind during a slide). While the pane is *narrowing* a
// stale width is a larger one, so the image was drawn wider than the pane it had to fit in and
// then snapped back once the rect caught up — visible as the image jumping around while the
// split animation ran. `column_width` is recomputed from the viewport every frame, so the size
// is taken as the smaller of the two.
//
// This was invisible until the fixed 720x540 display box was removed: for any column wider than
// 720 both widths clamped to the same box, so the lag could not show.
//
// Only the FIRST image is checked, with the reader held at the top so that block is on screen
// and therefore actually drawn every frame. An off-screen block legitimately carries its last
// measurement until the re-measure budget reaches it, so asserting over every block would fail
// on blocks that are behaving correctly. Both sides of the comparison come from the same frame,
// which keeps it honest regardless of how the harness times a backend resize.
test "markdown preview: an image is never wider than the column while the pane slides" {
    const gpa = std.testing.allocator;
    md_doc = md_sample_images;
    var t = try dvui.testing.init(.{ .allocator = gpa, .window_size = .{ .w = 900, .h = 700 } });
    defer t.deinit();
    md_preview = .{};
    defer md_preview.deinit();

    try markdownSettle();
    try std.testing.expect(mdTallBlockCount() >= 3); // fixture is live
    md_preview.scroll.scrollToOffset(.vertical, 0);
    try markdownSettle();

    var first_img: ?usize = null;
    for (md_preview.rs.blocks.extents.items, 0..) |ext, idx| {
        if (ext.kind == .image) {
            first_img = idx;
            break;
        }
    }
    const img = first_img orelse return error.NoImageBlock;

    // Everything the fixture loads is square, so an image block's height is its width plus the
    // caption line under it. Allow for the caption and its margins, and nothing more.
    const caption_slack: f32 = 80;

    // Big steps on purpose: the error is proportional to how far the pane moves per frame, so a
    // slow drag hides it. This is a slide, not a drag.
    var w: f32 = 900;
    var i: usize = 0;
    while (i < 6) : (i += 1) {
        w -= 100;
        t.backend.size = .{ .w = w, .h = 700 };
        t.backend.size_pixels = .{ .w = w * 2, .h = 1400 };
        _ = try dvui.testing.step(markdownFrame);

        const col = md_preview.rs.blocks.layout_width;
        const h = md_preview.rs.blocks.heights.items[img];
        if (h.state == .estimated) continue; // never drawn; nothing was emitted to be wrong
        if (h.h > col + caption_slack) {
            std.debug.print(
                "\nimage block {d} is {d:.1}pt tall in a {d:.1}pt column: the image is being " ++
                    "drawn wider than the pane it is in\n",
                .{ img, h.h, col },
            );
            return error.ImageWiderThanColumn;
        }
    }
}

// Scrolling UP must not lay the document out at last frame's geometry.
//
// Off-screen blocks are collapsed into a single spacer whose height is the sum of the heights it
// stands in for. dvui sizes a widget to `max(min_size_content, what it measured last frame)`, so a
// spacer that keeps the same widget id also keeps its old height. Scrolling up shrinks the run as
// blocks come into view, so the spacer asks to get *shorter* and is handed last frame's taller
// value instead — laying every block below it exactly one block too low, then snapping back on the
// next frame.
//
// This is the bug that survived every other probe in this file, because nothing it touches is a
// block: the height table, the anchor and `virtual_size` are all computed from block heights and
// stayed perfectly consistent while the page visibly jumped. `RenderState.place_err` is the gap
// between where the table says the first drawn block is and where it was actually laid out, which
// is the one quantity that can see it. Measured at 290pt on docs/PLUGINS.md and 589pt on the image
// fixture before the fix.
//
// Note the direction: scrolling DOWN never showed it, because a growing run is already the larger
// value and `max` takes it immediately. A test that only scrolls down passes either way.
test "markdown preview: scrolling up does not lay blocks out at the previous frame's geometry" {
    const gpa = std.testing.allocator;
    for ([_][]const u8{ md_sample, md_sample_tables, md_sample_images }) |sample| {
        md_doc = sample;
        var t = try dvui.testing.init(.{ .allocator = gpa, .window_size = .{ .w = 560, .h = 800 } });
        defer t.deinit();
        md_preview = .{};
        defer md_preview.deinit();
        try markdownSettle();

        // Park deep enough that there is a substantial run of skipped blocks above the reader —
        // which is the thing whose height goes stale.
        const max = md_preview.scroll.virtual_size.h - md_preview.scroll.viewport.h;
        md_preview.scroll.scrollToOffset(.vertical, max * 0.4);
        try markdownSettle();
        try std.testing.expect(md_preview.scroll.viewport.y > 1000); // really did park

        var prev = md_preview.rs.place_err;
        var i: usize = 0;
        while (i < 60) : (i += 1) {
            try markdownScroll(30, 1); // positive ticks scroll up
            const cur = md_preview.rs.place_err;
            if (!std.math.isNan(prev) and !std.math.isNan(cur) and @abs(cur - prev) > 8) {
                std.debug.print(
                    "\nplacement moved {d:.1} -> {d:.1} ({d:.1}pt) at viewport y={d:.1}: the block " ++
                        "was laid out somewhere other than where the height table puts it\n",
                    .{ prev, cur, cur - prev, md_preview.scroll.viewport.y },
                );
                return error.BlockLaidOutAtStaleGeometry;
            }
            prev = cur;
        }
    }
}

// Syntax highlighting in a fenced code block, exercised for real rather than only compiled.
//
// The markdown plugin bundles no grammars: it maps the fence's language tag to an extension and
// asks the host which plugin claims it. So the interesting behaviour only happens when a language
// provider is registered, which is what this sets up — a real tree-sitter grammar (already linked
// into this binary through the text module) and real queries, standing in for the external `zig`
// language plugin the app would use.
//
// The height assertion is the load-bearing one. Highlighting is allowed to change *colour* and
// nothing else: a block's height feeds the height table, the anchor and the scroll total, so a
// highlighted fence that measured differently from a plain one would be able to move the reader.
// Emitting the same text in the same font as several styled runs instead of one must be invisible
// to the layout.
extern fn tree_sitter_zig() callconv(.c) *dvui.c.TSLanguage;
const ts_zig_queries = @embedFile("ts_zig_queries");

const md_code_sample =
    \\# Code
    \\
    \\Some prose before the fence so the block is not the first thing in the document.
    \\
    \\```zig
    \\const std = @import("std");
    \\
    \\pub fn main() !void {
    \\    var total: usize = 0;
    \\    for (0..10) |i| total += i;
    \\    std.debug.print("total {d}\\n", .{total});
    \\}
    \\```
    \\
    \\Some prose after it as well, so the fence has a neighbour on both sides.
    \\
;

fn mdZigHighlight(_: *anyopaque, ext: []const u8) ?sdk.language.TreeSitterHighlight {
    if (!std.mem.eql(u8, ext, ".zig")) return null;
    return .{
        .language = @ptrCast(tree_sitter_zig()),
        .queries = ts_zig_queries,
        .highlights = &md_zig_styles,
    };
}

const md_zig_styles = [_]sdk.language.HighlightStyle{
    .{ .name = "comment", .opts = .{ .color_text = .fromHex("6A9955") } },
    .{ .name = "keyword", .opts = .{ .color_text = .fromHex("569CD6") } },
    .{ .name = "function", .opts = .{ .color_text = .fromHex("DCDCAA") } },
    .{ .name = "type", .opts = .{ .color_text = .fromHex("4EC9B0") } },
    .{ .name = "string", .opts = .{ .color_text = .fromHex("CE9178") } },
};

const md_zig_ls_vtable: sdk.LanguageSupport.VTable = .{ .treeSitterHighlight = mdZigHighlight };

// `Host.treeSitterHighlightFor` skips any provider with no owner (it needs somewhere to get the
// `state` pointer every hook takes), so the stand-in language plugin needs a `Plugin` even though
// this one holds no state of its own.
var md_zig_plugin_state: u8 = 0;
const md_zig_plugin_vtable: sdk.Plugin.VTable = .{};
var md_zig_plugin: sdk.Plugin = .{
    .state = @ptrCast(&md_zig_plugin_state),
    .vtable = &md_zig_plugin_vtable,
    .id = "test_zig_lang",
    .display_name = "Zig (test)",
};

test "markdown preview: a code fence is highlighted without changing its height" {
    const gpa = std.testing.allocator;
    md_doc = md_code_sample;

    // Plain first: no host, so `drawHighlightedCode` bails and the fence is plain monospace.
    const plain_h, const plain_bytes = blk: {
        var t = try dvui.testing.init(.{ .allocator = gpa, .window_size = .{ .w = 700, .h = 700 } });
        defer t.deinit();
        md_preview = .{};
        defer md_preview.deinit();
        md_render_ast.highlight_host = null;
        try markdownSettle();
        break :blk .{ md_preview.scroll.virtual_size.h, md_render_ast.stats.add_text_bytes };
    };

    // Now with a language provider registered, which is what makes the fence highlight.
    var host: sdk.Host = .init(gpa);
    defer host.deinit();
    try host.registerLanguageSupport(.{
        .id = "test-zig",
        .vtable = &md_zig_ls_vtable,
        .owner = &md_zig_plugin,
    });

    const lit_h, const lit_runs = blk: {
        var t = try dvui.testing.init(.{ .allocator = gpa, .window_size = .{ .w = 700, .h = 700 } });
        defer t.deinit();
        md_preview = .{};
        defer md_preview.deinit();
        md_render_ast.highlight_host = &host;
        defer md_render_ast.highlight_host = null;
        try markdownSettle();
        break :blk .{ md_preview.scroll.virtual_size.h, md_render_ast.stats.add_text_calls };
    };

    // Anti-vacuity: the highlighted pass must have split the fence into several styled runs. If
    // the grammar or queries ever stop resolving, this fails instead of the test quietly
    // asserting that plain text equals plain text.
    if (lit_runs < 6) {
        std.debug.print(
            "\nonly {d} addText call(s) with a language provider registered — the fence was not " ++
                "highlighted, so this test proves nothing\n",
            .{lit_runs},
        );
        return error.CodeFenceNotHighlighted;
    }
    try std.testing.expect(plain_bytes > 0);

    // ...and colouring it must not have moved anything.
    try std.testing.expectApproxEqAbs(plain_h, lit_h, 0.5);
}

// The workflow this preview actually exists for: typing in the editor with the preview beside it.
// Every keystroke re-parses the document, and a re-parse used to throw the whole height table
// away — all 50 blocks fell back to estimates, the total collapsed from 20,093 to 8,886, and the
// reader was thrown hundreds of points for several frames. Once per character.
//
// Two things keep it still now, and both are needed: heights are keyed by block source so an edit
// only invalidates the block it touched, and the anchor identifies its block by source hash so an
// insertion above the reader does not renumber them out from under it.
test "markdown preview: an edit does not move the reader or lose the layout" {
    const gpa = std.testing.allocator;
    // The same document with one line inserted near the top — what typing looks like from here.
    const edited = try std.mem.concat(gpa, u8, &.{ md_sample_tables[0..200], "\nnew line\n", md_sample_tables[200..] });
    defer gpa.free(edited);

    md_doc = md_sample_tables;
    var t = try dvui.testing.init(.{ .allocator = gpa, .window_size = .{ .w = 900, .h = 700 } });
    defer t.deinit();
    md_preview = .{};
    defer md_preview.deinit();

    try markdownSettle();
    const max = md_preview.scroll.virtual_size.h - md_preview.scroll.viewport.h;
    md_preview.scroll.scrollToOffset(.vertical, max * 0.6);
    try markdownSettle();

    const y_before = md_preview.scroll.viewport.y;
    const total_before = md_preview.scroll.virtual_size.h;
    try std.testing.expect(y_before > max * 0.5); // really did park

    md_doc = edited;
    _ = try dvui.testing.step(markdownFrame);

    // On the very first frame after the edit, most of the layout must survive. Blocks the edit did
    // not touch keep their measured heights, so the document does not momentarily believe it is
    // half its real size.
    try std.testing.expect(md_preview.scroll.virtual_size.h > total_before * 0.8);
    var kept: usize = 0;
    for (md_preview.rs.blocks.heights.items) |e| {
        if (e.state != .estimated) kept += 1;
    }
    try std.testing.expect(kept > md_preview.rs.blocks.heights.items.len / 2);

    // And the reader ends up exactly where they were, despite every line below the insertion
    // having been renumbered.
    try markdownSettle();
    try std.testing.expectApproxEqAbs(y_before, md_preview.scroll.viewport.y, 2.0);
}

// Before a block has ever been laid out, its height is a guess from its source — and until the
// warm-up sweep finishes, the scrollbar is the sum of those guesses. The guess used to ignore what
// kind of block it was: an image is one line of source and hundreds of points tall, a table row is
// a line of source and a line *plus* cell padding, a heading is a line in a much larger font. All
// the errors pointed the same way, and plans/PLUGIN_MANIFEST_PLAN.md estimated at 24% of its real
// length — a scrollbar claiming the document was a quarter of its true size.
//
// A band, not a number: these are guesses and are meant to be. What matters is that they are the
// right order of magnitude, and that a future change to the estimator cannot quietly undo that.
test "markdown preview: the estimated document length is in the right ballpark" {
    const gpa = std.testing.allocator;
    for ([_][]const u8{ md_sample, md_sample_tables, md_sample_images }) |sample| {
        md_doc = sample;
        var t = try dvui.testing.init(.{ .allocator = gpa, .window_size = .{ .w = 900, .h = 700 } });
        defer t.deinit();
        md_preview = .{};
        defer md_preview.deinit();

        try markdownAwaitParse();
        const m = md_render_ast.currentMetricsForTest();
        const w = md_preview.rs.blocks.layout_width;
        var est: f32 = 0;
        for (0..md_preview.rs.blocks.len()) |i| est += md_preview.rs.blocks.estimate(i, m, w) orelse 0;

        try markdownSettle();
        var real: f32 = 0;
        for (md_preview.rs.blocks.heights.items) |e| real += e.h;

        try std.testing.expect(real > 10_000); // these really are long documents
        const ratio = est / real;
        if (ratio < 0.7 or ratio > 1.4) {
            std.debug.print("\nestimated length {d:.0} vs real {d:.0} ({d:.0}%)\n", .{ est, real, ratio * 100 });
            return error.EstimateOutOfBand;
        }
    }
}

// Scrolling the whole document down and back up, checking every step that the reader went where
// they asked and nowhere else. This is the shape of the bug reports that kept coming back — "it
// jumps to the top", "it jumps to the bottom" — and none of the earlier tests could see it,
// because they all parked somewhere and thrashed locally instead of traversing.
//
// The last one it caught: anchoring by block source hash, where the hash identifies *text* and
// documents repeat themselves. plans/PLUGIN_MANIFEST_PLAN.md has seven top-level blocks sharing a
// single hash, so an anchor on any of them resolved to whichever copy came first and the reader
// was thrown to the top of the document.
test "markdown preview: scrolling through the document never jumps past where it was asked" {
    const gpa = std.testing.allocator;
    // Both samples: PLUGINS.md is the longer one (185 blocks) and has its own tables. Running
    // this only on the table-heavy sample missed it entirely.
    for ([_][]const u8{ md_sample, md_sample_tables, md_sample_images }) |sample| {
        md_doc = sample;
        var t = try dvui.testing.init(.{ .allocator = gpa, .window_size = .{ .w = 900, .h = 700 } });
        defer t.deinit();
        md_preview = .{};
        defer md_preview.deinit();

        try markdownSettle();
        md_preview.scroll.scrollToOffset(.vertical, 0);
        try markdownSettle();

        // Small steps on purpose. A coarse traversal steps straight over the short blocks — a rule, a
        // one-line paragraph — and those are exactly the ones a document repeats, so a coarse sweep
        // never anchors on one and never sees the bug that repetition causes.
        const step_px: f32 = 100;
        // Generous: one step of scrolling, plus room for the document's total to still be settling.
        const tolerance: f32 = step_px + 250;

        var down: usize = 0;
        while (down < 220) : (down += 1) {
            const before = md_preview.scroll.viewport.y;
            try markdownScroll(-step_px, 2);
            const after = md_preview.scroll.viewport.y;
            if (after < before - 1 or after > before + tolerance) {
                std.debug.print("\nscrolling down: y {d:.1} -> {d:.1} (asked for +{d:.0})\n", .{ before, after, step_px });
                return error.ScrollJumped;
            }
        }
        try std.testing.expect(md_preview.scroll.viewport.y > 5000); // it really did travel

        var up: usize = 0;
        while (up < 260) : (up += 1) {
            const before = md_preview.scroll.viewport.y;
            try markdownScroll(step_px, 2);
            const after = md_preview.scroll.viewport.y;
            if (after > before + 1 or after < before - tolerance) {
                std.debug.print("\nscrolling up: y {d:.1} -> {d:.1} (asked for -{d:.0})\n", .{ before, after, step_px });
                return error.ScrollJumped;
            }
        }
        try std.testing.expectApproxEqAbs(@as(f32, 0), md_preview.scroll.viewport.y, 1.0);
    }
}

// The preview must stop asking for frames. `dvui.Window.end` returns 0 while a refresh is pending
// ("render again immediately") and null when there is nothing to do — so a preview that keeps
// returning 0 is an app that never sleeps, burning battery behind an idle window.
//
// This is not hypothetical: the renderer asks for another frame whenever any block or table row is
// still owed a measuring pass, and "keep asking until it converges" is not a termination argument.
// A table whose cells never agree with the column width they are laid out in never converges, and
// the preview then holds the whole app awake for as long as the document is open.
fn markdownReachesIdle() !bool {
    // Generous: the warm-up sweep legitimately wants a few hundred frames on a long document.
    for (0..900) |_| {
        const wait = try dvui.testing.step(markdownFrame);
        if (wait == null or wait.? > 0) return true;
    }
    return false;
}

test "markdown preview: stops asking for frames so the app can sleep" {
    const gpa = std.testing.allocator;
    for ([_][]const u8{ md_sample, md_sample_tables, md_sample_images }) |sample| {
        md_doc = sample;
        var t = try dvui.testing.init(.{ .allocator = gpa, .window_size = .{ .w = 900, .h = 700 } });
        defer t.deinit();
        md_preview = .{};
        defer md_preview.deinit();

        try markdownAwaitParse();
        if (!try markdownReachesIdle()) {
            var counts = @as([4]usize, @splat(0));
            for (md_preview.rs.blocks.heights.items) |e| counts[@backingInt(e.state)] += 1;
            std.debug.print(
                "\nnever idle: estimated={d} measured={d} settled={d} deferred={d} pending_measure={d}\n",
                .{ counts[0], counts[1], counts[2], counts[3], md_render_ast.stats.pending_measure },
            );
            return error.PreviewNeverStopsRequestingFrames;
        }

        // ...and it must still be idle after scrolling into the tables and back, which is where
        // the never-settling measurements live.
        try markdownScroll(-8000, 4);
        if (!try markdownReachesIdle()) return error.PreviewNeverStopsRequestingFramesAfterScroll;
        try markdownScroll(8000, 4);
        if (!try markdownReachesIdle()) return error.PreviewNeverStopsRequestingFramesAfterScrollBack;
    }
}

// Typing, one character at a time, with the preview open beside the editor. This is the single
// most common thing anyone does with this preview, and every keystroke re-parses the document.
//
// The per-edit test above inserts one line and checks the reader comes back. That is not the same
// as *never leaving*: a jump that lasts one frame and corrects itself is still a jump the reader
// sees, once per character.
var md_edit_buf: std.ArrayListUnmanaged(u8) = .empty;

test "markdown preview: typing does not move the preview" {
    const gpa = std.testing.allocator;
    md_edit_buf.clearRetainingCapacity();
    defer md_edit_buf.deinit(gpa);
    try md_edit_buf.appendSlice(gpa, md_sample);
    md_doc = md_edit_buf.items;

    var t = try dvui.testing.init(.{ .allocator = gpa, .window_size = .{ .w = 900, .h = 700 } });
    defer t.deinit();
    md_preview = .{};
    defer md_preview.deinit();

    try markdownSettle();
    const max = md_preview.scroll.virtual_size.h - md_preview.scroll.viewport.h;
    // Deep, so that every table in the document is *above* the reader. A table's height changing
    // below them moves nothing; the whole question is what happens to content above.
    md_preview.scroll.scrollToOffset(.vertical, max * 0.9);
    try markdownSettle();

    const parked = md_preview.scroll.viewport.y;
    try std.testing.expect(parked > max * 0.8);

    // Type into a paragraph near the top — above the reader, so any height it gains moves
    // everything they are looking at.
    var typed: usize = 0;
    while (typed < 12) : (typed += 1) {
        try md_edit_buf.insert(gpa, 300, 'x');
        md_doc = md_edit_buf.items;
        // A couple of frames per keystroke, which is what a typist actually gives it.
        for (0..2) |_| _ = try dvui.testing.step(markdownFrame);
        if (@abs(md_preview.scroll.viewport.y - parked) > 3) {
            std.debug.print(
                "\nkeystroke {d}: preview moved {d:.1} -> {d:.1} (total {d:.0})\n",
                .{ typed, parked, md_preview.scroll.viewport.y, md_preview.scroll.virtual_size.h },
            );
            return error.PreviewMovedWhileTyping;
        }
    }
}

// -- the files service -------------------------------------------------------------------------

// Creating, renaming, deleting and moving used to be `Host` methods, which made fizzy's
// implementation the only one an app could have. They are a service now, and this is the whole
// contract: an app registers an implementation, a plugin asks for it by type and version, and a
// plugin that does not find one carries on without it.
test "the files service is the app's to provide, and a plugin asking for it gets what was registered" {
    var ctx = try shim.init(std.testing.allocator);
    defer ctx.deinit(std.testing.allocator);

    const editor = ctx.editor;
    const files_api = fizzy.sdk.services.files.Api;

    // Nothing registered yet: the caller's answer is null, not a crash and not an error type it
    // has to know about. This is the degradation every call site is written against.
    try std.testing.expect(editor.app.host.getServiceTyped(files_api) == null);

    var service = fizzy.Editor.FilesService.api(editor);
    try editor.app.host.registerService(files_api, &service, null);

    const found = editor.app.host.getServiceTyped(files_api) orelse return error.TestUnexpectedResult;

    // Same implementation the app registered — a service is a pointer to the app's own value,
    // not a copy the host owns.
    try std.testing.expect(found == &service);

    // And it really is fizzy's: with no file table behind it (this shim has none) the app's
    // implementation says so rather than pretending to have written anything.
    try std.testing.expectError(error.NoFileTable, found.createFile("/tmp/fizzy-files-service-test"));
}

// -- driving a region from outside the layout ---------------------------------------------------

// A native menu item is dispatched *between* frames: the command runs before this frame's shape
// has declared anything. Toggle Explorer asks `regionFor` for the sidebar and shuts it, so if the
// region registry is empty at that moment the command silently does half its job — the menu title
// flips, because that reads a bool, and the sidebar never moves. It was empty, because the
// registry used to be cleared at the top of the frame and refilled by the shape.
//
// The registry now answers from the last completed shape, which is the same set of ids this frame
// will declare (a region's id comes from its shape's `@src()`).
test "a command dispatched between frames can still find and shut a region" {
    var ctx = try shim.init(std.testing.allocator);
    defer ctx.deinit(std.testing.allocator);

    const editor = ctx.editor;
    editor.app.gpa = std.testing.allocator;
    defer editor.app.layout.regions.deinit(editor.app.gpa);
    defer editor.app.layout.regions_building.deinit(editor.app.gpa);

    const kw = fizzy.sdk.keywords.ide.sidebar;
    const id = dvui.Id.zero.update("test.sidebar.region");

    // Nothing declared yet: exactly the state a first-frame command sees, and it must not crash.
    try std.testing.expect(editor.regionFor(kw) == null);

    // What a shape does when it declares a resizable region.
    editor.app.layout.registerRegion(editor.app.gpa, .{ .keywords = kw, .id = id, .default_extent = 260 });

    // Still invisible to a command — the shape has not finished. This is the half-built list the
    // old code let callers read.
    try std.testing.expect(editor.regionFor(kw) == null);

    // The shape completes and publishes.
    editor.app.layout.publishRegions();

    const region = editor.regionFor(kw) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(id, region.id);

    // And the command's half of the mechanism: shut it, and it reads as shut.
    dvui.dataSet(null, id, "_size", @as(f32, 260));
    try std.testing.expect(!region.isClosed());
    region.close();
    try std.testing.expect(region.isClosed());
    region.open();
    try std.testing.expect(!region.isClosed());
}

// -- a place keeps its order ------------------------------------------------------------------------

// Registration order is load order, and a plugin's reload, update or reinstall registers its views
// again, last. A place writes its order down as it shows views, so the views it has shown keep
// their slots: a plugin's tools second in the sidebar stay second through its reload, and a new
// plugin's views arrive at the end.
test "a place keeps its views' order through a plugin's reload" {
    var ctx = try shim.init(std.testing.allocator);
    defer ctx.deinit(std.testing.allocator);

    const editor = ctx.editor;
    editor.app.gpa = std.testing.allocator;
    defer editor.app.layout.regions.deinit(editor.app.gpa);
    defer editor.app.layout.regions_building.deinit(editor.app.gpa);
    defer editor.app.layout.deinitAssignments(editor.app.gpa);

    const sidebar = fizzy.sdk.keywords.ide.sidebar;
    editor.app.layout.registerRegion(editor.app.gpa, .{ .name = "Sidebar", .keywords = sidebar, .id = .extendId(null, @src(), 1), .default_extent = 260 });
    editor.app.layout.publishRegions();

    const draw = struct {
        fn f(_: ?*anyopaque) anyerror!dvui.App.Result {
            return .ok;
        }
    }.f;
    const vtable: fizzy.sdk.Plugin.VTable = .{};
    var files = fizzy.sdk.Plugin{ .state = undefined, .vtable = &vtable, .id = "files", .display_name = "Files" };
    var tools = fizzy.sdk.Plugin{ .state = undefined, .vtable = &vtable, .id = "tools", .display_name = "Tools" };
    var late = fizzy.sdk.Plugin{ .state = undefined, .vtable = &vtable, .id = "late", .display_name = "Late" };
    const host = &editor.app.host;
    try host.registerPlugin(&files);
    try host.registerSurface(.{ .id = "files.view", .owner = &files, .title = "Files", .keywords = sidebar, .draw = draw });
    try host.registerPlugin(&tools);
    try host.registerSurface(.{ .id = "tools.view", .owner = &tools, .title = "Tools", .keywords = sidebar, .draw = draw });

    var layout = fizzy.Editor.Layout.init(host, &editor.app.layout, editor.app.gpa, dvui.currentWindow().arena());
    const ids = struct {
        fn of(l: *fizzy.Editor.Layout, k: []const []const u8) [3][]const u8 {
            var out: [3][]const u8 = .{ "", "", "" };
            for (l.matching(k), 0..) |s, i| if (i < 3) {
                out[i] = s.id;
            };
            return out;
        }
    }.of;
    try std.testing.expectEqualDeep([3][]const u8{ "files.view", "tools.view", "" }, ids(&layout, sidebar));
    // Written down as it was shown, to be saved with the layout.
    try std.testing.expectEqual(@as(usize, 2), editor.app.layout.order("Sidebar").?.len);

    // Files reloads: gone for a moment, then registered again, after Tools. Still first.
    host.unregisterPlugin(&files);
    try std.testing.expectEqualDeep([3][]const u8{ "tools.view", "", "" }, ids(&layout, sidebar));
    try host.registerPlugin(&files);
    try host.registerSurface(.{ .id = "files.view", .owner = &files, .title = "Files", .keywords = sidebar, .draw = draw });
    try std.testing.expectEqualDeep([3][]const u8{ "files.view", "tools.view", "" }, ids(&layout, sidebar));

    // A plugin installed later arrives at the end.
    try host.registerPlugin(&late);
    try host.registerSurface(.{ .id = "late.view", .owner = &late, .title = "Late", .keywords = sidebar, .draw = draw });
    try std.testing.expectEqualDeep([3][]const u8{ "files.view", "tools.view", "late.view" }, ids(&layout, sidebar));

    host.unregisterPlugin(&late);
    host.unregisterPlugin(&tools);
    host.unregisterPlugin(&files);
}

// -- assigning surfaces to a region --------------------------------------------------------------

// The payoff of keyword matching, and the reason free-form strings are safe here: a placement the
// plugin guessed wrong is two clicks from fixed. The user's answer is per *region* — "what goes
// here" — and the layout reads it live; this is that path without the picker.
test "assigning a region overrides keyword matching, duplicates and empties" {
    var ctx = try shim.init(std.testing.allocator);
    defer ctx.deinit(std.testing.allocator);

    const editor = ctx.editor;
    editor.app.gpa = std.testing.allocator;
    defer editor.app.layout.regions.deinit(editor.app.gpa);
    defer editor.app.layout.regions_building.deinit(editor.app.gpa);
    defer editor.app.layout.deinitAssignments(editor.app.gpa);

    const sidebar = fizzy.sdk.keywords.ide.sidebar;
    const panel = fizzy.sdk.keywords.ide.panel;

    // The shape fizzy runs declares these two; a real frame registers them from `Region.init`.
    editor.app.layout.registerRegion(editor.app.gpa, .{ .name = "Sidebar", .keywords = sidebar, .id = .extendId(null, @src(), 1), .default_extent = 260 });
    editor.app.layout.registerRegion(editor.app.gpa, .{ .name = "Panel", .keywords = panel, .id = .extendId(null, @src(), 2), .default_extent = 200 });
    editor.app.layout.publishRegions();

    // A plugin that believes its panel belongs somewhere sidebar-shaped.
    const draw = struct {
        fn f(_: ?*anyopaque) anyerror!dvui.App.Result {
            return .ok;
        }
    }.f;
    try editor.app.host.registerSurface(.{ .id = "test.movable", .title = "Movable", .keywords = sidebar, .draw = draw });
    try editor.app.host.registerSurface(.{ .id = "test.other", .title = "Other", .keywords = sidebar, .draw = draw });

    var layout = fizzy.Editor.Layout.init(&editor.app.host, &editor.app.layout, editor.app.gpa, dvui.currentWindow().arena());

    // Where they land by default: the sidebar, because that is what they asked for.
    try std.testing.expectEqual(@as(usize, 2), layout.matching(sidebar).len);
    try std.testing.expectEqual(@as(usize, 0), layout.matching(panel).len);
    try std.testing.expectEqual(@as(usize, 0), layout.unplaced().len);

    // The user puts Movable in the panel. It leaves the sidebar: a surface
    // lives in one place, so the panel's assignment claims it.
    try editor.app.layout.assign(editor.app.gpa, "Panel", &.{"test.movable"});
    try std.testing.expectEqual(@as(usize, 1), layout.matching(panel).len);
    try std.testing.expectEqualStrings("test.movable", layout.matching(panel)[0].id);
    try std.testing.expectEqual(@as(usize, 1), layout.matching(sidebar).len);
    try std.testing.expectEqualStrings("test.other", layout.matching(sidebar)[0].id);

    // Then trims the sidebar to Other alone: Movable now lives only in the panel.
    try editor.app.layout.assign(editor.app.gpa, "Sidebar", &.{"test.other"});
    try std.testing.expectEqual(@as(usize, 1), layout.matching(sidebar).len);
    try std.testing.expectEqualStrings("test.other", layout.matching(sidebar)[0].id);
    try std.testing.expectEqual(@as(usize, 0), layout.unplaced().len);

    // An empty assignment is a real choice — nothing here — and the surface it orphans is
    // reported rather than lost.
    try editor.app.layout.assign(editor.app.gpa, "Panel", &.{});
    try std.testing.expectEqual(@as(usize, 0), layout.matching(panel).len);
    try std.testing.expectEqual(@as(usize, 1), layout.unplaced().len);
    try std.testing.expectEqualStrings("test.movable", layout.unplaced()[0].id);

    // An id no loaded plugin owns is kept, not dropped: it draws once that plugin loads.
    try editor.app.layout.assign(editor.app.gpa, "Panel", &.{ "ghost.surface", "test.movable" });
    try std.testing.expectEqual(@as(usize, 1), layout.matching(panel).len);

    // Unassigning hands the sidebar back to its keywords. Movable stays
    // on the panel, so the sidebar only attracts Other.
    editor.app.layout.unassign(editor.app.gpa, "Sidebar");
    try std.testing.expectEqual(@as(usize, 1), layout.matching(sidebar).len);
    try std.testing.expectEqualStrings("test.other", layout.matching(sidebar)[0].id);
}

// A pane adds or drops a tab by reading its assignment, editing the list and writing it back
// (`Workspace.addTab`), so the list it writes borrows the ids it replaces. On 2026-10-16 that
// crashed fizzy in `evictIdFromOthers`, reading ids the write had just freed, on a document an
// agent opened beside the person. The page allocator unmaps every free, so a read of one faults
// here every time rather than whenever the freed slot's page happened to go.
test "assigning a region a list borrowed from the assignments it replaces" {
    const gpa = std.heap.page_allocator;
    var state: fizzy.Editor.Layout.State = .{};
    defer state.deinitAssignments(gpa);

    try state.assign(gpa, "pane.1", &.{ "doc.a", "doc.b" });
    try state.assign(gpa, "pane.2", &.{ "doc.c", "doc.d" });

    // Pane 1 takes doc.c as a tab: its own ids, then the new one borrowed from pane 2's list.
    const one = state.assignment("pane.1").?;
    const two = state.assignment("pane.2").?;
    try state.assign(gpa, "pane.1", &.{ one[0], one[1], two[0] });
    try std.testing.expectEqual(@as(usize, 3), state.assignment("pane.1").?.len);
    try std.testing.expectEqualStrings("doc.c", state.assignment("pane.1").?[2]);
    try std.testing.expectEqual(@as(usize, 1), state.assignment("pane.2").?.len);
    try std.testing.expectEqualStrings("doc.d", state.assignment("pane.2").?[0]);

    // Pane 2 drops back to its first tab, written from its own list, under its own key.
    const keyed = state.assignments.getEntry("pane.2").?;
    try state.assign(gpa, keyed.key_ptr.*, keyed.value_ptr.*[0..1]);
    try std.testing.expectEqualStrings("doc.d", state.assignment("pane.2").?[0]);
}

// Taking a region's ids out of the others rewrites them, and rewriting even an existing entry
// can grow the map (`getOrPut` makes room first), moving every entry. Whatever `assign` holds of
// its own entry must outlive that. Some count of regions leaves the map full at the rewrite;
// trying every count up to well past a resize reaches it, and the page allocator faults on a
// stale read.
test "assigning a region whose ids other regions hold, whatever the map's fill" {
    const gpa = std.heap.page_allocator;
    for (1..64) |count| {
        var state: fizzy.Editor.Layout.State = .{};
        defer state.deinitAssignments(gpa);
        var names: [64][16]u8 = undefined;
        var ids: [64][]const u8 = undefined;
        for (0..count) |i| {
            const name = try std.mem.print(&names[i], "pane.{d}", .{i});
            try state.assign(gpa, name, &.{name});
            ids[i] = name;
        }
        // One region takes every id: each other region is emptied, none twice.
        try state.assign(gpa, "all", ids[0..count]);
        try std.testing.expectEqual(count, state.assignment("all").?.len);
        for (ids[0..count]) |name| try std.testing.expectEqual(@as(usize, 0), state.assignment(name).?.len);
    }
}

// A place of many tabs keeps every one when another place takes one of them.
test "taking one id out of a region of many keeps the rest" {
    const gpa = std.testing.allocator;
    var state: fizzy.Editor.Layout.State = .{};
    defer state.deinitAssignments(gpa);
    var bufs: [40][16]u8 = undefined;
    var ids: [40][]const u8 = undefined;
    for (&ids, 0..) |*id, i| id.* = try std.mem.print(&bufs[i], "doc.{d}", .{i});
    try state.assign(gpa, "pane.1", &ids);
    try state.assign(gpa, "pane.2", &.{ids[0]});
    try std.testing.expectEqual(@as(usize, 39), state.assignment("pane.1").?.len);
    try std.testing.expectEqualStrings("doc.39", state.assignment("pane.1").?[38]);
}

// -- regions inside regions ----------------------------------------------------------------------

// A region declared inside another names a place *within* it: a document pane inside the main area
// accepts `main.document`. The shape writes the short word, because a sub-region should not have to
// know — or repeat — what it is nested in, and a plugin still reaches it by kind alone.
//
// This is the half of sub-regions that has to work before a plugin can declare one: the vocabulary.
test "a nested region qualifies its keywords, and keeps them across frames" {
    var ctx = try shim.init(std.testing.allocator);
    defer ctx.deinit(std.testing.allocator);

    const editor = ctx.editor;
    editor.app.gpa = std.testing.allocator;
    defer editor.app.layout.regions.deinit(editor.app.gpa);
    defer editor.app.layout.regions_building.deinit(editor.app.gpa);
    defer editor.app.layout.deinitQualified(editor.app.gpa);

    const document: []const []const u8 = &.{"document"};
    const qualified = editor.app.layout.qualify(editor.app.gpa, "main", document);

    try std.testing.expectEqual(@as(usize, 1), qualified.len);
    try std.testing.expectEqualStrings("main.document", qualified[0]);

    // Interned, not arena-allocated: the registry is read a frame *later* than it is written, so
    // the same request has to come back with the same memory rather than a fresh copy.
    const again = editor.app.layout.qualify(editor.app.gpa, "main", document);
    try std.testing.expectEqual(qualified.ptr, again.ptr);

    // A shape that writes the qualified form itself is left alone — no `main.main.document`.
    const already = editor.app.layout.qualify(editor.app.gpa, "main", &.{"main.document"});
    try std.testing.expectEqualStrings("main.document", already[0]);

    // And a region that accepts nothing does not invent a level of vocabulary.
    try std.testing.expectEqual(@as(usize, 0), editor.app.layout.qualify(editor.app.gpa, "main", &.{}).len);
}

// A plugin declaring a region: the other half of sub-regions, and the reason the vocabulary work
// above had to come first. The plugin says "a `document` place goes here"; it gets one that
// accepts `main.document`, because it is declared inside Main and cannot name anything outside it.
//
// Driven through `Layout` rather than a loaded dylib, which is where the vtable lands
// (`Host.region` → `EditorAPI.beginRegion` → `Editor.beginPluginRegion` → this).
const PluginRegionFrame = struct {
    var editor: ?*fizzy.Editor = null;
    var draws: usize = 0;

    fn drawSurface(_: ?*anyopaque) anyerror!dvui.App.Result {
        draws += 1;
        return .ok;
    }

    fn frame() anyerror!dvui.App.Result {
        const e = editor.?;
        draws = 0;
        var layout = fizzy.Editor.Layout.init(&e.app.host, &e.app.layout, e.app.gpa, dvui.currentWindow().arena());
        {
            var main = try layout.region(@src(), .{
                .name = "Main",
                .keywords = fizzy.sdk.keywords.ide.main,
            }, .{ .expand = .both });
            defer main.deinit();

            // Exactly what a plugin's `host.region(...)` does, one call in from the vtable.
            const token = layout.beginPluginRegion(.{
                .name = "Pane",
                .keywords = &.{"document"},
                .key = 7,
            }) orelse return error.TestUnexpectedResult;
            _ = try layout.drawPluginRegionContents(token);
            layout.endPluginRegion(token);
        }
        e.app.layout.publishRegions();
        return .ok;
    }
};

test "a plugin declares a region inside the one it was given" {
    var ctx = try shim.init(std.testing.allocator);
    defer ctx.deinit(std.testing.allocator);

    const editor = ctx.editor;
    editor.app.gpa = std.testing.allocator;
    defer editor.app.layout.regions.deinit(editor.app.gpa);
    // A plugin region blurs between what it shows (`Layout.drawPluginRegionContents`).
    defer editor.app.layout.deinitSwaps(editor.app.gpa);
    defer editor.app.layout.regions_building.deinit(editor.app.gpa);
    defer editor.app.layout.deinitQualified(editor.app.gpa);

    // A surface that only says what kind of thing it is, which is all a document plugin knows.
    try editor.app.host.registerSurface(.{
        .id = "test.doc",
        .title = "Doc",
        .keywords = &.{"document"},
        .draw = PluginRegionFrame.drawSurface,
    });

    PluginRegionFrame.editor = editor;
    defer PluginRegionFrame.editor = null;
    try dvui.testing.settle(PluginRegionFrame.frame);

    // The plugin's region is in the app's registry like any other, under the name an assignment
    // would persist against — and its keywords are qualified by the region it was declared in.
    const pane = for (editor.app.layout.regions.items) |r| {
        if (std.mem.eql(u8, r.name, "Pane")) break r;
    } else return error.TestUnexpectedResult;
    try std.testing.expectEqual(@as(usize, 1), pane.keywords.len);
    try std.testing.expectEqualStrings("main.document", pane.keywords[0]);

    // And the surface drew there — once, inside the pane rather than behind it in Main.
    try std.testing.expectEqual(@as(usize, 1), PluginRegionFrame.draws);
}

// A place shows tabs exactly when it holds more than one view, and not at all when it chooses
// among them itself (`RegionSpec.owns_selection`, the workbench's document panes): no mode says so.
const TabsFrame = struct {
    var editor: ?*fizzy.Editor = null;
    var pane_owns = false;

    fn draw(_: ?*anyopaque) anyerror!dvui.App.Result {
        return .ok;
    }

    fn frame() anyerror!dvui.App.Result {
        const e = editor.?;
        fizzy.core.anchor.want();
        var layout = fizzy.Editor.Layout.init(&e.app.host, &e.app.layout, e.app.gpa, dvui.currentWindow().arena());
        {
            var main = try layout.region(@src(), .{ .name = "Main", .keywords = fizzy.sdk.keywords.ide.main }, .{ .expand = .both });
            defer main.deinit();
            const token = layout.beginPluginRegion(.{
                .name = "Pane",
                .keywords = &.{"document"},
                .key = 7,
                .owns_selection = pane_owns,
            }) orelse return error.TestUnexpectedResult;
            _ = try layout.drawPluginRegionContents(token);
            layout.endPluginRegion(token);
        }
        e.app.layout.publishRegions();
        return .ok;
    }
};

test "a place shows tabs only while it holds two or more views, and none when it chooses itself" {
    var ctx = try shim.init(std.testing.allocator);
    defer ctx.deinit(std.testing.allocator);
    const editor = ctx.editor;
    editor.app.gpa = std.testing.allocator;
    defer editor.app.layout.regions.deinit(editor.app.gpa);
    defer editor.app.layout.deinitSwaps(editor.app.gpa);
    defer editor.app.layout.regions_building.deinit(editor.app.gpa);
    defer editor.app.layout.deinitQualified(editor.app.gpa);
    TabsFrame.editor = editor;
    defer TabsFrame.editor = null;
    TabsFrame.pane_owns = false;

    const main = fizzy.sdk.keywords.ide.main;
    try editor.app.host.registerSurface(.{ .id = "test.a", .title = "A", .keywords = main, .draw = TabsFrame.draw });
    try editor.app.host.registerSurface(.{ .id = "test.d1", .title = "D1", .keywords = &.{"document"}, .draw = TabsFrame.draw });
    try dvui.testing.settle(TabsFrame.frame);
    // One view each: no strip.
    try std.testing.expect(dvui.tagGet("tabs:Main") == null);
    try std.testing.expect(dvui.tagGet("tabs:Pane") == null);

    try editor.app.host.registerSurface(.{ .id = "test.b", .title = "B", .keywords = main, .draw = TabsFrame.draw });
    try editor.app.host.registerSurface(.{ .id = "test.d2", .title = "D2", .keywords = &.{"document"}, .draw = TabsFrame.draw });
    try dvui.testing.settle(TabsFrame.frame);
    // Two each: the app's strip, over a shape's place and a plugin's alike.
    try std.testing.expect(dvui.tagGet("tabs:Main") != null);
    try std.testing.expect(dvui.tagGet("tabs:Pane") != null);

    // A region that draws its own chooser gets none of the app's.
    TabsFrame.pane_owns = true;
    try dvui.testing.settle(TabsFrame.frame);
    try std.testing.expect(dvui.tagGet("tabs:Main") != null);
    try std.testing.expect(dvui.tagGet("tabs:Pane") == null);
}

// Where two regions accept the same surface, the more specific one takes it: a document pane
// inside the main area, and the main area itself, both accept a surface asking for
// `main.document` — and without a rule the surface draws twice, once in the pane made for it and
// once behind that pane.
//
// Regions with the same keywords are one place and share: an icon rail and the body it chooses
// for list the same surfaces and draw one. Between different places that accept a surface
// equally, the one declared first has it (see the test after this one).
test "the more specific region claims a surface, and regions with the same keywords share it" {
    var ctx = try shim.init(std.testing.allocator);
    defer ctx.deinit(std.testing.allocator);

    const editor = ctx.editor;
    editor.app.gpa = std.testing.allocator;
    defer editor.app.layout.regions.deinit(editor.app.gpa);
    defer editor.app.layout.regions_building.deinit(editor.app.gpa);
    defer editor.app.layout.deinitQualified(editor.app.gpa);

    const main = fizzy.sdk.keywords.ide.main;
    const pane: []const []const u8 = &.{"main.document"};
    const sidebar = fizzy.sdk.keywords.ide.sidebar;

    editor.app.layout.registerRegion(editor.app.gpa, .{ .name = "Main", .keywords = main, .id = .extendId(null, @src(), 1) });
    editor.app.layout.registerRegion(editor.app.gpa, .{ .name = "Pane", .keywords = pane, .id = .extendId(null, @src(), 2) });
    editor.app.layout.registerRegion(editor.app.gpa, .{ .name = "Rail", .keywords = sidebar, .id = .extendId(null, @src(), 3) });
    editor.app.layout.registerRegion(editor.app.gpa, .{ .name = "Sidebar", .keywords = sidebar, .id = .extendId(null, @src(), 4) });
    editor.app.layout.publishRegions();

    const draw = struct {
        fn f(_: ?*anyopaque) anyerror!dvui.App.Result {
            return .ok;
        }
    }.f;
    // One surface that names the sub-place, one that only names its kind.
    try editor.app.host.registerSurface(.{ .id = "test.doc", .title = "Doc", .keywords = pane, .draw = draw });
    try editor.app.host.registerSurface(.{ .id = "test.kind", .title = "Kind", .keywords = &.{"document"}, .draw = draw });
    try editor.app.host.registerSurface(.{ .id = "test.files", .title = "Files", .keywords = sidebar, .draw = draw });

    var layout = fizzy.Editor.Layout.init(&editor.app.host, &editor.app.layout, editor.app.gpa, dvui.currentWindow().arena());

    // The pane takes both: the exact word, and the kind it qualifies.
    try std.testing.expectEqual(@as(usize, 2), layout.matching(pane).len);

    // The main area accepts `main.document` too — that is how a plugin written for a nested shape
    // lands in a flat one — but not while a pane exists to take it.
    try std.testing.expectEqual(@as(usize, 0), layout.matching(main).len);

    // Nothing is lost: a claimed surface is placed, not unplaced.
    try std.testing.expectEqual(@as(usize, 0), layout.unplaced().len);

    // Two regions with the same keywords still share, which is the rail and the sidebar.
    try std.testing.expectEqual(@as(usize, 1), layout.matching(sidebar).len);

    // An assignment is a claim: the surface lives there, not in another
    // keyword group. Output on Main must leave the panel.
    defer editor.app.layout.deinitAssignments(editor.app.gpa);
    try editor.app.layout.assign(editor.app.gpa, "Pane", &.{"test.doc"});
    try std.testing.expectEqual(@as(usize, 1), layout.matching(pane).len);
    try std.testing.expectEqual(@as(usize, 0), layout.matching(main).len);
}

// A region is declared before it draws, so while the sidebar draws, Main — declared after it —
// exists only in last frame's set. The claim check read this frame's regions alone once any were
// declared, so Files dragged onto Main went on drawing in the sidebar as well.
test "a claim made further down the shape reaches the regions declared before it" {
    var ctx = try shim.init(std.testing.allocator);
    defer ctx.deinit(std.testing.allocator);

    const editor = ctx.editor;
    editor.app.gpa = std.testing.allocator;
    defer editor.app.layout.regions.deinit(editor.app.gpa);
    defer editor.app.layout.regions_building.deinit(editor.app.gpa);
    defer editor.app.layout.deinitQualified(editor.app.gpa);
    defer editor.app.layout.deinitAssignments(editor.app.gpa);

    const main = fizzy.sdk.keywords.ide.main;
    const sidebar = fizzy.sdk.keywords.ide.sidebar;

    // Last frame: the sidebar, then Main.
    editor.app.layout.registerRegion(editor.app.gpa, .{ .name = "Sidebar", .keywords = sidebar, .id = .extendId(null, @src(), 1) });
    editor.app.layout.registerRegion(editor.app.gpa, .{ .name = "Main", .keywords = main, .id = .extendId(null, @src(), 2) });
    editor.app.layout.publishRegions();

    const draw = struct {
        fn f(_: ?*anyopaque) anyerror!dvui.App.Result {
            return .ok;
        }
    }.f;
    try editor.app.host.registerSurface(.{ .id = "test.files", .title = "Files", .keywords = sidebar, .draw = draw });
    try editor.app.host.registerSurface(.{ .id = "test.outline", .title = "Outline", .keywords = sidebar, .draw = draw });
    try editor.app.layout.assign(editor.app.gpa, "Main", &.{"test.files"});

    // This frame, as the sidebar draws: it is declared, Main is not yet.
    editor.app.layout.registerRegion(editor.app.gpa, .{ .name = "Sidebar", .keywords = sidebar, .id = .extendId(null, @src(), 1) });

    var layout = fizzy.Editor.Layout.init(&editor.app.host, &editor.app.layout, editor.app.gpa, dvui.currentWindow().arena());
    const in_sidebar = layout.matching(sidebar);
    try std.testing.expectEqual(@as(usize, 1), in_sidebar.len);
    try std.testing.expectEqualStrings("test.outline", in_sidebar[0].id);
    const in_main = layout.matching(main);
    try std.testing.expectEqual(@as(usize, 1), in_main.len);
    try std.testing.expectEqualStrings("test.files", in_main[0].id);

    editor.app.layout.registerRegion(editor.app.gpa, .{ .name = "Main", .keywords = main, .id = .extendId(null, @src(), 2) });
    editor.app.layout.publishRegions();
}

// Two regions in different keyword groups that accept a surface equally used to both draw it.
// A surface is drawn in one place: the tie goes to the region the shape declares first.
test "between equally good regions, the one declared first has the surface" {
    var ctx = try shim.init(std.testing.allocator);
    defer ctx.deinit(std.testing.allocator);

    const editor = ctx.editor;
    editor.app.gpa = std.testing.allocator;
    defer editor.app.layout.regions.deinit(editor.app.gpa);
    defer editor.app.layout.regions_building.deinit(editor.app.gpa);
    defer editor.app.layout.deinitQualified(editor.app.gpa);

    const left: []const []const u8 = &.{ "sidebar", "left" };
    const right: []const []const u8 = &.{ "sidebar", "right" };
    editor.app.layout.registerRegion(editor.app.gpa, .{ .name = "Left", .keywords = left, .id = .extendId(null, @src(), 1) });
    editor.app.layout.registerRegion(editor.app.gpa, .{ .name = "Right", .keywords = right, .id = .extendId(null, @src(), 2) });
    editor.app.layout.publishRegions();

    const draw = struct {
        fn f(_: ?*anyopaque) anyerror!dvui.App.Result {
            return .ok;
        }
    }.f;
    try editor.app.host.registerSurface(.{ .id = "test.files", .title = "Files", .keywords = &.{"sidebar"}, .draw = draw });

    var layout = fizzy.Editor.Layout.init(&editor.app.host, &editor.app.layout, editor.app.gpa, dvui.currentWindow().arena());
    try std.testing.expectEqual(@as(usize, 1), layout.matching(left).len);
    try std.testing.expectEqual(@as(usize, 0), layout.matching(right).len);
    // Placed, not lost.
    try std.testing.expectEqual(@as(usize, 0), layout.unplaced().len);
}

// Tab content is not a place's content: a document belongs in a slot made for documents (the
// Workspace's panes), where it has a tab, splits, and is what Save and Undo act on. A plain place
// neither shows it — not even from an assignment a layout saved before the rule — nor offers it.
test "a document goes to a slot made for it, never a plain place" {
    var ctx = try shim.init(std.testing.allocator);
    defer ctx.deinit(std.testing.allocator);

    const editor = ctx.editor;
    editor.app.gpa = std.testing.allocator;
    defer editor.app.layout.regions.deinit(editor.app.gpa);
    defer editor.app.layout.regions_building.deinit(editor.app.gpa);
    defer editor.app.layout.deinitQualified(editor.app.gpa);
    defer editor.app.layout.deinitAssignments(editor.app.gpa);

    const main = fizzy.sdk.keywords.ide.main;
    const pane: []const []const u8 = &.{"main.document"};

    const draw = struct {
        fn f(_: ?*anyopaque) anyerror!dvui.App.Result {
            return .ok;
        }
    }.f;
    try editor.app.host.registerSurface(.{ .id = "test.doc", .title = "untitled.txt", .keywords = fizzy.sdk.document.keywords, .draw = draw });
    try editor.app.host.registerSurface(.{ .id = "test.view", .title = "Workspace", .keywords = main, .draw = draw });

    // No document slot in this shape (an app not using the Workspace): anything goes anywhere.
    editor.app.layout.registerRegion(editor.app.gpa, .{ .name = "Main", .keywords = main, .id = .extendId(null, @src(), 1) });
    editor.app.layout.publishRegions();
    var layout = fizzy.Editor.Layout.init(&editor.app.host, &editor.app.layout, editor.app.gpa, dvui.currentWindow().arena());
    const doc = editor.app.host.surfaceById("test.doc").?;
    const view = editor.app.host.surfaceById("test.view").?;
    try std.testing.expect(!layout.slotted(doc));

    // With one: the pane has the document, Main does not, whatever Main was assigned.
    editor.app.layout.registerRegion(editor.app.gpa, .{ .name = "Main", .keywords = main, .id = .extendId(null, @src(), 1) });
    editor.app.layout.registerRegion(editor.app.gpa, .{ .name = "Pane 0", .keywords = pane, .id = .extendId(null, @src(), 2), .by_name = true, .kind_slot = true });
    editor.app.layout.publishRegions();
    // Main holds the document (a stale entry); the pane was given nothing and goes by keywords.
    // Assigning the pane too would evict the entry from Main and prove nothing.
    try editor.app.layout.assign(editor.app.gpa, "Main", &.{ "test.view", "test.doc" });

    layout = fizzy.Editor.Layout.init(&editor.app.host, &editor.app.layout, editor.app.gpa, dvui.currentWindow().arena());
    try std.testing.expect(layout.slotted(doc));
    try std.testing.expect(!layout.slotted(view));

    var main_region: ?fizzy.Editor.Layout.Region = null;
    var pane_region: ?fizzy.Editor.Layout.Region = null;
    for (editor.app.layout.regions.items) |r| {
        if (std.mem.eql(u8, r.name, "Main")) main_region = r;
        if (std.mem.eql(u8, r.name, "Pane 0")) pane_region = r;
    }
    const m = main_region orelse return error.TestExpectedEqual;
    const p = pane_region orelse return error.TestExpectedEqual;

    // Main offers the view and not the document; the pane the other way round.
    try std.testing.expect(layout.offers(&m, view));
    try std.testing.expect(!layout.offers(&m, doc));
    try std.testing.expect(layout.offers(&p, doc));
    try std.testing.expect(!layout.offers(&p, view));

    // And draws accordingly: Main's stale entry neither shows the document nor claims it away
    // from the pane, so it is drawn once, in the pane.
    const in_main = layout.matchingIn(&m);
    try std.testing.expectEqual(@as(usize, 1), in_main.len);
    try std.testing.expectEqualStrings("test.view", in_main[0].id);
    const in_pane = layout.matchingIn(&p);
    try std.testing.expectEqual(@as(usize, 1), in_pane.len);
    try std.testing.expectEqualStrings("test.doc", in_pane[0].id);
}

// The bottom panel's shape: Main, a split, then the panel — declared after its own split and
// hiding itself when it has nothing to show. With every panel view toggled off, the split used to
// stay behind as a handle with nothing after it, still draggable. A split is drawn by the region
// that follows it, or not at all.
const EmptyPanelFrame = struct {
    var editor: ?*fizzy.Editor = null;
    var main_draws: usize = 0;

    fn drawMain(_: ?*anyopaque) anyerror!dvui.App.Result {
        main_draws += 1;
        return .ok;
    }

    fn frame() anyerror!dvui.App.Result {
        const e = editor.?;
        main_draws = 0;
        var layout = fizzy.Editor.Layout.init(&e.app.host, &e.app.layout, e.app.gpa, dvui.currentWindow().arena());
        {
            var content = try layout.region(@src(), .{ .dir = .vertical }, .{ .expand = .both });
            defer content.deinit();
            {
                var main = try layout.region(@src(), .{ .name = "Main", .keywords = fizzy.sdk.keywords.ide.main }, .{ .expand = .both });
                defer main.deinit();
            }
            layout.split(@src(), .{});
            {
                var panel = try layout.region(@src(), .{
                    .name = "Panel",
                    .keywords = fizzy.sdk.keywords.ide.panel,
                    .resize = true,
                    .hide_when_empty = true,
                }, .{ .min_size_content = .{ .h = 220 }, .expand = .horizontal });
                defer panel.deinit();
            }
        }
        if (layout.depth != 0) return error.TestUnexpectedResult;
        e.app.layout.publishRegions();
        return .ok;
    }
};

/// Main above a keyword-matched Panel showing several, as fizzy's own shape has them.
const ManyPanelFrame = struct {
    var editor: ?*fizzy.Editor = null;
    /// This frame's layout, while it draws: what a view asking for it mid-frame reaches.
    var layout: ?*fizzy.Editor.Layout = null;

    fn draw(_: ?*anyopaque) anyerror!dvui.App.Result {
        return .ok;
    }

    fn frame() anyerror!dvui.App.Result {
        const e = editor.?;
        var l = fizzy.Editor.Layout.init(&e.app.host, &e.app.layout, e.app.gpa, dvui.currentWindow().arena());
        layout = &l;
        defer layout = null;
        {
            var content = try l.region(@src(), .{ .dir = .vertical }, .{ .expand = .both });
            defer content.deinit();
            {
                var main = try l.region(@src(), .{ .name = "Main", .keywords = fizzy.sdk.keywords.ide.main }, .{ .expand = .both });
                defer main.deinit();
            }
            l.split(@src(), .{});
            {
                var panel = try l.region(@src(), .{
                    .name = "Panel",
                    .keywords = fizzy.sdk.keywords.ide.panel,
                    .resize = true,
                    .hide_when_empty = true,
                }, .{ .min_size_content = .{ .h = 220 }, .expand = .horizontal });
                defer panel.deinit();
            }
        }
        // As fizzy's frame does: the floats over the shape, before its regions are published,
        // and what a view asked to put away once all of it has drawn.
        l.drawFloats();
        e.app.layout.publishRegions();
        _ = l.applyHides();
        return .ok;
    }
};

const ManyPanelCase = struct {
    ctx: shim.Ctx,

    fn init() !ManyPanelCase {
        var ctx = try shim.init(std.testing.allocator);
        errdefer ctx.deinit(std.testing.allocator);
        const editor = ctx.editor;
        editor.app.gpa = std.testing.allocator;
        try editor.app.host.registerSurface(.{ .id = "test.main", .title = "Main", .keywords = fizzy.sdk.keywords.ide.main, .draw = ManyPanelFrame.draw });
        try editor.app.host.registerSurface(.{ .id = "test.output", .title = "Output", .keywords = fizzy.sdk.keywords.ide.panel, .draw = ManyPanelFrame.draw });
        ManyPanelFrame.editor = editor;
        try dvui.testing.settle(ManyPanelFrame.frame);
        return .{ .ctx = ctx };
    }

    fn deinit(self: *ManyPanelCase) void {
        const editor = self.ctx.editor;
        editor.app.layout.regions.deinit(editor.app.gpa);
        editor.app.layout.regions_building.deinit(editor.app.gpa);
        editor.app.layout.deinitExtents(editor.app.gpa);
        editor.app.layout.deinitAssignments(editor.app.gpa);
        editor.app.layout.deinitQualified(editor.app.gpa);
        ManyPanelFrame.editor = null;
        self.ctx.deinit(std.testing.allocator);
    }

    fn place(self: *ManyPanelCase, source: []const u8, dest: []const u8, kind: fizzy.Editor.Layout.Drop.Kind) !void {
        const editor = self.ctx.editor;
        var layout = fizzy.Editor.Layout.init(&editor.app.host, &editor.app.layout, editor.app.gpa, dvui.currentWindow().arena());
        fizzy.Editor.Layout.ViewDrag.place(&layout, source, dest, kind);
        try dvui.testing.settle(ManyPanelFrame.frame);
        try dvui.testing.settle(ManyPanelFrame.frame);
    }

    /// The ids place `name` draws, whether its keywords or a list chose them.
    fn shows(self: *ManyPanelCase, name: []const u8) []const []const u8 {
        const editor = self.ctx.editor;
        var layout = fizzy.Editor.Layout.init(&editor.app.host, &editor.app.layout, editor.app.gpa, dvui.currentWindow().arena());
        for (editor.app.layout.regions.items) |*r| if (std.mem.eql(u8, r.name, name)) {
            const items = layout.matchingIn(r);
            const out = dvui.currentWindow().arena().alloc([]const u8, items.len) catch return &.{};
            for (items, 0..) |s, i| out[i] = s.id;
            return out;
        };
        return &.{};
    }

    fn placeNamed(self: *ManyPanelCase, not: []const []const u8) ?[]const u8 {
        for (self.ctx.editor.app.layout.regions.items) |r| {
            for (not) |n| {
                if (std.mem.eql(u8, r.name, n)) break;
            } else if (r.name.len > 0) return r.name;
        }
        return null;
    }
};

test "trash: the last view of a place its keywords fill goes, and the place is empty" {
    var case = try ManyPanelCase.init();
    defer case.deinit();
    try std.testing.expectEqual(@as(usize, 1), case.shows("Panel").len);
    try case.place("Panel", "Panel", .remove);
    // Out of the panel: it shows nothing now, its keywords notwithstanding.
    try std.testing.expectEqual(@as(usize, 0), case.shows("Panel").len);
    const main = case.shows("Main");
    try std.testing.expectEqual(@as(usize, 1), main.len);
    try std.testing.expectEqualStrings("test.main", main[0]);
}

test "split: the last view of a place its keywords fill, carried to another place's edge, goes with it" {
    var case = try ManyPanelCase.init();
    defer case.deinit();
    try case.place("Panel", "Main", .{ .split = .right });
    const main = case.shows("Main");
    try std.testing.expectEqual(@as(usize, 1), main.len);
    try std.testing.expectEqualStrings("test.main", main[0]);
    const half = case.placeNamed(&.{ "Main", "Panel" }) orelse return error.TestExpectedEqual;
    const there = case.shows(half);
    try std.testing.expectEqual(@as(usize, 1), there.len);
    try std.testing.expectEqualStrings("test.output", there[0]);
    try std.testing.expectEqual(@as(usize, 0), case.shows("Panel").len);
}

test "split: the last view of a place its keywords fill, split onto its own place, stays and an empty half opens" {
    var case = try ManyPanelCase.init();
    defer case.deinit();
    try case.place("Panel", "Panel", .{ .split = .right });
    const panel = case.shows("Panel");
    try std.testing.expectEqual(@as(usize, 1), panel.len);
    try std.testing.expectEqualStrings("test.output", panel[0]);
    const half = case.placeNamed(&.{ "Main", "Panel" }) orelse return error.TestExpectedEqual;
    try std.testing.expectEqual(@as(usize, 0), case.shows(half).len);
    try std.testing.expect(case.ctx.editor.app.layout.isMinted(half));
}

test "a split before a region that hides itself is not drawn, and nothing draws twice" {
    var ctx = try shim.init(std.testing.allocator);
    defer ctx.deinit(std.testing.allocator);

    const editor = ctx.editor;
    editor.app.gpa = std.testing.allocator;
    defer editor.app.layout.regions.deinit(editor.app.gpa);
    defer editor.app.layout.regions_building.deinit(editor.app.gpa);
    defer editor.app.layout.deinitQualified(editor.app.gpa);
    defer editor.app.layout.deinitExtents(editor.app.gpa);

    try editor.app.host.registerSurface(.{ .id = "test.main", .title = "Main", .keywords = fizzy.sdk.keywords.ide.main, .draw = EmptyPanelFrame.drawMain });
    try editor.app.host.registerSurface(.{ .id = "test.output", .title = "Output", .keywords = fizzy.sdk.keywords.ide.panel, .draw = EmptyPanelFrame.drawMain });

    EmptyPanelFrame.editor = editor;
    defer EmptyPanelFrame.editor = null;
    try dvui.testing.settle(EmptyPanelFrame.frame);
    // Both surfaces drew (the counter is shared): main once, output once.
    try std.testing.expectEqual(@as(usize, 2), EmptyPanelFrame.main_draws);
    try std.testing.expectEqual(@as(usize, 2), editor.app.layout.regions.items.len);

    // Every panel view toggled off, as the panel's menu does.
    editor.app.host.setSurfaceHidden("test.output", true);
    try dvui.testing.settle(EmptyPanelFrame.frame);
    try std.testing.expectEqual(@as(usize, 1), EmptyPanelFrame.main_draws);
    // The panel drew nothing and no split survived it — but it is still a place the picker can
    // find, which is how the user gets it back.
    try std.testing.expectEqual(@as(usize, 2), editor.app.layout.regions.items.len);
    try std.testing.expectEqualStrings("Panel", editor.app.layout.regions.items[1].name);

    // And it comes back.
    editor.app.host.setSurfaceHidden("test.output", false);
    try dvui.testing.settle(EmptyPanelFrame.frame);
    try std.testing.expectEqual(@as(usize, 2), editor.app.layout.regions.items.len);
}

// A view whose content is its own scroll area, without `Surface.scrolls_itself`, grows wider
// without limit in a place that scrolls what it shows, and nothing on screen says why. A Debug
// build names it, once; one that says it scrolls itself, or whose scroll area does not fill its
// place, is not named.
const ScrollerFrame = struct {
    var editor: ?*fizzy.Editor = null;

    fn fills(_: ?*anyopaque) anyerror!dvui.App.Result {
        var scroll = dvui.scrollArea(@src(), .{}, .{ .expand = .both });
        defer scroll.deinit();
        dvui.label(@src(), "rows", .{}, .{});
        return .ok;
    }

    fn small(_: ?*anyopaque) anyerror!dvui.App.Result {
        var scroll = dvui.scrollArea(@src(), .{}, .{ .min_size_content = .{ .w = 40, .h = 40 } });
        defer scroll.deinit();
        dvui.label(@src(), "rows", .{}, .{});
        return .ok;
    }

    fn frame() anyerror!dvui.App.Result {
        const e = editor.?;
        var layout = fizzy.Editor.Layout.init(&e.app.host, &e.app.layout, e.app.gpa, dvui.currentWindow().arena());
        {
            var content = try layout.region(@src(), .{ .dir = .vertical }, .{ .expand = .both });
            defer content.deinit();
            {
                var main = try layout.region(@src(), .{ .name = "Main", .keywords = fizzy.sdk.keywords.ide.main }, .{ .expand = .both });
                defer main.deinit();
            }
            {
                var panel = try layout.region(@src(), .{ .name = "Panel", .keywords = fizzy.sdk.keywords.ide.panel }, .{ .expand = .both });
                defer panel.deinit();
            }
            {
                var sidebar = try layout.region(@src(), .{ .name = "Sidebar", .keywords = fizzy.sdk.keywords.ide.sidebar }, .{ .expand = .both });
                defer sidebar.deinit();
            }
        }
        e.app.layout.publishRegions();
        return .ok;
    }
};

test "a view filling its place with an unmarked scroll area is named once in Debug" {
    if (builtin.mode != .debug) return error.SkipZigTest;
    var ctx = try shim.init(std.testing.allocator);
    defer ctx.deinit(std.testing.allocator);

    const editor = ctx.editor;
    editor.app.gpa = std.testing.allocator;
    defer editor.app.layout.regions.deinit(editor.app.gpa);
    defer editor.app.layout.regions_building.deinit(editor.app.gpa);
    defer editor.app.layout.deinitQualified(editor.app.gpa);
    defer editor.app.layout.deinitExtents(editor.app.gpa);

    const host = &editor.app.host;
    try host.registerSurface(.{ .id = "test.unmarked", .title = "Unmarked", .keywords = fizzy.sdk.keywords.ide.main, .draw = ScrollerFrame.fills });
    try host.registerSurface(.{ .id = "test.marked", .title = "Marked", .keywords = fizzy.sdk.keywords.ide.panel, .draw = ScrollerFrame.fills, .scrolls_itself = true });
    try host.registerSurface(.{ .id = "test.small", .title = "Small", .keywords = fizzy.sdk.keywords.ide.sidebar, .draw = ScrollerFrame.small });

    ScrollerFrame.editor = editor;
    defer ScrollerFrame.editor = null;
    try dvui.testing.settle(ScrollerFrame.frame);
    try dvui.testing.settle(ScrollerFrame.frame);

    const named = &editor.app.layout.unmarked_scrollers;
    try std.testing.expectEqual(@as(u8, 1), named.len);
    try std.testing.expect(named.contains("test.unmarked"));
    try std.testing.expect(!named.contains("test.marked"));
    try std.testing.expect(!named.contains("test.small"));
}

/// Sidebar beside Main over Panel, with the picker drawn over them as fizzy's frame does.
const PickerFrame = struct {
    var editor: ?*fizzy.Editor = null;

    fn draw(_: ?*anyopaque) anyerror!dvui.App.Result {
        return .ok;
    }

    fn frame() anyerror!dvui.App.Result {
        const e = editor.?;
        fizzy.core.anchor.want();
        var layout = fizzy.Editor.Layout.init(&e.app.host, &e.app.layout, e.app.gpa, dvui.currentWindow().arena());
        {
            var content = try layout.region(@src(), .{ .dir = .horizontal }, .{ .expand = .both });
            defer content.deinit();
            {
                var sidebar = try layout.region(@src(), .{ .name = "Sidebar", .keywords = sdk.keywords.ide.sidebar }, .{ .min_size_content = .{ .w = 200 }, .expand = .vertical });
                defer sidebar.deinit();
            }
            layout.split(@src(), .{});
            {
                var right = try layout.region(@src(), .{ .dir = .vertical }, .{ .expand = .both });
                defer right.deinit();
                {
                    var main = try layout.region(@src(), .{ .name = "Main", .keywords = sdk.keywords.ide.main }, .{ .expand = .both });
                    defer main.deinit();
                }
                layout.split(@src(), .{});
                {
                    var panel = try layout.region(@src(), .{ .name = "Panel", .keywords = sdk.keywords.ide.panel }, .{ .min_size_content = .{ .h = 200 }, .expand = .horizontal });
                    defer panel.deinit();
                }
            }
        }
        e.app.layout.publishRegions();
        layout.captureUnplaced();
        e.app.layout.picker.draw(&layout);
        return .ok;
    }
};

test "the picker lists each view under the place it is made for, the open place first" {
    var ctx = try shim.init(std.testing.allocator);
    defer ctx.deinit(std.testing.allocator);

    const editor = ctx.editor;
    editor.app.gpa = std.testing.allocator;
    defer editor.app.layout.regions.deinit(editor.app.gpa);
    defer editor.app.layout.regions_building.deinit(editor.app.gpa);
    defer editor.app.layout.deinitQualified(editor.app.gpa);
    defer editor.app.layout.deinitAssignments(editor.app.gpa);
    defer editor.app.layout.deinitExtents(editor.app.gpa);
    defer editor.app.layout.picker.close(editor.app.gpa);
    defer editor.app.layout.discardSnapshots(editor.app.gpa);

    try editor.app.host.registerSurface(.{ .id = "test.files", .title = "Files", .keywords = sdk.keywords.ide.sidebar, .draw = PickerFrame.draw });
    try editor.app.host.registerSurface(.{ .id = "test.output", .title = "Output", .keywords = sdk.keywords.ide.panel, .draw = PickerFrame.draw });
    try editor.app.host.registerSurface(.{ .id = "test.misc", .title = "Misc", .keywords = &.{"inspector"}, .draw = PickerFrame.draw });

    PickerFrame.editor = editor;
    defer PickerFrame.editor = null;
    try dvui.testing.settle(PickerFrame.frame);

    const y = struct {
        fn of(id: []const u8) !f32 {
            var buf: [64]u8 = undefined;
            return (try dvui.testing.tagGet(try std.mem.print(&buf, "picker:{s}", .{id}))).rect.y;
        }
    }.of;

    // From the panel: its own view first, then the sidebar's, then the one no place asks for.
    // Stepped, not settled: the open popup keeps asking for frames.
    editor.app.layout.openPicker(editor.app.gpa, "Panel", null);
    for (0..4) |_| _ = try dvui.testing.step(PickerFrame.frame);
    try std.testing.expect(try y("test.output") < try y("test.files"));
    try std.testing.expect(try y("test.files") < try y("test.misc"));

    // From the sidebar, the sidebar's view leads instead.
    editor.app.layout.openPicker(editor.app.gpa, "Sidebar", null);
    for (0..4) |_| _ = try dvui.testing.step(PickerFrame.frame);
    try std.testing.expect(try y("test.files") < try y("test.output"));
    try std.testing.expect(try y("test.output") < try y("test.misc"));

    // Files moved into the panel reads under the panel, in one row with Output, from either
    // picker.
    try editor.app.layout.assign(editor.app.gpa, "Panel", &.{ "test.output", "test.files" });
    for (0..4) |_| _ = try dvui.testing.step(PickerFrame.frame);
    try std.testing.expectEqual(try y("test.output"), try y("test.files"));
    try std.testing.expect(try y("test.output") < try y("test.misc"));
    // The sidebar holds nothing now, and still leads, empty, under its own name.
    try std.testing.expect((try dvui.testing.tagGet("picker.empty")).rect.y < try y("test.files"));
    editor.app.layout.openPicker(editor.app.gpa, "Panel", null);
    for (0..4) |_| _ = try dvui.testing.step(PickerFrame.frame);
    try std.testing.expectEqual(try y("test.output"), try y("test.files"));
    try std.testing.expect(try y("test.output") < try y("test.misc"));
    try std.testing.expect(dvui.tagGet("picker.empty") == null);
}

/// Views no place shows, each counting its draws: what the picker draws offscreen for its cards.
const UnplacedViews = struct {
    const ids = [_][]const u8{ "test.u0", "test.u1", "test.u2", "test.u3", "test.u4", "test.u5", "test.u6" };
    var draws: [ids.len]u32 = @splat(0);

    fn drawFor(comptime n: usize) fn (?*anyopaque) anyerror!dvui.App.Result {
        return struct {
            fn draw(_: ?*anyopaque) anyerror!dvui.App.Result {
                draws[n] += 1;
                return .ok;
            }
        }.draw;
    }

    /// Whether the picker's list had view `n`'s card in view on the last frame.
    fn shown(n: usize) !bool {
        var buf: [64]u8 = undefined;
        return (try dvui.testing.tagGet(try std.mem.print(&buf, "picker:{s}", .{ids[n]}))).visible;
    }

    /// Step a frame; fails if two of the views were drawn in it.
    fn step() !void {
        const before = draws;
        _ = try dvui.testing.step(PickerFrame.frame);
        var drew: usize = 0;
        for (before, draws) |b, a| drew += a - b;
        try std.testing.expect(drew <= 1);
    }
};

test "picker: a view that draws nowhere is drawn for its card one at a time, only while the list shows it" {
    var ctx = try shim.init(std.testing.allocator);
    defer ctx.deinit(std.testing.allocator);

    const editor = ctx.editor;
    editor.app.gpa = std.testing.allocator;
    defer editor.app.layout.regions.deinit(editor.app.gpa);
    defer editor.app.layout.regions_building.deinit(editor.app.gpa);
    defer editor.app.layout.deinitQualified(editor.app.gpa);
    defer editor.app.layout.deinitAssignments(editor.app.gpa);
    defer editor.app.layout.deinitExtents(editor.app.gpa);
    defer editor.app.layout.picker.close(editor.app.gpa);
    defer editor.app.layout.discardSnapshots(editor.app.gpa);

    UnplacedViews.draws = @splat(0);
    // Only views no place shows: one on screen would be captured first, and fail, and with no
    // texture targets that ends capture for the session before any is drawn offscreen.
    inline for (UnplacedViews.ids, 0..) |id, n| {
        try editor.app.host.registerSurface(.{ .id = id, .title = id, .keywords = &.{"inspector"}, .draw = UnplacedViews.drawFor(n) });
    }

    PickerFrame.editor = editor;
    defer PickerFrame.editor = null;
    try dvui.testing.settle(PickerFrame.frame);

    editor.app.layout.openPicker(editor.app.gpa, "Sidebar", null);
    // The frame it opens on, and the list's first, when no card has a size yet: no card shows,
    // and nothing is drawn for one.
    for (0..2) |_| try UnplacedViews.step();
    try std.testing.expectEqual(@as([UnplacedViews.ids.len]u32, @splat(0)), UnplacedViews.draws);

    // The cards in view are the list's first ones, in order: some of the views and not all, in the
    // shim's 600 by 400 window. The views are drawn one at a time, first card first. The testing
    // backend has no texture targets, so no capture can start: after three in a row, capture is
    // given up for the session, and nothing more is drawn.
    try std.testing.expectEqual(dvui.Size.Natural{ .w = 600, .h = 400 }, dvui.windowRect().size());
    for (0..600) |_| try UnplacedViews.step();
    try std.testing.expect(editor.app.layout.capture_unavailable);
    var shown: usize = 0;
    while (shown < UnplacedViews.ids.len and try UnplacedViews.shown(shown)) shown += 1;
    try std.testing.expect(shown > 0 and shown < UnplacedViews.ids.len);
    for (0..UnplacedViews.ids.len) |i| try std.testing.expectEqual(i < shown, try UnplacedViews.shown(i));
    for (UnplacedViews.draws, 0..) |n, i| try std.testing.expectEqual(i < @min(shown, 3), n > 0);
    const settled = UnplacedViews.draws;
    for (0..30) |_| try UnplacedViews.step();
    try std.testing.expectEqual(settled, UnplacedViews.draws);

    // Reopened, with the views in view already failed: the ones left are past the fold, and are
    // not drawn.
    UnplacedViews.draws = @splat(0);
    editor.app.layout.openPicker(editor.app.gpa, "Sidebar", null);
    for (0..shown) |i| editor.app.layout.recordCaptureFailed(editor.app.gpa, UnplacedViews.ids[i]);
    for (0..200) |_| try UnplacedViews.step();
    try std.testing.expectEqual(@as([UnplacedViews.ids.len]u32, @splat(0)), UnplacedViews.draws);

    // Filtered: with those views gone from the list, the next card moves up into view and its view
    // is drawn. (Hidden rather than typed or scrolled: the testing backend's input does not reach
    // the popup.)
    for (0..shown) |i| editor.app.host.setSurfaceHidden(UnplacedViews.ids[i], true);
    for (0..200) |_| try UnplacedViews.step();
    try std.testing.expect(try UnplacedViews.shown(shown));
    try std.testing.expect(UnplacedViews.draws[shown] > 0);
    for (shown..UnplacedViews.ids.len) |i| {
        if (!try UnplacedViews.shown(i)) try std.testing.expectEqual(@as(u32, 0), UnplacedViews.draws[i]);
    }
}

test "a hide_when_empty panel stays while its view is dragged onto main" {
    var ctx = try shim.init(std.testing.allocator);
    defer ctx.deinit(std.testing.allocator);

    const editor = ctx.editor;
    editor.app.gpa = std.testing.allocator;
    defer editor.app.layout.regions.deinit(editor.app.gpa);
    defer editor.app.layout.regions_building.deinit(editor.app.gpa);
    defer editor.app.layout.deinitQualified(editor.app.gpa);
    defer editor.app.layout.deinitAssignments(editor.app.gpa);
    defer editor.app.layout.deinitExtents(editor.app.gpa);
    defer editor.app.layout.view_drag.discard(editor.app.gpa);

    try editor.app.host.registerSurface(.{ .id = "test.main", .title = "Main", .keywords = fizzy.sdk.keywords.ide.main, .draw = EmptyPanelFrame.drawMain });
    try editor.app.host.registerSurface(.{ .id = "test.output", .title = "Output", .keywords = fizzy.sdk.keywords.ide.panel, .draw = EmptyPanelFrame.drawMain });

    EmptyPanelFrame.editor = editor;
    defer EmptyPanelFrame.editor = null;
    try dvui.testing.settle(EmptyPanelFrame.frame);

    var layout = fizzy.Editor.Layout.init(&editor.app.host, &editor.app.layout, editor.app.gpa, dvui.currentWindow().arena());
    const ViewDrag = fizzy.Editor.Layout.ViewDrag;
    ViewDrag.begin(&layout, "Panel", .{ .x = 0, .y = 400, .w = 800, .h = 200 }, .{ .x = 0, .y = 400, .w = 800, .h = 200 });
    editor.app.layout.view_drag.moved_id = "test.output";

    // Its view rides the pointer, but it is still the panel's until the drop: the panel stands
    // empty (hatched), not gone.
    const panel = ViewDrag.regionNamed(&editor.app.layout, "Panel") orelse return error.TestExpectedEqual;
    try std.testing.expectEqual(@as(usize, 1), layout.matchingIn(panel).len);

    _ = try dvui.testing.step(EmptyPanelFrame.frame);
    var panel_h: f32 = 0;
    for (editor.app.layout.regions.items) |r| {
        if (std.mem.eql(u8, r.name, "Panel")) panel_h = r.bounds.h;
    }
    try std.testing.expect(panel_h > 50);
}

// Two document panes accept the same qualified keywords, and by keyword group they would be one
// region: one assignment, one active tab. A plugin-declared region resolves by *name* instead,
// which is what lets a workbench have as many panes as the user opens.
test "two plugin regions with the same keywords keep separate contents and selections" {
    var ctx = try shim.init(std.testing.allocator);
    defer ctx.deinit(std.testing.allocator);

    const editor = ctx.editor;
    editor.app.gpa = std.testing.allocator;
    defer editor.app.layout.regions.deinit(editor.app.gpa);
    defer editor.app.layout.regions_building.deinit(editor.app.gpa);
    defer editor.app.layout.deinitQualified(editor.app.gpa);
    defer editor.app.layout.deinitAssignments(editor.app.gpa);

    const draw = struct {
        fn f(_: ?*anyopaque) anyerror!dvui.App.Result {
            return .ok;
        }
    }.f;
    try editor.app.host.registerSurface(.{ .id = "test.a", .title = "A", .keywords = &.{"document"}, .draw = draw });
    try editor.app.host.registerSurface(.{ .id = "test.b", .title = "B", .keywords = &.{"document"}, .draw = draw });
    try editor.app.host.registerSurface(.{ .id = "test.output", .title = "Output", .keywords = fizzy.sdk.keywords.ide.panel, .draw = draw });

    const kw: []const []const u8 = &.{"main.document"};
    const one: fizzy.Editor.Region = .{ .name = "Pane 1", .keywords = kw, .id = .extendId(null, @src(), 1), .by_name = true, .kind_slot = true };
    const two: fizzy.Editor.Region = .{ .name = "Pane 2", .keywords = kw, .id = .extendId(null, @src(), 2), .by_name = true, .kind_slot = true };
    editor.app.layout.registerRegion(editor.app.gpa, one);
    editor.app.layout.registerRegion(editor.app.gpa, two);
    editor.app.layout.publishRegions();

    var layout = fizzy.Editor.Layout.init(&editor.app.host, &editor.app.layout, editor.app.gpa, dvui.currentWindow().arena());

    // Untouched, both accept both by keyword — the same thing `matching` says.
    try std.testing.expectEqual(@as(usize, 2), layout.matchingIn(&one).len);
    try std.testing.expectEqual(@as(usize, 2), layout.matchingIn(&two).len);

    // Assign one pane; the other is unaffected — which by keyword group it could not be.
    try editor.app.layout.assign(editor.app.gpa, "Pane 1", &.{"test.a"});
    try std.testing.expectEqual(@as(usize, 1), layout.matchingIn(&one).len);
    try std.testing.expectEqual(@as(usize, 2), layout.matchingIn(&two).len);

    // Output does not fit a document pane. A drop that landed on the
    // workbench canvas used to assign it here and draw it as a tab.
    try editor.app.layout.assign(editor.app.gpa, "Pane 1", &.{ "test.output", "test.a" });
    try std.testing.expectEqual(@as(usize, 1), layout.matchingIn(&one).len);
    try std.testing.expectEqualStrings("test.a", layout.matchingIn(&one)[0].id);

    // Selections are per pane as well: choosing B in pane 2 leaves pane 1 on A.
    layout.selectIn(&two, "test.b");
    try std.testing.expectEqualStrings("test.b", layout.selectedIn(&two).?.id);
    try std.testing.expectEqualStrings("test.a", layout.selectedIn(&one).?.id);
}

// A surface that exists only while another is selected: pixi's packer fills the main area while
// "Project" is the sidebar's tab, a plugin README while its store card is. Declared by the
// surface (`takeover_when`), resolved by the layout, so there is one rule instead of a hook per
// place it can happen.
test "a takeover surface appears only while its trigger is selected, and then annexes the region" {
    var ctx = try shim.init(std.testing.allocator);
    defer ctx.deinit(std.testing.allocator);

    const editor = ctx.editor;
    editor.app.gpa = std.testing.allocator;
    defer editor.app.layout.regions.deinit(editor.app.gpa);
    defer editor.app.layout.regions_building.deinit(editor.app.gpa);
    defer editor.app.layout.deinitQualified(editor.app.gpa);

    const draw = struct {
        fn f(_: ?*anyopaque) anyerror!dvui.App.Result {
            return .ok;
        }
    }.f;
    const sidebar = fizzy.sdk.keywords.ide.sidebar;
    const main = fizzy.sdk.keywords.ide.main;
    try editor.app.host.registerSurface(.{ .id = "test.files", .title = "Files", .keywords = sidebar, .draw = draw });
    try editor.app.host.registerSurface(.{ .id = "test.project", .title = "Project", .keywords = sidebar, .draw = draw });
    try editor.app.host.registerSurface(.{ .id = "test.workspace", .title = "Workspace", .keywords = main, .draw = draw });
    try editor.app.host.registerSurface(.{ .id = "test.packer", .title = "Packer", .keywords = main, .draw = draw, .takeover_when = "test.project" });

    editor.app.layout.registerRegion(editor.app.gpa, .{ .name = "Sidebar", .keywords = sidebar, .id = .extendId(null, @src(), 1) });
    editor.app.layout.registerRegion(editor.app.gpa, .{ .name = "Main", .keywords = main, .id = .extendId(null, @src(), 2) });
    editor.app.layout.publishRegions();

    var layout = fizzy.Editor.Layout.init(&editor.app.host, &editor.app.layout, editor.app.gpa, dvui.currentWindow().arena());

    // Files is the sidebar's default; the packer does not exist.
    try std.testing.expectEqual(@as(usize, 1), layout.matching(main).len);
    try std.testing.expectEqualStrings("test.workspace", layout.selected(main).?.id);
    try std.testing.expectEqual(@as(usize, 0), layout.unplaced().len);

    // Select Project in the sidebar: the packer exists, and it is what Main shows — regardless of
    // what Main's own selection was.
    editor.app.host.setSelectionFor(sidebar, "test.project");
    try std.testing.expectEqual(@as(usize, 2), layout.matching(main).len);
    try std.testing.expectEqualStrings("test.packer", layout.selected(main).?.id);

    // Back to Files: the packer is gone again and Main is the workspace.
    editor.app.host.setSelectionFor(sidebar, "test.files");
    try std.testing.expectEqualStrings("test.workspace", layout.selected(main).?.id);
}

// -- the chrome option ---------------------------------------------------------------------------
// `layout.zig` (fizzy's desktop shape) under each `Chrome`: which end the rail and Sidebar sit at,
// and whether the Panel exists.

const ChromeFrame = struct {
    var editor: ?*fizzy.Editor = null;
    var explorer: fizzy.Explorer = .{};
    var chrome: fizzy.Editor.Chrome = .{};

    fn menuDraw(_: ?*anyopaque) !void {
        dvui.labelNoFmt(@src(), "Test menu", .{}, .{});
    }

    fn frame() !dvui.App.Result {
        const e = editor.?;
        fizzy.core.anchor.want();
        e.chrome = chrome;
        var layout = fizzy.Editor.Layout.init(&e.app.host, &e.app.layout, e.app.gpa, dvui.currentWindow().arena());
        const result = try fizzy.layout.layout(e, &layout);
        e.app.layout.publishRegions();
        return result;
    }
};

fn chromeBounds(editor: *fizzy.Editor, name: []const u8) ?dvui.Rect.Physical {
    for (editor.app.layout.regions.items) |r| if (std.mem.eql(u8, r.name, name)) return r.bounds;
    return null;
}

/// Draw fizzy's shape under `chrome`, with a view in each of its places, and hand `check` the editor.
// anytype: the checks have inferred error sets.
fn withChrome(chrome: fizzy.Editor.Chrome, comptime check: anytype) !void {
    var ctx = try shim.init(std.testing.allocator);
    defer ctx.deinit(std.testing.allocator);
    const editor = ctx.editor;
    editor.app.gpa = std.testing.allocator;
    defer editor.app.layout.regions.deinit(editor.app.gpa);
    defer editor.app.layout.regions_building.deinit(editor.app.gpa);
    defer editor.app.layout.deinitExtents(editor.app.gpa);
    defer editor.app.layout.deinitQualified(editor.app.gpa);
    defer editor.app.layout.deinitAssignments(editor.app.gpa);

    editor.infobar = .{};
    editor.app.host.fizzy_api = .{ .ctx = editor, .vtable = &fizzy.Editor.fizzy_api_vtable };
    try editor.app.host.registerMenu(.{ .id = "test.menu", .draw = ChromeFrame.menuDraw });
    ChromeFrame.explorer = .{};
    editor.explorer = &ChromeFrame.explorer;
    ChromeFrame.editor = editor;
    defer ChromeFrame.editor = null;
    ChromeFrame.chrome = chrome;

    const kw = fizzy.sdk.keywords.ide;
    try editor.app.host.registerSurface(.{ .id = "test.files", .title = "Files", .keywords = kw.sidebar, .draw = TabsFrame.draw });
    try editor.app.host.registerSurface(.{ .id = "test.workspace", .title = "Workspace", .keywords = kw.main, .draw = TabsFrame.draw });
    try editor.app.host.registerSurface(.{ .id = "test.output", .title = "Output", .keywords = kw.panel, .draw = TabsFrame.draw });
    try dvui.testing.settle(ChromeFrame.frame);
    try check(editor);
}

fn expectSidebarLeft(editor: *fizzy.Editor) !void {
    const side = chromeBounds(editor, "Sidebar") orelse return error.TestUnexpectedResult;
    const main = chromeBounds(editor, "Main") orelse return error.TestUnexpectedResult;
    try std.testing.expect(side.x < main.x);
    // The rail sits left of it.
    try std.testing.expect(side.x > 0);
    try std.testing.expect(chromeBounds(editor, "Panel") != null);
}

fn expectSidebarRight(editor: *fizzy.Editor) !void {
    const side = chromeBounds(editor, "Sidebar") orelse return error.TestUnexpectedResult;
    const main = chromeBounds(editor, "Main") orelse return error.TestUnexpectedResult;
    try std.testing.expect(side.x > main.x + main.w - 1);
    // The rail takes the window's last stretch, so the Sidebar stops short of the edge.
    try std.testing.expect(side.x + side.w < dvui.windowRectPixels().w - 20);
    // And the left edge is Main's, with only the work area's gutter before it.
    try std.testing.expect(main.x < 40);
    try std.testing.expect(chromeBounds(editor, "Panel") != null);
}

fn expectNoPanel(editor: *fizzy.Editor) !void {
    try std.testing.expect(chromeBounds(editor, "Main") != null);
    try std.testing.expect(chromeBounds(editor, "Sidebar") != null);
    try std.testing.expect(chromeBounds(editor, "Panel") == null);
    try std.testing.expect(editor.regionFor(fizzy.sdk.keywords.ide.panel) == null);
}

test "rail: the undecided-plugin badge counts for the store view and no other" {
    var ctx = try shim.init(std.testing.allocator);
    defer ctx.deinit(std.testing.allocator);
    const editor = ctx.editor;
    editor.app.gpa = std.testing.allocator;
    defer {
        for (editor.app.undecided_plugin_ids.items) |id| editor.app.gpa.free(id);
        editor.app.undecided_plugin_ids.clearAndFree(editor.app.gpa);
    }
    try editor.app.trackUndecidedPlugin("one");
    try editor.app.trackUndecidedPlugin("two");

    const host = fizzy.layout.railHost(editor);
    try std.testing.expectEqual(@as(usize, 2), host.vtable.undecidedPluginCount(host.ctx, @import("app").store.Store.view_id));
    try std.testing.expectEqual(@as(usize, 0), host.vtable.undecidedPluginCount(host.ctx, "test.files"));
}

test "chrome: the defaults are fizzy's own frame, Sidebar left of Main with a Panel" {
    try std.testing.expectEqual(fizzy.Editor.Chrome{}, fizzy.Editor.Chrome.configured);
    try withChrome(.{}, expectSidebarLeft);
}

test "chrome: sidebar_edge right puts the rail and Sidebar right of Main" {
    try withChrome(.{ .sidebar_edge = .right }, expectSidebarRight);
}

test "chrome: panel false leaves no Panel place" {
    try withChrome(.{ .panel = false }, expectNoPanel);
}

fn expectBarsVisible(editor: *fizzy.Editor) !void {
    const side = chromeBounds(editor, "Sidebar") orelse return error.TestUnexpectedResult;
    try std.testing.expect(side.h < dvui.windowRectPixels().h - 1);
}

fn expectBarsHidden(editor: *fizzy.Editor) !void {
    const side = chromeBounds(editor, "Sidebar") orelse return error.TestUnexpectedResult;
    try std.testing.expectApproxEqAbs(dvui.windowRectPixels().h, side.h, 0.5);
}

test "chrome: infobar occupies space only when enabled" {
    try withChrome(.{ .menu_bar = false }, expectBarsVisible);
    try withChrome(.{ .menu_bar = false, .infobar = false }, expectBarsHidden);
}

test "chrome: in-window menu occupies space only when enabled" {
    const Menu = @import("fizzy").Editor.Menu;
    const before = Menu.debug_force_on_macos;
    Menu.debug_force_on_macos = true;
    defer Menu.debug_force_on_macos = before;
    try withChrome(.{ .infobar = false }, expectBarsVisible);
    try withChrome(.{ .menu_bar = false, .infobar = false }, expectBarsHidden);
}

// -- the mobile shape ----------------------------------------------------------------------------
// `layout_mobile.zig` under a forced `.mobile` form factor: which places it declares, what it
// draws, and that mobile's arrangement is kept apart from a desktop's in `layout.zon`.

const MobileFrame = struct {
    var editor: ?*fizzy.Editor = null;
    var explorer: fizzy.Explorer = .{};

    fn frame() !dvui.App.Result {
        const e = editor.?;
        fizzy.core.anchor.want();
        var layout = fizzy.Editor.Layout.init(&e.app.host, &e.app.layout, e.app.gpa, dvui.currentWindow().arena());
        if (layout.form_factor != .mobile) return error.TestUnexpectedResult;
        const result = try fizzy.layout_mobile.layout(e, &layout);
        e.app.layout.publishRegions();
        return result;
    }
};

fn regionHeight(editor: *fizzy.Editor, name: []const u8) f32 {
    for (editor.app.layout.regions.items) |r| if (std.mem.eql(u8, r.name, name)) return r.size.h;
    return -1;
}

/// A left click at the middle of `r`, then the frames after it.
// anytype: Frame callbacks have inferred error sets and run through the same tap sequence.
fn tapAt(r: dvui.Rect.Physical, comptime frame: anytype) !void {
    _ = try dvui.currentWindow().addEventMouseMotion(.{ .pt = r.center() });
    _ = try dvui.currentWindow().addEventMouseButton(.left, .press);
    _ = try dvui.currentWindow().addEventMouseButton(.left, .release);
    try dvui.testing.settle(frame);
}

fn mobileCase(ctx: *shim.Ctx) !void {
    const editor = ctx.editor;
    editor.app.gpa = std.testing.allocator;
    MobileFrame.explorer = .{};
    editor.explorer = &MobileFrame.explorer;
    fizzy.core.platform.cached_form_factor = .mobile;
    editor.chrome = .{};
    MobileFrame.editor = editor;
    const kw = fizzy.sdk.keywords.ide;
    try editor.app.host.registerSurface(.{ .id = "test.files", .title = "Files", .keywords = kw.sidebar, .draw = TabsFrame.draw });
    try editor.app.host.registerSurface(.{ .id = "test.search", .title = "Search", .keywords = kw.sidebar, .draw = TabsFrame.draw });
    try editor.app.host.registerSurface(.{ .id = "test.workspace", .title = "Workspace", .keywords = kw.main, .draw = TabsFrame.draw });
    try editor.app.host.registerSurface(.{ .id = "test.output", .title = "Output", .keywords = kw.panel, .draw = TabsFrame.draw });
}

test "mobile's shape is Main, two shut sheets, a bar of the rail's views and a command button" {
    var ctx = try shim.init(std.testing.allocator);
    defer ctx.deinit(std.testing.allocator);
    const editor = ctx.editor;
    editor.app.gpa = std.testing.allocator;
    defer editor.app.layout.regions.deinit(editor.app.gpa);
    defer editor.app.layout.regions_building.deinit(editor.app.gpa);
    defer editor.app.layout.deinitExtents(editor.app.gpa);
    defer editor.app.layout.deinitQualified(editor.app.gpa);
    defer editor.app.layout.deinitAssignments(editor.app.gpa);

    fizzy.core.platform.cached_form_factor = .mobile;
    defer fizzy.core.platform.cached_form_factor = .desktop;
    editor.chrome = .{};
    MobileFrame.editor = editor;
    defer MobileFrame.editor = null;

    const kw = fizzy.sdk.keywords.ide;
    try editor.app.host.registerSurface(.{ .id = "test.files", .title = "Files", .keywords = kw.sidebar, .draw = TabsFrame.draw });
    try editor.app.host.registerSurface(.{ .id = "test.search", .title = "Search", .keywords = kw.sidebar, .draw = TabsFrame.draw });
    try editor.app.host.registerSurface(.{ .id = "test.workspace", .title = "Workspace", .keywords = kw.main, .draw = TabsFrame.draw });
    try editor.app.host.registerSurface(.{ .id = "test.output", .title = "Output", .keywords = kw.panel, .draw = TabsFrame.draw });

    try dvui.testing.settle(MobileFrame.frame);

    // The places: one Main, a sheet each for the sidebar's views and the panel's, nothing else.
    var names: std.ArrayList([]const u8) = .empty;
    defer names.deinit(std.testing.allocator);
    for (editor.app.layout.regions.items) |r| if (r.name.len > 0) try names.append(std.testing.allocator, r.name);
    try std.testing.expectEqual(@as(usize, 3), names.items.len);
    try std.testing.expect(holds(names.items, "Main"));
    try std.testing.expect(holds(names.items, "Explorer"));
    try std.testing.expect(holds(names.items, "Panel"));

    // Sheets start shut, and a shut sheet takes no space: Main has the screen between the title
    // strip and the bar.
    try std.testing.expect(placeShut(editor, "Explorer"));
    try std.testing.expect(placeShut(editor, "Panel"));
    {
        const win = dvui.windowRect().h;
        const main_h = regionHeight(editor, "Main");
        try std.testing.expect(main_h > win - 48 - 56 - 8);
        try std.testing.expect(main_h <= win);
    }

    // What is drawn, by the names demos aim at: the title, a bar entry for each sidebar view,
    // the panel's button and the commands'. No rail, and so no desktop chrome.
    try std.testing.expect(dvui.tagGet("fizzy.mobile.title") != null);
    try std.testing.expect(dvui.tagGet("fizzy.mobile.commands") != null);
    try std.testing.expect(dvui.tagGet("fizzy.mobile.panel") != null);
    try std.testing.expect(dvui.tagGet("fizzy.mobile.tab:test.files") != null);
    try std.testing.expect(dvui.tagGet("fizzy.mobile.tab:test.search") != null);
    try std.testing.expect(dvui.tagGet("fizzy.rail:test.files") == null);

    // The bar sits under Main and the strip over it.
    const strip = dvui.tagGet("fizzy.mobile.title").?.rect;
    const tab = dvui.tagGet("fizzy.mobile.tab:test.files").?.rect;
    try std.testing.expect(strip.y < tab.y);

    // Opening the panel sheet gives it height, and shutting it takes it away again.
    const panel = editor.regionFor(kw.panel) orelse return error.TestUnexpectedResult;
    panel.open();
    try dvui.testing.settle(MobileFrame.frame);
    try std.testing.expect(!placeShut(editor, "Panel"));
    var panel_h: f32 = 0;
    for (editor.app.layout.regions.items) |r| if (std.mem.eql(u8, r.name, "Panel")) {
        panel_h = r.size.h;
    };
    try std.testing.expect(panel_h > 100);
    panel.close();
    try dvui.testing.settle(MobileFrame.frame);
    try std.testing.expect(placeShut(editor, "Panel"));
}

test "a tap on the scrim shuts the open sheet, and a tap on Main with none open does not" {
    var ctx = try shim.init(std.testing.allocator);
    defer ctx.deinit(std.testing.allocator);
    const editor = ctx.editor;
    try mobileCase(&ctx);
    defer fizzy.core.platform.cached_form_factor = .desktop;
    defer MobileFrame.editor = null;
    defer editor.app.layout.regions.deinit(editor.app.gpa);
    defer editor.app.layout.regions_building.deinit(editor.app.gpa);
    defer editor.app.layout.deinitExtents(editor.app.gpa);
    defer editor.app.layout.deinitQualified(editor.app.gpa);
    defer editor.app.layout.deinitAssignments(editor.app.gpa);

    try dvui.testing.settle(MobileFrame.frame);
    const panel = editor.regionFor(fizzy.sdk.keywords.ide.panel) orelse return error.TestUnexpectedResult;
    panel.open();
    try dvui.testing.settle(MobileFrame.frame);
    try std.testing.expect(!placeShut(editor, "Panel"));

    // Just under the title strip: over Main, above the sheet.
    const title = dvui.tagGet("fizzy.mobile.title").?.rect;
    const scrim: dvui.Rect.Physical = .{ .x = title.x, .y = title.y + title.h + 60, .w = 10, .h = 10 };
    try tapAt(scrim, MobileFrame.frame);
    try dvui.testing.settle(MobileFrame.frame);
    try std.testing.expect(placeShut(editor, "Panel"));
}

test "a bar tab opens the explorer sheet on its view, and picking the showing one again shuts it" {
    var ctx = try shim.init(std.testing.allocator);
    defer ctx.deinit(std.testing.allocator);
    const editor = ctx.editor;
    try mobileCase(&ctx);
    defer fizzy.core.platform.cached_form_factor = .desktop;
    defer MobileFrame.editor = null;
    defer editor.app.layout.regions.deinit(editor.app.gpa);
    defer editor.app.layout.regions_building.deinit(editor.app.gpa);
    defer editor.app.layout.deinitExtents(editor.app.gpa);
    defer editor.app.layout.deinitQualified(editor.app.gpa);
    defer editor.app.layout.deinitAssignments(editor.app.gpa);

    try dvui.testing.settle(MobileFrame.frame);
    try std.testing.expect(placeShut(editor, "Explorer"));

    const search = dvui.tagGet("fizzy.mobile.tab:test.search").?.rect;
    try tapAt(search, MobileFrame.frame);
    try std.testing.expect(!placeShut(editor, "Explorer"));
    {
        var layout = fizzy.Editor.Layout.init(&editor.app.host, &editor.app.layout, editor.app.gpa, dvui.currentWindow().arena());
        try std.testing.expectEqualStrings("test.search", layout.selected(fizzy.sdk.keywords.ide.sidebar).?.id);
    }

    // The tab showing, tapped again: the sheet goes.
    try tapAt(dvui.tagGet("fizzy.mobile.tab:test.search").?.rect, MobileFrame.frame);
    try std.testing.expect(placeShut(editor, "Explorer"));
}

test "the Layout setting switches a desktop window to the mobile shape and back, held while a demo plays" {
    var ctx = try shim.init(std.testing.allocator);
    defer ctx.deinit(std.testing.allocator);
    const editor = ctx.editor;
    const gpa = std.testing.allocator;
    editor.app.gpa = gpa;
    defer editor.app.layout.deinitExtents(gpa);
    defer editor.app.layout.deinitAssignments(gpa);
    const io_before = dvui.io;
    defer dvui.io = io_before;
    dvui.io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var dir_buf: [std.fs.max_path_bytes]u8 = undefined;
    editor.app.config_folder = dir_buf[0..try tmp.dir.realPath(dvui.io, &dir_buf)];
    defer fizzy.core.platform.cached_layout_mode = .auto;

    const state = &editor.app.layout;
    const mobile_key = "mobile";

    editor.chooseShape();
    try std.testing.expectEqualStrings("", state.shape);

    // Mobile on a desktop form factor: the mobile shape at once.
    editor.app.settings.layout_mode = .mobile;
    editor.chooseShape();
    try std.testing.expectEqual(fizzy.core.platform.FormFactor.mobile, fizzy.core.platform.formFactor());
    try std.testing.expectEqualStrings(mobile_key, state.shape);

    // Desktop: the desktop arrangement is back.
    editor.app.settings.layout_mode = .desktop;
    editor.chooseShape();
    try std.testing.expectEqualStrings("", state.shape);

    // While a demo plays the change waits, and lands when it ends.
    editor.app.settings.layout_mode = .mobile;
    editor.demo.player.state = .playing;
    editor.chooseShape();
    try std.testing.expectEqualStrings("", state.shape);
    editor.demo.player.state = .idle;
    editor.chooseShape();
    try std.testing.expectEqualStrings(mobile_key, state.shape);
}

test "syncLayoutMode hands the Layout setting to the form factor without switching the shape, held while a demo plays" {
    var ctx = try shim.init(std.testing.allocator);
    defer ctx.deinit(std.testing.allocator);
    const editor = ctx.editor;
    defer fizzy.core.platform.cached_layout_mode = .auto;

    const shape_before = editor.app.layout.shape;
    editor.app.settings.layout_mode = .mobile;
    editor.syncLayoutMode();
    try std.testing.expectEqual(fizzy.core.platform.FormFactor.mobile, fizzy.core.platform.formFactor());
    try std.testing.expectEqualStrings(shape_before, editor.app.layout.shape);

    editor.app.settings.layout_mode = .desktop;
    editor.demo.player.state = .playing;
    editor.syncLayoutMode();
    try std.testing.expectEqual(fizzy.core.platform.FormFactor.mobile, fizzy.core.platform.formFactor());
    editor.demo.player.state = .idle;
    editor.syncLayoutMode();
    try std.testing.expectEqual(fizzy.core.platform.FormFactor.desktop, fizzy.core.platform.formFactor());
}

test "a form-factor flip saves the shape it leaves and loads the other's, leaving the first's file part alone" {
    var ctx = try shim.init(std.testing.allocator);
    defer ctx.deinit(std.testing.allocator);
    const editor = ctx.editor;
    const gpa = std.testing.allocator;
    editor.app.gpa = gpa;
    defer editor.app.layout.deinitExtents(gpa);
    defer editor.app.layout.deinitAssignments(gpa);
    const io_before = dvui.io;
    defer dvui.io = io_before;
    dvui.io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var dir_buf: [std.fs.max_path_bytes]u8 = undefined;
    const dir = dir_buf[0..try tmp.dir.realPath(dvui.io, &dir_buf)];
    editor.app.config_folder = dir;

    const state = &editor.app.layout;
    // The desktop, with a sidebar the user dragged and not yet saved.
    _ = state.setExtent(gpa, "Sidebar", 300);
    state.dirty = true;
    editor.useShape("mobile");
    try std.testing.expectEqualStrings("mobile", state.shape);
    try std.testing.expect(!state.dirty);
    // The desktop's was written, and none of it is in the mobile's state.
    try std.testing.expectEqual(@as(?f32, null), state.extents.get("Sidebar"));
    {
        const desktop = fizzy.backend.loadRegions(gpa, dir, "");
        defer fizzy.backend.freeRegions(gpa, desktop);
        try std.testing.expectEqual(@as(usize, 1), desktop.len);
        try std.testing.expectEqual(@as(?f32, 300), desktop[0].extent);
    }

    // The mobile's sheet, then back: the mobile's is written, the desktop's is read again.
    _ = state.setExtent(gpa, "Explorer", 400);
    state.dirty = true;
    editor.useShape("");
    try std.testing.expectEqualStrings("", state.shape);
    try std.testing.expectEqual(@as(?f32, 300), state.extents.get("Sidebar"));
    try std.testing.expectEqual(@as(?f32, null), state.extents.get("Explorer"));
    {
        const mobile = fizzy.backend.loadRegions(gpa, dir, "mobile");
        defer fizzy.backend.freeRegions(gpa, mobile);
        try std.testing.expectEqual(@as(usize, 1), mobile.len);
        try std.testing.expectEqualStrings("Explorer", mobile[0].name);
        const desktop = fizzy.backend.loadRegions(gpa, dir, "");
        defer fizzy.backend.freeRegions(gpa, desktop);
        try std.testing.expectEqual(@as(usize, 1), desktop.len);
        try std.testing.expectEqualStrings("Sidebar", desktop[0].name);
    }

    // The same shape again is nothing to do: unsaved changes stay unsaved.
    _ = state.setExtent(gpa, "Sidebar", 280);
    state.dirty = true;
    editor.useShape("");
    try std.testing.expect(state.dirty);
}

test "layout.zon keeps each shape's regions apart, and a file with no shapes reads as the first" {
    const gpa = std.testing.allocator;
    const io_before = dvui.io;
    defer dvui.io = io_before;
    dvui.io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    // Absolute: the writer makes the folder with `createDirAbsolute`.
    var dir_buf: [std.fs.max_path_bytes]u8 = undefined;
    const dir = dir_buf[0..try tmp.dir.realPath(dvui.io, &dir_buf)];

    // A file as a fizzy before shapes wrote it: a frame and a region list.
    try tmp.dir.writeFile(dvui.io, .{ .sub_path = "layout.zon", .data =
        \\.{ .x = 10, .regions = .{ .{ .name = "Sidebar", .extent = 260 } } }
    });
    {
        const desktop = fizzy.backend.loadRegions(gpa, dir, "");
        defer fizzy.backend.freeRegions(gpa, desktop);
        try std.testing.expectEqual(@as(usize, 1), desktop.len);
        const mobile = fizzy.backend.loadRegions(gpa, dir, "mobile");
        defer fizzy.backend.freeRegions(gpa, mobile);
        try std.testing.expectEqual(@as(usize, 0), mobile.len);
    }

    // The mobile saves its own; the desktop's is where it was.
    fizzy.backend.saveRegions(dir, "mobile", &.{.{ .name = "Explorer", .extent = 400 }});
    {
        const desktop = fizzy.backend.loadRegions(gpa, dir, "");
        defer fizzy.backend.freeRegions(gpa, desktop);
        try std.testing.expectEqual(@as(usize, 1), desktop.len);
        try std.testing.expectEqualStrings("Sidebar", desktop[0].name);
        const mobile = fizzy.backend.loadRegions(gpa, dir, "mobile");
        defer fizzy.backend.freeRegions(gpa, mobile);
        try std.testing.expectEqual(@as(usize, 1), mobile.len);
        try std.testing.expectEqualStrings("Explorer", mobile[0].name);
        try std.testing.expectEqual(@as(?f32, 400), mobile[0].extent);
    }

    // The desktop saves again, and again the mobile's stays; a second mobile save replaces the first.
    fizzy.backend.saveRegions(dir, "", &.{ .{ .name = "Sidebar", .extent = 300 }, .{ .name = "Panel", .extent = 200 } });
    fizzy.backend.saveRegions(dir, "mobile", &.{.{ .name = "Panel", .extent = 150 }});
    {
        const desktop = fizzy.backend.loadRegions(gpa, dir, "");
        defer fizzy.backend.freeRegions(gpa, desktop);
        try std.testing.expectEqual(@as(usize, 2), desktop.len);
        const mobile = fizzy.backend.loadRegions(gpa, dir, "mobile");
        defer fizzy.backend.freeRegions(gpa, mobile);
        try std.testing.expectEqual(@as(usize, 1), mobile.len);
        try std.testing.expectEqualStrings("Panel", mobile[0].name);
    }
}

// -- endless layout ------------------------------------------------------------------------------
// The endless shape, not a shipped fizzy preset: a copy of fizzyedit/example-app's
// `shapes/endless.zig`, wired as `endless_layout` in `build/app.zig` from `tests/shapes/endless.zig`.

const endless = @import("endless_layout");

const EndlessFrame = struct {
    var editor: ?*fizzy.Editor = null;

    fn frame() anyerror!dvui.App.Result {
        const e = editor.?;
        var layout = fizzy.Editor.Layout.init(&e.app.host, &e.app.layout, e.app.gpa, dvui.currentWindow().arena());
        const result = try endless.layout(null, &layout);
        layout.drawFloats();
        e.app.layout.publishRegions();
        // Over every place, as fizzy's frame does: the drops the places queued.
        layout.drawDragOverlay();
        return result;
    }
};

test "the first frame declares leftover Center and no edge sentinels" {
    var ctx = try shim.init(std.testing.allocator);
    defer ctx.deinit(std.testing.allocator);

    const editor = ctx.editor;
    editor.app.gpa = std.testing.allocator;
    defer editor.app.layout.regions.deinit(editor.app.gpa);
    defer editor.app.layout.regions_building.deinit(editor.app.gpa);
    defer editor.app.layout.deinitExtents(editor.app.gpa);
    defer editor.app.layout.deinitQualified(editor.app.gpa);

    EndlessFrame.editor = editor;
    defer EndlessFrame.editor = null;

    try dvui.testing.settle(EndlessFrame.frame);

    var center = false;
    var edges: usize = 0;
    for (editor.app.layout.regions.items) |r| {
        if (std.mem.eql(u8, r.name, "Center")) center = true;
        if (std.mem.startsWith(u8, r.name, "edge-")) edges += 1;
    }
    try std.testing.expect(center);
    try std.testing.expectEqual(@as(usize, 0), edges);
}

test "a menu split opens an empty place on that axis" {
    var ctx = try shim.init(std.testing.allocator);
    defer ctx.deinit(std.testing.allocator);

    const editor = ctx.editor;
    editor.app.gpa = std.testing.allocator;
    defer editor.app.layout.regions.deinit(editor.app.gpa);
    defer editor.app.layout.regions_building.deinit(editor.app.gpa);
    defer editor.app.layout.deinitExtents(editor.app.gpa);
    defer editor.app.layout.deinitAssignments(editor.app.gpa);
    defer editor.app.layout.deinitQualified(editor.app.gpa);

    EndlessFrame.editor = editor;
    defer EndlessFrame.editor = null;

    try dvui.testing.settle(EndlessFrame.frame);
    {
        var layout = fizzy.Editor.Layout.init(&editor.app.host, &editor.app.layout, editor.app.gpa, dvui.currentWindow().arena());
        layout.splitNamed("Center", .horizontal);
    }
    try dvui.testing.settle(EndlessFrame.frame);

    try std.testing.expect(editor.app.layout.dock != null);
    try std.testing.expect(editor.app.layout.dock.?.contains("Center/r1"));
    try std.testing.expect(editor.app.layout.isMinted("Center/r1"));
    try std.testing.expect(!editor.app.layout.isMinted("Center"));

    // Leftover keeps a real share. Without the content-size cap, the welcome
    // screen shoves the new pane (and its sash) to the far edge.
    var leftover_w: f32 = 0;
    var created_w: f32 = 0;
    for (editor.app.layout.regions.items) |r| {
        if (std.mem.eql(u8, r.name, "Center")) leftover_w = r.size.w;
        if (std.mem.eql(u8, r.name, "Center/r1")) created_w = r.size.w;
    }
    try std.testing.expect(leftover_w > 80);
    try std.testing.expect(created_w > 80);
}

test "a leftover split keeps its sash on the leftover side" {
    var ctx = try shim.init(std.testing.allocator);
    defer ctx.deinit(std.testing.allocator);

    const editor = ctx.editor;
    editor.app.gpa = std.testing.allocator;
    defer editor.app.layout.regions.deinit(editor.app.gpa);
    defer editor.app.layout.regions_building.deinit(editor.app.gpa);
    defer editor.app.layout.deinitExtents(editor.app.gpa);
    defer editor.app.layout.deinitAssignments(editor.app.gpa);
    defer editor.app.layout.deinitQualified(editor.app.gpa);

    EndlessFrame.editor = editor;
    defer EndlessFrame.editor = null;

    try dvui.testing.settle(EndlessFrame.frame);
    {
        var layout = fizzy.Editor.Layout.init(&editor.app.host, &editor.app.layout, editor.app.gpa, dvui.currentWindow().arena());
        layout.splitNamed("Center", .horizontal);
    }
    try dvui.testing.settle(EndlessFrame.frame);
    {
        var layout = fizzy.Editor.Layout.init(&editor.app.host, &editor.app.layout, editor.app.gpa, dvui.currentWindow().arena());
        layout.splitNamed("Center", .horizontal);
    }
    try dvui.testing.settle(EndlessFrame.frame);

    try std.testing.expect(editor.app.layout.dock.?.contains("Center/r2"));
    try std.testing.expect(editor.app.layout.isMinted("Center/r2"));
    var leftover_w: f32 = 0;
    var inner_w: f32 = 0;
    var outer_w: f32 = 0;
    for (editor.app.layout.regions.items) |r| {
        if (std.mem.eql(u8, r.name, "Center")) leftover_w = r.size.w;
        if (std.mem.eql(u8, r.name, "Center/r2")) inner_w = r.size.w;
        if (std.mem.eql(u8, r.name, "Center/r1")) outer_w = r.size.w;
    }
    try std.testing.expect(leftover_w > 40);
    try std.testing.expect(inner_w > 40);
    try std.testing.expect(outer_w > 40);
}

const FizzySplitFrame = struct {
    var editor: ?*fizzy.Editor = null;

    fn frame() anyerror!dvui.App.Result {
        const e = editor.?;
        var layout = fizzy.Editor.Layout.init(&e.app.host, &e.app.layout, e.app.gpa, dvui.currentWindow().arena());
        {
            var main = try layout.region(@src(), .{ .name = "Main", .keywords = fizzy.sdk.keywords.ide.main }, .{ .expand = .both });
            defer main.deinit();
        }
        e.app.layout.publishRegions();
        e.app.layout.splits.reap(e.app.gpa);
        return .ok;
    }
};

test "picker: its controls are named for a tape or an agent to aim at, while they can be pressed" {
    var ctx = try shim.init(std.testing.allocator);
    defer ctx.deinit(std.testing.allocator);

    const editor = ctx.editor;
    editor.app.gpa = std.testing.allocator;
    defer editor.app.layout.regions.deinit(editor.app.gpa);
    defer editor.app.layout.regions_building.deinit(editor.app.gpa);
    defer editor.app.layout.deinitExtents(editor.app.gpa);
    defer editor.app.layout.deinitAssignments(editor.app.gpa);
    defer editor.app.layout.deinitQualified(editor.app.gpa);
    defer editor.app.layout.picker.close(editor.app.gpa);

    PickerFrame.editor = editor;
    defer PickerFrame.editor = null;

    try fizzy.Editor.Layout.place_commands.register(&editor.app.host, &editor.app.layout);
    try dvui.testing.settle(PickerFrame.frame);
    editor.app.layout.picker.open(editor.app.gpa, "Main", null);
    _ = try dvui.testing.step(PickerFrame.frame);
    _ = try dvui.testing.step(PickerFrame.frame);

    for ([_][]const u8{ "region.menu.split-right:Main", "region.menu.split-down:Main" }) |name| {
        if (dvui.tagGet(name) == null) {
            std.debug.print("no anchor {s}\n", .{name});
            return error.TestExpectedEqual;
        }
    }
    // Main shows nothing, so Clear is dimmed and has no name; nothing was put there, so there is
    // no default to go back to; and a shape's place cannot be deleted.
    try std.testing.expect(dvui.tagGet("region.menu.clear:Main") == null);
    try std.testing.expect(dvui.tagGet("region.menu.reset:Main") == null);
    try std.testing.expect(dvui.tagGet("region.menu.delete:Main") == null);
}

test "picker: each header control runs its command, the button and the palette alike" {
    var ctx = try shim.init(std.testing.allocator);
    defer ctx.deinit(std.testing.allocator);

    const editor = ctx.editor;
    editor.app.gpa = std.testing.allocator;
    defer editor.app.layout.regions.deinit(editor.app.gpa);
    defer editor.app.layout.regions_building.deinit(editor.app.gpa);
    defer editor.app.layout.deinitExtents(editor.app.gpa);
    defer editor.app.layout.deinitAssignments(editor.app.gpa);
    defer editor.app.layout.deinitQualified(editor.app.gpa);
    defer editor.app.layout.picker.close(editor.app.gpa);

    PickerFrame.editor = editor;
    defer PickerFrame.editor = null;
    const state = &editor.app.layout;
    try fizzy.Editor.Layout.place_commands.register(&editor.app.host, state);
    try editor.app.host.registerSurface(.{ .id = "test.out", .title = "Out", .keywords = sdk.keywords.ide.panel, .draw = PickerFrame.draw });
    try dvui.testing.settle(PickerFrame.frame);

    // Run from the palette, with no place named: the place whose menu is open.
    state.picker.open(editor.app.gpa, "Panel", null);
    try editor.app.host.runCommand("layout.place.clear");
    try dvui.testing.settle(PickerFrame.frame);
    try std.testing.expectEqual(@as(usize, 0), (state.assignment("Panel") orelse return error.TestExpectedEqual).len);
    try std.testing.expect(state.picker.is_open);

    // The button: pressed, it runs `layout.place.reset`, and Panel goes back to its keywords.
    try dvui.testing.settle(PickerFrame.frame);
    try dvui.testing.moveTo("region.menu.reset:Panel");
    try dvui.testing.click(.left);
    try dvui.testing.settle(PickerFrame.frame);
    try std.testing.expect(state.assignment("Panel") == null);

    // Split, named: the place divides, and its menu, no longer true, shuts.
    var results: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer results.deinit();
    const out = editor.app.host.callCommand("layout.place.splitRight", ".{ .place = \"Panel\" }", results.allocator());
    try std.testing.expect(out == .ok);
    try dvui.testing.settle(PickerFrame.frame);
    try std.testing.expect(state.splits.root("Panel") != null);
    try std.testing.expect(!state.picker.is_open);
}

test "a fizzy Main split is a removable slot, not main.slot" {
    var ctx = try shim.init(std.testing.allocator);
    defer ctx.deinit(std.testing.allocator);

    const editor = ctx.editor;
    editor.app.gpa = std.testing.allocator;
    defer editor.app.layout.regions.deinit(editor.app.gpa);
    defer editor.app.layout.regions_building.deinit(editor.app.gpa);
    defer editor.app.layout.deinitExtents(editor.app.gpa);
    defer editor.app.layout.deinitAssignments(editor.app.gpa);
    defer editor.app.layout.deinitQualified(editor.app.gpa);

    FizzySplitFrame.editor = editor;
    defer FizzySplitFrame.editor = null;

    try dvui.testing.settle(FizzySplitFrame.frame);
    {
        var layout = fizzy.Editor.Layout.init(&editor.app.host, &editor.app.layout, editor.app.gpa, dvui.currentWindow().arena());
        layout.splitNamed("Main", .horizontal);
    }
    try dvui.testing.settle(FizzySplitFrame.frame);

    try std.testing.expect(editor.app.layout.splits.canForget("Main/r1"));
    var slot = false;
    var qualified = false;
    for (editor.app.layout.regions.items) |r| {
        if (!std.mem.eql(u8, r.name, "Main/r1")) continue;
        try std.testing.expect(r.forget_when_empty);
        try std.testing.expect(r.by_name);
        for (r.keywords) |k| {
            if (std.mem.eql(u8, k, "slot")) slot = true;
            if (std.mem.endsWith(u8, k, ".slot")) qualified = true;
        }
    }
    try std.testing.expect(slot);
    try std.testing.expect(!qualified);
}

test "a fizzy Main split keeps the workspace on the leftover side" {
    var ctx = try shim.init(std.testing.allocator);
    defer ctx.deinit(std.testing.allocator);

    const editor = ctx.editor;
    editor.app.gpa = std.testing.allocator;
    defer editor.app.layout.regions.deinit(editor.app.gpa);
    defer editor.app.layout.regions_building.deinit(editor.app.gpa);
    defer editor.app.layout.deinitExtents(editor.app.gpa);
    defer editor.app.layout.deinitAssignments(editor.app.gpa);
    defer editor.app.layout.deinitQualified(editor.app.gpa);

    const Draw = struct {
        var count: usize = 0;
        fn f(_: ?*anyopaque) anyerror!dvui.App.Result {
            count += 1;
            return .ok;
        }
    };
    try editor.app.host.registerSurface(.{
        .id = "test.workspace",
        .title = "Workspace",
        .keywords = fizzy.sdk.keywords.ide.main,
        .draw = Draw.f,
    });

    FizzySplitFrame.editor = editor;
    defer FizzySplitFrame.editor = null;

    Draw.count = 0;
    try dvui.testing.settle(FizzySplitFrame.frame);
    try std.testing.expect(Draw.count > 0);

    {
        var layout = fizzy.Editor.Layout.init(&editor.app.host, &editor.app.layout, editor.app.gpa, dvui.currentWindow().arena());
        layout.splitNamed("Main", .horizontal);
    }

    Draw.count = 0;
    try dvui.testing.settle(FizzySplitFrame.frame);
    try std.testing.expect(Draw.count > 0);
    try std.testing.expect(editor.app.layout.splits.canForget("Main/r1"));
    const created = editor.app.layout.assignment("Main/r1") orelse return error.TestExpectedEqual;
    try std.testing.expectEqual(@as(usize, 0), created.len);
}

/// Frees the state a `FizzySplitFrame` test builds up, so `std.testing.allocator` sees every leak
/// and every use after free.
fn deinitSplitState(editor: *fizzy.Editor) void {
    editor.app.layout.regions.deinit(editor.app.gpa);
    editor.app.layout.regions_building.deinit(editor.app.gpa);
    editor.app.layout.deinitExtents(editor.app.gpa);
    editor.app.layout.deinitAssignments(editor.app.gpa);
    editor.app.layout.deinitQualified(editor.app.gpa);
}

test "a leading empty split dropped onto the trash does not draw freed nodes" {
    var ctx = try shim.init(std.testing.allocator);
    defer ctx.deinit(std.testing.allocator);
    const editor = ctx.editor;
    editor.app.gpa = std.testing.allocator;
    defer deinitSplitState(editor);
    FizzySplitFrame.editor = editor;
    defer FizzySplitFrame.editor = null;

    try dvui.testing.settle(FizzySplitFrame.frame);
    {
        var layout = fizzy.Editor.Layout.init(&editor.app.host, &editor.app.layout, editor.app.gpa, dvui.currentWindow().arena());
        // `.left`: the new half is the tree's first child, the original `Main` leaf its last.
        try std.testing.expectEqualStrings("Main/l1", layout.splitOn("Main", .left) orelse return error.TestExpectedEqual);
    }
    try dvui.testing.settle(FizzySplitFrame.frame);
    try std.testing.expect(editor.app.layout.splits.root("Main") != null);

    {
        var layout = fizzy.Editor.Layout.init(&editor.app.host, &editor.app.layout, editor.app.gpa, dvui.currentWindow().arena());
        fizzy.Editor.Layout.ViewDrag.place(&layout, "Main/l1", "Main/l1", .remove);
    }
    try dvui.testing.settle(FizzySplitFrame.frame);
    try dvui.testing.settle(FizzySplitFrame.frame);
    // The collapse took the whole tree down to the origin leaf, and the frame's reap freed it.
    try std.testing.expect(editor.app.layout.splits.root("Main") == null);
    try std.testing.expectEqual(@as(usize, 0), editor.app.layout.splits.buried.items.len);
}

test "a saved layout holding an empty runtime split draws without crashing" {
    var ctx = try shim.init(std.testing.allocator);
    defer ctx.deinit(std.testing.allocator);
    const editor = ctx.editor;
    editor.app.gpa = std.testing.allocator;
    defer deinitSplitState(editor);
    FizzySplitFrame.editor = editor;
    defer FizzySplitFrame.editor = null;

    // What `Editor.applySavedRegions` rebuilds from a file: Main/l1 from the left of Main, an
    // extent of nothing (what a drop leaves behind), and no view in it.
    const saved = [_]fizzy.backend.SavedRegion{
        .{ .name = "Main/l1", .extent = 0, .parent = "Main", .from = "left" },
    };
    editor.applySavedRegions(&saved);
    try std.testing.expect(editor.app.layout.splits.root("Main") != null);

    try dvui.testing.settle(FizzySplitFrame.frame);
    try dvui.testing.settle(FizzySplitFrame.frame);
    // The collapse took the whole tree down to the origin leaf, and the frame's reap freed it.
    try std.testing.expect(editor.app.layout.splits.root("Main") == null);
    try std.testing.expectEqual(@as(usize, 0), editor.app.layout.splits.buried.items.len);
}

/// fizzy's own Main: a carded place that hands its card to its panes, in a column of the window.
const ColumnCardFrame = struct {
    var editor: ?*fizzy.Editor = null;

    fn frame() anyerror!dvui.App.Result {
        const e = editor.?;
        var layout = fizzy.Editor.Layout.init(&e.app.host, &e.app.layout, e.app.gpa, dvui.currentWindow().arena());
        layout.card = .{ .background = true, .padding = .all(8) };
        {
            var column = try layout.region(@src(), .{ .dir = .vertical }, .{ .expand = .both });
            defer column.deinit();
            var main = try layout.region(@src(), .{ .name = "Main", .keywords = fizzy.sdk.keywords.ide.main, .card = true, .pane_cards = true }, .{ .expand = .both });
            defer main.deinit();
        }
        e.app.layout.publishRegions();
        return .ok;
    }

    /// What the place takes on screen: its border box in physical pixels, measured where it was
    /// drawn rather than read back from the `size` a split halves.
    fn sizeOf(e: *fizzy.Editor, name: []const u8) !dvui.Size {
        for (e.app.layout.regions.items) |r| {
            if (std.mem.eql(u8, r.name, name)) return .{ .w = r.bounds.w, .h = r.bounds.h };
        }
        return error.TestExpectedEqual;
    }
};

// A split's extent is the new half's whole reach, card and all. Measured from the place's content
// instead, every split of a carded place came out uneven by the card's padding, twice over.
test "a split of a carded place, and of its new half, opens even halves" {
    var ctx = try shim.init(std.testing.allocator);
    defer ctx.deinit(std.testing.allocator);

    const editor = ctx.editor;
    editor.app.gpa = std.testing.allocator;
    defer editor.app.layout.regions.deinit(editor.app.gpa);
    defer editor.app.layout.regions_building.deinit(editor.app.gpa);
    defer editor.app.layout.deinitExtents(editor.app.gpa);
    defer editor.app.layout.deinitAssignments(editor.app.gpa);
    defer editor.app.layout.deinitQualified(editor.app.gpa);

    ColumnCardFrame.editor = editor;
    defer ColumnCardFrame.editor = null;

    try dvui.testing.settle(ColumnCardFrame.frame);
    {
        var layout = fizzy.Editor.Layout.init(&editor.app.host, &editor.app.layout, editor.app.gpa, dvui.currentWindow().arena());
        try std.testing.expectEqualStrings("Main/r1", layout.splitOn("Main", .right) orelse return error.TestExpectedEqual);
    }
    try dvui.testing.settle(ColumnCardFrame.frame);
    const left = try ColumnCardFrame.sizeOf(editor, "Main");
    const right = try ColumnCardFrame.sizeOf(editor, "Main/r1");
    try std.testing.expect(left.w > 40);
    try std.testing.expectApproxEqAbs(left.w, right.w, 1);

    {
        var layout = fizzy.Editor.Layout.init(&editor.app.host, &editor.app.layout, editor.app.gpa, dvui.currentWindow().arena());
        try std.testing.expectEqualStrings("Main/r1/b1", layout.splitOn("Main/r1", .bottom) orelse return error.TestExpectedEqual);
    }
    try dvui.testing.settle(ColumnCardFrame.frame);
    const top = try ColumnCardFrame.sizeOf(editor, "Main/r1");
    const bottom = try ColumnCardFrame.sizeOf(editor, "Main/r1/b1");
    try std.testing.expect(top.h > 40);
    try std.testing.expectApproxEqAbs(top.h, bottom.h, 1);
}

// A split fizzy made turns with its space: stacked when the room is taller than wide, side by
// side when wider. The turn is how it is drawn, not what is saved: the person's side and extent
// stay as they left them, nothing is written, and the new half keeps its share of the room.
test "an adaptive split turns with the window, keeps its share and writes nothing" {
    var ctx = try shim.init(std.testing.allocator);
    defer ctx.deinit(std.testing.allocator);

    const editor = ctx.editor;
    editor.app.gpa = std.testing.allocator;
    defer editor.app.layout.regions.deinit(editor.app.gpa);
    defer editor.app.layout.regions_building.deinit(editor.app.gpa);
    defer editor.app.layout.deinitExtents(editor.app.gpa);
    defer editor.app.layout.deinitAssignments(editor.app.gpa);
    defer editor.app.layout.deinitQualified(editor.app.gpa);

    ColumnCardFrame.editor = editor;
    defer ColumnCardFrame.editor = null;

    // A tablet held across: wider than tall.
    ctx.t.backend.size = .{ .w = 1180, .h = 820 };
    ctx.t.backend.size_pixels = .{ .w = 1180, .h = 820 };
    _ = try dvui.testing.step(ColumnCardFrame.frame);
    try dvui.testing.settle(ColumnCardFrame.frame);
    {
        var layout = fizzy.Editor.Layout.init(&editor.app.host, &editor.app.layout, editor.app.gpa, dvui.currentWindow().arena());
        try std.testing.expectEqualStrings("Main/r1", layout.splitOn("Main", .right) orelse return error.TestExpectedEqual);
        layout.markAdaptive("Main/r1");
    }
    try dvui.testing.settle(ColumnCardFrame.frame);
    const old = try ColumnCardFrame.sizeOf(editor, "Main");
    const new = try ColumnCardFrame.sizeOf(editor, "Main/r1");
    try std.testing.expect(new.w > 40);
    try std.testing.expectApproxEqAbs(old.h, new.h, 1);
    const share = new.w / (old.w + new.w);
    const saved_extent = editor.app.layout.extent("Main/r1", 0);
    editor.app.layout.dirty = false;

    // Turned upright: the new half is below, with the share it had beside.
    ctx.t.backend.size = .{ .w = 820, .h = 1180 };
    ctx.t.backend.size_pixels = .{ .w = 820, .h = 1180 };
    // The turn eases (the place slides shut, and open the other way): the frames it takes.
    for (0..40) |_| _ = try dvui.testing.step(ColumnCardFrame.frame);
    const top = try ColumnCardFrame.sizeOf(editor, "Main");
    const bottom = try ColumnCardFrame.sizeOf(editor, "Main/r1");
    try std.testing.expectApproxEqAbs(top.w, bottom.w, 1);
    try std.testing.expectApproxEqAbs(share, bottom.h / (top.h + bottom.h), 0.03);
    try std.testing.expect(!editor.app.layout.dirty);
    try std.testing.expectEqual(saved_extent, editor.app.layout.extent("Main/r1", 0));
    {
        const links = editor.app.layout.splits.collectLinks(std.testing.allocator);
        defer std.testing.allocator.free(links);
        try std.testing.expectEqual(@as(usize, 1), links.len);
        try std.testing.expectEqual(fizzy.Editor.Layout.State.SplitTree.Side.right, links[0].side);
        try std.testing.expect(links[0].adaptive);
    }

    // And back across: beside again, the same share.
    ctx.t.backend.size = .{ .w = 1180, .h = 820 };
    ctx.t.backend.size_pixels = .{ .w = 1180, .h = 820 };
    for (0..40) |_| _ = try dvui.testing.step(ColumnCardFrame.frame);
    const left = try ColumnCardFrame.sizeOf(editor, "Main");
    const right = try ColumnCardFrame.sizeOf(editor, "Main/r1");
    try std.testing.expectApproxEqAbs(left.h, right.h, 1);
    try std.testing.expectApproxEqAbs(share, right.w / (left.w + right.w), 0.03);
    try std.testing.expect(!editor.app.layout.dirty);
}

// The half of an adaptive split that is itself split is an outer branch, not a leaf: its turn
// waits for it to slide shut, and while drawn turned its extent is not the person's to save.
test "an adaptive split whose new half is split again turns and writes nothing" {
    var case = try NestedSplitCase.init();
    defer case.deinit();
    const ctx = &case.ctx;
    const editor = ctx.editor;
    {
        var layout = fizzy.Editor.Layout.init(&editor.app.host, &editor.app.layout, editor.app.gpa, dvui.currentWindow().arena());
        layout.markAdaptive("Main/r1");
    }
    ctx.t.backend.size = .{ .w = 1180, .h = 820 };
    ctx.t.backend.size_pixels = .{ .w = 1180, .h = 820 };
    for (0..40) |_| _ = try dvui.testing.step(ColumnCardFrame.frame);
    const left = try ColumnCardFrame.sizeOf(editor, "Main");
    try std.testing.expect(left.w < left.h * 1.15);
    const saved_extent = editor.app.layout.extent("Main/r1", 0);
    editor.app.layout.dirty = false;

    ctx.t.backend.size = .{ .w = 820, .h = 1180 };
    ctx.t.backend.size_pixels = .{ .w = 820, .h = 1180 };
    for (0..60) |_| _ = try dvui.testing.step(ColumnCardFrame.frame);
    const top = try ColumnCardFrame.sizeOf(editor, "Main");
    const column = try ColumnCardFrame.sizeOf(editor, "Main/r1");
    try std.testing.expect(column.h > 40);
    try std.testing.expectApproxEqAbs(top.w, column.w, 40);
    try std.testing.expect(!editor.app.layout.dirty);
    try std.testing.expectEqual(saved_extent, editor.app.layout.extent("Main/r1", 0));
}

// A half saved in landscape is a pixel extent along the width. Over a portrait box that number is
// another share, so the share is saved beside it and the turn uses that one.
test "an adaptive split saved beside comes back as the same share stacked" {
    var ctx = try shim.init(std.testing.allocator);
    defer ctx.deinit(std.testing.allocator);

    const editor = ctx.editor;
    editor.app.gpa = std.testing.allocator;
    defer editor.app.layout.regions.deinit(editor.app.gpa);
    defer editor.app.layout.regions_building.deinit(editor.app.gpa);
    defer editor.app.layout.deinitExtents(editor.app.gpa);
    defer editor.app.layout.deinitAssignments(editor.app.gpa);
    defer editor.app.layout.deinitQualified(editor.app.gpa);

    ColumnCardFrame.editor = editor;
    defer ColumnCardFrame.editor = null;

    // A restart in portrait: the layout as loaded (`loadRuntimeSplits`) has the landscape half,
    // 590 across a 1180 box, and its share of a half.
    ctx.t.backend.size = .{ .w = 820, .h = 1180 };
    ctx.t.backend.size_pixels = .{ .w = 820, .h = 1180 };
    try dvui.testing.settle(ColumnCardFrame.frame);
    const state = &editor.app.layout;
    const intern = struct {
        var st: *fizzy.Editor.Layout.State = undefined;
        fn go(a: std.mem.Allocator, name: []const u8) []const u8 {
            return st.internName(a, name);
        }
    };
    intern.st = state;
    try std.testing.expect(state.splits.split(editor.app.gpa, intern.go, "Main", .right, 590, "Main/r1") != null);
    try std.testing.expect(state.splits.markAdaptive("Main/r1"));
    try std.testing.expect(state.splits.setShare("Main/r1", 0.5));
    _ = state.setExtent(editor.app.gpa, "Main/r1", 590);

    // Exercise the same collection, ZON format and reconstruction as a saved layout.
    const gpa = std.testing.allocator;
    const regions = editor.collectSavedRegions(gpa);
    defer gpa.free(regions);
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    try std.zon.stringify.serializeMaxDepth(regions, .{}, &out.writer, 64);
    const text = try gpa.dupeSentinel(u8, out.written(), 0);
    defer gpa.free(text);
    var saved_arena: std.heap.ArenaAllocator = .init(gpa);
    defer saved_arena.deinit();
    var saved_diag: std.zon.parse.Diagnostics = undefined;
    const saved = try std.zon.parse.fromSlice([]fizzy.backend.SavedRegion, .{
        .gpa = gpa,
        .arena = saved_arena.allocator(),
        .source = text,
        .diagnostics = &saved_diag,
        .ignore_unknown_fields = true,
    });
    state.resetLayout(gpa);
    editor.applySavedRegions(saved);
    const links = state.splits.collectLinks(gpa);
    defer gpa.free(links);
    try std.testing.expectEqual(@as(usize, 1), links.len);
    try std.testing.expectEqual(@as(?f32, 0.5), links[0].share);
    try std.testing.expect(links[0].adaptive);

    for (0..60) |_| _ = try dvui.testing.step(ColumnCardFrame.frame);
    const top = try ColumnCardFrame.sizeOf(editor, "Main");
    const bottom = try ColumnCardFrame.sizeOf(editor, "Main/r1");
    // Not 590 over the 820 width, which is the share the pixels alone would say.
    try std.testing.expectApproxEqAbs(0.5, bottom.h / (top.h + bottom.h), 0.03);
}

// A sash dragged while an adaptive split is turned is shown and nothing more: the share the saved
// extent gave comes back with the turn back, and the next turn uses it, not the drag's.
test "a drag while an adaptive split is turned is not kept when it turns back" {
    var ctx = try shim.init(std.testing.allocator);
    defer ctx.deinit(std.testing.allocator);

    const editor = ctx.editor;
    editor.app.gpa = std.testing.allocator;
    defer editor.app.layout.regions.deinit(editor.app.gpa);
    defer editor.app.layout.regions_building.deinit(editor.app.gpa);
    defer editor.app.layout.deinitExtents(editor.app.gpa);
    defer editor.app.layout.deinitAssignments(editor.app.gpa);
    defer editor.app.layout.deinitQualified(editor.app.gpa);

    ColumnCardFrame.editor = editor;
    defer ColumnCardFrame.editor = null;

    ctx.t.backend.size = .{ .w = 1180, .h = 820 };
    ctx.t.backend.size_pixels = .{ .w = 1180, .h = 820 };
    _ = try dvui.testing.step(ColumnCardFrame.frame);
    try dvui.testing.settle(ColumnCardFrame.frame);
    {
        var layout = fizzy.Editor.Layout.init(&editor.app.host, &editor.app.layout, editor.app.gpa, dvui.currentWindow().arena());
        try std.testing.expectEqualStrings("Main/r1", layout.splitOn("Main", .right) orelse return error.TestExpectedEqual);
        layout.markAdaptive("Main/r1");
    }
    try dvui.testing.settle(ColumnCardFrame.frame);
    const old = try ColumnCardFrame.sizeOf(editor, "Main");
    const new = try ColumnCardFrame.sizeOf(editor, "Main/r1");
    const share = new.w / (old.w + new.w);
    const saved_extent = editor.app.layout.extent("Main/r1", 0);
    editor.app.layout.dirty = false;

    ctx.t.backend.size = .{ .w = 820, .h = 1180 };
    ctx.t.backend.size_pixels = .{ .w = 820, .h = 1180 };
    for (0..40) |_| _ = try dvui.testing.step(ColumnCardFrame.frame);

    // The sash dragged to a third of the room, as `Split` writes a drag.
    const room = (try ColumnCardFrame.sizeOf(editor, "Main")).h + (try ColumnCardFrame.sizeOf(editor, "Main/r1")).h;
    const leaf = for (editor.app.layout.regions.items) |r| {
        if (std.mem.eql(u8, r.name, "Main/r1")) break r.id;
    } else return error.TestExpectedEqual;
    dvui.dataSet(null, leaf, "_size", room / 3);
    dvui.dataSet(null, leaf, "_shown", room / 3);
    for (0..4) |_| _ = try dvui.testing.step(ColumnCardFrame.frame);
    const dragged = try ColumnCardFrame.sizeOf(editor, "Main/r1");
    try std.testing.expectApproxEqAbs(room / 3, dragged.h, room * 0.05);
    try std.testing.expect(!editor.app.layout.dirty);
    try std.testing.expectEqual(saved_extent, editor.app.layout.extent("Main/r1", 0));

    // Back across: the saved share, not the drag's.
    ctx.t.backend.size = .{ .w = 1180, .h = 820 };
    ctx.t.backend.size_pixels = .{ .w = 1180, .h = 820 };
    for (0..40) |_| _ = try dvui.testing.step(ColumnCardFrame.frame);
    const left = try ColumnCardFrame.sizeOf(editor, "Main");
    const right = try ColumnCardFrame.sizeOf(editor, "Main/r1");
    try std.testing.expectApproxEqAbs(share, right.w / (left.w + right.w), 0.03);

    // And upright again: the share is still the saved one.
    ctx.t.backend.size = .{ .w = 820, .h = 1180 };
    ctx.t.backend.size_pixels = .{ .w = 820, .h = 1180 };
    for (0..40) |_| _ = try dvui.testing.step(ColumnCardFrame.frame);
    const top = try ColumnCardFrame.sizeOf(editor, "Main");
    const bottom = try ColumnCardFrame.sizeOf(editor, "Main/r1");
    try std.testing.expectApproxEqAbs(share, bottom.h / (top.h + bottom.h), 0.03);
    try std.testing.expect(!editor.app.layout.dirty);
}

// -- the place commands that follow the room --------------------------------------------------------
// `layout.place.split` and `layout.place.adaptive` (design note "layout placement", Who asks it,
// item 2), on the forest of a carded Main as a phone or a tablet has it. The picker is drawn after
// the shape, as fizzy's frame does: what a place command asks is carried out there.

const PlaceCase = struct {
    ctx: shim.Ctx,

    fn init(w: f32, h: f32) !PlaceCase {
        var ctx = try shim.init(std.testing.allocator);
        errdefer ctx.deinit(std.testing.allocator);
        const editor = ctx.editor;
        editor.app.gpa = std.testing.allocator;
        ColumnCardFrame.editor = editor;
        try fizzy.Editor.Layout.place_commands.register(&editor.app.host, &editor.app.layout);
        resize(&ctx, w, h);
        _ = try dvui.testing.step(frame);
        try dvui.testing.settle(frame);
        return .{ .ctx = ctx };
    }

    fn deinit(self: *PlaceCase) void {
        const editor = self.ctx.editor;
        editor.app.layout.picker.close(editor.app.gpa);
        editor.app.layout.regions.deinit(editor.app.gpa);
        editor.app.layout.regions_building.deinit(editor.app.gpa);
        editor.app.layout.deinitExtents(editor.app.gpa);
        editor.app.layout.deinitAssignments(editor.app.gpa);
        editor.app.layout.deinitQualified(editor.app.gpa);
        ColumnCardFrame.editor = null;
        self.ctx.deinit(std.testing.allocator);
    }

    fn frame() !dvui.App.Result {
        fizzy.core.anchor.want();
        const result = try ColumnCardFrame.frame();
        const e = ColumnCardFrame.editor.?;
        var layout = fizzy.Editor.Layout.init(&e.app.host, &e.app.layout, e.app.gpa, dvui.currentWindow().arena());
        e.app.layout.picker.draw(&layout);
        return result;
    }

    fn palette() !dvui.App.Result {
        fizzy.core.anchor.want();
        const e = ColumnCardFrame.editor.?;
        e.command_palette.draw(e);
        return .ok;
    }

    fn resize(ctx: *shim.Ctx, w: f32, h: f32) void {
        ctx.t.backend.size = .{ .w = w, .h = h };
        ctx.t.backend.size_pixels = .{ .w = w, .h = h };
    }

    /// Run place command `id` on `place`, as the palette, a tape or an agent does, and draw what
    /// it asked.
    fn run(self: *PlaceCase, id: []const u8, place: []const u8) !void {
        var results: std.heap.ArenaAllocator = .init(std.testing.allocator);
        defer results.deinit();
        var buf: [96]u8 = undefined;
        const args = try std.mem.print(&buf, ".{{ .place = \"{s}\" }}", .{place});
        const out = self.ctx.editor.app.host.callCommand(id, args, results.allocator());
        if (out != .ok) return error.TestUnexpectedResult;
        try dvui.testing.settle(frame);
    }

    fn link(self: *PlaceCase) !fizzy.Editor.Layout.State.SplitTree.Forest.SavedLink {
        const links = self.ctx.editor.app.layout.splits.collectLinks(std.testing.allocator);
        defer std.testing.allocator.free(links);
        try std.testing.expectEqual(@as(usize, 1), links.len);
        return links[0];
    }

    fn leafId(self: *PlaceCase, name: []const u8) !dvui.Id {
        for (self.ctx.editor.app.layout.regions.items) |r| {
            if (std.mem.eql(u8, r.name, name)) return r.id;
        }
        return error.TestExpectedEqual;
    }
};

fn splitsByRoom(w: f32, h: f32, made: []const u8, side: fizzy.Editor.Layout.SplitTree.Side) !void {
    var case = try PlaceCase.init(w, h);
    defer case.deinit();
    try case.run("layout.place.split", "Main");
    const l = try case.link();
    try std.testing.expectEqualStrings(made, l.name);
    try std.testing.expectEqual(side, l.side);
    try std.testing.expect(l.adaptive);
    const old = try ColumnCardFrame.sizeOf(case.ctx.editor, "Main");
    const new = try ColumnCardFrame.sizeOf(case.ctx.editor, made);
    try std.testing.expect(new.w > 40 and new.h > 40);
    switch (side) {
        .bottom => try std.testing.expectApproxEqAbs(old.w, new.w, 1),
        else => try std.testing.expectApproxEqAbs(old.h, new.h, 1),
    }
}

test "layout.place.split stacks a tall place, as the room asks, and the split follows its room" {
    try splitsByRoom(820, 1180, "Main/b1", .bottom);
}

test "layout.place.split puts a wide place's halves side by side, as the room asks" {
    try splitsByRoom(1180, 820, "Main/r1", .right);
}

// A person's split is a point extent. Marked adaptive it keeps the size it is drawn at as its
// share; unmarked while turned it keeps the turn, and is the person's again: a drag is saved.
test "layout.place.adaptive turns a person's split to follow its room and back, nothing moving" {
    var case = try PlaceCase.init(1180, 820);
    defer case.deinit();
    const editor = case.ctx.editor;
    {
        var layout = fizzy.Editor.Layout.init(&editor.app.host, &editor.app.layout, editor.app.gpa, dvui.currentWindow().arena());
        try std.testing.expectEqualStrings("Main/r1", layout.splitOn("Main", .right) orelse return error.TestExpectedEqual);
    }
    try dvui.testing.settle(PlaceCase.frame);
    try std.testing.expect(!(try case.link()).adaptive);
    // Sized by the person, not halved.
    const leaf = try case.leafId("Main/r1");
    dvui.dataSet(null, leaf, "_size", @as(f32, 300));
    dvui.dataSet(null, leaf, "_shown", @as(f32, 300));
    try dvui.testing.settle(PlaceCase.frame);
    const fixed = try ColumnCardFrame.sizeOf(editor, "Main/r1");

    try case.run("layout.place.adaptive", "Main/r1");
    for (0..4) |_| _ = try dvui.testing.step(PlaceCase.frame);
    try std.testing.expect((try case.link()).adaptive);
    try std.testing.expect((try case.link()).share != null);
    try std.testing.expectApproxEqAbs(fixed.w, (try ColumnCardFrame.sizeOf(editor, "Main/r1")).w, 1);

    // Upright: it turns, with the share it had.
    PlaceCase.resize(&case.ctx, 820, 1180);
    for (0..40) |_| _ = try dvui.testing.step(PlaceCase.frame);
    const top = try ColumnCardFrame.sizeOf(editor, "Main");
    const bottom = try ColumnCardFrame.sizeOf(editor, "Main/r1");
    try std.testing.expectApproxEqAbs(top.w, bottom.w, 1);

    // Off while turned: it stays as it is drawn, and that is saved.
    try case.run("layout.place.adaptive", "Main/r1");
    const l = try case.link();
    try std.testing.expect(!l.adaptive);
    try std.testing.expectEqual(fizzy.Editor.Layout.SplitTree.Side.bottom, l.side);
    const still = try ColumnCardFrame.sizeOf(editor, "Main/r1");
    try std.testing.expectApproxEqAbs(bottom.w, still.w, 1);
    try std.testing.expectApproxEqAbs(bottom.h, still.h, 1);

    // The person's again: a drag of it is kept.
    const room = top.h + bottom.h;
    dvui.dataSet(null, leaf, "_size", room / 3);
    dvui.dataSet(null, leaf, "_shown", room / 3);
    for (0..4) |_| _ = try dvui.testing.step(PlaceCase.frame);
    try std.testing.expectApproxEqAbs(room / 3, editor.app.layout.extent("Main/r1", 0), 1);
}

test "layout.place.adaptive off while the split slides shut to turn opens it back where it was" {
    var case = try PlaceCase.init(1180, 820);
    defer case.deinit();
    const editor = case.ctx.editor;
    try case.run("layout.place.split", "Main");
    try std.testing.expectEqualStrings("Main/r1", (try case.link()).name);
    const before = try ColumnCardFrame.sizeOf(editor, "Main/r1");

    PlaceCase.resize(&case.ctx, 820, 1180);
    const leaf = try case.leafId("Main/r1");
    for (0..10) |_| {
        _ = try dvui.testing.step(PlaceCase.frame);
        if (dvui.dataGet(null, leaf, "_fold", bool) orelse false) break;
    } else return error.TestExpectedEqual;

    try case.run("layout.place.adaptive", "Main/r1");
    const l = try case.link();
    try std.testing.expect(!l.adaptive);
    try std.testing.expectEqual(fizzy.Editor.Layout.SplitTree.Side.right, l.side);
    const main = try ColumnCardFrame.sizeOf(editor, "Main");
    const after = try ColumnCardFrame.sizeOf(editor, "Main/r1");
    try std.testing.expectApproxEqAbs(before.w, after.w, 2);
    try std.testing.expectApproxEqAbs(main.h, after.h, 1);
}

test "layout.place.adaptive is refused where the shape declared the split, and offered on a split made since" {
    var case = try PlaceCase.init(1180, 820);
    defer case.deinit();
    const editor = case.ctx.editor;
    var results: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer results.deinit();
    try std.testing.expect(editor.app.host.callCommand("layout.place.adaptive", ".{ .place = \"Main\" }", results.allocator()) == .failed);

    // The menu: Split offered, the toggle not until there is a split of the person's to turn.
    editor.app.layout.picker.open(editor.app.gpa, "Main", null);
    try dvui.testing.settle(PlaceCase.frame);
    try std.testing.expect(dvui.tagGet("region.menu.split:Main") != null);
    try std.testing.expect(dvui.tagGet("region.menu.adaptive:Main") == null);
    editor.app.layout.picker.close(editor.app.gpa);

    try case.run("layout.place.splitRight", "Main");
    editor.app.layout.picker.open(editor.app.gpa, "Main", null);
    try dvui.testing.settle(PlaceCase.frame);
    try dvui.testing.moveTo("region.menu.adaptive:Main");
    try dvui.testing.click(.left);
    try dvui.testing.settle(PlaceCase.frame);
    try std.testing.expect((try case.link()).adaptive);
    // A toggle: the menu stays open on the place it changed.
    try std.testing.expect(editor.app.layout.picker.is_open);
}

test "the palette lists the place commands that follow the room" {
    var case = try PlaceCase.init(1180, 820);
    defer case.deinit();
    const editor = case.ctx.editor;
    editor.command_palette.show(.commands);
    try dvui.testing.settle(PlaceCase.palette);
    try dvui.testing.writeText("Place: Split");
    try dvui.testing.settle(PlaceCase.palette);
    try std.testing.expect(dvui.tagGet("fizzy.palette.row:layout.place.split") != null);
    try std.testing.expect(dvui.tagGet("fizzy.palette.row:layout.place.adaptive") != null);
}

fn mobilePlaceFrame() !dvui.App.Result {
    const result = try MobileFrame.frame();
    const e = MobileFrame.editor.?;
    var layout = fizzy.Editor.Layout.init(&e.app.host, &e.app.layout, e.app.gpa, dvui.currentWindow().arena());
    e.app.layout.picker.draw(&layout);
    return result;
}

test "the phone's split button makes two groups, stacked in portrait" {
    var ctx = try shim.init(std.testing.allocator);
    defer ctx.deinit(std.testing.allocator);
    const editor = ctx.editor;
    try mobileCase(&ctx);
    defer fizzy.core.platform.cached_form_factor = .desktop;
    defer MobileFrame.editor = null;
    defer editor.app.layout.regions.deinit(editor.app.gpa);
    defer editor.app.layout.regions_building.deinit(editor.app.gpa);
    defer editor.app.layout.deinitExtents(editor.app.gpa);
    defer editor.app.layout.deinitQualified(editor.app.gpa);
    defer editor.app.layout.deinitAssignments(editor.app.gpa);
    try fizzy.Editor.Layout.place_commands.register(&editor.app.host, &editor.app.layout);
    PlaceCase.resize(&ctx, 390, 844);
    try dvui.testing.settle(mobilePlaceFrame);

    try tapAt((dvui.tagGet("fizzy.mobile.split") orelse return error.TestExpectedEqual).rect, mobilePlaceFrame);
    const links = editor.app.layout.splits.collectLinks(std.testing.allocator);
    defer std.testing.allocator.free(links);
    try std.testing.expectEqual(@as(usize, 1), links.len);
    try std.testing.expectEqualStrings("Main/b1", links[0].name);
    try std.testing.expect(links[0].adaptive);
}

test "an adaptive split saved without a share loads with the ratio absent" {
    var ctx = try shim.init(std.testing.allocator);
    defer ctx.deinit(std.testing.allocator);
    const gpa = std.testing.allocator;
    const editor = ctx.editor;
    editor.app.gpa = gpa;
    defer editor.app.layout.deinitExtents(gpa);
    defer editor.app.layout.deinitQualified(gpa);

    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    var diagnostics: std.zon.parse.Diagnostics = undefined;
    const saved = try std.zon.parse.fromSlice([]fizzy.backend.SavedRegion, .{
        .gpa = gpa,
        .arena = arena.allocator(),
        .source = ".{.{ .name = \"Main/r1\", .parent = \"Main\", .from = \"right\", .extent = 590, .adaptive = true }}",
        .diagnostics = &diagnostics,
        .ignore_unknown_fields = true,
    });
    try std.testing.expectEqual(@as(?f32, null), saved[0].share);
    editor.applySavedRegions(saved);
    const links = editor.app.layout.splits.collectLinks(gpa);
    defer gpa.free(links);
    try std.testing.expectEqual(@as(usize, 1), links.len);
    try std.testing.expect(links[0].adaptive);
    try std.testing.expectEqual(@as(?f32, null), links[0].share);
    try std.testing.expectEqual(@as(f32, 590), editor.app.layout.extent("Main/r1", 0));
}

/// Main | (Main/r1 over Main/r1/b1) in fizzy's split forest, each holding one view. Main/r1 is two
/// things at once: the half Main's split minted, and the half its own split kept.
const NestedSplitCase = struct {
    ctx: shim.Ctx,

    fn init() !NestedSplitCase {
        var ctx = try shim.init(std.testing.allocator);
        errdefer ctx.deinit(std.testing.allocator);
        const editor = ctx.editor;
        editor.app.gpa = std.testing.allocator;
        ColumnCardFrame.editor = editor;
        const draw = struct {
            fn f(_: ?*anyopaque) anyerror!dvui.App.Result {
                return .ok;
            }
        }.f;
        for ([_][]const u8{ "test.left", "test.top", "test.bottom", "test.right" }) |id| {
            try editor.app.host.registerSurface(.{ .id = id, .title = id, .keywords = fizzy.sdk.keywords.ide.main, .draw = draw });
        }
        try dvui.testing.settle(ColumnCardFrame.frame);
        try editor.app.layout.assign(editor.app.gpa, "Main", &.{"test.left"});
        try split(editor, "Main", .right, "Main/r1", "test.top");
        try split(editor, "Main/r1", .bottom, "Main/r1/b1", "test.bottom");
        return .{ .ctx = ctx };
    }

    fn split(editor: *fizzy.Editor, name: []const u8, side: fizzy.Editor.Layout.SplitTree.Side, want: []const u8, view: []const u8) !void {
        {
            var layout = fizzy.Editor.Layout.init(&editor.app.host, &editor.app.layout, editor.app.gpa, dvui.currentWindow().arena());
            try std.testing.expectEqualStrings(want, layout.splitOn(name, side) orelse return error.TestExpectedEqual);
        }
        try editor.app.layout.assign(editor.app.gpa, want, &.{view});
        try dvui.testing.settle(ColumnCardFrame.frame);
    }

    fn deinit(self: *NestedSplitCase) void {
        const editor = self.ctx.editor;
        editor.app.layout.regions.deinit(editor.app.gpa);
        editor.app.layout.regions_building.deinit(editor.app.gpa);
        editor.app.layout.deinitExtents(editor.app.gpa);
        editor.app.layout.deinitAssignments(editor.app.gpa);
        editor.app.layout.deinitQualified(editor.app.gpa);
        ColumnCardFrame.editor = null;
        self.ctx.deinit(std.testing.allocator);
    }

    fn trash(self: *NestedSplitCase, name: []const u8) !void {
        const editor = self.ctx.editor;
        var layout = fizzy.Editor.Layout.init(&editor.app.host, &editor.app.layout, editor.app.gpa, dvui.currentWindow().arena());
        fizzy.Editor.Layout.ViewDrag.place(&layout, name, name, .remove);
        try dvui.testing.settle(ColumnCardFrame.frame);
        try dvui.testing.settle(ColumnCardFrame.frame);
    }
};

test "split: emptying the half that was split again closes only that half" {
    var case = try NestedSplitCase.init();
    defer case.deinit();
    const state = &case.ctx.editor.app.layout;
    const column = (try ColumnCardFrame.sizeOf(case.ctx.editor, "Main/r1")).w;

    try case.trash("Main/r1");

    // The column stays, one place again under the name Main's split knows, holding what its
    // other half held — the same merge as emptying a split's origin anywhere else.
    try std.testing.expectEqualStrings("Main", state.splits.siblingLeaf("Main/r1") orelse return error.TestExpectedEqual);
    try std.testing.expect(state.splits.rootOf("Main/r1/b1") == null);
    const kept = state.assignment("Main/r1") orelse return error.TestExpectedEqual;
    try std.testing.expectEqual(@as(usize, 1), kept.len);
    try std.testing.expectEqualStrings("test.bottom", kept[0]);
    try std.testing.expectApproxEqAbs(column, (try ColumnCardFrame.sizeOf(case.ctx.editor, "Main/r1")).w, 1);

    const links = state.splits.collectLinks(std.testing.allocator);
    defer std.testing.allocator.free(links);
    try std.testing.expectEqual(@as(usize, 1), links.len);
    try std.testing.expectEqualStrings("Main/r1", links[0].name);
}

test "split: emptying the half that was split again stays when its other half is split too" {
    var case = try NestedSplitCase.init();
    defer case.deinit();
    const editor = case.ctx.editor;
    try NestedSplitCase.split(editor, "Main/r1/b1", .right, "Main/r1/b1/r1", "test.right");

    try case.trash("Main/r1");

    // No one place to merge into: the column and every split in it stay, Main/r1 empty.
    const leaves = editor.app.layout.splits.leavesUnder(dvui.currentWindow().arena(), "Main");
    try std.testing.expectEqual(@as(usize, 4), leaves.len);
    const kept = editor.app.layout.assignment("Main/r1") orelse return error.TestExpectedEqual;
    try std.testing.expectEqual(@as(usize, 0), kept.len);
    try std.testing.expectEqualStrings("test.bottom", editor.app.layout.assignment("Main/r1/b1").?[0]);
}

test "split: a column shut by its sash goes only once every place in it is empty" {
    var case = try NestedSplitCase.init();
    defer case.deinit();
    const editor = case.ctx.editor;
    const state = &editor.app.layout;
    // The branch registers before the half that kept its name, so the first `Main/r1` is the
    // column: the box its parent's sash sizes.
    const column = for (state.regions.items) |r| {
        if (std.mem.eql(u8, r.name, "Main/r1")) break r.id;
    } else return error.TestExpectedEqual;

    // Shut with a view still in its bottom half: the column stays, and so does every place in it.
    try state.assign(editor.app.gpa, "Main/r1", &.{});
    fizzy.core.widgets.Split.close(column);
    try dvui.testing.settle(ColumnCardFrame.frame);
    try dvui.testing.settle(ColumnCardFrame.frame);
    try std.testing.expectEqual(@as(usize, 3), state.splits.leavesUnder(dvui.currentWindow().arena(), "Main").len);
    try std.testing.expectEqualStrings("test.bottom", state.assignment("Main/r1/b1").?[0]);

    // Nothing left in it, the whole column goes, and nothing it held is left behind.
    try state.assign(editor.app.gpa, "Main/r1/b1", &.{});
    try dvui.testing.settle(ColumnCardFrame.frame);
    try dvui.testing.settle(ColumnCardFrame.frame);
    try std.testing.expect(state.splits.root("Main") == null);
    try std.testing.expect(state.assignment("Main/r1/b1") == null);
    try std.testing.expectEqual(@as(f32, -1), state.extent("Main/r1/b1", -1));
}

test "a view-drag split opens on the dropped edge" {
    var ctx = try shim.init(std.testing.allocator);
    defer ctx.deinit(std.testing.allocator);

    const editor = ctx.editor;
    editor.app.gpa = std.testing.allocator;
    defer editor.app.layout.regions.deinit(editor.app.gpa);
    defer editor.app.layout.regions_building.deinit(editor.app.gpa);
    defer editor.app.layout.deinitExtents(editor.app.gpa);
    defer editor.app.layout.deinitAssignments(editor.app.gpa);
    defer editor.app.layout.deinitQualified(editor.app.gpa);

    EndlessFrame.editor = editor;
    defer EndlessFrame.editor = null;

    try dvui.testing.settle(EndlessFrame.frame);
    {
        var layout = fizzy.Editor.Layout.init(&editor.app.host, &editor.app.layout, editor.app.gpa, dvui.currentWindow().arena());
        try std.testing.expect(layout.splitOn("Center", .left) != null);
    }
    try dvui.testing.settle(EndlessFrame.frame);

    try std.testing.expect(editor.app.layout.dock.?.contains("Center/l1"));
    try std.testing.expect(editor.app.layout.isMinted("Center/l1"));
}

test "removing a created place drops it from the tree" {
    var ctx = try shim.init(std.testing.allocator);
    defer ctx.deinit(std.testing.allocator);

    const editor = ctx.editor;
    editor.app.gpa = std.testing.allocator;
    defer editor.app.layout.regions.deinit(editor.app.gpa);
    defer editor.app.layout.regions_building.deinit(editor.app.gpa);
    defer editor.app.layout.deinitExtents(editor.app.gpa);
    defer editor.app.layout.deinitAssignments(editor.app.gpa);
    defer editor.app.layout.deinitQualified(editor.app.gpa);

    EndlessFrame.editor = editor;
    defer EndlessFrame.editor = null;

    try dvui.testing.settle(EndlessFrame.frame);
    {
        var layout = fizzy.Editor.Layout.init(&editor.app.host, &editor.app.layout, editor.app.gpa, dvui.currentWindow().arena());
        layout.splitNamed("Center", .horizontal);
    }
    try dvui.testing.settle(EndlessFrame.frame);

    var created_idx: ?fizzy.core.widgets.DockLayout.NodeIndex = null;
    if (editor.app.layout.dock) |*dock| created_idx = dock.findPanel("Center/r1");
    try std.testing.expect(created_idx != null);

    editor.app.layout.assign(editor.app.gpa, "Center/r1", &.{}) catch unreachable;
    {
        const dock = &(editor.app.layout.dock orelse return error.TestExpectedEqual);
        dock.animated = false;
        dock.closeLeaf(created_idx.?);
        dock.animated = true;
    }
    try dvui.testing.settle(EndlessFrame.frame);

    try std.testing.expect(!(editor.app.layout.dock orelse return error.TestExpectedEqual).contains("Center/r1"));
    try std.testing.expect((editor.app.layout.dock orelse return error.TestExpectedEqual).contains("Center"));
}

test "a split's last view dropped on the other half's middle joins the two into one place" {
    var ctx = try shim.init(std.testing.allocator);
    defer ctx.deinit(std.testing.allocator);

    const editor = ctx.editor;
    editor.app.gpa = std.testing.allocator;
    defer editor.app.layout.regions.deinit(editor.app.gpa);
    defer editor.app.layout.regions_building.deinit(editor.app.gpa);
    defer editor.app.layout.deinitExtents(editor.app.gpa);
    defer editor.app.layout.deinitAssignments(editor.app.gpa);
    defer editor.app.layout.deinitQualified(editor.app.gpa);

    EndlessFrame.editor = editor;
    defer EndlessFrame.editor = null;

    const draw = struct {
        fn f(_: ?*anyopaque) anyerror!dvui.App.Result {
            return .ok;
        }
    }.f;
    try editor.app.host.registerSurface(.{ .id = "test.view", .title = "View", .keywords = fizzy.sdk.keywords.ide.main, .draw = draw });
    try editor.app.host.registerSurface(.{ .id = "test.other", .title = "Other", .keywords = fizzy.sdk.keywords.ide.main, .draw = draw });

    try dvui.testing.settle(EndlessFrame.frame);
    try editor.app.layout.assign(editor.app.gpa, "Center", &.{"test.view"});
    const made = blk: {
        var layout = fizzy.Editor.Layout.init(&editor.app.host, &editor.app.layout, editor.app.gpa, dvui.currentWindow().arena());
        break :blk layout.splitOn("Center", .right) orelse return error.TestExpectedEqual;
    };
    const made_name = try std.testing.allocator.dupe(u8, made);
    defer std.testing.allocator.free(made_name);
    try editor.app.layout.assign(editor.app.gpa, made_name, &.{"test.other"});
    try dvui.testing.settle(EndlessFrame.frame);
    try std.testing.expect(editor.app.layout.joinable("Center", made_name) != null);

    {
        var layout = fizzy.Editor.Layout.init(&editor.app.host, &editor.app.layout, editor.app.gpa, dvui.currentWindow().arena());
        layout.placeVisible("Center", made_name, .swap);
    }
    try dvui.testing.settle(EndlessFrame.frame);
    try dvui.testing.settle(EndlessFrame.frame);

    // One place, holding both — the one dropped on first, the dragged one after — as tabs.
    const joined = editor.app.layout.assignment("Center") orelse return error.TestExpectedEqual;
    try std.testing.expectEqual(@as(usize, 2), joined.len);
    try std.testing.expectEqualStrings("test.other", joined[0]);
    try std.testing.expectEqualStrings("test.view", joined[1]);
    // The half the split made is gone.
    try std.testing.expect(!editor.app.layout.isMinted(made_name));
}

/// The endless example's Center split right into `Center` and its minted half, holding
/// `center` and `half` (empty lists for an empty place). For the merge rules below.
const SplitCase = struct {
    ctx: shim.Ctx,
    half: []u8,

    fn init(center: []const []const u8, half: []const []const u8) !SplitCase {
        var ctx = try shim.init(std.testing.allocator);
        errdefer ctx.deinit(std.testing.allocator);
        const editor = ctx.editor;
        editor.app.gpa = std.testing.allocator;
        EndlessFrame.editor = editor;
        const draw = struct {
            fn f(_: ?*anyopaque) anyerror!dvui.App.Result {
                return .ok;
            }
        }.f;
        try editor.app.host.registerSurface(.{ .id = "test.view", .title = "View", .keywords = fizzy.sdk.keywords.ide.main, .draw = draw });
        try editor.app.host.registerSurface(.{ .id = "test.other", .title = "Other", .keywords = fizzy.sdk.keywords.ide.main, .draw = draw });
        try dvui.testing.settle(EndlessFrame.frame);
        try editor.app.layout.assign(editor.app.gpa, "Center", center);
        const made = blk: {
            var layout = fizzy.Editor.Layout.init(&editor.app.host, &editor.app.layout, editor.app.gpa, dvui.currentWindow().arena());
            break :blk layout.splitOn("Center", .right) orelse return error.TestExpectedEqual;
        };
        const name = try std.testing.allocator.dupe(u8, made);
        try editor.app.layout.assign(editor.app.gpa, name, half);
        try dvui.testing.settle(EndlessFrame.frame);
        return .{ .ctx = ctx, .half = name };
    }

    fn deinit(self: *SplitCase) void {
        const editor = self.ctx.editor;
        editor.app.layout.regions.deinit(editor.app.gpa);
        editor.app.layout.regions_building.deinit(editor.app.gpa);
        editor.app.layout.deinitExtents(editor.app.gpa);
        editor.app.layout.deinitAssignments(editor.app.gpa);
        editor.app.layout.deinitQualified(editor.app.gpa);
        EndlessFrame.editor = null;
        std.testing.allocator.free(self.half);
        self.ctx.deinit(std.testing.allocator);
    }

    fn place(self: *SplitCase, source: []const u8, dest: []const u8, kind: fizzy.Editor.Layout.Drop.Kind) !void {
        const editor = self.ctx.editor;
        var layout = fizzy.Editor.Layout.init(&editor.app.host, &editor.app.layout, editor.app.gpa, dvui.currentWindow().arena());
        fizzy.Editor.Layout.ViewDrag.place(&layout, source, dest, kind);
        try dvui.testing.settle(EndlessFrame.frame);
        try dvui.testing.settle(EndlessFrame.frame);
    }

    fn holds(self: *SplitCase, name: []const u8) []const []const u8 {
        return self.ctx.editor.app.layout.assignment(name) orelse &.{};
    }
};

test "split: only a half of a split the user made can go" {
    var case = try SplitCase.init(&.{"test.view"}, &.{"test.other"});
    defer case.deinit();
    const state = &case.ctx.editor.app.layout;
    try std.testing.expect(state.userSplitPart("Center"));
    try std.testing.expect(state.userSplitPart(case.half));
    // Joined again, the one place left is the shape's own, and stays.
    try case.place("Center", "Center", .remove);
    try std.testing.expect(!state.userSplitPart("Center"));
}

test "split: the trash is offered out of a place of several, not out of a lone default place" {
    var case = try SplitCase.init(&.{"test.view"}, &.{"test.other"});
    defer case.deinit();
    const editor = case.ctx.editor;
    const VD = fizzy.Editor.Layout.ViewDrag;
    // Joined back, Center is the shape's one place again, showing one view.
    try case.place("Center", "Center", .remove);
    var layout = fizzy.Editor.Layout.init(&editor.app.host, &editor.app.layout, editor.app.gpa, dvui.currentWindow().arena());
    defer editor.app.layout.view_drag.discard(editor.app.gpa);
    VD.begin(&layout, "Center", .{ .w = 100, .h = 100 }, .{ .w = 100, .h = 100 });
    try std.testing.expect(!VD.removable(&layout));
    editor.app.layout.view_drag.discard(editor.app.gpa);
    // Holding several, the trash takes just the view carried.
    try editor.app.layout.assign(editor.app.gpa, "Center", &.{ "test.view", "test.other" });
    try dvui.testing.settle(EndlessFrame.frame);
    var layout2 = fizzy.Editor.Layout.init(&editor.app.host, &editor.app.layout, editor.app.gpa, dvui.currentWindow().arena());
    VD.begin(&layout2, "Center", .{ .w = 100, .h = 100 }, .{ .w = 100, .h = 100 });
    try std.testing.expect(VD.removable(&layout2));
}

test "drag: a strip whose place cannot take the view is not a chooser for it" {
    var case = try SplitCase.init(&.{"test.view"}, &.{"test.other"});
    defer case.deinit();
    const editor = case.ctx.editor;
    const VD = fizzy.Editor.Layout.ViewDrag;
    var layout = fizzy.Editor.Layout.init(&editor.app.host, &editor.app.layout, editor.app.gpa, dvui.currentWindow().arena());
    defer editor.app.layout.view_drag.discard(editor.app.gpa);
    VD.begin(&layout, "Center", .{ .w = 100, .h = 100 }, .{ .w = 100, .h = 100 });
    const strip: dvui.Rect.Physical = .{ .x = 0, .y = 0, .w = 200, .h = 30 };
    // A strip of a place the drag mapped no target for (a document pane, say) is passed over...
    VD.offerChooser(&layout, "Pane 9", strip, true, null);
    try std.testing.expect(VD.chooserAt(&editor.app.layout, .{ .x = 10, .y = 10 }) == null);
    // ...and the place the view came out of always reads as one.
    VD.offerChooser(&layout, "Center", strip, false, null);
    const o = VD.chooserAt(&editor.app.layout, .{ .x = 10, .y = 10 }) orelse return error.TestExpectedEqual;
    try std.testing.expectEqualStrings("Center", o.name);
}

test "split: trashing the last view of the half that was split merges the other half into it" {
    var case = try SplitCase.init(&.{"test.view"}, &.{"test.other"});
    defer case.deinit();
    try case.place("Center", "Center", .remove);
    // One place again, the shape's, holding what the other half held.
    try std.testing.expect(!case.ctx.editor.app.layout.isMinted(case.half));
    try std.testing.expectEqual(@as(usize, 1), case.holds("Center").len);
    try std.testing.expectEqualStrings("test.other", case.holds("Center")[0]);
}

test "split: trashing the last view of the minted half closes it" {
    var case = try SplitCase.init(&.{"test.view"}, &.{"test.other"});
    defer case.deinit();
    try case.place(case.half, case.half, .remove);
    try std.testing.expect(!case.ctx.editor.app.layout.isMinted(case.half));
    try std.testing.expectEqualStrings("test.view", case.holds("Center")[0]);
}

test "split: an empty half dropped in a place's middle goes, merging into the other" {
    // The minted half, empty, onto the one with a view.
    {
        var case = try SplitCase.init(&.{"test.view"}, &.{});
        defer case.deinit();
        try case.place(case.half, "Center", .swap);
        try std.testing.expect(!case.ctx.editor.app.layout.isMinted(case.half));
        try std.testing.expectEqualStrings("test.view", case.holds("Center")[0]);
    }
    // The half that was split, empty, onto the minted one: one place, holding its view.
    {
        var case = try SplitCase.init(&.{}, &.{"test.other"});
        defer case.deinit();
        try case.place("Center", case.half, .swap);
        try std.testing.expect(!case.ctx.editor.app.layout.isMinted(case.half));
        try std.testing.expectEqualStrings("test.other", case.holds("Center")[0]);
    }
    // Two empty halves: one consumes the other, one empty place left.
    {
        var case = try SplitCase.init(&.{}, &.{});
        defer case.deinit();
        try case.place(case.half, "Center", .swap);
        try std.testing.expect(!case.ctx.editor.app.layout.isMinted(case.half));
        try std.testing.expectEqual(@as(usize, 0), case.holds("Center").len);
    }
}

test "split: an empty half dropped on a place's edge moves there" {
    var case = try SplitCase.init(&.{"test.view"}, &.{});
    defer case.deinit();
    try case.place(case.half, "Center", .{ .split = .left });
    const state = &case.ctx.editor.app.layout;
    // Gone from the right, opened on the left: still one empty half beside Center.
    try std.testing.expect(!state.isMinted(case.half));
    const moved = state.siblingLeaf("Center") orelse return error.TestExpectedEqual;
    try std.testing.expect(state.isMinted(moved));
    try std.testing.expectEqual(@as(usize, 0), case.holds(moved).len);
    try std.testing.expectEqualStrings("test.view", case.holds("Center")[0]);
}

test "a view-drag from a multi place moves only the visible surface" {
    var ctx = try shim.init(std.testing.allocator);
    defer ctx.deinit(std.testing.allocator);

    const editor = ctx.editor;
    editor.app.gpa = std.testing.allocator;
    defer editor.app.layout.regions.deinit(editor.app.gpa);
    defer editor.app.layout.regions_building.deinit(editor.app.gpa);
    defer editor.app.layout.deinitExtents(editor.app.gpa);
    defer editor.app.layout.deinitAssignments(editor.app.gpa);
    defer editor.app.layout.deinitQualified(editor.app.gpa);

    EndlessFrame.editor = editor;
    defer EndlessFrame.editor = null;

    const draw = struct {
        fn f(_: ?*anyopaque) anyerror!dvui.App.Result {
            return .ok;
        }
    }.f;
    try editor.app.host.registerSurface(.{
        .id = "test.one",
        .title = "One",
        .keywords = fizzy.sdk.keywords.ide.main,
        .draw = draw,
    });
    try editor.app.host.registerSurface(.{
        .id = "test.two",
        .title = "Two",
        .keywords = fizzy.sdk.keywords.ide.main,
        .draw = draw,
    });

    try dvui.testing.settle(EndlessFrame.frame);
    try editor.app.layout.assign(editor.app.gpa, "Center", &.{ "test.one", "test.two" });
    {
        var layout = fizzy.Editor.Layout.init(&editor.app.host, &editor.app.layout, editor.app.gpa, dvui.currentWindow().arena());
        try std.testing.expect(layout.splitOn("Center", .right) != null);
    }
    try dvui.testing.settle(EndlessFrame.frame);

    var center: ?fizzy.Editor.Layout.Region = null;
    for (editor.app.layout.regions.items) |r| {
        if (std.mem.eql(u8, r.name, "Center")) center = r;
    }
    var layout = fizzy.Editor.Layout.init(&editor.app.host, &editor.app.layout, editor.app.gpa, dvui.currentWindow().arena());
    layout.selectIn(&(center orelse return error.TestExpectedEqual), "test.one");
    layout.placeVisible("Center", "Center/r1", .swap);
    try dvui.testing.settle(EndlessFrame.frame);

    const dest = editor.app.layout.assignment("Center/r1") orelse return error.TestExpectedEqual;
    try std.testing.expectEqual(@as(usize, 1), dest.len);
    try std.testing.expectEqualStrings("test.one", dest[0]);
    const source = editor.app.layout.assignment("Center") orelse return error.TestExpectedEqual;
    try std.testing.expectEqual(@as(usize, 1), source.len);
    try std.testing.expectEqualStrings("test.two", source[0]);
    // Not a join: the place it left kept a view, so both halves stay.
    try std.testing.expect(editor.app.layout.isMinted("Center/r1"));
}

// A place of several draws its strip, then the selected view in a box of its own. Drawn into the
// place beside the strip, the view was laid out as though the strip were not there, and the swap
// blurred over the strip; the bottom panel had always kept them apart.
const MultiProbe = struct {
    var one_top: f32 = 0;
    var two_top: f32 = 0;

    fn one(_: ?*anyopaque) anyerror!dvui.App.Result {
        one_top = dvui.parentGet().data().rectScale().r.y;
        return .ok;
    }
    fn two(_: ?*anyopaque) anyerror!dvui.App.Result {
        two_top = dvui.parentGet().data().rectScale().r.y;
        return .ok;
    }
};

fn multiCenter(editor: *fizzy.Editor) !fizzy.Editor.Layout.Region {
    try editor.app.host.registerSurface(.{ .id = "test.one", .title = "One", .keywords = fizzy.sdk.keywords.ide.main, .draw = MultiProbe.one });
    try editor.app.host.registerSurface(.{ .id = "test.two", .title = "Two", .keywords = fizzy.sdk.keywords.ide.main, .draw = MultiProbe.two });
    try dvui.testing.settle(EndlessFrame.frame);
    try editor.app.layout.assign(editor.app.gpa, "Center", &.{ "test.one", "test.two" });
    try dvui.testing.settle(EndlessFrame.frame);
    for (editor.app.layout.regions.items) |r| {
        if (std.mem.eql(u8, r.name, "Center")) return r;
    }
    return error.TestExpectedEqual;
}

test "a Multiple place draws its view beneath its tab strip, not over it" {
    var ctx = try shim.init(std.testing.allocator);
    defer ctx.deinit(std.testing.allocator);
    const editor = ctx.editor;
    editor.app.gpa = std.testing.allocator;
    defer editor.app.layout.regions.deinit(editor.app.gpa);
    defer editor.app.layout.regions_building.deinit(editor.app.gpa);
    defer editor.app.layout.deinitExtents(editor.app.gpa);
    defer editor.app.layout.deinitAssignments(editor.app.gpa);
    defer editor.app.layout.deinitQualified(editor.app.gpa);
    EndlessFrame.editor = editor;
    defer EndlessFrame.editor = null;

    const center = try multiCenter(editor);
    // The first view is showing, and starts below the top of the place: the strip is above it.
    try std.testing.expect(MultiProbe.one_top > center.bounds.y + 8);
}

test "dragging a tab along a place's strip reorders its views" {
    var ctx = try shim.init(std.testing.allocator);
    defer ctx.deinit(std.testing.allocator);
    const editor = ctx.editor;
    editor.app.gpa = std.testing.allocator;
    defer editor.app.layout.regions.deinit(editor.app.gpa);
    defer editor.app.layout.regions_building.deinit(editor.app.gpa);
    defer editor.app.layout.deinitExtents(editor.app.gpa);
    defer editor.app.layout.deinitAssignments(editor.app.gpa);
    defer editor.app.layout.deinitQualified(editor.app.gpa);
    EndlessFrame.editor = editor;
    defer EndlessFrame.editor = null;

    const center = try multiCenter(editor);
    const cw = dvui.currentWindow();
    // The strip is the band above the view.
    const y = center.bounds.y + (MultiProbe.one_top - center.bounds.y) / 2;
    const x0 = center.bounds.x + 16;
    _ = try cw.addEventMouseMotion(.{ .pt = .{ .x = x0, .y = y } });
    _ = try cw.addEventMouseButton(.left, .press);
    _ = try dvui.testing.step(EndlessFrame.frame);
    // Past the second tab, still on the strip (it is only as wide as its tabs).
    var x = x0;
    while (x < x0 + 170) : (x += 10) {
        _ = try cw.addEventMouseMotion(.{ .pt = .{ .x = x, .y = y } });
        _ = try dvui.testing.step(EndlessFrame.frame);
    }
    _ = try cw.addEventMouseButton(.left, .release);
    try dvui.testing.settle(EndlessFrame.frame);

    const order = editor.app.layout.assignment("Center") orelse return error.TestExpectedEqual;
    try std.testing.expectEqual(@as(usize, 2), order.len);
    try std.testing.expectEqualStrings("test.two", order[0]);
    try std.testing.expectEqualStrings("test.one", order[1]);
    try std.testing.expect(!editor.app.layout.view_drag.active());
}

// A place its keywords fill is reordered by an order, not an assignment: writing its list down
// would freeze it, and a view registered later would never appear there.
test "reordering a keyword place keeps an order, and later views still arrive" {
    var ctx = try shim.init(std.testing.allocator);
    defer ctx.deinit(std.testing.allocator);
    const editor = ctx.editor;
    editor.app.gpa = std.testing.allocator;
    defer editor.app.layout.regions.deinit(editor.app.gpa);
    defer editor.app.layout.regions_building.deinit(editor.app.gpa);
    defer editor.app.layout.deinitExtents(editor.app.gpa);
    defer editor.app.layout.deinitAssignments(editor.app.gpa);
    defer editor.app.layout.deinitQualified(editor.app.gpa);
    EndlessFrame.editor = editor;
    defer EndlessFrame.editor = null;

    try editor.app.host.registerSurface(.{ .id = "test.one", .title = "One", .keywords = &.{"slot"}, .draw = MultiProbe.one });
    try editor.app.host.registerSurface(.{ .id = "test.two", .title = "Two", .keywords = &.{"slot"}, .draw = MultiProbe.two });
    try dvui.testing.settle(EndlessFrame.frame);
    try dvui.testing.settle(EndlessFrame.frame);
    var center: fizzy.Editor.Layout.Region = undefined;
    for (editor.app.layout.regions.items) |r| {
        if (std.mem.eql(u8, r.name, "Center")) center = r;
    }
    // The endless shape's Center takes `slot`: both views are here by keyword, nothing assigned.
    try std.testing.expect(editor.app.layout.assignment("Center") == null);

    const cw = dvui.currentWindow();
    const y = center.bounds.y + (MultiProbe.one_top - center.bounds.y) / 2;
    const x0 = center.bounds.x + 16;
    _ = try cw.addEventMouseMotion(.{ .pt = .{ .x = x0, .y = y } });
    _ = try cw.addEventMouseButton(.left, .press);
    _ = try dvui.testing.step(EndlessFrame.frame);
    var x = x0;
    while (x < x0 + 170) : (x += 10) {
        _ = try cw.addEventMouseMotion(.{ .pt = .{ .x = x, .y = y } });
        _ = try dvui.testing.step(EndlessFrame.frame);
    }
    _ = try cw.addEventMouseButton(.left, .release);
    try dvui.testing.settle(EndlessFrame.frame);

    try std.testing.expect(editor.app.layout.assignment("Center") == null);
    const order = editor.app.layout.order("Center") orelse return error.TestExpectedEqual;
    try std.testing.expectEqualStrings("test.two", order[0]);
    try std.testing.expectEqualStrings("test.one", order[1]);

    // A view that arrives later still lands here, after the ones the user ordered.
    const draw = struct {
        fn f(_: ?*anyopaque) anyerror!dvui.App.Result {
            return .ok;
        }
    }.f;
    try editor.app.host.registerSurface(.{ .id = "test.three", .title = "Three", .keywords = &.{"slot"}, .draw = draw });
    try dvui.testing.settle(EndlessFrame.frame);
    for (editor.app.layout.regions.items) |r| {
        if (std.mem.eql(u8, r.name, "Center")) center = r;
    }
    var layout = fizzy.Editor.Layout.init(&editor.app.host, &editor.app.layout, editor.app.gpa, dvui.currentWindow().arena());
    const shown = layout.matchingIn(&center);
    try std.testing.expectEqual(@as(usize, 3), shown.len);
    try std.testing.expectEqualStrings("test.two", shown[0].id);
    try std.testing.expectEqualStrings("test.one", shown[1].id);
    try std.testing.expectEqualStrings("test.three", shown[2].id);
}

// A rail: a vertical chooser beside its place, drawn before the place is declared — the icon
// rail's arrangement. The same reorder as a strip, along the other axis.
const RailFrame = struct {
    var editor: ?*fizzy.Editor = null;
    var first_item: dvui.Rect.Physical = .{};

    fn frame() anyerror!dvui.App.Result {
        const e = editor.?;
        var layout = fizzy.Editor.Layout.init(&e.app.host, &e.app.layout, e.app.gpa, dvui.currentWindow().arena());
        var row = dvui.box(@src(), .{ .dir = .horizontal }, .{ .expand = .both });
        defer row.deinit();
        {
            var rail = fizzy.Editor.Layout.Chooser.init(@src(), &layout, .{ .keywords = &.{"slot"} }, .{
                .dir = .vertical,
                .outer = .{ .expand = .vertical, .min_size_content = .{ .w = 40 } },
            });
            defer rail.deinit();
            for (rail.views(), 0..) |view, i| {
                var it = rail.item(@src(), view, .{});
                defer it.deinit();
                _ = dvui.spacer(@src(), .{ .min_size_content = .{ .w = 30, .h = 30 }, .id_extra = i });
                if (i == 0) first_item = it.data().rectScale().r;
            }
        }
        const result = try endless.layout(null, &layout);
        e.app.layout.publishRegions();
        return result;
    }
};

test "dragging an item down a vertical chooser reorders its place's views" {
    var ctx = try shim.init(std.testing.allocator);
    defer ctx.deinit(std.testing.allocator);
    const editor = ctx.editor;
    editor.app.gpa = std.testing.allocator;
    defer editor.app.layout.regions.deinit(editor.app.gpa);
    defer editor.app.layout.regions_building.deinit(editor.app.gpa);
    defer editor.app.layout.deinitExtents(editor.app.gpa);
    defer editor.app.layout.deinitAssignments(editor.app.gpa);
    defer editor.app.layout.deinitQualified(editor.app.gpa);
    RailFrame.editor = editor;
    defer RailFrame.editor = null;

    const draw = struct {
        fn f(_: ?*anyopaque) anyerror!dvui.App.Result {
            return .ok;
        }
    }.f;
    try editor.app.host.registerSurface(.{ .id = "test.one", .title = "One", .keywords = &.{"slot"}, .draw = draw });
    try editor.app.host.registerSurface(.{ .id = "test.two", .title = "Two", .keywords = &.{"slot"}, .draw = draw });
    try dvui.testing.settle(RailFrame.frame);

    const cw = dvui.currentWindow();
    const start = RailFrame.first_item.center();
    _ = try cw.addEventMouseMotion(.{ .pt = start });
    _ = try cw.addEventMouseButton(.left, .press);
    _ = try dvui.testing.step(RailFrame.frame);
    var y = start.y;
    // Down onto the slot after the second item, staying in the rail's column. The lifted item
    // leaves the list while it floats, so that slot is where the second item was.
    // `first_item` is read before its item lays out, so its height is not usable here.
    while (y < start.y + 70) : (y += 6) {
        _ = try cw.addEventMouseMotion(.{ .pt = .{ .x = start.x, .y = y } });
        _ = try dvui.testing.step(RailFrame.frame);
    }
    _ = try cw.addEventMouseButton(.left, .release);
    try dvui.testing.settle(RailFrame.frame);

    try std.testing.expect(!editor.app.layout.view_drag.active());
    const order = editor.app.layout.order("Center") orelse return error.TestExpectedEqual;
    try std.testing.expectEqualStrings("test.two", order[0]);
    try std.testing.expectEqualStrings("test.one", order[1]);
}

test "dragging a tab off a Multiple place's strip starts the view drag with it" {
    var ctx = try shim.init(std.testing.allocator);
    defer ctx.deinit(std.testing.allocator);
    const editor = ctx.editor;
    editor.app.gpa = std.testing.allocator;
    defer editor.app.layout.regions.deinit(editor.app.gpa);
    defer editor.app.layout.regions_building.deinit(editor.app.gpa);
    defer editor.app.layout.deinitExtents(editor.app.gpa);
    defer editor.app.layout.deinitAssignments(editor.app.gpa);
    defer editor.app.layout.deinitQualified(editor.app.gpa);
    defer editor.app.layout.view_drag.discard(editor.app.gpa);
    EndlessFrame.editor = editor;
    defer EndlessFrame.editor = null;

    const center = try multiCenter(editor);
    const cw = dvui.currentWindow();
    const y = center.bounds.y + (MultiProbe.one_top - center.bounds.y) / 2;
    const x = center.bounds.x + 16;
    _ = try cw.addEventMouseMotion(.{ .pt = .{ .x = x, .y = y } });
    _ = try cw.addEventMouseButton(.left, .press);
    _ = try dvui.testing.step(EndlessFrame.frame);
    var dy: f32 = 0;
    while (dy < 200 and !editor.app.layout.view_drag.active()) : (dy += 20) {
        _ = try cw.addEventMouseMotion(.{ .pt = .{ .x = x, .y = y + dy } });
        _ = try dvui.testing.step(EndlessFrame.frame);
    }
    try std.testing.expect(editor.app.layout.view_drag.active());
    try std.testing.expectEqualStrings("test.one", editor.app.layout.view_drag.moved_id);
}

test "a tab carried off a Multiple place's strip and back along it goes in where it is let go" {
    var ctx = try shim.init(std.testing.allocator);
    defer ctx.deinit(std.testing.allocator);
    const editor = ctx.editor;
    editor.app.gpa = std.testing.allocator;
    defer editor.app.layout.regions.deinit(editor.app.gpa);
    defer editor.app.layout.regions_building.deinit(editor.app.gpa);
    defer editor.app.layout.deinitExtents(editor.app.gpa);
    defer editor.app.layout.deinitAssignments(editor.app.gpa);
    defer editor.app.layout.deinitQualified(editor.app.gpa);
    defer editor.app.layout.view_drag.discard(editor.app.gpa);
    EndlessFrame.editor = editor;
    defer EndlessFrame.editor = null;

    const center = try multiCenter(editor);
    const cw = dvui.currentWindow();
    const y = center.bounds.y + (MultiProbe.one_top - center.bounds.y) / 2;
    const x0 = center.bounds.x + 16;
    _ = try cw.addEventMouseMotion(.{ .pt = .{ .x = x0, .y = y } });
    _ = try cw.addEventMouseButton(.left, .press);
    _ = try dvui.testing.step(EndlessFrame.frame);
    // Down off the strip, well into the place: the view drag, carrying `one`.
    var dy: f32 = 0;
    while (dy <= 120) : (dy += 20) {
        _ = try cw.addEventMouseMotion(.{ .pt = .{ .x = x0, .y = y + dy } });
        _ = try dvui.testing.step(EndlessFrame.frame);
    }
    try std.testing.expect(editor.app.layout.view_drag.active());
    try std.testing.expect(fizzy.Editor.Layout.ViewDrag.chooserAt(&editor.app.layout, .{ .x = x0, .y = y + 120 }) == null);
    // Back up onto the strip and along it past `two`: the strip is somewhere to go in, and says
    // where along it.
    var x = x0;
    while (x < x0 + 170) : (x += 10) {
        _ = try cw.addEventMouseMotion(.{ .pt = .{ .x = x, .y = y } });
        _ = try dvui.testing.step(EndlessFrame.frame);
    }
    const o = fizzy.Editor.Layout.ViewDrag.chooserAt(&editor.app.layout, .{ .x = x, .y = y }) orelse return error.TestExpectedEqual;
    try std.testing.expectEqualStrings("Center", o.name);
    try std.testing.expect(o.at != null);
    _ = try cw.addEventMouseButton(.left, .release);
    try dvui.testing.settle(EndlessFrame.frame);

    try std.testing.expect(!editor.app.layout.view_drag.active());
    const order = editor.app.layout.assignment("Center") orelse return error.TestExpectedEqual;
    try std.testing.expectEqual(@as(usize, 2), order.len);
    try std.testing.expectEqualStrings("test.two", order[0]);
    try std.testing.expectEqualStrings("test.one", order[1]);
}

test "a view let go over another place's chooser goes into its list where along it, and is shown" {
    var ctx = try shim.init(std.testing.allocator);
    defer ctx.deinit(std.testing.allocator);
    const editor = ctx.editor;
    editor.app.gpa = std.testing.allocator;
    defer editor.app.layout.regions.deinit(editor.app.gpa);
    defer editor.app.layout.regions_building.deinit(editor.app.gpa);
    defer editor.app.layout.deinitExtents(editor.app.gpa);
    defer editor.app.layout.deinitAssignments(editor.app.gpa);
    defer editor.app.layout.deinitQualified(editor.app.gpa);
    defer editor.app.layout.view_drag.discard(editor.app.gpa);
    EndlessFrame.editor = editor;
    defer EndlessFrame.editor = null;

    _ = try multiCenter(editor);
    const draw = struct {
        fn f(_: ?*anyopaque) anyerror!dvui.App.Result {
            return .ok;
        }
    }.f;
    // In no place: Center's list is written down, and does not take it by keyword.
    try editor.app.host.registerSurface(.{ .id = "test.three", .title = "Three", .keywords = fizzy.sdk.keywords.ide.main, .draw = draw });
    try dvui.testing.settle(EndlessFrame.frame);
    var layout = fizzy.Editor.Layout.init(&editor.app.host, &editor.app.layout, editor.app.gpa, dvui.currentWindow().arena());
    const ViewDrag = fizzy.Editor.Layout.ViewDrag;
    ViewDrag.beginLoose(&layout, "test.three", .{ .w = 40, .h = 20 }, null);
    try std.testing.expect(editor.app.layout.view_drag.active());
    ViewDrag.insertInto(&layout, ViewDrag.loose_source, "Center", .{ .before = "test.two" });

    const order = editor.app.layout.assignment("Center") orelse return error.TestExpectedEqual;
    try std.testing.expectEqual(@as(usize, 3), order.len);
    try std.testing.expectEqualStrings("test.one", order[0]);
    try std.testing.expectEqualStrings("test.three", order[1]);
    try std.testing.expectEqualStrings("test.two", order[2]);
    try dvui.testing.settle(EndlessFrame.frame);
    var center: fizzy.Editor.Layout.Region = undefined;
    for (editor.app.layout.regions.items) |r| {
        if (std.mem.eql(u8, r.name, "Center")) center = r;
    }
    const shown = layout.selectedIn(&center) orelse return error.TestExpectedEqual;
    try std.testing.expectEqualStrings("test.three", shown.id);
}

test "a view-drag can split its own place" {
    var ctx = try shim.init(std.testing.allocator);
    defer ctx.deinit(std.testing.allocator);

    const editor = ctx.editor;
    editor.app.gpa = std.testing.allocator;
    defer editor.app.layout.regions.deinit(editor.app.gpa);
    defer editor.app.layout.regions_building.deinit(editor.app.gpa);
    defer editor.app.layout.deinitExtents(editor.app.gpa);
    defer editor.app.layout.deinitAssignments(editor.app.gpa);
    defer editor.app.layout.deinitQualified(editor.app.gpa);

    EndlessFrame.editor = editor;
    defer EndlessFrame.editor = null;

    const draw = struct {
        fn f(_: ?*anyopaque) anyerror!dvui.App.Result {
            return .ok;
        }
    }.f;
    try editor.app.host.registerSurface(.{
        .id = "test.view",
        .title = "View",
        .keywords = fizzy.sdk.keywords.ide.main,
        .draw = draw,
    });

    try dvui.testing.settle(EndlessFrame.frame);
    try editor.app.layout.assign(editor.app.gpa, "Center", &.{"test.view"});
    {
        var layout = fizzy.Editor.Layout.init(&editor.app.host, &editor.app.layout, editor.app.gpa, dvui.currentWindow().arena());
        layout.placeVisible("Center", "Center", .{ .split = .bottom });
    }
    try dvui.testing.settle(EndlessFrame.frame);

    // Drop on the bottom: view stays on leftover Center (bottom), empty
    // leaf opens on top. A minted bottom leaf would put the view opposite
    // the drop — the self-split reversal.
    try std.testing.expect(editor.app.layout.dock.?.contains("Center/t1"));
    try std.testing.expect(editor.app.layout.isMinted("Center/t1"));
    const created = editor.app.layout.assignment("Center/t1") orelse return error.TestExpectedEqual;
    try std.testing.expectEqual(@as(usize, 0), created.len);
    const leftover = editor.app.layout.assignment("Center") orelse return error.TestExpectedEqual;
    try std.testing.expectEqual(@as(usize, 1), leftover.len);
    try std.testing.expectEqualStrings("test.view", leftover[0]);
}

// The rule in SPLITS.md, measured on screen rather than in the tree: whichever
// edge the view is dropped on is the half it occupies afterwards. Both cases
// go through `placeVisible`, the same call a release makes.
test "a dropped view ends up on the edge it was dropped on" {
    const Layout = fizzy.Editor.Layout;

    for ([_]struct { side: Layout.SplitTree.Side, leaf: []const u8 }{
        .{ .side = .top, .leaf = "Center/b1" },
        .{ .side = .bottom, .leaf = "Center/t1" },
    }) |case| {
        var ctx = try shim.init(std.testing.allocator);
        defer ctx.deinit(std.testing.allocator);

        const editor = ctx.editor;
        editor.app.gpa = std.testing.allocator;
        defer editor.app.layout.regions.deinit(editor.app.gpa);
        defer editor.app.layout.regions_building.deinit(editor.app.gpa);
        defer editor.app.layout.deinitExtents(editor.app.gpa);
        defer editor.app.layout.deinitAssignments(editor.app.gpa);
        defer editor.app.layout.deinitQualified(editor.app.gpa);

        const draw = struct {
            fn f(_: ?*anyopaque) anyerror!dvui.App.Result {
                return .ok;
            }
        }.f;
        try editor.app.host.registerSurface(.{
            .id = "test.view",
            .title = "View",
            .keywords = fizzy.sdk.keywords.ide.main,
            .draw = draw,
        });

        EndlessFrame.editor = editor;
        defer EndlessFrame.editor = null;

        try dvui.testing.settle(EndlessFrame.frame);
        try editor.app.layout.assign(editor.app.gpa, "Center", &.{"test.view"});
        {
            var layout = Layout.init(&editor.app.host, &editor.app.layout, editor.app.gpa, dvui.currentWindow().arena());
            layout.placeVisible("Center", "Center", .{ .split = case.side });
        }
        try dvui.testing.settle(EndlessFrame.frame);

        // The empty leaf took the far side, so the view's own half is the one
        // under where the pointer was.
        try std.testing.expect(editor.app.layout.dock.?.contains(case.leaf));
        try std.testing.expect(editor.app.layout.isMinted(case.leaf));
        var view_y: f32 = 0;
        var empty_y: f32 = 0;
        for (editor.app.layout.regions.items) |r| {
            if (std.mem.eql(u8, r.name, "Center")) view_y = r.bounds.y;
            if (std.mem.eql(u8, r.name, case.leaf)) empty_y = r.bounds.y;
        }
        try std.testing.expect(view_y > 0 or empty_y > 0);
        switch (case.side) {
            .top => try std.testing.expect(view_y < empty_y),
            .bottom => try std.testing.expect(view_y > empty_y),
            else => unreachable,
        }
    }
}

test "a nested document pane rejects a panel surface, a shape place does not" {
    const Region = fizzy.Editor.Region;
    const ViewDrag = fizzy.Editor.Layout.ViewDrag;
    const pane: Region = .{ .name = "Pane 1", .keywords = &.{"main.document"}, .by_name = true, .kind_slot = true };
    const main: Region = .{ .name = "Main", .keywords = fizzy.sdk.keywords.ide.main };
    const center: Region = .{ .name = "Center", .keywords = &.{"slot"}, .by_name = true };
    try std.testing.expect(!ViewDrag.accepts(pane, fizzy.sdk.keywords.ide.panel));
    try std.testing.expect(ViewDrag.accepts(pane, &.{"document"}));
    try std.testing.expect(ViewDrag.accepts(main, fizzy.sdk.keywords.ide.panel));
    try std.testing.expect(ViewDrag.accepts(center, fizzy.sdk.keywords.ide.panel));
}

// A place a split made is a container for a view, not furniture. Carrying its
// last view out leaves nothing there to want, so it shuts and its neighbour
// takes the room back — where emptying one of the shape's own places leaves
// the place, because that is where the shape says it is.
test "a place a split made shuts itself when its last view is carried out" {
    var ctx = try shim.init(std.testing.allocator);
    defer ctx.deinit(std.testing.allocator);

    const editor = ctx.editor;
    editor.app.gpa = std.testing.allocator;
    defer editor.app.layout.regions.deinit(editor.app.gpa);
    defer editor.app.layout.regions_building.deinit(editor.app.gpa);
    defer editor.app.layout.deinitExtents(editor.app.gpa);
    defer editor.app.layout.deinitAssignments(editor.app.gpa);
    defer editor.app.layout.deinitQualified(editor.app.gpa);

    const draw = struct {
        fn f(_: ?*anyopaque) anyerror!dvui.App.Result {
            return .ok;
        }
    }.f;
    try editor.app.host.registerSurface(.{
        .id = "test.view",
        .title = "View",
        .keywords = fizzy.sdk.keywords.ide.main,
        .draw = draw,
    });

    EndlessFrame.editor = editor;
    defer EndlessFrame.editor = null;

    try dvui.testing.settle(EndlessFrame.frame);
    {
        var layout = fizzy.Editor.Layout.init(&editor.app.host, &editor.app.layout, editor.app.gpa, dvui.currentWindow().arena());
        layout.splitNamed("Center", .vertical);
    }
    try dvui.testing.settle(EndlessFrame.frame);

    // The made place holds the only view; Center is the empty one.
    try editor.app.layout.assign(editor.app.gpa, "Center/b1", &.{"test.view"});
    try editor.app.layout.assign(editor.app.gpa, "Center", &.{});
    try dvui.testing.settle(EndlessFrame.frame);
    try std.testing.expect(editor.app.layout.dock.?.contains("Center/b1"));

    {
        var layout = fizzy.Editor.Layout.init(&editor.app.host, &editor.app.layout, editor.app.gpa, dvui.currentWindow().arena());
        layout.placeVisible("Center/b1", "Center", .swap);
    }
    try dvui.testing.settle(EndlessFrame.frame);

    // The two halves of the seed's split join: Center holds the view.
    const landed = editor.app.layout.assignment("Center") orelse return error.TestExpectedEqual;
    try std.testing.expectEqual(@as(usize, 1), landed.len);
    try std.testing.expectEqualStrings("test.view", landed[0]);
}

// Closing is one motion, and the end of it is the part people watch. A place
// at zero extent was still as wide as its own card padding, and the sash beside
// it still a full 10pt — so a close that looked smooth to the eye handed back
// a last two dozen points in one frame, when the leaf was finally dropped.
//
// Staged rather than animated: a test frame's clock jumps far enough to cross
// the whole curve in three steps, so the way to look at the end of a close is
// to put the place there — extent gone, a travelling `_shown` to keep the leaf
// from being collapsed out from under the measurement — and read what it and
// its sash are still holding.
/// One place, dressed the way fizzy dresses a place: a card with an inset. The
/// inset is the point — it is room the place takes up, and a close has to give
/// it back like everything else.
const PaddedCardFrame = struct {
    var editor: ?*fizzy.Editor = null;

    fn frame() anyerror!dvui.App.Result {
        const e = editor.?;
        var layout = fizzy.Editor.Layout.init(&e.app.host, &e.app.layout, e.app.gpa, dvui.currentWindow().arena());
        {
            var main = try layout.region(@src(), .{ .name = "Main", .keywords = fizzy.sdk.keywords.ide.main }, .{
                .expand = .both,
                .background = true,
                .padding = .all(card_inset),
            });
            defer main.deinit();
        }
        e.app.layout.publishRegions();
        return .ok;
    }

    const card_inset: f32 = 8;
};

test "a place closing for good is not still holding its padding and its sash" {
    var ctx = try shim.init(std.testing.allocator);
    defer ctx.deinit(std.testing.allocator);

    const editor = ctx.editor;
    editor.app.gpa = std.testing.allocator;
    defer editor.app.layout.regions.deinit(editor.app.gpa);
    defer editor.app.layout.regions_building.deinit(editor.app.gpa);
    defer editor.app.layout.deinitExtents(editor.app.gpa);
    defer editor.app.layout.deinitAssignments(editor.app.gpa);
    defer editor.app.layout.deinitQualified(editor.app.gpa);

    PaddedCardFrame.editor = editor;
    defer PaddedCardFrame.editor = null;

    try dvui.testing.settle(PaddedCardFrame.frame);
    {
        var layout = fizzy.Editor.Layout.init(&editor.app.host, &editor.app.layout, editor.app.gpa, dvui.currentWindow().arena());
        layout.splitNamed("Main", .vertical);
    }
    try dvui.testing.settle(PaddedCardFrame.frame);

    const scale = dvui.currentWindow().natural_scale;
    const ViewDrag = fizzy.Editor.Layout.ViewDrag;
    const open_leaf = ViewDrag.placeBounds(&editor.app.layout, "Main/b1") orelse return error.TestExpectedEqual;
    const open_rest = ViewDrag.placeBounds(&editor.app.layout, "Main") orelse return error.TestExpectedEqual;
    try std.testing.expectApproxEqAbs(
        fizzy.Editor.Layout.handle_size * scale,
        open_leaf.y - (open_rest.y + open_rest.h),
        1,
    );

    const leaf_id = blk: {
        for (editor.app.layout.regions.items) |r| {
            if (std.mem.eql(u8, r.name, "Main/b1")) break :blk r.id;
        }
        return error.TestExpectedEqual;
    };

    // Four points from shut and held there: an animation that goes nowhere is
    // what "still travelling" means to everything reading this — the curve is
    // live, so the leaf is not collapsed and the frame can be measured. Three
    // frames to settle at it: the sash reads the extent the place last drew at,
    // and a place's bounds are published for the frame after they were laid out.
    const left: f32 = 4;
    dvui.dataSet(null, leaf_id, "_size", @as(f32, 0));
    for (0..3) |_| {
        dvui.animation(leaf_id, "_ease", .{ .start_val = left, .end_val = left, .end_time = 100 * std.time.us_per_s });
        _ = try dvui.testing.step(PaddedCardFrame.frame);
    }

    const leaf = ViewDrag.placeBounds(&editor.app.layout, "Main/b1") orelse return error.TestExpectedEqual;
    const rest = ViewDrag.placeBounds(&editor.app.layout, "Main") orelse return error.TestExpectedEqual;

    // A place's extent is its whole reach, inset included, so four points from
    // shut the card is four points tall: its 8pt inset has folded to what four
    // points can carry. Kept whole, the inset alone would hold the place 16pt
    // open.
    try std.testing.expectApproxEqAbs(left * scale, leaf.h, 1);
    // And the sash has come down with it, rather than holding a full ten points
    // of gap open beside a place that is about to not be there — ten points
    // handed back in one frame at the end of an otherwise smooth close.
    try std.testing.expectApproxEqAbs(left * scale, leaf.y - (rest.y + rest.h), 1);
}

const DropFinishFrame = struct {
    var editor: ?*fizzy.Editor = null;
    const key: dvui.Id = @fromBackingInt(@intCast(0xd7_0b_f1_4e));

    fn frame() anyerror!dvui.App.Result {
        const e = editor.?;
        var layout = fizzy.Editor.Layout.init(&e.app.host, &e.app.layout, e.app.gpa, dvui.currentWindow().arena());
        fizzy.Editor.Layout.ViewDrag.drawZones(&layout, "Main", key);
        layout.drawDragOverlay();
        return .ok;
    }
};

// A drop leaves the way it came: its bubbles run back together and shrink
// away. The release usually changes the place it was over — a split renames
// it, a join closes it — and the drop looked it up again by name, found
// nothing, and was forgotten mid-way: it vanished instead. So did one released
// after the drag was held still, which measured the pause as one step.
test "a drop runs back together after the release, whatever happened to its place" {
    var ctx = try shim.init(std.testing.allocator);
    defer ctx.deinit(std.testing.allocator);

    const editor = ctx.editor;
    editor.app.gpa = std.testing.allocator;
    defer editor.app.layout.regions.deinit(editor.app.gpa);
    defer editor.app.layout.regions_building.deinit(editor.app.gpa);
    defer editor.app.layout.deinitQualified(editor.app.gpa);
    defer editor.app.layout.deinitAssignments(editor.app.gpa);

    const main_kw = fizzy.sdk.keywords.ide.main;
    const panel_kw = fizzy.sdk.keywords.ide.panel;
    const main_at: dvui.Rect.Physical = .{ .x = 0, .y = 0, .w = 600, .h = 300 };
    const panel_at: dvui.Rect.Physical = .{ .x = 0, .y = 300, .w = 600, .h = 100 };
    editor.app.layout.registerRegion(editor.app.gpa, .{ .name = "Main", .keywords = main_kw, .bounds = main_at, .size = .{ .w = 600, .h = 300 } });
    editor.app.layout.registerRegion(editor.app.gpa, .{ .name = "Panel", .keywords = panel_kw, .bounds = panel_at });
    editor.app.layout.publishRegions();

    DropFinishFrame.editor = editor;
    defer DropFinishFrame.editor = null;
    const DropZones = fizzy.core.widgets.DropZones;
    defer DropZones.forget(DropFinishFrame.key);

    {
        var layout = fizzy.Editor.Layout.init(&editor.app.host, &editor.app.layout, editor.app.gpa, dvui.currentWindow().arena());
        fizzy.Editor.Layout.ViewDrag.begin(&layout, "Panel", panel_at, panel_at);
    }
    defer editor.app.layout.view_drag.discard(editor.app.gpa);
    _ = try dvui.currentWindow().addEventMouseMotion(.{ .pt = main_at.center() });
    try dvui.testing.settle(DropFinishFrame.frame);
    try std.testing.expect(DropZones.showing(DropFinishFrame.key));

    // Held still for three seconds: a drag that does not move asks for no frames.
    {
        const cw = dvui.currentWindow();
        _ = try cw.end(.{});
        try cw.begin(cw.frame_time_ns + 3 * std.time.ns_per_s);
    }

    // Released, and the place it was over is now called something else.
    editor.app.layout.view_drag.discard(editor.app.gpa);
    editor.app.layout.registerRegion(editor.app.gpa, .{ .name = "Main/b0", .keywords = main_kw, .bounds = main_at });
    editor.app.layout.registerRegion(editor.app.gpa, .{ .name = "Panel", .keywords = panel_kw, .bounds = panel_at });
    editor.app.layout.publishRegions();

    _ = try dvui.testing.step(DropFinishFrame.frame);
    try std.testing.expect(DropZones.showing(DropFinishFrame.key));
    try dvui.testing.settle(DropFinishFrame.frame);
    try std.testing.expect(!DropZones.showing(DropFinishFrame.key));
}

// A drag must not change the map it is being read against. It does, twice
// over: the preview draws the view it is about to land, and the panes *that*
// declares register as places under the pointer; and the place being split
// pulls back to its half, moving the rect the pointer is aiming at. Either one
// flips the reading every frame — the jitter that made dropping into another
// place impossible. The map is photographed at lift, like the view is.
test "a drag aims at the places that were there when it began" {
    var ctx = try shim.init(std.testing.allocator);
    defer ctx.deinit(std.testing.allocator);

    const editor = ctx.editor;
    editor.app.gpa = std.testing.allocator;
    defer editor.app.layout.regions.deinit(editor.app.gpa);
    defer editor.app.layout.regions_building.deinit(editor.app.gpa);
    defer editor.app.layout.deinitQualified(editor.app.gpa);
    defer editor.app.layout.deinitAssignments(editor.app.gpa);

    const main_kw = fizzy.sdk.keywords.ide.main;
    const panel_kw = fizzy.sdk.keywords.ide.panel;
    const whole: dvui.Rect.Physical = .{ .x = 0, .y = 0, .w = 800, .h = 400 };
    const panel_at: dvui.Rect.Physical = .{ .x = 0, .y = 400, .w = 800, .h = 200 };
    const middle: dvui.Point.Physical = .{ .x = 400, .y = 200 };

    const full: dvui.Size = .{ .w = 800, .h = 400 };

    editor.app.layout.registerRegion(editor.app.gpa, .{ .name = "Main", .keywords = main_kw, .bounds = whole, .size = full });
    editor.app.layout.registerRegion(editor.app.gpa, .{ .name = "Panel", .keywords = panel_kw, .bounds = panel_at });
    editor.app.layout.publishRegions();

    var layout = fizzy.Editor.Layout.init(&editor.app.host, &editor.app.layout, editor.app.gpa, dvui.currentWindow().arena());
    const ViewDrag = fizzy.Editor.Layout.ViewDrag;
    ViewDrag.begin(&layout, "Panel", panel_at, panel_at);
    defer editor.app.layout.view_drag.discard(editor.app.gpa);

    try std.testing.expectEqualStrings("Main", ViewDrag.targetAt(&layout, middle, "Panel") orelse
        return error.TestExpectedEqual);

    // A pane that exists only because the preview is drawing the incoming view
    // is smaller than Main and sits right under the pointer. It still loses:
    // it was not there when the drag began.
    editor.app.layout.registerRegion(editor.app.gpa, .{ .name = "Main", .keywords = main_kw, .bounds = whole });
    editor.app.layout.registerRegion(editor.app.gpa, .{ .name = "Panel", .keywords = panel_kw, .bounds = panel_at });
    editor.app.layout.registerRegion(editor.app.gpa, .{
        .name = "Preview pane",
        .keywords = &.{"main.document"},
        .by_name = true,
        .bounds = .{ .x = 380, .y = 180, .w = 120, .h = 80 },
    });
    editor.app.layout.publishRegions();
    try std.testing.expectEqualStrings("Main", ViewDrag.targetAt(&layout, middle, "Panel") orelse
        return error.TestExpectedEqual);

    // Main pulling back to the half it would keep does not take its own edge
    // out from under the pointer aiming at it.
    editor.app.layout.registerRegion(editor.app.gpa, .{
        .name = "Main",
        .keywords = main_kw,
        .bounds = .{ .x = 0, .y = 0, .w = 400, .h = 400 },
        .size = .{ .w = 400, .h = 400 },
    });
    editor.app.layout.registerRegion(editor.app.gpa, .{ .name = "Panel", .keywords = panel_kw, .bounds = panel_at });
    editor.app.layout.publishRegions();
    const right_half: dvui.Point.Physical = .{ .x = 600, .y = 200 };
    try std.testing.expectEqualStrings("Main", ViewDrag.targetAt(&layout, right_half, "Panel") orelse
        return error.TestExpectedEqual);
    try std.testing.expectEqual(whole, ViewDrag.placeBounds(&editor.app.layout, "Main").?);

    // And the drop settles the split against that same full measure. Halving
    // the pulled-back 400 would seat the new pane at a quarter of the place
    // the preview showed opening.
    try std.testing.expectEqual(full, ViewDrag.placeSize(&editor.app.layout, "Main").?);
}

test "dropping a panel surface onto main puts it beside what main holds, and only there" {
    var ctx = try shim.init(std.testing.allocator);
    defer ctx.deinit(std.testing.allocator);

    const editor = ctx.editor;
    editor.app.gpa = std.testing.allocator;
    defer editor.app.layout.regions.deinit(editor.app.gpa);
    defer editor.app.layout.regions_building.deinit(editor.app.gpa);
    defer editor.app.layout.deinitQualified(editor.app.gpa);
    defer editor.app.layout.deinitAssignments(editor.app.gpa);

    const main = fizzy.sdk.keywords.ide.main;
    const panel = fizzy.sdk.keywords.ide.panel;
    editor.app.layout.registerRegion(editor.app.gpa, .{ .name = "Main", .keywords = main, .id = .extendId(null, @src(), 1) });
    editor.app.layout.registerRegion(editor.app.gpa, .{ .name = "Panel", .keywords = panel, .id = .extendId(null, @src(), 2) });
    editor.app.layout.publishRegions();

    const draw = struct {
        fn f(_: ?*anyopaque) anyerror!dvui.App.Result {
            return .ok;
        }
    }.f;
    try editor.app.host.registerSurface(.{ .id = "test.workspace", .title = "Workspace", .keywords = main, .draw = draw });
    try editor.app.host.registerSurface(.{ .id = "test.output", .title = "Output", .keywords = panel, .draw = draw });

    var layout = fizzy.Editor.Layout.init(&editor.app.host, &editor.app.layout, editor.app.gpa, dvui.currentWindow().arena());
    try std.testing.expectEqual(@as(usize, 1), layout.matching(panel).len);

    layout.placeVisible("Panel", "Main", .swap);

    // Main holds both now — two views, so tabs — with the one dropped showing; nothing is traded
    // back to the panel, which is left empty.
    const dest = editor.app.layout.assignment("Main") orelse return error.TestExpectedEqual;
    try std.testing.expectEqual(@as(usize, 2), dest.len);
    try std.testing.expectEqualStrings("test.workspace", dest[0]);
    try std.testing.expectEqualStrings("test.output", dest[1]);
    try std.testing.expectEqualStrings("test.output", layout.selected(main).?.id);
    try std.testing.expectEqual(@as(usize, 0), layout.matching(panel).len);
}

// Every place takes a dropped view beside what it holds; none trades.
//
// Dragging Files out of the sidebar onto Main: Main takes Files beside its
// workspace. The sidebar must then *stop showing Files* — both in its match
// list and as its selection — or the explorer body keeps drawing Files beside
// the rail, which has already dropped the icon, until the user clicks some
// other icon. That is a chooser and a body that have stopped agreeing about
// what this place is.
test "a place adds a dropped view beside what it holds" {
    var ctx = try shim.init(std.testing.allocator);
    defer ctx.deinit(std.testing.allocator);

    const editor = ctx.editor;
    editor.app.gpa = std.testing.allocator;
    defer editor.app.layout.regions.deinit(editor.app.gpa);
    defer editor.app.layout.regions_building.deinit(editor.app.gpa);
    defer editor.app.layout.deinitQualified(editor.app.gpa);
    defer editor.app.layout.deinitAssignments(editor.app.gpa);

    const main = fizzy.sdk.keywords.ide.main;
    const side = fizzy.sdk.keywords.ide.sidebar;
    editor.app.layout.registerRegion(editor.app.gpa, .{ .name = "Main", .keywords = main, .id = .extendId(null, @src(), 1) });
    editor.app.layout.registerRegion(editor.app.gpa, .{ .name = "Sidebar", .keywords = side, .id = .extendId(null, @src(), 2) });
    editor.app.layout.publishRegions();

    const draw = struct {
        fn f(_: ?*anyopaque) anyerror!dvui.App.Result {
            return .ok;
        }
    }.f;
    try editor.app.host.registerSurface(.{ .id = "test.workspace", .title = "Workspace", .keywords = main, .draw = draw });
    try editor.app.host.registerSurface(.{ .id = "test.files", .title = "Files", .keywords = side, .draw = draw });
    try editor.app.host.registerSurface(.{ .id = "test.plugins", .title = "Plugins", .keywords = side, .draw = draw });

    var layout = fizzy.Editor.Layout.init(&editor.app.host, &editor.app.layout, editor.app.gpa, dvui.currentWindow().arena());
    editor.app.host.setSelectionFor(side, "test.files");
    try std.testing.expectEqualStrings("test.files", layout.selected(side).?.id);

    // Files leaves the sidebar and goes in beside Main's workspace.
    layout.placeVisible("Sidebar", "Main", .swap);

    try std.testing.expectEqualStrings("test.files", layout.selected(main).?.id);
    try std.testing.expectEqual(@as(usize, 2), layout.matching(main).len);

    var files_still_here = false;
    for (layout.matching(side)) |s| {
        if (std.mem.eql(u8, s.id, "test.files")) files_still_here = true;
    }
    try std.testing.expect(!files_still_here);
    const after = layout.selected(side) orelse return error.TestExpectedEqual;
    try std.testing.expect(!std.mem.eql(u8, after.id, "test.files"));

    // Back: Files joins what the sidebar holds, and Main keeps its workspace, taking nothing of
    // the sidebar's in trade.
    layout.placeVisible("Main", "Sidebar", .swap);
    var has_workspace = false;
    var has_files = false;
    for (layout.matching(side)) |s| {
        if (std.mem.eql(u8, s.id, "test.workspace")) has_workspace = true;
        if (std.mem.eql(u8, s.id, "test.files")) has_files = true;
    }
    try std.testing.expect(!has_workspace);
    try std.testing.expect(has_files);
    try std.testing.expectEqual(@as(usize, 1), layout.matching(main).len);
    try std.testing.expectEqualStrings("test.workspace", layout.matching(main)[0].id);
    try std.testing.expectEqualStrings("test.files", layout.selected(side).?.id);
}

// A view dropped on a plugin's region is the plugin's to land (`RegionSpec.on_drop`): the app
// drew the drag, the plugin makes the pane. The middle and each edge arrive as themselves.
const DropProbe = struct {
    var last: ?fizzy.sdk.RegionSpec.Drop = null;
    var id_buf: [64]u8 = undefined;

    fn onDrop(_: ?*anyopaque, drop: fizzy.sdk.RegionSpec.Drop) bool {
        const n = @min(drop.surface_id.len, id_buf.len);
        @memcpy(id_buf[0..n], drop.surface_id[0..n]);
        last = .{ .surface_id = id_buf[0..n], .zone = drop.zone };
        return true;
    }
};

fn dropRegions(editor: *fizzy.Editor) void {
    const pane: []const []const u8 = &.{"main.document"};
    editor.app.layout.registerRegion(editor.app.gpa, .{ .name = "Pane 0", .keywords = pane, .id = .extendId(null, @src(), 1), .by_name = true, .kind_slot = true, .on_drop = DropProbe.onDrop });
    editor.app.layout.registerRegion(editor.app.gpa, .{ .name = "Pane 1", .keywords = pane, .id = .extendId(null, @src(), 2), .by_name = true, .kind_slot = true });
    editor.app.layout.publishRegions();
}

test "a view dropped on a plugin's region goes to its on_drop, middle and edge alike" {
    var ctx = try shim.init(std.testing.allocator);
    defer ctx.deinit(std.testing.allocator);
    const editor = ctx.editor;
    editor.app.gpa = std.testing.allocator;
    defer editor.app.layout.regions.deinit(editor.app.gpa);
    defer editor.app.layout.regions_building.deinit(editor.app.gpa);
    defer editor.app.layout.deinitQualified(editor.app.gpa);
    defer editor.app.layout.deinitAssignments(editor.app.gpa);

    const draw = struct {
        fn f(_: ?*anyopaque) anyerror!dvui.App.Result {
            return .ok;
        }
    }.f;
    try editor.app.host.registerSurface(.{ .id = "test.doc", .title = "a.txt", .keywords = fizzy.sdk.document.keywords, .draw = draw });
    dropRegions(editor);
    try editor.app.layout.assign(editor.app.gpa, "Pane 1", &.{"test.doc"});

    var layout = fizzy.Editor.Layout.init(&editor.app.host, &editor.app.layout, editor.app.gpa, dvui.currentWindow().arena());
    const VD = fizzy.Editor.Layout.ViewDrag;

    DropProbe.last = null;
    VD.place(&layout, "Pane 1", "Pane 0", .{ .split = .right });
    const edge = DropProbe.last orelse return error.TestExpectedEqual;
    try std.testing.expectEqualStrings("test.doc", edge.surface_id);
    try std.testing.expect(edge.zone == .edge and edge.zone.edge == .right);

    DropProbe.last = null;
    VD.place(&layout, "Pane 1", "Pane 0", .swap);
    const mid = DropProbe.last orelse return error.TestExpectedEqual;
    try std.testing.expect(mid.zone == .center);

    // The handler landed it (here, by recording it): the app did not also move it.
    const still = editor.app.layout.assignment("Pane 1") orelse return error.TestExpectedEqual;
    try std.testing.expectEqual(@as(usize, 1), still.len);
}

// A file carried out of the explorer that is not open yet has no surface: it is carried by the id
// its document will have (`sdk.document.surfaceId`), and only a document's slot takes it — whose
// own drop opens the file (the workbench's `paneDrop`).
test "drag: a document not open yet goes only to a document's slot, whose drop gets the id it will have" {
    var ctx = try shim.init(std.testing.allocator);
    defer ctx.deinit(std.testing.allocator);
    const editor = ctx.editor;
    editor.app.gpa = std.testing.allocator;
    defer editor.app.layout.regions.deinit(editor.app.gpa);
    defer editor.app.layout.regions_building.deinit(editor.app.gpa);
    defer editor.app.layout.deinitQualified(editor.app.gpa);
    defer editor.app.layout.deinitAssignments(editor.app.gpa);
    defer editor.app.layout.view_drag.discard(editor.app.gpa);

    const state = &editor.app.layout;
    const gpa = editor.app.gpa;
    const main_at: dvui.Rect.Physical = .{ .x = 0, .y = 0, .w = 800, .h = 400 };
    const pane_at: dvui.Rect.Physical = .{ .x = 100, .y = 40, .w = 600, .h = 320 };
    const panel_at: dvui.Rect.Physical = .{ .x = 0, .y = 400, .w = 800, .h = 200 };
    const doc_kw: []const []const u8 = &.{"main.document"};
    state.registerRegion(gpa, .{ .name = "Main", .keywords = fizzy.sdk.keywords.ide.main, .bounds = main_at, .size = .{ .w = 800, .h = 400 } });
    state.registerRegion(gpa, .{ .name = "Pane 0", .keywords = doc_kw, .by_name = true, .kind_slot = true, .bounds = pane_at, .on_drop = DropProbe.onDrop });
    state.registerRegion(gpa, .{ .name = "Panel", .keywords = fizzy.sdk.keywords.ide.panel, .bounds = panel_at });
    state.publishRegions();

    var layout = fizzy.Editor.Layout.init(&editor.app.host, state, gpa, dvui.currentWindow().arena());
    const VD = fizzy.Editor.Layout.ViewDrag;
    const id = "text.doc:/project/notes.md";
    try std.testing.expect(editor.app.host.surfaceById(id) == null);
    VD.beginLoose(&layout, id, .{ .x = 10, .y = 10, .w = 120, .h = 24 }, null);
    try std.testing.expect(state.view_drag.active());
    try std.testing.expectEqualStrings(id, state.view_drag.moved_id);

    // Mapped: the document's slot, and no plain place.
    try std.testing.expectEqual(@as(usize, 1), state.view_drag.target_count);
    try std.testing.expectEqualStrings("Pane 0", state.view_drag.targets[0].name);
    try std.testing.expectEqualStrings("Pane 0", VD.targetAt(&layout, .{ .x = 400, .y = 200 }, VD.loose_source) orelse
        return error.TestExpectedEqual);
    try std.testing.expect(VD.targetAt(&layout, .{ .x = 40, .y = 200 }, VD.loose_source) == null);
    try std.testing.expect(VD.targetAt(&layout, .{ .x = 400, .y = 500 }, VD.loose_source) == null);

    // Let go on the slot: its drop gets the id, to open the file by.
    DropProbe.last = null;
    VD.place(&layout, VD.loose_source, "Pane 0", .swap);
    const got = DropProbe.last orelse return error.TestExpectedEqual;
    try std.testing.expectEqualStrings(id, got.surface_id);
    try std.testing.expect(got.zone == .center);
    // On a plain place, nothing: no list there names a document it cannot show.
    VD.place(&layout, VD.loose_source, "Main", .swap);
    VD.place(&layout, VD.loose_source, "Panel", .swap);
    try std.testing.expect(state.assignment("Main") == null);
    try std.testing.expect(state.assignment("Panel") == null);
}

/// An application's views holding documents (`State.documents`), for the layout to float: a new
/// one is always `test.workspace.2`; the view a document carries alone is `lone`'s.
const DocViews = struct {
    var housed: [64]u8 = undefined;
    var housed_len: usize = 0;
    var lone: ?[]const u8 = null;
    var folded: usize = 0;

    fn house(_: *anyopaque, ids: []const []const u8) ?[]const u8 {
        housed_len = @min(ids[0].len, housed.len);
        @memcpy(housed[0..housed_len], ids[0][0..housed_len]);
        return "test.workspace.2";
    }

    fn alone(_: *anyopaque, _: []const u8) ?[]const u8 {
        return lone;
    }

    fn fold(_: *anyopaque, id: []const u8) bool {
        if (!std.mem.startsWith(u8, id, "test.workspace.")) return false;
        folded += 1;
        return true;
    }
};

test "float: a document tab dropped on its own pane's middle floats in a view holding it" {
    var ctx = try shim.init(std.testing.allocator);
    defer ctx.deinit(std.testing.allocator);
    const editor = ctx.editor;
    editor.app.gpa = std.testing.allocator;
    defer editor.app.layout.regions.deinit(editor.app.gpa);
    defer editor.app.layout.regions_building.deinit(editor.app.gpa);
    defer editor.app.layout.deinitExtents(editor.app.gpa);
    defer editor.app.layout.deinitQualified(editor.app.gpa);
    defer editor.app.layout.deinitAssignments(editor.app.gpa);
    defer editor.app.layout.view_drag.discard(editor.app.gpa);

    const state = &editor.app.layout;
    const gpa = editor.app.gpa;
    const host = &editor.app.host;
    const doc_kw: []const []const u8 = &.{"main.document"};
    const regions = struct {
        fn publish(st: *@TypeOf(editor.app.layout), g: std.mem.Allocator, float: bool) void {
            st.registerRegion(g, .{ .name = "Main", .keywords = fizzy.sdk.keywords.ide.main, .bounds = .{ .x = 0, .y = 0, .w = 800, .h = 400 }, .size = .{ .w = 800, .h = 400 } });
            st.registerRegion(g, .{ .name = "Pane 0", .keywords = &.{"main.document"}, .by_name = true, .kind_slot = true, .bounds = .{ .x = 100, .y = 40, .w = 600, .h = 320 }, .on_drop = DropProbe.onDrop });
            if (float) st.registerRegion(g, .{ .name = "Float 2", .keywords = fizzy.sdk.keywords.ide.main, .bounds = .{ .x = 200, .y = 100, .w = 400, .h = 240 } });
            st.publishRegions();
        }
    };
    regions.publish(state, gpa, false);
    try host.registerSurface(.{ .id = "test.workspace.1", .title = "Workspace", .keywords = fizzy.sdk.keywords.ide.main, .draw = ManyPanelFrame.draw });
    try host.registerSurface(.{ .id = "test.workspace.2", .title = "Workspace", .keywords = fizzy.sdk.keywords.ide.main, .draw = ManyPanelFrame.draw });
    try host.registerSurface(.{ .id = "text.doc:/project/a.md", .title = "a.md", .keywords = doc_kw, .draw = ManyPanelFrame.draw });
    try host.registerSurface(.{ .id = "text.doc:/project/b.md", .title = "b.md", .keywords = doc_kw, .draw = ManyPanelFrame.draw });
    try state.assign(gpa, "Main", &.{"test.workspace.1"});
    try state.assign(gpa, "Pane 0", &.{ "text.doc:/project/a.md", "text.doc:/project/b.md" });
    var docs_ctx: u8 = 0;
    state.documents = .{ .ctx = &docs_ctx, .house = DocViews.house, .alone = DocViews.alone, .fold = DocViews.fold };
    defer state.documents = null;
    DocViews.lone = null;
    DocViews.folded = 0;

    var layout = fizzy.Editor.Layout.init(host, state, gpa, dvui.currentWindow().arena());
    const VD = fizzy.Editor.Layout.ViewDrag;

    // One tab of two: it floats in a new view holding just it, and the pane is never asked.
    DropProbe.last = null;
    VD.beginLoose(&layout, "text.doc:/project/a.md", .{ .x = 110, .y = 44, .w = 120, .h = 24 }, null);
    VD.place(&layout, VD.loose_source, "Pane 0", .swap);
    state.view_drag.discard(gpa);
    try std.testing.expect(DropProbe.last == null);
    try std.testing.expectEqualStrings("text.doc:/project/a.md", DocViews.housed[0..DocViews.housed_len]);
    try std.testing.expectEqual(@as(usize, 1), state.floats.items.items.len);
    const first = state.floats.items.items[0];
    try std.testing.expectEqualStrings("Float 1", first.name);
    const in_first = state.assignment("Float 1") orelse return error.TestExpectedEqual;
    try std.testing.expectEqual(@as(usize, 1), in_first.len);
    try std.testing.expectEqualStrings("test.workspace.2", in_first[0]);
    // The workspace it came out of stays where it was.
    try std.testing.expectEqualStrings("test.workspace.1", (state.assignment("Main") orelse return error.TestExpectedEqual)[0]);

    // A workspace's only tab carries the workspace: that floats, out of the place showing it.
    try state.assign(gpa, "Pane 0", &.{"text.doc:/project/b.md"});
    DocViews.lone = "test.workspace.1";
    VD.beginLoose(&layout, "text.doc:/project/b.md", .{ .x = 110, .y = 44, .w = 120, .h = 24 }, null);
    VD.place(&layout, VD.loose_source, "Pane 0", .swap);
    state.view_drag.discard(gpa);
    try std.testing.expectEqual(@as(usize, 2), state.floats.items.items.len);
    try std.testing.expectEqualStrings("Main", state.floats.items.items[1].home);
    try std.testing.expectEqualStrings("test.workspace.1", (state.assignment("Float 2") orelse return error.TestExpectedEqual)[0]);
    try std.testing.expectEqual(@as(usize, 0), (state.assignment("Main") orelse return error.TestExpectedEqual).len);

    // Alone in a float nobody split, it does not float again: the pane takes the drop.
    regions.publish(state, gpa, true);
    VD.beginLoose(&layout, "text.doc:/project/b.md", .{ .x = 110, .y = 44, .w = 120, .h = 24 }, null);
    VD.place(&layout, VD.loose_source, "Pane 0", .swap);
    state.view_drag.discard(gpa);
    try std.testing.expectEqual(@as(usize, 2), state.floats.items.items.len);
    try std.testing.expect(DropProbe.last != null);

    // Closed, a float's workspace gives its documents to the main window's (`fold`), and is
    // not sent home as itself.
    layout.closeFloat("Float 2");
    try std.testing.expectEqual(@as(usize, 1), DocViews.folded);
    try std.testing.expectEqual(@as(usize, 0), (state.assignment("Main") orelse return error.TestExpectedEqual).len);
}

test "a region with no drop handler takes the middle by the app's default" {
    var ctx = try shim.init(std.testing.allocator);
    defer ctx.deinit(std.testing.allocator);
    const editor = ctx.editor;
    editor.app.gpa = std.testing.allocator;
    defer editor.app.layout.regions.deinit(editor.app.gpa);
    defer editor.app.layout.regions_building.deinit(editor.app.gpa);
    defer editor.app.layout.deinitQualified(editor.app.gpa);
    defer editor.app.layout.deinitAssignments(editor.app.gpa);

    const draw = struct {
        fn f(_: ?*anyopaque) anyerror!dvui.App.Result {
            return .ok;
        }
    }.f;
    try editor.app.host.registerSurface(.{ .id = "test.doc", .title = "a.txt", .keywords = fizzy.sdk.document.keywords, .draw = draw });
    dropRegions(editor);
    // A workbench pane always has an assignment, empty or not; without one it would go by its
    // keywords, which two panes share.
    try editor.app.layout.assign(editor.app.gpa, "Pane 1", &.{});
    try editor.app.layout.assign(editor.app.gpa, "Pane 0", &.{"test.doc"});

    var layout = fizzy.Editor.Layout.init(&editor.app.host, &editor.app.layout, editor.app.gpa, dvui.currentWindow().arena());
    fizzy.Editor.Layout.ViewDrag.place(&layout, "Pane 0", "Pane 1", .swap);
    const dest = editor.app.layout.assignment("Pane 1") orelse return error.TestExpectedEqual;
    try std.testing.expectEqual(@as(usize, 1), dest.len);
    try std.testing.expectEqualStrings("test.doc", dest[0]);
    // An assignment lives in one place: it left the pane it came from.
    const from = editor.app.layout.assignment("Pane 0") orelse return error.TestExpectedEqual;
    try std.testing.expectEqual(@as(usize, 0), from.len);
}

// Every place a dragged view could land shows its drop zones, the place it came from included.
test "dragging a view over its own place shows that place's drop zones" {
    var ctx = try shim.init(std.testing.allocator);
    defer ctx.deinit(std.testing.allocator);
    const editor = ctx.editor;
    editor.app.gpa = std.testing.allocator;
    defer editor.app.layout.regions.deinit(editor.app.gpa);
    defer editor.app.layout.regions_building.deinit(editor.app.gpa);
    defer editor.app.layout.deinitExtents(editor.app.gpa);
    defer editor.app.layout.deinitAssignments(editor.app.gpa);
    defer editor.app.layout.deinitQualified(editor.app.gpa);
    defer editor.app.layout.view_drag.discard(editor.app.gpa);
    EndlessFrame.editor = editor;
    defer EndlessFrame.editor = null;

    const draw = struct {
        fn f(_: ?*anyopaque) anyerror!dvui.App.Result {
            return .ok;
        }
    }.f;
    try editor.app.host.registerSurface(.{ .id = "test.view", .title = "View", .keywords = &.{"slot"}, .draw = draw });
    try dvui.testing.settle(EndlessFrame.frame);
    var center: fizzy.Editor.Layout.Region = undefined;
    for (editor.app.layout.regions.items) |r| {
        if (std.mem.eql(u8, r.name, "Center")) center = r;
    }

    // The corner button, at the place's top right.
    const cw = dvui.currentWindow();
    const button: dvui.Point.Physical = .{ .x = center.bounds.x + center.bounds.w - 16, .y = center.bounds.y + 16 };
    _ = try cw.addEventMouseMotion(.{ .pt = button });
    _ = try dvui.testing.step(EndlessFrame.frame);
    _ = try dvui.testing.step(EndlessFrame.frame);
    _ = try cw.addEventMouseButton(.left, .press);
    _ = try dvui.testing.step(EndlessFrame.frame);
    // Into the middle of the same place.
    const mid = center.bounds.center();
    var i: usize = 1;
    while (i <= 12) : (i += 1) {
        const t: f32 = @as(f32, @floatFromInt(i)) / 12;
        _ = try cw.addEventMouseMotion(.{ .pt = .{ .x = button.x + (mid.x - button.x) * t, .y = button.y + (mid.y - button.y) * t } });
        _ = try dvui.testing.step(EndlessFrame.frame);
    }
    for (0..6) |_| _ = try dvui.testing.step(EndlessFrame.frame);

    const d = &editor.app.layout.view_drag;
    try std.testing.expect(d.active());
    // The place as this frame declared it: its id is not the one it had before its tree was set up.
    for (editor.app.layout.regions.items) |r| {
        if (std.mem.eql(u8, r.name, "Center")) center = r;
    }
    try std.testing.expect(fizzy.core.widgets.DropZones.showing(center.id));
}

test "drop: beside marks the tall target's bottom rather than the wide source's right" {
    var ctx = try shim.init(std.testing.allocator);
    defer ctx.deinit(std.testing.allocator);
    const editor = ctx.editor;
    const gpa = std.testing.allocator;
    editor.app.gpa = gpa;
    const state = &editor.app.layout;
    defer state.regions.deinit(gpa);
    defer state.regions_building.deinit(gpa);
    defer state.deinitExtents(gpa);
    defer state.deinitAssignments(gpa);
    defer state.deinitQualified(gpa);
    defer state.view_drag.discard(gpa);
    const source: dvui.Rect.Physical = .{ .x = 0, .y = 0, .w = 1200, .h = 800 };
    const target: dvui.Rect.Physical = .{ .x = 1200, .y = 0, .w = 820, .h = 1180 };
    state.registerRegion(gpa, .{ .name = "Source", .keywords = fizzy.sdk.keywords.ide.main, .bounds = source, .size = .{ .w = source.w, .h = source.h } });
    state.registerRegion(gpa, .{ .name = "Target", .keywords = &.{"slot"}, .bounds = target, .size = .{ .w = target.w, .h = target.h } });
    state.publishRegions();
    const Probe = struct {
        calls: usize = 0,
        fn edge(raw: *anyopaque, name: []const u8) ?fizzy.Editor.Layout.State.SplitTree.Side {
            const self: *@This() = @ptrCast(@alignCast(raw));
            self.calls += 1;
            const room = if (std.mem.eql(u8, name, "Target")) target else source;
            return workbench.Workbench.sideFor(room.w, room.h);
        }
    };
    var probe: Probe = .{};
    state.beside = .{ .ctx = &probe, .edge = Probe.edge };
    defer state.beside = null;
    try editor.app.host.registerSurface(.{ .id = "test.view", .title = "View", .keywords = &.{"slot"}, .draw = ManyPanelFrame.draw });
    try state.assign(gpa, "Source", &.{"test.view"});
    var layout = fizzy.Editor.Layout.init(&editor.app.host, state, gpa, dvui.currentWindow().arena());
    const VD = fizzy.Editor.Layout.ViewDrag;
    const cw = dvui.currentWindow();
    const mouse = cw.mouse_pt;
    defer cw.mouse_pt = mouse;
    cw.mouse_pt = source.center();
    VD.begin(&layout, "Source", source, source);
    cw.mouse_pt = target.center();
    fizzy.core.anchor.want();
    VD.drawZones(&layout, "Target", dvui.parentGet().extendId(@src(), 0));
    const beside = dvui.tagGet("drop:beside") orelse return error.TestUnexpectedResult;
    const bottom = dvui.tagGet("drop:bottom") orelse return error.TestUnexpectedResult;
    const right = dvui.tagGet("drop:right") orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(bottom.rect, beside.rect);
    try std.testing.expect(!std.meta.eql(right.rect, beside.rect));
    try std.testing.expectEqual(@as(usize, 1), probe.calls);

    // Main's implicit pane must not borrow the shape of a workspace held elsewhere.
    const wb = &editor.workbench;
    const grouping = wb.open_workspace_grouping;
    var workspace = workbench.Workspace.init(grouping);
    workspace.pane_rect_physical = source;
    try wb.workspaces.put(gpa, grouping, workspace);
    defer wb.workspaces.deinit(gpa);
    var id_buf: [64]u8 = undefined;
    const id = try std.mem.print(&id_buf, fizzy.Editor.Workspaces.id_prefix ++ "{d}", .{grouping});
    try editor.app.host.registerSurface(.{ .id = id, .title = "Workspace", .keywords = &.{"slot"}, .draw = ManyPanelFrame.draw });
    try state.assign(gpa, "Target", &.{id});
    editor.demo.editor = editor;
    editor.app.host.installFizzyApi(.{ .ctx = editor, .vtable = &fizzy.Editor.fizzy_api_vtable });
    try std.testing.expectEqual(@as(?fizzy.Editor.Layout.State.SplitTree.Side, null), fizzy.Editor.Demo.besideEdge(&editor.demo, "Source"));
}

// `core` is not a test root, so its widgets' pure rules are tested here.
const DZ = fizzy.core.widgets.DropZones;

test "drop: the middle, each side and the trash are their bubbles; off them, nothing" {
    const w = DZ.wheel(.{ .x = 0, .y = 0, .w = 800, .h = 600 }, 1, true);
    try std.testing.expect(DZ.at(w, .{ .x = 400, .y = 300 }).?.eql(.center));
    try std.testing.expect(DZ.at(w, w.bubble(.{ .edge = .left }).c).?.eql(.{ .edge = .left }));
    try std.testing.expect(DZ.at(w, w.bubble(.{ .edge = .right }).c).?.eql(.{ .edge = .right }));
    try std.testing.expect(DZ.at(w, w.bubble(.{ .edge = .top }).c).?.eql(.{ .edge = .top }));
    try std.testing.expect(DZ.at(w, w.bubble(.{ .edge = .bottom }).c).?.eql(.{ .edge = .bottom }));
    try std.testing.expect(DZ.at(w, w.bubble(.remove).c).?.eql(.remove));
    // The place's own edges are off the drop.
    try std.testing.expect(DZ.at(w, .{ .x = 10, .y = 300 }) == null);
    try std.testing.expect(DZ.at(w, .{ .x = 400, .y = 590 }) == null);
    // Without the trash offered, its bubble is nothing.
    const plain = DZ.wheel(.{ .x = 0, .y = 0, .w = 800, .h = 600 }, 1, false);
    try std.testing.expect(DZ.at(plain, plain.bubble(.remove).c) == null);
}

test "drop: a carried drop chooses the bubble it is into, wherever the finger is" {
    const w = DZ.wheel(.{ .x = 0, .y = 0, .w = 800, .h = 600 }, 1, true);
    const r: f32 = 52;
    // A drop riding up and left of a finger, its middle just past the left bubble's rim: the
    // finger is off every bubble, the drop is into the left one.
    const left = w.bubble(.{ .edge = .left });
    const c: dvui.Point.Physical = .{ .x = left.c.x - left.r - r * 0.5, .y = left.c.y };
    const finger: dvui.Point.Physical = .{ .x = c.x + r, .y = c.y + r };
    try std.testing.expect(DZ.at(w, finger) == null);
    try std.testing.expect(DZ.atDisc(w, c, r).?.eql(.{ .edge = .left }));
    // Touching none of them, it chooses none.
    try std.testing.expect(DZ.atDisc(w, .{ .x = 20, .y = 20 }, r) == null);
    // Over the middle, the middle: the nearest for their sizes, not the first it touches.
    try std.testing.expect(DZ.atDisc(w, .{ .x = 410, .y = 300 }, r).?.eql(.center));
    // A point reads as it always has.
    try std.testing.expect(DZ.atDisc(w, .{ .x = 400, .y = 300 }, 0).?.eql(.center));
}

test "drop: settled bubbles stand clear of each other" {
    const w = DZ.wheel(.{ .x = 0, .y = 0, .w = 800, .h = 600 }, 1, true);
    for (DZ.all, 0..) |a, i| for (DZ.all[i + 1 ..]) |b| {
        const p = w.bubble(a);
        const q = w.bubble(b);
        const dx = p.c.x - q.c.x;
        const dy = p.c.y - q.c.y;
        try std.testing.expect(@sqrt(dx * dx + dy * dy) > p.r + q.r);
    };
}

test "drop: a small place shows the whole of it" {
    const b: dvui.Rect.Physical = .{ .x = 0, .y = 0, .w = 120, .h = 90 };
    const w = DZ.wheel(b, 2, true);
    try std.testing.expect(b.contains(w.rect().topLeft()));
    try std.testing.expect(w.rect().h <= b.h);
    try std.testing.expect(DZ.at(w, b.center()).?.eql(.center));
}

/// `w`'s bubbles lie in one line through the place's middle, in `order` along it, each reading as
/// its own zone, all of them inside `place`.
fn expectStrip(w: DZ.Wheel, place: dvui.Rect.Physical, order: []const DZ.Zone) !void {
    const across = w.dir == .horizontal;
    var last: f32 = -std.math.floatMax(f32);
    for (order) |z| {
        const b = w.bubble(z);
        try std.testing.expectApproxEqAbs(if (across) place.center().y else place.center().x, if (across) b.c.y else b.c.x, 0.01);
        const along = if (across) b.c.x else b.c.y;
        try std.testing.expect(along > last);
        last = along;
        try std.testing.expect(DZ.at(w, b.c).?.eql(z));
    }
    try std.testing.expect(DZ.at(w, place.center()).?.eql(.center));
    const r = w.rect();
    try std.testing.expect(place.contains(r.topLeft()) and place.contains(r.bottomRight()));
}

test "drop: a long, skinny place lines its drop up along it, bigger than a wheel there" {
    // A bottom panel, 1000 by 200: a wheel would be cut to 200 tall, a strip along it is not.
    const panel: dvui.Rect.Physical = .{ .x = 0, .y = 400, .w = 1000, .h = 200 };
    const across = DZ.wheel(panel, 1, true);
    try std.testing.expectEqual(@as(f32, 1), across.strip);
    try std.testing.expectEqual(dvui.enums.Direction.horizontal, across.dir);
    try std.testing.expect(across.unit > across.shaped(0, across.dir).unit * DZ.strip_gain);
    // The place's ends at the ends, its top and bottom either side of the middle, the trash past the end.
    try expectStrip(across, panel, &.{ .{ .edge = .left }, .{ .edge = .top }, .center, .{ .edge = .bottom }, .{ .edge = .right }, .remove });
    // Without the trash, the same line less it.
    const plain = DZ.wheel(panel, 1, false);
    try expectStrip(plain, panel, &.{ .{ .edge = .left }, .{ .edge = .top }, .center, .{ .edge = .bottom }, .{ .edge = .right } });
    try std.testing.expect(DZ.at(plain, across.bubble(.remove).c) == null);

    // A narrow sidebar, 260 by 800, on a display at twice the scale: down it.
    const side: dvui.Rect.Physical = .{ .x = 0, .y = 0, .w = 520, .h = 1600 };
    const down = DZ.wheel(side, 2, true);
    try std.testing.expectEqual(@as(f32, 1), down.strip);
    try std.testing.expectEqual(dvui.enums.Direction.vertical, down.dir);
    try std.testing.expect(down.unit > down.shaped(0, down.dir).unit * DZ.strip_gain);
    try expectStrip(down, side, &.{ .{ .edge = .top }, .{ .edge = .left }, .center, .{ .edge = .right }, .{ .edge = .bottom }, .remove });
}

test "drop: a place with room for the wheel keeps it" {
    // Roomy: the wheel at full size, and so would a strip be.
    try std.testing.expectEqual(@as(f32, 0), DZ.wheel(.{ .x = 0, .y = 0, .w = 800, .h = 600 }, 1, true).strip);
    try std.testing.expectEqual(@as(f32, 0), DZ.wheel(.{ .x = 0, .y = 0, .w = 600, .h = 2000 }, 1, true).strip);
    // Small but not skinny: a strip would be smaller still.
    try std.testing.expectEqual(@as(f32, 0), DZ.wheel(.{ .x = 0, .y = 0, .w = 200, .h = 200 }, 1, true).strip);
    // Narrow, but a wheel there is all but as big as a strip would be.
    const near = DZ.wheel(.{ .x = 0, .y = 0, .w = 340, .h = 1000 }, 1, true);
    try std.testing.expectEqual(@as(f32, 0), near.strip);
    try std.testing.expect(near.shaped(1, .vertical).unit > near.unit);
}

const ShapeFrame = struct {
    var wheel: DZ.Wheel = undefined;
    const key: dvui.Id = @fromBackingInt(@intCast(0x5a_a9_e0_01));

    fn frame() anyerror!dvui.App.Result {
        _ = DZ.draw(key, wheel, 1, .{});
        return .ok;
    }

    fn strip() !f32 {
        return (DZ.shapeOf(key) orelse return error.TestUnexpectedResult).strip;
    }
};

test "drop: a drop comes in in its shape, and changes into another over time" {
    var t = try dvui.testing.init(.{ .allocator = std.testing.allocator, .window_size = .{ .w = 1000, .h = 1000 } });
    defer t.deinit();
    defer DZ.forget(ShapeFrame.key);

    // Arriving over a bottom panel: a strip from the first frame, not a wheel turning into one.
    ShapeFrame.wheel = DZ.wheel(.{ .x = 0, .y = 800, .w = 1000, .h = 200 }, 1, true);
    try std.testing.expectEqual(@as(f32, 1), ShapeFrame.wheel.strip);
    _ = try dvui.testing.step(ShapeFrame.frame);
    try std.testing.expectEqual(@as(f32, 1), try ShapeFrame.strip());
    try dvui.testing.settle(ShapeFrame.frame);

    // The place grows tall enough for the wheel: the strip goes over to it over several frames
    // (100ms each), not at once, and settles there.
    ShapeFrame.wheel = DZ.wheel(.{ .x = 0, .y = 400, .w = 1000, .h = 600 }, 1, true);
    try std.testing.expectEqual(@as(f32, 0), ShapeFrame.wheel.strip);
    _ = try dvui.testing.step(ShapeFrame.frame);
    _ = try dvui.testing.step(ShapeFrame.frame);
    const partway = try ShapeFrame.strip();
    try std.testing.expect(partway > 0 and partway < 1);
    try dvui.testing.settle(ShapeFrame.frame);
    try std.testing.expectEqual(@as(f32, 0), try ShapeFrame.strip());

    // A strip across given a strip down goes back through the wheel to turn.
    ShapeFrame.wheel = DZ.wheel(.{ .x = 0, .y = 800, .w = 1000, .h = 200 }, 1, true);
    try dvui.testing.settle(ShapeFrame.frame);
    try std.testing.expectEqual(dvui.enums.Direction.horizontal, DZ.shapeOf(ShapeFrame.key).?.dir);
    ShapeFrame.wheel = DZ.wheel(.{ .x = 0, .y = 0, .w = 200, .h = 1000 }, 1, true);
    try std.testing.expectEqual(dvui.enums.Direction.vertical, ShapeFrame.wheel.dir);
    var through_wheel = false;
    for (0..40) |_| {
        _ = try dvui.testing.step(ShapeFrame.frame);
        const now = DZ.shapeOf(ShapeFrame.key).?;
        if (now.strip == 0) through_wheel = true;
        // Never running the new way before it has been the wheel.
        if (!through_wheel) try std.testing.expectEqual(dvui.enums.Direction.horizontal, now.dir);
    }
    try std.testing.expect(through_wheel);
    try std.testing.expectEqual(@as(f32, 1), try ShapeFrame.strip());
    try std.testing.expectEqual(dvui.enums.Direction.vertical, DZ.shapeOf(ShapeFrame.key).?.dir);
}

test "drop: a drop given another middle slides there over time, and comes in where it is given" {
    var t = try dvui.testing.init(.{ .allocator = std.testing.allocator, .window_size = .{ .w = 1000, .h = 1000 } });
    defer t.deinit();
    defer DZ.forget(ShapeFrame.key);

    // Arriving: where it is given from the first frame, not sliding in from anywhere.
    ShapeFrame.wheel = DZ.wheel(.{ .x = 0, .y = 0, .w = 1000, .h = 1000 }, 1, true);
    _ = try dvui.testing.step(ShapeFrame.frame);
    try std.testing.expectEqual(ShapeFrame.wheel.center, DZ.shapeOf(ShapeFrame.key).?.center);
    try dvui.testing.settle(ShapeFrame.frame);

    // The part of its place it sits in moves — a window over the place's middle came back — and
    // it goes over several frames, through the points between, to settle at the new middle.
    const from = ShapeFrame.wheel.center;
    ShapeFrame.wheel = DZ.wheel(.{ .x = 0, .y = 0, .w = 400, .h = 1000 }, 1, true);
    const to = ShapeFrame.wheel.center;
    _ = try dvui.testing.step(ShapeFrame.frame);
    _ = try dvui.testing.step(ShapeFrame.frame);
    const partway = DZ.shapeOf(ShapeFrame.key).?.center;
    try std.testing.expect(partway.x < from.x and partway.x != to.x);
    try dvui.testing.settle(ShapeFrame.frame);
    try std.testing.expectEqual(to, DZ.shapeOf(ShapeFrame.key).?.center);
    try std.testing.expectEqual(ShapeFrame.wheel.unit, DZ.shapeOf(ShapeFrame.key).?.unit);
}

test "drop: a place's drop sits in the part of it no window lies over, where it is biggest" {
    const place: dvui.Rect.Physical = .{ .x = 0, .y = 0, .w = 1000, .h = 600 };
    // Nothing over it: the place itself.
    try std.testing.expectEqual(place, DZ.uncovered(place, &.{}, 1, true).?);
    // A window off the place covers none of it.
    try std.testing.expectEqual(place, DZ.uncovered(place, &.{.{ .x = 1200, .y = 0, .w = 100, .h = 100 }}, 1, true).?);
    // A window over its middle and right: the left of it, as tall as the place, where the whole
    // wheel fits — not a strip along the top, which would shrink it.
    const win: dvui.Rect.Physical = .{ .x = 450, .y = 150, .w = 600, .h = 300 };
    const r = DZ.uncovered(place, &.{win}, 1, true).?;
    try std.testing.expectEqual(dvui.Rect.Physical{ .x = 0, .y = 0, .w = 450, .h = 600 }, r);
    try std.testing.expect(r.intersect(win).w <= 0);
    // Two windows with a gap between them: the gap, if the drop is biggest there.
    const two = DZ.uncovered(place, &.{ .{ .x = 0, .y = 0, .w = 300, .h = 600 }, .{ .x = 700, .y = 0, .w = 300, .h = 600 } }, 1, true).?;
    try std.testing.expectEqual(dvui.Rect.Physical{ .x = 300, .y = 0, .w = 400, .h = 600 }, two);
    // All of it covered: no drop.
    try std.testing.expect(DZ.uncovered(place, &.{.{ .x = -10, .y = -10, .w = 1100, .h = 700 }}, 1, true) == null);
}

test "drop: settled, as a wheel or a strip, no two bubbles are near enough to run together" {
    // Two bubbles closer than half the merge run together (`LiquidField`'s smooth minimum, and the
    // OS's glass container alike): at rest each zone is a bubble of its own, whichever the shape
    // and the way it runs, with the trash and without. On the way from one shape to the other, and
    // swollen while the carried view is aimed at one, they may run together.
    const room = DZ.wheel(.{ .x = 0, .y = 0, .w = 1e5, .h = 1e5 }, 1, true);
    try std.testing.expectEqual(@as(f32, 1), room.unit);
    for ([_]bool{ true, false }) |remove| for ([_]dvui.enums.Direction{ .horizontal, .vertical }) |dir| for ([_]f32{ 0, 1 }) |strip| {
        var base = room;
        base.remove = remove;
        const w = base.shaped(strip, dir);
        try std.testing.expectEqual(@as(f32, 1), w.unit);
        for (DZ.all, 0..) |a, j| for (DZ.all[j + 1 ..]) |b| {
            if ((a == .remove or b == .remove) and !remove) continue;
            const p = w.bubble(a);
            const q = w.bubble(b);
            const d = @sqrt((p.c.x - q.c.x) * (p.c.x - q.c.x) + (p.c.y - q.c.y) * (p.c.y - q.c.y));
            try std.testing.expect(d - p.r - q.r > DZ.merge / 2);
        };
    };
}

test "drop: aimed at, a bubble swells into one beside it, overlapping none, and the trash joins none" {
    // The bubble the carried view is aimed at grows by `join_swell` — the trash keeps its size:
    // swollen, it runs into at least one bubble beside it and overlaps none, and the trash stays a
    // drop of its own.
    const room = DZ.wheel(.{ .x = 0, .y = 0, .w = 1e5, .h = 1e5 }, 1, true);
    for ([_]dvui.enums.Direction{ .horizontal, .vertical }) |dir| for ([_]f32{ 0, 1 }) |strip| {
        const w = room.shaped(strip, dir);
        for (DZ.all, 0..) |aimed, ai| {
            if (aimed == .remove) continue;
            var joins = false;
            for (DZ.all, 0..) |a, i| for (DZ.all[i + 1 ..], i + 1..) |b, j| {
                const p = w.bubble(a);
                const q = w.bubble(b);
                const pr = p.r * (if (i == ai) 1 + DZ.join_swell else 1);
                const qr = q.r * (if (j == ai) 1 + DZ.join_swell else 1);
                const d = @sqrt((p.c.x - q.c.x) * (p.c.x - q.c.x) + (p.c.y - q.c.y) * (p.c.y - q.c.y));
                const gap = d - pr - qr;
                try std.testing.expect(gap > 0);
                if (a == .remove or b == .remove) {
                    try std.testing.expect(gap > DZ.merge / 2);
                } else if ((i == ai or j == ai) and gap < DZ.merge / 2) joins = true;
            };
            try std.testing.expect(joins);
        }
    };
}

test "liquid blob: far apart it is its discs; close together it bridges them" {
    const LB = fizzy.core.liquid_blob;
    const two = [_]LB.Disc{ .{ .c = .{ .x = 0, .y = 0 }, .r = 10 }, .{ .c = .{ .x = 100, .y = 0 }, .r = 10 } };
    try std.testing.expectApproxEqAbs(@as(f32, -10), LB.field(&two, 2, .{ .x = 0, .y = 0 }).d, 0.01);
    try std.testing.expectApproxEqAbs(@as(f32, 5), LB.field(&two, 2, .{ .x = 15, .y = 0 }).d, 0.01);
    const close = [_]LB.Disc{ .{ .c = .{ .x = 0, .y = 0 }, .r = 10 }, .{ .c = .{ .x = 22, .y = 0 }, .r = 10 } };
    try std.testing.expect(LB.field(&close, 8, .{ .x = 11, .y = 0 }).d < 0);
    try std.testing.expect(LB.field(&close, 0.5, .{ .x = 11, .y = 0 }).d > 0);
}

test "liquid field: a rounded box's outline is its rect with its own corner per corner" {
    const LF = fizzy.core.LiquidField;
    var f: LF = .{};
    // 100 x 60, a 20 radius at the top left and none elsewhere.
    f.add(.{ .rect = .{ .x = 0, .y = 0, .w = 100, .h = 60 }, .radii = .{ 20, 0, 0, 0 } });
    try std.testing.expectApproxEqAbs(@as(f32, -30), f.sample(.{ .x = 50, .y = 30 }).d, 0.01);
    // On a straight side, and just outside it.
    try std.testing.expectApproxEqAbs(@as(f32, 0), f.sample(.{ .x = 50, .y = 0 }).d, 0.01);
    try std.testing.expectApproxEqAbs(@as(f32, 0.5), f.sample(.{ .x = 50, .y = 60 }).coverage, 0.01);
    try std.testing.expectApproxEqAbs(@as(f32, 0), f.sample(.{ .x = 50, .y = 60.5 }).coverage, 0.01);
    // The square corners are square; the round one cuts its corner off.
    try std.testing.expect(f.sample(.{ .x = 99.5, .y = 59.5 }).d < 0);
    try std.testing.expect(f.sample(.{ .x = 1, .y = 1 }).d > 0);
    const at45: f32 = 20.0 - 20.0 / std.math.sqrt2;
    try std.testing.expectApproxEqAbs(@as(f32, 0), f.sample(.{ .x = at45, .y = at45 }).d, 0.01);
    try std.testing.expect(f.hit(.{ .x = 50, .y = 30 }) and !f.hit(.{ .x = 2, .y = 2 }));
}

test "liquid field: a shape near its place's edge joins it by a neck, and none of it crosses the edge" {
    const LF = fizzy.core.LiquidField;
    // A place 200 x 100 at the origin, a 24 radius at its top right; a drop 6px in from its top.
    var f: LF = .{ .merge_px = 16, .edge = .{ .rect = .{ .x = 0, .y = 0, .w = 200, .h = 100 }, .radii = .{ 0, 24, 0, 0 } } };
    f.add(LF.Shape.circle(.{ .x = 100, .y = 26 }, 20));
    // Between the drop and the edge, a neck: glass where the drop alone has none.
    try std.testing.expect(f.sample(.{ .x = 100, .y = 3 }).d < 0);
    var alone: LF = .{ .merge_px = 16 };
    alone.add(LF.Shape.circle(.{ .x = 100, .y = 26 }, 20));
    try std.testing.expect(alone.sample(.{ .x = 100, .y = 3 }).d > 0);
    // The neck is only near the drop: along the edge away from it, no glass, not even a sliver.
    try std.testing.expectEqual(@as(f32, 0), f.sample(.{ .x = 20, .y = 0.5 }).coverage);
    try std.testing.expectEqual(@as(f32, 0), f.sample(.{ .x = 20, .y = 3 }).coverage);
    // A drop pushed past the edge is cut at it: none of it outside the place.
    var past: LF = .{ .merge_px = 16, .edge = .{ .rect = .{ .x = 0, .y = 0, .w = 200, .h = 100 } } };
    past.add(LF.Shape.circle(.{ .x = 100, .y = 0 }, 20));
    try std.testing.expectEqual(@as(f32, 0), past.sample(.{ .x = 100, .y = -5 }).coverage);
    try std.testing.expect(past.sample(.{ .x = 100, .y = 5 }).d < 0);
    // Round the curved corner too: a point past the curve, inside the rect, is outside the place.
    var corner: LF = .{ .merge_px = 16, .edge = .{ .rect = .{ .x = 0, .y = 0, .w = 200, .h = 100 }, .radii = .{ 0, 24, 0, 0 } } };
    corner.add(LF.Shape.circle(.{ .x = 200, .y = 0 }, 20));
    try std.testing.expectEqual(@as(f32, 0), corner.sample(.{ .x = 199, .y = 1 }).coverage);
    try std.testing.expect(corner.sample(.{ .x = 190, .y = 10 }).d < 0);
    // A field with an edge holds one shape fewer: the last slot is the edge's.
    var full: LF = .{ .edge = .{ .rect = .{ .x = 0, .y = 0, .w = 200, .h = 100 } } };
    for (0..LF.max_shapes) |_| full.add(LF.Shape.circle(.{ .x = 50, .y = 50 }, 5));
    try std.testing.expectEqual(LF.max_shapes - 1, full.len);
}

test "liquid field: shapes bridge within the merge width, swell no more than a quarter of it, and part beyond" {
    const LF = fizzy.core.LiquidField;
    var f: LF = .{ .merge_px = 16 };
    f.add(LF.Shape.circle(.{ .x = 0, .y = 0 }, 20));
    f.add(LF.Shape.circle(.{ .x = 46, .y = 0 }, 20));
    // A 6px gap, under half the merge width: bridged across the middle (the smooth minimum
    // deepens by at most k/4 there, so a gap closes below k/2).
    try std.testing.expect(f.sample(.{ .x = 23, .y = 0 }).d < 0);
    // Part them past the merge width: two drops again, the gap clear.
    f.shapes[1] = LF.Shape.circle(.{ .x = 60, .y = 0 }, 20);
    try std.testing.expect(f.sample(.{ .x = 30, .y = 0 }).d > 0);
    try std.testing.expectApproxEqAbs(@as(f32, -20), f.sample(.{ .x = 0, .y = 0 }).d, 0.01);
    // Many piled on one spot swell the outline by at most k/4.
    var pile: LF = .{ .merge_px = 16 };
    for (0..6) |_| pile.add(LF.Shape.circle(.{ .x = 0, .y = 0 }, 20));
    try std.testing.expect(pile.sample(.{ .x = 20 + 16.0 / 4.0 + 0.01, .y = 0 }).d > 0);
    // Across a bridge the materials blend: a lit drop's light runs into the neck.
    var lit: LF = .{ .merge_px = 16 };
    var a = LF.Shape.circle(.{ .x = 0, .y = 0 }, 20);
    a.light = 1;
    lit.add(a);
    lit.add(LF.Shape.circle(.{ .x = 46, .y = 0 }, 20));
    const mid = lit.sample(.{ .x = 23, .y = 0 }).light;
    try std.testing.expect(mid > 0 and mid < 1);
}

test "liquid field: groups are the shapes that touch, each drawn as its own quad" {
    const LF = fizzy.core.LiquidField;
    var f: LF = .{ .merge_px = 10 };
    f.add(LF.Shape.circle(.{ .x = 0, .y = 0 }, 10));
    f.add(LF.Shape.circle(.{ .x = 300, .y = 0 }, 10));
    f.add(LF.Shape.circle(.{ .x = 22, .y = 0 }, 10));
    const g = f.clusters();
    try std.testing.expectEqual(@as(usize, 2), g.count);
    try std.testing.expectEqual(@as(u8, 2), g.size[0]);
    try std.testing.expectEqual(@as(u8, 1), g.size[1]);
    // The uniforms are the shader's `uData`: its header, then three vec4s a shape.
    try std.testing.expectEqual(@as(usize, (11 + 3 * LF.max_shapes) * 16), @sizeOf(LF.Uniforms));
    const u = f.pack(.{ .x = 0, .y = 0, .w = 400, .h = 100 }, false, g.order[0..f.len]);
    try std.testing.expectEqual(@as(f32, 22), u.shapes[1][0][0]);
}

test "liquid field: fizzy's default look packs to today's uniforms for every role" {
    const LF = fizzy.core.LiquidField;
    const gl = fizzy.core.glass_look;
    var i: usize = 0;
    while (i <= 10) : (i += 1) {
        const opacity: f32 = @as(f32, @floatFromInt(i)) / 10;
        const looks = fizzy.core.material.Looks.fromOpacity(opacity);
        // Today's looks, as `forDrops`, `forText` and `forLens` made them of `inApp`.
        const base = gl.inApp(opacity);
        const today = [_]struct { role: gl.Role, look: gl.Look }{
            .{ .role = .drop, .look = gl.forDrops(base) },
            .{ .role = .card, .look = gl.forDrops(base) },
            .{ .role = .bar, .look = gl.forDrops(base) },
            .{ .role = .text, .look = gl.forText(base) },
            .{ .role = .lens, .look = gl.forLens(base) },
        };
        for (today) |t| {
            var f: LF = .{ .tint = .{ .r = 10, .g = 20, .b = 30, .a = 200 }, .mix = 0.5, .lift = 0.2, .role = t.role };
            f.add(LF.Shape.circle(.{ .x = 50, .y = 50 }, 40));
            const order = [_]u8{0};
            var u = f.pack(.{ .x = 0, .y = 0, .w = 100, .h = 100 }, false, &order);
            f.applyLook(&u, looks.get(t.role));
            const l = t.look;
            try std.testing.expectEqual(std.math.clamp(l.mix, 0, 1), u.face[0]);
            // The flat lift of before is the wash, equal top and bottom, and nothing else.
            try std.testing.expectEqual(std.math.clamp(l.wash_top, 0, 1), u.face[1] + u.curves[0]);
            try std.testing.expectEqual(u.curves[0], u.curves[1]);
            // The new curves are the identity: no sweep, no cap, the hairline as dark as it was.
            try std.testing.expectEqual(@as(f32, 0), u.curves[2]);
            try std.testing.expectEqual(@as(f32, 1), u.curves[3]);
            try std.testing.expectEqual(@as(f32, 0.85), u.widths[0]);
            const old_lift: f32 = if (t.role == .lens) 0 else 0.03 * gl.way(opacity).shine;
            try std.testing.expectEqual(old_lift, u.curves[0]);
            try std.testing.expectEqual(@max(l.bevel, 0.0001), u.dither[1]);
            try std.testing.expectEqual(l.bend * 0.5, u.dither[2]);
            try std.testing.expectEqual(l.shade, u.dither[3]);
            try std.testing.expectEqual(l.dispersion, u.backdrop[1]);
            try std.testing.expectEqual(l.diagonal, u.backdrop[2]);
            try std.testing.expectEqual(l.rim, u.rim[3]);
            try std.testing.expectEqual(l.frost * f.shapes[0].blur, u.shapes[0][2][0]);
        }
    }
}

test "liquid field: fizzy's looks pack the lit edge off" {
    const LF = fizzy.core.LiquidField;
    const gl = fizzy.core.glass_look;
    for ([_]f32{ 0.05, 0.5, 1 }) |opacity| {
        const looks = fizzy.core.material.Looks.fromOpacity(opacity);
        inline for (comptime std.enums.values(gl.Role)) |which| {
            var f: LF = .{ .tint = .{ .r = 10, .g = 20, .b = 30, .a = 200 }, .mix = 0.5, .lift = 0.2, .role = which };
            f.add(LF.Shape.circle(.{ .x = 50, .y = 50 }, 40));
            const order = [_]u8{0};
            var u = f.pack(.{ .x = 0, .y = 0, .w = 100, .h = 100 }, false, &order);
            f.applyLook(&u, looks.get(which));
            try std.testing.expectEqual([4]f32{ 0, 0, 0, 0 }, u.edge);
            try std.testing.expectApproxEqAbs(@as(f32, -0.70710678), u.light[0], 1e-6);
            try std.testing.expectApproxEqAbs(@as(f32, -0.70710678), u.light[1], 1e-6);
            try std.testing.expectEqual(@as(f32, 0.5), u.light[2]);
            try std.testing.expectEqual(@as(f32, 0), u.light[3]);
            try std.testing.expectEqual(@as(f32, 0), u.widths[3]);
            try std.testing.expectEqual(@as(f32, 0.85), u.widths[0]);
        }
    }
}

test "liquid field: an app look's curves reach the uniforms, a surface keeps its own lift" {
    const LF = fizzy.core.LiquidField;
    var look = fizzy.core.material.Looks.fromOpacity(0.6).card;
    look.sweep = 0.11;
    look.ceiling = 0.6;
    look.wash_top = 0.107;
    look.wash_bottom = 0.04;
    look.edge_dark = 0.3;
    var f: LF = .{ .tint = .{ .r = 0, .g = 0, .b = 0, .a = 255 }, .lift = 0.2, .role = .card };
    f.add(LF.Shape.circle(.{ .x = 50, .y = 50 }, 40));
    const order = [_]u8{0};
    var u = f.pack(.{ .x = 0, .y = 0, .w = 100, .h = 100 }, false, &order);
    f.applyLook(&u, look);
    try std.testing.expectEqual([4]f32{ 0.107, 0.04, 0.11, 0.6 }, u.curves);
    try std.testing.expectEqual(@as(f32, 0.3), u.widths[0]);
    // A surface's colour is its own: its lift stays, and the look's wash does not reach it.
    var surface = f;
    surface.surface = true;
    var us = surface.pack(.{ .x = 0, .y = 0, .w = 100, .h = 100 }, false, &order);
    surface.applyLook(&us, look);
    try std.testing.expectEqual(@as(f32, 0.2), us.face[1]);
    try std.testing.expectEqual(@as(f32, 0), us.curves[0]);
    try std.testing.expectEqual(@as(f32, 0), us.curves[2]);
    surface.surface = false;
    surface.window = true;
    var uw = surface.pack(.{ .x = 0, .y = 0, .w = 100, .h = 100 }, false, &order);
    surface.applyLook(&uw, look);
    try std.testing.expectEqual(@as(f32, 0), uw.curves[2]);
}

test "liquid field: a lens's picture reaches as far past its shapes as the earlier glass's rim pulls from" {
    const LF = fizzy.core.LiquidField;
    var f: LF = .{ .scale = 2, .refraction = 1 };
    f.add(LF.Shape.circle(.{ .x = 100, .y = 100 }, 60));
    // The earlier glass (the web's) pulls its rim from `liquid_glass.refraction` points out at full
    // strength: a picture reaching that far past the shape has something there to show.
    try std.testing.expect(f.pictureMargin() >= fizzy.core.liquid_glass.refraction * 2);
    // Further at the strongest refraction setting.
    var strong = f;
    strong.refraction = 2;
    try std.testing.expect(strong.pictureMargin() > f.pictureMargin());
    // And further for a stronger lens on its shape.
    var bent = f;
    bent.shapes[0].lens = 1.5;
    try std.testing.expect(bent.pictureMargin() > f.pictureMargin());
    // Nothing in fizzy draws one (pixi's dropper magnifier does): compiled here all the same.
    _ = &LF.drawPicture;
}

test "liquid glass: the rings of a pane run the way dvui's paths do" {
    const r: dvui.Rect.Physical = .{ .x = 0, .y = 0, .w = 200, .h = 100 };
    var pts: [4 * 7 + 2 * (8 - 1) + 2 * (4 - 1)]dvui.Point.Physical = undefined;
    fizzy.core.liquid_glass.ringPoints(&pts, null, r, fizzy.core.liquid_glass.uniform(8), 0, 6, 8, 4);
    // Shoelace: the sign of dvui's own rect path (top-left, bottom-left, bottom-right,
    // top-right), which is negative in these coordinates.
    var area: f32 = 0;
    for (pts, 0..) |p, i| {
        const q = pts[(i + 1) % pts.len];
        area += p.x * q.y - q.x * p.y;
    }
    try std.testing.expect(area < 0);
    // Starts at the top of the top-left corner.
    try std.testing.expectApproxEqAbs(@as(f32, 8), pts[0].x, 0.01);
    try std.testing.expectApproxEqAbs(@as(f32, 0), pts[0].y, 0.01);
}

fn peakOf(comptime f: fn (f32, f32) f32, lv: f32) f32 {
    var peak: f32 = 0;
    var t: f32 = 0;
    while (t <= 1) : (t += 0.005) peak = @max(peak, f(lv, t));
    return peak;
}

test "motion: failed migration leaves startup preferences usable and legacy data intact" {
    var ctx = try shim.init(std.testing.allocator);
    defer ctx.deinit(std.testing.allocator);
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(io, ".", gpa);
    defer gpa.free(root);
    const settings = try std.fs.path.join(gpa, &.{ root, "settings.zon" });
    defer gpa.free(settings);
    const blocked = try std.fs.path.join(gpa, &.{ root, "blocked" });
    defer gpa.free(blocked);
    try tmp.dir.writeFile(io, .{ .sub_path = "settings.zon", .data = ".{ .motion = 0.6 }" });
    try tmp.dir.writeFile(io, .{ .sub_path = "blocked", .data = "a file cannot be a config directory" });
    ctx.editor.app.gpa = gpa;
    ctx.editor.person_dir = blocked;
    ctx.editor.loadPerson(settings);
    try std.testing.expectEqual(@as(?f32, null), ctx.editor.person.motion);
    const data = try fizzy.core.fs.read(gpa, io, settings);
    defer gpa.free(data);
    try std.testing.expectEqualStrings(".{ .motion = 0.6 }", data);
    try tmp.dir.deleteFile(io, "blocked");
    ctx.editor.loadPerson(settings);
    try std.testing.expectEqual(@as(?f32, 0.6), ctx.editor.person.motion);
}

test "motion: a profiled instance keeps person.zon under its profile root" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(io, ".", gpa);
    defer gpa.free(root);

    const profiled = try fizzy.Editor.personDir(gpa, root, "/the/persons/config");
    defer gpa.free(profiled);
    try std.testing.expectEqualStrings(root, profiled);
    try fizzy.core.person.save(io, profiled, .{ .motion = 0.2 });
    try tmp.dir.access(io, "person.zon", .{});

    const shared = try fizzy.Editor.personDir(gpa, null, "/the/persons/config");
    defer gpa.free(shared);
    const want_shared = try std.fs.path.join(gpa, &.{ "/the/persons/config", "fizzyedit" });
    defer gpa.free(want_shared);
    try std.testing.expectEqualStrings(want_shared, shared);
}

test "motion: migration and focus share the person's choice across app configs" {
    var ctx = try shim.init(std.testing.allocator);
    defer ctx.deinit(std.testing.allocator);
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(io, ".", gpa);
    defer gpa.free(root);
    const person_dir = try std.fs.path.join(gpa, &.{ root, "person" });
    defer gpa.free(person_dir);
    const Migration = @import("app").settings.Migration;
    try tmp.dir.createDirPath(io, "first");
    try tmp.dir.createDirPath(io, "second");
    const first = try std.fs.path.join(gpa, &.{ root, "first", "settings.zon" });
    defer gpa.free(first);
    const second = try std.fs.path.join(gpa, &.{ root, "second", "settings.zon" });
    defer gpa.free(second);
    try fizzy.core.fs.write(io, first, ".{ .motion = 0.6 }");
    try Migration.personMotion(gpa, io, first, person_dir);
    try std.testing.expectEqual(@as(?f32, 0.6), fizzy.core.person.load(io, person_dir).motion);
    const migrated = try fizzy.core.fs.read(gpa, io, first);
    defer gpa.free(migrated);
    try std.testing.expect(std.mem.find(u8, migrated, ".motion =") == null);

    try fizzy.core.person.save(io, person_dir, .{ .motion = 0.2 });
    try fizzy.core.fs.write(io, second, ".{ .motion = 0.6 }");
    try Migration.personMotion(gpa, io, second, person_dir);
    try std.testing.expectEqual(@as(?f32, 0.2), fizzy.core.person.load(io, person_dir).motion);

    const editor = ctx.editor;
    editor.app.gpa = gpa;
    editor.person_dir = person_dir;
    editor.person_mtime = null;
    editor.reloadPerson();
    try std.testing.expectEqual(@as(f32, 0.2), fizzy.core.person.motionLevel(editor.person, 1));
    try fizzy.core.person.save(io, person_dir, .{ .motion = 0.8 });
    // Coarse filesystem clocks can give consecutive replacements the same timestamp.
    const shared = try tmp.dir.openFile(io, "person/person.zon", .{ .mode = .read_write });
    defer shared.close(io);
    try shared.setTimestamps(io, .{ .modify_timestamp = .{ .new = .{ .nanoseconds = @intCast(editor.person_mtime.? + std.time.ns_per_s) } } });
    editor.reloadPerson();
    try std.testing.expectEqual(@as(f32, 0.8), fizzy.core.person.motionLevel(editor.person, 0.3));
    const M = fizzy.core.motion;
    M.publish(fizzy.core.person.motionLevel(.{}, 0.3), M.default_speed, false, false, 1);
    try std.testing.expectEqual(@as(f32, 0.3), M.level());
    for ([_]f32{ 0.3, 1 }) |app_level| {
        M.publish(fizzy.core.person.motionLevel(editor.person, app_level), M.default_speed, false, false, 1);
        try std.testing.expectEqual(@as(f32, 0.8), M.level());
    }
    for ([_]?f32{ null, 0, 0.8, 1 }) |level| {
        M.publish(fizzy.core.person.motionLevel(.{ .motion = level }, 1), M.default_speed, true, false, 1);
        try std.testing.expect(M.off());
    }
}

test "motion: pending shared choices stay in memory until flushed" {
    var ctx = try shim.init(std.testing.allocator);
    defer ctx.deinit(std.testing.allocator);
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir = try tmp.dir.realPathFileAlloc(io, ".", gpa);
    defer gpa.free(dir);
    ctx.editor.app.gpa = gpa;
    ctx.editor.person_dir = dir;
    try fizzy.core.person.save(io, dir, .{ .motion = 0.2 });
    ctx.editor.person.motion = 0.8;
    ctx.editor.markPersonDirty();
    try std.testing.expectEqual(@as(?f32, 0.2), fizzy.core.person.load(io, dir).motion);
    ctx.editor.reloadPerson();
    try std.testing.expectEqual(@as(?f32, 0.8), ctx.editor.person.motion);
    ctx.editor.savePerson();
    try std.testing.expectEqual(@as(?f32, 0.8), fizzy.core.person.load(io, dir).motion);
    try std.testing.expectEqual(@as(?i128, null), ctx.editor.person_save_deadline_ns);
}

test "motion: settings reset saves null and draws the shared default" {
    var ctx = try shim.init(std.testing.allocator);
    defer ctx.deinit(std.testing.allocator);
    const gpa = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir = try tmp.dir.realPathFileAlloc(std.testing.io, ".", gpa);
    defer gpa.free(dir);
    ctx.editor.app.gpa = gpa;
    ctx.editor.person_dir = dir;
    ctx.editor.person.motion = 0.8;
    const frame = struct {
        fn draw() !dvui.App.Result {
            var box = dvui.box(@src(), .{ .dir = .vertical }, .{ .expand = .horizontal });
            defer box.deinit();
            for (fizzy.Explorer.settings.groups) |group| for (group.items) |item| {
                if (std.mem.eql(u8, item.key, "motion")) item.draw.?();
            };
            return .ok;
        }
    }.draw;
    dvui.debug.captureFrame();
    defer dvui.debug.clearCaptures(dvui.currentWindow().gpa);
    _ = try dvui.testing.step(frame);
    _ = try dvui.testing.step(frame);
    var reset: ?dvui.Point.Physical = null;
    for (dvui.debug.lastCapture().?.widgets.items) |widget| {
        if (widget.text) |text| if (std.mem.eql(u8, text, "Reset to system default")) {
            reset = widget.rect_border.center();
        };
    }
    _ = try dvui.currentWindow().addEventMouseMotion(.{ .pt = reset orelse return error.TestUnexpectedResult });
    try dvui.testing.click(.left);
    _ = try dvui.testing.step(frame);
    try std.testing.expectEqual(@as(?f32, null), ctx.editor.person.motion);
    try std.testing.expectEqual(@as(?f32, null), fizzy.core.person.load(std.testing.io, dir).motion);
    dvui.debug.captureFrame();
    _ = try dvui.testing.step(frame);
    _ = try dvui.testing.step(frame);
    var default_shown = false;
    var shared_shown = false;
    var reset_shown = false;
    for (dvui.debug.lastCapture().?.widgets.items) |widget| {
        if (widget.text) |text| {
            if (std.mem.eql(u8, text, "Reset to system default")) reset_shown = true;
            if (std.mem.startsWith(u8, text, "System default (")) default_shown = true;
            if (std.mem.eql(u8, text, "Applies to every fizzy app.")) shared_shown = true;
        }
    }
    try std.testing.expect(default_shown);
    try std.testing.expect(shared_shown);
    try std.testing.expect(!reset_shown);
}

test "motion: every curve starts at 0 and lands on 1, at every level" {
    const M = fizzy.core.motion;
    var lv: f32 = 0;
    while (lv <= 1.0001) : (lv += 0.125) {
        try std.testing.expectApproxEqAbs(@as(f32, 0), M.enterAt(lv, 0), 1e-4);
        try std.testing.expectApproxEqAbs(@as(f32, 1), M.enterAt(lv, 1), 1e-4);
        try std.testing.expectApproxEqAbs(@as(f32, 0), M.settleAt(lv, 0), 1e-4);
        try std.testing.expectApproxEqAbs(@as(f32, 1), M.settleAt(lv, 1), 1e-4);
    }
}

test "motion: linear up to minimal, a swing past the target toward playful" {
    const M = fizzy.core.motion;
    // Up to minimal: linear to the target at `arrival`, nothing overshoots.
    for ([_]f32{ 0.001, 0.25, 0.5 }) |lv| {
        try std.testing.expectApproxEqAbs(0.3 / M.arrival, M.enterAt(lv, 0.3), 1e-4);
        try std.testing.expect(peakOf(M.enterAt, lv) <= 1.0001);
    }
    // Playful: about 12% past, and back to rest at the end.
    const playful = peakOf(M.enterAt, 1);
    try std.testing.expect(playful > 1.10 and playful < 1.15);
    try std.testing.expect(peakOf(M.enterAt, 0.75) > 1.01 and peakOf(M.enterAt, 0.75) < playful);
}

test "motion: every level arrives on time, and passes through without a kink" {
    const M = fizzy.core.motion;
    for ([_]f32{ 0.3, 0.5, 0.6, 0.75, 0.9, 1.0 }) |lv| {
        // At `arrival` of its duration it is at its target, whatever the level — and not before.
        try std.testing.expectApproxEqAbs(@as(f32, 1), M.enterAt(lv, M.arrival), 1e-4);
        try std.testing.expect(M.enterAt(lv, M.arrival * 0.95) < 0.99);
        // Leaving, it is gone the same `arrival` after it sets off, drawing back first above
        // minimal.
        try std.testing.expectApproxEqAbs(@as(f32, 1), M.exitAt(lv, M.arrival + M.swingAt(lv)), 1e-4);
        try std.testing.expect(M.exitAt(lv, (M.arrival + M.swingAt(lv)) * 0.9) < 0.99);
        // Above minimal it draws back before it leaves.
        if (M.swingAt(lv) > 0) try std.testing.expect(M.exitAt(lv, M.swingAt(lv) * 0.4) < 0);
        if (M.swingAt(lv) > 0) {
            // The same speed either side of the target. A fine step: at low levels the swing
            // turns sharply, and a coarse one reads its curvature as a kink.
            const h: f32 = 0.0001;
            const a = M.arrival;
            const before = (M.enterAt(lv, a) - M.enterAt(lv, a - h)) / h;
            const after = (M.enterAt(lv, a + h) - M.enterAt(lv, a)) / h;
            try std.testing.expectApproxEqRel(before, after, 0.02);
        }
    }
}

// -- demo automation ---------------------------------------------------------------------------
//
// The player against real widgets in a real (headless) window: a button and the text plugin's
// editor, tagged the way an app tags what a demo aims at. What is under test is the dvui half —
// that tape input arrives as events every widget handles as a person's, that a rewind replays to
// exactly the state live play reached, and that a person's input pauses the demo and is undone
// when it resumes. The sequencing rules themselves are unit-tested in `sdk/tape/`.

const automation = @import("app").automation;
const ExecutableWatcher = @import("app").watch.ExecutableWatcher;
const SettingsWatcher = @import("app").watch.SettingsWatcher;

const DemoStage = struct {
    keyframes: usize = 0,
    commands: usize = 0,
    fast: bool = false,
    begun: bool = false,
    /// The demo was let go with the app left as it was (`Stage.keep`).
    kept: bool = false,
    /// Off, the player seeks from keyframes alone.
    snapshots: bool = true,
    restores: usize = 0,
    /// On, every snapshot is refused when put back, as fizzy's are for a scene whose documents
    /// moved pane: the seek cuts to the keyframe instead.
    refuse_restores: bool = false,
    /// Restores refused while `refuse_restores` was on.
    refused: usize = 0,

    /// The whole of this app's model.
    const Snap = struct { text: []u8, clicks: usize, commands: usize };

    fn stage(self: *DemoStage) automation.Stage {
        return .{ .ctx = self, .vtable = &.{
            .begin = begin,
            .end = end,
            .keep = keep,
            .keyframe = keyframe,
            .idle = idle,
            .command = command,
            .chordFor = chordFor,
            .commandTitle = commandTitle,
            .fastForward = fastForward,
            .capture = capture,
            .restore = restore,
            .release = release,
            .fingerprint = fingerprint,
        } };
    }
    fn from(ctx: *anyopaque) *DemoStage {
        return @ptrCast(@alignCast(ctx));
    }
    fn begin(ctx: *anyopaque, _: *const automation.Tape) void {
        from(ctx).begun = true;
    }
    fn end(ctx: *anyopaque) void {
        from(ctx).begun = false;
    }
    fn keep(ctx: *anyopaque) void {
        from(ctx).begun = false;
        from(ctx).kept = true;
    }
    /// The whole of this app's state is the field's text and the button's count.
    fn keyframe(ctx: *anyopaque, kf: *const automation.Tape.Keyframe) void {
        from(ctx).keyframes += 1;
        demo_text.clearRetainingCapacity();
        if (kf.files.len > 0) demo_text.appendSlice(std.testing.allocator, kf.files[0].text) catch unreachable;
        demo_clicks = 0;
        demo_commands = 0;
    }
    fn idle(_: *anyopaque) bool {
        return true;
    }
    fn command(ctx: *anyopaque, id: []const u8, args: []const u8) void {
        if (std.mem.eql(u8, id, "demo.ping")) demo_commands += 1;
        demo_command_args.clearRetainingCapacity();
        demo_command_args.appendSlice(std.testing.allocator, args) catch unreachable;
        from(ctx).commands += 1;
    }
    fn chordFor(_: *anyopaque, _: []const u8) ?@import("app").keymap.chord.Stroke {
        return null;
    }
    fn commandTitle(_: *anyopaque, _: []const u8) ?[]const u8 {
        return "Ping";
    }
    fn fastForward(ctx: *anyopaque, on: bool) void {
        from(ctx).fast = on;
    }
    fn capture(ctx: *anyopaque) ?*anyopaque {
        if (!from(ctx).snapshots) return null;
        const snap = std.testing.allocator.create(Snap) catch return null;
        snap.* = .{
            .text = std.testing.allocator.dupe(u8, demo_text.items) catch {
                std.testing.allocator.destroy(snap);
                return null;
            },
            .clicks = demo_clicks,
            .commands = demo_commands,
        };
        return snap;
    }
    fn restore(ctx: *anyopaque, raw: *anyopaque) bool {
        const snap: *Snap = @ptrCast(@alignCast(raw));
        if (from(ctx).refuse_restores) {
            from(ctx).refused += 1;
            return false;
        }
        from(ctx).restores += 1;
        demo_text.clearRetainingCapacity();
        demo_text.appendSlice(std.testing.allocator, snap.text) catch unreachable;
        demo_clicks = snap.clicks;
        demo_commands = snap.commands;
        return true;
    }
    fn release(_: *anyopaque, raw: *anyopaque) void {
        const snap: *Snap = @ptrCast(@alignCast(raw));
        std.testing.allocator.free(snap.text);
        std.testing.allocator.destroy(snap);
    }
    fn fingerprint(_: *anyopaque) u64 {
        var h = std.hash.Wyhash.init(0);
        h.update(demo_text.items);
        h.update(std.mem.asBytes(&[_]usize{ demo_clicks, demo_commands }));
        return h.final();
    }
};

var demo_text: std.ArrayListUnmanaged(u8) = .empty;
var demo_clicks: usize = 0;
var demo_commands: usize = 0;
/// The arguments the latest command op carried, as the stage was handed them.
var demo_command_args: std.ArrayList(u8) = .empty;
var demo_stage: DemoStage = .{};
var demo_player: automation.Player = undefined;
/// What the harness hands `Player.frames` as the backend's clock: the testing backend has none of
/// its own, and its next frame's time comes from the last one's (`dvui.testing.step`) anyway.
var demo_clock: i128 = 0;
var demo_clock_on: bool = true;
/// A bar out under the demo's (a document's history bar, as `HistoryTransport` publishes it), for
/// the demo's to stack above; physical. Null: none.
var demo_other_bar: ?dvui.Rect.Physical = null;

/// The app's frame function, as an app runs it: through the player, which repeats it unseen
/// while a seek catches up.
fn demoFrame() !dvui.App.Result {
    return demo_player.frames(dvui.currentWindow(), demoRun, if (demo_clock_on) &demo_clock else null);
}

/// One run of the frame.
fn demoRun() !dvui.App.Result {
    demo_player.frame();
    for (dvui.events()) |e| {
        if (!e.handled and e.evt == .mouse and e.evt.mouse.action == .release) demo_releases += 1;
    }
    {
        var col = dvui.box(@src(), .{ .dir = .vertical }, .{ .expand = .both });
        defer col.deinit();
        if (dvui.button(@src(), "Count", .{}, .{ .tag = "demo.count" })) demo_clicks += 1;
        var te: TextEntryWidget = undefined;
        te.init(@src(), .{
            .multiline = true,
            .text = .{ .array_list = .{ .backing = &demo_text, .allocator = std.testing.allocator, .limit = 4096 } },
        }, .{ .expand = .both, .tag = "demo.field" });
        te.processEvents();
        te.draw();
        te.deinit();
    }
    if (demo_float) |*r| {
        // lint-allow(raw-transient-surface): headless test fixture, not a shown surface
        var fw = dvui.floatingWindow(@src(), .{ .rect = r }, .{ .tag = "demo.float" });
        defer fw.deinit();
        dvui.labelNoFmt(@src(), "Float", .{}, .{});
    }
    if (demo_other_bar) |b| @import("app").dome.publishBar(b);
    automation.overlay.draw(&demo_player);
    demo_callout_main = if (dvui.tagGet(automation.overlay.callout_anchor)) |td| fizzy.core.screens.isMain(td.id) else null;
    return .ok;
}

/// Pointer releases that got past the player to the app's widgets.
var demo_releases: usize = 0;

/// A float the harness draws under the overlay, as the app's are, while set (natural rect).
var demo_float: ?dvui.Rect = null;

/// Whether the callout was the main window's in the frame just run (`core.screens.markMain`).
var demo_callout_main: ?bool = null;

/// Seed, count once, click into the field, type two words with a chapter between, ping.
fn demoTape() !automation.Tape.Owned {
    var s: automation.Script = .init(std.testing.allocator, "test", "Test");
    errdefer s.deinit();
    try s.keyframe(.{ .root = "demo://test", .files = &.{.{ .path = "field", .text = "> " }} });
    try s.chapter("Count");
    try s.click(.{ .tag = "demo.count" }, .{});
    try s.chapter("Type");
    try s.click(.{ .tag = "demo.field", .x = 0.9, .y = 0.5 }, .{});
    try s.typeText("hello", .{ .cps = 20 });
    try s.chapter("More");
    try s.typeText(" world", .{ .cps = 20 });
    try s.command("demo.ping");
    return s.finish();
}

fn demoCtx() !dvui.testing {
    var t = try dvui.testing.init(.{ .allocator = std.testing.allocator, .window_size = .{ .w = 800, .h = 600 } });
    errdefer t.deinit();
    demo_text = .empty;
    demo_clicks = 0;
    demo_commands = 0;
    demo_releases = 0;
    demo_stage = .{};
    demo_float = null;
    demo_player = .init(std.testing.allocator, demo_stage.stage());
    // No wall-time budget: a seek lands in the step that asked for it, whatever the machine.
    demo_player.budget_ns = std.math.maxInt(i64);
    demo_clock = 0;
    demo_clock_on = true;
    // Lay the widgets out once, so the first glide has somewhere to go.
    try dvui.testing.settle(demoFrame);
    return t;
}

fn deinitDemo(t: *dvui.testing) void {
    demo_player.deinit();
    t.deinit();
    demo_text.deinit(std.testing.allocator);
    demo_text = .empty;
}

/// Frames until the player is in `state`, or fail after `max`.
fn stepDemoUntil(state: automation.Player.State, max: usize) !void {
    for (0..max) |_| {
        if (demo_player.state == state) return;
        _ = try dvui.testing.step(demoFrame);
    }
    if (demo_player.state != state) {
        std.debug.print("player is {t} at {d:.0}ms, wanted {t}\n", .{ demo_player.state, demo_player.seq.now, state });
        return error.TestUnexpectedResult;
    }
}

/// Where the subwindow `tag` marks sits in dvui's stack of them, later being above; null when it
/// has none. A floating window's tag is on its frame, which its subwindow shares the rect of.
fn subwindowIndex(tag: []const u8) ?usize {
    const td = dvui.tagGet(tag) orelse return null;
    for (dvui.currentWindow().subwindows.stack.items, 0..) |sw, i| {
        if (sw.id == td.id) return i;
        const r = sw.rect_pixels;
        if (@abs(r.x - td.rect.x) < 1 and @abs(r.y - td.rect.y) < 1 and @abs(r.w - td.rect.w) < 1 and @abs(r.h - td.rect.h) < 1) return i;
    }
    return null;
}

/// A tape that only moves the pointer: over a float, across the field and back to the float's
/// header, with no press anywhere in it.
fn moveOnlyTape() !automation.Tape.Owned {
    var s: automation.Script = .init(std.testing.allocator, "moves", "Moves");
    errdefer s.deinit();
    try s.keyframe(.{ .root = "demo://moves", .files = &.{.{ .path = "field", .text = "" }} });
    try s.moveTo(.{ .tag = "demo.float", .x = 0.5, .y = 0.5 }, .{});
    try s.moveTo(.{ .tag = "demo.field", .x = 0.8, .y = 0.8 }, .{});
    try s.moveTo(.{ .tag = "demo.float", .x = 0.5, .y = 0.05 }, .{});
    try s.moveTo(.{ .tag = "demo.count" }, .{});
    s.pause(300);
    return s.finish();
}

test "demo: a tape with no press drags nothing, even over a float's header" {
    var t = try demoCtx();
    defer deinitDemo(&t);
    demo_float = .{ .x = 200, .y = 150, .w = 300, .h = 200 };
    const home = demo_float.?;
    try dvui.testing.settle(demoFrame);

    demo_player.load(try moveOnlyTape(), .{});
    for (0..600) |_| {
        if (demo_player.state == .ended) break;
        _ = try dvui.testing.step(demoFrame);
        try std.testing.expect(dvui.currentWindow().dragging.state == .none);
        try std.testing.expectEqual(home, demo_float.?);
    }
    try std.testing.expectEqual(automation.Player.State.ended, demo_player.state);
}

/// A tape that drags the float by its header.
fn floatDragTape() !automation.Tape.Owned {
    var s: automation.Script = .init(std.testing.allocator, "drags", "Drags");
    errdefer s.deinit();
    try s.keyframe(.{ .root = "demo://drags", .files = &.{.{ .path = "field", .text = "" }} });
    try s.drag(.{ .tag = "demo.float", .x = 0.5, .y = 0.05 }, .{ .tag = "demo.count" }, .{});
    return s.finish();
}

test "demo: a press in the tape does drag a float by its header" {
    var t = try demoCtx();
    defer deinitDemo(&t);
    demo_float = .{ .x = 200, .y = 150, .w = 300, .h = 200 };
    const home = demo_float.?;
    try dvui.testing.settle(demoFrame);

    demo_player.load(try floatDragTape(), .{});
    try stepDemoUntil(.ended, 600);
    try std.testing.expect(demo_float.?.x != home.x or demo_float.?.y != home.y);
}

/// Three captions about no one thing, each starting while the one before shows.
fn threeCaptionsTape() !automation.Tape.Owned {
    var s: automation.Script = .init(std.testing.allocator, "captions", "Captions");
    errdefer s.deinit();
    try s.keyframe(.{ .root = "demo://captions", .files = &.{.{ .path = "field", .text = "" }} });
    try s.caption("First.", .{ .ms = 8000 });
    s.pause(600);
    try s.caption("Second.", .{ .ms = 8000 });
    s.pause(600);
    try s.caption("Third.", .{ .ms = 8000 });
    s.pause(1500);
    return s.finish();
}

test "demo: captions come in the tape's order, newest lowest, above every float" {
    var t = try demoCtx();
    defer deinitDemo(&t);

    demo_player.load(try threeCaptionsTape(), .{});

    // The frame each first shows in: never one before the one ahead of it in the tape.
    var first_seen: [3]?usize = .{ null, null, null };
    for (0..400) |frame| {
        _ = try dvui.testing.step(demoFrame);
        inline for (0..3) |i| {
            if (first_seen[i] == null and dvui.tagGet(std.fmt.comptimePrint("automation.caption:{d}", .{i})) != null) first_seen[i] = frame;
        }
        if (first_seen[2] != null) break;
    }
    try std.testing.expect(first_seen[0] != null and first_seen[1] != null and first_seen[2] != null);
    try std.testing.expect(first_seen[0].? <= first_seen[1].?);
    try std.testing.expect(first_seen[1].? <= first_seen[2].?);

    // A float opened while they show, as a dropped view's is, lands under them.
    demo_float = .{ .x = 100, .y = 100, .w = 300, .h = 300 };
    for (0..10) |_| _ = try dvui.testing.step(demoFrame);

    const first = dvui.tagGet("automation.caption:0") orelse return error.TestUnexpectedResult;
    const second = dvui.tagGet("automation.caption:1") orelse return error.TestUnexpectedResult;
    const third = dvui.tagGet("automation.caption:2") orelse return error.TestUnexpectedResult;
    // Stacked up from the foot: each older one above those after it.
    try std.testing.expect(first.rect.y < second.rect.y);
    try std.testing.expect(second.rect.y < third.rect.y);

    const float_at = subwindowIndex("demo.float") orelse return error.TestUnexpectedResult;
    inline for (0..3) |i| {
        const at = subwindowIndex(std.fmt.comptimePrint("automation.caption:{d}", .{i})) orelse return error.TestUnexpectedResult;
        try std.testing.expect(at > float_at);
    }
}

test "demo: a tape plays into real widgets as a person's input" {
    var t = try demoCtx();
    defer deinitDemo(&t);

    demo_player.load(try demoTape(), .{});
    try std.testing.expect(demo_stage.begun);
    try stepDemoUntil(.ended, 400);

    try std.testing.expectEqual(@as(usize, 1), demo_clicks);
    try std.testing.expectEqualStrings("> hello world", demo_text.items);
    try std.testing.expectEqual(@as(usize, 1), demo_commands);
    try std.testing.expectEqual(@as(usize, 1), demo_stage.keyframes);
    try std.testing.expect(!demo_stage.fast);

    demo_player.unload();
    try std.testing.expect(!demo_stage.begun);
}

test "demo: rewinding replays to exactly what live play reached, and forward again" {
    var t = try demoCtx();
    defer deinitDemo(&t);
    // The keyframe path: no snapshots to come back to.
    demo_stage.snapshots = false;

    demo_player.load(try demoTape(), .{});
    try stepDemoUntil(.ended, 400);
    const tape = demo_player.tape().?;
    const more = tape.chapters[2].at;

    // Back to just before the second word: the keyframe again, then a fast replay.
    demo_player.seek(@floatFromInt(more - 10));
    try std.testing.expectEqual(automation.Player.State.seeking, demo_player.state);
    try std.testing.expect(demo_stage.fast);
    try stepDemoUntil(.paused, 200);
    try std.testing.expect(!demo_stage.fast);
    try std.testing.expectEqual(@as(usize, 2), demo_stage.keyframes);
    try std.testing.expectEqualStrings("> hello", demo_text.items);
    try std.testing.expectEqual(@as(usize, 1), demo_clicks);
    try std.testing.expectEqual(@as(usize, 0), demo_commands);

    // Forward from there needs no rewind: it carries on from the tape's own state.
    demo_player.seek(@floatFromInt(tape.duration()));
    try stepDemoUntil(.paused, 200);
    try std.testing.expectEqual(@as(usize, 2), demo_stage.keyframes);
    try std.testing.expectEqualStrings("> hello world", demo_text.items);
    try std.testing.expectEqual(@as(usize, 1), demo_commands);

    // A chapter jump backwards is a seek like any other.
    demo_player.stepChapter(-1);
    demo_player.stepChapter(-1);
    try stepDemoUntil(.paused, 200);
    try std.testing.expectEqualStrings("> ", demo_text.items[0..2]);
    try std.testing.expect(demo_player.seq.now <= @as(f64, @floatFromInt(more)));
}

test "demo: a seek lands in the frame that asked for it, the app's clock following the demo" {
    var t = try demoCtx();
    defer deinitDemo(&t);
    // Every seek replays from the keyframe, so there is demo time to cover.
    demo_stage.snapshots = false;

    demo_player.load(try demoTape(), .{});
    try stepDemoUntil(.ended, 400);
    const more: f64 = @floatFromInt(demo_player.tape().?.chapters[2].at);

    // Without the backend's clock a silent frame steps a microsecond: the step's own 100 ms.
    demo_clock_on = false;
    var before = dvui.currentWindow().frame_time_ns;
    demo_player.seek(more - 10);
    _ = try dvui.testing.step(demoFrame);
    try std.testing.expectEqual(automation.Player.State.paused, demo_player.state);
    try std.testing.expectEqualStrings("> hello", demo_text.items);
    try std.testing.expectEqual(@as(u32, 1), demo_player.seek_stats.shown);
    try std.testing.expect(demo_player.seek_stats.silent > 3);
    try std.testing.expect(dvui.currentWindow().frame_time_ns - before < 101 * std.time.ns_per_ms);

    // With it, each silent frame begins as much later as the demo time the one before covered:
    // seconds of demo in one step.
    demo_clock_on = true;
    demo_player.seek(@floatFromInt(demo_player.duration()));
    try stepDemoUntil(.paused, 200);
    before = dvui.currentWindow().frame_time_ns;
    demo_player.seek(more - 10);
    _ = try dvui.testing.step(demoFrame);
    try std.testing.expectEqual(automation.Player.State.paused, demo_player.state);
    try std.testing.expectEqualStrings("> hello", demo_text.items);
    try std.testing.expect(dvui.currentWindow().frame_time_ns - before > 1100 * std.time.ns_per_ms);
    // The player's own chrome stays on the wall.
    try std.testing.expect(demo_player.ahead_ns > 0);
    try std.testing.expectEqual(demo_player.ahead_ns, demo_clock);

    // No budget at all is the replay shown a frame at a time.
    demo_player.budget_ns = 0;
    demo_player.seek(@floatFromInt(demo_player.duration()));
    try stepDemoUntil(.paused, 200);
    try std.testing.expectEqualStrings("> hello world", demo_text.items);
    demo_player.seek(more - 10);
    try stepDemoUntil(.paused, 200);
    try std.testing.expectEqualStrings("> hello", demo_text.items);
    try std.testing.expectEqual(@as(u32, 0), demo_player.seek_stats.silent);
    try std.testing.expect(demo_player.seek_stats.shown > 3);
}

test "demo: a seek or pause mid-drag lets go of the held button, and the release of an unheld button sends no event" {
    var t = try demoCtx();
    defer deinitDemo(&t);
    demo_stage.snapshots = false;

    var s: automation.Script = .init(std.testing.allocator, "drag", "Drag");
    try s.keyframe(.{ .root = "demo://drag", .files = &.{.{ .path = "field", .text = "> " }} });
    try s.drag(.{ .tag = "demo.count" }, .{ .tag = "demo.field" }, .{});
    demo_player.load(try s.finish(), .{});
    var press_at: f64 = 0;
    var release_at: f64 = 0;
    for (demo_player.tape().?.ops) |op| switch (op.do) {
        .press => press_at = @floatFromInt(op.at),
        .release => release_at = @floatFromInt(op.at),
        else => {},
    };
    const mid = (press_at + release_at) / 2;

    // A seek that lands paused inside the drag, forward on the tape's own state.
    demo_player.pause();
    demo_player.seek(mid);
    try stepDemoUntil(.paused, 200);
    try std.testing.expectEqual(@as(usize, 0), demo_player.input.held.count());

    // Back to the keyframe and on into the drag again, then a pause asked for mid-seek.
    demo_player.seek(0);
    try stepDemoUntil(.paused, 200);
    demo_player.play();
    demo_player.seek(mid);
    demo_player.pause();
    try stepDemoUntil(.paused, 200);
    try std.testing.expectEqual(@as(usize, 0), demo_player.input.held.count());

    // Carrying on past the cut-short drag: its release finds nothing held.
    demo_player.play();
    try stepDemoUntil(.ended, 400);
    try std.testing.expectEqual(@as(usize, 0), demo_player.input.held.count());

    // The release of a button nothing holds sends dvui no event; an empty `held` alone could not
    // tell, since removing an absent button changes nothing.
    const cw = dvui.currentWindow();
    const sent = cw.event_num;
    demo_player.input.button(.left, false);
    try std.testing.expectEqual(sent, cw.event_num);
    // The guard lets a release of a held button through.
    demo_player.input.button(.left, true);
    const pressed = cw.event_num;
    try std.testing.expect(pressed > sent);
    demo_player.input.button(.left, false);
    try std.testing.expect(cw.event_num > pressed);
}

test "demo: a seek back goes to the nearest snapshot, not the keyframe, and lands exactly" {
    var t = try demoCtx();
    defer deinitDemo(&t);

    demo_player.load(try demoTape(), .{});
    try stepDemoUntil(.ended, 400);
    // Taken as it played: once the scene settled, at each chapter, every few seconds.
    try std.testing.expect(demo_player.snapshots.items.len >= 3);
    const more: f64 = @floatFromInt(demo_player.tape().?.chapters[2].at);

    demo_player.seek(more - 10);
    _ = try dvui.testing.step(demoFrame);
    try std.testing.expectEqual(automation.Player.State.paused, demo_player.state);
    try std.testing.expectEqualStrings("> hello", demo_text.items);
    try std.testing.expectEqual(@as(usize, 1), demo_clicks);
    try std.testing.expectEqual(@as(usize, 0), demo_commands);
    // Put back in place, the keyframe never cut to again.
    try std.testing.expectEqual(@as(usize, 1), demo_stage.keyframes);
    try std.testing.expectEqual(@as(usize, 1), demo_stage.restores);
    try std.testing.expect(demo_player.seek_stats.restored != null);

    // On to the end: the moments snapshotted on the first pass, reached again, are the same.
    demo_player.seek(@floatFromInt(demo_player.duration()));
    try stepDemoUntil(.paused, 200);
    try std.testing.expectEqualStrings("> hello world", demo_text.items);
    try std.testing.expectEqual(@as(u32, 0), demo_player.mismatches);
}

fn twoScenesTape() !automation.Tape.Owned {
    var s: automation.Script = .init(std.testing.allocator, "scenes", "Scenes");
    errdefer s.deinit();
    try s.keyframe(.{ .root = "demo://scenes", .files = &.{.{ .path = "field", .text = "> " }} });
    try s.click(.{ .tag = "demo.field", .x = 0.9, .y = 0.5 }, .{});
    try s.typeText("one", .{ .cps = 20 });
    s.pause(4000);
    try s.keyframe(.{ .root = "demo://scenes", .files = &.{.{ .path = "field", .text = "# " }} });
    try s.chapter("Two");
    try s.click(.{ .tag = "demo.field", .x = 0.9, .y = 0.5 }, .{});
    try s.typeText("two", .{ .cps = 20 });
    s.pause(1000);
    return s.finish();
}

test "demo: a seek back to a keyframe does not check the scene before's last snapshot against it" {
    var t = try demoCtx();
    defer deinitDemo(&t);

    // Two scenes, a pause before the second: the snapshot taken in that pause has the cursor of
    // the second keyframe's op, which is where a rewind to that keyframe sits before it cuts.
    demo_player.load(try twoScenesTape(), .{});
    try stepDemoUntil(.ended, 600);
    try std.testing.expectEqualStrings("# two", demo_text.items);
    // The moment this is about: a snapshot of the first scene at the second keyframe's op.
    const tape = demo_player.tape().?;
    const second_kf = for (tape.ops, 0..) |op, i| {
        if (i > 0 and op.do == .keyframe) break i;
    } else return error.TestUnexpectedResult;
    const before_cut = for (demo_player.snapshots.items) |s| {
        if (s.cursor == second_kf) break s;
    } else return error.TestUnexpectedResult;
    try std.testing.expectEqual(@as(usize, 0), before_cut.scene);

    // From the end back into the second scene, every snapshot refused: a rewind to its keyframe.
    demo_stage.refuse_restores = true;
    const two: f64 = @floatFromInt(tape.chapters[0].at);
    demo_player.seek(two + 100);
    try stepDemoUntil(.paused, 200);
    try std.testing.expect(demo_stage.refused > 0);
    try std.testing.expectEqualStrings("# ", demo_text.items);
    try std.testing.expectEqual(@as(u32, 0), demo_player.mismatches);
}

test "demo: the scrubber seeks as it is dragged" {
    var t = try demoCtx();
    defer deinitDemo(&t);

    demo_player.load(try demoTape(), .{});
    try stepDemoUntil(.ended, 400);
    const tape = demo_player.tape().?;
    const typing: f64 = @floatFromInt(tape.chapters[1].at);
    const more: f64 = @floatFromInt(tape.chapters[2].at);

    // Held and moved back: the app follows the knob while it is held.
    demo_player.transport.scrub = typing - 10;
    _ = try dvui.testing.step(demoFrame);
    try std.testing.expectEqualStrings("> ", demo_text.items);
    try std.testing.expectEqual(@as(usize, 1), demo_clicks);
    demo_player.transport.scrub = more - 10;
    _ = try dvui.testing.step(demoFrame);
    try std.testing.expectEqualStrings("> hello", demo_text.items);
    demo_player.transport.scrub = typing - 10;
    _ = try dvui.testing.step(demoFrame);
    try std.testing.expectEqualStrings("> ", demo_text.items);
    try std.testing.expectEqual(@as(usize, 1), demo_stage.keyframes);
    try std.testing.expectEqual(@as(u32, 0), demo_player.mismatches);
}

test "demo: closed from its bar, the bar runs back together before the demo goes" {
    var t = try demoCtx();
    defer deinitDemo(&t);

    demo_player.load(try demoTape(), .{});
    try stepDemoUntil(.ended, 400);
    // Ended, the bar is out and open.
    for (0..20) |_| _ = try dvui.testing.step(demoFrame);
    try std.testing.expect(demo_player.transport.openness > 0.99);

    // A click on its close button, the way a backend adds it.
    const close = demo_player.transport.close;
    try std.testing.expect(close.w > 0);
    _ = try dvui.currentWindow().addEventMouseMotion(.{ .pt = close.center() });
    _ = try dvui.currentWindow().addEventMouseButton(.left, .press);
    _ = try dvui.testing.step(demoFrame);
    // Not gone under the pointer: still loaded, the bar on its way out.
    try std.testing.expect(demo_player.tape() != null);
    try std.testing.expect(demo_player.transport.closing);
    _ = try dvui.currentWindow().addEventMouseButton(.left, .release);

    // Gone once it has run back together, and not before it shut.
    var frames: usize = 0;
    while (demo_player.tape() != null and frames < 40) : (frames += 1) {
        try std.testing.expect(demo_player.transport.openness > 0 or demo_player.transport.shut);
        _ = try dvui.testing.step(demoFrame);
    }
    try std.testing.expect(demo_player.tape() == null);
    try std.testing.expect(frames > 1);
}

test "demo: the bar goes into its corner and grows back out of it" {
    var t = try demoCtx();
    defer deinitDemo(&t);

    demo_player.load(try demoTape(), .{});
    try stepDemoUntil(.ended, 400);
    for (0..20) |_| _ = try dvui.testing.step(demoFrame);
    const tr = &demo_player.transport;
    try std.testing.expect(tr.openness > 0.99);

    // Its tab sends it into the corner, ended as it is, and the corner full: the tape has played out.
    try std.testing.expect(tr.tab.w > 0);
    _ = try dvui.currentWindow().addEventMouseMotion(.{ .pt = tr.tab.center() });
    _ = try dvui.currentWindow().addEventMouseButton(.left, .press);
    _ = try dvui.testing.step(demoFrame);
    _ = try dvui.currentWindow().addEventMouseButton(.left, .release);
    try std.testing.expect(tr.tucked);
    var frames: usize = 0;
    while (tr.openness > 0 and frames < 60) : (frames += 1) _ = try dvui.testing.step(demoFrame);
    try std.testing.expectEqual(@as(f32, 0), tr.openness);
    const corner = tr.rest orelse return error.TestUnexpectedResult;
    try std.testing.expect(dvui.tagGet("demo.corner") != null);

    // Passing over the corner brings nothing; held on it, the bar grows back out.
    _ = try dvui.currentWindow().addEventMouseMotion(.{ .pt = corner.center() });
    for (0..3) |_| _ = try dvui.testing.step(demoFrame);
    try std.testing.expectEqual(@as(f32, 0), tr.openness);
    frames = 0;
    while (tr.openness < 0.99 and frames < 200) : (frames += 1) _ = try dvui.testing.step(demoFrame);
    try std.testing.expect(tr.openness > 0.99);
    try std.testing.expect(!tr.tucked);

    // In again, and a press on the corner brings it at once.
    _ = try dvui.currentWindow().addEventMouseMotion(.{ .pt = tr.tab.center() });
    _ = try dvui.currentWindow().addEventMouseButton(.left, .press);
    _ = try dvui.testing.step(demoFrame);
    _ = try dvui.currentWindow().addEventMouseButton(.left, .release);
    frames = 0;
    while (tr.openness > 0 and frames < 60) : (frames += 1) _ = try dvui.testing.step(demoFrame);
    _ = try dvui.currentWindow().addEventMouseMotion(.{ .pt = tr.rest.?.center() });
    _ = try dvui.currentWindow().addEventMouseButton(.left, .press);
    _ = try dvui.testing.step(demoFrame);
    _ = try dvui.currentWindow().addEventMouseButton(.left, .release);
    try std.testing.expect(!tr.tucked);
    // Not the app's: the demo was not diverged by it.
    try std.testing.expect(!demo_player.diverged);
}

test "demo: the bar stacks above a history bar out under it, and comes back down" {
    var t = try demoCtx();
    defer deinitDemo(&t);
    defer demo_other_bar = null;

    demo_player.load(try demoTape(), .{});
    try stepDemoUntil(.ended, 400);
    for (0..20) |_| _ = try dvui.testing.step(demoFrame);
    const tr = &demo_player.transport;
    const rest = tr.bar orelse return error.TestUnexpectedResult;

    // A bar comes out where the tape's is: the tape's eases up until it is clear above it.
    demo_other_bar = .{ .x = rest.x + 40, .y = rest.y - 4, .w = 300, .h = rest.h + 8 };
    for (0..60) |_| _ = try dvui.testing.step(demoFrame);
    const up = tr.bar orelse return error.TestUnexpectedResult;
    try std.testing.expect(up.y + up.h <= demo_other_bar.?.y);
    try std.testing.expectEqual(rest.x, up.x);

    // It goes: the tape's comes back down to its place.
    demo_other_bar = null;
    for (0..60) |_| _ = try dvui.testing.step(demoFrame);
    const down = tr.bar orelse return error.TestUnexpectedResult;
    try std.testing.expectApproxEqAbs(rest.y, down.y, 0.5);
}

/// A tape with one callout over the pointer: it goes to the Count button and wiggles there, then
/// goes off across the field.
fn calloutTape() !automation.Tape.Owned {
    var s: automation.Script = .init(std.testing.allocator, "callout", "Callout");
    errdefer s.deinit();
    try s.keyframe(.{ .root = "demo://callout", .files = &.{.{ .path = "field", .text = "" }} });
    try s.caption("The pointer goes to Count, and wiggles there, then across the field.", .{ .ms = 9000 });
    try s.moveTo(.{ .tag = "demo.count" }, .{});
    for (0..8) |i| {
        const k: f32 = if (i % 2 == 0) 4 else -4;
        try s.moveTo(.{ .tag = "demo.count", .dx = k, .dy = -k / 2 }, .{ .ms = 150 });
    }
    try s.moveTo(.{ .tag = "demo.field", .x = 0.85, .y = 0.8 }, .{});
    s.pause(2500);
    return s.finish();
}

/// Where the callout is drawn this frame, natural; null when none is.
fn calloutRect() ?dvui.Rect {
    const td = dvui.tagGet(automation.overlay.callout_anchor) orelse return null;
    return dvui.windowRectScale().rectFromPhysical(td.rect);
}

test "demo: a callout stays put through the pointer's wiggle, and moves once when it moves on" {
    var t = try demoCtx();
    defer deinitDemo(&t);

    const tape = try calloutTape();
    const wiggle_end = blk: {
        // The last of the wiggles starts the move across.
        var last: u32 = 0;
        for (tape.tape.ops) |op| if (op.do == .move and std.mem.eql(u8, op.do.move.tag, "demo.count")) {
            last = op.at + op.ms;
        };
        break :blk last;
    };
    demo_player.load(tape, .{});

    var prev: ?dvui.Rect = null;
    var travels: usize = 0;
    var moving = false;
    for (0..400) |_| {
        if (demo_player.state == .ended) break;
        _ = try dvui.testing.step(demoFrame);
        const r = calloutRect() orelse {
            prev = null;
            continue;
        };
        defer prev = r;
        const p = prev orelse continue;
        // Past its opening, where it is placed by its size.
        if (demo_player.now() < 800) continue;
        const moved = @abs(r.x - p.x) > 0.5 or @abs(r.y - p.y) > 0.5;
        // Until it sets off ahead of the pointer for the field (`overlay.lead_ms`, 250 ms).
        if (demo_player.now() <= @as(f64, @floatFromInt(wiggle_end)) - 300) {
            if (moved) std.debug.print("callout moved during the wiggle at {d:.0}ms: {any} -> {any}\n", .{ demo_player.now(), p, r });
            try std.testing.expect(!moved);
        }
        if (moved and !moving) travels += 1;
        moving = moved;
    }
    try std.testing.expectEqual(@as(usize, 1), travels);
}

test "demo: a callout never covers a history bar out beside its subject, nor the subject" {
    var t = try demoCtx();
    defer deinitDemo(&t);
    defer demo_other_bar = null;

    const count = (dvui.tagGet("demo.count") orelse return error.TestUnexpectedResult).rect;
    // A history bar out along the button, where the callout would otherwise go: beside it.
    demo_other_bar = .{ .x = count.x + count.w + 4, .y = count.y - 6, .w = 360, .h = count.h + 12 };
    const bar = dvui.windowRectScale().rectFromPhysical(demo_other_bar.?);
    const target = dvui.windowRectScale().rectFromPhysical(count);

    demo_player.load(try calloutTape(), .{});
    var seen: usize = 0;
    for (0..400) |_| {
        if (demo_player.state == .ended) break;
        _ = try dvui.testing.step(demoFrame);
        // While it is about the button: till the pointer sets off across the field.
        if (demo_player.now() > 3000) break;
        const r = calloutRect() orelse continue;
        seen += 1;
        const over_bar = r.intersect(bar);
        const over_target = r.intersect(target);
        if (over_bar.w > 0 and over_bar.h > 0 or over_target.w > 0 and over_target.h > 0) {
            std.debug.print("callout {any} covers the bar {any} or the target {any}\n", .{ r, bar, target });
            return error.TestUnexpectedResult;
        }
    }
    try std.testing.expect(seen > 0);
}

test "demo: a callout keeps clear of an OS window shown over the main one" {
    var t = try demoCtx();
    defer deinitDemo(&t);

    const count = (dvui.tagGet("demo.count") orelse return error.TestUnexpectedResult).rect;
    // A window lying over the main window's frame along the button, where the callout would go.
    const window: dvui.Rect.Physical = .{ .x = count.x + count.w + 4, .y = count.y - 6, .w = 360, .h = count.h + 12 };
    var covered_main: [8]dvui.Rect.Physical = undefined;
    covered_main[0] = window;
    // Its part of the frame is elsewhere (past the main window's edge), holding nothing here.
    var covered: [8]dvui.Rect.Physical = undefined;
    covered[0] = .{ .x = 1e6, .y = 1e6, .w = 400, .h = 300 };
    const over = dvui.windowRectScale().rectFromPhysical(window);

    demo_player.load(try calloutTape(), .{});
    // After the load, which starts the transport afresh.
    demo_player.transport.covered = covered;
    demo_player.transport.covered_main = covered_main;
    demo_player.transport.covered_n = 1;
    defer demo_player.transport.covered_n = 0;
    var seen: usize = 0;
    for (0..400) |_| {
        if (demo_player.state == .ended or demo_player.now() > 3000) break;
        _ = try dvui.testing.step(demoFrame);
        const r = calloutRect() orelse continue;
        seen += 1;
        const hit = r.intersect(over);
        if (hit.w > 0 and hit.h > 0) {
            std.debug.print("callout {any} covers the window {any}\n", .{ r, over });
            return error.TestUnexpectedResult;
        }
    }
    try std.testing.expect(seen > 0);
}

test "demo: a callout about what an OS window shows is drawn within that window" {
    var t = try demoCtx();
    defer deinitDemo(&t);

    // A window whose part of the frame holds the button and most of the main one, short of its
    // edge on the right, where the callout would otherwise be kept to the main window's.
    const main = dvui.windowRectPixels();
    const part: dvui.Rect.Physical = .{ .x = main.x, .y = main.y, .w = main.w - 120, .h = main.h };
    var covered: [8]dvui.Rect.Physical = undefined;
    covered[0] = part;
    var covered_main: [8]dvui.Rect.Physical = undefined;
    covered_main[0] = .{ .x = 1e6, .y = 1e6, .w = part.w, .h = part.h };
    const own = dvui.windowRectScale().rectFromPhysical(part);

    demo_player.load(try calloutTape(), .{});
    // After the load, which starts the transport afresh.
    demo_player.transport.covered = covered;
    demo_player.transport.covered_main = covered_main;
    demo_player.transport.covered_n = 1;
    defer demo_player.transport.covered_n = 0;
    var seen: usize = 0;
    for (0..400) |_| {
        if (demo_player.state == .ended or demo_player.now() > 3000) break;
        _ = try dvui.testing.step(demoFrame);
        const r = calloutRect() orelse continue;
        seen += 1;
        if (r.x < own.x - 0.5 or r.y < own.y - 0.5 or r.x + r.w > own.x + own.w + 0.5 or r.y + r.h > own.y + own.h + 0.5) {
            std.debug.print("callout {any} is not within its window {any}\n", .{ r, own });
            return error.TestUnexpectedResult;
        }
    }
    try std.testing.expect(seen > 0);
}

test "demo: a callout is the main window's unless its subject's window can hold it" {
    var t = try demoCtx();
    defer deinitDemo(&t);

    const count = (dvui.tagGet("demo.count") orelse return error.TestUnexpectedResult).rect;
    const main = dvui.windowRectPixels();
    const cases = [_]struct { part: dvui.Rect.Physical, main: bool }{
        // A window around the button, big enough: the callout goes into it.
        .{ .part = .{ .x = main.x, .y = main.y, .w = main.w - 120, .h = main.h }, .main = false },
        // A menu's: around the button, too small to hold a callout, so it stays on the main window.
        .{ .part = .{ .x = count.x - 4, .y = count.y - 4, .w = count.w + 8, .h = count.h + 8 }, .main = true },
    };
    for (cases) |case| {
        demo_player.load(try calloutTape(), .{});
        demo_player.transport.covered[0] = case.part;
        demo_player.transport.covered_main[0] = .{ .x = 1e6, .y = 1e6, .w = case.part.w, .h = case.part.h };
        demo_player.transport.covered_n = 1;
        defer demo_player.transport.covered_n = 0;
        var seen: usize = 0;
        for (0..400) |_| {
            if (demo_player.state == .ended or demo_player.now() > 3000) break;
            _ = try dvui.testing.step(demoFrame);
            if (calloutRect() == null) continue;
            seen += 1;
            try std.testing.expectEqual(@as(?bool, case.main), demo_callout_main);
        }
        try std.testing.expect(seen > 0);
    }
}

test "demo: a callout with no subject stays on the main window, clear of an OS window over it" {
    var t = try demoCtx();
    defer deinitDemo(&t);

    var s: automation.Script = .init(std.testing.allocator, "no-subject", "No subject");
    errdefer s.deinit();
    try s.keyframe(.{ .root = "demo://callout", .files = &.{.{ .path = "field", .text = "" }} });
    // Beside something that is not drawn, with no pointer to aim at: nothing to sit beside.
    try s.caption("Nothing here to point at.", .{ .ms = 6000, .near = "demo.nowhere" });
    s.pause(6000);
    demo_player.load(try s.finish(), .{});

    // A window over the main one, across the foot of it where such a callout goes at home, with
    // a part of the frame elsewhere that holds nothing here.
    const window: dvui.Rect.Physical = .{ .x = 150, .y = 380, .w = 500, .h = 100 };
    demo_player.transport.covered[0] = .{ .x = 1e6, .y = 1e6, .w = 400, .h = 300 };
    demo_player.transport.covered_main[0] = window;
    demo_player.transport.covered_n = 1;
    defer demo_player.transport.covered_n = 0;
    const over = dvui.windowRectScale().rectFromPhysical(window);

    var seen: usize = 0;
    for (0..400) |_| {
        if (demo_player.state == .ended or demo_player.now() > 3000) break;
        _ = try dvui.testing.step(demoFrame);
        const r = calloutRect() orelse continue;
        seen += 1;
        try std.testing.expectEqual(@as(?bool, true), demo_callout_main);
        const hit = r.intersect(over);
        if (hit.w > 0 and hit.h > 0) {
            std.debug.print("callout {any} covers the window {any}\n", .{ r, over });
            return error.TestUnexpectedResult;
        }
    }
    try std.testing.expect(seen > 0);
}

test "demo: a replay that does not reach what playing did is caught" {
    var t = try demoCtx();
    defer deinitDemo(&t);

    demo_player.load(try demoTape(), .{});
    try stepDemoUntil(.ended, 400);
    const more: f64 = @floatFromInt(demo_player.tape().?.chapters[2].at);
    demo_player.seek(more - 10);
    _ = try dvui.testing.step(demoFrame);
    // Something the tape does not do, as an unawaited load or an unnamed target would — then on,
    // through the moments the first pass snapshotted. (A seek forward would jump to the next
    // snapshot instead, putting the model right without replaying it.)
    try demo_text.appendSlice(std.testing.allocator, "!");
    demo_player.play();
    try stepDemoUntil(.ended, 400);
    try std.testing.expect(demo_player.mismatches > 0);
}

test "demo: a person's click pauses it, and resuming carries on from what they did as a new branch" {
    var t = try demoCtx();
    defer deinitDemo(&t);

    demo_player.load(try demoTape(), .{});
    // Into the typing of the first word.
    const typing_at = demo_player.tape().?.chapters[1].at + 1500;
    for (0..400) |_| {
        if (demo_player.seq.now >= @as(f64, @floatFromInt(typing_at))) break;
        _ = try dvui.testing.step(demoFrame);
    }
    try std.testing.expectEqual(automation.Player.State.playing, demo_player.state);
    const paused_at = demo_player.seq.now;

    // Real input between frames, the way a backend adds it: a click on the button.
    const button_rect = dvui.tagGet("demo.count").?.rect;
    _ = try dvui.currentWindow().addEventMouseMotion(.{ .pt = button_rect.center() });
    _ = try dvui.currentWindow().addEventMouseButton(.left, .press);
    _ = try dvui.currentWindow().addEventMouseButton(.left, .release);
    _ = try dvui.testing.step(demoFrame);
    _ = try dvui.testing.step(demoFrame);
    try std.testing.expectEqual(automation.Player.State.paused, demo_player.state);
    try std.testing.expect(demo_player.diverged);
    // The click went on to do what the person meant.
    try std.testing.expectEqual(@as(usize, 2), demo_clicks);
    try std.testing.expect(demo_player.seq.now <= paused_at + 200);

    // Resume: the tape carries on from what the person did, not replaying over it.
    demo_player.play();
    try std.testing.expectEqual(automation.Player.State.playing, demo_player.state);
    try std.testing.expect(demo_player.branched);
    try std.testing.expect(!demo_player.diverged);
    try std.testing.expectEqual(@as(usize, 2), demo_clicks);
    // Rewinding is into the tape's own history, and leaves the branch.
    demo_player.pause();
    demo_player.seek(0);
    try stepDemoUntil(.paused, 400);
    try std.testing.expect(!demo_player.branched);
}

/// One left drag along the Count button, so the pointer is on it the whole way.
fn dragTape() !automation.Tape.Owned {
    var s: automation.Script = .init(std.testing.allocator, "drag", "Drag");
    errdefer s.deinit();
    try s.keyframe(.{ .root = "demo://drag", .files = &.{.{ .path = "field", .text = "> " }} });
    try s.drag(.{ .tag = "demo.count", .x = 0.2 }, .{ .tag = "demo.count", .x = 0.8 }, .{});
    return s.finish();
}

/// Seeks to the middle of the drag's carry, landing as `after`, and lets the frames settle.
fn seekIntoDrag(after: automation.Player.After) !void {
    var press: f64 = 0;
    var release: f64 = 0;
    for (demo_player.tape().?.ops) |op| switch (op.do) {
        .press => press = @floatFromInt(op.at),
        .release => release = @floatFromInt(op.at),
        else => {},
    };
    demo_player.seek((press + release) / 2);
    demo_player.after_seek = after;
    try stepDemoUntil(if (after == .pause) .paused else .playing, 400);
}

test "demo: a real release does not end the drag the tape is making" {
    var t = try demoCtx();
    defer deinitDemo(&t);

    demo_player.load(try dragTape(), .{});
    try seekIntoDrag(.play);
    try std.testing.expect(demo_player.input.held.count() > 0);

    const before = demo_releases;
    _ = try dvui.currentWindow().addEventMouseButton(.left, .release);
    _ = try dvui.testing.step(demoFrame);
    try std.testing.expectEqual(automation.Player.State.playing, demo_player.state);
    try std.testing.expect(demo_player.input.held.count() > 0);
    try std.testing.expectEqual(before, demo_releases);

    // The tape's own release still lands when it gets there.
    try stepDemoUntil(.ended, 400);
    try std.testing.expectEqual(before + 1, demo_releases);
}

test "demo: pausing mid-drag and resuming sends no release that has no press" {
    var t = try demoCtx();
    defer deinitDemo(&t);

    demo_player.load(try dragTape(), .{});
    try seekIntoDrag(.play);
    demo_player.pause();
    for (0..2) |_| _ = try dvui.testing.step(demoFrame);
    const after_pause = demo_releases;
    try std.testing.expectEqual(@as(usize, 1), after_pause);

    demo_player.play();
    try stepDemoUntil(.ended, 400);
    try std.testing.expectEqual(after_pause, demo_releases);
}

/// A real press at the middle of `r`, between frames, as a backend adds it.
fn pressAt(r: dvui.Rect.Physical) !void {
    _ = try dvui.currentWindow().addEventMouseMotion(.{ .pt = r.center() });
    _ = try dvui.currentWindow().addEventMouseButton(.left, .press);
    _ = try dvui.currentWindow().addEventMouseButton(.left, .release);
    _ = try dvui.testing.step(demoFrame);
}

test "demo: play at the end restarts the tape over what a person did" {
    var t = try demoCtx();
    defer deinitDemo(&t);
    demo_player.load(try demoTape(), .{});
    try stepDemoUntil(.ended, 400);
    demo_player.diverged = true;
    demo_player.play();
    try stepDemoUntil(.playing, 400);
    try std.testing.expect(!demo_player.diverged and !demo_player.branched);
}

test "demo: the Revert to before pill gives the session back, and the bar's close keeps what is on screen" {
    var t = try demoCtx();
    defer deinitDemo(&t);

    // The pill: where the overlay drew it, a press reverts at once (the bar being out of view).
    demo_player.load(try demoTape(), .{});
    try stepDemoUntil(.ended, 400);
    const bar: dvui.Rect.Physical = .{ .x = 100, .y = 500, .w = 400, .h = 44 };
    demo_player.transport.bar = bar;
    demo_player.transport.revert = .{ .x = 340, .y = 460, .w = 150, .h = 30 };
    try pressAt(demo_player.transport.revert);
    try std.testing.expectEqual(automation.Player.State.idle, demo_player.state);
    try std.testing.expect(!demo_stage.begun and !demo_stage.kept);

    // The bar's close, with the bar out: it runs back, and only once shut is the demo let go,
    // leaving the app as it is because the tape ended.
    demo_player.load(try demoTape(), .{});
    try stepDemoUntil(.ended, 400);
    demo_player.transport.bar = bar;
    demo_player.transport.openness = 1;
    demo_player.transport.close = .{ .x = 450, .y = 506, .w = 32, .h = 32 };
    try pressAt(demo_player.transport.close);
    try std.testing.expect(demo_player.transport.closing);
    try std.testing.expectEqual(automation.Player.State.ended, demo_player.state);
    demo_player.transport.shut = true;
    _ = try dvui.testing.step(demoFrame);
    try std.testing.expectEqual(automation.Player.State.idle, demo_player.state);
    try std.testing.expect(demo_stage.kept and !demo_stage.begun);

    // Closed while still playing, the demo just stops where it is: the app stays as it is.
    demo_stage.kept = false;
    demo_player.load(try demoTape(), .{});
    for (0..6) |_| _ = try dvui.testing.step(demoFrame);
    try std.testing.expectEqual(automation.Player.State.playing, demo_player.state);
    demo_player.stop();
    try std.testing.expect(demo_stage.kept and !demo_stage.begun);
}

test "demo: the Revert pill is the size of its layer" {
    var t = try demoCtx();
    defer deinitDemo(&t);

    demo_player.load(try demoTape(), .{});
    try stepDemoUntil(.ended, 400);
    // Let the bar finish opening and the layer settle to its minimum size.
    for (0..20) |_| _ = try dvui.testing.step(demoFrame);
    const td = dvui.tagGet("demo.revert") orelse return error.TestUnexpectedResult;
    const rect = for (dvui.currentWindow().subwindows.stack.items) |sw| {
        if (sw.id == td.id) break sw.rect_pixels;
    } else return error.TestUnexpectedResult;

    // Half a pixel allows rounding at each edge; two pixels allow it across the size.
    try std.testing.expect(rect.x <= td.rect.x + 0.5);
    try std.testing.expect(rect.y <= td.rect.y + 0.5);
    try std.testing.expect(rect.x + rect.w >= td.rect.x + td.rect.w - 0.5);
    try std.testing.expect(rect.y + rect.h >= td.rect.y + td.rect.h - 0.5);
    try std.testing.expect(rect.w <= td.rect.w + 2);
    try std.testing.expect(rect.h <= td.rect.h + 2);
}

test "demo: real pointer motion does not move the tape's pointer while it plays" {
    var t = try demoCtx();
    defer deinitDemo(&t);

    demo_player.load(try demoTape(), .{});
    for (0..12) |_| _ = try dvui.testing.step(demoFrame);
    try std.testing.expectEqual(automation.Player.State.playing, demo_player.state);
    _ = try dvui.currentWindow().addEventMouseMotion(.{ .pt = .{ .x = 3, .y = 3 } });
    _ = try dvui.testing.step(demoFrame);
    try std.testing.expectEqual(automation.Player.State.playing, demo_player.state);
    const p = demo_player.seq.pointer;
    try std.testing.expectEqual(p.x, dvui.currentWindow().mouse_pt.x);
    try std.testing.expectEqual(p.y, dvui.currentWindow().mouse_pt.y);
}

/// One frame, the next beginning `ms` later: a slow frame, or the app not drawing at all.
fn stepDemoBy(ms: i128) !void {
    const cw = dvui.currentWindow();
    _ = try demoFrame();
    _ = try cw.end(.{});
    try cw.begin(cw.frame_time_ns + ms * std.time.ns_per_ms);
}

/// Ten seconds of nothing, then a ping.
fn quietTape() !automation.Tape.Owned {
    var s: automation.Script = .init(std.testing.allocator, "quiet", "Quiet");
    errdefer s.deinit();
    try s.keyframe(.{ .root = "demo://quiet", .files = &.{.{ .path = "field", .text = "> " }} });
    s.pause(10_000);
    try s.command("demo.ping");
    return s.finish();
}

test "demo: a slow browser plays it at its pace, not in slow motion" {
    var t = try demoCtx();
    defer deinitDemo(&t);

    demo_player.load(try quietTape(), .{});
    try stepDemoUntil(.playing, 50);

    // Frames 400 ms apart, two and a half a second: as much demo as wall. (The first of them
    // follows an ordinary step's 100 ms.)
    var before = demo_player.seq.now;
    for (0..6) |_| try stepDemoBy(400);
    try std.testing.expect(demo_player.seq.now - before >= 2000);

    // Paused a long while: the first frame back plays a frame's worth, not the pause.
    demo_player.pause();
    try stepDemoBy(30_000);
    demo_player.play();
    before = demo_player.seq.now;
    try stepDemoBy(16);
    try std.testing.expect(demo_player.seq.now - before <= 100);

    // Nothing drawn for half a minute while it plays (a hidden tab): no more than a second of it.
    try stepDemoBy(30_000);
    before = demo_player.seq.now;
    try stepDemoBy(16);
    try std.testing.expect(demo_player.seq.now - before <= automation.Player.max_frame_ms);
    try std.testing.expectEqual(automation.Player.State.playing, demo_player.state);
}

test "demo: every bundled demo builds into a valid tape" {
    for (fizzy.Editor.Demo.catalog.entries) |e| {
        var s: automation.Script = .init(std.testing.allocator, e.name, e.title);
        s.check = automation.Input.check;
        e.build(&s) catch |err| {
            s.deinit();
            return err;
        };
        var owned = try s.finish();
        defer owned.deinit();
        try std.testing.expect(owned.tape.duration() > 5000);
        try std.testing.expect(owned.tape.chapters.len > 0);
        // Its files mount under its own name — `demo://<name>`, what the web's `?demo=` says.
        try std.testing.expect(std.mem.endsWith(u8, owned.tape.keyframes[0].root, e.name));

        // And it travels as a `.tape` (what a site hosts) unchanged.
        const bytes = try automation.binary.encode(std.testing.allocator, owned.tape, .{});
        defer std.testing.allocator.free(bytes);
        var back = try automation.Tape.load(std.testing.allocator, bytes, automation.Input.check);
        defer back.deinit();
        try std.testing.expectEqualDeep(owned.tape, back.tape);
    }
}

test "verdict: the soak tape is a demo, and its expectations read" {
    var owned = try automation.Tape.parse(std.testing.allocator, @embedFile("soak_tape"), automation.Input.check);
    defer owned.deinit();
    try std.testing.expectEqualStrings("soak", owned.tape.name);
    // It ends on a wait, so what closed last has time to close before the windows are counted.
    try std.testing.expect(owned.tape.ops[owned.tape.ops.len - 1].do == .wait);
    // Every button on an anchor (docs/AUTOMATION.md), as every bundled demo's is (`tests/demos.zig`).
    try std.testing.expectEqual(@as(?usize, null), owned.tape.firstButtonOffAnchor());

    var expect_arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer expect_arena.deinit();
    var expect_diag: std.zon.parse.Diagnostics = undefined;
    const expect = try std.zon.parse.fromSliceNoAlloc(fizzy.verdict.Expect, .{ .gpa = std.testing.allocator, .arena = expect_arena.allocator(), .source = @embedFile("soak_expect"), .diagnostics = &expect_diag });
    try std.testing.expect(!expect.allow_leaks);
    try std.testing.expectEqual(@as(u32, 0), expect.max_sdl_errors);
    try std.testing.expectEqual(@as(?u32, null), expect.os_windows);
}

test "demo: the hand-written sample tape parses and round-trips" {
    const source = @embedFile("demo_sample_tape");
    var owned = try automation.Tape.parse(std.testing.allocator, source, automation.Input.check);
    defer owned.deinit();
    try std.testing.expectEqualStrings("hello", owned.tape.name);
    try std.testing.expectEqualStrings(".split", owned.tape.keyframes[0].settings[0].value);

    var out: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();
    try owned.tape.write(&out.writer);
    const again = try std.testing.allocator.dupeSentinel(u8, out.written(), 0);
    defer std.testing.allocator.free(again);
    var back = try automation.Tape.parse(std.testing.allocator, again, automation.Input.check);
    defer back.deinit();
    try std.testing.expectEqual(owned.tape.ops.len, back.tape.ops.len);
    try std.testing.expectEqual(owned.tape.duration(), back.tape.duration());

    // `Tape.load` takes the source as it is and the binary form alike.
    var loaded = try automation.Tape.load(std.testing.allocator, source, automation.Input.check);
    defer loaded.deinit();
    const bytes = try automation.binary.encode(std.testing.allocator, owned.tape, .{});
    defer std.testing.allocator.free(bytes);
    var from_binary = try automation.Tape.load(std.testing.allocator, bytes, automation.Input.check);
    defer from_binary.deinit();
    try std.testing.expectEqualDeep(loaded.tape, from_binary.tape);
}

// ── Floating a view ─────────────────────────────────────────────────────────────────────────────
// The rules (where a float opens, its name, its stacking) are `app/layout/float_rules.zig`'s own
// unit tests; these drive the layout.

/// The view `name` is showing, as a drag would lift it.
fn visibleIn(editor: *fizzy.Editor, name: []const u8) ?[]const u8 {
    var layout = fizzy.Editor.Layout.init(&editor.app.host, &editor.app.layout, editor.app.gpa, dvui.currentWindow().arena());
    return fizzy.Editor.Layout.ViewDrag.visibleId(&layout, name);
}

/// Floats not flying shut.
fn openFloats(editor: *fizzy.Editor) usize {
    var n: usize = 0;
    for (editor.app.layout.floats.items.items) |f| {
        if (!f.closing) n += 1;
    }
    return n;
}

fn holds(ids: []const []const u8, id: []const u8) bool {
    for (ids) |x| if (std.mem.eql(u8, x, id)) return true;
    return false;
}

// ── Putting a view away (`Host.hideSurface`) ──────────────────────────────────────────────────

/// `Layout.hide` between frames, as `Host.hideSurface` runs it, then the frames after.
fn hideView(editor: *fizzy.Editor, id: []const u8) !bool {
    var layout = fizzy.Editor.Layout.init(&editor.app.host, &editor.app.layout, editor.app.gpa, dvui.currentWindow().arena());
    const acted = layout.hide(id);
    try dvui.testing.settle(ManyPanelFrame.frame);
    return acted;
}

fn revealView(editor: *fizzy.Editor, id: []const u8) !bool {
    var layout = fizzy.Editor.Layout.init(&editor.app.host, &editor.app.layout, editor.app.gpa, dvui.currentWindow().arena());
    const acted = layout.reveal(id);
    try dvui.testing.settle(ManyPanelFrame.frame);
    return acted;
}

fn placeShut(editor: *fizzy.Editor, name: []const u8) bool {
    for (editor.app.layout.regions.items) |r| {
        if (std.mem.eql(u8, r.name, name)) return r.isClosed();
    }
    return false;
}

test "hide: a tray's view shuts the tray, and reveal opens it again" {
    var case = try ManyPanelCase.init();
    defer case.deinit();
    const editor = case.ctx.editor;
    try std.testing.expect(!placeShut(editor, "Panel"));

    try std.testing.expect(try hideView(editor, "test.output"));
    try std.testing.expect(placeShut(editor, "Panel"));
    // Out of sight already: nothing to put away.
    try std.testing.expect(!try hideView(editor, "test.output"));
    try std.testing.expect(!try hideView(editor, "test.nothing"));

    try std.testing.expect(try revealView(editor, "test.output"));
    try std.testing.expect(!placeShut(editor, "Panel"));
    // Round again: a toggle.
    try std.testing.expect(try hideView(editor, "test.output"));
    try std.testing.expect(placeShut(editor, "Panel"));
}

test "hide: a view in Main, or in a place a split made, stays and nothing changes" {
    var case = try ManyPanelCase.init();
    defer case.deinit();
    const editor = case.ctx.editor;
    try std.testing.expect(!try hideView(editor, "test.main"));
    try std.testing.expect(!placeShut(editor, "Main"));

    // Split off Main.
    try case.place("Panel", "Main", .{ .split = .right });
    const half = case.placeNamed(&.{ "Main", "Panel" }) orelse return error.TestExpectedEqual;
    try std.testing.expect(holds(case.shows(half), "test.output"));
    try std.testing.expect(!try hideView(editor, "test.output"));
    try std.testing.expect(!placeShut(editor, half));
    try std.testing.expect(holds(case.shows(half), "test.output"));
}

test "hide: a view in a tray the user split stays, and nothing changes" {
    var case = try ManyPanelCase.init();
    defer case.deinit();
    const editor = case.ctx.editor;
    try case.place("Panel", "Panel", .{ .split = .right });
    try std.testing.expect(holds(case.shows("Panel"), "test.output"));
    try std.testing.expect(!try hideView(editor, "test.output"));
    try std.testing.expect(!placeShut(editor, "Panel"));
    try std.testing.expect(holds(case.shows("Panel"), "test.output"));
}

test "hide: a view alone in a float closes the float, and it goes home" {
    var case = try ManyPanelCase.init();
    defer case.deinit();
    const editor = case.ctx.editor;
    try case.place("Panel", "Panel", .swap);
    try std.testing.expectEqual(@as(usize, 1), openFloats(editor));

    try std.testing.expect(try hideView(editor, "test.output"));
    try dvui.testing.settle(ManyPanelFrame.frame);
    try std.testing.expectEqual(@as(usize, 0), editor.app.layout.floats.items.items.len);
    try std.testing.expect(holds(case.shows("Panel"), "test.output"));
}

test "hide: a view in a float with others stays, and nothing changes" {
    var case = try ManyPanelCase.init();
    defer case.deinit();
    const editor = case.ctx.editor;
    try editor.app.host.registerSurface(.{ .id = "test.tools", .title = "Tools", .keywords = &.{"tools"}, .draw = ManyPanelFrame.draw });
    try case.place("Panel", "Panel", .swap);
    try editor.app.layout.assign(editor.app.gpa, "Float 1", &.{ "test.output", "test.tools" });
    try dvui.testing.settle(ManyPanelFrame.frame);

    try std.testing.expect(!try hideView(editor, "test.output"));
    try std.testing.expect(!try hideView(editor, "test.tools"));
    try std.testing.expectEqual(@as(usize, 1), openFloats(editor));
    try std.testing.expectEqual(@as(usize, 2), case.shows("Float 1").len);
}

/// A view that asks, from its own draw, to be put away (`hideLater`, as `Host.hideSurface` does
/// during a frame), and what it saw when it asked.
const HidingView = struct {
    var ask = false;
    var answer = false;
    var floats_then: usize = 0;

    fn draw(_: ?*anyopaque) anyerror!dvui.App.Result {
        if (!ask) return .ok;
        ask = false;
        const l = ManyPanelFrame.layout orelse return .ok;
        answer = l.hideLater("test.hider");
        floats_then = openFloats(ManyPanelFrame.editor.?);
        return .ok;
    }
};

test "hide: asked from a floating view's own draw, it answers then and acts once the frame has drawn" {
    var case = try ManyPanelCase.init();
    defer case.deinit();
    const editor = case.ctx.editor;
    try editor.app.host.registerSurface(.{ .id = "test.hider", .title = "Hider", .keywords = &.{"tools"}, .draw = HidingView.draw });
    try case.place("Panel", "Panel", .swap);
    try editor.app.layout.assign(editor.app.gpa, "Float 1", &.{"test.hider"});
    try dvui.testing.settle(ManyPanelFrame.frame);
    try std.testing.expectEqual(@as(usize, 1), case.shows("Float 1").len);

    HidingView.ask = true;
    _ = try dvui.testing.step(ManyPanelFrame.frame);
    try std.testing.expect(!HidingView.ask); // it drew, and asked
    try std.testing.expect(HidingView.answer);
    // Nothing moved while the float was drawing; by the frame's end it is closing.
    try std.testing.expectEqual(@as(usize, 1), HidingView.floats_then);
    try std.testing.expectEqual(@as(usize, 0), openFloats(editor));
    try dvui.testing.settle(ManyPanelFrame.frame);
    try std.testing.expectEqual(@as(usize, 0), editor.app.layout.floats.items.items.len);
}

test "float: a view dropped on the middle of its own place floats, and the place keeps the rest" {
    var case = try ManyPanelCase.init();
    defer case.deinit();
    const editor = case.ctx.editor;
    try editor.app.host.registerSurface(.{ .id = "test.problems", .title = "Problems", .keywords = fizzy.sdk.keywords.ide.panel, .draw = ManyPanelFrame.draw });
    try dvui.testing.settle(ManyPanelFrame.frame);
    try std.testing.expectEqual(@as(usize, 2), case.shows("Panel").len);
    const lifted = visibleIn(editor, "Panel") orelse return error.TestExpectedEqual;

    try case.place("Panel", "Panel", .swap);

    const floats = editor.app.layout.floats.items.items;
    try std.testing.expectEqual(@as(usize, 1), floats.len);
    try std.testing.expectEqualStrings("Float 1", floats[0].name);
    try std.testing.expectEqualStrings("Panel", floats[0].home);
    // Its window has drawn, and its place holds just the view that was showing.
    try std.testing.expect(floats[0].win_id != .zero);
    const floated = case.shows("Float 1");
    try std.testing.expectEqual(@as(usize, 1), floated.len);
    try std.testing.expectEqualStrings(lifted, floated[0]);
    const left = case.shows("Panel");
    try std.testing.expectEqual(@as(usize, 1), left.len);
    try std.testing.expect(!std.mem.eql(u8, left[0], lifted));
}

test "float: a view alone in a float does not float again" {
    var case = try ManyPanelCase.init();
    defer case.deinit();
    const editor = case.ctx.editor;
    try case.place("Panel", "Panel", .swap);
    try std.testing.expectEqual(@as(usize, 1), editor.app.layout.floats.items.items.len);
    try case.place("Float 1", "Float 1", .swap);
    try std.testing.expectEqual(@as(usize, 1), editor.app.layout.floats.items.items.len);
    try std.testing.expectEqual(@as(usize, 1), case.shows("Float 1").len);
}

test "float: its last view carried back to a place closes it" {
    var case = try ManyPanelCase.init();
    defer case.deinit();
    const editor = case.ctx.editor;
    try case.place("Panel", "Panel", .swap);
    try std.testing.expectEqual(@as(usize, 1), openFloats(editor));
    try std.testing.expectEqual(@as(usize, 0), case.shows("Panel").len);

    try case.place("Float 1", "Panel", .swap);
    try dvui.testing.settle(ManyPanelFrame.frame);
    try std.testing.expectEqual(@as(usize, 0), openFloats(editor));
    // Flown shut and gone.
    try std.testing.expectEqual(@as(usize, 0), editor.app.layout.floats.items.items.len);
    try std.testing.expect(holds(case.shows("Panel"), "test.output"));
}

test "float: closing it sends its view home" {
    var case = try ManyPanelCase.init();
    defer case.deinit();
    const editor = case.ctx.editor;
    try case.place("Panel", "Panel", .swap);
    try std.testing.expectEqual(@as(usize, 0), case.shows("Panel").len);

    var layout = fizzy.Editor.Layout.init(&editor.app.host, &editor.app.layout, editor.app.gpa, dvui.currentWindow().arena());
    layout.closeFloat("Float 1");
    try dvui.testing.settle(ManyPanelFrame.frame);
    try dvui.testing.settle(ManyPanelFrame.frame);

    try std.testing.expectEqual(@as(usize, 0), editor.app.layout.floats.items.items.len);
    // Panel's keywords fill it, so the view is let go and they bring it back — Panel's list is
    // not written down, which would freeze it against surfaces registered later.
    try std.testing.expect(holds(case.shows("Panel"), "test.output"));
    try std.testing.expect(editor.app.layout.assignment("Panel") == null);
    try std.testing.expect(editor.app.layout.assignment("Float 1") == null);
}

test "float: a float in an OS window with its own buttons still has a close a tape can press" {
    var case = try ManyPanelCase.init();
    defer case.deinit();
    const editor = case.ctx.editor;
    try case.place("Panel", "Panel", .swap);
    const floats = editor.app.layout.floats.items.items;
    try std.testing.expectEqual(@as(usize, 1), floats.len);
    // As Popout makes it on macOS: its OS window draws the close button, so the header draws none.
    floats[0].viewport = .{ .rect = floats[0].rect, .os_buttons = true, .buttons_w = 60 };

    const WantFrame = struct {
        fn frame() !dvui.App.Result {
            fizzy.core.anchor.want();
            return ManyPanelFrame.frame();
        }
    };
    try dvui.testing.settle(WantFrame.frame);
    try dvui.testing.settle(WantFrame.frame);

    const td = dvui.tagGet("float-close:Float 1") orelse return error.TestUnexpectedResult;
    try std.testing.expect(td.visible);
    const cw = dvui.currentWindow();
    _ = try cw.addEventMouseMotion(.{ .pt = .{ .x = td.rect.x + td.rect.w / 2, .y = td.rect.y + td.rect.h / 2 } });
    _ = try cw.addEventMouseButton(.left, .press);
    _ = try cw.addEventMouseButton(.left, .release);
    try dvui.testing.settle(WantFrame.frame);
    try dvui.testing.settle(WantFrame.frame);
    try std.testing.expectEqual(@as(usize, 0), editor.app.layout.floats.items.items.len);
}

test "float: a press on the header of a float in an OS window, off its buttons, does not close it" {
    var case = try ManyPanelCase.init();
    defer case.deinit();
    const editor = case.ctx.editor;
    try case.place("Panel", "Panel", .swap);
    const floats = editor.app.layout.floats.items.items;
    try std.testing.expectEqual(@as(usize, 1), floats.len);
    floats[0].viewport = .{ .rect = floats[0].rect, .os_buttons = true, .buttons_w = 60 };

    const WantFrame = struct {
        fn frame() !dvui.App.Result {
            fizzy.core.anchor.want();
            return ManyPanelFrame.frame();
        }
    };
    try dvui.testing.settle(WantFrame.frame);
    try dvui.testing.settle(WantFrame.frame);

    const close = dvui.tagGet("float-close:Float 1") orelse return error.TestUnexpectedResult;
    const header = dvui.tagGet("float-header:Float 1") orelse return error.TestUnexpectedResult;
    // The header's far end, well clear of the leading traffic light.
    const pt: dvui.Point.Physical = .{ .x = header.rect.x + header.rect.w - 8, .y = close.rect.y + close.rect.h / 2 };
    try std.testing.expect(pt.x > close.rect.x + close.rect.w);
    const cw = dvui.currentWindow();
    _ = try cw.addEventMouseMotion(.{ .pt = pt });
    _ = try cw.addEventMouseButton(.left, .press);
    _ = try cw.addEventMouseButton(.left, .release);
    try dvui.testing.settle(WantFrame.frame);
    try dvui.testing.settle(WantFrame.frame);
    try std.testing.expectEqual(@as(usize, 1), editor.app.layout.floats.items.items.len);
}

test "float: closing it loses no view its keywords would show nowhere" {
    var case = try ManyPanelCase.init();
    defer case.deinit();
    const editor = case.ctx.editor;
    // A view whose keywords no place answers — a plugin's tools, merged into a float that came out
    // of the panel its keywords fill.
    try editor.app.host.registerSurface(.{ .id = "test.tools", .title = "Tools", .keywords = &.{"tools"}, .draw = ManyPanelFrame.draw });
    try case.place("Panel", "Panel", .swap);
    try editor.app.layout.assign(editor.app.gpa, "Float 1", &.{ "test.output", "test.tools" });
    try dvui.testing.settle(ManyPanelFrame.frame);
    try std.testing.expectEqual(@as(usize, 2), case.shows("Float 1").len);

    var layout = fizzy.Editor.Layout.init(&editor.app.host, &editor.app.layout, editor.app.gpa, dvui.currentWindow().arena());
    layout.closeFloat("Float 1");
    try dvui.testing.settle(ManyPanelFrame.frame);
    try dvui.testing.settle(ManyPanelFrame.frame);

    try std.testing.expectEqual(@as(usize, 0), editor.app.layout.floats.items.items.len);
    // Both back in the main window: Output where its keywords show it, Tools beside it in the
    // place the float came out of, rather than let go to be shown nowhere.
    const panel = case.shows("Panel");
    try std.testing.expect(holds(panel, "test.output"));
    try std.testing.expect(holds(panel, "test.tools"));
}

test "float: the saved layout brings it back, and Reset Layout takes it away" {
    var case = try ManyPanelCase.init();
    defer case.deinit();
    const editor = case.ctx.editor;
    const gpa = std.testing.allocator;
    try case.place("Panel", "Panel", .swap);
    const was = editor.app.layout.floats.items.items[0].rect;

    // As `layout.zon` holds it: collected, written as ZON and read back — no disk.
    const regions = editor.collectSavedRegions(gpa);
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    try std.zon.stringify.serializeMaxDepth(regions, .{}, &out.writer, 64);
    gpa.free(regions);
    const text = try gpa.dupeSentinel(u8, out.written(), 0);
    defer gpa.free(text);
    var saved_arena: std.heap.ArenaAllocator = .init(gpa);
    defer saved_arena.deinit();
    var saved_diag: std.zon.parse.Diagnostics = undefined;
    const saved = try std.zon.parse.fromSlice([]fizzy.backend.SavedRegion, .{ .gpa = gpa, .arena = saved_arena.allocator(), .source = text, .diagnostics = &saved_diag, .ignore_unknown_fields = true });

    editor.app.layout.resetLayout(gpa);
    try dvui.testing.settle(ManyPanelFrame.frame);
    try std.testing.expectEqual(@as(usize, 0), editor.app.layout.floats.items.items.len);
    try std.testing.expect(holds(case.shows("Panel"), "test.output"));

    editor.applySavedRegions(saved);
    try dvui.testing.settle(ManyPanelFrame.frame);
    const floats = editor.app.layout.floats.items.items;
    try std.testing.expectEqual(@as(usize, 1), floats.len);
    try std.testing.expectEqualStrings("Float 1", floats[0].name);
    try std.testing.expectEqualStrings("Panel", floats[0].home);
    try std.testing.expectEqual(was, floats[0].rect);
    const floated = case.shows("Float 1");
    try std.testing.expectEqual(@as(usize, 1), floated.len);
    try std.testing.expectEqualStrings("test.output", floated[0]);
    try std.testing.expectEqual(@as(usize, 0), case.shows("Panel").len);
}

test "float: a drag aims at a float's place over it, at nothing over its header, past it as before" {
    var ctx = try shim.init(std.testing.allocator);
    defer ctx.deinit(std.testing.allocator);
    const editor = ctx.editor;
    const gpa = std.testing.allocator;
    editor.app.gpa = gpa;
    defer editor.app.layout.regions.deinit(gpa);
    defer editor.app.layout.regions_building.deinit(gpa);
    defer editor.app.layout.deinitExtents(gpa);
    defer editor.app.layout.deinitQualified(gpa);
    defer editor.app.layout.deinitAssignments(gpa);

    const main_at: dvui.Rect.Physical = .{ .x = 0, .y = 0, .w = 800, .h = 400 };
    const panel_at: dvui.Rect.Physical = .{ .x = 0, .y = 400, .w = 800, .h = 200 };
    const window: dvui.Rect.Physical = .{ .x = 200, .y = 100, .w = 300, .h = 260 };
    const header: dvui.Rect.Physical = .{ .x = 200, .y = 100, .w = 300, .h = 40 };
    const body: dvui.Rect.Physical = .{ .x = 200, .y = 140, .w = 300, .h = 220 };
    const state = &editor.app.layout;
    state.registerRegion(gpa, .{ .name = "Main", .keywords = fizzy.sdk.keywords.ide.main, .bounds = main_at, .size = .{ .w = 800, .h = 400 } });
    state.registerRegion(gpa, .{ .name = "Panel", .keywords = fizzy.sdk.keywords.ide.panel, .bounds = panel_at });
    // The float's place, drawn in its window: layer 1.
    state.layer_building = 1;
    state.registerRegion(gpa, .{ .name = "Float 1", .keywords = fizzy.Editor.Layout.slot_keywords, .by_name = true, .bounds = body });
    state.layer_building = 0;
    state.publishRegions();
    _ = try state.floats.add(gpa, .{
        .name = "Float 1",
        .rect = .{ .x = 100, .y = 50, .w = 150, .h = 130 },
        .home = "Panel",
        .fresh = false,
        .win_id = @fromBackingInt(@intCast(0xf10a7)),
        .bounds = window,
        .header = header,
    });

    var layout = fizzy.Editor.Layout.init(&editor.app.host, state, gpa, dvui.currentWindow().arena());
    const ViewDrag = fizzy.Editor.Layout.ViewDrag;
    ViewDrag.begin(&layout, "Panel", panel_at, panel_at);
    defer state.view_drag.discard(gpa);

    // Over the float: its place, though Main is under it too.
    try std.testing.expectEqualStrings("Float 1", ViewDrag.targetAt(&layout, .{ .x = 350, .y = 250 }, "Panel") orelse
        return error.TestExpectedEqual);
    // Over its header: nothing — it is the float's handle.
    try std.testing.expect(ViewDrag.targetAt(&layout, .{ .x = 350, .y = 120 }, "Panel") == null);
    // Beside it, Main as ever.
    try std.testing.expectEqualStrings("Main", ViewDrag.targetAt(&layout, .{ .x = 650, .y = 200 }, "Panel") orelse
        return error.TestExpectedEqual);
}

/// Main, Panel and a float lying over Main's middle, registered as a frame would have them, for a
/// drag to read: `drag_aims_*`.
const FloatOverMain = struct {
    const main_at: dvui.Rect.Physical = .{ .x = 0, .y = 0, .w = 800, .h = 400 };
    const panel_at: dvui.Rect.Physical = .{ .x = 0, .y = 400, .w = 800, .h = 200 };
    const window: dvui.Rect.Physical = .{ .x = 200, .y = 100, .w = 300, .h = 260 };
    const header: dvui.Rect.Physical = .{ .x = 200, .y = 100, .w = 300, .h = 40 };
    const body: dvui.Rect.Physical = .{ .x = 200, .y = 140, .w = 300, .h = 220 };
    /// A leaf a split of Main made, all of it under the float.
    const hidden_at: dvui.Rect.Physical = .{ .x = 240, .y = 180, .w = 200, .h = 140 };

    fn register(editor: *fizzy.Editor, hidden: bool) !void {
        try registerAt(editor, hidden, window);
    }

    /// `register` with the float's window at `win`: its header the top 40 of it, its place the rest.
    fn registerAt(editor: *fizzy.Editor, hidden: bool, win: dvui.Rect.Physical) !void {
        const head: dvui.Rect.Physical = .{ .x = win.x, .y = win.y, .w = win.w, .h = 40 };
        const place: dvui.Rect.Physical = .{ .x = win.x, .y = win.y + 40, .w = win.w, .h = win.h - 40 };
        const gpa = editor.app.gpa;
        const state = &editor.app.layout;
        state.registerRegion(gpa, .{ .name = "Main", .keywords = fizzy.sdk.keywords.ide.main, .bounds = main_at, .size = .{ .w = 800, .h = 400 } });
        state.registerRegion(gpa, .{ .name = "Panel", .keywords = fizzy.sdk.keywords.ide.panel, .bounds = panel_at });
        if (hidden) state.registerRegion(gpa, .{ .name = "Main/r1", .keywords = fizzy.sdk.keywords.ide.main, .bounds = hidden_at });
        // The float's place, drawn in its window: layer 1.
        state.layer_building = 1;
        state.registerRegion(gpa, .{ .name = "Float 1", .keywords = fizzy.Editor.Layout.slot_keywords, .by_name = true, .bounds = place });
        state.layer_building = 0;
        state.publishRegions();
        _ = try state.floats.add(gpa, .{
            .name = "Float 1",
            .rect = .{ .x = 100, .y = 50, .w = 150, .h = 130 },
            .home = "Panel",
            .fresh = false,
            .win_id = @fromBackingInt(@intCast(0xf10a7)),
            .bounds = win,
            .header = head,
        });
    }
};

test "float: a place a float lies over has its drop in the part left clear, where a release takes it" {
    var ctx = try shim.init(std.testing.allocator);
    defer ctx.deinit(std.testing.allocator);
    const editor = ctx.editor;
    const gpa = std.testing.allocator;
    editor.app.gpa = gpa;
    defer editor.app.layout.regions.deinit(gpa);
    defer editor.app.layout.regions_building.deinit(gpa);
    defer editor.app.layout.deinitExtents(gpa);
    defer editor.app.layout.deinitQualified(gpa);
    defer editor.app.layout.deinitAssignments(gpa);
    try FloatOverMain.register(editor, false);

    var layout = fizzy.Editor.Layout.init(&editor.app.host, &editor.app.layout, gpa, dvui.currentWindow().arena());
    const ViewDrag = fizzy.Editor.Layout.ViewDrag;
    ViewDrag.begin(&layout, "Panel", FloatOverMain.panel_at, FloatOverMain.panel_at);
    defer editor.app.layout.view_drag.discard(editor.app.gpa);

    // Main's middle is under the float: its drop is in Main, clear of the float, all of it.
    const clear = ViewDrag.zoneBounds(&editor.app.layout, "Main") orelse return error.TestExpectedEqual;
    const main_at = FloatOverMain.main_at;
    try std.testing.expect(clear.x >= main_at.x and clear.y >= main_at.y and clear.x + clear.w <= main_at.x + main_at.w and clear.y + clear.h <= main_at.y + main_at.h);
    try std.testing.expect(clear.intersect(FloatOverMain.window).w <= 0 or clear.intersect(FloatOverMain.window).h <= 0);
    const w = ViewDrag.wheelOf(&editor.app.layout, "Main") orelse return error.TestExpectedEqual;
    try std.testing.expect(!FloatOverMain.window.contains(w.center));
    try std.testing.expect(clear.contains(w.center));
    // Aimed at its middle bubble, the drop is Main's — the geometry drawn is the one read.
    try std.testing.expectEqualStrings("Main", ViewDrag.targetAt(&layout, w.center, "Panel") orelse return error.TestExpectedEqual);
    try std.testing.expect(DZ.at(w, w.center).?.eql(.center));
    // The float's own place has its drop inside the float.
    const fw = ViewDrag.wheelOf(&editor.app.layout, "Float 1") orelse return error.TestExpectedEqual;
    try std.testing.expect(FloatOverMain.body.contains(fw.center));
    try std.testing.expectEqualStrings("Float 1", ViewDrag.targetAt(&layout, fw.center, "Panel") orelse return error.TestExpectedEqual);
}

test "float: a place a float lies all over has no drop" {
    var ctx = try shim.init(std.testing.allocator);
    defer ctx.deinit(std.testing.allocator);
    const editor = ctx.editor;
    const gpa = std.testing.allocator;
    editor.app.gpa = gpa;
    defer editor.app.layout.regions.deinit(gpa);
    defer editor.app.layout.regions_building.deinit(gpa);
    defer editor.app.layout.deinitExtents(gpa);
    defer editor.app.layout.deinitQualified(gpa);
    defer editor.app.layout.deinitAssignments(gpa);
    try FloatOverMain.register(editor, true);

    var layout = fizzy.Editor.Layout.init(&editor.app.host, &editor.app.layout, gpa, dvui.currentWindow().arena());
    const ViewDrag = fizzy.Editor.Layout.ViewDrag;
    ViewDrag.begin(&layout, "Panel", FloatOverMain.panel_at, FloatOverMain.panel_at);
    defer editor.app.layout.view_drag.discard(editor.app.gpa);

    try std.testing.expect(ViewDrag.zoneBounds(&editor.app.layout, "Main/r1") == null);
    try std.testing.expect(ViewDrag.wheelOf(&editor.app.layout, "Main/r1") == null);
    // Over where it is, the float.
    try std.testing.expectEqualStrings("Float 1", ViewDrag.targetAt(&layout, FloatOverMain.hidden_at.center(), "Panel") orelse return error.TestExpectedEqual);
}

test "float: dragging a place's view onto its own middle floats it, over a seed tree too" {
    var ctx = try shim.init(std.testing.allocator);
    defer ctx.deinit(std.testing.allocator);
    const editor = ctx.editor;
    editor.app.gpa = std.testing.allocator;
    defer editor.app.layout.regions.deinit(editor.app.gpa);
    defer editor.app.layout.regions_building.deinit(editor.app.gpa);
    defer editor.app.layout.deinitExtents(editor.app.gpa);
    defer editor.app.layout.deinitAssignments(editor.app.gpa);
    defer editor.app.layout.deinitQualified(editor.app.gpa);
    defer editor.app.layout.view_drag.discard(editor.app.gpa);
    EndlessFrame.editor = editor;
    defer EndlessFrame.editor = null;

    const draw = struct {
        fn f(_: ?*anyopaque) anyerror!dvui.App.Result {
            return .ok;
        }
    }.f;
    try editor.app.host.registerSurface(.{ .id = "test.view", .title = "View", .keywords = &.{"slot"}, .draw = draw });
    try dvui.testing.settle(EndlessFrame.frame);
    var center: fizzy.Editor.Layout.Region = undefined;
    for (editor.app.layout.regions.items) |r| {
        if (std.mem.eql(u8, r.name, "Center")) center = r;
    }

    // From the corner button into the middle of the same place, and let go: the gesture a person
    // makes, through dvui's own events.
    const cw = dvui.currentWindow();
    const button: dvui.Point.Physical = .{ .x = center.bounds.x + center.bounds.w - 16, .y = center.bounds.y + 16 };
    _ = try cw.addEventMouseMotion(.{ .pt = button });
    _ = try dvui.testing.step(EndlessFrame.frame);
    _ = try dvui.testing.step(EndlessFrame.frame);
    _ = try cw.addEventMouseButton(.left, .press);
    _ = try dvui.testing.step(EndlessFrame.frame);
    const mid = center.bounds.center();
    var i: usize = 1;
    while (i <= 12) : (i += 1) {
        const t: f32 = @as(f32, @floatFromInt(i)) / 12;
        _ = try cw.addEventMouseMotion(.{ .pt = .{ .x = button.x + (mid.x - button.x) * t, .y = button.y + (mid.y - button.y) * t } });
        _ = try dvui.testing.step(EndlessFrame.frame);
    }
    for (0..6) |_| _ = try dvui.testing.step(EndlessFrame.frame);
    _ = try cw.addEventMouseButton(.left, .release);
    try dvui.testing.settle(EndlessFrame.frame);

    try std.testing.expect(!editor.app.layout.view_drag.active());
    const floats = editor.app.layout.floats.items.items;
    try std.testing.expectEqual(@as(usize, 1), floats.len);
    try std.testing.expectEqualStrings("Float 1", floats[0].name);
    try std.testing.expectEqualStrings("Center", floats[0].home);
    // Landed: grown out of the carried glass and settled into its window.
    try std.testing.expect(floats[0].landing == null);
    try std.testing.expect(floats[0].win_id != .zero);
    const shown = editor.app.layout.assignment("Float 1") orelse return error.TestExpectedEqual;
    try std.testing.expectEqual(@as(usize, 1), shown.len);
    try std.testing.expectEqualStrings("test.view", shown[0]);
}

/// Move the pointer to `p` and draw `frames` frames of `frame` there.
fn pointTo(p: dvui.Point.Physical, frame: fn () anyerror!dvui.App.Result, frames: usize) !void {
    _ = try dvui.currentWindow().addEventMouseMotion(.{ .pt = p });
    for (0..frames) |_| _ = try dvui.testing.step(frame);
}

/// A point in the window off the float `bounds`: one of the window's corners, a little in.
fn offFloat(bounds: dvui.Rect.Physical) !dvui.Point.Physical {
    const w = dvui.windowRectPixels();
    for ([_]dvui.Point.Physical{ w.topLeft(), w.topRight(), w.bottomLeft(), w.bottomRight() }) |corner| {
        const p: dvui.Point.Physical = .{ .x = std.math.lerp(corner.x, w.center().x, 0.05), .y = std.math.lerp(corner.y, w.center().y, 0.05) };
        if (!bounds.contains(p)) return p;
    }
    return error.TestUnexpectedResult;
}

/// Rest the pointer on `p`, drawing frames of `frame` until the ghost of the float the view is
/// carried out of firms up there (`ViewDrag.ghost_rest_ms`, as the clock goes), or it plainly
/// will not — and then for the float to fade all the way back from its ghost.
fn restOn(editor: *fizzy.Editor, p: dvui.Point.Physical, frame: fn () anyerror!dvui.App.Result) !void {
    _ = try dvui.currentWindow().addEventMouseMotion(.{ .pt = p });
    const start = dvui.currentWindow().frame_time_ns;
    const enough = 3 * fizzy.Editor.Layout.ViewDrag.ghost_rest_ms * std.time.ns_per_ms;
    while (!editor.app.layout.view_drag.ghost_firm and dvui.currentWindow().frame_time_ns - start < enough) {
        _ = try dvui.testing.step(frame);
    }
    for (0..ghost_frames) |_| _ = try dvui.testing.step(frame);
}

/// How far aside float `i` is now (`Floats.Float.aside`): 0 itself, 1 its ghost.
fn asideOf(editor: *fizzy.Editor, i: usize) f32 {
    return editor.app.layout.floats.items.items[i].aside.at();
}

/// Frames for a float to fade all the way to its ghost, and a couple more. Its fade runs on a clock
/// its frames step, each by no more than `core.FrameClock.max_step_ns`, and the testing backend's
/// frames are longer than that: each moves the fade on by one step, not by the frame.
const ghost_frames: usize = @as(usize, @intFromFloat(@ceil(fizzy.Editor.Layout.Floats.aside_ms * std.time.ns_per_ms /
    @as(f32, @floatFromInt(fizzy.core.FrameClock.max_step_ns))))) + 2;

test "float: the float a view is carried out of is a ghost while the view is aimed off it, itself over it, and back when it is let go over nothing" {
    var case = try ManyPanelCase.init();
    defer case.deinit();
    const editor = case.ctx.editor;
    try case.place("Panel", "Panel", .swap);
    const floats = &editor.app.layout.floats;
    const bounds = floats.items.items[0].bounds;
    const header = floats.items.items[0].header;

    var layout = fizzy.Editor.Layout.init(&editor.app.host, &editor.app.layout, editor.app.gpa, dvui.currentWindow().arena());
    const ViewDrag = fizzy.Editor.Layout.ViewDrag;
    // Lifted from its corner button, over the float: it is still itself.
    try pointTo(.{ .x = bounds.x + bounds.w - 16, .y = header.y + header.h + 16 }, ManyPanelFrame.frame, 1);
    ViewDrag.begin(&layout, "Float 1", bounds, bounds);
    defer editor.app.layout.view_drag.discard(editor.app.gpa);
    // Mapped with the others, marked as the one the view is carried out of.
    try std.testing.expectEqual(@as(usize, 1), editor.app.layout.view_drag.occluder_count);
    try std.testing.expect(editor.app.layout.view_drag.occluders[0].source);
    _ = try dvui.testing.step(ManyPanelFrame.frame);
    try std.testing.expect(editor.app.layout.view_drag.ghost_firm);
    try std.testing.expectEqual(@as(f32, 0), asideOf(editor, 0));

    // Aimed off it: a ghost of itself.
    try pointTo(try offFloat(bounds), ManyPanelFrame.frame, ghost_frames);
    try std.testing.expect(!editor.app.layout.view_drag.ghost_firm);
    try std.testing.expectEqual(@as(f32, 1), asideOf(editor, 0));
    // It still holds its view, and its place is still drawn: the drag is held by its corner button.
    try std.testing.expect(holds(case.shows("Float 1"), "test.output"));

    // Carried back over it — every drop beneath clear of it — itself again at once, and what the
    // view aims at. On its place's card, inside the glass that frames it: the frame, as the
    // window's own between its cards, is no place.
    const body: dvui.Point.Physical = .{ .x = bounds.x + 32, .y = bounds.y + bounds.h - 32 };
    try pointTo(body, ManyPanelFrame.frame, 1);
    try std.testing.expect(editor.app.layout.view_drag.ghost_firm);
    try restOn(editor, body, ManyPanelFrame.frame);
    try std.testing.expect(editor.app.layout.view_drag.ghost_firm);
    try std.testing.expectEqual(@as(f32, 0), asideOf(editor, 0));
    try std.testing.expectEqualStrings("Float 1", ViewDrag.targetAt(&layout, body, "Float 1") orelse return error.TestExpectedEqual);

    // Off it again, and let go over nothing: back as it was.
    try pointTo(try offFloat(bounds), ManyPanelFrame.frame, ghost_frames);
    try std.testing.expectEqual(@as(f32, 1), asideOf(editor, 0));
    editor.app.layout.view_drag.discard(editor.app.gpa);
    try dvui.testing.settle(ManyPanelFrame.frame);
    try std.testing.expectEqual(@as(usize, 1), openFloats(editor));
    try std.testing.expectEqual(@as(f32, 0), asideOf(editor, 0));
}

test "float: the drops beneath a ghost sit clear of it, and it firms up as the view comes over it" {
    var ctx = try shim.init(std.testing.allocator);
    defer ctx.deinit(std.testing.allocator);
    const editor = ctx.editor;
    const gpa = std.testing.allocator;
    editor.app.gpa = gpa;
    defer editor.app.layout.regions.deinit(gpa);
    defer editor.app.layout.regions_building.deinit(gpa);
    defer editor.app.layout.deinitExtents(gpa);
    defer editor.app.layout.deinitQualified(gpa);
    defer editor.app.layout.deinitAssignments(gpa);
    // A narrow float, Main roomy beside it.
    const win: dvui.Rect.Physical = .{ .x = 200, .y = 100, .w = 180, .h = 260 };
    const head: dvui.Rect.Physical = .{ .x = win.x, .y = win.y, .w = win.w, .h = 40 };
    const place: dvui.Rect.Physical = .{ .x = win.x, .y = win.y + 40, .w = win.w, .h = win.h - 40 };
    try FloatOverMain.registerAt(editor, false, win);
    const state = &editor.app.layout;
    const cw = dvui.currentWindow();
    const prev_mouse = cw.mouse_pt;
    defer cw.mouse_pt = prev_mouse;

    var layout = fizzy.Editor.Layout.init(&editor.app.host, state, gpa, cw.arena());
    const ViewDrag = fizzy.Editor.Layout.ViewDrag;
    cw.mouse_pt = place.center();
    ViewDrag.begin(&layout, "Float 1", place, place);
    defer state.view_drag.discard(gpa);

    // Aimed off the float: a ghost, and beside it, what is beneath.
    const beside: dvui.Point.Physical = .{ .x = 650, .y = 200 };
    cw.mouse_pt = beside;
    try std.testing.expect(!ViewDrag.settleGhost(state));
    try std.testing.expectEqualStrings("Main", ViewDrag.targetAt(&layout, beside, "Float 1") orelse return error.TestExpectedEqual);
    // Main's drop is clear of the ghost, as of any float: there is room beside it.
    const main_drop = ViewDrag.wheelOf(state, "Main") orelse return error.TestExpectedEqual;
    try std.testing.expect(!win.contains(main_drop.center));

    // Carried over the ghost, it firms up at once — nothing beneath is under it to be reached
    // through it — and the float's place is what the view aims at.
    const corner: dvui.Point.Physical = .{ .x = place.x + 16, .y = place.y + place.h - 12 };
    cw.mouse_pt = corner;
    try std.testing.expect(ViewDrag.settleGhost(state));
    try std.testing.expectEqualStrings("Float 1", ViewDrag.targetAt(&layout, corner, "Float 1") orelse return error.TestExpectedEqual);
    // Main's drop has not moved for it.
    try std.testing.expectEqual(main_drop.center, (ViewDrag.wheelOf(state, "Main") orelse return error.TestExpectedEqual).center);
    // Over its header, nothing: its handle.
    try std.testing.expect(ViewDrag.targetAt(&layout, head.center(), "Float 1") == null);

    // Off it again: a ghost, and Main's drop where it was.
    cw.mouse_pt = beside;
    try std.testing.expect(!ViewDrag.settleGhost(state));
    try std.testing.expectEqual(main_drop.center, (ViewDrag.wheelOf(state, "Main") orelse return error.TestExpectedEqual).center);
}

test "float: a drop squeezed by the ghost stays whole under it, reached through it, and the ghost firms only for a rest off it" {
    var ctx = try shim.init(std.testing.allocator);
    defer ctx.deinit(std.testing.allocator);
    const editor = ctx.editor;
    const gpa = std.testing.allocator;
    editor.app.gpa = gpa;
    defer editor.app.layout.regions.deinit(gpa);
    defer editor.app.layout.regions_building.deinit(gpa);
    defer editor.app.layout.deinitExtents(gpa);
    defer editor.app.layout.deinitQualified(gpa);
    defer editor.app.layout.deinitAssignments(gpa);
    // A float over nearly all of Main: what is left of Main round it is a thin frame.
    const win: dvui.Rect.Physical = .{ .x = 24, .y = 20, .w = 752, .h = 360 };
    const head: dvui.Rect.Physical = .{ .x = win.x, .y = win.y, .w = win.w, .h = 40 };
    const place: dvui.Rect.Physical = .{ .x = win.x, .y = win.y + 40, .w = win.w, .h = win.h - 40 };
    try FloatOverMain.registerAt(editor, false, win);
    const state = &editor.app.layout;
    const cw = dvui.currentWindow();
    const prev_mouse = cw.mouse_pt;
    defer cw.mouse_pt = prev_mouse;

    var layout = fizzy.Editor.Layout.init(&editor.app.host, state, gpa, cw.arena());
    const ViewDrag = fizzy.Editor.Layout.ViewDrag;
    cw.mouse_pt = place.center();
    ViewDrag.begin(&layout, "Float 1", place, place);
    defer state.view_drag.discard(gpa);

    const prev_time = cw.frame_time_ns;
    defer cw.frame_time_ns = prev_time;
    // Aimed off the float, beside it in what is left of Main: a ghost.
    const beside: dvui.Point.Physical = .{ .x = 10, .y = 200 };
    cw.mouse_pt = beside;
    try std.testing.expect(!ViewDrag.settleGhost(state));
    try std.testing.expectEqualStrings("Main", ViewDrag.targetAt(&layout, beside, "Float 1") orelse return error.TestExpectedEqual);
    // Too little of Main is clear of it for its drop: the drop sits under the ghost, whole, and
    // aimed at there through it, it is Main's.
    const main_drop = ViewDrag.wheelOf(state, "Main") orelse return error.TestExpectedEqual;
    try std.testing.expect(win.contains(main_drop.center));
    try std.testing.expectEqual(DZ.wheel(ViewDrag.interiorBounds(state, "Main") orelse return error.TestExpectedEqual, cw.natural_scale, main_drop.remove).unit, main_drop.unit);
    try std.testing.expectEqualStrings("Main", ViewDrag.targetAt(&layout, main_drop.center, "Float 1") orelse return error.TestExpectedEqual);

    // Carried across the ghost to that drop, it stays a ghost — over it off the drop, the view is
    // over Main and no bubble of it — and on the drop, it is a ghost however long it rests there.
    const corner: dvui.Point.Physical = .{ .x = place.x + 16, .y = place.y + place.h - 12 };
    try std.testing.expect(DZ.at(main_drop, corner) == null);
    cw.mouse_pt = corner;
    try std.testing.expect(!ViewDrag.settleGhost(state));
    try std.testing.expectEqualStrings("Main", ViewDrag.targetAt(&layout, corner, "Float 1") orelse return error.TestExpectedEqual);
    cw.mouse_pt = main_drop.center;
    try std.testing.expect(!ViewDrag.settleGhost(state));
    cw.frame_time_ns += 2 * ViewDrag.ghost_rest_ms * std.time.ns_per_ms;
    try std.testing.expect(!ViewDrag.settleGhost(state));

    // Rested on off the drop, it firms up, and stays firm over it: the float's place is what the
    // view aims at there and over Main's drop — which stays where it is, under it.
    cw.mouse_pt = corner;
    try std.testing.expect(!ViewDrag.settleGhost(state));
    cw.frame_time_ns += ViewDrag.ghost_rest_ms * std.time.ns_per_ms;
    try std.testing.expect(ViewDrag.settleGhost(state));
    try std.testing.expectEqualStrings("Float 1", ViewDrag.targetAt(&layout, corner, "Float 1") orelse return error.TestExpectedEqual);
    try std.testing.expectEqualStrings("Float 1", ViewDrag.targetAt(&layout, main_drop.center, "Float 1") orelse return error.TestExpectedEqual);
    try std.testing.expectEqual(main_drop.center, (ViewDrag.wheelOf(state, "Main") orelse return error.TestExpectedEqual).center);

    // Off it, and rested on its header: firm too, the header being its handle.
    cw.mouse_pt = beside;
    try std.testing.expect(!ViewDrag.settleGhost(state));
    cw.mouse_pt = head.center();
    try std.testing.expect(!ViewDrag.settleGhost(state));
    cw.frame_time_ns += ViewDrag.ghost_rest_ms * std.time.ns_per_ms;
    try std.testing.expect(ViewDrag.settleGhost(state));
}

test "float: a float of two is a ghost too, and comes back without the view that landed elsewhere" {
    var case = try ManyPanelCase.init();
    defer case.deinit();
    const editor = case.ctx.editor;
    try editor.app.host.registerSurface(.{ .id = "test.problems", .title = "Problems", .keywords = fizzy.sdk.keywords.ide.panel, .draw = ManyPanelFrame.draw });
    try dvui.testing.settle(ManyPanelFrame.frame);
    try case.place("Panel", "Panel", .swap);
    // The other panel view joins it: a float of two.
    try case.place("Panel", "Float 1", .swap);
    try std.testing.expectEqual(@as(usize, 2), case.shows("Float 1").len);
    const floats = &editor.app.layout.floats;
    const bounds = floats.items.items[0].bounds;
    const carried = visibleIn(editor, "Float 1") orelse return error.TestExpectedEqual;

    var layout = fizzy.Editor.Layout.init(&editor.app.host, &editor.app.layout, editor.app.gpa, dvui.currentWindow().arena());
    const ViewDrag = fizzy.Editor.Layout.ViewDrag;
    ViewDrag.begin(&layout, "Float 1", bounds, bounds);
    // A ghost while the view is aimed off it: it covers nothing.
    try pointTo(try offFloat(bounds), ManyPanelFrame.frame, ghost_frames);
    try std.testing.expectEqual(@as(f32, 1), floats.items.items[0].aside.at());
    try std.testing.expect(!editor.app.layout.view_drag.ghost_firm);

    // Landed in Panel, which takes it beside what it shows: the float comes back, holding the
    // other.
    ViewDrag.place(&layout, "Float 1", "Panel", .swap);
    editor.app.layout.view_drag.discard(editor.app.gpa);
    try dvui.testing.settle(ManyPanelFrame.frame);
    try std.testing.expectEqual(@as(usize, 1), openFloats(editor));
    try std.testing.expectEqual(@as(f32, 0), floats.items.items[0].aside.at());
    const left = case.shows("Float 1");
    try std.testing.expectEqual(@as(usize, 1), left.len);
    try std.testing.expect(!std.mem.eql(u8, left[0], carried));
}

test "float: a ghost for its last view goes when the view lands, without flying shut" {
    var case = try ManyPanelCase.init();
    defer case.deinit();
    const editor = case.ctx.editor;
    try case.place("Panel", "Panel", .swap);
    const floats = &editor.app.layout.floats;
    const bounds = floats.items.items[0].bounds;

    var layout = fizzy.Editor.Layout.init(&editor.app.host, &editor.app.layout, editor.app.gpa, dvui.currentWindow().arena());
    const ViewDrag = fizzy.Editor.Layout.ViewDrag;
    ViewDrag.begin(&layout, "Float 1", bounds, bounds);
    try pointTo(try offFloat(bounds), ManyPanelFrame.frame, ghost_frames);
    // Released on Panel, as `apply` lands it, then the drag ends.
    ViewDrag.place(&layout, "Float 1", "Panel", .swap);
    editor.app.layout.view_drag.discard(editor.app.gpa);
    _ = try dvui.testing.step(ManyPanelFrame.frame);
    // Gone on the next frame: no glass reappearing to fly shut.
    try std.testing.expectEqual(@as(usize, 0), floats.items.items.len);
    try dvui.testing.settle(ManyPanelFrame.frame);
    try std.testing.expect(holds(case.shows("Panel"), "test.output"));
}

/// A view that counts its draws and keeps the alpha it was last drawn at.
const FadeProbe = struct {
    var draws: usize = 0;
    var alpha: f32 = 0;

    fn draw(_: ?*anyopaque) anyerror!dvui.App.Result {
        draws += 1;
        alpha = dvui.currentWindow().alpha;
        return .ok;
    }
};

// The view of a float coming back is drawn into a picture of itself and laid down at the fade,
// so even what it draws past dvui's alpha fades with the window. dvui's testing backend has no
// render targets, so here it is the fallback — the view under the window's alpha — that runs: it
// still draws the view once a frame, and never ahead of the window round it.
test "float: coming back without the view that landed elsewhere, it draws its view once a frame, never ahead of its window" {
    var case = try ManyPanelCase.init();
    defer case.deinit();
    const editor = case.ctx.editor;
    try editor.app.host.registerSurface(.{ .id = "test.probe", .title = "Probe", .keywords = fizzy.sdk.keywords.ide.panel, .draw = FadeProbe.draw });
    editor.app.host.setSelectionFor(fizzy.sdk.keywords.ide.panel, "test.probe");
    try dvui.testing.settle(ManyPanelFrame.frame);
    try std.testing.expectEqualStrings("test.probe", visibleIn(editor, "Panel") orelse return error.TestExpectedEqual);
    // The probe floated, then Output beside it in the float, in front of it.
    try case.place("Panel", "Panel", .swap);
    try case.place("Panel", "Float 1", .swap);
    try std.testing.expectEqualStrings("test.output", visibleIn(editor, "Float 1") orelse return error.TestExpectedEqual);
    const floats = &editor.app.layout.floats;
    const bounds = floats.items.items[0].bounds;

    // Output carried out to Panel: the float is a ghost while it is aimed there, and comes back
    // holding the probe.
    var layout = fizzy.Editor.Layout.init(&editor.app.host, &editor.app.layout, editor.app.gpa, dvui.currentWindow().arena());
    const ViewDrag = fizzy.Editor.Layout.ViewDrag;
    ViewDrag.begin(&layout, "Float 1", bounds, bounds);
    try pointTo(try offFloat(bounds), ManyPanelFrame.frame, ghost_frames);
    ViewDrag.place(&layout, "Float 1", "Panel", .swap);
    editor.app.layout.view_drag.discard(editor.app.gpa);

    var faded = false;
    for (0..ghost_frames) |_| {
        const before = FadeProbe.draws;
        _ = try dvui.testing.step(ManyPanelFrame.frame);
        try std.testing.expectEqual(before + 1, FadeProbe.draws);
        const shown = fizzy.Editor.Layout.Floats.ghostLook(floats.items.items[0].aside.at()).alpha;
        try std.testing.expect(FadeProbe.alpha <= shown + 0.001);
        if (FadeProbe.alpha > 0.001 and FadeProbe.alpha < 0.999) faded = true;
    }
    try std.testing.expect(faded);
    try std.testing.expectEqual(@as(f32, 1), FadeProbe.alpha);
    try std.testing.expectEqualStrings("test.probe", visibleIn(editor, "Float 1") orelse return error.TestExpectedEqual);
}

// ── The drag over the floats ─────────────────────────────────────────────────────────────────────

/// `ManyPanelFrame` with the view drag's overlay over all of it, as fizzy's frame draws it last.
const OverlaidFrame = struct {
    fn frame() anyerror!dvui.App.Result {
        const result = try ManyPanelFrame.frame();
        const e = ManyPanelFrame.editor.?;
        var layout = fizzy.Editor.Layout.init(&e.app.host, &e.app.layout, e.app.gpa, dvui.currentWindow().arena());
        layout.drawDragOverlay();
        return result;
    }
};

test "float: a drag's own layer is over every float" {
    var case = try ManyPanelCase.init();
    defer case.deinit();
    const editor = case.ctx.editor;
    try case.place("Panel", "Panel", .swap);
    const main = fizzy.Editor.Layout.ViewDrag.placeBounds(&editor.app.layout, "Main") orelse return error.TestExpectedEqual;

    // A view carried over the float: its drops and the card go over the float's glass, which a
    // floating widget made in the app's own window would stay under.
    var layout = fizzy.Editor.Layout.init(&editor.app.host, &editor.app.layout, editor.app.gpa, dvui.currentWindow().arena());
    fizzy.Editor.Layout.ViewDrag.begin(&layout, "Main", main, main);
    defer editor.app.layout.view_drag.discard(editor.app.gpa);
    _ = try dvui.testing.step(OverlaidFrame.frame);
    _ = try dvui.testing.step(OverlaidFrame.frame);
    const float_id = editor.app.layout.floats.items.items[0].win_id;
    const stack = dvui.currentWindow().subwindows.stack.items;
    var float_at: ?usize = null;
    for (stack, 0..) |sw, k| {
        if (sw.id == float_id) float_at = k;
    }
    // The top of the stack: the drag's layer, taking no pointer events, over the float.
    try std.testing.expect(float_at.? < stack.len - 1);
    try std.testing.expect(!stack[stack.len - 1].mouse_events);
}

test "float: a strip a float lies over is no chooser where the float is, and is one beside it" {
    var ctx = try shim.init(std.testing.allocator);
    defer ctx.deinit(std.testing.allocator);
    const editor = ctx.editor;
    const gpa = std.testing.allocator;
    editor.app.gpa = gpa;
    defer editor.app.layout.regions.deinit(gpa);
    defer editor.app.layout.regions_building.deinit(gpa);
    defer editor.app.layout.deinitExtents(gpa);
    defer editor.app.layout.deinitQualified(gpa);
    defer editor.app.layout.deinitAssignments(gpa);
    try FloatOverMain.register(editor, false);

    const state = &editor.app.layout;
    var layout = fizzy.Editor.Layout.init(&editor.app.host, state, gpa, dvui.currentWindow().arena());
    const ViewDrag = fizzy.Editor.Layout.ViewDrag;
    ViewDrag.begin(&layout, "Panel", FloatOverMain.panel_at, FloatOverMain.panel_at);
    defer state.view_drag.discard(gpa);

    // A strip across Main, drawn in the app's own window, running under the float's body — a tab
    // strip of a pane the float lies over, as a plugin offers one (`Host.Region.offerChooser`).
    const strip: dvui.Rect.Physical = .{ .x = 0, .y = 200, .w = 800, .h = 30 };
    ViewDrag.offerChooser(&layout, "Main", strip, true, null);
    // Where the float lies over it, the float is what the view is over: the strip opens no slot
    // there, and a release does not go into it.
    try std.testing.expect(ViewDrag.chooserAt(state, .{ .x = 350, .y = 215 }) == null);
    // Beside the float, the strip as ever.
    const o = ViewDrag.chooserAt(state, .{ .x = 650, .y = 215 }) orelse return error.TestExpectedEqual;
    try std.testing.expectEqualStrings("Main", o.name);
}

/// What `canvasPointerInputSuppressed` answered last frame, asked from the main window and from
/// inside a floating window over it (`canvasGateFrame`).
var canvas_gate_main: ?bool = null;
var canvas_gate_float: ?bool = null;
const canvas_gate_rect: dvui.Rect = .{ .x = 200, .y = 150, .w = 300, .h = 200 };

fn canvasGateFrame() anyerror!dvui.App.Result {
    canvas_gate_main = fizzy.core.dialogs.canvasPointerInputSuppressed();
    var rect = canvas_gate_rect;
    const win = fizzy.core.widgets.floatingWindow(@src(), .{ .rect = &rect, .placed = true, .window_avoid = .none }, .{});
    defer win.deinit();
    canvas_gate_float = fizzy.core.dialogs.canvasPointerInputSuppressed();
    return .ok;
}

test "float: a document canvas in a float takes the pointer, and one under it does not" {
    var t = try dvui.testing.init(.{ .allocator = std.testing.allocator, .window_size = .{ .w = 800, .h = 600 } });
    defer t.deinit();
    const cw = dvui.currentWindow();

    // Pointer positions are physical pixels.
    const s = cw.natural_scale;
    const over = canvas_gate_rect.center().scale(s, dvui.Point.Physical);
    // Over the float: a canvas drawn in it takes the pointer (it used to be blocked, as though
    // the float were a dialog over the main window's canvas), and the main window's does not.
    _ = try cw.addEventMouseMotion(.{ .pt = over });
    try dvui.testing.settle(canvasGateFrame);
    try std.testing.expectEqual(false, canvas_gate_float.?);
    try std.testing.expectEqual(true, canvas_gate_main.?);

    // Beside it, the other way round.
    _ = try cw.addEventMouseMotion(.{ .pt = .{ .x = 50 * s, .y = 50 * s } });
    try dvui.testing.settle(canvasGateFrame);
    try std.testing.expectEqual(true, canvas_gate_float.?);
    try std.testing.expectEqual(false, canvas_gate_main.?);
}

const workbench = @import("workbench");

test "workbench: where a tab carried over a strip goes in is read as if its open slot were not there" {
    // Three tabs, 100 wide, the middle one at index 1 in the pane's list; a slot 80 wide open
    // before the third (`drawGap`), which has moved along by that much.
    var pane = workbench.Workspace.init(1);
    pane.tab_slots[0] = .{ .index = 0, .rect = .{ .x = 0, .y = 0, .w = 100, .h = 30 } };
    pane.tab_slots[1] = .{ .index = 1, .rect = .{ .x = 100, .y = 0, .w = 100, .h = 30 } };
    pane.tab_slots[2] = .{ .index = 2, .rect = .{ .x = 280, .y = 0, .w = 100, .h = 30 } };
    pane.tab_slot_count = 3;
    pane.gap_x = 200;
    pane.gap_w = 80;
    // Short of a tab's middle, before it; past the last one's, the end.
    try std.testing.expectEqual(@as(usize, 0), pane.insertIndexAt(40, 3));
    try std.testing.expectEqual(@as(usize, 1), pane.insertIndexAt(120, 3));
    // Over the open slot itself, where the third tab stood before it opened: still before the
    // third — the slot does not chase the pointer along the strip.
    try std.testing.expectEqual(@as(usize, 2), pane.insertIndexAt(230, 3));
    try std.testing.expectEqual(@as(usize, 3), pane.insertIndexAt(290, 3));
    try std.testing.expectEqual(@as(usize, 3), pane.insertIndexAt(500, 3));
}

fn glyphLuma(c: dvui.Color) f32 {
    return 0.2126 * @as(f32, @floatFromInt(c.r)) + 0.7152 * @as(f32, @floatFromInt(c.g)) + 0.0722 * @as(f32, @floatFromInt(c.b));
}

test "workbench: a file tree's glyphs stand off the main window's base and a float's pane alike" {
    // Fizzy Dark's colours, as `Editor` sets them up (no themes are loaded here).
    var fizzy_dark = dvui.Theme.builtin.adwaita_dark;
    fizzy_dark.window = .{ .fill = .{ .r = 28, .g = 29, .b = 36 }, .text = .{ .r = 206, .g = 163, .b = 127 } };
    fizzy_dark.control = .{ .fill = .{ .r = 28, .g = 29, .b = 36 }, .text = .{ .r = 134, .g = 138, .b = 148 } };
    fizzy_dark.fill = .{ .r = 42, .g = 44, .b = 54 };
    // The report, measured in a popped-out float on Liquid Glass: its explorer's pane card, and the
    // main window's sidebar beside it. The window's fill, which the glyphs rested in, was the
    // sidebar's dark glyph and within a few steps of the float's card: invisible there.
    const float_card: dvui.Color = .{ .r = 38, .g = 39, .b = 45 };
    const main_base: dvui.Color = .{ .r = 65, .g = 67, .b = 74 };
    try std.testing.expect(@abs(glyphLuma(fizzy_dark.color(.window, .fill)) - glyphLuma(float_card)) < 15);
    const glyph = fizzy.core.widgets.treeGlyphColor(fizzy_dark);
    try std.testing.expect(@abs(glyphLuma(glyph) - glyphLuma(float_card)) > 60);
    try std.testing.expect(@abs(glyphLuma(glyph) - glyphLuma(main_base)) > 40);

    // And in every theme fizzy ships with dvui's: off the window's fill and the content fill (a
    // pane's card), whichever a tree is drawn on, in the main window or a float.
    for (dvui.Theme.builtins) |theme| {
        const g = fizzy.core.widgets.treeGlyphColor(theme);
        for ([_]dvui.Color{ theme.color(.window, .fill), theme.color(.content, .fill) }) |base| {
            std.testing.expect(@abs(glyphLuma(g) - glyphLuma(base)) > 40) catch |err| {
                std.debug.print("{s}: glyph {f} on {f}\n", .{ theme.name, g, base });
                return err;
            };
        }
    }
}

// An app's home page in place of the workbench's: a surface keyworded `home`, shown in the `Home`
// place the sole document pane declares while it is empty (`Workspace.drawHome`). The pane here is
// declared as `Workspace.draw` declares it, through the plugin's `Host`, so the place is the one
// the workbench makes.
const HomeFrame = struct {
    var editor: ?*fizzy.Editor = null;
    /// Which home surface drew this frame (its `ctx`), and how many times one did.
    var home: ?usize = null;
    var home_draws: usize = 0;
    var doc_draws: usize = 0;
    /// The workbench would have drawn its own page this frame.
    var builtin_home = false;

    const pane_key: u64 = 1;
    const doc = "test.doc:/notes.txt";

    fn drawHome(ctx: ?*anyopaque) anyerror!dvui.App.Result {
        home = @intFromPtr(ctx);
        home_draws += 1;
        return .ok;
    }

    fn drawDoc(_: ?*anyopaque) anyerror!dvui.App.Result {
        doc_draws += 1;
        return .ok;
    }

    fn registerHome(e: *fizzy.Editor, id: []const u8, n: usize) !void {
        try e.app.host.registerSurface(.{
            .id = id,
            .title = "Start",
            .keywords = fizzy.sdk.keywords.ide.home,
            .ctx = @ptrFromInt(n),
            .draw = drawHome,
        });
    }

    fn frame() anyerror!dvui.App.Result {
        const e = editor.?;
        home = null;
        home_draws = 0;
        doc_draws = 0;
        builtin_home = false;
        var layout = fizzy.Editor.Layout.init(&e.app.host, &e.app.layout, e.app.gpa, dvui.currentWindow().arena());
        e.app.frame_layout = &layout;
        defer e.app.frame_layout = null;
        {
            var main = try layout.region(@src(), .{
                .name = "Main",
                .keywords = fizzy.sdk.keywords.ide.main,
            }, .{ .expand = .both });
            defer main.deinit();

            var pane = e.app.host.region(.{
                .name = "Pane 1",
                .keywords = fizzy.sdk.document.keywords,
                .key = pane_key,
            }) orelse return error.TestUnexpectedResult;
            defer pane.deinit();
            if (pane.matching().len > 0) {
                _ = try pane.drawContents();
            } else {
                builtin_home = !try workbench.Workspace.drawHome(&e.app.host, pane_key);
            }
        }
        e.app.layout.publishRegions();
        return .ok;
    }
};

test "workbench: a home surface shows while nothing is open, and a document puts it away" {
    var ctx = try shim.init(std.testing.allocator);
    defer ctx.deinit(std.testing.allocator);

    const editor = ctx.editor;
    const gpa = std.testing.allocator;
    editor.app.gpa = gpa;
    defer editor.app.layout.regions.deinit(gpa);
    defer editor.app.layout.deinitSwaps(gpa);
    defer editor.app.layout.regions_building.deinit(gpa);
    defer editor.app.layout.deinitQualified(gpa);
    editor.app.host.installFizzyApi(.{ .ctx = editor, .vtable = &fizzy.Editor.fizzy_api_vtable });

    HomeFrame.editor = editor;
    defer HomeFrame.editor = null;

    // No plugin offers a home page: the place declines, and the workbench draws its own.
    try dvui.testing.settle(HomeFrame.frame);
    try std.testing.expect(HomeFrame.builtin_home);
    try std.testing.expectEqual(@as(usize, 0), HomeFrame.home_draws);

    // One does: it is the home page, drawn once, in the Home place and not in Main beside it.
    try HomeFrame.registerHome(editor, "test.home", 1);
    try dvui.testing.settle(HomeFrame.frame);
    try std.testing.expect(!HomeFrame.builtin_home);
    try std.testing.expectEqual(@as(usize, 1), HomeFrame.home_draws);
    try std.testing.expectEqual(@as(?usize, 1), HomeFrame.home);

    // A restored session: the pane already lists a document that has not landed. Nothing is open
    // yet, so the home stays...
    try editor.app.host.assignSurfaces("Pane 1", &.{HomeFrame.doc});
    try dvui.testing.settle(HomeFrame.frame);
    try std.testing.expectEqual(@as(usize, 1), HomeFrame.home_draws);

    // ...until it lands, a few frames later, and the home is put away: drawn nowhere, Main
    // included, with nothing on the plugin's side.
    try editor.app.host.registerSurface(.{
        .id = HomeFrame.doc,
        .title = "notes.txt",
        .keywords = fizzy.sdk.document.keywords,
        .draw = HomeFrame.drawDoc,
    });
    try dvui.testing.settle(HomeFrame.frame);
    try std.testing.expectEqual(@as(usize, 1), HomeFrame.doc_draws);
    try std.testing.expectEqual(@as(usize, 0), HomeFrame.home_draws);
    try std.testing.expect(!HomeFrame.builtin_home);

    // The last document closing brings it back.
    editor.app.host.unregisterSurface(HomeFrame.doc);
    try dvui.testing.settle(HomeFrame.frame);
    try std.testing.expectEqual(@as(usize, 1), HomeFrame.home_draws);
    try std.testing.expectEqual(@as(?usize, 1), HomeFrame.home);

    // Two plugins offer one: the first registered shows, until the app chooses the other by
    // assigning the place, as the picker would.
    try HomeFrame.registerHome(editor, "test.home2", 2);
    try dvui.testing.settle(HomeFrame.frame);
    try std.testing.expectEqual(@as(?usize, 1), HomeFrame.home);
    try editor.app.host.assignSurfaces(workbench.Workspace.home_region, &.{"test.home2"});
    try dvui.testing.settle(HomeFrame.frame);
    try std.testing.expectEqual(@as(usize, 1), HomeFrame.home_draws);
    try std.testing.expectEqual(@as(?usize, 2), HomeFrame.home);
}

test "workbench: restoring panes leaves tape and demo files out of the assignment" {
    var ctx = try shim.init(std.testing.allocator);
    defer ctx.deinit(std.testing.allocator);

    const editor = ctx.editor;
    const gpa = std.testing.allocator;
    editor.app.gpa = gpa;
    defer editor.app.layout.regions.deinit(gpa);
    defer editor.app.layout.deinitSwaps(gpa);
    defer editor.app.layout.regions_building.deinit(gpa);
    defer editor.app.layout.deinitQualified(gpa);
    editor.app.host.installFizzyApi(.{ .ctx = editor, .vtable = &fizzy.Editor.fizzy_api_vtable });

    // Installing the runtime routes dialogs through this host, which is freed with the test.
    const prior_chrome = fizzy.core.dialogs.host_chrome;
    fizzy.sdk.installRuntime(&editor.app.gpa, &editor.app.host, null);
    defer fizzy.core.dialogs.host_chrome = prior_chrome;
    editor.workbench = .init(gpa);
    defer editor.workbench.deinit();
    try editor.workbench.initDefaultWorkspace();
    defer editor.workbench.panes.deinit();
    defer editor.workbench.workspaces.deinit(gpa);
    workbench.runtime.setWorkbench(&editor.workbench);
    // The real path is opened through these; no plugin claims its extension here, so it stays closed.
    editor.app.file_table = fizzy.core.FileTable.init(gpa, dvui.io);
    defer editor.app.file_table.deinit();
    editor.doc_io = @FieldType(fizzy.Editor, "doc_io").init(editor);

    // Last session quit mid-tour, with a recording's tab open beside a file of the person's.
    const real = "test.doc:/home/nobody/restore-real.txt";
    try editor.app.host.assignSurfaces("Pane 1", &.{ "test.doc:demo://tour/x.zig", "test.doc:tape://1/a.txt", real });
    editor.workbench.restored = false;
    try editor.workbench.rebuildWorkspaces();

    const kept = editor.app.host.assignedSurfaces("Pane 1") orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(@as(usize, 1), kept.len);
    try std.testing.expectEqualStrings(real, kept[0]);
    try std.testing.expect(editor.app.host.docFromPath("demo://tour/x.zig") == null);
    try std.testing.expect(editor.app.host.docFromPath("tape://1/a.txt") == null);

    // A pane holding nothing else goes, rather than waiting for what will never come.
    try editor.app.host.assignSurfaces("Pane 2", &.{"test.doc:demo://tour/y.zig"});
    editor.workbench.restored = false;
    try editor.workbench.rebuildWorkspaces();
    try std.testing.expect(editor.app.host.assignedSurfaces("Pane 2") == null);
}

// The Files explorer over a folder of 300,000 notes. The folder is read, indexed and ranked off
// the frame, and a frame draws only the rows in view, so the work of a frame does not grow with
// the folder. Budgets are for a Debug build on a busy CI machine: the median idle frame is under
// `explorer_frame_budget_ns`, and no frame while the folder loads or is searched takes longer than
// `explorer_stall_budget_ns` (it was 5.5 s to read the folder in one frame, and 3 s to index it).
const explorer_frame_budget_ns = 16 * std.time.ns_per_ms;
const explorer_stall_budget_ns = 500 * std.time.ns_per_ms;

var explorer_scroll: dvui.ScrollInfo = .{ .horizontal = .none };

fn explorerFrame() !dvui.App.Result {
    fizzy.core.anchor.want();
    // The host pumps the file table once a frame, before anything draws.
    workbench.runtime.host().files.?.pump();
    var scroll = dvui.scrollArea(@src(), .{ .scroll_info = &explorer_scroll }, .{ .expand = .both });
    defer scroll.deinit();
    try workbench.files.draw();
    return .ok;
}

/// Steps frames until `done`, returning the longest one. Gives up after a minute.
fn explorerStepUntil(comptime done: fn (*fizzy.core.FileTable) bool, table: *fizzy.core.FileTable) !i128 {
    const perf = fizzy.core.perf;
    var slowest: i128 = 0;
    const give_up = perf.nanoTimestamp() + 60 * std.time.ns_per_s;
    while (!done(table)) {
        const t0 = perf.nanoTimestamp();
        _ = try dvui.testing.step(explorerFrame);
        slowest = @max(slowest, perf.nanoTimestamp() - t0);
        if (perf.nanoTimestamp() > give_up) return error.NeverSettled;
        std.Thread.yield() catch {};
    }
    return slowest;
}

fn explorerListed(table: *fizzy.core.FileTable) bool {
    return table.listings.count() > 0 and table.pending.count() == 0;
}

fn explorerSearched(table: *fizzy.core.FileTable) bool {
    return !table.indexing() and !table.ranking() and table.results.items.len > 0;
}

fn explorerMedianFrameNs(frames: usize) !i128 {
    var took: [32]i128 = undefined;
    for (took[0..frames]) |*t| {
        const t0 = fizzy.core.perf.nanoTimestamp();
        _ = try dvui.testing.step(explorerFrame);
        t.* = fizzy.core.perf.nanoTimestamp() - t0;
    }
    std.mem.sort(i128, took[0..frames], {}, std.sort.asc(i128));
    return took[frames / 2];
}

test "workbench: the Files explorer frame does not grow with a 300k-note folder" {
    var ctx = try shim.init(std.testing.allocator);
    defer ctx.deinit(std.testing.allocator);

    const editor = ctx.editor;
    const gpa = std.testing.allocator;
    editor.app.gpa = gpa;
    defer editor.app.layout.regions.deinit(gpa);
    defer editor.app.layout.deinitSwaps(gpa);
    defer editor.app.layout.regions_building.deinit(gpa);
    defer editor.app.layout.deinitQualified(gpa);
    editor.app.host.installFizzyApi(.{ .ctx = editor, .vtable = &fizzy.Editor.fizzy_api_vtable });
    const prior_chrome = fizzy.core.dialogs.host_chrome;
    fizzy.sdk.installRuntime(&editor.app.gpa, &editor.app.host, null);
    defer fizzy.core.dialogs.host_chrome = prior_chrome;
    editor.workbench = .init(gpa);
    defer editor.workbench.deinit();
    try editor.workbench.initDefaultWorkspace();
    defer editor.workbench.panes.deinit();
    defer editor.workbench.workspaces.deinit(gpa);
    workbench.runtime.setWorkbench(&editor.workbench);
    // The selection is a module global the next test shares: freed, and left usable.
    defer {
        workbench.files.deinitCaches();
        workbench.files.selected_paths = .empty;
        workbench.files.selected_id = null;
    }
    editor.app.file_table = fizzy.core.FileTable.init(gpa, dvui.io);
    defer editor.app.file_table.deinit();
    const table = &editor.app.file_table;
    editor.app.host.files = table;
    // The app has a live folder watcher; without one the table re-reads a listing every second.
    table.env.watching = struct {
        fn live(_: ?*anyopaque) bool {
            return true;
        }
    }.live;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const n: usize = 300_000;
    var name_buf: [32]u8 = undefined;
    for (0..n) |i| {
        const name = try std.fmt.bufPrint(&name_buf, "note-{d:0>6}.md", .{i});
        var f = try tmp.dir.createFile(dvui.io, name, .{});
        f.close(dvui.io);
    }
    var root_buf: [std.fs.max_path_bytes]u8 = undefined;
    const root = root_buf[0..try tmp.dir.realPath(dvui.io, &root_buf)];
    editor.app.folder = try gpa.dupe(u8, root);
    defer gpa.free(editor.app.folder.?);
    explorer_scroll = .{ .horizontal = .none };

    const last_name = try std.fmt.allocPrint(gpa, "note-{d:0>6}.md", .{n - 1});
    defer gpa.free(last_name);
    const last = try std.fs.path.join(gpa, &.{ root, last_name });
    defer gpa.free(last);
    const last_tag = try std.fmt.allocPrint(gpa, "workbench.file:{s}", .{last});
    defer gpa.free(last_tag);
    const hit = try std.fs.path.join(gpa, &.{ root, "note-123456.md" });
    defer gpa.free(hit);
    const hit_tag = try std.fmt.allocPrint(gpa, "workbench.file:{s}", .{hit});
    defer gpa.free(hit_tag);

    // Loading the folder: no frame waits for the disk, and the row says so meanwhile.
    const load_stall = try explorerStepUntil(explorerListed, table);
    for (0..8) |_| _ = try dvui.testing.step(explorerFrame);
    std.debug.print("explorer: slowest frame while loading {d} ms\n", .{@divTrunc(load_stall, std.time.ns_per_ms)});
    try std.testing.expect(load_stall < explorer_stall_budget_ns);

    // Idle, and scrolled to the end: only the rows in view are measured and drawn.
    try std.testing.expect(dvui.tagGet(last_tag) == null);
    const idle = try explorerMedianFrameNs(21);
    std.debug.print("explorer: median idle frame {d} us\n", .{@divTrunc(idle, std.time.ns_per_us)});
    try std.testing.expect(idle < explorer_frame_budget_ns);

    for (0..12) |_| {
        explorer_scroll.viewport.y = @max(0, explorer_scroll.virtual_size.h - explorer_scroll.viewport.h);
        _ = try dvui.testing.step(explorerFrame);
    }
    const scrolled = try explorerMedianFrameNs(21);
    std.debug.print("explorer: median scrolled frame {d} us\n", .{@divTrunc(scrolled, std.time.ns_per_us)});
    try std.testing.expect(scrolled < explorer_frame_budget_ns);

    // The last note is reachable, and selecting it selects it.
    try dvui.testing.expectVisible(last_tag);
    try dvui.testing.moveTo(last_tag);
    _ = try dvui.testing.step(explorerFrame);
    try dvui.testing.click(.left);
    for (0..3) |_| _ = try dvui.testing.step(explorerFrame);
    try std.testing.expectEqual(@as(usize, 1), workbench.files.selected_paths.count());
    try std.testing.expectEqualStrings(last, workbench.files.selected_paths.values()[0]);

    // Filtering for a name finds it among all of them, without a frame waiting for the index.
    explorer_scroll.viewport.y = 0;
    for (0..3) |_| _ = try dvui.testing.step(explorerFrame);
    _ = try dvui.currentWindow().addEventMouseMotion(.{ .pt = .{ .x = 80, .y = 14 } });
    _ = try dvui.testing.step(explorerFrame);
    try dvui.testing.click(.left);
    _ = try dvui.testing.step(explorerFrame);
    try dvui.testing.writeText("note-123456");
    const search_stall = try explorerStepUntil(explorerSearched, table);
    for (0..10) |_| _ = try dvui.testing.step(explorerFrame);
    std.debug.print("explorer: slowest frame while searching {d} ms\n", .{@divTrunc(search_stall, std.time.ns_per_ms)});
    try std.testing.expect(search_stall < explorer_stall_budget_ns);
    try dvui.testing.expectVisible(hit_tag);
    const filtered = try explorerMedianFrameNs(21);
    try std.testing.expect(filtered < explorer_frame_budget_ns);
}

// -- rows carried out of a tree and back --------------------------------------------------------

// A tree of two folders and two files, as the explorer draws one: `F` open with `c` inside it, `G`
// shut, then `a` and `b`. Rows carried out of it as another drag and brought back are handed to it
// each frame (`TreeWidget.carriedOver`), and whichever row then says it takes them is recorded.
const CarriedTree = struct {
    const TW = fizzy.core.widgets.TreeWidget;
    const f: usize = 1;
    const a: usize = 2;
    const b: usize = 3;
    const c: usize = 4;
    const g: usize = 5;

    const Carried = struct { primary: usize, p: dvui.Point.Physical, released: bool = false };
    const Landed = struct { row: usize, into: bool };

    var carried: ?Carried = null;
    var selected: []const usize = &.{};
    /// Put the tree's own drag down this frame (`TreeWidget.cancelDrag`).
    var cancel = false;
    var landed: ?Landed = null;
    /// Whether the tree's own drag was under way as this frame began.
    var dragging = false;
    var headers: [6]dvui.Rect.Physical = @splat(.{});

    fn reset() void {
        carried = null;
        selected = &.{};
        cancel = false;
        landed = null;
        dragging = false;
    }

    fn frame() anyerror!dvui.App.Result {
        var tree = TW.tree(@src(), .{ .enable_reordering = true, .drag_name = "test.row" }, .{ .expand = .both });
        defer tree.deinit();
        tree.selected_branch_ids = selected;
        dragging = tree.reorderDragActive();
        if (cancel) {
            cancel = false;
            tree.cancelDrag();
        }
        if (carried) |it| tree.carriedOver(it.primary, it.p, it.released);
        row(tree, f, true, true);
        row(tree, g, true, false);
        row(tree, a, false, false);
        row(tree, b, false, false);
        return .ok;
    }

    fn row(tree: *TW, id: usize, folder: bool, open: bool) void {
        const branch = tree.branch(@src(), .{
            .expanded = open,
            .animation_duration = 0,
            .can_accept_children = folder,
            .branch_id = id,
        }, .{ .id_extra = id, .expand = .horizontal });
        defer branch.deinit();
        headers[id] = branch.button.data().borderRectScale().r;
        if (branch.insertBefore()) landed = .{ .row = id, .into = false };
        if (branch.dropInto()) landed = .{ .row = id, .into = true };
        dvui.labelNoFmt(@src(), "row", .{}, .{ .id_extra = id, .min_size_content = .{ .w = 120, .h = 20 } });
        if (folder and branch.expander(@src(), .{}, .{ .expand = .horizontal })) {
            if (id == f) row(tree, c, false, false);
        }
    }
};

test "tree: an external reopen during closing owns the branch state" {
    const Scene = struct {
        // Written by this test and its frame callback on the test thread.
        var open = true;
        var expanded = false;
        var children = false;
        var requested: ?bool = null;
        var progress: f32 = 0;

        fn frame() !dvui.App.Result {
            const tree = fizzy.core.widgets.TreeWidget.tree(@src(), .{}, .{ .expand = .both });
            defer tree.deinit();
            const branch = tree.branch(@src(), .{ .expanded = open }, .{ .expand = .horizontal });
            defer branch.deinit();
            expanded = branch.expanded;
            dvui.labelNoFmt(@src(), "folder", .{}, .{});
            children = branch.expander(@src(), .{}, .{ .expand = .horizontal });
            requested = branch.requested;
            progress = branch.anim.?.val.?;
            if (children) dvui.labelNoFmt(@src(), "child", .{}, .{});
            return .ok;
        }
    };
    var t = try dvui.testing.init(.{ .allocator = std.testing.allocator });
    defer t.deinit();
    Scene.open = true;
    _ = try dvui.testing.step(Scene.frame);
    try std.testing.expectEqual(@as(f32, 1), Scene.progress);
    try dvui.testing.settle(Scene.frame);
    Scene.open = false;
    _ = try dvui.testing.step(Scene.frame);
    try std.testing.expect(!Scene.expanded);
    try std.testing.expect(Scene.children);
    try std.testing.expectEqual(@as(?bool, null), Scene.requested);
    Scene.open = true;
    _ = try dvui.testing.step(Scene.frame);
    try std.testing.expect(Scene.expanded);
    try dvui.testing.settle(Scene.frame);
    try std.testing.expect(Scene.expanded and Scene.children);
    try std.testing.expectEqual(@as(?bool, null), Scene.requested);
}

test "tree: a row carried back over it goes into the folder under the pointer when let go" {
    var t = try dvui.testing.init(.{ .allocator = std.testing.allocator });
    defer t.deinit();
    CarriedTree.reset();
    defer CarriedTree.reset();
    try dvui.testing.settle(CarriedTree.frame);

    // Over the shut folder: it would take the row, but nothing goes in until it is let go.
    const over_g = CarriedTree.headers[CarriedTree.g].center();
    CarriedTree.carried = .{ .primary = CarriedTree.a, .p = over_g };
    _ = try dvui.testing.step(CarriedTree.frame);
    try std.testing.expect(CarriedTree.landed == null);

    CarriedTree.carried = .{ .primary = CarriedTree.a, .p = over_g, .released = true };
    _ = try dvui.testing.step(CarriedTree.frame);
    const landed = CarriedTree.landed orelse return error.TestExpectedEqual;
    try std.testing.expectEqual(CarriedTree.g, landed.row);
    try std.testing.expect(landed.into);

    // Gone from the tree with the drag: the next frames are no drag of the tree's own, and so no
    // drop of one either.
    CarriedTree.carried = null;
    CarriedTree.landed = null;
    _ = try dvui.testing.step(CarriedTree.frame);
    _ = try dvui.testing.step(CarriedTree.frame);
    try std.testing.expect(!CarriedTree.dragging);
    try std.testing.expect(CarriedTree.landed == null);
}

test "tree: rows carried back over it and taken elsewhere move nothing" {
    var t = try dvui.testing.init(.{ .allocator = std.testing.allocator });
    defer t.deinit();
    CarriedTree.reset();
    defer CarriedTree.reset();
    try dvui.testing.settle(CarriedTree.frame);

    // Over the folder, then off the tree — let go somewhere else, or the drag cancelled: whoever
    // carries the row stops handing it to the tree, and the tree drops nothing.
    CarriedTree.carried = .{ .primary = CarriedTree.a, .p = CarriedTree.headers[CarriedTree.g].center() };
    _ = try dvui.testing.step(CarriedTree.frame);
    CarriedTree.carried = null;
    for (0..3) |_| _ = try dvui.testing.step(CarriedTree.frame);
    try std.testing.expect(CarriedTree.landed == null);
    try std.testing.expect(!CarriedTree.dragging);
}

test "tree: a carried selection, and the rows inside it, take no drop of it" {
    var t = try dvui.testing.init(.{ .allocator = std.testing.allocator });
    defer t.deinit();
    CarriedTree.reset();
    defer CarriedTree.reset();
    try dvui.testing.settle(CarriedTree.frame);

    // `a` carried out with `F` selected beside it: both are carried, as a drag of the selection
    // would carry them, so neither `F` nor `c` inside it takes them — a folder cannot go into itself.
    CarriedTree.selected = &.{ CarriedTree.f, CarriedTree.a };
    for ([_]usize{ CarriedTree.f, CarriedTree.c, CarriedTree.a }) |over| {
        CarriedTree.landed = null;
        CarriedTree.carried = .{ .primary = CarriedTree.a, .p = CarriedTree.headers[over].center(), .released = true };
        _ = try dvui.testing.step(CarriedTree.frame);
        try std.testing.expect(CarriedTree.landed == null);
    }

    // Over `b`, a file: they go in before it.
    CarriedTree.landed = null;
    CarriedTree.carried = .{ .primary = CarriedTree.a, .p = CarriedTree.headers[CarriedTree.b].center(), .released = true };
    _ = try dvui.testing.step(CarriedTree.frame);
    const landed = CarriedTree.landed orelse return error.TestExpectedEqual;
    try std.testing.expectEqual(CarriedTree.b, landed.row);
    try std.testing.expect(!landed.into);
}

test "tree: a drag put down is not dropped where the pointer last was" {
    var t = try dvui.testing.init(.{ .allocator = std.testing.allocator });
    defer t.deinit();
    CarriedTree.reset();
    defer CarriedTree.reset();
    try dvui.testing.settle(CarriedTree.frame);
    const cw = dvui.currentWindow();

    // `a` dragged up over the shut folder `G`, by the tree's own drag.
    const from = CarriedTree.headers[CarriedTree.a].center();
    const to = CarriedTree.headers[CarriedTree.g].center();
    _ = try cw.addEventMouseMotion(.{ .pt = from });
    _ = try cw.addEventMouseButton(.left, .press);
    _ = try dvui.testing.step(CarriedTree.frame);
    var y = from.y;
    while (y > to.y) : (y -= 4) {
        _ = try cw.addEventMouseMotion(.{ .pt = .{ .x = from.x, .y = y } });
        _ = try dvui.testing.step(CarriedTree.frame);
    }
    _ = try cw.addEventMouseMotion(.{ .pt = to });
    _ = try dvui.testing.step(CarriedTree.frame);
    _ = try dvui.testing.step(CarriedTree.frame);
    try std.testing.expect(CarriedTree.dragging);

    // Taken out of the tree as another drag: put down, it lands nowhere — not on `G`, which the
    // pointer is still over, as the end of a drag would.
    CarriedTree.cancel = true;
    _ = try dvui.testing.step(CarriedTree.frame);
    _ = try dvui.testing.step(CarriedTree.frame);
    try std.testing.expect(!CarriedTree.dragging);
    try std.testing.expect(CarriedTree.landed == null);
    _ = try cw.addEventMouseButton(.left, .release);
    try dvui.testing.settle(CarriedTree.frame);
    try std.testing.expect(CarriedTree.landed == null);
}

// A key fold sticks. The caller below keeps its own open state and passes it back each frame, as
// the settings, file and guides trees do, applying `branch.requested` after `expander()`: Left must
// fold the branch (animated, as a click does) and leave it folded, and Right open it again.
const KeyFoldTree = struct {
    const TW = fizzy.core.widgets.TreeWidget;

    var focus = false;
    var open = true;
    var body_drawn = false;

    fn frame() anyerror!dvui.App.Result {
        var tree = TW.tree(@src(), .{}, .{ .expand = .both });
        defer tree.deinit();
        const branch = tree.branch(@src(), .{ .expanded = open }, .{ .expand = .horizontal });
        defer branch.deinit();
        if (focus) {
            focus = false;
            dvui.focusWidget(branch.button.data().id, null, null);
        }
        dvui.labelNoFmt(@src(), "row", .{}, .{ .min_size_content = .{ .w = 120, .h = 20 } });
        body_drawn = false;
        if (branch.expander(@src(), .{}, .{ .expand = .horizontal })) {
            body_drawn = true;
            dvui.labelNoFmt(@src(), "child", .{}, .{ .min_size_content = .{ .w = 120, .h = 20 } });
        }
        if (branch.requested) |r| open = r;
        return .ok;
    }
};

test "tree: a key fold stays folded when the caller passes its open state back" {
    var t = try dvui.testing.init(.{ .allocator = std.testing.allocator });
    defer t.deinit();
    KeyFoldTree.focus = true;
    KeyFoldTree.open = true;
    try dvui.testing.settle(KeyFoldTree.frame);
    try std.testing.expect(KeyFoldTree.open and KeyFoldTree.body_drawn);

    try dvui.testing.pressKey(.left, .none);
    // The fold animates: the body is still drawn the frame after the key, closing.
    _ = try dvui.testing.step(KeyFoldTree.frame);
    try std.testing.expect(KeyFoldTree.body_drawn);
    try dvui.testing.settle(KeyFoldTree.frame);
    try std.testing.expect(!KeyFoldTree.open and !KeyFoldTree.body_drawn);
    _ = try dvui.testing.step(KeyFoldTree.frame);
    try std.testing.expect(!KeyFoldTree.open);

    try dvui.testing.pressKey(.right, .none);
    try dvui.testing.settle(KeyFoldTree.frame);
    try std.testing.expect(KeyFoldTree.open and KeyFoldTree.body_drawn);
    _ = try dvui.testing.step(KeyFoldTree.frame);
    try std.testing.expect(KeyFoldTree.open);
}

const OutsideOpenTree = struct {
    const TW = fizzy.core.widgets.TreeWidget;

    var open = true;
    var shown = false;
    var body_drawn = false;

    // lint-allow(anyerror): the signature of dvui.App.frameFunction
    fn frame() anyerror!dvui.App.Result {
        var tree = TW.tree(@src(), .{}, .{ .expand = .both });
        defer tree.deinit();
        const branch = tree.branch(@src(), .{ .expanded = open, .animation_duration = 400_000 }, .{ .expand = .horizontal });
        defer branch.deinit();
        dvui.labelNoFmt(@src(), "row", .{}, .{ .min_size_content = .{ .w = 120, .h = 20 } });
        body_drawn = false;
        if (branch.expander(@src(), .{}, .{ .expand = .horizontal })) {
            body_drawn = true;
            dvui.labelNoFmt(@src(), "child", .{}, .{ .min_size_content = .{ .w = 120, .h = 20 } });
        }
        shown = branch.expanded;
        if (branch.requested) |r| open = r;
        return .ok;
    }
};

test "tree: the caller's open state set mid-close wins over the running animation" {
    var t = try dvui.testing.init(.{ .allocator = std.testing.allocator });
    defer t.deinit();
    OutsideOpenTree.open = true;
    try dvui.testing.settle(OutsideOpenTree.frame);
    try std.testing.expect(OutsideOpenTree.shown and OutsideOpenTree.body_drawn);

    // Start the close, then restore the open state from outside while it is still running.
    OutsideOpenTree.open = false;
    _ = try dvui.testing.step(OutsideOpenTree.frame);
    try std.testing.expect(OutsideOpenTree.body_drawn);
    OutsideOpenTree.open = true;
    try dvui.testing.settle(OutsideOpenTree.frame);
    try std.testing.expect(OutsideOpenTree.open and OutsideOpenTree.shown and OutsideOpenTree.body_drawn);

    // And the other way: an open branch closed from outside ends closed.
    OutsideOpenTree.open = false;
    try dvui.testing.settle(OutsideOpenTree.frame);
    try std.testing.expect(!OutsideOpenTree.open and !OutsideOpenTree.shown and !OutsideOpenTree.body_drawn);
}

test "a frost never captures more than the picture it reads" {
    const within = fizzy.core.widgets.BlurBackdrop.within;
    const Rect = dvui.Rect.Physical;
    const win: Rect = .{ .w = 2400, .h = 1600 };
    // Partly off the window, and smaller than it: kept whole, and so its capture size.
    const edge: Rect = .{ .x = 2300, .y = 10, .w = 400, .h = 300 };
    try std.testing.expectEqual(edge, within(edge, win).?);
    // A view drag's drop zones across the main window and a float's band 100000 pixels on: the
    // window's width (it asked Metal for a texture 46424 pixels wide), its own height.
    const across = within(.{ .x = 1800, .y = 200, .w = 100600, .h = 900 }, win).?;
    try std.testing.expectEqual(@as(f32, 0), across.x);
    try std.testing.expectEqual(@as(f32, 2400), across.w);
    try std.testing.expectEqual(@as(f32, 200), across.y);
    try std.testing.expectEqual(@as(f32, 900), across.h);
    // Taller than the window — a window-tall float, its capture bucketed past the frame — moving up
    // and down: one size all the way, the window's height. Cut to what of it was on the window, it
    // was a new height and a new pyramid every frame (Safari: half the frame rate).
    var y: f32 = -300;
    while (y < 600) : (y += 37) {
        const tall = within(.{ .x = 100, .y = y, .w = 862, .h = 1900 }, win).?;
        try std.testing.expectEqual(Rect{ .x = 100, .y = 0, .w = 862, .h = 1600 }, tall);
    }
    // Wholly in the band: nothing of the window.
    try std.testing.expectEqual(@as(?Rect, null), within(.{ .x = 100000, .y = 0, .w = 3000, .h = 100 }, win));
    // Smaller than the picture but nowhere on it — the main window's drop zones replayed into a
    // float window's target in its band: nothing, rather than pixels from past its edge.
    const band: Rect = .{ .x = 100000, .y = 400, .w = 712, .h = 878 };
    try std.testing.expectEqual(@as(?Rect, null), within(.{ .x = 900, .y = 300, .w = 500, .h = 700 }, band));
}

// -- commands with arguments ---------------------------------------------------------------------

// The palette asks for a command's required parameters in turn — free text checked against the
// parameter, a list for an enum — and runs the command with what was given. This is the path a
// menu row or a keybind reaches through `EditorAPI.askCommandArguments` too.
const PaletteArgs = struct {
    const Side = enum { left, right };
    const Params = sdk.Command.Params(struct {
        line: sdk.Command.Arg(u32, .{ .description = "The line.", .min = 1 }),
        side: sdk.Command.Arg(Side, .{ .description = "Which side." }),
        column: sdk.Command.Arg(u32, .{ .description = "The column." }) = .init(1),
    });
    var got: ?Params.Args = null;
    var editor: *fizzy.Editor = undefined;

    fn run(_: *anyopaque, args: Params.Args, _: *sdk.Command.Call) anyerror!void {
        got = args;
    }
    fn frame() !dvui.App.Result {
        editor.command_palette.draw(editor);
        return .ok;
    }
};

test "the palette asks for a command's required arguments, then runs it with them" {
    var ctx = try shim.init(std.testing.allocator);
    defer ctx.deinit(std.testing.allocator);
    const editor = ctx.editor;
    PaletteArgs.editor = editor;
    PaletteArgs.got = null;

    const vtable = sdk.Plugin.VTable{};
    var state: u8 = 0;
    var plugin = sdk.Plugin{ .state = &state, .vtable = &vtable, .id = "t", .display_name = "T" };
    try editor.app.host.registerCommand(.{
        .id = "t.place",
        .owner = &plugin,
        .title = "Place",
        .params = PaletteArgs.Params.params,
        .runWith = PaletteArgs.Params.bind(PaletteArgs.run),
    });

    try std.testing.expect(editor.command_palette.ask(editor, "t.place"));
    try dvui.testing.settle(PaletteArgs.frame);

    // An answer that does not fit the parameter is refused where it was typed.
    try dvui.testing.writeText("0");
    try dvui.testing.settle(PaletteArgs.frame);
    try dvui.testing.pressKey(.enter, .none);
    try dvui.testing.settle(PaletteArgs.frame);
    try std.testing.expectEqual(@as(usize, 0), editor.command_palette.asking.?.param);
    try std.testing.expect(editor.command_palette.asking.?.problem_len > 0);
    try std.testing.expect(PaletteArgs.got == null);

    // A good one moves on to the next required parameter; the optional one is never asked.
    try dvui.testing.pressKey(.backspace, .none);
    try dvui.testing.writeText("12");
    try dvui.testing.settle(PaletteArgs.frame);
    try dvui.testing.pressKey(.enter, .none);
    try dvui.testing.settle(PaletteArgs.frame);
    try std.testing.expectEqual(@as(usize, 1), editor.command_palette.asking.?.param);

    // An enum is a list, filtered by what is typed; Enter takes the row.
    try dvui.testing.writeText("ri");
    try dvui.testing.settle(PaletteArgs.frame);
    try dvui.testing.pressKey(.enter, .none);
    try dvui.testing.settle(PaletteArgs.frame);

    const got = PaletteArgs.got orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(@as(u32, 12), got.line);
    try std.testing.expectEqual(PaletteArgs.Side.right, got.side);
    try std.testing.expectEqual(@as(u32, 1), got.column);
    try std.testing.expect(editor.command_palette.closing or !editor.command_palette.open);
}

fn keybindArgsFrame() !dvui.App.Result {
    try fizzy.Editor.Keybinds.tick();
    return .ok;
}

test "a key bound with arguments runs its command with them, and is not its shortcut" {
    var ctx = try shim.init(std.testing.allocator);
    defer ctx.deinit(std.testing.allocator);
    const editor = ctx.editor;
    const gpa = editor.app.host.allocator;
    defer editor.app.keymap.deinit(gpa);
    PaletteArgs.got = null;
    // `tick` reads which context the keys land in; the shim's editor has no explorer of its own.
    var explorer: fizzy.Editor.Explorer = undefined;
    @memset(std.mem.asBytes(&explorer), 0);
    explorer.closed = true;
    editor.explorer = &explorer;

    const vtable = sdk.Plugin.VTable{};
    var state: u8 = 0;
    var plugin = sdk.Plugin{ .state = &state, .vtable = &vtable, .id = "t", .display_name = "T" };
    try editor.app.host.registerCommand(.{
        .id = "t.place",
        .owner = &plugin,
        .title = "Place",
        .params = PaletteArgs.Params.params,
        .runWith = PaletteArgs.Params.bind(PaletteArgs.run),
    });

    // As `keybinds.zon` would give them: the command's shortcut, and a key that runs it with
    // arguments.
    const parseKeys = @import("app").keymap.Keymap.parseKeys;
    try editor.app.keymap.add(gpa, .{ .stroke = try parseKeys("ctrl+g", .other), .command = "t.place", .source = .user });
    try editor.app.keymap.add(gpa, .{
        .stroke = try parseKeys("ctrl+1", .other),
        .command = "t.place",
        .args = ".{ .line = 3, .side = .left }",
        .source = .user,
    });

    try dvui.testing.pressKey(.one, .lcontrol);
    try dvui.testing.settle(keybindArgsFrame);
    const got = PaletteArgs.got orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(@as(u32, 3), got.line);
    try std.testing.expectEqual(PaletteArgs.Side.left, got.side);
    try std.testing.expectEqual(@as(u32, 1), got.column);

    // The menu row shows the shortcut, never the key that carries arguments.
    const kb = fizzy.Editor.Keybinds.menuKeybindFor(editor, "t.place");
    try std.testing.expectEqual(dvui.enums.Key.g, kb.key.?);
}

test "demo: a command op hands its arguments to the stage" {
    var t = try demoCtx();
    defer deinitDemo(&t);
    defer {
        demo_command_args.deinit(std.testing.allocator);
        demo_command_args = .empty;
    }

    var s: automation.Script = .init(std.testing.allocator, "args", "Args");
    errdefer s.deinit();
    try s.keyframe(.{ .root = "demo://args" });
    try s.commandWith("demo.ping", .{ .times = 2 });
    demo_player.load(try s.finish(), .{});
    try stepDemoUntil(.ended, 200);

    try std.testing.expectEqual(@as(usize, 1), demo_commands);
    try std.testing.expectEqualStrings(".{ .times = 2 }", demo_command_args.items);
}

test "demo: fizzy's stage runs a command op's arguments through callCommand" {
    var ctx = try shim.init(std.testing.allocator);
    defer ctx.deinit(std.testing.allocator);
    const editor = ctx.editor;
    editor.app.gpa = std.testing.allocator;
    PaletteArgs.got = null;

    const vtable = sdk.Plugin.VTable{};
    var state: u8 = 0;
    var plugin = sdk.Plugin{ .state = &state, .vtable = &vtable, .id = "t", .display_name = "T" };
    try editor.app.host.registerCommand(.{
        .id = "t.place",
        .owner = &plugin,
        .title = "Place",
        .params = PaletteArgs.Params.params,
        .runWith = PaletteArgs.Params.bind(PaletteArgs.run),
    });

    var demo: fizzy.Editor.Demo = .detached;
    demo.attach(editor);
    defer demo.deinit();
    demo.player.stage.command("t.place", ".{ .line = 4, .side = .right }");

    const got = PaletteArgs.got orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(@as(u32, 4), got.line);
    try std.testing.expectEqual(PaletteArgs.Side.right, got.side);
}

// The control server's routes over a Host: the commands as the API, JSON in and out, errors as
// HTTP's (plans/CONTROL_SERVER_PLAN.md). The socket half is `app/control/Server.zig`'s own test.
const ControlFixture = struct {
    fn place(_: *anyopaque, args: PaletteArgs.Params.Args, call: *sdk.Command.Call) anyerror!void {
        if (args.line > 100) return call.fail("line {d} is past the end", .{args.line});
        try call.returns(.{ .line = args.line, .side = args.side, .column = args.column, .note = "placed" });
    }
    fn never(_: *anyopaque) bool {
        return false;
    }
    fn nothing(_: *anyopaque) anyerror!void {}
};

test "control: commands are listed, described and run over the routes" {
    const gpa = std.testing.allocator;
    const routes = @import("app").control.routes;
    var host: sdk.Host = .init(gpa);
    defer host.deinit();
    const vtable = sdk.Plugin.VTable{};
    var state: u8 = 0;
    var plugin = sdk.Plugin{ .state = &state, .vtable = &vtable, .id = "t", .display_name = "T" };
    try host.registerCommand(.{
        .id = "t.place",
        .owner = &plugin,
        .title = "Place",
        .params = PaletteArgs.Params.params,
        .runWith = PaletteArgs.Params.bind(ControlFixture.place),
    });
    try host.registerCommand(.{ .id = "t.off", .owner = &plugin, .title = "Off", .run = ControlFixture.nothing, .isEnabled = ControlFixture.never });

    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // Who is answering.
    const root = routes.handle(&host, .GET, "/", null, "", arena);
    try std.testing.expectEqual(std.http.Status.ok, root.status);
    try std.testing.expect(std.mem.find(u8, root.body, "\"sdk_version\":") != null);

    // The listing: each command with its params, an enum's choices and a default.
    const list = routes.handle(&host, .GET, "/commands", null, "", arena);
    try std.testing.expectEqual(std.http.Status.ok, list.status);
    const parsed = try std.json.parseFromSliceLeaky(std.json.Value, arena, list.body, .{});
    try std.testing.expectEqual(@as(usize, 2), parsed.array.items.len);
    const place = parsed.array.items[0].object;
    try std.testing.expectEqualStrings("t.place", place.get("id").?.string);
    try std.testing.expectEqualStrings("t", place.get("owner").?.string);
    try std.testing.expect(place.get("enabled").?.bool);
    const params = place.get("params").?.array.items;
    try std.testing.expectEqualStrings("line", params[0].object.get("key").?.string);
    try std.testing.expect(params[0].object.get("required").?.bool);
    try std.testing.expectEqualStrings("enum", params[1].object.get("kind").?.string);
    try std.testing.expectEqualStrings("right", params[1].object.get("choices").?.array.items[1].string);
    try std.testing.expectEqual(@as(i64, 1), params[2].object.get("default").?.integer);
    try std.testing.expect(!parsed.array.items[1].object.get("enabled").?.bool);

    // Run it: JSON in (an enum as its name), the result back as JSON.
    const ran = routes.handle(&host, .POST, "/commands/t.place", "application/json", "{\"line\":4,\"side\":\"right\"}", arena);
    try std.testing.expectEqual(std.http.Status.ok, ran.status);
    try std.testing.expectEqualStrings("{\"line\":4,\"side\":\"right\",\"column\":1,\"note\":\"placed\"}", ran.body);

    // ZON in, ZON out.
    const zon = routes.handle(&host, .POST, "/commands/t.place", "application/zon", ".{ .line = 5, .side = .left }", arena);
    try std.testing.expectEqual(std.http.Status.ok, zon.status);
    try std.testing.expectEqualStrings("application/zon", zon.content_type);
    try std.testing.expect(std.mem.find(u8, zon.body, ".side = .left") != null or std.mem.find(u8, zon.body, ".side=.left") != null);

    // Errors as HTTP's.
    try std.testing.expectEqual(std.http.Status.not_found, routes.handle(&host, .POST, "/commands/t.missing", null, "", arena).status);
    try std.testing.expectEqual(std.http.Status.not_found, routes.handle(&host, .GET, "/nowhere", null, "", arena).status);
    try std.testing.expectEqual(std.http.Status.bad_request, routes.handle(&host, .POST, "/commands/t.place", null, "{\"side\":\"right\"}", arena).status);
    try std.testing.expectEqual(std.http.Status.bad_request, routes.handle(&host, .POST, "/commands/t.place", null, "not json", arena).status);
    try std.testing.expectEqual(std.http.Status.conflict, routes.handle(&host, .POST, "/commands/t.off", null, "", arena).status);
    try std.testing.expectEqual(std.http.Status.method_not_allowed, routes.handle(&host, .DELETE, "/commands/t.place", null, "", arena).status);
    const failed = routes.handle(&host, .POST, "/commands/t.place", null, "{\"line\":200,\"side\":\"left\"}", arena);
    try std.testing.expectEqual(std.http.Status.internal_server_error, failed.status);
    try std.testing.expectEqualStrings("{\"error\":\"line 200 is past the end\"}", failed.body);
}

const OpenApiFixture = struct {
    fn byHand(_: *anyopaque, _: *sdk.Command.Call) anyerror!void {}
};

test "control: /openapi.json describes each command's body and the declared events" {
    const gpa = std.testing.allocator;
    const routes = @import("app").control.routes;
    var host: sdk.Host = .init(gpa);
    defer host.deinit();
    const vtable = sdk.Plugin.VTable{};
    var state: u8 = 0;
    var plugin = sdk.Plugin{ .state = &state, .vtable = &vtable, .id = "t", .display_name = "T" };
    try host.registerCommand(.{
        .id = "t.place",
        .owner = &plugin,
        .title = "Place",
        .params = PaletteArgs.Params.params,
        .runWith = PaletteArgs.Params.bind(ControlFixture.place),
    });
    try host.registerCommand(.{ .id = "t.off", .owner = &plugin, .title = "Off", .run = ControlFixture.nothing });
    // A `runWith` written by hand, declaring no parameters (as the chat plugin's are).
    try host.registerCommand(.{ .id = "t.by hand{x}", .owner = &plugin, .title = "By hand", .runWith = OpenApiFixture.byHand });
    // Another plugin's command by the same id: held in reserve, the first kept and described once.
    var other = sdk.Plugin{ .state = &state, .vtable = &vtable, .id = "u", .display_name = "U" };
    try host.registerCommand(.{ .id = "t.off", .owner = &other, .title = "Off again", .run = ControlFixture.nothing });
    try host.declareEvent(.{ .name = "t.placed", .owner = &plugin, .description = "Something was placed.", .payload = ".{ .line = 4, .side = .left }" });

    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const answer = routes.handle(&host, .GET, "/openapi.json", null, "", arena);
    try std.testing.expectEqual(std.http.Status.ok, answer.status);
    // Parsed as std parses: a repeated key is an error, so a duplicate path would fail here.
    const spec = (try std.json.parseFromSliceLeaky(std.json.Value, arena, answer.body, .{})).object;
    try std.testing.expectEqualStrings("3.1.0", spec.get("openapi").?.string);
    const paths = spec.get("paths").?.object;
    for ([_][]const u8{ "/", "/commands", "/events", "/openapi.json", "/commands/t.place", "/commands/t.off", "/commands/t.by%20hand%7Bx%7D" }) |p| {
        if (paths.get(p) == null) {
            std.debug.print("\nmissing path {s}\n", .{p});
            return error.TestUnexpectedResult;
        }
    }
    try std.testing.expectEqualStrings("Off", paths.get("/commands/t.off").?.object.get("post").?.object.get("summary").?.string);

    // The body: each parameter's type, the required ones listed, nothing else accepted.
    const place = paths.get("/commands/t.place").?.object.get("post").?.object;
    try std.testing.expectEqualStrings("t.place", place.get("operationId").?.string);
    const body = place.get("requestBody").?.object;
    try std.testing.expect(body.get("required").?.bool);
    const schema = body.get("content").?.object.get("application/json").?.object.get("schema").?.object;
    try std.testing.expect(!schema.get("additionalProperties").?.bool);
    const props = schema.get("properties").?.object;
    const line = props.get("line").?.object;
    try std.testing.expectEqualStrings("integer", line.get("type").?.string);
    // Bounds the server does not check stay out of the schema, said in words instead.
    try std.testing.expect(line.get("minimum") == null and line.get("maximum") == null);
    try std.testing.expect(std.mem.find(u8, line.get("description").?.string, "from 1 to") != null);
    try std.testing.expectEqualStrings("right", props.get("side").?.object.get("enum").?.array.items[1].string);
    try std.testing.expectEqual(@as(i64, 1), props.get("column").?.object.get("default").?.integer);
    const required = schema.get("required").?.array.items;
    try std.testing.expectEqual(@as(usize, 2), required.len);
    try std.testing.expectEqualStrings("line", required[0].string);
    const responses = place.get("responses").?.object;
    for ([_][]const u8{ "200", "400", "404", "409", "500" }) |code| try std.testing.expect(responses.get(code) != null);
    // Any JSON value: the schema `true`, never `[]`, which is not a schema at all.
    try std.testing.expect(responses.get("200").?.object.get("content").?.object.get("application/json").?.object.get("schema").?.bool);

    // A command with only `run` takes no body; one with a hand-written `runWith` takes any object.
    try std.testing.expect(paths.get("/commands/t.off").?.object.get("post").?.object.get("requestBody") == null);
    const by_hand = paths.get("/commands/t.by%20hand%7Bx%7D").?.object.get("post").?.object.get("requestBody").?.object;
    const open_schema = by_hand.get("content").?.object.get("application/json").?.object.get("schema").?.object;
    try std.testing.expect(open_schema.get("additionalProperties") == null and open_schema.get("properties") == null);

    // The declared event, its example payload as JSON.
    const events = paths.get("/events").?.object.get("get").?.object.get("x-fizzy-events").?.array.items;
    try std.testing.expectEqual(@as(usize, 1), events.len);
    try std.testing.expectEqualStrings("t.placed", events[0].object.get("name").?.string);
    try std.testing.expectEqualStrings("left", events[0].object.get("example").?.object.get("side").?.string);

    // Every operationId once; every `$ref` names a schema the description has.
    var ids: std.StringHashMapUnmanaged(void) = .empty;
    var it = paths.iterator();
    while (it.next()) |path| {
        var ops = path.value_ptr.object.iterator();
        while (ops.next()) |op| {
            const id = op.value_ptr.object.get("operationId").?.string;
            try std.testing.expect(!ids.contains(id));
            try ids.put(arena, id, {});
        }
    }
    const schemas = spec.get("components").?.object.get("schemas").?.object;
    var at: usize = 0;
    while (std.mem.findPos(u8, answer.body, at, "#/components/schemas/")) |i| {
        const name_start = i + "#/components/schemas/".len;
        const name_end = std.mem.findScalarPos(u8, answer.body, name_start, '"').?;
        try std.testing.expect(schemas.get(answer.body[name_start..name_end]) != null);
        at = name_end;
    }
    // A HEAD is answered without generating it.
    try std.testing.expectEqualStrings("", routes.handle(&host, .HEAD, "/openapi.json", null, "", arena).body);
}

/// Sends one request and reads the answer by its `Content-Length`, as an HTTP client does.
const ControlOneShot = struct {
    path: []const u8,
    request: []const u8,
    reply: [2048]u8 = undefined,
    len: usize = 0,
    fn run(self: *ControlOneShot) void {
        const io = std.testing.io;
        const addr = std.Io.net.UnixAddress.init(self.path) catch return;
        const stream = addr.connect(io) catch return;
        defer stream.close(io);
        var wbuf: [256]u8 = undefined;
        var w = stream.writer(io, &wbuf);
        w.interface.writeAll(self.request) catch return;
        w.interface.flush() catch return;
        var rbuf: [256]u8 = undefined;
        var r = stream.reader(io, &rbuf);
        while (self.len < self.reply.len) {
            const n = r.interface.readSliceShort(self.reply[self.len..][0..1]) catch return;
            if (n == 0) return;
            self.len += 1;
            if (std.mem.endsWith(u8, self.reply[0..self.len], "\r\n\r\n")) break;
        }
        const key = "content-length: ";
        const i = std.ascii.findIgnoreCase(self.reply[0..self.len], key) orelse return;
        const end = std.mem.findPos(u8, self.reply[0..self.len], i, "\r\n") orelse return;
        const want = std.fmt.parseInt(usize, self.reply[i + key.len .. end], 10) catch return;
        r.interface.readSliceAll(self.reply[self.len..][0..want]) catch return;
        self.len += want;
    }
};

const SlowCommand = struct {
    ticket: u32 = 0,
    fn start(state: *anyopaque, call: *sdk.Command.Call) anyerror!void {
        const self: *SlowCommand = @ptrCast(@alignCast(state));
        self.ticket = call.later();
    }
};

test "control: a command that answers in a later frame holds its request open until it does" {
    if (!std.Io.net.has_unix_sockets) return error.SkipZigTest;
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    const control = @import("app").control;
    var host: sdk.Host = .init(gpa);
    defer host.deinit();
    const vtable = sdk.Plugin.VTable{};
    var slow: SlowCommand = .{};
    var plugin = sdk.Plugin{ .state = &slow, .vtable = &vtable, .id = "t", .display_name = "T" };
    try host.registerCommand(.{ .id = "t.slow", .owner = &plugin, .title = "Slow", .runWith = SlowCommand.start });
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir = try tmp.dir.realPathFileAlloc(io, ".", gpa);
    defer gpa.free(dir);
    const path = try std.fs.path.join(gpa, &.{ dir, "c.sock" });
    defer gpa.free(path);
    const Wake = struct {
        fn none() void {}
    };
    var server: control.Server = .{ .gpa = gpa, .io = io, .socket_path = path, .wake = Wake.none };
    try server.start();
    var state: control.routes.State = .{};
    errdefer control.routes.stop(&server, &state, &host);

    const post = "POST /commands/t.slow HTTP/1.1\r\nHost: x\r\nContent-Length: 0\r\nConnection: close\r\n\r\n";
    var client: ControlOneShot = .{ .path = path, .request = post };
    const thread = try std.Thread.spawn(.{}, ControlOneShot.run, .{&client});
    // Frames, until the command has started and its request waits on it.
    var frames: usize = 0;
    while (state.waiters.items.len == 0 and frames < 2000) : (frames += 1) {
        control.routes.answerPending(&server, &state, &host);
        io.sleep(.fromMilliseconds(1), .awake) catch {};
    }
    try std.testing.expectEqual(@as(usize, 1), state.waiters.items.len);
    // More frames: still nothing to answer.
    for (0..5) |_| control.routes.answerPending(&server, &state, &host);
    try std.testing.expectEqual(@as(usize, 0), client.len);
    // Done, in a later frame: the request is answered with what it returned.
    host.finishCall(slow.ticket, .{ .ok = ".{ .done = true }" });
    thread.join();
    try std.testing.expectEqual(@as(usize, 0), state.waiters.items.len);
    const reply = client.reply[0..client.len];
    try std.testing.expect(std.mem.startsWith(u8, reply, "HTTP/1.1 200 OK\r\n"));
    try std.testing.expect(std.mem.endsWith(u8, reply, "\r\n\r\n{\"done\":true}"));

    // One still waiting when the server stops: answered as stopping, its call let go of.
    var late: ControlOneShot = .{ .path = path, .request = post };
    const late_thread = try std.Thread.spawn(.{}, ControlOneShot.run, .{&late});
    frames = 0;
    while (state.waiters.items.len == 0 and frames < 2000) : (frames += 1) {
        control.routes.answerPending(&server, &state, &host);
        io.sleep(.fromMilliseconds(1), .awake) catch {};
    }
    try std.testing.expectEqual(@as(usize, 1), state.waiters.items.len);
    const ticket = slow.ticket;
    control.routes.stop(&server, &state, &host);
    late_thread.join();
    try std.testing.expect(std.mem.startsWith(u8, late.reply[0..late.len], "HTTP/1.1 503 "));
    try std.testing.expect(!host.callWanted(ticket));
    // Its answer, when it comes, goes nowhere.
    host.finishCall(ticket, .{ .ok = null });
}

test "control: MCP on the socket lists the commands as tools and calls them, now or later" {
    if (!std.Io.net.has_unix_sockets) return error.SkipZigTest;
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    const control = @import("app").control;
    var host: sdk.Host = .init(gpa);
    defer host.deinit();
    const vtable = sdk.Plugin.VTable{};
    var slow: SlowCommand = .{};
    var plugin = sdk.Plugin{ .state = &slow, .vtable = &vtable, .id = "t", .display_name = "T" };
    try host.registerCommand(.{ .id = "t.slow", .owner = &plugin, .title = "Slow", .runWith = SlowCommand.start });
    try host.registerCommand(.{
        .id = "t.place",
        .owner = &plugin,
        .title = "Place",
        .params = PaletteArgs.Params.params,
        .runWith = PaletteArgs.Params.bind(ControlFixture.place),
    });

    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const routes = control.routes;
    // Without a socket (`handle`): the replies a client reads.
    const init = routes.handle(&host, .POST, "/mcp", null, "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{\"protocolVersion\":\"2025-03-26\"}}", arena);
    try std.testing.expect(std.mem.find(u8, init.body, "\"protocolVersion\":\"2025-03-26\"") != null);
    try std.testing.expectEqual(std.http.Status.accepted, routes.handle(&host, .POST, "/mcp", null, "{\"jsonrpc\":\"2.0\",\"method\":\"notifications/initialized\"}", arena).status);
    const list = try std.json.parseFromSliceLeaky(std.json.Value, arena, routes.handle(&host, .POST, "/mcp", null, "{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"tools/list\"}", arena).body, .{});
    const tools = list.object.get("result").?.object.get("tools").?.array.items;
    try std.testing.expectEqual(@as(usize, 2), tools.len);
    const place = tools[1].object;
    // Named as every client accepts, with the command's id in its description.
    try std.testing.expectEqualStrings("t__place", place.get("name").?.string);
    try std.testing.expect(std.mem.find(u8, place.get("description").?.string, "t.place") != null);
    try std.testing.expectEqualStrings("integer", place.get("inputSchema").?.object.get("properties").?.object.get("line").?.object.get("type").?.string);
    const called = routes.handle(&host, .POST, "/mcp", null, "{\"jsonrpc\":\"2.0\",\"id\":3,\"method\":\"tools/call\",\"params\":{\"name\":\"t__place\",\"arguments\":{\"line\":4,\"side\":\"right\"}}}", arena);
    try std.testing.expect(std.mem.find(u8, called.body, "\"isError\":false") != null);
    try std.testing.expect(std.mem.find(u8, called.body, "\\\"note\\\":\\\"placed\\\"") != null);
    const refused = routes.handle(&host, .POST, "/mcp", null, "{\"jsonrpc\":\"2.0\",\"id\":4,\"method\":\"tools/call\",\"params\":{\"name\":\"t__place\",\"arguments\":{\"side\":\"right\"}}}", arena);
    try std.testing.expect(std.mem.find(u8, refused.body, "\"isError\":true") != null);
    // A client written before the names were spelled still reaches it by its id.
    const by_id = routes.handle(&host, .POST, "/mcp", null, "{\"jsonrpc\":\"2.0\",\"id\":6,\"method\":\"tools/call\",\"params\":{\"name\":\"t.place\",\"arguments\":{\"line\":4,\"side\":\"right\"}}}", arena);
    try std.testing.expect(std.mem.find(u8, by_id.body, "\"isError\":false") != null);
    // An id that shares t.place's name, but does not spell back as it does, gets a suffix; a call
    // by that name runs it (it answers later), not t.place (which answers now).
    try host.registerCommand(.{ .id = "t__place", .owner = &plugin, .title = "Twin", .runWith = SlowCommand.start });
    const named = try std.json.parseFromSliceLeaky(std.json.Value, arena, routes.handle(&host, .POST, "/mcp", null, "{\"jsonrpc\":\"2.0\",\"id\":8,\"method\":\"tools/list\"}", arena).body, .{});
    const three = named.object.get("result").?.object.get("tools").?.array.items;
    try std.testing.expectEqual(@as(usize, 3), three.len);
    try std.testing.expectEqualStrings("t__place", three[1].object.get("name").?.string);
    const twin = three[2].object.get("name").?.string;
    try std.testing.expect(std.mem.startsWith(u8, twin, "t__place_") and twin.len == "t__place_".len + 6);
    const twin_call = try arena.print("{{\"jsonrpc\":\"2.0\",\"id\":9,\"method\":\"tools/call\",\"params\":{{\"name\":\"{s}\"}}}}", .{twin});
    try std.testing.expect(std.mem.find(u8, routes.handle(&host, .POST, "/mcp", null, twin_call, arena).body, "answer comes later") != null);

    try std.testing.expect(std.mem.find(u8, routes.handle(&host, .POST, "/mcp", null, "{\"jsonrpc\":\"2.0\",\"id\":5,\"method\":\"nope\"}", arena).body, "-32601") != null);
    // A response from the client, as a notification is, is taken (202), not refused.
    try std.testing.expectEqual(std.http.Status.accepted, routes.handle(&host, .POST, "/mcp", null, "{\"jsonrpc\":\"2.0\",\"id\":7,\"result\":{}}", arena).status);
    // An id comes back as it was sent; one that is neither a string nor a number is refused.
    try std.testing.expect(std.mem.find(u8, routes.handle(&host, .POST, "/mcp", null, "{\"jsonrpc\":\"2.0\",\"id\":12345678901234567890,\"method\":\"ping\"}", arena).body, "\"id\":12345678901234567890,") != null);
    try std.testing.expect(std.mem.find(u8, routes.handle(&host, .POST, "/mcp", null, "{\"jsonrpc\":\"2.0\",\"id\":true,\"method\":\"ping\"}", arena).body, "-32600") != null);
    // Told only of commands the app has: no fizzy.screen here.
    try std.testing.expect(std.mem.find(u8, init.body, "fizzy.screen") == null);

    // Over the socket, a tool whose command answers later answers its call then.
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir = try tmp.dir.realPathFileAlloc(io, ".", gpa);
    defer gpa.free(dir);
    const path = try std.fs.path.join(gpa, &.{ dir, "c.sock" });
    defer gpa.free(path);
    const Wake = struct {
        fn none() void {}
    };
    var server: control.Server = .{ .gpa = gpa, .io = io, .socket_path = path, .wake = Wake.none };
    try server.start();
    var state: control.routes.State = .{};
    defer control.routes.stop(&server, &state, &host);
    const body = "{\"jsonrpc\":\"2.0\",\"id\":\"later\",\"method\":\"tools/call\",\"params\":{\"name\":\"t__slow\"}}";
    const request = try arena.print("POST /mcp HTTP/1.1\r\nHost: x\r\nContent-Type: application/json\r\nContent-Length: {d}\r\nConnection: close\r\n\r\n{s}", .{ body.len, body });
    var client: ControlOneShot = .{ .path = path, .request = request };
    const thread = try std.Thread.spawn(.{}, ControlOneShot.run, .{&client});
    var frames: usize = 0;
    while (state.waiters.items.len == 0 and frames < 2000) : (frames += 1) {
        control.routes.answerPending(&server, &state, &host);
        io.sleep(.fromMilliseconds(1), .awake) catch {};
    }
    try std.testing.expectEqual(@as(usize, 1), state.waiters.items.len);
    host.finishCall(slow.ticket, .{ .ok = ".{ .done = true }" });
    thread.join();
    try std.testing.expect(std.mem.endsWith(u8, client.reply[0..client.len], "{\"jsonrpc\":\"2.0\",\"id\":\"later\",\"result\":{\"content\":[{\"type\":\"text\",\"text\":\"{\\\"done\\\":true}\"}],\"isError\":false}}"));
}

/// A command that keeps who called it (`Host.author`), and the events the bus delivered.
const McpWho = struct {
    host: *sdk.Host,
    who: sdk.Author = .unattributed,
    label: [64]u8 = undefined,
    label_len: usize = 0,
    ended: [256]u8 = undefined,
    ended_len: usize = 0,
    fn record(state: *anyopaque) anyerror!void {
        const self: *McpWho = @ptrCast(@alignCast(state));
        self.who = self.host.author();
        self.label_len = @min(self.who.label.len, self.label.len);
        @memcpy(self.label[0..self.label_len], self.who.label[0..self.label_len]);
    }
    fn heard(state: *anyopaque, event: sdk.events.Event) void {
        const self: *McpWho = @ptrCast(@alignCast(state));
        self.ended_len = @min(event.payload.len, self.ended.len);
        @memcpy(self.ended[0..self.ended_len], event.payload[0..self.ended_len]);
    }
};

test "control: each MCP client is a session, its calls made as its own author" {
    const gpa = std.testing.allocator;
    const mcp = @import("app").mcp;
    var host: sdk.Host = .init(gpa);
    defer host.deinit();
    var who: McpWho = .{ .host = &host };
    const vtable = sdk.Plugin.VTable{};
    var plugin = sdk.Plugin{ .state = &who, .vtable = &vtable, .id = "t", .display_name = "T" };
    try host.registerCommand(.{ .id = "t.who", .owner = &plugin, .title = "Who", .run = McpWho.record });
    try host.subscribe(.{ .event = mcp.session_ended.name, .owner = &plugin, .handler = McpWho.heard });
    var sessions: mcp.Sessions = .{};
    defer sessions.deinit(gpa);
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // `initialize` opens a session named by the client, and says which.
    var ctx: mcp.Context = .{ .gpa = gpa, .sessions = &sessions, .header = null, .now = 0, .fresh_id = 0x2a };
    _ = try mcp.handle(&host, "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{\"clientInfo\":{\"name\":\"Claude Code\"}}}", arena, null, &ctx);
    try std.testing.expectEqual(@as(?u64, 0x2a), ctx.opened);
    var buf: [16]u8 = undefined;
    const header = mcp.formatSession(0x2a, &buf);
    try std.testing.expectEqualStrings("000000000000002a", header);
    try std.testing.expectEqual(@as(?u64, 0x2a), mcp.parseSession(header));

    // A call with the session is made as its author, labelled with the client's name.
    const call = "{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"tools/call\",\"params\":{\"name\":\"t__who\"}}";
    var with: mcp.Context = .{ .gpa = gpa, .sessions = &sessions, .header = header, .now = 1, .fresh_id = 0 };
    _ = try mcp.handle(&host, call, arena, null, &with);
    try std.testing.expect(who.who.same(.{ .kind = .agent, .plugin = "control", .session = 0x2a }));
    try std.testing.expectEqualStrings("Claude Code", who.label[0..who.label_len]);
    // Without one, the shared author, as every call was before sessions.
    var without: mcp.Context = .{ .gpa = gpa, .sessions = &sessions, .header = null, .now = 1, .fresh_id = 0 };
    _ = try mcp.handle(&host, call, arena, null, &without);
    try std.testing.expect(who.who.same(mcp.Sessions.shared));
    // A session that is not open is refused, so the client initializes again.
    var unknown: mcp.Context = .{ .gpa = gpa, .sessions = &sessions, .header = "00000000000000ff", .now = 1, .fresh_id = 0 };
    try std.testing.expect(try mcp.handle(&host, call, arena, null, &unknown) == .unknown_session);
    var garbled: mcp.Context = .{ .gpa = gpa, .sessions = &sessions, .header = "not hex", .now = 1, .fresh_id = 0 };
    try std.testing.expect(try mcp.handle(&host, call, arena, null, &garbled) == .unknown_session);
    // Only the header's own form names a session: no sign, no separators, no short forms.
    try std.testing.expectEqual(@as(?u64, null), mcp.parseSession("2a"));
    try std.testing.expectEqual(@as(?u64, null), mcp.parseSession("+00000000000002a"));
    try std.testing.expectEqual(@as(?u64, null), mcp.parseSession("0000_0000000002a"));
    // A notification naming a session that is not open is refused as well.
    var late: mcp.Context = .{ .gpa = gpa, .sessions = &sessions, .header = "00000000000000ff", .now = 1, .fresh_id = 0 };
    try std.testing.expect(try mcp.handle(&host, "{\"jsonrpc\":\"2.0\",\"method\":\"notifications/initialized\"}", arena, null, &late) == .unknown_session);

    // At the cap, opening one more ends the one idle longest.
    var capped: mcp.Sessions = .{};
    defer capped.deinit(gpa);
    for (0..mcp.Sessions.max + 1) |i| {
        var open: mcp.Context = .{ .gpa = gpa, .sessions = &capped, .header = null, .now = @intCast(i), .fresh_id = 100 + i };
        _ = try mcp.handle(&host, "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\"}", arena, null, &open);
    }
    try std.testing.expectEqual(@as(usize, mcp.Sessions.max), capped.list.items.len);
    for (capped.list.items) |c| try std.testing.expect(c.id != 100);
    host.deliverEvents();

    // Idle past the limit, it ends, and the bus says whose it was.
    sessions.expire(gpa, &host, 1 + mcp.Sessions.idle_ns - 1);
    try std.testing.expectEqual(@as(usize, 1), sessions.list.items.len);
    sessions.expire(gpa, &host, 1 + mcp.Sessions.idle_ns);
    try std.testing.expectEqual(@as(usize, 0), sessions.list.items.len);
    host.deliverEvents();
    try std.testing.expectEqualStrings(".{.session=42,.label=\"Claude Code\",.plugin=\"control\"}", who.ended[0..who.ended_len]);
}

test "control: an MCP session's id comes back as a header, and DELETE /mcp ends it" {
    if (!std.Io.net.has_unix_sockets) return error.SkipZigTest;
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    const control = @import("app").control;
    var host: sdk.Host = .init(gpa);
    defer host.deinit();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir = try tmp.dir.realPathFileAlloc(io, ".", gpa);
    defer gpa.free(dir);
    const path = try std.fs.path.join(gpa, &.{ dir, "c.sock" });
    defer gpa.free(path);
    const Wake = struct {
        fn none() void {}
    };
    var server: control.Server = .{ .gpa = gpa, .io = io, .socket_path = path, .wake = Wake.none };
    try server.start();
    var state: control.routes.State = .{};
    defer control.routes.stop(&server, &state, &host);
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const Exchange = struct {
        fn run(server_: *control.Server, state_: *control.routes.State, host_: *sdk.Host, client: *ControlOneShot) !void {
            const thread = try std.Thread.spawn(.{}, ControlOneShot.run, .{client});
            var frames: usize = 0;
            while (client.len == 0 and frames < 2000) : (frames += 1) {
                control.routes.answerPending(server_, state_, host_);
                std.testing.io.sleep(.fromMilliseconds(1), .awake) catch {};
            }
            thread.join();
        }
    };
    const init = "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{\"clientInfo\":{\"name\":\"probe\"}}}";
    var opening: ControlOneShot = .{ .path = path, .request = try arena.print("POST /mcp HTTP/1.1\r\nHost: x\r\nContent-Type: application/json\r\nContent-Length: {d}\r\nConnection: close\r\n\r\n{s}", .{ init.len, init }) };
    try Exchange.run(&server, &state, &host, &opening);
    const reply = opening.reply[0..opening.len];
    const key = "mcp-session-id: ";
    const at = std.ascii.findIgnoreCase(reply, key) orelse return error.TestUnexpectedResult;
    const id = reply[at + key.len ..][0..16];
    try std.testing.expectEqual(@as(usize, 1), state.sessions.list.items.len);
    try std.testing.expectEqual(@import("app").mcp.parseSession(id), state.sessions.list.items[0].id);

    var ending: ControlOneShot = .{ .path = path, .request = try arena.print("DELETE /mcp HTTP/1.1\r\nHost: x\r\nMcp-Session-Id: {s}\r\nContent-Length: 0\r\nConnection: close\r\n\r\n", .{id}) };
    try Exchange.run(&server, &state, &host, &ending);
    try std.testing.expect(std.mem.startsWith(u8, ending.reply[0..ending.len], "HTTP/1.1 200"));
    try std.testing.expectEqual(@as(usize, 0), state.sessions.list.items.len);
}

const ControlStreamClient = struct {
    path: []const u8,
    reply: [4096]u8 = undefined,
    len: usize = 0,
    fn run(self: *ControlStreamClient) void {
        const io = std.testing.io;
        const addr = std.Io.net.UnixAddress.init(self.path) catch return;
        const stream = addr.connect(io) catch return;
        defer stream.close(io);
        var wbuf: [256]u8 = undefined;
        var w = stream.writer(io, &wbuf);
        w.interface.writeAll("GET /events?topics=t.* HTTP/1.1\r\nHost: x\r\n\r\n") catch return;
        w.interface.flush() catch return;
        var rbuf: [256]u8 = undefined;
        var r = stream.reader(io, &rbuf);
        self.len = r.interface.readSliceShort(&self.reply) catch 0;
    }
};

test "control: the app's events reach a stream, and the bus listens only while one is open" {
    if (!std.Io.net.has_unix_sockets) return error.SkipZigTest;
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    const control = @import("app").control;
    var host: sdk.Host = .init(gpa);
    defer host.deinit();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir = try tmp.dir.realPathFileAlloc(io, ".", gpa);
    defer gpa.free(dir);
    const path = try std.fs.path.join(gpa, &.{ dir, "c.sock" });
    defer gpa.free(path);

    const Wake = struct {
        fn none() void {}
    };
    var server: control.Server = .{ .gpa = gpa, .io = io, .socket_path = path, .wake = Wake.none };
    try server.start();
    var relay: control.routes.State = .{};
    try std.testing.expect(!host.listening.load(.acquire));

    var client: ControlStreamClient = .{ .path = path };
    const thread = try std.Thread.spawn(.{}, ControlStreamClient.run, .{&client});
    // Frames, as the app would run them, until the stream is open and the relay listens.
    var frames: usize = 0;
    while (frames < 2000) : (frames += 1) {
        control.routes.answerPending(&server, &relay, &host);
        server.lock.lockUncancelable(io);
        const open = server.streams.items.len;
        server.lock.unlock(io);
        if (open == 1) break;
        io.sleep(.fromMilliseconds(1), .awake) catch {};
    }
    try std.testing.expect(host.listening.load(.acquire));

    host.emitZon("t.done", .{ .n = 1, .mode = .fast });
    host.emitZon("u.other", .{ .n = 2 });
    host.deliverEvents();
    io.sleep(.fromMilliseconds(50), .awake) catch {};
    control.routes.stop(&server, &relay, &host);
    thread.join();
    // Stopped: nothing listens, so an emit costs the bus its one load again.
    try std.testing.expect(!host.listening.load(.acquire));
    const reply = client.reply[0..client.len];
    try std.testing.expect(std.mem.endsWith(u8, reply, "\r\n\r\nevent: t.done\ndata: {\"n\":1,\"mode\":\"fast\"}\n\n"));
}

test "a failed open is not a load in flight: settled and live tapes go on" {
    const gpa = std.testing.allocator;
    const Openings = @FieldType(fizzy.Editor, "openings");
    var openings: Openings = .init(gpa);
    defer openings.deinit();
    try std.testing.expect(!openings.loading());

    const o = try gpa.create(Openings.Opening);
    o.* = .{
        .editor = undefined,
        .path = try gpa.dupe(u8, "/p/untitled-1"),
        .surface_id = try gpa.dupe(u8, "fizzy.loading:/p/untitled-1"),
        .grouping = 0,
        .preview = false,
    };
    try openings.entries.put(gpa, o.path, o);
    try std.testing.expect(openings.loading());

    // Its placeholder stays, saying why, until its tab is closed; nothing is on its way.
    o.failed = try gpa.dupe(u8, "Its plugin could not read it.");
    try std.testing.expect(!openings.loading());
}

// ── Live tapes ──────────────────────────────────────────────────────────────────────────────────
// `automation.LiveDriver` over the same widgets and stage as the demo tests: input on the app as it
// is, each step once the last has landed.

var demo_live: automation.LiveDriver = undefined;

fn liveFrame() !dvui.App.Result {
    demo_live.frame();
    var col = dvui.box(@src(), .{ .dir = .vertical }, .{ .expand = .both });
    defer col.deinit();
    if (dvui.button(@src(), "Count", .{}, .{ .tag = "demo.count" })) demo_clicks += 1;
    var te: TextEntryWidget = undefined;
    te.init(@src(), .{
        .multiline = true,
        .text = .{ .array_list = .{ .backing = &demo_text, .allocator = std.testing.allocator, .limit = 4096 } },
    }, .{ .expand = .both, .tag = "demo.field" });
    te.processEvents();
    te.draw();
    te.deinit();
    automation.overlay.drawLive(&demo_live);
    return .ok;
}

fn liveCtx() !dvui.testing {
    var t = try dvui.testing.init(.{ .allocator = std.testing.allocator, .window_size = .{ .w = 800, .h = 600 } });
    errdefer t.deinit();
    demo_text = .empty;
    try demo_text.appendSlice(std.testing.allocator, "> ");
    demo_clicks = 0;
    demo_commands = 0;
    demo_stage = .{};
    demo_live = .init(demo_stage.stage());
    try dvui.testing.settle(liveFrame);
    return t;
}

fn deinitLive(t: *dvui.testing) void {
    demo_live.deinit();
    t.deinit();
    demo_text.deinit(std.testing.allocator);
    demo_text = .empty;
    demo_command_args.deinit(std.testing.allocator);
    demo_command_args = .empty;
}

/// Frames until the live tape stops, or fail after `max`.
fn stepLiveUntilDone(max: usize) !void {
    for (0..max) |_| {
        if (!demo_live.playing()) return;
        _ = try dvui.testing.step(liveFrame);
    }
    return error.TestUnexpectedResult;
}

/// Count, click into the field, type, ping with arguments — no keyframe: the app as it is.
fn liveTape() !automation.Tape.Owned {
    var s: automation.Script = .init(std.testing.allocator, "live", "");
    errdefer s.deinit();
    s.check = automation.Input.check;
    s.check.live = true;
    try s.click(.{ .tag = "demo.count" }, .{});
    try s.click(.{ .tag = "demo.field", .x = 0.9, .y = 0.5 }, .{});
    try s.typeText("hi", .{});
    try s.commandWith("demo.ping", .{ .n = 1 });
    return s.finish();
}

test "live: a tape plays on the app as it is, each step once the last has landed" {
    var t = try liveCtx();
    defer deinitLive(&t);

    try demo_live.play(try liveTape());
    try stepLiveUntilDone(200);
    try std.testing.expect(demo_live.outcome.? == .finished);
    try std.testing.expectEqual(@as(usize, 1), demo_clicks);
    try std.testing.expectEqualStrings("> hi", demo_text.items);
    try std.testing.expectEqual(@as(usize, 1), demo_commands);
    try std.testing.expectEqualStrings(".{ .n = 1 }", demo_command_args.items);
    // Nothing of a demo's: no keyframe, no session set aside.
    try std.testing.expectEqual(@as(usize, 0), demo_stage.keyframes);
    try std.testing.expect(!demo_stage.begun);
}

test "live: the pointer clicks, then steps aside while the tape types" {
    var t = try liveCtx();
    defer deinitLive(&t);

    try demo_live.play(try liveTape());
    try std.testing.expect(demo_live.hand.press == null);
    try std.testing.expect(!demo_live.hand.typing);
    // Until the tape types: by then both clicks have landed.
    for (0..200) |_| {
        if (demo_live.hand.typing) break;
        _ = try dvui.testing.step(liveFrame);
    } else return error.TestUnexpectedResult;
    const press = demo_live.hand.press orelse return error.TestUnexpectedResult;
    // The second click, into the field: its pointer is where the ripple spreads from.
    const field = (dvui.tagGet("demo.field") orelse return error.TestUnexpectedResult).rect;
    try std.testing.expect(field.contains(.{ .x = press.pt.x, .y = press.pt.y }));
    try std.testing.expectEqual(@as(usize, 1), demo_clicks);
    try stepLiveUntilDone(200);
}

test "live: a person's key stops it, before the op it had not reached" {
    var t = try liveCtx();
    defer deinitLive(&t);

    try demo_live.play(try liveTape());
    // A step in: the first click has been aimed, not the rest.
    _ = try dvui.testing.step(liveFrame);
    try dvui.testing.pressKey(.escape, .none);
    try stepLiveUntilDone(10);
    const stopped_before = demo_live.outcome.?.interrupted;
    try std.testing.expect(stopped_before < 10);
    try std.testing.expectEqual(@as(usize, 0), demo_commands);
    try std.testing.expectEqualStrings("> ", demo_text.items);
}

test "live: a demo's tape, or a second tape, is refused" {
    var t = try liveCtx();
    defer deinitLive(&t);

    // A keyframe is a demo's: a live tape never cuts.
    try std.testing.expectError(error.KeyframeInLiveTape, demo_live.play(try demoTape()));
    try std.testing.expect(!demo_live.playing());

    try demo_live.play(try liveTape());
    try std.testing.expectError(error.Busy, demo_live.play(try liveTape()));
    demo_live.stop();
    try std.testing.expect(demo_live.outcome.? == .stopped);
}

/// Count, then wait for something that never comes, then ping.
fn lostTape() !automation.Tape.Owned {
    var s: automation.Script = .init(std.testing.allocator, "lost", "");
    errdefer s.deinit();
    s.check.live = true;
    try s.click(.{ .tag = "demo.count" }, .{});
    try s.waitFor("demo.nowhere", .{ .timeout = 300 });
    try s.command("demo.ping");
    return s.finish();
}

test "live: a wait that never holds stops the tape and says where" {
    var t = try liveCtx();
    defer deinitLive(&t);

    try demo_live.play(try lostTape());
    try stepLiveUntilDone(100);
    const at = demo_live.outcome.?.timed_out;
    try std.testing.expect(at > 0);
    try std.testing.expectEqual(@as(usize, 1), demo_clicks);
    try std.testing.expectEqual(@as(usize, 0), demo_commands);
}

// ── Profiles ────────────────────────────────────────────────────────────────────────────────────
// Taking `--profile` out of argv is `app/profile.zig`'s own unit tests; these are the single-instance
// layer's half: the profile made absolute like any other path, and never forwarded as one.

/// `expected` written with `/`, against a path the OS spelled with its own separator.
fn expectPosixPath(expected: []const u8, actual: []const u8) !void {
    const gpa = std.testing.allocator;
    const posix = try gpa.dupe(u8, actual);
    defer gpa.free(posix);
    std.mem.replaceScalar(u8, posix, std.fs.path.sep, '/');
    try std.testing.expectEqualStrings(expected, posix);
}

test "profile: argv names one, made absolute and taken out of what is opened" {
    const si = @import("app").single_instance;
    const gpa = std.testing.allocator;

    const named = try si.resolveArgs(gpa, "/work", &.{ "fizzy", "--profile", "sandbox/./one", "notes.md", "-v" }, "/from/env");
    defer si.freeResolvedArgv(gpa, named.argv);
    defer gpa.free(named.profile.?);
    try expectPosixPath("/work/sandbox/one", named.profile.?);
    try std.testing.expectEqual(@as(usize, 3), named.argv.len);
    try expectPosixPath("/work/notes.md", named.argv[1]);
    try std.testing.expectEqualStrings("-v", named.argv[2]);

    // The flag absent, the environment names it; neither, there is none.
    const from_env = try si.resolveArgs(gpa, "/work", &.{"fizzy"}, "/from/env");
    defer si.freeResolvedArgv(gpa, from_env.argv);
    defer gpa.free(from_env.profile.?);
    try expectPosixPath("/from/env", from_env.profile.?);

    const none = try si.resolveArgs(gpa, "/work", &.{ "fizzy", "a.md" }, null);
    defer si.freeResolvedArgv(gpa, none.argv);
    try std.testing.expectEqual(@as(?[]u8, null), none.profile);
    try std.testing.expect(!none.quiet);

    // `--quiet` comes out with it, wherever it is, and is never a path to open.
    const quiet = try si.resolveArgs(gpa, "/work", &.{ "fizzy", "--quiet", "a.md", "--profile", "p", "--quiet" }, null);
    defer si.freeResolvedArgv(gpa, quiet.argv);
    defer gpa.free(quiet.profile.?);
    try std.testing.expect(quiet.quiet);
    try std.testing.expectEqual(@as(usize, 2), quiet.argv.len);
    try expectPosixPath("/work/a.md", quiet.argv[1]);

    // Taking the lock with a profile is native startup, not something a test process can do
    // twice; it is compiled here, so a mistake in it fails this build rather than only the app's.
    _ = &si.acquireLock;
}

// ── Accessible names ──────────────────────────────────────────────────────────────────────────
// dvui's frame dump (`dvui.debug.captureFrame`) records each widget's role, label and the text a
// label shows. A button's name is its `label` option, or the text of the label widget it names or
// holds — how dvui names `dvui.button("Save")` — so an icon-only button needs a `label` of its own.

/// Capture one frame of `frame` and fail, naming each one, when something on screen a person clicks
/// (a button, tab, checkbox, radio, link or menu item) has no name.
fn expectButtonsNamed(frame: fn () anyerror!dvui.App.Result) !void {
    dvui.debug.captureFrame();
    // `captureFrame` starts at the next `Window.begin`: the second step is the captured one.
    _ = try dvui.testing.step(frame);
    _ = try dvui.testing.step(frame);
    const widgets = (dvui.debug.lastCapture() orelse return error.TestUnexpectedResult).widgets.items;
    var unnamed: usize = 0;
    for (widgets, 0..) |*w, i| {
        const clickable = w.role != null and switch (w.role.?) {
            .button, .tab, .check_box, .radio_button, .link, .menu_item => true,
            else => false,
        };
        if (!clickable or !w.visible) continue;
        // The rule a snapshot names widgets by (`replay.Snapshot.name`).
        if (automation.Snapshot.name(widgets, i, true) != null) continue;
        unnamed += 1;
        std.debug.print("unnamed {s}: {s}:{d} ({s}){s}{s}\n", .{ @tagName(w.role.?), w.src_file, w.src_line, w.src_fn, if (w.tag != null) " tag=" else "", w.tag orelse "" });
    }
    dvui.debug.clearCaptures(dvui.currentWindow().gpa);
    try std.testing.expectEqual(@as(usize, 0), unnamed);
}

// ── Headless ────────────────────────────────────────────────────────────────────────────────────
// The spike in plans/AGENTS_PLAN.md ("Running with no display"): the whole editor, as `Entry`
// brings it up, over dvui's testing backend in a profile of its own.

/// The app's frame as `Entry` runs it: the demo player, the frame target, the editor.
var inline_md: ?sdk.services.markdown.Api = null;
var inline_md_text: []const u8 = "A *short* paragraph.";
var inline_md_height: f32 = 0;
fn inlineMarkdownFrame() !dvui.App.Result {
    var box = dvui.box(@src(), .{ .dir = .vertical }, .{});
    try inline_md.?.renderInline(inline_md_text, dvui.currentWindow().gpa, .{ .width = 300, .id_extra = 0x1d1e });
    const id = box.data().id;
    box.deinit();
    inline_md_height = dvui.minSizeGet(id).?.h;
    return .ok;
}

/// A listener's record of fizzy's events: each one's name and the path its payload names.
const HeardEvents = struct {
    events: std.ArrayListUnmanaged(struct { name: []u8, path: []u8 }) = .empty,

    fn handler(state: *anyopaque, e: sdk.events.Event) void {
        const self: *HeardEvents = @ptrCast(@alignCast(state));
        const gpa = std.heap.smp_allocator;
        const src = gpa.dupeSentinel(u8, e.payload, 0) catch return;
        defer gpa.free(src);
        // A batch of disk changes is heard by its first path, everything else by its `.path`.
        const path = if (std.mem.eql(u8, e.name, "fizzy.files.changed")) files: {
            var changed_arena: std.heap.ArenaAllocator = .init(gpa);
            defer changed_arena.deinit();
            var changed_diag: std.zon.parse.Diagnostics = undefined;
            const changed = std.zon.parse.fromSlice(sdk.events.FilesChanged, .{ .gpa = gpa, .arena = changed_arena.allocator(), .source = src, .diagnostics = &changed_diag, .ignore_unknown_fields = true }) catch return;
            if (changed.events.len == 0) return;
            break :files gpa.dupe(u8, changed.events[0].path) catch return;
        } else plain: {
            var payload_arena: std.heap.ArenaAllocator = .init(gpa);
            defer payload_arena.deinit();
            var payload_diag: std.zon.parse.Diagnostics = undefined;
            const payload = std.zon.parse.fromSlice(sdk.events.Path, .{ .gpa = gpa, .arena = payload_arena.allocator(), .source = src, .diagnostics = &payload_diag, .ignore_unknown_fields = true }) catch return;
            break :plain gpa.dupe(u8, payload.path) catch return;
        };
        self.events.append(gpa, .{ .name = gpa.dupe(u8, e.name) catch return, .path = path }) catch gpa.free(path);
    }

    fn deinit(self: *HeardEvents) void {
        for (self.events.items) |e| {
            std.heap.smp_allocator.free(e.name);
            std.heap.smp_allocator.free(e.path);
        }
        self.events.deinit(std.heap.smp_allocator);
    }
};

fn headlessFrame() !dvui.App.Result {
    return fizzy.Entry.AppFrame();
}

/// What a demo made of the document panes while it played, watched a frame at a time: the most
/// panes there were at once, and whether two of them ever sat one above the other or side by side.
const PaneWatch = struct {
    most: usize = 0,
    stacked: bool = false,
    side_by_side: bool = false,

    fn look(self: *PaneWatch, wb: *const workbench.Workbench) void {
        const panes = wb.workspaces.values();
        self.most = @max(self.most, panes.len);
        for (panes, 0..) |a, i| for (panes[i + 1 ..]) |b| {
            const ra = a.pane_rect_physical orelse continue;
            const rb = b.pane_rect_physical orelse continue;
            if (ra.w < 1 or rb.w < 1 or ra.h < 1 or rb.h < 1) continue;
            const below = ra.y >= rb.y + rb.h - 1 or rb.y >= ra.y + ra.h - 1;
            const beside = ra.x >= rb.x + rb.w - 1 or rb.x >= ra.x + ra.w - 1;
            if (below and !beside) self.stacked = true;
            if (beside and !below) self.side_by_side = true;
        };
    }
};

test "headless: the whole editor comes up, opens a file, plays the tour and goes down" {
    // One test, not several: a second whole editor in the same process cannot load its plugins.
    // Not the testing allocator: this is the app's own lifetime, whose exit leaks by design
    // (`Editor.unloadPluginLibs`), and what is measured here is that it runs.
    const gpa = std.heap.smp_allocator;
    var t = try dvui.testing.init(.{ .allocator = gpa, .window_size = .{ .w = 1280, .h = 800 } });
    defer t.deinit();

    // A fresh profile, so nothing of anyone's config — or of an earlier run — comes in.
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root_buf: [std.fs.max_path_bytes]u8 = undefined;
    const root = root_buf[0..try tmp.dir.realPath(dvui.io, &root_buf)];
    const app = @import("app");
    app.profile.root = root;
    defer app.profile.root = null;

    // As `Entry.AppInit` brings it up.
    const entry = try gpa.create(fizzy.Entry);
    defer gpa.destroy(entry);
    entry.* = .{ .allocator = gpa, .window = t.window, .root_path = "." };
    const editor = try gpa.create(fizzy.Editor);
    defer gpa.destroy(editor);
    fizzy.setInstances(entry, editor);
    editor.* = try fizzy.Editor.init(entry);
    // A failing expect below returns early, and the watcher threads read the editor until
    // `deinit` joins them: without this they outlive the `destroy` above and crash the run
    // while it prints the failure.
    var quit = false;
    errdefer if (!quit) editor.deinit() catch {};
    workbench.runtime.setWorkbench(&editor.workbench);
    try editor.postInit();
    try dvui.testing.settle(headlessFrame);
    try std.testing.expectEqualStrings(root, editor.app.config_folder);
    // The person's choices stay in the profile too, not in the shared config folder.
    try std.testing.expectEqualStrings(root, editor.person_dir);
    // A plugin's data folder (`Host.pluginDataFolder`): under the profile, made on the first ask,
    // the same borrowed path after, one per plugin.
    {
        const host = &editor.app.host;
        const text_plugin = host.pluginById("text") orelse return error.TestUnexpectedResult;
        const markdown_plugin = host.pluginById("markdown") orelse return error.TestUnexpectedResult;
        const data = host.pluginDataFolder(text_plugin) orelse return error.TestUnexpectedResult;
        const want = try std.fs.path.join(gpa, &.{ root, "plugin-data", "text" });
        defer gpa.free(want);
        try std.testing.expectEqualStrings(want, data);
        var dir = try std.Io.Dir.cwd().openDir(dvui.io, data, .{});
        dir.close(dvui.io);
        try std.testing.expectEqual(data.ptr, (host.pluginDataFolder(text_plugin) orelse return error.TestUnexpectedResult).ptr);
        const other = host.pluginDataFolder(markdown_plugin) orelse return error.TestUnexpectedResult;
        try std.testing.expect(!std.mem.eql(u8, data, other));
        const level = std.testing.log_level;
        std.testing.log_level = .err; // the warnings the cases below ask for
        defer std.testing.log_level = level;
        // An id that is not a plain identifier gets no folder and no entry, and one no plugin
        // registered gets none either; `Text` is `text`'s folder, one entry per folder.
        try std.testing.expect(editor.app.pluginDataFolder("../escape") == null);
        try std.testing.expect(editor.app.plugin_data_folders.get("../escape") == null);
        try std.testing.expect(editor.app.pluginDataFolder("nobody") == null);
        try std.testing.expect(editor.app.plugin_data_folders.get("nobody") == null);
        try std.testing.expectEqual(data.ptr, (editor.app.pluginDataFolder("Text") orelse return error.TestUnexpectedResult).ptr);
        const vt = sdk.Plugin.VTable{};
        // A plugin whose id has capitals gets it in lowercase; another in a different case of it
        // is not registered at all. Retired (`Host.retirePlugin`), its folder is still its own
        // in its `deinit`, and not handed out after.
        {
            const Retiring = struct {
                var plugin: sdk.Plugin = undefined;
                var host_seen: ?*sdk.Host = null;
                var in_deinit: ?bool = null;
                fn deinit(_: *anyopaque) void {
                    in_deinit = host_seen.?.pluginDataFolder(&plugin) != null;
                }
            };
            const retiring_vt = sdk.Plugin.VTable{ .deinit = Retiring.deinit };
            var state: u8 = 0;
            Retiring.plugin = .{ .state = &state, .vtable = &retiring_vt, .id = "CaseTest", .display_name = "Case Test" };
            Retiring.host_seen = host;
            try host.registerPlugin(&Retiring.plugin);
            const want_cased = try std.fs.path.join(gpa, &.{ root, "plugin-data", "casetest" });
            defer gpa.free(want_cased);
            try std.testing.expectEqualStrings(want_cased, host.pluginDataFolder(&Retiring.plugin) orelse return error.TestUnexpectedResult);
            var lower = sdk.Plugin{ .state = undefined, .vtable = &vt, .id = "casetest", .display_name = "Case Test" };
            try std.testing.expectError(error.DuplicatePluginId, host.registerPlugin(&lower));
            const kept = host.pluginDataFolder(&Retiring.plugin) orelse return error.TestUnexpectedResult;
            host.retirePlugin(&Retiring.plugin, null);
            try std.testing.expectEqual(@as(?bool, true), Retiring.in_deinit);
            try std.testing.expect(host.pluginDataFolder(&Retiring.plugin) == null);
            // The same id in another case, registered once the first is gone, is the same folder
            // and the same entry: one per folder.
            try host.registerPlugin(&lower);
            defer host.retirePlugin(&lower, null);
            try std.testing.expectEqual(kept.ptr, (host.pluginDataFolder(&lower) orelse return error.TestUnexpectedResult).ptr);
        }
        // Unregistered without being retired (an app's own unload, a test's), its folder is
        // released all the same: no caller leaves a live one behind.
        {
            var released = sdk.Plugin{ .state = undefined, .vtable = &vt, .id = "released", .display_name = "Released" };
            try host.registerPlugin(&released);
            _ = host.pluginDataFolder(&released) orelse return error.TestUnexpectedResult;
            host.unregisterPlugin(&released);
            try std.testing.expect(host.pluginDataFolder(&released) == null);
        }
        // An id that is not a plain identifier names no folder.
        {
            var dotted = sdk.Plugin{ .state = undefined, .vtable = &vt, .id = "dotted.id", .display_name = "Dotted" };
            try host.registerPlugin(&dotted);
            defer host.retirePlugin(&dotted, null);
            try std.testing.expect(host.pluginDataFolder(&dotted) == null);
        }
        // Deleted since, it is made again by an ask once the second it is trusted for is over.
        try std.Io.Dir.cwd().deleteTree(dvui.io, data);
        const text_entry = editor.app.plugin_data_folders.getPtr("text") orelse return error.TestUnexpectedResult;
        text_entry.made_at.? -= app.App.plugin_data_recheck_ns;
        _ = host.pluginDataFolder(text_plugin) orelse return error.TestUnexpectedResult;
        var again = try std.Io.Dir.cwd().openDir(dvui.io, data, .{});
        again.close(dvui.io);
        // One that cannot be made (a file in its way) is null, and not tried again for a few
        // seconds; once they have passed, with the way clear, it is made.
        {
            var blocked = sdk.Plugin{ .state = undefined, .vtable = &vt, .id = "blocked", .display_name = "Blocked" };
            try host.registerPlugin(&blocked);
            defer host.retirePlugin(&blocked, null);
            try tmp.dir.writeFile(dvui.io, .{ .sub_path = "plugin-data/blocked", .data = "" });
            try std.testing.expect(host.pluginDataFolder(&blocked) == null);
            try tmp.dir.deleteFile(dvui.io, "plugin-data/blocked");
            try std.testing.expect(host.pluginDataFolder(&blocked) == null);
            const cached = editor.app.plugin_data_folders.getPtr("blocked") orelse return error.TestUnexpectedResult;
            cached.failed_at.? -= app.App.plugin_data_retry_ns;
            const made = host.pluginDataFolder(&blocked) orelse return error.TestUnexpectedResult;
            var dir2 = try std.Io.Dir.cwd().openDir(dvui.io, made, .{});
            dir2.close(dvui.io);
            try std.testing.expect(cached.failed_at == null);
        }
        // A build declaring a loaded plugin's id in another case is refused before it is opened,
        // its card shows it failed (not loaded) and says why, and uninstalling it goes through.
        if (app.App.loads_plugins) {
            try std.testing.expectError(error.DuplicatePluginId, editor.loadUserPluginById("Text"));
            const status = editor.app.pluginStatus("Text");
            try std.testing.expectEqual(sdk.services.plugins.Api.State.failed, status.state);
            try std.testing.expect(std.mem.find(u8, status.why, "differs only in case") != null);
            // Uninstalling from that card never deletes the loaded plugin's folder, which on macOS
            // and Windows is the same folder by another name.
            try tmp.dir.createDirPath(dvui.io, "plugins/text");
            try tmp.dir.writeFile(dvui.io, .{ .sub_path = "plugins/text/keep", .data = "" });
            try editor.uninstallPlugin("Text", true);
            try std.testing.expectEqual(sdk.services.plugins.Api.State.not_loaded, editor.app.pluginStatus("Text").state);
            try std.testing.expect(host.pluginById("text") != null);
            _ = try tmp.dir.statFile(dvui.io, "plugins/text/keep", .{});
            try tmp.dir.deleteTree(dvui.io, "plugins/text");
        }
        // A folder already in `plugins/` in another case clashes too, read fresh at each ask: an
        // installed plugin that is not loaded.
        {
            var clash_buf: [std.fs.max_name_bytes]u8 = undefined;
            try std.testing.expect(editor.app.pluginCaseClash(&clash_buf, "graphl") == null);
            try tmp.dir.createDirPath(dvui.io, "plugins/Graphl");
            try tmp.dir.writeFile(dvui.io, .{ .sub_path = "plugins/Graphl/keep", .data = "" });
            defer tmp.dir.deleteTree(dvui.io, "plugins/Graphl") catch {};
            const found = editor.app.pluginCaseClash(&clash_buf, "graphl") orelse return error.TestUnexpectedResult;
            try std.testing.expectEqualStrings("Graphl", found.other);
            try std.testing.expect(editor.app.pluginCaseClash(&clash_buf, "Graphl") == null);
            // Its refused variant's card, uninstalled, never takes the installed plugin's folder,
            // though on macOS and Windows `plugins/graphl` is that folder.
            editor.app.recordCaseClash("graphl", "Graphl", null);
            try editor.uninstallPlugin("graphl", true);
            _ = try tmp.dir.statFile(dvui.io, "plugins/Graphl/keep", .{});
            try std.testing.expectEqual(sdk.services.plugins.Api.State.not_loaded, editor.app.pluginStatus("graphl").state);
        }
        // A plugin's own folder, alone under its name, is still what uninstalling deletes.
        {
            try tmp.dir.createDirPath(dvui.io, "plugins/solo");
            try tmp.dir.writeFile(dvui.io, .{ .sub_path = "plugins/solo/build", .data = "" });
            try editor.uninstallPlugin("solo", true);
            try std.testing.expectError(error.FileNotFound, tmp.dir.statFile(dvui.io, "plugins/solo", .{}));
        }
    }
    // The app offers its plugins the `automation` service, and nothing is in flight.
    const automation_api = editor.app.host.getServiceTyped(sdk.services.automation.Api) orelse return error.TestUnexpectedResult;
    try std.testing.expect(automation_api.settled());

    // A project and a document in it, as `fizzy <dir>` and a click would open them.
    try tmp.dir.createDirPath(dvui.io, "project");
    try tmp.dir.writeFile(dvui.io, .{ .sub_path = "project/notes.md", .data = "# Notes\n\nwritten headless\n" });
    const project = try std.fs.path.join(gpa, &.{ root, "project" });
    defer gpa.free(project);
    const notes = try std.fs.path.join(gpa, &.{ project, "notes.md" });
    defer gpa.free(notes);
    try editor.setProjectFolder(project);
    // It is now the most recent folder, and a plugin can read when it was opened.
    {
        const host = &editor.app.host;
        const last = host.recentFolderCount() - 1;
        try std.testing.expectEqualStrings(project, host.recentFolderAt(last).?);
        const opened = host.recentFolderOpened(last) orelse return error.TestUnexpectedResult;
        try std.testing.expect(@abs(std.Io.Clock.real.now(dvui.io).toSeconds() - opened) < 60);
        try std.testing.expect(host.recentFolderOpened(last + 1) == null);
    }
    _ = try editor.openFilePath(notes, editor.workbench.currentGroupingID());
    for (0..200) |_| {
        if (editor.activeDoc() != null) break;
        _ = try dvui.testing.step(headlessFrame);
    }
    try dvui.testing.settle(headlessFrame);
    try std.testing.expect(editor.activeDoc() != null);
    // Every button on screen has a name a person, a screen reader or a script could use.
    try expectButtonsNamed(headlessFrame);

    // What is on screen, as a plugin reads it: the rail's views, the explorer's rows, the
    // document's tab and editor, each a line with what it is, its name and the tag a tape aims at.
    const ticket = automation_api.snapshot();
    try std.testing.expectEqual(ticket, automation_api.snapshot());
    var shot: ?[]const u8 = null;
    for (0..4) |_| {
        shot = automation_api.snapshotText(ticket);
        if (shot != null) break;
        _ = try dvui.testing.step(headlessFrame);
    }
    const text = shot orelse return error.TestUnexpectedResult;
    try std.testing.expect(std.mem.find(u8, text, ".role=\"tab\",.name=\"Files\",.tag=\"fizzy.rail:workbench.files\"") != null);
    try std.testing.expect(std.mem.find(u8, text, ".role=\"button\",.name=\"Close Tab\"") != null);
    try std.testing.expect(std.mem.find(u8, text, ".tag=\"workbench.tab:") != null);
    try std.testing.expect(std.mem.find(u8, text, ".role=\"button\",.name=\"notes.md\",.tag=\"workbench.file:") != null);
    // A region is not named by what is in it.
    try std.testing.expect(std.mem.find(u8, text, ".name=\"FILES\"") == null);
    // A markdown file opens on its preview.
    try std.testing.expect(std.mem.find(u8, text, ".tag=\"text.preview:") != null);
    // The windows first, the main one alone here: the testing backend opens no others.
    try std.testing.expect(std.mem.startsWith(u8, text, ".{\n    .{.role=\"window\",.name=\"fizzy\",.tag=\"fizzy.window:main\""));

    // A dialog is on screen too, though dvui shows dialogs after it has stopped capturing the
    // frame, and its buttons have names a tape clicks: About, shut from its own Close button by a
    // live tape, as an agent shuts it.
    {
        const about_close = "fizzy.dialog:About Fizzy:Close";
        const shotOf = struct {
            fn shotOf(api: *const sdk.services.automation.Api) ![]const u8 {
                const n = api.snapshot();
                for (0..4) |_| {
                    if (api.snapshotText(n)) |got| return got;
                    _ = try dvui.testing.step(headlessFrame);
                }
                return error.TestUnexpectedResult;
            }
        }.shotOf;
        fizzy.Editor.Dialogs.AboutFizzy.request();
        try dvui.testing.settle(headlessFrame);
        const open = try shotOf(automation_api);
        try std.testing.expect(std.mem.find(u8, open, ".name=\"About Fizzy\"") != null);
        try std.testing.expect(std.mem.find(u8, open, ".role=\"button\",.name=\"Close\",.tag=\"" ++ about_close ++ "\"") != null);

        var s: automation.Script = .init(gpa, "close-about", "");
        s.check = automation.Input.check;
        s.check.live = true;
        try s.click(.{ .tag = about_close }, .{});
        try editor.demo.live.play(try s.finish());
        for (0..200) |_| {
            if (!editor.demo.live.playing()) break;
            _ = try dvui.testing.step(headlessFrame);
        }
        try std.testing.expect(editor.demo.live.outcome.? == .finished);
        try dvui.testing.settle(headlessFrame);
        const shut = try shotOf(automation_api);
        try std.testing.expect(std.mem.find(u8, shut, "About Fizzy") == null);
    }

    // Open, open folder, save as and close, told a path, as a keybind with arguments, a tape or
    // an agent calls them (`Host.callCommand`); each refuses what it cannot do, saying why.
    {
        const host = &editor.app.host;
        // And fizzy announces each as an event (`Host.emit`), heard by a listener that knows
        // nothing of who opened what.
        var heard: HeardEvents = .{};
        defer heard.deinit();
        const listener_vtable: sdk.Plugin.VTable = .{};
        var listener: sdk.Plugin = .{ .state = &heard, .vtable = &listener_vtable, .id = "listener", .display_name = "Listener" };
        try host.subscribe(.{ .event = "fizzy.*", .owner = &listener, .handler = HeardEvents.handler });
        defer host.withdrawPlugin(&listener);
        const call = struct {
            fn call(h: *sdk.Host, id: []const u8, args: []const u8) sdk.Host.CommandOutcome {
                return h.callCommand(id, args, h.arena());
            }
        }.call;
        try tmp.dir.writeFile(dvui.io, .{ .sub_path = "project/a.txt", .data = "alpha\n" });
        const a = try std.fs.path.join(gpa, &.{ project, "a.txt" });
        defer gpa.free(a);
        const b = try std.fs.path.join(gpa, &.{ project, "b.txt" });
        defer gpa.free(b);
        const args = struct {
            fn path(p: []const u8) ![]u8 {
                return gpa.print(".{{ .path = \"{f}\" }}", .{std.zig.fmtString(p)});
            }
        };

        try std.testing.expect(call(host, "fizzy.openFolder", ".{ .path = \"project\" }") == .failed);
        try std.testing.expect(call(host, "fizzy.openFiles", ".{ .path = \"/no/such/file.txt\" }") == .failed);
        const folder_args = try args.path(project);
        defer gpa.free(folder_args);
        try std.testing.expect(call(host, "fizzy.openFolder", folder_args) == .ok);

        const open_args = try args.path(a);
        defer gpa.free(open_args);
        try std.testing.expect(call(host, "fizzy.openFiles", open_args) == .ok);
        for (0..200) |_| {
            _ = try dvui.testing.step(headlessFrame);
            const d = editor.activeDoc() orelse continue;
            if (std.mem.eql(u8, d.owner.documentPath(d), a)) break;
        }
        const doc = editor.activeDoc() orelse return error.TestUnexpectedResult;
        try std.testing.expectEqualStrings(a, doc.owner.documentPath(doc));

        // Save As: written by the next frame, and the document takes the new name.
        try std.testing.expect(call(host, "fizzy.saveAs", ".{ .path = \"/no/such/dir/b.txt\" }") == .failed);
        const save_args = try args.path(b);
        defer gpa.free(save_args);
        try std.testing.expect(call(host, "fizzy.saveAs", save_args) == .ok);
        for (0..50) |_| {
            _ = try dvui.testing.step(headlessFrame);
            const d = editor.activeDoc() orelse continue;
            if (std.mem.eql(u8, d.owner.documentPath(d), b)) break;
        }
        const saved = editor.activeDoc() orelse return error.TestUnexpectedResult;
        try std.testing.expectEqualStrings(b, saved.owner.documentPath(saved));
        const written = try tmp.dir.readFileAlloc(dvui.io, "project/b.txt", gpa, .limited(1024));
        defer gpa.free(written);
        try std.testing.expectEqualStrings("alpha\n", written);

        // Close is ⌘W/Ctrl+W, the document's key in every editor (the window's is ⇧⌘W).
        const close_key = fizzy.Editor.Keybinds.menuKeybindFor(editor, "fizzy.close");
        try std.testing.expectEqual(dvui.enums.Key.w, close_key.key.?);
        try std.testing.expect((close_key.command orelse false) or (close_key.control orelse false));
        try std.testing.expect(!(close_key.shift orelse false));

        // Close, by path: that document goes, the notes stay.
        const before = editor.app.open_files.count();
        try std.testing.expect(call(host, "fizzy.close", ".{ .path = \"/no/such/file.txt\" }") == .failed);
        try std.testing.expect(call(host, "fizzy.close", save_args) == .ok);
        try dvui.testing.settle(headlessFrame);
        try std.testing.expectEqual(before - 1, editor.app.open_files.count());
        try std.testing.expect(editor.docFromPath(b) == null);
        try std.testing.expect(editor.docFromPath(notes) != null);

        // Disk changes from fizzy's watcher, and a buffer settling as its owner reports it.
        host.notifyFolderPathsChanged(.{ .events = &.{.{ .path = a, .kind = .renamed, .object = .file, .old_path = b }} });
        host.notifyDocumentContentChanged(notes);

        // What the listener heard, in order: the folder closing and opening again (the project was
        // already open), the document opening, its save as b.txt, its close, the disk changing and
        // the notes settling.
        _ = try dvui.testing.step(headlessFrame);
        const want = [_][2][]const u8{
            .{ "fizzy.folder.closed", project },
            .{ "fizzy.folder.opened", project },
            .{ "fizzy.document.opened", a },
            .{ "fizzy.document.saved", b },
            .{ "fizzy.document.closed", b },
            .{ "fizzy.files.changed", a },
            .{ "fizzy.document.changed", notes },
        };
        var at: usize = 0;
        for (heard.events.items) |e| {
            if (at < want.len and std.mem.eql(u8, e.name, want[at][0]) and std.mem.eql(u8, e.path, want[at][1])) at += 1;
        }
        if (at != want.len) {
            for (heard.events.items) |e| std.debug.print("heard {s} {s}\n", .{ e.name, e.path });
            return error.TestUnexpectedResult;
        }
    }

    // The tour, every frame of it, on the testing backend's clock (100 ms a step): about a
    // minute of demo in a few hundred frames.
    // Measured while it plays, with no profiler window open: what each plugin cost, by name.
    fizzy.core.profile.want(60_000);
    // Every frame of it a hitch, so the lookback keeps some whatever this machine's speed.
    _ = try dvui.testing.step(headlessFrame);
    const lookback = fizzy.core.profile.lookback() orelse return error.TestUnexpectedResult;
    lookback.budget_ns = 0;
    defer lookback.budget_ns = std.time.ns_per_s / 60;
    const unattributed_before = editor.app.host.unattributed_steps;
    // The explorer shut, so the person's pane has the room for the tour's drop to split it
    // (`core.placement`); with it open the tour leaves that drop out.
    editor.explorer.close(editor);
    try dvui.testing.settle(headlessFrame);
    try editor.demo.play("tour");
    var frames: usize = 0;
    var desktop_panes: PaneWatch = .{};
    var relocations: usize = 0;
    var prev: ?dvui.Rect = null;
    var was_moving = false;
    while (editor.demo.player.state != .ended and frames < 5000) : (frames += 1) {
        _ = try dvui.testing.step(headlessFrame);
        desktop_panes.look(&editor.workbench);
        const now = calloutRect();
        const moving = if (prev) |p| if (now) |n| @abs(n.x - p.x) + @abs(n.y - p.y) > 0.5 and @abs(n.w - p.w) < 0.5 else false else false;
        if (moving and !was_moving) relocations += 1;
        was_moving = moving;
        prev = now;
    }
    // A callout holds its place: the tour's callouts set off 12 times here before they stopped
    // dodging the resting pointer (`overlay.keepClear`), 11 since. The count is measured on this
    // CI's platform (Linux); macOS lays the tour out with one glide fewer, so 11 is the bound that
    // fails without the change here and holds on both.
    try std.testing.expect(relocations <= 11);
    try std.testing.expectEqual(app.automation.Player.State.ended, editor.demo.player.state);
    // A wide window sets the tour's two documents side by side.
    try std.testing.expect(desktop_panes.side_by_side);
    try std.testing.expect(!desktop_panes.stacked);
    // Every step the tour made has an author: its own where it drives the frame, or its commands'
    // (`Host.act` in the demo's stage). A step nobody acted for is a missed site
    // (`plans/SHARED_HISTORY_PLAN.md`). Owners report every step once that plan's step 3 lands;
    // until then this guards the steps reported while recording.
    try std.testing.expectEqual(unattributed_before, editor.app.host.unattributed_steps);
    {
        var out: std.Io.Writer.Allocating = .init(std.testing.allocator);
        defer out.deinit();
        try fizzy.core.profile.report(fizzy.core.profile.host(), &out.writer, .{ .min_ms = 0, .over_ms = 30_000, .hitches = 3 });
        const profiled = out.written();
        // Past the half second: the costliest scopes over the last 30 s, and the frames that
        // went over budget, each with what it spent.
        try std.testing.expect(std.mem.find(u8, profiled, ".over = .{ .seconds = ") != null);
        try std.testing.expect(std.mem.find(u8, profiled, ".hitch_budget_ms = 0.000") != null);
        try std.testing.expectEqual(@as(usize, 3), std.mem.count(u8, profiled, ".ago_s = "));
        // Spans: the UI thread's frames, each kept, and as a Chrome trace that reads back.
        var with_spans: std.Io.Writer.Allocating = .init(std.testing.allocator);
        defer with_spans.deinit();
        try fizzy.core.profile.report(fizzy.core.profile.host(), &with_spans.writer, .{ .spans = 4 });
        try std.testing.expect(std.mem.find(u8, with_spans.written(), ".spans = .{\n        .{ .name = \"frame\", .count = ") != null);
        var trace: std.Io.Writer.Allocating = .init(std.testing.allocator);
        defer trace.deinit();
        try fizzy.core.profile.writeTrace(&trace.writer, 0);
        const parsed = try std.json.parseFromSlice(struct { traceEvents: []const struct { ph: []const u8, name: []const u8 } }, std.testing.allocator, trace.written(), .{ .ignore_unknown_fields = true });
        defer parsed.deinit();
        var frames_traced: usize = 0;
        for (parsed.value.traceEvents) |e| frames_traced += @intFromBool(std.mem.eql(u8, e.ph, "X") and std.mem.eql(u8, e.name, "frame"));
        try std.testing.expect(frames_traced > 10);
        try std.testing.expect(std.mem.find(u8, profiled, ".frame = .{ .fps = ") != null);
        try std.testing.expect(std.mem.find(u8, profiled, ".owner = \"fizzy\"") != null);
        // The plugins drawing the tour, each under its own name.
        try std.testing.expect(std.mem.find(u8, profiled, ".owner = \"workbench\"") != null);
        try std.testing.expect(std.mem.find(u8, profiled, ".owner = \"text\"") != null);
    }
    // The tour leaves the explorer, the panel and the rest of the window open: their buttons too.
    try expectButtonsNamed(headlessFrame);
    {
        // Scrubbed across the Materials chapter, back and forth: every frame of the seek skips the
        // app's motion, but the glass — the transport's among it — keeps the edge it has in
        // straight playback (`motion.liquid`), and each landing is the model live play reached.
        // A budget of nothing: one run a frame, so every frame shown is one of the seek's.
        const player = &editor.demo.player;
        const budget = player.budget_ns;
        player.budget_ns = 0;
        defer player.budget_ns = budget;
        const tape = player.tape().?;
        const materials = for (tape.chapters, 0..) |ch, i| {
            if (std.mem.eql(u8, ch.title, "Materials")) break i;
        } else return error.TestUnexpectedResult;
        const start: f64 = @floatFromInt(tape.chapters[materials].at);
        const after: f64 = @floatFromInt(if (materials + 1 < tape.chapters.len) tape.chapters[materials + 1].at else tape.duration());
        const edge = fizzy.core.motion.liquid();
        try std.testing.expect(edge > 0);
        var seeking_frames: usize = 0;
        for ([_]f64{ @max(0, start - 500), (start + after) / 2, after + 200, start + 2500, @max(0, start - 500), after - 300 }) |to| {
            player.seek(to);
            var n: usize = 0;
            while (player.state == .seeking and n < 400) : (n += 1) {
                _ = try dvui.testing.step(headlessFrame);
                if (player.state != .seeking) break;
                seeking_frames += 1;
                try std.testing.expect(fizzy.core.motion.off());
                try std.testing.expectEqual(edge, fizzy.core.motion.liquid());
            }
            try std.testing.expect(player.state != .seeking);
            _ = try dvui.testing.step(headlessFrame);
            try std.testing.expect(!fizzy.core.motion.off());
            try std.testing.expectEqual(edge, fizzy.core.motion.liquid());
        }
        try std.testing.expect(seeking_frames > 0);
        try std.testing.expectEqual(@as(u32, 0), player.mismatches);
    }
    editor.demo.player.unload();
    try dvui.testing.settle(headlessFrame);

    // The tour again, in a phone's shape: its anchors differ (no rail, no Sidebar place), and the
    // tape still has to reach its last chapter rather than wait on one that is not there.
    {
        const desktop_api = editor.demos.api;
        const desktop_generation = desktop_api.generation();
        const desktop_size = t.backend.size;
        const desktop_pixels = t.backend.size_pixels;
        // The testing backend reports its size from these fields, so writing them *is* a resize.
        t.backend.size = .{ .w = 390, .h = 844 };
        t.backend.size_pixels = .{ .w = 390, .h = 844 };
        fizzy.core.platform.cached_form_factor = .mobile;
        defer {
            fizzy.core.platform.cached_form_factor = .desktop;
            t.backend.size = desktop_size;
            t.backend.size_pixels = desktop_pixels;
        }
        // `step` re-reads the size at its end, so the first frame still runs at the old one.
        _ = try dvui.testing.step(headlessFrame);
        try dvui.testing.settle(headlessFrame);
        // The list differs by form factor, so its generation moves and a retained one is stale.
        try std.testing.expect(desktop_api.generation() != desktop_generation);
        // Tabs opened until the last one starts past the phone's narrow strip: selecting it scrolls
        // the strip to it, so it is not left off the screen.
        // In a folder of their own: none of the editor's watches is on it.
        var strip_tmp = std.testing.tmpDir(.{});
        defer strip_tmp.cleanup();
        var strip_buf: [std.fs.max_path_bytes]u8 = undefined;
        const strip_dir = strip_buf[0..try strip_tmp.dir.realPath(dvui.io, &strip_buf)];
        for (0..5) |n| {
            var name_buf: [160]u8 = undefined;
            // The last has a name wider than the strip, shown by its leading edge.
            const name = if (n == 4)
                try std.fmt.bufPrint(&name_buf, "strip-tab-{d}-{s}.txt", .{ n, "a-very-long-name-a-very-long-name-a-very-long-name-a-very-long-name-a-very-long-name-" })
            else
                try std.fmt.bufPrint(&name_buf, "strip-tab-{d}.txt", .{n});
            try strip_tmp.dir.writeFile(dvui.io, .{ .sub_path = name, .data = "" });
            const path = try std.fs.path.join(gpa, &.{ strip_dir, name });
            defer gpa.free(path);
            _ = try editor.openFilePath(path, editor.workbench.currentGroupingID());
            for (0..200) |_| {
                _ = try dvui.testing.step(headlessFrame);
                const d = editor.activeDoc() orelse continue;
                if (std.mem.eql(u8, d.owner.documentPath(d), path)) break;
            }
        }
        try dvui.testing.settle(headlessFrame);
        {
            const pane = editor.workbench.workspaces.getPtr(editor.workbench.currentGroupingID()) orelse return error.TestUnexpectedResult;
            const strip = pane.strip_rect_physical orelse return error.TestUnexpectedResult;
            try std.testing.expect(pane.tab_slot_count >= 5);
            const last = pane.tab_slots[pane.tab_slot_count - 1].rect;
            try std.testing.expect(last.w > strip.w);
            try std.testing.expect(last.x >= strip.x - 1 and last.x < strip.x + strip.w);
        }
        try editor.demo.play("tour");
        const player = &editor.demo.player;
        var phone_frames: usize = 0;
        var phone_panes: PaneWatch = .{};
        while (player.state != .ended and phone_frames < 5000) : (phone_frames += 1) {
            _ = try dvui.testing.step(headlessFrame);
            phone_panes.look(&editor.workbench);
        }
        try std.testing.expectEqual(app.automation.Player.State.ended, player.state);
        // Every anchor the phone's tour aims at is drawn: the strip scrolls the selected tab on.
        try std.testing.expectEqual(@as(u32, 0), player.timeouts);
        // A phone never splits by itself: the second document is a card in the one group.
        try std.testing.expectEqual(@as(usize, 1), phone_panes.most);
        player.unload();
        // Their documents are still open: the demo owns only what it opened.
        try std.testing.expect(editor.docFromPath(notes) != null);
        try dvui.testing.settle(headlessFrame);
        for (0..5) |n| {
            var name_buf: [160]u8 = undefined;
            const name = if (n == 4)
                try std.fmt.bufPrint(&name_buf, "strip-tab-{d}-{s}.txt", .{ n, "a-very-long-name-a-very-long-name-a-very-long-name-a-very-long-name-a-very-long-name-" })
            else
                try std.fmt.bufPrint(&name_buf, "strip-tab-{d}.txt", .{n});
            const path = try std.fs.path.join(gpa, &.{ strip_dir, name });
            defer gpa.free(path);
            const doc = editor.docFromPath(path) orelse return error.TestUnexpectedResult;
            try editor.closeFileID(doc.id);
        }
        try dvui.testing.settle(headlessFrame);
    }

    // A tablet held upright stacks the tour's two documents: the window is taller than wide, with
    // room for two.
    {
        const desktop_size = t.backend.size;
        const desktop_pixels = t.backend.size_pixels;
        t.backend.size = .{ .w = 820, .h = 1180 };
        t.backend.size_pixels = .{ .w = 820, .h = 1180 };
        defer {
            t.backend.size = desktop_size;
            t.backend.size_pixels = desktop_pixels;
        }
        _ = try dvui.testing.step(headlessFrame);
        try dvui.testing.settle(headlessFrame);
        try editor.demo.play("tour");
        const player = &editor.demo.player;
        var tablet_frames: usize = 0;
        var tablet_panes: PaneWatch = .{};
        while (player.state != .ended and tablet_frames < 5000) : (tablet_frames += 1) {
            _ = try dvui.testing.step(headlessFrame);
            tablet_panes.look(&editor.workbench);
        }
        try std.testing.expectEqual(app.automation.Player.State.ended, player.state);
        try std.testing.expect(tablet_panes.stacked);
        try std.testing.expect(!tablet_panes.side_by_side);
        player.unload();
        try dvui.testing.settle(headlessFrame);
        // Their documents are still open: the demo owns only what it opened.
        try std.testing.expect(editor.docFromPath(notes) != null);
    }

    // The text commands, as a snippet keybind, a tape or an agent calls them: each one
    // undoable edit to the active document.
    {
        const host = &editor.app.host;
        try tmp.dir.writeFile(dvui.io, .{ .sub_path = "project/main.zig", .data = "const a = 1;\nconst b = 2;\n" });
        const main_zig = try std.fs.path.join(gpa, &.{ project, "main.zig" });
        defer gpa.free(main_zig);
        _ = try editor.openFilePath(main_zig, editor.workbench.currentGroupingID());
        for (0..200) |_| {
            _ = try dvui.testing.step(headlessFrame);
            const d = editor.activeDoc() orelse continue;
            if (std.mem.eql(u8, d.owner.documentPath(d), main_zig)) break;
        }
        try dvui.testing.settle(headlessFrame);
        const doc = editor.activeDoc() orelse return error.TestUnexpectedResult;
        const Read = struct { path: []const u8, lines: usize, text: []const u8 };
        const read = struct {
            fn read(h: *sdk.Host, args: []const u8) !Read {
                const out = h.callCommand("text.read", args, h.arena());
                const zon = switch (out) {
                    .ok => |r| r orelse return error.TestUnexpectedResult,
                    else => return error.TestUnexpectedResult,
                };
                var diag: std.zon.parse.Diagnostics = undefined;
                return std.zon.parse.fromSlice(Read, .{ .gpa = h.arena(), .arena = h.arena(), .source = try h.arena().dupeSentinel(u8, zon, 0), .diagnostics = &diag, .ignore_unknown_fields = true });
            }
        }.read;

        try std.testing.expect(host.callCommand("text.insert", ".{ .text = \"// top\\n\", .line = 1 }", host.arena()) == .ok);
        try std.testing.expectEqualStrings("// top\nconst a = 1;\nconst b = 2;\n", (try read(host, "")).text);

        // One occurrence replaced; an ambiguous or missing one refused, saying so.
        try std.testing.expect(host.callCommand("text.replace", ".{ .find = \"const\", .with = \"var\" }", host.arena()) == .failed);
        try std.testing.expect(host.callCommand("text.replace", ".{ .find = \"nothing\", .with = \"x\" }", host.arena()) == .failed);
        try std.testing.expect(host.callCommand("text.replace", ".{ .find = \"b = 2\", .with = \"b = 3\" }", host.arena()) == .ok);
        try std.testing.expect(host.callCommand("text.replace", ".{ .find = \"const\", .with = \"var\", .all = true }", host.arena()) == .ok);
        try dvui.testing.settle(headlessFrame);
        const now = try read(host, ".{ .from_line = 2, .to_line = 2 }");
        try std.testing.expectEqualStrings("var a = 1;\n", now.text);
        try std.testing.expectEqual(@as(usize, 4), now.lines);
        try std.testing.expectEqualStrings(main_zig, now.path);
        try std.testing.expect(doc.owner.isDirty(doc));

        // Every replacement at once was one edit: one undo puts them all back.
        try editor.undo();
        try std.testing.expectEqualStrings("// top\nconst a = 1;\nconst b = 3;\n", (try read(host, "")).text);

        // By path: a document that is open but not the one in front, read and written.
        const notes_args = try gpa.print(".{{ .path = \"{f}\" }}", .{std.zig.fmtString(notes)});
        defer gpa.free(notes_args);
        try std.testing.expect(std.mem.startsWith(u8, (try read(host, notes_args)).text, "# Notes"));
        try std.testing.expect(host.callCommand("text.read", ".{ .path = \"/not/open.txt\" }", host.arena()) == .failed);

        // A reveal (go to definition, a backlink): the owner's `text.goToLine`, into a document
        // behind the one in front, which comes to the front with its caret there.
        try std.testing.expect(try editor.revealPosition(notes, 2, 3, false));
        try dvui.testing.settle(headlessFrame);
        {
            const front = editor.activeDoc() orelse return error.TestUnexpectedResult;
            try std.testing.expectEqualStrings(notes, front.owner.documentPath(front));
            const Caret = struct { caret: struct { line: u32, column: u32 } };
            const out = host.callCommand("text.read", notes_args, host.arena()).ok.?;
            var at_diag: std.zon.parse.Diagnostics = undefined;
            const at = try std.zon.parse.fromSlice(Caret, .{ .gpa = host.arena(), .arena = host.arena(), .source = try host.arena().dupeSentinel(u8, out, 0), .diagnostics = &at_diag, .ignore_unknown_fields = true });
            try std.testing.expectEqual(@as(u32, 3), at.caret.line);
            try std.testing.expectEqual(@as(u32, 4), at.caret.column);
        }
        try std.testing.expect(try editor.revealPosition(main_zig, 0, 0, false));
        try dvui.testing.settle(headlessFrame);

        // A write changes only what differs, as one edit, and one undo puts back exactly that.
        const write_args = try gpa.print(".{{ .path = \"{f}\", .text = \"// top\\nconst a = 42;\\nconst b = 3;\\n\" }}", .{std.zig.fmtString(main_zig)});
        defer gpa.free(write_args);
        const wrote = host.callCommand("text.write", write_args, host.arena());
        try std.testing.expect(wrote == .ok);
        try std.testing.expect(std.mem.find(u8, wrote.ok.?, ".line = 2") != null);
        try std.testing.expectEqualStrings("// top\nconst a = 42;\nconst b = 3;\n", (try read(host, "")).text);
        try editor.undo();
        try std.testing.expectEqualStrings("// top\nconst a = 1;\nconst b = 3;\n", (try read(host, "")).text);
        try std.testing.expect(std.mem.find(u8, host.callCommand("text.write", write_args, host.arena()).ok.?, ".changed = true") != null);
        try std.testing.expect(std.mem.find(u8, host.callCommand("text.write", write_args, host.arena()).ok.?, ".changed = false") != null);

        // `fizzy.undo`/`fizzy.redo` by path, on a document behind the one in front, as a script or
        // an agent calls them: only the step `expect` names, and the answer says whose it was.
        {
            const notes_doc = editor.docFromPath(notes) orelse return error.TestUnexpectedResult;
            const before = (try read(host, notes_args)).text;
            const notes_write = try gpa.print(".{{ .path = \"{f}\", .text = \"# Notes, by Claude\\n\" }}", .{std.zig.fmtString(notes)});
            defer gpa.free(notes_write);
            const outer = host.act(.{ .kind = .agent, .plugin = "test", .session = 1, .label = "Claude" });
            try std.testing.expect(host.callCommand("text.write", notes_write, host.arena()) == .ok);
            host.endAct(outer);
            const line = notes_doc.owner.historyLine(notes_doc, host.arena()) orelse return error.TestUnexpectedResult;
            const top = line.entries[line.at - 1].id;

            const stale = try gpa.print(".{{ .path = \"{f}\", .expect = {d} }}", .{ std.zig.fmtString(notes), top + 1000 });
            defer gpa.free(stale);
            switch (host.callCommand("fizzy.undo", stale, host.arena())) {
                .failed => |m| try std.testing.expect(std.mem.find(u8, m, "by Claude") != null),
                else => return error.TestUnexpectedResult,
            }
            try std.testing.expectEqualStrings("# Notes, by Claude\n", (try read(host, notes_args)).text);

            const named = try gpa.print(".{{ .path = \"{f}\", .expect = {d} }}", .{ std.zig.fmtString(notes), top });
            defer gpa.free(named);
            const undid = host.callCommand("fizzy.undo", named, host.arena());
            try std.testing.expect(undid == .ok);
            try std.testing.expect(std.mem.find(u8, undid.ok.?, ".by = \"Claude\"") != null);
            try std.testing.expectEqualStrings(before, (try read(host, notes_args)).text);
            // The document in front is untouched, and still in front.
            try std.testing.expectEqualStrings(main_zig, (editor.activeDoc() orelse return error.TestUnexpectedResult).owner.documentPath(editor.activeDoc().?));

            try std.testing.expect(host.callCommand("fizzy.redo", named, host.arena()) == .ok);
            try std.testing.expectEqualStrings("# Notes, by Claude\n", (try read(host, notes_args)).text);
            try std.testing.expect(host.callCommand("fizzy.undo", named, host.arena()) == .ok);
            try std.testing.expectEqualStrings(before, (try read(host, notes_args)).text);
        }

        // The person's Cmd-Z taking a step someone else made: the menu names it, and the pane says
        // so with a Redo that puts it back.
        {
            const front = editor.activeDoc() orelse return error.TestUnexpectedResult;
            const before = (try read(host, "")).text;
            const front_write = try gpa.print(".{{ .path = \"{f}\", .text = \"// by Claude\\n\" }}", .{std.zig.fmtString(main_zig)});
            defer gpa.free(front_write);
            const outer = host.act(.{ .kind = .agent, .plugin = "test", .session = 1, .label = "Claude" });
            try std.testing.expect(host.callCommand("text.write", front_write, host.arena()) == .ok);
            host.endAct(outer);
            const taken = try editor.stepToTake(front, .undo, host.arena());
            try std.testing.expectEqualStrings("Claude", fizzy.Editor.authorName(taken.by));

            try editor.undo();
            try std.testing.expectEqualStrings(before, (try read(host, "")).text);
            const ds = editor.doc_surfaces.get(front.id) orelse return error.TestUnexpectedResult;
            const said = ds.feed.items[ds.feed.len - 1];
            try std.testing.expect(std.mem.startsWith(u8, said.title[0..said.len], "Undid Claude's "));
            const redo = said.action orelse return error.TestUnexpectedResult;
            try std.testing.expectEqual(taken.step.id, redo.tag);
            editor.redoFromFeed(front, redo.tag);
            try std.testing.expectEqualStrings("// by Claude\n", (try read(host, "")).text);
            try editor.undo();
            try std.testing.expectEqualStrings(before, (try read(host, "")).text);
        }

        // Going back is a step, and the jump is whoever went back's: Claude writes, the person
        // takes it back, Claude writes again. Claude's first write is still on the line, its
        // reverse is the person's, and Claude's new write is Claude's.
        {
            const front = editor.activeDoc() orelse return error.TestUnexpectedResult;
            const claude: sdk.Author = .{ .kind = .agent, .plugin = "test", .session = 2, .label = "Claude" };
            const first = try gpa.print(".{{ .path = \"{f}\", .text = \"// first\\n\" }}", .{std.zig.fmtString(main_zig)});
            defer gpa.free(first);
            const second = try gpa.print(".{{ .path = \"{f}\", .text = \"// second\\n\" }}", .{std.zig.fmtString(main_zig)});
            defer gpa.free(second);
            const before = try gpa.dupe(u8, (try read(host, "")).text);
            defer gpa.free(before);

            var outer = host.act(claude);
            try std.testing.expect(host.callCommand("text.write", first, host.arena()) == .ok);
            host.endAct(outer);
            const claudes = (try editor.stepToTake(front, .undo, host.arena())).step.id;
            outer = host.act(.person);
            try editor.undo();
            host.endAct(outer);
            try std.testing.expectEqualStrings(before, (try read(host, "")).text);
            outer = host.act(claude);
            try std.testing.expect(host.callCommand("text.write", second, host.arena()) == .ok);
            host.endAct(outer);

            const hist = front.owner.historyLine(front, host.arena()) orelse return error.TestUnexpectedResult;
            const top = hist.entries[hist.at - 1];
            const reverse = hist.entries[hist.at - 2];
            try std.testing.expectEqual(claudes, hist.entries[hist.at - 3].id);
            try std.testing.expect(std.mem.startsWith(u8, reverse.title, "Back to "));
            try std.testing.expectEqual(sdk.Author.Kind.person, host.stepAuthor(front.id, reverse.id).kind);
            try std.testing.expectEqualStrings("Claude", host.stepAuthor(front.id, top.id).label);
            try std.testing.expectEqualStrings("Claude", host.stepAuthor(front.id, claudes).label);
            // Claude's first write is still there to go to, and before it the text as it was.
            try std.testing.expect(front.owner.historyGoTo(front, claudes));
            try std.testing.expectEqualStrings("// first\n", (try read(host, "")).text);
            try std.testing.expect(front.owner.historyGoTo(front, hist.entries[hist.at - 4].id));
            try std.testing.expectEqualStrings(before, (try read(host, "")).text);
        }

        // "Go back to before Claude's change": to just before the first step of Claude's last
        // call, saying first when the person's steps are mixed in, and losing nothing.
        {
            const front = editor.activeDoc() orelse return error.TestUnexpectedResult;
            const claude: sdk.Author = .{ .kind = .agent, .plugin = "test", .session = 3, .label = "Claude" };
            const before = try gpa.dupe(u8, (try read(host, "")).text);
            defer gpa.free(before);
            const writeAs = struct {
                fn f(h: *sdk.Host, who: sdk.Author, path: []const u8, body: []const u8) !void {
                    const args = try h.arena().print(".{{ .path = \"{f}\", .text = \"{s}\" }}", .{ std.zig.fmtString(path), body });
                    const outer = h.act(who);
                    defer h.endAct(outer);
                    try std.testing.expect(h.callCommand("text.write", args, h.arena()) == .ok);
                }
            }.f;
            try writeAs(host, .person, main_zig, "// mine\\n");
            // One call of Claude's, two steps.
            {
                const outer = host.act(claude);
                defer host.endAct(outer);
                for ([_][]const u8{ "// claude one\\n", "// claude two\\n" }) |body| {
                    const args = try host.arena().print(".{{ .path = \"{f}\", .text = \"{s}\" }}", .{ std.zig.fmtString(main_zig), body });
                    try std.testing.expect(host.callCommand("text.write", args, host.arena()) == .ok);
                }
            }
            // Its activity says whose, and its bubble offers to go back.
            try std.testing.expect(host.activity.getLast().agent != null);
            var feed: @import("app").ActivityFeed = .{ .seen = host.activity_seq - 1 };
            feed.take(host, front.id, 0);
            try std.testing.expectEqual(@as(usize, 1), feed.len);
            const offered = feed.items[0].action orelse return error.TestUnexpectedResult;
            try std.testing.expectEqual(@import("app").ActivityFeed.Act.go_back, offered.act);

            const back = editor.backBefore(front, null, host.arena()) orelse return error.TestUnexpectedResult;
            try std.testing.expectEqualStrings("Claude", back.by.label);
            try std.testing.expectEqual(@as(usize, 0), back.yours);
            // The person writes after Claude's call: going back would take that too, and says so.
            try writeAs(host, .person, main_zig, "// mine again\\n");
            const mixed = editor.backBefore(front, @intCast(offered.tag), host.arena()) orelse return error.TestUnexpectedResult;
            try std.testing.expectEqual(@as(usize, 1), mixed.yours);
            try std.testing.expectEqual(back.to, mixed.to);

            const args = try host.arena().print(".{{ .path = \"{f}\" }}", .{std.zig.fmtString(main_zig)});
            const went = host.callCommand("fizzy.goBackBefore", args, host.arena());
            try std.testing.expect(went == .ok);
            try std.testing.expect(std.mem.find(u8, went.ok.?, ".also_taken_back = 1") != null);
            try std.testing.expectEqualStrings("// mine\n", (try read(host, "")).text);
            // Nothing lost: Claude's call and the person's edit are still on the line ahead.
            try std.testing.expect(front.owner.historyGoTo(front, mixed.from));
            try std.testing.expectEqualStrings("// mine again\n", (try read(host, "")).text);
            // Undone, a run is not offered.
            try std.testing.expect(front.owner.historyGoTo(front, back.to));
            try std.testing.expect(editor.backBefore(front, @intCast(offered.tag), host.arena()) == null);

            // Back to the text as it was, for what follows.
            const line = front.owner.historyLine(front, host.arena()) orelse return error.TestUnexpectedResult;
            const first_mine = for (line.entries, 0..) |e, k| {
                if (e.id == back.to) break k;
            } else return error.TestUnexpectedResult;
            try std.testing.expect(front.owner.historyGoTo(front, if (first_mine == 0) 0 else line.entries[first_mine - 1].id));
            try std.testing.expectEqualStrings(before, (try read(host, "")).text);
        }

        // Save and Close, the unsaved-changes dialog's: the same write Save makes, then the tab
        // closes once it lands.
        try std.testing.expect(doc.owner.isDirty(doc));
        try fizzy.Editor.Dialogs.UnsavedClose.saveAndClose(doc.id);
        for (0..50) |_| {
            _ = try dvui.testing.step(headlessFrame);
            if (editor.docFromPath(main_zig) == null) break;
        }
        try std.testing.expect(editor.docFromPath(main_zig) == null);
        const on_disk = try std.Io.Dir.cwd().readFileAlloc(dvui.io, main_zig, gpa, .limited(1024));
        defer gpa.free(on_disk);
        try std.testing.expectEqualStrings("// top\nconst a = 42;\nconst b = 3;\n", on_disk);

        // A save is a snapshot on the UI thread, then an encode and a write on a worker: an edit
        // made while it is in flight is not in the file, and leaves the document dirty.
        {
            const c_txt = try std.fs.path.join(gpa, &.{ project, "c.txt" });
            defer gpa.free(c_txt);
            try tmp.dir.writeFile(dvui.io, .{ .sub_path = "project/c.txt", .data = "" });
            _ = try editor.openFilePath(c_txt, editor.workbench.currentGroupingID());
            for (0..200) |_| {
                _ = try dvui.testing.step(headlessFrame);
                const d = editor.activeDoc() orelse continue;
                if (std.mem.eql(u8, d.owner.documentPath(d), c_txt)) break;
            }
            const c_doc = editor.activeDoc() orelse return error.TestUnexpectedResult;
            try std.testing.expect(host.callCommand("text.insert", ".{ .text = \"one\\n\", .line = 1 }", host.arena()) == .ok);
            try editor.save();
            try std.testing.expect(host.callCommand("text.insert", ".{ .text = \"two\\n\", .line = 2 }", host.arena()) == .ok);
            for (0..100) |_| {
                _ = try dvui.testing.step(headlessFrame);
                if (!editor.docSaving(c_doc)) break;
            }
            const written = try std.Io.Dir.cwd().readFileAlloc(dvui.io, c_txt, gpa, .limited(1024));
            defer gpa.free(written);
            try std.testing.expectEqualStrings("one\n", written);
            try std.testing.expect(c_doc.owner.isDirty(c_doc));
        }
    }

    // New File's editor takes the keyboard: what is typed next lands in it, no click first.
    {
        const host = &editor.app.host;
        try editor.app.host.runCommand("fizzy.newFile");
        for (0..200) |_| {
            _ = try dvui.testing.step(headlessFrame);
            const d = editor.activeDoc() orelse continue;
            if (std.mem.startsWith(u8, std.fs.path.basename(d.owner.documentPath(d)), "untitled")) break;
        }
        try dvui.testing.settle(headlessFrame);
        try dvui.testing.writeText("typed");
        try dvui.testing.settle(headlessFrame);
        const out = host.callCommand("text.read", "", host.arena());
        const zon = switch (out) {
            .ok => |r| r orelse return error.TestUnexpectedResult,
            else => return error.TestUnexpectedResult,
        };
        try std.testing.expect(std.mem.find(u8, zon, ".text = \"typed\"") != null);

        // A document a plugin holds (`sdk.Claim`) takes none of the person's input: what they
        // type waits, and so do the commands they run on it and its close, until the holder lets
        // go or they press Stop on its panes. The holder's own calls still reach it.
        const doc = editor.activeDoc() orelse return error.TestUnexpectedResult;
        const path = doc.owner.documentPath(doc);
        const docText = struct {
            fn docText(h: *sdk.Host) ![]const u8 {
                return switch (h.callCommand("text.read", "", h.arena())) {
                    .ok => |r| r orelse error.TestUnexpectedResult,
                    else => error.TestUnexpectedResult,
                };
            }
        }.docText;
        var holder_state: u8 = 0;
        const holder_vtable: sdk.Plugin.VTable = .{};
        var holder: sdk.Plugin = .{ .state = &holder_state, .vtable = &holder_vtable, .id = "holder", .display_name = "Holder" };
        const here = editor.workbench.open_workspace_grouping;
        // The claim shows the document beside the person's pane, as a room with space for two
        // does (`core.placement`); the pane here is narrower than that under a sidebar, so its
        // room is set to a desktop window's.
        const here_ws = editor.workbench.workspaces.getPtr(here) orelse return error.TestUnexpectedResult;
        const drawn_room = here_ws.pane_rect_physical;
        defer here_ws.pane_rect_physical = drawn_room;
        const room_scale = dvui.windowNaturalScale();
        here_ws.pane_rect_physical = .{ .x = 0, .y = 0, .w = 1200 * room_scale, .h = 800 * room_scale };
        const claim = try host.claimDocument(&holder, doc.id, "Holder");
        try std.testing.expectError(error.DocumentClaimed, host.claimDocument(editor.app.host.plugins.items[0], doc.id, "Other"));
        try dvui.testing.settle(headlessFrame);

        // It shows beside the person, who keeps the pane they were in (`Workbench.showBeside`).
        try std.testing.expectEqual(here, editor.workbench.open_workspace_grouping);
        const beside = for (editor.workbench.workspaces.values()) |ws| {
            if (ws.grouping != here) if (ws.active) |a| if (a.id == doc.id) break true;
        } else false;
        try std.testing.expect(beside);
        // The person goes to it there.
        editor.workbench.setActiveDocIndex(editor.app.open_files.getIndex(doc.id) orelse return error.TestUnexpectedResult);
        try dvui.testing.settle(headlessFrame);

        try dvui.testing.writeText("held");
        try dvui.testing.settle(headlessFrame);
        try std.testing.expect(std.mem.find(u8, try docText(host), ".text = \"typed\"") != null);
        // Its history aside: the person's undo always runs, and stops the holder (below).
        try std.testing.expectError(error.DocumentClaimed, editor.runActiveDocCommand("paste"));
        try editor.closeFileID(doc.id);
        try std.testing.expect(editor.docFromPath(path) != null);

        // The holder's own edit lands.
        try std.testing.expect(host.callCommand("text.insert", ".{ .text = \"!\", .line = 1 }", host.arena()) == .ok);
        try std.testing.expect(std.mem.find(u8, try docText(host), ".text = \"!typed\"") != null);

        // Who holds it is on its panes, with Stop, which a person (or a tape) presses.
        const stop_tag = try gpa.print("fizzy.claim.stop:{s}", .{path});
        defer gpa.free(stop_tag);
        var s: automation.Script = .init(gpa, "stop-claim", "");
        s.check = automation.Input.check;
        s.check.live = true;
        try s.click(.{ .tag = stop_tag }, .{});
        try editor.demo.live.play(try s.finish());
        for (0..200) |_| {
            if (!editor.demo.live.playing()) break;
            _ = try dvui.testing.step(headlessFrame);
        }
        try std.testing.expect(editor.demo.live.outcome.? == .finished);
        try std.testing.expect(!host.claimHolds(claim));
        try std.testing.expect(host.documentClaim(doc.id) == null);

        // Let go, the person's commands reach it again.
        try editor.undo();
        try dvui.testing.settle(headlessFrame);
        try std.testing.expect(std.mem.find(u8, try docText(host), ".text = \"typed\"") != null);
    }

    // Documents a command creates open beside the person (`Host.openBeside`), as an agent's
    // `pixi.create` does, into panes whose tabs have come and gone. Each pane's tab list is
    // rewritten from itself (`Workspace.addTab`), the crash of 2026-10-16 (`Layout.State.assign`).
    {
        const host = &editor.app.host;
        const here = editor.workbench.open_workspace_grouping;
        const grid: sdk.EditorAPI.NewDocGrid = .{ .column_width = 16, .row_height = 16 };
        var made: [4]u64 = undefined;
        for (&made, 0..) |*id, i| {
            const p = try gpa.print("{s}/beside-{d}.txt", .{ project, i });
            defer gpa.free(p);
            host.openBeside();
            defer host.endOpenBeside();
            const doc = try editor.newFile(p, grid);
            id.* = doc.id;
            try dvui.testing.settle(headlessFrame);
            try std.testing.expectEqual(here, editor.workbench.open_workspace_grouping);
            // Every other one goes again, leaving its pane's list shorter for the next.
            if (i % 2 == 1) try editor.closeFileID(made[i - 1]);
            try dvui.testing.settle(headlessFrame);
        }
        const last = editor.app.docById(made[made.len - 1]) orelse return error.TestUnexpectedResult;
        const beside = for (editor.workbench.workspaces.values()) |ws| {
            if (ws.grouping != here) if (ws.active) |a| if (a.id == last.id) break true;
        } else false;
        try std.testing.expect(beside);
    }

    // A document opened beside the person's goes where the shape of its room says
    // (`core.placement.place`): a new pane in a room with space for two, the person's own pane as
    // a card in one without, and the pane that is there already, whatever its size. The window
    // cannot be resized under a whole editor headlessly (the testing backend crashes), so the
    // room is the pane's own rect, set.
    {
        const wb = &editor.workbench;
        const here = wb.open_workspace_grouping;
        const ws = wb.workspaces.getPtr(here) orelse return error.TestUnexpectedResult;
        const drawn = ws.pane_rect_physical orelse return error.TestUnexpectedResult;
        defer ws.pane_rect_physical = drawn;
        const s = dvui.windowNaturalScale();
        const others = wb.workspaces.count() - 1;
        ws.pane_rect_physical = .{ .x = 0, .y = 0, .w = 1200 * s, .h = 800 * s };
        try std.testing.expect(wb.besideGrouping() != here);
        ws.pane_rect_physical = .{ .x = 0, .y = 0, .w = 820 * s, .h = 1180 * s };
        try std.testing.expect(wb.besideGrouping() != here);
        ws.pane_rect_physical = .{ .x = 0, .y = 0, .w = 390 * s, .h = 844 * s };
        // With another pane there, it takes the view; without, the person's own does.
        const taken = wb.besideGrouping();
        if (others > 0) try std.testing.expect(taken != here) else try std.testing.expectEqual(here, taken);
        // A pane that has not drawn is no place to send the view: it joins the person's pane.
        if (others > 0) {
            const other = for (wb.workspaces.values()) |*o| {
                if (o.grouping != here) break o;
            } else return error.TestUnexpectedResult;
            const other_rect = other.pane_rect_physical;
            defer other.pane_rect_physical = other_rect;
            other.pane_rect_physical = null;
            try std.testing.expectEqual(here, wb.besideGrouping());
        }
        // A demo's `drop:beside` is the answer for the place it is aimed at, not the person's pane's
        // for every place: Main's is the pane's edge in its own room, which turns with the room,
        // and a place that holds no documents has none.
        if (others == 0) {
            const Side = fizzy.core.widgets.DockLayout.Side;
            const main = (editor.regionFor(fizzy.sdk.keywords.ide.main) orelse return error.TestUnexpectedResult).name;
            const sidebar = (editor.regionFor(fizzy.sdk.keywords.ide.sidebar) orelse return error.TestUnexpectedResult).name;
            ws.pane_rect_physical = .{ .x = 0, .y = 0, .w = 1200 * s, .h = 800 * s };
            try std.testing.expectEqual(@as(?Side, .right), fizzy.Editor.Demo.besideEdge(&editor.demo, main));
            try std.testing.expectEqual(@as(?Side, null), fizzy.Editor.Demo.besideEdge(&editor.demo, sidebar));
            ws.pane_rect_physical = .{ .x = 0, .y = 0, .w = 820 * s, .h = 1180 * s };
            try std.testing.expectEqual(@as(?Side, .bottom), fizzy.Editor.Demo.besideEdge(&editor.demo, main));
            var pane_buf: [32]u8 = undefined;
            const pane = fizzy.Editor.Workspace.name(&pane_buf, here);
            try std.testing.expectEqual(@as(?Side, .bottom), fizzy.Editor.Demo.besideEdge(&editor.demo, pane));
            var other_buf: [32]u8 = undefined;
            try std.testing.expectEqual(@as(?Side, null), fizzy.Editor.Demo.besideEdge(&editor.demo, fizzy.Editor.Workspace.name(&other_buf, here + 1000)));
            try std.testing.expectEqual(@as(?Side, null), wb.besideEdge(here + 1000));
            ws.pane_rect_physical = .{ .x = 0, .y = 0, .w = 390 * s, .h = 844 * s };
        }
        try std.testing.expectEqual(fizzy.core.widgets.DockLayout.Side.right, workbench.Workbench.sideFor(1200, 800));
        try std.testing.expectEqual(fizzy.core.widgets.DockLayout.Side.bottom, workbench.Workbench.sideFor(820, 1180));
    }

    // A document's history as a line (`Plugin.historyLine`): each step keeps its id through
    // undo and redo, and going to one (`historyGoTo`) is so many undos or redos.
    {
        const host = &editor.app.host;
        const was = editor.activeDoc() orelse return error.TestUnexpectedResult;
        try host.runCommand("fizzy.newFile");
        for (0..200) |_| {
            _ = try dvui.testing.step(headlessFrame);
            const d = editor.activeDoc() orelse continue;
            if (d.id != was.id and std.mem.startsWith(u8, std.fs.path.basename(d.owner.documentPath(d)), "untitled")) break;
        }
        const doc = editor.activeDoc() orelse return error.TestUnexpectedResult;
        try std.testing.expect(doc.id != was.id);
        for ([_][]const u8{ "1", "2", "3" }) |digit| {
            const args = try host.arena().print(".{{ .text = \"{s}\", .line = 1 }}", .{digit});
            try std.testing.expect(host.callCommand("text.insert", args, host.arena()) == .ok);
        }
        const readText = struct {
            fn readText(h: *sdk.Host) ![]const u8 {
                const zon = switch (h.callCommand("text.read", "", h.arena())) {
                    .ok => |r| r orelse return error.TestUnexpectedResult,
                    else => return error.TestUnexpectedResult,
                };
                const at = std.mem.find(u8, zon, ".text = \"") orelse return error.TestUnexpectedResult;
                const rest = zon[at + ".text = \"".len ..];
                return rest[0 .. std.mem.findScalar(u8, rest, '"') orelse return error.TestUnexpectedResult];
            }
        }.readText;
        try std.testing.expectEqualStrings("321", try readText(host));

        const line = doc.owner.historyLine(doc, host.arena()) orelse return error.TestUnexpectedResult;
        try std.testing.expectEqual(@as(usize, 3), line.entries.len);
        try std.testing.expectEqual(@as(usize, 3), line.at);
        const steps = [_]u64{ line.entries[0].id, line.entries[1].id, line.entries[2].id };

        try std.testing.expect(doc.owner.historyGoTo(doc, steps[0]));
        try std.testing.expectEqualStrings("1", try readText(host));
        const back = doc.owner.historyLine(doc, host.arena()) orelse return error.TestUnexpectedResult;
        try std.testing.expect(back.version != line.version);
        try std.testing.expectEqual(@as(usize, 1), back.at);
        for (back.entries, steps) |e, id| try std.testing.expectEqual(id, e.id);

        try std.testing.expect(doc.owner.historyGoTo(doc, 0));
        try std.testing.expectEqualStrings("", try readText(host));
        try std.testing.expect(doc.owner.historyGoTo(doc, steps[2]));
        try std.testing.expectEqualStrings("321", try readText(host));

        // Gone again, and the document before it active, as what follows expects.
        try editor.rawCloseFileID(doc.id);
        editor.workbench.setActiveDocIndex(editor.app.open_files.getIndex(was.id) orelse return error.TestUnexpectedResult);
        try dvui.testing.settle(headlessFrame);
    }

    // A document's steps (`Host.recordStep`): while recorded, each change is reported as it
    // happens, forward, and played into a fresh document (`Plugin.applyStep`) they make the same
    // text. Typing runs join a step; an undo is its step reversed; nothing is encoded unrecorded.
    {
        const host = &editor.app.host;
        const was = editor.activeDoc() orelse return error.TestUnexpectedResult;
        const newDoc = struct {
            fn newDoc(ed: *fizzy.Editor, h: *sdk.Host, not: u64) !sdk.DocHandle {
                try h.runCommand("fizzy.newFile");
                for (0..200) |_| {
                    _ = try dvui.testing.step(headlessFrame);
                    const d = ed.activeDoc() orelse continue;
                    if (d.id != not and std.mem.startsWith(u8, std.fs.path.basename(d.owner.documentPath(d)), "untitled")) return d;
                }
                return error.TestUnexpectedResult;
            }
        }.newDoc;
        const textOf = struct {
            fn textOf(h: *sdk.Host, d: sdk.DocHandle) ![]const u8 {
                const args = try h.arena().print(".{{ .path = \"{f}\" }}", .{std.zig.fmtString(d.owner.documentPath(d))});
                const zon = switch (h.callCommand("text.read", args, h.arena())) {
                    .ok => |r| r orelse return error.TestUnexpectedResult,
                    else => return error.TestUnexpectedResult,
                };
                const at = std.mem.find(u8, zon, ".text = \"") orelse return error.TestUnexpectedResult;
                const rest = zon[at + ".text = \"".len ..];
                return rest[0 .. std.mem.findScalar(u8, rest, '"') orelse return error.TestUnexpectedResult];
            }
        }.textOf;
        const Recorded = struct {
            doc: u64 = 0,
            kinds: std.ArrayList(sdk.Step.Kind) = .empty,
            effects: std.ArrayList([]u8) = .empty,

            fn wants(ctx: *anyopaque, id: u64) bool {
                return @as(*@This(), @ptrCast(@alignCast(ctx))).doc == id;
            }
            fn step(ctx: *anyopaque, id: u64, st: sdk.Step) void {
                const self: *@This() = @ptrCast(@alignCast(ctx));
                std.debug.assert(id == self.doc);
                self.kinds.append(std.testing.allocator, st.kind) catch unreachable;
                self.effects.append(std.testing.allocator, std.testing.allocator.dupe(u8, st.effect) catch unreachable) catch unreachable;
            }
            fn deinit(self: *@This()) void {
                for (self.effects.items) |e| std.testing.allocator.free(e);
                self.effects.deinit(std.testing.allocator);
                self.kinds.deinit(std.testing.allocator);
            }
        };
        var rec: Recorded = .{};
        defer rec.deinit();
        host.recorder = .{ .ctx = &rec, .vtable = &.{ .wants = Recorded.wants, .step = Recorded.step } };
        defer host.recorder = null;

        const a = try newDoc(editor, host, was.id);
        rec.doc = a.id;
        // Typed a keystroke at a time: one step, joined. A crash checkpoint between them (one is
        // taken every few seconds of typing, by the wall clock: `Checkpoint`) is no save, so the
        // run stays open; taken here, it is between them however long a frame takes.
        for ([_][]const u8{ "a", "b" }, 0..) |key, i| {
            try dvui.testing.writeText(key);
            try dvui.testing.settle(headlessFrame);
            if (i == 0) {
                var kept = try fizzy.Editor.KeptDocuments.capture(editor, null);
                kept.deinit();
            }
        }
        try std.testing.expect(host.callCommand("text.insert", ".{ .text = \"X\", .line = 1 }", host.arena()) == .ok);
        try editor.undo();
        try editor.redo();
        try editor.undo();
        // An edit after going back: the step gone back over comes back on the line, then its
        // reverse, then the edit, so the text is as it was gone back to and nothing is lost.
        try std.testing.expect(host.callCommand("text.insert", ".{ .text = \"Y\", .line = 1 }", host.arena()) == .ok);
        try dvui.testing.settle(headlessFrame);
        try std.testing.expectEqualStrings("Yab", try textOf(host, a));
        try std.testing.expectEqualSlices(sdk.Step.Kind, &.{ .added, .joined, .added, .undone, .redone, .undone, .redone, .added, .added }, rec.kinds.items);

        // Played into a document of its own, forward, in order: the same text.
        const b = try newDoc(editor, host, a.id);
        try std.testing.expect(b.owner.step_format == a.owner.step_format and a.owner.step_format != 0);
        for (rec.effects.items) |effect| try std.testing.expect(b.owner.applyStep(b, effect, "", 0));
        try dvui.testing.settle(headlessFrame);
        try std.testing.expectEqualStrings("Yab", try textOf(host, b));
        // Unrecorded, B reported nothing; and a step that does not fit is refused, B untouched:
        // the undo takes back an `X` that is not there.
        try std.testing.expectEqual(@as(usize, 9), rec.kinds.items.len);
        // (Through the hook itself: the wrapper logs the refusal as an error, which fails a run.)
        try std.testing.expectError(error.StepDoesNotApply, b.owner.vtable.applyStep.?(b.owner.state, b, rec.effects.items[3], "", 0));
        try std.testing.expectEqualStrings("Yab", try textOf(host, b));

        // A save is an undo stop, made when its write lands (`documentWritten`): typing after it
        // is a step of its own, and undoing that step comes back to the saved, clean document.
        const c = try newDoc(editor, host, b.id);
        try dvui.testing.writeText("a");
        try dvui.testing.settle(headlessFrame);
        const bytes = (try c.owner.saveBytes(c, c.owner.documentPath(c), gpa)) orelse return error.TestUnexpectedResult;
        gpa.free(bytes);
        try c.owner.documentWritten(c, c.owner.documentPath(c));
        try std.testing.expect(!c.owner.isDirty(c));
        try dvui.testing.writeText("b");
        try dvui.testing.settle(headlessFrame);
        try editor.undo();
        try dvui.testing.settle(headlessFrame);
        try std.testing.expectEqualStrings("a", try textOf(host, c));
        try std.testing.expect(!c.owner.isDirty(c));

        // A checkpoint is no save (`Plugin.documentBytes`): with format on save on, it keeps the
        // text as typed and leaves the document alone; the save itself formats.
        const d = try newDoc(editor, host, c.id);
        {
            const Formatter = struct {
                fn supports(_: *anyopaque, _: []const u8) bool {
                    return true;
                }
                fn format(_: *anyopaque, _: []const u8, _: []const u8, _: []const u8) ?[]const u8 {
                    return "formatted";
                }
                const vtable: sdk.LanguageSupport.VTable = .{ .supportsFormat = supports, .format = format };
            };
            try host.registerLanguageSupport(.{ .id = "test-format", .vtable = &Formatter.vtable, .owner = &md_zig_plugin });
            defer _ = host.language_support.pop();
            const text_settings = &@import("text").statePtr().settings;
            text_settings.format_on_save.set(true);
            defer text_settings.format_on_save.set(false);
            try dvui.testing.writeText("as typed");
            try dvui.testing.settle(headlessFrame);
            {
                var kept = try fizzy.Editor.KeptDocuments.capture(editor, null);
                defer kept.deinit();
                const unsaved = for (kept.docs.items) |k| {
                    if (std.mem.eql(u8, k.path, d.owner.documentPath(d))) break k.unsaved orelse return error.TestUnexpectedResult;
                } else return error.TestUnexpectedResult;
                try std.testing.expectEqualStrings("as typed", unsaved);
            }
            try std.testing.expectEqualStrings("as typed", try textOf(host, d));
            const formatted = (try d.owner.saveBytes(d, d.owner.documentPath(d), gpa)) orelse return error.TestUnexpectedResult;
            defer gpa.free(formatted);
            try std.testing.expectEqualStrings("formatted", formatted);
            try d.owner.documentWritten(d, d.owner.documentPath(d));
            try dvui.testing.settle(headlessFrame);
        }

        // A checkpoint while a save's write is in flight leaves the save's edit as it was: the
        // write lands, and the keystroke typed after its snapshot is still unsaved.
        const e = try newDoc(editor, host, d.id);
        try dvui.testing.writeText("a");
        try dvui.testing.settle(headlessFrame);
        const in_flight = (try e.owner.saveBytes(e, e.owner.documentPath(e), gpa)) orelse return error.TestUnexpectedResult;
        defer gpa.free(in_flight);
        try dvui.testing.writeText("b");
        try dvui.testing.settle(headlessFrame);
        {
            var kept = try fizzy.Editor.KeptDocuments.capture(editor, null);
            kept.deinit();
        }
        try e.owner.documentWritten(e, e.owner.documentPath(e));
        try std.testing.expectEqualStrings("a", in_flight);
        try std.testing.expect(e.owner.isDirty(e));

        try editor.rawCloseFileID(e.id);
        try editor.rawCloseFileID(d.id);
        try editor.rawCloseFileID(c.id);
        try editor.rawCloseFileID(b.id);
        try editor.rawCloseFileID(a.id);
        editor.workbench.setActiveDocIndex(editor.app.open_files.getIndex(was.id) orelse return error.TestUnexpectedResult);
        try dvui.testing.settle(headlessFrame);
    }

    // Tracks (`app.Tracks`): with tracking on, an open document's steps are kept with their times,
    // beside its state when the track began and every so often since; any moment of the track
    // replays into another document. A replay target records nothing of it.
    {
        const host = &editor.app.host;
        const was = editor.activeDoc() orelse return error.TestUnexpectedResult;
        const newDoc = struct {
            fn newDoc(ed: *fizzy.Editor, h: *sdk.Host, not: u64) !sdk.DocHandle {
                try h.runCommand("fizzy.newFile");
                for (0..200) |_| {
                    _ = try dvui.testing.step(headlessFrame);
                    const d = ed.activeDoc() orelse continue;
                    if (d.id != not and std.mem.startsWith(u8, std.fs.path.basename(d.owner.documentPath(d)), "untitled")) return d;
                }
                return error.TestUnexpectedResult;
            }
        }.newDoc;
        const textOf = struct {
            fn textOf(h: *sdk.Host, d: sdk.DocHandle) ![]const u8 {
                const args = try h.arena().print(".{{ .path = \"{f}\" }}", .{std.zig.fmtString(d.owner.documentPath(d))});
                const zon = switch (h.callCommand("text.read", args, h.arena())) {
                    .ok => |r| r orelse return error.TestUnexpectedResult,
                    else => return error.TestUnexpectedResult,
                };
                const at = std.mem.find(u8, zon, ".text = \"") orelse return error.TestUnexpectedResult;
                const rest = zon[at + ".text = \"".len ..];
                return rest[0 .. std.mem.findScalar(u8, rest, '"') orelse return error.TestUnexpectedResult];
            }
        }.textOf;
        editor.setTracking(true);
        defer editor.setTracking(false);
        const tracks = &editor.app.tracks.?;

        const a = try newDoc(editor, host, was.id);
        try dvui.testing.settle(headlessFrame);
        for ([_][]const u8{ "a", "b" }) |key| {
            try dvui.testing.writeText(key);
            try dvui.testing.settle(headlessFrame);
        }
        // Enough steps for a checkpoint, then an undo.
        for (0..Tracks.checkpoint_steps + 44) |_| {
            try std.testing.expect(host.callCommand("text.insert", ".{ .text = \"x\", .line = 1 }", host.arena()) == .ok);
        }
        try editor.undo();
        try dvui.testing.settle(headlessFrame);
        const want = try std.testing.allocator.dupe(u8, try textOf(host, a));
        defer std.testing.allocator.free(want);
        try std.testing.expectEqual(Tracks.checkpoint_steps + 43 + 2, want.len);

        const track = tracks.trackOf(a.id) orelse return error.TestUnexpectedResult;
        const n = track.steps.items.len;
        try std.testing.expectEqual(@as(usize, 2 + Tracks.checkpoint_steps + 44 + 1), n);
        try std.testing.expect(track.base != null);
        try std.testing.expectEqual(@as(usize, 1), track.checkpoints.items.len);
        try std.testing.expectEqual(n, track.checkpoints.items[0].step);
        try std.testing.expectEqual(sdk.Step.Kind.undone, track.steps.items[n - 1].kind);
        for (track.steps.items[1..], track.steps.items[0 .. n - 1]) |later, earlier| try std.testing.expect(later.at >= earlier.at);
        try std.testing.expectEqual(a.id, tracks.focus.items[tracks.focus.items.len - 1].doc_id);

        // All of it, from the checkpoint, to the fingerprint it recorded; and the start of it,
        // from the base.
        const b = try newDoc(editor, host, a.id);
        try dvui.testing.settle(headlessFrame);
        try tracks.replayInto(a.id, b, n);
        try dvui.testing.settle(headlessFrame);
        try std.testing.expectEqualStrings(want, try textOf(host, b));
        try std.testing.expectEqual(a.owner.documentFingerprint(a), b.owner.documentFingerprint(b));
        try tracks.replayInto(a.id, b, 2);
        try dvui.testing.settle(headlessFrame);
        try std.testing.expectEqualStrings("ab", try textOf(host, b));
        // The target kept its own track, and recorded none of the replay.
        const tb = tracks.trackOf(b.id) orelse return error.TestUnexpectedResult;
        try std.testing.expectEqual(@as(usize, 0), tb.steps.items.len);

        // The history it recorded, put back into a document that stands where it ends
        // (`Tracks.historyOf`, `restoreHistory`): the same line, ids and all, that undoes to where
        // the track began and redoes to where it ended.
        {
            var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
            defer arena.deinit();
            const h = (try Tracks.historyOf(track, arena.allocator())) orelse return error.TestUnexpectedResult;
            const la = a.owner.historyLine(a, arena.allocator()) orelse return error.TestUnexpectedResult;
            try std.testing.expectEqual(la.entries.len, h.entries.len);
            try std.testing.expectEqual(la.at, h.applied);
            for (la.entries, h.entries) |x, y| try std.testing.expectEqual(x.id, y.id);
            // Typed, then inserted by command: not every entry reads alike.
            try std.testing.expectEqualStrings("Typing", la.entries[0].title);
            try std.testing.expectEqualStrings("Edit", la.entries[1].title);
            try tracks.replayInto(a.id, b, n);
            try dvui.testing.settle(headlessFrame);
            try std.testing.expectEqualStrings(want, try textOf(host, b));
            try std.testing.expect(b.owner.restoreHistory(b, h));
            const lb = b.owner.historyLine(b, arena.allocator()) orelse return error.TestUnexpectedResult;
            try std.testing.expectEqual(la.at, lb.at);
            // Each entry keeps its title, as the live line shows it.
            for (la.entries, lb.entries) |x, y| {
                try std.testing.expectEqual(x.id, y.id);
                try std.testing.expectEqualStrings(x.title, y.title);
            }
            try std.testing.expectEqualStrings(want, try textOf(host, b));
            try std.testing.expect(b.owner.historyGoTo(b, 0));
            try dvui.testing.settle(headlessFrame);
            try std.testing.expectEqualStrings("", try textOf(host, b));
            try std.testing.expect(b.owner.historyGoTo(b, la.entries[la.entries.len - 1].id));
            try dvui.testing.settle(headlessFrame);
            try std.testing.expectEqual(want.len + 1, (try textOf(host, b)).len);
            // A history that does not fit what the document holds is refused, and nothing moves:
            // back at the start, there is nothing for its applied entries to undo.
            try std.testing.expect(b.owner.historyGoTo(b, 0));
            try dvui.testing.settle(headlessFrame);
            const lb2 = b.owner.historyLine(b, arena.allocator()) orelse return error.TestUnexpectedResult;
            try std.testing.expectError(error.StepDoesNotApply, b.owner.vtable.restoreHistory.?(b.owner.state, b, .{ .entries = h.entries, .applied = h.applied }));
            const lb3 = b.owner.historyLine(b, arena.allocator()) orelse return error.TestUnexpectedResult;
            try std.testing.expectEqual(lb2.at, lb3.at);
            try std.testing.expectEqual(lb2.version, lb3.version);
        }

        // A frame nothing asked of does no tracks work: an idle app, recording, costs a branch.
        const worked = tracks.worked;
        for (0..120) |_| {
            dvui.refresh(null, @src(), null);
            _ = try dvui.testing.step(headlessFrame);
        }
        try std.testing.expectEqual(worked, tracks.worked);
        // What they hold, as devtools and an agent read it.
        const report = switch (host.callCommand("fizzy.tracks", "", host.arena())) {
            .ok => |r| r orelse return error.TestUnexpectedResult,
            else => return error.TestUnexpectedResult,
        };
        try std.testing.expect(std.mem.find(u8, report, ".on = true") != null);
        const steps_row = try host.arena().print(".steps = {d}", .{n});
        try std.testing.expect(std.mem.find(u8, report, steps_row) != null);

        // Closed, a document's track is kept for the session.
        try editor.rawCloseFileID(b.id);
        try editor.rawCloseFileID(a.id);
        try std.testing.expect(tracks.open.get(a.id) == null);
        try std.testing.expectEqual(track, tracks.trackOf(a.id).?);
        editor.workbench.setActiveDocIndex(editor.app.open_files.getIndex(was.id) orelse return error.TestUnexpectedResult);
        try dvui.testing.settle(headlessFrame);
    }

    // A closed document's track is kept in the profile and picked up when the document opens
    // again (`Tracks.keep`, `pickUp`, plan step 10): its history comes back, ids and all, and
    // undoes to where the track began. A file changed outside fizzy since starts a new one.
    {
        const host = &editor.app.host;
        const was = editor.activeDoc() orelse return error.TestUnexpectedResult;
        editor.setTracking(true);
        defer editor.setTracking(false);
        const tracks = &editor.app.tracks.?;
        const kept_path = try std.fs.path.join(gpa, &.{ root, "kept-history.txt" });
        defer gpa.free(kept_path);
        try tmp.dir.writeFile(dvui.io, .{ .sub_path = "kept-history.txt", .data = "" });
        const open = struct {
            fn open(ed: *fizzy.Editor, path: []const u8) !sdk.DocHandle {
                _ = try ed.openFilePath(path, ed.workbench.currentGroupingID());
                for (0..200) |_| {
                    _ = try dvui.testing.step(headlessFrame);
                    const d = ed.activeDoc() orelse continue;
                    if (std.mem.eql(u8, d.owner.documentPath(d), path)) return d;
                }
                return error.TestUnexpectedResult;
            }
        }.open;
        var arena: std.heap.ArenaAllocator = .init(gpa);
        defer arena.deinit();

        var doc = try open(editor, kept_path);
        try dvui.testing.settle(headlessFrame);
        for ([_][]const u8{ "a", "b", "c" }) |letter| {
            const args = try host.arena().print(".{{ .text = \"{s}\", .line = 1 }}", .{letter});
            try std.testing.expect(host.callCommand("text.insert", args, host.arena()) == .ok);
        }
        try editor.undo();
        try dvui.testing.settle(headlessFrame);
        try editor.save();
        for (0..100) |_| {
            _ = try dvui.testing.step(headlessFrame);
            if (!editor.docSaving(doc)) break;
        }
        const before = doc.owner.historyLine(doc, arena.allocator()) orelse return error.TestUnexpectedResult;
        const ids = try arena.allocator().alloc(u64, before.entries.len);
        for (before.entries, ids) |e, *id| id.* = e.id;
        const steps = (tracks.trackOf(doc.id) orelse return error.TestUnexpectedResult).steps.items.len;
        try std.testing.expectEqual(@as(usize, 3), ids.len);
        try std.testing.expectEqual(@as(usize, 2), before.at);
        try editor.rawCloseFileID(doc.id);
        try dvui.testing.settle(headlessFrame);

        // Opened again, saved: its file is where the track ended.
        doc = try open(editor, kept_path);
        try dvui.testing.settle(headlessFrame);
        const after = doc.owner.historyLine(doc, arena.allocator()) orelse return error.TestUnexpectedResult;
        try std.testing.expectEqual(before.at, after.at);
        try std.testing.expectEqual(ids.len, after.entries.len);
        for (ids, after.entries) |id, e| try std.testing.expectEqual(id, e.id);
        try std.testing.expectEqual(steps, (tracks.trackOf(doc.id) orelse return error.TestUnexpectedResult).steps.items.len);
        try std.testing.expect(!doc.owner.isDirty(doc));
        try std.testing.expect(doc.owner.historyGoTo(doc, 0));
        try dvui.testing.settle(headlessFrame);
        try std.testing.expect(doc.owner.historyGoTo(doc, ids[1]));
        try dvui.testing.settle(headlessFrame);
        try std.testing.expect(!doc.owner.isDirty(doc));
        try editor.rawCloseFileID(doc.id);
        try dvui.testing.settle(headlessFrame);

        // Changed outside fizzy: a new track, and no history.
        try tmp.dir.writeFile(dvui.io, .{ .sub_path = "kept-history.txt", .data = "changed elsewhere" });
        doc = try open(editor, kept_path);
        try dvui.testing.settle(headlessFrame);
        const fresh = doc.owner.historyLine(doc, arena.allocator()) orelse return error.TestUnexpectedResult;
        try std.testing.expectEqual(@as(usize, 0), fresh.entries.len);
        try std.testing.expectEqual(@as(usize, 0), (tracks.trackOf(doc.id) orelse return error.TestUnexpectedResult).steps.items.len);
        try editor.rawCloseFileID(doc.id);
        editor.workbench.setActiveDocIndex(editor.app.open_files.getIndex(was.id) orelse return error.TestUnexpectedResult);
        try dvui.testing.settle(headlessFrame);
    }

    // A restart keeps each open document's history with the session (`keepSessionForRestart`):
    // the new instance opens them, and takes their tracks up, while the old one is still running,
    // so a track kept only as the old one quits comes too late. An unsaved document comes back
    // dirty with its steps, and undo takes them back, by the person's Undo and by the command.
    {
        const host = &editor.app.host;
        const was = editor.activeDoc() orelse return error.TestUnexpectedResult;
        editor.setTracking(true);
        defer editor.setTracking(false);
        const tracks = &editor.app.tracks.?;
        const path = try std.fs.path.join(gpa, &.{ root, "restart-history.txt" });
        defer gpa.free(path);
        try tmp.dir.writeFile(dvui.io, .{ .sub_path = "restart-history.txt", .data = "" });
        _ = try editor.openFilePath(path, editor.workbench.currentGroupingID());
        var doc = for (0..200) |_| {
            _ = try dvui.testing.step(headlessFrame);
            const d = editor.activeDoc() orelse continue;
            if (std.mem.eql(u8, d.owner.documentPath(d), path)) break d;
        } else return error.TestUnexpectedResult;
        try dvui.testing.settle(headlessFrame);
        // An agent's edits, through the text plugin's commands: unsaved.
        for ([_][]const u8{ "a", "b", "c" }) |letter| {
            const args = try host.arena().print(".{{ .text = \"{s}\", .line = 1 }}", .{letter});
            try std.testing.expect(host.callCommand("text.insert", args, host.arena()) == .ok);
        }
        try dvui.testing.settle(headlessFrame);
        try std.testing.expect(doc.owner.isDirty(doc));
        const grouping = doc.owner.documentGrouping(doc);
        const dir = try fizzy.Editor.KeptDocuments.sessionDir(gpa, editor.app.config_folder);
        defer gpa.free(dir);
        try std.testing.expect(editor.keepSessionForRestart());
        // The old instance keeps nothing more: its quit comes after the new one is up.
        {
            const keep_dir = tracks.dir;
            tracks.dir = null;
            defer tracks.dir = keep_dir;
            editor.detachFileID(doc.id);
        }

        editor.session = fizzy.Editor.KeptDocuments.loadSession(gpa, dir) orelse return error.TestUnexpectedResult;
        defer {
            if (editor.session) |*kept| kept.deinit();
            editor.session = null;
        }
        _ = try host.openFile(.{ .path = path, .grouping = grouping });
        doc = editor.docFromPath(path) orelse return error.TestUnexpectedResult;
        try dvui.testing.settle(headlessFrame);
        try std.testing.expect(doc.owner.isDirty(doc));
        var arena: std.heap.ArenaAllocator = .init(gpa);
        defer arena.deinit();
        const line = doc.owner.historyLine(doc, arena.allocator()) orelse return error.TestUnexpectedResult;
        try std.testing.expectEqual(@as(usize, 3), line.entries.len);
        try std.testing.expectEqual(@as(usize, 3), line.at);
        const read = struct {
            fn read(h: *sdk.Host) ![]const u8 {
                return switch (h.callCommand("text.read", "", h.arena())) {
                    .ok => |r| r orelse error.TestUnexpectedResult,
                    else => error.TestUnexpectedResult,
                };
            }
        }.read;
        try std.testing.expect(std.mem.find(u8, try read(host), ".text = \"cba\"") != null);
        // The person's Undo (what mod+z runs), then the command, as an agent calls it.
        try editor.undo();
        try dvui.testing.settle(headlessFrame);
        try std.testing.expect(std.mem.find(u8, try read(host), ".text = \"ba\"") != null);
        try std.testing.expect(host.callCommand("fizzy.undo", "", host.arena()) == .ok);
        try dvui.testing.settle(headlessFrame);
        try std.testing.expect(std.mem.find(u8, try read(host), ".text = \"a\"") != null);
        try editor.rawCloseFileID(doc.id);
        editor.workbench.setActiveDocIndex(editor.app.open_files.getIndex(was.id) orelse return error.TestUnexpectedResult);
        try dvui.testing.settle(headlessFrame);
    }

    // A document never comes back dirty with nothing to undo. After a crash (`Checkpoint`), whose
    // checkpoint writes the tracks of unsaved documents with their states (`Tracks.takeChanged`),
    // and across a plugin's reload (`KeptDocuments.reattach`), it picks its history up as a
    // restart's does; with no track to pick up (history not recorded), its unsaved changes come
    // back as one step over its file (`Plugin.recoverDocumentState`), which undo takes back to it.
    {
        const host = &editor.app.host;
        const was = editor.activeDoc() orelse return error.TestUnexpectedResult;
        const text_plugin = host.pluginById("text") orelse return error.TestUnexpectedResult;
        // By path: a reload brings it back under a new id.
        const was_path = try gpa.dupe(u8, was.owner.documentPath(was));
        defer gpa.free(was_path);
        defer editor.setTracking(false);
        const path = try std.fs.path.join(gpa, &.{ root, "comes-back.txt" });
        defer gpa.free(path);
        try tmp.dir.writeFile(dvui.io, .{ .sub_path = "comes-back.txt", .data = "disk" });
        const read = struct {
            fn read(h: *sdk.Host) ![]const u8 {
                return switch (h.callCommand("text.read", "", h.arena())) {
                    .ok => |r| r orelse error.TestUnexpectedResult,
                    else => error.TestUnexpectedResult,
                };
            }
        }.read;
        var arena: std.heap.ArenaAllocator = .init(gpa);
        defer arena.deinit();
        for ([_]enum { crash, reload }{ .crash, .reload }) |how| for ([_]bool{ true, false }) |recorded| {
            editor.setTracking(recorded);
            _ = try editor.openFilePath(path, editor.workbench.currentGroupingID());
            var doc = for (0..200) |_| {
                _ = try dvui.testing.step(headlessFrame);
                const d = editor.activeDoc() orelse continue;
                if (std.mem.eql(u8, d.owner.documentPath(d), path)) break d;
            } else return error.TestUnexpectedResult;
            try dvui.testing.settle(headlessFrame);
            for ([_][]const u8{ "a", "b", "c" }) |letter| {
                const args = try host.arena().print(".{{ .text = \"{s}\", .line = 1 }}", .{letter});
                try std.testing.expect(host.callCommand("text.insert", args, host.arena()) == .ok);
            }
            try dvui.testing.settle(headlessFrame);
            try std.testing.expect(doc.owner.isDirty(doc));
            const grouping = doc.owner.documentGrouping(doc);
            const tracks = &editor.app.tracks.?;
            const keep_dir = tracks.dir;
            switch (how) {
                .crash => {
                    // A checkpoint, as the frame takes one (`Checkpoint.tick`): due now.
                    const cp = &editor.checkpoint;
                    const generation = cp.generation;
                    cp.last_ns = 0;
                    cp.looked_ns = 0;
                    for (0..400) |_| {
                        _ = try dvui.testing.step(headlessFrame);
                        if (cp.generation > generation and cp.job == null) break;
                    } else return error.TestUnexpectedResult;
                    // The crash: nothing more is kept as it goes.
                    tracks.dir = null;
                    editor.detachFileID(doc.id);
                    tracks.dir = keep_dir;
                    editor.session = fizzy.Editor.Checkpoint.recover(gpa, editor.app.config_folder, false) orelse return error.TestUnexpectedResult;
                    defer {
                        if (editor.session) |*kept| kept.deinit();
                        editor.session = null;
                    }
                    _ = try host.openFile(.{ .path = path, .grouping = grouping });
                },
                .reload => {
                    // All of a reload but the swap, as the reload test above does it.
                    var kept = try fizzy.Editor.KeptDocuments.capture(editor, text_plugin);
                    defer kept.deinit();
                    var owned: std.ArrayListUnmanaged(u64) = .empty;
                    defer owned.deinit(gpa);
                    for (editor.app.open_files.values()) |d| if (d.owner == text_plugin) try owned.append(gpa, d.id);
                    for (owned.items) |id| editor.detachFileID(id);
                    kept.reattach(editor, text_plugin);
                },
            }
            doc = editor.docFromPath(path) orelse return error.TestUnexpectedResult;
            editor.workbench.setActiveDocIndex(editor.app.open_files.getIndex(doc.id) orelse return error.TestUnexpectedResult);
            try dvui.testing.settle(headlessFrame);
            try std.testing.expect(doc.owner.isDirty(doc));
            try std.testing.expect(std.mem.find(u8, try read(host), ".text = \"cbadisk\"") != null);
            const line = doc.owner.historyLine(doc, arena.allocator()) orelse return error.TestUnexpectedResult;
            if (recorded) {
                // Its history, picked up: each letter undoes on its own.
                try std.testing.expectEqual(@as(usize, 3), line.entries.len);
                try std.testing.expectEqual(@as(usize, 3), line.at);
                try editor.undo();
                try dvui.testing.settle(headlessFrame);
                try std.testing.expect(std.mem.find(u8, try read(host), ".text = \"badisk\"") != null);
            } else {
                // One step over its file, and undo goes back to it: saved, nothing changed.
                try std.testing.expectEqual(@as(usize, 1), line.entries.len);
                try std.testing.expectEqualStrings("Recovered", line.entries[0].title);
                try editor.undo();
                try dvui.testing.settle(headlessFrame);
                try std.testing.expect(std.mem.find(u8, try read(host), ".text = \"disk\"") != null);
                try std.testing.expect(!doc.owner.isDirty(doc));
            }
            try editor.rawCloseFileID(doc.id);
            const back = editor.docFromPath(was_path) orelse return error.TestUnexpectedResult;
            editor.workbench.setActiveDocIndex(editor.app.open_files.getIndex(back.id) orelse return error.TestUnexpectedResult);
            try dvui.testing.settle(headlessFrame);
        };
    }

    // The person always wins: their Undo runs on a document an agent holds (`sdk.Claim`), and stops
    // the agent first (`Editor.stopClaim`), as Stop on its pill does. Another agent's undo there
    // is still refused while the claim holds.
    {
        const host = &editor.app.host;
        const was = editor.activeDoc() orelse return error.TestUnexpectedResult;
        const holder = host.pluginById("devtools") orelse return error.TestUnexpectedResult;
        const path = try std.fs.path.join(gpa, &.{ root, "held.txt" });
        defer gpa.free(path);
        try tmp.dir.writeFile(dvui.io, .{ .sub_path = "held.txt", .data = "" });
        _ = try editor.openFilePath(path, editor.workbench.currentGroupingID());
        const doc = for (0..200) |_| {
            _ = try dvui.testing.step(headlessFrame);
            const d = editor.activeDoc() orelse continue;
            if (std.mem.eql(u8, d.owner.documentPath(d), path)) break d;
        } else return error.TestUnexpectedResult;
        try dvui.testing.settle(headlessFrame);
        const claude: sdk.Author = .{ .kind = .agent, .plugin = "agent", .session = 1, .label = "Claude" };
        const claim = try host.claimDocument(holder, doc.id, "Claude");
        {
            const outer = host.act(claude);
            defer host.endAct(outer);
            try std.testing.expect(host.callCommand("text.insert", ".{ .text = \"drawn\", .line = 1 }", host.arena()) == .ok);
        }
        try dvui.testing.settle(headlessFrame);
        try std.testing.expect(doc.owner.isDirty(doc));
        // A held document shows beside the person (`showClaimed`): they go to it there.
        editor.workbench.setActiveDocIndex(editor.app.open_files.getIndex(doc.id) orelse return error.TestUnexpectedResult);
        try dvui.testing.settle(headlessFrame);
        // Another agent's undo waits for the holder, as every command of theirs does.
        {
            const outer = host.act(.{ .kind = .agent, .plugin = "agent", .session = 2, .label = "Other" });
            defer host.endAct(outer);
            editor.undo() catch {};
        }
        try std.testing.expect(host.claimHolds(claim));
        try std.testing.expect(std.mem.find(u8, host.callCommand("text.read", "", host.arena()).ok.?, ".text = \"drawn\"") != null);
        // The person's mod+z.
        host.setInputAuthor(.person);
        try editor.undo();
        host.setInputAuthor(null);
        try dvui.testing.settle(headlessFrame);
        try std.testing.expect(!host.claimHolds(claim));
        try std.testing.expect(!doc.owner.isDirty(doc));
        const out = host.callCommand("text.read", "", host.arena());
        try std.testing.expect(std.mem.find(u8, out.ok.?, ".text = \"\"") != null);
        try editor.rawCloseFileID(doc.id);
        editor.workbench.setActiveDocIndex(editor.app.open_files.getIndex(was.id) orelse return error.TestUnexpectedResult);
        try dvui.testing.settle(headlessFrame);
    }

    // Kept history keeps to its cap, takes the files of documents gone from disk, and a document's
    // can be forgotten outright (`Tracks.sweep`, `forget`, `fizzy.tracks.forget`).
    {
        const host = &editor.app.host;
        const was = editor.activeDoc() orelse return error.TestUnexpectedResult;
        editor.setTracking(true);
        defer editor.setTracking(false);
        const tracks = &editor.app.tracks.?;
        const open = struct {
            fn open(ed: *fizzy.Editor, path: []const u8) !sdk.DocHandle {
                _ = try ed.openFilePath(path, ed.workbench.currentGroupingID());
                for (0..200) |_| {
                    _ = try dvui.testing.step(headlessFrame);
                    const d = ed.activeDoc() orelse continue;
                    if (std.mem.eql(u8, d.owner.documentPath(d), path)) return d;
                }
                return error.TestUnexpectedResult;
            }
        }.open;
        // Edited, saved and closed: kept.
        const editSaveClose = struct {
            fn run(ed: *fizzy.Editor, h: *sdk.Host, path: []const u8, o: *const fn (*fizzy.Editor, []const u8) anyerror!sdk.DocHandle) !void {
                const d = try o(ed, path);
                try dvui.testing.settle(headlessFrame);
                try std.testing.expect(h.callCommand("text.insert", ".{ .text = \"kept\", .line = 1 }", h.arena()) == .ok);
                try ed.save();
                for (0..100) |_| {
                    _ = try dvui.testing.step(headlessFrame);
                    if (!ed.docSaving(d)) break;
                }
                try ed.rawCloseFileID(d.id);
                // Its history is packed and written by the checkpoint's thread.
                for (0..400) |_| {
                    _ = try dvui.testing.step(headlessFrame);
                    if (ed.app.tracks.?.pending.items.len == 0 and ed.checkpoint.job == null) break;
                } else return error.TestUnexpectedResult;
                try dvui.testing.settle(headlessFrame);
            }
        }.run;
        _ = tracks.forgetKept();
        try std.testing.expectEqual(@as(usize, 0), tracks.keptSize().files);

        // Forgotten: no history now, none kept, none when it opens again.
        const forget_path = try std.fs.path.join(gpa, &.{ root, "forget-me.txt" });
        defer gpa.free(forget_path);
        try tmp.dir.writeFile(dvui.io, .{ .sub_path = "forget-me.txt", .data = "" });
        try editSaveClose(editor, host, forget_path, open);
        try std.testing.expectEqual(@as(usize, 1), tracks.keptSize().files);
        var doc = try open(editor, forget_path);
        try dvui.testing.settle(headlessFrame);
        var arena: std.heap.ArenaAllocator = .init(gpa);
        defer arena.deinit();
        try std.testing.expectEqual(@as(usize, 1), (doc.owner.historyLine(doc, arena.allocator()) orelse return error.TestUnexpectedResult).entries.len);
        try std.testing.expect(host.callCommand("fizzy.tracks.forget", "", host.arena()) == .ok);
        try dvui.testing.settle(headlessFrame);
        try std.testing.expectEqual(@as(usize, 0), (doc.owner.historyLine(doc, arena.allocator()) orelse return error.TestUnexpectedResult).entries.len);
        try std.testing.expectEqual(@as(usize, 0), (tracks.trackOf(doc.id) orelse return error.TestUnexpectedResult).steps.items.len);
        try std.testing.expectEqual(@as(usize, 0), tracks.keptSize().files);
        try std.testing.expect(!doc.owner.isDirty(doc));
        try editor.rawCloseFileID(doc.id);
        try dvui.testing.settle(headlessFrame);
        doc = try open(editor, forget_path);
        try dvui.testing.settle(headlessFrame);
        try std.testing.expectEqual(@as(usize, 0), (doc.owner.historyLine(doc, arena.allocator()) orelse return error.TestUnexpectedResult).entries.len);
        try editor.rawCloseFileID(doc.id);
        try dvui.testing.settle(headlessFrame);

        // Past the cap, the oldest kept file goes; the newest stays.
        const older_path = try std.fs.path.join(gpa, &.{ root, "kept-older.txt" });
        defer gpa.free(older_path);
        const newer_path = try std.fs.path.join(gpa, &.{ root, "kept-newer.txt" });
        defer gpa.free(newer_path);
        try tmp.dir.writeFile(dvui.io, .{ .sub_path = "kept-older.txt", .data = "" });
        try tmp.dir.writeFile(dvui.io, .{ .sub_path = "kept-newer.txt", .data = "" });
        try editSaveClose(editor, host, older_path, open);
        const one = tracks.keptSize().bytes;
        try std.testing.expect(one > 0);
        try std.Io.sleep(dvui.io, .fromMilliseconds(20), .awake);
        const cap_was = editor.app.settings.kept_history_gb;
        editor.app.settings.kept_history_gb = @as(f32, @floatFromInt(one + one / 2)) / (1 << 30);
        try editSaveClose(editor, host, newer_path, open);
        editor.app.settings.kept_history_gb = cap_was;
        try std.testing.expectEqual(@as(usize, 1), tracks.keptSize().files);
        doc = try open(editor, newer_path);
        try dvui.testing.settle(headlessFrame);
        try std.testing.expectEqual(@as(usize, 1), (doc.owner.historyLine(doc, arena.allocator()) orelse return error.TestUnexpectedResult).entries.len);
        try editor.rawCloseFileID(doc.id);
        try dvui.testing.settle(headlessFrame);

        // Its document gone from disk, the first sweep of a session takes its file.
        try tmp.dir.deleteFile(dvui.io, "kept-newer.txt");
        tracks.swept_gone = false;
        tracks.sweep();
        try std.testing.expectEqual(@as(usize, 0), tracks.keptSize().files);
        editor.workbench.setActiveDocIndex(editor.app.open_files.getIndex(was.id) orelse return error.TestUnexpectedResult);
        try dvui.testing.settle(headlessFrame);
    }

    // A document's transport (`app.HistoryTransport`): undo shows it over the document's pane; a
    // press on its line goes to that step, its buttons step, a drag along it follows; and an undo
    // held down goes further each press.
    {
        const host = &editor.app.host;
        const was = editor.activeDoc() orelse return error.TestUnexpectedResult;
        try host.runCommand("fizzy.newFile");
        for (0..200) |_| {
            _ = try dvui.testing.step(headlessFrame);
            const d = editor.activeDoc() orelse continue;
            if (d.id != was.id and std.mem.startsWith(u8, std.fs.path.basename(d.owner.documentPath(d)), "untitled")) break;
        }
        const doc = editor.activeDoc() orelse return error.TestUnexpectedResult;
        try std.testing.expect(doc.id != was.id);
        const path = doc.owner.documentPath(doc);
        for (0..40) |_| try std.testing.expect(host.callCommand("text.insert", ".{ .text = \"x\", .line = 1 }", host.arena()) == .ok);
        try dvui.testing.settle(headlessFrame);
        const at = struct {
            fn at(h: *sdk.Host, d: sdk.DocHandle) !usize {
                return (d.owner.historyLine(d, h.arena()) orelse return error.TestUnexpectedResult).at;
            }
        }.at;
        const ds = editor.doc_surfaces.get(doc.id) orelse return error.TestUnexpectedResult;
        try std.testing.expectEqual(@as(f32, 0), ds.transport.shown.openness(dvui.frameTimeNS()));

        const ed_play = struct {
            fn play(ed: *fizzy.Editor, script: *automation.Script) !void {
                try ed.demo.live.play(try script.finish());
                for (0..300) |_| {
                    if (!ed.demo.live.playing()) break;
                    _ = try dvui.testing.step(headlessFrame);
                }
                try std.testing.expect(ed.demo.live.outcome.? == .finished);
            }
        }.play;
        // The pointer held on the grip (the bottom edge of the pane, in its middle) brings the bar
        // up; nothing else is pressed or moved.
        {
            const grip_tag = try gpa.print("history.grip:{s}", .{path});
            defer gpa.free(grip_tag);
            var s: automation.Script = .init(gpa, "transport-grip", "");
            s.check = automation.Input.check;
            s.check.live = true;
            try s.moveTo(.{ .tag = grip_tag }, .{});
            s.pause(200);
            try ed_play(editor, &s);
            // Passing over it is not enough: it waits for the pointer to stay.
            try std.testing.expectEqual(@as(f32, 0), ds.transport.shown.openness(dvui.frameTimeNS()));
            // Held there, it does. (A headless frame's time is its own: frames, not the tape's pause.)
            const held_from = dvui.frameTimeNS();
            while (ds.transport.shown.openness(dvui.frameTimeNS()) <= 0 and dvui.frameTimeNS() - held_from < 2 * std.time.ns_per_s)
                _ = try dvui.testing.step(headlessFrame);
            try std.testing.expect(dvui.frameTimeNS() - held_from >= 800 * std.time.ns_per_ms);
            try std.testing.expect(ds.transport.shown.openness(dvui.frameTimeNS()) > 0);
            try std.testing.expectEqual(@as(usize, 40), (doc.owner.historyLine(doc, host.arena()) orelse return error.TestUnexpectedResult).at);

            // Its tab sends it back into the grip, and the pointer resting on it after does not
            // bring it back.
            const tab_tag = try gpa.print("history.collapse:{s}", .{path});
            defer gpa.free(tab_tag);
            var fold: automation.Script = .init(gpa, "transport-collapse", "");
            fold.check = s.check;
            try fold.click(.{ .tag = tab_tag }, .{});
            try ed_play(editor, &fold);
            const folded_at = dvui.frameTimeNS();
            while (ds.transport.shown.openness(dvui.frameTimeNS()) > 0 and dvui.frameTimeNS() - folded_at < 2 * std.time.ns_per_s)
                _ = try dvui.testing.step(headlessFrame);
            try std.testing.expectEqual(@as(f32, 0), ds.transport.shown.openness(dvui.frameTimeNS()));
            for (0..20) |_| _ = try dvui.testing.step(headlessFrame);
            try std.testing.expectEqual(@as(f32, 0), ds.transport.shown.openness(dvui.frameTimeNS()));
            try std.testing.expectEqual(@as(usize, 40), (doc.owner.historyLine(doc, host.arena()) orelse return error.TestUnexpectedResult).at);

            // Held on the grip, the bar comes once; resting there after it goes, it stays gone.
            var rest: automation.Script = .init(gpa, "transport-grip-rest", "");
            rest.check = s.check;
            try rest.moveTo(.{ .tag = grip_tag }, .{});
            try ed_play(editor, &rest);
            const rest_from = dvui.frameTimeNS();
            while (ds.transport.shown.openness(dvui.frameTimeNS()) <= 0 and dvui.frameTimeNS() - rest_from < 3 * std.time.ns_per_s)
                _ = try dvui.testing.step(headlessFrame);
            try std.testing.expect(ds.transport.shown.openness(dvui.frameTimeNS()) > 0);
            const up_at = dvui.frameTimeNS();
            while (ds.transport.shown.openness(dvui.frameTimeNS()) > 0 and dvui.frameTimeNS() - up_at < 8 * std.time.ns_per_s)
                _ = try dvui.testing.step(headlessFrame);
            try std.testing.expectEqual(@as(f32, 0), ds.transport.shown.openness(dvui.frameTimeNS()));
            const gone_at = dvui.frameTimeNS();
            while (dvui.frameTimeNS() - gone_at < 2 * std.time.ns_per_s) {
                _ = try dvui.testing.step(headlessFrame);
                try std.testing.expectEqual(@as(f32, 0), ds.transport.shown.openness(dvui.frameTimeNS()));
            }
        }

        try editor.undo();
        for (0..4) |_| _ = try dvui.testing.step(headlessFrame);
        try std.testing.expect(ds.transport.shown.openness(dvui.frameTimeNS()) > 0);
        try std.testing.expectEqual(@as(usize, 39), try at(host, doc));

        const play = struct {
            fn play(ed: *fizzy.Editor, script: *automation.Script) !void {
                try ed.demo.live.play(try script.finish());
                for (0..300) |_| {
                    if (!ed.demo.live.playing()) break;
                    _ = try dvui.testing.step(headlessFrame);
                }
                try std.testing.expect(ed.demo.live.outcome.? == .finished);
            }
        }.play;
        const line_tag = try gpa.print("history.line:{s}", .{path});
        defer gpa.free(line_tag);
        const forward_tag = try gpa.print("history.forward:{s}", .{path});
        defer gpa.free(forward_tag);
        {
            // A press on the title, over the line's start, is the bar's and goes nowhere.
            var s: automation.Script = .init(gpa, "transport-title", "");
            s.check = automation.Input.check;
            s.check.live = true;
            try s.click(.{ .tag = line_tag, .x = 0, .y = 0.15 }, .{});
            try play(editor, &s);
        }
        try std.testing.expectEqual(@as(usize, 39), try at(host, doc));
        {
            // The line's start: before any change.
            var s: automation.Script = .init(gpa, "transport-start", "");
            s.check = automation.Input.check;
            s.check.live = true;
            try s.click(.{ .tag = line_tag, .x = 0 }, .{});
            try play(editor, &s);
        }
        try std.testing.expectEqual(@as(usize, 0), try at(host, doc));
        {
            // The knob's stop 0 is the line's very start: the end cell is half a stop wide
            // (40 stops: 1/80 of the line), so a press at 2/100 across is stop 1, not 0.
            var s: automation.Script = .init(gpa, "transport-first-stop", "");
            s.check = automation.Input.check;
            s.check.live = true;
            try s.click(.{ .tag = line_tag, .x = 0.02 }, .{});
            try play(editor, &s);
        }
        try std.testing.expectEqual(@as(usize, 1), try at(host, doc));
        {
            var s: automation.Script = .init(gpa, "transport-start-again", "");
            s.check = automation.Input.check;
            s.check.live = true;
            try s.click(.{ .tag = line_tag, .x = 0 }, .{});
            try play(editor, &s);
        }
        try std.testing.expectEqual(@as(usize, 0), try at(host, doc));
        {
            // Redo: one step on.
            var s: automation.Script = .init(gpa, "transport-forward", "");
            s.check = automation.Input.check;
            s.check.live = true;
            try s.click(.{ .tag = forward_tag }, .{});
            try play(editor, &s);
        }
        try std.testing.expectEqual(@as(usize, 1), try at(host, doc));
        {
            // A drag from the start to the end follows the pointer there.
            var s: automation.Script = .init(gpa, "transport-drag", "");
            s.check = automation.Input.check;
            s.check.live = true;
            try s.drag(.{ .tag = line_tag, .x = 0 }, .{ .tag = line_tag, .x = 1 }, .{});
            try play(editor, &s);
        }
        try std.testing.expectEqual(@as(usize, 40), try at(host, doc));

        // Held down, ten presses in a frame: one step each for six, then two each.
        for (0..10) |_| try editor.undo();
        try std.testing.expectEqual(@as(usize, 40 - 14), try at(host, doc));

        try editor.rawCloseFileID(doc.id);
        editor.workbench.setActiveDocIndex(editor.app.open_files.getIndex(was.id) orelse return error.TestUnexpectedResult);
        try dvui.testing.settle(headlessFrame);
    }

    // A document's track as a tape (`fizzy.tracks.export`): its file as the track began, then its
    // steps; the person's document and history as they were; played (`Demo.playTape`), it makes
    // the same text in a document of its own.
    {
        const host = &editor.app.host;
        const was = editor.activeDoc() orelse return error.TestUnexpectedResult;
        editor.setTracking(true);
        defer editor.setTracking(false);
        try host.runCommand("fizzy.newFile");
        for (0..200) |_| {
            _ = try dvui.testing.step(headlessFrame);
            const d = editor.activeDoc() orelse continue;
            if (d.id != was.id and std.mem.startsWith(u8, std.fs.path.basename(d.owner.documentPath(d)), "untitled")) break;
        }
        const doc = editor.activeDoc() orelse return error.TestUnexpectedResult;
        try std.testing.expect(doc.id != was.id);
        try dvui.testing.settle(headlessFrame);
        for ([_][]const u8{ "one", "two", "three", "four", "five" }) |word| {
            const args = try host.arena().print(".{{ .text = \"{s}\\n\", .line = 1 }}", .{word});
            try std.testing.expect(host.callCommand("text.insert", args, host.arena()) == .ok);
        }
        try editor.undo();
        try dvui.testing.settle(headlessFrame);
        const textOf = struct {
            fn textOf(h: *sdk.Host, path: []const u8) ![]const u8 {
                const args = try h.arena().print(".{{ .path = \"{f}\" }}", .{std.zig.fmtString(path)});
                const zon = switch (h.callCommand("text.read", args, h.arena())) {
                    .ok => |r| r orelse return error.TestUnexpectedResult,
                    else => return error.TestUnexpectedResult,
                };
                const at = std.mem.find(u8, zon, ".text = \"") orelse return error.TestUnexpectedResult;
                const rest = zon[at + ".text = \"".len ..];
                return rest[0 .. std.mem.findScalar(u8, rest, '"') orelse return error.TestUnexpectedResult];
            }
        }.textOf;
        const path = doc.owner.documentPath(doc);
        const want = try gpa.dupe(u8, try textOf(host, path));
        defer gpa.free(want);
        const line_before = (doc.owner.historyLine(doc, host.arena()) orelse return error.TestUnexpectedResult);

        const out = try gpa.print("{s}/tapes/export-test.tape", .{editor.app.config_folder});
        defer gpa.free(out);
        const args = try host.arena().print(".{{ .path = \"{f}\", .out = \"{f}\" }}", .{ std.zig.fmtString(path), std.zig.fmtString(out) });
        const result = switch (host.callCommand("fizzy.tracks.export", args, host.arena())) {
            .ok => |r| r orelse return error.TestUnexpectedResult,
            else => |r| {
                std.debug.print("export: {any}\n", .{r});
                return error.TestUnexpectedResult;
            },
        };
        try std.testing.expect(std.mem.find(u8, result, ".steps = 6") != null);
        // A range (`from`): the tape opens on the document as it was after two steps, and holds
        // the four after; its summary names whose they are.
        {
            const ranged = try gpa.print("{s}/tapes/export-range.tape", .{editor.app.config_folder});
            defer gpa.free(ranged);
            const range_args = try host.arena().print(".{{ .path = \"{f}\", .out = \"{f}\", .from = 2 }}", .{ std.zig.fmtString(path), std.zig.fmtString(ranged) });
            const range_result = switch (host.callCommand("fizzy.tracks.export", range_args, host.arena())) {
                .ok => |r| r orelse return error.TestUnexpectedResult,
                else => return error.TestUnexpectedResult,
            };
            try std.testing.expect(std.mem.find(u8, range_result, ".steps = 4") != null);
            // One author, named (a command run with no one acting is nobody known).
            try std.testing.expect(std.mem.find(u8, range_result, ".authors = .{\"unattributed\"}") != null);
            const range_bytes = try std.Io.Dir.cwd().readFileAlloc(dvui.io, ranged, gpa, .limited(1 << 20));
            defer gpa.free(range_bytes);
            var range_check = app.automation.Input.check;
            range_check.steps = fizzy.Editor.Demo.stepsCheck;
            var range_tape = try app.automation.Tape.load(gpa, range_bytes, range_check);
            defer range_tape.deinit();
            try std.testing.expectEqualStrings("two\none\n", range_tape.tape.keyframes[0].files[0].text);
            var range_steps: usize = 0;
            for (range_tape.tape.ops) |op| range_steps += @intFromBool(op.do == .step);
            try std.testing.expectEqual(@as(usize, 4), range_steps);
            // The person's document is where it was.
            try std.testing.expectEqualStrings(want, try textOf(host, path));
        }
        // The person's document is where it was, its history too.
        try std.testing.expectEqualStrings(want, try textOf(host, path));
        const line_after = (doc.owner.historyLine(doc, host.arena()) orelse return error.TestUnexpectedResult);
        try std.testing.expectEqual(line_before.at, line_after.at);
        try std.testing.expectEqual(line_before.entries.len, line_after.entries.len);

        const bytes = try std.Io.Dir.cwd().readFileAlloc(dvui.io, out, gpa, .limited(1 << 20));
        defer gpa.free(bytes);
        // What it holds: fizzy reads it (its owner and format known), its keyframe is the file as
        // the track began (a new document's: empty).
        var check = app.automation.Input.check;
        check.steps = fizzy.Editor.Demo.stepsCheck;
        var owned = try app.automation.Tape.load(gpa, bytes, check);
        defer owned.deinit();
        const kf = owned.tape.keyframes[0];
        try std.testing.expectEqual(@as(usize, 1), kf.files.len);
        try std.testing.expectEqualStrings("text", kf.files[0].owner);
        try std.testing.expectEqualStrings("", kf.files[0].text);
        // Played in a tab of its own (`TapeTabs`, the transport's share), each step at its moment:
        // the same text, under the tape's own mount, with the person's documents untouched.
        // A tape naming a plugin that is not loaded is not played: natively nothing is fetched,
        // and it says which plugin it needs rather than open a document no owner can step.
        {
            var tape_check = app.automation.Input.check;
            tape_check.steps = fizzy.Editor.Demo.stepsCheck;
            var loaded = try app.automation.Tape.load(gpa, bytes, tape_check);
            defer loaded.deinit();
            const files = try host.arena().dupe(app.automation.Tape.File, loaded.tape.keyframes[0].files);
            files[0].owner = "no-such-plugin";
            const keyframes = try host.arena().dupe(app.automation.Tape.Keyframe, loaded.tape.keyframes);
            keyframes[0].files = files;
            var orphan_tape = loaded.tape;
            orphan_tape.keyframes = keyframes;
            const orphan = try app.automation.binary.encode(gpa, orphan_tape, .{});
            defer gpa.free(orphan);
            const docs_before = editor.app.open_files.count();
            try editor.tape_tabs.openWhenReady(editor, orphan, false);
            try dvui.testing.settle(headlessFrame);
            try std.testing.expect(editor.tape_tabs.waiting == null);
            try std.testing.expectEqual(docs_before, editor.app.open_files.count());
        }
        // Its plugin loaded, a tape plays at the next frame's top (`openWhenReady`), as
        // `Demo: Play a Tape…` and a page's `?tape=` both open one.
        try editor.tape_tabs.openWhenReady(editor, bytes, false);
        const played_path = try gpa.print("tape://1/{s}", .{std.fs.path.basename(path)});
        defer gpa.free(played_path);
        for (0..2000) |_| {
            _ = try dvui.testing.step(headlessFrame);
            if (!editor.tape_tabs.isPlaying(played_path)) break;
            std.Io.sleep(dvui.io, .fromMilliseconds(5), .awake) catch {};
        }
        const replay = editor.docFromPath(played_path) orelse return error.TestUnexpectedResult;
        try std.testing.expect(!editor.tape_tabs.isPlaying(played_path));
        try dvui.testing.settle(headlessFrame);
        try std.testing.expectEqualStrings(want, try textOf(host, played_path));
        try std.testing.expectEqualStrings(want, try textOf(host, path));
        const played_line = replay.owner.historyLine(replay, host.arena()) orelse return error.TestUnexpectedResult;
        try std.testing.expectEqual(@as(usize, 6), played_line.at);
        // Played out, it is kept as played in its own mount: closing it asks nothing.
        for (0..200) |_| {
            if (!replay.owner.isDirty(replay)) break;
            _ = try dvui.testing.step(headlessFrame);
        }
        try std.testing.expect(!replay.owner.isDirty(replay));
        try editor.closeFileID(replay.id);
        try dvui.testing.settle(headlessFrame);
        try std.testing.expect(editor.docFromPath(played_path) == null);
        try std.testing.expectEqual(@as(usize, 0), editor.tape_tabs.playing.items.len);

        // The strip's export window (pressed: `share_pending`), at the top of the next frame:
        // stops 2 to 5 of a line of five entries with the last undone. The tape kept holds what
        // the strip shows: the document after two entries, then the steps that made the next
        // three, the undone one too; the person's document and its history are where they were.
        {
            const tracks = &editor.app.tracks.?;
            const line = doc.owner.historyLine(doc, host.arena()) orelse return error.TestUnexpectedResult;
            try std.testing.expectEqual(@as(usize, 5), line.entries.len);
            try std.testing.expectEqual(@as(usize, 4), line.at);
            const sum = tracks.lineSummary(host, doc, host.arena(), line, 2, 5) orelse return error.TestUnexpectedResult;
            try std.testing.expectEqual(@as(usize, 3), sum.steps);
        }
        const tapes_dir = try std.fs.path.join(gpa, &.{ editor.app.config_folder, "tapes" });
        defer gpa.free(tapes_dir);
        var keep_state: std.heap.ArenaAllocator = .init(gpa);
        defer keep_state.deinit();
        const keep = keep_state.allocator();
        const listing = struct {
            fn names(a: std.mem.Allocator, dir_path: []const u8) ![]const []const u8 {
                var dir = try std.Io.Dir.cwd().openDir(dvui.io, dir_path, .{ .iterate = true });
                defer dir.close(dvui.io);
                var it = dir.iterate();
                var found: std.ArrayListUnmanaged([]const u8) = .empty;
                while (try it.next(dvui.io)) |e| try found.append(a, try a.dupe(u8, e.name));
                return found.items;
            }
        }.names;
        const before = try listing(keep, tapes_dir);
        editor.share_pending = .{ .doc_id = doc.id, .from = 2, .to = 5 };
        try dvui.testing.settle(headlessFrame);
        const after = try listing(keep, tapes_dir);
        try std.testing.expectEqual(before.len + 1, after.len);
        const fresh = for (after) |name| {
            for (before) |b| {
                if (std.mem.eql(u8, b, name)) break;
            } else break name;
        } else return error.TestUnexpectedResult;
        {
            const kept_path = try std.fs.path.join(keep, &.{ tapes_dir, fresh });
            const kept = try std.Io.Dir.cwd().readFileAlloc(dvui.io, kept_path, gpa, .limited(1 << 20));
            defer gpa.free(kept);
            var kept_check = app.automation.Input.check;
            kept_check.steps = fizzy.Editor.Demo.stepsCheck;
            var kept_tape = try app.automation.Tape.load(gpa, kept, kept_check);
            defer kept_tape.deinit();
            try std.testing.expectEqualStrings("two\none\n", kept_tape.tape.keyframes[0].files[0].text);
            var kept_steps: usize = 0;
            for (kept_tape.tape.ops) |op| kept_steps += @intFromBool(op.do == .step);
            try std.testing.expectEqual(@as(usize, 3), kept_steps);
        }
        try std.testing.expectEqualStrings(want, try textOf(host, path));
        try std.testing.expectEqual(@as(usize, 4), (doc.owner.historyLine(doc, host.arena()) orelse return error.TestUnexpectedResult).at);

        try editor.rawCloseFileID(doc.id);

        // A track whose start was undone past and edited over still exports: going back is a
        // step, so its start is still on the line. The document is left as it was.
        editor.setTracking(false);
        try host.runCommand("fizzy.newFile");
        for (0..200) |_| {
            _ = try dvui.testing.step(headlessFrame);
            const d = editor.activeDoc() orelse continue;
            if (d.id != doc.id and d.id != was.id and std.mem.startsWith(u8, std.fs.path.basename(d.owner.documentPath(d)), "untitled")) break;
        }
        const gone = editor.activeDoc() orelse return error.TestUnexpectedResult;
        for ([_][]const u8{ "a", "b" }) |word| {
            const insert = try host.arena().print(".{{ .text = \"{s}\\n\", .line = 1 }}", .{word});
            try std.testing.expect(host.callCommand("text.insert", insert, host.arena()) == .ok);
        }
        editor.setTracking(true);
        try dvui.testing.settle(headlessFrame);
        try editor.undo();
        try editor.undo();
        try std.testing.expect(host.callCommand("text.insert", ".{ .text = \"c\\n\", .line = 1 }", host.arena()) == .ok);
        const gone_path = gone.owner.documentPath(gone);
        const before_text = try gpa.dupe(u8, try textOf(host, gone_path));
        defer gpa.free(before_text);
        const gone_args = try host.arena().print(".{{ .path = \"{f}\", .out = \"{f}\" }}", .{ std.zig.fmtString(gone_path), std.zig.fmtString(out) });
        try std.testing.expect(host.callCommand("fizzy.tracks.export", gone_args, host.arena()) == .ok);
        try std.testing.expectEqualStrings(before_text, try textOf(host, gone_path));
        try editor.rawCloseFileID(gone.id);
        editor.workbench.setActiveDocIndex(editor.app.open_files.getIndex(was.id) orelse return error.TestUnexpectedResult);
        try dvui.testing.settle(headlessFrame);
    }

    // Recording follows its setting (`record_history`, on by default) each time it changes, a
    // command's say (`setTracking`, as the tests above used) holding until then: turned off,
    // nothing is recorded and what was is forgotten; turned on, every open document gets a track.
    {
        const tracks = &editor.app.tracks.?;
        try std.testing.expect(editor.app.settings.record_history);
        editor.setTracking(true);
        try dvui.testing.settle(headlessFrame);
        try std.testing.expect(tracks.open.count() > 0);
        editor.app.settings.record_history = false;
        try dvui.testing.settle(headlessFrame);
        try std.testing.expect(!tracks.on and editor.app.host.recorder == null);
        try std.testing.expectEqual(@as(usize, 0), tracks.open.count());
        editor.app.settings.record_history = true;
        try dvui.testing.settle(headlessFrame);
        try std.testing.expect(tracks.on and editor.app.host.recorder != null);
        try std.testing.expectEqual(editor.app.open_files.count(), tracks.open.count());
    }

    // Revealing a view (`Host.revealSurface`): with the bottom panel shut, revealing Output opens
    // the panel with Output selected, and a view no region shows is not revealed.
    {
        const panel = editor.regionFor(sdk.keywords.ide.panel) orelse return error.TestUnexpectedResult;
        panel.close();
        try dvui.testing.settle(headlessFrame);
        try std.testing.expect(panel.isClosed());
        try std.testing.expect(editor.app.host.revealSurface("fizzy.output"));
        try std.testing.expect(!panel.isClosed());
        try std.testing.expectEqualStrings("fizzy.output", editor.app.host.selectionFor(sdk.keywords.ide.panel) orelse "");
        try std.testing.expect(!editor.app.host.revealSurface("nothing.here"));
        try dvui.testing.settle(headlessFrame);
    }

    // The dashboard (`devtools`): Show Profiler reveals it in the bottom panel, where it records
    // while drawn, and `devtools.stats` answers the plugins and the profiler's report as ZON.
    {
        const host = &editor.app.host;
        try std.testing.expect(host.callCommand("devtools.show", "", host.arena()) == .ok);
        // A few frames, not a settle: a live dashboard keeps asking for them.
        for (0..4) |_| _ = try dvui.testing.step(headlessFrame);
        try std.testing.expectEqualStrings("devtools.dashboard", host.selectionFor(sdk.keywords.ide.panel) orelse "");
        try std.testing.expect((fizzy.core.profile.current() orelse return error.TestUnexpectedResult).enabled);
        const zon = switch (host.callCommand("devtools.stats", ".{ .hitches = 1 }", host.arena())) {
            .ok => |r| r orelse return error.TestUnexpectedResult,
            else => return error.TestUnexpectedResult,
        };
        const Stats = struct {
            plugins: []const struct { id: []const u8, link: sdk.services.plugins.Api.Link },
            // The report as the profiler has it; its averages fill in once a half-second window
            // has passed on screen, which a few test frames are not.
            profile: struct { frame: struct { fps: f64 } },
        };
        var stats_diag: std.zon.parse.Diagnostics = undefined;
        const stats = try std.zon.parse.fromSlice(Stats, .{ .gpa = host.arena(), .arena = host.arena(), .source = try host.arena().dupeSentinel(u8, zon, 0), .diagnostics = &stats_diag, .ignore_unknown_fields = true });
        try std.testing.expect(for (stats.plugins) |pl| {
            if (std.mem.eql(u8, pl.id, "devtools")) break pl.link == .bundled;
        } else false);
        // Off screen again, it stops recording the frame after.
        _ = host.revealSurface("fizzy.output");
        try dvui.testing.settle(headlessFrame);
        try std.testing.expect(!(fizzy.core.profile.current() orelse return error.TestUnexpectedResult).enabled);
    }

    // The dashboard plugin's Needs-you carousel, over the demo provider of three cards: it draws one
    // card at a time, and a card the person answers leaves the count.
    {
        const host = &editor.app.host;
        const Status = struct { count: usize, index: usize, drawn: usize };
        const Reader = struct {
            fn read(h: *sdk.Host) !Status {
                const zon = switch (h.callCommand("dashboard.status", "", h.arena())) {
                    .ok => |r| r orelse return error.TestUnexpectedResult,
                    else => return error.TestUnexpectedResult,
                };
                var diag: std.zon.parse.Diagnostics = undefined;
                return std.zon.parse.fromSlice(Status, .{ .gpa = h.arena(), .arena = h.arena(), .source = try h.arena().dupeSentinel(u8, zon, 0), .diagnostics = &diag });
            }
        };
        try std.testing.expect(host.callCommand("dashboard.show", "", host.arena()) == .ok);
        for (0..4) |_| _ = try dvui.testing.step(headlessFrame);
        try std.testing.expectEqualStrings("dashboard.view", host.selectionFor(sdk.keywords.ide.sidebar) orelse "");
        const cards = @import("dashboard").View.provider(host);
        const before = try Reader.read(host);
        try std.testing.expectEqual(@as(usize, 3), before.count);
        try std.testing.expectEqual(@as(usize, 1), before.drawn);
        try std.testing.expectEqual(@as(usize, 0), before.index);

        cards.act(cards.list()[0].id, cards.list()[0].actions[0].id);
        for (0..4) |_| _ = try dvui.testing.step(headlessFrame);
        const after = try Reader.read(host);
        try std.testing.expectEqual(@as(usize, 2), after.count);
        try std.testing.expectEqual(@as(usize, 0), after.index);
        // Settled again: the card that was answered is not drawn, and only one is.
        try dvui.testing.settle(headlessFrame);
        try std.testing.expectEqual(@as(usize, 1), (try Reader.read(host)).drawn);
        _ = host.revealSurface("fizzy.output");
        try dvui.testing.settle(headlessFrame);
    }

    // The black box (`fizzy.capture`): the last frames' input written out exactly, and read back.
    {
        const host = &editor.app.host;
        _ = try dvui.currentWindow().addEventMouseMotion(.{ .pt = .{ .x = 7, .y = 11 } });
        _ = try dvui.testing.step(headlessFrame);
        const zon = switch (host.callCommand("fizzy.capture", ".{ .seconds = 60, .why = \"test\" }", host.arena())) {
            .ok => |r| r orelse return error.TestUnexpectedResult,
            else => return error.TestUnexpectedResult,
        };
        const Written = struct { path: []const u8, frames: u64 };
        var written_diag: std.zon.parse.Diagnostics = undefined;
        const written = try std.zon.parse.fromSlice(Written, .{ .gpa = host.arena(), .arena = host.arena(), .source = try host.arena().dupeSentinel(u8, zon, 0), .diagnostics = &written_diag, .ignore_unknown_fields = true });
        try std.testing.expect(written.frames > 0);
        const input_path = try std.fs.path.join(host.arena(), &.{ written.path, "input.bin" });
        const bytes = try std.Io.Dir.cwd().readFileAlloc(dvui.io, input_path, host.arena(), .unlimited);
        const stretch = try app.automation.events.Ring.read(bytes);
        try std.testing.expectEqual(written.frames, stretch.frames.len);
        try std.testing.expect(for (stretch.records) |e| {
            if (e.kind == .motion and e.x == 7 and e.y == 11) break true;
        } else false);
        // And what the capture says about itself.
        const meta = try std.Io.Dir.cwd().readFileAlloc(dvui.io, try std.fs.path.join(host.arena(), &.{ written.path, "meta.zon" }), host.arena(), .unlimited);
        try std.testing.expect(std.mem.find(u8, meta, ".why = \"test\"") != null);
    }

    // The markdown service's inline render: no scroll area of its own, as tall as its text at the
    // width it is given, and laid out again only when that changes.
    {
        inline_md = (editor.app.host.getServiceTyped(sdk.services.markdown.Api) orelse return error.TestUnexpectedResult).*;
        defer inline_md = null;
        for (0..3) |_| _ = try dvui.testing.step(inlineMarkdownFrame);
        try std.testing.expect(inline_md_height > 20);
        const one_para = inline_md_height;
        inline_md_text = "**One** paragraph.\n\nAnd another, with `code`.\n\n- and\n- a list";
        for (0..3) |_| _ = try dvui.testing.step(inlineMarkdownFrame);
        try std.testing.expect(inline_md_height > one_para * 2);
        inline_md.?.release(0x1d1e);

        // Streamed in a few bytes a frame, as a chat reply arrives, it only ever grows. Each
        // re-parse left the edited block with an estimate that a pin then emitted for a frame, so
        // a streaming reply shrank by a line and grew back, over and over.
        const reply = "Sure. Let me look at how the view lays out a message while it streams, because that is where the motion comes from.\n\nThe **scroll area** sizes its content from last frame's sizes, and a message that grows by a line is a frame late.\n\n- one point\n- and a second that goes on long enough to wrap at this width, and then some more";
        var last: f32 = 0;
        var n: usize = 0;
        while (n < reply.len) {
            n = @min(reply.len, n + 9);
            inline_md_text = reply[0..n];
            _ = try dvui.testing.step(inlineMarkdownFrame);
            if (inline_md_height + 0.5 < last) {
                std.debug.print("inline markdown shrank from {d:.1} to {d:.1} at byte {d}\n", .{ last, inline_md_height, n });
                return error.TestUnexpectedResult;
            }
            last = inline_md_height;
        }
        inline_md.?.release(0x1d1e);
    }

    // The `plugins` service: what each plugin's loading did. A built-in is loaded; a reload that
    // fails is reported without making a running plugin look broken.
    {
        const plugins = editor.app.host.getServiceTyped(sdk.services.plugins.Api) orelse return error.TestUnexpectedResult;
        try std.testing.expectEqual(sdk.services.plugins.Api.State.loaded, plugins.status("text").state);
        try std.testing.expectEqual(sdk.services.plugins.Api.State.not_loaded, plugins.status("nothing.here").state);
        editor.app.noteLoadFailed("text", "the rebuilt binary is for another SDK");
        const st = plugins.status("text");
        try std.testing.expectEqual(sdk.services.plugins.Api.State.loaded, st.state);
        try std.testing.expectEqualStrings("the rebuilt binary is for another SDK", st.why);
        try std.testing.expectEqual(@as(u32, 1), st.failures);
        editor.app.noteLoadTimes("text", 180, 6);
        try std.testing.expectEqual(@as(f32, 6), plugins.status("text").swapped_ms);

        // Who each plugin is and what it brought: the text plugin, bundled in this harness, with
        // the commands it registered; the app's own internal plugins left out.
        var arena: std.heap.ArenaAllocator = .init(gpa);
        defer arena.deinit();
        const all = try plugins.list(arena.allocator());
        const text_info = for (all) |info| {
            if (std.mem.eql(u8, info.id, "text")) break info;
        } else return error.TestUnexpectedResult;
        try std.testing.expectEqual(sdk.services.plugins.Api.Link.bundled, text_info.link);
        try std.testing.expect(text_info.registered.commands > 0);
        try std.testing.expectEqual(sdk.services.plugins.Api.State.loaded, text_info.status.state);
        for (all) |info| {
            const p = editor.app.host.pluginById(info.id) orelse continue;
            try std.testing.expect(!p.internal);
        }
        try std.testing.expect(for (all) |info| {
            if (std.mem.eql(u8, info.id, "workbench")) break info.registered.surfaces > 0;
        } else false);
    }

    // A plugin's reload keeps its open documents (`KeptDocuments`): captured, detached with their
    // tabs left in place, and brought back through the plugin as they were, unsaved edits and
    // all. A reload swaps a dylib, which this harness has none of; this is all of it but the swap,
    // on the untitled document just typed into, which has nothing on disk to load from.
    {
        const text_plugin = editor.app.host.pluginById("text") orelse return error.TestUnexpectedResult;
        const before = editor.activeDoc() orelse return error.TestUnexpectedResult;
        const path = try gpa.dupe(u8, before.owner.documentPath(before));
        defer gpa.free(path);
        try std.testing.expect(text_plugin.isDirty(before));
        var owned: std.ArrayListUnmanaged(u64) = .empty;
        defer owned.deinit(gpa);
        for (editor.app.open_files.values()) |d| if (d.owner == text_plugin) try owned.append(gpa, d.id);

        var kept = try fizzy.Editor.KeptDocuments.capture(editor, text_plugin);
        defer kept.deinit();
        for (owned.items) |id| editor.detachFileID(id);
        try std.testing.expect(editor.docFromPath(path) == null);
        kept.reattach(editor, text_plugin);
        try dvui.testing.settle(headlessFrame);

        var count: usize = 0;
        for (editor.app.open_files.values()) |d| count += @intFromBool(d.owner == text_plugin);
        try std.testing.expectEqual(owned.items.len, count);
        const after = editor.activeDoc() orelse return error.TestUnexpectedResult;
        try std.testing.expectEqualStrings(path, after.owner.documentPath(after));
        try std.testing.expect(text_plugin.isDirty(after));
        const out = editor.app.host.callCommand("text.read", "", editor.app.host.arena());
        try std.testing.expect(std.mem.find(u8, out.ok.?, ".text = \"typed\"") != null);
        // Still untitled: Save asks where, rather than writing its placeholder name.
        try std.testing.expect(!after.owner.documentHasRecognizedSaveExtension(after));
    }

    // A restart keeps every open document (`KeptDocuments.save` / `loadSession` / `openKept`):
    // written to the session, gone with the old process, and opened from the session — not the
    // disk, where an untitled document has nothing — when its tab asks for it at the next launch.
    // The session is read once.
    {
        const before = editor.activeDoc() orelse return error.TestUnexpectedResult;
        const path = try gpa.dupe(u8, before.owner.documentPath(before));
        defer gpa.free(path);
        const grouping = before.owner.documentGrouping(before);
        const dir = try fizzy.Editor.KeptDocuments.sessionDir(gpa, editor.app.config_folder);
        defer gpa.free(dir);
        {
            var kept = try fizzy.Editor.KeptDocuments.capture(editor, null);
            defer kept.deinit();
            try kept.save(dir);
        }
        var ids: std.ArrayListUnmanaged(u64) = .empty;
        defer ids.deinit(gpa);
        for (editor.app.open_files.values()) |d| try ids.append(gpa, d.id);
        for (ids.items) |id| editor.detachFileID(id);
        try std.testing.expect(editor.docFromPath(path) == null);

        editor.session = fizzy.Editor.KeptDocuments.loadSession(gpa, dir) orelse return error.TestUnexpectedResult;
        try expectEmptyFolder(dir);
        _ = try editor.app.host.openFile(.{ .path = path, .grouping = grouping });
        const after = editor.docFromPath(path) orelse return error.TestUnexpectedResult;
        try std.testing.expect(after.owner.isDirty(after));
        const out = editor.app.host.callCommand("text.read", "", editor.app.host.arena());
        try std.testing.expect(std.mem.find(u8, out.ok.?, ".text = \"typed\"") != null);
        if (editor.session) |*kept| kept.deinit();
        editor.session = null;
    }

    // A document never saved comes back from its unsaved bytes (`Plugin.loadUntitledDocument`),
    // kept as its owner would save them (`Plugin.bytesPath`), not from a file named by its title,
    // which there is none of. Here it has no state (its owner might keep none): all it has is
    // its bytes, and it is still untitled, dirty and whole.
    {
        const before = editor.activeDoc() orelse return error.TestUnexpectedResult;
        try std.testing.expect(!before.owner.documentHasRecognizedSaveExtension(before));
        const path = try gpa.dupe(u8, before.owner.documentPath(before));
        defer gpa.free(path);
        const grouping = before.owner.documentGrouping(before);
        const dir = try fizzy.Editor.KeptDocuments.sessionDir(gpa, editor.app.config_folder);
        defer gpa.free(dir);
        {
            var kept = try fizzy.Editor.KeptDocuments.capture(editor, null);
            defer kept.deinit();
            for (kept.docs.items) |d| if (std.mem.eql(u8, d.path, path)) {
                try std.testing.expect(d.save_as != null and d.unsaved != null);
            };
            try kept.save(dir);
        }
        {
            var d = try std.Io.Dir.cwd().openDir(dvui.io, dir, .{ .iterate = true });
            defer d.close(dvui.io);
            var it = d.iterate();
            while (try it.next(dvui.io)) |file| {
                if (std.mem.endsWith(u8, file.name, ".state")) try d.deleteFile(dvui.io, file.name);
            }
            const zon = try d.readFileAlloc(dvui.io, "session.zon", gpa, .unlimited);
            defer gpa.free(zon);
            const stateless = try std.mem.replaceOwned(u8, gpa, zon, ".has_state = true", ".has_state = false");
            defer gpa.free(stateless);
            try d.writeFile(dvui.io, .{ .sub_path = "session.zon", .data = stateless });
        }
        var ids: std.ArrayListUnmanaged(u64) = .empty;
        defer ids.deinit(gpa);
        for (editor.app.open_files.values()) |d| try ids.append(gpa, d.id);
        for (ids.items) |id| editor.detachFileID(id);

        editor.session = fizzy.Editor.KeptDocuments.loadSession(gpa, dir) orelse return error.TestUnexpectedResult;
        _ = try editor.app.host.openFile(.{ .path = path, .grouping = grouping });
        const after = editor.docFromPath(path) orelse return error.TestUnexpectedResult;
        try std.testing.expectEqualStrings("text", after.owner.id);
        try std.testing.expect(after.owner.isDirty(after));
        try std.testing.expect(!after.owner.documentHasRecognizedSaveExtension(after));
        const out = editor.app.host.callCommand("text.read", "", editor.app.host.arena());
        try std.testing.expect(std.mem.find(u8, out.ok.?, ".text = \"typed\"") != null);
        if (editor.session) |*kept| kept.deinit();
        editor.session = null;
    }

    // A checkpoint (`Checkpoint`): what a run that did not quit cleanly left is read once at the
    // next launch. Each write is a generation of files in the same folder (`saveGeneration`), the
    // last one's removed once the new `session.zon` is in place; one cut off before any
    // `session.zon` is neither read nor kept; and a restart's session, which is newer, wins.
    {
        const Checkpoint = fizzy.Editor.Checkpoint;
        const config = editor.app.config_folder;
        const dir = try Checkpoint.dir(gpa, config);
        defer gpa.free(dir);
        const cwd = std.Io.Dir.cwd();
        {
            var kept = try fizzy.Editor.KeptDocuments.capture(editor, null);
            defer kept.deinit();
            try kept.saveGeneration(dir, 1);
            try kept.saveGeneration(dir, 2);
        }
        // Only the second generation's files are left, beside its `session.zon`.
        {
            var d = try cwd.openDir(dvui.io, dir, .{ .iterate = true });
            defer d.close(dvui.io);
            var it = d.iterate();
            while (try it.next(dvui.io)) |file| {
                try std.testing.expect(std.mem.eql(u8, file.name, "session.zon") or std.mem.startsWith(u8, file.name, "2-"));
            }
        }
        var recovered = Checkpoint.recover(gpa, config, false) orelse return error.TestUnexpectedResult;
        try std.testing.expect(recovered.docs.items.len > 0);
        try std.testing.expect(recovered.docs.items[0].state != null);
        recovered.deinit();
        try expectEmptyFolder(dir);
        try std.testing.expect(Checkpoint.recover(gpa, config, false) == null);

        // Cut off before its first `session.zon`: nothing read, and nothing left.
        try tmp.dir.writeFile(dvui.io, .{ .sub_path = "checkpoint/1-0.state", .data = "cut off" });
        try std.testing.expect(Checkpoint.recover(gpa, config, false) == null);
        try expectEmptyFolder(dir);

        // A restart's session found: the checkpoint is older, and goes unread.
        {
            var kept = try fizzy.Editor.KeptDocuments.capture(editor, null);
            defer kept.deinit();
            try kept.saveGeneration(dir, 1);
        }
        try std.testing.expect(Checkpoint.recover(gpa, config, true) == null);
        try expectEmptyFolder(dir);
    }

    // A plugin's New flow writes its file itself and asks the `files` service to show it
    // (`reveal`): fizzy emits `fizzy.files.reveal`, and the tree, which hears it, reveals the row
    // with its name open for editing. The tree holds the path until the row is laid out, then
    // takes it, so heard-then-taken is the whole round trip.
    {
        try editor.setProjectFolder(project);
        editor.explorer.open(editor);
        editor.app.host.setSelectionFor(sdk.keywords.ide.sidebar, fizzy.Editor.workbench_files_view);
        try tmp.dir.writeFile(dvui.io, .{ .sub_path = "project/made-by-a-plugin.md", .data = "" });
        const made = try std.fs.path.join(gpa, &.{ project, "made-by-a-plugin.md" });
        defer gpa.free(made);
        const files_api = editor.app.host.getServiceTyped(sdk.services.files.Api) orelse return error.TestUnexpectedResult;
        files_api.reveal(made);
        var heard = false;
        for (0..200) |_| {
            _ = try dvui.testing.step(headlessFrame);
            if (editor.workbench.pending_new_file_path) |pending| {
                if (std.mem.eql(u8, pending, made)) heard = true;
            } else if (heard) break;
        }
        try std.testing.expect(heard);
        try std.testing.expect(editor.workbench.pending_new_file_path == null);
    }

    // A file opened before its plugin is there (launched with it while the plugin was refused,
    // before a dropped-in build was loaded) is the fallback's, as text, until the plugin arrives;
    // then it moves to it, in the same tab (`Editor.rehomeFallbackDocuments`).
    {
        const host = &editor.app.host;
        const image = host.pluginById("image") orelse return error.TestUnexpectedResult;
        host.unregisterPlugin(image);
        editor.rebuildExtensionOwnerCache();
        // One white pixel, uncompressed true-colour TGA.
        const tga = [_]u8{ 0, 0, 2, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1, 0, 1, 0, 32, 8, 255, 255, 255, 255 };
        try tmp.dir.writeFile(dvui.io, .{ .sub_path = "project/late.tga", .data = &tga });
        const late = try std.fs.path.join(gpa, &.{ project, "late.tga" });
        defer gpa.free(late);
        const ownerOf = struct {
            fn ownerOf(e: *fizzy.Editor, path: []const u8) ?*sdk.Plugin {
                const d = e.docFromPath(path) orelse return null;
                return d.owner;
            }
        }.ownerOf;
        _ = try editor.openFilePath(late, editor.workbench.currentGroupingID());
        for (0..200) |_| {
            if (ownerOf(editor, late) != null) break;
            _ = try dvui.testing.step(headlessFrame);
        }
        try dvui.testing.settle(headlessFrame);
        try std.testing.expectEqual(host.fallback_editor, ownerOf(editor, late));
        const docs_before = editor.app.open_files.count();

        try host.registerPlugin(image);
        editor.rebuildExtensionOwnerCache();
        for (0..200) |_| {
            if (ownerOf(editor, late) == image) break;
            _ = try dvui.testing.step(headlessFrame);
        }
        try dvui.testing.settle(headlessFrame);
        try std.testing.expectEqual(image, ownerOf(editor, late).?);
        try std.testing.expectEqual(docs_before, editor.app.open_files.count());
        // Its tab was taken over, not added beside it: one tab for the file, the image's.
        const surface = try sdk.document.surfaceId(host.arena(), image.id, late);
        try std.testing.expect(editor.workbench.hasTabAnywhere(surface));
        const text_surface = try sdk.document.surfaceId(host.arena(), host.fallback_editor.?.id, late);
        try std.testing.expect(!editor.workbench.hasTabAnywhere(text_surface));
        try editor.closeFileID(editor.docFromPath(late).?.id);
        try dvui.testing.settle(headlessFrame);
    }

    // A quit straight after a pane slid shut (`snapshotClosingPane`): the pane still holds its
    // picture, and the quit comes after the last frame, when nothing can be freed at a frame's end.
    {
        const pixels: [4 * 4 * 4]u8 = @splat(0);
        const snap = try t.window.backend.textureCreate(&pixels, .{ .width = 4, .height = 4 });
        editor.workbench.workspaces.values()[0].closing_snapshot = snap;
    }
    // The harness keeps its window current between frames; `appQuit` has none.
    const harness_window = dvui.current_window;
    dvui.current_window = null;
    defer dvui.current_window = harness_window;
    quit = true;
    try editor.deinit();
}

/// A state folder read once (a restart's session, a checkpoint): still there, with nothing in it.
/// It is emptied rather than removed, since the settings watcher may be watching it
/// (`SettingsWatcher.emptyStateFolder`).
fn expectEmptyFolder(path: []const u8) !void {
    var d = try std.Io.Dir.cwd().openDir(dvui.io, path, .{ .iterate = true });
    defer d.close(dvui.io);
    var it = d.iterate();
    try std.testing.expect(try it.next(dvui.io) == null);
}

// ── The app's own executable ────────────────────────────────────────────────────────────────────
// `ExecutableWatcher.tick`: when a replaced executable is a rebuild to restart into (the watcher's
// thread is nightwatch's, which sets the same flag the test sets).

test "executable watcher: a rebuild is a replaced executable that has held still" {
    if (comptime !ExecutableWatcher.have_impl) return error.SkipZigTest;
    const gpa = std.testing.allocator;
    const io_before = dvui.io;
    defer dvui.io = io_before;
    dvui.io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(dvui.io, .{ .sub_path = "app", .data = "the launched build" });
    const path = try std.fs.path.join(gpa, &.{ ".zig-cache", "tmp", &tmp.sub_path, "app" });
    defer gpa.free(path);
    var w = try ExecutableWatcher.init(gpa, path);
    defer w.deinit();

    // An event for an executable that did not change (touched by a no-op install): no restart.
    w.dirty.store(true, .release);
    try std.testing.expect(!w.tick());
    w.pending_ns -= ExecutableWatcher.settle_ns;
    try std.testing.expect(!w.tick());

    // Replaced, as an install does it: written beside it, renamed into place.
    try tmp.dir.writeFile(dvui.io, .{ .sub_path = "app.new", .data = "the rebuilt build, longer" });
    try tmp.dir.rename("app.new", tmp.dir, "app", dvui.io);
    w.dirty.store(true, .release);
    try std.testing.expect(!w.tick()); // settling
    w.pending_ns -= ExecutableWatcher.settle_ns;
    try std.testing.expect(w.tick());
}

// A build that lands while the app is still starting (the window, the GPU, the plugins take a
// second or so, more under load): measured against the executable as the process started from it
// (`noteLaunch`), it is a rebuild, and the watcher looks once as it starts, since the build's events
// came before anyone listened. Measured when watching began, it was taken for the build running.
test "executable watcher: a build that lands while the app starts is restarted into" {
    if (comptime !ExecutableWatcher.have_impl) return error.SkipZigTest;
    const gpa = std.testing.allocator;
    const io_before = dvui.io;
    defer dvui.io = io_before;
    dvui.io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root_buf: [std.fs.max_path_bytes]u8 = undefined;
    const root = root_buf[0..try tmp.dir.realPath(dvui.io, &root_buf)];
    const path = try std.fs.path.join(gpa, &.{ root, "app" });
    defer gpa.free(path);
    try tmp.dir.writeFile(dvui.io, .{ .sub_path = "app", .data = "the launched build" });
    ExecutableWatcher.noteLaunchAt(dvui.io, path);

    // Replaced during startup, before the watcher exists.
    try tmp.dir.writeFile(dvui.io, .{ .sub_path = "app.new", .data = "the rebuilt build, longer" });
    try tmp.dir.rename("app.new", tmp.dir, "app", dvui.io);

    var w = try ExecutableWatcher.init(gpa, path);
    defer w.deinit();
    try w.start();
    // Settled each time round: a late event from the watch itself only starts the wait again.
    var restarts = false;
    for (0..8) |_| {
        if (w.tick()) {
            restarts = true;
            break;
        }
        if (w.pending_ns != 0) w.pending_ns -= ExecutableWatcher.settle_ns;
    }
    try std.testing.expect(restarts);
}

// `SettingsWatcher` over the config folder while the app keeps its own state beside the settings:
// a crash checkpoint, a restart's session. On Linux the watch is recursive by hand (nightwatch adds
// an inotify watch for each folder it sees appear, on its own thread), so a folder made and
// removed before that thread gets to it logs an error. The app's state folders are emptied, never
// removed: none of them can vanish under it, however fast the writes come.
test "settings watcher: the app's state folders come and go under it without an error" {
    if (comptime !SettingsWatcher.have_impl) return error.SkipZigTest;
    const gpa = std.testing.allocator;
    const io_before = dvui.io;
    defer dvui.io = io_before;
    dvui.io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root_buf: [std.fs.max_path_bytes]u8 = undefined;
    const config = root_buf[0..try tmp.dir.realPath(dvui.io, &root_buf)];

    var w = try SettingsWatcher.init(gpa, config);
    try w.start();
    defer w.stop();

    const Checkpoint = fizzy.Editor.Checkpoint;
    const KeptDocuments = fizzy.Editor.KeptDocuments;
    const checkpoint = try Checkpoint.dir(gpa, config);
    defer gpa.free(checkpoint);
    const session = try KeptDocuments.sessionDir(gpa, config);
    defer gpa.free(session);
    var kept: KeptDocuments = .{ .gpa = gpa };
    defer kept.deinit();
    for (0..2000) |_| {
        // A checkpoint written and recovered, one cut off before its `session.zon`, and one a
        // restart's session supersedes: each the first thing the next launch reads.
        try kept.saveGeneration(checkpoint, 1);
        try std.testing.expect(Checkpoint.recover(gpa, config, false) == null);
        try tmp.dir.writeFile(dvui.io, .{ .sub_path = "checkpoint/1-0.state", .data = "cut off" });
        try std.testing.expect(Checkpoint.recover(gpa, config, false) == null);
        try kept.saveGeneration(checkpoint, 2);
        try std.testing.expect(Checkpoint.recover(gpa, config, true) == null);
        try expectEmptyFolder(checkpoint);
        // A restart's session, written and read once.
        try kept.save(session);
        var loaded = KeptDocuments.loadSession(gpa, session) orelse return error.TestUnexpectedResult;
        loaded.deinit();
        try expectEmptyFolder(session);
    }
}

// The watcher's callback runs on nightwatch's own thread, and calls through a pointer to the
// watcher. So `stop` must not return while a callback is still running: the watcher is freed (or,
// in a test, its stack frame reused) straight after. On macOS that thread is FSEvents' dispatch
// queue, and stopping the stream does not wait for a callback already on it. Under load, the one
// the test above leaves running reached the next test's frame and aborted it.
test "settings watcher: stop waits for a callback already running" {
    if (comptime !SettingsWatcher.have_impl) return error.SkipZigTest;
    const gpa = std.testing.allocator;
    const io_before = dvui.io;
    defer dvui.io = io_before;
    dvui.io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root_buf: [std.fs.max_path_bytes]u8 = undefined;
    const config = root_buf[0..try tmp.dir.realPath(dvui.io, &root_buf)];

    var w = try SettingsWatcher.init(gpa, config);
    const Handler = @TypeOf(w.impl.handler);
    const change_params = @typeInfo(@typeInfo(@FieldType(Handler.VTable, "change")).pointer.child).@"fn".param_types;
    const EventType = change_params[2].?;
    const ObjectType = change_params[3].?;
    // The first callback holds on long enough for `stop` to be called while it runs.
    const Slow = struct {
        var entered: std.atomic.Value(bool) = .init(false);
        var stopped: std.atomic.Value(bool) = .init(false);
        var left: std.atomic.Value(bool) = .init(false);
        var outlived_stop: std.atomic.Value(bool) = .init(false);

        fn change(_: *Handler, _: []const u8, _: EventType, _: ObjectType) error{HandlerFailed}!void {
            if (entered.swap(true, .acq_rel)) return;
            std.testing.io.sleep(.fromMilliseconds(300), .awake) catch {};
            outlived_stop.store(stopped.load(.acquire), .release);
            left.store(true, .release);
        }

        fn rename(h: *Handler, _: []const u8, dst: []const u8, o: ObjectType) error{HandlerFailed}!void {
            return change(h, dst, .modified, o);
        }
    };
    const vtable: Handler.VTable = .{ .change = Slow.change, .rename = Slow.rename };
    w.impl.handler = .{ .vtable = &vtable };
    try w.start();

    try tmp.dir.writeFile(dvui.io, .{ .sub_path = "settings.zon", .data = ".{}" });
    for (0..5000) |_| {
        if (Slow.entered.load(.acquire)) break;
        try std.testing.io.sleep(.fromMilliseconds(1), .awake);
    } else return error.TestUnexpectedResult;
    w.stop();
    Slow.stopped.store(true, .release);
    for (0..2000) |_| {
        if (Slow.left.load(.acquire)) break;
        try std.testing.io.sleep(.fromMilliseconds(1), .awake);
    }
    try std.testing.expect(Slow.left.load(.acquire));
    try std.testing.expect(!Slow.outlived_stop.load(.acquire));
}

// ── The automation service ──────────────────────────────────────────────────────────────────────
// `automation.Service` over the live driver above: what a plugin sees — tape bytes in, a ticket
// back, and the outcome asked for by ticket.

const AutomationApi = sdk.services.automation.Api;

var service_demo_loaded = false;

fn serviceOther(_: *anyopaque) bool {
    return service_demo_loaded;
}

fn liveService() automation.Service {
    service_demo_loaded = false;
    return .{
        .gpa = std.testing.allocator,
        .driver = &demo_live,
        .other = .{ .ctx = &service_demo_loaded, .driving = serviceOther },
    };
}

/// A tape as a plugin hands it over: ZON text.
fn tapeZon(owned: automation.Tape.Owned) ![]u8 {
    var o = owned;
    defer o.deinit();
    var out: std.Io.Writer.Allocating = .init(std.testing.allocator);
    errdefer out.deinit();
    try o.tape.write(&out.writer);
    return out.toOwnedSlice();
}

fn started(p: AutomationApi.Play) !AutomationApi.Ticket {
    return switch (p) {
        .started => |t| t,
        else => error.TestUnexpectedResult,
    };
}

test "automation service: tape bytes in, a ticket back, the outcome by ticket" {
    var t = try liveCtx();
    defer deinitLive(&t);
    var svc = liveService();
    svc.bind();
    const api = svc.api;

    try std.testing.expect(api.settled());
    const bytes = try tapeZon(try liveTape());
    defer std.testing.allocator.free(bytes);
    const ticket = try started(api.play(bytes));
    try std.testing.expect(api.outcome(ticket) == .playing);
    try std.testing.expect(!api.settled());

    try stepLiveUntilDone(200);
    try std.testing.expect(api.outcome(ticket) == .finished);
    try std.testing.expect(api.settled());
    try std.testing.expectEqual(@as(usize, 1), demo_clicks);
    try std.testing.expectEqualStrings("> hi", demo_text.items);
    try std.testing.expectEqualStrings(".{ .n = 1 }", demo_command_args.items);

    // The binary form plays the same; the first tape's outcome is still there to ask for.
    var owned = try liveTape();
    defer owned.deinit();
    const encoded = try automation.binary.encode(std.testing.allocator, owned.tape, .{});
    defer std.testing.allocator.free(encoded);
    const second = try started(api.play(encoded));
    try std.testing.expect(second != ticket);
    try stepLiveUntilDone(200);
    try std.testing.expect(api.outcome(second) == .finished);
    try std.testing.expect(api.outcome(ticket) == .finished);
    try std.testing.expectEqual(@as(usize, 2), demo_clicks);
}

test "automation service: refused while something drives the app, or for a demo's tape" {
    var t = try liveCtx();
    defer deinitLive(&t);
    var svc = liveService();
    svc.bind();
    const api = svc.api;

    const live = try tapeZon(try liveTape());
    defer std.testing.allocator.free(live);
    const demo = try tapeZon(try demoTape());
    defer std.testing.allocator.free(demo);

    // A demo's tape opens on a keyframe; garbage is no tape at all. Both say why.
    try std.testing.expectEqualStrings("KeyframeInLiveTape", api.play(demo).invalid);
    try std.testing.expect(api.play("not a tape") == .invalid);
    try std.testing.expect(api.outcome(@fromBackingInt(@intCast(12345))) == .unknown);

    // A demo loaded: refused, and nothing is settled while it plays.
    service_demo_loaded = true;
    try std.testing.expect(api.play(live) == .busy);
    try std.testing.expect(!api.settled());
    service_demo_loaded = false;

    // One tape at a time, and only its own ticket stops it.
    const ticket = try started(api.play(live));
    try std.testing.expect(api.play(live) == .busy);
    api.stop(@fromBackingInt(@intCast(@backingInt(ticket) + 1)));
    try std.testing.expect(api.outcome(ticket) == .playing);
    api.stop(ticket);
    try std.testing.expect(api.outcome(ticket) == .stopped);
    try std.testing.expect(api.settled());
}

test "automation service: a person's input stops the tape, and the outcome says before which op" {
    var t = try liveCtx();
    defer deinitLive(&t);
    var svc = liveService();
    svc.bind();
    const api = svc.api;

    const bytes = try tapeZon(try liveTape());
    defer std.testing.allocator.free(bytes);
    const ticket = try started(api.play(bytes));
    _ = try dvui.testing.step(liveFrame);
    try dvui.testing.pressKey(.escape, .none);
    try stepLiveUntilDone(10);
    const before = api.outcome(ticket).interrupted;
    try std.testing.expect(before < 10);
    try std.testing.expectEqual(@as(usize, 0), demo_commands);
}

test "automation service: settled waits for dvui to go quiet, and wakes the app once to say so" {
    var t = try liveCtx();
    defer deinitLive(&t);
    var svc = liveService();
    svc.bind();
    const api = svc.api;

    // A frame ended with dvui wanting the next one now (a refresh, or an animation running).
    try std.testing.expect(!svc.frameEnded(0));
    try std.testing.expect(!api.settled());
    // An animation due later is still something in flight.
    try std.testing.expect(!svc.frameEnded(16_000));
    try std.testing.expect(!api.settled());
    // dvui goes quiet: whoever was told "not yet" gets one more frame to see it change.
    try std.testing.expect(svc.frameEnded(null));
    try std.testing.expect(api.settled());
    // Asked and answered yes: no frame is run for nobody.
    try std.testing.expect(!svc.frameEnded(null));
    try std.testing.expect(!svc.frameEnded(null));
    try std.testing.expect(api.settled());
}

// -- output panel --------------------------------------------------------------------------------
// The panel lays out only the lines in view, so the width it scrolls sideways over was only theirs:
// a line wider than the panel in view put up the horizontal bar, the bar took a row's height off
// the view, the view following the tail dropped its top row, and with it the wide line; the bar
// went, the row came back, and the panel jittered every frame with no input.

const output_panel_size: dvui.Size = .{ .w = 300, .h = 120 };

fn outputPanelFrame() anyerror!dvui.App.Result {
    var box = dvui.box(@src(), .{}, .{
        .min_size_content = output_panel_size,
        .max_size_content = .{ .w = output_panel_size.w, .h = output_panel_size.h },
    });
    defer box.deinit();
    return fizzy.OutputPanel.draw(null);
}

test "the output panel settles at its tail with a line wider than it anywhere in view" {
    var t = try dvui.testing.init(.{ .allocator = std.testing.allocator });
    defer t.deinit();
    defer fizzy.OutputLog.clear();

    const wide = comptime blk: {
        var s: []const u8 = "";
        for (0..12) |_| s = s ++ "a line far wider than the panel ";
        break :blk s;
    };
    const rows = 40;
    // The wide line at each of the last rows in turn, wherever the top of the view falls.
    for (0..20) |from_tail| {
        fizzy.OutputLog.clear();
        for (0..rows) |i| {
            fizzy.OutputLog.appendLine(.info, "test", if (i == rows - 1 - from_tail) wide else "short");
        }
        dvui.testing.settle(outputPanelFrame) catch |err| {
            std.debug.print("wide line {d} rows from the tail: {s}\n", .{ from_tail, @errorName(err) });
            return err;
        };
    }
}

var output_sweep_height: f32 = 120;

fn outputSweepFrame() anyerror!dvui.App.Result {
    var box = dvui.box(@src(), .{}, .{
        .min_size_content = .{ .w = 500, .h = output_sweep_height },
        .max_size_content = .{ .w = 500, .h = output_sweep_height },
    });
    defer box.deinit();
    return fizzy.OutputPanel.draw(null);
}

// Output arriving two lines at a time (a plugin reload's pair), long and short lines mixed, in
// panes of every height from a few rows to a dozen: the panel settles after each pair. Near the
// height where the log first outgrows the pane the scrollbars come and go, which is where a
// panel whose bars or text height fed back into its range fought itself.
test "the output panel settles as lines arrive, in panes of every height" {
    var t = try dvui.testing.init(.{ .allocator = std.testing.allocator, .window_size = .{ .w = 800, .h = 600 } });
    defer t.deinit();
    defer fizzy.OutputLog.clear();

    var h: f32 = 60;
    while (h <= 220) : (h += 3) {
        output_sweep_height = h;
        fizzy.OutputLog.clear();
        var total: usize = 0;
        while (total < 30) {
            for (0..2) |_| {
                total += 1;
                fizzy.OutputLog.appendLine(.info, "fizzy", if (total % 3 == 0)
                    "plugin 'text': rebuilt binary found, reloading /Users/somebody/Library/Application Support/fizzy/plugins/text/text.dylib"
                else
                    "plugin 'text': reloaded");
            }
            dvui.testing.settle(outputSweepFrame) catch |err| {
                std.debug.print("pane {d} tall, {d} lines: {s}\n", .{ h, total, @errorName(err) });
                return err;
            };
        }
    }
}

// ---- A picture of the window, for an agent ------------------------------------------------------

var capture_under_test: automation.Capture = undefined;
var capture_target: dvui.Texture.Target = undefined;

var capture_dialog: dvui.Texture.Target = undefined;

/// A frame that ends as fizzy's does: each window's target read back for whoever asked — the main
/// window's, and a dialog's lying 2 pixels right of the main window's corner.
fn captureFrame() !dvui.App.Result {
    capture_under_test.endFrame(&.{
        .{ .tag = "fizzy.window:main", .target = capture_target, .w = 3, .h = 2 },
        .{ .tag = "fizzy.window:dialog:Ask", .target = capture_dialog, .w = 2, .h = 1, .at = .{ .x = 2, .y = 0 } },
    });
    return .ok;
}

test "a capture is the drawn part of the frame target, as drawn, once taken" {
    var t = try dvui.testing.init(.{ .allocator = std.testing.allocator, .window_size = .{ .w = 100, .h = 100 } });
    defer t.deinit();
    capture_under_test = .init(std.testing.allocator);
    defer capture_under_test.deinit();

    // A 4x2 target, premultiplied, of which the frame drew the left 3 columns.
    var pixels: [4 * 2 * 4]u8 = @splat(0);
    pixels[0..4].* = .{ 128, 0, 0, 128 }; // half-transparent red, premultiplied
    pixels[4..8].* = .{ 0, 255, 0, 255 };
    capture_target = .{ .ptr = &pixels, .width = 4, .height = 2, .format = .rgba_32, .interpolation = .nearest, .wrap_u = .clamp, .wrap_v = .clamp };
    // The dialog's window: opaque blue, then clear.
    var dialog_pixels: [2 * 1 * 4]u8 = .{ 0, 0, 255, 255, 0, 0, 0, 0 };
    capture_dialog = .{ .ptr = &dialog_pixels, .width = 2, .height = 1, .format = .rgba_32, .interpolation = .nearest, .wrap_u = .clamp, .wrap_v = .clamp };

    // Nothing asked: a frame takes no picture.
    _ = try dvui.testing.step(captureFrame);
    try std.testing.expect(capture_under_test.get(1) == null);

    const n = capture_under_test.request("");
    try std.testing.expect(capture_under_test.get(n) == null);
    try std.testing.expectEqual(n, capture_under_test.request("")); // asked again before it is taken
    _ = try dvui.testing.step(captureFrame);
    const main = capture_under_test.get(n) orelse return error.TestUnexpectedResult;
    // The drawn part's width and height, not the target's; its pixels as drawn, premultiplied,
    // row by row: nothing is encoded or converted in the app's frame.
    try std.testing.expectEqual(@as(u32, 3), main.width);
    try std.testing.expectEqual(@as(u32, 2), main.height);
    try std.testing.expectEqual(@as(usize, 3 * 2 * 4), main.pixels.len);
    try std.testing.expectEqualSlices(u8, &.{ 128, 0, 0, 128, 0, 255, 0, 255 }, main.pixels[0..8]);

    // The next is a new picture; the last stays until it is taken.
    const m = capture_under_test.request("fizzy.window:dialog:Ask");
    try std.testing.expect(m != n);
    try std.testing.expect(capture_under_test.get(n) != null);
    _ = try dvui.testing.step(captureFrame);
    try std.testing.expect(capture_under_test.get(n) == null);
    // A window by its tag: its own picture, its size.
    const dialog = capture_under_test.get(m) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(@as(u32, 2), dialog.width);
    try std.testing.expectEqual(@as(u32, 1), dialog.height);
    try std.testing.expectEqualSlices(u8, &dialog_pixels, dialog.pixels);

    // Every window, where each lies round the main one: the main window's 3 columns, and the
    // dialog's 2 from the third on — 4 wide.
    const every = capture_under_test.request(automation.Capture.all);
    _ = try dvui.testing.step(captureFrame);
    const all = capture_under_test.get(every) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(@as(u32, 4), all.width);
    try std.testing.expectEqual(@as(u32, 2), all.height);

    // No window by that name: taken, and empty.
    const none = capture_under_test.request("fizzy.window:dialog:Nobody");
    _ = try dvui.testing.step(captureFrame);
    try std.testing.expectEqual(@as(u32, 0), (capture_under_test.get(none) orelse return error.TestUnexpectedResult).width);
}

// ---- A live tape drags ------------------------------------------------------------------------

var live_driver: automation.LiveDriver = undefined;
var live_float: dvui.Rect = .{ .x = 300, .y = 200, .w = 240, .h = 160 };

fn liveDragFrame() !dvui.App.Result {
    live_driver.frame();
    // lint-allow(raw-transient-surface): headless test fixture, not a shown surface
    var fw = dvui.floatingWindow(@src(), .{ .rect = &live_float }, .{ .tag = "live.float" });
    defer fw.deinit();
    fw.dragAreaSet(dvui.windowHeader("Drag me", "", null));
    dvui.labelNoFmt(@src(), "body", .{}, .{});
    return .ok;
}

test "a live tape drags a floating window by its header" {
    var t = try dvui.testing.init(.{ .allocator = std.testing.allocator, .window_size = .{ .w = 800, .h = 600 } });
    defer t.deinit();
    demo_stage = .{};
    live_driver = .init(demo_stage.stage());
    defer live_driver.deinit();
    live_float = .{ .x = 300, .y = 200, .w = 240, .h = 160 };
    try dvui.testing.settle(liveDragFrame);

    const tape =
        \\.{ .name = "drag", .title = "drag", .ops = .{
        \\    .{ .at = 0, .ms = 100, .do = .{ .move = .{ .tag = "", .x = 0.525, .y = 0.35 } } },
        \\    .{ .at = 200, .do = .{ .press = .left } },
        \\    .{ .at = 300, .ms = 500, .do = .{ .move = .{ .tag = "", .x = 0.3375, .y = 0.35 } } },
        \\    .{ .at = 900, .do = .{ .release = .left } },
        \\} }
    ;
    var check = automation.Input.check;
    check.live = true;
    try live_driver.play(try automation.Tape.parse(std.testing.allocator, tape, check));
    var frames: usize = 0;
    while (live_driver.playing() and frames < 400) : (frames += 1) _ = try dvui.testing.step(liveDragFrame);
    try std.testing.expect(!live_driver.playing());
    try std.testing.expectEqual(automation.LiveDriver.Outcome.finished, live_driver.outcome.?);
    std.debug.print("float x {d:.1} (from 300) after {d} frames\n", .{ live_float.x, frames });
    try std.testing.expectApproxEqAbs(@as(f32, 150), live_float.x, 2);
}

test "layout.zon: a place an older fizzy showed one view in keeps that one, not a row of tabs" {
    if (comptime builtin.target.cpu.arch == .wasm32) return error.SkipZigTest;
    const gpa = std.testing.allocator;
    const io_before = dvui.io;
    defer dvui.io = io_before;
    dvui.io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(dvui.io, .{ .sub_path = "layout.zon", .data =
        \\.{ .regions = .{
        \\    .{ .name = "Main", .surfaces = .{ "a", "b" }, .shows = .one },
        \\    .{ .name = "Panel", .surfaces = .{ "c", "d" }, .shows = .many },
        \\    .{ .name = "Side", .surfaces = .{ "e", "f" } },
        \\} }
    });
    const dir = try std.fs.path.join(gpa, &.{ ".zig-cache", "tmp", &tmp.sub_path });
    defer gpa.free(dir);
    const saved = fizzy.backend.loadRegions(gpa, dir, "");
    defer fizzy.backend.freeRegions(gpa, saved);
    try std.testing.expectEqual(@as(usize, 3), saved.len);
    try std.testing.expectEqual(@as(usize, 1), saved[0].surfaces.?.len);
    try std.testing.expectEqualStrings("a", saved[0].surfaces.?[0]);
    try std.testing.expectEqual(@as(usize, 2), saved[1].surfaces.?.len);
    try std.testing.expectEqual(@as(usize, 2), saved[2].surfaces.?.len);
}

test "settings: an untouched in-app material is not written; a chosen one is" {
    const Settings = @import("app").settings.Settings;
    const gpa = std.testing.allocator;
    var s: Settings = .{};
    const plain = try s.serialize(gpa);
    defer gpa.free(plain);
    try std.testing.expect(std.mem.find(u8, plain, "in_app_material") == null);
    s.in_app_material = .frost;
    const chosen = try s.serialize(gpa);
    defer gpa.free(chosen);
    try std.testing.expect(std.mem.find(u8, chosen, ".in_app_material = .frost") != null);
}

test "settings: a fresh profile starts with glass off; a saved material is kept" {
    const Settings = @import("app").settings.Settings;
    const gpa = std.testing.allocator;
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();

    const fresh = try Settings.parseOnly(gpa, arena.allocator(), ".{}");
    try std.testing.expectEqual(fizzy.core.material.Kind.none, fresh.window_material);
    try std.testing.expectEqual(@as(?fizzy.core.material.Kind, null), fresh.in_app_material);

    const saved = try Settings.parseOnly(gpa, arena.allocator(), ".{ .window_material = .liquid, .in_app_material = .frost }");
    try std.testing.expectEqual(fizzy.core.material.Kind.liquid, saved.window_material);
    try std.testing.expectEqual(@as(?fizzy.core.material.Kind, .frost), saved.in_app_material);

    var chosen: Settings = .{};
    chosen.window_material = .liquid;
    const written = try chosen.serialize(gpa);
    defer gpa.free(written);
    try std.testing.expect(std.mem.find(u8, written, ".window_material = .liquid") != null);
}

// -- mobile sheets at tablet and landscape sizes -------------------------------------------------

const SheetSize = struct { name: []const u8, w: f32, h: f32 };
const sheet_sizes = [_]SheetSize{
    .{ .name = "768x1024", .w = 768, .h = 1024 },
    .{ .name = "1024x768", .w = 1024, .h = 768 },
    .{ .name = "1366x1024", .w = 1366, .h = 1024 },
    .{ .name = "812x375", .w = 812, .h = 375 },
};

/// The box a place draws, or null when it is not declared.
fn regionRect(editor: *fizzy.Editor, name: []const u8) ?dvui.Size {
    for (editor.app.layout.regions.items) |r| if (std.mem.eql(u8, r.name, name)) return r.size;
    return null;
}

/// Opens one sheet in a window of `size` and returns the box it settled at.
fn openedSheet(size: SheetSize, keywords: []const []const u8, name: []const u8) !dvui.Size {
    var ctx = try shim.initSized(std.testing.allocator, .{ .w = size.w, .h = size.h });
    defer ctx.deinit(std.testing.allocator);
    const editor = ctx.editor;
    try mobileCase(&ctx);
    defer fizzy.core.platform.cached_form_factor = .desktop;
    defer MobileFrame.editor = null;
    defer editor.app.layout.regions.deinit(editor.app.gpa);
    defer editor.app.layout.regions_building.deinit(editor.app.gpa);
    defer editor.app.layout.deinitExtents(editor.app.gpa);
    defer editor.app.layout.deinitQualified(editor.app.gpa);
    defer editor.app.layout.deinitAssignments(editor.app.gpa);

    try dvui.testing.settle(MobileFrame.frame);
    const sheet = editor.regionFor(keywords) orelse return error.TestUnexpectedResult;
    sheet.open();
    try dvui.testing.settle(MobileFrame.frame);
    return regionRect(editor, name) orelse error.TestUnexpectedResult;
}

test "mobile chrome: disabled panel has no place or toggle, landscape explorer follows edge" {
    for (sheet_sizes) |size| {
        var ctx = try shim.initSized(std.testing.allocator, .{ .w = size.w, .h = size.h });
        defer ctx.deinit(std.testing.allocator);
        try mobileCase(&ctx);
        defer mobileTeardown(&ctx);
        const editor = ctx.editor;
        editor.chrome = .{ .panel = false, .sidebar_edge = .right };
        try dvui.testing.settle(MobileFrame.frame);
        try std.testing.expect(chromeBounds(editor, "Panel") == null);
        try std.testing.expect(editor.regionFor(fizzy.sdk.keywords.ide.panel) == null);
        try std.testing.expect(dvui.tagGet("fizzy.mobile.panel") == null);
        editor.regionFor(fizzy.sdk.keywords.ide.sidebar).?.open();
        try dvui.testing.settle(MobileFrame.frame);
        const explorer = chromeBounds(editor, "Explorer") orelse return error.TestUnexpectedResult;
        if (size.w > size.h) {
            try std.testing.expect(explorer.x > dvui.windowRectPixels().w * 0.4);
            try std.testing.expectApproxEqAbs(dvui.windowRectPixels().w, explorer.x + explorer.w, 1);
        }
    }
}

test "mobile sheets: capped in width in portrait, side sheets in landscape" {
    const kw = fizzy.sdk.keywords.ide;
    // A sheet's box includes the card's 16 pt of padding.
    const pad = 16;
    for (sheet_sizes) |size| {
        const explorer = try openedSheet(size, kw.sidebar, "Explorer");
        const panel = try openedSheet(size, kw.panel, "Panel");
        for ([_]dvui.Size{ explorer, panel }) |box| {
            try std.testing.expect(box.w <= 560 + pad + 0.5);
            if (size.w > size.h) {
                // A side sheet: no wider than half the window, and tall enough to use.
                try std.testing.expect(box.w <= size.w * 0.5 + pad + 0.5);
                try std.testing.expect(box.h > size.h * 0.6);
            } else {
                // At the foot: 0.6 of the height, across at most the cap.
                try std.testing.expect(box.w < size.w or size.w <= 560 + pad);
                try std.testing.expectApproxEqAbs(size.h * 0.6 + pad, box.h, 1);
            }
        }
    }
}

/// Frees what a mobile-shaped test window leaves behind; deferred right after `shim.initSized`.
fn mobileTeardown(ctx: *shim.Ctx) void {
    const editor = ctx.editor;
    fizzy.core.platform.cached_form_factor = .desktop;
    MobileFrame.editor = null;
    editor.app.layout.regions.deinit(editor.app.gpa);
    editor.app.layout.regions_building.deinit(editor.app.gpa);
    editor.app.layout.deinitExtents(editor.app.gpa);
    editor.app.layout.deinitQualified(editor.app.gpa);
    editor.app.layout.deinitAssignments(editor.app.gpa);
}

/// Turns the window to `w` x `h` points, keeping the pixel ratio it started with.
fn resizeWindow(ctx: *shim.Ctx, w: f32, h: f32) !void {
    const scale = ctx.t.backend.size_pixels.w / ctx.t.backend.size.w;
    ctx.t.backend.size = .{ .w = w, .h = h };
    ctx.t.backend.size_pixels = .{ .w = w * scale, .h = h * scale };
    // The window reads its size in `begin`, which a step runs after the frame it ends.
    _ = try dvui.testing.step(MobileFrame.frame);
    try dvui.testing.settle(MobileFrame.frame);
}

test "mobile sheets: a dragged or kept side sheet never shows wider than the cap" {
    var ctx = try shim.initSized(std.testing.allocator, .{ .w = 1366, .h = 1024 });
    defer ctx.deinit(std.testing.allocator);
    defer mobileTeardown(&ctx);
    try mobileCase(&ctx);
    try dvui.testing.settle(MobileFrame.frame);
    const editor = ctx.editor;
    const sheet = editor.regionFor(fizzy.sdk.keywords.ide.sidebar) orelse return error.TestUnexpectedResult;
    sheet.open();
    try dvui.testing.settle(MobileFrame.frame);
    try std.testing.expect(regionRect(editor, "Explorer").?.w <= 560 + 0.5);

    // A drag to 900 writes the extent and what is shown together.
    dvui.dataSet(null, sheet.id, "_size", @as(f32, 900));
    dvui.dataSet(null, sheet.id, "_shown", @as(f32, 900));
    // Every frame on the way back, not only the settled one: the ease starts at 900.
    for (0..4) |_| {
        _ = try dvui.testing.step(MobileFrame.frame);
        try std.testing.expect(regionRect(editor, "Explorer").?.w <= 560 + 0.5);
    }
    try dvui.testing.settle(MobileFrame.frame);
    try std.testing.expect(regionRect(editor, "Explorer").?.w <= 560 + 0.5);
    try std.testing.expect(dvui.dataGet(null, sheet.id, "_size", f32).? <= 560);

    // A smaller window in the same orientation lowers the cap: half of 900 is 450.
    try resizeWindow(&ctx, 900, 700);
    try std.testing.expect(regionRect(editor, "Explorer").?.w <= 450 + 0.5);
}

test "mobile sheets: turning the window with a sheet open shuts it, in both directions" {
    var ctx = try shim.initSized(std.testing.allocator, .{ .w = 768, .h = 1024 });
    defer ctx.deinit(std.testing.allocator);
    defer mobileTeardown(&ctx);
    try mobileCase(&ctx);
    try dvui.testing.settle(MobileFrame.frame);
    const editor = ctx.editor;
    const kw = fizzy.sdk.keywords.ide;
    (editor.regionFor(kw.sidebar) orelse return error.TestUnexpectedResult).open();
    try dvui.testing.settle(MobileFrame.frame);
    try std.testing.expect(!placeShut(editor, "Explorer"));
    // At the foot, across the window up to the cap.
    try std.testing.expect(regionRect(editor, "Explorer").?.w <= 560 + 16 + 0.5);

    // Turned on its side: what was open shuts, rather than a height being read as a width.
    try resizeWindow(&ctx, 1024, 768);
    try std.testing.expect(placeShut(editor, "Explorer"));
    try std.testing.expect(placeShut(editor, "Panel"));

    // Opened again it is a side sheet, no wider than the cap or half the window.
    (editor.regionFor(kw.sidebar) orelse return error.TestUnexpectedResult).open();
    try dvui.testing.settle(MobileFrame.frame);
    const side = regionRect(editor, "Explorer").?;
    try std.testing.expect(side.w <= 512 + 0.5);
    try std.testing.expect(side.h > 768 * 0.6);

    // And back upright: shut again, and the next one rises from the foot.
    try resizeWindow(&ctx, 768, 1024);
    try std.testing.expect(placeShut(editor, "Explorer"));
    (editor.regionFor(kw.panel) orelse return error.TestUnexpectedResult).open();
    try dvui.testing.settle(MobileFrame.frame);
    try std.testing.expectApproxEqAbs(1024 * 0.6 + 16, regionRect(editor, "Panel").?.h, 1);
}

/// Glass-layer frames: `n_items` rows of 50 points down a scroll area, each added to one layer.
const GlassLayerFrame = struct {
    const glass = fizzy.core.glass;
    const id: dvui.Id = @fromBackingInt(@intCast(802));
    var n_items: usize = 30;
    var viewport_y: f32 = 0;
    var max_diff: f32 = 0;
    var drawn: usize = 0;

    var si: dvui.ScrollInfo = .{ .vertical = .auto, .horizontal = .none };

    fn frame() !dvui.App.Result {
        var scroll = fizzy.core.widgets.ScrollArea.init(@src(), .{ .scroll_info = &si, .horizontal = .none, .vertical_bar = .hide }, .{ .expand = .both });
        defer {
            scroll.deinit();
            viewport_y = si.viewport.y;
        }
        var l = glass.layer(id, .{});
        var rects: [64]dvui.Rect.Physical = undefined;
        var expected: usize = 0;
        for (0..n_items) |i| {
            var box = dvui.box(@src(), .{}, .{ .id_extra = i, .expand = .horizontal, .min_size_content = .{ .w = 100, .h = 50 }, .margin = .all(5) });
            defer box.deinit();
            const r = box.data().borderRectScale().r;
            try std.testing.expect(l.add(.{ .shape = .{ .box = .{ .rect = r, .radii = @splat(8) } } }));
            if (glass.reaches(r)) {
                rects[expected] = r;
                expected += 1;
            }
        }
        l.end();
        const got = glass.drawnRects();
        try std.testing.expectEqual(expected, got.len);
        for (got, rects[0..expected]) |g, r| {
            max_diff = @max(max_diff, @abs(g.x - r.x), @abs(g.y - r.y), @abs(g.w - r.w), @abs(g.h - r.h));
        }
        drawn += got.len;
        return .ok;
    }
};

test "fling: the glass never trails its item" {
    var t = try dvui.testing.init(.{ .window_size = .{ .w = 300, .h = 400 } });
    defer t.deinit();
    const F = GlassLayerFrame;
    fizzy.core.LiquidField.readyInTest(true);
    F.n_items = 30;
    F.max_diff = 0;
    F.drawn = 0;
    const cw = dvui.currentWindow();
    try dvui.testing.settle(F.frame);
    // A touch flick up the screen at 10 points a frame, then 60 frames of coast.
    const x = 0.5;
    var y: f32 = 0.8;
    const h = cw.data().rect.h;
    const Step = struct {
        fn after(ms: u64) !void {
            const w = dvui.currentWindow();
            _ = try F.frame();
            _ = try w.end(.{});
            try w.begin(w.frame_time_ns + @as(i128, ms) * std.time.ns_per_ms);
        }
    };
    _ = try cw.addEventPointer(.{ .button = .touch0, .action = .press, .xynorm = .{ .x = x, .y = y } });
    try Step.after(16);
    for (0..10) |_| {
        _ = try cw.addEventTouchMotion(.touch0, x, y - 10 / h, 0, -10 / h);
        y -= 10 / h;
        try Step.after(16);
    }
    _ = try cw.addEventPointer(.{ .button = .touch0, .action = .release, .xynorm = .{ .x = x, .y = y } });
    try Step.after(16);
    const at_release = F.viewport_y;
    for (0..60) |_| try Step.after(16);
    // It did scroll, so the check was made on moving items, and the glass was on the same pixels.
    try std.testing.expect(F.viewport_y - at_release > 50);
    try std.testing.expect(F.drawn > 60);
    std.debug.print("fling: max |glass - item| = {d} px over {d} drawn shapes\n", .{ F.max_diff, F.drawn });
    try std.testing.expectEqual(0, F.max_diff);
}

test "a layer inside a scroll area is clipped to it" {
    var t = try dvui.testing.init(.{ .window_size = .{ .w = 300, .h = 400 } });
    defer t.deinit();
    const glass = fizzy.core.glass;
    fizzy.core.LiquidField.readyInTest(true);
    var scroll = fizzy.core.widgets.ScrollArea.init(@src(), .{ .horizontal = .none }, .{ .rect = .{ .x = 20, .y = 100, .w = 200, .h = 200 } });
    defer scroll.deinit();
    const clip = dvui.clipGet();
    // As a deferred context sees it: the layer is one command in the enclosing queue.
    var queues: dvui.RenderQueues = .{};
    const cw = dvui.currentWindow();
    const was_rendering = dvui.renderingSet(false);
    cw.defer_render = &queues;
    var l = glass.layer(GlassLayerFrame.id, .{});
    // Half the item is above the area's top edge.
    const card: dvui.Rect.Physical = .{ .x = clip.x + 10, .y = clip.y - 40, .w = 100, .h = 80 };
    try std.testing.expect(l.add(.{ .shape = .{ .box = .{ .rect = card, .radii = @splat(8) } } }));
    l.end();
    cw.defer_render = null;
    _ = dvui.renderingSet(was_rendering);
    try std.testing.expectEqual(1, queues.normal.items.len);
    const command = queues.normal.items[0];
    try std.testing.expect(command.cmd == .custom);
    // The clip in effect at `layer` rides with the command and is restored at replay, so the
    // glass quad is cut to the area as dvui's triangles are.
    try std.testing.expectEqual(clip, command.clip);
    try queues.render(cw);
    const drawn = glass.drawnRects();
    try std.testing.expectEqual(1, drawn.len);
    try std.testing.expectEqual(card, drawn[0]);
    try std.testing.expectEqual(card.h / 2, card.intersect(command.clip).h);
}
