//! `zig build conformance`: runs the suite against a platform and prints one line per case.
//! Options: `--tag all|needs_display|macos|windows|linux`, `--filter text`, `--list`; the build
//! passes them from `-Dconformance-tag`, `-Dconformance-filter` and `-Dconformance-list`.
//! Exits non-zero if any case failed. A skipped case is not a failure, but is printed with why.
//!
//! Today the only driver is `Sim`, which checks the suite itself. TODO(seam): the SDL3 adapter
//! (plans#51, step 7) adds its driver here, selected by `--platform`; a driver is a type with
//! the declarations `conformance/root.zig` lists.
const std = @import("std");
const winsys = @import("winsys");

const conformance = winsys.conformance;

const Printer = struct {
    out: *std.Io.Writer,

    fn report(p: *Printer, r: conformance.Result) void {
        const label = switch (r.outcome) {
            .passed => "ok     ",
            .failed => "FAILED ",
            .skipped => "skipped",
        };
        p.out.print("{s} {s}", .{ label, r.name }) catch {};
        if (r.detail.len > 0) p.out.print(" ({s})", .{r.detail}) catch {};
        p.out.writeAll("\n") catch {};
    }
};

pub fn main(init: std.process.Init) !u8 {
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    var options: conformance.Options = .{};
    var list_only = false;
    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "--list")) {
            list_only = true;
        } else if (std.mem.eql(u8, arg, "--tag") and i + 1 < args.len) {
            i += 1;
            options.only = std.meta.stringToEnum(conformance.Tag, args[i]) orelse return error.UnknownTag;
        } else if (std.mem.eql(u8, arg, "--filter") and i + 1 < args.len) {
            i += 1;
            options.filter = args[i];
        } else return error.InvalidArguments;
    }

    var buffer: [4096]u8 = undefined;
    var stdout = std.Io.File.stdout().writer(init.io, &buffer);
    const out = &stdout.interface;
    defer out.flush() catch {};

    const Suite = conformance.Suite(conformance.SimDriver);
    if (list_only) {
        for (Suite.all) |case| try out.print("{s}\t{s}\n", .{ @tagName(case.tag), case.name });
        return 0;
    }
    var printer: Printer = .{ .out = out };
    const summary = Suite.run(init.gpa, options, &printer, Printer.report);
    try out.print("{d} passed, {d} failed, {d} skipped\n", .{ summary.passed, summary.failed, summary.skipped });
    return if (summary.failed == 0) 0 else 1;
}
