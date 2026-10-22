//! Where a macOS app bundle runs from, and what that means for it: whether it can update in
//! place, whether to offer to move it to /Applications, and what happens to the copy it leaves.
//!
//! std-only and free of the system, so each rule tests on any host. What only macOS can say (the
//! executable's path, whether Gatekeeper translocated it, where the translocated copy came from)
//! is asked by `macos_bundle.zig` and handed in here.

const std = @import("std");

/// Where a bundle sits, by the rules below.
pub const Place = enum {
    /// Under /Applications.
    applications,
    /// Under the user's own ~/Applications.
    user_applications,
    /// Gatekeeper runs it from a randomized read-only mount (App Translocation): a quarantined
    /// bundle opened from where it was downloaded or unpacked, never moved by the user.
    translocated,
    /// On a mounted volume: an opened disk image, or another disk.
    volume,
    /// In the user's ~/Downloads.
    downloads,
    /// Anywhere else: the Desktop, a project folder.
    elsewhere,
};

/// What becomes of the copy a move leaves behind.
pub const Leftover = enum {
    /// Left where it is: a disk image's copy goes when the image is ejected, and a copy anywhere
    /// but Downloads is one the user put there on purpose.
    keep,
    /// Moved to the Trash, from where the user can put it back. Never deleted outright.
    trash,
};

/// The app bundle that holds `exe_path`: the path up to and including the `.app` whose
/// `Contents/MacOS/` holds the executable. Null for a loose executable. A slice of `exe_path`.
pub fn bundlePath(exe_path: []const u8) ?[]const u8 {
    const marker = ".app/Contents/MacOS/";
    const at = std.mem.findLast(u8, exe_path, marker) orelse return null;
    return exe_path[0 .. at + ".app".len];
}

/// Where `bundle` sits. `home` is the user's home folder, null when unknown; `translocated` is
/// the system's answer for it (`macos_bundle.isTranslocated`).
pub fn classify(bundle: []const u8, home: ?[]const u8, translocated: bool) Place {
    // The system's answer, and the mount's own name as a backstop for when it cannot be asked.
    if (translocated or std.mem.find(u8, bundle, "/AppTranslocation/") != null) return .translocated;
    if (under(bundle, "/Applications")) return .applications;
    if (under(bundle, "/Volumes")) return .volume;
    if (home) |h| {
        if (underHome(bundle, h, "Applications")) return .user_applications;
        if (underHome(bundle, h, "Downloads")) return .downloads;
    }
    return .elsewhere;
}

/// An install that can update in place: one in an Applications folder, which the updater
/// writes into. A translocated copy is read-only and is gone at the next launch.
pub fn updatable(place: Place) bool {
    return place == .applications or place == .user_applications;
}

/// Whether to offer the move: anywhere it cannot update, unless the user said not now to this
/// version (`declined_version`, null when never).
pub fn offers(place: Place, version: []const u8, declined_version: ?[]const u8) bool {
    if (updatable(place)) return false;
    const declined = declined_version orelse return true;
    return !std.mem.eql(u8, declined, version);
}

/// What to do with the copy left behind. `original` is where the bundle was before Gatekeeper
/// translocated it, or where it runs from when it was not.
pub fn leftover(original: Place) Leftover {
    return if (original == .downloads) .trash else .keep;
}

/// `/Applications/<name>.app` for `bundle`, written into `buf`. The bundle keeps its own name, so
/// each app built on fizzy lands under its own.
pub fn destination(buf: []u8, bundle: []const u8) error{NoSpaceLeft}![]const u8 {
    return std.mem.print(buf, "/Applications/{s}", .{std.fs.path.basename(bundle)});
}

fn under(path: []const u8, dir: []const u8) bool {
    return std.mem.startsWith(u8, path, dir) and path.len > dir.len and path[dir.len] == '/';
}

fn underHome(path: []const u8, home: []const u8, sub: []const u8) bool {
    const h = std.mem.trimEnd(u8, home, "/");
    if (!under(path, h)) return false;
    return under(path[h.len + 1 ..], sub);
}

const test_home = "/Users/ada";

test "bundlePath finds the bundle around the executable" {
    try std.testing.expectEqualStrings("/Applications/Fizzy.app", bundlePath("/Applications/Fizzy.app/Contents/MacOS/fizzy").?);
    // A helper app nested in the bundle: the innermost bundle holds the executable.
    try std.testing.expectEqualStrings(
        "/Applications/Outer.app/Contents/Helpers/Inner.app",
        bundlePath("/Applications/Outer.app/Contents/Helpers/Inner.app/Contents/MacOS/inner").?,
    );
    try std.testing.expect(bundlePath("/Users/ada/dev/fizzy/zig-out/bin/fizzy") == null);
}

test "a translocated bundle is translocated wherever its path points" {
    const p = "/private/var/folders/xy/abc/T/AppTranslocation/1234-ABCD/d/Fizzy.app";
    try std.testing.expectEqual(Place.translocated, classify(p, test_home, false));
    try std.testing.expectEqual(Place.translocated, classify("/Users/ada/Downloads/Fizzy.app", test_home, true));
    try std.testing.expect(!updatable(.translocated));
    try std.testing.expect(offers(.translocated, "1.0.0", null));
}

test "/Applications updates and is never offered the move" {
    const place = classify("/Applications/Fizzy.app", test_home, false);
    try std.testing.expectEqual(Place.applications, place);
    try std.testing.expect(updatable(place));
    try std.testing.expect(!offers(place, "1.0.0", null));
    // A folder of its own inside /Applications is still under it.
    try std.testing.expectEqual(Place.applications, classify("/Applications/Tools/Fizzy.app", test_home, false));
    // A name that only starts like it is not.
    try std.testing.expectEqual(Place.elsewhere, classify("/ApplicationsOld/Fizzy.app", test_home, false));
}

test "~/Applications updates and is never offered the move" {
    const place = classify("/Users/ada/Applications/Fizzy.app", test_home, false);
    try std.testing.expectEqual(Place.user_applications, place);
    try std.testing.expect(!offers(place, "1.0.0", null));
    try std.testing.expectEqual(Place.user_applications, classify("/Users/ada/Applications/Fizzy.app", test_home ++ "/", false));
}

test "a disk image's copy is offered the move and kept after it" {
    const place = classify("/Volumes/Fizzy 1.0/Fizzy.app", test_home, false);
    try std.testing.expectEqual(Place.volume, place);
    try std.testing.expect(offers(place, "1.0.0", null));
    try std.testing.expectEqual(Leftover.keep, leftover(place));
}

test "a copy in Downloads is offered the move and trashed after it" {
    const place = classify("/Users/ada/Downloads/Fizzy.app", test_home, false);
    try std.testing.expectEqual(Place.downloads, place);
    try std.testing.expect(offers(place, "1.0.0", null));
    try std.testing.expectEqual(Leftover.trash, leftover(place));
    // Unknown home: nothing is taken for Downloads, so nothing is trashed.
    try std.testing.expectEqual(Leftover.keep, leftover(classify("/Users/ada/Downloads/Fizzy.app", null, false)));
}

test "anywhere else is offered the move and kept after it" {
    const place = classify("/Users/ada/Desktop/Fizzy.app", test_home, false);
    try std.testing.expectEqual(Place.elsewhere, place);
    try std.testing.expect(offers(place, "1.0.0", null));
    try std.testing.expectEqual(Leftover.keep, leftover(place));
}

test "a translocated copy of an install already in /Applications updates once it runs from there" {
    // Moved there by a tool that kept the quarantine flag: Gatekeeper still translocates it.
    try std.testing.expectEqual(Place.translocated, classify("/Users/ada/x/AppTranslocation/1/d/Fizzy.app", test_home, false));
    try std.testing.expect(updatable(classify("/Applications/Fizzy.app", test_home, false)));
}

test "not now holds until the version changes" {
    try std.testing.expect(!offers(.downloads, "1.0.0", "1.0.0"));
    try std.testing.expect(offers(.downloads, "1.0.1", "1.0.0"));
}

test "destination keeps the bundle's own name" {
    var buf: [64]u8 = undefined;
    try std.testing.expectEqualStrings("/Applications/Other App.app", try destination(&buf, "/Volumes/Other/Other App.app"));
}
