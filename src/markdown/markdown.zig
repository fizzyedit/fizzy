//! In-tree markdown render library (host-side, native-only).
//!
//! This is the reusable *render engine* extracted from the markdown plugin — no document,
//! plugin, or editor machinery. The plugin store calls `drawPreview` to render fetched
//! README bytes; a future `.md` editing wrapper can reuse the same engine for its preview
//! pane (paired with `sdk.text` for the source pane).
//!
//! Depends on the `cmark-gfm` C library, so it is wired into native builds only and gated
//! out of the wasm build (see `build/markdown.zig`).
const std = @import("std");
const dvui = @import("dvui");

const md_parse = @import("md/cmark_parse.zig");
const render_ast = @import("md/render_ast.zig");

pub const RenderState = render_ast.RenderState;

/// Persistent, caller-owned preview state: caches the parsed AST + precomputed render data
/// keyed by a content hash, plus the scroll position. Reuse one instance across frames for a
/// given rendered document (e.g. the store's currently-selected plugin README).
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

    /// Re-parse only when the content changes (hash mismatch). All persistent allocations use
    /// `gpa`; pass the same allocator every frame for a given Preview.
    fn ensureParsed(self: *Preview, content: []const u8, gpa: std.mem.Allocator) void {
        self.gpa = gpa;
        var hasher = std.hash.XxHash3.init(0);
        hasher.update(content);
        const h = hasher.final();
        if (self.content_hash == h and self.ast_root != null) return;
        md_parse.freeCachedRoot(self.ast_root);
        self.ast_root = null;
        self.rs.clear(gpa);
        self.content_hash = h;
        if (md_parse.parseMarkdown(content)) |ast| {
            self.ast_root = @ptrCast(ast.root.n);
            _ = render_ast.scanNode(ast.root, &self.rs, gpa);
        }
    }
};

pub const PreviewOptions = struct {
    /// `std.Io` used for image loads. Required.
    io: std.Io,
    /// Base dir for resolving relative `![alt](path)` images. READMEs fetched from a remote repo
    /// have no local base, so relative images simply won't resolve — that's fine.
    image_base_dir: []const u8 = ".",
    /// Seed for widget ids so multiple previews don't collide.
    id_extra: u64 = 0,
};

/// Render `bytes` as a read-only markdown preview (own scroll area) into the current dvui parent.
/// Safe to call every frame; parsing is cached on `state` by content hash.
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

    var scroll = dvui.scrollArea(@src(), .{
        .scroll_info = &state.scroll,
        .horizontal_bar = .hide,
        .vertical_bar = .auto_overlay,
    }, .{
        .expand = .both,
        .background = true,
        .color_fill = dvui.themeGet().fill,
        .style = .content,
        .id_extra = opts.id_extra,
    });
    defer scroll.deinit();

    if (state.ast_root) |rp| {
        var v = dvui.box(@src(), .{ .dir = .vertical }, .{
            .expand = .horizontal,
            .gravity_x = 0,
            .padding = .{ .x = 8, .y = 8, .w = 8, .h = 8 },
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
}
