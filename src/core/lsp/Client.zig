//! A minimal, server-agnostic LSP client: process lifecycle, JSON-RPC framing, and just
//! enough of the LSP to answer `textDocument/hover`, `textDocument/definition`,
//! `textDocument/completion`, `textDocument/signatureHelp`, and `textDocument/formatting`.
//! The server to spawn, its `languageId`, and the host callbacks (allocator, workspace
//! folder, logging, redraw) are all supplied by the caller via `Config` — see `configure`.
//! A language plugin (`zig`/zls, a future `cpp`/clangd, …) wraps this with a thin
//! extension-gate + `Config` and registers the result as an `sdk.LanguageSupport` provider.
//!
//! Threading model (read this before touching anything below):
//! - `hover`/`gotoDefinition` are called on the **draw thread**, every frame the mouse
//!   dwells over a token (hover) or on a Ctrl/Cmd+click (gotoDefinition). `hover` must
//!   never block — it only reads a cache and, on a miss, hands a *copy* of the input off to
//!   a background worker. `gotoDefinition` is allowed to block briefly (a few hundred ms).
//! - The reader thread and dispatch-worker thread are the only places that block on the
//!   language server's I/O. Neither may call `dvui.*` — they only touch their own copied
//!   inputs, this struct's fields (behind `SpinLock`), and `self.config.allocator`, mirroring
//!   the discipline documented on `pixi`'s `PackJob.zig`.
//! - `bytes` passed into `hover`/`gotoDefinition` is a borrowed slice into the live,
//!   mutable document buffer — copy it before handing it to the background queue.
const std = @import("std");
const builtin = @import("builtin");
const dvui = @import("dvui");
const Protocol = @import("Protocol.zig");
const UriUtil = @import("UriUtil.zig");
const shell_env = @import("../shell_env.zig");
const darwin_spawn = @import("../darwin_spawn.zig");

const Client = @This();

/// Everything a language plugin supplies to make this client usable for its server. Set once
/// via `configure`, called from the plugin's `register(host)` — that's the earliest point
/// `sdk.allocator()`/`sdk.host()`-style values are actually valid (they can't be read at
/// comptime/file-scope struct init, which is why `Config` isn't just a constructor argument on
/// the file-scope `var client: Client = .{};` every plugin declares).
pub const Config = struct {
    /// Argv to spawn the language server, e.g. `&.{"zls"}` or `&.{"clangd", "--background-index"}`.
    command: []const []const u8,
    /// LSP `languageId` sent in `textDocument/didOpen`/`didChange`, e.g. `"zig"`, `"cpp"`.
    language_id: []const u8,
    /// Host allocator (persistent, not per-frame arena) — mirrors `sdk.allocator()`.
    allocator: std.mem.Allocator,
    /// Returns the current workspace folder, or null — queried fresh each time it's needed
    /// (mirrors `sdk.host().folder()`), since it can change after a project is opened/closed.
    getFolder: *const fn () ?[]const u8,
    /// Forwards a line at the given level to the host's Output panel and this dylib's own
    /// `std.log` (mirrors `sdk.host().logLine(level, source, msg)`) — needed because each
    /// plugin dylib has its own private `std.log` binding, so `dvui.log.warn` alone never
    /// reaches the host. Used both for this client's own diagnostics (spawn failure, stderr
    /// drain) and to relay the server's own `window/logMessage` notifications.
    log: *const fn (source: []const u8, level: std.log.Level, msg: []const u8) void,
    /// Wakes the app's event loop from a background thread (mirrors `sdk.refresh()`).
    refresh: *const fn () void,
    /// Sent verbatim as `initialize`'s `initializationOptions`, or omitted (sent as `null`)
    /// when absent. Several servers are near-unusable without server-specific settings here —
    /// rust-analyzer reads most of its behavior from this object, gopls expects a
    /// `"gopls"`-keyed settings dict — while others (zls) simply ignore it. Caller-owned; must
    /// outlive every call to `onFolderOpen` (this client re-sends it on every server restart).
    initialization_options: ?std.json.Value = null,
};

/// Hover text returned by `hover`. `text` is plain text or markdown, valid only for the
/// duration of the call — copy it if the caller needs to hold onto it past that frame. An
/// empty `text` is a deliberate, distinct answer — "definitively nothing to show here" (e.g. a
/// comment, or a symbol the language server has no info for) — not the same as the call
/// returning `null` ("still pending, ask again next frame"). Callers should render these two
/// cases differently (e.g. a brief "No info" vs a loading placeholder).
pub const HoverResult = struct {
    text: []const u8,
};

/// A jump target returned by `gotoDefinition`. `line`/`character` (both 0-based, `character`
/// a byte count within the line) are LSP `Position`-shaped rather than a pre-resolved byte
/// offset into the target file's contents — deliberately: resolving a definition usually lands
/// in a file this client has never read and doesn't otherwise need to (the caret target could
/// be in an entirely different, possibly huge, file than the one it was asked about), so
/// reading and parsing it here just to convert a position would be redundant work in a call
/// whose only other job is a network round-trip. The receiving side already has to load that
/// file to display it at all, so it resolves `line`/`character` against its own canonical,
/// already-in-memory buffer instead.
pub const DefinitionLocation = struct {
    /// Absolute path to the target file (may equal the source document's path).
    path: []const u8,
    /// 0-based line number.
    line: u32,
    /// 0-based byte offset within `line`. Clamped to the line's actual length by the
    /// receiving side if this client's own line/column bookkeeping runs past it.
    character: u32,
};

/// A coarse category for a completion candidate, used to pick which icon a dropdown row
/// shows — deliberately a small set, not a passthrough of the LSP's 25-value
/// `CompletionItemKind` enum; `lspCompletionKind` below maps the richer vocabulary onto this.
pub const CompletionKind = enum {
    function,
    method,
    variable,
    field,
    constant,
    /// A struct/class/interface/enum — anything that names a type.
    type_,
    module,
    keyword,
    other,
};

/// One completion candidate returned by `completion`, among possibly several. Valid only for
/// the duration of the call, same convention as `HoverResult.text` — copy it if the caller
/// needs to hold onto it past that frame.
pub const CompletionItem = struct {
    /// Full display text for the dropdown row, e.g. "orelse" — untouched by prefix-trimming,
    /// unlike `insert_text`. Distinct field because a ghost-text suffix like "else" reads as
    /// confusing/wrong when shown as a list row on its own.
    label: []const u8,
    /// Suggestion text already trimmed to a pure suffix after what the user has typed —
    /// ghost text only ever appears after the caret, it never re-shows characters already
    /// visible before it.
    insert_text: []const u8,
    /// Byte range in the document this replaces when accepted. Usually `[byte_offset,
    /// byte_offset)` (a pure insertion), but can start earlier when the underlying language
    /// server's result replaces an already-typed partial token.
    replace_start: usize,
    replace_end: usize,
    /// Drives the dropdown row's icon.
    kind: CompletionKind = .other,
    /// Short type/signature text shown on the right of the dropdown row, e.g. "u32" for a
    /// variable or "fn (a: u32) void" for a function. Empty when the provider has nothing to
    /// show — the row just omits the right-hand text rather than showing a blank space.
    detail: []const u8 = "",
    /// Doc comment / prose documentation for this candidate (plain text or markdown), shown in
    /// an info panel next to the dropdown while this candidate is highlighted — the same LSP
    /// `documentation` field a hover result's `HoverResult.text` draws from, just scoped to
    /// this one candidate instead of whatever's under the cursor. Empty when there's nothing
    /// to show, in which case the caller shows no info panel at all rather than an empty one.
    documentation: []const u8 = "",
};

/// Signature help for the call the cursor currently sits inside, returned by
/// `signatureHelp`, or null when the cursor isn't inside a call. Valid only for the duration
/// of the call, same convention as `HoverResult.text`.
pub const SignatureHelpResult = struct {
    /// Full signature text, e.g. "fn foo(a: u32, b: []const u8) void".
    label: []const u8,
    /// Byte range within `label` (not the document) to render emphasized — the active
    /// parameter's slice of the signature. Equal start/end means nothing to emphasize (a
    /// zero-arg call, or the language server didn't report an active parameter).
    active_param_start: usize,
    active_param_end: usize,
};

/// Real OS-thread-safe spinlock (`std.atomic.Mutex` has no blocking `lock()`, only
/// `tryLock`/`unlock`) for the short critical sections below — every locked region here is
/// O(1) hashmap/list work, never I/O, so spinning is fine.
const SpinLock = struct {
    inner: std.atomic.Mutex = .unlocked,

    fn lock(self: *SpinLock) void {
        while (!self.inner.tryLock()) std.Thread.yield() catch {};
    }
    fn unlock(self: *SpinLock) void {
        self.inner.unlock();
    }
};

const StateTag = enum(u8) { not_started, starting, ready, unavailable };

const ResponseSlot = struct {
    ready: std.atomic.Value(bool) = .init(false),
    /// Raw JSON message body, owned by `self.config.allocator`. Set once by the reader thread,
    /// consumed and freed by whichever caller is waiting on this slot.
    body: ?[]u8 = null,
};

const DocState = struct {
    version: i32,
    last_hash: u64,
};

const CacheKey = struct {
    path_hash: u64,
    byte_offset: usize,
    /// `Wyhash` of the document bytes at the time this position was queried. Without this,
    /// retyping a *different* character at a byte offset that's been queried before (common —
    /// type, backspace, type something else; or just move the cursor back to a spot you were
    /// at a minute ago after other edits) would collide on `{path_hash, byte_offset}` alone and
    /// silently serve the stale cached result for whatever used to be there, never re-querying
    /// zls at all. Observed as: pressing `m` and seeing `std` (a leftover suggestion from
    /// whatever was typed there before) as the first candidate.
    content_hash: u64,
};

const CacheEntry = struct {
    /// null is a *negative* cache entry — "zls has no hover info at this position" — still a
    /// cache hit. Without this, dwelling over any token with no hover (whitespace,
    /// punctuation, an unresolvable symbol, ...) would re-send an identical request to zls
    /// every single frame for as long as the mouse sits still, since nothing else would
    /// ever populate the cache for that key. That's a real hard-freeze risk, not just waste:
    /// it showed up in practice hovering into a huge stdlib file after goto-definition.
    text: ?[]u8,
    /// Insertion sequence number (from `Client.cache_seq`), used for oldest-first eviction.
    /// A plain counter, not wall-clock time — a counter is all LRU-ish eviction needs.
    seq: u64,
    /// When this entry was cached — used only to expire *negative* entries (`text == null`)
    /// after `hover_negative_cache_ttl_ms`. zls answers a hover request for an otherwise valid
    /// symbol (e.g. a type from a large dependency like `dvui`) with "no info" while it's still
    /// building its background analysis of that dependency, not just for genuinely undocumented
    /// tokens — without an expiry, that transient "not indexed yet" answer would cache
    /// indistinguishably from a permanent one and never self-correct for that exact
    /// `{path, byte_offset, content}` for the rest of the session, even once zls finishes and
    /// would now answer correctly (observed: the *first* hover over a given `dvui.Window`
    /// reference after launch permanently shows nothing, while a freshly typed identical
    /// reference elsewhere — a different cache key — hovers fine). Positive entries never
    /// expire: once zls has real text for a position, that answer isn't going stale the way
    /// "zls hasn't looked yet" is.
    cached_at: std.Io.Clock.Timestamp,
    /// Only meaningful when `text == null`. False means this negative hasn't been retried
    /// yet — per `cached_at`'s doc comment, a *single* negative answer is routinely just zls
    /// still indexing, not a real verdict, so `hover()` reports it to callers as still-pending
    /// (`null`) rather than "confirmed nothing" until a *second* consecutive negative answer
    /// lands for this exact key (tracked across the retry via `unconfirmed_negative_keys`,
    /// since this entry itself gets removed to force the retry). Only once `true` does
    /// `hover()` return `Some(.{.text=""})` — see `HoverResult`'s doc comment on the SDK side.
    confirmed_negative: bool = false,
};

const HoverJob = struct {
    path: []u8,
    bytes: []u8,
    byte_offset: usize,
    key: CacheKey,
};

/// A cached candidate plus the *original* LSP `CompletionItem` JSON it came from, serialized
/// back to text (see `runCompletionJob`) rather than kept as a `std.json.Value` tree — the
/// parsed response tree it was cut from is freed at the end of that call, and re-parsing this
/// text at resolve time is simpler than deep-cloning a `Value` graph into a separately owned
/// arena. Needed because `completionItem/resolve` (see `resolveCompletionDocumentation`) must
/// echo the item back verbatim, `data` field and all — zls uses that to resolve without
/// re-analyzing from scratch, and a synthetic item built from just `item`'s own fields
/// (`label`/`kind`/...) would be missing it.
const CachedCompletionItem = struct {
    item: CompletionItem,
    raw_json: []u8,
};

const CompletionCacheEntry = struct {
    /// null is a negative cache entry — "zls has no completion here" — same rationale as
    /// `CacheEntry.text`. Non-null is never empty (see `runCompletionJob`) — an owned slice of
    /// `CachedCompletionItem`s, each with gpa-owned `label`/`insert_text`/`detail`/
    /// `documentation`/`raw_json`; the slice and every string inside it are freed together
    /// (eviction, cache clear, shutdown).
    items: ?[]CachedCompletionItem,
    seq: u64,
};

/// Identifies one candidate from a specific `completion()` result, for
/// `resolveCompletionDocumentation` — `index` is that candidate's position in the *same*
/// `CompletionCacheEntry.items` the original `completion()` call filled in, so the raw item
/// JSON needed to actually send `completionItem/resolve` can be looked up from there.
const ResolveKey = struct {
    completion_key: CacheKey,
    index: usize,
};

const ResolveCacheEntry = struct {
    /// null is a negative cache entry — resolve returned nothing beyond what `completion()`
    /// already had (or failed) — same rationale as `CacheEntry.text`.
    documentation: ?[]u8,
    seq: u64,
};

/// A resolve request queued for the dispatch thread — unlike hover/completion/signature-help,
/// there's no debounce here (a highlighted-candidate change is already a settled, deliberate
/// selection by the time the caller asks, not a per-keystroke stream) — just a plain FIFO like
/// `HoverJob`. `raw_item_json` is an owned copy (the cache entry it was read from could be
/// evicted or freed while this job waits in the queue).
const ResolveJob = struct {
    key: ResolveKey,
    raw_item_json: []u8,
};

/// A completion request waiting out its debounce window. `completion()` overwrites this
/// (freeing whatever was here) whenever a new position is asked about — each keystroke
/// cancels the previous not-yet-sent request, so nothing is ever sent to zls for a position
/// the user has already moved past. Dropped entirely (not converted to a real request) if
/// nothing claims it before something newer replaces it.
const PendingCompletion = struct {
    path: []u8,
    bytes: []u8,
    byte_offset: usize,
    key: CacheKey,
    /// Real monotonic timestamp, not a counter — debounce genuinely needs to know "how much
    /// wall-clock time has passed", unlike `CacheEntry.seq`'s oldest-first eviction, which
    /// only needs relative ordering.
    queued_at: std.Io.Clock.Timestamp,
};

const SignatureHelpCacheEntry = struct {
    /// null is a negative cache entry — "not inside a call, or zls has nothing to show" —
    /// same rationale as `CacheEntry.text`. Non-null holds a gpa-owned `label`, freed
    /// together with the entry (eviction, cache clear, shutdown).
    result: ?SignatureHelpResult,
    seq: u64,
};

/// Same shape/rationale as `PendingCompletion`, for `textDocument/signatureHelp`.
const PendingSignatureHelp = struct {
    path: []u8,
    bytes: []u8,
    byte_offset: usize,
    key: CacheKey,
    queued_at: std.Io.Clock.Timestamp,
};

/// Set once via `configure` before any other method is called — see `Config`'s doc comment.
config: Config = undefined,
state: std.atomic.Value(StateTag) = .init(.not_started),
workspace_root: ?[]u8 = null,
child: ?std.process.Child = null,
next_id: std.atomic.Value(i64) = .init(1),
encoding: Protocol.PositionEncoding = .utf16,
/// Parsed from the `initialize` response's `capabilities.completionProvider.resolveProvider` —
/// zls (as of this writing) hard-codes this `false` (never sends a real answer to
/// `completionItem/resolve`, always `{"result": null}`), so without this check
/// `resolveCompletionDocumentation` would queue a doomed request for every single highlighted
/// candidate whose initial `documentation` is empty, for no benefit. Kept server-driven rather
/// than hardcoded to zls specifically in case a future/different server behind this same client
/// does support it.
completion_resolve_supported: bool = false,
shutdown: std.atomic.Value(bool) = .init(false),

/// Every background task this client owns (`startupThreadMain`, `readerThreadMain`,
/// `stderrDrainThreadMain`, `dispatchThreadMain`) — see `ensureStarted`'s and
/// `shutdownProcess`'s doc comments. One shared group rather than four separate
/// `?std.Thread` fields: `shutdownProcess` needs to wait for all of them together anyway
/// (there's no scenario where only some are running), and `Io.Group.concurrent` dispatches
/// onto `Io.Threaded`'s pooled workers instead of a fresh OS thread per (re)start.
tasks: std.Io.Group = .init,

write_lock: SpinLock = .{},

response_map_lock: SpinLock = .{},
response_map: std.AutoHashMapUnmanaged(i64, *ResponseSlot) = .empty,

open_docs_lock: SpinLock = .{},
open_docs: std.StringHashMapUnmanaged(DocState) = .empty,

hover_cache_lock: SpinLock = .{},
hover_cache: std.AutoHashMapUnmanaged(CacheKey, CacheEntry) = .empty,
in_flight: std.AutoHashMapUnmanaged(CacheKey, void) = .empty,
cache_seq: u64 = 0,
/// Deadline a negative hover entry will expire at, set whenever one is cached — the dispatch
/// thread polls this every loop tick (already running every 20ms regardless of whether the
/// GUI is asleep) and wakes the app once it elapses. Without this, a stationary hover whose
/// first answer was a transient "zls hasn't indexed this yet" negative (see `CacheEntry`'s
/// doc comment on why that's expected and self-correcting) never gets retried: `hover()` is
/// only ever called from a draw frame, the GUI goes to sleep once the mouse stops generating
/// events, and nothing is left to notice the TTL lapsed — the placeholder just sits there
/// until some unrelated real input forces a frame. Guarded by `hover_cache_lock` (already
/// held everywhere this needs touching). Null = nothing pending.
pending_negative_wake: ?std.Io.Clock.Timestamp = null,
/// Keys that have had exactly one negative answer, whose retry is still outstanding —
/// consulted (and cleared) by `cacheHoverResult` when the retry's answer lands, to tell "this
/// is the second negative in a row, confirm it" apart from "this is the first negative for a
/// key I've never seen before". Needed because the *entry* for an unconfirmed key gets
/// removed from `hover_cache` (by `hover()`, once its TTL elapses) to force the retry, so by
/// the time the retry completes there's nothing left in `hover_cache` itself to compare
/// against. Guarded by `hover_cache_lock`.
unconfirmed_negative_keys: std.AutoHashMapUnmanaged(CacheKey, void) = .empty,

queue_lock: SpinLock = .{},
queue: std.ArrayListUnmanaged(HoverJob) = .empty,

completion_cache_lock: SpinLock = .{},
completion_cache: std.AutoHashMapUnmanaged(CacheKey, CompletionCacheEntry) = .empty,
completion_in_flight: std.AutoHashMapUnmanaged(CacheKey, void) = .empty,
completion_cache_seq: u64 = 0,

completion_pending_lock: SpinLock = .{},
completion_pending: ?PendingCompletion = null,

signature_help_cache_lock: SpinLock = .{},
signature_help_cache: std.AutoHashMapUnmanaged(CacheKey, SignatureHelpCacheEntry) = .empty,
signature_help_in_flight: std.AutoHashMapUnmanaged(CacheKey, void) = .empty,
signature_help_cache_seq: u64 = 0,

signature_help_pending_lock: SpinLock = .{},
signature_help_pending: ?PendingSignatureHelp = null,

resolve_cache_lock: SpinLock = .{},
resolve_cache: std.AutoHashMapUnmanaged(ResolveKey, ResolveCacheEntry) = .empty,
resolve_in_flight: std.AutoHashMapUnmanaged(ResolveKey, void) = .empty,
resolve_cache_seq: u64 = 0,

/// Plain FIFO, not a debounced `Pending*` slot like completion/signature-help — see
/// `ResolveJob`'s doc comment for why.
resolve_queue_lock: SpinLock = .{},
resolve_queue: std.ArrayListUnmanaged(ResolveJob) = .empty,

/// Scratch buffer for the path returned from `gotoDefinition` — valid only until the next
/// `gotoDefinition` call, which matches how the caller (`TextEditor.drawEditor`) uses it:
/// synchronously, immediately after the call returns, in the same frame.
def_path_buf: std.ArrayListUnmanaged(u8) = .empty,

/// Owned copies of the most recently returned cache-hit results, kept alive until the *next*
/// call to the same function — safe because `hover`/`completion`/`signatureHelp` are only
/// ever called synchronously from the draw thread, and each caller fully consumes the
/// returned value before the next frame's call happens (same lifetime convention as
/// `def_path_buf` above).
///
/// These exist to close a real use-after-free race: a cache-hit used to unlock
/// `*_cache_lock` and hand back a slice/string *borrowed from the cache entry itself*. Nothing
/// then stopped the dispatch thread from concurrently evicting (freeing) that exact entry —
/// via `evictOldest*IfNeededLocked`, itself gated by the same lock, so it's not blocked by a
/// released lock — while the draw-thread caller was still reading the borrowed data. Confirmed
/// in practice: typing (which fires `completion()` on nearly every keystroke, filling the
/// 256-entry cache and triggering evictions quickly — far more than hover's mouse-dwell rate)
/// crashed with "reached unreachable code", from a freed `CompletionKind` byte failing an
/// exhaustive switch — freed memory is poison-filled in Debug/ReleaseSafe builds, so the
/// recycled byte didn't land on any of the enum's declared tags. The fix is to copy the data
/// out *while still holding the lock* (see `setHoverReturnScratch` etc.), so eviction — which
/// needs that same lock — can't race the copy.
hover_return_scratch: ?[]u8 = null,
completion_return_scratch: std.ArrayListUnmanaged(CompletionItem) = .empty,
signature_help_return_scratch: ?[]u8 = null,
/// Owned copy of the most recently returned `format` result — same lifetime convention as
/// `hover_return_scratch` above, but `format` has no cache to race against (it's a direct,
/// uncached request/response per call), so this exists purely so the returned slice survives
/// past `waitForSlot`'s response-body free, not to close a concurrent-eviction race.
format_return_scratch: ?[]u8 = null,
resolve_return_scratch: ?[]u8 = null,

const hover_cache_limit = 256;
/// How long a *negative* hover cache entry ("zls had no info here") stays trusted before a
/// re-hover at the same position retries instead of reusing it — see `CacheEntry.cached_at`'s
/// doc comment for why this needs to expire at all rather than caching forever like everything
/// else here.
const hover_negative_cache_ttl_ms: i64 = 5000;
const completion_cache_limit = 256;
const signature_help_cache_limit = 256;
const resolve_cache_limit = 256;
/// Caps how many candidates get resolved and shown per completion — zls can return dozens to
/// hundreds of matches for a short/common prefix; the dropdown list is meant to be scannable,
/// not exhaustive.
const completion_max_items = 50;
const poll_interval_ms: u64 = 5;
const hover_timeout_ms: u64 = 2000;
const definition_timeout_ms: u64 = 400;
const completion_timeout_ms: u64 = 2000;
/// How long a completion request waits, with nothing newer superseding it, before it's
/// actually sent to zls. No existing debounce precedent anywhere in this codebase to anchor
/// to — a pure tuning decision, easy to adjust after real-world testing.
const completion_debounce_ms: i64 = 200;
const signature_help_timeout_ms: u64 = 2000;
/// Same debounce window as completion — signature help re-queries at roughly the same
/// keystroke frequency (every character typed inside an open call's parens).
const signature_help_debounce_ms: i64 = 200;
const initialize_timeout_ms: u64 = 10_000;
/// Longer budget than `hover`/`completion` — formatting is an explicit, infrequent user
/// action (Edit > Format Document, or format-on-save) allowed to block briefly, same
/// convention as `gotoDefinition`, but zig fmt on a large file legitimately takes longer than
/// a single hover/completion lookup.
const format_timeout_ms: u64 = 5000;
/// Same budget as hover — `completionItem/resolve` is a single lightweight lookup for zls
/// (usually just formatting already-computed info), not a fresh analysis pass.
const completion_resolve_timeout_ms: u64 = 2000;

// ---- SDK-facing entry points (called on the draw thread) ------------------------------

/// Wires up the language server to spawn and the host callbacks this client needs — must be
/// called exactly once, before any other method, from the owning plugin's `register(host)`
/// (the earliest point host-injected values like `sdk.allocator()` are actually valid).
pub fn configure(self: *Client, config: Config) void {
    self.config = config;
}

pub fn onFolderOpen(self: *Client) void {
    // A real project folder is always authoritative over a per-file fallback root (see
    // `ensureStarted`) — restart zls against it if a process is already running (e.g. was
    // lazily spawned against a loose file's directory before this folder was opened).
    if (self.state.load(.acquire) != .not_started) self.shutdownProcess();
    self.workspaceRootUpdate();
}

pub fn onFolderClose(self: *Client) void {
    self.shutdownProcess();
    if (self.workspace_root) |r| self.config.allocator.free(r);
    self.workspace_root = null;
}

pub fn deinit(self: *Client) void {
    self.shutdownProcess();
    if (self.workspace_root) |r| self.config.allocator.free(r);
    self.workspace_root = null;
    self.def_path_buf.deinit(self.config.allocator);

    const gpa = self.config.allocator;
    if (self.hover_return_scratch) |t| gpa.free(t);
    for (self.completion_return_scratch.items) |it| {
        gpa.free(it.label);
        gpa.free(it.insert_text);
        gpa.free(it.detail);
        gpa.free(it.documentation);
    }
    self.completion_return_scratch.deinit(gpa);
    if (self.signature_help_return_scratch) |t| gpa.free(t);
    if (self.format_return_scratch) |t| gpa.free(t);
    if (self.resolve_return_scratch) |t| gpa.free(t);
}

/// Replaces `hover_return_scratch` with a fresh copy of `text`, freeing whatever was there —
/// see the field's doc comment. Returns null (and leaves the scratch empty) if the copy
/// itself fails, rather than falling back to the original unsafe-to-return reference.
fn setHoverReturnScratch(self: *Client, gpa: std.mem.Allocator, text: []const u8) ?[]const u8 {
    if (self.hover_return_scratch) |old| gpa.free(old);
    self.hover_return_scratch = gpa.dupe(u8, text) catch null;
    return self.hover_return_scratch;
}

/// Replaces `completion_return_scratch` with fresh copies of `cached[i].item` (and every owned
/// string inside them), freeing whatever was there — see the field's doc comment. `raw_json`
/// is deliberately not copied along: this scratch is the SDK-facing return value, which has no
/// slot for it and no caller needs it (only `resolveCompletionDocumentation`, which reads the
/// cache directly instead). Items that fail to dupe are skipped, matching `runCompletionJob`'s
/// existing "partial list beats none" stance.
fn setCompletionReturnScratch(self: *Client, gpa: std.mem.Allocator, cached: []const CachedCompletionItem) []const CompletionItem {
    for (self.completion_return_scratch.items) |it| {
        gpa.free(it.label);
        gpa.free(it.insert_text);
        gpa.free(it.detail);
        gpa.free(it.documentation);
    }
    self.completion_return_scratch.clearRetainingCapacity();
    for (cached) |c| {
        const item = c.item;
        const label = gpa.dupe(u8, item.label) catch continue;
        const insert_text = gpa.dupe(u8, item.insert_text) catch {
            gpa.free(label);
            continue;
        };
        const detail = gpa.dupe(u8, item.detail) catch {
            gpa.free(label);
            gpa.free(insert_text);
            continue;
        };
        const documentation = gpa.dupe(u8, item.documentation) catch {
            gpa.free(label);
            gpa.free(insert_text);
            gpa.free(detail);
            continue;
        };
        self.completion_return_scratch.append(gpa, .{
            .label = label,
            .insert_text = insert_text,
            .replace_start = item.replace_start,
            .replace_end = item.replace_end,
            .kind = item.kind,
            .detail = detail,
            .documentation = documentation,
        }) catch {
            gpa.free(label);
            gpa.free(insert_text);
            gpa.free(detail);
            gpa.free(documentation);
            continue;
        };
    }
    return self.completion_return_scratch.items;
}

/// Replaces `signature_help_return_scratch` with a fresh copy of `label`, freeing whatever
/// was there — see the field's doc comment.
fn setSignatureHelpReturnScratch(self: *Client, gpa: std.mem.Allocator, label: []const u8) ?[]const u8 {
    if (self.signature_help_return_scratch) |old| gpa.free(old);
    self.signature_help_return_scratch = gpa.dupe(u8, label) catch null;
    return self.signature_help_return_scratch;
}

/// Replaces `resolve_return_scratch` with a fresh copy of `text`, freeing whatever was there —
/// same rationale as `setHoverReturnScratch`.
fn setResolveReturnScratch(self: *Client, gpa: std.mem.Allocator, text: []const u8) ?[]const u8 {
    if (self.resolve_return_scratch) |old| gpa.free(old);
    self.resolve_return_scratch = gpa.dupe(u8, text) catch null;
    return self.resolve_return_scratch;
}

/// Non-blocking. Returns a cached hover result, or null and (on a cache miss) kicks off a
/// background fetch for next time.
pub fn hover(self: *Client, path: []const u8, bytes: []const u8, byte_offset: usize) ?HoverResult {
    if (path.len == 0) return null;
    if (!self.ensureStarted(path)) return null;

    const gpa = self.config.allocator;
    const key: CacheKey = .{ .path_hash = std.hash.Wyhash.hash(0, path), .byte_offset = byte_offset, .content_hash = std.hash.Wyhash.hash(0, bytes) };

    self.hover_cache_lock.lock();
    if (self.hover_cache.get(key)) |entry| {
        if (entry.text == null and !entry.confirmed_negative) {
            // Unconfirmed negative — a single "no info" answer, per `CacheEntry`'s doc
            // comment, is routinely just zls still indexing, not a real verdict. Report it as
            // still-pending (like an in-flight request) until the retry confirms it one way
            // or the other, rather than asserting a possibly-wrong "nothing here" the moment
            // the first answer lands.
            if (entry.cached_at.untilNow(dvui.io).raw.toMilliseconds() >= hover_negative_cache_ttl_ms) {
                // TTL elapsed — remove to force the retry below. `unconfirmed_negative_keys`
                // (set when this entry was first cached) remembers this key already had one
                // negative, surviving the removal so `cacheHoverResult` can tell a repeat
                // negative apart from a fresh one once the retry's answer lands.
                _ = self.hover_cache.remove(key);
            } else {
                self.hover_cache_lock.unlock();
                return null;
            }
        } else {
            // Copy out *while still holding the lock* — see `hover_return_scratch`'s doc
            // comment for why: this is the only thing preventing a concurrent eviction on the
            // dispatch thread from freeing `entry.text` while we're still reading it.
            //
            // A confirmed negative entry (`entry.text == null`, two consecutive "no hover
            // info" answers) returns `Some(.{.text = ""})`, not `null` — `null` is reserved
            // for "still pending" so the caller can tell "genuinely nothing to show" apart
            // from "ask again next frame". See `HoverResult`'s doc comment on the SDK side.
            const result: ?HoverResult = if (entry.text) |t| blk: {
                const copy = self.setHoverReturnScratch(gpa, t) orelse break :blk null;
                break :blk .{ .text = copy };
            } else .{ .text = "" };
            self.hover_cache_lock.unlock();
            return result;
        }
    }
    if (self.in_flight.contains(key)) {
        self.hover_cache_lock.unlock();
        return null;
    }
    self.in_flight.put(gpa, key, {}) catch {
        self.hover_cache_lock.unlock();
        return null;
    };
    self.hover_cache_lock.unlock();

    const owned_path = gpa.dupe(u8, path) catch {
        self.clearInFlight(key);
        return null;
    };
    const owned_bytes = gpa.dupe(u8, bytes) catch {
        gpa.free(owned_path);
        self.clearInFlight(key);
        return null;
    };

    self.queue_lock.lock();
    self.queue.append(gpa, .{ .path = owned_path, .bytes = owned_bytes, .byte_offset = byte_offset, .key = key }) catch {
        self.queue_lock.unlock();
        gpa.free(owned_path);
        gpa.free(owned_bytes);
        self.clearInFlight(key);
        return null;
    };
    self.queue_lock.unlock();
    return null;
}

/// May block up to `definition_timeout_ms`. Returns the definition location for the symbol
/// at `byte_offset`, or null on timeout / no result / zls unavailable.
pub fn gotoDefinition(self: *Client, path: []const u8, bytes: []const u8, byte_offset: usize) ?DefinitionLocation {
    if (path.len == 0) return null;
    if (!self.ensureStarted(path)) return null;

    const io = dvui.io;
    const gpa = self.config.allocator;

    self.syncDocument(io, path, bytes) catch |err| {
        dvui.log.warn("{s}: gotoDefinition: syncDocument failed: {any}", .{ self.config.language_id, err });
        return null;
    };

    const pos = Protocol.byteOffsetToPosition(bytes, byte_offset, self.encoding);
    const uri = UriUtil.pathToUri(gpa, path) catch return null;
    defer gpa.free(uri);

    const req = self.sendRequest(io, "textDocument/definition", .{
        .textDocument = .{ .uri = uri },
        .position = pos,
    }) catch |err| {
        dvui.log.warn("{s}: gotoDefinition: sendRequest failed: {any}", .{ self.config.language_id, err });
        return null;
    };

    const body = self.waitForSlot(io, req.id, req.slot, definition_timeout_ms) orelse {
        dvui.log.warn("{s}: gotoDefinition: request (id={d}) timed out", .{ self.config.language_id, req.id });
        return null;
    };
    defer gpa.free(body);

    var parsed = std.json.parseFromSlice(std.json.Value, gpa, body, .{}) catch return null;
    defer parsed.deinit();
    const resp = Protocol.parseResponse(parsed.value);
    // No result / a non-null error here usually just means "no definition found for this
    // symbol" (e.g. a keyword or literal), which is the common case, not a real problem.
    const result = resp.result orelse return null;

    const loc_obj = firstLocationObject(result) orelse return null;
    const target_uri = jsonString(loc_obj, "uri") orelse return null;
    const range = jsonObject(loc_obj, "range") orelse return null;
    const start = jsonObject(range, "start") orelse return null;
    const line = jsonInt(start, "line") orelse return null;
    const character = jsonInt(start, "character") orelse return null;

    const target_path = UriUtil.uriToPath(gpa, target_uri) catch return null;
    defer gpa.free(target_path);

    // Hand `line`/`character` straight back rather than resolving a byte offset here — the
    // target file may be one this client has never opened (an arbitrarily large standard-
    // library file, say), so reading and parsing it here just to convert a position would be
    // both wasted work (the receiving side has to load that same file to display it anyway)
    // and a second, independent place `line`/`character` -> byte-offset conversion could go
    // wrong. `DefinitionLocation`'s doc comment covers the tradeoff in full; the
    // shell resolves this against its own copy of the file once it has one loaded.
    //
    // `character` is only a true byte offset within the line when `self.encoding == .utf8`
    // (negotiated during `initialize` — see `spawnAndHandshake`); if zls fell back to the LSP-
    // default UTF-16 code-unit encoding, a target line containing non-ASCII text *before* the
    // reported column would land a handful of bytes off within that line. The line itself is
    // always exact either way, and Zig source is overwhelmingly ASCII, so this is an accepted,
    // rare approximation rather than a reason to keep the old per-jump file read.
    self.def_path_buf.clearRetainingCapacity();
    self.def_path_buf.appendSlice(gpa, target_path) catch return null;
    return .{
        .path = self.def_path_buf.items,
        .line = if (line >= 0) @intCast(line) else 0,
        .character = if (character >= 0) @intCast(character) else 0,
    };
}

/// May block up to `format_timeout_ms`. Returns `bytes` reformatted via zls's
/// `textDocument/formatting`, or null on timeout / no edits (already formatted, or the
/// document has a syntax error zls can't format around) / zls unavailable. Same
/// allowed-to-block convention as `gotoDefinition` — this is only ever called on an explicit
/// user action (Edit > Format Document, or format-on-save), never every frame.
pub fn format(self: *Client, path: []const u8, bytes: []const u8) ?[]const u8 {
    if (path.len == 0) return null;
    if (!self.ensureStarted(path)) return null;

    const io = dvui.io;
    const gpa = self.config.allocator;

    self.syncDocument(io, path, bytes) catch |err| {
        dvui.log.warn("{s}: format: syncDocument failed: {any}", .{ self.config.language_id, err });
        return null;
    };

    const uri = UriUtil.pathToUri(gpa, path) catch return null;
    defer gpa.free(uri);

    const req = self.sendRequest(io, "textDocument/formatting", .{
        .textDocument = .{ .uri = uri },
        .options = .{ .tabSize = @as(u32, 4), .insertSpaces = true },
    }) catch |err| {
        dvui.log.warn("{s}: format: sendRequest failed: {any}", .{ self.config.language_id, err });
        return null;
    };

    const body = self.waitForSlot(io, req.id, req.slot, format_timeout_ms) orelse {
        dvui.log.warn("{s}: format: request (id={d}) timed out", .{ self.config.language_id, req.id });
        return null;
    };
    defer gpa.free(body);

    var parsed = std.json.parseFromSlice(std.json.Value, gpa, body, .{}) catch return null;
    defer parsed.deinit();
    const resp = Protocol.parseResponse(parsed.value);
    // A missing/null result or an empty edit list just means "already formatted" (or zls
    // declined, e.g. a syntax error) — not an error worth logging.
    const result = resp.result orelse return null;
    if (result == .null) return null;
    const edits = switch (result) {
        .array => |arr| arr.items,
        else => return null,
    };
    if (edits.len == 0) return null;

    const formatted = applyTextEdits(gpa, bytes, edits, self.encoding) orelse return null;
    if (self.format_return_scratch) |old| gpa.free(old);
    self.format_return_scratch = formatted;
    return self.format_return_scratch;
}

/// Non-blocking, same convention as `hover`: returns a cached/ready inline suggestion, or
/// null and (on a cache miss) debounces a background fetch — completion fires on every
/// keystroke, far more often than hover's mouse-dwell trigger, so it follows hover's
/// never-block-the-draw-thread model, not `gotoDefinition`'s allowed-to-block-briefly one.
pub fn completion(self: *Client, path: []const u8, bytes: []const u8, byte_offset: usize) ?[]const CompletionItem {
    if (path.len == 0) return null;
    if (!self.ensureStarted(path)) return null;
    if (byte_offset == 0 or byte_offset > bytes.len) return null;

    // Cheap local pre-filter, not an LSP requirement: only identifier-continuing,
    // member-access, or builtin (`@`) positions are worth asking zls about — skips wasted
    // round-trips on cursor moves through whitespace/punctuation.
    const prev = bytes[byte_offset - 1];
    if (!(std.ascii.isAlphanumeric(prev) or prev == '_' or prev == '.' or prev == '@')) return null;

    const gpa = self.config.allocator;
    const key: CacheKey = .{ .path_hash = std.hash.Wyhash.hash(0, path), .byte_offset = byte_offset, .content_hash = std.hash.Wyhash.hash(0, bytes) };

    self.completion_cache_lock.lock();
    if (self.completion_cache.get(key)) |entry| {
        // Copy out *while still holding the lock* — see `hover_return_scratch`'s doc comment.
        const result: ?[]const CompletionItem = if (entry.items) |items|
            self.setCompletionReturnScratch(gpa, items)
        else
            null;
        self.completion_cache_lock.unlock();
        return result;
    }
    if (self.completion_in_flight.contains(key)) {
        self.completion_cache_lock.unlock();
        return null;
    }
    self.completion_cache_lock.unlock();

    self.completion_pending_lock.lock();
    defer self.completion_pending_lock.unlock();
    if (self.completion_pending) |pending| {
        // Already the pending request (e.g. the cursor has sat still here for several
        // frames, still waiting out the debounce window) — nothing to do. Only replace when
        // the position genuinely changed, or every frame's call would keep resetting the
        // debounce clock and it would never fire.
        if (std.meta.eql(pending.key, key)) return null;
        gpa.free(pending.path);
        gpa.free(pending.bytes);
    }
    const owned_path = gpa.dupe(u8, path) catch return null;
    const owned_bytes = gpa.dupe(u8, bytes) catch {
        gpa.free(owned_path);
        return null;
    };
    self.completion_pending = .{
        .path = owned_path,
        .bytes = owned_bytes,
        .byte_offset = byte_offset,
        .key = key,
        .queued_at = std.Io.Clock.Timestamp.now(dvui.io, .awake),
    };
    return null;
}

/// Non-blocking, same convention as `hover`: returns a cached/ready expanded documentation
/// string for candidate `index` of the `completion(path, bytes, byte_offset)` result that
/// produced it, or null while still resolving (kicks off a background
/// `completionItem/resolve`) or if there's nothing beyond what `completion()` already
/// returned. zls (like most LSP servers) sends an empty `documentation` placeholder in the
/// initial completion response for most non-trivial symbols — real doc-comment text is only
/// filled in per-candidate, on demand, via this request — see `CachedCompletionItem`'s doc
/// comment. `path`/`bytes`/`byte_offset` must match the original `completion()` call exactly
/// (same `CacheKey` derivation) so the raw item JSON needed to actually resolve can be found;
/// `index` out of range, or no completion cache entry for that key at all (evicted, or the
/// original request never completed), is a clean "nothing to resolve" rather than an error.
pub fn resolveCompletionDocumentation(self: *Client, path: []const u8, bytes: []const u8, byte_offset: usize, index: usize) ?[]const u8 {
    if (path.len == 0) return null;
    if (!self.ensureStarted(path)) return null;
    // zls declares `resolveProvider: false` and always answers `completionItem/resolve` with
    // `{"result": null}` — see `completion_resolve_supported`'s doc comment. Bail before
    // queuing a request that's guaranteed to come back empty.
    if (!self.completion_resolve_supported) return null;

    const gpa = self.config.allocator;
    const completion_key: CacheKey = .{ .path_hash = std.hash.Wyhash.hash(0, path), .byte_offset = byte_offset, .content_hash = std.hash.Wyhash.hash(0, bytes) };
    const key: ResolveKey = .{ .completion_key = completion_key, .index = index };

    self.resolve_cache_lock.lock();
    if (self.resolve_cache.get(key)) |entry| {
        // Copy out *while still holding the lock* — see `hover_return_scratch`'s doc comment.
        const result: ?[]const u8 = if (entry.documentation) |d| self.setResolveReturnScratch(gpa, d) else null;
        self.resolve_cache_lock.unlock();
        return result;
    }
    if (self.resolve_in_flight.contains(key)) {
        self.resolve_cache_lock.unlock();
        return null;
    }
    self.resolve_cache_lock.unlock();

    // The raw item JSON to send back lives on the *completion* cache entry for this same key —
    // not duplicated into the resolve cache itself, since it's only needed once, right here,
    // to build the queued job.
    self.completion_cache_lock.lock();
    const raw_json_copy: ?[]u8 = blk: {
        const entry = self.completion_cache.get(completion_key) orelse break :blk null;
        const items = entry.items orelse break :blk null;
        if (index >= items.len) break :blk null;
        break :blk gpa.dupe(u8, items[index].raw_json) catch null;
    };
    self.completion_cache_lock.unlock();
    const raw_json = raw_json_copy orelse return null;

    self.resolve_cache_lock.lock();
    self.resolve_in_flight.put(gpa, key, {}) catch {
        self.resolve_cache_lock.unlock();
        gpa.free(raw_json);
        return null;
    };
    self.resolve_cache_lock.unlock();

    self.resolve_queue_lock.lock();
    self.resolve_queue.append(gpa, .{ .key = key, .raw_item_json = raw_json }) catch {
        self.resolve_queue_lock.unlock();
        gpa.free(raw_json);
        self.clearResolveInFlight(key);
        return null;
    };
    self.resolve_queue_lock.unlock();
    return null;
}

/// Naive lexical scan (no string/comment awareness — a `(` inside a string literal or comment
/// on the same statement would miscount) for whether `byte_offset` sits inside an unclosed
/// `(`. Scans backward from the cursor, tracking paren depth, stopping at a statement boundary
/// (`;`, `{`, `}` at depth 0) or after `signature_help_scan_limit` bytes, whichever comes
/// first — bounds the cost on a long line/file and matches how far a single call expression
/// realistically extends. Documented gap, not a correctness bug, same as this file's other
/// lexical-scan shortcuts (see `wordStartBefore`).
const signature_help_scan_limit: usize = 500;
fn insideOpenCall(bytes: []const u8, byte_offset: usize) bool {
    if (byte_offset == 0 or byte_offset > bytes.len) return false;
    var depth: i32 = 0;
    var i = byte_offset;
    const floor = if (byte_offset > signature_help_scan_limit) byte_offset - signature_help_scan_limit else 0;
    while (i > floor) {
        i -= 1;
        switch (bytes[i]) {
            ')' => depth -= 1,
            '(' => {
                depth += 1;
                if (depth > 0) return true;
            },
            ';', '{', '}' => if (depth == 0) return false,
            else => {},
        }
    }
    return false;
}

/// Non-blocking, same convention as `completion`: returns a cached/ready signature help
/// result for the call the cursor at `byte_offset` currently sits inside, or null and (on a
/// cache miss) debounces a background fetch. Unlike `completion`'s alphanumeric/`.` pre-filter,
/// the local gate here is `insideOpenCall` — signature help is only ever relevant while the
/// cursor is inside an unclosed `(`.
pub fn signatureHelp(self: *Client, path: []const u8, bytes: []const u8, byte_offset: usize) ?SignatureHelpResult {
    if (path.len == 0) return null;
    if (!self.ensureStarted(path)) return null;
    if (!insideOpenCall(bytes, byte_offset)) return null;

    const gpa = self.config.allocator;
    const key: CacheKey = .{ .path_hash = std.hash.Wyhash.hash(0, path), .byte_offset = byte_offset, .content_hash = std.hash.Wyhash.hash(0, bytes) };

    self.signature_help_cache_lock.lock();
    if (self.signature_help_cache.get(key)) |entry| {
        // Copy out *while still holding the lock* — see `hover_return_scratch`'s doc comment.
        const result: ?SignatureHelpResult = if (entry.result) |r| blk: {
            const label_copy = self.setSignatureHelpReturnScratch(gpa, r.label) orelse break :blk null;
            break :blk .{ .label = label_copy, .active_param_start = r.active_param_start, .active_param_end = r.active_param_end };
        } else null;
        self.signature_help_cache_lock.unlock();
        return result;
    }
    if (self.signature_help_in_flight.contains(key)) {
        self.signature_help_cache_lock.unlock();
        return null;
    }
    self.signature_help_cache_lock.unlock();

    self.signature_help_pending_lock.lock();
    defer self.signature_help_pending_lock.unlock();
    if (self.signature_help_pending) |pending| {
        if (std.meta.eql(pending.key, key)) return null;
        gpa.free(pending.path);
        gpa.free(pending.bytes);
    }
    const owned_path = gpa.dupe(u8, path) catch return null;
    const owned_bytes = gpa.dupe(u8, bytes) catch {
        gpa.free(owned_path);
        return null;
    };
    self.signature_help_pending = .{
        .path = owned_path,
        .bytes = owned_bytes,
        .byte_offset = byte_offset,
        .key = key,
        .queued_at = std.Io.Clock.Timestamp.now(dvui.io, .awake),
    };
    return null;
}

// ---- lifecycle --------------------------------------------------------------------------

fn workspaceRootUpdate(self: *Client) void {
    const gpa = self.config.allocator;
    if (self.workspace_root) |r| gpa.free(r);
    self.workspace_root = null;
    if (self.config.getFolder()) |f| {
        self.workspace_root = gpa.dupe(u8, f) catch null;
    }
}

/// Falls back to `doc_path`'s containing directory as the workspace root when no project
/// folder is open — otherwise a loose file opened without "Open Project Folder" would never
/// get hover/goto-definition at all. A real folder open (`onFolderOpen`) always overrides
/// this and restarts zls against the authoritative root.
fn deriveFallbackRoot(self: *Client, doc_path: []const u8) void {
    const dir = std.fs.path.dirname(doc_path) orelse return;
    self.workspace_root = self.config.allocator.dupe(u8, dir) catch null;
}

/// Non-blocking: kicks off a background spawn+handshake at most once per `not_started`
/// period. Returns whether the client is ready to accept requests right now.
fn ensureStarted(self: *Client, doc_path: []const u8) bool {
    switch (self.state.load(.acquire)) {
        .ready => return true,
        .unavailable => return false,
        .starting => return false,
        .not_started => {
            if (self.workspace_root == null) self.deriveFallbackRoot(doc_path);
            if (self.workspace_root == null) return false;
            // Captured here, on the caller's thread (draw thread — `ensureStarted` is only
            // ever called from `hover`/`gotoDefinition`/etc.), and handed off by value rather
            // than read fresh from inside a background thread. `dvui.io` is a plain,
            // non-atomic global the draw thread also *writes* every frame
            // (`Editor.syncLoadedPluginDvuiContexts` → `dvui_context.inject`) — reading it
            // concurrently from another thread would race that writer with no synchronization,
            // risking a torn read of the vtable pointer. `Io.Group.concurrent` guarantees the
            // task is fully assigned a unit of concurrency before returning (unlike `Io.async`,
            // which is allowed to fall back to running inline on this — the draw — thread under
            // load), so this capture is the last read of the global on this thread for this
            // task; `startupThreadMain` only ever sees its own copy from here on.
            const io = dvui.io;
            self.tasks.concurrent(io, startupThreadMain, .{ self, io }) catch |err| {
                // `ConcurrencyUnavailable` is a documented transient condition (pool
                // exhaustion) — leave state as `not_started` so the next hover retries,
                // rather than permanently disabling the client the way `.unavailable` would.
                dvui.log.warn("{s}: Io.Group.concurrent(startupThreadMain) failed: {any}", .{ self.config.language_id, err });
                return false;
            };
            self.state.store(.starting, .release);
            return false;
        },
    }
}

/// Spawns the subprocess (see `spawnProcess`'s doc comment for why that's safe from a
/// background thread now — it was not, before `darwin_spawn` replaced the fork-based
/// `std.process.spawn` on the platform that mattered) and then runs the handshake — both on
/// this one `Io.Group`-dispatched task, so `ensureStarted` never blocks the draw thread.
fn startupThreadMain(self: *Client, io: std.Io) void {
    // Unconditional, regardless of how startup ends (spawn failure, handshake failure, or
    // success) — same reasoning as `dispatchThreadMain`'s job-completion `defer`. Without
    // this, any `hover()`/etc. call that arrived while zls was still starting up silently
    // no-ops via `ensureStarted` returning false (before reaching any of its own logging or
    // caching logic) and is never retried once startup finishes, since nothing wakes the UI
    // thread to notice the state flipped to `.ready`/`.unavailable` — it just sits on
    // whatever placeholder it last drew until an unrelated input event happens to trigger
    // another frame. zls startup (spawn + handshake + initial indexing) can easily take
    // several seconds on a large workspace, so this isn't a narrow race.
    defer self.config.refresh();
    self.spawnProcess(io) catch {
        self.state.store(.unavailable, .release);
        return;
    };
    self.handshake(io) catch |err| {
        dvui.log.warn("{s}: language server unavailable ({any})", .{ self.config.language_id, err });
        var msg_buf: [256]u8 = undefined;
        const msg = std.fmt.bufPrint(&msg_buf, "language server unavailable ({any})", .{err}) catch "language server unavailable";
        self.config.log(self.config.language_id, .warn, msg);
        self.state.store(.unavailable, .release);
        return;
    };
    self.state.store(.ready, .release);
}

/// Spawns the language server subprocess. Runs on the background `startupThreadMain` task, not
/// the draw thread — safe to do so now that this goes through `darwin_spawn` on Darwin rather
/// than `std.process.spawn` (see its doc comment): the latter always forks the whole process,
/// which is unsafe from a background thread in this multithreaded Cocoa/Metal process (if some
/// other thread holds a lock inside a non-fork-safe system framework at the instant of
/// `fork()`, that lock is stuck forever in the child), *and* unconditionally walks the
/// process's raw `environ` array in a way that's turned up a crash specifically right after a
/// Velopack installer auto-open. `darwin_spawn`'s `posix_spawn` doesn't fork the caller's
/// address space at all, so neither hazard applies regardless of which thread calls it.
fn spawnProcess(self: *Client, io: std.Io) !void {
    const root = self.workspace_root orelse return error.NoWorkspace;
    const gpa = self.config.allocator;

    // A GUI app launched via LaunchServices/launchd on macOS doesn't inherit the user's login
    // shell PATH — Homebrew, cargo, zvm, rustup, etc. install locations all live outside the
    // launchd-provided default (`/usr/bin:/bin:/usr/sbin:/sbin`), so `std.process.spawn`'s own
    // PATH search (over *this process's own* inherited PATH) usually can't find a server the
    // user installed normally from a terminal, even though it's right there once you open one.
    // Resolve it ourselves first and pass an absolute path, which sidesteps that search
    // entirely; falls back to the bare command unresolved (same behavior as before this
    // existed) if it can't be found anywhere, so the resulting error is still a clear
    // FileNotFound rather than something more surprising.
    const resolved_argv0 = resolveExecutable(gpa, io, self.config.command[0]);
    defer if (resolved_argv0) |r| gpa.free(r);

    var argv_buf: [16][]const u8 = undefined;
    const argv: []const []const u8 = if (resolved_argv0 != null and self.config.command.len <= argv_buf.len) blk: {
        argv_buf[0] = resolved_argv0.?;
        @memcpy(argv_buf[1..self.config.command.len], self.config.command[1..]);
        break :blk argv_buf[0..self.config.command.len];
    } else self.config.command;

    self.child = spawnChild(gpa, io, argv, root) catch |err| {
        dvui.log.warn("{s}: could not spawn \"{s}\" ({any}) — hover/goto-definition disabled for this session", .{ self.config.language_id, argv[0], err });
        var msg_buf: [256]u8 = undefined;
        const msg = std.fmt.bufPrint(&msg_buf, "could not spawn \"{s}\" ({any}) — hover/goto-definition disabled for this session", .{ argv[0], err }) catch "could not spawn language server";
        self.config.log(self.config.language_id, .warn, msg);
        return err;
    };
}

fn spawnChild(gpa: std.mem.Allocator, io: std.Io, argv: []const []const u8, cwd: []const u8) !std.process.Child {
    if (comptime builtin.os.tag == .macos) {
        // Prefers the fuller login-shell-resolved PATH (already resolved above, by
        // `resolveExecutable` → `shell_env.path`, and cached) over this process's own
        // inherited one, so the server itself — not just fizzy locating its binary — sees the
        // user's normal PATH (e.g. a server that shells out to other installed tools).
        return darwin_spawn.spawn(gpa, .{
            .argv = argv,
            .cwd = cwd,
            .stdin = .pipe,
            .stdout = .pipe,
            .stderr = .pipe,
        }, shell_env.path(gpa, io));
    }
    return std.process.spawn(io, .{
        .argv = argv,
        .cwd = .{ .path = cwd },
        .stdin = .pipe,
        .stdout = .pipe,
        .stderr = .pipe,
    });
}

/// Resolves `name` to an absolute executable path if it isn't one already (i.e. contains no
/// `/` — already a path, `std.process.spawn` treats it literally rather than PATH-searching).
/// Searches this process's own inherited `PATH` first — cheap, and covers any setup that
/// already works (e.g. a LaunchAgent plist setting PATH) without the cost below. Only on a
/// miss there does it fall back to asking the user's actual login shell what its `PATH` is
/// (`shell_env.path`) and searching that — this is what makes a `zls` installed via Homebrew,
/// cargo, zvm, or anywhere else the user's own shell profile already knows about resolve
/// correctly, without fizzy having to guess at or hardcode install locations itself. Caller
/// owns the returned slice; returns null if `name` isn't found on either PATH.
fn resolveExecutable(gpa: std.mem.Allocator, io: std.Io, name: []const u8) ?[]u8 {
    if (std.mem.indexOfScalar(u8, name, '/') != null) return null;

    const inherited_path: ?[]const u8 = if (std.c.getenv("PATH")) |p| std.mem.span(p) else null;
    if (findInPath(gpa, io, inherited_path, name)) |found| return found;

    return findInPath(gpa, io, shell_env.path(gpa, io), name);
}

/// Searches each `:`-separated directory in `path_value` for `name`, in order, returning the
/// first that exists. Caller owns the returned slice.
fn findInPath(gpa: std.mem.Allocator, io: std.Io, path_value: ?[]const u8, name: []const u8) ?[]u8 {
    const p = path_value orelse return null;
    var it = std.mem.splitScalar(u8, p, ':');
    while (it.next()) |dir| {
        if (dir.len == 0) continue;
        const candidate = std.fs.path.join(gpa, &.{ dir, name }) catch continue;
        std.Io.Dir.accessAbsolute(io, candidate, .{ .read = true }) catch {
            gpa.free(candidate);
            continue;
        };
        return candidate;
    }
    return null;
}

/// Everything after the subprocess is already running: reader/stderr threads plus the LSP
/// `initialize`/`initialized` handshake. None of this forks, so — unlike `spawnProcess` — it's
/// safe, and necessary (to keep `hover`/etc. non-blocking), to run on the background startup
/// thread.
fn handshake(self: *Client, io: std.Io) !void {
    const root = self.workspace_root orelse return error.NoWorkspace;
    const gpa = self.config.allocator;

    try self.tasks.concurrent(io, readerThreadMain, .{ self, io });
    try self.tasks.concurrent(io, stderrDrainThreadMain, .{ self, io });

    const root_uri = try UriUtil.pathToUri(gpa, root);
    defer gpa.free(root_uri);

    // `name` is display-only (used by multi-root-aware servers in logs/UI) — falls back to
    // the full root when it has no path separator to take a basename from (e.g. a bare "/").
    const root_name = std.fs.path.basename(root);

    const req = try self.sendRequest(io, "initialize", .{
        .processId = @as(?u32, null),
        // Sent alongside the newer `workspaceFolders` below, not instead of it — `rootUri` is
        // LSP-legacy (pre-3.6) but plenty of servers still read it exclusively, so dropping it
        // would be a regression for those while multi-root-aware servers (clangd,
        // rust-analyzer) prefer `workspaceFolders`. Sending both is what VSCode's own client
        // does during the transition and every server we've checked tolerates it fine.
        .rootUri = root_uri,
        .workspaceFolders = &[_]struct { uri: []const u8, name: []const u8 }{
            .{ .uri = root_uri, .name = root_name },
        },
        .capabilities = .{
            .general = .{ .positionEncodings = &[_][]const u8{"utf-8"} },
            .workspace = .{ .workspaceFolders = true },
            .textDocument = .{
                .definition = .{ .linkSupport = false },
                // Minimal — no snippet/context-trigger support. zls gates completion
                // responses on this being present at all. `labelDetailsSupport` asks the
                // server to populate `CompletionItem.labelDetails` (LSP 3.17), which is where
                // a right-hand type/signature string (VSCode's own display) actually lives —
                // without declaring this, a spec-compliant server may omit it.
                .completion = .{ .completionItem = .{ .labelDetailsSupport = true } },
                .signatureHelp = Protocol.EmptyObject{},
                // Without this, zls answers hover with plain, unfenced text (`hover_supports_md`
                // defaults false — see zls's `Server.zig` `initialize` handler), which only
                // distinguishes a declaration's signature from its doc comment by a blank line.
                // That single-blank-line heuristic breaks down for a field-access hover (`a.b.c`)
                // where zls joins one section *per matching declaration* — multiple signatures
                // back to back, all separated by the exact same blank-line marker as a real
                // header/body split, so text alone can't tell them apart. Requesting markdown
                // gets every signature wrapped in its own ```zig fence (`hoverSymbolResolved`),
                // an unambiguous delimiter `drawHoverInfoContent` now parses instead.
                .hover = .{ .contentFormat = &[_][]const u8{ "markdown", "plaintext" } },
            },
        },
        // Verbatim per-server settings (rust-analyzer's config, gopls's `"gopls"` dict, …) —
        // most servers treat an absent/null value here as "use defaults", so this is safe to
        // send as `null` for servers (like zls) that don't need it.
        .initializationOptions = self.config.initialization_options orelse .null,
    });
    const body = self.waitForSlot(io, req.id, req.slot, initialize_timeout_ms) orelse {
        return error.InitializeTimeout;
    };
    defer gpa.free(body);

    var parsed = try std.json.parseFromSlice(std.json.Value, gpa, body, .{});
    defer parsed.deinit();
    const resp = Protocol.parseResponse(parsed.value);
    if (resp.result) |result| {
        if (jsonObject(result, "capabilities")) |caps| {
            if (jsonString(caps, "positionEncoding")) |enc| {
                if (std.mem.eql(u8, enc, "utf-8")) self.encoding = .utf8;
            }
            if (jsonObject(caps, "completionProvider")) |cp| {
                if (jsonGet(cp, "resolveProvider")) |rp| {
                    self.completion_resolve_supported = switch (rp) {
                        .bool => |b| b,
                        else => false,
                    };
                }
            }
        }
    }

    try self.sendNotification(io, "initialized", Protocol.EmptyObject{});

    try self.tasks.concurrent(io, dispatchThreadMain, .{ self, io });
}

fn shutdownProcess(self: *Client) void {
    if (self.state.load(.acquire) == .not_started) return;
    const gpa = self.config.allocator;
    const io = dvui.io;

    self.shutdown.store(true, .release);
    if (self.child) |*c| c.kill(io);

    // Waits for every task in the group — `startupThreadMain` included, not just the three
    // loop threads it starts partway through. The old per-thread `?std.Thread` fields could
    // only ever join threads that had *already* been spawned by the time shutdown ran; if
    // shutdown landed while still mid-`spawnProcess`/mid-handshake (state `.starting`, reader/
    // stderr/dispatch not started yet), the detached startup thread was never waited on at
    // all — a real use-after-free risk if it kept running past `self`'s lifetime. `Io.Group`
    // tracks the whole family as one unit, so this now genuinely blocks until nothing is left
    // touching `self`, regardless of which stage shutdown catches it at. `shutdown`/`child.kill`
    // above are what actually make each loop thread notice and exit promptly — `await` here is
    // purely the join, not the cancellation signal.
    self.tasks.await(io) catch {};

    self.child = null;
    self.shutdown.store(false, .release);

    self.hover_cache_lock.lock();
    var hc_it = self.hover_cache.iterator();
    while (hc_it.next()) |e| {
        if (e.value_ptr.text) |t| gpa.free(t);
    }
    self.hover_cache.clearAndFree(gpa);
    self.in_flight.clearAndFree(gpa);
    self.hover_cache_lock.unlock();

    self.completion_cache_lock.lock();
    var cc_it = self.completion_cache.iterator();
    while (cc_it.next()) |e| {
        if (e.value_ptr.items) |items| {
            for (items) |it| {
                gpa.free(it.item.label);
                gpa.free(it.item.insert_text);
                gpa.free(it.item.detail);
                gpa.free(it.item.documentation);
                gpa.free(it.raw_json);
            }
            gpa.free(items);
        }
    }
    self.completion_cache.clearAndFree(gpa);
    self.completion_in_flight.clearAndFree(gpa);
    self.completion_cache_lock.unlock();

    self.completion_pending_lock.lock();
    if (self.completion_pending) |pending| {
        gpa.free(pending.path);
        gpa.free(pending.bytes);
        self.completion_pending = null;
    }
    self.completion_pending_lock.unlock();

    self.resolve_cache_lock.lock();
    var rc_it = self.resolve_cache.iterator();
    while (rc_it.next()) |e| {
        if (e.value_ptr.documentation) |d| gpa.free(d);
    }
    self.resolve_cache.clearAndFree(gpa);
    self.resolve_in_flight.clearAndFree(gpa);
    self.resolve_cache_lock.unlock();

    self.resolve_queue_lock.lock();
    for (self.resolve_queue.items) |rj| gpa.free(rj.raw_item_json);
    self.resolve_queue.clearAndFree(gpa);
    self.resolve_queue_lock.unlock();

    self.open_docs_lock.lock();
    var od_it = self.open_docs.iterator();
    while (od_it.next()) |e| gpa.free(e.key_ptr.*);
    self.open_docs.clearAndFree(gpa);
    self.open_docs_lock.unlock();

    self.queue_lock.lock();
    for (self.queue.items) |j| {
        gpa.free(j.path);
        gpa.free(j.bytes);
    }
    self.queue.clearAndFree(gpa);
    self.queue_lock.unlock();

    self.response_map_lock.lock();
    self.response_map.clearAndFree(gpa);
    self.response_map_lock.unlock();

    self.encoding = .utf16;
    self.state.store(.not_started, .release);
}

fn clearInFlight(self: *Client, key: CacheKey) void {
    self.hover_cache_lock.lock();
    _ = self.in_flight.remove(key);
    self.hover_cache_lock.unlock();
}

fn clearCompletionInFlight(self: *Client, key: CacheKey) void {
    self.completion_cache_lock.lock();
    _ = self.completion_in_flight.remove(key);
    self.completion_cache_lock.unlock();
}

fn clearSignatureHelpInFlight(self: *Client, key: CacheKey) void {
    self.signature_help_cache_lock.lock();
    _ = self.signature_help_in_flight.remove(key);
    self.signature_help_cache_lock.unlock();
}

fn clearResolveInFlight(self: *Client, key: ResolveKey) void {
    self.resolve_cache_lock.lock();
    _ = self.resolve_in_flight.remove(key);
    self.resolve_cache_lock.unlock();
}

/// Returns the pending completion request once it's aged past `completion_debounce_ms` with
/// nothing newer superseding it, marking its key in-flight so `completion()` won't re-queue
/// it while it's being sent. Non-blocking — returns null immediately otherwise, so hover jobs
/// queued while a completion request is still debouncing aren't starved by this waiting on
/// the dispatch thread.
fn claimDebouncedCompletion(self: *Client, io: std.Io) ?PendingCompletion {
    self.completion_pending_lock.lock();
    defer self.completion_pending_lock.unlock();
    const pending = self.completion_pending orelse return null;
    if (pending.queued_at.untilNow(io).raw.toMilliseconds() < completion_debounce_ms) return null;
    self.completion_pending = null;

    self.completion_cache_lock.lock();
    self.completion_in_flight.put(self.config.allocator, pending.key, {}) catch {};
    self.completion_cache_lock.unlock();

    return pending;
}

/// Same shape/rationale as `claimDebouncedCompletion`, for signature help.
fn claimDebouncedSignatureHelp(self: *Client, io: std.Io) ?PendingSignatureHelp {
    self.signature_help_pending_lock.lock();
    defer self.signature_help_pending_lock.unlock();
    const pending = self.signature_help_pending orelse return null;
    if (pending.queued_at.untilNow(io).raw.toMilliseconds() < signature_help_debounce_ms) return null;
    self.signature_help_pending = null;

    self.signature_help_cache_lock.lock();
    self.signature_help_in_flight.put(self.config.allocator, pending.key, {}) catch {};
    self.signature_help_cache_lock.unlock();

    return pending;
}

// ---- background threads -----------------------------------------------------------------

fn readerThreadMain(self: *Client, io: std.Io) void {
    const gpa = self.config.allocator;
    var buf: [1 << 16]u8 = undefined;
    // `readerStreaming`, not `reader` — see the matching note in `send()`: a pipe can't
    // seek, so force streaming mode instead of relying on the positional-first fallback.
    var rdr = self.child.?.stdout.?.readerStreaming(io, &buf);
    while (!self.shutdown.load(.acquire)) {
        const body = Protocol.readMessage(gpa, &rdr.interface) catch {
            // zls exited or its stdout pipe closed — degrade to unavailable like a failed
            // spawn; no restart-on-crash for this basic implementation.
            self.state.store(.unavailable, .release);
            return;
        };
        var owned = true;
        defer if (owned) gpa.free(body);

        var parsed = std.json.parseFromSlice(std.json.Value, gpa, body, .{}) catch continue;
        defer parsed.deinit();
        const resp = Protocol.parseResponse(parsed.value);

        if (resp.method) |method| {
            if (resp.id) |req_id| {
                // A server-to-client *request* (`workspace/configuration`,
                // `client/registerCapability`, `window/workDoneProgress/create`, …) — must be
                // answered or a server that awaits the reply (rust-analyzer and gopls both do,
                // heavily, for `workspace/configuration`) can stall or degrade indefinitely.
                // Answered synchronously, right here on the reader thread: these are rare
                // (once at startup, or per-setting-change) and each reply is a single small
                // write, so blocking the read loop for it is not a real throughput concern.
                self.handleServerRequest(io, req_id, method, resp.params);
            } else if (std.mem.eql(u8, method, "window/logMessage")) {
                // zls (and most servers) route their own logging through this notification by
                // default rather than stderr — without this, the Output panel only ever sees a
                // crash or a failed spawn, never the server's actual "here's what I'm doing"
                // trail, which is exactly what's needed to tell a slow response from a stuck one.
                self.handleLogMessage(resp.params);
            }
            // Any other notification (`textDocument/publishDiagnostics`, …) — no `id` to reply
            // to and this client doesn't consume it today, so just drop it.
            continue;
        }

        const id = resp.id orelse continue; // malformed frame (neither a response nor method-bearing) — ignored

        // Look up *and* write to the slot inside the same locked section — `waitForSlot`'s
        // timeout path also removes-and-`gpa.destroy()`s under this same lock, so this closes
        // a real use-after-free race: getting the pointer, releasing the lock, and only then
        // writing to `*s` (the old order) left a window where a concurrent timeout could
        // destroy the slot in between, and this thread would write through a dangling
        // pointer. Same bug class as the cache-hit races fixed earlier, just on the request/
        // response path instead of the cache — a slow response (e.g. a large-file completion
        // request that's still in flight when the caller gives up waiting) racing a timeout
        // reproduces it.
        self.response_map_lock.lock();
        if (self.response_map.get(id)) |s| {
            s.body = body;
            owned = false;
            s.ready.store(true, .release);
        }
        self.response_map_lock.unlock();
    }
}

/// Drains zls's stderr and logs each line — otherwise a crash, bad-arg error, or protocol
/// complaint from zls is completely invisible (its exit/silence looks identical to a hang).
/// Also forwarded to the shell's "Output" panel (`Host.logLine`): this plugin builds as its
/// own dylib with its own private `std.log` binding, so `dvui.log.warn` alone never reaches
/// it (see `EditorAPI.logLine`'s doc comment).
fn stderrDrainThreadMain(self: *Client, io: std.Io) void {
    const stderr_file = self.child.?.stderr orelse return;
    var buf: [4096]u8 = undefined;
    var rdr = stderr_file.readerStreaming(io, &buf);
    while (true) {
        const raw_line = rdr.interface.takeDelimiterInclusive('\n') catch break;
        const line = std.mem.trimEnd(u8, raw_line, "\n\r");
        dvui.log.warn("{s}: language server stderr: {s}", .{ self.config.language_id, line });

        var msg_buf: [4160]u8 = undefined;
        const msg = std.fmt.bufPrint(&msg_buf, "language server stderr: {s}", .{line}) catch line;
        self.config.log(self.config.language_id, .warn, msg);
    }
}

fn dispatchThreadMain(self: *Client, io: std.Io) void {
    const gpa = self.config.allocator;
    while (!self.shutdown.load(.acquire)) {
        self.checkPendingNegativeWake(io);

        self.queue_lock.lock();
        const job: ?HoverJob = if (self.queue.items.len > 0) self.queue.orderedRemove(0) else null;
        self.queue_lock.unlock();

        if (job) |j| {
            defer gpa.free(j.path);
            defer gpa.free(j.bytes);
            defer self.clearInFlight(j.key);
            // Unconditional, regardless of how the job ended (cached success — already
            // refreshes itself via `cacheHoverResult`, so this is a harmless extra wakeup —
            // timeout, or a thrown error partway through). The per-branch `host.refresh()` calls
            // inside `runHoverJob` only cover the timeout path explicitly; a thrown error (bad
            // JSON, an alloc failure, anything else caught below) used to leave `in_flight`
            // cleared but the UI thread asleep, so the placeholder never got another chance to
            // retry — exactly the same "stuck until an unrelated redraw" symptom the timeout
            // fix targeted, just via a different exit path.
            defer self.config.refresh();
            self.runHoverJob(io, j) catch |err| {
                dvui.log.warn("{s}: runHoverJob failed: {any}", .{ self.config.language_id, err });
            };
            continue;
        }

        if (self.claimDebouncedCompletion(io)) |pc| {
            defer gpa.free(pc.path);
            defer gpa.free(pc.bytes);
            defer self.clearCompletionInFlight(pc.key);
            defer self.config.refresh();
            self.runCompletionJob(io, pc) catch |err| {
                dvui.log.warn("{s}: runCompletionJob failed: {any}", .{ self.config.language_id, err });
            };
            continue;
        }

        if (self.claimDebouncedSignatureHelp(io)) |ps| {
            defer gpa.free(ps.path);
            defer gpa.free(ps.bytes);
            defer self.clearSignatureHelpInFlight(ps.key);
            defer self.config.refresh();
            self.runSignatureHelpJob(io, ps) catch |err| {
                dvui.log.warn("{s}: runSignatureHelpJob failed: {any}", .{ self.config.language_id, err });
            };
            continue;
        }

        self.resolve_queue_lock.lock();
        const rjob: ?ResolveJob = if (self.resolve_queue.items.len > 0) self.resolve_queue.orderedRemove(0) else null;
        self.resolve_queue_lock.unlock();

        if (rjob) |rj| {
            defer gpa.free(rj.raw_item_json);
            defer self.clearResolveInFlight(rj.key);
            defer self.config.refresh();
            self.runResolveJob(io, rj) catch |err| {
                dvui.log.warn("{s}: runResolveJob failed: {any}", .{ self.config.language_id, err });
            };
            continue;
        }

        io.sleep(std.Io.Duration.fromMilliseconds(20), .awake) catch {};
    }
}

fn runHoverJob(self: *Client, io: std.Io, j: HoverJob) !void {
    const gpa = self.config.allocator;
    try self.syncDocument(io, j.path, j.bytes);

    const pos = Protocol.byteOffsetToPosition(j.bytes, j.byte_offset, self.encoding);
    const uri = try UriUtil.pathToUri(gpa, j.path);
    defer gpa.free(uri);

    const req = try self.sendRequest(io, "textDocument/hover", .{
        .textDocument = .{ .uri = uri },
        .position = pos,
    });
    const body = self.waitForSlot(io, req.id, req.slot, hover_timeout_ms) orelse {
        // Deliberately not cached: no response at all is inconclusive (could be a slow
        // first parse of a huge file), unlike the definitive "no hover here" answers below.
        // `in_flight` for this key is about to be cleared by the dispatch loop's `defer`
        // (which also wakes the UI thread — see `dispatchThreadMain`), so the client is ready
        // to retry the instant something re-polls `hover()`. The eventual real response (if
        // zls answers after all, just late) has nowhere to land by then anyway: `waitForSlot`
        // already destroyed this request's slot.
        return;
    };
    defer gpa.free(body);

    var parsed = try std.json.parseFromSlice(std.json.Value, gpa, body, .{});
    defer parsed.deinit();
    const resp = Protocol.parseResponse(parsed.value);
    // A missing/null result or absent contents just means "no hover info here" (the common
    // case for most tokens) — cached as a negative entry, not logged as an error.
    const result = resp.result orelse {
        self.cacheHoverResult(io, gpa, j.key, null);
        return;
    };
    if (result == .null) {
        self.cacheHoverResult(io, gpa, j.key, null);
        return;
    }
    const contents = jsonGet(result, "contents") orelse {
        self.cacheHoverResult(io, gpa, j.key, null);
        return;
    };
    const text = extractContentsText(contents) orelse {
        self.cacheHoverResult(io, gpa, j.key, null);
        return;
    };
    const owned_text = try gpa.dupe(u8, text);
    self.cacheHoverResult(io, gpa, j.key, owned_text);
}

/// Called once per dispatch-loop tick (~20ms, regardless of GUI sleep state — see
/// `pending_negative_wake`'s doc comment). Wakes the app exactly once a pending negative
/// hover entry's TTL has elapsed, so `hover()` gets a chance to notice the expiry and retry.
/// `io` comes from the caller (`dispatchThreadMain`'s own parameter, itself captured once on
/// the draw thread in `ensureStarted`) rather than the `dvui.io` global — see `ensureStarted`'s
/// doc comment for why reading that global from a background thread is unsafe.
fn checkPendingNegativeWake(self: *Client, io: std.Io) void {
    self.hover_cache_lock.lock();
    const due = if (self.pending_negative_wake) |cached_at|
        cached_at.untilNow(io).raw.toMilliseconds() >= hover_negative_cache_ttl_ms
    else
        false;
    if (due) self.pending_negative_wake = null;
    self.hover_cache_lock.unlock();
    if (due) self.config.refresh();
}

/// Stores a hover result (or a negative `null` entry — see `CacheEntry.text`) in the cache
/// and evicts the oldest entry if it's now over `hover_cache_limit`. `owned_text`, if
/// non-null, must already be owned by `gpa` — this function takes ownership of it. `io` — see
/// `checkPendingNegativeWake`'s doc comment.
fn cacheHoverResult(self: *Client, io: std.Io, gpa: std.mem.Allocator, key: CacheKey, owned_text: ?[]u8) void {
    self.hover_cache_lock.lock();
    defer self.hover_cache_lock.unlock();
    self.cache_seq += 1;
    const cached_at: std.Io.Clock.Timestamp = .now(io, .awake);
    var confirmed_negative = false;
    if (owned_text == null) {
        if (self.unconfirmed_negative_keys.remove(key)) {
            // A negative answer already for this exact key, still awaiting its retry — this
            // is that retry, and it's negative again. Confirm it.
            confirmed_negative = true;
        } else {
            // First negative ever seen for this key — remember it so the retry (once its
            // answer lands) can tell it apart from a fresh key, and schedule the dispatch
            // thread to nudge the app awake once its TTL lapses so the retry actually happens
            // instead of the placeholder sitting forever — see `pending_negative_wake`'s doc
            // comment.
            _ = self.unconfirmed_negative_keys.put(gpa, key, {}) catch {};
            self.pending_negative_wake = cached_at;
        }
    } else {
        // A positive answer clears any stale "had one negative" memory for this key — not
        // load-bearing (a positive `CacheEntry` never even reads `confirmed_negative`), just
        // tidy: without this, an old negative could be sitting in `unconfirmed_negative_keys`
        // for a key whose next answer turned out positive, and linger there unused forever.
        _ = self.unconfirmed_negative_keys.remove(key);
    }
    self.hover_cache.put(gpa, key, .{ .text = owned_text, .seq = self.cache_seq, .cached_at = cached_at, .confirmed_negative = confirmed_negative }) catch {
        if (owned_text) |t| gpa.free(t);
        return;
    };
    self.evictOldestIfNeededLocked(gpa);
    // The mouse may have sat still since the request went out — with no other GUI event
    // pending, a redraw wouldn't otherwise happen until something unrelated triggers one.
    self.config.refresh();
}

fn evictOldestIfNeededLocked(self: *Client, gpa: std.mem.Allocator) void {
    if (self.hover_cache.count() <= hover_cache_limit) return;
    var oldest_key: ?CacheKey = null;
    var oldest_seq: u64 = std.math.maxInt(u64);
    var it = self.hover_cache.iterator();
    while (it.next()) |e| {
        if (e.value_ptr.seq < oldest_seq) {
            oldest_seq = e.value_ptr.seq;
            oldest_key = e.key_ptr.*;
        }
    }
    if (oldest_key) |k| {
        if (self.hover_cache.fetchRemove(k)) |kv| {
            if (kv.value.text) |t| gpa.free(t);
        }
    }
}

fn runCompletionJob(self: *Client, io: std.Io, pc: PendingCompletion) !void {
    const gpa = self.config.allocator;
    try self.syncDocument(io, pc.path, pc.bytes);

    const pos = Protocol.byteOffsetToPosition(pc.bytes, pc.byte_offset, self.encoding);
    const uri = try UriUtil.pathToUri(gpa, pc.path);
    defer gpa.free(uri);

    const req = try self.sendRequest(io, "textDocument/completion", .{
        .textDocument = .{ .uri = uri },
        .position = pos,
    });
    const body = self.waitForSlot(io, req.id, req.slot, completion_timeout_ms) orelse {
        // Deliberately not cached: no response at all is inconclusive, same rationale as
        // hover's timeout case. The dispatch loop's `defer` wakes the UI thread regardless of
        // how this job ends — see `dispatchThreadMain`.
        return;
    };
    defer gpa.free(body);

    var parsed = try std.json.parseFromSlice(std.json.Value, gpa, body, .{});
    defer parsed.deinit();
    const resp = Protocol.parseResponse(parsed.value);
    // A missing/null result or one with no usable item just means "nothing to suggest here"
    // (the common case for most cursor positions) — cached as a negative entry.
    const result = resp.result orelse {
        self.cacheCompletionResult(gpa, pc.key, null);
        return;
    };
    if (result == .null) {
        self.cacheCompletionResult(gpa, pc.key, null);
        return;
    }

    const raw_items = allCompletionItems(result);
    if (raw_items.len == 0) {
        self.cacheCompletionResult(gpa, pc.key, null);
        return;
    }

    // Resolve every candidate (up to `completion_max_items`), skipping — not aborting on —
    // any that fail to reduce to this SDK's ghost-text-compatible shape (see
    // `resolveCompletionItem`). zls returns items already ranked, so a straight preselect-
    // first-else-server-order pass is all the sorting this needs. Each candidate also keeps
    // its own original JSON, serialized back to text — see `CachedCompletionItem`'s doc
    // comment for why — needed later if `resolveCompletionDocumentation` asks zls to fill in
    // the `documentation` this initial response left empty (zls's usual lazy-load convention).
    var resolved: std.ArrayListUnmanaged(CachedCompletionItem) = .empty;
    defer resolved.deinit(gpa);
    errdefer for (resolved.items) |c| {
        gpa.free(c.item.label);
        gpa.free(c.item.insert_text);
        gpa.free(c.item.detail);
        gpa.free(c.item.documentation);
        gpa.free(c.raw_json);
    };

    // Diagnostic only — captures the first candidate `resolveCompletionItem` rejects, so a
    // "completions silently vanished" report can be told apart from "zls sent nothing" (the
    // `raw_items.len == 0` branch above) without needing a debugger. See its use below.
    var first_dropped_label: []const u8 = "";

    for (raw_items) |item_obj| {
        if (resolved.items.len >= completion_max_items) break;
        const r = resolveCompletionItem(item_obj, pc.bytes, pc.byte_offset) orelse {
            if (first_dropped_label.len == 0) first_dropped_label = jsonString(item_obj, "label") orelse "?";
            continue;
        };
        const owned_label = gpa.dupe(u8, r.label) catch continue;
        const owned_text = gpa.dupe(u8, r.insert_text) catch {
            gpa.free(owned_label);
            continue;
        };
        const owned_detail = gpa.dupe(u8, r.detail) catch {
            gpa.free(owned_label);
            gpa.free(owned_text);
            continue;
        };
        const owned_documentation = gpa.dupe(u8, r.documentation) catch {
            gpa.free(owned_label);
            gpa.free(owned_text);
            gpa.free(owned_detail);
            continue;
        };
        const raw_json = std.json.Stringify.valueAlloc(gpa, item_obj, .{}) catch {
            gpa.free(owned_label);
            gpa.free(owned_text);
            gpa.free(owned_detail);
            gpa.free(owned_documentation);
            continue;
        };
        resolved.append(gpa, .{
            .item = .{
                .label = owned_label,
                .insert_text = owned_text,
                .replace_start = r.replace_start,
                .replace_end = r.replace_end,
                .kind = r.kind,
                .detail = owned_detail,
                .documentation = owned_documentation,
            },
            .raw_json = raw_json,
        }) catch {
            gpa.free(owned_label);
            gpa.free(owned_text);
            gpa.free(owned_detail);
            gpa.free(owned_documentation);
            gpa.free(raw_json);
            continue;
        };
    }

    if (resolved.items.len == 0) {
        var msg_buf: [256]u8 = undefined;
        const msg = std.fmt.bufPrint(
            &msg_buf,
            "completion: zls returned {d} candidate(s) (e.g. \"{s}\") but none survived resolveCompletionItem",
            .{ raw_items.len, first_dropped_label },
        ) catch "completion: zls candidates were all filtered out";
        self.config.log(self.config.language_id, .debug, msg);
        self.cacheCompletionResult(gpa, pc.key, null);
        return;
    }

    const owned_items = resolved.toOwnedSlice(gpa) catch {
        for (resolved.items) |c| {
            gpa.free(c.item.label);
            gpa.free(c.item.insert_text);
            gpa.free(c.item.detail);
            gpa.free(c.item.documentation);
            gpa.free(c.raw_json);
        }
        self.cacheCompletionResult(gpa, pc.key, null);
        return;
    };
    self.cacheCompletionResult(gpa, pc.key, owned_items);
}

/// Stores a completion result (or a negative `null` entry — see `CompletionCacheEntry.items`)
/// in the cache and evicts the oldest entry if it's now over `completion_cache_limit`.
/// `owned_items`, if non-null, must already be owned by `gpa` (the slice and every owned field
/// inside each entry, `raw_json` included) — this function takes ownership.
fn cacheCompletionResult(self: *Client, gpa: std.mem.Allocator, key: CacheKey, owned_items: ?[]CachedCompletionItem) void {
    self.completion_cache_lock.lock();
    defer self.completion_cache_lock.unlock();
    self.completion_cache_seq += 1;
    self.completion_cache.put(gpa, key, .{ .items = owned_items, .seq = self.completion_cache_seq }) catch {
        if (owned_items) |items| {
            for (items) |it| {
                gpa.free(it.item.label);
                gpa.free(it.item.insert_text);
                gpa.free(it.item.detail);
                gpa.free(it.item.documentation);
                gpa.free(it.raw_json);
            }
            gpa.free(items);
        }
        return;
    };
    self.evictOldestCompletionIfNeededLocked(gpa);
    // Same rationale as `cacheHoverResult` — the debounce timer can fire well after the last
    // keystroke, with the mouse and keyboard both idle, so the dropdown needs its own kick to
    // actually appear instead of waiting for the next unrelated input event.
    self.config.refresh();
}

fn evictOldestCompletionIfNeededLocked(self: *Client, gpa: std.mem.Allocator) void {
    if (self.completion_cache.count() <= completion_cache_limit) return;
    var oldest_key: ?CacheKey = null;
    var oldest_seq: u64 = std.math.maxInt(u64);
    var it = self.completion_cache.iterator();
    while (it.next()) |e| {
        if (e.value_ptr.seq < oldest_seq) {
            oldest_seq = e.value_ptr.seq;
            oldest_key = e.key_ptr.*;
        }
    }
    if (oldest_key) |k| {
        if (self.completion_cache.fetchRemove(k)) |kv| {
            if (kv.value.items) |items| {
                for (items) |owned| {
                    gpa.free(owned.item.label);
                    gpa.free(owned.item.insert_text);
                    gpa.free(owned.item.detail);
                    gpa.free(owned.item.documentation);
                    gpa.free(owned.raw_json);
                }
                gpa.free(items);
            }
        }
        // Deliberately not cross-evicting `resolve_cache`/`resolve_in_flight` entries keyed to
        // `k` here — they're bounded by their own independent limit/eviction policy, and any
        // left pointing at a now-gone completion entry are simply never read again (a fresh
        // `completion()` call for the same position mints a new `CacheKey` via `content_hash`
        // anyway, since the document will have changed by then).
    }
}

fn runSignatureHelpJob(self: *Client, io: std.Io, ps: PendingSignatureHelp) !void {
    const gpa = self.config.allocator;
    try self.syncDocument(io, ps.path, ps.bytes);

    const pos = Protocol.byteOffsetToPosition(ps.bytes, ps.byte_offset, self.encoding);
    const uri = try UriUtil.pathToUri(gpa, ps.path);
    defer gpa.free(uri);

    const req = try self.sendRequest(io, "textDocument/signatureHelp", .{
        .textDocument = .{ .uri = uri },
        .position = pos,
    });
    const body = self.waitForSlot(io, req.id, req.slot, signature_help_timeout_ms) orelse {
        // Deliberately not cached: no response at all is inconclusive, same rationale as
        // hover's/completion's timeout case. The dispatch loop's `defer` wakes the UI thread
        // regardless of how this job ends — see `dispatchThreadMain`.
        return;
    };
    defer gpa.free(body);

    var parsed = try std.json.parseFromSlice(std.json.Value, gpa, body, .{});
    defer parsed.deinit();
    const resp = Protocol.parseResponse(parsed.value);
    // A missing/null result just means "not inside a call zls recognizes" — the common case
    // for most cursor positions — cached as a negative entry.
    const result = resp.result orelse {
        self.cacheSignatureHelpResult(gpa, ps.key, null);
        return;
    };
    if (result == .null) {
        self.cacheSignatureHelpResult(gpa, ps.key, null);
        return;
    }

    const resolved = resolveSignatureHelp(result) orelse {
        self.cacheSignatureHelpResult(gpa, ps.key, null);
        return;
    };
    const owned_label = gpa.dupe(u8, resolved.label) catch {
        self.cacheSignatureHelpResult(gpa, ps.key, null);
        return;
    };
    self.cacheSignatureHelpResult(gpa, ps.key, .{
        .label = owned_label,
        .active_param_start = resolved.active_param_start,
        .active_param_end = resolved.active_param_end,
    });
}

/// Stores a signature help result (or a negative `null` entry — see
/// `SignatureHelpCacheEntry.result`) in the cache and evicts the oldest entry if it's now over
/// `signature_help_cache_limit`. `owned_result`, if non-null, must already have a gpa-owned
/// `label` — this function takes ownership.
fn cacheSignatureHelpResult(self: *Client, gpa: std.mem.Allocator, key: CacheKey, owned_result: ?SignatureHelpResult) void {
    self.signature_help_cache_lock.lock();
    defer self.signature_help_cache_lock.unlock();
    self.signature_help_cache_seq += 1;
    self.signature_help_cache.put(gpa, key, .{ .result = owned_result, .seq = self.signature_help_cache_seq }) catch {
        if (owned_result) |r| gpa.free(r.label);
        return;
    };
    self.evictOldestSignatureHelpIfNeededLocked(gpa);
    // Same rationale as `cacheCompletionResult` — the debounce timer can fire with the mouse
    // and keyboard both idle by then.
    self.config.refresh();
}

fn evictOldestSignatureHelpIfNeededLocked(self: *Client, gpa: std.mem.Allocator) void {
    if (self.signature_help_cache.count() <= signature_help_cache_limit) return;
    var oldest_key: ?CacheKey = null;
    var oldest_seq: u64 = std.math.maxInt(u64);
    var it = self.signature_help_cache.iterator();
    while (it.next()) |e| {
        if (e.value_ptr.seq < oldest_seq) {
            oldest_seq = e.value_ptr.seq;
            oldest_key = e.key_ptr.*;
        }
    }
    if (oldest_key) |k| {
        if (self.signature_help_cache.fetchRemove(k)) |kv| {
            if (kv.value.result) |r| gpa.free(r.label);
        }
    }
}

/// Sends `completionItem/resolve` with `rj.raw_item_json` (the original candidate, verbatim)
/// and caches whatever `documentation` comes back — see `resolveCompletionDocumentation`'s
/// doc comment for the whole flow this is one step of.
fn runResolveJob(self: *Client, io: std.Io, rj: ResolveJob) !void {
    const gpa = self.config.allocator;

    var item_parsed = try std.json.parseFromSlice(std.json.Value, gpa, rj.raw_item_json, .{});
    defer item_parsed.deinit();

    // `completionItem/resolve`'s params *are* the completion item itself — no wrapper object,
    // unlike every other request this client sends.
    const req = try self.sendRequest(io, "completionItem/resolve", item_parsed.value);
    const body = self.waitForSlot(io, req.id, req.slot, completion_resolve_timeout_ms) orelse {
        // Deliberately not cached: no response at all is inconclusive, same rationale as
        // hover's/completion's timeout case. The dispatch loop's `defer` wakes the UI thread
        // regardless of how this job ends — see `dispatchThreadMain`.
        return;
    };
    defer gpa.free(body);

    var parsed = try std.json.parseFromSlice(std.json.Value, gpa, body, .{});
    defer parsed.deinit();
    const resp = Protocol.parseResponse(parsed.value);
    // A missing/null result, or one with no `documentation` beyond what `completion()` already
    // had, just means zls had nothing more to add — cached as a negative entry.
    const result = resp.result orelse {
        self.cacheResolveResult(gpa, rj.key, null);
        return;
    };
    if (result == .null) {
        self.cacheResolveResult(gpa, rj.key, null);
        return;
    }
    const documentation = if (jsonGet(result, "documentation")) |doc| extractContentsText(doc) else null;
    if (documentation == null or documentation.?.len == 0) {
        self.cacheResolveResult(gpa, rj.key, null);
        return;
    }
    const owned = gpa.dupe(u8, documentation.?) catch {
        self.cacheResolveResult(gpa, rj.key, null);
        return;
    };
    self.cacheResolveResult(gpa, rj.key, owned);
}

/// Stores a resolve result (or a negative `null` entry — see `ResolveCacheEntry.documentation`)
/// in the cache and evicts the oldest entry if it's now over `resolve_cache_limit`.
/// `owned_documentation`, if non-null, must already be owned by `gpa` — this function takes
/// ownership.
fn cacheResolveResult(self: *Client, gpa: std.mem.Allocator, key: ResolveKey, owned_documentation: ?[]u8) void {
    self.resolve_cache_lock.lock();
    defer self.resolve_cache_lock.unlock();
    self.resolve_cache_seq += 1;
    self.resolve_cache.put(gpa, key, .{ .documentation = owned_documentation, .seq = self.resolve_cache_seq }) catch {
        if (owned_documentation) |d| gpa.free(d);
        return;
    };
    self.evictOldestResolveIfNeededLocked(gpa);
    // Same rationale as `cacheCompletionResult` — the dropdown's info panel needs its own kick
    // to actually show the newly-resolved text instead of waiting for unrelated input.
    self.config.refresh();
}

fn evictOldestResolveIfNeededLocked(self: *Client, gpa: std.mem.Allocator) void {
    if (self.resolve_cache.count() <= resolve_cache_limit) return;
    var oldest_key: ?ResolveKey = null;
    var oldest_seq: u64 = std.math.maxInt(u64);
    var it = self.resolve_cache.iterator();
    while (it.next()) |e| {
        if (e.value_ptr.seq < oldest_seq) {
            oldest_seq = e.value_ptr.seq;
            oldest_key = e.key_ptr.*;
        }
    }
    if (oldest_key) |k| {
        if (self.resolve_cache.fetchRemove(k)) |kv| {
            if (kv.value.documentation) |d| gpa.free(d);
        }
    }
}

/// `textDocument/completion` replies with either a bare `CompletionItem[]` or a
/// `CompletionList{isIncomplete, items}` — unwraps either shape. Any item marked `preselect:
/// true` (the language server's own "best guess") is swapped to the front in place; the rest
/// keep zls's own ranking. Mutating the parsed JSON tree's own array in place is safe here —
/// it's owned by the `std.json.Parsed` value in `runCompletionJob` and never read again after
/// that call returns.
fn allCompletionItems(result: std.json.Value) []const std.json.Value {
    const items: []const std.json.Value = switch (result) {
        .array => |arr| arr.items,
        .object => |o| blk: {
            const items_val = o.get("items") orelse return &.{};
            break :blk switch (items_val) {
                .array => |arr| arr.items,
                else => return &.{},
            };
        },
        else => return &.{},
    };
    for (items, 0..) |it, i| {
        const p = jsonGet(it, "preselect") orelse continue;
        if (p == .bool and p.bool and i != 0) {
            // Swap the first preselected item to the front — items itself is the parsed
            // JSON tree's own array (owned by the `std.json.Parsed` in `runCompletionJob`,
            // freed only after this function's caller is done with it), so mutating this
            // slice in place is safe and avoids an extra allocation.
            const mutable: []std.json.Value = @constCast(items);
            std.mem.swap(std.json.Value, &mutable[0], &mutable[i]);
            break;
        }
    }
    return items;
}

const ResolvedCompletion = struct {
    /// Full, untrimmed display text — the LSP `CompletionItem.label` field verbatim.
    label: []const u8,
    insert_text: []const u8,
    replace_start: usize,
    replace_end: usize,
    kind: CompletionKind,
    /// LSP `CompletionItem.detail`, verbatim — empty string when absent.
    detail: []const u8,
    /// LSP `CompletionItem.documentation` (`string | MarkupContent`), unwrapped the same way
    /// `extractContentsText` already unwraps a hover result's `contents` — empty when absent.
    documentation: []const u8,
};

/// Maps an LSP `CompletionItemKind` integer (1-25 per spec) onto this SDK's small
/// `CompletionKind` set. Unknown/unmapped values (including future LSP kinds this client
/// doesn't know about yet) fall back to `.other`.
fn lspCompletionKind(n: i64) CompletionKind {
    return switch (n) {
        2 => .method,
        3 => .function,
        4 => .function, // Constructor
        5 => .field,
        6 => .variable,
        7, 8, 13, 22 => .type_, // Class, Interface, Enum, Struct
        9, 19 => .module, // Module, Folder
        10 => .field, // Property
        14 => .keyword,
        20 => .constant, // EnumMember
        21 => .constant,
        else => .other,
    };
}

/// Scans backward from `byte_offset` over identifier characters to find where the current
/// partial word starts. Needed because a completion item with no `textEdit` is *not* a pure
/// insertion at the cursor — per LSP convention (mirroring how VSCode's own client behaves),
/// `insertText`/`label` there represents the *whole* word, meant to replace whatever's
/// already typed, not to be appended after it. Getting this wrong duplicated text: typing
/// `example.or` and accepting a fallback candidate literally `"or"` inserted a second `"or"`
/// at the cursor, producing `example.oror`, since a zero-length replace range at the cursor
/// treats the whole thing as new text to insert rather than a replacement for `"or"`.
fn wordStartBefore(bytes: []const u8, byte_offset: usize) usize {
    var i = byte_offset;
    while (i > 0) {
        const c = bytes[i - 1];
        // `@` is part of Zig builtin names (`@import`) — without it, typing `@im` derives
        // the already-typed prefix as just `im`, which fails to match candidates whose
        // insert text starts with `@` and drops every builtin from the list.
        if (!(std.ascii.isAlphanumeric(c) or c == '_' or c == '@')) break;
        i -= 1;
    }
    return i;
}

/// Converts one LSP `CompletionItem` JSON object into this SDK's minimal shape: prefers
/// `textEdit.newText`, falling back to `insertText` or `label` otherwise. `textEdit.range` is
/// deliberately *not* trusted for how much of the already-typed prefix to trim — zls has been
/// observed returning a zero-width range at the cursor (`start == end == byte_offset`) with
/// `newText` set to the *whole* candidate rather than just the untyped remainder, which the
/// old range-driven trim treated as "nothing to trim" and inserted unfiltered right after
/// what's already typed (typing `or`, accepting a real `or` keyword candidate, rendered as
/// `oror`). Instead, the already-typed prefix is derived independently from the buffer via
/// `wordStartBefore` and *always* trimmed, regardless of what the range claimed — a ghost-text
/// UX only ever needs a pure suffix after the cursor anyway, never a true multi-token replace.
/// Rejects the item entirely (returns null) if the derived prefix doesn't actually match the
/// start of the candidate text, rather than showing something that would read as duplicated or
/// contradictory — this same reject also keeps unrelated candidates (zls returning broader
/// in-scope symbols than what's actually been typed) out of both the ghost text and the list.
fn resolveCompletionItem(item: std.json.Value, bytes: []const u8, byte_offset: usize) ?ResolvedCompletion {
    // `label` is a mandatory LSP field, independent of whichever of the three sources below
    // ends up providing `insert_text` — used only for the dropdown's full display text, never
    // trimmed like `insert_text` is.
    const label = jsonString(item, "label") orelse return null;

    var insert_text: []const u8 = undefined;
    if (jsonObject(item, "textEdit")) |edit| {
        insert_text = jsonString(edit, "newText") orelse return null;
    } else if (jsonString(item, "insertText")) |ins| {
        insert_text = ins;
    } else {
        insert_text = label;
    }

    const word_start = wordStartBefore(bytes, byte_offset);
    if (word_start > bytes.len or byte_offset > bytes.len) return null;
    var already_typed = bytes[word_start..byte_offset];

    // zls omits the leading `@` sigil from a builtin's `newText`/`insertText` — its
    // `textEdit.range` starts just after the `@` since the server only means to replace the
    // name, not the sigil. The `@` is already in the buffer, so when the candidate text itself
    // doesn't repeat it, drop it from the derived prefix too, otherwise every builtin candidate
    // fails the startsWith check below and gets dropped (typing `@i` never suggests `@intCast`).
    if (already_typed.len > 0 and already_typed[0] == '@' and !std.mem.startsWith(u8, insert_text, "@")) {
        already_typed = already_typed[1..];
    }

    if (!std.mem.startsWith(u8, insert_text, already_typed)) return null;
    insert_text = insert_text[already_typed.len..];

    if (insert_text.len == 0) return null;
    const kind = if (jsonInt(item, "kind")) |n| lspCompletionKind(n) else .other;
    // Prefer LSP 3.17's `labelDetails` — `description` is what VSCode itself shows right-
    // aligned (typically the type, e.g. "u32"), `detail` there is more like an inline
    // signature suffix. zls (like most modern servers) populates `labelDetails` instead of
    // the legacy top-level `detail` string, which is why checking only the latter came up
    // empty despite VSCode clearly showing type info for the same server.
    const detail = blk: {
        if (jsonObject(item, "labelDetails")) |ld| {
            if (jsonString(ld, "description")) |d| break :blk d;
            if (jsonString(ld, "detail")) |d| break :blk d;
        }
        break :blk jsonString(item, "detail") orelse "";
    };
    const documentation = if (jsonGet(item, "documentation")) |doc| extractContentsText(doc) orelse "" else "";
    return .{
        .label = label,
        .insert_text = insert_text,
        .replace_start = byte_offset,
        .replace_end = byte_offset,
        .kind = kind,
        .detail = detail,
        .documentation = documentation,
    };
}

/// Converts a UTF-16 code-unit offset into `s` (assumed valid UTF-8, single-line) to a byte
/// offset. Distinct from `Protocol.positionToByteOffset`, which operates on a multi-line
/// document and is keyed to the negotiated `PositionEncoding` — LSP `ParameterInformation.label`
/// tuple offsets are always UTF-16 code units per spec, regardless of what encoding was
/// negotiated for document positions.
fn utf16OffsetToByteInString(s: []const u8, units_wanted: u32) usize {
    var units: u32 = 0;
    var byte_off: usize = 0;
    var view = std.unicode.Utf8View.initUnchecked(s);
    var it = view.iterator();
    while (units < units_wanted) {
        const cp = it.nextCodepoint() orelse break;
        units += if (cp > 0xFFFF) 2 else 1;
        byte_off = it.i;
    }
    return byte_off;
}

const ResolvedSignatureHelp = struct {
    label: []const u8,
    active_param_start: usize,
    active_param_end: usize,
};

/// Converts a `textDocument/signatureHelp` JSON result into this SDK's flattened shape:
/// resolves which signature is "active" (`activeSignature`, defaulting to the first — zig has
/// no function overloading, so servers realistically only ever return one) and locates its
/// active parameter's byte range within the label, if any. Returns null only when there's no
/// usable signature at all; a signature with no resolvable active parameter still returns
/// (with `active_param_start == active_param_end`, meaning "nothing to emphasize") rather than
/// being rejected outright — a signature with an unresolvable parameter is still worth showing.
fn resolveSignatureHelp(result: std.json.Value) ?ResolvedSignatureHelp {
    const obj = switch (result) {
        .object => result,
        else => return null,
    };
    const signatures = switch (jsonGet(obj, "signatures") orelse return null) {
        .array => |arr| arr.items,
        else => return null,
    };
    if (signatures.len == 0) return null;

    const active_sig_idx: usize = blk: {
        const n = jsonInt(obj, "activeSignature") orelse break :blk 0;
        break :blk if (n >= 0 and @as(usize, @intCast(n)) < signatures.len) @intCast(n) else 0;
    };
    const sig = signatures[active_sig_idx];
    const label = jsonString(sig, "label") orelse return null;
    const no_emphasis: ResolvedSignatureHelp = .{ .label = label, .active_param_start = 0, .active_param_end = 0 };

    // A signature's own `activeParameter` (LSP 3.16+) overrides the top-level one when present.
    const active_param_idx: ?usize = blk: {
        const n = jsonInt(sig, "activeParameter") orelse jsonInt(obj, "activeParameter") orelse break :blk null;
        break :blk if (n >= 0) @intCast(n) else null;
    };
    const param_idx = active_param_idx orelse return no_emphasis;

    const parameters = switch (jsonGet(sig, "parameters") orelse return no_emphasis) {
        .array => |arr| arr.items,
        else => return no_emphasis,
    };
    if (param_idx >= parameters.len) return no_emphasis;
    const param_label = jsonGet(parameters[param_idx], "label") orelse return no_emphasis;

    return switch (param_label) {
        .string => |s| blk: {
            const idx = std.mem.indexOf(u8, label, s) orelse break :blk no_emphasis;
            break :blk ResolvedSignatureHelp{ .label = label, .active_param_start = idx, .active_param_end = idx + s.len };
        },
        .array => |arr| blk: {
            if (arr.items.len != 2) break :blk no_emphasis;
            const start_units = switch (arr.items[0]) {
                .integer => |n| n,
                else => break :blk no_emphasis,
            };
            const end_units = switch (arr.items[1]) {
                .integer => |n| n,
                else => break :blk no_emphasis,
            };
            if (start_units < 0 or end_units < 0) break :blk no_emphasis;
            const start = utf16OffsetToByteInString(label, @intCast(start_units));
            const end = utf16OffsetToByteInString(label, @intCast(end_units));
            break :blk ResolvedSignatureHelp{ .label = label, .active_param_start = start, .active_param_end = end };
        },
        else => no_emphasis,
    };
}

const TextEditSpan = struct { start: usize, end: usize, new_text: []const u8 };

/// Applies a `textDocument/formatting` response's `TextEdit[]` to `bytes`, returning the
/// fully edited document (owned by `gpa`), or null if no edit had a parseable range. zls
/// typically returns a single edit spanning the whole file, but this applies an arbitrary set
/// correctly: edits are sorted by descending start offset and applied back-to-front, so each
/// edit's byte range (computed against the *original* `bytes`/positions) stays valid — an
/// earlier edit's insert/delete would otherwise shift every later offset.
fn applyTextEdits(gpa: std.mem.Allocator, bytes: []const u8, edits: []const std.json.Value, encoding: Protocol.PositionEncoding) ?[]u8 {
    var spans: std.ArrayListUnmanaged(TextEditSpan) = .empty;
    defer spans.deinit(gpa);

    for (edits) |edit| {
        const range = jsonObject(edit, "range") orelse continue;
        const start_pos = jsonObject(range, "start") orelse continue;
        const end_pos = jsonObject(range, "end") orelse continue;
        const new_text = jsonString(edit, "newText") orelse continue;
        const start_line = jsonInt(start_pos, "line") orelse continue;
        const start_char = jsonInt(start_pos, "character") orelse continue;
        const end_line = jsonInt(end_pos, "line") orelse continue;
        const end_char = jsonInt(end_pos, "character") orelse continue;
        if (start_line < 0 or start_char < 0 or end_line < 0 or end_char < 0) continue;

        const start = Protocol.positionToByteOffset(bytes, .{ .line = @intCast(start_line), .character = @intCast(start_char) }, encoding);
        const end = Protocol.positionToByteOffset(bytes, .{ .line = @intCast(end_line), .character = @intCast(end_char) }, encoding);
        if (end < start) continue;
        spans.append(gpa, .{ .start = start, .end = end, .new_text = new_text }) catch continue;
    }
    if (spans.items.len == 0) return null;

    std.mem.sort(TextEditSpan, spans.items, {}, struct {
        fn lessThan(_: void, a: TextEditSpan, b: TextEditSpan) bool {
            return a.start > b.start;
        }
    }.lessThan);

    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(gpa);
    out.appendSlice(gpa, bytes) catch return null;

    for (spans.items) |span| {
        const s = @min(span.start, out.items.len);
        const e = @min(span.end, out.items.len);
        if (e < s) continue;
        out.replaceRange(gpa, s, e - s, span.new_text) catch return null;
    }

    return out.toOwnedSlice(gpa) catch null;
}

// ---- document sync ------------------------------------------------------------------------

fn syncDocument(self: *Client, io: std.Io, path: []const u8, bytes: []const u8) !void {
    const gpa = self.config.allocator;
    const hash = std.hash.Wyhash.hash(0, bytes);

    var send_open = false;
    var send_change = false;
    var version: i32 = 1;

    self.open_docs_lock.lock();
    if (self.open_docs.getPtr(path)) |st| {
        if (st.last_hash != hash) {
            st.version += 1;
            st.last_hash = hash;
            version = st.version;
            send_change = true;
        }
    } else {
        const owned_path = try gpa.dupe(u8, path);
        errdefer gpa.free(owned_path);
        try self.open_docs.put(gpa, owned_path, .{ .version = 1, .last_hash = hash });
        send_open = true;
    }
    self.open_docs_lock.unlock();

    if (!send_open and !send_change) return;

    const uri = try UriUtil.pathToUri(gpa, path);
    defer gpa.free(uri);

    if (send_open) {
        try self.sendNotification(io, "textDocument/didOpen", .{
            .textDocument = .{ .uri = uri, .languageId = self.config.language_id, .version = @as(i32, 1), .text = bytes },
        });
    } else {
        try self.sendNotification(io, "textDocument/didChange", .{
            .textDocument = .{ .uri = uri, .version = version },
            .contentChanges = &[_]struct { text: []const u8 }{.{ .text = bytes }},
        });
    }
}

// ---- JSON-RPC plumbing --------------------------------------------------------------------

fn send(self: *Client, io: std.Io, value: anytype) !void {
    self.write_lock.lock();
    defer self.write_lock.unlock();
    const gpa = self.config.allocator;
    const stdin = self.child.?.stdin.?;
    var buf: [4096]u8 = undefined;
    // `writerStreaming`, not `writer` — a child process's stdin pipe cannot seek, so the
    // default positional-write-then-fallback-to-streaming path (`File.Writer.init`) forces
    // an initial positional syscall attempt that's doomed to fail on a pipe. That's meant to
    // self-heal by switching to streaming on `error.Unseekable`, but the streaming toolchain
    // used to build the app in one environment surfaced a `LockViolation` from that same
    // positional attempt instead — a mapping that doesn't otherwise exist anywhere in this
    // std lib's macOS/POSIX write path (only Windows NtWriteFile status codes produce it),
    // pointing at a version-specific bug in that fallback rather than anything in our code.
    // Requesting streaming mode up front sidesteps the whole positional attempt (and
    // whatever bug lives in its fallback) entirely — the documented recommendation in
    // `std.Io.File.Writer.initStreaming`'s doc comment for exactly this kind of file.
    var w = stdin.writerStreaming(io, &buf);
    Protocol.writeMessage(gpa, &w.interface, value) catch |err| {
        // `WriteFailed` is std.Io.Writer's generic wrapper error; the real underlying OS
        // error (if any) is stashed on the concrete File.Writer for exactly this reason.
        dvui.log.warn("{s}: send failed: {any} (underlying file-writer error: {any})", .{ self.config.language_id, err, w.err });
        return err;
    };
}

const SentRequest = struct { id: i64, slot: *ResponseSlot };

fn sendRequest(self: *Client, io: std.Io, method: []const u8, params: anytype) !SentRequest {
    const gpa = self.config.allocator;
    const id = Protocol.nextRequestId(&self.next_id);
    const slot = try gpa.create(ResponseSlot);
    slot.* = .{};

    self.response_map_lock.lock();
    try self.response_map.put(gpa, id, slot);
    self.response_map_lock.unlock();

    const Params = @TypeOf(params);
    const Msg = struct {
        jsonrpc: []const u8 = "2.0",
        id: i64,
        method: []const u8,
        params: Params,
    };
    self.send(io, Msg{ .id = id, .method = method, .params = params }) catch |err| {
        self.response_map_lock.lock();
        _ = self.response_map.remove(id);
        self.response_map_lock.unlock();
        gpa.destroy(slot);
        return err;
    };
    return .{ .id = id, .slot = slot };
}

fn sendNotification(self: *Client, io: std.Io, method: []const u8, params: anytype) !void {
    const Params = @TypeOf(params);
    const Msg = struct {
        jsonrpc: []const u8 = "2.0",
        method: []const u8,
        params: Params,
    };
    try self.send(io, Msg{ .method = method, .params = params });
}

/// Replies to a server-to-client *request* with a success `result` — the JSON-RPC response
/// shape the server is waiting on, distinct from `sendRequest` (which sends a request *we*
/// initiate) and `sendNotification` (which expects no reply at all). `id` is echoed back
/// verbatim so the server can match this reply to the request it sent.
fn sendResponse(self: *Client, io: std.Io, id: i64, result: anytype) !void {
    const Result = @TypeOf(result);
    const Msg = struct {
        jsonrpc: []const u8 = "2.0",
        id: i64,
        result: Result,
    };
    try self.send(io, Msg{ .id = id, .result = result });
}

/// Answers a server-to-client request (see `readerThreadMain`'s doc comment on why every one
/// must get a reply). `workspace/configuration` gets a real, spec-shaped answer (an array of
/// `null`s, one per requested item — "we have no client-side setting for this", which every
/// server checked so far, rust-analyzer/gopls/clangd included, treats as "use your own
/// defaults" rather than an error). Anything else this client doesn't specifically act on
/// (`client/registerCapability`, `window/workDoneProgress/create`, …) gets a generic `null`
/// success ack, which is spec-correct for a request whose result the caller simply discards.
fn handleServerRequest(self: *Client, io: std.Io, id: i64, method: []const u8, params: ?std.json.Value) void {
    if (std.mem.eql(u8, method, "workspace/configuration")) {
        const gpa = self.config.allocator;
        const count: usize = blk: {
            const p = params orelse break :blk 0;
            const items = jsonGet(p, "items") orelse break :blk 0;
            break :blk switch (items) {
                .array => |arr| arr.items.len,
                else => 0,
            };
        };
        const nulls = gpa.alloc(std.json.Value, count) catch {
            self.sendResponse(io, id, @as(?u8, null)) catch {};
            return;
        };
        defer gpa.free(nulls);
        for (nulls) |*v| v.* = .null;
        self.sendResponse(io, id, nulls) catch |err| {
            dvui.log.warn("{s}: failed to answer workspace/configuration: {any}", .{ self.config.language_id, err });
        };
        return;
    }

    self.sendResponse(io, id, @as(?u8, null)) catch |err| {
        dvui.log.warn("{s}: failed to ack {s}: {any}", .{ self.config.language_id, method, err });
    };
}

/// Forwards a `window/logMessage` notification to the Output panel at its own reported
/// severity (LSP `MessageType`: 1=Error, 2=Warning, 3=Info, 4=Log — anything else maps to
/// `.debug` rather than being dropped, since an unrecognized-but-present level is still
/// signal). Silently does nothing if `params` is missing/malformed — this is best-effort
/// diagnostics, not a protocol requirement.
fn handleLogMessage(self: *Client, params: ?std.json.Value) void {
    const p = params orelse return;
    const message = jsonString(p, "message") orelse return;
    const level: std.log.Level = switch (jsonInt(p, "type") orelse 4) {
        1 => .err,
        2 => .warn,
        3 => .info,
        else => .debug,
    };
    self.config.log(self.config.language_id, level, message);
}

/// Polls `slot.ready` until it's set or `timeout_ms` elapses. Either way, removes the slot
/// from `response_map` and frees it — the caller owns the returned body (if any).
fn waitForSlot(self: *Client, io: std.Io, id: i64, slot: *ResponseSlot, timeout_ms: u64) ?[]u8 {
    const gpa = self.config.allocator;
    var waited: u64 = 0;
    while (!slot.ready.load(.acquire)) {
        if (self.shutdown.load(.acquire) or waited >= timeout_ms) {
            self.response_map_lock.lock();
            _ = self.response_map.remove(id);
            self.response_map_lock.unlock();
            // The reader thread's get-and-write is one atomic locked section now (see its
            // comment), so it's possible it slipped in and populated the slot in the brief
            // window between this loop's last `!ready` check and this timeout branch — free
            // that body rather than leaking it, even though the caller is about to give up.
            if (slot.body) |b| gpa.free(b);
            gpa.destroy(slot);
            return null;
        }
        io.sleep(std.Io.Duration.fromMilliseconds(poll_interval_ms), .awake) catch {};
        waited += poll_interval_ms;
    }
    self.response_map_lock.lock();
    _ = self.response_map.remove(id);
    self.response_map_lock.unlock();
    const body = slot.body;
    gpa.destroy(slot);
    return body;
}

// ---- JSON helpers -------------------------------------------------------------------------

fn jsonGet(v: std.json.Value, key: []const u8) ?std.json.Value {
    return switch (v) {
        .object => |o| o.get(key),
        else => null,
    };
}
fn jsonObject(v: std.json.Value, key: []const u8) ?std.json.Value {
    const got = jsonGet(v, key) orelse return null;
    return switch (got) {
        .object => got,
        else => null,
    };
}
fn jsonString(v: std.json.Value, key: []const u8) ?[]const u8 {
    const got = jsonGet(v, key) orelse return null;
    return switch (got) {
        .string => |s| s,
        else => null,
    };
}
fn jsonInt(v: std.json.Value, key: []const u8) ?i64 {
    const got = jsonGet(v, key) orelse return null;
    return switch (got) {
        .integer => |n| n,
        else => null,
    };
}

/// `textDocument/definition` may reply with a single `Location`, a `Location[]`, or (if we
/// hadn't disabled `linkSupport`) `LocationLink[]` — we only ever request the plain-`Location`
/// shape, so this just unwraps the optional array layer.
fn firstLocationObject(result: std.json.Value) ?std.json.Value {
    return switch (result) {
        .object => result,
        .array => |arr| if (arr.items.len > 0) arr.items[0] else null,
        else => null,
    };
}

/// `Hover.contents` may be a plain string, a `MarkupContent`/`MarkedString` object with a
/// `value` field, or an array of either — walks all three shapes for the first text found.
fn extractContentsText(contents: std.json.Value) ?[]const u8 {
    return switch (contents) {
        .string => |s| s,
        .object => |o| if (o.get("value")) |v| switch (v) {
            .string => |s| s,
            else => null,
        } else null,
        .array => |arr| if (arr.items.len > 0) extractContentsText(arr.items[0]) else null,
        else => null,
    };
}
