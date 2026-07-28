//! The fixed Fizzy accent palette — independent of the active `dvui.Theme`.
//!
//! Used anywhere identity should stay stable across theme switches: rainbow bracket
//! nesting in the text editor, file-tree row / icon tints in the workbench, etc. Themes
//! still own chrome (fills, borders, selection); this table owns the "which of N accents"
//! question, so switching from Fizzy Dark to Adwaita Light doesn't reshuffle the file tree
//! or recolor every nested brace.
//!
//! Colours are chosen to read on both dark and light content fills — saturated enough to
//! tell apart at a glance, not so neon that they fight syntax highlighting.

const dvui = @import("dvui");

/// Soft red, amber, gold, green, blue, purple, cyan — cycles via `at`.
pub const colors = [_]dvui.Color{
    .{ .r = 224, .g = 108, .b = 117, .a = 255 },
    .{ .r = 209, .g = 154, .b = 102, .a = 255 },
    .{ .r = 229, .g = 192, .b = 123, .a = 255 },
    .{ .r = 152, .g = 195, .b = 121, .a = 255 },
    .{ .r = 97, .g = 175, .b = 239, .a = 255 },
    .{ .r = 198, .g = 120, .b = 221, .a = 255 },
    .{ .r = 86, .g = 182, .b = 194, .a = 255 },
};

/// `index` wraps — nesting depth 7 is the same colour as depth 0, file-tree row 7 the same
/// as row 0. Empty `colors` is impossible (the array is a compile-time constant), so the
/// modulo is always well-defined.
pub fn at(index: usize) dvui.Color {
    return colors[index % colors.len];
}

/// Scrambled walk through `colors` for rainbow brackets — same accents as the file tree, but
/// not the same sequence. Indent-0 braces therefore don't double as "file-tree row 0", and the
/// eye reads editor nesting as its own scale rather than a mirror of the explorer.
///
/// Must stay a permutation of `0 .. colors.len` (every colour still appears; no duplicates).
const bracket_order = [_]usize{ 4, 0, 6, 2, 5, 1, 3 };

comptime {
    if (bracket_order.len != colors.len) @compileError("bracket_order must cover every palette colour");
    var seen = [_]bool{false} ** colors.len;
    for (bracket_order) |i| {
        if (i >= colors.len or seen[i]) @compileError("bracket_order must be a permutation of colors indices");
        seen[i] = true;
    }
}

/// Like `at`, but through `bracket_order` — used by the text editor's rainbow brackets only.
pub fn bracket(index: usize) dvui.Color {
    return colors[bracket_order[index % bracket_order.len]];
}
