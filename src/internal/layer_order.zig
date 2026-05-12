//! Pure layer-list reorder algorithm.
//!
//! Extracted from `internal/File.zig` so `zig build test` can exercise
//! it without pulling in dvui / fizzy globals. Re-exported by File.zig
//! as `layerOrderAfterMove`.
//!
//! Mirrors the drop-handling logic in `editor/explorer/tools.zig`: given
//! a logical "remove element at index `removed`, then insert it before
//! position `insert_before`" operation, fill `out[0..len]` with the new
//! position-to-storage-index mapping (position 0 = top of stack).

const std = @import("std");

/// Maximum list length supported by the in-place implementation.
/// Layers in fizzy are bounded well below this; raising it just bumps
/// the stack-allocated scratch buffer.
pub const max_len: usize = 1024;

pub fn layerOrderAfterMove(
    len: usize,
    removed: usize,
    insert_before: usize,
    out: []usize,
) void {
    std.debug.assert(out.len >= len);
    std.debug.assert(removed < len);
    std.debug.assert(insert_before <= len);
    if (removed == insert_before) {
        for (0..len) |i| out[i] = i;
        return;
    }
    const insert_pos = if (removed < insert_before) insert_before - 1 else insert_before;
    var tmp: [max_len]usize = undefined;
    std.debug.assert(len <= tmp.len);
    var m: usize = 0;
    for (0..len) |i| {
        if (i == removed) continue;
        tmp[m] = i;
        m += 1;
    }
    var ti: usize = 0;
    for (0..len) |dst| {
        if (dst == insert_pos) {
            out[dst] = removed;
        } else {
            out[dst] = tmp[ti];
            ti += 1;
        }
    }
}

const expectEqualSlices = std.testing.expectEqualSlices;

test "layerOrderAfterMove no-op when removed == insert_before" {
    var out: [5]usize = undefined;
    layerOrderAfterMove(5, 2, 2, &out);
    try expectEqualSlices(usize, &.{ 0, 1, 2, 3, 4 }, &out);
}

test "layerOrderAfterMove first to last" {
    // Move element 0 to insert before position 5 (i.e. the end).
    var out: [5]usize = undefined;
    layerOrderAfterMove(5, 0, 5, &out);
    try expectEqualSlices(usize, &.{ 1, 2, 3, 4, 0 }, &out);
}

test "layerOrderAfterMove last to first" {
    // Move element 4 to the very front.
    var out: [5]usize = undefined;
    layerOrderAfterMove(5, 4, 0, &out);
    try expectEqualSlices(usize, &.{ 4, 0, 1, 2, 3 }, &out);
}

test "layerOrderAfterMove forward middle" {
    // Move index 1 to before position 4 (slides past indexes 2 and 3).
    // Because removed (1) < insert_before (4), the insert position
    // collapses to 4 - 1 = 3 after the removal.
    var out: [5]usize = undefined;
    layerOrderAfterMove(5, 1, 4, &out);
    try expectEqualSlices(usize, &.{ 0, 2, 3, 1, 4 }, &out);
}

test "layerOrderAfterMove backward middle" {
    // Move index 3 to before position 1 (i.e. earlier in the list).
    var out: [5]usize = undefined;
    layerOrderAfterMove(5, 3, 1, &out);
    try expectEqualSlices(usize, &.{ 0, 3, 1, 2, 4 }, &out);
}

test "layerOrderAfterMove single-element list is a no-op" {
    var out: [1]usize = undefined;
    layerOrderAfterMove(1, 0, 0, &out);
    try expectEqualSlices(usize, &.{0}, &out);
}

test "layerOrderAfterMove permutation is always a valid permutation" {
    // Every output should be a permutation of 0..len. Sweep all
    // (removed, insert_before) pairs for a small list.
    const len: usize = 6;
    var out: [len]usize = undefined;
    var seen: [len]bool = undefined;
    var removed: usize = 0;
    while (removed < len) : (removed += 1) {
        var insert_before: usize = 0;
        while (insert_before <= len) : (insert_before += 1) {
            layerOrderAfterMove(len, removed, insert_before, &out);
            @memset(&seen, false);
            for (out) |idx| {
                try std.testing.expect(idx < len);
                try std.testing.expect(!seen[idx]);
                seen[idx] = true;
            }
        }
    }
}
