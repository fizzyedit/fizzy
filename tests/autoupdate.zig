//! The auto-updater end to end, on Linux, macOS and Windows: the old version checks an update feed
//! and, when asked, installs the new version over itself. `zig build test-autoupdate`
//! (`build/autoupdate_test.zig`) packages both versions and runs
//!
//!     fizzy-autoupdate-test <app-name> <display-name> <old-prefix> <old-version> <new-prefix> <new-version>
//!
//! where each prefix is a `zig build package --prefix` output: one directory below it holds the
//! package with its Velopack feed. The old package is installed into a folder of the test's own,
//! as a person would: the AppImage copied (Linux), the portable zip unpacked (Windows), the
//! portable zip's bundle unpacked into an Applications folder (macOS, where Velopack updates
//! nothing else). It is run three times, each judged by what it logs: against a feed nobody
//! answers (the check fails, nothing changes), an empty feed (nothing to install), and the new
//! version's feed, where the test asks for the install through the control server
//! (`fizzy.update.install`, what the update toast's button does) and waits for Velopack to replace
//! the install. The replaced install must then say it is the new version.
//!
//! Each run gets a profile of its own and `FIZZY_QUIET=1`, so it never touches the person's config
//! or takes their focus; it still opens a window on the display it is given (`xvfb-run` keeps it
//! off a Linux desktop). Its temporary folder is the test's, and so is its home on macOS, where
//! Velopack keeps its downloads under the home. Everything lives in `fizzy-autoupdate-*` in the
//! system's temporary folder, removed at the end unless `FIZZY_AUTOUPDATE_KEEP=1`. On Linux,
//! Velopack keeps downloads in `/var/tmp/velopack/<app-name>/`, cleared before and after: a newer
//! package left there is installed by the next launch of any copy of the app. On Windows it keeps
//! them beside the install, and logs to `%LOCALAPPDATA%\velopack\`.
const std = @import("std");
const builtin = @import("builtin");
const Io = std.Io;
const Allocator = std.mem.Allocator;

const os = builtin.os.tag;

/// How long a run has to log what it is expected to.
const log_timeout_ms = 90_000;
/// How long the install has to download the new version and replace the old.
const install_timeout_ms = 300_000;
/// How long a run has to end once asked to, before it is killed.
const stop_timeout_ms = 10_000;
const poll_ms = 100;

const check_failed = "fizzy autoupdate: check failed";
const feed_empty = "fizzy autoupdate: remote feed empty";
const no_update = "fizzy autoupdate: no update available";
const update_available = "fizzy autoupdate: update available: ";
const applying = "fizzy autoupdate: applying the update once this process exits";

pub fn main(init: std.process.Init) !u8 {
    if (comptime os != .linux and os != .macos and os != .windows) {
        std.debug.print("autoupdate: skipped, Velopack packages only Linux, macOS and Windows\n", .{});
        return 0;
    }
    const arena = init.arena.allocator();
    const args = try init.minimal.args.toSlice(arena);
    if (args.len != 7) {
        std.debug.print("usage: {s} <app-name> <display-name> <old-prefix> <old-version> <new-prefix> <new-version>\n", .{args[0]});
        return 2;
    }
    const io = init.io;
    var random: [4]u8 = undefined;
    io.random(&random);
    const temp = if (os == .windows) init.environ_map.get("TEMP") orelse "C:\\Windows\\Temp" else "/tmp";
    const made = try std.fmt.allocPrint(arena, "{s}{c}fizzy-autoupdate-{x}", .{ temp, std.fs.path.sep, random });
    try Io.Dir.cwd().createDirPath(io, made);
    var t: Test = .{
        .io = io,
        .arena = arena,
        .environ = init.environ_map,
        .app_name = args[1],
        .display_name = args[2],
        .old = .{ .prefix = args[3], .version = args[4] },
        .new = .{ .prefix = args[5], .version = args[6] },
        // The real path, as the OS names the processes' executables and macOS the bundle's place.
        .work = try Io.Dir.realPathFileAbsoluteAlloc(io, made, arena),
    };
    const keep = init.environ_map.get("FIZZY_AUTOUPDATE_KEEP") != null;
    defer if (keep) std.debug.print("autoupdate: kept {s}\n", .{t.work}) else t.cleanUp();
    t.run() catch |err| switch (err) {
        error.TestFailed => return 1,
        else => return err,
    };
    std.debug.print("autoupdate: all passed\n", .{});
    return 0;
}

const Version = struct {
    prefix: []const u8,
    version: []const u8,
};

const Test = struct {
    io: Io,
    arena: Allocator,
    environ: *const std.process.Environ.Map,
    app_name: []const u8,
    display_name: []const u8,
    old: Version,
    new: Version,
    work: []const u8,
    /// What every run starts: the AppImage, or the executable in the install.
    exe: []const u8 = "",
    /// The file the update replaces, whose identity says whether it has.
    probe: []const u8 = "",
    feed: Feed = undefined,

    fn run(t: *Test) !void {
        const io = t.io;
        const cwd = Io.Dir.cwd();
        for ([_][]const u8{ "installed", "profile", "tmp", "empty", "home" }) |sub|
            try cwd.createDirPath(io, try t.path(sub));
        const old_pkg = try findPackage(t.arena, io, t.old.prefix);
        const new_pkg = try findPackage(t.arena, io, t.new.prefix);
        try t.installOld(old_pkg);
        // An empty feed is the channel's release list with nothing in it.
        try cwd.writeFile(io, .{
            .sub_path = try std.fs.path.join(t.arena, &.{ try t.path("empty"), old_pkg.releases }),
            .data = "{\"Assets\":[]}",
        });
        t.clearVelopack();

        const roots = [_][]const u8{ try t.path("empty"), new_pkg.dir };
        try t.feed.start(io, &roots);
        defer t.feed.stop();
        const feed_url = try std.fmt.allocPrint(t.arena, "http://127.0.0.1:{d}", .{t.feed.port});
        std.debug.print("autoupdate: {s} {s} -> {s}, feed on {s}, work in {s}\n", .{ t.app_name, t.old.version, t.new.version, feed_url, t.work });

        try t.unreachableFeed();
        t.feed.serve(0);
        try t.emptyFeed(feed_url);
        t.feed.serve(1);
        try t.update(feed_url);
        t.feed.serve(0);
        try t.updated(feed_url);
    }

    fn installOld(t: *Test, pkg: Package) !void {
        const io = t.io;
        const cwd = Io.Dir.cwd();
        const source = try std.fs.path.join(t.arena, &.{ pkg.dir, pkg.file });
        switch (os) {
            .linux => {
                t.exe = try std.fs.path.join(t.arena, &.{ try t.path("installed"), pkg.file });
                try cwd.copyFile(source, cwd, t.exe, io, .{});
                t.probe = t.exe;
            },
            .windows => {
                var dest = try cwd.openDir(io, try t.path("installed"), .{});
                defer dest.close(io);
                const zip = try cwd.openFile(io, source, .{});
                defer zip.close(io);
                var buf: [64 * 1024]u8 = undefined;
                var reader = zip.reader(io, &buf);
                try std.zip.extract(dest, &reader, .{ .allow_backslashes = true });
                const exe_name = try std.fmt.allocPrint(t.arena, "{s}.exe", .{t.app_name});
                t.exe = try std.fs.path.join(t.arena, &.{ try t.path("installed"), "current", exe_name });
                t.probe = try std.fs.path.join(t.arena, &.{ try t.path("installed"), "current", "sq.version" });
            },
            .macos => {
                const apps = try t.path("home/Applications");
                try cwd.createDirPath(io, apps);
                // ditto keeps the bundle's modes, which std's zip does not.
                try runTool(t.arena, io, &.{ "ditto", "-x", "-k", source, apps });
                const bundle = try findBundle(t.arena, io, apps);
                const macos_dir = try std.fs.path.join(t.arena, &.{ bundle, "Contents", "MacOS" });
                t.exe = try std.fs.path.join(t.arena, &.{ macos_dir, t.app_name });
                const in_macos = try std.fs.path.join(t.arena, &.{ macos_dir, "sq.version" });
                t.probe = if (cwd.access(io, in_macos, .{})) |_| in_macos else |_| try std.fs.path.join(t.arena, &.{ bundle, "Contents", "Resources", "sq.version" });
            },
            else => comptime unreachable,
        }
        _ = try t.stat();
    }

    /// Nothing listens on port 1: the check fails at once, and the install is left as it was.
    fn unreachableFeed(t: *Test) !void {
        const name = "unreachable feed";
        const before = try t.stat();
        const r = try Run.start(t, "http://127.0.0.1:1");
        defer r.stop();
        _ = try r.expect(name, &.{try t.versionLine(t.old.version)});
        _ = try r.expect(name, &.{check_failed});
        r.stop();
        try r.expectNot(name, update_available);
        try t.expectUnchanged(name, before, r);
        std.debug.print("autoupdate: PASS {s}: \"{s}\"\n", .{ name, r.line(check_failed) });
    }

    /// A feed listing no releases: nothing to install, and the install is left as it was.
    fn emptyFeed(t: *Test, url: []const u8) !void {
        const name = "empty feed";
        const before = try t.stat();
        const r = try Run.start(t, url);
        defer r.stop();
        _ = try r.expect(name, &.{try t.versionLine(t.old.version)});
        const said = try r.expect(name, &.{ feed_empty, no_update });
        r.stop();
        try r.expectNot(name, update_available);
        try r.expectNot(name, applying);
        try t.expectUnchanged(name, before, r);
        std.debug.print("autoupdate: PASS {s}: \"{s}\"\n", .{ name, r.line(said) });
    }

    /// The new version's feed: the check finds it, the install downloads it, and the app restarts
    /// into it, Velopack replacing the install once the old version has exited.
    fn update(t: *Test, url: []const u8) !void {
        const name = "update";
        const before = try t.stat();
        const r = try Run.start(t, url);
        defer r.stop();
        _ = try r.expect(name, &.{try t.versionLine(t.old.version)});
        const available = try std.fmt.allocPrint(t.arena, "{s}{s}", .{ update_available, t.new.version });
        _ = try r.expect(name, &.{available});
        try t.install(name, r);
        _ = try r.expectWithin(name, &.{applying}, install_timeout_ms);
        try t.waitReplaced(name, before, r);
        r.stop();
        std.debug.print("autoupdate: PASS {s}: \"{s}\", then \"{s}\", and the install was replaced\n", .{ name, r.line(available), r.line(applying) });
    }

    /// The replaced install is the new version.
    fn updated(t: *Test, url: []const u8) !void {
        const name = "updated";
        const r = try Run.start(t, url);
        defer r.stop();
        const version = try t.versionLine(t.new.version);
        _ = try r.expect(name, &.{version});
        r.stop();
        std.debug.print("autoupdate: PASS {s}: \"{s}\"\n", .{ name, r.line(version) });
    }

    /// Asks the running app for the install, as the update toast's button does, through its
    /// control server: retried while the server is not up yet.
    fn install(t: *Test, name: []const u8, r: *Run) !void {
        const sock = try t.socketPath();
        if (sock.len > Io.net.UnixAddress.max_len) return t.fail(name, r, "the control socket's path is too long: {s}", .{sock});
        var last: []const u8 = "no answer";
        const attempts = log_timeout_ms / (poll_ms * 5);
        for (0..attempts) |_| {
            if (postCommand(t.arena, t.io, sock, "fizzy.update.install")) |reply| {
                if (reply.status == 200) return;
                last = reply.body;
            } else |err| last = @errorName(err);
            sleep(t.io, poll_ms * 5);
        }
        return t.fail(name, r, "fizzy.update.install never succeeded: {s}", .{last});
    }

    fn waitReplaced(t: *Test, name: []const u8, before: Io.File.Stat, r: *Run) !void {
        const polls = install_timeout_ms / poll_ms;
        var stable: u8 = 0;
        var last: ?Io.File.Stat = null;
        for (0..polls) |_| {
            sleep(t.io, poll_ms);
            const now = t.stat() catch continue;
            if (!changed(before, now)) continue;
            // Replaced: done once it has stayed the same for a moment.
            stable = if (last != null and !changed(last.?, now)) stable + 1 else 0;
            last = now;
            if (stable >= 5) return;
        }
        return t.fail(name, r, "{s} was not replaced within {d} s", .{ t.probe, install_timeout_ms / 1000 });
    }

    fn expectUnchanged(t: *Test, name: []const u8, before: Io.File.Stat, r: *Run) !void {
        const now = try t.stat();
        if (changed(before, now)) return t.fail(name, r, "{s} changed", .{t.probe});
    }

    fn stat(t: *Test) !Io.File.Stat {
        return Io.Dir.cwd().statFile(t.io, t.probe, .{});
    }

    fn versionLine(t: *Test, version: []const u8) ![]const u8 {
        return std.fmt.allocPrint(t.arena, "{s} version {s} (", .{ t.display_name, version });
    }

    fn path(t: *Test, sub: []const u8) ![]const u8 {
        return std.fs.path.join(t.arena, &.{ t.work, sub });
    }

    fn socketPath(t: *Test) ![]const u8 {
        return std.fs.path.join(t.arena, &.{ t.work, "profile", "control", "control.sock" });
    }

    fn velopackLog(t: *Test) ![]const u8 {
        const file = try std.fmt.allocPrint(t.arena, "velopack_{s}.log", .{t.app_name});
        if (os == .windows) {
            const local = t.environ.get("LOCALAPPDATA") orelse return error.NoLocalAppData;
            return std.fs.path.join(t.arena, &.{ local, "velopack", file });
        }
        return std.fs.path.join(t.arena, &.{ t.work, "tmp", file });
    }

    fn fail(t: *Test, name: []const u8, r: *Run, comptime fmt: []const u8, args: anytype) error{TestFailed} {
        std.debug.print("autoupdate: FAIL {s}: " ++ fmt ++ "\n", .{name} ++ args);
        r.mutex.lockUncancelable(t.io);
        std.debug.print("---- the app's log ----\n{s}\n", .{r.log.items});
        r.mutex.unlock(t.io);
        const vpk_path = t.velopackLog() catch return error.TestFailed;
        if (Io.Dir.cwd().readFileAlloc(t.io, vpk_path, t.arena, .limited(1 << 20))) |text| {
            std.debug.print("---- {s} ----\n{s}\n", .{ vpk_path, text });
        } else |_| {}
        return error.TestFailed;
    }

    fn clearVelopack(t: *Test) void {
        if (os != .linux) return;
        const dir = std.fmt.allocPrint(t.arena, "/var/tmp/velopack/{s}", .{t.app_name}) catch return;
        Io.Dir.cwd().deleteTree(t.io, dir) catch |err| std.debug.print("autoupdate: could not clear {s}: {t}\n", .{ dir, err });
    }

    fn cleanUp(t: *Test) void {
        stopAll(t);
        t.clearVelopack();
        Io.Dir.cwd().deleteTree(t.io, t.work) catch |err| std.debug.print("autoupdate: could not remove {s}: {t}\n", .{ t.work, err });
    }
};

fn changed(a: Io.File.Stat, b: Io.File.Stat) bool {
    return a.inode != b.inode or a.size != b.size or a.mtime.nanoseconds != b.mtime.nanoseconds;
}

/// One launch of the installed app, and what it logs, read on a thread of its own.
const Run = struct {
    t: *Test,
    child: ?std.process.Child,
    stderr: Io.File,
    reader: ?std.Thread = null,
    mutex: Io.Mutex = .init,
    log: std.ArrayList(u8) = .empty,
    eof: std.atomic.Value(bool) = .init(false),

    fn start(t: *Test, feed_url: []const u8) !*Run {
        var env = try t.environ.clone(t.arena);
        try env.put("FIZZY_PROFILE", try t.path("profile"));
        try env.put("FIZZY_QUIET", "1");
        try env.put("FIZZY_AUTOUPDATE_URL", feed_url);
        const tmp = try t.path("tmp");
        switch (os) {
            .linux => {
                try env.put("APPIMAGE_EXTRACT_AND_RUN", "1");
                try env.put("TMPDIR", tmp);
            },
            .macos => {
                try env.put("HOME", try t.path("home"));
                try env.put("TMPDIR", tmp);
            },
            .windows => {
                try env.put("TEMP", tmp);
                try env.put("TMP", tmp);
            },
            else => comptime unreachable,
        }
        var child = try std.process.spawn(t.io, .{
            .argv = &.{t.exe},
            .environ_map = &env,
            .stdin = .ignore,
            .stdout = .ignore,
            .stderr = .pipe,
        });
        // The run's to close, once its reader is done with it: `Child.kill` would close it under
        // the reader.
        const stderr = child.stderr.?;
        child.stderr = null;
        const r = try t.arena.create(Run);
        r.* = .{ .t = t, .child = child, .stderr = stderr };
        r.reader = std.Thread.spawn(.{}, readLog, .{r}) catch |err| {
            r.eof.store(true, .release);
            return err;
        };
        return r;
    }

    fn readLog(r: *Run) void {
        defer r.eof.store(true, .release);
        const max_reads = 10_000_000;
        var buf: [16 * 1024]u8 = undefined;
        for (0..max_reads) |_| {
            const n = r.stderr.readStreaming(r.t.io, &.{&buf}) catch return;
            r.mutex.lockUncancelable(r.t.io);
            defer r.mutex.unlock(r.t.io);
            r.log.appendSlice(r.t.arena, buf[0..n]) catch return;
        }
    }

    fn has(r: *Run, needle: []const u8) bool {
        r.mutex.lockUncancelable(r.t.io);
        defer r.mutex.unlock(r.t.io);
        return std.mem.find(u8, r.log.items, needle) != null;
    }

    /// Reads the log until one of `any` is in it; which one.
    fn expect(r: *Run, name: []const u8, any: []const []const u8) ![]const u8 {
        return r.expectWithin(name, any, log_timeout_ms);
    }

    fn expectWithin(r: *Run, name: []const u8, any: []const []const u8, timeout_ms: u32) ![]const u8 {
        for (0..timeout_ms / poll_ms + 1) |_| {
            for (any) |needle| if (r.has(needle)) return needle;
            sleep(r.t.io, poll_ms);
        }
        return r.t.fail(name, r, "no \"{s}\" in the log within {d} s", .{ any[0], timeout_ms / 1000 });
    }

    fn expectNot(r: *Run, name: []const u8, needle: []const u8) !void {
        if (r.has(needle)) return r.t.fail(name, r, "\"{s}\" in the log", .{needle});
    }

    /// The whole log line holding `needle`.
    fn line(r: *Run, needle: []const u8) []const u8 {
        r.mutex.lockUncancelable(r.t.io);
        defer r.mutex.unlock(r.t.io);
        const log = r.log.items;
        const at = std.mem.find(u8, log, needle) orelse return needle;
        const begin = if (std.mem.findScalarLast(u8, log[0..at], '\n')) |i| i + 1 else 0;
        const end = std.mem.findScalarPos(u8, log, at, '\n') orelse log.len;
        return r.t.arena.dupe(u8, std.mem.trimEnd(u8, log[begin..end], "\r")) catch needle;
    }

    /// Ends the run and everything it started, reading the last of its log. Safe to call again.
    fn stop(r: *Run) void {
        if (r.child == null) return;
        stopAll(r.t);
        for (0..stop_timeout_ms / poll_ms) |_| {
            if (r.eof.load(.acquire)) break;
            sleep(r.t.io, poll_ms);
        }
        var child = r.child.?;
        r.child = null;
        // Should it not have been found, `kill` still ends and reaps it.
        child.kill(r.t.io);
        if (r.reader) |thread| {
            if (r.eof.load(.acquire)) {
                thread.join();
                r.stderr.close(r.t.io);
            } else {
                // Something it started still holds the pipe open: leave the reader blocked on it.
                std.debug.print("autoupdate: the log pipe stayed open; its reader is left behind\n", .{});
                thread.detach();
            }
            r.reader = null;
        }
    }
};

fn sleep(io: Io, ms: u32) void {
    io.sleep(.fromMilliseconds(ms), .awake) catch {};
}

fn runTool(arena: Allocator, io: Io, argv: []const []const u8) !void {
    var child = try std.process.spawn(io, .{ .argv = argv, .stdin = .ignore });
    const term = try child.wait(io);
    if (!term.success()) {
        const cmd = try std.mem.join(arena, " ", argv);
        std.debug.print("autoupdate: `{s}` failed: {f}\n", .{ cmd, term });
        return error.TestFailed;
    }
}

const Pid = if (os == .windows) u32 else std.posix.pid_t;

/// Ends every process whose executable is in the test's folder: the app, Velopack's updater, the
/// version Velopack starts after the update. Asked first (SIGTERM, which fizzy answers with its
/// ordinary quit; `fizzy.quit` over the control server on Windows), killed if still there
/// `stop_timeout_ms` later.
fn stopAll(t: *Test) void {
    var pids: [64]Pid = undefined;
    for ([_]bool{ false, true }) |force| {
        const found = ownPids(t, &pids);
        if (found.len == 0) return;
        if (os == .windows and !force) {
            if (t.socketPath()) |sock| {
                _ = postCommand(t.arena, t.io, sock, "fizzy.quit") catch {};
            } else |_| {}
        } else for (found) |pid| endProcess(pid, force);
        for (0..stop_timeout_ms / poll_ms) |_| {
            if (ownPids(t, &pids).len == 0) return;
            sleep(t.io, poll_ms);
        }
    }
}

fn endProcess(pid: Pid, force: bool) void {
    if (os == .windows) {
        const h = win.OpenProcess(win.PROCESS_TERMINATE, 0, pid) orelse return;
        defer _ = win.CloseHandle(h);
        _ = win.TerminateProcess(h, 1);
    } else std.posix.kill(pid, if (force) .KILL else .TERM) catch {};
}

/// The live processes whose executable is under the test's folder.
fn ownPids(t: *Test, out: []Pid) []Pid {
    var n: usize = 0;
    var path_buf: [4096]u8 = undefined;
    switch (os) {
        .linux => {
            const io = t.io;
            var proc = Io.Dir.openDirAbsolute(io, "/proc", .{ .iterate = true }) catch return out[0..0];
            defer proc.close(io);
            var it = proc.iterate();
            const max_entries = 1_000_000;
            for (0..max_entries) |_| {
                const entry = (it.next(io) catch null) orelse break;
                const pid = std.fmt.parseInt(Pid, entry.name, 10) catch continue;
                var link_buf: [32]u8 = undefined;
                const link = std.fmt.bufPrint(&link_buf, "{d}/exe", .{pid}) catch continue;
                const len = proc.readLink(io, link, &path_buf) catch continue;
                if (!under(path_buf[0..len], t.work)) continue;
                if (n == out.len) break;
                out[n] = pid;
                n += 1;
            }
        },
        .macos => {
            var all: [8192]c_int = undefined;
            const count = mac.proc_listallpids(&all, @sizeOf(@TypeOf(all)));
            if (count <= 0) return out[0..0];
            for (all[0..@min(@as(usize, @intCast(count)), all.len)]) |pid| {
                if (pid <= 0) continue;
                const len = mac.proc_pidpath(pid, &path_buf, path_buf.len);
                if (len <= 0) continue;
                if (!under(path_buf[0..@intCast(len)], t.work)) continue;
                if (n == out.len) break;
                out[n] = pid;
                n += 1;
            }
        },
        .windows => {
            const snap = win.CreateToolhelp32Snapshot(win.TH32CS_SNAPPROCESS, 0);
            if (snap == std.os.windows.INVALID_HANDLE_VALUE) return out[0..0];
            defer _ = win.CloseHandle(snap);
            var entry: win.PROCESSENTRY32W = undefined;
            entry.dwSize = @sizeOf(win.PROCESSENTRY32W);
            var more = win.Process32FirstW(snap, &entry) != 0;
            const max_entries = 1_000_000;
            for (0..max_entries) |_| {
                if (!more) break;
                defer more = win.Process32NextW(snap, &entry) != 0;
                const pid = entry.th32ProcessID;
                const h = win.OpenProcess(win.PROCESS_QUERY_LIMITED_INFORMATION, 0, pid) orelse continue;
                defer _ = win.CloseHandle(h);
                var wide: [1024]u16 = undefined;
                var wide_len: u32 = wide.len;
                if (win.QueryFullProcessImageNameW(h, 0, &wide, &wide_len) == 0) continue;
                const len = std.unicode.wtf16LeToWtf8(&path_buf, wide[0..@min(wide_len, wide.len)]);
                if (!under(path_buf[0..len], t.work)) continue;
                if (n == out.len) break;
                out[n] = pid;
                n += 1;
            }
        },
        else => comptime unreachable,
    }
    return out[0..n];
}

/// Whether `file` is in `dir`, as Windows compares paths (without case) or as others do.
fn under(file: []const u8, dir: []const u8) bool {
    if (file.len <= dir.len) return false;
    const head = file[0..dir.len];
    const same = if (os == .windows) std.ascii.eqlIgnoreCase(head, dir) else std.mem.eql(u8, head, dir);
    return same and std.fs.path.isSep(file[dir.len]);
}

const mac = struct {
    extern "c" fn proc_listallpids(buffer: ?*anyopaque, buffersize: c_int) c_int;
    extern "c" fn proc_pidpath(pid: c_int, buffer: [*]u8, buffersize: u32) c_int;
};

const win = struct {
    const HANDLE = std.os.windows.HANDLE;
    const BOOL = c_int;
    const TH32CS_SNAPPROCESS: u32 = 0x2;
    const PROCESS_TERMINATE: u32 = 0x1;
    const PROCESS_QUERY_LIMITED_INFORMATION: u32 = 0x1000;
    const PROCESSENTRY32W = extern struct {
        dwSize: u32,
        cntUsage: u32,
        th32ProcessID: u32,
        th32DefaultHeapID: usize,
        th32ModuleID: u32,
        cntThreads: u32,
        th32ParentProcessID: u32,
        pcPriClassBase: i32,
        dwFlags: u32,
        szExeFile: [260]u16,
    };
    extern "kernel32" fn CreateToolhelp32Snapshot(flags: u32, pid: u32) callconv(.winapi) HANDLE;
    extern "kernel32" fn Process32FirstW(snapshot: HANDLE, entry: *PROCESSENTRY32W) callconv(.winapi) BOOL;
    extern "kernel32" fn Process32NextW(snapshot: HANDLE, entry: *PROCESSENTRY32W) callconv(.winapi) BOOL;
    extern "kernel32" fn OpenProcess(access: u32, inherit: BOOL, pid: u32) callconv(.winapi) ?HANDLE;
    extern "kernel32" fn QueryFullProcessImageNameW(process: HANDLE, flags: u32, name: [*]u16, size: *u32) callconv(.winapi) BOOL;
    extern "kernel32" fn TerminateProcess(process: HANDLE, code: u32) callconv(.winapi) BOOL;
    extern "kernel32" fn CloseHandle(object: HANDLE) callconv(.winapi) BOOL;
};

const Package = struct {
    /// The directory holding the package and its feed.
    dir: []const u8,
    /// The package's file name: the AppImage, or the portable zip.
    file: []const u8,
    /// The feed's release list's file name, `releases.<channel>.json`.
    releases: []const u8,
};

/// The package under `prefix`: the one directory below it with this OS's package and a release
/// list in it.
fn findPackage(arena: Allocator, io: Io, prefix: []const u8) !Package {
    const suffix = if (os == .linux) ".AppImage" else "-Portable.zip";
    var top = try Io.Dir.cwd().openDir(io, prefix, .{ .iterate = true });
    defer top.close(io);
    var it = top.iterate();
    while (try it.next(io)) |entry| {
        if (entry.kind != .directory) continue;
        const dir = try std.fs.path.join(arena, &.{ prefix, entry.name });
        var sub = try top.openDir(io, entry.name, .{ .iterate = true });
        defer sub.close(io);
        var file: ?[]const u8 = null;
        var releases: ?[]const u8 = null;
        var files = sub.iterate();
        while (try files.next(io)) |f| {
            if (f.kind != .file) continue;
            if (std.mem.endsWith(u8, f.name, suffix)) file = try arena.dupe(u8, f.name);
            if (std.mem.startsWith(u8, f.name, "releases.") and std.mem.endsWith(u8, f.name, ".json"))
                releases = try arena.dupe(u8, f.name);
        }
        if (file != null and releases != null) return .{ .dir = dir, .file = file.?, .releases = releases.? };
    }
    std.debug.print("autoupdate: no *{s} with a releases.*.json beside it under {s}\n", .{ suffix, prefix });
    return error.TestFailed;
}

/// The one `.app` bundle in `dir`.
fn findBundle(arena: Allocator, io: Io, dir: []const u8) ![]const u8 {
    var d = try Io.Dir.cwd().openDir(io, dir, .{ .iterate = true });
    defer d.close(io);
    var it = d.iterate();
    while (try it.next(io)) |entry| {
        if (entry.kind == .directory and std.mem.endsWith(u8, entry.name, ".app"))
            return std.fs.path.join(arena, &.{ dir, entry.name });
    }
    std.debug.print("autoupdate: the portable zip held no .app bundle ({s})\n", .{dir});
    return error.TestFailed;
}

const Reply = struct { status: u16, body: []const u8 };

/// `POST /commands/<id>` with no arguments on the control server's socket.
fn postCommand(arena: Allocator, io: Io, sock: []const u8, id: []const u8) !Reply {
    const addr = try Io.net.UnixAddress.init(sock);
    const stream = try addr.connect(io);
    defer stream.close(io);
    var wbuf: [512]u8 = undefined;
    var w = stream.writer(io, &wbuf);
    try w.interface.print(
        "POST /commands/{s} HTTP/1.1\r\nHost: localhost\r\nContent-Type: application/json\r\n" ++
            "Content-Length: 2\r\nConnection: close\r\n\r\n{{}}",
        .{id},
    );
    try w.interface.flush();
    var rbuf: [4096]u8 = undefined;
    var r = stream.reader(io, &rbuf);
    // Read only the framed response: the head, then Content-Length bytes.
    var head: std.ArrayList(u8) = .empty;
    for (0..16 * 1024) |_| {
        try head.append(arena, try r.interface.takeByte());
        if (std.mem.endsWith(u8, head.items, "\r\n\r\n")) break;
    } else return error.HeadTooLong;
    if (head.items.len < 12 or !std.mem.startsWith(u8, head.items, "HTTP/1.")) return error.NotHttp;
    const status = try std.fmt.parseInt(u16, head.items[9..12], 10);
    const key = "content-length: ";
    const at = std.ascii.findIgnoreCase(head.items, key) orelse return .{ .status = status, .body = "" };
    const end = std.mem.findPos(u8, head.items, at, "\r\n") orelse return error.NotHttp;
    const len = try std.fmt.parseInt(usize, head.items[at + key.len .. end], 10);
    const body = try arena.alloc(u8, @min(len, 64 * 1024));
    try r.interface.readSliceAll(body);
    return .{ .status = status, .body = body };
}

/// The update feed: a directory's files over HTTP on an ephemeral loopback port, one request a
/// connection, on a thread of its own. Which directory is `serve`'s to say between runs.
const Feed = struct {
    io: Io,
    roots: []const []const u8,
    root: std.atomic.Value(usize) = .init(0),
    stopping: std.atomic.Value(bool) = .init(false),
    listener: Io.net.Server,
    port: u16,
    thread: std.Thread,

    fn start(f: *Feed, io: Io, roots: []const []const u8) !void {
        const addr: Io.net.IpAddress = .{ .ip4 = .loopback(0) };
        f.* = .{
            .io = io,
            .roots = roots,
            .listener = try addr.listen(io, .{ .reuse_address = true }),
            .port = undefined,
            .thread = undefined,
        };
        f.port = f.listener.socket.address.getPort();
        f.thread = try std.Thread.spawn(.{}, acceptLoop, .{f});
    }

    fn serve(f: *Feed, root: usize) void {
        f.root.store(root, .release);
    }

    fn stop(f: *Feed) void {
        f.stopping.store(true, .release);
        // Wakes the blocked accept, which then sees `stopping`.
        const addr: Io.net.IpAddress = .{ .ip4 = .loopback(f.port) };
        if (addr.connect(f.io, .{ .mode = .stream })) |s| s.close(f.io) else |_| {}
        f.thread.join();
        f.listener.deinit(f.io);
    }

    fn acceptLoop(f: *Feed) void {
        const max_requests = 100_000;
        for (0..max_requests) |_| {
            const stream = f.listener.accept(f.io) catch |err| {
                std.debug.print("feed: accept failed: {t}\n", .{err});
                return;
            };
            defer stream.close(f.io);
            if (f.stopping.load(.acquire)) return;
            f.handle(stream) catch |err| std.debug.print("feed: request failed: {t}\n", .{err});
        }
    }

    fn handle(f: *Feed, stream: Io.net.Stream) !void {
        var rbuf: [8 * 1024]u8 = undefined;
        var wbuf: [64 * 1024]u8 = undefined;
        var reader = stream.reader(f.io, &rbuf);
        var writer = stream.writer(f.io, &wbuf);
        var server = std.http.Server.init(&reader.interface, &writer.interface);
        var request = try server.receiveHead();
        const target = request.head.target;
        const no_query = target[0 .. std.mem.findScalar(u8, target, '?') orelse target.len];
        const name = std.mem.trimStart(u8, no_query, "/");
        const root = f.roots[f.root.load(.acquire)];
        // The feed is one flat directory.
        const flat = name.len > 0 and std.mem.findAny(u8, name, "/\\") == null and !std.mem.eql(u8, name, "..");
        var dir = try Io.Dir.cwd().openDir(f.io, root, .{});
        defer dir.close(f.io);
        const file = (if (flat) dir.openFile(f.io, name, .{}) else error.FileNotFound) catch {
            std.debug.print("feed: 404 {s}\n", .{target});
            return request.respond("not found", .{ .status = .not_found, .keep_alive = false });
        };
        defer file.close(f.io);
        const size = (try file.stat(f.io)).size;
        std.debug.print("feed: 200 {s} ({d} bytes)\n", .{ target, size });
        var body_buf: [64 * 1024]u8 = undefined;
        var body = try request.respondStreaming(&body_buf, .{
            .content_length = size,
            .respond_options = .{ .keep_alive = false },
        });
        var file_buf: [64 * 1024]u8 = undefined;
        var file_reader = file.reader(f.io, &file_buf);
        _ = try file_reader.interface.streamRemaining(&body.writer);
        try body.end();
    }
};
