//! The fixed Fizzy accent palette — independent of the active `dvui.Theme`.
//!
//! Used anywhere identity should stay stable across theme switches: file-tree row / icon
//! tints in the workbench, rainbow bracket nesting in the text editor, etc. Themes still own
//! chrome (fills, borders, selection); these tables own the "which of N accents" question, so
//! switching from Fizzy Dark to Adwaita Light doesn't reshuffle the file tree or recolor every
//! nested brace.
//!
//! Two tables, because the two jobs want opposite things: `colors` is the saturated brand
//! palette for wide tints, `bracket_colors` a muted set sized for one-character glyphs sitting
//! inside syntax highlighting.
//!
//! These are the ten chromatic entries of `fizzy.hex`, in file order, transcribed to code.
//! That file is the Fizzy brand palette and still ships with the pixi plugin, whose
//! `registerFileRowFillColor` resolver feeds the same colours to the file tree when pixi is
//! installed. Keeping this table byte-identical to it is what makes a plain fizzy build look
//! like a fizzy+pixi build — if `fizzy.hex` ever changes, change this with it (order and
//! length both matter: row/bracket index is taken modulo `colors.len`).

const dvui = @import("dvui");

/// `fizzy.hex`: plum, crimson, coral, gold, lime, green, teal, navy, blue, sky — cycles via `at`.
pub const colors = [_]dvui.Color{
    .{ .r = 0x5d, .g = 0x27, .b = 0x5d, .a = 255 },
    .{ .r = 0xb1, .g = 0x3e, .b = 0x53, .a = 255 },
    .{ .r = 0xef, .g = 0x7d, .b = 0x57, .a = 255 },
    .{ .r = 0xff, .g = 0xcd, .b = 0x75, .a = 255 },
    .{ .r = 0xa7, .g = 0xf0, .b = 0x70, .a = 255 },
    .{ .r = 0x38, .g = 0xb7, .b = 0x64, .a = 255 },
    .{ .r = 0x25, .g = 0x71, .b = 0x79, .a = 255 },
    .{ .r = 0x29, .g = 0x36, .b = 0x6f, .a = 255 },
    .{ .r = 0x3b, .g = 0x5d, .b = 0xc9, .a = 255 },
    .{ .r = 0x41, .g = 0xa6, .b = 0xf6, .a = 255 },
};

/// `index` wraps — nesting depth 10 is the same colour as depth 0, file-tree row 10 the same
/// as row 0. Empty `colors` is impossible (the array is a compile-time constant), so the
/// modulo is always well-defined.
pub fn at(index: usize) dvui.Color {
    return colors[index % colors.len];
}

/// Rainbow brackets have their own table rather than reusing `colors`. The brand palette is
/// tuned for wide tints (file-tree rows, sprite swatches) where full saturation reads as
/// identity; at one-character width, behind syntax highlighting, those same hues shout — a
/// nested `{` ends up louder than the keyword next to it. These are the same hue families
/// pulled toward the softer range editors like Zed and the gruvbox / One-dark family use for
/// nesting — deliberately a middle ground, not fully desaturated: enough chroma that depths
/// stay easy to tell apart at a glance, not so much that a wall of nested braces competes
/// with the syntax colours around it.
///
/// Mid-lightness on purpose, so one table serves dark *and* light content fills without
/// either end washing out.
///
/// Adjacent entries alternate warm/cool so consecutive nesting depths never sit on
/// neighbouring hues. Length matters twice: nesting index wraps modulo it, and
/// `textcore.pairs.kindOffset` spaces brace/paren/bracket by +0/+3/+5, which only stay
/// distinct while those offsets don't collide modulo `bracket_colors.len`.
pub const bracket_colors = [_]dvui.Color{
    .{ .r = 0xd9, .g = 0xab, .b = 0x5e, .a = 255 }, // gold
    .{ .r = 0x6f, .g = 0xa9, .b = 0xd4, .a = 255 }, // sky
    .{ .r = 0xdc, .g = 0x8e, .b = 0x6a, .a = 255 }, // coral
    .{ .r = 0x85, .g = 0xbb, .b = 0x74, .a = 255 }, // green
    .{ .r = 0xcd, .g = 0x79, .b = 0x87, .a = 255 }, // rose
    .{ .r = 0x5f, .g = 0xab, .b = 0xab, .a = 255 }, // teal
    .{ .r = 0xb2, .g = 0xbf, .b = 0x6c, .a = 255 }, // olive
    .{ .r = 0x8b, .g = 0x8b, .b = 0xd6, .a = 255 }, // indigo
};

comptime {
    // `kindOffset`'s +0/+3/+5 must land on three different slots at any indent.
    for ([_]usize{ 3, 5, 2 }) |delta| {
        if (delta % bracket_colors.len == 0) @compileError("bracket_colors length collides with pairs.kindOffset spacing");
    }
}

/// Like `at`, but through `bracket_colors` — used by the text editor's rainbow brackets only.
pub fn bracket(index: usize) dvui.Color {
    return bracket_colors[index % bracket_colors.len];
}
