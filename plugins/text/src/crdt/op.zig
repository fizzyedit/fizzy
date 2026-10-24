//! The operations a replica sends: what two replicas exchange and nothing else.
//!
//! An insert carries its own `Id` and the two neighbours it was typed between (its origins), so a
//! receiver can place it with no knowledge of the sender's list. A delete names the character it
//! tombstones.

const std = @import("std");

/// One character's name for ever: the replica that typed it and that replica's running count.
/// Counters of one replica are consecutive from 0, which is what lets a receiver find an item by
/// id with an array lookup and demand causal order per replica.
pub const Id = struct {
    replica: u32,
    counter: u32,

    /// The start of the text: the left origin of a character typed at position 0.
    pub const root: Id = .{ .replica = std.math.maxInt(u32), .counter = 0 };

    pub fn eql(a: Id, b: Id) bool {
        return a.replica == b.replica and a.counter == b.counter;
    }

    /// The tie-break between concurrent siblings: lower sorts first, on every replica alike.
    pub fn order(a: Id, b: Id) std.math.Order {
        const r = std.math.order(a.replica, b.replica);
        return if (r != .eq) r else std.math.order(a.counter, b.counter);
    }
};

pub const Insert = struct {
    id: Id,
    /// A Unicode scalar value. A character is the unit, so concurrent edits never split a
    /// multi-byte sequence.
    ch: u21,
    /// The visible-or-tombstoned neighbour to the left when typed; `Id.root` at the start.
    left: Id,
    /// The neighbour to the right when typed; null at the end.
    right: ?Id,
};

pub const Op = union(enum) {
    insert: Insert,
    /// Tombstones the character; applying it twice is the same as once.
    delete: Id,
};
