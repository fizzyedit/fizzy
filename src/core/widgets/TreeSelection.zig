//! Helpers for multi-selection gestures in tree-style lists.
//!
//! The TreeWidget itself is selection-agnostic: consumers (layer list, animation list, frame list,
//! file tree) own their own selected-id sets. This file provides the small amount of shared logic
//! needed to keep click/modifier behavior consistent across the editor:
//!
//! * Plain click         -> replace selection with the clicked item
//! * Ctrl/Cmd click      -> toggle the clicked item in selection
//! * Shift click         -> extend selection from anchor (or primary) to clicked item
//!
//! Selections are modeled as a sorted, deduplicated slice of `usize`s. For index-based lists
//! (layers, animations, frames) the values are positions in the underlying `MultiArrayList`. For
//! the file tree the values are the path hashes the tree already uses as branch ids.

const std = @import("std");
const dvui = @import("dvui");

/// Describes how a click should change the selection set.
pub const ClickMode = enum {
    /// Plain click (no modifiers): selection becomes just the clicked item.
    replace,
    /// Ctrl/Cmd click: flip the clicked item's membership in the selection set.
    toggle,
    /// Shift click: contiguous range from anchor (or current primary) through the clicked item.
    extend,
};

pub fn clickModeFromMod(mod: dvui.enums.Mod) ClickMode {
    if (mod.shift()) return .extend;
    if (mod.control() or mod.command()) return .toggle;
    return .replace;
}

pub const ApplyResult = struct {
    /// The new primary (anchor for subsequent extend clicks; also the "single" fallback index for
    /// consumers that still need one focal item). Null only when `require_primary` is false and
    /// the final selection is empty.
    primary: ?usize,
    /// Shift-range anchor to store for the next `extend` click. Usually equal to `primary`.
    anchor: ?usize,
};

/// Apply a single-item click to an existing usize-indexed selection.
/// * `selected` is the caller's current selection (sorted, deduplicated). It is read-only here.
/// * `primary_opt` is the caller's current "primary" index, if any.
/// * `anchor_opt` is the last anchor stored for shift-range (often equals `primary_opt`).
/// * `clicked` is the index of the row the user just pressed/released on.
/// * `mode` is derived from the mouse event's modifier state via `clickModeFromMod`.
/// * `require_primary` when true guarantees the returned selection is never empty (ctrl-click
///    on the only selected item is a no-op instead of deselecting). Used for lists like
///    `layers` where the editor always needs a single focal item.
/// * `out` is an ArrayList the caller has already cleared; we append the new selection sorted.
pub fn applyClickUsize(
    gpa: std.mem.Allocator,
    selected: []const usize,
    primary_opt: ?usize,
    anchor_opt: ?usize,
    clicked: usize,
    mode: ClickMode,
    require_primary: bool,
    out: *std.ArrayList(usize),
) !ApplyResult {
    switch (mode) {
        .replace => {
            try out.append(gpa, clicked);
            return .{ .primary = clicked, .anchor = clicked };
        },
        .toggle => {
            var found: bool = false;
            for (selected) |i| {
                if (i == clicked) {
                    found = true;
                } else {
                    try out.append(gpa, i);
                }
            }
            if (!found) try out.append(gpa, clicked);
            std.sort.pdq(usize, out.items, {}, std.sort.asc(usize));

            if (out.items.len == 0) {
                if (require_primary) {
                    try out.append(gpa, clicked);
                    return .{ .primary = clicked, .anchor = clicked };
                }
                return .{ .primary = null, .anchor = clicked };
            }

            if (primary_opt) |p| {
                for (out.items) |i| if (i == p) return .{ .primary = p, .anchor = clicked };
            }
            for (out.items) |i| if (i == clicked) return .{ .primary = clicked, .anchor = clicked };
            return .{ .primary = out.items[0], .anchor = clicked };
        },
        .extend => {
            const anchor = anchor_opt orelse primary_opt orelse clicked;
            const lo = if (anchor < clicked) anchor else clicked;
            const hi = if (anchor < clicked) clicked else anchor;
            var i: usize = lo;
            while (i <= hi) : (i += 1) try out.append(gpa, i);
            return .{ .primary = clicked, .anchor = anchor };
        },
    }
}

/// Given a sorted list of source indices that are about to be removed from a linear list, and the
/// "insert before" target index expressed against the ORIGINAL list, compute the new insertion
/// index after the sources have been pulled out. This is the canonical multi-drop math used by
/// typical file trees (the moved rows are inserted contiguously at the target, preserving their
/// relative order).
pub fn adjustInsertBeforeForRemovals(sorted_removed: []const usize, insert_before: usize) usize {
    var shift: usize = 0;
    for (sorted_removed) |r| {
        if (r < insert_before) shift += 1 else break;
    }
    return insert_before - shift;
}

test {
    @import("std").testing.refAllDecls(@This());
}
