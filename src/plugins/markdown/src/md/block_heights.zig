//! The markdown preview's top-level block height table — the bookkeeping half of the virtualized
//! block list in `render_ast.zig`.
//!
//! Deliberately std-only, exactly like `textcore` and `wikilink_scan`: every rule that decides
//! *where a block sits* and *whether its height can be trusted* lives here, so it can be unit
//! tested headlessly instead of only being observable as the preview misbehaving. `render_ast.zig`
//! keeps the half that needs dvui — laying blocks out and measuring them — and hands the numbers
//! back through `record`.
//!
//! The one invariant everything else serves: **a block's cached height is either a measurement or
//! an admission that it isn't one.** The renderer used to blur the two — an estimate could
//! overwrite a measurement on resize, and a knowingly-collapsed height could claim to be settled —
//! and every scroll instability downstream traced back to a number that was trusted more than it
//! deserved.

const std = @import("std");

/// Font metrics the estimator needs, passed in rather than read from dvui so this file stays
/// testable. `em_w` is the width of an "M" in the body font.
pub const Metrics = struct {
    line_h: f32,
    em_w: f32,

    /// The metrics used throughout the tests below: a 16px line in a 10px-em font. Real values
    /// come from `dvui.Font.theme(.body)`.
    pub const test_default: Metrics = .{ .line_h = 16, .em_w = 10 };
};

/// The span of markdown source one top-level block was parsed from — enough to guess its laid-out
/// height before it has ever been laid out, and to map a source line onto a block.
pub const SourceExtent = struct {
    lines: u32 = 0,
    bytes: u32 = 0,
    /// 0-based first source line of the block, or `no_line` when cmark didn't report one.
    start_line: u32 = no_line,
    /// What kind of block this is, which is most of what decides how tall it lays out.
    kind: BlockKind = .paragraph,
    /// Hash of the block's source text, or 0 when there was none to hash.
    ///
    /// This is a block's identity *across re-parses*. Editing a document rebuilds the AST from
    /// scratch, and every block index shifts the moment a line is added above — but a paragraph
    /// nobody touched still hashes the same, so its measured height is still valid and can be
    /// carried over instead of being thrown away and guessed at again. See `Table.by_source`.
    hash: u64 = 0,

    pub const no_line: u32 = std.math.maxInt(u32);
};

/// The shapes a top-level block can take, as far as guessing its height is concerned.
///
/// The estimator used to ignore this entirely: every block was "source lines, wrapped, times a
/// line height, times 0.8". That is roughly right for prose and badly wrong for everything else —
/// an image is one line of source and several hundred points tall, a table row is a line of source
/// and a line *plus cell padding* tall, a heading is a line of source in a much larger font. The
/// errors all point the same way, so a whole document came out at ~44% of its real length and the
/// scrollbar said so until every block had been measured.
pub const BlockKind = enum {
    paragraph,
    heading,
    /// Fenced or indented code: monospace, and never wrapped.
    code,
    table,
    /// A paragraph whose content is an image.
    image,
    list,
    quote,
    /// Thematic break.
    rule,
    html,
};

/// One top-level block's height, and how much that number is worth.
///
/// This started as a single `settled: bool` doing two unrelated jobs: "this height is correct" and
/// "stop re-measuring this block". A table whose height could not yet be measured properly needed
/// the second and got the first for free, so a height everyone knew was wrong was marked
/// authoritative and never revisited. Splitting them is what lets `deferred` say "keep working on
/// this, and do not believe it yet".
pub const Height = struct {
    h: f32,
    state: State,
    /// Consecutive contaminated measurements this block has produced. Bounds `deferred` so it
    /// cannot demand frames for ever — see `wantsMeasure` and `deferred_max_attempts`.
    attempts: u8 = 0,

    pub const State = enum {
        /// Guessed from source extent; never laid out. Placement only.
        estimated,
        /// Laid out once at the current width. dvui sizes a widget from what its children
        /// reported the frame before, so a first measurement is still settling.
        measured,
        /// Two consecutive measurements agreed. Trustworthy; don't re-measure.
        settled,
        /// Laid out, but the measurement was contaminated — a table inside it still has rows
        /// that have never been measured, so the height it reported depends on which rows
        /// happened to be culled this frame, and therefore on where the reader is scrolled.
        /// The number is not an answer; the block keeps being drawn until it becomes one.
        deferred,
    };

    /// Whether re-measuring this block could still improve the number.
    ///
    /// `deferred` says yes — drawing the block is what measures the table rows that made it
    /// deferred in the first place, and excluding it meant those rows were never measured and the
    /// block kept a wrong height for ever.
    ///
    /// But only `deferred_max_attempts` times. "Keep trying until it converges" is not a
    /// termination argument, and when it does not converge the cost is not a wrong height, it is
    /// an app that never sleeps: an unsatisfied block keeps `Stats.pending_measure` non-zero,
    /// which asks for another frame, for ever. A table whose cells never settle (their measured
    /// size disagreeing with the column width they are laid out in, frame after frame) is exactly
    /// that case. After the cap the block keeps whatever height it has and stops asking; the next
    /// width change resets the count, and scrolling to it draws it anyway.
    pub fn wantsMeasure(self: Height) bool {
        return switch (self.state) {
            .estimated, .measured => true,
            .deferred => self.attempts < deferred_max_attempts,
            .settled => false,
        };
    }

    /// Whether this height can be believed by the scrollbar's total.
    pub fn trusted(self: Height) bool {
        return self.state == .settled;
    }
};

/// What one laid-out block reported back.
pub const Measurement = struct {
    h: f32,
    /// The measurement is contaminated and must not be believed — a table in this block still
    /// has rows that have never been measured, so its height this frame depends on which rows
    /// were culled, and therefore on where the reader is scrolled. Filed as `.deferred`.
    partial: bool = false,
};

/// How many contaminated measurements a block may produce before it stops asking to be re-drawn.
///
/// Sized for the legitimate case, not the pathological one: a table converges by measuring a few
/// KB of its rows per frame (`render_ast.table_measure_bytes`), so the 45KB table in
/// docs/PLUGIN_MANIFEST_PLAN.md needs a dozen-odd passes and a much larger one proportionally
/// more. At 60fps this cap is about four seconds — long enough that nothing real hits it, short
/// enough that a block which will *never* settle stops holding the app awake.
///
/// An earlier value of 8 was tight enough to cut legitimate convergence short, which showed up as
/// the settle helper returning while tables were still hundreds of points from their real height.
pub const deferred_max_attempts: u8 = 240;

/// Heights agreeing within this many pixels count as the same height.
///
/// Exact float equality was the original rule, and a block whose layout jittered by a fraction of
/// a pixel between frames could therefore never reach `settled`: it re-measured forever, consuming
/// the frame's budget and perturbing the document total every frame it did.
pub const settle_epsilon: f32 = 0.5;

/// Column widths within this many pixels count as unchanged.
pub const width_epsilon: f32 = 0.5;

/// A scroll position expressed as *content identity* rather than as a pixel offset.
///
/// This is the whole point of the anchor. An absolute `viewport.y` only means something relative
/// to a total height, and this renderer's total changes constantly — blocks get measured, the pane
/// resizes, the document is re-parsed under an edit. Every one of those silently redefined what
/// the reader's scroll offset pointed at, which is what made the preview jump. A line number does
/// not move when the block above it turns out to be 40px taller than guessed.
pub const Anchor = struct {
    /// Hash of the anchored block's source, or 0 when it had none.
    ///
    /// Preferred over `line` when resolving, because it is the only identity an *edit* preserves:
    /// inserting a line above the reader shifts every line number below it, so a line-based anchor
    /// silently starts naming different content. The block itself is unchanged and hashes the
    /// same. `line` remains as the fallback — a `revealLine` request has a line and no hash, and a
    /// block whose text the edit did change has to land somewhere sensible.
    hash: u64 = 0,
    /// 0-based source line of the anchored block.
    line: u32,
    /// Pixels from that block's top down to the viewport top.
    ///
    /// Pixels, not a fraction of the block: a fraction re-scales when the anchor block's own
    /// height settles, sliding the very text the reader is looking at.
    offset_px: f32,
    /// The reader is parked at the end of the document. A line anchor alone would drift up off the
    /// bottom as blocks below it settle taller, so "at the end" is held as its own fact.
    at_end: bool = false,
};

/// How close to `max_scroll` still counts as parked at the end.
pub const end_epsilon: f32 = 1.0;

/// The block height table, in document order.
pub const Table = struct {
    heights: std.ArrayListUnmanaged(Height) = .empty,
    extents: std.ArrayListUnmanaged(SourceExtent) = .empty,
    /// Column width `heights` was measured at. Negative means "nothing measured yet".
    layout_width: f32 = -1,

    /// Measured heights keyed by block source hash, surviving re-parses — the thing that makes
    /// typing in a live preview bearable.
    ///
    /// Without it, every keystroke re-parsed the document, cleared the height table, and left all
    /// 50 blocks as estimates: the document's total collapsed from 20,093 to 8,886 and the reader
    /// was thrown hundreds of points for several frames, once per character. Almost every block is
    /// unchanged by an edit, so almost every height is still good — it just has to be findable by
    /// something other than its index, which the edit moved.
    by_source: std.AutoHashMapUnmanaged(u64, Height) = .empty,

    /// Ceiling on `by_source` before it is dropped wholesale. Entries for blocks that no longer
    /// exist accumulate as a document is edited, and nothing else prunes them; heights are cheap
    /// to relearn, so a bounded cache that occasionally forgets beats one that grows forever.
    const by_source_max: usize = 8192;

    pub fn deinit(self: *Table, gpa: std.mem.Allocator) void {
        self.heights.deinit(gpa);
        self.extents.deinit(gpa);
        self.by_source.deinit(gpa);
        self.* = .{};
    }

    /// Full reset — a different document, or one whose layout must be rebuilt from nothing.
    pub fn clear(self: *Table) void {
        self.clearForReparse();
        self.by_source.clearRetainingCapacity();
        self.layout_width = -1;
    }

    /// Reset for a re-parse of the *same* document: drop the positional arrays, whose indices the
    /// edit just invalidated, but keep the heights that are keyed by content and the width they
    /// were measured at. Blocks the edit did not touch are then re-seeded with their real heights
    /// as their extents are re-recorded, instead of collapsing back to estimates.
    pub fn clearForReparse(self: *Table) void {
        self.heights.clearRetainingCapacity();
        self.extents.clearRetainingCapacity();
    }

    /// Record one block's source span, and seed its height from a previous parse when this exact
    /// source has been measured before.
    ///
    /// Always appends exactly one height, so the two arrays stay index-for-index aligned. They have
    /// to: a seeded entry landing at the wrong index would give one block another block's height.
    /// A block with nothing to seed from gets a zero-height `.estimated` placeholder, which
    /// `heightAt` resolves through `estimate` rather than reading back as zero.
    pub fn appendExtent(self: *Table, gpa: std.mem.Allocator, e: SourceExtent) void {
        self.extents.append(gpa, e) catch return;
        const seeded: ?Height = if (e.hash != 0) self.by_source.get(e.hash) else null;
        // Carry the *state* across too, not just the number.
        //
        // Flattening everything to `.measured` looked harmless and was not: `record` reads
        // `.measured` as "a height from before a width change", and discards it in favour of even a
        // contaminated measurement. A re-parse hands every table exactly one contaminated
        // measurement — the cell sizes the renderer keys by AST node pointer die with the old tree
        // — so on every keystroke a settled 900pt table was replaced by whatever that frame's
        // half-culled layout reported. Measured at 42pt in the test below: an 858pt lurch under the
        // reader, once per character typed.
        //
        // The source is byte-identical and the column has not moved, so the height has not changed
        // either, and the state that vouched for it still holds. `attempts` starts fresh: this is a
        // new tree, and whatever the old one struggled with is not this one's debt.
        const entry: Height = if (seeded) |h|
            (if (h.h > 0) Height{ .h = h.h, .state = h.state, .attempts = 0 } else .{ .h = 0, .state = .estimated })
        else
            .{ .h = 0, .state = .estimated };
        self.heights.append(gpa, entry) catch {
            // Keep the arrays aligned even under OOM — a short `heights` is recoverable
            // (`ensureSlot` refills it), a misaligned one silently corrupts every later block.
            _ = self.extents.pop();
        };
    }

    /// How many blocks the table knows about. Extents are recorded once per parse, so they are the
    /// authority on block count; heights grow to match as blocks are placed.
    pub fn len(self: *const Table) usize {
        return self.extents.items.len;
    }

    /// Rough laid-out height for a block that has never been drawn.
    ///
    /// Biased low on purpose, and the bias is only sound for deciding *what to draw*: guessing
    /// short draws a few extra blocks, while guessing tall skips one that is really on screen and
    /// flashes a gap. It is not sound as a scrollbar total, which is why a measurement must never
    /// be replaced by one of these — see `invalidateForWidth`.
    pub fn estimate(self: *const Table, index: usize, m: Metrics, column_width: f32) ?f32 {
        if (index >= self.extents.items.len) return null;
        const extent = self.extents.items[index];
        if (extent.lines == 0) return null;

        const src_lines: f32 = @floatFromInt(extent.lines);
        const bytes: f32 = @floatFromInt(extent.bytes);

        // How many lines this much text wraps to at this column width. `em_w * 0.5` because
        // ordinary prose averages a good deal narrower than an "M".
        const avg_char_w = @max(1, m.em_w * 0.5);
        const chars_per_line = @max(20, column_width / avg_char_w);
        const wrapped = @ceil(bytes / chars_per_line);

        return switch (extent.kind) {
            // Wrapped prose: however many lines it takes, whichever of the two counts is larger.
            .paragraph, .html => @max(src_lines, wrapped) * m.line_h,
            // List items each start a line, so the source line count is the floor, and wrapping
            // adds to it rather than replacing it.
            .list => (@max(src_lines, wrapped) + src_lines * 0.15) * m.line_h,
            // Quotes wrap like prose and add their own padding.
            .quote => @max(src_lines, wrapped) * m.line_h + 8,
            // Headings are one line in a much bigger font.
            .heading => src_lines * m.line_h * 1.8,
            // Code never wraps — one source line is one laid-out line — plus the panel's padding.
            .code => src_lines * m.line_h + 12,
            // A table's height is driven by how much its cells *wrap*, not by how many rows it
            // has: the 45KB table in docs/PLUGIN_MANIFEST_PLAN.md is 25 source lines and 13,310pt
            // tall. Cell text wraps inside a column rather than across the whole width, so it
            // needs far more lines than the same bytes of prose — measured at roughly a third of
            // the full column width across the sample documents, which is what the divisor is.
            // Calibrated, not derived; a table with very different proportions will be off.
            .table => blk: {
                const cell_chars = @max(8, chars_per_line / 1.7);
                const text_lines = @ceil(bytes / cell_chars);
                // Rows are the floor (an empty row still occupies one), and each pays the cell
                // padding whatever its content does.
                break :blk @max(src_lines, text_lines) * m.line_h + src_lines * 10 + 16;
            },
            // Nothing in the source says how tall an image is; this is the middle of the range
            // the renderer clamps them to (see `max_image_display_height`). Wrong either way,
            // but wrong by a few hundred points instead of by five hundred.
            .image => 240,
            .rule => m.line_h,
        };
    }

    /// This block's height for placement purposes: its cached value, or an estimate, or zero when
    /// there is nothing to go on at all.
    pub fn heightAt(self: *const Table, index: usize, m: Metrics, column_width: f32) f32 {
        if (index < self.heights.items.len) {
            const e = self.heights.items[index];
            // An estimate is re-derived rather than read back. It is a function of the current
            // column width, and a stored one is whatever width happened to be in force when the
            // slot was created — which after a re-parse is not necessarily this one.
            if (e.state == .estimated) return self.estimate(index, m, column_width) orelse e.h;
            return e.h;
        }
        return self.estimate(index, m, column_width) orelse 0;
    }

    pub fn attemptsAt(self: *const Table, index: usize) u8 {
        if (index < self.heights.items.len) return self.heights.items[index].attempts;
        return 0;
    }

    pub fn stateAt(self: *const Table, index: usize) Height.State {
        if (index < self.heights.items.len) return self.heights.items[index].state;
        return .estimated;
    }

    /// Whether this block can be positioned at all — it has been laid out, or it has enough source
    /// to guess from. A block that is neither (cmark reported no span for it) has no height and no
    /// way to get one except being drawn, so the renderer must draw it unconditionally. That is
    /// what keeps the table filling in without ever leaving a gap.
    pub fn placeable(self: *const Table, index: usize) bool {
        if (index < self.heights.items.len and self.heights.items[index].state != .estimated) return true;
        return index < self.extents.items.len and self.extents.items[index].lines != 0;
    }

    /// Make sure `heights` has a slot for `index`, filling any gap with estimates. Blocks are
    /// placed in document order, so filling forward never skips a slot that later needs a
    /// different value.
    pub fn ensureSlot(self: *Table, gpa: std.mem.Allocator, index: usize, m: Metrics, column_width: f32) void {
        while (self.heights.items.len <= index) {
            const i = self.heights.items.len;
            const h = self.estimate(i, m, column_width) orelse 0;
            self.heights.append(gpa, .{ .h = h, .state = .estimated }) catch return;
        }
    }

    /// Virtual `y` of a block's top, by prefix sum.
    pub fn yAt(self: *const Table, index: usize, m: Metrics, column_width: f32, origin_y: f32) f32 {
        var y = origin_y;
        var i: usize = 0;
        while (i < index and i < self.len()) : (i += 1) y += self.heightAt(i, m, column_width);
        return y;
    }

    /// Total laid-out height of the document as currently believed.
    pub fn total(self: *const Table, m: Metrics, column_width: f32) f32 {
        var sum: f32 = 0;
        var i: usize = 0;
        while (i < self.len()) : (i += 1) sum += self.heightAt(i, m, column_width);
        return sum;
    }

    /// Fold a fresh measurement in.
    ///
    /// A `partial` measurement never overwrites a height we already have: an off-screen table
    /// reporting its header height is strictly less informative than whatever the block last
    /// measured on screen.
    pub fn record(self: *Table, gpa: std.mem.Allocator, index: usize, mm: Measurement, m: Metrics, column_width: f32) void {
        self.ensureSlot(gpa, index, m, column_width);
        if (index >= self.heights.items.len) return; // allocation failed; nothing to update
        // Resolved through `heightAt`, not read raw: an `.estimated` slot carries no stored height
        // (it is derived from the current width on demand), so reading the field would see zero
        // and treat a perfectly good guess as "nothing to keep".
        const prev: Height = .{
            .h = self.heightAt(index, m, column_width),
            .state = self.heights.items[index].state,
            .attempts = self.heights.items[index].attempts,
        };

        if (mm.partial) {
            // Keep what we had, but only when it is worth keeping: a height already confirmed at
            // *this* width. A `.measured` entry here is one a width change just invalidated, so
            // it describes a column the document no longer has — holding onto it would freeze the
            // table at its pre-resize size. A contaminated measurement at the right width beats a
            // clean one at the wrong width.
            // Only `.measured` is excluded, and only because a width change is what produces it
            // here: that height describes a column the document no longer has. An `.estimated`
            // entry is kept — it is crude, but it is derived from the source and does not lurch
            // when the reader scrolls, which a contaminated measurement very much does.
            const keep = prev.h > 0 and prev.state != .measured;
            const entry: Height = .{
                .h = if (keep) prev.h else mm.h,
                .state = .deferred,
                .attempts = prev.attempts +| 1,
            };
            self.heights.items[index] = entry;
            // Published as well: a large table may never reach `.settled`, and without this its
            // height is the one thing a re-parse cannot recover — leaving the block to fall back
            // to an estimate on every keystroke.
            self.publish(gpa, index, entry);
            return;
        }

        const agrees = switch (prev.state) {
            .measured, .settled => @abs(prev.h - mm.h) <= settle_epsilon,
            .estimated, .deferred => false,
        };
        // A clean measurement clears the strike count: whatever was wrong with this block has
        // stopped being wrong, and it deserves the full budget again if it recurs.
        const entry: Height = .{ .h = mm.h, .state = if (agrees) .settled else .measured, .attempts = 0 };
        self.heights.items[index] = entry;
        self.publish(gpa, index, entry);
    }

    /// Remember a measured height against its block's source, so a re-parse can find it again.
    fn publish(self: *Table, gpa: std.mem.Allocator, index: usize, entry: Height) void {
        if (index >= self.extents.items.len) return;
        const hash = self.extents.items[index].hash;
        if (hash == 0 or entry.h <= 0) return;
        if (self.by_source.count() >= by_source_max and !self.by_source.contains(hash)) {
            self.by_source.clearRetainingCapacity();
        }
        self.by_source.put(gpa, hash, entry) catch {};
    }

    /// React to the text column changing width.
    ///
    /// Every wrapped block reflows, so no height is *current* any more — but a stale measurement is
    /// still far closer to the truth than an estimate, so heights are kept and merely demoted to
    /// re-measurable. They must not be clamped toward the estimate: an image or a table occupies
    /// one line of source, so its estimate is a dozen pixels against a real several hundred, and
    /// clamping collapsed the whole document's height model on every sash drag.
    ///
    /// Returns true when the width actually moved.
    pub fn invalidateForWidth(self: *Table, column_width: f32) bool {
        if (self.layout_width >= 0 and @abs(self.layout_width - column_width) <= width_epsilon) return false;
        self.layout_width = column_width;
        // `deferred` is demoted too. Its height is every bit as much a *previous width's* height
        // as a settled one, and leaving it alone meant a table pinned to its old-width height
        // could never learn the new one — the pin forced each measurement to equal the pin, so
        // the block agreed with itself forever and the table never reflowed.
        for (self.heights.items) |*e| {
            e.state = .measured;
            // A new width is a fresh problem — give every block its attempts back.
            e.attempts = 0;
        }
        return true;
    }

    /// Index of the block whose source hashes to `hash`, disambiguated by `near_line` when more
    /// than one matches. Null for 0 (no hash recorded), or when the edit changed that block's
    /// text, in which case the caller falls back to the line.
    ///
    /// Duplicates are not an edge case — a source hash identifies *text*, and real documents
    /// repeat themselves. docs/PLUGIN_MANIFEST_PLAN.md has seven top-level blocks sharing one
    /// hash. Taking the first match threw the reader to whichever copy came earliest in the
    /// document, which is why anchoring by hash alone sent them to the top.
    pub fn blockForHash(self: *const Table, hash: u64, near_line: u32) ?usize {
        if (hash == 0) return null;
        var best: ?usize = null;
        var best_dist: u64 = std.math.maxInt(u64);
        for (self.extents.items, 0..) |ext, i| {
            if (ext.hash != hash) continue;
            // Nearest by source line: an edit shifts lines a little, never across the document.
            const line = if (ext.start_line == SourceExtent.no_line) 0 else ext.start_line;
            const dist: u64 = if (line > near_line) line - near_line else near_line - line;
            if (dist < best_dist) {
                best_dist = dist;
                best = i;
            }
        }
        return best;
    }

    /// Index of the top-level block containing 0-based source `line`: the last block that starts at
    /// or before it.
    ///
    /// Blocks are in document order and their start lines ascend, but not every block has one —
    /// cmark reports positions for the ones it parsed from source, and a block without one is
    /// skipped rather than allowed to end the search early.
    pub fn blockForLine(self: *const Table, line: u32) ?usize {
        var best: ?usize = null;
        for (self.extents.items, 0..) |ext, i| {
            if (ext.start_line == SourceExtent.no_line) continue;
            if (ext.start_line > line) break;
            best = i;
        }
        return best;
    }

    /// Where an anchor points, as a scroll offset against the *current* heights.
    ///
    /// Clamped to `max_scroll` by the caller's reckoning rather than by a stale internal total —
    /// the scroll container is the authority on how much room there is, and the old code's habit
    /// of clamping against a half-known total is what made a jump into a long document land short.
    pub fn resolveAnchor(
        self: *const Table,
        a: Anchor,
        m: Metrics,
        column_width: f32,
        origin_y: f32,
        max_scroll: f32,
    ) f32 {
        const limit = @max(0, max_scroll);
        if (a.at_end) return limit;
        const idx = self.blockForHash(a.hash, a.line) orelse self.blockForLine(a.line) orelse return 0;
        const y = self.yAt(idx, m, column_width, origin_y);
        return std.math.clamp(y + a.offset_px, 0, limit);
    }

    /// Turn the current scroll offset back into an anchor. Inverse of `resolveAnchor` while the
    /// heights hold still, which is what makes the position a fixed point across frames.
    pub fn captureAnchor(
        self: *const Table,
        viewport_y: f32,
        m: Metrics,
        column_width: f32,
        origin_y: f32,
        max_scroll: f32,
    ) ?Anchor {
        const n = self.len();
        if (n == 0) return null;
        if (max_scroll > 0 and viewport_y >= max_scroll - end_epsilon) {
            return .{ .line = 0, .offset_px = 0, .at_end = true };
        }

        // The block the viewport top falls inside. Past the end of the last block (bounce, or a
        // total that shrank under us) anchors to that last block rather than to nothing.
        var idx: usize = n - 1;
        var idx_y: f32 = origin_y;
        {
            var y = origin_y;
            var i: usize = 0;
            while (i < n) : (i += 1) {
                const h = self.heightAt(i, m, column_width);
                if (viewport_y < y + h or i == n - 1) {
                    idx = i;
                    idx_y = y;
                    break;
                }
                y += h;
            }
        }

        // Anchor identity is a source line, and not every block has one. Walk back to the nearest
        // block that does, rolling the skipped heights into the offset so the position stays
        // exact rather than merely close.
        while (self.extents.items[idx].start_line == SourceExtent.no_line) {
            if (idx == 0) return null;
            idx -= 1;
            idx_y -= self.heightAt(idx, m, column_width);
        }

        return .{
            .hash = self.extents.items[idx].hash,
            .line = self.extents.items[idx].start_line,
            .offset_px = viewport_y - idx_y,
        };
    }

    /// Inclusive range of blocks that must be laid out to cover the viewport (plus slack).
    pub const Range = struct {
        first: usize,
        last: usize,

        pub fn contains(self: Range, i: usize) bool {
            return i >= self.first and i <= self.last;
        }

        pub fn count(self: Range) usize {
            return self.last - self.first + 1;
        }
    };

    /// Which blocks the viewport covers, with `slack` pixels of over-draw each way.
    ///
    /// Guaranteed non-empty for a non-empty document, and that guarantee is the point. The old code
    /// had no such invariant: it decided per block whether to draw, so a height table that had
    /// drifted (say, every height still sized for a narrower column mid-sash-drag) could conclude
    /// that *nothing* overlapped the viewport and render a blank pane. Stating the guarantee once,
    /// here, is what makes that unrepresentable — rather than approximating it by biasing every
    /// height downward and hoping the error lands the safe way.
    pub fn visibleRange(
        self: *const Table,
        viewport_y: f32,
        viewport_h: f32,
        slack: f32,
        m: Metrics,
        column_width: f32,
        origin_y: f32,
    ) ?Range {
        const n = self.len();
        if (n == 0) return null;

        const top = viewport_y - slack;
        const bot = viewport_y + viewport_h + slack;

        var first: ?usize = null;
        var last: usize = 0;
        var y = origin_y;
        var i: usize = 0;
        while (i < n) : (i += 1) {
            const h = self.heightAt(i, m, column_width);
            const y_end = y + h;
            // A zero-height block still counts as overlapping the point it sits at, so use `>=`
            // for its end: otherwise a run of them at the viewport top selects nothing.
            if (y_end >= top and y < bot) {
                if (first == null) first = i;
                last = i;
            }
            y = y_end;
        }

        if (first) |f| return .{ .first = f, .last = @max(f, last) };

        // Nothing overlapped: the viewport is off the end of what the table currently believes
        // (or before its start). Fall back to the nearest block rather than drawing nothing.
        if (viewport_y <= origin_y) return .{ .first = 0, .last = 0 };
        return .{ .first = n - 1, .last = n - 1 };
    }
};

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;
const tm = Metrics.test_default;

/// Build a table of `n` blocks, each `lines` long, with ascending start lines.
fn testTable(gpa: std.mem.Allocator, n: usize, lines: u32) Table {
    var t: Table = .{};
    var i: usize = 0;
    while (i < n) : (i += 1) {
        t.appendExtent(gpa, .{
            .lines = lines,
            .bytes = lines * 40,
            .start_line = @intCast(i * lines),
        });
    }
    return t;
}

test "estimate is positive and grows with source" {
    const gpa = testing.allocator;
    var t = testTable(gpa, 3, 2);
    defer t.deinit(gpa);

    const e = t.estimate(0, tm, 600).?;
    try testing.expect(e > 0);

    var wide = testTable(gpa, 1, 40);
    defer wide.deinit(gpa);
    try testing.expect(wide.estimate(0, tm, 600).? > e);
}

test "estimate is null without a source extent" {
    const gpa = testing.allocator;
    var t: Table = .{};
    defer t.deinit(gpa);
    t.appendExtent(gpa, .{});
    try testing.expectEqual(@as(?f32, null), t.estimate(0, tm, 600));
}

test "measurement settles only after two agreeing draws" {
    const gpa = testing.allocator;
    var t = testTable(gpa, 1, 2);
    defer t.deinit(gpa);

    try testing.expectEqual(Height.State.estimated, t.stateAt(0));

    t.record(gpa, 0, .{ .h = 100 }, tm, 600);
    try testing.expectEqual(Height.State.measured, t.stateAt(0));
    try testing.expect(!t.heights.items[0].trusted());

    t.record(gpa, 0, .{ .h = 100 }, tm, 600);
    try testing.expectEqual(Height.State.settled, t.stateAt(0));
    try testing.expect(t.heights.items[0].trusted());
    try testing.expect(!t.heights.items[0].wantsMeasure());
}

test "sub-pixel jitter still settles" {
    const gpa = testing.allocator;
    var t = testTable(gpa, 1, 2);
    defer t.deinit(gpa);

    t.record(gpa, 0, .{ .h = 100.0 }, tm, 600);
    t.record(gpa, 0, .{ .h = 100.2 }, tm, 600);
    // Exact equality was the old rule; this block would have re-measured forever.
    try testing.expectEqual(Height.State.settled, t.stateAt(0));
}

test "a real disagreement does not settle" {
    const gpa = testing.allocator;
    var t = testTable(gpa, 1, 2);
    defer t.deinit(gpa);

    t.record(gpa, 0, .{ .h = 100 }, tm, 600);
    t.record(gpa, 0, .{ .h = 140 }, tm, 600);
    try testing.expectEqual(Height.State.measured, t.stateAt(0));
    try testing.expectEqual(@as(f32, 140), t.heights.items[0].h);
}

test "partial measurement never overwrites a real height and is not trusted" {
    const gpa = testing.allocator;
    var t = testTable(gpa, 1, 2);
    defer t.deinit(gpa);

    t.record(gpa, 0, .{ .h = 300 }, tm, 600);
    t.record(gpa, 0, .{ .h = 300 }, tm, 600);
    try testing.expectEqual(Height.State.settled, t.stateAt(0));

    // A row inside it turns out never to have been measured, so this frame's height is a
    // scroll-dependent mix of real rows and placeholders.
    t.record(gpa, 0, .{ .h = 24, .partial = true }, tm, 600);
    try testing.expectEqual(@as(f32, 300), t.heights.items[0].h);
    try testing.expectEqual(Height.State.deferred, t.stateAt(0));
    // The old code marked this `settled` — claiming a height it knew was a placeholder.
    try testing.expect(!t.heights.items[0].trusted());
    // ...and it must keep being drawn, because drawing it is what measures those rows.
    try testing.expect(t.heights.items[0].wantsMeasure());
}

test "a block that never settles eventually stops asking to be re-measured" {
    const gpa = testing.allocator;
    var t = testTable(gpa, 1, 1);
    defer t.deinit(gpa);

    // A table whose cells never agree with the column width they are laid out in produces a
    // contaminated measurement every single frame. "Keep trying until it converges" is not a
    // termination argument, and the cost of not terminating is not a wrong height — it is an app
    // that never sleeps, because an unsatisfied block keeps asking for another frame.
    var i: usize = 0;
    while (i < deferred_max_attempts + 10) : (i += 1) {
        t.record(gpa, 0, .{ .h = 100 + @as(f32, @floatFromInt(i % 7)), .partial = true }, tm, 600);
    }
    try testing.expectEqual(Height.State.deferred, t.stateAt(0));
    try testing.expect(!t.heights.items[0].wantsMeasure());
}

test "a clean measurement gives a struggling block its attempts back" {
    const gpa = testing.allocator;
    var t = testTable(gpa, 1, 1);
    defer t.deinit(gpa);

    var i: usize = 0;
    while (i < deferred_max_attempts + 10) : (i += 1) t.record(gpa, 0, .{ .h = 100, .partial = true }, tm, 600);
    try testing.expect(!t.heights.items[0].wantsMeasure());

    t.record(gpa, 0, .{ .h = 100 }, tm, 600);
    try testing.expectEqual(@as(u8, 0), t.heights.items[0].attempts);
    try testing.expect(t.heights.items[0].wantsMeasure());
}

test "a width change restores a exhausted block's attempts" {
    const gpa = testing.allocator;
    var t = testTable(gpa, 1, 1);
    defer t.deinit(gpa);

    var i: usize = 0;
    while (i < deferred_max_attempts + 10) : (i += 1) t.record(gpa, 0, .{ .h = 100, .partial = true }, tm, 600);
    try testing.expect(!t.heights.items[0].wantsMeasure());

    // A new column is a fresh problem, and worth spending the budget on again.
    _ = t.invalidateForWidth(900);
    try testing.expect(t.heights.items[0].wantsMeasure());
}

test "a re-parse keeps a table's height instead of a contaminated first measurement" {
    const gpa = testing.allocator;
    var t = testTable(gpa, 1, 1);
    defer t.deinit(gpa);
    t.extents.items[0].hash = 4242;
    _ = t.invalidateForWidth(600);

    // A table that settled at 900pt before the edit.
    t.record(gpa, 0, .{ .h = 900 }, tm, 600);
    t.record(gpa, 0, .{ .h = 900 }, tm, 600);
    try testing.expectEqual(Height.State.settled, t.stateAt(0));

    // The user types elsewhere. The document re-parses: block indices are rebuilt, and the cell
    // measurements the renderer keys by AST node pointer are gone with the old tree — so this
    // table's very next measurement is contaminated, every time, on every keystroke.
    t.clearForReparse();
    t.appendExtent(gpa, .{ .lines = 1, .bytes = 40, .start_line = 0, .kind = .table, .hash = 4242 });
    t.record(gpa, 0, .{ .h = 42, .partial = true }, tm, 600);

    // Its source is byte-identical and the column has not moved, so its height has not changed.
    // Taking the contaminated 42 here is a jump of 858pt under the reader — once per character.
    try testing.expectEqual(@as(f32, 900), t.heightAt(0, tm, 600));
}

test "a contaminated measurement does not displace a source estimate" {
    const gpa = testing.allocator;
    var t = testTable(gpa, 1, 2);
    defer t.deinit(gpa);

    const est = t.estimate(0, tm, 600).?;
    t.record(gpa, 0, .{ .h = 24, .partial = true }, tm, 600);
    // The estimate does not move when the reader scrolls; the measurement does. Between two
    // wrong numbers, prefer the stable one.
    try testing.expectEqual(est, t.heights.items[0].h);
    try testing.expectEqual(Height.State.deferred, t.stateAt(0));
}

test "a contaminated measurement is used only when there is nothing at all" {
    const gpa = testing.allocator;
    var t: Table = .{};
    defer t.deinit(gpa);
    t.appendExtent(gpa, .{}); // no source span, so no estimate

    t.record(gpa, 0, .{ .h = 24, .partial = true }, tm, 600);
    try testing.expectEqual(@as(f32, 24), t.heights.items[0].h);
    try testing.expectEqual(Height.State.deferred, t.stateAt(0));
}

test "width change keeps measurements instead of clamping them to estimates" {
    const gpa = testing.allocator;
    // One block, one line of source — an image or a table. Its estimate is tiny; its real
    // height is not.
    var t = testTable(gpa, 1, 1);
    defer t.deinit(gpa);

    _ = t.invalidateForWidth(600);
    t.record(gpa, 0, .{ .h = 540 }, tm, 600);
    t.record(gpa, 0, .{ .h = 540 }, tm, 600);

    const est = t.estimate(0, tm, 900).?;
    try testing.expect(est < 100); // the estimator really is this wrong for such a block

    try testing.expect(t.invalidateForWidth(900));

    // The regression this guards: the height used to be clamped to `@min(h, estimate)`, which
    // collapsed 540 to ~13 on every sash drag and took the document's height model with it.
    try testing.expectEqual(@as(f32, 540), t.heights.items[0].h);
    try testing.expectEqual(Height.State.measured, t.stateAt(0));
    try testing.expect(t.heights.items[0].wantsMeasure());
}

test "width change within epsilon is not a change" {
    const gpa = testing.allocator;
    var t = testTable(gpa, 1, 2);
    defer t.deinit(gpa);

    _ = t.invalidateForWidth(600);
    t.record(gpa, 0, .{ .h = 80 }, tm, 600);
    t.record(gpa, 0, .{ .h = 80 }, tm, 600);
    try testing.expectEqual(Height.State.settled, t.stateAt(0));

    try testing.expect(!t.invalidateForWidth(600.2));
    try testing.expectEqual(Height.State.settled, t.stateAt(0));
}

test "a width change invalidates a deferred height too" {
    const gpa = testing.allocator;
    var t = testTable(gpa, 1, 1);
    defer t.deinit(gpa);

    _ = t.invalidateForWidth(600);
    t.record(gpa, 0, .{ .h = 400 }, tm, 600);
    t.record(gpa, 0, .{ .h = 18, .partial = true }, tm, 600);
    try testing.expectEqual(Height.State.deferred, t.stateAt(0));

    // A deferred height is still a height measured at the *old* width. Leaving it deferred let
    // the renderer keep pinning the block to its pre-resize size, and because a pinned block
    // measures exactly its pin, it agreed with itself forever and never reflowed.
    _ = t.invalidateForWidth(900);
    try testing.expectEqual(Height.State.measured, t.stateAt(0));
    try testing.expect(t.heights.items[0].wantsMeasure());

    // ...and now a contaminated measurement at the new width is preferred over the old-width
    // number, because the old number describes a column that no longer exists.
    t.record(gpa, 0, .{ .h = 55, .partial = true }, tm, 900);
    try testing.expectEqual(@as(f32, 55), t.heights.items[0].h);
    try testing.expectEqual(Height.State.deferred, t.stateAt(0));
}

test "blockForLine picks the last block starting at or before the line" {
    const gpa = testing.allocator;
    var t = testTable(gpa, 4, 10); // blocks start at lines 0, 10, 20, 30
    defer t.deinit(gpa);

    try testing.expectEqual(@as(?usize, 0), t.blockForLine(0));
    try testing.expectEqual(@as(?usize, 0), t.blockForLine(9));
    try testing.expectEqual(@as(?usize, 1), t.blockForLine(10));
    try testing.expectEqual(@as(?usize, 3), t.blockForLine(30));
    // Past the end of the document: still the last block, not null.
    try testing.expectEqual(@as(?usize, 3), t.blockForLine(9999));
}

test "blockForLine skips blocks cmark gave no position" {
    const gpa = testing.allocator;
    var t: Table = .{};
    defer t.deinit(gpa);
    t.appendExtent(gpa, .{ .lines = 1, .bytes = 10, .start_line = 0 });
    t.appendExtent(gpa, .{ .lines = 1, .bytes = 10 }); // no_line
    t.appendExtent(gpa, .{ .lines = 1, .bytes = 10, .start_line = 5 });

    // The unpositioned block must not end the search early.
    try testing.expectEqual(@as(?usize, 2), t.blockForLine(7));
    try testing.expectEqual(@as(?usize, 0), t.blockForLine(1));
}

test "blockForLine is null before the first positioned block" {
    const gpa = testing.allocator;
    var t: Table = .{};
    defer t.deinit(gpa);
    t.appendExtent(gpa, .{ .lines = 1, .bytes = 10, .start_line = 4 });
    try testing.expectEqual(@as(?usize, null), t.blockForLine(0));
}

test "yAt is the prefix sum and total is the whole document" {
    const gpa = testing.allocator;
    var t = testTable(gpa, 3, 2);
    defer t.deinit(gpa);

    var i: usize = 0;
    while (i < 3) : (i += 1) t.record(gpa, i, .{ .h = 50 }, tm, 600);

    try testing.expectEqual(@as(f32, 0), t.yAt(0, tm, 600, 0));
    try testing.expectEqual(@as(f32, 50), t.yAt(1, tm, 600, 0));
    try testing.expectEqual(@as(f32, 100), t.yAt(2, tm, 600, 0));
    try testing.expectEqual(@as(f32, 150), t.total(tm, 600));

    // origin offsets every block equally.
    try testing.expectEqual(@as(f32, 58), t.yAt(1, tm, 600, 8));
}

test "visibleRange covers the viewport" {
    const gpa = testing.allocator;
    var t = testTable(gpa, 10, 2);
    defer t.deinit(gpa);
    var i: usize = 0;
    while (i < 10) : (i += 1) t.record(gpa, i, .{ .h = 100 }, tm, 600);

    // Viewport 250..450, no slack → blocks 2,3,4.
    const r = t.visibleRange(250, 200, 0, tm, 600, 0).?;
    try testing.expectEqual(@as(usize, 2), r.first);
    try testing.expectEqual(@as(usize, 4), r.last);
    try testing.expect(r.contains(3));
    try testing.expect(!r.contains(5));
}

test "visibleRange widens with slack" {
    const gpa = testing.allocator;
    var t = testTable(gpa, 10, 2);
    defer t.deinit(gpa);
    var i: usize = 0;
    while (i < 10) : (i += 1) t.record(gpa, i, .{ .h = 100 }, tm, 600);

    const r = t.visibleRange(250, 200, 100, tm, 600, 0).?;
    try testing.expectEqual(@as(usize, 1), r.first);
    try testing.expectEqual(@as(usize, 5), r.last);
}

test "visibleRange is never empty, even past the end of the document" {
    const gpa = testing.allocator;
    var t = testTable(gpa, 5, 2);
    defer t.deinit(gpa);
    var i: usize = 0;
    while (i < 5) : (i += 1) t.record(gpa, i, .{ .h = 100 }, tm, 600);

    // Scrolled far beyond anything the table believes exists — the blank-pane case.
    const r = t.visibleRange(100_000, 200, 0, tm, 600, 0).?;
    try testing.expect(r.count() >= 1);
    try testing.expectEqual(@as(usize, 4), r.first);

    // And above the start.
    const r2 = t.visibleRange(-5000, 200, 0, tm, 600, 0).?;
    try testing.expect(r2.count() >= 1);
    try testing.expectEqual(@as(usize, 0), r2.first);
}

test "visibleRange still covers the reader after a narrow-to-wide resize" {
    const gpa = testing.allocator;
    var t = testTable(gpa, 20, 3);
    defer t.deinit(gpa);

    // Laid out narrow: every block wrapped tall.
    _ = t.invalidateForWidth(300);
    var i: usize = 0;
    while (i < 20) : (i += 1) {
        t.record(gpa, i, .{ .h = 200 }, tm, 300);
        t.record(gpa, i, .{ .h = 200 }, tm, 300);
    }

    // Reader is in the middle, then the pane is widened. Heights are now all too tall, but they
    // are kept (not clamped), so the range still resolves to real blocks around the viewport.
    _ = t.invalidateForWidth(900);
    const r = t.visibleRange(2000, 400, 200, tm, 900, 0).?;
    try testing.expect(r.count() >= 1);
    try testing.expect(r.contains(10));
}

test "visibleRange handles zero-height blocks without selecting nothing" {
    const gpa = testing.allocator;
    var t = testTable(gpa, 5, 1);
    defer t.deinit(gpa);
    var i: usize = 0;
    while (i < 5) : (i += 1) t.record(gpa, i, .{ .h = 0 }, tm, 600);

    const r = t.visibleRange(0, 100, 0, tm, 600, 0).?;
    try testing.expect(r.count() >= 1);
}

test "visibleRange is null only for an empty document" {
    const gpa = testing.allocator;
    var t: Table = .{};
    defer t.deinit(gpa);
    try testing.expectEqual(@as(?Table.Range, null), t.visibleRange(0, 500, 100, tm, 600, 0));
}

test "never-measured blocks are placed by estimate, not stacked at zero" {
    const gpa = testing.allocator;
    var t = testTable(gpa, 50, 4);
    defer t.deinit(gpa);

    // Nothing measured at all — the first-open case. Every block must still get a distinct
    // position, or virtualization piles the whole document at y=0 and draws all of it.
    try testing.expect(t.total(tm, 600) > 0);
    try testing.expect(t.yAt(49, tm, 600, 0) > t.yAt(1, tm, 600, 0));

    const r = t.visibleRange(0, 500, 100, tm, 600, 0).?;
    try testing.expect(r.last < 49); // i.e. it really did skip most of the document
}

test "heights stay index-aligned with extents, and gaps read as estimates" {
    const gpa = testing.allocator;
    var t = testTable(gpa, 5, 3);
    defer t.deinit(gpa);

    // One height slot per extent from the moment the extent is recorded. They must not drift
    // apart: a seeded height landing at the wrong index gives one block another block's size.
    try testing.expectEqual(t.extents.items.len, t.heights.items.len);

    // Record block 3 first; 0..2 must still be placed sensibly.
    t.record(gpa, 3, .{ .h = 77 }, tm, 600);
    try testing.expectEqual(@as(usize, 5), t.heights.items.len);
    var i: usize = 0;
    while (i < 3) : (i += 1) {
        try testing.expectEqual(Height.State.estimated, t.stateAt(i));
        // Read through `heightAt`: an estimated slot stores no height of its own, because an
        // estimate is a function of the column width it is asked about.
        try testing.expect(t.heightAt(i, tm, 600) > 0);
    }
    try testing.expectEqual(@as(f32, 77), t.heightAt(3, tm, 600));
}

test "a block cmark gave no span is not placeable until it is drawn" {
    const gpa = testing.allocator;
    var t: Table = .{};
    defer t.deinit(gpa);
    t.appendExtent(gpa, .{ .lines = 2, .bytes = 80, .start_line = 0 });
    t.appendExtent(gpa, .{}); // no span at all

    try testing.expect(t.placeable(0));
    // Must be drawn unconditionally: it has no height and no way to acquire one otherwise.
    try testing.expect(!t.placeable(1));

    t.record(gpa, 1, .{ .h = 60 }, tm, 600);
    try testing.expect(t.placeable(1));
}

test "an estimated-but-placeable block does not demand a draw" {
    const gpa = testing.allocator;
    var t = testTable(gpa, 3, 2);
    defer t.deinit(gpa);
    // Never measured, but every block has source to guess from.
    var i: usize = 0;
    while (i < 3) : (i += 1) try testing.expect(t.placeable(i));
}

// -- anchoring ---------------------------------------------------------------------------------

/// Every block 100px tall, blocks starting at source lines 0, 10, 20, ...
fn anchoredTable(gpa: std.mem.Allocator, n: usize) Table {
    var t = testTable(gpa, n, 10);
    var i: usize = 0;
    while (i < n) : (i += 1) {
        t.record(gpa, i, .{ .h = 100 }, tm, 600);
        t.record(gpa, i, .{ .h = 100 }, tm, 600);
    }
    return t;
}

test "an anchor follows its block through an edit that shifts every line" {
    const gpa = testing.allocator;
    var t = anchoredTable(gpa, 20);
    defer t.deinit(gpa);
    // Give each block a distinct source hash, as `recordBlockExtents` does.
    for (t.extents.items, 0..) |*e, i| e.hash = 1000 + @as(u64, i);

    const want = t.yAt(10, tm, 600, 0) + 30;
    const a = t.captureAnchor(want, tm, 600, 0, 10_000).?;
    try testing.expectEqual(@as(u64, 1010), a.hash);

    // An edit inserts two blocks near the top. Every line number below shifts; the hashes do not.
    var t2: Table = .{};
    defer t2.deinit(gpa);
    var i: usize = 0;
    while (i < 22) : (i += 1) {
        const src: u64 = if (i < 2) 900 + @as(u64, i) else 1000 + @as(u64, i - 2);
        // Lines all shifted by two relative to the original document.
        t2.appendExtent(gpa, .{ .lines = 10, .bytes = 400, .start_line = @intCast(i * 10), .hash = src });
    }
    i = 0;
    while (i < 22) : (i += 1) {
        t2.record(gpa, i, .{ .h = 100 }, tm, 600);
        t2.record(gpa, i, .{ .h = 100 }, tm, 600);
    }

    // The block that was index 10 is now index 12, and its *line* is no longer 100 — anchoring by
    // line would land on whatever now occupies line 100. By hash it lands exactly.
    try testing.expectEqual(@as(?usize, 12), t2.blockForHash(1010, a.line));
    try testing.expectApproxEqAbs(t2.yAt(12, tm, 600, 0) + 30, t2.resolveAnchor(a, tm, 600, 0, 10_000), 0.001);
}

test "duplicate block sources resolve to the nearest one, not the first" {
    const gpa = testing.allocator;
    var t = anchoredTable(gpa, 20);
    defer t.deinit(gpa);
    // A document that repeats itself: blocks 2, 10 and 17 are the same text (a rule, a stock
    // one-liner — real documents are full of these).
    for (t.extents.items, 0..) |*e, i| e.hash = 1000 + @as(u64, i);
    t.extents.items[2].hash = 777;
    t.extents.items[10].hash = 777;
    t.extents.items[17].hash = 777;

    // Anchored on the middle copy. Taking the first match would have sent the reader to block 2 —
    // near the top of the document, which is exactly what it did.
    const a = t.captureAnchor(t.yAt(10, tm, 600, 0), tm, 600, 0, 10_000).?;
    try testing.expectEqual(@as(u64, 777), a.hash);
    try testing.expectEqual(@as(?usize, 10), t.blockForHash(777, a.line));
    try testing.expectApproxEqAbs(t.yAt(10, tm, 600, 0), t.resolveAnchor(a, tm, 600, 0, 10_000), 0.001);

    // ...and the last copy resolves to itself too, not to either of the earlier ones.
    const b = t.captureAnchor(t.yAt(17, tm, 600, 0), tm, 600, 0, 10_000).?;
    try testing.expectEqual(@as(?usize, 17), t.blockForHash(777, b.line));
}

test "an anchor whose block the edit rewrote falls back to its line" {
    const gpa = testing.allocator;
    var t = anchoredTable(gpa, 20);
    defer t.deinit(gpa);
    for (t.extents.items, 0..) |*e, i| e.hash = 1000 + @as(u64, i);

    const a = t.captureAnchor(t.yAt(10, tm, 600, 0), tm, 600, 0, 10_000).?;

    // The reader's own block is the one that changed, so its hash is gone. The line still points
    // at roughly the right place, which is the best available answer.
    t.extents.items[10].hash = 424242;
    try testing.expectEqual(@as(?usize, null), t.blockForHash(a.hash, a.line));
    try testing.expectApproxEqAbs(t.yAt(10, tm, 600, 0), t.resolveAnchor(a, tm, 600, 0, 10_000), 0.001);
}

test "capture then resolve is the identity" {
    const gpa = testing.allocator;
    var t = anchoredTable(gpa, 20);
    defer t.deinit(gpa);

    for ([_]f32{ 0, 50, 137, 400, 1250 }) |v| {
        const a = t.captureAnchor(v, tm, 600, 0, 10_000).?;
        try testing.expectApproxEqAbs(v, t.resolveAnchor(a, tm, 600, 0, 10_000), 0.001);
    }
}

test "capture then resolve is the identity with a content origin" {
    const gpa = testing.allocator;
    var t = anchoredTable(gpa, 20);
    defer t.deinit(gpa);

    for ([_]f32{ 8, 137, 900 }) |v| {
        const a = t.captureAnchor(v, tm, 600, 8, 10_000).?;
        try testing.expectApproxEqAbs(v, t.resolveAnchor(a, tm, 600, 8, 10_000), 0.001);
    }
}

test "a block growing ABOVE the reader does not move the reader" {
    const gpa = testing.allocator;
    var t = anchoredTable(gpa, 20);
    defer t.deinit(gpa);

    // Parked partway into block 10.
    const before = t.yAt(10, tm, 600, 0) + 30;
    const a = t.captureAnchor(before, tm, 600, 0, 10_000).?;
    try testing.expectEqual(@as(u32, 100), a.line); // block 10 starts at source line 100
    try testing.expectApproxEqAbs(@as(f32, 30), a.offset_px, 0.001);

    // Blocks 0..4 turn out to be 60px taller each than they were guessed at — the warm-up sweep
    // arriving, or a table finally measuring its rows.
    var i: usize = 0;
    while (i < 5) : (i += 1) {
        t.record(gpa, i, .{ .h = 160 }, tm, 600);
        t.record(gpa, i, .{ .h = 160 }, tm, 600);
    }

    // The reader is still 30px into the same block. The offset absorbed the whole 300px, which
    // under an absolute scroll offset would have shoved five blocks' worth of text past them.
    const after = t.resolveAnchor(a, tm, 600, 0, 10_000);
    try testing.expectApproxEqAbs(t.yAt(10, tm, 600, 0) + 30, after, 0.001);
    try testing.expectApproxEqAbs(before + 300, after, 0.001);
}

test "a block growing BELOW the reader does not move the reader at all" {
    const gpa = testing.allocator;
    var t = anchoredTable(gpa, 20);
    defer t.deinit(gpa);

    const before = t.yAt(10, tm, 600, 0) + 30;
    const a = t.captureAnchor(before, tm, 600, 0, 10_000).?;

    var i: usize = 15;
    while (i < 20) : (i += 1) {
        t.record(gpa, i, .{ .h = 400 }, tm, 600);
        t.record(gpa, i, .{ .h = 400 }, tm, 600);
    }

    try testing.expectApproxEqAbs(before, t.resolveAnchor(a, tm, 600, 0, 10_000), 0.001);
}

test "a width change keeps the reader on the same block" {
    const gpa = testing.allocator;
    var t = anchoredTable(gpa, 20);
    defer t.deinit(gpa);

    const a = t.captureAnchor(t.yAt(10, tm, 600, 0), tm, 600, 0, 10_000).?;

    // Pane widened; everything reflows shorter.
    _ = t.invalidateForWidth(900);
    var i: usize = 0;
    while (i < 20) : (i += 1) {
        t.record(gpa, i, .{ .h = 70 }, tm, 900);
        t.record(gpa, i, .{ .h = 70 }, tm, 900);
    }

    // Still at the top of block 10, wherever that now is.
    try testing.expectApproxEqAbs(t.yAt(10, tm, 900, 0), t.resolveAnchor(a, tm, 900, 0, 10_000), 0.001);
}

test "an anchor survives a reparse that shifts block indices" {
    const gpa = testing.allocator;
    var t = anchoredTable(gpa, 20);
    defer t.deinit(gpa);

    // Reader at the top of the block starting on source line 100.
    const a = t.captureAnchor(t.yAt(10, tm, 600, 0), tm, 600, 0, 10_000).?;
    try testing.expectEqual(@as(u32, 100), a.line);

    // An edit inserts two new blocks near the top. Indices shift by two; source lines do not.
    var t2: Table = .{};
    defer t2.deinit(gpa);
    var i: usize = 0;
    while (i < 22) : (i += 1) {
        // Two extra blocks at lines 1 and 2, then the original blocks keep their lines.
        const line: u32 = if (i < 2) @intCast(i + 1) else @intCast((i - 2) * 10);
        t2.appendExtent(gpa, .{ .lines = 10, .bytes = 400, .start_line = line });
    }
    i = 0;
    while (i < 22) : (i += 1) {
        t2.record(gpa, i, .{ .h = 100 }, tm, 600);
        t2.record(gpa, i, .{ .h = 100 }, tm, 600);
    }

    // The same source line now lives at index 12 — and that is where the reader ends up.
    try testing.expectEqual(@as(?usize, 12), t2.blockForLine(100));
    try testing.expectApproxEqAbs(t2.yAt(12, tm, 600, 0), t2.resolveAnchor(a, tm, 600, 0, 10_000), 0.001);
}

test "parked at the end stays at the end as the document grows" {
    const gpa = testing.allocator;
    var t = anchoredTable(gpa, 20);
    defer t.deinit(gpa);

    const a = t.captureAnchor(1300, tm, 600, 0, 1300).?;
    try testing.expect(a.at_end);
    // The total grew by 500; "the end" moved with it.
    try testing.expectApproxEqAbs(@as(f32, 1800), t.resolveAnchor(a, tm, 600, 0, 1800), 0.001);
}

test "not-quite-at-the-end is not treated as at-the-end" {
    const gpa = testing.allocator;
    var t = anchoredTable(gpa, 20);
    defer t.deinit(gpa);

    const a = t.captureAnchor(1200, tm, 600, 0, 1300).?;
    try testing.expect(!a.at_end);
}

test "a short document that cannot scroll is not parked at the end" {
    const gpa = testing.allocator;
    var t = anchoredTable(gpa, 2);
    defer t.deinit(gpa);

    // max_scroll 0: everything is trivially "at the end", which must not latch.
    const a = t.captureAnchor(0, tm, 600, 0, 0).?;
    try testing.expect(!a.at_end);
}

test "anchoring skips back over a block with no source position" {
    const gpa = testing.allocator;
    var t: Table = .{};
    defer t.deinit(gpa);
    t.appendExtent(gpa, .{ .lines = 1, .bytes = 40, .start_line = 0 });
    t.appendExtent(gpa, .{ .lines = 1, .bytes = 40 }); // no_line
    var i: usize = 0;
    while (i < 2) : (i += 1) {
        t.record(gpa, i, .{ .h = 100 }, tm, 600);
        t.record(gpa, i, .{ .h = 100 }, tm, 600);
    }

    // Inside the unpositioned block: anchors to the previous positioned one, with the skipped
    // height rolled into the offset, so the round trip is still exact.
    const a = t.captureAnchor(150, tm, 600, 0, 10_000).?;
    try testing.expectEqual(@as(u32, 0), a.line);
    try testing.expectApproxEqAbs(@as(f32, 150), a.offset_px, 0.001);
    try testing.expectApproxEqAbs(@as(f32, 150), t.resolveAnchor(a, tm, 600, 0, 10_000), 0.001);
}

test "capture is null for an empty document" {
    const gpa = testing.allocator;
    var t: Table = .{};
    defer t.deinit(gpa);
    try testing.expectEqual(@as(?Anchor, null), t.captureAnchor(0, tm, 600, 0, 100));
}

test "resolve clamps into range" {
    const gpa = testing.allocator;
    var t = anchoredTable(gpa, 20);
    defer t.deinit(gpa);

    // An anchor deep in the document, resolved against a total that cannot reach it.
    const a: Anchor = .{ .line = 190, .offset_px = 0 };
    try testing.expectApproxEqAbs(@as(f32, 500), t.resolveAnchor(a, tm, 600, 0, 500), 0.001);
    // And never negative.
    const b: Anchor = .{ .line = 0, .offset_px = -9999 };
    try testing.expectApproxEqAbs(@as(f32, 0), t.resolveAnchor(b, tm, 600, 0, 500), 0.001);
}

test "clear resets the width so the next layout re-invalidates" {
    const gpa = testing.allocator;
    var t = testTable(gpa, 2, 2);
    defer t.deinit(gpa);

    _ = t.invalidateForWidth(600);
    try testing.expect(!t.invalidateForWidth(600));
    t.clear();
    try testing.expect(t.invalidateForWidth(600));
}
