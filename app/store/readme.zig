//! Plugin README rendering for the store.
//!
//! Fetches a plugin's `README.md` from its repository over HTTPS on a worker thread, then
//! renders it read-only via the bundled markdown plugin (`drawPreview`).
const std = @import("std");
const builtin = @import("builtin");
const dvui = @import("dvui");
const markdown = @import("markdown");
const repo_asset = @import("plugin_repo_asset.zig");

const is_wasm = builtin.target.cpu.arch == .wasm32;
const web_fetch = if (is_wasm) @import("web_fetch.zig") else struct {};

const readme_filename = "README.md";

const Status = enum(u8) { idle, fetching, ready, not_found, failed };

/// One in-flight / rendered README. Only one plugin is selected at a time, so the module keeps a
/// single `current`.
const Readme = struct {
    id: []u8,
    repo: []u8,
    /// Path within the repo to look under for `README.md` (e.g. `"plugins/workbench"` for a
    /// built-in whose source lives in a subdirectory of the fizzy monorepo). Empty means repo root.
    subpath: []u8,
    io: std.Io,
    /// Captured at select time so the worker can wake the blocked event loop when the fetch
    /// finishes (otherwise the UI stays on "Loading…" until an unrelated input event).
    window: *dvui.Window,
    status: std.atomic.Value(u8) = .init(@intFromEnum(Status.idle)),
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
        return @enumFromInt(self.status.load(.acquire));
    }
};

var current: ?Readme = null;

/// Select `id` (from its `repo` URL, optionally scoped to `subpath` within that repo) as the
/// README to show. No-op if already selected. Spawns the fetch worker on first selection of an id.
pub fn select(id: []const u8, repo: []const u8, subpath: []const u8) void {
    if (current) |*c| {
        if (std.mem.eql(u8, c.id, id)) return;
        clearCurrent();
    }

    const gpa = repo_asset.gpa();
    const id_owned = gpa.dupe(u8, id) catch return;
    const repo_owned = gpa.dupe(u8, repo) catch {
        gpa.free(id_owned);
        return;
    };
    const subpath_owned = gpa.dupe(u8, subpath) catch {
        gpa.free(id_owned);
        gpa.free(repo_owned);
        return;
    };

    current = .{
        .id = id_owned,
        .repo = repo_owned,
        .subpath = subpath_owned,
        .io = dvui.io,
        .window = dvui.currentWindow(),
    };
    const self = &current.?;
    self.status.store(@intFromEnum(Status.fetching), .release);
    if (comptime is_wasm) {
        fillWasmCandidates(self);
        return;
    }
    self.thread = std.Thread.spawn(.{}, worker, .{self}) catch {
        self.status.store(@intFromEnum(Status.failed), .release);
        return;
    };
}

/// The id currently selected (or null). Lets the store highlight the active card.
pub fn selectedId() ?[]const u8 {
    return if (current) |*c| c.id else null;
}

pub fn deinit() void {
    clearCurrent();
    // Joins the markdown engine's remote-image fetch threads. Fizzy links its *own* copy of the
    // markdown module for this pane (the plugin's dylib copy has separate globals and is torn
    // down by the plugin's own `deinit`), so this copy has no plugin lifecycle to ride on.
    markdown.deinitShared();
}

/// Drop the current selection (e.g. the store "back" button).
pub fn clear() void {
    clearCurrent();
}

fn clearCurrent() void {
    const gpa = repo_asset.gpa();
    if (current) |*c| {
        if (comptime !is_wasm) {
            if (c.thread) |t| {
                t.join();
                c.thread = null;
            }
        }
        c.preview.deinit();
        if (c.bytes) |b| gpa.free(b);
        if (c.image_base) |b| gpa.free(b);
        for (c.wasm_urls[0..c.wasm_url_len]) |u| gpa.free(u);
        gpa.free(c.id);
        gpa.free(c.repo);
        gpa.free(c.subpath);
    }
    current = null;
}

/// Advance the in-flight README GET. Wasm only; native is a no-op (the worker does this).
pub fn pump() void {
    if (comptime !is_wasm) return;
    const c = if (current) |*cur| cur else return;
    if (c.statusValue() != .fetching) return;
    if (c.wasm_url_i >= c.wasm_url_len) {
        c.status.store(@intFromEnum(Status.not_found), .release);
        return;
    }
    switch (web_fetch.request(repo_asset.gpa(), c.wasm_urls[c.wasm_url_i])) {
        .pending => {},
        .failed => {
            c.wasm_url_i += 1;
            if (c.wasm_url_i >= c.wasm_url_len)
                c.status.store(@intFromEnum(Status.not_found), .release);
        },
        .ready => |body| {
            const gpa = repo_asset.gpa();
            c.bytes = gpa.dupe(u8, body) catch {
                c.status.store(@intFromEnum(Status.failed), .release);
                return;
            };
            c.image_base = gpa.dupe(u8, c.wasm_urls[c.wasm_url_i]) catch null;
            c.status.store(@intFromEnum(Status.ready), .release);
        },
    }
}

fn fillWasmCandidates(self: *Readme) void {
    var url_buf: [3][256]u8 = undefined;
    const candidates = repo_asset.rawGithubUrls(&url_buf, self.repo, self.subpath, readme_filename) orelse {
        self.status.store(@intFromEnum(Status.not_found), .release);
        return;
    };
    const gpa = repo_asset.gpa();
    var n: usize = 0;
    for (candidates.slice()) |url| {
        self.wasm_urls[n] = gpa.dupe(u8, url) catch break;
        n += 1;
    }
    self.wasm_url_len = n;
    if (n == 0) self.status.store(@intFromEnum(Status.not_found), .release);
}

/// Render the current selection's README into the current dvui parent. Shows placeholder text
/// while fetching / on failure. Safe to call every frame.
pub fn draw() void {
    pump();
    const c = if (current) |*cur| cur else {
        dvui.labelNoFmt(@src(), "Select a plugin to read its README.", .{}, .{
            .expand = .both,
            .gravity_x = 0.5,
            .gravity_y = 0.5,
            .color_text = .{ .color = dvui.themeGet().color(.window, .text).opacity(0.7) },
        });
        return;
    };

    switch (c.statusValue()) {
        .idle, .fetching => dvui.labelNoFmt(@src(), "Loading README…", .{}, .{
            .expand = .both,
            .gravity_x = 0.5,
            .gravity_y = 0.5,
            .color_text = .{ .color = dvui.themeGet().color(.window, .text).opacity(0.7) },
        }),
        .not_found => dvui.labelNoFmt(@src(), "No README found for this plugin.", .{}, .{
            .expand = .both,
            .gravity_x = 0.5,
            .gravity_y = 0.5,
            .color_text = .{ .color = dvui.themeGet().color(.window, .text).opacity(0.7) },
        }),
        .failed => dvui.labelNoFmt(@src(), "Could not fetch the README.", .{}, .{
            .expand = .both,
            .gravity_x = 0.5,
            .gravity_y = 0.5,
            .color_text = .{ .color = dvui.themeGet().color(.err, .text).opacity(0.85) },
        }),
        .ready => {
            const bytes = c.bytes orelse return;
            // Transparent — the store's detail page draws its own background behind this
            // (matching every other pane in the app); without this the preview's own scroll
            // area painted a visibly different `.content`-styled fill on top of it.
            markdown.drawPreview(&c.preview, bytes, repo_asset.gpa(), .{
                .io = c.io,
                .background = false,
                .image_base_dir = c.image_base orelse ".",
                .id_extra = std.hash.Wyhash.hash(0, c.id),
            });
        },
    }
}

fn worker(self: *Readme) void {
    defer dvui.refresh(self.window, @src(), null);

    const limit: std.Io.Limit = .limited(repo_asset.max_readme_bytes);

    if (self.subpath.len > 0) {
        if (repo_asset.readLocalAsset(self.io, self.subpath, readme_filename, limit)) |asset| {
            self.bytes = asset.bytes;
            self.image_base = asset.dir;
            self.status.store(@intFromEnum(Status.ready), .release);
            return;
        }
    }

    var url_buf: [3][256]u8 = undefined;
    const candidates = repo_asset.rawGithubUrls(&url_buf, self.repo, self.subpath, readme_filename) orelse {
        self.status.store(@intFromEnum(Status.not_found), .release);
        return;
    };

    for (candidates.slice()) |url| {
        if (repo_asset.fetchOk(self.io, url, limit)) |body| {
            self.bytes = body;
            // `url` lives in the worker's stack buffer — the preview needs it every frame.
            self.image_base = repo_asset.gpa().dupe(u8, url) catch null;
            self.status.store(@intFromEnum(Status.ready), .release);
            return;
        }
    }
    self.status.store(@intFromEnum(Status.not_found), .release);
}
