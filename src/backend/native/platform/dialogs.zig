//! Native file dialogs — save, open, open folder — that never block the frame: SDL shows them
//! and calls back when the user is done, and the result is handed to the app inside a frame
//! (`pollPendingDialogResult`), where it may touch dvui. Where a dialog starts is the app's to say
//! (`DialogDirs`); a dialog with no say opens where the platform likes.
const std = @import("std");
const builtin = @import("builtin");
const dvui = @import("dvui");
const c = @import("backend").c;
const window = @import("window.zig");

/// The application's long-lived allocator, set once at startup.
///
/// Everything here that allocates does so on behalf of the app — a dialog's default path, the
/// recent-folders menu, a plugin-contributed menu item's title — and outlives the frame that
/// asked for it. An app sets it at startup (`setAllocator`).
var app_gpa: ?std.mem.Allocator = null;

pub fn setAllocator(gpa: std.mem.Allocator) void {
    app_gpa = gpa;
}

/// Where a file dialog starts, and what the application learns from where it ended.
///
/// A native dialog is platform plumbing; *which directory it opens in* is the application's
/// memory of what the user was doing. Fizzy answers with its project folder and its last used
/// save/open directories; an app that remembers nothing returns null and gets the platform
/// default, which is a perfectly good answer.
pub const DialogDirs = struct {
    ctx: *anyopaque,
    /// The directory a `.save` or `.open` dialog should start in, or null for the platform's
    /// choice. The returned slice is borrowed for the call only.
    initial: *const fn (ctx: *anyopaque, mode: DialogMode) ?[]const u8,
    /// Where the user actually ended up. Called with the chosen file's directory.
    remember: *const fn (ctx: *anyopaque, mode: DialogMode, dir: []const u8) void,
};

pub const DialogMode = enum { save, open };

var dialog_dirs: ?DialogDirs = null;

pub fn setDialogDirs(d: DialogDirs) void {
    dialog_dirs = d;
}

/// The app's remembered directory for `mode`, or "" when it has none.
fn initialDir(mode: DialogMode) []const u8 {
    const d = dialog_dirs orelse return "";
    return d.initial(d.ctx, mode) orelse "";
}

fn alloc() std.mem.Allocator {
    return app_gpa orelse @panic("backend used before the app supplied an allocator");
}

/// The allocator dialogs (and the rest of `platform`) allocate with on the app's behalf.
pub fn allocator() std.mem.Allocator {
    return alloc();
}

pub const DialogFileFilter = c.SDL_DialogFileFilter;

pub fn showSaveFileDialog(cb: *const fn (?[][:0]const u8) void, filters: []const DialogFileFilter, default_filename: []const u8, default_folder: ?[]const u8) void {
    const default: [:0]const u8 = blk: {
        const dir = default_folder orelse initialDir(.save);
        break :blk std.fs.path.joinZ(alloc(), &.{ dir, default_filename }) catch "untitled";
    };
    defer alloc().free(default);
    // Do not use our borderless/custom-frame main window as the dialog parent on Windows: the shell
    // may inherit extended style and the picker loses normal frame/close affordances.
    const parent: ?*c.SDL_Window = if (builtin.os.tag == .windows) null else dvui.currentWindow().backend.impl.window;
    c.SDL_ShowSaveFileDialog(GenericSaveDialogCallback, @ptrCast(@alignCast(@constCast(cb))), parent, filters.ptr, @intCast(filters.len), default);
}

pub fn showOpenFileDialog(cb: *const fn (?[][:0]const u8) void, filters: []const DialogFileFilter, default_filename: []const u8, default_folder: ?[]const u8) void {
    const default: [:0]const u8 = blk: {
        const dir = default_folder orelse initialDir(.open);
        break :blk std.fs.path.joinZ(alloc(), &.{ dir, default_filename }) catch "untitled";
    };
    defer alloc().free(default);
    const parent: ?*c.SDL_Window = if (builtin.os.tag == .windows) null else dvui.currentWindow().backend.impl.window;
    c.SDL_ShowOpenFileDialog(GenericOpenDialogCallback, @ptrCast(@alignCast(@constCast(cb))), parent, filters.ptr, @intCast(filters.len), default.ptr, true);
}

pub fn showOpenFolderDialog(cb: *const fn (?[][:0]const u8) void, default_folder: ?[]const u8) void {
    const default: [:0]const u8 = blk: {
        const dir = default_folder orelse initialDir(.open);
        break :blk std.fmt.allocPrintSentinel(alloc(), "{s}", .{dir}, 0) catch "untitled";
    };
    defer alloc().free(default);
    const parent: ?*c.SDL_Window = if (builtin.os.tag == .windows) null else dvui.currentWindow().backend.impl.window;
    c.SDL_ShowOpenFolderDialog(GenericOpenDialogCallback, @ptrCast(@alignCast(@constCast(cb))), parent, default.ptr, false);
}

fn GenericSaveDialogCallback(cb: ?*anyopaque, files: [*c]const [*c]const u8, _: c_int) callconv(.c) void {
    GenericDialogCallback(cb, files, .save);
}

fn GenericOpenDialogCallback(cb: ?*anyopaque, files: [*c]const [*c]const u8, _: c_int) callconv(.c) void {
    GenericDialogCallback(cb, files, .open);
}

// Native open/save dialogs on macOS complete asynchronously via the Cocoa run loop, which is
// pumped from `SDL_WaitEvent` between frames — i.e. outside `dvui.Window.begin`/`end`. Callers
// (plugin dialog callbacks) routinely touch dvui state that requires `dvui.currentWindow()`
// (e.g. stashing `dvui.currentWindow()` on a `FileLoadJob`), which panics if invoked directly
// from here. So we only capture the result here and hand it off; the actual callback runs from
// `pollPendingDialogResult`, called once per frame from inside fizzy's own frame tick.
//
// On Windows and Linux SDL runs the callback on a thread of its own, so the queue is behind a
// lock, and nothing of the app's runs from here — where the user ended up is remembered
// (`DialogDirs.remember`) when the result is drained, on the app's thread.
const PendingDialogResult = struct {
    callback: *const fn (?[][:0]const u8) void,
    files: ?[][:0]const u8,
    mode: DialogMode = .open,
};
var pending_dialog_results: std.ArrayListUnmanaged(PendingDialogResult) = .empty;
/// A spinlock: held for a list append or remove, between a dialog's thread and the frame.
var pending_dialog_lock: std.atomic.Mutex = .unlocked;

fn lockDialogResults() void {
    while (!pending_dialog_lock.tryLock()) std.atomic.spinLoopHint();
}

fn queueDialogResult(r: PendingDialogResult) !void {
    lockDialogResults();
    defer pending_dialog_lock.unlock();
    try pending_dialog_results.append(alloc(), r);
}

/// Drain one queued dialog result per call. Call once per frame from inside
/// `Window.begin`/`end` (e.g. `Editor.tick`) so callbacks are free to touch dvui state.
pub fn pollPendingDialogResult() ?PendingDialogResult {
    const r = blk: {
        lockDialogResults();
        defer pending_dialog_lock.unlock();
        if (pending_dialog_results.items.len == 0) return null;
        break :blk pending_dialog_results.orderedRemove(0);
    };
    // Tell the app where the user ended up, so the next dialog starts there.
    if (r.files) |files| if (files.len > 0) {
        if (std.fs.path.dirname(files[0])) |dir| {
            if (dialog_dirs) |d| d.remember(d.ctx, r.mode, dir);
        }
    };
    return r;
}

/// Queuing a dialog result is not enough to get it processed: this runs from the Cocoa/Win32
/// run loop that the event wait pumps *between* frames, so if the panel closes without any
/// further input — Enter on the Save As sheet, mouse never moved — the loop goes straight back
/// to sleep and `pollPendingDialogResult` is not reached until something unrelated wakes it.
/// The user sees the file land on disk with the tab/title still saying "untitled".
///
/// `dvui.refresh` with an explicit window is the outside-`begin`/`end` form: it marks a frame
/// needed *and* wakes the backend's event wait.
fn wakeForDialogResult() void {
    if (window.dvuiWindow()) |w| dvui.refresh(w, @src(), null);
}

fn GenericDialogCallback(cb: ?*anyopaque, files: [*c]const [*c]const u8, mode: DialogMode) void {
    const callback: *const fn (?[][:0]const u8) void = @ptrCast(@alignCast(@constCast(cb)));

    // Try to count the number of files until we hit a null pointer.
    var path_count: usize = 0;
    while (files[path_count] != null) : (path_count += 1) {}

    if (path_count == 0) {
        queueDialogResult(.{ .callback = callback, .files = null, .mode = mode }) catch {
            dvui.log.err("Failed to queue dialog result", .{});
            return;
        };
        wakeForDialogResult();
        return;
    }

    // Dupe every path (and the slice holding them) into memory that outlives this callback,
    // since the `files` pointers are only valid for the duration of this call.
    const zig_files: [][:0]const u8 = alloc().alloc([:0]const u8, path_count) catch {
        dvui.log.err("Failed to allocate dialog result paths", .{});
        return;
    };
    var allocated: usize = 0;
    for (0..path_count) |i| {
        zig_files[i] = alloc().dupeZ(u8, std.mem.span(files[i])) catch {
            dvui.log.err("Failed to dupe dialog result path", .{});
            for (zig_files[0..allocated]) |f| alloc().free(f);
            alloc().free(zig_files);
            return;
        };
        allocated += 1;
    }

    queueDialogResult(.{ .callback = callback, .files = zig_files, .mode = mode }) catch {
        dvui.log.err("Failed to queue dialog result", .{});
        for (zig_files) |f| alloc().free(f);
        alloc().free(zig_files);
        return;
    };
    wakeForDialogResult();
}
