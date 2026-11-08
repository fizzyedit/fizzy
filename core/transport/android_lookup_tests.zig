//! Android swaps std's name lookup for bionic's getaddrinfo; every other target keeps std's.
const std = @import("std");
const builtin = @import("builtin");
const android_lookup = @import("android_lookup.zig");

test "android_lookup is on exactly for Android targets" {
    try std.testing.expectEqual(builtin.target.abi.isAndroid(), android_lookup.use);
}

test "wrap leaves a non-Android Io as the same vtable" {
    var vt: std.Io.VTable = undefined;
    const io = android_lookup.wrap(std.testing.io, &vt);
    if (comptime android_lookup.use) {
        try std.testing.expect(io.vtable == &vt);
        try std.testing.expect(io.vtable.netLookup != std.testing.io.vtable.netLookup);
    } else {
        try std.testing.expect(io.vtable == std.testing.io.vtable);
    }
}
