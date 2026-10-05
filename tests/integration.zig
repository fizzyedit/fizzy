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
const dvui = @import("dvui");
const fizzy = @import("fizzy");
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
/// Table-heavy: one of its tables is 45KB on its own, which is what makes it the document that
/// exercises row culling inside a table rather than only block skipping around it.
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
    var counts = [_]usize{0} ** 4;
    for (md_preview.rs.blocks.heights.items) |e| counts[@intFromEnum(e.state)] += 1;
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
        var sum: f32 = 0;
        for (virtualized.heights) |h| sum += h;
        try std.testing.expectApproxEqAbs(sum + 16, virtualized.virtual_h, 0.01);
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

// The user-visible complaint these two encode: on docs/PLUGIN_MANIFEST_PLAN.md, scrolling about
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

    // Three quarters of the way down — the region the instability was reported in, and on this
    // document the one holding the 45KB table.
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
// the errors pointed the same way, and docs/PLUGIN_MANIFEST_PLAN.md estimated at 24% of its real
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
// documents repeat themselves. docs/PLUGIN_MANIFEST_PLAN.md has seven top-level blocks sharing a
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
            var counts = [_]usize{0} ** 4;
            for (md_preview.rs.blocks.heights.items) |e| counts[@intFromEnum(e.state)] += 1;
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

    fn draw(_: ?*anyopaque) anyerror!dvui.App.Result {
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
            layout.split(@src(), .{});
            {
                var panel = try layout.region(@src(), .{
                    .name = "Panel",
                    .keywords = fizzy.sdk.keywords.ide.panel,
                    .shows = .many,
                    .resize = true,
                    .hide_when_empty = true,
                }, .{ .min_size_content = .{ .h = 220 }, .expand = .horizontal });
                defer panel.deinit();
            }
        }
        // As fizzy's frame does: the floats over the shape, before its regions are published.
        layout.drawFloats();
        e.app.layout.publishRegions();
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
    defer editor.app.layout.view_drag.discard();

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

// -- endless layout ------------------------------------------------------------------------------
// The example's own layout, not a shipped fizzy preset. Wired as `endless_layout` in
// `build/app.zig` from `examples/endless-app/src/layout.zig`.

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
        return .ok;
    }
};

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
    try std.testing.expectEqual(fizzy.Editor.Layout.Region.Shows.many, editor.app.layout.showsOf("Center", .one));
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
    defer editor.app.layout.view_drag.discard();
    VD.begin(&layout, "Center", .{ .w = 100, .h = 100 }, .{ .w = 100, .h = 100 });
    try std.testing.expect(!VD.removable(&layout));
    editor.app.layout.view_drag.discard();
    // Showing several, the trash takes just the view carried.
    editor.app.layout.setShows(editor.app.gpa, "Center", .many);
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
    defer editor.app.layout.view_drag.discard();
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
    editor.app.layout.setShows(editor.app.gpa, "Center", .many);
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

// A Multiple place draws its strip, then the selected view in a box of its own. Drawn into the
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
    editor.app.layout.setShows(editor.app.gpa, "Center", .many);
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

test "dragging a tab along a Multiple place's strip reorders its views" {
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
    editor.app.layout.setShows(editor.app.gpa, "Center", .many);
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
    defer editor.app.layout.view_drag.discard();
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
    defer editor.app.layout.view_drag.discard();
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
    defer editor.app.layout.view_drag.discard();
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
    const key: dvui.Id = @enumFromInt(0xd7_0b_f1_4e);

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
    editor.app.layout.registerRegion(editor.app.gpa, .{ .name = "Panel", .keywords = panel_kw, .bounds = panel_at, .shows = .many });
    editor.app.layout.publishRegions();

    DropFinishFrame.editor = editor;
    defer DropFinishFrame.editor = null;
    const DropZones = fizzy.core.widgets.DropZones;
    defer DropZones.forget(DropFinishFrame.key);

    {
        var layout = fizzy.Editor.Layout.init(&editor.app.host, &editor.app.layout, editor.app.gpa, dvui.currentWindow().arena());
        fizzy.Editor.Layout.ViewDrag.begin(&layout, "Panel", panel_at, panel_at);
    }
    defer editor.app.layout.view_drag.discard();
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
    editor.app.layout.view_drag.discard();
    editor.app.layout.registerRegion(editor.app.gpa, .{ .name = "Main/b0", .keywords = main_kw, .bounds = main_at });
    editor.app.layout.registerRegion(editor.app.gpa, .{ .name = "Panel", .keywords = panel_kw, .bounds = panel_at, .shows = .many });
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
    editor.app.layout.registerRegion(editor.app.gpa, .{ .name = "Panel", .keywords = panel_kw, .bounds = panel_at, .shows = .many });
    editor.app.layout.publishRegions();

    var layout = fizzy.Editor.Layout.init(&editor.app.host, &editor.app.layout, editor.app.gpa, dvui.currentWindow().arena());
    const ViewDrag = fizzy.Editor.Layout.ViewDrag;
    ViewDrag.begin(&layout, "Panel", panel_at, panel_at);
    defer editor.app.layout.view_drag.discard();

    try std.testing.expectEqualStrings("Main", ViewDrag.targetAt(&layout, middle, "Panel") orelse
        return error.TestExpectedEqual);

    // A pane that exists only because the preview is drawing the incoming view
    // is smaller than Main and sits right under the pointer. It still loses:
    // it was not there when the drag began.
    editor.app.layout.registerRegion(editor.app.gpa, .{ .name = "Main", .keywords = main_kw, .bounds = whole });
    editor.app.layout.registerRegion(editor.app.gpa, .{ .name = "Panel", .keywords = panel_kw, .bounds = panel_at, .shows = .many });
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
    editor.app.layout.registerRegion(editor.app.gpa, .{ .name = "Panel", .keywords = panel_kw, .bounds = panel_at, .shows = .many });
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

test "swapping a panel surface onto main leaves it only on main" {
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
    editor.app.layout.registerRegion(editor.app.gpa, .{ .name = "Panel", .keywords = panel, .id = .extendId(null, @src(), 2), .shows = .many });
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

    const dest = editor.app.layout.assignment("Main") orelse return error.TestExpectedEqual;
    try std.testing.expectEqual(@as(usize, 1), dest.len);
    try std.testing.expectEqualStrings("test.output", dest[0]);
    try std.testing.expectEqual(@as(usize, 1), layout.matching(main).len);
    try std.testing.expectEqualStrings("test.output", layout.matching(main)[0].id);
    try std.testing.expectEqual(@as(usize, 1), layout.matching(panel).len);
    try std.testing.expectEqualStrings("test.workspace", layout.matching(panel)[0].id);
}

// A shelf (shows many) takes a view; a slot (shows one) trades for it.
//
// Dragging Files out of the sidebar onto Main is the slot case: Main takes
// Files and sends its workspace back. The shelf must then *stop showing Files*
// — both in its match list and as its selection — or the explorer body keeps
// drawing Files beside the rail, which has already dropped the icon, until
// the user clicks some other icon. That is a chooser and a body that have
// stopped agreeing about what this place is.
test "a shelf adds a view and a slot trades for it" {
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
    editor.app.layout.registerRegion(editor.app.gpa, .{ .name = "Sidebar", .keywords = side, .id = .extendId(null, @src(), 2), .shows = .many });
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

    // Slot: Files leaves the shelf and trades with Main.
    layout.placeVisible("Sidebar", "Main", .swap);

    try std.testing.expectEqualStrings("test.files", layout.selected(main).?.id);
    try std.testing.expectEqual(@as(usize, 1), layout.matching(main).len);

    var files_still_here = false;
    for (layout.matching(side)) |s| {
        if (std.mem.eql(u8, s.id, "test.files")) files_still_here = true;
    }
    try std.testing.expect(!files_still_here);
    const after = layout.selected(side) orelse return error.TestExpectedEqual;
    try std.testing.expect(!std.mem.eql(u8, after.id, "test.files"));

    // Shelf: Files joins what is already there; Main is left empty rather
    // than taking the sidebar's current tab in trade.
    layout.placeVisible("Main", "Sidebar", .swap);
    var has_workspace = false;
    var has_files = false;
    for (layout.matching(side)) |s| {
        if (std.mem.eql(u8, s.id, "test.workspace")) has_workspace = true;
        if (std.mem.eql(u8, s.id, "test.files")) has_files = true;
    }
    try std.testing.expect(has_workspace);
    try std.testing.expect(has_files);
    try std.testing.expectEqual(@as(usize, 0), layout.matching(main).len);
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
    editor.app.layout.registerRegion(editor.app.gpa, .{ .name = "Pane 0", .keywords = pane, .id = .extendId(null, @src(), 1), .by_name = true, .kind_slot = true, .shows = .many, .on_drop = DropProbe.onDrop });
    editor.app.layout.registerRegion(editor.app.gpa, .{ .name = "Pane 1", .keywords = pane, .id = .extendId(null, @src(), 2), .by_name = true, .kind_slot = true, .shows = .many });
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
    defer editor.app.layout.view_drag.discard();

    const state = &editor.app.layout;
    const gpa = editor.app.gpa;
    const main_at: dvui.Rect.Physical = .{ .x = 0, .y = 0, .w = 800, .h = 400 };
    const pane_at: dvui.Rect.Physical = .{ .x = 100, .y = 40, .w = 600, .h = 320 };
    const panel_at: dvui.Rect.Physical = .{ .x = 0, .y = 400, .w = 800, .h = 200 };
    const doc_kw: []const []const u8 = &.{"main.document"};
    state.registerRegion(gpa, .{ .name = "Main", .keywords = fizzy.sdk.keywords.ide.main, .bounds = main_at, .size = .{ .w = 800, .h = 400 } });
    state.registerRegion(gpa, .{ .name = "Pane 0", .keywords = doc_kw, .by_name = true, .kind_slot = true, .shows = .many, .bounds = pane_at, .on_drop = DropProbe.onDrop });
    state.registerRegion(gpa, .{ .name = "Panel", .keywords = fizzy.sdk.keywords.ide.panel, .shows = .many, .bounds = panel_at });
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
    defer editor.app.layout.view_drag.discard();
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
    const near = DZ.wheel(.{ .x = 0, .y = 0, .w = 310, .h = 1000 }, 1, true);
    try std.testing.expectEqual(@as(f32, 0), near.strip);
    try std.testing.expect(near.shaped(1, .vertical).unit > near.unit);
}

const ShapeFrame = struct {
    var wheel: DZ.Wheel = undefined;
    const key: dvui.Id = @enumFromInt(0x5a_a9_e0_01);

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
    // Two bubbles closer than half the merge run together (`LiquidField`'s smooth minimum): at
    // rest each zone is a bubble of its own, whichever the shape and the way it runs, with the
    // trash and without. On the way from one shape to the other they may run together.
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
    try std.testing.expectEqual(@as(usize, (7 + 3 * LF.max_shapes) * 16), @sizeOf(LF.Uniforms));
    const u = f.pack(.{ .x = 0, .y = 0, .w = 400, .h = 100 }, false, g.order[0..f.len]);
    try std.testing.expectEqual(@as(f32, 22), u.shapes[1][0][0]);
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

const DemoStage = struct {
    keyframes: usize = 0,
    commands: usize = 0,
    fast: bool = false,
    begun: bool = false,
    /// Off, the player seeks from keyframes alone.
    snapshots: bool = true,
    restores: usize = 0,

    /// The whole of this app's model.
    const Snap = struct { text: []u8, clicks: usize, commands: usize };

    fn stage(self: *DemoStage) automation.Stage {
        return .{ .ctx = self, .vtable = &.{
            .begin = begin,
            .end = end,
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
    fn command(ctx: *anyopaque, id: []const u8) void {
        if (std.mem.eql(u8, id, "demo.ping")) demo_commands += 1;
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
var demo_stage: DemoStage = .{};
var demo_player: automation.Player = undefined;
/// What the harness hands `Player.frames` as the backend's clock: the testing backend has none of
/// its own, and its next frame's time comes from the last one's (`dvui.testing.step`) anyway.
var demo_clock: i128 = 0;
var demo_clock_on: bool = true;

/// The app's frame function, as an app runs it: through the player, which repeats it unseen
/// while a seek catches up.
fn demoFrame() !dvui.App.Result {
    return demo_player.frames(dvui.currentWindow(), demoRun, if (demo_clock_on) &demo_clock else null);
}

/// One run of the frame.
fn demoRun() !dvui.App.Result {
    demo_player.frame();
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
    automation.overlay.draw(&demo_player);
    return .ok;
}

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
    demo_stage = .{};
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

test "demo: a person's click pauses it, and resuming undoes what they did first" {
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

    // Resume: the replay puts the tape's own state back before carrying on.
    demo_player.play();
    try std.testing.expectEqual(automation.Player.State.seeking, demo_player.state);
    try stepDemoUntil(.playing, 200);
    try std.testing.expectEqual(@as(usize, 1), demo_clicks);
    try std.testing.expect(!demo_player.diverged);
    try stepDemoUntil(.ended, 400);
    try std.testing.expectEqualStrings("> hello world", demo_text.items);
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
        s.check = automation.Player.check;
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
        const bytes = try automation.binary.encode(std.testing.allocator, owned.tape);
        defer std.testing.allocator.free(bytes);
        var back = try automation.Tape.load(std.testing.allocator, bytes, automation.Player.check);
        defer back.deinit();
        try std.testing.expectEqualDeep(owned.tape, back.tape);
    }
}

test "demo: the hand-written sample tape parses and round-trips" {
    const source = @embedFile("demo_sample_tape");
    var owned = try automation.Tape.parse(std.testing.allocator, source, automation.Player.check);
    defer owned.deinit();
    try std.testing.expectEqualStrings("hello", owned.tape.name);
    try std.testing.expectEqualStrings(".split", owned.tape.keyframes[0].settings[0].value);

    var out: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();
    try owned.tape.write(&out.writer);
    const again = try std.testing.allocator.dupeZ(u8, out.written());
    defer std.testing.allocator.free(again);
    var back = try automation.Tape.parse(std.testing.allocator, again, automation.Player.check);
    defer back.deinit();
    try std.testing.expectEqual(owned.tape.ops.len, back.tape.ops.len);
    try std.testing.expectEqual(owned.tape.duration(), back.tape.duration());

    // `Tape.load` takes the source as it is and the binary form alike.
    var loaded = try automation.Tape.load(std.testing.allocator, source, automation.Player.check);
    defer loaded.deinit();
    const bytes = try automation.binary.encode(std.testing.allocator, owned.tape);
    defer std.testing.allocator.free(bytes);
    var from_binary = try automation.Tape.load(std.testing.allocator, bytes, automation.Player.check);
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
    const text = try gpa.dupeZ(u8, out.written());
    defer gpa.free(text);
    const saved = try std.zon.parse.fromSliceAlloc([]fizzy.backend.SavedRegion, gpa, text, null, .{ .ignore_unknown_fields = true });
    defer std.zon.parse.free(gpa, saved);

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
    state.registerRegion(gpa, .{ .name = "Panel", .keywords = fizzy.sdk.keywords.ide.panel, .bounds = panel_at, .shows = .many });
    // The float's place, drawn in its window: layer 1.
    state.layer_building = 1;
    state.registerRegion(gpa, .{ .name = "Float 1", .keywords = fizzy.Editor.Layout.slot_keywords, .by_name = true, .shows = .many, .bounds = body });
    state.layer_building = 0;
    state.publishRegions();
    _ = try state.floats.add(gpa, .{
        .name = "Float 1",
        .rect = .{ .x = 100, .y = 50, .w = 150, .h = 130 },
        .home = "Panel",
        .fresh = false,
        .win_id = @enumFromInt(0xf10a7),
        .bounds = window,
        .header = header,
    });

    var layout = fizzy.Editor.Layout.init(&editor.app.host, state, gpa, dvui.currentWindow().arena());
    const ViewDrag = fizzy.Editor.Layout.ViewDrag;
    ViewDrag.begin(&layout, "Panel", panel_at, panel_at);
    defer state.view_drag.discard();

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
        state.registerRegion(gpa, .{ .name = "Panel", .keywords = fizzy.sdk.keywords.ide.panel, .bounds = panel_at, .shows = .many });
        if (hidden) state.registerRegion(gpa, .{ .name = "Main/r1", .keywords = fizzy.sdk.keywords.ide.main, .bounds = hidden_at });
        // The float's place, drawn in its window: layer 1.
        state.layer_building = 1;
        state.registerRegion(gpa, .{ .name = "Float 1", .keywords = fizzy.Editor.Layout.slot_keywords, .by_name = true, .shows = .many, .bounds = place });
        state.layer_building = 0;
        state.publishRegions();
        _ = try state.floats.add(gpa, .{
            .name = "Float 1",
            .rect = .{ .x = 100, .y = 50, .w = 150, .h = 130 },
            .home = "Panel",
            .fresh = false,
            .win_id = @enumFromInt(0xf10a7),
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
    defer editor.app.layout.view_drag.discard();

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
    defer editor.app.layout.view_drag.discard();

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
    defer editor.app.layout.view_drag.discard();
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
    defer editor.app.layout.view_drag.discard();
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
    // view aims at.
    const body: dvui.Point.Physical = .{ .x = bounds.x + 12, .y = bounds.y + bounds.h - 12 };
    try pointTo(body, ManyPanelFrame.frame, 1);
    try std.testing.expect(editor.app.layout.view_drag.ghost_firm);
    try restOn(editor, body, ManyPanelFrame.frame);
    try std.testing.expect(editor.app.layout.view_drag.ghost_firm);
    try std.testing.expectEqual(@as(f32, 0), asideOf(editor, 0));
    try std.testing.expectEqualStrings("Float 1", ViewDrag.targetAt(&layout, body, "Float 1") orelse return error.TestExpectedEqual);

    // Off it again, and let go over nothing: back as it was.
    try pointTo(try offFloat(bounds), ManyPanelFrame.frame, ghost_frames);
    try std.testing.expectEqual(@as(f32, 1), asideOf(editor, 0));
    editor.app.layout.view_drag.discard();
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
    defer state.view_drag.discard();

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
    defer state.view_drag.discard();

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
    editor.app.layout.view_drag.discard();
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
    editor.app.layout.view_drag.discard();
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
    editor.app.layout.view_drag.discard();

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
    defer editor.app.layout.view_drag.discard();
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
    defer state.view_drag.discard();

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

test "a frost never captures more than the picture it reads" {
    const within = fizzy.core.widgets.BlurBackdrop.within;
    const Rect = dvui.Rect.Physical;
    const win: Rect = .{ .w = 2400, .h = 1600 };
    // Partly off the window, and smaller than it: kept whole, and so its capture size.
    const edge: Rect = .{ .x = 2300, .y = 10, .w = 400, .h = 300 };
    try std.testing.expectEqual(edge, within(edge, win).?);
    // A view drag's drop zones across the main window and a float's band 100000 pixels on: cut to
    // the window (it asked Metal for a texture 46424 pixels wide).
    const across = within(.{ .x = 1800, .y = 200, .w = 100600, .h = 900 }, win).?;
    try std.testing.expectEqual(@as(f32, 1800), across.x);
    try std.testing.expectEqual(@as(f32, 600), across.w);
    try std.testing.expectEqual(@as(f32, 900), across.h);
    // Wholly in the band: nothing of the window.
    try std.testing.expectEqual(@as(?Rect, null), within(.{ .x = 100000, .y = 0, .w = 3000, .h = 100 }, win));
    // Smaller than the picture but nowhere on it — the main window's drop zones replayed into a
    // float window's target in its band: nothing, rather than pixels from past its edge.
    const band: Rect = .{ .x = 100000, .y = 400, .w = 712, .h = 878 };
    try std.testing.expectEqual(@as(?Rect, null), within(.{ .x = 900, .y = 300, .w = 500, .h = 700 }, band));
}
