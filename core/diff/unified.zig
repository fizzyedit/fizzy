//! Standard unified diff (`@@ -a,l +b,l @@`) of two texts from their hunks: what `patch` and
//! `git apply` accept and what an agent reads best, sized by a byte cap.
const std = @import("std");
const Text = @import("Text.zig");

pub const Options = struct {
    /// Unchanged lines kept around each change.
    context: u32 = 3,
    /// Stop before the hunk group that would pass this many bytes (0: no limit). The output ends
    /// with a line saying how many hunks were left out; a group is never cut in half, so the
    /// output stays a valid patch, and the first group is dropped too if it alone is over.
    max_bytes: usize = 0,
};

/// Write `hunks` (from `Text.diff(a, b)`) as a unified diff headed by the two names. Returns
/// how many hunks the cap left out.
pub fn write(gpa: std.mem.Allocator, w: *std.Io.Writer, a_name: []const u8, b_name: []const u8, a: []const u8, b: []const u8, hunks: []const Text.Hunk, opts: Options) (std.Io.Writer.Error || std.mem.Allocator.Error)!u32 {
    if (hunks.len == 0) return 0;
    var head: std.Io.Writer.Allocating = .init(gpa);
    defer head.deinit();
    try head.writer.print("--- {s}\n+++ {s}\n", .{ a_name, b_name });
    var written = head.written().len;
    try w.writeAll(head.written());

    var group: std.Io.Writer.Allocating = .init(gpa);
    defer group.deinit();
    var i: usize = 0;
    while (i < hunks.len) {
        // Hunks whose context would touch belong to one `@@` group.
        var end = i + 1;
        while (end < hunks.len and gapLines(hunks[end - 1], hunks[end]) <= 2 * opts.context) end += 1;
        group.clearRetainingCapacity();
        try writeGroup(&group.writer, a, b, hunks[i..end], opts.context);
        if (opts.max_bytes != 0 and written + group.written().len + trailer_room > opts.max_bytes) {
            const left: u32 = @intCast(hunks.len - i);
            try w.print("... {d} more hunk{s}\n", .{ left, if (left == 1) "" else "s" });
            return left;
        }
        try w.writeAll(group.written());
        written += group.written().len;
        i = end;
    }
    return 0;
}

/// Bytes kept free for the "... N more hunks" line.
const trailer_room = 32;

fn gapLines(prev: Text.Hunk, next: Text.Hunk) u32 {
    return next.a_start - (prev.a_start + prev.a_len);
}

/// Where the line `n` lines before byte `at` (a line start) begins, not before the text's start.
fn backLines(text: []const u8, at: usize, n: u32) usize {
    var pos = at;
    var left = n;
    while (left > 0 and pos > 0) : (left -= 1) {
        pos = if (std.mem.findScalarLast(u8, text[0 .. pos - 1], '\n')) |nl| nl + 1 else 0;
    }
    return pos;
}

/// Where the text `n` lines past byte `at` ends (the end of text at most).
fn forwardLines(text: []const u8, at: usize, n: u32) usize {
    var pos = at;
    var left = n;
    while (left > 0 and pos < text.len) : (left -= 1) {
        pos = if (std.mem.findScalarPos(u8, text, pos, '\n')) |nl| nl + 1 else text.len;
    }
    return pos;
}

fn lineCount(text: []const u8) u32 {
    return @intCast(std.mem.countScalar(u8, text, '\n') + @intFromBool(text.len > 0 and text[text.len - 1] != '\n'));
}

fn writeGroup(w: *std.Io.Writer, a: []const u8, b: []const u8, hunks: []const Text.Hunk, context: u32) !void {
    const first = hunks[0];
    const last = hunks[hunks.len - 1];
    const lead = backLines(a, first.a_byte, context);
    const lead_lines = lineCount(a[lead..first.a_byte]);
    const trail = forwardLines(a, last.a_end, context);
    var a_n: u32 = lead_lines + lineCount(a[last.a_end..trail]);
    var b_n: u32 = a_n;
    for (hunks, 0..) |h, k| {
        a_n += h.a_len;
        b_n += h.b_len;
        // Between hunks the context counts on both sides.
        if (k > 0) {
            const gap = gapLines(hunks[k - 1], h);
            a_n += gap;
            b_n += gap;
        }
    }
    try w.writeAll("@@ -");
    try span(w, first.a_start - lead_lines, a_n);
    try w.writeAll(" +");
    try span(w, first.b_start - lead_lines, b_n);
    try w.writeAll(" @@\n");

    var at = lead;
    for (hunks) |h| {
        try lines(w, ' ', a[at..h.a_byte]);
        try lines(w, '-', a[h.a_byte..h.a_end]);
        try lines(w, '+', b[h.b_byte..h.b_end]);
        at = h.a_end;
    }
    try lines(w, ' ', a[at..trail]);
}

/// `start,len` as unified diff writes it: 1-based, the line before for an empty range, and
/// no length when it is one.
fn span(w: *std.Io.Writer, from: u32, len: u32) !void {
    if (len == 0) return w.print("{d},0", .{from});
    if (len == 1) return w.print("{d}", .{from + 1});
    try w.print("{d},{d}", .{ from + 1, len });
}

fn lines(w: *std.Io.Writer, mark: u8, text: []const u8) !void {
    var at: usize = 0;
    while (at < text.len) {
        const end = if (std.mem.findScalarPos(u8, text, at, '\n')) |nl| nl + 1 else text.len;
        try w.writeByte(mark);
        try w.writeAll(text[at..end]);
        if (text[end - 1] != '\n') try w.writeAll("\n\\ No newline at end of file\n");
        at = end;
    }
}
