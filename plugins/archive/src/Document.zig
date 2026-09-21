//! One opened archive: its contents unpacked into a `Mem` and mounted at `zip://<name>`, and
//! the tab that stands for the mount. There is nothing to draw but the mount's name and what
//! can be done with it — the files themselves are in the explorer, like any other folder.
const std = @import("std");
const builtin = @import("builtin");
const dvui = @import("dvui");
const core = @import("core");
const sdk = @import("fizzy_sdk");

const Document = @This();

id: u64,
/// Where the archive came from: a disk path natively, the upload's name on the web.
path: []u8,
/// `zip://<archive name without extension>`. Owned.
prefix: []u8,
grouping: u64 = 0,
mem: *core.vfs.Mem,
/// `mem.generation` when the archive was last read or written, so dirty is "changed since".
clean_generation: u64,
mounted: bool = false,

pub fn fromBytes(path: []const u8, bytes: []const u8) !Document {
    const gpa = sdk.allocator();
    const path_copy = try gpa.dupe(u8, path);
    errdefer gpa.free(path_copy);

    const stem = std.fs.path.stem(std.fs.path.basename(path));
    const prefix = try uniquePrefix(gpa, if (stem.len > 0) stem else "archive");
    errdefer gpa.free(prefix);

    const mem = try gpa.create(core.vfs.Mem);
    errdefer gpa.destroy(mem);
    mem.* = try core.vfs.Mem.init(gpa);
    errdefer mem.deinit();
    try core.vfs.zip.unpackInto(mem, bytes);

    return .{
        .id = sdk.host().allocDocId(),
        .path = path_copy,
        .prefix = prefix,
        .mem = mem,
        .clean_generation = mem.generation,
    };
}

/// `zip://<stem>`, or `zip://<stem> (2)`, … when that prefix is already mounted: two archives
/// with one name must not share a mount, or closing either unmounts both.
fn uniquePrefix(gpa: std.mem.Allocator, stem: []const u8) ![]u8 {
    const files = sdk.host().files orelse return std.fmt.allocPrint(gpa, "zip://{s}", .{stem});
    var n: usize = 1;
    while (n < 1000) : (n += 1) {
        const candidate = if (n == 1)
            try std.fmt.allocPrint(gpa, "zip://{s}", .{stem})
        else
            try std.fmt.allocPrint(gpa, "zip://{s} ({d})", .{ stem, n });
        var taken = false;
        for (files.mountList()) |m| {
            if (std.mem.eql(u8, m.prefix, candidate)) taken = true;
        }
        if (!taken) return candidate;
        gpa.free(candidate);
    }
    return error.TooManyArchives;
}

/// Native: read the archive from disk. Web has no disk; archives arrive as bytes.
pub fn fromPath(path: []const u8) !Document {
    if (comptime builtin.target.cpu.arch == .wasm32) return error.Unsupported;
    const gpa = sdk.allocator();
    const bytes = try std.Io.Dir.cwd().readFileAlloc(dvui.io, path, gpa, .limited(max_archive_bytes));
    defer gpa.free(bytes);
    return fromBytes(path, bytes);
}

/// An archive is held in memory twice over (bytes, then the unpacked tree); past this it is
/// not something to open in a browser tab.
const max_archive_bytes: usize = 512 * 1024 * 1024;

pub fn mount(self: *Document) !void {
    if (self.mounted) return;
    try sdk.host().mount(self.prefix, self.mem.fs());
    self.mounted = true;
}

pub fn unmount(self: *Document) void {
    if (!self.mounted) return;
    sdk.host().unmount(self.prefix);
    self.mounted = false;
}

pub fn isDirty(self: *const Document) bool {
    return self.mem.generation != self.clean_generation;
}

/// The archive as it stands now. Caller owns.
pub fn pack(self: *const Document, allocator: std.mem.Allocator) ![]u8 {
    return core.vfs.zip.pack(allocator, self.mem);
}

pub fn markClean(self: *Document) void {
    self.clean_generation = self.mem.generation;
}

pub fn deinit(self: *Document) void {
    const gpa = sdk.allocator();
    self.unmount();
    self.mem.deinit();
    gpa.destroy(self.mem);
    gpa.free(self.prefix);
    gpa.free(self.path);
}
