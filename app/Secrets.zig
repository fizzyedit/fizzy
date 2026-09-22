//! Credentials a plugin holds on the user's behalf — a refresh token, an API key — kept out of
//! `settings.zon`, which is exported, diffed, watched and shown in a pane.
//!
//! The seam is the point: `get`/`set`/`remove` by key, with the backend chosen by the app.
//! Today that is one backend, `secrets` in the config folder — one `key=base64` line per
//! entry, created `0600`, read whole; the OS stores (Keychain, libsecret, DPAPI) slot in
//! behind the same three calls without a plugin noticing. Not available on the web build, where a page has no private
//! storage worth the name — a plugin there keeps a session token in memory and asks again.
//!
//! Keys are plugin-namespaced by convention (`drive.refresh_token`); values are opaque bytes.
const std = @import("std");
const builtin = @import("builtin");

const Secrets = @This();

gpa: std.mem.Allocator,
io: std.Io,
/// `<config>/secrets`; empty on the web.
path: []const u8,
values: std.StringArrayHashMapUnmanaged([]u8) = .empty,
loaded: bool = false,

pub fn init(gpa: std.mem.Allocator, io: std.Io, config_folder: []const u8) !Secrets {
    const path = if (builtin.target.cpu.arch == .wasm32) "" else try std.fs.path.join(gpa, &.{ config_folder, "secrets" });
    return .{ .gpa = gpa, .io = io, .path = path };
}

pub fn deinit(self: *Secrets) void {
    self.clearValues();
    self.values.deinit(self.gpa);
    if (self.path.len != 0) self.gpa.free(self.path);
}

fn clearValues(self: *Secrets) void {
    for (self.values.keys(), self.values.values()) |k, v| {
        self.gpa.free(k);
        @memset(v, 0); // not left lying in freed memory
        self.gpa.free(v);
    }
    self.values.clearRetainingCapacity();
}

/// Borrowed until the next `set`/`remove` of that key. Null when unset (or on the web).
pub fn get(self: *Secrets, key: []const u8) ?[]const u8 {
    self.load();
    return self.values.get(key);
}

/// Store `value` under `key` and write the file. An empty value is the same as `remove`.
///
/// Once the map holds `v` it owns it, so nothing here may free it on a later failure: an
/// `errdefer` that outlived the `put` left the map pointing at freed memory, and the next `get`
/// handed that out. On the web it did so every single time — `save` always fails there (memory
/// only, no file), so every `set` both stored the value and freed it.
pub fn set(self: *Secrets, key: []const u8, value: []const u8) !void {
    if (value.len == 0) return self.remove(key);
    self.load();
    const v = try self.gpa.dupe(u8, value);
    {
        errdefer self.gpa.free(v);
        if (self.values.getEntry(key)) |e| {
            @memset(e.value_ptr.*, 0);
            self.gpa.free(e.value_ptr.*);
            e.value_ptr.* = v;
        } else {
            const k = try self.gpa.dupe(u8, key);
            errdefer self.gpa.free(k);
            try self.values.put(self.gpa, k, v);
        }
    }
    self.save() catch |err| {
        if (comptime builtin.target.cpu.arch == .wasm32) return;
        return err;
    };
}

pub fn remove(self: *Secrets, key: []const u8) !void {
    self.load();
    const kv = self.values.fetchOrderedRemove(key) orelse return;
    self.gpa.free(kv.key);
    @memset(kv.value, 0);
    self.gpa.free(kv.value);
    try self.save();
}

/// One `key=base64(value)` per line — nothing a settings parser or a shell glob would ever
/// pick up by accident, and any bytes survive. Loaded once, lazily.
fn load(self: *Secrets) void {
    if (self.loaded) return;
    self.loaded = true;
    if (comptime builtin.target.cpu.arch == .wasm32) return;
    if (self.path.len == 0) return;
    const raw = std.Io.Dir.cwd().readFileAlloc(self.io, self.path, self.gpa, .limited(1 << 20)) catch return;
    defer self.gpa.free(raw);
    var lines = std.mem.splitScalar(u8, raw, '\n');
    while (lines.next()) |line| {
        const eq = std.mem.indexOfScalar(u8, line, '=') orelse continue;
        const key = line[0..eq];
        const enc = std.mem.trimEnd(u8, line[eq + 1 ..], "\r");
        const len = std.base64.standard.Decoder.calcSizeForSlice(enc) catch continue;
        const v = self.gpa.alloc(u8, len) catch continue;
        std.base64.standard.Decoder.decode(v, enc) catch {
            self.gpa.free(v);
            continue;
        };
        const k = self.gpa.dupe(u8, key) catch {
            self.gpa.free(v);
            continue;
        };
        self.values.put(self.gpa, k, v) catch {
            self.gpa.free(k);
            self.gpa.free(v);
        };
    }
}

fn save(self: *Secrets) !void {
    if (comptime builtin.target.cpu.arch == .wasm32) return error.Unsupported;
    if (self.path.len == 0) return error.Unsupported;
    if (self.values.count() == 0) {
        std.Io.Dir.deleteFileAbsolute(self.io, self.path) catch |err| if (err != error.FileNotFound) return err;
        return;
    }
    var out: std.Io.Writer.Allocating = .init(self.gpa);
    defer out.deinit();
    for (self.values.keys(), self.values.values()) |k, v| {
        const enc = try self.gpa.alloc(u8, std.base64.standard.Encoder.calcSize(v.len));
        defer self.gpa.free(enc);
        _ = std.base64.standard.Encoder.encode(enc, v);
        try out.writer.print("{s}={s}\n", .{ k, enc });
    }
    // Created `0600`, written whole, then moved into place: never a moment where the file
    // is world-readable or half-written.
    const tmp = try std.fmt.allocPrint(self.gpa, "{s}.tmp", .{self.path});
    defer self.gpa.free(tmp);
    {
        var file = try std.Io.Dir.createFileAbsolute(self.io, tmp, .{ .permissions = @enumFromInt(0o600), .truncate = true });
        defer file.close(self.io);
        try file.writeStreamingAll(self.io, out.written());
    }
    try std.Io.Dir.renameAbsolute(tmp, self.path, self.io);
}

test "secrets round-trip through a 0600 file and never through settings" {
    if (builtin.target.cpu.arch == .wasm32) return error.SkipZigTest;
    const a = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir = try tmp.dir.realPathFileAlloc(io, ".", a);
    defer a.free(dir);

    var s = try Secrets.init(a, io, dir);
    defer s.deinit();
    try std.testing.expect(s.get("drive.refresh_token") == null);
    try s.set("drive.refresh_token", "1//abc\"quoted\"");
    try std.testing.expectEqualStrings("1//abc\"quoted\"", s.get("drive.refresh_token").?);

    // On disk: only the owner can read it, and a fresh instance reads it back.
    const st = try tmp.dir.statFile(io, "secrets", .{});
    if (builtin.os.tag != .windows) try std.testing.expectEqual(@as(u32, 0o600), @as(u32, @intCast(st.permissions.toMode() & 0o777)));
    var again = try Secrets.init(a, io, dir);
    defer again.deinit();
    try std.testing.expectEqualStrings("1//abc\"quoted\"", again.get("drive.refresh_token").?);

    try again.remove("drive.refresh_token");
    try std.testing.expect(again.get("drive.refresh_token") == null);
    try std.testing.expectError(error.FileNotFound, tmp.dir.statFile(io, "secrets", .{}));
}
