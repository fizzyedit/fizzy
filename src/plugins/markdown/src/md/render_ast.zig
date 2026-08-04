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

    pub fn deinit(self: *RenderState, gpa: std.mem.Allocator) void {
        self.clear(gpa);
        self.image_cache.deinit(gpa);
        self.image_sizes.deinit(gpa);
        self.image_decode_failed.deinit(gpa);
        self.ext_node_kinds.deinit(gpa);
        self.subtree_has_image.deinit(gpa);
        self.table_col_counts.deinit(gpa);
        self.task_items.deinit(gpa);
        self.html_images.deinit(gpa);
        self.wikilinks.deinit(gpa);
        self.wikilink_resolved.deinit(gpa);
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
        self.table_col_counts.clearRetainingCapacity();
        self.task_items.clearRetainingCapacity();
        var hi = self.html_images.valueIterator();
        while (hi.next()) |urls| html_images_mod.free(urls.*, gpa);
        self.html_images.clearRetainingCapacity();
        var wi = self.wikilinks.valueIterator();
        while (wi.next()) |toks| gpa.free(toks.*);
        self.wikilinks.clearRetainingCapacity();
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
    return scanNodeInner(node, rs, gpa, .{ .bytes = source, .index = index });
}

fn scanNodeInner(node: md.Node, rs: *RenderState, gpa: std.mem.Allocator, source: ScanSource) bool {
    const ts = node.typeString();
    if (std.mem.eql(u8, ts, "table")) {
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
    }
    if (self_has_image)
        rs.subtree_has_image.put(gpa, @intFromPtr(node.n), {}) catch {};

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

/// Clickable markdown hyperlink. `file://` URLs (including zls hover's `file:///path#L12`
/// form) open in the editor via workbench `revealPosition`; everything else falls through to
/// `dvui.openURL`. Middle-click / Ctrl/Cmd+click requests a side split for file targets (and
/// a new browser window for http(s)), matching `TextLayoutWidget.addLink`.
fn addMarkdownLink(tl: *dvui.TextLayoutWidget, url: []const u8, text: ?[]const u8, opts: dvui.Options) void {
    const defs: dvui.Options = .{ .color_text = dvui.themeGet().focus, .font = dvui.Font.theme(.body).withUnderline(.{}) };
    if (tl.addTextClick(text orelse url, defs.override(opts))) |click_event| {
        const open_side = (click_event == .mouse and (click_event.mouse.button == .middle or click_event.mouse.mod.matchBind("ctrl/cmd")));
        openMarkdownUrl(url, open_side);
    }
}

fn openMarkdownUrl(url: []const u8, open_side: bool) void {
    if (tryRevealFileUri(url, open_side)) return;
    // `untitled://` (zls hover for unsaved buffers) and other non-http schemes have nowhere
    // useful to go via the system opener — skip them rather than hand SDL a junk URL.
    if (std.ascii.startsWithIgnoreCase(url, "untitled:")) return;
    _ = dvui.openURL(.{ .url = url, .new_window = open_side });
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
    var tl = dvui.textLayout(@src(), .{}, .{
        .expand = .horizontal,
        .margin = .{ .y = 2, .h = 2 },
        .background = ctx.background,
        .id_extra = ids.next(),
    });
    defer tl.deinit();
    addMarkdownLink(tl, url, text, .{ .font = dvui.Font.theme(.mono).larger(-1) });
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
        var outer = dvui.box(@src(), .{ .dir = .vertical }, .{
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

    var outer = dvui.box(@src(), .{ .dir = .vertical }, .{
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
                var tl = dvui.textLayout(@src(), .{}, .{
                    .expand = .horizontal,
                    .background = ctx.background,
                    .id_extra = ids.next(),
                });
                defer tl.deinit();
                addMarkdownLink(tl, url_trim, "open", .{ .font = dvui.Font.theme(.mono) });
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
    var cap = dvui.textLayout(@src(), .{}, .{
        .expand = .horizontal,
        .margin = .{ .y = 2, .h = 0 },
        .background = ctx.background,
        .id_extra = ids.next(),
    });
    defer cap.deinit();
    cap.addText(alt, .{
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

    var b = dvui.box(@src(), .{ .dir = .horizontal }, .{
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
                        var tl = dvui.textLayout(@src(), .{}, .{
                            .expand = .horizontal,
                            .background = span.background,
                            .id_extra = ids.next(),
                        });
                        defer tl.deinit();
                        tl.addText(t, .{ .font = span.font, .color_text = span.color_text });
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

        var tl = dvui.textLayout(@src(), .{}, .{
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
    if (ctx.wikilink == null) return tl.addText(literal, plain);
    const tokens = ctx.rs.wikilinks.get(@intFromPtr(node.n)) orelse return tl.addText(literal, plain);

    var cursor: usize = 0;
    for (tokens, 0..) |tok, i| {
        if (tok.start > cursor) tl.addText(literal[cursor..tok.start], plain);
        renderWikilink(tl, node, i, tok, span, ctx);
        cursor = tok.end;
    }
    if (cursor < literal.len) tl.addText(literal[cursor..], plain);
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
        .indexing => tl.addText(label, .{ .font = span.font, .color_text = span.color_text }),

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
        .unresolved => tl.addText(label, .{
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
            tl.addText(" ", .{});
        },
        md.c.CMARK_NODE_LINEBREAK => {
            tl.addText("\n", .{});
        },
        md.c.CMARK_NODE_CODE => {
            if (x.literal()) |t| {
                tl.addText(t, .{
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
                    addMarkdownLink(tl, url, if (display.len == 0) null else display, link_opts);
                } else |_| {
                    if (x.firstChild()) |_| renderInlines(tl, x, link_opts, ctx, ids);
                }
            }
        },
        md.c.CMARK_NODE_IMAGE => unreachable,
        md.c.CMARK_NODE_HTML_INLINE => {
            if (x.literal()) |t| tl.addText(t, .{
                .font = dvui.Font.theme(.mono),
                .color_text = dvui.themeGet().color(.err, .text),
            });
        },
        md.c.CMARK_NODE_FOOTNOTE_REFERENCE => {
            if (x.literal()) |t| {
                const fn_font = dvui.Font.theme(.mono).larger(-1);
                const fn_color = dvui.themeGet().focus.opacity(0.8);
                tl.addText("[^", .{ .font = fn_font, .color_text = fn_color });
                tl.addText(t, .{ .font = fn_font, .color_text = fn_color });
                tl.addText("]", .{ .font = fn_font, .color_text = fn_color });
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
                tl.addText(t, .{ .font = span.font, .color_text = span.color_text });
            }
        },
    }
}

fn renderBlock(n: md.Node, ids: *IdGen, ctx: RenderContext) void {
    const t = n.nodeType();
    switch (t) {
        md.c.CMARK_NODE_DOCUMENT => {
            var c = n.firstChild();
            while (c) |ch| : (c = ch.nextSibling()) renderBlock(ch, ids, ctx);
        },
        md.c.CMARK_NODE_BLOCK_QUOTE => {
            var outer = dvui.box(@src(), .{ .dir = .horizontal }, .{
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

            var content = dvui.box(@src(), .{ .dir = .vertical }, .{
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
                var row = dvui.box(@src(), .{ .dir = .horizontal }, .{
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
                    var pb = dvui.box(@src(), .{ .dir = .horizontal }, .{
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

                var col = dvui.box(@src(), .{ .dir = .vertical }, .{
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
            var outer = dvui.box(@src(), .{ .dir = .vertical }, .{
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
                var hdr = dvui.box(@src(), .{ .dir = .horizontal }, .{
                    .expand = .horizontal,
                    .padding = .{ .x = 10, .y = 5, .w = 10, .h = 5 },
                    .background = true,
                    .color_fill = dvui.themeGet().border.opacity(0.12),
                    .id_extra = ids.next(),
                });
                defer hdr.deinit();
                var tl_i = dvui.textLayout(@src(), .{}, .{ .expand = .horizontal, .background = false, .id_extra = ids.next() });
                tl_i.addText(info, .{
                    .font = dvui.Font.theme(.mono).withWeight(.bold),
                    .color_text = dvui.themeGet().color(.control, .text).opacity(0.55),
                });
                tl_i.deinit();
            }

            var tl_c = dvui.textLayout(@src(), .{}, .{
                .expand = .horizontal,
                .padding = .{ .x = 10, .y = 8, .w = 10, .h = 8 },
                .background = false,
                .id_extra = ids.next(),
            });
            defer tl_c.deinit();
            tl_c.addText(code, .{ .font = dvui.Font.theme(.mono) });
        },
        md.c.CMARK_NODE_HTML_BLOCK => {
            // `<p align="center"><img …></p>` is how most READMEs carry their hero image; render
            // the images and drop the wrapper markup rather than dumping the tags as raw text.
            if (ctx.rs.html_images.get(@intFromPtr(n.n))) |urls| {
                var outer = dvui.box(@src(), .{ .dir = .vertical }, .{
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
                var tl = dvui.textLayout(@src(), .{}, .{
                    .expand = .horizontal,
                    .margin = .{ .y = 2 },
                    .padding = .{ .x = 8, .y = 4, .w = 8, .h = 4 },
                    .background = true,
                    .color_fill = dvui.themeGet().color(.err, .fill).opacity(0.08),
                    .id_extra = ids.next(),
                });
                defer tl.deinit();
                tl.addText(h, .{
                    .font = dvui.Font.theme(.mono),
                    .color_text = dvui.themeGet().color(.err, .text).opacity(0.85),
                });
            }
        },
        md.c.CMARK_NODE_PARAGRAPH => {
            if (!hasImageSubtree(ctx, n)) {
                var tl = dvui.textLayout(@src(), .{}, .{
                    .expand = .horizontal,
                    .margin = .{ .y = paragraph_margin_y, .h = paragraph_margin_y },
                    .background = ctx.background,
                    .id_extra = ids.next(),
                });
                defer tl.deinit();
                renderInlines(tl, n, .{ .background = ctx.background }, ctx, ids);
            } else {
                var outer = dvui.box(@src(), .{ .dir = .vertical }, .{
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
                var tl = dvui.textLayout(@src(), .{}, .{
                    .expand = .horizontal,
                    .margin = .{ .y = top_margin, .h = 2 },
                    .font = heading_font,
                    .background = ctx.background,
                    .id_extra = ids.next(),
                });
                defer tl.deinit();
                renderInlines(tl, n, span, ctx, ids);
            } else {
                var outer = dvui.box(@src(), .{ .dir = .vertical }, .{
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
                var tl = dvui.textLayout(@src(), .{}, .{
                    .expand = .horizontal,
                    .margin = .{ .y = 4 },
                    .background = ctx.background,
                    .id_extra = ids.next(),
                });
                const fn_font = dvui.Font.theme(.mono).larger(-1);
                const fn_color = dvui.themeGet().focus.opacity(0.8);
                tl.addText("[^", .{ .font = fn_font, .color_text = fn_color });
                tl.addText(name, .{ .font = fn_font, .color_text = fn_color });
                tl.addText("]: ", .{ .font = fn_font, .color_text = fn_color });
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

                var table_wrap = dvui.box(@src(), .{ .dir = .vertical }, .{
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
                        var col: usize = 0;
                        var cl = row.firstChild();
                        while (cl) |cell| : (cl = cell.nextSibling()) {
                            if (extKind(ctx, cell) != .table_cell) continue;
                            const cell_box = g.cell(.{ .col = col, .row = body_row }, banded.opts(body_row, cell_padding));
                            defer cell_box.deinit();
                            renderInlineFlowContainer(cell, .{ .background = false }, ctx, ids);
                            col += 1;
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
    var resolved_ctx = ctx;
    resolved_ctx.wikilink = wikilinkResolver(ctx);

    var ids: IdGen = .{ .n = ctx.id_base };
    renderBlock(root, &ids, resolved_ctx);
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
