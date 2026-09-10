//! Remote image fetching for markdown previews.
//!
//! `![alt](https://…)` and `<img src="https://…">` are the normal way READMEs carry their
//! screenshots and badges, so a preview that only reads local files renders most real-world
//! markdown with holes in it. Each distinct URL is fetched once into a process-wide cache;
//! the UI is woken with `dvui.refresh` (native) or `requestRender` (web) when it lands.
//!
//! Native uses a worker thread + `std.http.Client` and stores encoded bytes (stb decodes
//! them later). Web has neither threads nor that HTTP client — the browser loads the URL
//! instead (`new Image`, see `web/index.html`). When CORS allows it, the pixels are copied
//! into a dvui texture. When it does not — GitHub Actions badges are the usual case —
//! the browser still has the image, so the preview positions an `<img>` over the canvas
//! rather than drawing the "open" fallback link. Same ownership shape as fizzy's own
//! `store_icon.zig`: entries are heap-allocated so a worker's pointer stays valid across
//! map growth, and each worker writes only its own entry's payload before flipping
//! `status` with release ordering.
const std = @import("std");
const builtin = @import("builtin");
const dvui = @import("dvui");

const is_wasm = builtin.target.cpu.arch == .wasm32;

/// Whether this build can fetch at all. Native talks HTTP on a worker; web asks the
/// browser to load the URL (see `rasterizes_svg`). Both resolve to `.failed` when the
/// load does not land, and the preview draws its placeholder.
pub const fetch_supported = true;

/// The browser can show SVG (pixels when CORS allows, an `<img>` overlay when it
/// does not). Native cannot — dvui's `svgToTvg` mangles every real badge — so SVG
/// URLs are skipped there instead of fetched. The preview uses this to decide
/// *before* a fetch, so a `.svg` badge never becomes the "open" fallback link.
pub const rasterizes_svg = is_wasm;

pub const Status = enum(u8) { fetching, ready, failed };

/// Decoded non-premultiplied RGBA, row-major. Web-only payload: the browser already
/// rasterized, so stb never sees these bytes.
pub const Pixels = struct {
    rgba: []const u8,
    width: u32,
    height: u32,
};

/// Image the browser loaded but we cannot read (no CORS). The preview reserves
/// `width`×`height` and asks JS to park an `<img>` on top of the canvas.
pub const Overlay = struct {
    id: u32,
    width: u32,
    height: u32,
};

/// Per-image cap. Matches `render_ast.max_image_bytes` — a README image past this is a mistake.
const max_bytes: usize = 16 * 1024 * 1024;
/// Bound on how many distinct remote URLs one session will ever fetch. A pathological document
/// can't turn the preview into an unbounded download queue.
const max_entries: usize = 256;
/// Bound on fetches in flight at once, so a README with 40 badges doesn't spawn 40 threads
/// (native) or 40 `<img>` loads (web).
const max_in_flight: usize = 6;

const Entry = struct {
    id: u32 = 0,
    status: std.atomic.Value(u8) = .init(@intFromEnum(Status.fetching)),
    /// Encoded file bytes (`gpa`-owned). Native worker writes this before the release-store
    /// of `ready`. Unused on web.
    bytes: ?[]u8 = null,
    /// Browser-rasterized pixels (`gpa`-owned). Web completion writes this before `ready`.
    /// Unused on native.
    pixels: ?Pixels = null,
    /// Set when the browser loaded the image but pixels were unreadable (CORS).
    overlay: ?Overlay = null,
    /// Native worker handle. Omitted on wasm — that target is single-threaded and
    /// `std.Thread` cannot even be named there.
    thread: if (is_wasm) void else ?std.Thread = if (is_wasm) {} else null,
    url: []u8,

    fn statusValue(self: *Entry) Status {
        return @enumFromInt(self.status.load(.acquire));
    }
};

var entries: std.StringHashMapUnmanaged(*Entry) = .empty;
/// Captured from the first `request` — every entry is allocated and freed with it.
var gpa: ?std.mem.Allocator = null;
var next_id: u32 = 1;

const wasm = if (is_wasm) struct {
    /// Starts a browser load for `url`. Wired in `web/index.html` by adding a `fizzy`
    /// import namespace at instantiate time — dvui's `web.js` only provides `dvui.*`.
    extern "fizzy" fn fizzy_web_image_request(id: u32, url_ptr: [*]const u8, url_len: usize) void;
    extern "fizzy" fn fizzy_web_image_place(id: u32, x: f32, y: f32, w: f32, h: f32, cx: f32, cy: f32, cw: f32, ch: f32) void;
    extern "fizzy" fn fizzy_web_image_dismiss(id: u32) void;
    /// Marks the start of a canvas frame so JS can hide overlays this frame did not
    /// place. Idle (no frame) must not hide them — see `beginOverlayFrame`.
    extern "fizzy" fn fizzy_web_image_frame_begin() void;
} else struct {};

/// Web only. Tell JS a canvas frame is starting. Overlays that aren't `placeOverlay`'d
/// this frame hide after paint; when the app sleeps (mouse left the window) this is
/// never called, so badges stay put instead of vanishing on a wall-clock timeout.
pub fn beginOverlayFrame() void {
    if (comptime !is_wasm) return;
    wasm.fizzy_web_image_frame_begin();
}

/// Counted rather than tracked in a counter the workers would have to decrement: the map is
/// small and bounded by `max_entries`, and a UI-thread-only walk keeps this state single-owner.
fn inFlight() usize {
    var n: usize = 0;
    var it = entries.valueIterator();
    while (it.next()) |e| {
        if (e.*.statusValue() == .fetching) n += 1;
    }
    return n;
}

fn entryById(id: u32) ?*Entry {
    var it = entries.valueIterator();
    while (it.next()) |e| {
        if (e.*.id == id) return e.*;
    }
    return null;
}

/// True for a URL this module handles (everything else is a local path).
pub fn isRemote(url: []const u8) bool {
    return std.ascii.startsWithIgnoreCase(url, "http://") or std.ascii.startsWithIgnoreCase(url, "https://");
}

pub const Result = union(enum) {
    /// Fetch in progress — the caller should draw a placeholder and try again next frame.
    pending,
    /// Cached encoded bytes, valid until `deinit`. Native path.
    ready: []const u8,
    /// Cached decoded pixels, valid until `deinit`. Web path.
    ready_pixels: Pixels,
    /// Browser has the image; we cannot copy pixels. Web path.
    overlay: Overlay,
    failed,
};

/// Look up `url`, starting a fetch on first sight. UI thread only.
pub fn request(allocator: std.mem.Allocator, url: []const u8) Result {
    if (gpa == null) gpa = allocator;
    const a = gpa.?;

    if (entries.get(url)) |entry| {
        return resultOf(entry);
    }

    if (entries.count() >= max_entries or inFlight() >= max_in_flight) return .pending;

    const url_owned = a.dupe(u8, url) catch return .failed;
    const entry = a.create(Entry) catch {
        a.free(url_owned);
        return .failed;
    };
    const id = next_id;
    next_id +|= 1;
    entry.* = .{ .id = id, .url = url_owned };
    // Keyed by the entry's own copy of the URL, so the map never borrows caller memory.
    entries.put(a, url_owned, entry) catch {
        a.free(url_owned);
        a.destroy(entry);
        return .failed;
    };

    if (comptime is_wasm) {
        wasm.fizzy_web_image_request(id, url_owned.ptr, url_owned.len);
        return .pending;
    }

    const io = dvui.io;
    const win = dvui.currentWindow();
    entry.thread = std.Thread.spawn(.{}, worker, .{ entry, io, win }) catch {
        entry.status.store(@intFromEnum(Status.failed), .release);
        return .failed;
    };
    return .pending;
}

fn resultOf(entry: *Entry) Result {
    return switch (entry.statusValue()) {
        .fetching => .pending,
        .failed => .failed,
        .ready => if (entry.pixels) |p|
            .{ .ready_pixels = p }
        else if (entry.overlay) |o|
            .{ .overlay = o }
        else if (entry.bytes) |b|
            .{ .ready = b }
        else
            .failed,
    };
}

/// Join every worker and free the cache. Called from the plugin's `deinit` — a dylib must not be
/// unloaded with its own threads still running.
pub fn deinit() void {
    const a = gpa orelse {
        entries = .empty;
        return;
    };
    var it = entries.iterator();
    while (it.next()) |kv| {
        const entry = kv.value_ptr.*;
        if (comptime !is_wasm) {
            if (entry.thread) |t| t.join();
        } else {
            wasm.fizzy_web_image_dismiss(entry.id);
        }
        if (entry.bytes) |b| a.free(b);
        if (entry.pixels) |p| a.free(p.rgba);
        a.free(entry.url);
        a.destroy(entry);
    }
    entries.deinit(a);
    entries = .empty;
    gpa = null;
}

fn worker(entry: *Entry, io: std.Io, win: *dvui.Window) void {
    defer dvui.refresh(win, @src(), null);
    const a = gpa orelse {
        entry.status.store(@intFromEnum(Status.failed), .release);
        return;
    };

    var client: std.http.Client = .{ .allocator = a, .io = io };
    defer client.deinit();

    var body: std.Io.Writer.Allocating = .init(a);
    defer body.deinit();

    const result = client.fetch(.{
        .location = .{ .url = entry.url },
        .response_writer = &body.writer,
    }) catch {
        entry.status.store(@intFromEnum(Status.failed), .release);
        return;
    };
    if (result.status != .ok or body.written().len == 0 or body.written().len > max_bytes) {
        entry.status.store(@intFromEnum(Status.failed), .release);
        return;
    }

    const owned = a.dupe(u8, body.written()) catch {
        entry.status.store(@intFromEnum(Status.failed), .release);
        return;
    };
    entry.bytes = owned;
    entry.status.store(@intFromEnum(Status.ready), .release);
}

/// Allocate the pixel buffer the browser will write into. Same `gpa` as the rest of
/// the cache, so `deinit` can free it. Returns 0 on OOM — JS then calls `Failed`.
export fn FizzyWebImageAlloc(len: usize) usize {
    if (comptime !is_wasm) return 0;
    if (len == 0 or len > max_bytes) return 0;
    const a = gpa orelse return 0;
    const buf = a.alloc(u8, len) catch return 0;
    return @intFromPtr(buf.ptr);
}

/// Browser finished rasterizing `id`. `ptr`/`len` is the buffer from `FizzyWebImageAlloc`;
/// we take ownership. A stale id (deinit raced the load) frees the buffer and returns.
export fn FizzyWebImageReady(id: u32, ptr: usize, len: usize, width: u32, height: u32) void {
    if (comptime !is_wasm) return;
    const a = gpa orelse return;
    if (ptr == 0 or len == 0 or width == 0 or height == 0) {
        if (ptr != 0 and len != 0) a.free(@as([*]u8, @ptrFromInt(ptr))[0..len]);
        if (entryById(id)) |entry| entry.status.store(@intFromEnum(Status.failed), .release);
        return;
    }
    const rgba = @as([*]u8, @ptrFromInt(ptr))[0..len];
    const expected = @as(usize, width) * @as(usize, height) * 4;
    if (len != expected) {
        a.free(rgba);
        if (entryById(id)) |entry| entry.status.store(@intFromEnum(Status.failed), .release);
        return;
    }
    const entry = entryById(id) orelse {
        a.free(rgba);
        return;
    };
    if (entry.statusValue() != .fetching) {
        a.free(rgba);
        return;
    }
    entry.pixels = .{ .rgba = rgba, .width = width, .height = height };
    entry.status.store(@intFromEnum(Status.ready), .release);
}

export fn FizzyWebImageFailed(id: u32) void {
    if (comptime !is_wasm) return;
    const entry = entryById(id) orelse return;
    if (entry.statusValue() != .fetching) return;
    entry.status.store(@intFromEnum(Status.failed), .release);
}

/// Browser loaded the image but pixels were unreadable (tainted canvas). We still
/// know the intrinsic size, so the preview can reserve space and overlay an `<img>`.
export fn FizzyWebImageOverlay(id: u32, width: u32, height: u32) void {
    if (comptime !is_wasm) return;
    const entry = entryById(id) orelse return;
    if (entry.statusValue() != .fetching) return;
    // A badge SVG with no intrinsic size still needs a slot — GitHub's are ~200×20,
    // and a zero box would collapse the overlay to nothing.
    const w = if (width == 0) 200 else width;
    const h = if (height == 0) 20 else height;
    entry.overlay = .{ .id = id, .width = w, .height = h };
    entry.status.store(@intFromEnum(Status.ready), .release);
}

/// Park the browser `<img>` over `rect`, clipped to the preview pane. Coordinates
/// are physical; we convert to CSS pixels with `scale` so the overlay tracks a
/// HiDPI canvas.
pub fn placeOverlay(id: u32, rect: dvui.Rect.Physical, clip: dvui.Rect.Physical, scale: f32) void {
    if (comptime !is_wasm) return;
    if (!(scale > 0)) return;
    wasm.fizzy_web_image_place(
        id,
        rect.x / scale,
        rect.y / scale,
        rect.w / scale,
        rect.h / scale,
        clip.x / scale,
        clip.y / scale,
        clip.w / scale,
        clip.h / scale,
    );
}
