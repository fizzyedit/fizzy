//! Where Report a Bug goes when the build isn't told (`-Dapp-issues-url`). std-only, so the rule
//! is tested in `zig build test` (`fizzy-issues-url-tests`) although the build is its only user.

const std = @import("std");

pub const fizzy_issues = "https://github.com/fizzyedit/fizzy/issues";

/// The issues page of the repo an app named (`-Drepo-url`, null when it named none), trimmed of
/// trailing slashes and `.git`; else fizzy's own, for fizzy itself; else empty, which disables
/// Report a Bug. `repo-url` itself defaults to fizzy's (it is the update feed), so only an
/// explicit one says where an app's reports go.
pub fn derive(gpa: std.mem.Allocator, repo: ?[]const u8, is_fizzy: bool) ![]const u8 {
    var r = repo orelse "";
    while (std.mem.endsWith(u8, r, "/")) r = r[0 .. r.len - 1];
    if (std.mem.endsWith(u8, r, ".git")) r = r[0 .. r.len - ".git".len];
    if (r.len > 0) return std.fmt.allocPrint(gpa, "{s}/issues", .{r});
    return if (is_fizzy) fizzy_issues else "";
}

test derive {
    const gpa = std.testing.allocator;
    const cases = [_]struct { repo: ?[]const u8, is_fizzy: bool, want: []const u8 }{
        .{ .repo = "https://github.com/me/app", .is_fizzy = false, .want = "https://github.com/me/app/issues" },
        .{ .repo = "https://github.com/me/app//", .is_fizzy = false, .want = "https://github.com/me/app/issues" },
        .{ .repo = "https://github.com/me/app.git", .is_fizzy = false, .want = "https://github.com/me/app/issues" },
        .{ .repo = "https://github.com/me/app.git/", .is_fizzy = false, .want = "https://github.com/me/app/issues" },
        .{ .repo = "https://github.com/me/toolkit", .is_fizzy = false, .want = "https://github.com/me/toolkit/issues" },
        .{ .repo = "", .is_fizzy = false, .want = "" },
        .{ .repo = "", .is_fizzy = true, .want = fizzy_issues },
        .{ .repo = null, .is_fizzy = false, .want = "" },
        .{ .repo = null, .is_fizzy = true, .want = fizzy_issues },
    };
    for (cases) |c| {
        const got = try derive(gpa, c.repo, c.is_fizzy);
        defer if (got.len > 0 and got.ptr != fizzy_issues.ptr) gpa.free(got);
        try std.testing.expectEqualStrings(c.want, got);
    }
}
