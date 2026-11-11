//! The local time's offset from UTC, in seconds east of UTC, as it is now: the same unit as SDL's
//! `SDL_DateTime.utc_offset`. Decided from numbers alone so it tests without a Window;
//! `core.platform` holds the live value.
const std = @import("std");

/// The widest offset accepted: real zones span -12 h to +14 h.
pub const max_s: i32 = 18 * 3600;

/// `Date.getTimezoneOffset()`, which is minutes WEST of UTC, as seconds east; null when it is
/// out of range.
pub fn fromJsMinutes(js: i32) ?i32 {
    const s = -@as(i64, js) * 60;
    if (@abs(s) > max_s) return null;
    return @intCast(s);
}

test fromJsMinutes {
    try std.testing.expectEqual(@as(?i32, -21600), fromJsMinutes(360)); // US Central, standard
    try std.testing.expectEqual(@as(?i32, 19800), fromJsMinutes(-330)); // India
    try std.testing.expectEqual(@as(?i32, 20700), fromJsMinutes(-345)); // Nepal
    try std.testing.expectEqual(@as(?i32, 0), fromJsMinutes(0));
    try std.testing.expectEqual(@as(?i32, null), fromJsMinutes(1100));
    try std.testing.expectEqual(@as(?i32, null), fromJsMinutes(-1100));
}
