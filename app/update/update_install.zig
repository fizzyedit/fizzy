//! Background install of a Velopack update.
//!
//! `vpkc_download_updates` and `vpkc_wait_exit_then_apply_updates` are both blocking
//! calls — running them on the GUI thread freezes the window for the full download
//! window. This module owns a worker thread (one at a time, latched on a module-level
//! singleton) that runs both steps off-thread and publishes phase + 0–100 progress
//! back through atomics so the dialog can render a status line and a progress bar.
//!
//! The worker only downloads. Once the update is on disk the job latches
//! `.downloaded` and the app restarts the way it always does (`restart`): unsaved
//! documents are asked about first, and at teardown `applyAtExit` hands the waiting
//! update to Velopack, which swaps the install once this process has exited and
//! starts the new version. A restart called off leaves it downloaded — Velopack
//! applies it on the next launch on its own. On failure the job latches `.failed`
//! with an error code; callers wipe the singleton when the user dismisses the dialog.

const std = @import("std");
const dvui = @import("dvui");
const auto_update = @import("auto_update.zig");
const build_opts = @import("build_opts");

const Vpk = if (auto_update.impl)
    @cImport({
        @cInclude("Velopack.h");
    })
else
    struct {};

const UpdateJob = @This();

pub const Phase = enum(u8) {
    queued = 0,
    downloading = 1,
    /// On disk, waiting for the restart that installs it (`applyAtExit`).
    downloaded = 2,
    failed = 3,
    no_update = 4,
};

allocator: std.mem.Allocator,
window: *dvui.Window,
io: std.Io,

phase: std.atomic.Value(u8) = .init(@intFromEnum(Phase.queued)),
/// 0–100 from Velopack's download callback. Stays at 0 outside `.downloading`.
progress: std.atomic.Value(u8) = .init(0),
/// Worker → main publish flag.
done: std.atomic.Value(bool) = .init(false),
/// Set on `.failed`. Read only after `phase == .failed`.
err: ?auto_update.UpdateInstallError = null,
err_msg_buf: [320]u8 = undefined,
err_msg_len: usize = 0,
/// Set with `.downloaded`, read on the GUI thread once `done` is: the manager and the release
/// it downloaded, kept for `applyAtExit`.
manager: ?*anyopaque = null,
update_info: ?*anyopaque = null,
/// Raised with `.downloaded` for `takeDownloaded`, which lowers it.
downloaded_unseen: std.atomic.Value(bool) = .init(false),

// ----------------------------------------------------------------------------
// Singleton — one in-flight install at a time. Both the About dialog and the
// launch toast share this so they can't kick concurrent downloads.
// ----------------------------------------------------------------------------

var current: ?*UpdateJob = null;

pub fn currentJob() ?*UpdateJob {
    return current;
}

/// Returns the singleton if a worker is already running; otherwise spawns one and
/// returns the new job. Caller does not own the pointer — call `clear()` when the
/// user dismisses the UI to free it.
pub fn startOrGet(allocator: std.mem.Allocator, io: std.Io) !*UpdateJob {
    if (current) |j| return j;

    const job = try allocator.create(UpdateJob);
    job.* = .{
        .allocator = allocator,
        .window = dvui.currentWindow(),
        .io = io,
    };
    current = job;
    errdefer {
        current = null;
        allocator.destroy(job);
    }

    const thread = try std.Thread.spawn(.{}, workerMain, .{job});
    thread.detach();
    return job;
}

/// Drop the singleton if the worker has published `done`. No-op while the worker
/// is still running, and for a downloaded update — that one waits for `applyAtExit`.
/// Safe to call repeatedly.
pub fn clearIfFinished() void {
    const j = current orelse return;
    if (!j.done.load(.acquire)) return;
    if (j.currentPhase() == .downloaded) return;
    current = null;
    j.allocator.destroy(j);
}

/// True once, on the GUI thread, when an update the user asked for has finished downloading —
/// the cue to restart into it (`restart.tick`).
pub fn takeDownloaded() bool {
    const j = current orelse return false;
    return j.downloaded_unseen.swap(false, .acq_rel);
}

/// Whether an update is downloaded and waiting for a restart.
pub fn downloaded() bool {
    const j = current orelse return false;
    return j.done.load(.acquire) and j.currentPhase() == .downloaded;
}

/// At teardown, on a restart: hand a downloaded update to Velopack, which waits for this process
/// to exit, swaps the install and starts the new version. False when there is none, or Velopack
/// would not take it — the app then starts itself again as it is.
pub fn applyAtExit() bool {
    if (!auto_update.impl) return false;
    if (!downloaded()) return false;
    const j = current.?;
    const mgr: *Vpk.vpkc_update_manager_t = @ptrCast(@alignCast(j.manager orelse return false));
    const info: *Vpk.vpkc_update_info_t = @ptrCast(@alignCast(j.update_info orelse return false));
    defer {
        Vpk.vpkc_free_update_info(info);
        auto_update.freeUpdateManager(j.manager);
        j.manager = null;
        j.update_info = null;
    }
    // silent=false allows the elevation prompt — /Applications is root-owned, so the bundle swap
    // needs admin rights; restart=true starts the new version once it is in place.
    if (!Vpk.vpkc_wait_exit_then_apply_updates(mgr, info.TargetFullRelease, false, true, null, 0)) {
        auto_update.logVpkError("fizzy autoupdate: wait_exit_then_apply_updates failed");
        return false;
    }
    return true;
}

pub fn currentPhase(job: *const UpdateJob) Phase {
    const raw = job.phase.load(.acquire);
    return @enumFromInt(raw);
}

pub fn progressPercent(job: *const UpdateJob) u8 {
    return job.progress.load(.monotonic);
}

pub fn phaseLabel(p: Phase) []const u8 {
    return switch (p) {
        // `.queued` is only ever visible for the brief window between
        // `startOrGet` returning and the worker actually transitioning to
        // `.downloading`. Both callers (toast + About dialog) have already
        // confirmed an update is available, so we say "Downloading…" here
        // too instead of leaking a "Checking…" / "Preparing…" state that
        // would contradict the prior step.
        .queued, .downloading => "Downloading update…",
        .downloaded => "Restarting to update…",
        .failed => "Update failed",
        .no_update => "You're up to date.",
    };
}

// ----------------------------------------------------------------------------
// Worker
// ----------------------------------------------------------------------------

fn progressCb(p_user_data: ?*anyopaque, prog: usize) callconv(.c) void {
    if (!auto_update.impl) return;
    const raw = p_user_data orelse return;
    const job: *UpdateJob = @ptrCast(@alignCast(raw));
    const clamped: u8 = @intCast(@min(prog, 100));
    job.progress.store(clamped, .monotonic);
    dvui.refresh(job.window, @src(), null);
}

fn setFailed(job: *UpdateJob, e: auto_update.UpdateInstallError) void {
    job.err = e;
    if (auto_update.impl) {
        const slice = auto_update.lastErrorSlice(&job.err_msg_buf);
        job.err_msg_len = slice.len;
    } else {
        job.err_msg_len = 0;
    }
    job.phase.store(@intFromEnum(Phase.failed), .release);
}

fn workerMain(job: *UpdateJob) void {
    defer {
        job.done.store(true, .release);
        dvui.refresh(job.window, @src(), null);
    }

    if (!auto_update.impl) {
        job.setFailed(error.NoFeed);
        return;
    }
    if (!auto_update.installLayoutSupported(job.io)) {
        job.setFailed(error.InstallLayoutUnsupported);
        return;
    }

    job.phase.store(@intFromEnum(Phase.downloading), .release);
    dvui.refresh(job.window, @src(), null);

    const mgr_opaque = auto_update.openUpdateManager(job.io, job.allocator) catch {
        job.setFailed(error.OutOfMemory);
        return;
    } orelse {
        job.setFailed(error.NoFeed);
        return;
    };
    // Kept past a successful download, for `applyAtExit`.
    var keep = false;
    defer if (!keep) auto_update.freeUpdateManager(mgr_opaque);

    const mgr: *Vpk.vpkc_update_manager_t = @ptrCast(@alignCast(mgr_opaque));

    var update_info: ?*Vpk.vpkc_update_info_t = null;
    const result = Vpk.vpkc_check_for_updates(mgr, &update_info);
    switch (result) {
        Vpk.UPDATE_AVAILABLE => {},
        Vpk.NO_UPDATE_AVAILABLE, Vpk.REMOTE_IS_EMPTY => {
            job.phase.store(@intFromEnum(Phase.no_update), .release);
            return;
        },
        Vpk.UPDATE_ERROR => {
            auto_update.logVpkError("fizzy autoupdate: check failed");
            job.setFailed(error.CheckFailed);
            return;
        },
        else => {
            job.setFailed(error.CheckFailed);
            return;
        },
    }

    const u = update_info.?;
    defer if (!keep) Vpk.vpkc_free_update_info(u);
    if (!Vpk.vpkc_download_updates(mgr, u, progressCb, job)) {
        auto_update.logVpkError("fizzy autoupdate: download failed");
        job.setFailed(error.DownloadFailed);
        return;
    }

    // On disk: the app restarts into it (`restart`), Velopack applying it at teardown.
    keep = true;
    job.manager = mgr_opaque;
    job.update_info = u;
    job.progress.store(100, .monotonic);
    job.phase.store(@intFromEnum(Phase.downloaded), .release);
    job.downloaded_unseen.store(true, .release);
}
