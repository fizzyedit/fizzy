const std = @import("std");
const builtin = @import("builtin");
const build_opts = @import("build_opts");
const file_assoc = @import("file_assoc.zig");

pub const impl: bool = build_opts.velopack_enabled and builtin.target.cpu.arch != .wasm32;

const Vpk = if (impl)
    @cImport({
        @cInclude("Velopack.h");
    })
else
    struct {};

pub fn logVpkError(prefix: []const u8) void {
    if (!impl) return;
    var err_buf: [512]u8 = undefined;
    const msg = lastErrorSlice(&err_buf);
    std.log.err("{s}: {s}", .{ prefix, msg });
}

pub fn lastErrorSlice(buf: []u8) []const u8 {
    if (!impl) return "";
    const n = Vpk.vpkc_get_last_error(buf.ptr, buf.len);
    if (n > 0 and n <= buf.len)
        return buf[0 .. n - 1];
    return "(unknown)";
}

fn castManager(m: *anyopaque) *Vpk.vpkc_update_manager_t {
    return @ptrCast(@alignCast(m));
}

/// Velopack's macOS locator expects the process image under `*.app/Contents/MacOS/*`.
/// Loose binaries from `zig build` / `zig-out/.../fizzy` are not supported — skip the C API
/// so we don't spam logs or Velopack errors on every frame.
pub fn installLayoutSupported(io: std.Io) bool {
    if (!impl) return false;
    if (builtin.os.tag != .macos) return true;

    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const n = std.process.executablePath(io, &buf) catch return false;
    return std.mem.indexOf(u8, buf[0..n], ".app/") != null;
}

/// Iterates the ordered list of GitHub repo URLs to check for updates: the
/// build-time primary (`app_repo_url`) first, then each non-empty, comma-
/// separated entry of `app_repo_url_fallback`. Used to survive a repo move:
/// point the primary at the new home and a fallback at the old one (where the
/// transitional release is published) so the binary works before and after the
/// transfer regardless of GitHub's redirects.
const RepoUrlIterator = struct {
    primary_done: bool = false,
    rest: []const u8 = build_opts.app_repo_url_fallback,

    fn next(self: *RepoUrlIterator) ?[]const u8 {
        if (!self.primary_done) {
            self.primary_done = true;
            if (build_opts.app_repo_url.len != 0) return build_opts.app_repo_url;
        }
        while (self.rest.len != 0) {
            const comma = std.mem.indexOfScalar(u8, self.rest, ',');
            const raw = if (comma) |c| self.rest[0..c] else self.rest;
            self.rest = if (comma) |c| self.rest[c + 1 ..] else self.rest[self.rest.len..];
            const item = std.mem.trim(u8, raw, " \t");
            if (item.len != 0) return item;
        }
        return null;
    }
};

/// True when at least one non-empty fallback repo URL is configured.
fn hasFallbackUrl() bool {
    var it = RepoUrlIterator{ .primary_done = true };
    return it.next() != null;
}

/// Create a Velopack update manager backed by a GitHub release source at `url`.
fn openGithubManager(allocator: std.mem.Allocator, url: []const u8) error{OutOfMemory}!?*anyopaque {
    if (!impl) return null;
    if (url.len == 0) return null;

    const repo_url_z = try allocator.dupeZ(u8, url);
    defer allocator.free(repo_url_z);

    const source: ?*Vpk.vpkc_update_source_t = Vpk.vpkc_new_source_github(repo_url_z.ptr, null, false);
    if (source == null) {
        logVpkError("fizzy autoupdate: vpkc_new_source_github failed");
        return null;
    }

    var manager: ?*Vpk.vpkc_update_manager_t = null;
    if (!Vpk.vpkc_new_update_manager_with_source(source, null, null, &manager)) {
        Vpk.vpkc_free_source(source);
        logVpkError("fizzy autoupdate: vpkc_new_update_manager_with_source failed");
        return null;
    }
    return @ptrCast(manager.?);
}

/// Create an update manager using `FIZZY_AUTOUPDATE_URL`, or the build-time repo
/// URL(s). When one or more fallback repos are configured, each candidate is
/// probed in order and the manager for the first repo reporting an available
/// update is returned; if none has an update, the first reachable repo's manager
/// is returned so callers still see a "no update" result. Callers re-run
/// `vpkc_check_for_updates` on the returned manager (cheap, and the winning repo
/// will report the same available update) to download and apply.
pub fn openUpdateManager(io: std.Io, allocator: std.mem.Allocator) error{OutOfMemory}!?*anyopaque {
    if (!impl) return null;
    if (!installLayoutSupported(io)) return null;

    if (std.c.getenv("FIZZY_AUTOUPDATE_URL")) |raw| {
        const update_url = std.mem.span(raw);
        if (update_url.len == 0) return null;
        const update_url_z = try allocator.dupeZ(u8, update_url);
        defer allocator.free(update_url_z);
        var manager: ?*Vpk.vpkc_update_manager_t = null;
        if (!Vpk.vpkc_new_update_manager(update_url_z.ptr, null, null, &manager)) {
            logVpkError("fizzy autoupdate: vpkc_new_update_manager failed");
            return null;
        }
        return @ptrCast(manager.?);
    }

    // Fast path: no fallback configured — single source, no extra probe (the
    // caller's own check is the only network round-trip), matching the original
    // behavior exactly.
    if (!hasFallbackUrl()) {
        return openGithubManager(allocator, build_opts.app_repo_url);
    }

    // Fallback(s) present: probe each candidate and return the manager for the
    // first repo with an available update, else the first reachable repo.
    var first_reachable: ?*anyopaque = null;
    var it = RepoUrlIterator{};
    while (it.next()) |url| {
        const mgr = (try openGithubManager(allocator, url)) orelse continue;

        var update_info: ?*Vpk.vpkc_update_info_t = null;
        const result = Vpk.vpkc_check_for_updates(castManager(mgr), &update_info);
        if (update_info) |info| Vpk.vpkc_free_update_info(info);

        switch (result) {
            Vpk.UPDATE_AVAILABLE => {
                std.log.info("fizzy autoupdate: update available at {s}", .{url});
                if (first_reachable) |fr| freeUpdateManager(fr);
                return mgr;
            },
            Vpk.NO_UPDATE_AVAILABLE, Vpk.REMOTE_IS_EMPTY => {
                // Reachable but nothing newer; remember the first such repo so a
                // genuine "you're up to date" can still be reported.
                if (first_reachable == null) {
                    first_reachable = mgr;
                } else {
                    freeUpdateManager(mgr);
                }
            },
            else => {
                logVpkError("fizzy autoupdate: check failed during repo probe");
                freeUpdateManager(mgr);
            },
        }
    }
    return first_reachable;
}

pub fn freeUpdateManager(m: ?*anyopaque) void {
    if (!impl) return;
    if (m == null) return;
    Vpk.vpkc_free_update_manager(castManager(m.?));
}

/// Set inside a fast-callback hook to record that Velopack dispatched an
/// install/update/uninstall lifecycle event. `appRunHook` reads this after
/// `vpkc_app_run` returns and exits the process — Velopack's docs promise an
/// auto-exit but the runtime we link against doesn't always deliver it,
/// leaving the installer's "Installing fizzy…" window hanging until its 30 s
/// timeout marks the hook failed (even though our work succeeded).
var lifecycle_hook_fired: bool = false;

pub fn appRunHook() void {
    if (!impl) return;
    // Velopack invokes fizzy with --vpk-install / --vpk-updated / --vpk-uninstall
    // CLI flags during the install / update / uninstall lifecycle, and the hooks
    // registered here are dispatched from inside vpkc_app_run() based on which
    // flag is set. Hooks must be installed *before* vpkc_app_run runs.
    if (comptime builtin.os.tag == .windows) {
        Vpk.vpkc_app_set_hook_after_install(hookAfterInstall);
        Vpk.vpkc_app_set_hook_after_update(hookAfterUpdate);
        Vpk.vpkc_app_set_hook_before_uninstall(hookBeforeUninstall);
    }
    Vpk.vpkc_app_run(null);
    if (lifecycle_hook_fired) std.process.exit(0);
}

fn hookAfterInstall(_: ?*anyopaque, _: [*c]const u8) callconv(.c) void {
    file_assoc.registerAll();
    lifecycle_hook_fired = true;
}

fn hookAfterUpdate(_: ?*anyopaque, _: [*c]const u8) callconv(.c) void {
    // Velopack's current\fizzy.exe junction always points at the latest version,
    // so the registered command stays valid across updates. Re-registering on
    // update is still cheap and self-healing if a registry value drifted.
    file_assoc.registerAll();
    lifecycle_hook_fired = true;
}

fn hookBeforeUninstall(_: ?*anyopaque, _: [*c]const u8) callconv(.c) void {
    file_assoc.unregisterAll();
    lifecycle_hook_fired = true;
}

/// Startup path: check remote feed and apply+exit when an update is available.
pub fn checkAndMaybeApplyAtStartup(io: std.Io, allocator: std.mem.Allocator) !void {
    if (!impl) return;
    if (!installLayoutSupported(io)) return;

    const mgr = (try openUpdateManager(io, allocator)) orelse return;
    defer freeUpdateManager(mgr);

    var update_info: ?*Vpk.vpkc_update_info_t = null;
    const result = Vpk.vpkc_check_for_updates(castManager(mgr), &update_info);

    switch (result) {
        Vpk.UPDATE_AVAILABLE => {
            const u = update_info.?;
            defer Vpk.vpkc_free_update_info(u);

            std.log.info("fizzy autoupdate: update available, downloading", .{});
            if (!Vpk.vpkc_download_updates(castManager(mgr), u, null, null)) {
                logVpkError("fizzy autoupdate: download failed");
                return error.UpdateDownloadFailed;
            }

            std.log.info("fizzy autoupdate: applying update and restarting", .{});
            const target_asset = u.TargetFullRelease;
            // args: manager, asset, silent=false (allow elevation prompt — /Applications
            // is root-owned so the bundle swap needs admin rights; with silent=true
            // UpdateMac refuses to ask and aborts), restart=true, restartArgs=null, len=0.
            const applied = Vpk.vpkc_wait_exit_then_apply_updates(castManager(mgr), target_asset, false, true, null, 0);
            if (!applied) {
                // Helper failed to launch or rejected the asset. Don't exit —
                // let the app start normally on the old version instead of
                // tearing down silently and re-opening as the same version.
                logVpkError("fizzy autoupdate: wait_exit_then_apply_updates failed at startup");
                return error.UpdateApplyFailed;
            }
            if (builtin.os.tag == .windows) {
                const win32 = @import("win32");
                win32.system.threading.Sleep(2000);
            } else {
                const ts: std.c.timespec = .{ .sec = 2, .nsec = 0 };
                _ = std.c.nanosleep(&ts, null);
            }
            std.process.exit(0);
        },
        Vpk.NO_UPDATE_AVAILABLE => {
            std.log.info("fizzy autoupdate: no update available", .{});
        },
        Vpk.REMOTE_IS_EMPTY => {
            std.log.info("fizzy autoupdate: remote feed empty", .{});
        },
        Vpk.UPDATE_ERROR => {
            logVpkError("fizzy autoupdate: check failed");
            return error.UpdateCheckFailed;
        },
        else => |i| {
            std.log.err("fizzy autoupdate unknown status: {d}", .{i});
            return error.UpdateCheckUnknown;
        },
    }
}

pub fn getCurrentVersionInto(manager: *anyopaque, buf: []u8) []const u8 {
    if (!impl) return "";
    const n = Vpk.vpkc_get_current_version(castManager(manager), buf.ptr, buf.len);
    if (n > 0 and n <= buf.len)
        return buf[0 .. n - 1];
    return "";
}

pub const CheckSummary = union(enum) {
    unavailable: void,
    no_feed: void,
    /// macOS: not running inside a packaged `.app` (e.g. zig-out binary).
    install_layout_unsupported: void,
    failed: void,
    no_update: void,
    remote_empty: void,
    /// Sub-slice of the `ver_buf` passed to [`checkRemoteVersionSummary`].
    available: []const u8,
};

/// Checks the remote feed and copies the available version string into `ver_buf` (if any).
pub fn checkRemoteVersionSummary(io: std.Io, allocator: std.mem.Allocator, ver_buf: []u8) error{OutOfMemory}!CheckSummary {
    if (!impl) return .{ .unavailable = {} };
    if (ver_buf.len == 0) return .{ .failed = {} };
    if (!installLayoutSupported(io)) return .{ .install_layout_unsupported = {} };

    const mgr = (try openUpdateManager(io, allocator)) orelse return .{ .no_feed = {} };
    defer freeUpdateManager(mgr);

    var update_info: ?*Vpk.vpkc_update_info_t = null;
    const result = Vpk.vpkc_check_for_updates(castManager(mgr), &update_info);

    switch (result) {
        Vpk.UPDATE_AVAILABLE => {
            const info = update_info.?;
            defer Vpk.vpkc_free_update_info(info);
            const rel: *Vpk.vpkc_asset_t = @ptrCast(info.TargetFullRelease);
            const ver_c = rel.Version orelse return .{ .failed = {} };
            const ver = std.mem.span(ver_c);
            const n = @min(ver.len, ver_buf.len);
            @memcpy(ver_buf[0..n], ver[0..n]);
            return .{ .available = ver_buf[0..n] };
        },
        Vpk.NO_UPDATE_AVAILABLE => return .{ .no_update = {} },
        Vpk.REMOTE_IS_EMPTY => return .{ .remote_empty = {} },
        Vpk.UPDATE_ERROR => return .{ .failed = {} },
        else => return .{ .failed = {} },
    }
}

pub const UpdateInstallError = error{
    NoFeed,
    NoUpdateToInstall,
    InstallLayoutUnsupported,
    CheckFailed,
    DownloadFailed,
    /// `vpkc_wait_exit_then_apply_updates` returned false — the helper rejected
    /// the asset (commonly: code-signing mismatch, channel mismatch, or the helper
    /// binary couldn't be spawned). See `vpkc_get_last_error` in the logs.
    ApplyFailed,
    OutOfMemory,
};
