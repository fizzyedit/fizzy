//! `zig build bench-text` — frame-cost benchmark for the text editor's draw path.
//!
//! Drives the real `TextEntryWidget` (the same one `TextEditor.zig` uses, with the same
//! options the editor passes it) over a real Zig source file in dvui's headless testing
//! backend, and reports microseconds per frame. Deliberately *not* part of `zig build test`:
//! it prints timings rather than asserting, and timings are machine-dependent.
//!
//! What it can and can't tell you: the testing backend does no GPU work, so this measures the
//! CPU side — tree-sitter query + capture walk, text shaping, layout, event handling. That is
//! where the editor's per-frame time actually goes (see the tree-sitter/shape split below);
//! the GPU submission it omits is the part that doesn't change with document size.
//!
//! Always compare runs at the same `-Doptimize`. The C libraries vendored inside dvui
//! (tree-sitter, the grammar, freetype) compile at the *app's* optimize level, so a Debug run
//! measures an unoptimized tree-sitter and is several times slower than what ships.

const std = @import("std");
const dvui = @import("dvui");
const TextEntryWidget = @import("text").TextEntryWidget;

/// Two of this repo's own sources — a big one, because that is where per-frame costs that scale
/// with document size show up, and a small one to expose which costs *don't* scale — plus dvui's
/// example query file. All three come in as anonymous imports wired in `build/app.zig` rather
/// than as checked-in fixtures: the repo is already full of Zig, and copies would be ~200KB to
/// keep in sync for no gain. They do drift as those files are edited, so treat numbers as
/// comparable within a session (which is what A/B work needs), not across months.
const sample_large = @embedFile("sample_large");
const sample_small = @embedFile("sample_small");
const ts_queries = @embedFile("ts_zig_queries");

/// dvui bundles the Zig grammar for its own examples; the real editor gets one from the
/// external `zig` language plugin instead. Same grammar, same query shape — what's being timed
/// (query + per-capture chunk emission) doesn't depend on which of the two supplied it.
extern fn tree_sitter_zig() callconv(.c) *dvui.c.TSLanguage;

const ts_highlights = [_]TextEntryWidget.HighlightStyle{
    .{ .name = "comment", .opts = .{ .color_text = .fromHex("6A9955") } },
    .{ .name = "keyword", .opts = .{ .color_text = .fromHex("569CD6") } },
    .{ .name = "identifier", .opts = .{ .color_text = .fromHex("D4D4D4") } },
    .{ .name = "function", .opts = .{ .color_text = .fromHex("DCDCAA") } },
    .{ .name = "type", .opts = .{ .color_text = .fromHex("4EC9B0") } },
    .{ .name = "string", .opts = .{ .color_text = .fromHex("CE9178") } },
};

/// Live document + knobs for the frame function, which `dvui.App.frameFunction` requires to
/// take no arguments.
var text: std.ArrayListUnmanaged(u8) = .empty;
var pending_sel: ?usize = null;
var cache_layout: bool = true;
var tree_sitter: bool = true;
var typing: bool = false;
/// Lines scrolled per frame, for the scrolling case — 0 keeps the viewport still.
var scroll_lines_per_frame: f32 = 0;
/// Wheel ticks sent once before the timed frames, to park the viewport somewhere other than the
/// very top — where the query range is clipped by the start of the document and so understates
/// what a mid-document frame really costs.
var park_scroll_ticks: f32 = 0;

fn frame() !dvui.App.Result {
    var te: TextEntryWidget = undefined;
    te.init(@src(), .{
        .multiline = true,
        .break_lines = false,
        .scroll_horizontal = true,
        .cache_layout = cache_layout,
        .text = .{ .array_list = .{
            .backing = &text,
            .allocator = std.testing.allocator,
            .limit = 64 * 1024 * 1024,
        } },
        .tree_sitter = if (tree_sitter) .{
            .language = @ptrCast(tree_sitter_zig()),
            .queries = ts_queries,
            .highlights = &ts_highlights,
        } else null,
        .tab_inserts_indent = true,
        .tab_size = 4,
        .insert_spaces = true,
        .auto_indent_newline = true,
        .auto_close_pairs = true,
        .highlight_matching_bracket = true,
    }, .{ .expand = .both });

    dvui.focusWidget(te.data().id, null, null);

    if (pending_sel) |c| {
        const sel = te.textLayout.selectionGet(te.len);
        sel.start = c;
        sel.cursor = c;
        sel.end = c;
        pending_sel = null;
    }

    te.processEvents();
    te.draw();
    te.deinit();
    return .ok;
}

/// Scrolls the way the user does — a real wheel event through dvui's own event routing.
/// Writing `ScrollInfo.viewport.y` directly instead puts the scroll container in a state its
/// own code never produces, which trips an overflow check inside dvui in ReleaseSafe.
fn sendScroll(ticks: f32) !void {
    const cw = dvui.currentWindow();
    _ = try cw.addEventMouseMotion(.{ .pt = .{ .x = 200, .y = 200 } });
    _ = try cw.addEventMouseWheel(ticks, .vertical, null);
}

fn nowNs() i128 {
    return std.Io.Clock.boot.now(dvui.io).nanoseconds;
}

/// Runs `iters` timed frames after letting the widget settle, and reports µs/frame.
fn run(label: []const u8, sample: []const u8, cursor: usize) !void {
    text.clearRetainingCapacity();
    try text.appendSlice(std.testing.allocator, sample);
    pending_sel = cursor;

    var t = try dvui.testing.init(.{ .allocator = std.testing.allocator });
    defer {
        t.deinit();
        text.deinit(std.testing.allocator);
        text = .empty;
    }

    // Warm up: first frames build the tree-sitter tree, the glyph atlas and the byte-height
    // cache, none of which recur.
    for (0..15) |_| _ = try dvui.testing.step(frame);

    if (park_scroll_ticks != 0) {
        try sendScroll(park_scroll_ticks);
        for (0..5) |_| _ = try dvui.testing.step(frame);
    }

    // Report the *minimum* of several rounds, not the mean. Anything else on the machine can
    // only ever make a round slower, so the fastest round is the closest estimate of the work
    // actually being measured — with the mean, a background compile moved results by 30%,
    // which is larger than most of the differences worth acting on.
    const rounds: usize = 5;
    const iters: usize = 60;
    var best_ns: i128 = std.math.maxInt(i128);
    for (0..rounds) |_| {
        // Every round scrolls the same span, so the min across rounds compares like with like.
        if (scroll_lines_per_frame != 0) {
            try sendScroll(10_000);
            _ = try dvui.testing.step(frame);
        }
        const t0 = nowNs();
        for (0..iters) |_| {
            if (typing) try dvui.testing.writeText("x");
            if (scroll_lines_per_frame != 0) try sendScroll(-scroll_lines_per_frame * 20);
            _ = try dvui.testing.step(frame);
        }
        best_ns = @min(best_ns, nowNs() - t0);
    }
    const per_frame_us: u64 = @intCast(@divTrunc(best_ns, iters * 1000));

    std.debug.print("  {s:<34} {d:>6} us/frame\n", .{ label, per_frame_us });
}

test "bench: text editor frame cost" {
    std.debug.print("\n== text editor frame cost — {s} ==\n", .{@tagName(@import("builtin").mode)});

    const cases = [_]struct { name: []const u8, text: []const u8 }{
        .{ .name = "large (Editor.zig)", .text = sample_large },
        .{ .name = "small (App.zig)", .text = sample_small },
    };

    for (cases) |c| {
        std.debug.print(" {s}, {d} bytes\n", .{ c.name, c.text.len });

        tree_sitter = true;
        cache_layout = true;
        typing = false;
        scroll_lines_per_frame = 0;
        try run("idle, top of file (the app)", c.text, 0);
        park_scroll_ticks = -400;
        try run("idle, viewport mid-document", c.text, 0);
        park_scroll_ticks = 0;

        scroll_lines_per_frame = 3;
        try run("scrolling 3 lines/frame", c.text, 0);
        tree_sitter = false;
        try run("scrolling, no highlighting", c.text, 0);
        tree_sitter = true;
        scroll_lines_per_frame = 0;
        scroll_lines_per_frame = 0;

        typing = true;
        try run("typing", c.text, 0);
        typing = false;

        tree_sitter = false;
        try run("idle, no syntax highlighting", c.text, 0);
        tree_sitter = true;
    }
}
