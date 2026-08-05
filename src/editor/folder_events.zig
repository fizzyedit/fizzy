//! Buffering and filtering for `FolderWatcher` — the half that runs on nightwatch's thread.
//!
//! Split out and std-only on purpose. `FolderWatcher.zig` reaches `fizzy.zig` and `dvui`, so it
//! can only be exercised through a live editor; this is where the bugs would actually live (an
//! overrun on a path that doesn't fit, a filter that lets `.git` through) and it costs nothing
//! to test directly. Same reasoning as `keymap.zig` and `reveal.zig`.
//!
//! `Ring` is generic over the event enums rather than importing them: the real ones live on
//! `sdk.Plugin.PathEvent`, and `Plugin.zig` imports dvui, which would drag this file back out of
//! std-only territory and into the module whose tests never run.
const std = @import("std");

/// True when any path segment *below* `root` starts with a dot — `.git`, `.zig-cache`, `.env`.
///
/// Pure string work: no allocation, no filesystem, no host call, so it is safe to run on the
/// watcher's own thread. It is not the authoritative ignore check — fizzy's `IgnoreRules` is,
/// and that runs later on the UI thread. This exists so a `git checkout` or a build churning a
/// cache directory can't fill the ring before anyone gets to apply the real rules.
///
/// Only what is below `root` counts: a project folder may itself live under `~/.config`, which
/// is no reason to ignore every file in it.
pub fn underDotSegment(root: []const u8, path: []const u8) bool {
    if (!std.mem.startsWith(u8, path, root)) return false;
    var rest = path[root.len..];
    while (rest.len > 0) {
        while (rest.len > 0 and (rest[0] == '/' or rest[0] == '\\')) rest = rest[1..];
        if (rest.len == 0) return false;
        if (rest[0] == '.') return true;
        const next = std.mem.indexOfAny(u8, rest, "/\\") orelse return false;
        rest = rest[next..];
    }
    return false;
}

/// Fixed-capacity event buffer, filled by the watcher thread and drained by the UI thread.
///
/// Nothing here allocates, and that is the whole point: the producer runs on a thread nightwatch
/// owns, where reaching for a shared allocator is exactly what the other watcher adapters in
/// this directory are careful never to do. When the buffer fills, the overflow is *reported*
/// (`truncated`) rather than absorbed — a branch switch emits events by the tens of thousands,
/// and the useful answer for a consumer at that point is "rescan", not a longer list it still
/// has to walk.
pub fn Ring(comptime Kind: type, comptime Object: type) type {
    return struct {
        const Self = @This();

        pub const Event = struct {
            off: u32,
            len: u32,
            old_off: u32 = 0,
            old_len: u32 = 0,
            kind: Kind,
            object: Object,
        };

        /// Flat backing store for paths — one arena rather than a fixed slot per event, so a
        /// handful of deep paths can't crowd out everything else and no path length is a
        /// special case.
        paths: []u8,
        used: usize = 0,
        events: []Event,
        count: usize = 0,
        /// Something didn't fit. Sticky until `reset`.
        truncated: bool = false,

        pub fn init(paths: []u8, events: []Event) Self {
            return .{ .paths = paths, .events = events };
        }

        pub fn reset(self: *Self) void {
            self.used = 0;
            self.count = 0;
            self.truncated = false;
        }

        /// Nothing to report. Distinct from `count == 0`, which is also true for a batch whose
        /// every event was dropped — and that batch still has to go out.
        pub fn empty(self: *const Self) bool {
            return self.count == 0 and !self.truncated;
        }

        /// Append one event, or mark the buffer truncated if it won't fit. `old_path` is the
        /// pre-rename path, empty for everything else.
        pub fn push(self: *Self, path: []const u8, old_path: []const u8, kind: Kind, object: Object) void {
            if (self.count >= self.events.len or
                self.used + path.len + old_path.len > self.paths.len)
            {
                self.truncated = true;
                return;
            }
            const off: u32 = @intCast(self.used);
            @memcpy(self.paths[self.used..][0..path.len], path);
            self.used += path.len;
            const old_off: u32 = @intCast(self.used);
            @memcpy(self.paths[self.used..][0..old_path.len], old_path);
            self.used += old_path.len;

            self.events[self.count] = .{
                .off = off,
                .len = @intCast(path.len),
                .old_off = old_off,
                .old_len = @intCast(old_path.len),
                .kind = kind,
                .object = object,
            };
            self.count += 1;
        }

        pub fn pathOf(self: *const Self, e: Event) []const u8 {
            return self.paths[e.off..][0..e.len];
        }

        pub fn oldPathOf(self: *const Self, e: Event) []const u8 {
            return self.paths[e.old_off..][0..e.old_len];
        }

        pub fn slice(self: *const Self) []const Event {
            return self.events[0..self.count];
        }
    };
}

// -- tests ------------------------------------------------------------------------

const testing = std.testing;

const TestKind = enum { created, modified, deleted, renamed };
const TestObject = enum { file, dir, unknown };
const TestRing = Ring(TestKind, TestObject);

test "dot-segment reject keeps build and vcs churn out of the ring" {
    const root = "/home/u/proj";
    try testing.expect(underDotSegment(root, "/home/u/proj/.git/index"));
    try testing.expect(underDotSegment(root, "/home/u/proj/.zig-cache/o/abc/x.o"));
    try testing.expect(underDotSegment(root, "/home/u/proj/src/.hidden/f.md"));
    try testing.expect(underDotSegment(root, "/home/u/proj/.env"));

    try testing.expect(!underDotSegment(root, "/home/u/proj/README.md"));
    try testing.expect(!underDotSegment(root, "/home/u/proj/src/index/Db.zig"));
    // A dot *inside* a segment is a file extension, not a hidden entry.
    try testing.expect(!underDotSegment(root, "/home/u/proj/docs/a.b.md"));
    // The root may itself sit under a dot-directory; only what's below it is our business.
    try testing.expect(!underDotSegment("/home/u/.config/vault", "/home/u/.config/vault/note.md"));
    // Unrelated paths aren't ours to classify.
    try testing.expect(!underDotSegment(root, "/etc/passwd"));
}

test "dot-segment reject handles windows separators" {
    const root = "C:\\proj";
    try testing.expect(underDotSegment(root, "C:\\proj\\.git\\HEAD"));
    try testing.expect(!underDotSegment(root, "C:\\proj\\src\\main.zig"));
}

test "push records paths and rename pairs" {
    var paths: [64]u8 = undefined;
    var events: [4]TestRing.Event = undefined;
    var r = TestRing.init(&paths, &events);

    r.push("/a/one.md", "", .created, .file);
    r.push("/a/new.md", "/a/old.md", .renamed, .file);

    try testing.expectEqual(@as(usize, 2), r.count);
    try testing.expect(!r.truncated);

    const list = r.slice();
    try testing.expectEqualStrings("/a/one.md", r.pathOf(list[0]));
    try testing.expectEqualStrings("", r.oldPathOf(list[0]));
    try testing.expectEqualStrings("/a/new.md", r.pathOf(list[1]));
    try testing.expectEqualStrings("/a/old.md", r.oldPathOf(list[1]));
    try testing.expectEqual(TestKind.renamed, list[1].kind);
}

test "running out of event slots truncates without corrupting what fit" {
    var paths: [1024]u8 = undefined;
    var events: [2]TestRing.Event = undefined;
    var r = TestRing.init(&paths, &events);

    r.push("/a", "", .created, .file);
    r.push("/b", "", .created, .file);
    r.push("/c", "", .created, .file);

    try testing.expectEqual(@as(usize, 2), r.count);
    try testing.expect(r.truncated);
    // Truncation drops the tail; it never overwrites what was already recorded.
    try testing.expectEqualStrings("/a", r.pathOf(r.slice()[0]));
    try testing.expectEqualStrings("/b", r.pathOf(r.slice()[1]));
}

test "a path too long for the arena truncates rather than overruns" {
    var paths: [8]u8 = undefined;
    var events: [4]TestRing.Event = undefined;
    var r = TestRing.init(&paths, &events);

    r.push("/short", "", .created, .file);
    r.push("/a/much/longer/path.md", "", .created, .file);

    try testing.expectEqual(@as(usize, 1), r.count);
    try testing.expect(r.truncated);
    try testing.expectEqualStrings("/short", r.pathOf(r.slice()[0]));
}

test "a rename's two halves are counted together against the arena" {
    // The pair is stored back to back, so capacity has to account for both or the second
    // memcpy walks past the end.
    var paths: [12]u8 = undefined;
    var events: [4]TestRing.Event = undefined;
    var r = TestRing.init(&paths, &events);

    r.push("/aaaaaa", "/bbbbbb", .renamed, .file);
    try testing.expectEqual(@as(usize, 0), r.count);
    try testing.expect(r.truncated);
}

test "reset clears the truncation flag along with the events" {
    var paths: [64]u8 = undefined;
    var events: [1]TestRing.Event = undefined;
    var r = TestRing.init(&paths, &events);
    r.push("/a", "", .created, .file);
    r.push("/b", "", .created, .file);
    try testing.expect(r.truncated);

    r.reset();
    try testing.expectEqual(@as(usize, 0), r.count);
    try testing.expectEqual(@as(usize, 0), r.used);
    try testing.expect(!r.truncated);
    try testing.expect(r.empty());
}

test "empty distinguishes nothing-happened from everything-was-dropped" {
    // `FolderWatcher.tick` leans on this: a batch that truncated with zero surviving events
    // still has to be broadcast, because the dropped ones are exactly what nobody got to see.
    var paths: [4]u8 = undefined;
    var events: [1]TestRing.Event = undefined;
    var r = TestRing.init(&paths, &events);
    try testing.expect(r.empty());

    r.push("/aaaaaaaaaa", "", .created, .file);
    try testing.expectEqual(@as(usize, 0), r.count);
    try testing.expect(!r.empty());
}
