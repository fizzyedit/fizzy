//! Headless text-editing model for the `text` plugin.
//!
//! **Invariant: nothing under `textcore/` may import `dvui`.** Two reasons:
//!
//! 1. Editing and motion stop depending on layout state that resolves a frame late. dvui's
//!    `TextLayoutWidget.Selection` becomes a *projection* written before layout each frame,
//!    never the source of truth (`Selection.toDvui`). The one place layout legitimately owns
//!    a change is mouse hit-testing, which is lifted back via `Selection.fromDvui`.
//! 2. It keeps this module pure enough to sit in the `addTest`-per-pure-root list in
//!    `build/app.zig`, so the logic is unit-tested without a window or a GPU.
//!
//! This file is the single test root — Zig collects `test` blocks only from files in an
//! artifact's root module, and relative `@import`s (unlike named ones) are part of that same
//! module, so one `addTest` rooted here covers every file below.

const std = @import("std");

pub const Range = @import("Range.zig");
pub const Selection = @import("Selection.zig");
pub const LineIndex = @import("LineIndex.zig");
pub const movement = @import("movement.zig");
pub const Transaction = @import("Transaction.zig");
pub const History = @import("History.zig");
pub const pairs = @import("pairs.zig");
pub const completion = @import("completion.zig");

pub const Granularity = movement.Granularity;
pub const Dir = movement.Dir;
pub const MoveOpts = movement.Opts;

test {
    std.testing.refAllDecls(@This());
    _ = Range;
    _ = Selection;
    _ = LineIndex;
    _ = movement;
    _ = Transaction;
    _ = History;
    _ = pairs;
    _ = completion;
}
