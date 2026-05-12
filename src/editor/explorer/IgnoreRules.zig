//! Gitignore-style patterns for the file explorer. Loaded from `.fizignore` if present,
//! otherwise `.gitignore` at the project root.

const std = @import("std");
const fizzy = @import("../../fizzy.zig");
const dvui = @import("dvui");

pub const IgnoreRules = @This();
lines: std.ArrayListUnmanaged([]const u8) = .empty,
blob: ?[]u8 = null,

pub fn deinit(self: *IgnoreRules, gpa: std.mem.Allocator) void {
    self.lines.deinit(gpa);
    if (self.blob) |b| {
        gpa.free(b);
        self.blob = null;
    }
    self.* = .{};
}

fn fileExistsAbs(path: []const u8) bool {
    const f = std.Io.Dir.cwd().openFile(dvui.io, path, .{}) catch return false;
    defer f.close(dvui.io);
    return true;
}

/// Prefer `.fizignore`, else `.gitignore`.
pub fn load(gpa: std.mem.Allocator, project_root_abs: []const u8) !IgnoreRules {
    var out: IgnoreRules = .{};
    errdefer out.deinit(gpa);

    const path_fizzy = try std.fs.path.join(gpa, &.{ project_root_abs, ".fizignore" });
    defer gpa.free(path_fizzy);
    const path_git = try std.fs.path.join(gpa, &.{ project_root_abs, ".gitignore" });
    defer gpa.free(path_git);

    const chosen: ?[]const u8 = if (fileExistsAbs(path_fizzy))
        path_fizzy
    else if (fileExistsAbs(path_git))
        path_git
    else
        null;

    const path = chosen orelse return out;

    const data = fizzy.fs.read(gpa, dvui.io, path) catch return out;
    out.blob = data;

    var i: usize = 0;
    while (i < data.len) {
        const start = i;
        while (i < data.len and data[i] != '\n') i += 1;
        var line = data[start..i];
        if (i < data.len) i += 1;
        if (line.len > 0 and line[line.len - 1] == '\r')
            line = line[0 .. line.len - 1];

        const trimmed = std.mem.trim(u8, line, " \t");
        if (trimmed.len == 0) continue;
        if (trimmed[0] == '#') continue;
        if (trimmed[0] == '!') continue;

        try out.lines.append(gpa, trimmed);
    }

    return out;
}

pub fn isIgnored(self: *const IgnoreRules, project_root_abs: []const u8, abs_path: []const u8, entry_name: []const u8, kind: std.Io.File.Kind) bool {
    if (self.lines.items.len == 0) return false;

    const rel_unix = relPathUnix(project_root_abs, abs_path);
    for (self.lines.items) |pattern| {
        if (matchesPattern(pattern, rel_unix, entry_name, kind))
            return true;
    }
    return false;
}

fn relPathUnix(project_root_abs: []const u8, abs_path: []const u8) []const u8 {
    if (project_root_abs.len == 0) return abs_path;
    if (!std.mem.startsWith(u8, abs_path, project_root_abs)) return abs_path;
    var r = abs_path[project_root_abs.len..];
    if (r.len > 0 and (r[0] == '/' or r[0] == std.fs.path.sep_windows))
        r = r[1..];
    return r;
}

fn matchesPattern(pat_in: []const u8, rel_unix: []const u8, entry_name: []const u8, kind: std.Io.File.Kind) bool {
    var pat = pat_in;

    var directory_only = false;
    if (pat.len > 0 and pat[pat.len - 1] == '/') {
        directory_only = true;
        pat = pat[0 .. pat.len - 1];
    }
    if (pat.len == 0) return false;

    if (directory_only and kind != .directory)
        return false;

    const anchored = pat[0] == '/';
    if (anchored)
        pat = pat[1..];

    const has_star = std.mem.indexOfScalar(u8, pat, '*') != null;
    if (has_star) {
        if (anchored) {
            return globMatch(rel_unix, pat);
        }
        if (std.mem.indexOfScalar(u8, pat, '/') == null) {
            return globMatch(entry_name, pat);
        }
        return globMatch(rel_unix, pat);
    }

    if (anchored) {
        if (directory_only) {
            if (kind != .directory) return false;
            return std.mem.eql(u8, rel_unix, pat) or anchoredDirDescendant(rel_unix, pat);
        }
        return std.mem.eql(u8, rel_unix, pat) or anchoredDescendant(rel_unix, pat);
    }

    if (std.mem.eql(u8, entry_name, pat)) return true;
    if (std.mem.eql(u8, rel_unix, pat)) return true;
    if (segmentEquals(rel_unix, pat)) return true;
    return false;
}

fn anchoredDescendant(rel: []const u8, pat: []const u8) bool {
    if (rel.len < pat.len) return false;
    if (!std.mem.startsWith(u8, rel, pat)) return false;
    if (rel.len == pat.len) return true;
    return rel[pat.len] == '/';
}

fn anchoredDirDescendant(rel: []const u8, pat: []const u8) bool {
    return anchoredDescendant(rel, pat);
}

fn segmentEquals(rel: []const u8, pat: []const u8) bool {
    var it = std.mem.splitScalar(u8, rel, '/');
    while (it.next()) |seg| {
        if (std.mem.eql(u8, seg, pat)) return true;
    }
    return false;
}

fn globMatch(s: []const u8, p: []const u8) bool {
    return globMatchRec(s, p);
}

fn globMatchRec(s: []const u8, p: []const u8) bool {
    if (p.len == 0) return s.len == 0;
    if (p[0] == '*') {
        var i: usize = 0;
        while (i <= s.len) : (i += 1) {
            if (globMatchRec(s[i..], p[1..])) return true;
        }
        return false;
    }
    if (s.len == 0) return false;
    if (p[0] == s[0]) return globMatchRec(s[1..], p[1..]);
    return false;
}
