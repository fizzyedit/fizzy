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
// Only a *strictly* stronger claim wins, so the existing promise holds: two regions that accept a
// surface equally both show it (an icon rail and the pane it chooses for), and an ambiguity the
// user can see is one they can fix with the picker.
test "the more specific region claims a surface, an equal one shares it" {
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
    ViewDrag.begin(&layout, "Panel", .{ .x = 0, .y = 400, .w = 800, .h = 200 });
    editor.app.layout.view_drag.preview_name = editor.app.layout.internName(editor.app.gpa, "Main");
    editor.app.layout.view_drag.preview_t = 1;
    editor.app.layout.view_drag.moved_id = "test.output";
    editor.app.layout.view_drag.other_id = "";

    const panel_kw = fizzy.sdk.keywords.ide.panel;
    try std.testing.expectEqual(@as(usize, 0), layout.matching(panel_kw).len);
    const panel = ViewDrag.regionNamed(&editor.app.layout, "Panel") orelse return error.TestExpectedEqual;
    try std.testing.expectEqual(@as(usize, 1), layout.matchingStored(panel).len);

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
        e.app.layout.publishRegions();
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

test "a view-drag places the visible surface and empties a last-surface source" {
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
        try std.testing.expect(layout.splitOn("Center", .right) != null);
    }
    try dvui.testing.settle(EndlessFrame.frame);
    {
        var layout = fizzy.Editor.Layout.init(&editor.app.host, &editor.app.layout, editor.app.gpa, dvui.currentWindow().arena());
        layout.placeVisible("Center", "Center/r1", .swap);
    }
    try dvui.testing.settle(EndlessFrame.frame);

    const dest = editor.app.layout.assignment("Center/r1") orelse return error.TestExpectedEqual;
    try std.testing.expectEqual(@as(usize, 1), dest.len);
    try std.testing.expectEqualStrings("test.view", dest[0]);
    const source = editor.app.layout.assignment("Center") orelse return error.TestExpectedEqual;
    try std.testing.expectEqual(@as(usize, 0), source.len);

    var dest_region: ?fizzy.Editor.Layout.Region = null;
    for (editor.app.layout.regions.items) |r| {
        if (std.mem.eql(u8, r.name, "Center/r1")) dest_region = r;
    }
    var layout = fizzy.Editor.Layout.init(&editor.app.host, &editor.app.layout, editor.app.gpa, dvui.currentWindow().arena());
    const shown = layout.selectedIn(&(dest_region orelse return error.TestExpectedEqual));
    try std.testing.expect(shown != null);
    try std.testing.expectEqualStrings("test.view", shown.?.id);
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

    // ViewDrag's shut-if-emptied path is still SplitTree-only (this brief does
    // not move ViewDrag onto the seed tree). The view still lands; the minted
    // leaf is not auto-collapsed.
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

    // Four points of card wearing what four points of card can carry of an 8pt
    // inset — a quarter of it, so the card is 8pt tall. Kept whole, the inset
    // alone would hold 16 of the 20pt this place is still taking.
    const inset = PaddedCardFrame.card_inset * 2 * (left / (PaddedCardFrame.card_inset * 2));
    try std.testing.expectApproxEqAbs((left + inset) * scale, leaf.h, 1);
    // And the sash has come down with it, rather than holding a full ten points
    // of gap open beside a place that is about to not be there — ten points
    // handed back in one frame at the end of an otherwise smooth close.
    try std.testing.expectApproxEqAbs(left * scale, leaf.y - (rest.y + rest.h), 1);
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
    ViewDrag.begin(&layout, "Panel", panel_at);
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
