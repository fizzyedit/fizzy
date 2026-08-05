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
/// `pending_measure` is part of the condition and not just a nicety: a table block is marked
/// settled as soon as it has a height to stand on, long before its off-screen rows have been
/// measured, so waiting on block heights alone stops while the table is still hundreds of points
/// short of its real size.
fn markdownSettle() !void {
    for (0..600) |_| {
        _ = try dvui.testing.step(markdownFrame);
        var all = md_preview.rs.block_heights.items.len > 0;
        for (md_preview.rs.block_heights.items) |e| {
            if (!e.settled) all = false;
        }
        if (all and md_render_ast.stats.pending_measure == 0) return;
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
    md_preview = .{};
    defer md_preview.deinit();

    var t = try dvui.testing.init(.{ .allocator = gpa, .window_size = .{ .w = 900, .h = 700 } });
    defer t.deinit();

    try markdownSettle();

    if (wheel_ticks != 0) {
        const cw = dvui.currentWindow();
        _ = try cw.addEventMouseMotion(.{ .pt = .{ .x = 400, .y = 300 } });
        _ = try cw.addEventMouseWheel(wheel_ticks, .vertical, null);
        try markdownSettle();
    }

    const heights = try gpa.alloc(f32, md_preview.rs.block_heights.items.len);
    for (md_preview.rs.block_heights.items, heights) |entry, *out| out.* = entry.h;
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
