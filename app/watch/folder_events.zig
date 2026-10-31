//! Buffering and filtering for `FolderWatcher` - the half that runs on nightwatch's thread -
//! and the walk that decides which folders it watches.
//!
//! Split out and std-only on purpose. `FolderWatcher.zig` reaches `fizzy.zig` and `dvui`, so it
//! can only be exercised through a live editor; this is where the bugs would actually live (an
//! overrun on a path that doesn't fit, a filter that lets `.git` through) and it costs nothing
//! to test directly. Same reasoning as `keymap.zig` and `reveal.zig`.
//!
//! `Ring` is generic over the event enums rather than importing them: the real ones live on
//! `sdk.events.PathEvent`, and the SDK imports dvui, which would drag this file back out of
//! std-only territory and into the module whose tests never run.
const std = @import("std");
const builtin = @import("builtin");

/// True when a path segment *below* `root`, on the way to `path` or `path`'s own name, is one
/// `named` picks out: `dotName` for `.git`, `.zig-cache`, `.env`; `skipWatchDir` for the folders
/// a watch leaves alone.
///
/// Pure string work: no allocation, no filesystem, no host call, so it is safe to run on the
/// watcher's own thread. With `dotName` it is not the authoritative ignore check - fizzy's
/// `IgnoreRules` is, and that runs later on the UI thread. It exists so a `git checkout` or a
/// build churning a cache directory can't fill the ring before anyone gets to apply the real
/// rules.
///
/// Only what is below `root` counts: a project folder may itself live under `~/.config`, which
/// is no reason to ignore every file in it. A path not under `root` is not ours: false.
pub fn underSegment(root: []const u8, path: []const u8, comptime named: fn ([]const u8) bool) bool {
    if (!inside(path, root)) return false;
    var it = std.mem.tokenizeAny(u8, path[root.len..], "/\\");
    while (it.next()) |seg| if (named(seg)) return true;
    return false;
}

/// True when `path` is `dir` or below it: `dir` and then a separator, not merely the same
/// first bytes (`/p` is not under `/pp`). A `dir` that ends in a separator (`/`) is its own.
pub fn inside(path: []const u8, dir: []const u8) bool {
    if (!std.mem.startsWith(u8, path, dir)) return false;
    if (path.len == dir.len or dir.len == 0) return true;
    return isSep(path[dir.len]) or isSep(dir[dir.len - 1]);
}

fn isSep(c: u8) bool {
    return c == '/' or c == '\\';
}

/// A hidden entry's name: `.git`, `.env`. A dot inside a name is an extension.
pub fn dotName(name: []const u8) bool {
    return name.len > 0 and name[0] == '.';
}

/// The most folders one open folder may watch. inotify spends a watch per directory out of a
/// per-user pool (`fs.inotify.max_user_watches`) that every other program shares; a home folder
/// would take all of it. Past this many the tree is still browsable, only no longer live.
pub const max_dir_watches: u32 = 16384;

/// Folders a watch never descends into, by name: hidden ones (`.git`, `.zig-cache`, `.venv`,
/// `.bun`) and the dependency trees a tool writes, `node_modules` and `zig-pkg`. They hold most
/// of a project's directories and none of what a person edits. Anything else a project chooses
/// to ignore (`target`, `zig-out`, ...) is still watched, and `IgnoreRules` drops its events.
pub fn skipWatchDir(name: []const u8) bool {
    if (name.len == 0 or name[0] == '.') return true;
    return std.mem.eql(u8, name, "node_modules") or std.mem.eql(u8, name, "zig-pkg");
}

/// Why watching more folders stopped for now.
pub const Blocked = enum {
    /// `max_dir_watches` are in use.
    cap,
    /// The OS has no watches left (inotify's ENOSPC: `fs.inotify.max_user_watches`).
    refused,
};

/// What `Watches` has to say, through `ctx.say`. Each is said once, not once per folder.
pub const Said = union(enum) {
    /// A limit was reached with `watched` folders watched; folders left out are watched as
    /// watches are freed.
    blocked: struct { why: Blocked, watched: usize },
    /// A folder can't be watched for a reason of its own (a permission, a mount that refuses
    /// inotify, a name too long), so it is left out.
    skipped: struct { path: []const u8, reason: []const u8 },
    /// An allocation failed: what is watched can no longer be vouched for, for this folder's
    /// session. Said once.
    degraded,
};

/// Why the backend refused to watch a folder, as `ctx.why(path)` finds out: the backend itself
/// only says it failed.
pub const Refusal = union(enum) {
    /// The OS is out of watches: no folder would fare better until some are freed.
    pool,
    /// The folder went between the open and the watch.
    gone,
    /// It can be watched now after all: try once more.
    again,
    /// That folder's own problem, named.
    own: []const u8,
};

/// What a folder is still owed in announcements (`ctx.created`) when a walk gets to it.
const Owed = enum(u2) {
    none,
    /// What its subfolders hold, not its own entries: they were said before the walk stopped.
    below,
    /// Its own entries, and everything below them.
    all,
};

/// How a walk treats the folders it meets.
const Pass = struct {
    /// The folder the walk starts at may be watched already, with children not yet seen.
    resume_top: bool = false,
    owed: Owed = .none,
    /// Go through folders already watched too, to announce what is in them.
    through_known: bool = false,
};

/// The folders watched under one root, for a backend that watches folder by folder (inotify,
/// kqueue). One thread owns it: `FolderWatcher`'s walker, which the backend's thread hands its
/// folder events to. `ctx` is the backend and its listener: `add(path) !void`, `remove(path)`,
/// `why(path) Refusal`, `say(Said)` and `created(path, is_dir)`.
///
/// It counts the watches live, so folders coming and going never use up the cap, and a folder
/// already watched is not walked again. A walk that reaches a limit stops and remembers where
/// (`frontier`); `catchUp` goes on from there, never from the root, once watches are freed or
/// (`retry`) after a while.
///
/// One rule for running out of memory, wherever it happens: the watch that can't be kept
/// track of is removed, `degraded` is set for good, and that is said once.
pub const Watches = struct {
    gpa: std.mem.Allocator,
    /// Borrowed; outlives this.
    root: []const u8,
    limit: u32 = max_dir_watches,
    /// Set when the root is being closed: a walk in flight returns at the next folder.
    cancel: *const std.atomic.Value(bool),
    /// Every folder watched, sorted, so a folder and what is below it are found by binary
    /// search. Owned.
    paths: std.ArrayList([]u8) = .empty,
    /// Watched by the walk in progress, merged into `paths` in one pass when it ends: a walk
    /// adds folders by the thousand, and inserting each into a sorted list is quadratic. Owned.
    fresh: std.ArrayList([]u8) = .empty,
    /// The limit reached, until a watch is freed or added again.
    blocked: ?Blocked = null,
    /// The limit last said, until caught up: said once per time behind, not per retry.
    said: ?Blocked = null,
    /// Where walks stopped: folders not yet watched, and watched folders whose children were
    /// not all seen, each with what it is still owed. Keys owned.
    frontier: std.array_hash_map.String(Owed) = .empty,
    /// The frontier `catchUp` is working through, so a walk that finishes a folder still on
    /// it can take it off rather than have it walked and announced again. Keys owned.
    todo: std.array_hash_map.String(Owed) = .empty,
    /// Folders left out for reasons of their own, each said once and not tried again, until
    /// it goes or moves. Keys owned.
    lost: std.StringHashMapUnmanaged(void) = .empty,
    /// An allocation failed; sticky.
    degraded: bool = false,
    /// The folder events that arrived during the root's first walk have been handled. Until
    /// then a folder that appeared may already have been watched by that walk, silently.
    settled: bool = false,

    const Watched = enum { added, skipped, blocked };

    pub fn deinit(self: *Watches) void {
        for (self.paths.items) |p| self.gpa.free(p);
        self.paths.deinit(self.gpa);
        for (self.fresh.items) |p| self.gpa.free(p);
        self.fresh.deinit(self.gpa);
        for (self.frontier.keys()) |p| self.gpa.free(p);
        self.frontier.deinit(self.gpa);
        for (self.todo.keys()) |p| self.gpa.free(p);
        self.todo.deinit(self.gpa);
        var it = self.lost.keyIterator();
        while (it.next()) |k| self.gpa.free(k.*);
        self.lost.deinit(self.gpa);
    }

    /// Every folder under the root is watched: nothing left out, nothing waiting for room.
    /// Until then a plugin can't rely on change events alone.
    pub fn whole(self: *const Watches) bool {
        return self.blocked == null and self.frontier.count() == 0 and self.lost.count() == 0 and !self.degraded;
    }

    /// Something is left to try again later, and time may help: the OS freeing watches, an
    /// fd. Not the cap: only a folder of this tree going frees room under it.
    pub fn waiting(self: *const Watches) bool {
        return self.frontier.count() > 0 and self.blocked != .cap;
    }

    /// Let the next `catchUp` try again, after a while.
    pub fn retry(self: *Watches) void {
        if (self.blocked != .cap) self.blocked = null;
    }

    fn lowerBound(self: *const Watches, key: []const u8) usize {
        return std.sort.lowerBound([]u8, self.paths.items, key, struct {
            fn order(k: []const u8, item: []u8) std.math.Order {
                return std.mem.order(u8, k, item);
            }
        }.order);
    }

    pub fn contains(self: *const Watches, path: []const u8) bool {
        const i = self.lowerBound(path);
        return i < self.paths.items.len and std.mem.eql(u8, self.paths.items[i], path);
    }

    /// Watch the root and every folder under it not skipped, when it is opened.
    // anytype: Native watch backends and test contexts supply add/remove/created/say callbacks.
    pub fn walk(self: *Watches, io: std.Io, ctx: anytype) void {
        self.walkFrom(io, self.root, .{}, ctx);
    }

    /// `dir` was created, and is watched only now: whatever was made in it before then had
    /// no event, so it is announced - unless `announced`, when the backend already did (a
    /// folder moved in from outside the tree, which inotify reports with all it holds).
    // anytype: Native watch backends and test contexts supply add/remove/created/say callbacks.
    pub fn appeared(self: *Watches, io: std.Io, dir: []const u8, announced: bool, ctx: anytype) void {
        if (!inside(dir, self.root) or underSegment(self.root, dir, skipWatchDir)) return;
        if (self.contains(dir)) {
            // Watched by the root's first walk, which says nothing of what it finds.
            if (!self.settled and !announced) self.walkFrom(io, dir, .{ .resume_top = true, .owed = .all, .through_known = true }, ctx);
            return;
        }
        self.walkFrom(io, dir, .{ .owed = if (announced) .none else .all }, ctx);
    }

    /// Go on from where walks stopped. Call after a batch of folder events, not per event.
    // anytype: Native watch backends and test contexts supply add/remove/created/say callbacks.
    pub fn catchUp(self: *Watches, io: std.Io, ctx: anytype) void {
        // Each entry once per call: one refused again goes back on the frontier, not round
        // this loop for ever.
        std.debug.assert(self.todo.count() == 0);
        std.mem.swap(std.array_hash_map.String(Owed), &self.todo, &self.frontier);
        defer {
            for (self.todo.keys(), self.todo.values()) |p, owed| {
                self.leftOut(p, owed, ctx);
                self.gpa.free(p);
            }
            self.todo.clearRetainingCapacity();
            if (self.frontier.count() == 0) self.said = null;
        }
        while (self.blocked == null and !self.cancel.load(.acquire)) {
            const kv = self.todo.pop() orelse break;
            defer self.gpa.free(kv.key);
            if (!underSegment(self.root, kv.key, skipWatchDir))
                self.walkFrom(io, kv.key, .{ .resume_top = true, .owed = kv.value }, ctx);
        }
    }

    // anytype: Native watch backends and test contexts supply add/remove/created/say callbacks.
    fn walkFrom(self: *Watches, io: std.Io, dir: []const u8, pass: Pass, ctx: anytype) void {
        var buf: [std.fs.max_path_bytes]u8 = undefined;
        if (dir.len > buf.len) {
            _ = self.lose(dir, "NAMETOOLONG", ctx);
            return;
        }
        @memcpy(buf[0..dir.len], dir);
        _ = self.walkDir(io, &buf, dir.len, pass, true, ctx);
        std.mem.sortUnstable([]u8, self.fresh.items, {}, struct {
            fn lt(_: void, a: []u8, b: []u8) bool {
                return std.mem.lessThan(u8, a, b);
            }
        }.lt);
        self.merge(self.fresh.items) catch {
            for (self.fresh.items) |p| {
                ctx.remove(p);
                self.gpa.free(p);
            }
            self.degrade(ctx);
        };
        self.fresh.clearRetainingCapacity();
    }

    /// Merge the sorted `run` (owned) into `paths`, from the back, in place.
    fn merge(self: *Watches, run: []const []u8) !void {
        try self.paths.ensureUnusedCapacity(self.gpa, run.len);
        var i = self.paths.items.len;
        self.paths.items.len += run.len;
        const items = self.paths.items;
        var j = run.len;
        var k = items.len;
        while (j > 0) {
            k -= 1;
            if (i > 0 and std.mem.order(u8, items[i - 1], run[j - 1]) == .gt) {
                items[k] = items[i - 1];
                i -= 1;
            } else {
                items[k] = run[j - 1];
                j -= 1;
            }
        }
    }

    /// `name` appended to the folder in `buf[0..len]`, or null when it doesn't fit.
    fn join(buf: *[std.fs.max_path_bytes]u8, len: usize, name: []const u8) ?[]const u8 {
        if (len + 1 + name.len > buf.len) return null;
        buf[len] = std.fs.path.sep;
        @memcpy(buf[len + 1 ..][0..name.len], name);
        return buf[0 .. len + 1 + name.len];
    }

    /// An entry's kind, from the directory listing or, where that doesn't say (DT_UNKNOWN on
    /// some filesystems), from a stat that doesn't follow a symlink.
    fn kindOf(io: std.Io, d: std.Io.Dir, entry: std.Io.Dir.Entry) std.Io.File.Kind {
        if (entry.kind != .unknown) return entry.kind;
        const st = d.statFile(io, entry.name, .{ .follow_symlinks = false }) catch return .unknown;
        return st.kind;
    }

    /// False when the walk stopped before the tree ran out.
    // anytype: Native watch backends and test contexts supply add/remove/created/say callbacks.
    fn walkDir(self: *Watches, io: std.Io, buf: *[std.fs.max_path_bytes]u8, len: usize, pass: Pass, top: bool, ctx: anytype) bool {
        if (self.cancel.load(.acquire)) return false;
        const path = buf[0..len];
        if (self.lost.contains(path)) return true;
        // A watched folder's subtree was walked when it was added; a folder that appeared
        // since has its own event, and one a walk left out is on the frontier.
        const known = self.contains(path);
        if (known and !(top and pass.resume_top) and !pass.through_known) return true;
        var d = std.Io.Dir.openDirAbsolute(io, path, .{ .iterate = true }) catch |err| {
            self.unreadable(path, err, pass.owed, ctx);
            return true;
        };
        defer d.close(io);
        if (!known) switch (self.watch(path, ctx)) {
            .added => {},
            .skipped => return true,
            .blocked => {
                self.leftOut(path, pass.owed, ctx);
                return false;
            },
        };
        // Everything it holds is said before anything below it is walked, so a walk that
        // stops further down owes this folder its subfolders' contents, never its own entries
        // a second time.
        if (pass.owed == .all) {
            var it = d.iterate();
            while (it.next(io) catch {
                // Some said, the rest not: say them all again later rather than miss any.
                self.leftOut(path, .all, ctx);
                return true;
            }) |entry| {
                const kind = kindOf(io, d, entry);
                if (kind != .file and kind != .directory) continue;
                const child = join(buf, len, entry.name) orelse {
                    self.loseLong(path, entry.name, ctx);
                    continue;
                };
                ctx.created(child, kind == .directory);
            }
        }
        const rest: Owed = if (pass.owed == .none) .none else .below;
        const deeper: Owed = if (pass.owed == .none) .none else .all;
        var it = d.iterate();
        while (true) {
            const entry = (it.next(io) catch {
                self.leftOut(path, rest, ctx);
                return true;
            }) orelse break;
            if (skipWatchDir(entry.name)) continue;
            // A symlink is not followed: it may point back up the tree, or out of it.
            if (kindOf(io, d, entry) != .directory) continue;
            const child = join(buf, len, entry.name) orelse {
                self.loseLong(path, entry.name, ctx);
                continue;
            };
            if (!self.walkDir(io, buf, child.len, .{ .owed = deeper, .through_known = pass.through_known }, false, ctx)) {
                if (!self.cancel.load(.acquire)) self.leftOut(buf[0..len], rest, ctx);
                return false;
            }
        }
        self.done(path, pass.owed);
        return true;
    }

    /// `path` has been walked to the end, and what it was owed said: it is no longer waited
    /// for, wherever it was left out before.
    fn done(self: *Watches, path: []const u8, owed: Owed) void {
        inline for (.{ &self.frontier, &self.todo }) |map| {
            if (map.getIndex(path)) |i| if (@backingInt(map.values()[i]) <= @backingInt(owed)) {
                const k = map.keys()[i];
                map.swapRemoveAt(i);
                self.gpa.free(k);
            };
        }
    }

    /// A folder that couldn't be opened to walk.
    // anytype: Native watch backends and test contexts supply add/remove/created/say callbacks.
    fn unreadable(self: *Watches, path: []const u8, err: std.Io.Dir.OpenError, owed: Owed, ctx: anytype) void {
        switch (err) {
            // Gone already: nothing to watch.
            error.FileNotFound, error.NotDir => {},
            // Out of fds or kernel memory, or something unforeseen: worth another try later.
            error.ProcessFdQuotaExceeded, error.SystemFdQuotaExceeded, error.SystemResources, error.Unexpected => self.leftOut(path, owed, ctx),
            // Its own, and not passing (a permission, a loop, a bad name): left out, said once.
            else => {
                _ = self.lose(path, @errorName(err), ctx);
            },
        }
    }

    // anytype: Native watch backends and test contexts supply add/remove/created/say callbacks.
    fn watch(self: *Watches, path: []const u8, ctx: anytype) Watched {
        if (self.paths.items.len + self.fresh.items.len >= self.limit) return self.block(.cap, ctx);
        return self.add(path, 2, ctx);
    }

    /// Add a watch on `path`, asking why when refused; `tries` bounds the retries a refusal
    /// that has since cleared up gets.
    // anytype: Native watch backends and test contexts supply add/remove/created/say callbacks.
    fn add(self: *Watches, path: []const u8, tries: u8, ctx: anytype) Watched {
        ctx.add(path) catch |err| switch (err) {
            error.OutOfMemory => {
                self.degrade(ctx);
                return .skipped;
            },
            else => return switch (ctx.why(path)) {
                .gone => .skipped,
                .pool => self.block(.refused, ctx),
                .again => if (tries > 1) self.add(path, tries - 1, ctx) else self.lose(path, "refused", ctx),
                .own => |reason| self.lose(path, reason, ctx),
            },
        };
        const key = self.gpa.dupe(u8, path) catch {
            ctx.remove(path);
            self.degrade(ctx);
            return .skipped;
        };
        self.fresh.append(self.gpa, key) catch {
            self.gpa.free(key);
            ctx.remove(path);
            self.degrade(ctx);
            return .skipped;
        };
        self.blocked = null;
        return .added;
    }

    // anytype: Native watch backends and test contexts supply add/remove/created/say callbacks.
    fn degrade(self: *Watches, ctx: anytype) void {
        if (self.degraded) return;
        self.degraded = true;
        ctx.say(.degraded);
    }

    /// `path` is left out for good, said once.
    // anytype: Native watch backends and test contexts supply add/remove/created/say callbacks.
    fn lose(self: *Watches, path: []const u8, reason: []const u8, ctx: anytype) Watched {
        const gop = self.lost.getOrPut(self.gpa, path) catch {
            self.degrade(ctx);
            return .skipped;
        };
        if (gop.found_existing) return .skipped;
        gop.key_ptr.* = self.gpa.dupe(u8, path) catch {
            self.lost.removeByPtr(gop.key_ptr);
            self.degrade(ctx);
            return .skipped;
        };
        ctx.say(.{ .skipped = .{ .path = path, .reason = reason } });
        return .skipped;
    }

    /// An entry of `dir` whose path is too long to walk.
    // anytype: Native watch backends and test contexts supply add/remove/created/say callbacks.
    fn loseLong(self: *Watches, dir: []const u8, name: []const u8, ctx: anytype) void {
        const p = self.gpa.print("{s}{c}{s}", .{ dir, std.fs.path.sep, name }) catch return self.degrade(ctx);
        defer self.gpa.free(p);
        _ = self.lose(p, "NAMETOOLONG", ctx);
    }

    /// Lost folders at or under `dir` are no longer there to be lost.
    fn forgetLost(self: *Watches, dir: []const u8) void {
        while (true) {
            var it = self.lost.keyIterator();
            const k = while (it.next()) |k| {
                if (inside(k.*, dir)) break k.*;
            } else return;
            _ = self.lost.remove(k);
            self.gpa.free(k);
        }
    }

    // anytype: Native watch backends and test contexts supply add/remove/created/say callbacks.
    fn block(self: *Watches, why: Blocked, ctx: anytype) Watched {
        if (self.said != why) ctx.say(.{ .blocked = .{ .why = why, .watched = self.paths.items.len + self.fresh.items.len } });
        self.said = why;
        self.blocked = why;
        return .blocked;
    }

    // anytype: Native watch backends and test contexts supply add/remove/created/say callbacks.
    fn leftOut(self: *Watches, path: []const u8, owed: Owed, ctx: anytype) void {
        const gop = self.frontier.getOrPut(self.gpa, path) catch return self.degrade(ctx);
        if (gop.found_existing) {
            if (@backingInt(owed) > @backingInt(gop.value_ptr.*)) gop.value_ptr.* = owed;
            return;
        }
        gop.key_ptr.* = self.gpa.dupe(u8, path) catch {
            _ = self.frontier.swapRemove(path);
            return self.degrade(ctx);
        };
        gop.value_ptr.* = owed;
    }

    /// Frontier entries at or under `src` follow it to `dst`, or go, with no `dst`.
    // anytype: Native watch backends and test contexts supply add/remove/created/say callbacks.
    fn reframe(self: *Watches, src: []const u8, dst: ?[]const u8, ctx: anytype) void {
        var f: usize = 0;
        while (f < self.frontier.count()) {
            const p = self.frontier.keys()[f];
            if (!inside(p, src)) {
                f += 1;
                continue;
            }
            const owed = self.frontier.values()[f];
            self.frontier.swapRemoveAt(f);
            defer self.gpa.free(p);
            const to = dst orelse continue;
            const renamed = std.mem.concat(self.gpa, u8, &.{ to, p[src.len..] }) catch {
                self.degrade(ctx);
                continue;
            };
            defer self.gpa.free(renamed);
            self.leftOut(renamed, owed, ctx);
        }
        if (self.frontier.count() == 0) self.said = null;
    }

    /// The range of `paths` strictly below `dir`: the keys that start with `dir` and a
    /// separator. Found without building that prefix, so no path is too long for it.
    fn below(self: *const Watches, dir: []const u8) struct { usize, usize } {
        const items = self.paths.items;
        const start = std.sort.lowerBound([]u8, items, dir, struct {
            /// `d` and a separator, against `item`; a root that already ends in one (`/`)
            /// is its own prefix, and is itself before its range.
            fn order(d: []const u8, item: []u8) std.math.Order {
                const n = @min(d.len, item.len);
                switch (std.mem.order(u8, d, item[0..n])) {
                    .eq => {},
                    else => |o| return o,
                }
                if (item.len == d.len) return .gt;
                if (d.len > 0 and isSep(d[d.len - 1])) return .lt;
                return std.math.order(std.fs.path.sep, item[d.len]);
            }
        }.order);
        var end = start;
        while (end < items.len and items[end].len > dir.len and inside(items[end], dir)) end += 1;
        return .{ start, end };
    }

    /// Where `dir` itself is in `paths`.
    fn indexOf(self: *const Watches, dir: []const u8) ?usize {
        const i = self.lowerBound(dir);
        return if (i < self.paths.items.len and std.mem.eql(u8, self.paths.items[i], dir)) i else null;
    }

    /// Take `dir` and what is below it out of `paths` without allocating. With `remove`, each
    /// watch goes too, named as the backend knows it now: under `as` when it has been moved
    /// there. Returns how many keys went.
    // anytype: Native watch backends and test contexts supply add/remove/created/say callbacks.
    fn drop(self: *Watches, dir: []const u8, remove: bool, as: ?[]const u8, ctx: anytype) usize {
        const start, const end = self.below(dir);
        const at = self.indexOf(dir);
        var buf: [std.fs.max_path_bytes]u8 = undefined;
        const n = end - start + @intFromBool(at != null);
        for (self.paths.items[start..end]) |k| self.dropKey(k, dir, remove, as, &buf, ctx);
        self.paths.replaceRangeAssumeCapacity(start, end - start, &.{});
        // `dir` sorts before everything below it, so its index survived the range going.
        if (at) |i| self.dropKey(self.paths.orderedRemove(i), dir, remove, as, &buf, ctx);
        return n;
    }

    // anytype: Native watch backends and test contexts supply add/remove/created/say callbacks.
    fn dropKey(self: *Watches, k: []u8, dir: []const u8, remove: bool, as: ?[]const u8, buf: *[std.fs.max_path_bytes]u8, ctx: anytype) void {
        defer self.gpa.free(k);
        if (!remove) return;
        const to = as orelse return ctx.remove(k);
        // Too long to name: the watch stays, untracked. Said as such.
        const name = std.mem.print(buf, "{s}{s}", .{ to, k[dir.len..] }) catch return self.degrade(ctx);
        ctx.remove(name);
    }

    /// `dir` left the tree: deleted (the OS dropped its watches with it) or moved out (it
    /// kept them). Either way they are removed, which also clears the backend's own record,
    /// and nothing below it is waited for or lost any longer.
    // anytype: Native watch backends and test contexts supply add/remove/created/say callbacks.
    pub fn gone(self: *Watches, dir: []const u8, ctx: anytype) void {
        if (self.drop(dir, true, null, ctx) > 0) self.blocked = null;
        self.forgetLost(dir);
        self.reframe(dir, null, ctx);
    }

    /// `src` was renamed to `dst`. The OS keeps a moved folder's watches (the backend has
    /// already renamed them); they follow it here, unless it moved somewhere skipped or out
    /// of the tree, where they are removed. A folder moved in from a skipped name is walked,
    /// its contents announced: the backend reports the rename alone, and nothing was said
    /// about them while it was out of view.
    // anytype: Native watch backends and test contexts supply add/remove/created/say callbacks.
    pub fn moved(self: *Watches, io: std.Io, src: []const u8, dst: []const u8, ctx: anytype) void {
        if (!inside(dst, self.root)) return self.gone(src, ctx);
        // Renamed over an empty folder: that folder's key goes. Not its watch: the OS dropped
        // it with the folder, and the backend's record now names the moved one's.
        _ = self.drop(dst, false, null, ctx);
        self.forgetLost(dst);
        self.forgetLost(src);
        if (underSegment(self.root, dst, skipWatchDir)) {
            if (self.drop(src, true, dst, ctx) > 0) self.blocked = null;
            return self.reframe(src, null, ctx);
        }
        // Renaming a common prefix keeps the run in order, so it merges back in one pass.
        const start, const end = self.below(src);
        const at = self.indexOf(src);
        var run: std.ArrayList([]u8) = .empty;
        defer run.deinit(self.gpa);
        run.ensureTotalCapacity(self.gpa, end - start + 1) catch {
            if (self.drop(src, true, dst, ctx) > 0) self.blocked = null;
            self.degrade(ctx);
            return self.reframe(src, null, ctx);
        };
        if (at) |i| run.appendAssumeCapacity(self.paths.items[i]);
        run.appendSliceAssumeCapacity(self.paths.items[start..end]);
        self.paths.replaceRangeAssumeCapacity(start, end - start, &.{});
        if (at) |i| _ = self.paths.orderedRemove(i);
        var kept: usize = 0;
        var buf: [std.fs.max_path_bytes]u8 = undefined;
        for (run.items) |k| {
            const renamed = std.mem.concat(self.gpa, u8, &.{ dst, k[src.len..] }) catch {
                // No memory to follow it: the watch goes (and the key, in `dropKey`).
                self.dropKey(k, src, true, dst, &buf, ctx);
                continue;
            };
            self.gpa.free(k);
            run.items[kept] = renamed;
            kept += 1;
        }
        if (kept < run.items.len) self.degrade(ctx);
        self.merge(run.items[0..kept]) catch {
            for (run.items[0..kept]) |p| {
                ctx.remove(p);
                self.gpa.free(p);
            }
            self.degrade(ctx);
        };
        self.reframe(src, dst, ctx);
        self.walkFrom(io, dst, .{ .resume_top = true, .owed = if (underSegment(self.root, src, skipWatchDir)) .all else .none }, ctx);
    }
};

/// Where `Doorbell` builds: POSIX only. The walker that uses it exists only for a backend that
/// watches folder by folder (inotify, kqueue), and none of those is on Windows.
pub const has_doorbell = builtin.target.os.tag != .windows and !builtin.target.cpu.arch.isWasm();

/// Wakes a thread from another that may not wait, allocate or touch an `Io`: nightwatch's
/// reader. A pipe with a flag in front of it, so a burst of rings is one byte.
///
/// The flag's orderings: `ring`'s swap releases what the ringer did before it (an event put
/// on a list), and `answer`'s swap acquires it, so the waiter sees that work once it has
/// lowered the flag. A ring that finds the flag already up writes nothing; the waiter is then
/// either before `answer` (it will look at the work after) or about to wake on the byte
/// already in the pipe. Both are read-modify-writes on one variable, so of a ring and an
/// answer racing, one sees the other.
pub const Doorbell = struct {
    fds: [2]std.posix.fd_t,
    rung: std.atomic.Value(bool) = .init(false),

    pub fn init() !Doorbell {
        return .{ .fds = try std.Io.Threaded.pipe2(.{ .NONBLOCK = true, .CLOEXEC = true }) };
    }

    pub fn deinit(self: *Doorbell) void {
        std.Io.Threaded.closeFd(self.fds[0]);
        std.Io.Threaded.closeFd(self.fds[1]);
    }

    /// From any thread. Never blocks.
    pub fn ring(self: *Doorbell) void {
        if (!self.rung.swap(true, .acq_rel)) _ = std.posix.system.write(self.fds[1], "x", 1);
    }

    /// Block until rung since the last `answer`, or `timeout_ms` passes (-1: never). True when
    /// rung.
    pub fn wait(self: *Doorbell, timeout_ms: i32) error{PollFailed}!bool {
        var pfd = [_]std.posix.pollfd{.{ .fd = self.fds[0], .events = std.posix.POLL.IN, .revents = 0 }};
        const n = std.posix.poll(&pfd, timeout_ms) catch return error.PollFailed;
        return n > 0;
    }

    /// Lower the bell. Call before looking at what it was rung about: a ring after this is
    /// a new one.
    pub fn answer(self: *Doorbell) void {
        var buf: [64]u8 = undefined;
        while (true) _ = std.posix.read(self.fds[0], &buf) catch break;
        _ = self.rung.swap(false, .acq_rel);
    }
};

/// Fixed-capacity event buffer, filled by the watcher thread and drained by the UI thread.
///
/// Nothing here allocates, and that is the whole point: the producer runs on a thread nightwatch
/// owns, where reaching for a shared allocator is exactly what the other watcher adapters in
/// this directory are careful never to do. When the buffer fills, the overflow is *reported*
/// (`truncated`) rather than absorbed - a branch switch emits events by the tens of thousands,
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

        /// Flat backing store for paths - one arena rather than a fixed slot per event, so a
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
        /// every event was dropped - and that batch still has to go out.
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
    try testing.expect(underSegment(root, "/home/u/proj/.git/index", dotName));
    try testing.expect(underSegment(root, "/home/u/proj/.zig-cache/o/abc/x.o", dotName));
    try testing.expect(underSegment(root, "/home/u/proj/src/.hidden/f.md", dotName));
    try testing.expect(underSegment(root, "/home/u/proj/.env", dotName));

    try testing.expect(!underSegment(root, "/home/u/proj/README.md", dotName));
    try testing.expect(!underSegment(root, "/home/u/proj/src/index/Db.zig", dotName));
    // A dot *inside* a segment is a file extension, not a hidden entry.
    try testing.expect(!underSegment(root, "/home/u/proj/docs/a.b.md", dotName));
    // The root may itself sit under a dot-directory; only what's below it is our business.
    try testing.expect(!underSegment("/home/u/.config/vault", "/home/u/.config/vault/note.md", dotName));
    // Unrelated paths aren't ours to classify.
    try testing.expect(!underSegment(root, "/etc/passwd", dotName));
}

test "dot-segment reject handles windows separators" {
    const root = "C:\\proj";
    try testing.expect(underSegment(root, "C:\\proj\\.git\\HEAD", dotName));
    try testing.expect(!underSegment(root, "C:\\proj\\src\\main.zig", dotName));
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

test "a watch skips hidden folders and the trees tools write" {
    try testing.expect(skipWatchDir(".git"));
    try testing.expect(skipWatchDir(".zig-cache"));
    try testing.expect(skipWatchDir(".bun"));
    try testing.expect(skipWatchDir("node_modules"));
    try testing.expect(skipWatchDir("zig-pkg"));

    try testing.expect(!skipWatchDir("src"));
    // Ordinary names in plenty of projects (`docs/target`): watched, left to `IgnoreRules`.
    try testing.expect(!skipWatchDir("target"));
    try testing.expect(!skipWatchDir("zig-out"));
    try testing.expect(!skipWatchDir("my.module"));
}

test "a folder is skipped when any folder on its way from the root is" {
    try testing.expect(underSegment("/p", "/p/node_modules/lodash", skipWatchDir));
    try testing.expect(underSegment("/p", "/p/src/.git/objects", skipWatchDir));
    try testing.expect(!underSegment("/p", "/p/src/a", skipWatchDir));
    try testing.expect(!underSegment("/home/u/.config/vault", "/home/u/.config/vault/notes", skipWatchDir));
    try testing.expect(!underSegment("/p", "/elsewhere", skipWatchDir));
}

/// Watches as a backend would: refusing any past `room` the way inotify does once
/// `max_user_watches` is spent, and any folder named `refuse` for reasons of its own. `why`
/// answers as the errno probe would.
const TestBackend = struct {
    room: usize = std.math.maxInt(usize),
    refuse: []const u8 = "",
    oom: bool = false,
    live: usize = 0,
    attempts: usize = 0,
    removed: usize = 0,
    blocked_said: usize = 0,
    skipped_said: usize = 0,
    last_blocked: ?Blocked = null,
    created_dirs: usize = 0,
    created_files: usize = 0,
    degraded_said: usize = 0,
    /// What `why` says for `refuse` before it says `.own`: `.again`s first, or the pool.
    agains: usize = 0,
    refuse_is_pool: bool = false,

    pub fn add(self: *TestBackend, path: []const u8) error{ OutOfMemory, WatchFailed }!void {
        self.attempts += 1;
        if (self.oom) return error.OutOfMemory;
        if (self.refuse.len > 0 and std.mem.endsWith(u8, path, self.refuse)) return error.WatchFailed;
        if (self.live >= self.room) return error.WatchFailed;
        self.live += 1;
    }

    pub fn why(self: *TestBackend, path: []const u8) Refusal {
        if (self.refuse.len > 0 and std.mem.endsWith(u8, path, self.refuse)) {
            if (self.agains > 0) {
                self.agains -= 1;
                return .again;
            }
            return if (self.refuse_is_pool) .pool else .{ .own = "INVAL" };
        }
        return if (self.live >= self.room) .pool else .again;
    }

    pub fn remove(self: *TestBackend, path: []const u8) void {
        _ = path;
        self.live -= 1;
        self.removed += 1;
    }

    pub fn created(self: *TestBackend, path: []const u8, is_dir: bool) void {
        _ = path;
        if (is_dir) self.created_dirs += 1 else self.created_files += 1;
    }

    pub fn say(self: *TestBackend, said: Said) void {
        switch (said) {
            .blocked => |b| {
                self.blocked_said += 1;
                self.last_blocked = b.why;
            },
            .skipped => self.skipped_said += 1,
            .degraded => self.degraded_said += 1,
        }
    }
};

const TestTree = struct {
    tmp: testing.TmpDir,
    buf: [std.fs.max_path_bytes]u8 = undefined,
    root: []const u8 = "",
    cancel: std.atomic.Value(bool) = .init(false),
    scratch: [std.fs.max_path_bytes]u8 = undefined,

    /// A small project: six folders worth watching, and the kinds a watch leaves alone.
    fn init(self: *TestTree) !void {
        self.tmp = testing.tmpDir(.{});
        for ([_][]const u8{ "src/a", "docs", "zig-out/bin", ".git/objects/ab", "node_modules/x/y" }) |p|
            try self.tmp.dir.createDirPath(testing.io, p);
        self.root = self.buf[0..try self.tmp.dir.realPath(testing.io, &self.buf)];
    }

    /// `rel` under the root, with `/` for the separator. Valid until the next call.
    fn path(self: *TestTree, rel: []const u8) []const u8 {
        const out = std.mem.print(&self.scratch, "{s}{s}{s}", .{ self.root, std.fs.path.sep_str, rel }) catch unreachable;
        for (out[self.root.len..]) |*c| if (c.* == '/') {
            c.* = std.fs.path.sep;
        };
        return out;
    }

    /// `rel` under the root, owned by the caller.
    fn own(self: *TestTree, rel: []const u8) []u8 {
        return testing.allocator.dupe(u8, self.path(rel)) catch unreachable;
    }

    fn watches(self: *TestTree) Watches {
        return .{ .gpa = testing.allocator, .root = self.root, .cancel = &self.cancel };
    }
};

test "a walk watches the folders a person edits, once each" {
    var t: TestTree = .{ .tmp = undefined };
    try t.init();
    defer t.tmp.cleanup();
    var w = t.watches();
    defer w.deinit();
    var b: TestBackend = .{};

    w.walk(testing.io, &b);
    // root, src, src/a, docs, zig-out, zig-out/bin
    try testing.expectEqual(@as(usize, 6), w.paths.items.len);
    try testing.expect(w.contains(t.path("src/a")));
    try testing.expect(w.contains(t.path("zig-out/bin")));
    try testing.expect(!w.contains(t.path("node_modules/x")));
    try testing.expect(w.whole());

    // A tree moved in announces each folder in it; the ones already watched cost nothing.
    w.settled = true;
    w.appeared(testing.io, t.path("src"), true, &b);
    w.walk(testing.io, &b);
    try testing.expectEqual(@as(usize, 6), b.attempts);

    // A folder under a skipped one is never watched, whatever announced it.
    w.appeared(testing.io, t.path("node_modules/x"), false, &b);
    try testing.expectEqual(@as(usize, 6), w.paths.items.len);
    try testing.expectEqual(@as(usize, 0), b.blocked_said + b.skipped_said);
}

test "a walk's folders land in order, however many" {
    var t: TestTree = .{ .tmp = undefined };
    try t.init();
    defer t.tmp.cleanup();
    for (0..40) |i| {
        var name: [16]u8 = undefined;
        try t.tmp.dir.createDirPath(testing.io, try std.mem.print(&name, "d{d}/e", .{i}));
    }
    var w = t.watches();
    defer w.deinit();
    var b: TestBackend = .{};
    w.walk(testing.io, &b);
    try testing.expectEqual(@as(usize, 86), w.paths.items.len);
    for (w.paths.items[1..], 0..) |p, i| try testing.expect(std.mem.lessThan(u8, w.paths.items[i], p));
    try testing.expectEqual(@as(usize, 0), w.fresh.items.len);
}

test "a folder refused for its own reasons is left out, said once, and the walk goes on" {
    var t: TestTree = .{ .tmp = undefined };
    try t.init();
    defer t.tmp.cleanup();
    var w = t.watches();
    defer w.deinit();
    var b: TestBackend = .{ .refuse = "docs" };

    w.walk(testing.io, &b);
    try testing.expectEqual(@as(usize, 5), w.paths.items.len);
    try testing.expect(!w.contains(t.path("docs")));
    try testing.expectEqual(@as(usize, 1), b.skipped_said);
    try testing.expectEqual(@as(usize, 0), b.blocked_said);
    // Not waited for, never blamed on the pool, but the tree isn't whole.
    try testing.expectEqual(@as(usize, 0), w.frontier.count());
    try testing.expect(!w.waiting());
    try testing.expect(!w.whole());
}

test "a folder that can't be read is left out and said; the rest is watched" {
    if (builtin.target.os.tag == .windows) return error.SkipZigTest;
    var t: TestTree = .{ .tmp = undefined };
    try t.init();
    defer t.tmp.cleanup();
    try t.tmp.dir.createDirPath(testing.io, "locked/inner");
    try t.tmp.dir.setFilePermissions(testing.io, "locked", .fromMode(0o000), .{});
    defer t.tmp.dir.setFilePermissions(testing.io, "locked", .fromMode(0o755), .{}) catch {};
    // Root reads it anyway.
    if (t.tmp.dir.openDir(testing.io, "locked", .{ .iterate = true })) |d| {
        d.close(testing.io);
        return error.SkipZigTest;
    } else |_| {}
    var w = t.watches();
    defer w.deinit();
    var b: TestBackend = .{};
    w.walk(testing.io, &b);
    try testing.expect(!w.contains(t.path("locked/inner")));
    try testing.expect(w.contains(t.path("src/a")));
    try testing.expect(!w.whole());
}

test "out of watches stops the walk, is said once, and goes on from there when retried" {
    var t: TestTree = .{ .tmp = undefined };
    try t.init();
    defer t.tmp.cleanup();
    var w = t.watches();
    defer w.deinit();
    var b: TestBackend = .{ .room = 2 };

    w.walk(testing.io, &b);
    try testing.expectEqual(@as(usize, 2), w.paths.items.len);
    try testing.expectEqual(@as(usize, 1), b.blocked_said);
    try testing.expectEqual(@as(?Blocked, .refused), b.last_blocked);
    try testing.expect(w.waiting());

    // Still out: a retry finds nothing more, and says nothing more.
    w.retry();
    w.catchUp(testing.io, &b);
    try testing.expectEqual(@as(usize, 2), w.paths.items.len);
    try testing.expectEqual(@as(usize, 1), b.blocked_said);

    // Freed by someone else: the next retry goes on from where it stopped, not the root.
    b.room = 100;
    const attempts = b.attempts;
    w.retry();
    w.catchUp(testing.io, &b);
    try testing.expect(w.whole());
    try testing.expectEqual(@as(usize, 6), w.paths.items.len);
    try testing.expectEqual(attempts + 4, b.attempts);
    try testing.expectEqual(@as(usize, 0), b.skipped_said);
}

test "a root that can't be watched at all is retried" {
    var t: TestTree = .{ .tmp = undefined };
    try t.init();
    defer t.tmp.cleanup();
    var w = t.watches();
    defer w.deinit();
    var b: TestBackend = .{ .room = 0 };
    w.walk(testing.io, &b);
    try testing.expectEqual(@as(usize, 0), w.paths.items.len);
    try testing.expectEqual(@as(usize, 1), b.blocked_said);
    try testing.expect(w.waiting());
    b.room = 100;
    w.retry();
    w.catchUp(testing.io, &b);
    try testing.expect(w.whole());
    try testing.expectEqual(@as(usize, 6), w.paths.items.len);
}

test "the cap counts live watches, so a folder leaving frees room" {
    var t: TestTree = .{ .tmp = undefined };
    try t.init();
    defer t.tmp.cleanup();
    var w = t.watches();
    w.limit = 3;
    defer w.deinit();
    var b: TestBackend = .{};

    w.walk(testing.io, &b);
    try testing.expectEqual(@as(usize, 3), w.paths.items.len);
    try testing.expectEqual(@as(?Blocked, .cap), b.last_blocked);
    // Time doesn't help the cap.
    try testing.expect(!w.waiting());

    const kept = try testing.allocator.dupe(u8, w.paths.items[1]);
    defer testing.allocator.free(kept);
    w.gone(kept, &b);
    try testing.expect(w.paths.items.len < 3);
    w.catchUp(testing.io, &b);
    try testing.expectEqual(@as(usize, 3), w.paths.items.len);
    try testing.expectEqual(w.paths.items.len, b.live);
}

test "the backend out of memory degrades the watch, said once" {
    var t: TestTree = .{ .tmp = undefined };
    try t.init();
    defer t.tmp.cleanup();
    var w = t.watches();
    defer w.deinit();
    var b: TestBackend = .{ .oom = true };
    w.walk(testing.io, &b);
    try testing.expect(w.degraded);
    try testing.expectEqual(@as(usize, 1), b.degraded_said);
    try testing.expectEqual(@as(usize, 0), b.blocked_said);
    try testing.expect(!w.whole());
}

test "what a new folder held before its watch landed is announced, once" {
    var t: TestTree = .{ .tmp = undefined };
    try t.init();
    defer t.tmp.cleanup();
    var w = t.watches();
    defer w.deinit();
    var b: TestBackend = .{};
    w.walk(testing.io, &b);
    w.settled = true;
    try testing.expectEqual(@as(usize, 0), b.created_dirs + b.created_files);

    // An extract, a clone: a folder, and files and folders written into it at once.
    try t.tmp.dir.createDirPath(testing.io, "new/sub/node_modules/x");
    try t.tmp.dir.writeFile(testing.io, .{ .sub_path = "new/f.txt", .data = "" });
    try t.tmp.dir.writeFile(testing.io, .{ .sub_path = "new/sub/g.txt", .data = "" });
    w.appeared(testing.io, t.path("new"), false, &b);
    // f.txt, g.txt; sub, sub/node_modules (seen, though not walked into).
    try testing.expectEqual(@as(usize, 2), b.created_files);
    try testing.expectEqual(@as(usize, 2), b.created_dirs);
    try testing.expect(w.contains(t.path("new/sub")));
    try testing.expect(!w.contains(t.path("new/sub/node_modules")));

    // The backend's own report of a move-in, and the subfolder's own event: nothing again.
    w.appeared(testing.io, t.path("new/sub"), false, &b);
    try t.tmp.dir.createDirPath(testing.io, "moved-in/x");
    w.appeared(testing.io, t.path("moved-in"), true, &b);
    try testing.expectEqual(@as(usize, 4), b.created_dirs + b.created_files);
    try testing.expect(w.contains(t.path("moved-in/x")));
}

test "a folder made during the first walk, and reached by it, is announced by its own event" {
    var t: TestTree = .{ .tmp = undefined };
    try t.init();
    defer t.tmp.cleanup();
    try t.tmp.dir.writeFile(testing.io, .{ .sub_path = "docs/made-early.md", .data = "" });
    var w = t.watches();
    defer w.deinit();
    var b: TestBackend = .{};
    w.walk(testing.io, &b);
    // Its event, queued while the walk ran, is handled before the walker settles.
    w.appeared(testing.io, t.path("docs"), false, &b);
    try testing.expectEqual(@as(usize, 1), b.created_files);
    w.settled = true;
    w.appeared(testing.io, t.path("docs"), false, &b);
    try testing.expectEqual(@as(usize, 1), b.created_files);
}

test "a folder that appeared while out of watches is announced when it is watched" {
    var t: TestTree = .{ .tmp = undefined };
    try t.init();
    defer t.tmp.cleanup();
    var w = t.watches();
    defer w.deinit();
    var b: TestBackend = .{};
    w.walk(testing.io, &b);
    w.settled = true;
    b.room = b.live;
    try t.tmp.dir.createDirPath(testing.io, "late");
    try t.tmp.dir.writeFile(testing.io, .{ .sub_path = "late/f.txt", .data = "" });
    w.appeared(testing.io, t.path("late"), false, &b);
    try testing.expectEqual(@as(usize, 0), b.created_files);
    b.room = 100;
    w.retry();
    w.catchUp(testing.io, &b);
    try testing.expectEqual(@as(usize, 1), b.created_files);
}

test "a folder leaving the tree gives back its watches and what was waiting below it" {
    var t: TestTree = .{ .tmp = undefined };
    try t.init();
    defer t.tmp.cleanup();
    var w = t.watches();
    defer w.deinit();
    var b: TestBackend = .{};
    w.walk(testing.io, &b);
    w.settled = true;

    // `src-x` sorts between `src` and `src/...`; it must survive `src` going.
    try t.tmp.dir.createDirPath(testing.io, "src-x");
    w.appeared(testing.io, t.path("src-x"), false, &b);
    const src = t.own("src");
    defer testing.allocator.free(src);
    const waiting = t.own("src/a/later");
    defer testing.allocator.free(waiting);
    w.leftOut(waiting, .none, &b);
    w.gone(src, &b);
    try testing.expectEqual(@as(usize, 2), b.removed);
    try testing.expect(w.contains(t.path("src-x")));
    try testing.expectEqual(w.paths.items.len, b.live);
    try testing.expectEqual(@as(usize, 0), w.frontier.count());
}

test "a renamed folder keeps its watches, gains them from a skipped name and loses them to one" {
    var t: TestTree = .{ .tmp = undefined };
    try t.init();
    defer t.tmp.cleanup();
    var w = t.watches();
    defer w.deinit();
    var b: TestBackend = .{};
    w.walk(testing.io, &b);
    const src = t.own("src");
    defer testing.allocator.free(src);
    const lib = t.own("lib");
    defer testing.allocator.free(lib);

    // Within view: the watches follow, none added; what was waiting below follows too.
    try t.tmp.dir.rename("src", t.tmp.dir, "lib", testing.io);
    const waiting = t.own("src/a/later");
    defer testing.allocator.free(waiting);
    w.leftOut(waiting, .all, &b);
    const attempts = b.attempts;
    w.moved(testing.io, src, lib, &b);
    try testing.expectEqual(attempts, b.attempts);
    try testing.expect(w.contains(t.path("lib/a")));
    try testing.expect(!w.contains(src));
    try testing.expectEqual(Owed.all, w.frontier.get(t.path("lib/a/later")).?);

    // Out of a hidden folder into view: watched now, and what it holds announced.
    try t.tmp.dir.createDirPath(testing.io, ".tmp-x/sub");
    try t.tmp.dir.rename(".tmp-x", t.tmp.dir, "pkg", testing.io);
    const tmpx = t.own(".tmp-x");
    defer testing.allocator.free(tmpx);
    const pkg = t.own("pkg");
    defer testing.allocator.free(pkg);
    w.moved(testing.io, tmpx, pkg, &b);
    try testing.expect(w.contains(t.path("pkg/sub")));
    try testing.expectEqual(@as(usize, 1), b.created_dirs);
    try testing.expectEqual(@as(usize, 8), b.live);

    // Into a hidden folder: its watches are given back, and nothing waits below it.
    try t.tmp.dir.rename("lib", t.tmp.dir, ".trash", testing.io);
    const trash = t.own(".trash");
    defer testing.allocator.free(trash);
    w.moved(testing.io, lib, trash, &b);
    try testing.expectEqual(@as(usize, 2), b.removed);
    try testing.expectEqual(@as(usize, 6), w.paths.items.len);
    try testing.expectEqual(w.paths.items.len, b.live);
    try testing.expectEqual(@as(usize, 0), w.frontier.count());
}

test "a folder renamed over an empty watched one leaves one key, not two" {
    var t: TestTree = .{ .tmp = undefined };
    try t.init();
    defer t.tmp.cleanup();
    var w = t.watches();
    defer w.deinit();
    var b: TestBackend = .{};
    w.walk(testing.io, &b);
    try t.tmp.dir.rename("src", t.tmp.dir, "docs", testing.io);
    const src = t.own("src");
    defer testing.allocator.free(src);
    const docs = t.own("docs");
    defer testing.allocator.free(docs);
    w.moved(testing.io, src, docs, &b);
    var n: usize = 0;
    for (w.paths.items) |p| if (std.mem.eql(u8, p, docs)) {
        n += 1;
    };
    try testing.expectEqual(@as(usize, 1), n);
    try testing.expect(w.contains(t.path("docs/a")));
}

test "a cancelled walk adds nothing" {
    var t: TestTree = .{ .tmp = undefined };
    try t.init();
    defer t.tmp.cleanup();
    var w = t.watches();
    defer w.deinit();
    t.cancel.store(true, .release);
    var b: TestBackend = .{};
    w.walk(testing.io, &b);
    try testing.expectEqual(@as(usize, 0), w.paths.items.len);
}

test "a doorbell rung any number of times wakes once, and again after it is answered" {
    if (comptime !has_doorbell) return error.SkipZigTest else {
        var bell: Doorbell = try .init();
        defer bell.deinit();
        try testing.expect(!try bell.wait(0));
        bell.ring();
        bell.ring();
        try testing.expect(try bell.wait(0));
        bell.answer();
        try testing.expect(!try bell.wait(0));
        bell.ring();
        try testing.expect(try bell.wait(0));
    }
}

test "a stop rung while the waiter is between waking and answering is not lost" {
    if (comptime !has_doorbell) return error.SkipZigTest else {
        // The walker's loop: wait, answer, then look. A stop that rings after the wake but
        // before the answer must still be seen, or `stopWatch`'s join waits for ever.
        var bell: Doorbell = try .init();
        defer bell.deinit();
        var stop: std.atomic.Value(bool) = .init(false);
        bell.ring();
        try testing.expect(try bell.wait(-1));
        stop.store(true, .release);
        bell.ring(); // swallowed by the flag: already rung
        bell.answer();
        try testing.expect(stop.load(.acquire));

        // And from another thread, a waiter blocked in `wait` wakes for it.
        const Waiter = struct {
            fn run(b: *Doorbell, s: *std.atomic.Value(bool)) void {
                while (true) {
                    _ = b.wait(-1) catch return;
                    b.answer();
                    if (s.load(.acquire)) return;
                }
            }
        };
        stop.store(false, .release);
        const th = try std.Thread.spawn(.{}, Waiter.run, .{ &bell, &stop });
        stop.store(true, .release);
        bell.ring();
        th.join();
    }
}

test "inside and the segment check need a separator after the folder" {
    try testing.expect(inside("/p/a", "/p"));
    try testing.expect(inside("/p", "/p"));
    try testing.expect(!inside("/pp/a", "/p"));
    try testing.expect(inside("/a", "/"));
    try testing.expect(!underSegment("/p", "/pp/node_modules", skipWatchDir));
    try testing.expect(underSegment("/p", "/p/node_modules", skipWatchDir));
    try testing.expect(underSegment("/", "/node_modules/x", skipWatchDir));
}

test "a walk that stops partway owes the folder only what it hadn't said" {
    // P holds files and D and E; the walk says P's entries, walks D whole, then runs out at
    // E. Resumed, it must say what is in E - and nothing in P or D again.
    var t: TestTree = .{ .tmp = undefined };
    try t.init();
    defer t.tmp.cleanup();
    var w = t.watches();
    defer w.deinit();
    var b: TestBackend = .{};
    w.walk(testing.io, &b);
    w.settled = true;
    try t.tmp.dir.createDirPath(testing.io, "P/D/d1");
    try t.tmp.dir.createDirPath(testing.io, "P/E/e1");
    try t.tmp.dir.writeFile(testing.io, .{ .sub_path = "P/f.txt", .data = "" });
    try t.tmp.dir.writeFile(testing.io, .{ .sub_path = "P/D/g.txt", .data = "" });
    try t.tmp.dir.writeFile(testing.io, .{ .sub_path = "P/E/h.txt", .data = "" });
    // Room for P and one of its subfolders' trees (two folders), whichever is walked first.
    b.room = b.live + 3;
    w.appeared(testing.io, t.path("P"), false, &b);
    try testing.expect(w.blocked != null);
    const said_first = b.created_files + b.created_dirs;
    const attempts = b.attempts;
    b.room = 100;
    w.retry();
    w.catchUp(testing.io, &b);
    try testing.expect(w.whole());
    // P: f.txt, D, E; D: d1, g.txt; E: e1, h.txt - seven, each once.
    try testing.expectEqual(@as(usize, 7), b.created_files + b.created_dirs);
    try testing.expect(said_first < 7);
    // Only what wasn't watched was tried: the refused folder and what is below it.
    try testing.expectEqual(@as(usize, 2), b.attempts - attempts);
}

test "a lost folder is said once, not tried again, and forgotten when it goes" {
    var t: TestTree = .{ .tmp = undefined };
    try t.init();
    defer t.tmp.cleanup();
    var w = t.watches();
    defer w.deinit();
    var b: TestBackend = .{ .refuse = "docs" };
    w.walk(testing.io, &b);
    try testing.expectEqual(@as(usize, 1), b.skipped_said);
    const tried = b.attempts;
    w.settled = true;
    w.appeared(testing.io, t.path("docs"), false, &b);
    w.walk(testing.io, &b);
    try testing.expectEqual(tried, b.attempts);
    try testing.expectEqual(@as(usize, 1), b.skipped_said);
    try testing.expect(!w.whole());

    const docs = t.own("docs");
    defer testing.allocator.free(docs);
    try t.tmp.dir.deleteTree(testing.io, "docs");
    w.gone(docs, &b);
    try testing.expect(w.whole());
}

test "a lost folder renamed is tried again under its new name" {
    var t: TestTree = .{ .tmp = undefined };
    try t.init();
    defer t.tmp.cleanup();
    var w = t.watches();
    defer w.deinit();
    var b: TestBackend = .{ .refuse = "docs" };
    w.walk(testing.io, &b);
    try testing.expect(!w.whole());
    try t.tmp.dir.rename("docs", t.tmp.dir, "notes", testing.io);
    const docs = t.own("docs");
    defer testing.allocator.free(docs);
    const notes = t.own("notes");
    defer testing.allocator.free(notes);
    w.moved(testing.io, docs, notes, &b);
    try testing.expect(w.contains(notes));
    try testing.expect(w.whole());
}

test "a refusal that clears up is tried once more, then judged again" {
    var t: TestTree = .{ .tmp = undefined };
    try t.init();
    defer t.tmp.cleanup();
    {
        var w = t.watches();
        defer w.deinit();
        // Says .again, then the retry is refused for the pool: blocked, kept for later.
        var b: TestBackend = .{ .refuse = "docs", .agains = 1, .refuse_is_pool = true };
        w.walk(testing.io, &b);
        try testing.expectEqual(@as(?Blocked, .refused), w.blocked);
        try testing.expect(w.frontier.contains(t.path("docs")));
        try testing.expectEqual(@as(usize, 0), w.lost.count());
    }
    {
        var w = t.watches();
        defer w.deinit();
        // Says .again twice: lost after the one retry, not looped on.
        var b: TestBackend = .{ .refuse = "docs", .agains = 5 };
        w.walk(testing.io, &b);
        try testing.expect(w.lost.contains(t.path("docs")));
        try testing.expectEqual(@as(usize, 1), b.skipped_said);
    }
}

test "a folder moved out of the root goes" {
    var t: TestTree = .{ .tmp = undefined };
    try t.init();
    defer t.tmp.cleanup();
    var w = t.watches();
    defer w.deinit();
    var b: TestBackend = .{};
    w.walk(testing.io, &b);
    const src = t.own("src");
    defer testing.allocator.free(src);
    w.moved(testing.io, src, "/elsewhere/src", &b);
    try testing.expect(!w.contains(t.path("src/a")));
    try testing.expectEqual(w.paths.items.len, b.live);
}

test "running out of memory anywhere leaves no watch untracked" {
    var t: TestTree = .{ .tmp = undefined };
    try t.init();
    defer t.tmp.cleanup();
    try t.tmp.dir.createDirPath(testing.io, "new/sub");
    try t.tmp.dir.writeFile(testing.io, .{ .sub_path = "new/f.txt", .data = "" });
    // Fail the first, then the second, ... allocation of a whole session: walk, a folder that
    // appears, a rename, a folder going. Whatever fails, every live watch is one `paths`
    // holds (so it can be removed), and nothing leaks.
    var fail_at: usize = 0;
    while (fail_at < 200) : (fail_at += 1) {
        var failing = std.testing.FailingAllocator.init(testing.allocator, .{ .fail_index = fail_at });
        var w: Watches = .{ .gpa = failing.allocator(), .root = t.root, .cancel = &t.cancel };
        var b: TestBackend = .{};
        w.walk(testing.io, &b);
        w.settled = true;
        w.appeared(testing.io, t.path("new"), false, &b);
        const src = t.own("src");
        const lib = t.own("lib");
        w.moved(testing.io, src, lib, &b);
        w.moved(testing.io, lib, src, &b);
        w.gone(src, &b);
        testing.allocator.free(src);
        testing.allocator.free(lib);
        w.catchUp(testing.io, &b);
        try testing.expectEqual(w.paths.items.len, b.live);
        if (failing.has_induced_failure) {
            try testing.expect(w.degraded or w.blocked != null);
            try testing.expect(!w.whole());
        }
        w.deinit();
    }
}
