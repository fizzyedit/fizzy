//! The conformance suite: what every `Platform` must do, written once against the interface and
//! run against any platform. It is the contract: an adapter is selectable only once it passes the
//! `.all` cases (and the tag of its OS), and `Sim` passes them in `zig build test`.
//!
//! A platform is brought to the suite as a **driver**, a type the suite is generic over. A real
//! window system cannot be made to press a key or drag a file in, so the driver is what injects
//! the outside world. What it must declare:
//!
//! - `pub const os: ?std.Target.Os.Tag`: the OS it really is, which selects the `.macos`,
//!   `.windows` and `.linux` cases; null for a simulation.
//! - `pub const has_display: bool`: a display exists, which selects `.needs_display`.
//! - `pub fn init(gpa) !Driver` and `deinit`: every case gets a fresh one, so none depends on
//!   another.
//! - `pub fn platform(*Driver) Platform`.
//! - `pub fn settle(*Driver) void`: lets what was asked of the OS land (a resize, a focus
//!   change). Sim advances its clock; a real driver pumps the platform for a bounded time.
//!
//! and what it may provide, each of which a case names in `Case.needs`; a case whose hooks the
//! driver lacks is skipped, never failed (`hooks.zig` says what each does).
//!
//! Cases read events the way an app does and assert order and values, never timing. Events a
//! platform adds that a case did not ask about (a pointer move) are skipped. Replay-based cases
//! wait for the recording step (plans#51, step 5).
const std = @import("std");
const Platform = @import("../Platform.zig");
const cases = @import("cases.zig");
const Sim = @import("../Sim.zig");

pub const hooks = @import("hooks.zig");
pub const SimDriver = @import("SimDriver.zig");

/// Where a case applies. `all` is the bar every adapter must clear.
pub const Tag = enum { all, needs_display, macos, windows, linux };

/// What a case may fail with: the platform's errors, `std.testing`'s, and the named ones a case
/// raises when an event it waits for never arrives.
pub const Error = Platform.Error || error{
    HookMissing,
    WindowHasNoDisplay,
    NoResizedEvent,
    NoComposition,
    NoClear,
    NoText,
    EmptyClipboard,
    NoClipboardEvent,
    NoEnter,
    NoMove,
    NoDrop,
    TestUnexpectedResult,
    TestExpectedEqual,
};

pub const Outcome = enum { passed, failed, skipped };

pub const Result = struct {
    name: []const u8,
    outcome: Outcome,
    /// Why it was skipped, or the error it failed with.
    detail: []const u8 = "",
};

pub const Summary = struct {
    passed: usize = 0,
    failed: usize = 0,
    skipped: usize = 0,

    fn add(s: *Summary, outcome: Outcome) void {
        switch (outcome) {
            .passed => s.passed += 1,
            .failed => s.failed += 1,
            .skipped => s.skipped += 1,
        }
    }
};

pub const Options = struct {
    /// Run only the cases of this tag.
    only: ?Tag = null,
    /// Run only the cases whose name contains this.
    filter: ?[]const u8 = null,
};

pub fn Case(comptime Driver: type) type {
    return struct {
        name: []const u8,
        tag: Tag,
        /// The hooks it uses; `available` is whether the driver has them all.
        needs: []const hooks.Hook = &.{},
        available: bool = true,
        run: *const fn (*Driver, std.mem.Allocator) Error!void,
    };
}

/// The suite for one driver type.
pub fn Suite(comptime Driver: type) type {
    return struct {
        pub const all = cases.list(Driver);

        /// Why `case` does not apply to this driver, or null if it does.
        pub fn skipReason(case: Case(Driver)) ?[]const u8 {
            switch (case.tag) {
                .all => {},
                .needs_display => if (!Driver.has_display) return "no display",
                .macos, .windows, .linux => if (Driver.os == null or !std.mem.eql(u8, @tagName(Driver.os.?), @tagName(case.tag))) return "other OS",
            }
            if (!case.available) return "driver lacks a hook";
            return null;
        }

        /// Runs every applicable case, each on a fresh driver, calling `report` per case.
        /// `report` may be null.
        // anytype: Report callbacks and their contexts are supplied by each conformance runner.
        pub fn run(gpa: std.mem.Allocator, options: Options, context: anytype, comptime report: anytype) Summary {
            var summary: Summary = .{};
            for (all) |case| {
                if (options.only) |only| if (case.tag != only) continue;
                if (options.filter) |f| if (std.mem.indexOf(u8, case.name, f) == null) continue;
                const result = runOne(gpa, case);
                summary.add(result.outcome);
                report(context, result);
            }
            return summary;
        }

        fn runOne(gpa: std.mem.Allocator, case: Case(Driver)) Result {
            if (skipReason(case)) |why| return .{ .name = case.name, .outcome = .skipped, .detail = why };
            var driver = Driver.init(gpa) catch |err| return .{ .name = case.name, .outcome = .failed, .detail = @errorName(err) };
            defer driver.deinit();
            case.run(&driver, gpa) catch |err| return .{ .name = case.name, .outcome = .failed, .detail = @errorName(err) };
            return .{ .name = case.name, .outcome = .passed };
        }
    };
}

pub fn ignore(_: void, _: Result) void {}

test {
    _ = @import("tests.zig");
}

test "Sim passes every case that applies to it" {
    const Reporter = struct {
        fn report(_: void, r: Result) void {
            if (r.outcome == .failed) std.debug.print("conformance: {s} failed: {s}\n", .{ r.name, r.detail });
        }
    };
    const summary = Suite(SimDriver).run(std.testing.allocator, .{}, {}, Reporter.report);
    try std.testing.expectEqual(@as(usize, 0), summary.failed);
    // Sim is a display with no OS: it runs `all` and `needs_display`, and skips the OS-only ones.
    try std.testing.expect(summary.passed >= 9);
}
