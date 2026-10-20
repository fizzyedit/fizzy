//! The suite's own tests: that it selects by tag and hook, and that it catches a platform that
//! breaks the contract (a suite that cannot fail proves nothing).
const std = @import("std");
const root = @import("root.zig");
const Sim = @import("../Sim.zig");
const Platform = @import("../Platform.zig");
const SimDriver = root.SimDriver;

const Collect = struct {
    skipped: usize = 0,
    reasons: [16][]const u8 = undefined,
    failed_names: [16][]const u8 = undefined,
    failed: usize = 0,

    fn report(c: *Collect, r: root.Result) void {
        if (r.outcome == .skipped) {
            c.reasons[c.skipped] = r.detail;
            c.skipped += 1;
        }
        if (r.outcome == .failed) {
            c.failed_names[c.failed] = r.name;
            c.failed += 1;
        }
    }
};

/// Sim with no injection and an OS: only what a window system can be asked for alone.
const Bare = struct {
    pub const os: ?std.Target.Os.Tag = .linux;
    pub const has_display = false;
    sim: Sim,

    pub fn init(gpa: std.mem.Allocator) !Bare {
        return .{ .sim = Sim.init(gpa, .{}) };
    }
    pub fn deinit(b: *Bare) void {
        b.sim.deinit();
    }
    pub fn platform(b: *Bare) Platform {
        return b.sim.platform();
    }
    pub fn settle(b: *Bare) void {
        b.sim.advance(50 * std.time.ns_per_ms);
    }
};

test "a case is skipped, not failed, when the driver has no display or lacks its hook" {
    var c: Collect = .{};
    const summary = root.Suite(Bare).run(std.testing.allocator, .{}, &c, Collect.report);
    try std.testing.expectEqual(@as(usize, 0), summary.failed);
    try std.testing.expect(summary.skipped > 0 and summary.passed > 0);
    for (c.reasons[0..c.skipped]) |why| try std.testing.expect(why.len > 0);
}

test "the tag and name filters pick cases" {
    const only_all = root.Suite(SimDriver).run(std.testing.allocator, .{ .only = .all }, {}, root.ignore);
    const everything = root.Suite(SimDriver).run(std.testing.allocator, .{}, {}, root.ignore);
    try std.testing.expect(only_all.passed + only_all.skipped + only_all.failed < everything.passed + everything.skipped);
    const one = root.Suite(SimDriver).run(std.testing.allocator, .{ .filter = "hot-plug" }, {}, root.ignore);
    try std.testing.expectEqual(@as(usize, 1), one.passed);
}

/// Sim that loses text: a platform that never types what a key makes, and swallows focus loss.
const NoText = struct {
    pub const os = SimDriver.os;
    pub const has_display = true;
    inner: SimDriver,

    pub fn init(gpa: std.mem.Allocator) !NoText {
        return .{ .inner = try SimDriver.init(gpa) };
    }
    pub fn deinit(n: *NoText) void {
        n.inner.deinit();
    }
    pub fn platform(n: *NoText) Platform {
        var p = n.inner.platform();
        p.vtable = &vtable;
        return p;
    }
    pub fn settle(n: *NoText) void {
        n.inner.settle();
    }
    pub fn tap(n: *NoText, code: @import("../Event.zig").Code) void {
        n.inner.tap(code);
    }

    var vtable: Platform.VTable = undefined;
    var real: *const Platform.VTable = undefined;
    fn poll(ctx: *anyopaque) ?@import("../Event.zig") {
        while (real.poll(ctx)) |e| if (e.payload != .text) return e;
        return null;
    }
};

test "the suite fails a platform that drops the text a key makes" {
    var probe = try SimDriver.init(std.testing.allocator);
    defer probe.deinit();
    NoText.real = probe.platform().vtable;
    NoText.vtable = NoText.real.*;
    NoText.vtable.poll = NoText.poll;

    var c: Collect = .{};
    const summary = root.Suite(NoText).run(std.testing.allocator, .{ .filter = "key:" }, &c, Collect.report);
    try std.testing.expectEqual(@as(usize, 1), summary.failed);
}
