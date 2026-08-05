//! cmark-gfm markdown preview (native-only — links libc + C library).
const std = @import("std");
const dvui = @import("dvui");
const core_dvui = @import("core").dvui;

const md_parse = @import("md/cmark_parse.zig");
const render_ast = @import("md/render_ast.zig");
const net_image = @import("md/net_image.zig");

pub const RenderState = render_ast.RenderState;

/// Tear down process-wide preview state — currently the remote-image cache and its worker
/// threads, which must be joined before this plugin's dylib can be unloaded. Separate from
/// `Preview.deinit` because it is shared by every preview in the app, not owned by one.
pub fn deinitShared() void {
    net_image.deinit();
}

/// Persistent preview state: caches parsed AST + precomputed render data keyed by content hash.
pub const Preview = struct {
    scroll: dvui.ScrollInfo = .{},
    content_hash: u64 = std.math.maxInt(u64),
    ast_root: ?*anyopaque = null,
    gpa: ?std.mem.Allocator = null,
    rs: render_ast.RenderState = .{},

    pub fn deinit(self: *Preview) void {
        md_parse.freeCachedRoot(self.ast_root);
        self.ast_root = null;
        if (self.gpa) |gpa| self.rs.deinit(gpa);
        self.* = .{};
    }

    fn ensureParsed(self: *Preview, content: []const u8, gpa: std.mem.Allocator) void {
        self.gpa = gpa;
        var hasher = std.hash.XxHash3.init(0);
        hasher.update(content);
        const h = hasher.final();
        if (self.content_hash == h and self.ast_root != null) return;
        // `scanNode` needs the original source, not just the AST: cmark's text nodes have had
        // backslash escapes applied and adjacent runs merged, so `\[\[A]]` is indistinguishable
        // from `[[A]]` by then. See `md/wikilink_scan.zig`.
        md_parse.freeCachedRoot(self.ast_root);
        self.ast_root = null;
        self.rs.clear(gpa);
        self.content_hash = h;
        const t0 = std.Io.Clock.boot.now(dvui.io).nanoseconds;
        if (md_parse.parseMarkdown(content)) |ast| {
            self.ast_root = @ptrCast(ast.root.n);
            _ = render_ast.scanNode(ast.root, &self.rs, gpa, content);
        }
        render_ast.stats.parse_ns +%= @intCast(std.Io.Clock.boot.now(dvui.io).nanoseconds - t0);
    }
};

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
};

/// Render `bytes` as a read-only markdown preview (own scroll area) into the current dvui parent.
pub fn drawPreview(
    state: *Preview,
    bytes: []const u8,
    gpa: std.mem.Allocator,
    opts: PreviewOptions,
) void {
    state.ensureParsed(bytes, gpa);

    if (state.ast_root) |rp| {
        const root: md_parse.Node = .{ .n = @ptrCast(@alignCast(rp)) };
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

    var scroll = dvui.scrollArea(@src(), .{
        .scroll_info = &state.scroll,
        .horizontal_bar = .auto,
        .vertical_bar = .auto_overlay,
    }, .{
        .expand = .both,
        .background = opts.background,
        .color_fill = opts.color_fill orelse dvui.themeGet().fill,
        .style = .content,
        .id_extra = opts.id_extra,
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
        const pad: dvui.Rect = .{ .x = 8, .y = 8, .w = 8, .h = 8 };
        const pad_w = pad.x + pad.w;
        const viewport_w = state.scroll.viewport.w;
        const inner_w = if (viewport_w > pad_w) viewport_w - pad_w else 0;
        const column_w = @max(min_preview_content_width, inner_w);

        var v = dvui.box(@src(), .{ .dir = .vertical }, .{
            .expand = .none,
            .min_size_content = .{ .w = column_w },
            .max_size_content = .width(column_w),
            .gravity_x = 0,
            .padding = pad,
            .id_extra = opts.id_extra + 1,
        });
        defer v.deinit();

        const root: md_parse.Node = .{ .n = @ptrCast(@alignCast(rp)) };
        render_ast.renderDocument(root, .{
            .image_base_dir = opts.image_base_dir,
            .io = opts.io,
            .gpa = gpa,
            .rs = &state.rs,
            .id_base = @intCast(opts.id_extra << 16),
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
            // then, so it stands in.
            .viewport = if (state.scroll.viewport.h > 0)
                state.scroll.viewport
            else
                .{ .h = scroll.data().contentRect().h },
            .content_origin_y = pad.y,
            .column_width = column_w,
        });
    } else {
        dvui.labelNoFmt(
            @src(),
            "Could not parse markdown.",
            .{},
            .{
                .expand = .both,
                .gravity_x = 0.5,
                .gravity_y = 0.5,
                .color_text = dvui.themeGet().color(.err, .text).opacity(0.85),
                .id_extra = opts.id_extra,
            },
        );
    }

    scroll.deinit();

    // `state.scroll` is the caller-owned `ScrollInfo` the area was driven by, so it stays valid
    // after `deinit` and holds this frame's final viewport/virtual size/offset. Horizontal
    // overflow only happens below the min column width.
    core_dvui.drawScrollEdgeShadows(scroll_rs, scroll_rs, &state.scroll, .{});
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
