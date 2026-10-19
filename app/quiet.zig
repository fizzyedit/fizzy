//! A quiet run: one started beside the person (an agent's build, a sandbox) that is never to take
//! their focus. `--quiet` on the command line, or `FIZZY_QUIET=1` in the environment, asks for it.
//!
//! Parsed once at startup (`single_instance.earlyStartup`), taken out of argv with the profile
//! (`single_instance.resolveArgs`) so it is never forwarded to another instance as a path to open.
//! A quiet launch that finds another instance on its lock hands it no paths at all: that instance
//! may be the person's, and opening a file there brings it forward. The flag is carried as the flag through a restart and
//! a handover (`restart`), whose new instance gets a fixed environment and so never sees the
//! variable. The backend reads it as `quiet` (set by the app before its window exists). std-only.
const std = @import("std");

/// The command-line flag.
pub const flag = "--quiet";
/// The environment variable that asks for it when the flag is absent: any value but empty or `0`.
pub const env_var = "FIZZY_QUIET";

/// Whether this run is quiet. Set once at startup, before the window.
pub var on: bool = false;

/// Whether the variable, `value` (null when unset), asks for a quiet run: set, and not `0` (as the
/// app's other switches read, `FIZZY_POPOUT`). Empty asks for nothing.
pub fn fromEnv(value: ?[]const u8) bool {
    const v = value orelse return false;
    return v.len > 0 and !std.mem.eql(u8, v, "0");
}

test "fromEnv: set and not 0" {
    try std.testing.expect(fromEnv("1"));
    try std.testing.expect(!fromEnv("0"));
    try std.testing.expect(!fromEnv(""));
    try std.testing.expect(!fromEnv(null));
}
