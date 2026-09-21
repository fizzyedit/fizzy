//! A zip archive in and out of `Mem` — the PhysicsFS idea, without the search paths: the user
//! hands over one archive, works on it as a mounted filesystem, and takes the archive back.
//!
//! Reading is done by hand over the byte slice rather than through `std.zip.Iterator`, which
//! wants a `File.Reader`; the archive arrived as bytes (a browser upload) and wasm has no
//! files. The header structs and the end-record finder are `std.zip`'s own. Writing uses the
//! store method only: an archive the user is about to download again is not worth the
//! compressor's time, and every reader accepts it.
//!
//! Not handled, on purpose: zip64 (an archive past 4 GiB is not one to hold in memory),
//! encryption, data descriptors without sizes in the central directory (the central directory
//! always has them), and `__MACOSX/` resource forks, which are skipped.

const std = @import("std");
const zip = std.zip;
const Fs = @import("Fs.zig");
const Mem = @import("mem.zig").Mem;
const Allocator = std.mem.Allocator;

pub const Error = error{
    InvalidArchive,
    Unsupported,
    /// The archive claims more than `max_total_bytes` once inflated — a zip bomb, or simply
    /// more than a page should hold.
    TooLarge,
    OutOfMemory,
};

/// Inflated bytes an archive may claim in total. Every entry's `uncompressed_size` is trusted
/// only up to this sum; the header value is 32-bit, so without it a small archive could ask
/// for 4 GiB per entry.
pub const max_total_bytes: u64 = 1 << 30;

/// Every entry of `bytes` into `mem`, creating parents as needed. Entries that collide with
/// something already there are skipped — an archive unpacked twice is not an error.
pub fn unpackInto(mem: *Mem, bytes: []const u8) Error!void {
    const end = findEndRecord(bytes) orelse return error.InvalidArchive;
    if (end.need_zip64()) return error.Unsupported;

    // All offset arithmetic in u64: on wasm32 `usize` is 32 bits and a crafted
    // `compressed_size` could wrap `data_off + size` back below `data_off`, past the bounds
    // check and into memory beyond the archive.
    const len: u64 = bytes.len;
    var budget: u64 = max_total_bytes;
    var off: u64 = end.central_directory_offset;
    var i: usize = 0;
    while (i < end.record_count_total) : (i += 1) {
        const hdr = readStruct(zip.CentralDirectoryFileHeader, bytes, off) orelse return error.InvalidArchive;
        if (!std.mem.eql(u8, &hdr.signature, &zip.central_file_header_sig)) return error.InvalidArchive;
        const name_off = off + @sizeOf(zip.CentralDirectoryFileHeader);
        const name_end = name_off + hdr.filename_len;
        if (name_end > len) return error.InvalidArchive;
        const raw_name = bytes[@intCast(name_off)..@intCast(name_end)];
        off = name_end + hdr.extra_len + hdr.comment_len;

        if (hdr.flags.encrypted) return error.Unsupported;
        const local = readStruct(zip.LocalFileHeader, bytes, hdr.local_file_header_offset) orelse return error.InvalidArchive;
        if (!std.mem.eql(u8, &local.signature, &zip.local_file_header_sig)) return error.InvalidArchive;
        const data_off: u64 = @as(u64, hdr.local_file_header_offset) + @sizeOf(zip.LocalFileHeader) + local.filename_len + local.extra_len;
        const data_end: u64 = data_off + hdr.compressed_size;
        if (data_end > len) return error.InvalidArchive;
        if (hdr.uncompressed_size > budget) return error.TooLarge;
        budget -= hdr.uncompressed_size;

        const path = try mountPath(mem.allocator, raw_name);
        defer mem.allocator.free(path);
        if (path.len == 0) continue;
        const is_dir = raw_name[raw_name.len - 1] == '/';
        try ensureParents(mem, path);
        if (is_dir) {
            mem.putDir(path) catch |err| switch (err) {
                error.Exists => {},
                error.OutOfMemory => return error.OutOfMemory,
                else => return error.InvalidArchive,
            };
            continue;
        }

        const data = try inflate(mem.allocator, bytes[@intCast(data_off)..@intCast(data_end)], hdr.compression_method, hdr.uncompressed_size);
        defer mem.allocator.free(data);
        mem.put(path, data) catch |err| switch (err) {
            error.Exists => {},
            error.OutOfMemory => return error.OutOfMemory,
            else => return error.InvalidArchive,
        };
    }
}

/// `mem` as a zip archive, store method, entries in path order with directories included so
/// empty ones survive the round trip. Caller owns the bytes.
pub fn pack(allocator: Allocator, mem: *const Mem) Error![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    var central: std.ArrayList(u8) = .empty;
    defer central.deinit(allocator);

    // Sorted so a reader sees parents before children and the archive is reproducible.
    const paths = try allocator.dupe([]const u8, mem.nodes.keys());
    defer allocator.free(paths);
    std.mem.sort([]const u8, paths, {}, struct {
        fn lt(_: void, a: []const u8, b: []const u8) bool {
            return std.mem.lessThan(u8, a, b);
        }
    }.lt);

    var count: u16 = 0;
    for (paths) |path| {
        if (Fs.isRoot(path)) continue;
        const node = mem.nodes.get(path).?;
        const name = try entryName(allocator, path, node.kind == .dir);
        defer allocator.free(name);
        if (name.len > std.math.maxInt(u16) or node.bytes.len > std.math.maxInt(u32)) return error.Unsupported;
        if (out.items.len > std.math.maxInt(u32)) return error.Unsupported;
        if (count == std.math.maxInt(u16)) return error.Unsupported;

        const crc = std.hash.Crc32.hash(node.bytes);
        const offset: u32 = @intCast(out.items.len);
        const local: zip.LocalFileHeader = .{
            .signature = zip.local_file_header_sig,
            .version_needed_to_extract = 20,
            .flags = .{ .encrypted = false, ._ = 0 },
            .compression_method = .store,
            .last_modification_time = 0,
            .last_modification_date = dos_epoch_date,
            .crc32 = crc,
            .compressed_size = @intCast(node.bytes.len),
            .uncompressed_size = @intCast(node.bytes.len),
            .filename_len = @intCast(name.len),
            .extra_len = 0,
        };
        try writeStruct(allocator, &out, local);
        try out.appendSlice(allocator, name);
        try out.appendSlice(allocator, node.bytes);

        const cd: zip.CentralDirectoryFileHeader = .{
            .signature = zip.central_file_header_sig,
            .version_made_by = 20,
            .version_needed_to_extract = 20,
            .flags = .{ .encrypted = false, ._ = 0 },
            .compression_method = .store,
            .last_modification_time = 0,
            .last_modification_date = dos_epoch_date,
            .crc32 = crc,
            .compressed_size = @intCast(node.bytes.len),
            .uncompressed_size = @intCast(node.bytes.len),
            .filename_len = @intCast(name.len),
            .extra_len = 0,
            .comment_len = 0,
            .disk_number = 0,
            .internal_file_attributes = 0,
            // MS-DOS directory bit, which is what most tools key "is a folder" on.
            .external_file_attributes = if (node.kind == .dir) 0x10 else 0,
            .local_file_header_offset = offset,
        };
        try writeStruct(allocator, &central, cd);
        try central.appendSlice(allocator, name);
        count += 1;
    }

    const cd_offset: u32 = @intCast(out.items.len);
    if (central.items.len > std.math.maxInt(u32)) return error.Unsupported;
    try out.appendSlice(allocator, central.items);
    const end: zip.EndRecord = .{
        .signature = zip.end_record_sig,
        .disk_number = 0,
        .central_directory_disk_number = 0,
        .record_count_disk = count,
        .record_count_total = count,
        .central_directory_size = @intCast(central.items.len),
        .central_directory_offset = cd_offset,
        .comment_len = 0,
    };
    try writeStruct(allocator, &out, end);
    return try out.toOwnedSlice(allocator);
}

/// The end-of-central-directory record: the last `PK\x05\x06` in the archive, since a
/// comment may follow it. (`std.zip.EndRecord.findBuffer` exists but does not compile as of
/// 0.16 — it returns an error outside its own set.)
fn findEndRecord(bytes: []const u8) ?zip.EndRecord {
    const pos = std.mem.lastIndexOf(u8, bytes, &zip.end_record_sig) orelse return null;
    return readStruct(zip.EndRecord, bytes, pos);
}

test "truncated and inflated-size-lying archives are refused, not read past" {
    const a = std.testing.allocator;
    var src = try Mem.init(a);
    defer src.deinit();
    try src.put("/a.txt", "hello");
    const good = try pack(a, &src);
    defer a.free(good);

    // Chop the data out from under the central directory's offsets.
    var dst = try Mem.init(a);
    defer dst.deinit();
    try std.testing.expectError(error.InvalidArchive, unpackInto(&dst, good[0 .. good.len - 30]));

    // Lie about the inflated size past the budget.
    const bad = try a.dupe(u8, good);
    defer a.free(bad);
    const cd = std.mem.indexOf(u8, bad, "PK\x01\x02").?;
    const size_at = cd + 24; // uncompressed_size in the central header
    std.mem.writeInt(u32, bad[size_at..][0..4], 0xFFFF_FFFF, .little);
    try std.testing.expectError(error.TooLarge, unpackInto(&dst, bad));
}

/// 1980-01-01, the earliest date the format can express.
const dos_epoch_date: u16 = (1 << 5) | 1;

fn readStruct(comptime T: type, bytes: []const u8, off: u64) ?T {
    if (off + @sizeOf(T) > bytes.len) return null;
    var v: T = @bitCast(bytes[@intCast(off)..][0..@sizeOf(T)].*);
    if (@import("builtin").cpu.arch.endian() == .big) std.mem.byteSwapAllFields(T, &v);
    return v;
}

fn writeStruct(allocator: Allocator, out: *std.ArrayList(u8), value: anytype) Allocator.Error!void {
    var v = value;
    if (@import("builtin").cpu.arch.endian() == .big) std.mem.byteSwapAllFields(@TypeOf(v), &v);
    try out.appendSlice(allocator, std.mem.asBytes(&v));
}

fn inflate(allocator: Allocator, data: []const u8, method: zip.CompressionMethod, expected: u32) Error![]u8 {
    switch (method) {
        .store => return allocator.dupe(u8, data),
        .deflate => {
            var input: std.Io.Reader = .fixed(data);
            var window: [std.compress.flate.max_window_len]u8 = undefined;
            var d: std.compress.flate.Decompress = .init(&input, .raw, &window);
            // One past the header's size: `allocRemaining` reports a stream *at* its limit as
            // too long, so an exact limit refused every deflated entry (a stored one never
            // reads past its end). The length check below still holds the archive to its word.
            const out = d.reader.allocRemaining(allocator, .limited(@as(usize, expected) + 1)) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                else => return error.InvalidArchive,
            };
            if (out.len != expected) {
                allocator.free(out);
                return error.InvalidArchive;
            }
            return out;
        },
        else => return error.Unsupported,
    }
}

/// An archive entry name as a mount path: `/`-rooted, no `.`/`..` segments, no trailing slash.
/// Empty when the entry is nothing a filesystem can hold (`./`, `__MACOSX/…`).
fn mountPath(allocator: Allocator, raw: []const u8) Allocator.Error![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    if (std.mem.startsWith(u8, raw, "__MACOSX/")) return out.toOwnedSlice(allocator);
    var it = std.mem.splitAny(u8, raw, "/\\");
    while (it.next()) |seg| {
        if (seg.len == 0 or std.mem.eql(u8, seg, ".")) continue;
        if (std.mem.eql(u8, seg, "..")) {
            // A path that escapes the archive is not one to honour; drop it entirely.
            out.clearRetainingCapacity();
            return out.toOwnedSlice(allocator);
        }
        try out.append(allocator, '/');
        try out.appendSlice(allocator, seg);
    }
    return out.toOwnedSlice(allocator);
}

fn entryName(allocator: Allocator, path: []const u8, is_dir: bool) Allocator.Error![]u8 {
    const rel = path[1..];
    if (is_dir) return std.mem.concat(allocator, u8, &.{ rel, "/" });
    return allocator.dupe(u8, rel);
}

fn ensureParents(mem: *Mem, path: []const u8) Error!void {
    var i: usize = 1;
    while (std.mem.indexOfScalarPos(u8, path, i, '/')) |slash| : (i = slash + 1) {
        const dir = path[0..slash];
        if (mem.nodes.contains(dir)) continue;
        mem.putDir(dir) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return error.InvalidArchive,
        };
    }
}

test "pack then unpack round-trips files, empty directories and nesting" {
    const a = std.testing.allocator;
    var src = try Mem.init(a);
    defer src.deinit();
    try src.putDir("/notes");
    try src.put("/notes/a.txt", "alpha");
    try src.putDir("/notes/deep");
    try src.put("/notes/deep/b.md", "# beta");
    try src.putDir("/empty");
    try src.put("/top.bin", &[_]u8{ 0, 1, 2, 255 });

    const bytes = try pack(a, &src);
    defer a.free(bytes);
    try std.testing.expect(std.mem.startsWith(u8, bytes, "PK\x03\x04"));

    var dst = try Mem.init(a);
    defer dst.deinit();
    try unpackInto(&dst, bytes);
    try std.testing.expectEqual(src.nodes.count(), dst.nodes.count());
    try std.testing.expectEqualStrings("alpha", dst.nodes.get("/notes/a.txt").?.bytes);
    try std.testing.expectEqualStrings("# beta", dst.nodes.get("/notes/deep/b.md").?.bytes);
    try std.testing.expectEqual(Fs.Kind.dir, dst.nodes.get("/empty").?.kind);
    try std.testing.expectEqualSlices(u8, &[_]u8{ 0, 1, 2, 255 }, dst.nodes.get("/top.bin").?.bytes);
}

test "unpack creates missing parents, skips resource forks and refuses escapes" {
    const a = std.testing.allocator;
    // An archive with only a nested file and no directory entries, as many tools write.
    var src = try Mem.init(a);
    defer src.deinit();
    try src.putDir("/x");
    try src.put("/x/y.txt", "y");
    const bytes = try pack(a, &src);
    defer a.free(bytes);

    var dst = try Mem.init(a);
    defer dst.deinit();
    // Remove the directory entry from the archive by unpacking into a Mem where only the
    // file's parent is missing: `ensureParents` must add `/x`.
    try unpackInto(&dst, bytes);
    try std.testing.expect(dst.nodes.contains("/x"));

    const junk = try mountPath(a, "__MACOSX/._a.txt");
    defer a.free(junk);
    try std.testing.expectEqual(@as(usize, 0), junk.len);
    const escape = try mountPath(a, "../etc/passwd");
    defer a.free(escape);
    try std.testing.expectEqual(@as(usize, 0), escape.len);
    const odd = try mountPath(a, "./a\\b/");
    defer a.free(odd);
    try std.testing.expectEqualStrings("/a/b", odd);
}

test "garbage is InvalidArchive" {
    var dst = try Mem.init(std.testing.allocator);
    defer dst.deinit();
    try std.testing.expectError(error.InvalidArchive, unpackInto(&dst, "not a zip"));
}

test "a deflated archive unpacks (an exact size limit refused every entry)" {
    // Python's zipfile, ZIP_DEFLATED: `notes/a.md` (the same line eight times) and `b.md`.
    const deflated = [_]u8{ 0x50, 0x4b, 0x03, 0x04, 0x14, 0x00, 0x00, 0x00, 0x08, 0x00, 0xbc, 0x81, 0x35, 0x5d, 0x75, 0x36, 0x8e, 0x57, 0x14, 0x00, 0x00, 0x00, 0x78, 0x00, 0x00, 0x00, 0x0a, 0x00, 0x00, 0x00, 0x6e, 0x6f, 0x74, 0x65, 0x73, 0x2f, 0x61, 0x2e, 0x6d, 0x64, 0x53, 0x56, 0x70, 0xe4, 0xe2, 0x2a, 0x4e, 0x4d, 0x55, 0x88, 0x8e, 0x76, 0x8a, 0x8d, 0xe5, 0x52, 0xa6, 0x17, 0x17, 0x00, 0x50, 0x4b, 0x03, 0x04, 0x14, 0x00, 0x00, 0x00, 0x08, 0x00, 0xbc, 0x81, 0x35, 0x5d, 0xb5, 0x5d, 0x14, 0x89, 0x06, 0x00, 0x00, 0x00, 0x04, 0x00, 0x00, 0x00, 0x04, 0x00, 0x00, 0x00, 0x62, 0x2e, 0x6d, 0x64, 0x53, 0x56, 0x70, 0xe2, 0x02, 0x00, 0x50, 0x4b, 0x01, 0x02, 0x14, 0x03, 0x14, 0x00, 0x00, 0x00, 0x08, 0x00, 0xbc, 0x81, 0x35, 0x5d, 0x75, 0x36, 0x8e, 0x57, 0x14, 0x00, 0x00, 0x00, 0x78, 0x00, 0x00, 0x00, 0x0a, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x80, 0x01, 0x00, 0x00, 0x00, 0x00, 0x6e, 0x6f, 0x74, 0x65, 0x73, 0x2f, 0x61, 0x2e, 0x6d, 0x64, 0x50, 0x4b, 0x01, 0x02, 0x14, 0x03, 0x14, 0x00, 0x00, 0x00, 0x08, 0x00, 0xbc, 0x81, 0x35, 0x5d, 0xb5, 0x5d, 0x14, 0x89, 0x06, 0x00, 0x00, 0x00, 0x04, 0x00, 0x00, 0x00, 0x04, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x80, 0x01, 0x3c, 0x00, 0x00, 0x00, 0x62, 0x2e, 0x6d, 0x64, 0x50, 0x4b, 0x05, 0x06, 0x00, 0x00, 0x00, 0x00, 0x02, 0x00, 0x02, 0x00, 0x6a, 0x00, 0x00, 0x00, 0x64, 0x00, 0x00, 0x00, 0x00, 0x00 };
    var dst = try Mem.init(std.testing.allocator);
    defer dst.deinit();
    try unpackInto(&dst, &deflated);
    const a = dst.nodes.get("/notes/a.md") orelse return error.Missing;
    try std.testing.expectEqual(@as(usize, 8 * "# A\n\nsee [[B]]\n".len), a.bytes.len);
    try std.testing.expectEqualStrings("# B\n", dst.nodes.get("/b.md").?.bytes);
}
