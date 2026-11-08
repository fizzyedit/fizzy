const std = @import("std");
const compat = @import("compat.zig");

test "hostKey is android on an android target" {
    const target = comptime try std.zig.system.resolveTargetQuery(std.testing.io, .{
        .cpu_arch = .aarch64,
        .os_tag = .linux,
        .abi = .android,
    });
    try std.testing.expectEqualStrings("android-aarch64", comptime compat.hostKeyFor(target));
}
