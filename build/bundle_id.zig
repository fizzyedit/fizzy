//! The default bundle id of an app built on fizzy, `dev.fizzy.<component>` (`build/app.zig`).
//! std-only, so `zig build test` covers it (`fizzy-bundle-id-tests`) although the build is its
//! only user.

const std = @import("std");

/// `name` as a bundle id component: anything but ASCII letters, digits, `.` and `-` becomes `-`
/// (a run of them, a multi-byte character among them, one `-`); no leading `-` or digit, no
/// trailing `-`; `app` if nothing is left.
pub fn component(gpa: std.mem.Allocator, name: []const u8) []const u8 {
    var out: std.ArrayList(u8) = .empty;
    for (name) |c| {
        const kept = if (std.ascii.isAlphanumeric(c) or c == '.') c else '-';
        if (kept == '-' and (out.items.len == 0 or out.items[out.items.len - 1] == '-')) continue;
        if (out.items.len == 0 and std.ascii.isDigit(kept)) continue;
        out.append(gpa, kept) catch @panic("OOM");
    }
    const trimmed = std.mem.trimEnd(u8, out.items, "-");
    return if (trimmed.len == 0) "app" else trimmed;
}

test component {
    const gpa = std.testing.allocator;
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const cases = [_][2][]const u8{
        .{ "myapp", "myapp" },
        .{ "minimal_app", "minimal-app" },
        .{ "my  app!!", "my-app" },
        .{ "--9lives", "lives" },
        .{ "Über App", "ber-App" },
        .{ "日本", "app" },
        .{ "", "app" },
    };
    for (cases) |c| try std.testing.expectEqualStrings(c[1], component(arena.allocator(), c[0]));
}
