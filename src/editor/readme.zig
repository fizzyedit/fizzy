//! Plugin README rendering for the store.
//!
//! Fetches a plugin's `README.md` from its repository over HTTPS on a worker thread, then
//! renders it read-only via the in-tree markdown render library (`src/markdown`). There is no
//! document/plugin detour — the store calls `select()` when a plugin is chosen and `draw()`
//! each frame to paint the current selection's README.
//!
//! Native-only: the markdown engine links cmark (needs libc) and the store itself never runs on
//! wasm, so this whole module is gated out of the web build at the import site in the store.
const std = @import("std");
const dvui = @import("dvui");
const fizzy = @import("../fizzy.zig");
const markdown = @import("markdown");

const Status = enum(u8) { idle, fetching, ready, not_found, failed };

/// One in-flight / rendered README. Only one plugin is selected at a time, so the module keeps a
/// single `current`.
const Readme = struct {
    id: []u8,
    repo: []u8,
    io: std.Io,
    status: std.atomic.Value(u8) = .init(@intFromEnum(Status.idle)),
    /// Fetched README bytes (app-allocator owned). Written once by the worker before it flips
    /// `status` to `ready` with release ordering; read on the UI thread only after an acquire
    /// load sees `ready`, so no lock is needed for the bytes themselves.
    bytes: ?[]u8 = null,
    thread: ?std.Thread = null,
    preview: markdown.Preview = .{},

    fn statusValue(self: *Readme) Status {
        return @enumFromInt(self.status.load(.acquire));
    }
};

var current: ?Readme = null;

fn gpa() std.mem.Allocator {
    return fizzy.app.allocator;
}

/// Select `id` (from its `repo` URL) as the README to show. No-op if already selected. Spawns the
/// fetch worker on first selection of an id.
pub fn select(id: []const u8, repo: []const u8) void {
    if (current) |*c| {
        if (std.mem.eql(u8, c.id, id)) return;
        clearCurrent();
    }

    const id_owned = gpa().dupe(u8, id) catch return;
    const repo_owned = gpa().dupe(u8, repo) catch {
        gpa().free(id_owned);
        return;
    };

    current = .{ .id = id_owned, .repo = repo_owned, .io = dvui.io };
    const self = &current.?;
    self.status.store(@intFromEnum(Status.fetching), .release);
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
}

/// Drop the current selection (e.g. the store "back" button).
pub fn clear() void {
    clearCurrent();
}

fn clearCurrent() void {
    if (current) |*c| {
        if (c.thread) |t| {
            t.join();
            c.thread = null;
        }
        c.preview.deinit();
        if (c.bytes) |b| gpa().free(b);
        gpa().free(c.id);
        gpa().free(c.repo);
    }
    current = null;
}

/// Render the current selection's README into the current dvui parent. Shows placeholder text
/// while fetching / on failure. Safe to call every frame.
pub fn draw() void {
    const c = if (current) |*cur| cur else {
        dvui.labelNoFmt(@src(), "Select a plugin to read its README.", .{}, .{
            .expand = .both,
            .gravity_x = 0.5,
            .gravity_y = 0.5,
            .color_text = dvui.themeGet().color(.window, .text).opacity(0.7),
        });
        return;
    };

    switch (c.statusValue()) {
        .idle, .fetching => dvui.labelNoFmt(@src(), "Loading README…", .{}, .{
            .expand = .both,
            .gravity_x = 0.5,
            .gravity_y = 0.5,
            .color_text = dvui.themeGet().color(.window, .text).opacity(0.7),
        }),
        .not_found => dvui.labelNoFmt(@src(), "No README found for this plugin.", .{}, .{
            .expand = .both,
            .gravity_x = 0.5,
            .gravity_y = 0.5,
            .color_text = dvui.themeGet().color(.window, .text).opacity(0.7),
        }),
        .failed => dvui.labelNoFmt(@src(), "Could not fetch the README.", .{}, .{
            .expand = .both,
            .gravity_x = 0.5,
            .gravity_y = 0.5,
            .color_text = dvui.themeGet().color(.err, .text).opacity(0.85),
        }),
        .ready => {
            const bytes = c.bytes orelse return;
            markdown.drawPreview(&c.preview, bytes, gpa(), .{ .io = c.io });
        },
    }
}

// ---- worker -----------------------------------------------------------------

fn worker(self: *Readme) void {
    const candidates = rawReadmeUrls(self.repo) orelse {
        self.status.store(@intFromEnum(Status.not_found), .release);
        return;
    };

    var found: ?[]u8 = null;
    for (candidates.slice()) |url| {
        if (fetchOk(self.io, url)) |body| {
            found = body;
            break;
        }
    }

    if (found) |body| {
        self.bytes = body;
        self.status.store(@intFromEnum(Status.ready), .release);
    } else {
        self.status.store(@intFromEnum(Status.not_found), .release);
    }
}

/// GET `url`; return the body bytes (app-allocator owned) on HTTP 200, else null.
fn fetchOk(io: std.Io, url: []const u8) ?[]u8 {
    var client: std.http.Client = .{ .allocator = gpa(), .io = io };
    defer client.deinit();

    var body: std.Io.Writer.Allocating = .init(gpa());
    defer body.deinit();

    const result = client.fetch(.{
        .location = .{ .url = url },
        .response_writer = &body.writer,
    }) catch return null;
    if (result.status != .ok) return null;

    return gpa().dupe(u8, body.written()) catch null;
}

const UrlList = struct {
    buf: [3][]const u8 = undefined,
    len: usize = 0,
    fn slice(self: *const UrlList) []const []const u8 {
        return self.buf[0..self.len];
    }
};

var url_storage: [3][256]u8 = undefined;

/// Derive candidate raw README URLs from a GitHub repository link. Returns null for hosts we
/// can't map. Not thread-safe across selections, but only one worker runs at a time.
fn rawReadmeUrls(repo: []const u8) ?UrlList {
    var r = repo;
    // Strip scheme.
    inline for (.{ "https://", "http://" }) |p| {
        if (std.mem.startsWith(u8, r, p)) r = r[p.len..];
    }
    if (!std.mem.startsWith(u8, r, "github.com/")) return null;
    r = r["github.com/".len..];
    r = std.mem.trimEnd(u8, r, "/");
    if (std.mem.endsWith(u8, r, ".git")) r = r[0 .. r.len - 4];

    // owner/repo = first two path segments.
    var it = std.mem.splitScalar(u8, r, '/');
    const owner = it.next() orelse return null;
    const name = it.next() orelse return null;
    if (owner.len == 0 or name.len == 0) return null;

    var list: UrlList = .{};
    const refs = [_][]const u8{ "HEAD", "main", "master" };
    for (refs, 0..) |ref, i| {
        const s = std.fmt.bufPrint(
            &url_storage[i],
            "https://raw.githubusercontent.com/{s}/{s}/{s}/README.md",
            .{ owner, name, ref },
        ) catch continue;
        list.buf[list.len] = s;
        list.len += 1;
    }
    return list;
}
