//! `zig build check` for third-party plugins — wired in automatically by `plugin.install()`
//! (see `plugin_sdk.zig`'s `addSdkCheck`). Prints the fizzy SDK version + ABI fingerprint that
//! the fizzy commit the plugin has pinned actually computes (built ReleaseFast, matching
//! fizzy's release CI — see `sdk/dylib.zig`'s `optimize_safety_class`), and diffs them against
//! the plugin's `.github/workflows/release.yml`. Catches the case where a plugin author bumps
//! their fizzy pin but leaves release.yml's `fizzy-sdk-version`/`abi-fingerprint`/
//! `min-sdk-version` stale — the CI dlopen check in `plugin-build-action` only catches that for
//! the 3 of 6 targets that happen to be a runner's native arch, so this is meant to catch it at
//! `zig build` time on every target instead.
const std = @import("std");
const sdk = @import("sdk");

/// The full line (sans newline) containing the first occurrence of `key`, or null if absent.
fn findLine(haystack: []const u8, key: []const u8) ?[]const u8 {
    const pos = std.mem.indexOf(u8, haystack, key) orelse return null;
    const line_start = if (std.mem.lastIndexOfScalar(u8, haystack[0..pos], '\n')) |nl| nl + 1 else 0;
    var line_end = pos + (std.mem.indexOfScalar(u8, haystack[pos..], '\n') orelse (haystack.len - pos));
    if (line_end > line_start and haystack[line_end - 1] == '\r') line_end -= 1;
    return haystack[line_start..line_end];
}

fn leadingWhitespace(line: []const u8) []const u8 {
    var i: usize = 0;
    while (i < line.len and (line[i] == ' ' or line[i] == '\t')) : (i += 1) {}
    return line[0..i];
}

fn quotedValue(line: []const u8) ?[]const u8 {
    const q1 = std.mem.indexOfScalar(u8, line, '"') orelse return null;
    const after = line[q1 + 1 ..];
    const q2 = std.mem.indexOfScalar(u8, after, '"') orelse return null;
    return after[0..q2];
}

const Field = struct {
    key: []const u8,
    search: []const u8,
    want: []const u8,
};

pub fn main(main_init: std.process.Init) !void {
    const arena = main_init.arena.allocator();

    const args = try main_init.minimal.args.toSlice(arena);
    if (args.len < 2) {
        std.debug.print("usage: plugin_sdk_check <path-to-release.yml>\n", .{});
        std.process.exit(2);
    }

    const file = std.Io.Dir.cwd().openFile(main_init.io, args[1], .{}) catch |err| switch (err) {
        error.FileNotFound => {
            // Plugin has no release workflow yet (e.g. brand new) — nothing to check.
            std.debug.print("no release.yml at \"{s}\" — skipping SDK version check.\n", .{args[1]});
            return;
        },
        else => return err,
    };
    defer file.close(main_init.io);
    var file_reader = file.reader(main_init.io, &.{});
    const contents = try file_reader.interface.allocRemaining(arena, .limited(1 << 20));

    const v = sdk.version.sdk_version;
    const want_version = try std.fmt.allocPrint(arena, "{d}.{d}.{d}", .{ v.major, v.minor, v.patch });
    const want_fingerprint = try std.fmt.allocPrint(arena, "0x{x}", .{sdk.dylib.abi_fingerprint});

    const fields = [_]Field{
        .{ .key = "fizzy-sdk-version", .search = "fizzy-sdk-version:", .want = want_version },
        .{ .key = "abi-fingerprint", .search = "abi-fingerprint:", .want = want_fingerprint },
        .{ .key = "min-sdk-version", .search = "min-sdk-version:", .want = want_version },
    };

    var ok = true;
    for (fields) |f| {
        const line = findLine(contents, f.search);
        const got = if (line) |l| quotedValue(l) else null;
        if (got == null or !std.mem.eql(u8, got.?, f.want)) ok = false;
    }

    if (ok) {
        std.debug.print("release.yml is in sync with the pinned fizzy SDK ({s}, {s}).\n", .{ want_version, want_fingerprint });
        return;
    }

    std.debug.print("release.yml is out of sync with the pinned fizzy commit.\n\n", .{});
    std.debug.print("current release.yml:\n", .{});
    for (fields) |f| {
        if (findLine(contents, f.search)) |line| {
            std.debug.print("{s}\n", .{line});
        } else {
            std.debug.print("      {s}: <missing>\n", .{f.key});
        }
    }

    std.debug.print("\nupdated release.yml:\n", .{});
    for (fields) |f| {
        const indent = if (findLine(contents, f.search)) |line| leadingWhitespace(line) else "      ";
        std.debug.print("{s}{s}: \"{s}\"\n", .{ indent, f.key, f.want });
    }

    std.process.exit(1);
}
