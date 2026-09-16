const std = @import("std");
const builtin = @import("builtin");
const dvui = @import("dvui");
const build_opts = @import("build_opts");

const assets = @import("assets");

const icon = assets.files.@"icon.png";

const fizzy = @import("fizzy.zig");
const workbench = @import("workbench");
const text = @import("text");
const auto_update = @import("app").update.auto_update;
const file_assoc = @import("backend/file_assoc.zig");
const update_notify = @import("app").update.update_notify;
const singleton = @import("app").single_instance;
const paths = fizzy.core.paths;
const Constants = @import("editor/Constants.zig");
const AppInfo = @import("app").AppInfo;

const Entry = @This();
const Editor = fizzy.Editor;

// Entry fields
allocator: std.mem.Allocator = undefined,

//delta_time: f32 = 0.0,

root_path: [:0]const u8 = undefined,
should_close: bool = false,
window: *dvui.Window = undefined,

// Wasm must not declare DebugAllocator at all — the type itself pulls in stack-trace
// capture → Threaded Io → posix.getrandom, even if never called.
const NativeGpa = std.heap.DebugAllocator(.{});
var gpa: if (builtin.target.cpu.arch == .wasm32) void else NativeGpa =
    if (builtin.target.cpu.arch == .wasm32) {} else .init;

fn appAllocator() std.mem.Allocator {
    if (comptime builtin.target.cpu.arch == .wasm32) return std.heap.page_allocator;
    return gpa.allocator();
}

// Stashed in `main` so `AppInit` (which runs later via dvui's initFn) can
// reach argv through this zig's `process.Init` API.
var main_init_global: ?std.process.Init = null;

var pref_path_buf: [std.fs.max_path_bytes]u8 = undefined;
var pref_path_len: usize = 0;

const start_options_base: dvui.App.StartOptions = .{
    .size = .{ .w = Constants.initial_window_size[0], .h = Constants.initial_window_size[1] },
    .min_size = .{ .w = Constants.min_window_size[0], .h = Constants.min_window_size[1] },
    .title = AppInfo.display_name_z,
    .icon = icon,
    .transparent = if (builtin.os.tag == .macos or builtin.os.tag == .windows) true else false,
    // macOS: Cancel-leading dialog/footer order; other platforms: OK-leading (matches dialog header close vs icon).
    .window_init_options = .{
        .button_order = if (builtin.os.tag.isDarwin()) .cancel_ok else .ok_cancel,
    },
};

/// macOS only: is the process image inside a `.app` bundle (as opposed to a loose
/// `zig-out/bin/fizzy` from `zig build run`)? Mirrors `auto_update.installLayoutSupported`'s
/// probe, minus its Velopack gating.
fn runningFromAppBundle(io: std.Io) bool {
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const n = std.process.executablePath(io, &buf) catch return false;
    return std.mem.indexOf(u8, buf[0..n], ".app/") != null;
}

fn startOptions() dvui.App.StartOptions {
    var opts = start_options_base;

    // Create the dvui window with the *same* allocator the host hands to plugins
    // (`fizzy.entry().allocator`). Without this, dvui defaults the window to the runtime's
    // `main_init.gpa`, a different allocator instance — so `dvui.currentWindow().gpa`
    // and `host.allocator` would be distinct, and a plugin that allocated with one and
    // freed with the other would corrupt the heap. Unifying them makes every allocator a
    // plugin can reach the same instance. (No-op on wasm, which uses the page allocator.)
    if (comptime builtin.target.cpu.arch != .wasm32) {
        opts.gpa = appAllocator();
        const main_init = dvui.App.main_init orelse return opts;
        // SDL's Cocoa backend implements SDL_SetWindowIcon as `[NSApp setApplicationIconImage:]`,
        // i.e. it replaces the whole *application* icon while we run. That hands AppKit a finished
        // bitmap, skipping the system treatment (rounded-rect backdrop, mask) it applies to the
        // bundle's `.icns` — so the Dock icon visibly loses its background the moment fizzy
        // launches. Inside a bundle the `.icns` is already the right icon; leave it alone. Loose
        // dev builds have no bundle icon at all, so there we still want the runtime one.
        if (comptime builtin.os.tag == .macos) {
            if (runningFromAppBundle(main_init.io)) opts.icon = null;
        }
        if (paths.configFolderZ(&pref_path_buf, main_init.io, fizzy.core.platform.processEnviron(), ".", AppInfo.current.config_dir)) |pref_path| {
            pref_path_len = pref_path.len;
            opts.pref_path = pref_path_buf[0..pref_path_len :0];
        }
        // Open hidden so AppInit (dvui's initFn) can apply the window chrome and
        // settle geometry before the window is shown — no unstyled flash. AppInit
        // calls `fizzy.backend.showWindow` once everything is in place.
        opts.hidden = true;
        // fizzy owns geometry for its custom (frame == content) window — dvui's
        // content-based persistence can't represent it (see backend.restoreWindowState
        // / saveWindowGeometry). Disable dvui's so the two don't fight.
        opts.persist_window_geometry = false;
    }
    return opts;
}

// To be a dvui App:
// * declare "dvui_app"
// * expose the backend's main function
// * use the backend's log function
pub const dvui_app: dvui.App = .{
    .config = .{ .startFn = &startOptions },
    .frameFn = AppFrame,
    .initFn = AppInit,
    .deinitFn = AppDeinit,
};

pub fn main(main_init: std.process.Init) !u8 {
    std.log.info("{s} version {s} ({s})", .{ AppInfo.current.display_name, AppInfo.current.version, @tagName(@import("builtin").mode) });

    if (comptime auto_update.impl) {
        // What fizzy wants done at Velopack's lifecycle points: claim (and release) the file
        // types it opens. The updater has no opinion about file types — see `auto_update.Hooks`.
        auto_update.hooks = .{
            .installed = file_assoc.registerAll,
            .updated = file_assoc.registerAll,
            .uninstalling = file_assoc.unregisterAll,
        };
        // appRunHook handles Velopack's install/uninstall/firstrun CLI flags and
        // does not touch the network. Update checks are user-initiated from the
        // About dialog — startup must not block on connectivity.
        auto_update.appRunHook();
    }

    main_init_global = main_init;

    if (comptime builtin.target.cpu.arch != .wasm32) {
        // Where fizzy's file dialogs start, and what it learns from where they end: its own
        // recents, falling back to the open project folder. The platform dialog has no memory
        // of what the user was doing; that memory is the app's.
        fizzy.backend.setDialogDirs(.{
            .ctx = undefined,
            .initial = struct {
                fn f(_: *anyopaque, mode: fizzy.backend.DialogMode) ?[]const u8 {
                    const editor = fizzy.editor();
                    const remembered = switch (mode) {
                        .save => editor.app.recents.last_save_folder,
                        .open => editor.app.recents.last_open_folder,
                    };
                    return remembered orelse editor.app.folder;
                }
            }.f,
            .remember = struct {
                fn f(_: *anyopaque, mode: fizzy.backend.DialogMode, dir: []const u8) void {
                    const editor = fizzy.editor();
                    const slot = switch (mode) {
                        .save => &editor.app.recents.last_save_folder,
                        .open => &editor.app.recents.last_open_folder,
                    };
                    const copy = editor.app.gpa.dupe(u8, dir) catch {
                        std.log.err("failed to remember dialog directory {s}", .{dir});
                        return;
                    };
                    if (slot.*) |old| editor.app.gpa.free(old);
                    slot.* = copy;
                }
            }.f,
        });

        // Before anything native allocates on the app's behalf — dialog paths, menu titles.
        fizzy.backend.setAllocator(appAllocator());

        // The lock is per *application*, so fizzy names itself rather than the framework
        // reading fizzy's identity file — which is exactly what made it fizzy's before.
        singleton.setIdentity(AppInfo.bundle_id_z, AppInfo.current.name);

        // What fizzy does with a path a second launch forwards: a directory becomes the project
        // folder, a file becomes a document — and only when nothing is open yet does it look
        // upward for a project marker first. All of that is fizzy's, so it lives here.
        singleton.setSink(.{
            .ctx = undefined,
            .openFolder = struct {
                fn f(_: *anyopaque, path: []const u8) anyerror!void {
                    try fizzy.editor().setProjectFolder(path);
                }
            }.f,
            .openFile = struct {
                fn f(_: *anyopaque, path: []const u8, project_root: ?[]const u8) anyerror!void {
                    if (project_root) |root| fizzy.editor().setProjectFolder(root) catch |err| {
                        std.log.warn("found project root '{s}' but failed to set: {t}", .{ root, err });
                    };
                    _ = try fizzy.editor().openFilePath(path, fizzy.editor().workbench.currentGroupingID());
                }
            }.f,
            .wantsProjectRoot = struct {
                fn f(_: *anyopaque) bool {
                    return fizzy.editor().app.folder == null;
                }
            }.f,
        });
        try singleton.earlyStartup(appAllocator(), main_init);
    }

    if (@hasDecl(dvui.backend, "main")) {
        return dvui.App.main(main_init);
    }
    try dvui.App.main();
    return 0;
}

pub const panic = dvui.App.panic;
pub const std_options: std.Options = .{
    .logFn = logFn,
};

// Forwards every log call to dvui's usual sink (stderr on native, the browser console on
// web) and also into `fizzy.OutputLog`, so fizzy's "Output" bottom panel can show it — except
// while `FIZZY_LOG_REFRESH` is on, see `refresh_log_active`.
fn logFn(comptime level: std.log.Level, comptime scope: @EnumLiteral(), comptime format: []const u8, args: anytype) void {
    if (!refresh_log_active) fizzy.OutputLog.append(level, scope, format, args);
    dvui.App.logFn(level, scope, format, args);
}

/// `FIZZY_LOG_REFRESH=1` logs every `dvui.refresh` with the source location that asked for it.
///
/// This answers the one question a profiler cannot: when the app will not go to sleep, a profile
/// shows where the time goes, but "who keeps asking for another frame" is a different question and
/// usually a different culprit. dvui already tracks it — this just exposes the switch, since fizzy
/// does not surface dvui's debug window.
///
/// Expect a lot of output: it logs per refresh, per frame. Pipe it and count by source line; the
/// caller that appears on every single frame is the one keeping the app awake.
///
/// While it is on, log lines bypass `fizzy.OutputLog` (see `refresh_log_active`) and go to stderr
/// only: the Output panel grows by a row per logged refresh, that growth changes its scroll
/// container's virtual size, and the resulting `dvui.refresh` asks for another frame — so with the
/// panel visible the diagnostic keeps the app awake all by itself, and reports its own feedback
/// loop as the culprit.
fn initRefreshLogFromEnv() void {
    if (comptime @import("builtin").target.cpu.arch == .wasm32) return;
    const raw = std.c.getenv("FIZZY_LOG_REFRESH") orelse return;
    if (std.mem.eql(u8, std.mem.span(raw), "0")) return;
    refresh_log_active = true;
    _ = dvui.debug.logRefresh(true);
    std.log.info("refresh logging on (FIZZY_LOG_REFRESH); Output panel logging is off for this run", .{});
}

/// Set by `initRefreshLogFromEnv`; keeps refresh-log output out of the Output panel.
var refresh_log_active = false;

// Runs before the first frame, after backend and dvui.Window.init()
pub fn AppInit(win: *dvui.Window) !void {
    // Snapshot the platform from DVUI's keybind selection. On native this is a
    // no-op; on wasm it tells `fizzy.core.platform.isMacOS()` what browser we're in.
    fizzy.core.platform.cacheFromWindow(win);
    fizzy.core.hitch.initFromEnv();
    initRefreshLogFromEnv();
    fizzy.core.FrameTarget.init();

    // Apply the macOS window chrome and install the Space monitor while the
    // window is still hidden (see startOptions: opts.hidden = true), so the
    // full-size-content-view style mask is in place before the window is shown.
    // No-op on non-macOS (Windows chrome is applied further below).
    fizzy.backend.restoreWindowState(win);

    const allocator = appAllocator();

    // Inject shared infrastructure context into `core` so it stays decoupled from
    // the Entry hub (allocator for gfx, trackpad input for the canvas widget).
    fizzy.core.gpa = allocator;
    fizzy.core.takeTrackpadPinchRatio = fizzy.backend.takeTrackpadPinchRatio;

    const resolved_argv = singleton.consumeStartupArgv();
    defer singleton.freeResolvedArgv(allocator, resolved_argv);

    // Run from the directory where the executable is located so relative assets can be found.
    // No-op on wasm: there's no executable path or working directory in the browser, and
    // `std.posix.PATH_MAX` / `std.posix.system.chdir` are unavailable on wasm32-freestanding.
    // Assets on wasm are baked into the binary via `@embedFile`, so no chdir is needed.
    var buffer: [1024]u8 = undefined;
    const path: []const u8 = path_blk: {
        if (comptime builtin.target.cpu.arch == .wasm32) break :path_blk ".";
        const exe_dir_len = std.process.executableDirPath(dvui.io, buffer[0..]) catch 0;
        const dir: []const u8 = if (exe_dir_len > 0) buffer[0..exe_dir_len] else ".";
        var path_buf: [std.posix.PATH_MAX]u8 = undefined;
        if (dir.len < path_buf.len) {
            @memcpy(path_buf[0..dir.len], dir);
            path_buf[dir.len] = 0;
            _ = std.posix.system.chdir(@ptrCast(&path_buf));
        }
        break :path_blk dir;
    };

    const app_ptr = try allocator.create(Entry);
    app_ptr.* = .{
        .allocator = allocator,
        .window = win,
        .root_path = allocator.dupeZ(u8, path) catch ".",
    };

    const editor_ptr = try allocator.create(Editor);
    fizzy.setInstances(app_ptr, editor_ptr);
    editor_ptr.* = Editor.init(app_ptr) catch unreachable;

    // Workbench fizzy-owned state: wire before plugin `register`.
    workbench.runtime.setWorkbench(&fizzy.editor().workbench);

    // Second-stage init that needs the editor at its final heap address (e.g. registering the
    // workbench-api service whose `ctx` is this pointer). This loads the built-in plugins,
    // including pixi as a generic dylib that owns its own state + atlas packer.
    fizzy.editor().postInit() catch unreachable;

    // Hand the window to the listener thread and queue our own argv so the
    // first frame opens any files / project folder supplied on the command line.
    singleton.registerWindow(win, resolved_argv);

    // Install the SDL drop-file event watch and drain any drop events that
    // SDL already queued (macOS routes "Open With" through Apple Events
    // before our AppInit runs).
    fizzy.backend.installFileOpenEventHandling(win);

    // Override DVUI's default SDL metadata ("DVUI Entry Example") so the macOS
    // app menu reads "About fizzy" / "Hide fizzy" / "Quit fizzy" and process
    // listings show the real product name + version. `build_opts.app_version`
    // is a non-sentinel slice, so allocate a null-terminated copy for SDL.
    const version_z = std.fmt.allocPrintSentinel(allocator, "{s}", .{build_opts.app_version}, 0) catch "0.0.0";
    fizzy.backend.setSdlAppMetadata(AppInfo.display_name_z, version_z, AppInfo.bundle_id_z);

    fizzy.backend.setupMacOSMenuBar();

    // macOS trackpad pinch-zoom. NSEventTypeMagnify is not delivered through SDL3, so we install
    // an AppKit local event monitor to forward magnification deltas into the canvas widget.
    // No-op on Windows/Linux/web.
    fizzy.backend.installTrackpadGestureMonitor();

    // macOS window chrome was already applied in restoreWindowState (called
    // near the top of AppInit while the window was hidden). The window opens at
    // its saved windowed geometry; fullscreen/maximize are not restored. Windows
    // chrome goes here.
    if (builtin.os.tag != .macos) {
        fizzy.backend.setWindowStyle(win);
    }

    // The install runs on a background thread and outlives the frame that starts it, so it
    // needs a long-lived allocator — the app's, which `app/update/` cannot name for itself.
    update_notify.setAllocator(allocator);
    update_notify.startLaunchCheck(dvui.io, Constants.debug_simulate_update_available);

    // From here on the monitor's pump timer may drive frames during macOS
    // window animations.
    fizzy.backend.macosLaunchComplete();

    // Chrome and geometry are settled — reveal the window (created hidden).
    fizzy.backend.showWindow(win);
}

// Run as app is shutting down before dvui.Window.deinit()
pub fn AppDeinit(_: *dvui.Window) void {
    // Persist the current windowed frame while the window still exists. No-op off macOS.
    fizzy.backend.saveWindowGeometry(fizzy.entry().window);
    // `editor.deinit` runs each plugin's `deinit` first (pixi's persists its `.fizproject` and
    // frees its own state + packer while `editor.app.host`/folder are still live).
    fizzy.editor().deinit() catch unreachable;
    // Tear down the singleton listener after the editor so any callback
    // currently in flight finishes before we free state it touches.
    singleton.deinit();
}

// Run each frame to do normal UI
pub fn AppFrame() !dvui.App.Result {
    fizzy.core.hitch.frameBegin();
    defer fizzy.core.hitch.frameEnd();
    singleton.drainPending();
    // The whole frame draws into a texture — see `core.FrameTarget` for why.
    frame_target.begin();
    defer frame_target.end();
    return try fizzy.editor().tick();
}

var frame_target: fizzy.core.FrameTarget = .{};
