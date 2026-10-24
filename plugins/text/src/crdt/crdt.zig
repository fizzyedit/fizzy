//! A sequence CRDT for the text plugin: the prototype of live collaboration's core, with no
//! network, no UI and no link to the document yet.
//!
//! This file is the test root; the property tests live in `tests.zig`. std-only (see `Replica`).
//!
//! Seams for the step that wires it to the document and the history tracks (design/history.md):
//! - An op carries its own `Id` and origins and is plain data, so the text owner can record a
//!   transaction's ops as one `sdk.Step` under a new `step_format`; a replay applies the recorded
//!   ids, it never re-derives them from a `Transaction`.
//! - `captureDocumentState` will carry the items (ids, origins, tombstones) and `pending`; the
//!   items are flat and append-only, so a state deltas and slices cheaply.
//! - An op has no author. `Id.replica` maps to the host's `Author` in the document's state.

pub const op = @import("op.zig");
pub const Replica = @import("Replica.zig");
pub const Id = op.Id;
pub const Op = op.Op;
pub const Insert = op.Insert;

test {
    _ = @import("tests.zig");
    _ = @import("bench.zig");
}
