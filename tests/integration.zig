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

// -- content-swap reveal ------------------------------------------------------------------------

// `core.dvui.reveal` hides the one frame dvui needs to size newly-swapped content, then fades it
// in (see `src/core/reveal.zig`). The phase machine is unit-tested on its own; what needs a real
// window is the wiring — that the phases actually reach `dvui`'s alpha, that the animation is
// registered and completes, and that a settled pane ends fully opaque instead of stuck dim.

var reveal_key: u64 = 1;
var reveal_alpha: f32 = -1;

fn revealFrame() !dvui.App.Result {
    var b = dvui.box(@src(), .{ .dir = .vertical }, .{ .expand = .both });
    defer b.deinit();

    const rv = fizzy.core.dvui.reveal(b.data().id, reveal_key, .{});
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
// fades out over the incoming one — see `core.dvui.transition` and `Editor.drawActiveCenter`.
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
    return fizzy.Editor.drawActiveCenterForTest(center_frame_ctx);
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
    defer {
        editor.center_transition.discard();
        editor.host.center_providers.deinit(std.testing.allocator);
    }

    try editor.host.registerCenter(.{ .id = "test.center.a", .draw = centerADraw });
    try editor.host.registerCenter(.{ .id = "test.center.b", .draw = centerBDraw });

    editor.host.setActiveCenter("test.center.a");
    center_a_draws = 0;
    center_b_draws = 0;

    _ = try dvui.testing.step(centerFrame);
    _ = try dvui.testing.step(centerFrame);
    try std.testing.expectEqual(@as(usize, 2), center_a_draws);
    try std.testing.expectEqual(@as(usize, 0), center_b_draws);

    editor.host.setActiveCenter("test.center.b");
    _ = try dvui.testing.step(centerFrame);
    _ = try dvui.testing.step(centerFrame);

    // B took over immediately; A stopped dead; nothing is being held on to.
    try std.testing.expectEqual(@as(usize, 2), center_a_draws);
    try std.testing.expectEqual(@as(usize, 2), center_b_draws);
    try std.testing.expect(editor.center_transition.cross_fade.texture == null);
}

test "a center provider that disappears is not drawn for its own cross-fade" {
    // A plugin can be unloaded between frames, which is why the outgoing provider is looked up
    // again by id rather than cached — a stale `draw` pointer would be called on a dylib that is
    // no longer mapped.
    var ctx = try shim.init(std.testing.allocator);
    defer ctx.deinit(std.testing.allocator);

    const editor = ctx.editor;
    center_frame_ctx = editor;
    defer {
        editor.center_transition.discard();
        editor.host.center_providers.deinit(std.testing.allocator);
    }

    try editor.host.registerCenter(.{ .id = "test.center.a", .draw = centerADraw });
    try editor.host.registerCenter(.{ .id = "test.center.b", .draw = centerBDraw });
    editor.host.setActiveCenter("test.center.a");
    _ = try dvui.testing.step(centerFrame);

    center_a_draws = 0;
    center_b_draws = 0;

    // A goes away and B takes over in the same breath.
    _ = editor.host.center_providers.orderedRemove(0);
    editor.host.setActiveCenter("test.center.b");
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

fn markdownFrame() !dvui.App.Result {
    var b = dvui.box(@src(), .{ .dir = .vertical }, .{ .expand = .both });
    defer b.deinit();
    markdown.drawPreview(&md_preview, md_doc, std.testing.allocator, .{
        .io = dvui.io,
        .image_base_dir = ".",
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
    for ([_][]const u8{ md_sample, md_sample_tables }) |sample| for ([_]f32{ 0, -1200, -6000 }) |ticks| {
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
    for ([_][]const u8{ md_sample, md_sample_tables }) |sample| {
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
    for ([_][]const u8{ md_sample, md_sample_tables }) |sample| {
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
    for ([_][]const u8{ md_sample, md_sample_tables }) |sample| {
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
