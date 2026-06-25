//! Example plugin state. A plugin owns whatever state it needs; the host injects only the
//! allocator and `*Host` (read via `sdk.allocator()` / `sdk.host()`), so this is just a plain
//! struct the plugin holds. Trivial here — a real plugin keeps documents, caches, settings, etc.
const std = @import("std");

clicks: u64 = 0,

pub fn deinit(self: *@This(), gpa: std.mem.Allocator) void {
    _ = self;
    _ = gpa;
}
