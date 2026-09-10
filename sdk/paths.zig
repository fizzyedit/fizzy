//! Build-time copy of `localConfigRoot` from `core/paths.zig`.
//! Keep in sync — install path and runtime load path must never drift.
const std = @import("std");

pub fn localConfigRoot(
    os: std.Target.Os.Tag,
    allocator: std.mem.Allocator,
    home: ?[]const u8,
    xdg_config_home: ?[]const u8,
    local_app_data: ?[]const u8,
) !?[]const u8 {
    return switch (os) {
        .windows => local_app_data,
        .macos => if (home) |h|
            try std.fs.path.join(allocator, &.{ h, "Library", "Application Support" })
        else
            null,
        else => xdg_config_home orelse (if (home) |h|
            try std.fs.path.join(allocator, &.{ h, ".config" })
        else
            null),
    };
}
