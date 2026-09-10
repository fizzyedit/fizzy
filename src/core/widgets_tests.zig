//! Test root for the widgets that need a real dvui `Window` rather than pure logic.
//!
//! It exists only to sit **one directory above** `widgets/`, so the module path covers both
//! `widgets/SplitBox.zig` and the `../split_layout.zig` it imports. Zig collects `test` blocks
//! from every file reachable from a root by relative import, and forbids a relative import that
//! escapes the root's directory — rooting straight at `SplitBox.zig` hits the second rule.
const std = @import("std");

pub const SplitBox = @import("widgets/SplitBox.zig");

test {
    std.testing.refAllDecls(@This());
    _ = SplitBox;
}
