//! Markdown plugin state — caches parsed preview state keyed by shell document id.
const std = @import("std");
const Preview = @import("markdown.zig").Preview;

pub const State = struct {
    previews: std.AutoArrayHashMapUnmanaged(u64, Preview) = .empty,

    pub fn destroy(self: *State, gpa: std.mem.Allocator) void {
        for (self.previews.values()) |*p| p.deinit();
        self.previews.deinit(gpa);
    }

    pub fn previewFor(self: *State, gpa: std.mem.Allocator, id: u64) *Preview {
        const gop = self.previews.getOrPut(gpa, id) catch @panic("OOM");
        if (!gop.found_existing) gop.value_ptr.* = .{};
        return gop.value_ptr;
    }
};
