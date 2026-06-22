//! Shared helpers for fetching static assets (README.md, ICON.png, …) from a plugin's
//! GitHub repository over HTTPS, with a dev-tree fallback that walks up from the executable.
const std = @import("std");
const fizzy = @import("../fizzy.zig");

pub const max_readme_bytes = 512 * 1024;
pub const max_icon_bytes = 256 * 1024;

pub fn gpa() std.mem.Allocator {
    return fizzy.app.allocator;
}

/// GET `url`; return the body bytes (app-allocator owned) on HTTP 200, else null.
pub fn fetchOk(io: std.Io, url: []const u8, limit: std.Io.Limit) ?[]u8 {
    var client: std.http.Client = .{ .allocator = gpa(), .io = io };
    defer client.deinit();

    var body: std.Io.Writer.Allocating = .init(gpa());
    defer body.deinit();

    const result = client.fetch(.{
        .location = .{ .url = url },
        .response_writer = &body.writer,
    }) catch return null;
    if (result.status != .ok) return null;

    const written = body.written();
    if (limit != .unlimited and limit != .nothing and written.len > @intFromEnum(limit)) return null;
    return gpa().dupe(u8, written) catch null;
}

/// Walk up from the executable directory looking for `{subpath}/{filename}` on disk. Covers dev
/// trees (`zig-out/bin` → repo root) and sideloaded checkouts; packaged installs fall through to
/// the GitHub fetch below.
pub fn readLocalAsset(io: std.Io, subpath: []const u8, filename: []const u8, limit: std.Io.Limit) ?[]u8 {
    const trimmed = std.mem.trim(u8, subpath, "/");
    if (trimmed.len == 0) return null;

    var dir_buf: [std.fs.max_path_bytes]u8 = undefined;
    var dir_len = std.mem.sliceTo(fizzy.app.root_path, 0).len;
    if (dir_len == 0 or dir_len >= dir_buf.len) return null;
    @memcpy(dir_buf[0..dir_len], fizzy.app.root_path[0..dir_len]);

    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    var depth: u8 = 0;
    while (depth < 16) : (depth += 1) {
        const abs = std.fmt.bufPrint(
            &path_buf,
            "{s}" ++ std.fs.path.sep_str ++ "{s}" ++ std.fs.path.sep_str ++ "{s}",
            .{ dir_buf[0..dir_len], trimmed, filename },
        ) catch return null;
        if (std.Io.Dir.cwd().readFileAlloc(io, abs, gpa(), limit)) |body| {
            return body;
        } else |_| {}
        const parent = std.fs.path.dirname(dir_buf[0..dir_len]) orelse break;
        dir_len = parent.len;
    }
    return null;
}

pub const UrlList = struct {
    buf: [3][]const u8 = undefined,
    len: usize = 0,
    pub fn slice(self: *const UrlList) []const []const u8 {
        return self.buf[0..self.len];
    }
};

/// Derive candidate raw asset URLs from a GitHub repository link, optionally scoped to
/// `subpath` within that repo. Returns null for hosts we can't map. `url_storage` must be
/// owned by the caller (e.g. a stack buffer local to the calling worker thread) — README and
/// icon workers run concurrently on separate threads, so a shared/global buffer here would race.
pub fn rawGithubUrls(url_storage: *[3][256]u8, repo: []const u8, subpath: []const u8, filename: []const u8) ?UrlList {
    var r = repo;
    inline for (.{ "https://", "http://" }) |p| {
        if (std.mem.startsWith(u8, r, p)) r = r[p.len..];
    }
    if (!std.mem.startsWith(u8, r, "github.com/")) return null;
    r = r["github.com/".len..];
    r = std.mem.trimEnd(u8, r, "/");
    if (std.mem.endsWith(u8, r, ".git")) r = r[0 .. r.len - 4];

    var it = std.mem.splitScalar(u8, r, '/');
    const owner = it.next() orelse return null;
    const name = it.next() orelse return null;
    if (owner.len == 0 or name.len == 0) return null;

    const trimmed_subpath = std.mem.trim(u8, subpath, "/");

    var list: UrlList = .{};
    const refs = [_][]const u8{ "HEAD", "main", "master" };
    for (refs, 0..) |ref, i| {
        const s = if (trimmed_subpath.len > 0)
            std.fmt.bufPrint(
                &url_storage[i],
                "https://raw.githubusercontent.com/{s}/{s}/{s}/{s}/{s}",
                .{ owner, name, ref, trimmed_subpath, filename },
            ) catch continue
        else
            std.fmt.bufPrint(
                &url_storage[i],
                "https://raw.githubusercontent.com/{s}/{s}/{s}/{s}",
                .{ owner, name, ref, filename },
            ) catch continue;
        list.buf[list.len] = s;
        list.len += 1;
    }
    return list;
}
