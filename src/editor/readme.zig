//! Plugin README rendering for the store.
//!
//! Fetches a plugin's `README.md` from its repository over HTTPS on a worker thread, then
//! renders it read-only via the bundled markdown plugin (`drawPreview`).
const std = @import("std");
const dvui = @import("dvui");
const fizzy = @import("../fizzy.zig");
const markdown = @import("markdown");
const repo_asset = @import("plugin_repo_asset.zig");

const readme_filename = "README.md";

const Status = enum(u8) { idle, fetching, ready, not_found, failed };

/// One in-flight / rendered README. Only one plugin is selected at a time, so the module keeps a
/// single `current`.
const Readme = struct {
    id: []u8,
    repo: []u8,
    /// Path within the repo to look under for `README.md` (e.g. `"src/plugins/workbench"` for a
    /// built-in whose source lives in a subdirectory of the fizzy monorepo). Empty means repo root.
    subpath: []u8,
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

    current = .{ .id = id_owned, .repo = repo_owned, .subpath = subpath_owned, .io = dvui.io };
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
    const gpa = repo_asset.gpa();
    if (current) |*c| {
        if (c.thread) |t| {
            t.join();
            c.thread = null;
        }
        c.preview.deinit();
        if (c.bytes) |b| gpa.free(b);
        gpa.free(c.id);
        gpa.free(c.repo);
        gpa.free(c.subpath);
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
            markdown.drawPreview(&c.preview, bytes, repo_asset.gpa(), .{ .io = c.io });
        },
    }
}

fn worker(self: *Readme) void {
    const limit: std.Io.Limit = .limited(repo_asset.max_readme_bytes);

    if (self.subpath.len > 0) {
        if (repo_asset.readLocalAsset(self.io, self.subpath, readme_filename, limit)) |body| {
            self.bytes = body;
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
            self.status.store(@intFromEnum(Status.ready), .release);
            return;
        }
    }
    self.status.store(@intFromEnum(Status.not_found), .release);
}
