//! Watches the app's own executable, so a rebuild of it restarts the app into the new build
//! (`restart`), keeping every document (`KeptDocuments`). The loop a plugin has — build, and the
//! running app picks it up — for the app itself: for anyone working on fizzy from source, and for
//! an agent iterating on it (plans/RESTART_AND_CRASHES_PLAN.md, step 2).
//!
//! The same shape as `SettingsWatcher`: nightwatch's thread sets a flag and wakes the app, and
//! `tick` decides on the main thread. It watches the executable's folder (a file cannot be watched
//! across the rename an install does) and reacts only to the executable. `zig build` installs it by
//! writing a temporary file and renaming it into place, so it is whole when its event arrives; the
//! short coalesce covers an installer that writes in place, and the stamp (size and modification
//! time) must hold still across it before the app restarts.
//!
//! The path is read at launch: once the file is replaced, the running process's own idea of its
//! path can change (Linux reads `/proc/self/exe`, which then says "(deleted)").
const builtin = @import("builtin");
const std = @import("std");
const core = @import("core");
const dvui = @import("dvui");
const wake = @import("wake.zig");
const SettingsWatcher = @import("SettingsWatcher.zig");
const Allocator = std.mem.Allocator;

const ExecutableWatcher = @This();

pub const have_impl = SettingsWatcher.have_impl;

/// How long the executable must hold still once an event arrives before the app restarts.
pub const settle_ns: i128 = 150 * std.time.ns_per_ms;

gpa: Allocator,
/// This executable, as it was at launch. Owned.
path: []const u8,
/// Its stamp at launch: a rebuild is a stamp other than this one.
launched: Stamp,
impl: if (have_impl) Impl else void = if (have_impl) .{} else {},
dirty: std.atomic.Value(bool) = .init(false),
/// When the last event arrived, and the stamp then; 0: nothing pending.
pending_ns: i128 = 0,
pending: Stamp = .{},

const Stamp = struct {
    size: u64 = 0,
    mtime_ns: i96 = 0,

    fn of(path: []const u8) ?Stamp {
        const st = std.Io.Dir.cwd().statFile(dvui.io, path, .{}) catch return null;
        return .{ .size = st.size, .mtime_ns = st.mtime.nanoseconds };
    }

    fn eql(a: Stamp, b: Stamp) bool {
        return a.size == b.size and a.mtime_ns == b.mtime_ns;
    }
};

const Impl = if (have_impl) struct {
    const nightwatch = @import("nightwatch");
    const Handler = nightwatch.Default.Handler;

    handler: Handler = .{ .vtable = &vtable },
    nw: ?nightwatch.Default = null,
    /// Set in `start`, once the watcher is at its final address.
    dirty: ?*std.atomic.Value(bool) = null,
    name: []const u8 = "",

    const vtable = Handler.VTable{
        .change = onChange,
        .rename = onRename,
    };

    fn note(h: *Handler, path: []const u8) void {
        const impl: *Impl = @fieldParentPtr("handler", h);
        if (!std.mem.eql(u8, std.fs.path.basename(path), impl.name)) return;
        if (impl.dirty) |d| d.store(true, .release);
        wake.now();
    }

    fn onChange(h: *Handler, path: []const u8, event_type: nightwatch.EventType, object_type: nightwatch.ObjectType) error{HandlerFailed}!void {
        _ = event_type;
        _ = object_type;
        note(h, path);
    }

    fn onRename(h: *Handler, src: []const u8, dst: []const u8, object_type: nightwatch.ObjectType) error{HandlerFailed}!void {
        _ = src;
        _ = object_type;
        note(h, dst);
    }
} else void;

/// The executable at `path` (the app's own: `std.process.executablePath`, read at launch) and
/// its stamp now. `path` is copied. Does not start watching (`start`).
pub fn init(gpa: Allocator, exe_path: []const u8) !ExecutableWatcher {
    if (comptime !have_impl) return error.Unsupported;
    const path = try gpa.dupe(u8, exe_path);
    errdefer gpa.free(path);
    return .{ .gpa = gpa, .path = path, .launched = Stamp.of(path) orelse return error.NoExecutable };
}

/// Start watching the executable's folder. Only once `self` is at its final address: nightwatch
/// keeps `&self.impl.handler` (as `SettingsWatcher.start`).
pub fn start(self: *ExecutableWatcher) !void {
    if (comptime !have_impl) return error.Unsupported;
    const nightwatch = @import("nightwatch");
    self.impl.dirty = &self.dirty;
    self.impl.name = std.fs.path.basename(self.path);
    var nw = try nightwatch.Default.init(dvui.io, self.gpa, &self.impl.handler);
    errdefer nw.deinit();
    try nw.watch(std.fs.path.dirname(self.path) orelse return error.NoExecutable);
    self.impl.nw = nw;
}

/// Stop watching (joins nightwatch's thread) and free the path. Safe without `start`.
pub fn deinit(self: *ExecutableWatcher) void {
    if (comptime have_impl) {
        if (self.impl.nw) |*nw| nw.deinit();
        self.impl.nw = null;
    }
    self.gpa.free(self.path);
}

/// Once a frame. True once the executable has been rebuilt: replaced by a different file that has
/// held still since its last event.
pub fn tick(self: *ExecutableWatcher) bool {
    if (comptime !have_impl) return false;
    const now = core.perf.nanoTimestamp();
    if (self.dirty.swap(false, .acquire)) {
        self.pending_ns = now;
        self.pending = Stamp.of(self.path) orelse .{};
    }
    if (self.pending_ns == 0) return false;
    if (now - self.pending_ns < settle_ns) {
        wake.now();
        return false;
    }
    self.pending_ns = 0;
    const stamp = Stamp.of(self.path) orelse return false; // mid-replace: the rename's event follows
    if (!stamp.eql(self.pending)) {
        // Still being written: wait for it to hold still.
        self.pending_ns = now;
        self.pending = stamp;
        wake.now();
        return false;
    }
    return !stamp.eql(self.launched);
}
