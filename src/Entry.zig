const std = @import("std");
const builtin = @import("builtin");
const dvui = @import("dvui");
const build_opts = @import("build_opts");
/// The app's version for SDL's app metadata, which takes a C string.
const app_version_z = std.fmt.comptimePrint("{s}", .{build_opts.app_version});

const assets = @import("assets");

const icon = assets.files.@"icon.png";

const fizzy = @import("fizzy.zig");
const workbench = @import("workbench");
const text = @import("text");
const auto_update = @import("app").update.auto_update;
const file_assoc = @import("backend/file_assoc.zig");
const update_notify = @import("app").update.update_notify;
const singleton = @import("app").single_instance;
const restart = @import("app").restart;
const automation = @import("app").automation;
const paths = fizzy.core.paths;
const Constants = @import("editor/Constants.zig");
const AppInfo = @import("app").AppInfo;

const Entry = @This();
const Editor = fizzy.Editor;
const verdict = @import("editor/verdict.zig");

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
    // Linux too, for the rounded corners outside the window's fill (`Editor`): Vulkan composites
    // the swapchain's alpha on Wayland. Its fill stays opaque — nothing blurs behind it there.
    .transparent = if (builtin.os.tag == .macos or builtin.os.tag == .windows or builtin.os.tag == .linux) true else false,
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
    // dvui's own web default is `std.Io.failing`, whose clocks read 0.
    if (comptime builtin.target.cpu.arch == .wasm32) opts.io = @import("backend/web_io.zig").wasm_io;

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
        // A profile is the config folder itself (`app.profile`), for SDL's preferences too.
        const pref: ?[:0]const u8 = if (@import("app").profile.root) |root|
            std.fmt.bufPrintZ(&pref_path_buf, "{s}", .{root}) catch null
        else
            paths.configFolderZ(&pref_path_buf, main_init.io, fizzy.core.platform.processEnviron(), ".", AppInfo.current.config_dir);
        if (pref) |pref_path| {
            pref_path_len = pref_path.len;
            opts.pref_path = pref_path_buf[0..pref_path_len :0];
        }
        // Open hidden so AppInit (dvui's initFn) can apply the window chrome and
        // settle geometry before the window is shown — no unstyled flash. AppInit
        // calls `fizzy.backend.showWindow` once everything is in place.
        opts.hidden = true;
        // The window's geometry is kept by frame, not by content rect (`platform.geometry`), and in
        // `layout.zon` beside the layout — fizzy's chrome changes how the two relate after the
        // window is made, which dvui's content-rect persistence cannot follow. Off, so the two don't
        // fight.
        opts.persist_window_geometry = false;
        // The app's own name, version and id, before SDL starts: the macOS app menu is built
        // from them (About / Hide / Quit <name>), where the backend's defaults are an example's.
        fizzy.backend.setSdlAppMetadata(AppInfo.display_name_z, app_version_z, AppInfo.bundle_id_z);
        // Linux: fizzy draws its own title bar and the window's shadow (`linux_titlebar`), which
        // SDL has to know before the window is made.
        if (comptime builtin.os.tag == .linux) {
            const in = Constants.linux_window_shadow_insets;
            fizzy.backend.useClientDecorations(.{ .left = in.left, .top = in.top, .right = in.right, .bottom = in.bottom });
        }
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

        if (verdict.refuseWithoutProfile(appAllocator(), main_init.minimal.args)) |code| return code;

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

        // Both read relative to where fizzy was launched, before `AppInit` moves to its own directory.
        Editor.Demo.readEnvTape(appAllocator(), main_init.io);
        if (verdict.init(appAllocator(), main_init.io, @import("app").profile.root)) |code| return code;
    }

    if (@hasDecl(dvui.backend, "main")) {
        const status = try dvui.App.main(main_init);
        if (comptime builtin.target.cpu.arch == .wasm32) return status;
        if (!verdict.on()) return status;
        // Everything the app allocated is freed by now: what the debug allocator still holds leaked.
        const leaks: ?bool = if (comptime std.debug.runtime_safety) gpa.deinit() == .leak else null;
        return verdict.finish(leaks);
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
        .root_path = try allocator.dupeZ(u8, path),
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

    // Whether dvui went quiet at the end of each frame, for the `automation` service's `settled`.
    if (comptime @hasDecl(dvui.backend, "frame_ended_hook")) dvui.backend.frame_ended_hook = frameEnded;

    // Hand the window to the listener thread and queue our own argv so the
    // first frame opens any files / project folder supplied on the command line.
    singleton.registerWindow(win, resolved_argv);

    // Install the SDL drop-file event watch and drain any drop events that
    // SDL already queued (macOS routes "Open With" through Apple Events
    // before our AppInit runs).
    fizzy.backend.installFileOpenEventHandling(win);

    fizzy.backend.setupMacOSMenuBar();

    // Trackpad pinch-zoom: SDL's pinch events (macOS, iOS, Linux under Wayland or X11), gathered
    // for the canvas widget to drain each frame (`platform.gestures`).
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
    // A restart asked for (the Restart command, a downloaded update): started again once
    // everything is saved and the single-instance listener is down, so the new instance owns it
    // rather than handing its launch to this one.
    defer restart.relaunch(dvui.io, appAllocator());
    // Persist the current windowed frame while the window still exists. No-op off macOS.
    fizzy.backend.saveWindowGeometry(fizzy.entry().window);
    // Before the editor goes: the bar's hooks read its host.
    fizzy.backend.teardownMacOSMenuBar();
    // `editor.deinit` runs each plugin's `deinit` first (pixi's persists its `.fizproject` and
    // frees its own state + packer while `editor.app.host`/folder are still live).
    fizzy.editor().deinit() catch unreachable;
    // Tear down the singleton listener after the editor so any callback
    // currently in flight finishes before we free state it touches.
    singleton.deinit();
    // The instances themselves, last: nothing that could reach them is left running.
    const allocator = appAllocator();
    allocator.destroy(fizzy.editor());
    allocator.free(fizzy.entry().root_path);
    allocator.destroy(fizzy.entry());
}

// Run each frame to do normal UI
pub fn AppFrame() !dvui.App.Result {
    fizzy.core.hitch.frameBegin();
    defer fizzy.core.hitch.frameEnd();
    fizzy.core.profile.hostFrameBegin(lastSubmitNs());
    defer fizzy.core.profile.hostFrameEnd();
    singleton.drainPending();
    // Once, or — while a demo is seeking — again and again unseen until it lands (`frames`).
    const player = &fizzy.editor().demo.player;
    const win = fizzy.entry().window;
    const res = try player.frames(win, frameOnce, automation.Player.backendClock(win));
    // A run that ends in a verdict quits once its tape has ended.
    if (verdict.frame(&fizzy.editor().demo)) return .close;
    return res;
}

/// The backend's `frame_ended_hook`: what `Window.end` said, to the `automation` service.
fn frameEnded(end_micros: ?u32) bool {
    return fizzy.editor().demo.service.frameEnded(end_micros);
}

/// How long the backend took to end the last frame after the app's part of it — its draws
/// handed to the GPU — where the backend measures that (the web's does, `WebBackend`).
fn lastSubmitNs() ?u64 {
    if (comptime @hasDecl(dvui.backend, "last_submit_ns")) return dvui.backend.last_submit_ns;
    return null;
}

/// One run of the app's frame.
fn frameOnce() !dvui.App.Result {
    // First, before anything reads `dvui.events()` or the frame target binds: a playing demo adds
    // its input after the real input, takes the real input it owns, and says whether this run is
    // seen (see `app.automation.Player.frame`).
    fizzy.editor().demo.frame();
    // A float asked out of the main window, or back into it, goes before anything is drawn
    // (`Editor.Popout`: on by default on macOS, `FIZZY_POPOUT` elsewhere).
    Editor.Popout.beginFrame(&fizzy.editor().app.layout);
    // The whole frame draws into a texture — see `core.FrameTarget` for why.
    {
        const prof = fizzy.core.profile.begin("fizzy", "frame target: begin");
        defer prof.end();
        frame_target.begin();
    }
    defer {
        const prof = fizzy.core.profile.begin("fizzy", "frame target: onto the window");
        defer prof.end();
        frame_target.end();
    }
    // Before that replays the subwindows into the frame: a float out of the main window is
    // replayed into its own window instead.
    defer Editor.Popout.endFrame(&fizzy.editor().app.layout);
    const prof_tick = fizzy.core.profile.begin("fizzy", "tick");
    defer prof_tick.end();
    return try fizzy.editor().tick();
}

var frame_target: fizzy.core.FrameTarget = .{};
