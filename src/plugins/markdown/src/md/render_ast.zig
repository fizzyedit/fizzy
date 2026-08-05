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

/// One top-level block's laid-out height, and whether re-measuring it could still change it.
///
/// dvui sizes a widget from what its children reported the frame *before*, so a block's first
/// draw at a given width is still settling. A block that got skipped from then on would freeze at
/// that half-settled value forever, pushing everything below it out of place — so `settled` only
/// goes true once two consecutive draws agree, and until then the block is re-drawn (within
/// `resettle_budget`) even off screen.
pub const BlockHeight = struct {
    h: f32,
    settled: bool,
};

/// The span of markdown source one top-level block was parsed from.
pub const SourceExtent = struct {
    lines: u32,
    bytes: u32,
};

/// One table cell's measured content size. `settled` follows the same two-agreeing-draws rule as
/// `BlockHeight`, and for the same reason.
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

/// Escape hatch for tests: with this off, `renderTopLevel` lays out every block, on screen or
/// not. The integration test that asserts the two produce identical pixels is the only thing
/// that turns it off — and the reason it can stay a plain global is that the same test is what
/// would catch a divergence if some future caller ever set it.
pub var virtualize_blocks: bool = true;

/// Off-screen blocks `renderTopLevel` may re-measure per frame after a width change. Bounds what
/// a resize costs: without it, every frame of a window drag or a panel's open animation is a
/// full-document layout, which is the whole cost this virtualization exists to remove.
///
/// Each block needs two draws to settle (dvui sizes a widget from what its children reported the
/// frame before), so a 180-block document is fully accurate again about 30 frames after the drag
/// stops. Until then the only thing that is off is the scrollbar's idea of the total height.
const resettle_budget: usize = 12;

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

    /// Laid-out height of each top-level block, by document order — what lets `renderTopLevel`
    /// skip a block that isn't on screen and still hand the scroll container the right total
    /// height. Grown as blocks are measured; a block past the end has never been measured, and
    /// is always drawn.
    block_heights: std.ArrayListUnmanaged(BlockHeight) = .empty,
    /// How much *source* each top-level block came from, in document order — enough to guess its
    /// laid-out height before it has ever been laid out. Without this, opening a document costs
    /// one full-document layout (~13-20ms in ReleaseFast for a 60KB file, and it lands on the
    /// frame a panel is animating open), because a block with no height cannot be placed and so
    /// cannot be skipped.
    block_source: std.ArrayListUnmanaged(SourceExtent) = .empty,
    /// Content size each table cell measured at, keyed by @intFromPtr(cell node) — what a culled
    /// row hands the grid in place of its contents. It has to be the cell's *own* measurement and
    /// not the grid's row height / column width: the grid takes the max across a column, so
    /// feeding those back widens the column a little, which rewraps a visible cell and moves the
    /// whole table. (Measured the hard way: it showed up as one extra line of text in one row.)
    cell_sizes: std.AutoHashMapUnmanaged(usize, CellSize) = .empty,
    /// Column width `block_heights` was measured at. A different width invalidates every entry
    /// wholesale — wrapped prose reflows, so no cached height survives a resize.
    block_layout_width: f32 = -1,

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
        self.block_heights.deinit(gpa);
        self.cell_sizes.deinit(gpa);
        self.block_source.deinit(gpa);
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
        self.block_heights.clearRetainingCapacity();
        self.cell_sizes.clearRetainingCapacity();
        self.block_source.clearRetainingCapacity();
        self.block_layout_width = -1;
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

/// Record each top-level block's source span, for `renderTopLevel`'s first-sight height guess.
/// cmark reports 1-based line numbers for block nodes; a node whose lines don't fit the source
/// (nothing observed doing this, but the API doesn't promise it) simply gets a zero extent, and a
/// zero extent means "no guess available" — that block is drawn rather than estimated.
fn recordBlockExtents(doc_node: md.Node, rs: *RenderState, gpa: std.mem.Allocator, source: ScanSource) void {
    var child = doc_node.firstChild();
    while (child) |ch| : (child = ch.nextSibling()) {
        var extent: SourceExtent = .{ .lines = 0, .bytes = 0 };
        const start = ch.startLine();
        const end = ch.endLine();
        if (start >= 1 and end >= start) {
            extent.lines = @intCast(end - start + 1);
            if (source.index) |idx| {
                const starts = idx.starts;
                const first: usize = @intCast(start - 1);
                const after: usize = @intCast(end);
                if (first < starts.len) {
                    const from = starts[first];
                    const to = if (after < starts.len) starts[after] else @as(u32, @intCast(source.bytes.len));
                    if (to > from) extent.bytes = to - from;
                }
            }
        }
        rs.block_source.append(gpa, extent) catch {};
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
    const avail_w = outer.data().contentRect().w;

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
    if (rs.block_layout_width != ctx.column_width) {
        // A width change reflows every wrapped paragraph, so no cached height is right any more.
        // But *discarding* them would make every block "never measured" and force a full-document
        // layout on that frame — and the widths that change are the ones that change every frame:
        // the panel's open animation sliding out, and a window resize drag. So the heights are
        // kept as estimates and merely stop being trusted: they still place each block (which is
        // what keeps the on-screen set correct and gap-free — a skipped block really does occupy
        // its estimate this frame), while `resettle_budget` re-measures a few per frame until
        // they're all true again.
        for (rs.block_heights.items) |*e| e.settled = false;
        rs.block_layout_width = ctx.column_width;
    }

    // Draw beyond the viewport by half a screen each way. dvui needs the widget to exist for a
    // frame before it can be scrolled onto properly, and a keyboard/scrollbar jump can move the
    // viewport by more than a wheel tick does; the margin absorbs both without being large
    // enough to matter for cost.
    const virtualize = virtualize_blocks and ctx.viewport.h > 0;
    const slack = @max(200, ctx.viewport.h * 0.5);
    const vis_top = ctx.viewport.y - slack;
    const vis_bot = ctx.viewport.y + ctx.viewport.h + slack;

    // Off-screen blocks re-measured this frame, from the top down: the top of the document is
    // what everything below is positioned against, so settling it first stops the visible content
    // from wandering. The cost of one is roughly the cost of one visible block, which is what
    // sets the size of this number.
    var resettle_left: usize = resettle_budget;

    var y = ctx.content_origin_y;
    var index: usize = 0;
    var child = doc_node.firstChild();
    while (child) |ch| : ({
        child = ch.nextSibling();
        index += 1;
    }) {
        // A block never laid out yet is placed by a guess from how much source it came from.
        // The guess only has to be good enough to decide "near the viewport or not", and it is
        // deliberately biased *low* (see `estimateBlockHeight`): guessing short draws a few extra
        // blocks, while guessing tall would skip one that is actually on screen and flash a gap.
        const known: ?BlockHeight = if (index < rs.block_heights.items.len)
            rs.block_heights.items[index]
        else if (estimateBlockHeight(rs, index, ctx.column_width)) |est|
            BlockHeight{ .h = est, .settled = false }
        else
            null;
        const on_screen_est = known == null or (y < vis_bot and (y + known.?.h) > vis_top);
        var draw = !virtualize or on_screen_est;
        if (!draw and !known.?.settled) {
            if (resettle_left > 0) {
                draw = true;
                resettle_left -= 1;
            } else {
                // Owed a re-measure that this frame's budget couldn't pay for; see
                // `Stats.pending_measure`.
                stats.pending_measure += 1;
            }
        }

        var wrapper = box(@src(), .{ .dir = .vertical }, .{
            .expand = .horizontal,
            .id_extra = index,
            // Only when skipping: a drawn block must be free to report a *smaller* height than
            // last frame's, and a floor of the old value would keep it from ever shrinking.
            .min_size_content = if (draw) null else dvui.Size{ .h = known.?.h },
        });
        const wrapper_id = wrapper.data().id;
        const prof_t0 = if (block_profile == null) 0 else std.Io.Clock.boot.now(dvui.io).nanoseconds;
        const prof_tl = stats.text_layouts;
        const prof_bytes = stats.add_text_bytes;
        if (draw) {
            ids.n = 0;
            renderBlock(ch, ids, ctx);
        }
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

        const entry: BlockHeight = if (draw) blk: {
            const measured = (dvui.minSizeGet(wrapper_id) orelse dvui.Size{}).h;
            // Now that the height is known, was the block *really* on screen? The estimate above
            // decides what to draw; this decides what to believe. They differ exactly where it
            // matters: on the first frame every block is drawn, but a table drawn off screen
            // reports its header's height and nothing more.
            const was_visible = y < vis_bot and (y + measured) > vis_top;
            if (!was_visible and rs.subtree_has_table.contains(@intFromPtr(ch.n))) {
                // Keep the height from the last time it was on screen. With no such height yet,
                // the collapsed one is still a better placeholder than nothing — and either way
                // this block is done being re-measured until it is scrolled to, so mark it
                // settled rather than let it eat the budget every frame forever.
                break :blk .{ .h = if (known) |k| k.h else measured, .settled = true };
            }
            break :blk .{ .h = measured, .settled = known != null and known.?.h == measured };
        } else known.?;
        if (index < rs.block_heights.items.len) {
            rs.block_heights.items[index] = entry;
        } else {
            rs.block_heights.append(ctx.gpa, entry) catch {};
        }
        y += entry.h;
    }
}

/// Rough laid-out height for a block that has never been drawn, from the source it was parsed
/// from. Null when there is nothing to go on, which means "draw it".
///
/// Biased low on purpose — an underestimate costs a few extra blocks of layout, an overestimate
/// costs a visible gap where a block should have been.
fn estimateBlockHeight(rs: *RenderState, index: usize, column_width: f32) ?f32 {
    if (index >= rs.block_source.items.len) return null;
    const extent = rs.block_source.items[index];
    if (extent.lines == 0) return null;

    const font = dvui.Font.theme(.body);
    const line_h = font.lineHeight();
    // `sizeM` is the width of an "M"; ordinary prose averages a good deal narrower than that, and
    // erring narrow means erring toward *more* estimated lines, which is the safe direction.
    const avg_char_w = @max(1, font.sizeM(1, 1).w * 0.5);
    const chars_per_line = @max(20, column_width / avg_char_w);
    const wrapped: f32 = @ceil(@as(f32, @floatFromInt(extent.bytes)) / chars_per_line);
    const lines = @max(@as(f32, @floatFromInt(extent.lines)), wrapped);
    return lines * line_h * 0.8;
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

fn renderBlock(n: md.Node, ids: *IdGen, ctx: RenderContext) void {
    statBlock();
    const t = n.nodeType();
    switch (t) {
        md.c.CMARK_NODE_DOCUMENT => renderTopLevel(n, ids, ctx),
        md.c.CMARK_NODE_BLOCK_QUOTE => {
            var outer = box(@src(), .{ .dir = .horizontal }, .{
                .expand = .horizontal,
                .margin = .{ .x = 4, .y = 4, .w = 4, .h = 4 },
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
                .margin = .{ .y = 6 },
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
                    .margin = .{ .y = 2 },
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

                var table_wrap = box(@src(), .{ .dir = .vertical }, .{
                    .expand = .none,
                    .margin = .{ .y = 6 },
                    .id_extra = ids.next(),
                });
                defer table_wrap.deinit();

                var g = dvui.grid(@src(), .{
                    .scroll_opts = .{
                        .horizontal_bar = .auto,
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
                var measure_bytes_left: u64 = table_measure_bytes;
                var first_sight_left: u64 = table_first_sight_bytes;
                var rows_unsettled = false;

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
                        if (!measured_before) rows_unsettled = true;
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
                        if (!measured_before and !row_visible) stats.pending_measure += 1;
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
                            const cell_box = g.cell(
                                .{ .col = col, .row = body_row },
                                banded.opts(body_row, cell_padding).override(
                                    if (draw_cell) .{} else .{ .min_size_content = if (cached) |cs| cs.size else dvui.Size{} },
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
                // A grid only writes the row heights it measured into the ones it *keeps* during an
                // auto-size pass, and it stops running those passes as soon as a frame changes
                // nothing. A row measured after that point — which, with the measuring budget
                // above, is most of a big table's rows — would have its height computed and then
                // thrown away, leaving the row stuck at the grid's minimum. So the pass is re-armed
                // for as long as any row is still settling.
                //
                // Only for as long, though: `autoSize` re-arms itself and refreshes each frame
                // until the measurements agree, so calling it unconditionally would leave the
                // preview repainting forever.
                if (rows_unsettled) g.autoSize(.{ .auto = .both });
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
