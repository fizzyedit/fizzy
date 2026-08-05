//! `zig build bench-markdown` — frame-cost benchmark for the markdown preview's draw path.
//!
//! Drives the real preview renderer (`src/plugins/markdown`, the same entry point the editor's
//! preview pane and the plugin store's README pane call) over real markdown documents in dvui's
//! headless testing backend, and reports microseconds per frame. Deliberately *not* part of
//! `zig build test`: it prints timings rather than asserting, and timings are machine-dependent.
//!
//! What it can and can't tell you: the testing backend does no GPU work, so this measures the
//! CPU side — the cmark AST walk, widget construction, text shaping and layout. That is where
//! the preview's per-frame time actually goes; the GPU submission it omits doesn't change with
//! document size.
//!
//! Alongside the wall time it prints the renderer's own counters (`render_ast.stats`): how many
//! blocks were visited and how many text layouts / boxes were emitted for a single frame. Those
//! are what the wall time is a function of, and — unlike microseconds — they are exactly
//! reproducible, so they're the number to quote when comparing an optimization across machines.
//!
//! Always compare runs at the same `-Doptimize`. cmark and freetype compile at the app's
//! optimize level, so a Debug run measures unoptimized C and is several times slower than what
//! ships.

const std = @import("std");
const dvui = @import("dvui");
const markdown = @import("markdown");
const render_ast = markdown.render_ast;

/// Documents to render. These are the repo's own, wired in as anonymous imports from
/// `build/app.zig` rather than checked in as fixtures — `PLUGINS.md` is the document that
/// prompted this benchmark (single-digit fps in Debug), and the smaller ones separate costs
/// that scale with document size from those that don't.
const sample_huge = @embedFile("sample_huge"); // docs/PLUGINS.md
/// Same size as `sample_huge` but shaped completely differently: very long paragraphs (single
/// blocks of several thousand characters) and several tables. It is the document that stayed slow
/// after block virtualization, which is exactly why it is in here.
const sample_prose = @embedFile("sample_prose"); // docs/PLUGIN_MANIFEST_PLAN.md
const sample_medium = @embedFile("sample_medium"); // CLAUDE.md
const sample_small = @embedFile("sample_small"); // docs/MODULARIZATION_RELEASE_NOTES.md

/// Live document + preview state for the frame function, which `dvui.App.frameFunction`
/// requires to take no arguments.
var doc: []const u8 = "";
var preview: markdown.Preview = .{};
var gpa: std.mem.Allocator = undefined;
/// Width the preview is given this frame, or null for the whole window. Driven per frame by the
/// resize case — the preview pane really does change width every frame while a panel animates
/// open, and that used to invalidate every cached block height at once.
var forced_width: ?f32 = null;
var profile_blocks: bool = false;
var frame_times: [10]i128 = @splat(0);
var open_samples: std.ArrayListUnmanaged(render_ast.BlockSample) = .empty;

fn frame() !dvui.App.Result {
    var b = dvui.box(@src(), .{ .dir = .vertical }, .{
        .expand = if (forced_width == null) .both else .vertical,
        .min_size_content = if (forced_width) |w| dvui.Size{ .w = w } else null,
        .max_size_content = if (forced_width) |w| dvui.Options.MaxSize.width(w) else null,
    });
    defer b.deinit();

    // No `document_path`: that disables wikilink resolution, which needs a `Host` this harness
    // has no reason to stand up. It is also what the store's README pane passes, so this is a
    // path the app really takes rather than one invented for the benchmark.
    markdown.drawPreview(&preview, doc, gpa, .{
        .io = dvui.io,
        .image_base_dir = ".",
        .id_extra = 0,
    });
    return .ok;
}

/// Scrolls the way the user does — a real wheel event through dvui's own event routing.
/// Writing `ScrollInfo.viewport.y` directly instead puts the scroll container in a state its
/// own code never produces, which trips an overflow check inside dvui in ReleaseSafe.
fn sendScroll(ticks: f32) !void {
    const cw = dvui.currentWindow();
    _ = try cw.addEventMouseMotion(.{ .pt = .{ .x = 400, .y = 300 } });
    _ = try cw.addEventMouseWheel(ticks, .vertical, null);
}

fn nowNs() i128 {
    return std.Io.Clock.boot.now(dvui.io).nanoseconds;
}

const Case = struct {
    /// Wheel ticks sent once before the timed frames, to park the viewport somewhere other than
    /// the very top.
    park_scroll_ticks: f32 = 0,
    /// Lines scrolled per frame — 0 keeps the viewport still (the idle case, which is what the
    /// app spends nearly all its time in).
    scroll_lines_per_frame: f32 = 0,
    /// Change the pane's width every frame, as a panel's open animation and a window-resize drag
    /// both do. This is the case block-height caching is worst at, so it is the one to watch.
    resizing: bool = false,
    /// Off = the whole document is laid out every frame, which is what this renderer did before
    /// `render_ast.renderTopLevel` learned to skip off-screen blocks. Kept as a row in the output
    /// so the baseline is measured on the same machine and run as everything it is compared to.
    virtualize: bool = true,
};

/// Runs timed frames after letting the preview settle, and reports µs/frame plus the render
/// counters for one frame.
fn run(label: []const u8, sample: []const u8, case: Case) !void {
    doc = sample;
    preview = .{};
    render_ast.virtualize_blocks = case.virtualize;
    defer render_ast.virtualize_blocks = true;

    var t = try dvui.testing.init(.{
        .allocator = std.testing.allocator,
        .window_size = .{ .w = 1200, .h = 800 },
    });
    defer {
        // Preview first: it may own a running background parse worker holding the window
        // pointer it wakes on completion, and `Preview.deinit` is what joins that worker.
        // Destroying the window first left the worker refreshing freed memory.
        preview.deinit();
        t.deinit();
    }

    // Warm up: the first frames parse the document, build the glyph atlas and settle every
    // widget's min size, none of which recur.
    //
    // Parsing happens on a worker thread, so "run N frames" no longer implies the document
    // exists yet — and a fixed count silently stopped being enough the moment frames got fast.
    // In ReleaseFast the whole 15-frame warm-up finished in ~150us, the parse had not landed,
    // and every scenario below then measured the "Loading preview…" placeholder: 11us/frame,
    // 0us in renderDocument, and the counters left over from the *previous* document. Wait for
    // the document to actually be there.
    {
        var spins: usize = 0;
        while (preview.rs.blocks.len() == 0 and spins < 10_000) : (spins += 1) {
            _ = try dvui.testing.step(frame);
        }
        if (preview.rs.blocks.len() == 0) return error.MarkdownPreviewNeverParsed;
    }
    for (0..15) |_| _ = try dvui.testing.step(frame);

    if (case.park_scroll_ticks != 0) {
        try sendScroll(case.park_scroll_ticks);
        for (0..5) |_| _ = try dvui.testing.step(frame);
    }

    // Report the *minimum* of several rounds, not the mean: anything else running on the
    // machine can only make a round slower, so the fastest round is the closest estimate of the
    // work actually being measured.
    const rounds: usize = 5;
    const iters: usize = 30;
    var best_ns: i128 = std.math.maxInt(i128);
    var render_ns: u64 = 0;
    var counters: render_ast.Stats = .{};
    for (0..rounds) |_| {
        // Every round scrolls the same span, so the min across rounds compares like with like.
        if (case.scroll_lines_per_frame != 0) {
            try sendScroll(10_000);
            _ = try dvui.testing.step(frame);
        }
        const t0 = nowNs();
        render_ast.stats.render_ns = 0;
        for (0..iters) |i| {
            if (case.scroll_lines_per_frame != 0) try sendScroll(-case.scroll_lines_per_frame * 20);
            if (case.resizing) forced_width = 700 + @as(f32, @floatFromInt(i % 30)) * 15;
            _ = try dvui.testing.step(frame);
        }
        forced_width = null;
        const round_ns = nowNs() - t0;
        if (round_ns < best_ns) {
            best_ns = round_ns;
            render_ns = render_ast.stats.render_ns / iters;
            counters = render_ast.stats;
        }
    }
    const per_frame_us: u64 = @intCast(@divTrunc(best_ns, iters * 1000));

    if (profile_blocks) {
        var samples: std.ArrayListUnmanaged(render_ast.BlockSample) = .empty;
        defer samples.deinit(gpa);
        render_ast.block_profile = &samples;
        render_ast.block_profile_gpa = gpa;
        _ = try dvui.testing.step(frame);
        render_ast.block_profile = null;
        std.mem.sort(render_ast.BlockSample, samples.items, {}, struct {
            fn lt(_: void, a: render_ast.BlockSample, b: render_ast.BlockSample) bool {
                return a.ns > b.ns;
            }
        }.lt);
        for (samples.items[0..@min(6, samples.items.len)]) |worst| {
            std.debug.print("      block {d:>3} {s:<14} {d:>6} us  textlayouts={d} text={d}B\n", .{
                worst.index, worst.kind, worst.ns / 1000, worst.text_layouts, worst.add_text_bytes,
            });
        }
    }

    std.debug.print(
        "  {s:<30} {d:>6} us/frame ({d:>6} us in renderDocument)  blocks={d} textlayouts={d} boxes={d} addText={d}/{d}B\n",
        .{
            label,
            per_frame_us,
            render_ns / 1000,
            counters.blocks,
            counters.text_layouts,
            counters.boxes,
            counters.add_text_calls,
            counters.add_text_bytes,
        },
    );
}

/// What opening the file costs: the document is parsed, its blocks are placed for the first time,
/// and the preview settles — timed frame by frame, because this is the hitch the user actually
/// feels (and it lands while the preview panel is animating open, when frames are scarcest).
///
/// The window is warmed on a *different* document first. dvui's glyph atlas is per-window and the
/// app's window is long-lived, so a cold atlas would charge this measurement for rasterizing every
/// glyph — hundreds of microseconds per block, none of which the real app pays when opening its
/// second markdown file. Warming makes the number mean "opening a document", not "starting fizzy".
fn runOpen(sample: []const u8) !void {
    const rounds: usize = 5;
    const frames: usize = 10;
    var best_ns: i128 = std.math.maxInt(i128);
    for (0..rounds) |_| {
        var warm: markdown.Preview = .{};
        doc = sample_small;
        preview = warm;
        var t = try dvui.testing.init(.{
            .allocator = std.testing.allocator,
            .window_size = .{ .w = 1200, .h = 800 },
        });
        for (0..20) |_| _ = try dvui.testing.step(frame);
        warm = preview;
        warm.deinit();

        // Now open the document under test in that same, warm window.
        doc = sample;
        preview = .{};
        render_ast.stats.parse_ns = 0;
        var samples: std.ArrayListUnmanaged(render_ast.BlockSample) = .empty;
        defer samples.deinit(std.testing.allocator);
        if (profile_blocks) {
            render_ast.block_profile = &samples;
            render_ast.block_profile_gpa = std.testing.allocator;
        }
        const t0 = nowNs();
        var per: [10]i128 = @splat(0);
        var prev = t0;
        for (0..frames) |i| {
            _ = try dvui.testing.step(frame);
            if (i == 0) render_ast.block_profile = null;
            const now = nowNs();
            per[i] = @divTrunc(now - prev, 1000);
            prev = now;
        }
        if (nowNs() - t0 < best_ns) {
            best_ns = nowNs() - t0;
            frame_times = per;
            open_samples.clearRetainingCapacity();
            open_samples.appendSlice(std.testing.allocator, samples.items) catch {};
        }
        render_ast.block_profile = null;
        // Preview before window — see the note in `run`.
        preview.deinit();
        t.deinit();
    }

    if (profile_blocks) {
        std.mem.sort(render_ast.BlockSample, open_samples.items, {}, struct {
            fn lt(_: void, a: render_ast.BlockSample, b: render_ast.BlockSample) bool {
                return a.ns > b.ns;
            }
        }.lt);
        var total: u64 = 0;
        for (open_samples.items) |x| total += x.ns;
        std.debug.print("    first frame: {d} top-level blocks, {d} us in them\n", .{ open_samples.items.len, total / 1000 });
        for (open_samples.items[0..@min(4, open_samples.items.len)]) |x| {
            std.debug.print("      block {d:>3} {s:<14} {d:>6} us  textlayouts={d} text={d}B\n", .{ x.index, x.kind, x.ns / 1000, x.text_layouts, x.add_text_bytes });
        }
    }
    std.debug.print("  {s:<30} {d:>6} us for the first {d} frames ({d} us parsing)  each: {any}\n", .{ "opening the document", @divTrunc(best_ns, 1000), frames, render_ast.stats.parse_ns / 1000, frame_times });
}

test "bench: markdown preview frame cost" {
    gpa = std.testing.allocator;
    std.debug.print("\n== markdown preview frame cost — {s} ==\n", .{@tagName(@import("builtin").mode)});

    const cases = [_]struct { name: []const u8, text: []const u8 }{
        .{ .name = "huge (docs/PLUGINS.md)", .text = sample_huge },
        .{ .name = "prose (docs/PLUGIN_MANIFEST_PLAN.md)", .text = sample_prose },
        .{ .name = "medium (CLAUDE.md)", .text = sample_medium },
        .{ .name = "small (release notes)", .text = sample_small },
    };

    defer open_samples.deinit(std.testing.allocator);
    for (cases) |c| {
        std.debug.print(" {s}, {d} bytes\n", .{ c.name, c.text.len });
        profile_blocks = true;
        try runOpen(c.text);
        profile_blocks = false;
        try run("no virtualization (baseline)", c.text, .{ .virtualize = false });
        profile_blocks = true;
        try run("idle, top of document", c.text, .{});
        profile_blocks = false;
        try run("idle, viewport mid-document", c.text, .{ .park_scroll_ticks = -4000 });
        try run("scrolling 3 lines/frame", c.text, .{ .scroll_lines_per_frame = 3 });
        try run("resizing the pane every frame", c.text, .{ .resizing = true });
    }
}
