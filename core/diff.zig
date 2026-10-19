//! Diffing, std-only so plugins, the web and a plain test root all use it
//! (`plans/DIFF_PLAN.md`). `Text` is the line diff over a reusable scratch, `unified` writes
//! its hunks as a patch.
pub const Text = @import("diff/Text.zig");
pub const unified = @import("diff/unified.zig");

test {
    _ = Text;
    _ = unified;
    _ = @import("diff/tests.zig");
}
