//! Pluggable language/format support for the text editor.
//!
//! Plugins register a `LanguageSupport` contribution with optional hooks for tree-sitter
//! highlighting and/or a read-only preview pane. The `text` plugin looks up providers by
//! file extension; language plugins never own documents.
const std = @import("std");
const dvui = @import("dvui");
const core = @import("core");
const Plugin = @import("Plugin.zig");

/// Set by the text plugin immediately before calling `previewPane`; cleared after return.
/// Lets preview providers resolve relative assets (e.g. `![x](assets/foo.png)`) next to the
/// document without extending the vtable on every content edit.
///
/// NOTE: this only works because `previewPane`'s only consumers today (`text`/`markdown`)
/// happen to be statically linked into the same binary and so share one copy of this
/// `threadlocal`. It is NOT a valid way to pass data to a genuinely dynamically-loaded
/// plugin dylib — each `.dylib` gets its own private compiled copy of every SDK source file,
/// so a write from the host's copy is invisible from inside the plugin's copy (see
/// `src/sdk/version.zig`'s 0.13.0 changelog entry for the same class of bug with
/// `core.dvui.dialog_close_rect_override`). `hover`/`gotoDefinition` take `path` as an
/// explicit parameter instead, precisely because third-party language plugins (e.g. `zig`)
/// *are* loaded as separate dylibs.
threadlocal var preview_document_path: []const u8 = "";

pub fn setPreviewDocumentPath(path: []const u8) void {
    preview_document_path = path;
}

pub fn previewDocumentPath() []const u8 {
    return preview_document_path;
}

pub const HighlightStyle = struct {
    name: []const u8,
    opts: dvui.Options,
};

/// Tree-sitter highlight configuration returned by language plugins.
pub const TreeSitterHighlight = struct {
    /// Opaque tree-sitter language pointer (`*TSLanguage` at runtime on native).
    language: *anyopaque,
    queries: []const u8,
    highlights: []const HighlightStyle,
    log_captures: bool = false,
};

/// Result types below are owned by `core.lsp` (see `src/core/lsp/Client.zig`) — that's where
/// the LSP client producing them lives, shared by every language plugin. Aliased here so
/// `LanguageSupport.VTable` hooks can keep referring to them as `sdk.language.*`, matching the
/// rest of this SDK-facing surface; see each type's doc comment in `core.lsp` for the full
/// rationale (three-state hover convention, why `gotoDefinition` returns an LSP `Position`
/// instead of a resolved byte offset, the completion ghost-text/dropdown split, etc).
pub const HoverResult = core.lsp.HoverResult;
pub const DefinitionLocation = core.lsp.DefinitionLocation;
pub const CompletionKind = core.lsp.CompletionKind;
pub const CompletionItem = core.lsp.CompletionItem;
pub const SignatureHelpResult = core.lsp.SignatureHelpResult;

/// A plugin's contribution of language/format support for one or more extensions. Every
/// hook is optional and independent — a plugin can offer any subset.
pub const LanguageSupport = struct {
    id: []const u8,
    owner: ?*Plugin = null,
    vtable: *const VTable,

    pub const VTable = struct {
        /// Return true when this provider handles `ext` for preview (including the dot).
        supportsPreview: ?*const fn (state: *anyopaque, ext: []const u8) bool = null,
        /// Tree-sitter highlighting for `ext` (including the dot, e.g. ".zig").
        treeSitterHighlight: ?*const fn (state: *anyopaque, ext: []const u8) ?TreeSitterHighlight = null,
        /// Draw a read-only preview into the current dvui parent for the right-hand pane
        /// of a text|preview split. `bytes` is the live document text (re-called every
        /// frame the pane is visible, so a provider should cache its own parse internally
        /// keyed by content hash).
        previewPane: ?*const fn (state: *anyopaque, ext: []const u8, bytes: []const u8, id_extra: u64, gpa: std.mem.Allocator) anyerror!void = null,
        /// Non-blocking: return a cached/ready hover result for `byte_offset` in `bytes`
        /// (the document at `path`). Called every frame the mouse dwells over a token, so it
        /// must never block — kick off async work as a side effect. Three-state return:
        /// `null` while the lookup is still pending (in flight, or not yet queued — ask again
        /// next frame), `Some(.{.text = ""})` once it's definitively resolved to "nothing here"
        /// (don't ask again for this exact position/content until it changes), `Some` with
        /// real text once content lands. When the cache is populated from a background
        /// thread, call `sdk.refresh()` so the idle GUI wakes and redraws (mouse may not move
        /// again). `bytes` is the live document text, same convention as `previewPane`.
        /// `path` is passed explicitly (unlike `previewPane`)
        /// because language providers are commonly loaded as separate plugin dylibs — see the
        /// `preview_document_path` doc comment above for why a threadlocal can't be reused here.
        hover: ?*const fn (state: *anyopaque, ext: []const u8, path: []const u8, bytes: []const u8, byte_offset: usize) ?HoverResult = null,
        /// May block briefly (a few hundred ms) — called once per Ctrl/Cmd+click, not every
        /// frame. Returns the definition location for the symbol at `byte_offset` in `bytes`
        /// (the document at `path`), or null when none is found.
        gotoDefinition: ?*const fn (state: *anyopaque, ext: []const u8, path: []const u8, bytes: []const u8, byte_offset: usize) ?DefinitionLocation = null,
        /// Non-blocking, same convention as `hover`: return cached/ready completion
        /// candidates for the cursor at `byte_offset` in `bytes` (the document at `path`), or
        /// null when there's nothing to show yet. Called every frame the cursor sits in a
        /// completable position while typing — far more often than `hover`'s mouse-dwell
        /// trigger — so it must never block; kick off async work as a side effect and return
        /// null until a result is cached. When the cache is populated from a background
        /// thread, call `sdk.refresh()` so the idle GUI wakes. Never returns an empty
        /// (zero-length) slice — that's the same as null. The editor shows the first
        /// candidate's `insert_text` as ghost text and all of them in a scrollable dropdown
        /// list; Up/Down changes which one is "current" for both.
        completion: ?*const fn (state: *anyopaque, ext: []const u8, path: []const u8, bytes: []const u8, byte_offset: usize) ?[]const CompletionItem = null,
        /// Non-blocking, same convention as `hover`/`completion`: many language servers send
        /// completion candidates with an empty/placeholder `documentation` up front (a lazy-load
        /// optimization — full docs only sent on demand via LSP `completionItem/resolve`).
        /// `index` identifies which candidate from the most recent `completion` call at this
        /// same `byte_offset`/`bytes`/`path` to resolve (the provider is expected to have kept
        /// enough of that result cached to answer by index rather than re-deriving it). Returns
        /// the resolved documentation text, or null when there's nothing new yet (including
        /// "still in flight" — kick off async work as a side effect and return null until a
        /// result is cached, same as `hover`) or the provider has no resolve support at all, in
        /// which case the caller falls back to whatever `documentation` the original
        /// `CompletionItem` already carried. Called every frame a completion candidate's info
        /// panel would be visible, so it must never block.
        resolveCompletionDocumentation: ?*const fn (state: *anyopaque, ext: []const u8, path: []const u8, bytes: []const u8, byte_offset: usize, index: usize) ?[]const u8 = null,
        /// Non-blocking, same convention as `completion`: return a cached/ready signature
        /// help result for the call the cursor at `byte_offset` in `bytes` (the document at
        /// `path`) currently sits inside, or null when there's nothing to show yet (including
        /// "not inside a call at all", which a provider is expected to detect and return null
        /// for rather than the caller filtering it out). When the cache is populated from a
        /// background thread, call `sdk.refresh()` so the idle GUI wakes. Called every frame
        /// the cursor is inside an open call's parens while typing, so it must never block.
        signatureHelp: ?*const fn (state: *anyopaque, ext: []const u8, path: []const u8, bytes: []const u8, byte_offset: usize) ?SignatureHelpResult = null,
        /// Return true when this provider can format `ext` (including the dot, e.g. ".zig").
        /// Non-blocking and side-effect-free — called far more often than `format` itself (an
        /// owner asks it every frame to decide whether to show/enable a "Format Document" menu
        /// item), so it must never spawn a formatter process or otherwise block. Same
        /// supports/do split as `supportsPreview`/`previewPane`.
        supportsFormat: ?*const fn (state: *anyopaque, ext: []const u8) bool = null,
        /// May block briefly (formatting a single file is fast) — called only on explicit user
        /// action (Edit > Format Document, or format-on-save), never every frame. Returns the
        /// document's full contents reformatted, or null when formatting failed or the provider
        /// has nothing to say for `ext`. Valid only for the duration of the call, same
        /// convention as `HoverResult.text` — the caller (the document's owner) must copy it
        /// before returning.
        format: ?*const fn (state: *anyopaque, ext: []const u8, path: []const u8, bytes: []const u8) ?[]const u8 = null,
    };
};
