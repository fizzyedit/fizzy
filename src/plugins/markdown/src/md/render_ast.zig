const std = @import("std");
const builtin = @import("builtin");
const Io = std.Io;

const dvui = @import("dvui");
const sdk = @import("fizzy_sdk");

const md = @import("cmark_parse.zig");
const net_image = @import("net_image.zig");
const html_images_mod = @import("html_images.zig");
const image_format = @import("image_format.zig");
const url_join = @import("url_join.zig");
const wikilink_scan = @import("wikilink_scan.zig");
const bh = @import("block_heights.zig");

const WikilinkApi = sdk.services.wikilink.Api;

/// Where one `[[wikilink]]` resolved to, memoized per resolver generation.
pub const ResolvedLink = struct {
    status: WikilinkApi.Status,
    /// Absolute target path, gpa-owned. Empty unless `status` is `.resolved`/`.ambiguous`.
    path: []u8 = &.{},
    /// 0-based line to reveal (a `#heading` that was found).
    line: u32 = 0,
};

/// Memo key for one link: which text node, and which link within it. Node pointers are stable
/// for the life of the AST, and the whole memo is dropped when the AST is rebuilt.
fn wikilinkMemoKey(node: md.Node, token_index: usize) u64 {
    return std.hash.Wyhash.hash(@intFromPtr(node.n), std.mem.asBytes(&token_index));
}

const is_windows = builtin.target.os.tag == .windows;

/// What one `renderDocument` call emitted, for `zig build bench-markdown`. Wall time varies by
/// machine and build mode; these counts don't, so they're the reproducible half of a before/after
/// comparison — and they're what the wall time is a function of, since every widget here costs a
/// layout pass and every `addText` costs text shaping.
///
/// Always on: incrementing a counter next to a widget construction is unmeasurable against the
/// widget itself, and a build-mode gate would mean the numbers stop existing in exactly the
/// release build worth checking.
pub const Stats = struct {
    /// `renderBlock` calls (every block node reached, visible or not).
    blocks: u32 = 0,
    /// `dvui.textLayout` widgets created.
    text_layouts: u32 = 0,
    /// `dvui.box` widgets created.
    boxes: u32 = 0,
    add_text_calls: u32 = 0,
    add_text_bytes: u64 = 0,
    /// Off-screen blocks and table rows whose height this frame is a cached guess that hasn't been
    /// confirmed by two agreeing layout passes yet — the work the per-frame measuring budgets
    /// (`resettle_budget`, `table_measure_bytes`) have deferred.
    ///
    /// `renderDocument` asks for another frame while this is non-zero, which is what makes the
    /// budgets a way of *spreading* layout across frames rather than skipping it. Without that,
    /// deferred work stalls whenever a frame happens to change no widget's size: dvui only
    /// redraws when something asks it to, and a cached height asks for nothing by construction.
    pending_measure: u32 = 0,
    /// Nanoseconds spent parsing + pre-scanning the document, **accumulated** — one-time work
    /// that lands entirely on the frame a document is opened on, which is the frame the user
    /// feels as a hitch. Kept separate from `render_ns` so the two can be told apart.
    parse_ns: u64 = 0,
    /// Nanoseconds inside `renderDocument`, **accumulated** across frames — the benchmark zeroes
    /// it and divides by its own iteration count. Everything else is per-document-draw.
    render_ns: u64 = 0,
};

pub var stats: Stats = .{};

/// Per-top-level-block timing for `zig build bench-markdown`. Off unless a profiler is installed,
/// because it costs two clock reads per block.
pub const BlockSample = struct {
    index: usize,
    kind: [:0]const u8,
    ns: u64,
    text_layouts: u32,
    add_text_bytes: u64,
};
pub var block_profile: ?*std.ArrayListUnmanaged(BlockSample) = null;
pub var block_profile_gpa: ?std.mem.Allocator = null;

/// Where a block sits and how much its height can be believed — see `block_heights.zig`. That
/// bookkeeping is deliberately dvui-free and unit tested; this file owns the half that needs a
/// layout pass, and feeds measurements back through `Table.record`.
pub const SourceExtent = bh.SourceExtent;

/// One table cell's measured content size. `settled` follows the same two-agreeing-draws rule as
/// `bh.Height`, and for the same reason.
pub const CellSize = struct {
    size: dvui.Size,
    /// The column width the size was measured at. A wrapped cell's height is a function of the
    /// width it was laid out in, so a height on its own says nothing — and the widths a grid
    /// hands out before any cell has reported what it needs are placeholders (`colWidth` returns
    /// a flat 100 for a column it has never sized). Two draws at a placeholder width agree with
    /// each other perfectly, so without recording the width, a cell measured on a table's first
    /// frames settles at one line and stays there.
    col_w: f32,
    settled: bool,
};

/// One table's column widths, and the inputs they were computed from. Recomputed when either
/// input moves — the pane resizing, or the theme's body font changing size under it.
pub const TableLayout = struct {
    /// What each column wants on one unwrapped line, padding included (gpa-owned).
    ///
    /// Held separately from `widths` because it depends only on the table's *content* and the
    /// fonts — never on how much room the table has. Measuring it means walking every cell in the
    /// table and shaping its text, which on a 45KB table is milliseconds; recomputing that on
    /// every frame of a sash drag (where only `avail` is moving) was most of what made dragging
    /// the splitter crawl.
    natural: []f32,
    /// `natural` squeezed into `avail` (gpa-owned). Recomputed whenever `avail` moves, which is
    /// cheap — `fitColumns` is a couple of passes over one float per column.
    widths: []f32,
    /// Width the table had to fit into.
    avail: f32,
    /// The width of an "M" in each font the widths were measured with, body and mono. A probe
    /// rather than `Font.size`, because the size is not what moves: the app installs its themed
    /// fonts a few frames into startup, so a table measured before that was measured in a
    /// different *family* at the same nominal size, and every column came out too narrow.
    body_m: f32,
    mono_m: f32,
};

/// Escape hatch for tests: with this off, `renderTopLevel` lays out every block (and every table
/// row), on screen or not.
///
/// Turned off only by `tests/integration.zig`'s "skipping off-screen blocks lays the document out
/// identically", which is what keeps this honest — it asserts that virtualized and full layouts
/// agree on **every top-level block's height and the resulting virtual size**, at several scroll
/// positions, on both sample documents. Not on pixels: dvui's testing backend has no render
/// targets, so `capturePng` is unavailable. Layout equality is the property that matters anyway —
/// a remembered height drifting from the measured one is exactly what would shift the document
/// and make the scrollbar lie.
///
/// It can stay a plain global because that same test is what would catch a divergence if some
/// future caller ever set it.
pub var virtualize_blocks: bool = true;

/// `FIZZY_MD_DIAG=1` logs the two things that make this preview jump: the column width being
/// treated as "still resizing", and a block's height changing under the reader.
///
/// Env-gated because the useful version is noisy — it prints per block per frame — and because
/// every real cause found in this file so far was found by measuring, not by reasoning. A profile
/// says where time goes; this says what moved.
pub var diag: bool = false;

pub fn initDiagFromEnv() void {
    if (comptime builtin.target.cpu.arch == .wasm32) return;
    const raw = std.c.getenv("FIZZY_MD_DIAG") orelse return;
    if (std.mem.eql(u8, std.mem.span(raw), "0")) return;
    diag = true;
    dvui.log.info("markdown: height diagnostics on (FIZZY_MD_DIAG)", .{});
}

/// A height change at least this large is worth reporting — bigger than any settling wobble.
const diag_height_jump: f32 = 50;

/// Off-screen blocks `renderTopLevel` may re-measure per frame after a width change. Bounds what
/// a resize costs: without it, every frame of a window drag or a panel's open animation is a
/// full-document layout, which is the whole cost this virtualization exists to remove.
///
/// Each block needs two draws to settle (dvui sizes a widget from what its children reported the
/// frame before), so a 180-block document is fully accurate again about 30 frames after the drag
/// stops. Until then the only thing that is off is the scrollbar's idea of the total height.
const resettle_below_budget: usize = 12;

/// Off-screen blocks *above* the viewport top that may be re-measured per frame. Smaller than
/// `resettle_below_budget`: re-measuring one of these shifts the content under the reader for a
/// single frame before the anchor restores it. Non-zero because "never" leaves the scrollbar's
/// total permanently wrong. See the two-budget note in `renderTopLevel`.
const resettle_above_budget: usize = 4;

/// Off-screen table text (in bytes of markdown) that may be measured per frame the first time a
/// table is seen. Same idea as `resettle_budget`, one level down: a 45KB table
/// (docs/PLUGIN_MANIFEST_PLAN.md has one) costs several milliseconds to lay out in full, and
/// doing that on the frame the document opens is the hitch this whole file is about. Spread over
/// frames instead, the table's height is briefly short — by however many rows are still unmeasured
/// — and settles within half a second.
///
/// Counted in bytes rather than rows because rows differ wildly: this document's big table runs
/// ~2KB to a row, where an ordinary one runs ~50. A row budget that is gentle for the second is
/// several milliseconds a frame for the first.
const table_measure_bytes: u64 = 4000;

/// Table text (in bytes) laid out on the frame a table is first seen, before any of its geometry
/// exists — enough to fill a screen with something.
///
/// On that frame every row reports the grid's default height (a single line), so *every* row of a
/// tall table looks like it fits on screen and the visibility test above lets all of them through
/// — which is how one 45KB table came to cost 4.6ms on the frame its document opened. Capping the
/// first sight to roughly a screenful, and letting `table_measure_bytes` bring in the rest over
/// the next frames, is what keeps that frame cheap. From the second frame on the row heights are
/// real and the cap no longer applies.
const table_first_sight_bytes: u64 = 8000;

inline fn statBlock() void {
    stats.blocks += 1;
}

/// `dvui.textLayout` + the counter, so no call site can add one without the other.
inline fn textLayout(src: std.builtin.SourceLocation, init_opts: dvui.TextLayoutWidget.InitOptions, opts: dvui.Options) *dvui.TextLayoutWidget {
    stats.text_layouts += 1;
    return dvui.textLayout(src, init_opts, opts);
}

inline fn box(src: std.builtin.SourceLocation, init_opts: dvui.BoxWidget.InitOptions, opts: dvui.Options) *dvui.BoxWidget {
    stats.boxes += 1;
    return dvui.box(src, init_opts, opts);
}

inline fn addText(tl: *dvui.TextLayoutWidget, txt: []const u8, opts: dvui.Options) void {
    stats.add_text_calls += 1;
    stats.add_text_bytes += txt.len;
    tl.addText(txt, opts);
}

// Extension node kinds that cmark-gfm identifies by type string rather than
// integer constant.  Precomputed once after parsing so rendering never calls
// typeString() or any C FFI inside the per-frame draw loop.
pub const ExtNodeKind = enum { table, table_row, table_header, table_cell, strikethrough };

/// All precomputed per-AST render data.  Lives in MarkDownPreviewWidget.State,
/// rebuilt whenever the content hash changes, freed on deinit.
pub const RenderState = struct {
    /// abs_path (gpa-owned) → raw image bytes (gpa-owned).
    image_cache: std.StringHashMapUnmanaged([]u8) = .empty,
    /// @intFromPtr(bytes.ptr) → natural image size, cached to avoid per-frame stbi_info.
    image_sizes: std.AutoHashMapUnmanaged(usize, dvui.Size) = .empty,
    /// Set of @intFromPtr(bytes.ptr) for image bytes stb could not decode. Without this, a
    /// corrupt image re-enters stbi from
    /// *both* the preload pass and the render pass on every single frame, each attempt logging a
    /// dvui warning, for as long as the document is open. Recorded once, then the placeholder
    /// path is taken.
    image_decode_failed: std.AutoHashMapUnmanaged(usize, void) = .empty,
    /// @intFromPtr(node.n) → ExtNodeKind (extension nodes only).
    ext_node_kinds: std.AutoHashMapUnmanaged(usize, ExtNodeKind) = .empty,
    /// Set of @intFromPtr(node.n) for every node whose subtree contains an IMAGE.
    subtree_has_image: std.AutoHashMapUnmanaged(usize, void) = .empty,
    /// Set of @intFromPtr(node.n) for every node whose subtree contains a TABLE. A table is
    /// drawn with `dvui.grid`, which is a scroll container — and a scroll container lays out only
    /// the rows inside its own viewport, so an off-screen table measures as its header alone.
    /// That makes it the one block whose height `renderTopLevel` may not believe unless the block
    /// was really on screen.
    subtree_has_table: std.AutoHashMapUnmanaged(usize, void) = .empty,
    /// @intFromPtr(table_node.n) → column count (from header row).
    /// Avoids re-traversing the header row every render frame.
    table_col_counts: std.AutoHashMapUnmanaged(usize, usize) = .empty,
    /// @intFromPtr(item_node.n) → checked, for `- [ ]` / `- [x]` items only.
    /// Absence means "plain bullet", which is what distinguishes an *unchecked* task item
    /// from a normal one (both report `taskListItemChecked() == false`).
    task_items: std.AutoHashMapUnmanaged(usize, bool) = .empty,
    /// @intFromPtr(html_node.n) → every `<img>` in that raw-HTML node (src + requested size), in
    /// document order (gpa-owned). Absent when the node has no `<img>`.
    html_images: std.AutoHashMapUnmanaged(usize, []html_images_mod.Image) = .empty,
    /// @intFromPtr(text_node.n) → the `[[wikilinks]]` in that node's literal, in document order
    /// (gpa-owned). Absent when the node has none, which is the common case and the fast path.
    ///
    /// Content-derived only — token *positions*, never resolution results. Resolution lives in
    /// `wikilink_resolved` below and deliberately does not belong here: this map is rebuilt only
    /// when the document's content hash changes, but a link flips from broken to resolved when
    /// its *target file* is created, which doesn't touch this document at all.
    wikilinks: std.AutoHashMapUnmanaged(usize, []wikilink_scan.Token) = .empty,
    /// `wikilinkMemoKey(node, token_index)` → where that link resolved to. Valid only while
    /// `wikilink_generation` matches the resolver's `generation()`; cleared wholesale when it
    /// moves. Owns its paths (gpa).
    wikilink_resolved: std.AutoHashMapUnmanaged(u64, ResolvedLink) = .empty,
    /// Resolver generation `wikilink_resolved` was populated against. `maxInt` means "nothing
    /// memoized yet", which no real generation counter will collide with.
    wikilink_generation: u64 = std.math.maxInt(u64),

    /// Where every top-level block sits, in document order: its source extent (enough to guess a
    /// height before it has ever been laid out) and its measured height once it has. Without the
    /// guess, opening a document costs one full-document layout (~13-20ms in ReleaseFast for a
    /// 60KB file, landing on the frame a panel is animating open), because a block with no height
    /// cannot be placed and so cannot be skipped.
    blocks: bh.Table = .{},
    /// Content size each table cell measured at, keyed by @intFromPtr(cell node) — what a culled
    /// row hands the grid in place of its contents. It has to be the cell's *own* measurement and
    /// not the grid's row height / column width: the grid takes the max across a column, so
    /// feeding those back widens the column a little, which rewraps a visible cell and moves the
    /// whole table. (Measured the hard way: it showed up as one extra line of text in one row.)
    cell_sizes: std.AutoHashMapUnmanaged(usize, CellSize) = .empty,
    /// Rows in the block currently being laid out whose cells have never been measured, so they
    /// stood in with a placeholder height this frame.
    ///
    /// This is what makes a table block's measurement *untrustworthy*: the grid reports a height
    /// built from whatever mix of real and placeholder rows this frame happened to have, and that
    /// mix is a function of where the reader is scrolled — so the same table measures differently
    /// depending on how you arrived at it. Believing those numbers is what made the document jump
    /// when scrolling past a table. Reset per top-level block by `renderTopLevel`.
    block_rows_pending: usize = 0,
    /// The block being laid out has spent its re-measure attempts (see
    /// `block_heights.deferred_max_attempts`). Its table rows must then stop reporting themselves
    /// as owed work: `Stats.pending_measure` asks for another frame, and a table whose cells never
    /// settle would otherwise keep the whole app awake for ever.
    block_measure_exhausted: bool = false,
    /// Whether the text column changed width this frame — a sash drag, a window resize, a panel
    /// animating open. Set by `renderTopLevel`, read by the table renderer, which spends its own
    /// measuring budgets and needs the same answer for the same reason: work done at a width that
    /// is about to change again is work thrown away.
    width_in_flux: bool = false,
    /// @intFromPtr(table_node.n) → the column widths that table is laid out at (gpa-owned), plus
    /// what they were computed for. See `tableColumnWidths`.
    table_layouts: std.AutoHashMapUnmanaged(usize, TableLayout) = .empty,

    pub fn deinit(self: *RenderState, gpa: std.mem.Allocator) void {
        self.clear(gpa);
        self.image_cache.deinit(gpa);
        self.image_sizes.deinit(gpa);
        self.image_decode_failed.deinit(gpa);
        self.ext_node_kinds.deinit(gpa);
        self.subtree_has_image.deinit(gpa);
        self.subtree_has_table.deinit(gpa);
        self.table_col_counts.deinit(gpa);
        self.task_items.deinit(gpa);
        self.html_images.deinit(gpa);
        self.wikilinks.deinit(gpa);
        self.wikilink_resolved.deinit(gpa);
        self.blocks.deinit(gpa);
        self.cell_sizes.deinit(gpa);
        self.table_layouts.deinit(gpa);
    }

    pub fn clear(self: *RenderState, gpa: std.mem.Allocator) void {
        var it = self.image_cache.iterator();
        while (it.next()) |kv| {
            gpa.free(kv.key_ptr.*);
            gpa.free(kv.value_ptr.*);
        }
        self.image_cache.clearRetainingCapacity();
        self.image_sizes.clearRetainingCapacity();
        self.image_decode_failed.clearRetainingCapacity();
        self.ext_node_kinds.clearRetainingCapacity();
        self.subtree_has_image.clearRetainingCapacity();
        self.subtree_has_table.clearRetainingCapacity();
        self.table_col_counts.clearRetainingCapacity();
        self.task_items.clearRetainingCapacity();
        var hi = self.html_images.valueIterator();
        while (hi.next()) |urls| html_images_mod.free(urls.*, gpa);
        self.html_images.clearRetainingCapacity();
        var wi = self.wikilinks.valueIterator();
        while (wi.next()) |toks| gpa.free(toks.*);
        self.wikilinks.clearRetainingCapacity();
        // Deliberately `clearForReparse`, not `clear`: this runs on every content change, which
        // during editing is every keystroke. It drops the positional arrays (the edit invalidated
        // their indices) while keeping the heights keyed by block source, so blocks the edit did
        // not touch keep their measured heights instead of collapsing back to estimates.
        self.blocks.clearForReparse();
        self.cell_sizes.clearRetainingCapacity();
        var tl_it = self.table_layouts.valueIterator();
        while (tl_it.next()) |tl| {
            gpa.free(tl.natural);
            gpa.free(tl.widths);
        }
        self.table_layouts.clearRetainingCapacity();
        self.clearResolvedWikilinks(gpa);
    }

    /// Drop every memoized resolution. Called when the content changes (`clear`) and when the
    /// resolver's generation moves — a new file appearing is exactly the case that has to
    /// invalidate a "this link is broken" answer without the document itself changing.
    pub fn clearResolvedWikilinks(self: *RenderState, gpa: std.mem.Allocator) void {
        var it = self.wikilink_resolved.valueIterator();
        while (it.next()) |r| gpa.free(r.path);
        self.wikilink_resolved.clearRetainingCapacity();
        self.wikilink_generation = std.math.maxInt(u64);
    }
};

/// dvui ids derive from @src(); repeated layouts in loops/recursion need unique `.id_extra`.
const IdGen = struct {
    n: usize = 0,
    fn next(g: *IdGen) usize {
        g.n += 1;
        return g.n;
    }
};

pub const RenderContext = struct {
    /// What relative `![alt](path)` images resolve against: the markdown file's directory, or —
    /// for a document fetched over the network, like the store's README pane — the URL it came
    /// from (`https://…/README.md`), in which case relative images are fetched, not read.
    image_base_dir: ?[]const u8 = null,
    io: Io,
    /// Persistent allocator (same lifetime as State).  Used for image cache.
    gpa: std.mem.Allocator,
    /// Precomputed per-AST data: node kind map, image subtree set, image cache.
    rs: *RenderState,
    /// Seed for per-document widget id_extra values (avoids collisions with other panes/docs).
    id_base: usize = 0,
    /// Whether *text* widgets paint their own fill. Mirrors `markdown.PreviewOptions.background`,
    /// and has to be threaded all the way down here rather than just applied to the preview's
    /// scroll area: `dvui.TextLayoutWidget.defaults.background` is **true**, so every single
    /// `textLayout` paints a fill of its own unless explicitly told not to. Suppressing only the
    /// scroll area's fill therefore left every paragraph, heading, and caption drawing its own
    /// panel — which is exactly what "background = false" was meant to get rid of.
    ///
    /// Deliberate decorative fills are *not* governed by this and stay on regardless: the code
    /// block's surrounding panel, the HTML-block tint, table header/row banding, and task
    /// bullets. Those are part of how the element reads, not a background behind the text.
    background: bool = true,
    /// Absolute path of the document being rendered, `""` when it has none. Wikilinks resolve
    /// relative to it, and are disabled entirely when it's empty — see `PreviewOptions`.
    document_path: []const u8 = "",
    /// The scroll area's visible region, in its own virtual coordinates, and the virtual `y` the
    /// first top-level block starts at. Together they say which blocks are on screen, which is
    /// what lets everything else be skipped — see `renderTopLevel`. A zero-height viewport
    /// disables the skipping and draws the whole document (what a caller with no scroll area of
    /// its own would want).
    viewport: dvui.Rect = .{},
    content_origin_y: f32 = 0,
    /// Width the blocks lay out at. Only used to notice it changed, which invalidates every
    /// cached block height.
    column_width: f32 = 0,
    /// The `"wikilink"` resolver, looked up once per document draw rather than per link.
    /// Null whenever wikilinks are off: no resolver plugin installed, or no `document_path`.
    /// When null, `[[Note]]` renders as the literal text it always was.
    wikilink: ?*WikilinkApi = null,
};

/// Top/bottom margin every paragraph's `textLayout` carries. List markers match the top half so
/// they line up with the paragraph they label (see `CMARK_NODE_LIST`).
const paragraph_margin_y: f32 = 4;

/// Horizontal inset for the *framed* blocks — tables, code fences, blockquotes, raw HTML. Prose
/// runs the full column width; anything that draws its own panel sits a step in from it, so the
/// frame reads as a distinct object placed in the document rather than another line of text that
/// happens to have a border. Nested framed blocks (a fence inside a quote) inset again, which is
/// the intent: each level of containment is one step further in.
const block_inset_x: f32 = 14;

const max_image_bytes: usize = 16 * 1024 * 1024;
const max_image_display_width: f32 = 720;
const max_image_display_height: f32 = 540;

// ---------------------------------------------------------------------------
// Per-node fast lookups (replaces isTable/typeString calls in render loop)
// ---------------------------------------------------------------------------

inline fn extKind(ctx: RenderContext, n: md.Node) ?ExtNodeKind {
    return ctx.rs.ext_node_kinds.get(@intFromPtr(n.n));
}

inline fn hasImageSubtree(ctx: RenderContext, n: md.Node) bool {
    return ctx.rs.subtree_has_image.contains(@intFromPtr(n.n));
}

// ---------------------------------------------------------------------------
// AST pre-scan (called once after parsing, results stored in State)
// ---------------------------------------------------------------------------

/// Original markdown source, for the one thing the AST can't answer on its own — see
/// `wikilink_scan.zig`. Built once per parse rather than per node.
const ScanSource = struct {
    bytes: []const u8,
    index: ?wikilink_scan.LineIndex,

    fn spanFor(self: ScanSource, node: md.Node) ?[]const u8 {
        const index = self.index orelse return null;
        return wikilink_scan.sourceSpanFor(self.bytes, index, node);
    }
};

/// Walk the AST once, populating rs.ext_node_kinds, rs.subtree_has_image, and rs.wikilinks.
/// Returns true when any node in the subtree rooted at `node` is an IMAGE.
///
/// `source` is the markdown these nodes were parsed from.
pub fn scanNode(node: md.Node, rs: *RenderState, gpa: std.mem.Allocator, source: []const u8) bool {
    // A failed line index only costs escape detection, so scanning continues without it.
    var index: ?wikilink_scan.LineIndex = wikilink_scan.LineIndex.build(gpa, source) catch null;
    defer if (index) |*i| i.deinit(gpa);
    const scan_source: ScanSource = .{ .bytes = source, .index = index };
    recordBlockExtents(node, rs, gpa, scan_source);
    return scanNodeInner(node, rs, gpa, scan_source);
}

/// What shape a top-level block is, for the height estimator. A `table` here is the GFM extension
/// node, which cmark reports through `typeString` rather than as a `CMARK_NODE_*` constant, so it
/// comes from the kind map the scan built — except that the scan has not run yet the first time
/// through, which is why the node's own type is checked first and the map only consulted for the
/// extension types it is the only source for.
fn blockKind(n: md.Node, rs: *const RenderState) bh.BlockKind {
    switch (n.nodeType()) {
        md.c.CMARK_NODE_HEADING => return .heading,
        md.c.CMARK_NODE_CODE_BLOCK => return .code,
        md.c.CMARK_NODE_LIST => return .list,
        md.c.CMARK_NODE_BLOCK_QUOTE => return .quote,
        md.c.CMARK_NODE_THEMATIC_BREAK => return .rule,
        md.c.CMARK_NODE_HTML_BLOCK => return .html,
        md.c.CMARK_NODE_PARAGRAPH => {
            // A paragraph that exists to hold a picture is nothing like a paragraph of prose: one
            // line of source, and up to `max_image_display_height` on screen.
            var c = n.firstChild();
            while (c) |x| : (c = x.nextSibling()) {
                if (x.nodeType() == md.c.CMARK_NODE_IMAGE) return .image;
            }
            return .paragraph;
        },
        else => {},
    }
    if (rs.ext_node_kinds.get(@intFromPtr(n.n))) |k| {
        if (k == .table) return .table;
    }
    if (std.mem.eql(u8, n.typeString(), "table")) return .table;
    return .paragraph;
}

/// Record each top-level block's source span, for `renderTopLevel`'s first-sight height guess.
/// cmark reports 1-based line numbers for block nodes; a node whose lines don't fit the source
/// (nothing observed doing this, but the API doesn't promise it) simply gets a zero extent, and a
/// zero extent means "no guess available" — that block is drawn rather than estimated.
fn recordBlockExtents(doc_node: md.Node, rs: *RenderState, gpa: std.mem.Allocator, source: ScanSource) void {
    var child = doc_node.firstChild();
    while (child) |ch| : (child = ch.nextSibling()) {
        var extent: SourceExtent = .{ .kind = blockKind(ch, rs) };
        const start = ch.startLine();
        const end = ch.endLine();
        if (start >= 1 and end >= start) {
            extent.lines = @intCast(end - start + 1);
            extent.start_line = @intCast(start - 1);
            if (source.index) |idx| {
                const starts = idx.starts;
                const first: usize = @intCast(start - 1);
                const after: usize = @intCast(end);
                if (first < starts.len) {
                    const from = starts[first];
                    const to = if (after < starts.len) starts[after] else @as(u32, @intCast(source.bytes.len));
                    if (to > from) {
                        extent.bytes = to - from;
                        // The block's identity across re-parses. Hashed from the source rather
                        // than the AST because that is what an edit actually changes — a
                        // paragraph nobody touched hashes the same however far its index moved.
                        extent.hash = std.hash.XxHash3.hash(0, source.bytes[from..to]);
                    }
                }
            }
        }
        rs.blocks.appendExtent(gpa, extent);
    }
}

fn scanNodeInner(node: md.Node, rs: *RenderState, gpa: std.mem.Allocator, source: ScanSource) bool {
    var self_has_table = false;
    const ts = node.typeString();
    if (std.mem.eql(u8, ts, "table")) {
        self_has_table = true;
        rs.ext_node_kinds.put(gpa, @intFromPtr(node.n), .table) catch {};
        // Count columns once from the header (or first body row) so the render
        // loop never needs to re-traverse the row for this.
        var num_cols: usize = 0;
        var r = node.firstChild();
        while (r) |row| : (r = row.nextSibling()) {
            const rts = row.typeString();
            if (!std.mem.eql(u8, rts, "table_header") and !std.mem.eql(u8, rts, "table_row")) continue;
            var cl = row.firstChild();
            while (cl) |cell| : (cl = cell.nextSibling()) {
                if (std.mem.eql(u8, cell.typeString(), "table_cell")) num_cols += 1;
            }
            break;
        }
        rs.table_col_counts.put(gpa, @intFromPtr(node.n), num_cols) catch {};
    } else if (std.mem.eql(u8, ts, "table_row"))
        rs.ext_node_kinds.put(gpa, @intFromPtr(node.n), .table_row) catch {}
    else if (std.mem.eql(u8, ts, "table_header"))
        rs.ext_node_kinds.put(gpa, @intFromPtr(node.n), .table_header) catch {}
    else if (std.mem.eql(u8, ts, "table_cell"))
        rs.ext_node_kinds.put(gpa, @intFromPtr(node.n), .table_cell) catch {}
    else if (std.mem.eql(u8, ts, "strikethrough"))
        rs.ext_node_kinds.put(gpa, @intFromPtr(node.n), .strikethrough) catch {};

    if (node.nodeType() == md.c.CMARK_NODE_ITEM and node.isTaskListItem())
        rs.task_items.put(gpa, @intFromPtr(node.n), node.taskListItemChecked()) catch {};

    // `[[wikilinks]]`. Only TEXT nodes: inline code (CMARK_NODE_CODE), fenced/indented code
    // blocks, and raw HTML all have their own node types and never reach here, so "don't link
    // inside code" needs no work. Link *labels* do — `[see [[A]]](http://x)` puts that text
    // under a LINK parent, and turning part of a link's own label into a second link is not a
    // thing a `TextLayoutWidget` can express.
    if (node.nodeType() == md.c.CMARK_NODE_TEXT and !insideLinkOrImage(node)) {
        if (node.literal()) |t| {
            if (wikilink_scan.tokensFor(gpa, t, source.spanFor(node))) |toks| {
                if (toks.len > 0)
                    rs.wikilinks.put(gpa, @intFromPtr(node.n), toks) catch gpa.free(toks)
                else
                    gpa.free(toks);
            } else |_| {}
        }
    }

    var self_has_image = (node.nodeType() == md.c.CMARK_NODE_IMAGE);

    // Raw HTML: GitHub READMEs routinely wrap their hero image in `<p align="center"><img …>`,
    // which cmark hands us as an opaque HTML block. Pull the `<img src>` URLs out once here so
    // rendering can show the actual images instead of the raw markup.
    if (node.nodeType() == md.c.CMARK_NODE_HTML_BLOCK or node.nodeType() == md.c.CMARK_NODE_HTML_INLINE) {
        if (node.literal()) |html| {
            if (html_images_mod.collect(html, gpa)) |urls| {
                rs.html_images.put(gpa, @intFromPtr(node.n), urls) catch {
                    html_images_mod.free(urls, gpa);
                };
                self_has_image = true;
            }
        }
    }

    var child = node.firstChild();
    while (child) |ch| : (child = ch.nextSibling()) {
        if (scanNodeInner(ch, rs, gpa, source)) self_has_image = true;
        if (rs.subtree_has_table.contains(@intFromPtr(ch.n))) self_has_table = true;
    }
    if (self_has_image)
        rs.subtree_has_image.put(gpa, @intFromPtr(node.n), {}) catch {};
    if (self_has_table)
        rs.subtree_has_table.put(gpa, @intFromPtr(node.n), {}) catch {};

    return self_has_image;
}

/// True when `node` sits inside a markdown link or image, where its text is a label rather than
/// body prose. Walks parents once per parse, never per frame.
fn insideLinkOrImage(node: md.Node) bool {
    var p = node.parent();
    while (p) |parent| : (p = parent.parent()) {
        switch (parent.nodeType()) {
            md.c.CMARK_NODE_LINK, md.c.CMARK_NODE_IMAGE => return true,
            else => {},
        }
    }
    return false;
}

// ---------------------------------------------------------------------------
// Image preloading (keep GPU textures warm every frame, even when pane is closed)
// ---------------------------------------------------------------------------

/// Touch or create the GPU texture for every local image in the AST.
/// Call every frame from MarkDownPreviewWidget.init() so dvui's one-frame
/// texture eviction policy never fires between animation frames.
pub fn preloadImages(root: md.Node, ctx: RenderContext) void {
    if (!ctx.rs.subtree_has_image.contains(@intFromPtr(root.n))) return;
    const arena = dvui.currentWindow().arena();
    preloadImageSubtree(root, ctx, arena);
}

fn preloadImageSubtree(node: md.Node, ctx: RenderContext, arena: std.mem.Allocator) void {
    if (node.nodeType() == md.c.CMARK_NODE_IMAGE) {
        if (node.linkUrl()) |url| preloadSingleImage(url, ctx, arena);
        return;
    }
    if (ctx.rs.html_images.get(@intFromPtr(node.n))) |urls| {
        for (urls) |html_img| preloadSingleImage(html_img.src, ctx, arena);
    }
    if (!ctx.rs.subtree_has_image.contains(@intFromPtr(node.n))) return;
    var child = node.firstChild();
    while (child) |ch| : (child = ch.nextSibling()) {
        preloadImageSubtree(ch, ctx, arena);
    }
}

fn preloadSingleImage(raw_url: []const u8, ctx: RenderContext, arena: std.mem.Allocator) void {
    const resolved = resolveImageBytes(ctx, arena, raw_url);
    const bytes = switch (resolved) {
        .bytes => |b| b,
        else => return,
    };

    // Skipped at render time (see `renderImageUrl`), so there is nothing to warm.
    if (image_format.isSvg(bytes)) return;
    if (rasterDecodeFailed(ctx, bytes)) return;

    const dvui_key = textureCacheKey(bytes);

    // Cache hit: texture already warm this frame, nothing to do.
    if (dvui.textureGetCached(dvui_key) != null) return;

    // Cache miss: decode + GPU upload now so the animation first frame is free.
    const source: dvui.ImageSource = .{ .imageFile = .{
        .bytes = bytes,
        .name = raw_url,
        .invalidation = .ptr,
    } };
    const tex = dvui.Texture.fromImageSource(source) catch {
        markUndecodable(ctx, bytes);
        return;
    };
    ctx.rs.image_sizes.put(ctx.gpa, @intFromPtr(bytes.ptr), .{
        .w = @floatFromInt(tex.width),
        .h = @floatFromInt(tex.height),
    }) catch {};
    dvui.textureAddToCache(dvui_key, tex);
}

/// True once stb has already refused these bytes. Both paths (preload and render) ask before
/// handing anything to stbi, so a corrupt image costs one warning for the whole document rather
/// than two per frame.
fn rasterDecodeFailed(ctx: RenderContext, bytes: []const u8) bool {
    return ctx.rs.image_decode_failed.contains(@intFromPtr(bytes.ptr));
}

fn markUndecodable(ctx: RenderContext, bytes: []const u8) void {
    ctx.rs.image_decode_failed.put(ctx.gpa, @intFromPtr(bytes.ptr), {}) catch {};
}

/// The cache key dvui uses for an `imageFile` source with `.ptr` invalidation. dvui's own
/// `hash()` calls stbi_info and then ignores the result for `.ptr`, so it's skipped entirely.
fn textureCacheKey(bytes: []const u8) dvui.Texture.Cache.Key {
    var h = dvui.fnv.init();
    const bp = bytes.ptr;
    h.update(std.mem.asBytes(&bp));
    const it = @intFromEnum(dvui.enums.TextureInterpolation.linear);
    h.update(std.mem.asBytes(&it));
    return h.final();
}

// ---------------------------------------------------------------------------
// Image rendering helpers
// ---------------------------------------------------------------------------

fn resolvedLocalImagePath(ctx: RenderContext, arena: std.mem.Allocator, src: []const u8) ?[]const u8 {
    const t = std.mem.trim(u8, src, " \t\r\n");
    if (t.len == 0) return null;
    if (net_image.isRemote(t)) return null;
    if (std.fs.path.isAbsolute(t))
        return std.fs.path.resolve(arena, &.{t}) catch null;
    const base = ctx.image_base_dir orelse return null;
    return std.fs.path.resolve(arena, &.{ base, t }) catch null;
}

/// Encoded image bytes for one image URL, or why there aren't any (yet).
const ResolvedImage = union(enum) {
    bytes: []const u8,
    /// Remote fetch still running — caller should draw a placeholder and come back next frame.
    pending,
    /// User-facing reason the image can't be shown.
    message: []const u8,
};

/// Bytes for `raw_url`, from the persistent local-file cache or the remote fetcher. Never blocks:
/// a remote URL that hasn't landed yet returns `.pending`.
fn resolveImageBytes(ctx: RenderContext, arena: std.mem.Allocator, raw_url: []const u8) ResolvedImage {
    const url = std.mem.trim(u8, raw_url, " \t\r\n");
    if (url.len == 0) return .{ .message = "(empty image src)" };

    // A README fetched from a repo has a *URL* for a base, not a directory — its relative image
    // paths only resolve against that URL (see `RenderContext.image_base_dir`).
    const remote_url: ?[]const u8 = if (net_image.isRemote(url))
        url
    else if (ctx.image_base_dir) |base| blk: {
        if (!net_image.isRemote(base)) break :blk null;
        break :blk url_join.resolve(arena, base, url) orelse return .{ .message = "cannot resolve image url" };
    } else null;

    if (remote_url) |u| {
        return switch (net_image.request(ctx.gpa, u)) {
            .pending => .pending,
            .failed => .{ .message = "could not fetch image" },
            .ready => |b| .{ .bytes = b },
        };
    }

    const abs_path = resolvedLocalImagePath(ctx, arena, url) orelse
        return .{ .message = "cannot resolve image path (save file or use absolute path)" };

    if (ctx.rs.image_cache.get(abs_path)) |cached| return .{ .bytes = cached };

    const fresh = Io.Dir.cwd().readFileAlloc(ctx.io, abs_path, ctx.gpa, .limited(max_image_bytes)) catch
        return .{ .message = "could not read image" };
    const key = ctx.gpa.dupe(u8, abs_path) catch {
        ctx.gpa.free(fresh);
        return .{ .message = "could not read image" };
    };
    ctx.rs.image_cache.put(ctx.gpa, key, fresh) catch {
        ctx.gpa.free(key);
        ctx.gpa.free(fresh);
        return .{ .message = "could not cache image" };
    };
    return .{ .bytes = fresh };
}

/// Clickable markdown hyperlink. Resolution order:
/// 1. `file://` URIs (including zls hover's `file:///path#L12`) → editor
/// 2. Scheme-less relative/absolute paths against the document directory → editor
///    (brain's `[Title](../note.md)` inserts, and ordinary in-vault markdown links)
/// 3. Everything else → `dvui.openURL` (http(s), mailto, …)
///
/// Middle-click / Ctrl/Cmd+click requests a side split for file targets (and a new browser
/// window for http(s)), matching `TextLayoutWidget.addLink`.
fn addMarkdownLink(
    tl: *dvui.TextLayoutWidget,
    url: []const u8,
    text: ?[]const u8,
    opts: dvui.Options,
    ctx: RenderContext,
) void {
    const defs: dvui.Options = .{ .color_text = dvui.themeGet().focus, .font = dvui.Font.theme(.body).withUnderline(.{}) };
    if (tl.addTextClick(text orelse url, defs.override(opts))) |click_event| {
        const open_side = (click_event == .mouse and (click_event.mouse.button == .middle or click_event.mouse.mod.matchBind("ctrl/cmd")));
        openMarkdownUrl(url, open_side, ctx);
    }
}

fn openMarkdownUrl(url: []const u8, open_side: bool, ctx: RenderContext) void {
    if (tryRevealFileUri(url, open_side)) return;
    if (tryRevealRelativePath(url, open_side, ctx)) return;
    // `untitled://` (zls hover for unsaved buffers) and other non-http schemes have nowhere
    // useful to go via the system opener — skip them rather than hand SDL a junk URL.
    if (std.ascii.startsWithIgnoreCase(url, "untitled:")) return;
    _ = dvui.openURL(.{ .url = url, .new_window = open_side });
}

/// Resolve a scheme-less link against the document's directory and open it in the editor.
/// Returns false for URLs with a scheme (`http:`, `mailto:`, …), when there's no local base,
/// or when resolution fails. Fragments (`#heading`) are stripped for the path lookup; line
/// stays 0 for now (heading→line needs the brain index and can land later).
fn tryRevealRelativePath(url: []const u8, open_side: bool, ctx: RenderContext) bool {
    const trimmed = std.mem.trim(u8, url, " \t\r\n");
    if (trimmed.len == 0) return false;

    // Anything with `://` is a real URL. A single `:` could be a Windows drive (`C:…`) — we
    // only treat that as local when it looks like `X:/` or `X:\`; otherwise bail to openURL.
    if (std.mem.indexOf(u8, trimmed, "://") != null) return false;
    if (std.mem.indexOfScalar(u8, trimmed, ':')) |colon| {
        const windows_drive = colon == 1 and std.ascii.isAlphabetic(trimmed[0]) and
            trimmed.len > 2 and (trimmed[2] == '/' or trimmed[2] == '\\');
        if (!windows_drive) return false;
    }

    var path_part = trimmed;
    if (std.mem.indexOfScalar(u8, path_part, '#')) |hash| path_part = path_part[0..hash];
    if (path_part.len == 0) return false;

    // Percent-decode `%20` etc. so brain's encoded inserts round-trip.
    const arena = dvui.currentWindow().arena();
    const decoded = percentDecode(arena, path_part) catch return false;

    const abs = blk: {
        if (std.fs.path.isAbsolute(decoded))
            break :blk std.fs.path.resolve(arena, &.{decoded}) catch return false;
        const base = ctx.image_base_dir orelse dirnameOf(ctx.document_path) orelse return false;
        // Remote README bases are URLs — relative *page* links aren't editor targets.
        if (std.mem.indexOf(u8, base, "://") != null) return false;
        break :blk std.fs.path.resolve(arena, &.{ base, decoded }) catch return false;
    };

    return revealPath(abs, 0, 0, open_side);
}

fn dirnameOf(path: []const u8) ?[]const u8 {
    if (path.len == 0) return null;
    return std.fs.path.dirname(path);
}

fn percentDecode(arena: std.mem.Allocator, src: []const u8) ![]const u8 {
    if (std.mem.indexOfScalar(u8, src, '%') == null) return src;
    var out: std.ArrayList(u8) = .empty;
    try out.ensureTotalCapacity(arena, src.len);
    var i: usize = 0;
    while (i < src.len) {
        if (src[i] == '%' and i + 2 < src.len) {
            const byte = std.fmt.parseInt(u8, src[i + 1 .. i + 3], 16) catch {
                try out.append(arena, src[i]);
                i += 1;
                continue;
            };
            try out.append(arena, byte);
            i += 3;
        } else {
            try out.append(arena, src[i]);
            i += 1;
        }
    }
    return out.toOwnedSlice(arena);
}

/// Opens a `file://` URI (optionally with a `#L<n>` / `#L<n>C<m>` fragment) in the editor.
/// Returns false when the URL isn't a file URI or workbench isn't available.
fn tryRevealFileUri(url: []const u8, open_side: bool) bool {
    const arena = dvui.currentWindow().arena();
    const parsed = parseFileUri(arena, url) orelse return false;
    // zls (and VS Code-style `#L` fragments) are 1-based; workbench is 0-based.
    const line: u32 = if (parsed.line_1based > 0) parsed.line_1based - 1 else 0;
    const character: u32 = if (parsed.character_1based > 0) parsed.character_1based - 1 else 0;
    // Reaching workbench is what actually opens it, but a `file://` URL is *ours* either way —
    // returning true even when that fails keeps a broken editor link from being handed to the
    // system browser.
    _ = revealPath(parsed.path, line, character, open_side);
    return true;
}

/// Opens `path` (native, absolute) in the editor at a 0-based `line`/`character`, splitting to
/// the side when `open_side`. Returns false when workbench isn't available or refused.
///
/// Split out of `tryRevealFileUri` so a caller that already *has* a path — a resolved wikilink —
/// doesn't have to encode it into a `file://` URI just to have it decoded straight back. That
/// round trip isn't merely wasteful: it has to percent-encode, and a path containing a space or
/// a `#` is exactly where a hand-rolled encoder goes wrong.
fn revealPath(path: []const u8, line: u32, character: u32, open_side: bool) bool {
    const wb = sdk.host().getServiceTyped(sdk.services.workbench.Api) orelse return false;
    return wb.revealPosition(path, line, character, open_side) catch |err| {
        dvui.log.err("markdown: revealPosition failed for {s}: {any}", .{ path, err });
        return false;
    };
}

const ParsedFileUri = struct {
    path: []const u8,
    line_1based: u32 = 0,
    character_1based: u32 = 0,
};

/// Decodes `file:///abs/path.zig#L12` (and `#L12C3` / `#L12:3`) into a native path + optional
/// 1-based position. Arena-allocated path; returns null for non-`file://` URLs.
fn parseFileUri(arena: std.mem.Allocator, url: []const u8) ?ParsedFileUri {
    const prefix = "file://";
    if (!std.ascii.startsWithIgnoreCase(url, prefix)) return null;

    var path_part = url[prefix.len..];
    var line_1based: u32 = 0;
    var character_1based: u32 = 0;
    if (std.mem.indexOfScalar(u8, path_part, '#')) |hash| {
        const frag = path_part[hash + 1 ..];
        path_part = path_part[0..hash];
        // Accept `L12`, `L12C3`, `L12:3` (case-insensitive L/C).
        if (frag.len >= 2 and (frag[0] == 'L' or frag[0] == 'l')) {
            var i: usize = 1;
            var line: u32 = 0;
            while (i < frag.len and frag[i] >= '0' and frag[i] <= '9') : (i += 1) {
                line = line * 10 + (frag[i] - '0');
            }
            line_1based = line;
            if (i < frag.len and (frag[i] == 'C' or frag[i] == 'c' or frag[i] == ':')) {
                i += 1;
                var col: u32 = 0;
                while (i < frag.len and frag[i] >= '0' and frag[i] <= '9') : (i += 1) {
                    col = col * 10 + (frag[i] - '0');
                }
                character_1based = col;
            }
        }
    }

    const path = decodeFileUriPath(arena, path_part) catch return null;
    return .{ .path = path, .line_1based = line_1based, .character_1based = character_1based };
}

/// Percent-decodes the path portion of a `file://` URI into a native filesystem path.
fn decodeFileUriPath(arena: std.mem.Allocator, encoded: []const u8) ![]u8 {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(arena);
    var i: usize = 0;
    while (i < encoded.len) {
        if (encoded[i] == '%' and i + 2 < encoded.len) {
            const byte = std.fmt.parseInt(u8, encoded[i + 1 .. i + 3], 16) catch {
                try out.append(arena, encoded[i]);
                i += 1;
                continue;
            };
            try out.append(arena, byte);
            i += 3;
        } else {
            try out.append(arena, encoded[i]);
            i += 1;
        }
    }

    if (comptime is_windows) {
        // `file:///C:/Users/...` decodes to `/C:/Users/...`; strip the leading slash and
        // swap separators so this is a usable native Windows path.
        if (out.items.len >= 3 and out.items[0] == '/' and std.ascii.isAlphabetic(out.items[1]) and out.items[2] == ':') {
            _ = out.orderedRemove(0);
        }
        for (out.items) |*c| {
            if (c.* == '/') c.* = '\\';
        }
    }

    return out.toOwnedSlice(arena);
}

/// Plain UTF-8 for clickable link labels; nested emph/strong in the label lose per-span styling.
fn appendInlinePlainText(arena: std.mem.Allocator, n: md.Node, out: *std.ArrayList(u8)) std.mem.Allocator.Error!void {
    var cur: ?md.Node = n.firstChild();
    while (cur) |x| : (cur = x.nextSibling()) {
        switch (x.nodeType()) {
            md.c.CMARK_NODE_TEXT => {
                if (x.literal()) |t| try out.appendSlice(arena, t);
            },
            md.c.CMARK_NODE_SOFTBREAK => {
                try out.append(arena, ' ');
            },
            md.c.CMARK_NODE_LINEBREAK => {
                try out.append(arena, '\n');
            },
            md.c.CMARK_NODE_CODE => {
                if (x.literal()) |t| try out.appendSlice(arena, t);
            },
            md.c.CMARK_NODE_LINK => {
                try appendInlinePlainText(arena, x, out);
            },
            md.c.CMARK_NODE_IMAGE => {
                try out.appendSlice(arena, "![");
                try appendInlinePlainText(arena, x, out);
                try out.append(arena, ']');
                if (x.linkUrl()) |u| {
                    try out.append(arena, '(');
                    try out.appendSlice(arena, u);
                    try out.append(arena, ')');
                }
            },
            else => {
                if (x.firstChild()) |_| {
                    try appendInlinePlainText(arena, x, out);
                } else if (x.literal()) |t| {
                    try out.appendSlice(arena, t);
                }
            },
        }
    }
}

fn linkLabelPlainText(link: md.Node, arena: std.mem.Allocator) std.mem.Allocator.Error![]const u8 {
    var list: std.ArrayList(u8) = .empty;
    errdefer list.deinit(arena);
    try appendInlinePlainText(arena, link, &list);
    return try list.toOwnedSlice(arena);
}

/// Stand-in for an image whose bytes we have but nothing could decode — stb refused it and, for
/// an SVG, so did the TinyVG conversion. Shows the alt text rather than an error box (a row of
/// those reads as the *document* being broken), as a link when the image came from the network so
/// it's still reachable.
fn renderUndecodableImage(alt: []const u8, url: []const u8, ctx: RenderContext, ids: *IdGen) void {
    const text = if (alt.len > 0) alt else "image";
    if (!net_image.isRemote(url)) {
        renderMarkdownImagePlaceholder(text, ids);
        return;
    }
    var tl = textLayout(@src(), .{}, .{
        .expand = .horizontal,
        .margin = .{ .y = 2, .h = 2 },
        .background = ctx.background,
        .id_extra = ids.next(),
    });
    defer tl.deinit();
    addMarkdownLink(tl, url, text, .{ .font = dvui.Font.theme(.mono).larger(-1) }, ctx);
}

fn renderMarkdownImagePlaceholder(msg: []const u8, ids: *IdGen) void {
    dvui.labelNoFmt(@src(), msg, .{}, .{
        .expand = .horizontal,
        .margin = .{ .y = 2, .h = 2 },
        .color_text = dvui.themeGet().color(.control, .text).opacity(0.55),
        .font = dvui.Font.theme(.mono).larger(-1),
        .id_extra = ids.next(),
    });
}

fn renderMarkdownImage(img: md.Node, span: dvui.Options, ctx: RenderContext, ids: *IdGen) void {
    _ = span;
    const arena = dvui.currentWindow().arena();
    const raw_url = img.linkUrl() orelse {
        var outer = box(@src(), .{ .dir = .vertical }, .{
            .expand = .horizontal,
            .margin = .{ .y = 4, .h = 4 },
            .id_extra = ids.next(),
        });
        defer outer.deinit();
        renderMarkdownImagePlaceholder("(missing image src)", ids);
        return;
    };
    const alt = linkLabelPlainText(img, arena) catch "";
    renderImageUrl(raw_url, alt, .{}, ctx, ids);
}

/// A `Dim` in points. Percentages are resolved against `basis` (the image's natural width/height
/// — see the call site); pixel counts are absolute. Null when the markup asked for nothing.
fn resolveRequested(dim: ?html_images_mod.Dim, basis: f32) ?f32 {
    return switch (dim orelse return null) {
        .px => |px| px,
        .fraction => |f| if (basis > 0) basis * f else null,
    };
}

/// Size the markup asked for, when it did. Only raw HTML can: `![alt](url)` has no syntax for it.
const RequestedSize = struct {
    width: ?html_images_mod.Dim = null,
    height: ?html_images_mod.Dim = null,
    alignment: ?html_images_mod.Align = null,
};

/// Draw one image by URL — local path or remote — with an optional caption. Shared by
/// `![alt](url)` and by `<img src>` pulled out of raw HTML.
fn renderImageUrl(raw_url: []const u8, alt: []const u8, want: RequestedSize, ctx: RenderContext, ids: *IdGen) void {
    const arena = dvui.currentWindow().arena();
    const url_trim = std.mem.trim(u8, raw_url, " \t\r\n");

    const resolved = resolveImageBytes(ctx, arena, url_trim);

    // SVG is skipped outright — nothing drawn, no placeholder, no gap. dvui's `svgToTvg` covers
    // only a small subset of SVG (no `defs`, `clipPath`, gradients, `text`/`tspan`), so anything
    // beyond a hand-authored icon — every shields.io badge, every exported logo — converted into
    // wrong-looking artwork plus a burst of "unrecognized element" warnings per frame. A document
    // that silently omits them reads better than one full of mangled ones.
    //
    // Resolved *before* the layout box exists so a skipped image leaves no vertical margin
    // behind. Format is sniffed from the bytes rather than the URL: badge URLs routinely have no
    // extension at all.
    switch (resolved) {
        .bytes => |b| if (image_format.isSvg(b)) return,
        else => {},
    }

    var outer = box(@src(), .{ .dir = .vertical }, .{
        .expand = .horizontal,
        .margin = .{ .y = 4, .h = 4 },
        .id_extra = ids.next(),
    });
    defer outer.deinit();

    // Hard ceiling so an unconstrained (or still-too-large) image can't take over the pane.
    // Percentage widths are *not* resolved against this — see below.
    // During a sash/resize frame the wrapper's content rect can briefly report 0 — fall back to
    // the column width so the hero doesn't collapse to nothing for that frame.
    const avail_w = blk: {
        const w = outer.data().contentRect().w;
        break :blk if (w > 1) w else ctx.column_width;
    };

    const bytes: []const u8 = switch (resolved) {
        .bytes => |b| b,
        .pending => {
            renderMarkdownImagePlaceholder("loading image…", ids);
            return;
        },
        .message => |msg| {
            renderMarkdownImagePlaceholder(msg, ids);
            // A remote image that failed to load is still worth reaching: offer the link.
            if (net_image.isRemote(url_trim)) {
                var tl = textLayout(@src(), .{}, .{
                    .expand = .horizontal,
                    .background = ctx.background,
                    .id_extra = ids.next(),
                });
                defer tl.deinit();
                addMarkdownLink(tl, url_trim, "open", .{ .font = dvui.Font.theme(.mono) }, ctx);
            }
            return;
        },
    };

    if (rasterDecodeFailed(ctx, bytes)) {
        renderUndecodableImage(alt, url_trim, ctx, ids);
        return;
    }

    const dvui_key = textureCacheKey(bytes);

    // Fast path: texture already in dvui's cache from a prior visible frame.
    // Use .texture source to bypass hash()/stbi_info entirely on this frame.
    // Slow path: texture not yet created. Use imageFile source so dvui creates it
    // lazily inside renderImage (only when the image is actually in the clip rect).
    var source: dvui.ImageSource = .{ .imageFile = .{
        .bytes = bytes,
        .name = url_trim,
        .invalidation = .ptr,
    } };
    const nat: dvui.Size = if (dvui.textureGetCached(dvui_key)) |tex| nat: {
        source = .{ .texture = tex };
        break :nat .{ .w = @floatFromInt(tex.width), .h = @floatFromInt(tex.height) };
    } else nat: {
        const size_key = @intFromPtr(bytes.ptr);
        break :nat ctx.rs.image_sizes.get(size_key) orelse sz: {
            const sz = dvui.imageSize(source) catch {
                markUndecodable(ctx, bytes);
                renderUndecodableImage(alt, url_trim, ctx, ids);
                return;
            };
            ctx.rs.image_sizes.put(ctx.gpa, size_key, sz) catch {};
            break :sz sz;
        };
    };

    const size = displaySize(nat, want, avail_w) orelse {
        renderMarkdownImagePlaceholder("invalid image size", ids);
        return;
    };

    // `.expand = .ratio` would grow the image back out to whatever rect the parent hands it,
    // ignoring the size computed above (this is what kept the pixi hero at full size despite its
    // `width="25%"`). The size *is* the answer here, so ask for exactly it.
    _ = dvui.image(@src(), .{ .source = source, .shrink = .ratio }, .{
        .min_size_content = .{ .w = size.w, .h = size.h },
        .max_size_content = dvui.Options.MaxSize.size(.{ .w = size.w, .h = size.h }),
        .expand = .none,
        .gravity_x = alignGravityX(want),
        .label = .{ .text = if (alt.len > 0) alt else "markdown image" },
        .id_extra = ids.next(),
    });

    renderImageCaption(alt, ctx, ids);
}

/// Point size to draw an image of natural size `nat` at, honouring what the markup asked for and
/// the pane's ceilings. Null for a degenerate natural size. Shared by the raster and SVG paths so
/// a `<img width="25%">` means the same thing either way.
fn displaySize(nat: dvui.Size, want: RequestedSize, avail_w: f32) ?dvui.Size {
    if (nat.w <= 0 or nat.h <= 0) return null;
    const r = nat.w / nat.h;

    // `width="25%"` is treated as a scale of the image's *intrinsic* size, not of the pane —
    // so a logo stays a constant 25% of itself as the store/center is resized. (Resolving
    // against the containing block made the pixi hero grow and shrink with the pane.) A size
    // the markup asked for still wins over the natural size; the pane is only a fit ceiling.
    const requested_w: ?f32 = resolveRequested(want.width, nat.w);
    const requested_h: ?f32 = resolveRequested(want.height, nat.h);
    const target_w: f32 = requested_w orelse
        if (requested_h) |h| h * r else @min(nat.w, max_image_display_width);
    const target_h: f32 = if (requested_w == null and requested_h != null) requested_h.? else target_w / r;
    if (target_w <= 0 or target_h <= 0) return null;

    const ceiling_w = if (avail_w > 0) @min(avail_w, max_image_display_width) else max_image_display_width;
    const ceiling_h = max_image_display_height;
    const fit = @min(1.0, @min(ceiling_w / target_w, ceiling_h / target_h));
    return .{ .w = target_w * fit, .h = target_h * fit };
}

fn alignGravityX(want: RequestedSize) f32 {
    return switch (want.alignment orelse .left) {
        .left => 0,
        .center => 0.5,
        .right => 1,
    };
}

fn renderImageCaption(alt: []const u8, ctx: RenderContext, ids: *IdGen) void {
    if (alt.len == 0) return;
    var cap = textLayout(@src(), .{}, .{
        .expand = .horizontal,
        .margin = .{ .y = 2, .h = 0 },
        .background = ctx.background,
        .id_extra = ids.next(),
    });
    defer cap.deinit();
    addText(cap, alt, .{
        .font = dvui.Font.theme(.body).larger(-1),
        .color_text = dvui.themeGet().color(.control, .text).opacity(0.65),
    });
}

/// GFM task-list marker (`- [ ]` / `- [x]`), drawn rather than written.
///
/// This used to be a `"✓"` / `"•"` label, which showed up as a missing-glyph box: neither body
/// font fizzy ships (PlusJakartaSans, Comfortaa) has U+2713 — only the mono face does. Drawing
/// the box and using the bundled `entypo.check` vector keeps the marker correct under any font
/// the user picks, and gives unchecked items a real empty box instead of a plain bullet.
/// Where a list marker has to sit so it reads as being on the same line as the item's text.
///
/// Measured, not guessed: a glyph marker (`•`, `1.`) lands on the text's optical center for free
/// because its widget is itself a line box, and screenshots confirm both are centered to within a
/// pixel. A *drawn* box has no baseline of its own, so centering it in the line box left it ~4pt
/// high — the text's ink sits below the line box center by roughly half the line gap plus the
/// ascent. These numbers reproduce the glyph markers' placement to within ~0.2pt at body size.
const MarkerMetrics = struct {
    /// Side of the drawn checkbox, excluding its 1pt border.
    side: f32,
    /// Top margin that puts the drawn box's center on the text's ink center.
    top: f32,

    fn forBody() MarkerMetrics {
        const font = dvui.Font.theme(.body);
        const line_h = font.lineHeight();
        const side = @round(line_h * 0.72);

        var ascent: f32 = 0;
        _ = font.textSizeEx("x", .{ .ascent_out = &ascent });
        const line_gap = line_h - font.textHeight();
        const ink_center = ascent + line_gap / 2;

        // `border` adds 1pt on each side, so the box's drawn extent is `side + 2`.
        return .{ .side = side, .top = @max(0, ink_center - (side + 2) / 2) };
    }
};

fn renderTaskCheckbox(checked: bool, m: MarkerMetrics, ids: *IdGen) void {
    const theme = dvui.themeGet();

    var b = box(@src(), .{ .dir = .horizontal }, .{
        .min_size_content = .{ .w = m.side, .h = m.side },
        .max_size_content = .{ .w = m.side, .h = m.side },
        .gravity_y = 0,
        .margin = .{ .y = m.top },
        .background = true,
        .color_fill = if (checked) theme.color(.highlight, .fill) else theme.color(.control, .fill),
        .border = dvui.Rect.all(1),
        .color_border = if (checked) theme.color(.highlight, .fill) else theme.border.opacity(0.7),
        .corners = dvui.CornerRect.all(3),
        .id_extra = ids.next(),
    });
    defer b.deinit();

    if (checked) {
        dvui.icon(@src(), "task-checked", dvui.entypo.check, .{}, .{
            .expand = .ratio,
            .gravity_x = 0.5,
            .gravity_y = 0.5,
            .color_text = theme.color(.highlight, .text),
            .id_extra = ids.next(),
        });
    }
}

fn renderInlineFlowContainer(container: md.Node, span: dvui.Options, ctx: RenderContext, ids: *IdGen) void {
    var cur: ?md.Node = container.firstChild();
    while (cur) |node| {
        if (node.nodeType() == md.c.CMARK_NODE_IMAGE) {
            renderMarkdownImage(node, span, ctx, ids);
            cur = node.nextSibling();
            continue;
        }
        if (hasImageSubtree(ctx, node)) {
            switch (node.nodeType()) {
                md.c.CMARK_NODE_HTML_INLINE => {
                    // Only reachable when the tag carried an `<img src>` (that's what put this
                    // node in `subtree_has_image`); draw the images, drop the markup.
                    if (ctx.rs.html_images.get(@intFromPtr(node.n))) |urls| {
                        for (urls) |html_img| {
                            renderImageUrl(html_img.src, "", .{
                                .width = html_img.width,
                                .height = html_img.height,
                                .alignment = html_img.alignment,
                            }, ctx, ids);
                        }
                    }
                },
                md.c.CMARK_NODE_EMPH => {
                    if (node.firstChild()) |_| {
                        const f = span.fontGet().withStyle(.italic);
                        renderInlineFlowContainer(node, span.override(.{ .font = f }), ctx, ids);
                    }
                },
                md.c.CMARK_NODE_STRONG => {
                    if (node.firstChild()) |_| {
                        const f = span.fontGet().withWeight(.bold);
                        renderInlineFlowContainer(node, span.override(.{ .font = f }), ctx, ids);
                    }
                },
                md.c.CMARK_NODE_LINK => {
                    const link_font = span.fontGet().withUnderline(.{});
                    const link_color = dvui.themeGet().focus;
                    renderInlineFlowContainer(node, span.override(.{ .font = link_font, .color_text = link_color }), ctx, ids);
                },
                else => {
                    if (extKind(ctx, node) == .strikethrough) {
                        const strike_font = span.fontGet().withStrike(.{});
                        const strike_color = dvui.themeGet().color(.control, .text).opacity(0.5);
                        renderInlineFlowContainer(node, span.override(.{ .font = strike_font, .color_text = strike_color }), ctx, ids);
                    } else if (node.firstChild()) |_| {
                        renderInlineFlowContainer(node, span, ctx, ids);
                    } else if (node.literal()) |t| {
                        var tl = textLayout(@src(), .{}, .{
                            .expand = .horizontal,
                            .background = span.background,
                            .id_extra = ids.next(),
                        });
                        defer tl.deinit();
                        addText(tl, t, .{ .font = span.font, .color_text = span.color_text });
                    }
                },
            }
            cur = node.nextSibling();
            continue;
        }

        // Batch a run of siblings that contain no images into one textLayout.
        const run_first = node;
        var run_last = node;
        var scan: ?md.Node = node;
        while (scan) |s| {
            if (s.nodeType() == md.c.CMARK_NODE_IMAGE) break;
            if (hasImageSubtree(ctx, s)) break;
            run_last = s;
            scan = s.nextSibling();
        }

        var tl = textLayout(@src(), .{}, .{
            .expand = .horizontal,
            .margin = .{ .y = 2, .h = 2 },
            .background = span.background,
            .id_extra = ids.next(),
        });
        defer tl.deinit();
        var z: ?md.Node = run_first;
        while (z) |w| {
            renderInlineNodeToTl(tl, w, span, ctx, ids);
            if (w.n == run_last.n) break;
            z = w.nextSibling();
        }
        cur = run_last.nextSibling();
    }
}

/// `span` carries inherited font/color down into inline content.
/// Only `.font` and `.color_text` are meaningful here.
/// Caller must ensure `n` has no `CMARK_NODE_IMAGE` in any descendant.
fn renderInlines(tl: *dvui.TextLayoutWidget, n: md.Node, span: dvui.Options, ctx: RenderContext, ids: *IdGen) void {
    std.debug.assert(!hasImageSubtree(ctx, n));
    var cur: ?md.Node = n.firstChild();
    while (cur) |x| : (cur = x.nextSibling()) {
        renderInlineNodeToTl(tl, x, span, ctx, ids);
    }
}

/// A run of body text, with any `[[wikilinks]]` in it drawn as links.
///
/// The no-wikilinks path — no resolver, or none in this node — must produce **exactly** what
/// this used to: one `addText` of the whole literal, brackets and all. That's not just an
/// optimization, it's the contract that markdown renders identically with no indexer plugin
/// installed, and it's why the fast path is a single hash miss.
fn renderTextWithWikilinks(
    tl: *dvui.TextLayoutWidget,
    node: md.Node,
    literal: []const u8,
    span: dvui.Options,
    ctx: RenderContext,
) void {
    const plain: dvui.Options = .{ .font = span.font, .color_text = span.color_text };
    if (ctx.wikilink == null) return addText(tl, literal, plain);
    const tokens = ctx.rs.wikilinks.get(@intFromPtr(node.n)) orelse return addText(tl, literal, plain);

    var cursor: usize = 0;
    for (tokens, 0..) |tok, i| {
        if (tok.start > cursor) addText(tl, literal[cursor..tok.start], plain);
        renderWikilink(tl, node, i, tok, span, ctx);
        cursor = tok.end;
    }
    if (cursor < literal.len) addText(tl, literal[cursor..], plain);
}

fn renderWikilink(
    tl: *dvui.TextLayoutWidget,
    node: md.Node,
    token_index: usize,
    tok: wikilink_scan.Token,
    span: dvui.Options,
    ctx: RenderContext,
) void {
    const theme = dvui.themeGet();
    const label = tok.label();
    const res = resolveWikilink(ctx, node, token_index, tok);

    switch (res.status) {
        // Still scanning. Deliberately unstyled: painting every link red for the second after a
        // folder opens, then flipping them all blue, is worse than showing nothing at all.
        .indexing => addText(tl, label, .{ .font = span.font, .color_text = span.color_text }),

        .resolved, .ambiguous => {
            const color = if (res.status == .ambiguous) theme.color(.err, .fill) else theme.focus;
            const opts = span.override(.{
                .font = span.fontGet().withUnderline(.{}),
                .color_text = color,
            });
            if (tl.addTextClick(label, opts)) |click| {
                const open_side = click == .mouse and
                    (click.mouse.button == .middle or click.mouse.mod.matchBind("ctrl/cmd"));
                _ = revealPath(res.path, res.line, 0, open_side);
            }
        },

        // Nothing to open — but a link to a note you haven't written yet is a completely normal
        // thing to have in a wiki, not an error. So: still visibly a link, just unfinished — a
        // hairline underline and dimmed text, rather than the error red a broken URL would get.
        // (dvui's `Underline` carries thickness only, no dash style, so weight is what's
        // available to say "provisional" with.) Inert until there's a create-note flow.
        .unresolved => addText(tl, label, .{
            .font = span.fontGet().withUnderline(.{ .thick = 0.04 }),
            .color_text = (span.color_text orelse theme.color(.content, .text)).opacity(0.6),
        }),
    }
}

fn renderInlineNodeToTl(tl: *dvui.TextLayoutWidget, x: md.Node, span: dvui.Options, ctx: RenderContext, ids: *IdGen) void {
    switch (x.nodeType()) {
        md.c.CMARK_NODE_TEXT => {
            if (x.literal()) |t| renderTextWithWikilinks(tl, x, t, span, ctx);
        },
        md.c.CMARK_NODE_SOFTBREAK => {
            addText(tl, " ", .{});
        },
        md.c.CMARK_NODE_LINEBREAK => {
            addText(tl, "\n", .{});
        },
        md.c.CMARK_NODE_CODE => {
            if (x.literal()) |t| {
                addText(tl, t, .{
                    // Match the editor's monospace size (also `Font.theme(.mono)`).
                    .font = dvui.Font.theme(.mono),
                    .color_text = dvui.themeGet().color(.control, .text).opacity(0.9),
                });
            }
        },
        md.c.CMARK_NODE_EMPH => {
            if (x.firstChild()) |_| {
                const f = span.fontGet().withStyle(.italic);
                renderInlines(tl, x, span.override(.{ .font = f }), ctx, ids);
            }
        },
        md.c.CMARK_NODE_STRONG => {
            if (x.firstChild()) |_| {
                const f = span.fontGet().withWeight(.bold);
                renderInlines(tl, x, span.override(.{ .font = f }), ctx, ids);
            }
        },
        md.c.CMARK_NODE_LINK => {
            const link_font = span.fontGet().withUnderline(.{});
            const link_color = dvui.themeGet().focus;
            const link_opts = span.override(.{ .font = link_font, .color_text = link_color });
            const url = x.linkUrl() orelse "";
            if (url.len == 0) {
                if (x.firstChild()) |_| renderInlines(tl, x, link_opts, ctx, ids);
            } else {
                const arena = dvui.currentWindow().arena();
                if (linkLabelPlainText(x, arena)) |display| {
                    addMarkdownLink(tl, url, if (display.len == 0) null else display, link_opts, ctx);
                } else |_| {
                    if (x.firstChild()) |_| renderInlines(tl, x, link_opts, ctx, ids);
                }
            }
        },
        md.c.CMARK_NODE_IMAGE => unreachable,
        md.c.CMARK_NODE_HTML_INLINE => {
            if (x.literal()) |t| addText(tl, t, .{
                .font = dvui.Font.theme(.mono),
                .color_text = dvui.themeGet().color(.err, .text),
            });
        },
        md.c.CMARK_NODE_FOOTNOTE_REFERENCE => {
            if (x.literal()) |t| {
                const fn_font = dvui.Font.theme(.mono).larger(-1);
                const fn_color = dvui.themeGet().focus.opacity(0.8);
                addText(tl, "[^", .{ .font = fn_font, .color_text = fn_color });
                addText(tl, t, .{ .font = fn_font, .color_text = fn_color });
                addText(tl, "]", .{ .font = fn_font, .color_text = fn_color });
            }
        },
        else => {
            if (extKind(ctx, x) == .strikethrough) {
                const strike_font = span.fontGet().withStrike(.{});
                const strike_color = dvui.themeGet().color(.control, .text).opacity(0.5);
                renderInlines(tl, x, span.override(.{ .font = strike_font, .color_text = strike_color }), ctx, ids);
            } else if (x.firstChild()) |_| {
                renderInlines(tl, x, span, ctx, ids);
            } else if (x.literal()) |t| {
                addText(tl, t, .{ .font = span.font, .color_text = span.color_text });
            }
        },
    }
}

/// Draw the document's top-level blocks, laying out only the ones near the viewport.
///
/// Why this exists: every widget the renderer emits costs a full layout pass, and a
/// `TextLayoutWidget` re-shapes all of its text every frame — there is no per-string shaping
/// cache in dvui, and a paragraph is far too small for `cache_layout` (which skips *within* one
/// widget) to help. So the old "walk the whole AST every frame" cost was linear in the document's
/// **bytes**, not in what was on screen: docs/PLUGINS.md spent ~34ms/frame in Debug laying out
/// 58KB of text to show maybe 3KB of it, and scrolling to the end cost exactly the same as
/// sitting at the top. See `tests/bench/bench_markdown.zig`.
///
/// Each top-level block gets a wrapper box carrying its measured height. Off screen, the wrapper
/// is emitted with that height and its contents are skipped entirely; the scroll container still
/// sees the document's true total height, so the scrollbar and every scroll position stay exactly
/// as they were. A block whose height isn't known at all is always drawn, so the cache fills in
/// without ever showing a gap — which makes a document's first frame one full layout, and only
/// one.
///
/// Widths change every frame while a panel animates open or a window is dragged, which is
/// handled by `resettle_budget` rather than by throwing the cache away — see below.
///
/// The wrapper is also what makes the ids stable: widget ids inside a block are relative to it,
/// so `ids` restarts per block and a skipped neighbour can't shift anything.
fn renderTopLevel(doc_node: md.Node, ids: *IdGen, ctx: RenderContext) void {
    const rs = ctx.rs;
    const metrics = currentMetrics();

    // Width in flux this frame (sash open animation, first layout of a new pane, window resize
    // drag). Cached heights are for a different column, so they stop being trusted — but they are
    // *kept*, not clamped toward the estimate. Clamping was how a narrow→wide resize used to
    // collapse the document's height model: an image or a table occupies one line of source, so
    // its estimate is a dozen pixels against a real several hundred, and every sash drag crushed
    // it to that. The blank pane that clamping was meant to prevent is now prevented properly,
    // by `visibleRange` being guaranteed non-empty.
    const width_in_flux = rs.blocks.invalidateForWidth(ctx.column_width);
    rs.width_in_flux = width_in_flux;
    if (diag and width_in_flux) {
        dvui.log.warn("md-diag: column width now {d:.2} — every cached height distrusted, tables unpinned", .{ctx.column_width});
    }
    if (width_in_flux) {
        // Come back next frame — if the width has stopped moving, resettle can start.
        dvui.refresh(null, @src(), null);
    }

    // Draw beyond the viewport by half a screen each way. dvui needs the widget to exist for a
    // frame before it can be scrolled onto properly, and a keyboard/scrollbar jump can move the
    // viewport by more than a wheel tick does; the margin absorbs both without being large
    // enough to matter for cost.
    const virtualize = virtualize_blocks and ctx.viewport.h > 0;
    const slack = @max(200, ctx.viewport.h * 0.5);
    const vis_top = ctx.viewport.y - slack;
    const vis_bot = ctx.viewport.y + ctx.viewport.h + slack;
    // The viewport top: the line between "re-measuring this is free" and "re-measuring this
    // moves the reader, and costs a frame to put them back". See the budgets below.
    const anchor_y = ctx.viewport.y;

    // The blocks that must be laid out to cover the viewport, decided up front against the height
    // table rather than block-by-block during the walk. Doing it here is what makes "the pane is
    // never blank" a property of one function with tests behind it (`Table.visibleRange`) instead
    // of an emergent hope about the per-block predicate below.
    const must_draw: ?bh.Table.Range = if (!virtualize) null else rs.blocks.visibleRange(
        ctx.viewport.y,
        ctx.viewport.h,
        slack,
        metrics,
        ctx.column_width,
        ctx.content_origin_y,
    );

    // Two budgets, split by what a re-measure *costs the reader* rather than by distance.
    //
    // Below the viewport top is free: the anchor holds the reader's position against the block
    // they are on, so a block further down changing height moves nothing they can see.
    // Above the viewport top is not free: it shifts everything below it, and the anchor only puts
    // the reader back on the *next* frame (positions are resolved before layout, and a height
    // discovered during layout arrives too late for it). Correct, but briefly visible.
    //
    // Neither budget may be zero. A block that is never re-measured keeps its `estimate`,
    // estimates are biased low on purpose, and a document whose height is mostly low guesses has
    // a scrollbar that lies by thousands of pixels — which scrolling then "discovers" a screen at
    // a time. That was the reported instability, and the earlier distance gate caused it by
    // starving distant blocks outright (164 of 185 unmeasured after 600 frames on
    // docs/PLUGIN_MANIFEST_PLAN.md). Both budgets being non-zero is what makes the sweep
    // terminate: once every block has been measured twice, nothing wants a re-measure,
    // `pending_measure` hits zero, and the refresh loop stops. A bounded warm-up, not a
    // permanent wake.
    var resettle_below_left: usize = if (width_in_flux) 0 else resettle_below_budget;
    var resettle_above_left: usize = if (width_in_flux) 0 else resettle_above_budget;

    // Skipped blocks used to each get their own empty `box` with `min_size_content = h`. On a
    // multi-thousand-block document that meant thousands of widgets per frame even when only a
    // handful were on screen — the open hitch and the steady ~20ms frames while a large preview
    // sat idle. Contiguous skips collapse into one spacer instead.
    var skip_run_h: f32 = 0;
    var skip_run_id: usize = 0;

    const flushSkip = struct {
        fn f(run_h: *f32, run_id: usize) void {
            if (run_h.* <= 0) return;
            var spacer = box(@src(), .{ .dir = .vertical }, .{
                .expand = .horizontal,
                // Stable across frames for a given skip-run start so scroll anchoring stays
                // coherent when a neighbouring run's height changes.
                .id_extra = run_id +% 0x7000_0000,
                .min_size_content = .{ .h = run_h.* },
            });
            spacer.deinit();
            run_h.* = 0;
        }
    }.f;

    var y = ctx.content_origin_y;
    var index: usize = 0;
    var child = doc_node.firstChild();
    while (child) |ch| : ({
        child = ch.nextSibling();
        index += 1;
    }) {
        // A block never laid out yet is placed by a guess from how much source it came from. The
        // guess only has to be good enough to decide "near the viewport or not", and it is
        // deliberately biased *low* (see `Table.estimate`): guessing short draws a few extra
        // blocks, while guessing tall would skip one that is actually on screen and flash a gap.
        rs.blocks.ensureSlot(ctx.gpa, index, metrics, ctx.column_width);
        const known_h = rs.blocks.heightAt(index, metrics, ctx.column_width);
        const state = rs.blocks.stateAt(index);

        // `y` is always this block's start (skip runs advance it too; the spacer is just how
        // that reserved height reaches the scroll container).
        //
        // Two independent reasons to draw, and the union of them is deliberate. `must_draw` is
        // computed up front from the pre-frame height table, so it is the one that can *promise*
        // a non-empty result; the running `y` is more accurate within the frame, because blocks
        // above this one may have re-measured since that promise was made. Neither alone is both.
        const on_screen_now = y < vis_bot and (y + known_h) > vis_top;
        var draw = on_screen_now or
            !rs.blocks.placeable(index) or
            if (must_draw) |r| r.contains(index) else true;
        if (!draw and (bh.Height{ .h = known_h, .state = state }).wantsMeasure()) {
            // Entirely above the reader, or not? That is the only distinction that matters —
            // see the budgets above.
            const above = (y + known_h) <= anchor_y;
            const budget = if (above) &resettle_above_left else &resettle_below_left;
            if (budget.* > 0) {
                draw = true;
                budget.* -= 1;
            } else {
                // Owed a re-measure that this frame's budget couldn't pay for; see
                // `Stats.pending_measure`.
                stats.pending_measure += 1;
            }
        }

        if (!draw) {
            if (skip_run_h == 0) skip_run_id = index;
            skip_run_h += known_h;
            y += known_h;
            continue;
        }

        // Emit the spacer for everything we skipped above this block before laying it out.
        flushSkip(&skip_run_h, skip_run_id);

        // A block whose last measurement could not be trusted gets its height *pinned* to the one
        // we do trust, rather than being allowed to report whatever this frame's layout produces.
        //
        // Refusing to record an untrustworthy measurement is not enough on its own: the widget is
        // still emitted at whatever height it came out to, and the scroll container builds
        // `virtual_size` from the widgets, not from this file's height table. A table under row
        // culling is spectacularly unstable that way — the same block measured 46pt on one frame
        // and 29,995pt on another (real height ~6,132) as the visible row set changed — and each
        // swing moved the scrollbar and everything below it. Pinning both ends of the size makes
        // the block occupy exactly what the table says it occupies, so layout and bookkeeping
        // cannot disagree.
        //
        // The pin is released as soon as the block produces a measurement worth believing, which
        // for a table means every one of its rows has been measured at least once.
        // Scoped to blocks containing a table, and to states where the cached number is one we
        // believe. Reacting to *this* frame's contamination would always be a frame late — the
        // garbage measurement has already been emitted by then — so the pin goes on as soon as
        // there is something worth holding, and comes off only when a width change demotes the
        // entry back to `.measured` and the block genuinely has to be re-measured.
        const block_state = rs.blocks.stateAt(index);
        // ...and never while the column width is moving: that is precisely when the block has to
        // be allowed to relearn its height, and a pin there would hold it at its pre-resize size.
        const pin_h: ?f32 = if (known_h > 0 and !width_in_flux and
            (block_state == .settled or block_state == .deferred) and
            rs.subtree_has_table.contains(@intFromPtr(ch.n))) known_h else null;
        var wrapper = box(@src(), .{ .dir = .vertical }, .{
            .expand = .horizontal,
            .id_extra = index,
            .min_size_content = if (pin_h) |h| .{ .h = h } else null,
            .max_size_content = if (pin_h) |h| .height(h) else null,
        });
        const wrapper_id = wrapper.data().id;
        const prof_t0 = if (block_profile == null) 0 else std.Io.Clock.boot.now(dvui.io).nanoseconds;
        const prof_tl = stats.text_layouts;
        const prof_bytes = stats.add_text_bytes;
        ids.n = 0;
        rs.block_rows_pending = 0;
        rs.block_measure_exhausted = !(bh.Height{
            .h = known_h,
            .state = block_state,
            .attempts = rs.blocks.attemptsAt(index),
        }).wantsMeasure();
        renderBlock(ch, ids, ctx);
        wrapper.deinit();
        if (block_profile) |list| {
            list.append(block_profile_gpa.?, .{
                .index = index,
                .kind = ch.typeString(),
                .ns = @intCast(std.Io.Clock.boot.now(dvui.io).nanoseconds - prof_t0),
                .text_layouts = stats.text_layouts - prof_tl,
                .add_text_bytes = stats.add_text_bytes - prof_bytes,
            }) catch {};
        }

        const measured = (dvui.minSizeGet(wrapper_id) orelse dvui.Size{}).h;
        // The height is known — but is it *worth* knowing? A table whose rows have not all been
        // measured reports a height built from a scroll-position-dependent mix of real rows and
        // placeholders, so it measures differently depending on where the reader came from. That
        // is a height that cannot be believed, and believing it is what made the document jump
        // when scrolling past a table. `record` files it as `.deferred`: keep what we had, and
        // stop short of calling it an answer.
        //
        // This used to key off "was the block off screen?" instead, on the theory that an
        // off-screen table renders only its header. That stopped being true once culled cells
        // started reporting a real placeholder height, and by then the test had inverted: it
        // froze the *collapsed* first-frame measurement of a table the reader had never visited
        // and never revisited it, leaving the document ~1300px short per table.
        const partial = rs.block_rows_pending > 0;
        rs.blocks.record(ctx.gpa, index, .{ .h = measured, .partial = partial }, metrics, ctx.column_width);
        const after_h = rs.blocks.heightAt(index, metrics, ctx.column_width);
        if (diag and known_h > 0 and @abs(after_h - known_h) > diag_height_jump) {
            dvui.log.warn(
                "md-diag: block {d} ({s}) height {d:.0} -> {d:.0} ({s}, rows_pending={d}) at viewport y={d:.0}",
                .{ index, @tagName(rs.blocks.extents.items[index].kind), known_h, after_h, @tagName(rs.blocks.stateAt(index)), rs.block_rows_pending, ctx.viewport.y },
            );
        }
        // No scroll compensation here any more. A height change above the reader used to need a
        // delta accumulated and applied to `viewport.y` after the fact; the anchor makes the
        // reader's position a function of the current heights, so it simply re-derives.
        y += after_h;
    }
    flushSkip(&skip_run_h, skip_run_id);
}

/// Font metrics for `block_heights.zig`, which is deliberately dvui-free and so cannot read the
/// theme itself.
///
/// `sizeM` is the width of an "M"; ordinary prose averages a good deal narrower than that, and
/// erring narrow means erring toward *more* estimated lines, which is the safe direction.
pub fn currentMetricsForTest() bh.Metrics {
    return currentMetrics();
}

fn currentMetrics() bh.Metrics {
    const font = dvui.Font.theme(.body);
    return .{ .line_h = font.lineHeight(), .em_w = font.sizeM(1, 1).w };
}

pub const Anchor = bh.Anchor;

/// Where `a` points, as a scroll offset against the heights as they currently stand. Applied by
/// the preview *before* the scroll area is built — see `markdown.drawPreview`.
pub fn anchorResolve(rs: *const RenderState, a: Anchor, column_width: f32, origin_y: f32, max_scroll: f32) f32 {
    return rs.blocks.resolveAnchor(a, currentMetrics(), column_width, origin_y, max_scroll);
}

/// Turn the settled scroll offset back into an anchor, after the scroll area has committed.
pub fn anchorCapture(rs: *const RenderState, viewport_y: f32, column_width: f32, origin_y: f32, max_scroll: f32) ?Anchor {
    return rs.blocks.captureAnchor(viewport_y, currentMetrics(), column_width, origin_y, max_scroll);
}

/// True when any cell in this table row still needs a real layout pass — never measured, measured
/// only once and so possibly still settling, or measured against a column width the grid has
/// since changed its mind about.
fn rowNeedsMeasure(ctx: RenderContext, g: *dvui.GridWidget, row: md.Node) bool {
    var col: usize = 0;
    var cl = row.firstChild();
    while (cl) |cell| : (cl = cell.nextSibling()) {
        if (extKind(ctx, cell) != .table_cell) continue;
        defer col += 1;
        const cached = ctx.rs.cell_sizes.get(@intFromPtr(cell.n)) orelse return true;
        if (!cached.settled or cached.col_w != g.colWidth(col)) return true;
    }
    return false;
}

/// Column widths for one table: natural where the table fits, squeezed to `avail` where it
/// doesn't. Cached per table node (see `RenderState.table_layouts`) — the walk below visits every
/// cell in the table, which is exactly the work the render path goes to such lengths to avoid
/// doing per frame.
///
/// Why compute widths here at all, rather than let the grid auto-size them? Because the grid's
/// only inputs are the cells' *laid-out* min sizes, and a cell that wrapped reports the width it
/// wrapped to. Feed those back and the columns ratchet: shrink-to-fit narrows a column, the cell
/// inside re-wraps narrower, the next frame's measurement is narrower still, and a short cell
/// ends up one character wide. Natural widths are measured from the text instead, so they are the
/// same every frame no matter what the table currently looks like.
fn tableColumnWidths(n: md.Node, num_cols: usize, avail: f32, cell_padding: dvui.Rect, ctx: RenderContext) []const f32 {
    const font = dvui.Font.theme(.body);
    const body_m = font.sizeM(1, 1).w;
    const mono_m = dvui.Font.theme(.mono).sizeM(1, 1).w;
    const key = @intFromPtr(n.n);
    if (ctx.rs.table_layouts.getPtr(key)) |cached| {
        if (cached.body_m == body_m and cached.mono_m == mono_m and cached.natural.len == num_cols) {
            if (cached.avail == avail) return cached.widths;
            // Only the space available changed — which is every frame of a sash drag. The natural
            // widths are still valid, so re-fit them instead of re-measuring the whole table.
            @memcpy(cached.widths, cached.natural);
            fitColumns(cached.widths, avail, ctx.gpa);
            cached.avail = avail;
            return cached.widths;
        }
    }

    const natural = ctx.gpa.alloc(f32, num_cols) catch return &.{};
    @memset(natural, 0);
    const widths = ctx.gpa.alloc(f32, num_cols) catch {
        ctx.gpa.free(natural);
        return &.{};
    };

    // What a cell adds around its text: the grid cell's own padding, plus the `textLayout` the
    // content is drawn in (`TextLayoutWidget` has non-zero default padding, which is why the
    // grid's own default minimum is padded the same way). Leaving this out measured every column
    // a little too narrow, and a one-character column too narrow to show its character at all.
    const pad_w = cell_padding.x + cell_padding.w +
        dvui.TextLayoutWidget.defaults.paddingGet().x + dvui.TextLayoutWidget.defaults.paddingGet().w;

    var row = n.firstChild();
    while (row) |r| : (row = r.nextSibling()) {
        const rk = extKind(ctx, r);
        if (rk != .table_row and rk != .table_header) continue;
        const cell_font = if (rk == .table_header) font.withWeight(.bold) else font;
        var col: usize = 0;
        var cl = r.firstChild();
        while (cl) |cell| : (cl = cell.nextSibling()) {
            if (extKind(ctx, cell) != .table_cell) continue;
            defer col += 1;
            if (col >= num_cols) continue;
            // Rounded up: text measurement and layout disagree by fractions of a point, and a
            // column a fraction under what its text needs wraps a whole character.
            natural[col] = @max(natural[col], @ceil(inlineNaturalWidth(cell, cell_font) + pad_w) + 1);
        }
    }

    @memcpy(widths, natural);
    fitColumns(widths, avail, ctx.gpa);

    const old = ctx.rs.table_layouts.fetchPut(ctx.gpa, key, .{
        .natural = natural,
        .widths = widths,
        .avail = avail,
        .body_m = body_m,
        .mono_m = mono_m,
    }) catch {
        // Out of memory: hand back nothing and let the grid auto-size this table, rather than
        // leak a width vector nothing owns.
        ctx.gpa.free(natural);
        ctx.gpa.free(widths);
        return &.{};
    };
    if (old) |kv| {
        ctx.gpa.free(kv.value.natural);
        ctx.gpa.free(kv.value.widths);
    }
    return widths;
}

/// The width one table cell's contents want on a single unwrapped line. Walks the inlines rather
/// than flattening to plain text so each run is measured in the font it will actually be drawn
/// in: `` `--verbose` `` is monospace and wider than the same characters in the body font, and a
/// column measured in the wrong font is a column that wraps when it shouldn't.
fn inlineNaturalWidth(node: md.Node, font: dvui.Font) f32 {
    var total: f32 = 0;
    var c = node.firstChild();
    while (c) |x| : (c = x.nextSibling()) {
        switch (x.nodeType()) {
            md.c.CMARK_NODE_TEXT, md.c.CMARK_NODE_HTML_INLINE => {
                if (x.literal()) |t| total += font.textSize(t).w;
            },
            md.c.CMARK_NODE_CODE => {
                if (x.literal()) |t| total += dvui.Font.theme(.mono).textSize(t).w;
            },
            md.c.CMARK_NODE_SOFTBREAK, md.c.CMARK_NODE_LINEBREAK => total += font.textSize(" ").w,
            md.c.CMARK_NODE_STRONG => total += inlineNaturalWidth(x, font.withWeight(.bold)),
            md.c.CMARK_NODE_EMPH => total += inlineNaturalWidth(x, font.withStyle(.italic)),
            else => total += inlineNaturalWidth(x, font),
        }
    }
    return total;
}

/// Squeeze `widths` (natural, in place) into `avail`, leaving them alone when they already fit.
///
/// Max-min fair: a column narrower than an equal share of the space keeps its natural width in
/// full, and only the columns wider than their share give anything up — proportionally, and only
/// as far as the space that's left over once the narrow ones are paid. Repeated until no more
/// columns fall under the share, since paying the narrow ones raises it for everyone else.
///
/// The naive alternative — scale every column by the same factor — is what made `| flag |
/// description |` wrap the *flag*: the long description alone can cover the whole overflow, but
/// proportional scaling still takes its cut out of a column that had nothing to spare.
fn fitColumns(widths: []f32, avail: f32, gpa: std.mem.Allocator) void {
    if (widths.len == 0) return;
    var total: f32 = 0;
    for (widths) |w| total += w;
    if (total <= avail) return;

    const settled = gpa.alloc(bool, widths.len) catch return;
    defer gpa.free(settled);
    @memset(settled, false);

    var avail_left = avail;
    var cols_left: usize = widths.len;
    while (cols_left > 0) {
        const share = avail_left / @as(f32, @floatFromInt(cols_left));
        var any = false;
        for (widths, settled) |w, *s| {
            if (s.* or w > share) continue;
            s.* = true;
            any = true;
            avail_left -= w;
            cols_left -= 1;
        }
        if (!any) break;
    }

    // Whatever is left over goes to the columns still over their share, in proportion to what
    // they asked for. `cols_left == 0` means everything fit after all, which the total check
    // above already ruled out — but the loop is the only thing that proves it, so don't divide
    // by a zero it could produce.
    if (cols_left == 0) return;
    var over_total: f32 = 0;
    for (widths, settled) |w, s| {
        if (!s) over_total += w;
    }
    if (over_total <= 0) return;
    const scale = @max(0, avail_left) / over_total;
    for (widths, settled) |*w, s| {
        if (!s) w.* *= scale;
    }
}

fn renderBlock(n: md.Node, ids: *IdGen, ctx: RenderContext) void {
    statBlock();
    const t = n.nodeType();
    switch (t) {
        md.c.CMARK_NODE_DOCUMENT => renderTopLevel(n, ids, ctx),
        md.c.CMARK_NODE_BLOCK_QUOTE => {
            var outer = box(@src(), .{ .dir = .horizontal }, .{
                .expand = .horizontal,
                .margin = .{ .x = block_inset_x, .y = 4, .w = block_inset_x, .h = 4 },
                .id_extra = ids.next(),
            });
            defer outer.deinit();

            _ = dvui.spacer(@src(), .{
                .min_size_content = .{ .w = 3, .h = 0 },
                .expand = .vertical,
                .background = true,
                .color_fill = dvui.themeGet().color(.highlight, .fill).opacity(0.75),
                .corners = dvui.CornerRect.all(2),
                .id_extra = ids.next(),
            });

            var content = box(@src(), .{ .dir = .vertical }, .{
                .expand = .horizontal,
                .padding = .{ .x = 10, .y = 4, .w = 0, .h = 4 },
                .id_extra = ids.next(),
            });
            defer content.deinit();

            var c = n.firstChild();
            while (c) |ch| : (c = ch.nextSibling()) renderBlock(ch, ids, ctx);
        },
        md.c.CMARK_NODE_LIST => {
            var it = n.firstChild();
            var idx: i32 = n.listStart();
            const list_kind = n.listKind();
            const col_w = dvui.Font.theme(.body).sizeM(2.2, 0).w;
            // Once per list rather than per item: `textSizeEx` shapes a glyph and hits the font
            // cache, and every marker in one list resolves to the same placement anyway.
            const marker_metrics: MarkerMetrics = .forBody();
            while (it) |item_node| : (it = item_node.nextSibling()) {
                if (item_node.nodeType() != md.c.CMARK_NODE_ITEM) {
                    renderBlock(item_node, ids, ctx);
                    continue;
                }
                var row = box(@src(), .{ .dir = .horizontal }, .{
                    .expand = .horizontal,
                    .margin = .{ .y = 1 },
                    .id_extra = ids.next(),
                });
                defer row.deinit();

                var buf: [24]u8 = undefined;
                const task_checked: ?bool = ctx.rs.task_items.get(@intFromPtr(item_node.n));
                const bullet_str: []const u8 = switch (list_kind) {
                    .ul => "•",
                    .ol => std.fmt.bufPrint(&buf, "{d}.", .{idx}) catch "?",
                };
                if (list_kind == .ol) idx += 1;

                {
                    var pb = box(@src(), .{ .dir = .horizontal }, .{
                        .min_size_content = .{ .w = col_w, .h = 0 },
                        .gravity_y = 0,
                        // The item's content is a paragraph, and `CMARK_NODE_PARAGRAPH` gives its
                        // `textLayout` a 4pt top margin — without matching it here every marker
                        // sits a line-gap above the text it belongs to.
                        .margin = .{ .y = paragraph_margin_y },
                        .id_extra = ids.next(),
                    });
                    _ = dvui.spacer(@src(), .{ .expand = .horizontal, .id_extra = ids.next() });
                    if (task_checked) |checked| {
                        renderTaskCheckbox(checked, marker_metrics, ids);
                    } else {
                        dvui.labelNoFmt(@src(), bullet_str, .{}, .{
                            .gravity_y = 0,
                            .color_text = dvui.themeGet().color(.control, .text).opacity(0.45),
                            .id_extra = ids.next(),
                        });
                    }
                    pb.deinit();
                }

                _ = dvui.spacer(@src(), .{ .min_size_content = .{ .w = 5, .h = 0 }, .id_extra = ids.next() });

                var col = box(@src(), .{ .dir = .vertical }, .{
                    .expand = .horizontal,
                    .id_extra = ids.next(),
                });
                defer col.deinit();

                var sub = item_node.firstChild();
                while (sub) |s| : (sub = s.nextSibling()) {
                    renderBlock(s, ids, ctx);
                }
            }
        },
        md.c.CMARK_NODE_ITEM => {
            var c = n.firstChild();
            while (c) |ch| : (c = ch.nextSibling()) renderBlock(ch, ids, ctx);
        },
        md.c.CMARK_NODE_CODE_BLOCK => {
            const info = n.fenceInfo() orelse "";
            const code = n.literal() orelse "";
            var outer = box(@src(), .{ .dir = .vertical }, .{
                .expand = .horizontal,
                .margin = .{ .x = block_inset_x, .y = 6, .w = block_inset_x, .h = 6 },
                .background = true,
                .color_fill = dvui.themeGet().color(.window, .fill).opacity(0.9),
                .corners = dvui.CornerRect.all(6),
                .border = dvui.Rect.all(1),
                .color_border = dvui.themeGet().border.opacity(0.35),
                .id_extra = ids.next(),
            });
            defer outer.deinit();

            if (info.len > 0) {
                var hdr = box(@src(), .{ .dir = .horizontal }, .{
                    .expand = .horizontal,
                    .padding = .{ .x = 10, .y = 5, .w = 10, .h = 5 },
                    .background = true,
                    .color_fill = dvui.themeGet().border.opacity(0.12),
                    .id_extra = ids.next(),
                });
                defer hdr.deinit();
                var tl_i = textLayout(@src(), .{}, .{ .expand = .horizontal, .background = false, .id_extra = ids.next() });
                addText(tl_i, info, .{
                    .font = dvui.Font.theme(.mono).withWeight(.bold),
                    .color_text = dvui.themeGet().color(.control, .text).opacity(0.55),
                });
                tl_i.deinit();
            }

            var tl_c = textLayout(@src(), .{}, .{
                .expand = .horizontal,
                .padding = .{ .x = 10, .y = 8, .w = 10, .h = 8 },
                .background = false,
                .id_extra = ids.next(),
            });
            defer tl_c.deinit();
            addText(tl_c, code, .{ .font = dvui.Font.theme(.mono) });
        },
        md.c.CMARK_NODE_HTML_BLOCK => {
            // `<p align="center"><img …></p>` is how most READMEs carry their hero image; render
            // the images and drop the wrapper markup rather than dumping the tags as raw text.
            if (ctx.rs.html_images.get(@intFromPtr(n.n))) |urls| {
                var outer = box(@src(), .{ .dir = .vertical }, .{
                    .expand = .horizontal,
                    .id_extra = ids.next(),
                });
                defer outer.deinit();
                for (urls) |html_img| {
                    renderImageUrl(html_img.src, "", .{
                        .width = html_img.width,
                        .height = html_img.height,
                        .alignment = html_img.alignment,
                    }, ctx, ids);
                }
                return;
            }
            if (n.literal()) |h| {
                var tl = textLayout(@src(), .{}, .{
                    .expand = .horizontal,
                    .margin = .{ .x = block_inset_x, .y = 2, .w = block_inset_x, .h = 2 },
                    .padding = .{ .x = 8, .y = 4, .w = 8, .h = 4 },
                    .background = true,
                    .color_fill = dvui.themeGet().color(.err, .fill).opacity(0.08),
                    .id_extra = ids.next(),
                });
                defer tl.deinit();
                addText(tl, h, .{
                    .font = dvui.Font.theme(.mono),
                    .color_text = dvui.themeGet().color(.err, .text).opacity(0.85),
                });
            }
        },
        md.c.CMARK_NODE_PARAGRAPH => {
            if (!hasImageSubtree(ctx, n)) {
                var tl = textLayout(@src(), .{}, .{
                    .expand = .horizontal,
                    .margin = .{ .y = paragraph_margin_y, .h = paragraph_margin_y },
                    .background = ctx.background,
                    .id_extra = ids.next(),
                });
                defer tl.deinit();
                renderInlines(tl, n, .{ .background = ctx.background }, ctx, ids);
            } else {
                var outer = box(@src(), .{ .dir = .vertical }, .{
                    .expand = .horizontal,
                    .margin = .{ .y = paragraph_margin_y, .h = paragraph_margin_y },
                    .id_extra = ids.next(),
                });
                defer outer.deinit();
                renderInlineFlowContainer(n, .{ .background = ctx.background }, ctx, ids);
            }
        },
        md.c.CMARK_NODE_HEADING => {
            const level = @max(1, @min(6, n.headingLevel()));
            const size_bump: f32 = switch (level) {
                1 => 9,
                2 => 6,
                3 => 3,
                4 => 1,
                else => 0,
            };
            const top_margin: f32 = switch (level) {
                1 => 18,
                2 => 14,
                3 => 10,
                else => 7,
            };
            const heading_font = dvui.Font.theme(.heading).larger(size_bump - 2).withWeight(.bold);
            const span: dvui.Options = .{ .font = heading_font, .background = ctx.background };

            if (!hasImageSubtree(ctx, n)) {
                var tl = textLayout(@src(), .{}, .{
                    .expand = .horizontal,
                    .margin = .{ .y = top_margin, .h = 2 },
                    .font = heading_font,
                    .background = ctx.background,
                    .id_extra = ids.next(),
                });
                defer tl.deinit();
                renderInlines(tl, n, span, ctx, ids);
            } else {
                var outer = box(@src(), .{ .dir = .vertical }, .{
                    .expand = .horizontal,
                    .margin = .{ .y = top_margin, .h = 2 },
                    .id_extra = ids.next(),
                });
                defer outer.deinit();
                renderInlineFlowContainer(n, span, ctx, ids);
            }
        },
        md.c.CMARK_NODE_THEMATIC_BREAK => {
            _ = dvui.separator(@src(), .{
                .expand = .horizontal,
                .margin = .{ .y = 10, .h = 10 },
                .color_fill = dvui.themeGet().border.opacity(0.45),
                .id_extra = ids.next(),
            });
        },
        md.c.CMARK_NODE_FOOTNOTE_DEFINITION => {
            if (n.literal()) |name| {
                var tl = textLayout(@src(), .{}, .{
                    .expand = .horizontal,
                    .margin = .{ .y = 4 },
                    .background = ctx.background,
                    .id_extra = ids.next(),
                });
                const fn_font = dvui.Font.theme(.mono).larger(-1);
                const fn_color = dvui.themeGet().focus.opacity(0.8);
                addText(tl, "[^", .{ .font = fn_font, .color_text = fn_color });
                addText(tl, name, .{ .font = fn_font, .color_text = fn_color });
                addText(tl, "]: ", .{ .font = fn_font, .color_text = fn_color });
                tl.deinit();
            }
            var c = n.firstChild();
            while (c) |ch| : (c = ch.nextSibling()) renderBlock(ch, ids, ctx);
        },
        else => {
            if (extKind(ctx, n) == .table) {
                const arena = dvui.currentWindow().arena();

                const num_cols = ctx.rs.table_col_counts.get(@intFromPtr(n.n)) orelse return;
                if (num_cols == 0) return;

                // Holds the table's inset from the prose column (see `block_inset_x`). Expands so
                // the grid inside it is offered the full inset width — how much of that the table
                // actually takes is the grid's business, below.
                var table_wrap = box(@src(), .{ .dir = .vertical }, .{
                    .expand = .horizontal,
                    .margin = .{ .x = block_inset_x, .y = 8, .w = block_inset_x, .h = 8 },
                    .id_extra = ids.next(),
                });
                defer table_wrap.deinit();

                // `layout_only`: this is a content-sized preview table, not a spreadsheet. (The
                // row-culling path below still supplies `min_size_content` for skipped cells;
                // `layout_only` is what makes those heights stick every frame.)
                //
                // The width the table has to work with. Taken from the wrap rather than from
                // `ctx.column_width` so a table nested in a quote or list gets its container's
                // width, and — because the wrap expands — it is a *fixed* number rather than one
                // derived from how wide the table currently is. That distinction is the whole
                // trick: column widths computed against a number the columns themselves feed into
                // ratchet down a little every frame.
                const table_avail = blk: {
                    const w = table_wrap.data().contentRect().w;
                    // Headroom for the grid's own border, plus a point of slack. Without it, a
                    // squeezed table's columns sum to exactly the wrap width, the grid finds its
                    // viewport a hair narrower than that, and shaves the difference off every
                    // column — enough (0.3pt was the measured case) to push a column that fit its
                    // text perfectly into wrapping one character onto a second line.
                    break :blk @max(60, (if (w > 0) w else ctx.column_width - 2 * block_inset_x) - 4);
                };

                // `.expand = .none`: the table is as wide as its columns and no wider. A
                // two-column `| a | b |` stretched across the pane is harder to read than the same
                // table at its natural size. Widths come from `tableColumnWidths` below, which is
                // what makes "as wide as its columns" mean "up to the pane, then wrap".
                //
                // Scrolling stays off in both directions: the table scrolls with the document.
                var g = dvui.grid(@src(), .{
                    .layout_only = true,
                    .scroll_opts = .{
                        .horizontal = .none,
                        .vertical = .none,
                        .horizontal_bar = .hide,
                        .vertical_bar = .hide,
                    },
                }, .{
                    .expand = .none,
                    .background = true,
                    .color_fill = dvui.themeGet().color(.window, .fill).opacity(0.3),
                    .corners = dvui.CornerRect.all(4),
                    .border = dvui.Rect.all(1),
                    .color_border = dvui.themeGet().border.opacity(0.3),
                    .id_extra = ids.next(),
                });
                defer g.deinit();

                const cell_padding: dvui.Rect = .{ .x = 8, .y = 5, .w = 8, .h = 5 };

                // Install our own column widths, and with them off the grid's plate, leave it to
                // auto-size rows only. Row heights are safe to measure (a wrapped cell's height is
                // what we want to learn), and uncapped: the grid's default max is ~5 lines, which
                // clips a wrapped cell mid-sentence with nowhere else to read the rest.
                //
                // `col_widths` is empty on a table's first frame — the grid learns its column
                // count from the cells it saw last frame — so that frame falls back to the grid's
                // own auto-sizing and the frame after picks these up.
                const col_ws = tableColumnWidths(n, num_cols, table_avail, cell_padding, ctx);
                if (col_ws.len == num_cols and g.col_widths.len == num_cols) {
                    @memcpy(g.col_widths, col_ws);
                    g.autoSize(.{
                        .auto = .rows,
                        .min_height = 0,
                        .max_height = dvui.max_float_safe,
                    });
                }

                // dvui dropped `CellStyle.Banded` along with the grid rework, so the zebra
                // striping is applied here: odd body rows get the alternate fill, everything
                // else keeps the grid's own background.
                const banded = struct {
                    fn opts(row: usize, padding: dvui.Rect) dvui.Options {
                        var o: dvui.Options = .{ .padding = padding };
                        if (row % 2 == 1) {
                            o.background = true;
                            o.color_fill = dvui.themeGet().color(.control, .fill_press);
                        }
                        return o;
                    }
                };

                // Screen-space band a row has to touch to be laid out, with the same half-screen
                // of slack `renderTopLevel` gives blocks.
                const cull_rows = virtualize_blocks and ctx.viewport.h > 0;
                const clip = dvui.clipGet();
                const row_slack = @max(200 * clip.h / @max(1, ctx.viewport.h), clip.h * 0.5);
                const row_clip_top = clip.y - row_slack;
                const row_clip_bot = clip.y + clip.h + row_slack;
                var row_anchor: ?struct { screen_y: f32, scale: f32, row_offset: f32 } = null;
                // The *off-screen* budget goes to zero while the column is still moving, for the
                // same reason `renderTopLevel` zeroes its block budget: a row measured at this
                // frame's width is invalid at the next frame's, so a sash drag would pay for the
                // whole table over and over and keep none of it (~5.4KB of text shaped per frame
                // on docs/PLUGIN_MANIFEST_PLAN.md, discarded every time). Those rows stay owed —
                // `pending_measure` keeps frames coming — and get measured once the width holds.
                //
                // `first_sight_left` is deliberately *not* zeroed. It gates rows that are on
                // screen, and during a resize every row counts as never-measured (the column
                // width they were measured at just changed), so zeroing it made every visible row
                // cull itself and the table rendered blank for the whole drag.
                var measure_bytes_left: u64 = if (ctx.rs.width_in_flux) 0 else table_measure_bytes;
                var first_sight_left: u64 = table_first_sight_bytes;

                var body_row: usize = 0;
                var c = n.firstChild();
                while (c) |row| : (c = row.nextSibling()) {
                    const rk = extKind(ctx, row);
                    if (rk != .table_row and rk != .table_header) continue;

                    if (rk == .table_header) {
                        var col: usize = 0;
                        var cl = row.firstChild();
                        while (cl) |cell| : (cl = cell.nextSibling()) {
                            if (extKind(ctx, cell) != .table_cell) continue;
                            const label = linkLabelPlainText(cell, arena) catch "";
                            const hcell = g.colHeader(col, banded.opts(0, cell_padding));
                            defer hcell.deinit();
                            dvui.labelNoFmt(@src(), label, .{}, .{
                                .expand = .horizontal,
                                .gravity_x = 0.5,
                                .gravity_y = 0.5,
                                .font = dvui.Font.theme(.body).withWeight(.bold),
                                .id_extra = ids.next(),
                            });
                            col += 1;
                        }
                    } else {
                        // Is this row anywhere near the screen? A markdown table is drawn as a
                        // *content-sized* grid — it scrolls with the page rather than inside
                        // itself — so dvui's own row virtualization (`GridWidget.rowsVisible`)
                        // can't help: as far as the grid is concerned its whole body is in view.
                        // Without this, one 45KB table (docs/PLUGIN_MANIFEST_PLAN.md has one) is
                        // laid out in full on every frame it appears on, which costs more than
                        // the rest of that document put together.
                        //
                        // The anchor comes from the first body cell rather than from the grid's
                        // internals: every cell's rect is placed from the grid's own cached row
                        // heights, so one real cell rect plus `rowOffset`/`rowHeight` gives every
                        // other row's position exactly.
                        const measured_before = !rowNeedsMeasure(ctx, g, row);
                        var row_visible = if (!cull_rows or row_anchor == null) true else blk: {
                            const a = row_anchor.?;
                            const top = a.screen_y + (g.rowOffset(body_row) - a.row_offset) * a.scale;
                            const h = g.rowHeight(body_row) * a.scale;
                            break :blk top < row_clip_bot and (top + h) > row_clip_top;
                        };
                        // A row with no measurements behind it has no trustworthy position either
                        // — see `table_first_sight_rows`.
                        if (row_visible and !measured_before and cull_rows and first_sight_left == 0)
                            row_visible = false;

                        // An off-screen row whose cells have never been measured (or whose
                        // measurement hasn't been confirmed by a second draw) is worth one
                        // measuring pass so the table's height is right — but only a few such
                        // rows per frame, so a big table costs a little on each of several frames
                        // instead of all of it on the frame the document opens.
                        const measure_row = !row_visible and !measured_before and measure_bytes_left > 0;
                        // An off-screen row that isn't settled yet is work owed, not work dropped:
                        // `renderDocument` asks for another frame while any remains. It stays
                        // owed on the frame it *is* measured on, because a measurement only
                        // counts once a second pass agrees with it.
                        if (!measured_before and !row_visible and !ctx.rs.block_measure_exhausted) stats.pending_measure += 1;
                        // Any row that has not been measured for real leaves this table's height
                        // a guess, however it is drawn — see `RenderState.block_rows_pending`.
                        if (!measured_before) ctx.rs.block_rows_pending += 1;
                        const row_text_before = stats.add_text_bytes;

                        var col: usize = 0;
                        var cl = row.firstChild();
                        while (cl) |cell| : (cl = cell.nextSibling()) {
                            if (extKind(ctx, cell) != .table_cell) continue;
                            // A skipped cell still has to hand the grid the size its contents
                            // would have, or the row collapses and the column shrinks to whatever
                            // happens to be on screen. A cell with no measurement yet — or one
                            // whose measurement hasn't been confirmed by a second draw — is drawn
                            // regardless of where it is, which is what makes the table's total
                            // height right from the first frame it appears on.
                            const cell_key = @intFromPtr(cell.n);
                            const cached = ctx.rs.cell_sizes.get(cell_key);
                            // Read before the cell exists, so it is the width this cell is about
                            // to be laid out in rather than the one it produces.
                            const cell_w = g.colWidth(col);
                            const draw_cell = row_visible or measure_row;
                            // An unmeasured culled cell used to hand the grid a *zero* size, which
                            // is the same low-bias mistake `Table.estimate` makes one level up and
                            // it compounds: on a 45KB table most rows are unmeasured on first
                            // sight, so the block came out a fraction of its real height and then
                            // inflated by hundreds of points per frame as the budget caught up.
                            // One line is the honest floor — most table cells are exactly that —
                            // and the block's height is roughly right immediately instead.
                            const cell_placeholder: dvui.Size = if (cached) |cs|
                                cs.size
                            else
                                .{ .w = 0, .h = dvui.Font.theme(.body).lineHeight() };
                            const cell_box = g.cell(
                                .{ .col = col, .row = body_row },
                                banded.opts(body_row, cell_padding).override(
                                    if (draw_cell) .{} else .{ .min_size_content = cell_placeholder },
                                ),
                            );
                            if (row_anchor == null) {
                                const rs = cell_box.data().rectScale();
                                row_anchor = .{
                                    .screen_y = rs.r.y,
                                    .scale = rs.s,
                                    .row_offset = g.rowOffset(body_row),
                                };
                            }
                            if (draw_cell) {
                                // Ids inside a cell hang off the cell widget, so restarting them
                                // per cell keeps a skipped neighbour from shifting anything.
                                ids.n = 0;
                                renderInlineFlowContainer(cell, .{ .background = false }, ctx, ids);
                                // Read before `deinit`, and with the padding taken back off:
                                // `min_size_content` has the padding added to it again, so
                                // storing the padded size would grow the cell every frame.
                                const measured: dvui.Size = .{
                                    .w = @max(0, cell_box.data().min_size.w - cell_padding.x - cell_padding.w),
                                    .h = @max(0, cell_box.data().min_size.h - cell_padding.y - cell_padding.h),
                                };
                                const agrees = cached != null and cached.?.col_w == cell_w and
                                    cached.?.size.w == measured.w and cached.?.size.h == measured.h;
                                ctx.rs.cell_sizes.put(ctx.gpa, cell_key, .{
                                    .size = measured,
                                    .col_w = cell_w,
                                    .settled = agrees,
                                }) catch {};
                            }
                            cell_box.deinit();
                            col += 1;
                        }
                        // Charge whichever budget paid for this row. Measured after the fact: a
                        // row's size is only known once it has been laid out, so a budget can be
                        // overshot by at most the one row that exhausts it.
                        const row_text = stats.add_text_bytes - row_text_before;
                        if (row_visible and !measured_before) {
                            first_sight_left -|= row_text;
                        } else if (measure_row) {
                            measure_bytes_left -|= row_text;
                        }
                        body_row += 1;
                    }
                }
            } else {
                var c = n.firstChild();
                while (c) |ch| : (c = ch.nextSibling()) renderBlock(ch, ids, ctx);
            }
        },
    }
}

pub fn renderDocument(root: md.Node, ctx: RenderContext) void {
    // Per-draw counters reset here; `render_ns` deliberately accumulates (see `Stats`).
    const carried_ns = stats.render_ns;
    const carried_parse_ns = stats.parse_ns;
    stats = .{ .render_ns = carried_ns, .parse_ns = carried_parse_ns };
    // wasm has no monotonic clock wired into `dvui.io` (`std.Io.failing` returns zero for every
    // timestamp), so the counters above are the whole story there; timing is native-only.
    const t0: i128 = if (comptime builtin.target.cpu.arch == .wasm32) 0 else std.Io.Clock.boot.now(dvui.io).nanoseconds;

    var resolved_ctx = ctx;
    resolved_ctx.wikilink = wikilinkResolver(ctx);

    var ids: IdGen = .{ .n = ctx.id_base };
    renderBlock(root, &ids, resolved_ctx);

    // Keep frames coming until the measuring budgets have caught up — see `Stats.pending_measure`.
    if (stats.pending_measure > 0) dvui.refresh(null, @src(), null);

    if (comptime builtin.target.cpu.arch != .wasm32) {
        stats.render_ns +%= @intCast(std.Io.Clock.boot.now(dvui.io).nanoseconds - t0);
    }
}

/// The wikilink resolver to use for this document draw, or null when wikilinks are off.
///
/// Also the point where a stale resolution memo is dropped: the resolver bumps `generation()`
/// on every committed index change, and a link that was broken a moment ago becomes live the
/// instant its target file exists — with no edit to *this* document, so nothing else in the
/// pipeline would notice.
fn wikilinkResolver(ctx: RenderContext) ?*WikilinkApi {
    // A document with no path on disk has nothing to resolve *relative to*, and — for the
    // store's README pane — is remote content that must not reach into the user's own files.
    if (ctx.document_path.len == 0) return null;
    const api = sdk.host().getServiceTyped(WikilinkApi) orelse return null;

    const gen = api.generation();
    if (ctx.rs.wikilink_generation != gen) {
        ctx.rs.clearResolvedWikilinks(ctx.gpa);
        ctx.rs.wikilink_generation = gen;
    }
    return api;
}

/// Resolve one link, memoized against the resolver generation. Called every frame for every
/// visible link, so the steady-state path must be the hash lookup and nothing more.
fn resolveWikilink(
    ctx: RenderContext,
    node: md.Node,
    token_index: usize,
    tok: wikilink_scan.Token,
) ResolvedLink {
    const api = ctx.wikilink orelse return .{ .status = .unresolved };
    const key = wikilinkMemoKey(node, token_index);
    if (ctx.rs.wikilink_resolved.get(key)) |hit| return hit;

    const res = api.resolve(tok.target, tok.heading, ctx.document_path, ctx.gpa) catch
        return .{ .status = .unresolved };
    // `resolve` allocates from the allocator we hand it, and we hand it the persistent one so
    // the memo can outlive the frame. `title` is not kept — nothing renders it yet, and holding
    // it would mean freeing two strings per entry instead of one.
    ctx.gpa.free(res.title);

    const entry: ResolvedLink = .{
        .status = res.status,
        .path = @constCast(res.path),
        .line = res.line,
    };
    ctx.rs.wikilink_resolved.put(ctx.gpa, key, entry) catch {
        // Out of memory for the memo only — the answer is still good for this frame, it just
        // costs a resolve again next frame.
        ctx.gpa.free(res.path);
        return .{ .status = res.status, .line = res.line };
    };
    return entry;
}
