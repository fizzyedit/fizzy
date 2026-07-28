//! What (if anything) of a completion candidate can honestly be drawn as inline ghost text
//! after the caret. Pure buffer logic, for the same reason as the rest of `textcore/` — the
//! widget owns the actual splicing.

const std = @import("std");
const pairs = @import("pairs.zig");

/// The dimmed suffix to show after the caret for `candidate`, or null when there is nothing
/// that can be shown without misrepresenting it.
///
/// A candidate's text is the **whole** replacement for `[replace_start, replace_end)`, not a
/// suffix of what's already typed: the provider matches fuzzily (`arlst` matches `ArrayList`),
/// so the typed characters generally aren't a removable prefix. Ghost text can only ever
/// *append* after the caret, so it is shown only for candidates where the typed span really is
/// a literal prefix, and only for the part past it. Everything else stays perfectly usable from
/// the dropdown — which shows the full label and accepts via the replace range — it just gets
/// no inline preview, exactly as VSCode behaves.
///
/// Also suppressed mid-word: with the caret at `App|lication`, splicing a candidate in at the
/// cursor renders as `AppApplicationlication`, which reads as corrupted text rather than as a
/// suggestion.
pub fn ghostSuffix(
    text: []const u8,
    cursor: usize,
    candidate: []const u8,
    replace_start: usize,
    replace_end: usize,
) ?[]const u8 {
    if (cursor > text.len) return null;
    if (cursor < text.len and pairs.isWordByte(text[cursor])) return null;

    // Anything else means the candidate isn't anchored at the caret (a stale result, or a
    // provider replacing a span the caret isn't at the end of) — there's no position at which
    // appending its text would read correctly.
    if (replace_end != cursor) return null;
    if (replace_start > replace_end or replace_end > text.len) return null;

    const typed = text[replace_start..replace_end];
    if (typed.len > candidate.len) return null;
    if (!std.mem.eql(u8, candidate[0..typed.len], typed)) return null;

    const suffix = candidate[typed.len..];
    return if (suffix.len == 0) null else suffix;
}

// -- tests --------------------------------------------------------------------------------------

const testing = std.testing;

test "shows only the untyped remainder" {
    // `s|` with candidate `std` → ghost `td`, not `std`.
    try testing.expectEqualStrings("td", ghostSuffix("s", 1, "std", 0, 1).?);
    try testing.expectEqualStrings("d", ghostSuffix("st", 2, "std", 0, 2).?);
    // Nothing typed yet: the whole candidate is the remainder.
    try testing.expectEqualStrings("std", ghostSuffix("", 0, "std", 0, 0).?);
}

test "no ghost when the candidate is fully typed" {
    try testing.expectEqual(@as(?[]const u8, null), ghostSuffix("std", 3, "std", 0, 3));
}

test "no ghost in the middle of a word" {
    // `App|lication` must not render as `AppApplicationlication`.
    try testing.expectEqual(@as(?[]const u8, null), ghostSuffix("Application", 3, "Application", 0, 3));
}

test "no ghost for a fuzzy match the caret text does not literally prefix" {
    try testing.expectEqual(@as(?[]const u8, null), ghostSuffix("arlst", 5, "ArrayList", 0, 5));
    // Case-differing prefixes count as fuzzy too — accepting still works via the replace range.
    try testing.expectEqual(@as(?[]const u8, null), ghostSuffix("ar", 2, "ArrayList", 0, 2));
}

test "no ghost for a candidate not anchored at the caret" {
    // Replace range ends before the caret (stale result).
    try testing.expectEqual(@as(?[]const u8, null), ghostSuffix("std.", 4, "std", 0, 3));
    // Out of range spans are rejected rather than trusted.
    try testing.expectEqual(@as(?[]const u8, null), ghostSuffix("st", 9, "std", 0, 9));
    try testing.expectEqual(@as(?[]const u8, null), ghostSuffix("st", 2, "std", 2, 1));
}

test "ghost is allowed before punctuation and whitespace" {
    try testing.expectEqualStrings("td", ghostSuffix("s)", 1, "std", 0, 1).?);
    try testing.expectEqualStrings("td", ghostSuffix("s ", 1, "std", 0, 1).?);
}
