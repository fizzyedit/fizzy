//! Mirror of `src/sdk/sdk_version.zig` for the plugin-facing package's build scripts.
//! Keep the triplet identical — bump both in the same commit.
const std = @import("std");

pub const sdk_version = std.SemanticVersion{
    .major = 0,
    .minor = 1,
    .patch = 45,
};
