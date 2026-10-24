//! A sequence CRDT for the text plugin: the prototype of live collaboration's core, with no
//! network, no UI and no link to the document yet.
//!
//! This file is the test root; the property tests live in `tests.zig`. std-only (see `Replica`).

pub const op = @import("op.zig");
pub const Replica = @import("Replica.zig");
pub const Id = op.Id;
pub const Op = op.Op;
pub const Insert = op.Insert;

test {
    _ = @import("tests.zig");
    _ = @import("bench.zig");
}
