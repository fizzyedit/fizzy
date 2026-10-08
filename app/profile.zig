//! A profile: one directory holding everything an app keeps for a person between runs, so a run
//! can be pointed somewhere else entirely — a sandbox for a test or an agent, a portable install
//! on a stick, two configurations side by side.
//!
//! `--profile <dir>` (or `--profile=<dir>`) on the command line, else `FIZZY_PROFILE` in the
//! environment, names it. Under it:
//!
//!   <dir>/              the config folder: settings.zon, keybinds.zon, recents.zon, layout.zon,
//!                       secrets, palettes/ — everything `App.config_folder` holds
//!   <dir>/plugins/      the plugins directory, as it is under the config folder; a plugin's own
//!                       `zig build` installs here too when `FIZZY_PROFILE` is set
//!                       (`sdk/plugin_sdk.zig`)
//!   <dir>/run/          the runtime directory: the single-instance socket, and whatever else
//!                       lives only as long as the run
//!
//! The single-instance lock is the profile's own (`lockId`), so a run with a profile never
//! forwards its arguments to the person's everyday instance, or to a run with another profile.
//!
//! Without one, nothing changes: the platform's config folder and the system temp directory.
//! Native only — a browser tab has neither argv nor an environment.
const std = @import("std");

/// The command-line flag that names a profile.
pub const flag = "--profile";
/// The environment variable that names one when the flag is absent.
pub const env_var = "FIZZY_PROFILE";

/// The profile this run uses — absolute, normalized — or null for the platform's own places.
/// Set once at startup, by `single_instance.earlyStartup`, before anything reads a path.
pub var root: ?[]const u8 = null;

/// What `extract` found in argv.
pub const Extracted = struct {
    /// The profile directory as written, or null when argv names none.
    profile: ?[]const u8,
    /// Everything else, in order: what the app goes on to treat as its arguments.
    rest: []const []const u8,
};

/// Take the profile flag out of `argv` — `--profile <dir>` or `--profile=<dir>`, the last one
/// winning — so the directory is never mistaken for a path to open, or forwarded to another
/// instance as one. `argv[0]` stays first. `rest` is allocated with `gpa` and borrows `argv`'s
/// strings. A trailing `--profile` with nothing after it is dropped and names nothing.
pub fn extract(gpa: std.mem.Allocator, argv: []const []const u8) !Extracted {
    var rest: std.ArrayList([]const u8) = try .initCapacity(gpa, argv.len);
    errdefer rest.deinit(gpa);
    var profile: ?[]const u8 = null;
    var i: usize = 0;
    while (i < argv.len) : (i += 1) {
        const arg = argv[i];
        if (i > 0 and std.mem.eql(u8, arg, flag)) {
            if (i + 1 < argv.len) {
                profile = argv[i + 1];
                i += 1;
            }
            continue;
        }
        if (i > 0 and std.mem.startsWith(u8, arg, flag ++ "=")) {
            profile = arg[flag.len + 1 ..];
            continue;
        }
        rest.appendAssumeCapacity(arg);
    }
    if (profile) |p| {
        if (p.len == 0) profile = null;
    }
    return .{ .profile = profile, .rest = try rest.toOwnedSlice(gpa) };
}

/// `<root>/run`, the runtime directory. Caller owns.
pub fn runtimeDir(gpa: std.mem.Allocator, profile_root: []const u8) ![]u8 {
    return std.fs.path.join(gpa, &.{ profile_root, "run" });
}

/// The single-instance lock's name for a run with `profile_root`: the app's own id with a short
/// hash of the root appended, so each profile has a lock of its own — on Windows, where the lock
/// is a named pipe with no directory to put it in, as much as on Unix. Caller owns.
pub fn lockId(gpa: std.mem.Allocator, app_id: []const u8, profile_root: []const u8) ![:0]u8 {
    const h: u32 = @truncate(std.hash.Wyhash.hash(0, profile_root));
    return std.fmt.allocPrintSentinel(gpa, "{s}.p{x:0>8}", .{ app_id, h }, 0);
}

const testing = std.testing;

test "extract takes the profile out of argv, in either spelling" {
    const gpa = testing.allocator;

    const a = try extract(gpa, &.{ "fizzy", "--profile", "/tmp/sandbox", "/work/a.md" });
    defer gpa.free(a.rest);
    try testing.expectEqualStrings("/tmp/sandbox", a.profile.?);
    try testing.expectEqual(@as(usize, 2), a.rest.len);
    try testing.expectEqualStrings("fizzy", a.rest[0]);
    try testing.expectEqualStrings("/work/a.md", a.rest[1]);

    const b = try extract(gpa, &.{ "fizzy", "/work", "--profile=/p/one", "--profile=/p/two" });
    defer gpa.free(b.rest);
    try testing.expectEqualStrings("/p/two", b.profile.?);
    try testing.expectEqual(@as(usize, 2), b.rest.len);

    // Nothing named: argv as it was.
    const c = try extract(gpa, &.{ "fizzy", "-v", "/work" });
    defer gpa.free(c.rest);
    try testing.expectEqual(@as(?[]const u8, null), c.profile);
    try testing.expectEqual(@as(usize, 3), c.rest.len);

    // A trailing flag, or an empty value, names nothing — and is not left behind as a path.
    const d = try extract(gpa, &.{ "fizzy", "/work", "--profile" });
    defer gpa.free(d.rest);
    try testing.expectEqual(@as(?[]const u8, null), d.profile);
    try testing.expectEqual(@as(usize, 2), d.rest.len);
    const e = try extract(gpa, &.{ "fizzy", "--profile=" });
    defer gpa.free(e.rest);
    try testing.expectEqual(@as(?[]const u8, null), e.profile);
    try testing.expectEqual(@as(usize, 1), e.rest.len);

    // argv[0] is the program, never the flag.
    const f = try extract(gpa, &.{"--profile"});
    defer gpa.free(f.rest);
    try testing.expectEqual(@as(usize, 1), f.rest.len);
}

test "each profile has a lock of its own" {
    const gpa = testing.allocator;
    const one = try lockId(gpa, "dev.fizzy.app", "/home/me/sandbox-1");
    defer gpa.free(one);
    const two = try lockId(gpa, "dev.fizzy.app", "/home/me/sandbox-2");
    defer gpa.free(two);
    const again = try lockId(gpa, "dev.fizzy.app", "/home/me/sandbox-1");
    defer gpa.free(again);
    try testing.expect(std.mem.startsWith(u8, one, "dev.fizzy.app.p"));
    try testing.expectEqual("dev.fizzy.app.p".len + 8, one.len);
    try testing.expect(!std.mem.eql(u8, one, two));
    try testing.expectEqualStrings(one, again);
}
