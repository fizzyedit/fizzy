//! Markdown preview (CommonMark+GFM via md4c / md4zig). Native and web.
const std = @import("std");
const core = @import("core");
const dvui = @import("dvui");

const md_ast = @import("md/ast.zig");

/// `ast_root` is stored type-erased so `Preview` and `ParseJob` can share the
/// field without either owning `md_ast`'s types in its signature.
fn treeOf(root: *anyopaque) *md_ast.Tree {
    return @ptrCast(@alignCast(root));
}
const render_ast = @import("md/render_ast.zig");
const net_image = @import("md/net_image.zig");

pub const RenderState = render_ast.RenderState;

/// Tear down process-wide preview state — currently the remote-image cache and its worker
/// threads, which must be joined before this plugin's dylib can be unloaded. Separate from
/// `Preview.deinit` because it is shared by every preview in the app, not owned by one.
pub fn deinitShared() void {
    net_image.deinit();
}

/// Web only — see `net_image.beginOverlayFrame`. Called once per canvas frame from
/// `Editor.tick` so leaving a README and sleeping the window stay distinct.
pub fn beginWebOverlayFrame() void {
    net_image.beginOverlayFrame();
}

/// Persistent preview state: caches parsed AST + precomputed render data keyed by content hash.
pub const Preview = struct {
    scroll: dvui.ScrollInfo = .{},
    /// Where the reader is, as content identity rather than as pixels — see
    /// `render_ast.Anchor`. Resolved into `scroll.viewport.y` at the top of every frame and
    /// captured back at the bottom, which is what makes the position survive heights changing
    /// underneath it.
    anchor: ?render_ast.Anchor = null,
    /// The offset `applyAnchor` last wrote. Anything else finding a different one there means the
    /// position was set from outside the frame loop — see `applyAnchor`.
    anchor_applied_y: ?f32 = null,
    /// The last viewport height the scroll area actually had. dvui sizes a widget from what its
    /// children reported the frame before, so a window *height* change (a vertical resize drag)
    /// can hand the scroll area a zero-height rect for a frame while the layout re-settles — and a
    /// zero viewport reads as "no scroll area, draw the whole document", which for a long README
    /// is every block laid out and shaped for a frame nobody sees (800 blocks: ~250ms in Debug,
    /// repeated on every height step of the drag). Standing in with the height we last had keeps
    /// that frame to the blocks that were on screen; nothing is lost, since the real height comes
    /// back with the next layout.
    last_viewport_h: f32 = 0,
    /// Diagnostics only (`render_ast.diag`): last frame's virtual size, to spot the scroll
    /// container's own total moving without any single block tripping the height probe.
    diag_prev_virt: f32 = -1,
    content_hash: u64 = std.math.maxInt(u64),
    ast_root: ?*anyopaque = null,
    gpa: ?std.mem.Allocator = null,
    rs: render_ast.RenderState = .{},
    /// In-flight background parse for large documents; see `ensureParsed`.
    parse_job: ?*ParseJob = null,

    /// Frees the parsed tree, if there is one. `gpa` is null only before the first
    /// parse, when there is nothing to free.
    fn freeAst(self: *Preview) void {
        const root = self.ast_root orelse return;
        self.ast_root = null;
        if (self.gpa) |gpa| md_ast.destroy(gpa, treeOf(root));
    }

    pub fn deinit(self: *Preview) void {
        if (self.parse_job) |job| {
            // Job still owns its AST + scan maps until polled; `destroy` frees whatever remains.
            job.destroy();
            self.parse_job = null;
        }
        self.freeAst();
        if (self.gpa) |gpa| self.rs.deinit(gpa);
        self.* = .{};
    }

    /// Bring 0-based source `line` to the top of the view.
    ///
    /// One assignment, and it lands on the next frame. This used to be a six-frame retry loop
    /// that re-scrolled until the target block's height settled, because it had to place the
    /// target in *pixels* against a total the renderer only half knew — `scrollToOffset` clamps
    /// against `virtual_size`, so a jump deep into a document was clamped short and needed
    /// another try. Naming the destination by line removes the problem rather than retrying it.
    pub fn revealLine(self: *Preview, line: u32) void {
        self.anchor = .{ .line = line, .offset_px = 0 };
        // Clearing this marks the new anchor as authoritative: `applyAnchor` treats a scroll
        // offset it did not write as an outside instruction and re-derives from it, which would
        // otherwise throw this request away before it was ever applied.
        self.anchor_applied_y = null;
    }

    /// The column width the heights were last laid out at, and the scroll room they imply.
    ///
    /// Both come from the *previous* frame, which is the point: the anchor has to be turned into
    /// an offset before this frame's scroll area exists, so it is resolved against the geometry
    /// that produced the offset being restored. Null before anything has been laid out — there is
    /// no position to restore on a document's first frame.
    fn anchorGeometry(self: *const Preview, opts: PreviewOptions) ?struct { column_w: f32, max_scroll: f32 } {
        const column_w = self.rs.blocks.layout_width;
        if (column_w < 0) return null;
        if (self.rs.blocks.len() == 0) return null;
        _ = opts;
        return .{
            .column_w = column_w,
            .max_scroll = @max(0, self.scroll.virtual_size.h - self.scroll.viewport.h),
        };
    }

    fn applyAnchor(self: *Preview, opts: PreviewOptions) void {
        const geo = self.anchorGeometry(opts) orelse return;

        // Did anything move the scroll position *between* frames? `scrollToOffset` from a
        // command, dvui scrolling a focused widget into view, a caller restoring a saved
        // position — none of those go through the scroll area's event handling, so none of them
        // are reflected in the anchor. Restoring the anchor over the top of one would silently
        // discard it, which is exactly what it did: a `scrollToOffset` was undone on the very
        // next frame and the reader snapped back.
        //
        // An offset that differs from what this function last wrote is therefore an instruction,
        // not drift. Adopt it, and re-derive the anchor from it.
        if (self.anchor_applied_y) |prev| {
            if (@abs(self.scroll.viewport.y - prev) > 0.01) {
                // Something moved the scroll position between frames and the anchor is about to
                // adopt it. Normal for a wheel tick; a *large* delta here is the signature of the
                // layout jumping, because it means the position changed by more than the input
                // that caused it. See `render_ast.diag`.
                if (render_ast.diag and @abs(self.scroll.viewport.y - prev) > 40) {
                    dvui.log.warn(
                        "md-diag: scroll moved {d:.1} -> {d:.1} ({d:.1}pt) between frames, anchor re-derived",
                        .{ prev, self.scroll.viewport.y, self.scroll.viewport.y - prev },
                    );
                }
                self.anchor = null;
            }
        }
        if (self.anchor == null) {
            self.anchor = render_ast.anchorCapture(
                &self.rs,
                self.scroll.viewport.y,
                geo.column_w,
                opts.content_padding.y,
                geo.max_scroll,
            );
        }

        const a = self.anchor orelse return;
        const before_y = self.scroll.viewport.y;
        const y = render_ast.anchorResolve(
            &self.rs,
            a,
            geo.column_w,
            opts.content_padding.y,
            geo.max_scroll,
        );
        // The anchor moving the reader itself.
        //
        // The adopt-log above only fires when something *else* changed the offset. It cannot see
        // this: here the anchor is the thing writing the offset, so a wrong resolve moves the
        // reader with nothing to report it. `anchorResolve` clamps against `max_scroll`, which
        // comes from `virtual_size` — i.e. from the widgets, not from the height table — so it
        // can move even when every block height is stable and the height probes stay silent.
        if (render_ast.diag and @abs(y - before_y) > 20) {
            dvui.log.warn(
                "md-diag: ANCHOR resolved {d:.1} -> {d:.1} ({d:.1}pt) line={d} off={d:.1} at_end={any} virt={d:.1} max_scroll={d:.1}",
                .{ before_y, y, y - before_y, a.line, a.offset_px, a.at_end, self.scroll.virtual_size.h, geo.max_scroll },
            );
        }
        self.scroll.viewport.y = y;
        self.anchor_applied_y = y;
        if (render_ast.diag) {
            const v = self.scroll.virtual_size.h;
            if (self.diag_prev_virt >= 0 and @abs(v - self.diag_prev_virt) > 20) {
                dvui.log.warn("md-diag: virtual_size {d:.1} -> {d:.1} ({d:.1}pt) — the scroll total moved", .{
                    self.diag_prev_virt, v, v - self.diag_prev_virt,
                });
            }
            self.diag_prev_virt = v;
        }
    }

    fn captureAnchor(self: *Preview, opts: PreviewOptions) void {
        const geo = self.anchorGeometry(opts) orelse return;

        // Only re-derive the anchor when something actually moved the viewport this frame. If the
        // offset is still exactly what `applyAnchor` wrote, nothing happened that the anchor does
        // not already describe — and re-deriving it anyway means re-deriving it against heights
        // that may be mid-reflow, which lets a single bad frame's geometry become the reader's
        // stored position. That is how a pane resize could walk the reader into a different
        // section: not one big jump, but sixty small ones, each faithfully recorded.
        if (self.anchor != null) {
            if (self.anchor_applied_y) |prev| {
                if (@abs(self.scroll.viewport.y - prev) <= 0.01) return;
            }
        }

        if (render_ast.anchorCapture(
            &self.rs,
            self.scroll.viewport.y,
            geo.column_w,
            opts.content_padding.y,
            geo.max_scroll,
        )) |a| {
            self.anchor = a;
            self.anchor_applied_y = self.scroll.viewport.y;
        }
    }

    fn ensureParsed(self: *Preview, content: []const u8, gpa: std.mem.Allocator) void {
        self.gpa = gpa;
        var hasher = std.hash.XxHash3.init(0);
        hasher.update(content);
        const h = hasher.final();
        if (self.content_hash == h and (self.ast_root != null or self.parse_job != null)) return;

        // First open always hops to a worker — including the repo's own mid-size docs
        // (PLUGINS.md / PLUGIN_MANIFEST_PLAN.md). Those used to parse+scan on the same frames
        // as the preview split / first layout, which is exactly when a hitch is most visible.
        // Edits (ast already present) stay synchronous so we don't thrash workers per keystroke.
        if (self.ast_root == null and self.parse_job == null) {
            if (render_ast.diag) {
                dvui.log.warn(
                    "md-diag: starting background parse (hash {x} -> {x}, {d} bytes, {d} blocks discarded)",
                    .{ self.content_hash, h, content.len, self.rs.blocks.len() },
                );
            }
            self.content_hash = h;
            self.rs.clear(gpa);
            self.startParseJob(content, gpa, h);
            return;
        }

        // Content changed while a first-open parse was still running: wait for that worker,
        // drop its now-stale AST, and parse the new bytes sync below.
        if (self.parse_job) |job| {
            job.destroy();
            self.parse_job = null;
        }

        self.parseSync(content, gpa, h);
    }

    fn parseSync(self: *Preview, content: []const u8, gpa: std.mem.Allocator, hash: u64) void {
        // `scanNode` needs the original source, not just the AST: text nodes have had
        // backslash escapes applied and adjacent runs merged, so `\[\[A]]` is indistinguishable
        // from `[[A]]` by then. See `md/wikilink_scan.zig`.
        if (render_ast.diag) {
            dvui.log.warn(
                "md-diag: SYNC re-parse (hash {x} -> {x}, {d} bytes, {d} blocks discarded)",
                .{ self.content_hash, hash, content.len, self.rs.blocks.len() },
            );
        }
        self.freeAst();
        self.rs.clear(gpa);
        self.content_hash = hash;
        const t0 = std.Io.Clock.boot.now(dvui.io).nanoseconds;
        if (md_ast.parse(gpa, content)) |tree| {
            self.ast_root = @ptrCast(tree);
            _ = render_ast.scanNode(tree.node(), &self.rs, gpa, content);
        }
        render_ast.stats.parse_ns +%= @intCast(std.Io.Clock.boot.now(dvui.io).nanoseconds - t0);
    }

    fn startParseJob(self: *Preview, content: []const u8, gpa: std.mem.Allocator, hash: u64) void {
        const bytes = gpa.dupe(u8, content) catch {
            // OOM falling back to sync keeps the preview usable; a hitch beats a blank pane forever.
            self.parseSync(content, gpa, hash);
            return;
        };
        const job = gpa.create(ParseJob) catch {
            gpa.free(bytes);
            self.parseSync(content, gpa, hash);
            return;
        };
        job.* = .{
            .bytes = bytes,
            .hash = hash,
            .gpa = gpa,
            // Captured here, on the UI thread, because the worker cannot get it for itself:
            // dvui's `current_window` is a plain global that is only meaningful between
            // `Window.begin`/`end` on the UI thread. See `workerMain`.
            .win = dvui.currentWindow(),
        };
        self.parse_job = job;
        // `Io.concurrent` matches the editor's file-load workers. Wasm has no thread
        // pool, so this fails and we parse inline below.
        job.future = dvui.io.concurrent(ParseJob.workerMain, .{job}) catch {
            // Thread pool unavailable: parse inline rather than leave the preview empty.
            const owned = job.bytes;
            const h = job.hash;
            gpa.destroy(job);
            self.parse_job = null;
            self.parseSync(owned, gpa, h);
            gpa.free(owned);
            return;
        };
        dvui.refresh(null, @src(), null);
    }

    /// Pull a finished background parse into `ast_root` / `rs`. Returns true when the preview
    /// should keep animating (job still running).
    fn pollParseJob(self: *Preview) bool {
        const job = self.parse_job orelse return false;
        if (!job.done.load(.acquire)) {
            dvui.refresh(null, @src(), null);
            return true;
        }
        const gpa = self.gpa orelse job.gpa;
        // Stale job: the document changed again while this one was parsing. Drop it.
        if (job.hash != self.content_hash) {
            job.destroy();
            self.parse_job = null;
            return false;
        }
        self.freeAst();
        self.ast_root = job.ast_root;
        job.ast_root = null;
        // Worker already filled `job.rs` (parse + scan). Swap it in — no UI-thread scan.
        if (render_ast.diag) {
            dvui.log.warn(
                "md-diag: parse job landed — replacing RenderState ({d} measured blocks, layout_width {d:.1}) with the worker's fresh one",
                .{ self.rs.blocks.len(), self.rs.blocks.layout_width },
            );
        }
        self.rs.clear(gpa);
        self.rs.deinit(gpa);
        self.rs = job.rs;
        job.rs = .{};
        job.destroy();
        self.parse_job = null;
        dvui.refresh(null, @src(), null);
        return false;
    }
};

const ParseJob = struct {
    bytes: []u8,
    hash: u64,
    gpa: std.mem.Allocator,
    /// The window to wake when the parse finishes. Captured on the UI thread — see `workerMain`.
    win: *dvui.Window,
    ast_root: ?*anyopaque = null,
    /// Filled on the worker alongside `ast_root` so the UI thread only swaps pointers.
    rs: render_ast.RenderState = .{},
    done: std.atomic.Value(bool) = .init(false),
    future: ?std.Io.Future(void) = null,

    fn workerMain(self: *ParseJob) void {
        defer {
            self.done.store(true, .release);
            // Wake the UI so `pollParseJob` runs without waiting for an unrelated input event.
            //
            // The window must be passed explicitly. `refresh(null, ...)` resolves through dvui's
            // `current_window` global, which off the UI thread is either null (it logs an error
            // and does nothing — which is what `zig build bench-markdown` caught) or, worse, a
            // live pointer it then races on while only setting `extra_frames_needed`. Neither
            // calls `backend.refresh()`, so neither actually wakes a sleeping app: the preview
            // sat on "Loading preview…" until some unrelated input arrived. With the window in
            // hand this takes `refreshBackend`, which is the documented cross-thread path.
            dvui.refresh(self.win, @src(), null);
        }
        if (md_ast.parse(self.gpa, self.bytes)) |tree| {
            self.ast_root = @ptrCast(tree);
            _ = render_ast.scanNode(tree.node(), &self.rs, self.gpa, self.bytes);
        }
    }

    fn destroy(self: *ParseJob) void {
        const gpa = self.gpa;
        // Await the worker before freeing `bytes` / `rs` — it reads/writes them for the whole parse.
        if (self.future) |*f| f.await(dvui.io);
        gpa.free(self.bytes);
        // Stale/abandoned jobs still own their AST + scan maps.
        if (self.ast_root) |root| md_ast.destroy(gpa, treeOf(root));
        self.rs.deinit(gpa);
        gpa.destroy(self);
    }
};

/// How far the pane's width may wander from the width already laid out before the preview accepts
/// it as a real resize — see where `column_w` is computed. Large enough to swallow the wobble a
/// pane picks up from an animated split ratio, small enough that a drag is followed closely.
const column_hysteresis: f32 = 6;

/// Floor for the preview's text column. The column tracks the scroll viewport above this, and
/// below it the pane scrolls horizontally instead of crushing prose to one character per line.
const min_preview_content_width: f32 = 360;

pub const PreviewOptions = struct {
    /// `std.Io` used for image loads. Required.
    io: std.Io,
    /// Base for resolving relative `![alt](path)` images: a directory on disk, or the source URL
    /// when the markdown itself was fetched (relative images are then fetched from the same host).
    image_base_dir: []const u8 = ".",
    /// Seed for widget ids so multiple previews don't collide.
    id_extra: u64 = 0,
    /// Absolute path of the document being previewed, or `""` when it has none — an unsaved
    /// buffer, or markdown fetched from the network (the store's README pane).
    ///
    /// Distinct from `image_base_dir`, which is a *directory* and may be a URL. This is the file
    /// itself, and it's what `[[wikilink]]` resolution is relative to. Leaving it empty disables
    /// wikilinks entirely: a fetched README must not resolve `[[Note]]` against the user's own
    /// local files, and a link to nowhere is worse than the literal text it was written as.
    document_path: []const u8 = "",
    /// Whether the preview paints fills behind its text at all — both the scroll area's own and
    /// each text widget's. `false` for a caller (the store's plugin detail page) that already
    /// draws its own background behind this and wants the preview to read as part of that pane
    /// rather than a visibly different panel.
    ///
    /// This has to reach the individual text widgets, not just the scroll area:
    /// `dvui.TextLayoutWidget.defaults.background` is true, so every paragraph/heading/caption
    /// paints its own fill unless told otherwise (see `render_ast.RenderContext.background`).
    /// Deliberate decoration — code-block panels, HTML-block tint, table banding — ignores this.
    background: bool = true,
    /// Overrides the default `.content`-styled fill when `background` is true. Null keeps the
    /// existing look (a real `.md` file's own preview tab).
    color_fill: ?dvui.Color = null,
    /// Inset between the pane's edges and the text column. Subtracted from the viewport to get
    /// the column width, so widening it narrows the prose rather than pushing it into a
    /// horizontal scroll. The default is the tight one wanted by a caller whose surrounding
    /// panel already supplies breathing room (the store's detail page); a preview that runs
    /// edge-to-edge in its own pane wants more (see `plugin.zig`'s `previewPane`).
    content_padding: dvui.Rect = .{ .x = 8, .y = 8, .w = 8, .h = 8 },
};

/// Render `bytes` as a read-only markdown preview (own scroll area) into the current dvui parent.
pub fn drawPreview(
    state: *Preview,
    bytes: []const u8,
    gpa: std.mem.Allocator,
    opts: PreviewOptions,
) void {
    state.ensureParsed(bytes, gpa);
    const parsing = state.pollParseJob();

    if (state.ast_root) |rp| {
        const root = treeOf(rp).node();
        render_ast.preloadImages(root, .{
            .image_base_dir = opts.image_base_dir,
            .io = opts.io,
            .gpa = gpa,
            .rs = &state.rs,
        });
    }

    // Own both axes: vertical for long READMEs, horizontal only when the viewport is narrower
    // than the readable floor (see `min_preview_content_width`). ScrollInfo defaults horizontal
    // to `.none`, so it has to be enabled here every frame.
    state.scroll.horizontal = .auto;
    state.scroll.vertical = .auto;

    // Put the reader back where they were, *before* the scroll area reads `viewport.y` (it takes
    // it in `init`). Doing this here rather than after `deinit` is the whole difference: the old
    // code corrected the offset once the frame had already been drawn with the stale one, so
    // every correction was visible as a jump instead of preventing one.
    state.applyAnchor(opts);

    var scroll = dvui.scrollArea(@src(), .{
        .scroll_info = &state.scroll,
        // Overlay on both axes: a packed horizontal bar shrinks `viewport.h`, which changes
        // `max_scroll` and makes the line-anchor fight the new total. Vertical was already
        // overlay for the same reason.
        .horizontal_bar = .auto_overlay,
        .vertical_bar = .auto_overlay,
        // Deliberately not `lock_visible`. dvui's own anchoring pins to a *widget id*, and if
        // that id is missing for one frame — which virtualized content cannot promise after a
        // scrollbar jump — `ScrollContainerWidget` parks every child offscreen and the pane goes
        // blank. Anchoring on a source line instead fails soft: a line that no longer exists
        // resolves to the nearest preceding block.
    }, .{
        .expand = .both,
        .background = opts.background,
        .color_fill = .{ .color = opts.color_fill orelse dvui.themeGet().fill },
        .style = .content,
        .id_extra = @truncate(opts.id_extra),
    });
    // Captured before `deinit` (which invalidates the widget) — the shadows are drawn *after* the
    // content so they sit on top of it, matching `PluginStore`'s panes. Note the workbench's
    // recents list draws its shadows immediately after creating the scroll area, i.e. underneath
    // its own content; that ordering is not copied here.
    const scroll_rs = scroll.data().rectScale();

    if (state.ast_root) |rp| {
        // Pin the column to the viewport width (with a readable floor). Do *not* let wide
        // children expand the document: with horizontal scroll on, that ratchets virtual_size
        // past the viewport and parks centered content (the pixi logo) somewhere off to the
        // right. Long code fences keep their own horizontal scroll; images already fit to this
        // column. See KeybindSettings for the same scroll-container trap.
        const pad = opts.content_padding;
        const pad_w = pad.x + pad.w;
        const viewport_w = state.scroll.viewport.w;
        const inner_w = if (viewport_w > pad_w) viewport_w - pad_w else 0;
        // Sticky: a width within `column_hysteresis` of the one already laid out reuses that
        // exact value, so nothing downstream sees any change at all.
        //
        // The renderer treats a width change as "the pane is being resized": it stops trusting
        // cached heights, stops spending its measuring budgets, unpins table heights, and asks for
        // another frame. All correct for a split drag — and catastrophic if the width never quite
        // holds still, because then that state never ends. The pane's width comes from a split
        // whose ratio is eased toward its target every frame, so "never quite holds still" is not
        // hypothetical.
        //
        // Measured: a **one pixel** oscillation took the preview from idle on 197 of 400 frames to
        // idle on *none* of them, while the reader drifted backwards as they scrolled forwards.
        // Rounding to a grid does not fix it — two widths a pixel apart still land either side of
        // a boundary. Reusing the previous value does, because the comparison downstream is
        // against that same value.
        //
        // A real drag still registers: the reference only moves when it is actually adopted, so a
        // slow drag accumulates against a fixed anchor and crosses the threshold within a few
        // pixels of travel.
        const raw_w = @max(min_preview_content_width, inner_w);
        const column_w = blk: {
            const prev = state.rs.blocks.layout_width;
            if (prev > 0 and @abs(raw_w - prev) <= column_hysteresis) break :blk prev;
            break :blk raw_w;
        };

        var v = dvui.box(@src(), .{ .dir = .vertical }, .{
            .expand = .none,
            .min_size_content = .{ .w = column_w },
            .max_size_content = .width(column_w),
            .gravity_x = 0,
            .padding = pad,
            .id_extra = @truncate(opts.id_extra + 1),
        });
        defer v.deinit();

        const root = treeOf(rp).node();
        render_ast.renderDocument(root, .{
            .image_base_dir = opts.image_base_dir,
            .io = opts.io,
            .gpa = gpa,
            .rs = &state.rs,
            .id_base = @truncate(opts.id_extra << 16),
            .background = opts.background,
            .document_path = opts.document_path,
            // What lets the renderer lay out only the blocks on screen. `viewport` is in the
            // scroll area's virtual coordinates, where the column box starts at 0 — so the first
            // block sits at its top padding.
            //
            // On a document's very first frame the `ScrollInfo` has not been laid out yet and its
            // viewport is all zeros, which would read as "no viewport, draw everything" — and that
            // frame is exactly the one that must not lay out a whole 60KB document, because it is
            // the frame the preview pane opens on. The scroll area's own rect is already known by
            // then, so it stands in — and when even that is zero (a frame mid vertical resize,
            // see `last_viewport_h`), the height the area had last frame does.
            .viewport = viewport: {
                if (state.scroll.viewport.h > 0) {
                    state.last_viewport_h = state.scroll.viewport.h;
                    break :viewport state.scroll.viewport;
                }
                const own_h = scroll.data().contentRect().h;
                if (own_h > 0) break :viewport .{ .h = own_h };
                break :viewport .{ .y = state.scroll.viewport.y, .h = state.last_viewport_h };
            },
            .content_origin_y = pad.y,
            .column_width = column_w,
        });
    } else if (parsing) {
        dvui.labelNoFmt(
            @src(),
            "Loading preview…",
            .{},
            .{
                .expand = .both,
                .gravity_x = 0.5,
                .gravity_y = 0.5,
                .color_text = .{ .color = dvui.themeGet().color(.content, .text).opacity(0.55) },
                .id_extra = @truncate(opts.id_extra),
            },
        );
    } else {
        dvui.labelNoFmt(
            @src(),
            "Could not parse markdown.",
            .{},
            .{
                .expand = .both,
                .gravity_x = 0.5,
                .gravity_y = 0.5,
                .color_text = .{ .color = dvui.themeGet().color(.err, .text).opacity(0.85) },
                .id_extra = @truncate(opts.id_extra),
            },
        );
    }

    scroll.deinit();

    // Record where the reader ended up, now that events, velocity and bounce have all had their
    // say and `virtual_size` reflects what was actually laid out. Next frame's `applyAnchor`
    // reconstructs this exact offset from the heights as they stand then — which is what lets a
    // block above the reader change height without moving them.
    state.captureAnchor(opts);

    // `state.scroll` is the caller-owned `ScrollInfo` the area was driven by, so it stays valid
    // after `deinit` and holds this frame's final viewport/virtual size/offset. Horizontal
    // overflow only happens below the min column width.
    core.draw.drawScrollEdgeShadows(scroll_rs, scroll_rs, &state.scroll, .{});
}

/// Like `drawPreview`, but resolves `![alt](path)` relative to `document_path`.
pub fn drawPreviewForDocument(
    state: *Preview,
    document_path: []const u8,
    bytes: []const u8,
    gpa: std.mem.Allocator,
    opts: PreviewOptions,
) void {
    var merged = opts;
    merged.image_base_dir = if (document_path.len == 0)
        "."
    else
        std.fs.path.dirname(document_path) orelse ".";
    merged.document_path = document_path;
    drawPreview(state, bytes, gpa, merged);
}
