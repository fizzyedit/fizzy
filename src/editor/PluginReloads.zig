//! Rebuilt plugins swapped in without freezing a frame.
//!
//! When the plugin watcher sees a loaded plugin's binary change (`reconcileChangedPluginBinaries`),
//! the new build is opened on a worker thread (`PluginLoader.open`: the copy, the `dlopen`, the
//! ABI checks) while the old one keeps running. Only once it is open does a frame swap them: the
//! old unloaded, the new registered (`Editor.finishUserPluginLoad`). The `dlopen` was the whole
//! cost of a reload — on macOS ~180 ms for a file the system has not seen, which a rebuild always
//! is — and it was paid on the UI thread, freezing the person's frame; the swap left on it is a few
//! milliseconds. Measured by `scripts/plugin-loop/bench.py` (`docs/AGENTS_PLAN.md`, "Fast enough to
//! watch").
//!
//! One open per plugin at a time. A rebuild that lands while its plugin is still opening is picked
//! up after the swap, by checking the binaries again. A build the swap cannot take — the old
//! plugin has unsaved documents, or the new one fails to register — leaves the running one in
//! place, as a failed synchronous reload did.
const PluginReloads = @This();

const std = @import("std");
const builtin = @import("builtin");
const dvui = @import("dvui");
const fizzy = @import("../fizzy.zig");
const App = @import("app").App;
const PluginLoader = @import("app").store.Loader;
const Editor = @import("Editor.zig");

jobs: std.ArrayListUnmanaged(*Job) = .empty,

/// Native only: the web links a plugin as a wasm side module (`loadWebPlugin`), with no reload.
const native = builtin.target.cpu.arch != .wasm32;
const Opened = if (native) PluginLoader.Opened else void;

const Job = struct {
    id: []u8,
    /// The installed binary; the loaded plugin's own once it is swapped in.
    path: []u8,
    window: *dvui.Window,
    thread: std.Thread = undefined,
    started_ns: i96,
    /// The worker's, read by the UI thread once `done`.
    opened: PluginLoader.LoadError!Opened = error.DylibOpenFailed,
    opened_ns: i96 = 0,
    done: std.atomic.Value(bool) = .init(false),
    /// Another rebuild landed while this one opened: check the binaries again after the swap.
    again: bool = false,
};

/// Start opening `id`'s rebuilt binary off the UI thread. On the UI thread.
pub fn start(self: *PluginReloads, editor: *Editor, id: []const u8) void {
    if (comptime !native) return;
    for (self.jobs.items) |job| if (std.mem.eql(u8, job.id, id)) {
        job.again = true;
        return;
    };
    const gpa = editor.app.gpa;
    const own_id = gpa.dupe(u8, id) catch return;
    const path = App.userPluginPath(gpa, &editor.app, id) catch return gpa.free(own_id);
    const job = gpa.create(Job) catch {
        gpa.free(own_id);
        return gpa.free(path);
    };
    job.* = .{
        .id = own_id,
        .path = path,
        .window = fizzy.entry().window,
        .started_ns = std.Io.Clock.boot.now(dvui.io).nanoseconds,
    };
    self.jobs.append(gpa, job) catch return freeJob(gpa, job);
    job.thread = std.Thread.spawn(.{}, work, .{job}) catch |err| {
        dvui.log.warn("plugin watcher: could not start reloading '{s}': {t}", .{ id, err });
        _ = self.jobs.pop();
        return freeJob(gpa, job);
    };
}

fn work(job: *Job) void {
    // The worker's own allocator: `open` only needs a scratch path from it.
    job.opened = PluginLoader.open(std.heap.smp_allocator, job.path, job.id);
    job.opened_ns = std.Io.Clock.boot.now(dvui.io).nanoseconds;
    job.done.store(true, .release);
    // Wake the app: the swap happens on its next frame.
    dvui.refresh(job.window, @src(), null);
}

/// Swap in every plugin whose new build has finished opening. Once a frame, on the UI thread.
pub fn frame(self: *PluginReloads, editor: *Editor) void {
    if (comptime !native) return;
    var i: usize = 0;
    while (i < self.jobs.items.len) {
        const job = self.jobs.items[i];
        if (!job.done.load(.acquire)) {
            i += 1;
            continue;
        }
        job.thread.join();
        _ = self.jobs.orderedRemove(i);
        swap(editor, job);
    }
}

fn swap(editor: *Editor, job: *Job) void {
    const gpa = editor.app.gpa;
    var again = job.again;
    defer {
        gpa.free(job.id);
        gpa.destroy(job);
        // A rebuild that landed mid-open: its stamp is newer than what was just loaded.
        if (again) editor.reconcileChangedPluginBinaries();
    }
    var opened = job.opened catch |err| {
        dvui.log.warn("plugin watcher: could not reload rebuilt '{s}' ({s}): {s}", .{ job.id, @errorName(err), App.pluginLoadFailureReason(err) });
        gpa.free(job.path);
        // Not again until the binary changes again (as a failed synchronous reload did).
        editor.app.restampLoadedPlugin(job.id);
        again = false;
        return;
    };
    const start_ns = std.Io.Clock.boot.now(dvui.io).nanoseconds;
    editor.unloadPlugin(job.id, false) catch |err| {
        dvui.log.warn("plugin watcher: could not reload rebuilt '{s}' ({s})", .{ job.id, @errorName(err) });
        opened.close();
        gpa.free(job.path);
        editor.app.restampLoadedPlugin(job.id);
        again = false;
        return;
    };
    const unloaded_ns = std.Io.Clock.boot.now(dvui.io).nanoseconds;
    // Takes `opened` and its path either way.
    editor.finishUserPluginLoad(job.id, opened) catch |err| {
        dvui.log.warn("plugin watcher: rebuilt '{s}' did not register ({s})", .{ job.id, @errorName(err) });
        return;
    };
    const loaded_ns = std.Io.Clock.boot.now(dvui.io).nanoseconds;
    dvui.log.info("plugin '{s}': swapped in {d:.1}ms on the UI thread (unload {d:.1}ms, register {d:.1}ms), opened off it in {d:.1}ms", .{
        job.id,
        ms(start_ns, loaded_ns),
        ms(start_ns, unloaded_ns),
        ms(unloaded_ns, loaded_ns),
        ms(job.started_ns, job.opened_ns),
    });
    dvui.log.info("plugin watcher: reloaded '{s}' from its rebuilt binary", .{job.id});
}

/// Wait for every open in flight and drop what it opened. At shutdown, before plugins unload.
pub fn deinit(self: *PluginReloads, gpa: std.mem.Allocator) void {
    if (comptime !native) return;
    for (self.jobs.items) |job| {
        job.thread.join();
        if (job.opened) |o| {
            var opened = o;
            opened.close();
        } else |_| {}
        freeJob(gpa, job);
    }
    self.jobs.deinit(gpa);
}

fn freeJob(gpa: std.mem.Allocator, job: *Job) void {
    gpa.free(job.id);
    gpa.free(job.path);
    gpa.destroy(job);
}

fn ms(from_ns: i96, to_ns: i96) f64 {
    return @as(f64, @floatFromInt(to_ns - from_ns)) / std.time.ns_per_ms;
}
