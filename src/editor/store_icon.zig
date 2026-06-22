//! Plugin store card icons.
//!
//! Fetches each plugin's `ICON.png` from its repository over HTTPS on a worker thread (same
//! repo/subpath convention as `readme.zig`), caches decoded `dvui.ImageSource`s by plugin id,
//! and draws them on store cards — including before the plugin is installed.
const std = @import("std");
const dvui = @import("dvui");
const core = @import("core");
const fizzy = @import("../fizzy.zig");
const repo_asset = @import("plugin_repo_asset.zig");

const icon_filename = "ICON.png";

const Status = enum(u8) { idle, fetching, ready, not_found, failed };

const IconEntry = struct {
    status: std.atomic.Value(u8) = .init(@intFromEnum(Status.idle)),
    /// Fetched PNG bytes (app-allocator owned). Written by the worker; decoded on the UI thread.
    bytes: ?[]u8 = null,
    /// Decoded once on the UI thread after `bytes` is ready.
    image: ?dvui.ImageSource = null,
    thread: ?std.Thread = null,

    fn statusValue(self: *IconEntry) Status {
        return @enumFromInt(self.status.load(.acquire));
    }

    fn deinit(self: *IconEntry) void {
        if (self.thread) |t| {
            t.join();
            self.thread = null;
        }
        if (self.bytes) |b| repo_asset.gpa().free(b);
        self.bytes = null;
        if (self.image) |img| freeImage(img);
        self.image = null;
    }
};

// Stores *pointers* to heap-allocated entries, not entries by value: a worker thread holds a
// raw `*IconEntry` for the lifetime of its fetch, and `request()` for a *different* id can grow
// the map (rehashing the backing array) at any time. If entries lived in the map by value, that
// rehash would move/invalidate the struct a still-running worker is writing into — the pointer
// stored here is stable across rehashes even though the map's own storage isn't.
var icons: std.StringHashMapUnmanaged(*IconEntry) = .empty;

fn freeImage(source: dvui.ImageSource) void {
    switch (source) {
        .pixelsPMA => |p| repo_asset.gpa().free(p.rgba),
        .pixels => |p| repo_asset.gpa().free(p.rgba),
        else => {},
    }
}

/// Begin fetching `ICON.png` for `id` from `repo` (optionally under `subpath`) if not already
/// requested. Idempotent — safe to call every frame from each store card.
pub fn request(id: []const u8, repo: []const u8, subpath: []const u8) void {
    if (repo.len == 0) return;
    const gpa = repo_asset.gpa();

    if (icons.get(id)) |entry| {
        if (entry.statusValue() != .idle) return;
    } else {
        const owned_key = gpa.dupe(u8, id) catch return;
        const new_entry = gpa.create(IconEntry) catch {
            gpa.free(owned_key);
            return;
        };
        new_entry.* = .{};
        icons.put(gpa, owned_key, new_entry) catch {
            gpa.free(owned_key);
            gpa.destroy(new_entry);
            return;
        };
    }

    const entry = icons.get(id) orelse return;
    const repo_owned = gpa.dupe(u8, repo) catch return;
    const subpath_owned = gpa.dupe(u8, subpath) catch {
        gpa.free(repo_owned);
        return;
    };

    entry.status.store(@intFromEnum(Status.fetching), .release);
    entry.thread = std.Thread.spawn(.{}, worker, .{ repo_owned, subpath_owned, entry }) catch {
        gpa.free(repo_owned);
        gpa.free(subpath_owned);
        entry.status.store(@intFromEnum(Status.failed), .release);
        return;
    };
}

/// Draw the cached icon for `id` into the current dvui parent. Returns true when an icon image
/// was drawn; false means the caller should fall back (loaded-plugin hook or generic glyph).
pub fn draw(id: []const u8) bool {
    const entry = icons.get(id) orelse return false;
    if (entry.statusValue() != .ready) return false;

    const bytes = entry.bytes orelse return false;
    if (entry.image == null) {
        entry.image = core.image.fromImageFileBytes(icon_filename, bytes, .ptr) catch null;
    }
    const source = entry.image orelse return false;

    _ = dvui.image(@src(), .{ .source = source, .shrink = .ratio }, .{
        .gravity_x = 0.5,
        .gravity_y = 0.5,
        .min_size_content = .{ .w = 32, .h = 32 },
        .max_size_content = .{ .w = 32, .h = 32 },
    });
    return true;
}

pub fn deinit() void {
    const gpa = repo_asset.gpa();
    var it = icons.iterator();
    while (it.next()) |e| {
        e.value_ptr.*.deinit();
        gpa.destroy(e.value_ptr.*);
        gpa.free(e.key_ptr.*);
    }
    icons.deinit(gpa);
}

fn worker(repo_owned: []u8, subpath_owned: []u8, entry: *IconEntry) void {
    defer repo_asset.gpa().free(repo_owned);
    defer repo_asset.gpa().free(subpath_owned);

    const io = dvui.io;
    const limit: std.Io.Limit = .limited(repo_asset.max_icon_bytes);

    if (subpath_owned.len > 0) {
        if (repo_asset.readLocalAsset(io, subpath_owned, icon_filename, limit)) |body| {
            entry.bytes = body;
            entry.status.store(@intFromEnum(Status.ready), .release);
            return;
        }
    }

    var url_buf: [3][256]u8 = undefined;
    const candidates = repo_asset.rawGithubUrls(&url_buf, repo_owned, subpath_owned, icon_filename) orelse {
        entry.status.store(@intFromEnum(Status.not_found), .release);
        return;
    };

    for (candidates.slice()) |url| {
        if (repo_asset.fetchOk(io, url, limit)) |body| {
            entry.bytes = body;
            entry.status.store(@intFromEnum(Status.ready), .release);
            return;
        }
    }
    entry.status.store(@intFromEnum(Status.not_found), .release);
}
