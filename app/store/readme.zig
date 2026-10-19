//! Plugin README rendering for the store.
//!
//! Fetches a plugin's `README.md` from its repository over HTTPS on a worker thread, then
//! renders it read-only via the bundled markdown plugin (`drawPreview`).
//!
//! One value per README being shown: store pages are tabs, and there can be as many as the
//! user opens.
const std = @import("std");
const builtin = @import("builtin");
const dvui = @import("dvui");
const markdown = @import("markdown");
const repo_asset = @import("plugin_repo_asset.zig");

const is_wasm = builtin.target.cpu.arch == .wasm32;
const web_fetch = if (is_wasm) @import("web_fetch.zig") else struct {};

const readme_filename = "README.md";

const Status = enum(u8) { idle, fetching, ready, not_found, failed };

/// One in-flight / rendered README: start it with `init`, `draw` it every frame, `deinit` it
/// when whatever holds it goes away.
pub const Readme = struct {
    id: []u8,
    repo: []u8,
    /// Path within the repo to look under for `README.md` (e.g. `"plugins/workbench"` for a
    /// built-in whose source lives in a subdirectory of the fizzy monorepo). Empty means repo root.
    subpath: []u8,
    io: std.Io,
    /// Captured at select time so the worker can wake the blocked event loop when the fetch
    /// finishes (otherwise the UI stays on "Loading…" until an unrelated input event).
    window: *dvui.Window,
    status: std.atomic.Value(u8) = .init(@backingInt(Status.idle)),
    /// Fetched README bytes (app-allocator owned). Written once by the worker before it flips
    /// `status` to `ready` with release ordering; read on the UI thread only after an acquire
    /// load sees `ready`, so no lock is needed for the bytes themselves.
    bytes: ?[]u8 = null,
    /// Where the README was found — the dev-tree directory, or the raw URL it was fetched from.
    /// Written by the worker alongside `bytes`; the preview resolves the README's own relative
    /// images (`![shot](assets/shot.png)`) against it, which for the fetched case means pulling
    /// them from the same repo over HTTPS.
    image_base: ?[]u8 = null,
    thread: if (is_wasm) void else ?std.Thread = if (is_wasm) {} else null,
    /// Web: GitHub raw candidates we walk via `web_fetch`. Native uses the worker.
    wasm_urls: [3][]u8 = .{ &.{}, &.{}, &.{} },
    wasm_url_len: usize = 0,
    wasm_url_i: usize = 0,
    preview: markdown.Preview = .{},

    fn statusValue(self: *Readme) Status {
        return @fromBackingInt(@intCast(self.status.load(.acquire)));
    }

    /// Start fetching `id`'s README (from its `repo` URL, optionally scoped to `subpath` within
    /// that repo). Null when the strings could not be copied — the caller has no README to draw.
    pub fn init(id: []const u8, repo: []const u8, subpath: []const u8) ?Readme {
        const gpa = repo_asset.gpa();
        const id_owned = gpa.dupe(u8, id) catch return null;
        const repo_owned = gpa.dupe(u8, repo) catch {
            gpa.free(id_owned);
            return null;
        };
        const subpath_owned = gpa.dupe(u8, subpath) catch {
            gpa.free(id_owned);
            gpa.free(repo_owned);
            return null;
        };
        var self: Readme = .{
            .id = id_owned,
            .repo = repo_owned,
            .subpath = subpath_owned,
            .io = dvui.io,
            .window = dvui.currentWindow(),
        };
        self.status.store(@backingInt(Status.fetching), .release);
        return self;
    }

    /// Kick off the fetch. Separate from `init` because the worker takes a pointer to the value,
    /// which has to be at its final address first — a `Readme` returned by value and then moved
    /// into a document would hand the thread a dangling one.
    pub fn start(self: *Readme) void {
        if (comptime is_wasm) {
            fillWasmCandidates(self);
            return;
        }
        self.thread = std.Thread.spawn(.{}, worker, .{self}) catch {
            self.status.store(@backingInt(Status.failed), .release);
            return;
        };
    }

    pub fn deinit(self: *Readme) void {
        const gpa = repo_asset.gpa();
        if (comptime !is_wasm) {
            if (self.thread) |t| {
                t.join();
                self.thread = null;
            }
        }
        self.preview.deinit();
        if (self.bytes) |b| gpa.free(b);
        if (self.image_base) |b| gpa.free(b);
        for (self.wasm_urls[0..self.wasm_url_len]) |u| gpa.free(u);
        gpa.free(self.id);
        gpa.free(self.repo);
        gpa.free(self.subpath);
        self.* = undefined;
    }

    /// Advance the in-flight GET. Wasm only; native is a no-op (the worker does this).
    pub fn pump(self: *Readme) void {
        if (comptime !is_wasm) return;
        if (self.statusValue() != .fetching) return;
        if (self.wasm_url_i >= self.wasm_url_len) {
            self.status.store(@backingInt(Status.not_found), .release);
            return;
        }
        switch (web_fetch.request(repo_asset.gpa(), self.wasm_urls[self.wasm_url_i])) {
            .pending => {},
            .failed => {
                self.wasm_url_i += 1;
                if (self.wasm_url_i >= self.wasm_url_len)
                    self.status.store(@backingInt(Status.not_found), .release);
            },
            .ready => |body| {
                const gpa = repo_asset.gpa();
                self.bytes = gpa.dupe(u8, body) catch {
                    self.status.store(@backingInt(Status.failed), .release);
                    return;
                };
                self.image_base = gpa.dupe(u8, self.wasm_urls[self.wasm_url_i]) catch null;
                self.status.store(@backingInt(Status.ready), .release);
            },
        }
    }

    /// Render into the current dvui parent: placeholder text while fetching or on failure, the
    /// rendered markdown once it lands. Safe to call every frame.
    pub fn draw(self: *Readme) void {
        self.pump();
        switch (self.statusValue()) {
            .idle, .fetching => placeholder("Loading README…", false),
            .not_found => placeholder("No README found for this plugin.", false),
            .failed => placeholder("Could not fetch the README.", true),
            .ready => {
                const bytes = self.bytes orelse return;
                // Transparent — the page behind this draws its own background (matching every
                // other pane in the app); without this the preview's own scroll area painted a
                // visibly different `.content`-styled fill on top of it.
                markdown.drawPreview(&self.preview, bytes, repo_asset.gpa(), .{
                    .io = self.io,
                    .background = false,
                    .image_base_dir = self.image_base orelse ".",
                    .id_extra = std.hash.Wyhash.hash(0, self.id),
                });
            },
        }
    }
};

fn placeholder(text: []const u8, is_error: bool) void {
    const theme = dvui.themeGet();
    dvui.labelNoFmt(@src(), text, .{}, .{
        .expand = .both,
        .gravity_x = 0.5,
        .gravity_y = 0.5,
        .color_text = .{ .color = if (is_error)
            theme.color(.err, .text).opacity(0.85)
        else
            theme.color(.window, .text).opacity(0.7) },
    });
}

// ---- the markdown engine's shared teardown ---------------------------------------------------

/// Joins the markdown engine's remote-image fetch threads. Fizzy links its *own* copy of the
/// markdown module for store pages (the plugin's dylib copy has separate globals and is torn
/// down by the plugin's own `deinit`), so this copy has no plugin lifecycle to ride on.
pub fn deinit() void {
    markdown.deinitShared();
}

fn fillWasmCandidates(self: *Readme) void {
    var url_buf: [3][256]u8 = undefined;
    const candidates = repo_asset.rawGithubUrls(&url_buf, self.repo, self.subpath, readme_filename) orelse {
        self.status.store(@backingInt(Status.not_found), .release);
        return;
    };
    const gpa = repo_asset.gpa();
    var n: usize = 0;
    for (candidates.slice()) |url| {
        self.wasm_urls[n] = gpa.dupe(u8, url) catch break;
        n += 1;
    }
    self.wasm_url_len = n;
    if (n == 0) self.status.store(@backingInt(Status.not_found), .release);
}

fn worker(self: *Readme) void {
    defer dvui.refresh(self.window, @src(), null);

    const limit: std.Io.Limit = .limited(repo_asset.max_readme_bytes);

    if (self.subpath.len > 0) {
        if (repo_asset.readLocalAsset(self.io, self.subpath, readme_filename, limit)) |asset| {
            self.bytes = asset.bytes;
            self.image_base = asset.dir;
            self.status.store(@backingInt(Status.ready), .release);
            return;
        }
    }

    var url_buf: [3][256]u8 = undefined;
    const candidates = repo_asset.rawGithubUrls(&url_buf, self.repo, self.subpath, readme_filename) orelse {
        self.status.store(@backingInt(Status.not_found), .release);
        return;
    };

    for (candidates.slice()) |url| {
        if (repo_asset.fetchOk(self.io, url, limit)) |body| {
            self.bytes = body;
            // `url` lives in the worker's stack buffer — the preview needs it every frame.
            self.image_base = repo_asset.gpa().dupe(u8, url) catch null;
            self.status.store(@backingInt(Status.ready), .release);
            return;
        }
    }
    self.status.store(@backingInt(Status.not_found), .release);
}
