//! Restarting the application: quitting the way it always quits, then starting again.
//!
//! One path for every reason to restart — a setting the app takes only at launch, an update
//! downloaded and waiting to be swapped in. `request` posts the app's ordinary quit, so unsaved
//! documents are asked about first and a quit the user calls off calls the restart off with it.
//! Once the app has torn down, `relaunch` starts it again: through Velopack when an update is
//! waiting (it swaps the install, then starts the new version), as this executable otherwise.

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

/// Quit and start again. From any handler on the GUI thread.
pub fn request() void {
    if (comptime !supported) return;
    requested_ = true;
    quit_frames = 0;
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
    // Velopack waits for this process to exit, swaps the install and starts the new version.
    if (update_install.applyAtExit()) return;
    relaunchSelf(io, gpa);
}

/// This executable again, as a process of its own that nothing waits on, on the same profile. On
/// macOS through `core.darwin_spawn` — std's spawn crashes after any `unsetenv`, and it passes a
/// fixed environment, so a profile named by `FIZZY_PROFILE` goes on as the flag. The files this
/// run was started with are not passed again: the session brings back what is still open.
fn relaunchSelf(io: std.Io, gpa: std.mem.Allocator) void {
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const n = std.process.executablePath(io, &buf) catch |err| {
        dvui.log.err("restart: could not find this executable: {s}", .{@errorName(err)});
        return;
    };
    const argv: []const []const u8 = if (profile_dir) |dir| &.{ buf[0..n], profile.flag, dir } else &.{buf[0..n]};
    if (comptime builtin.os.tag.isDarwin()) {
        _ = core.darwin_spawn.spawn(gpa, .{ .argv = argv, .stdin = .discard, .stdout = .discard, .stderr = .discard }, null) catch |err| {
            dvui.log.err("restart: could not launch again: {s}", .{@errorName(err)});
        };
        return;
    }
    _ = std.process.spawn(io, .{ .argv = argv, .stdin = .ignore, .stdout = .ignore, .stderr = .ignore }) catch |err| {
        dvui.log.err("restart: could not launch again: {s}", .{@errorName(err)});
    };
}
