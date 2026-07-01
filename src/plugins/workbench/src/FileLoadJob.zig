//! Background file-load job. Owns a worker thread that runs the owning plugin's loader
//! (`owner.loadDocument`) off the main thread so large files don't stall the editor. The
//! main thread polls `done` each frame via `Editor.processLoadingJobs`; once true, the
//! result is moved into `editor.open_files`.
//!
//! Cancellation is best-effort: the plugin loader is monolithic, so we can only observe
//! cancellation AFTER it returns. The worker checks the flag, frees the loaded file if
//! cancelled, and exits.
//!
//! Ownership / threading model:
//!   - `path` is owned by the job, freed in `destroy()`.
//!   - `doc_buf` is written by the worker, read by the main thread only after `done.load(.acquire)`.
//!   - `phase` / `cancelled` are written by either side, read by either side.
//!   - The job pointer itself is owned by `Editor.loading_jobs`. Worker holds a borrowed pointer
//!     but only writes through atomic fields + the worker-only `doc_buf`/`err` fields.

const std = @import("std");
const wb = @import("../workbench.zig");
const dvui = wb.dvui;
const perf = wb.perf;
const sdk = wb.sdk;

const FileLoadJob = @This();

pub const Phase = enum(u8) {
    queued = 0,
    reading = 1,
    ready = 2,
    failed = 3,
    cancelled = 4,
};

allocator: std.mem.Allocator,

/// Absolute path. Owned by this job.
path: []u8,

/// Plugin that owns this file's extension (resolved on the main thread before spawn).
owner: *sdk.Plugin,

/// Workspace grouping the file should land in once loaded.
target_grouping: u64,

window: *dvui.Window,
started_at_ns: i128,

phase: std.atomic.Value(u8) = .init(@intFromEnum(Phase.queued)),
progress_num: std.atomic.Value(u32) = .init(0),
progress_den: std.atomic.Value(u32) = .init(0),
cancelled: std.atomic.Value(bool) = .init(false),
done: std.atomic.Value(bool) = .init(false),

/// Plugin-document staging buffer (size/align from `owner.documentStackSize/Align`).
doc_slab: []u8,
doc_buf: []u8,

err: ?anyerror = null,

pub fn create(allocator: std.mem.Allocator, path: []const u8, owner: *sdk.Plugin, target_grouping: u64) !*FileLoadJob {
    const path_copy = try allocator.dupe(u8, path);
    errdefer allocator.free(path_copy);

    const staging = try owner.allocDocumentBuffer(allocator);
    errdefer allocator.free(staging.backing);

    const job = try allocator.create(FileLoadJob);
    errdefer allocator.destroy(job);

    job.* = .{
        .allocator = allocator,
        .path = path_copy,
        .owner = owner,
        .target_grouping = target_grouping,
        .window = dvui.currentWindow(),
        .started_at_ns = perf.nanoTimestamp(),
        .doc_slab = staging.backing,
        .doc_buf = staging.buf,
    };
    return job;
}

pub fn destroy(job: *FileLoadJob) void {
    const a = job.allocator;
    a.free(job.path);
    a.free(job.doc_slab);
    a.destroy(job);
}

pub fn workerMain(job: *FileLoadJob) void {
    defer {
        job.done.store(true, .release);
        dvui.refresh(job.window, @src(), null);
    }

    if (job.cancelled.load(.monotonic)) {
        job.phase.store(@intFromEnum(Phase.cancelled), .release);
        return;
    }

    job.phase.store(@intFromEnum(Phase.reading), .release);

    const handled = job.owner.loadDocument(job.path, job.doc_buf.ptr) catch |e| {
        job.err = e;
        job.phase.store(@intFromEnum(Phase.failed), .release);
        return;
    };
    if (!handled) {
        job.err = error.InvalidFile;
        job.phase.store(@intFromEnum(Phase.failed), .release);
        return;
    }

    if (job.cancelled.load(.monotonic)) {
        job.owner.deinitDocumentBuffer(job.doc_buf.ptr);
        job.phase.store(@intFromEnum(Phase.cancelled), .release);
        return;
    }

    job.phase.store(@intFromEnum(Phase.ready), .release);
}

pub fn elapsedExceeds(job: *const FileLoadJob, threshold_ms: i64) bool {
    const elapsed_ns = perf.nanoTimestamp() - job.started_at_ns;
    return @divTrunc(elapsed_ns, std.time.ns_per_ms) >= threshold_ms;
}

pub fn currentPhase(job: *const FileLoadJob) Phase {
    const raw = job.phase.load(.acquire);
    return switch (raw) {
        0 => .queued,
        1 => .reading,
        2 => .ready,
        3 => .failed,
        4 => .cancelled,
        else => .queued,
    };
}

pub fn phaseLabel(phase: Phase) []const u8 {
    return switch (phase) {
        .queued => "Queued",
        .reading => "Reading",
        .ready => "Done",
        .failed => "Failed",
        .cancelled => "Cancelled",
    };
}
