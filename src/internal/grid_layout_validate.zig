//! Pure validation predicate for proposed grid-layout changes.
//!
//! Mirrors the export size cap (4096×4096) and rejects degenerate proposals before any
//! allocation. Lives in its own std-only file so the editor's grid-layout dialog and
//! `Internal.File.applyGridLayout{,SliceOnly}` can share a single source of truth that's
//! also reachable from `zig build test` without dvui / fizzy globals.
//!
//! Re-exported by `Internal.File.validateGridLayoutProposedDims` for backward compatibility
//! with existing call sites.

const std = @import("std");

/// Maximum exported atlas dimension. Keep aligned with `tools/Packer.zig`'s texture size
/// table — that table tops out at 8192 along the long axis but the editor caps single-axis
/// document size at 4096 so the document can always be exported into a single atlas page.
pub const max_axis: u32 = 4096;

pub fn validateGridLayoutProposedDims(
    column_width: u32,
    row_height: u32,
    columns: u32,
    rows: u32,
) bool {
    if (column_width == 0 or row_height == 0 or columns == 0 or rows == 0) return false;
    const total_w: u64 = @as(u64, column_width) * @as(u64, columns);
    const total_h: u64 = @as(u64, row_height) * @as(u64, rows);
    if (total_w == 0 or total_h == 0) return false;
    if (total_w > max_axis or total_h > max_axis) return false;
    return true;
}

const expect = std.testing.expect;

test "rejects any zero dimension" {
    try expect(!validateGridLayoutProposedDims(0, 16, 1, 1));
    try expect(!validateGridLayoutProposedDims(16, 0, 1, 1));
    try expect(!validateGridLayoutProposedDims(16, 16, 0, 1));
    try expect(!validateGridLayoutProposedDims(16, 16, 1, 0));
}

test "accepts the smallest non-zero proposal" {
    try expect(validateGridLayoutProposedDims(1, 1, 1, 1));
}

test "accepts a tile-sliced layout that fits inside the cap" {
    try expect(validateGridLayoutProposedDims(32, 32, 16, 16)); // 512×512
    try expect(validateGridLayoutProposedDims(64, 64, 32, 32)); // 2048×2048
}

test "accepts the largest dimension exactly at the cap" {
    try expect(validateGridLayoutProposedDims(max_axis, max_axis, 1, 1));
    try expect(validateGridLayoutProposedDims(1, 1, max_axis, max_axis));
}

test "rejects when total width exceeds the cap by one" {
    try expect(!validateGridLayoutProposedDims(max_axis + 1, 1, 1, 1));
    try expect(!validateGridLayoutProposedDims(max_axis, 1, 2, 1));
}

test "rejects when total height exceeds the cap by one" {
    try expect(!validateGridLayoutProposedDims(1, max_axis + 1, 1, 1));
    try expect(!validateGridLayoutProposedDims(1, max_axis, 1, 2));
}

test "rejects multiplications that would overflow u32 (defensive — uses u64 internally)" {
    // column_width * columns would wrap to 0 in u32 arithmetic for these inputs; the predicate
    // must still reject (not silently accept the wrapped value).
    try expect(!validateGridLayoutProposedDims(0xFFFF_FFFF, 1, 2, 1));
    try expect(!validateGridLayoutProposedDims(1, 0xFFFF_FFFF, 1, 2));
}