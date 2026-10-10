//! Restarting the application: quitting the way it always quits, then starting again.
//!
//! One path for every reason to restart — a setting the app takes only at launch, an update
//! downloaded and waiting to be swapped in. `request` posts the app's ordinary quit, so unsaved
//! documents are asked about first and a quit the user calls off calls the restart off with it.
//! Once the app has torn down, `relaunch` starts it again: through Velopack when an update is
//! waiting (it swaps the install, then starts the new version), as this executable otherwise.
//!
//! **A handover**, for a restart into this executable (a setting, a rebuild): the window never
//! closes. The app saves its session first (every document, `KeptDocuments`), then
//! `beginHandover` starts the new instance with `--handover <dir>` while this one stays on screen
//! taking no input. The new one skips the single-instance lock, comes up hidden (the GPU, fonts,
//! plugins: the slow part), reads the session, and says it is `ready` (`awaitHandover`). This one
//! then quits without asking (`handedOver`), and at the end of its teardown, its lock released,
//! says `released` (`relaunch`). The new one takes the lock and shows its window where this one's
//! was. If the new build never says ready (it crashed starting), this one goes on as it was.
//!
//! For a while two instances run on one profile. A plugin holding something there by path (the
//! agent plugin's socket) finds the new instance's in its place as it stops: it must not reach,
//! or remove, the path without checking the thing there is still its own.

const std = @import("std");
const builtin = @import("builtin");
const dvui = @import("dvui");
const core = @import("core");
const update_install = @import("update/update_install.zig");
const profile = @import("profile.zig");

/// A browser tab has nothing to start again.
pub const supported = builtin.target.cpu.arch != .wasm32;

var requested_: bool = false;
/// The profile to start again on, copied when the restart is asked for: teardown frees
/// `profile.root` (`single_instance.deinit`) before `relaunch` runs.
var profile_buf: [if (supported) std.fs.max_path_bytes else 0]u8 = undefined;
var profile_dir: ?[]const u8 = null;
/// Frames since the restart's quit was posted (`tick`).
var quit_frames: u8 = 0;

/// The old instance's side of a handover.
const Handover = enum { none, waiting, handed_over, declined };
var handover: Handover = .none;
var handover_deadline_ns: i96 = 0;
var handover_buf: [if (supported) std.fs.max_path_bytes else 0]u8 = undefined;
/// The folder the two instances meet in (`ready`, `released`).
var handover_dir: ?[]const u8 = null;
/// The new instance's side: the folder it was started with (`--handover <dir>`). Owned.
var handed_from: ?[]u8 = null;
pub const handover_flag = "--handover";
/// The app hands the window over on a restart into this executable: the frame after `request` it
/// either starts a handover (`beginHandover`) or declines one (`declineHandover`), and until then
/// `tick` posts no quit. Off by default, so an app that never drives a handover restarts the
/// ordinary way.
pub var hands_over: bool = false;
/// How long the new build has to come up before this one gives up on it and goes on.
const handover_timeout_ns = 30 * std.time.ns_per_s;

/// Quit and start again. From any handler on the GUI thread.
pub fn request() void {
    if (comptime !supported) return;
    requested_ = true;
    quit_frames = 0;
    handover = .none;
    profile_dir = if (profile.root) |dir| if (dir.len <= profile_buf.len) blk: {
        @memcpy(profile_buf[0..dir.len], dir);
        break :blk profile_buf[0..dir.len];
    } else null else null;
    dvui.refresh(null, @src(), null);
}

/// Whether a restart is under way: its quit posted, the app not yet called back from it.
pub fn requested() bool {
    return requested_;
}

/// Once a frame, before the app reads the frame's quit events. `quitting`: the app is still in
/// the middle of a quit — a question about unsaved documents open, saves running.
///
/// The restart's quit goes in ahead of the frame's own, so it is answered like any other: with
/// nothing unsaved the frame ends closing, and `relaunch` runs at teardown. Still here two frames
/// on and no longer quitting, the user kept the app open — and called the restart off with it.
pub fn tick(quitting: bool) void {
    if (comptime !supported) return;
    // An update the user asked for has finished downloading: installing it is a restart.
    if (update_install.takeDownloaded()) request();
    if (!requested_) return;
    // A handover quits once the new instance is ready (`pollHandover`), not now; and one the app
    // has yet to start or decline (it was asked for partway through a frame) waits for it.
    if (handover == .waiting or handover == .handed_over) return;
    if (hands_over and handover == .none and !update_install.downloaded()) return;
    if (quit_frames == 0) {
        dvui.currentWindow().addEventApp(.{ .action = .quit }) catch {};
    } else if (quit_frames > 1 and !quitting) {
        requested_ = false;
    }
    quit_frames +|= 1;
}

/// At the very end of teardown — after the app's windows, its documents and its single-instance
/// listener are gone, so the new instance owns the lock rather than handing its launch to this
/// one. No-op unless a restart was asked for.
pub fn relaunch(io: std.Io, gpa: std.mem.Allocator) void {
    if (comptime !supported) return;
    if (!requested_) return;
    if (handover == .handed_over) {
        // The new instance is up and waiting for the lock this one just let go of.
        const dir = handover_dir orelse return;
        var buf: [std.fs.max_path_bytes]u8 = undefined;
        const released = std.fmt.bufPrint(&buf, "{s}/released", .{dir}) catch return;
        std.Io.Dir.cwd().writeFile(io, .{ .sub_path = released, .data = "" }) catch |err|
            dvui.log.err("restart: could not hand the lock over ({t}); the new instance takes it when it times out", .{err});
        return;
    }
    // Velopack waits for this process to exit, swaps the install and starts the new version.
    if (update_install.applyAtExit()) return;
    relaunchSelf(io, gpa);
}

/// This executable again, as a process of its own that nothing waits on, on the same profile. On
/// macOS through `core.darwin_spawn` — std's spawn crashes after any `unsetenv`, and it passes a
/// fixed environment, so a profile named by `FIZZY_PROFILE` goes on as the flag. The files this
/// run was started with are not passed again: the session brings back what is still open.
fn relaunchSelf(io: std.Io, gpa: std.mem.Allocator) void {
    start(io, gpa, null) catch |err| dvui.log.err("restart: could not launch again: {t}", .{err});
}

/// This executable, on this profile, as a process of its own that nothing waits on; with
/// `--handover <dir>` when `handover_to` is given.
fn start(io: std.Io, gpa: std.mem.Allocator, handover_to: ?[]const u8) !void {
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const n = try std.process.executablePath(io, &buf);
    var argv_buf: [5][]const u8 = undefined;
    var argv: std.ArrayListUnmanaged([]const u8) = .initBuffer(&argv_buf);
    argv.appendAssumeCapacity(buf[0..n]);
    if (profile_dir) |dir| argv.appendSliceAssumeCapacity(&.{ profile.flag, dir });
    if (handover_to) |dir| argv.appendSliceAssumeCapacity(&.{ handover_flag, dir });
    if (comptime builtin.os.tag.isDarwin()) {
        _ = try core.darwin_spawn.spawn(gpa, .{ .argv = argv.items, .stdin = .discard, .stdout = .discard, .stderr = .discard }, null);
        return;
    }
    _ = try std.process.spawn(io, .{ .argv = argv.items, .stdin = .ignore, .stdout = .ignore, .stderr = .ignore });
}

// ---- The handover: the old instance ------------------------------------------------------------

/// Whether the restart asked for can hand the window over: it starts this executable again (no
/// update waiting for Velopack to swap in), and no handover has been tried for it.
pub fn canHandOver() bool {
    if (comptime !supported) return false;
    return requested_ and handover == .none and !update_install.downloaded();
}

/// This restart goes the ordinary way: quit, then start again.
pub fn declineHandover() void {
    handover = .declined;
}

/// Start the new instance in `dir` (`<config>/handover`), once the app has saved its session.
/// Until it is ready (`pollHandover`) this instance stays on screen; the app takes no input.
/// On an error the restart goes on the ordinary way: quit, then start again.
pub fn beginHandover(io: std.Io, gpa: std.mem.Allocator, dir: []const u8) !void {
    if (comptime !supported) return;
    handover = .declined;
    if (dir.len > handover_buf.len) return error.NameTooLong;
    const cwd = std.Io.Dir.cwd();
    cwd.deleteTree(io, dir) catch {};
    try cwd.createDirPath(io, dir);
    @memcpy(handover_buf[0..dir.len], dir);
    handover_dir = handover_buf[0..dir.len];
    try start(io, gpa, handover_dir);
    handover = .waiting;
    handover_deadline_ns = std.Io.Clock.awake.now(io).nanoseconds + handover_timeout_ns;
}

pub const Poll = enum {
    /// No handover under way.
    none,
    /// The new instance is coming up: take no input.
    waiting,
    /// It is ready: this instance's quit is posted.
    ready,
    /// It never came up (it crashed starting, most likely): the restart is called off, and this
    /// instance goes on as it was.
    failed,
};

/// Once a frame.
pub fn pollHandover(io: std.Io) Poll {
    if (comptime !supported) return .none;
    if (handover != .waiting) return .none;
    const dir = handover_dir orelse return .none;
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const ready = std.fmt.bufPrint(&buf, "{s}/ready", .{dir}) catch return .waiting;
    if (std.Io.Dir.cwd().access(io, ready, .{})) |_| {
        handover = .handed_over;
        dvui.currentWindow().addEventApp(.{ .action = .quit }) catch {};
        return .ready;
    } else |_| {}
    if (std.Io.Clock.awake.now(io).nanoseconds > handover_deadline_ns) {
        handover = .none;
        requested_ = false;
        std.Io.Dir.cwd().deleteTree(io, dir) catch {};
        return .failed;
    }
    dvui.refresh(null, @src(), null);
    return .waiting;
}

/// The new instance is up: this one quits without asking about unsaved documents or keeping them
/// again, since the new one has them.
pub fn handedOver() bool {
    return handover == .handed_over;
}

// ---- The handover: the new instance ------------------------------------------------------------

/// Take `--handover <dir>` out of `args` (the command line, `args[0]` the program), keeping the
/// folder: this instance was started by a handover (`startedByHandover`). From `single_instance`,
/// before the lock, which a handover's instance takes only once the old one has let go of it.
pub fn takeHandoverArg(gpa: std.mem.Allocator, args: *std.ArrayList([]const u8)) !void {
    var i: usize = 1;
    while (i < args.items.len) {
        if (std.mem.eql(u8, args.items[i], handover_flag) and i + 1 < args.items.len) {
            if (handed_from) |old| gpa.free(old);
            handed_from = try gpa.dupe(u8, args.items[i + 1]);
            _ = args.orderedRemove(i);
            _ = args.orderedRemove(i);
            continue;
        }
        i += 1;
    }
}

pub fn startedByHandover() bool {
    return handed_from != null;
}

/// The new instance, up and hidden: tell the old one, which quits. The caller shows its window now,
/// over the old one's at the same place, so a window is on screen throughout; the lock is taken
/// once the old one has let go of it (`pollReleased`).
pub fn signalReady(io: std.Io) void {
    if (comptime !supported) return;
    const dir = handed_from orelse return;
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const ready = std.fmt.bufPrint(&buf, "{s}/ready", .{dir}) catch return;
    std.Io.Dir.cwd().writeFile(io, .{ .sub_path = ready, .data = "" }) catch |err|
        dvui.log.err("restart: could not tell the old instance this one is ready ({t})", .{err});
    released_deadline_ns = std.Io.Clock.awake.now(io).nanoseconds + 15 * std.time.ns_per_s;
}

var released_deadline_ns: i96 = 0;

/// Once a frame while this instance was started by a handover: true once the old one has let go
/// of the single-instance lock (or has taken too long, and the lock is tried anyway), when the
/// caller takes it. The handover is over then.
pub fn pollReleased(io: std.Io, gpa: std.mem.Allocator) bool {
    if (comptime !supported) return false;
    const dir = handed_from orelse return false;
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const released = std.fmt.bufPrint(&buf, "{s}/released", .{dir}) catch return false;
    const done = if (std.Io.Dir.cwd().access(io, released, .{})) |_| true else |_| std.Io.Clock.awake.now(io).nanoseconds > released_deadline_ns;
    if (!done) {
        dvui.refresh(null, @src(), null);
        return false;
    }
    std.Io.Dir.cwd().deleteTree(io, dir) catch {};
    gpa.free(dir);
    handed_from = null;
    return true;
}
