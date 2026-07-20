const std = @import("std");
const builtin = @import("builtin");
const Io = std.Io;

const dvui = @import("dvui");
const sdk = @import("fizzy_sdk");

const md = @import("cmark_parse.zig");

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
    /// @intFromPtr(node.n) → ExtNodeKind (extension nodes only).
    ext_node_kinds: std.AutoHashMapUnmanaged(usize, ExtNodeKind) = .empty,
    /// Set of @intFromPtr(node.n) for every node whose subtree contains an IMAGE.
    subtree_has_image: std.AutoHashMapUnmanaged(usize, void) = .empty,
    /// @intFromPtr(table_node.n) → column count (from header row).
    /// Avoids re-traversing the header row every render frame.
    table_col_counts: std.AutoHashMapUnmanaged(usize, usize) = .empty,

    pub fn deinit(self: *RenderState, gpa: std.mem.Allocator) void {
        self.clear(gpa);
        self.image_cache.deinit(gpa);
        self.image_sizes.deinit(gpa);
        self.ext_node_kinds.deinit(gpa);
        self.subtree_has_image.deinit(gpa);
        self.table_col_counts.deinit(gpa);
    }

    pub fn clear(self: *RenderState, gpa: std.mem.Allocator) void {
        var it = self.image_cache.iterator();
        while (it.next()) |kv| {
            gpa.free(kv.key_ptr.*);
            gpa.free(kv.value_ptr.*);
        }
        self.image_cache.clearRetainingCapacity();
        self.image_sizes.clearRetainingCapacity();
        self.ext_node_kinds.clearRetainingCapacity();
        self.subtree_has_image.clearRetainingCapacity();
        self.table_col_counts.clearRetainingCapacity();
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
    /// Directory of the markdown file (for resolving relative `![alt](path)`).
    image_base_dir: ?[]const u8 = null,
    io: Io,
    /// Persistent allocator (same lifetime as State).  Used for image cache.
    gpa: std.mem.Allocator,
    /// Precomputed per-AST data: node kind map, image subtree set, image cache.
    rs: *RenderState,
    /// Seed for per-document widget id_extra values (avoids collisions with other panes/docs).
    id_base: usize = 0,
};

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

/// Walk the AST once, populating rs.ext_node_kinds and rs.subtree_has_image.
/// Returns true when any node in the subtree rooted at `node` is an IMAGE.
pub fn scanNode(node: md.Node, rs: *RenderState, gpa: std.mem.Allocator) bool {
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

    var self_has_image = (node.nodeType() == md.c.CMARK_NODE_IMAGE);
    var child = node.firstChild();
    while (child) |ch| : (child = ch.nextSibling()) {
        if (scanNode(ch, rs, gpa)) self_has_image = true;
    }
    if (self_has_image)
        rs.subtree_has_image.put(gpa, @intFromPtr(node.n), {}) catch {};

    return self_has_image;
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
        preloadSingleImage(node, ctx, arena);
        return;
    }
    if (!ctx.rs.subtree_has_image.contains(@intFromPtr(node.n))) return;
    var child = node.firstChild();
    while (child) |ch| : (child = ch.nextSibling()) {
        preloadImageSubtree(ch, ctx, arena);
    }
}

fn preloadSingleImage(img: md.Node, ctx: RenderContext, arena: std.mem.Allocator) void {
    const raw_url = img.linkUrl() orelse return;
    const abs_path = resolvedLocalImagePath(ctx, arena, raw_url) orelse return;

    const bytes: []const u8 = blk: {
        if (ctx.rs.image_cache.get(abs_path)) |cached| break :blk cached;
        const fresh = Io.Dir.cwd().readFileAlloc(ctx.io, abs_path, ctx.gpa, .limited(max_image_bytes)) catch return;
        const key = ctx.gpa.dupe(u8, abs_path) catch {
            ctx.gpa.free(fresh);
            return;
        };
        ctx.rs.image_cache.put(ctx.gpa, key, fresh) catch {
            ctx.gpa.free(key);
            ctx.gpa.free(fresh);
            return;
        };
        break :blk fresh;
    };

    const dvui_key: dvui.Texture.Cache.Key = blk: {
        var h = dvui.fnv.init();
        const bp = bytes.ptr;
        h.update(std.mem.asBytes(&bp));
        const it = @intFromEnum(dvui.enums.TextureInterpolation.linear);
        h.update(std.mem.asBytes(&it));
        break :blk h.final();
    };

    // Cache hit: texture already warm this frame, nothing to do.
    if (dvui.textureGetCached(dvui_key) != null) return;

    // Cache miss: decode + GPU upload now so the animation first frame is free.
    const source: dvui.ImageSource = .{ .imageFile = .{
        .bytes = bytes,
        .name = abs_path,
        .invalidation = .ptr,
    } };
    const tex = dvui.Texture.fromImageSource(source) catch return;
    ctx.rs.image_sizes.put(ctx.gpa, @intFromPtr(bytes.ptr), .{
        .w = @floatFromInt(tex.width),
        .h = @floatFromInt(tex.height),
    }) catch {};
    dvui.textureAddToCache(dvui_key, tex);
}

// ---------------------------------------------------------------------------
// Image rendering helpers
// ---------------------------------------------------------------------------

fn resolvedLocalImagePath(ctx: RenderContext, arena: std.mem.Allocator, src: []const u8) ?[]const u8 {
    const t = std.mem.trim(u8, src, " \t\r\n");
    if (t.len == 0) return null;
    if (std.ascii.startsWithIgnoreCase(t, "http://")) return null;
    if (std.ascii.startsWithIgnoreCase(t, "https://")) return null;
    if (std.fs.path.isAbsolute(t))
        return std.fs.path.resolve(arena, &.{t}) catch null;
    const base = ctx.image_base_dir orelse return null;
    return std.fs.path.resolve(arena, &.{ base, t }) catch null;
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
    const wb = sdk.host().getServiceTyped(sdk.services.workbench.Api) orelse return false;
    const arena = dvui.currentWindow().arena();
    const parsed = parseFileUri(arena, url) orelse return false;
    // zls (and VS Code-style `#L` fragments) are 1-based; workbench is 0-based.
    const line: u32 = if (parsed.line_1based > 0) parsed.line_1based - 1 else 0;
    const character: u32 = if (parsed.character_1based > 0) parsed.character_1based - 1 else 0;
    _ = wb.revealPosition(parsed.path, line, character, open_side) catch |err| {
        dvui.log.err("markdown: revealPosition failed for {s}: {any}", .{ parsed.path, err });
        return true; // still a file URI — don't fall through to openURL
    };
    return true;
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
    var outer = dvui.box(@src(), .{ .dir = .vertical }, .{
        .expand = .horizontal,
        .margin = .{ .y = 4, .h = 4 },
        .id_extra = ids.next(),
    });
    defer outer.deinit();

    const arena = dvui.currentWindow().arena();
    const raw_url = img.linkUrl() orelse {
        renderMarkdownImagePlaceholder("(missing image src)", ids);
        return;
    };
    const url_trim = std.mem.trim(u8, raw_url, " \t\r\n");
    if (url_trim.len == 0) {
        renderMarkdownImagePlaceholder("(empty image src)", ids);
        return;
    }

    const alt_owned = linkLabelPlainText(img, arena) catch "";
    const alt: []const u8 = alt_owned;

    if (std.ascii.startsWithIgnoreCase(url_trim, "http://") or std.ascii.startsWithIgnoreCase(url_trim, "https://")) {
        var tl = dvui.textLayout(@src(), .{}, .{
            .expand = .horizontal,
            .id_extra = ids.next(),
        });
        defer tl.deinit();
        if (alt.len > 0) {
            tl.addText(alt, .{ .color_text = dvui.themeGet().color(.control, .text).opacity(0.85) });
            tl.addText(" ", .{});
        }
        addMarkdownLink(tl, url_trim, "open", .{
            .font = dvui.Font.theme(.mono),
        });
        return;
    }

    const abs_path = resolvedLocalImagePath(ctx, arena, url_trim) orelse {
        renderMarkdownImagePlaceholder("cannot resolve image path (save file or use absolute path)", ids);
        return;
    };

    // Use persistent cache to avoid reading the file every frame.
    const bytes: []const u8 = blk: {
        if (ctx.rs.image_cache.get(abs_path)) |cached| break :blk cached;

        const fresh = Io.Dir.cwd().readFileAlloc(ctx.io, abs_path, ctx.gpa, .limited(max_image_bytes)) catch {
            renderMarkdownImagePlaceholder("could not read image", ids);
            return;
        };
        const key = ctx.gpa.dupe(u8, abs_path) catch {
            ctx.gpa.free(fresh);
            renderMarkdownImagePlaceholder("could not read image", ids);
            return;
        };
        ctx.rs.image_cache.put(ctx.gpa, key, fresh) catch {
            ctx.gpa.free(key);
            ctx.gpa.free(fresh);
            renderMarkdownImagePlaceholder("could not cache image", ids);
            return;
        };
        break :blk fresh;
    };

    // Compute the same cache key dvui uses for this imageFile with .ptr invalidation.
    // dvui's hash() calls stbi_info but ignores the result for .ptr — we skip it entirely.
    const dvui_key: dvui.Texture.Cache.Key = blk: {
        var h = dvui.fnv.init();
        const bp = bytes.ptr;
        h.update(std.mem.asBytes(&bp));
        const it = @intFromEnum(dvui.enums.TextureInterpolation.linear);
        h.update(std.mem.asBytes(&it));
        break :blk h.final();
    };

    // Fast path: texture already in dvui's cache from a prior visible frame.
    // Use .texture source to bypass hash()/stbi_info entirely on this frame.
    // Slow path: texture not yet created. Use imageFile source so dvui creates it
    // lazily inside renderImage (only when the image is actually in the clip rect).
    var source: dvui.ImageSource = .{ .imageFile = .{
        .bytes = bytes,
        .name = abs_path,
        .invalidation = .ptr,
    } };
    const nat: dvui.Size = if (dvui.textureGetCached(dvui_key)) |tex| nat: {
        source = .{ .texture = tex };
        break :nat .{ .w = @floatFromInt(tex.width), .h = @floatFromInt(tex.height) };
    } else nat: {
        const size_key = @intFromPtr(bytes.ptr);
        break :nat ctx.rs.image_sizes.get(size_key) orelse sz: {
            const sz = dvui.imageSize(source) catch {
                renderMarkdownImagePlaceholder("unsupported or corrupt image", ids);
                return;
            };
            ctx.rs.image_sizes.put(ctx.gpa, size_key, sz) catch {};
            break :sz sz;
        };
    };

    if (nat.w <= 0 or nat.h <= 0) {
        renderMarkdownImagePlaceholder("invalid image size", ids);
        return;
    }

    const r = nat.w / nat.h;
    const max_fit_w = @min(max_image_display_width, max_image_display_height * r);
    const max_fit_h = @min(max_image_display_height, max_image_display_width / r);

    const scale = @min(1.0, @min(max_fit_w / nat.w, max_fit_h / nat.h));
    const dw = nat.w * scale;
    const dh = nat.h * scale;

    _ = dvui.image(@src(), .{ .source = source, .shrink = .ratio }, .{
        .min_size_content = .{ .w = dw, .h = dh },
        .max_size_content = dvui.Options.MaxSize.size(.{ .w = max_fit_w, .h = max_fit_h }),
        .expand = .ratio,
        .label = .{ .text = if (alt.len > 0) alt else "markdown image" },
        .id_extra = ids.next(),
    });

    if (alt.len > 0) {
        var cap = dvui.textLayout(@src(), .{}, .{
            .expand = .horizontal,
            .margin = .{ .y = 2, .h = 0 },
            .id_extra = ids.next(),
        });
        defer cap.deinit();
        cap.addText(alt, .{
            .font = dvui.Font.theme(.body).larger(-1),
            .color_text = dvui.themeGet().color(.control, .text).opacity(0.65),
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

fn renderInlineNodeToTl(tl: *dvui.TextLayoutWidget, x: md.Node, span: dvui.Options, ctx: RenderContext, ids: *IdGen) void {
    switch (x.nodeType()) {
        md.c.CMARK_NODE_TEXT => {
            if (x.literal()) |t| tl.addText(t, .{ .font = span.font, .color_text = span.color_text });
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
                const is_task = list_kind == .ul and item_node.taskListItemChecked();
                const bullet_str: []const u8 = if (is_task)
                    "✓"
                else switch (list_kind) {
                    .ul => "•",
                    .ol => std.fmt.bufPrint(&buf, "{d}.", .{idx}) catch "?",
                };
                if (list_kind == .ol) idx += 1;

                const bullet_color = if (is_task)
                    dvui.themeGet().color(.highlight, .fill)
                else
                    dvui.themeGet().color(.control, .text).opacity(0.45);

                {
                    var pb = dvui.box(@src(), .{ .dir = .horizontal }, .{
                        .min_size_content = .{ .w = col_w, .h = 0 },
                        .gravity_y = 0,
                        .id_extra = ids.next(),
                    });
                    _ = dvui.spacer(@src(), .{ .expand = .horizontal, .id_extra = ids.next() });
                    dvui.labelNoFmt(@src(), bullet_str, .{}, .{
                        .gravity_y = 0,
                        .color_text = bullet_color,
                        .id_extra = ids.next(),
                    });
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
                var tl_i = dvui.textLayout(@src(), .{}, .{ .expand = .horizontal, .id_extra = ids.next() });
                tl_i.addText(info, .{
                    .font = dvui.Font.theme(.mono).withWeight(.bold),
                    .color_text = dvui.themeGet().color(.control, .text).opacity(0.55),
                });
                tl_i.deinit();
            }

            var tl_c = dvui.textLayout(@src(), .{}, .{
                .expand = .horizontal,
                .padding = .{ .x = 10, .y = 8, .w = 10, .h = 8 },
                .id_extra = ids.next(),
            });
            defer tl_c.deinit();
            tl_c.addText(code, .{ .font = dvui.Font.theme(.mono) });
        },
        md.c.CMARK_NODE_HTML_BLOCK => {
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
                    .margin = .{ .y = 4, .h = 4 },
                    .id_extra = ids.next(),
                });
                defer tl.deinit();
                renderInlines(tl, n, .{}, ctx, ids);
            } else {
                var outer = dvui.box(@src(), .{ .dir = .vertical }, .{
                    .expand = .horizontal,
                    .margin = .{ .y = 4, .h = 4 },
                    .id_extra = ids.next(),
                });
                defer outer.deinit();
                renderInlineFlowContainer(n, .{}, ctx, ids);
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
            const span: dvui.Options = .{ .font = heading_font };

            if (!hasImageSubtree(ctx, n)) {
                var tl = dvui.textLayout(@src(), .{}, .{
                    .expand = .horizontal,
                    .margin = .{ .y = top_margin, .h = 2 },
                    .font = heading_font,
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

                var g = dvui.grid(@src(), .numCols(num_cols), .{
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

                const banded: dvui.GridWidget.CellStyle.Banded = .{
                    .alt_cell_opts = .{
                        .color_fill = dvui.themeGet().color(.control, .fill_press),
                        .background = true,
                    },
                };

                const cell_padding: dvui.Rect = .{ .x = 8, .y = 5, .w = 8, .h = 5 };

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
                            const cell_pos: dvui.GridWidget.Cell = .colRow(col, 0);
                            var hdr_cell_opts = banded.cellOptions(cell_pos);
                            hdr_cell_opts.padding = cell_padding;
                            var hcell = g.headerCell(@src(), col, hdr_cell_opts);
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
                            const cell_pos: dvui.GridWidget.Cell = .colRow(col, body_row);
                            var cell_opts = banded.cellOptions(cell_pos);
                            cell_opts.padding = cell_padding;
                            var cell_box = g.bodyCell(@src(), cell_pos, cell_opts);
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
    var ids: IdGen = .{ .n = ctx.id_base };
    renderBlock(root, &ids, ctx);
}
