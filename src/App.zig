const std = @import("std");
const builtin = @import("builtin");
const dvui = @import("dvui");
const build_opts = @import("build_opts");

const assets = @import("assets");

const icon = assets.files.@"icon.png";

const fizzy = @import("fizzy.zig");
const workbench = @import("workbench");
const pixelart = @import("pixelart");
const code = @import("code");
const WorkbenchGlobals = workbench.Globals;
const CodeGlobals = code.Globals;
const auto_update = @import("backend/auto_update.zig");
const update_notify = @import("backend/update_notify.zig");
const singleton = @import("backend/singleton.zig");
const paths = fizzy.paths;

const App = @This();
const Editor = fizzy.Editor;
const Packer = pixelart.Packer;

// App fields
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
    .size = .{ .w = 1200.0, .h = 800.0 },
    .min_size = .{ .w = 640.0, .h = 480.0 },
    .title = "fizzy",
    .icon = icon,
    .transparent = if (builtin.os.tag == .macos or builtin.os.tag == .windows) true else false,
    // macOS: Cancel-leading dialog/footer order; other platforms: OK-leading (matches dialog header close vs icon).
    .window_init_options = .{
        .button_order = if (builtin.os.tag.isDarwin()) .cancel_ok else .ok_cancel,
    },
};

fn startOptions() dvui.App.StartOptions {
    var opts = start_options_base;
    if (comptime builtin.target.cpu.arch != .wasm32) {
        const main_init = dvui.App.main_init orelse return opts;
        if (paths.configFolderZ(&pref_path_buf, main_init.io, fizzy.processEnviron(), ".")) |pref_path| {
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
    std.log.info("Fizzy version {s}", .{build_opts.app_version});

    if (comptime auto_update.impl) {
        // appRunHook handles Velopack's install/uninstall/firstrun CLI flags and
        // does not touch the network. Update checks are user-initiated from the
        // About dialog — startup must not block on connectivity.
        auto_update.appRunHook();
    }

    main_init_global = main_init;

    if (comptime builtin.target.cpu.arch != .wasm32) {
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
    .logFn = dvui.App.logFn,
};

// Runs before the first frame, after backend and dvui.Window.init()
pub fn AppInit(win: *dvui.Window) !void {
    // Snapshot the platform from DVUI's keybind selection. On native this is a
    // no-op; on wasm it tells `fizzy.platform.isMacOS()` what browser we're in.
    fizzy.platform.cacheFromWindow(win);

    // Apply the macOS window chrome and install the Space monitor while the
    // window is still hidden (see startOptions: opts.hidden = true), so the
    // full-size-content-view style mask is in place before the window is shown.
    // No-op on non-macOS (Windows chrome is applied further below).
    fizzy.backend.restoreWindowState(win);

    const allocator = appAllocator();

    // Inject shared infrastructure context into `core` so it stays decoupled from
    // the App hub (allocator for gfx, trackpad input for the canvas widget).
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

    fizzy.app = try allocator.create(App);
    fizzy.app.* = .{
        .allocator = allocator,
        .window = win,
        .root_path = allocator.dupeZ(u8, path) catch ".",
    };

    fizzy.editor = try allocator.create(Editor);
    fizzy.editor.* = Editor.init(fizzy.app) catch unreachable;

    // Workbench plugin runtime injection: host + allocator, so workbench code
    // reaches the EditorAPI surface without importing `fizzy.zig`. Mirrors pixelart.Globals.
    WorkbenchGlobals.gpa = allocator;
    WorkbenchGlobals.host = &fizzy.editor.host;
    WorkbenchGlobals.workbench = &fizzy.editor.workbench;

    // Code plugin runtime injection: host + allocator + its open-document registry,
    // which lives on `Editor.code`. The plugin's `register` adopts it as its `state`.
    CodeGlobals.gpa = allocator;
    CodeGlobals.host = &fizzy.editor.host;
    CodeGlobals.state = &fizzy.editor.code;

    // Pixel-art plugin state (tools/colors/project/clipboard/pack jobs). Created
    // before `postInit` so the pixel-art plugin's `register` can adopt it as its
    // `state`. Owned on `Editor`; torn down in `AppDeinit`.
    const pixelart_state = try allocator.create(pixelart.State);
    pixelart.Globals.gpa = allocator;
    pixelart.Globals.state = pixelart_state;
    pixelart_state.* = pixelart.State.init(allocator, &fizzy.editor.host) catch unreachable;
    fizzy.editor.pixelart_state = pixelart_state;

    // Second-stage init that needs the editor at its final heap address (e.g.
    // registering the workbench-api service whose `ctx` is this pointer).
    fizzy.editor.postInit() catch unreachable;

    // `Packer` works on web now that `zstbi.c` compiles for wasm32-freestanding
    // (`STBI_NO_STDLIB` + the `fizzy_stbi_libc.c` shims). The web pack flow
    // packs the currently-open files instead of walking a project directory.
    fizzy.packer = try allocator.create(Packer);
    fizzy.packer.* = Packer.init(allocator) catch unreachable;

    pixelart.Globals.packer = fizzy.packer;
    fizzy.editor.syncLoadedPixelartGlobals();

    // Hand the window to the listener thread and queue our own argv so the
    // first frame opens any files / project folder supplied on the command line.
    singleton.registerWindow(win, resolved_argv);

    // Install the SDL drop-file event watch and drain any drop events that
    // SDL already queued (macOS routes "Open With" through Apple Events
    // before our AppInit runs).
    fizzy.backend.installFileOpenEventHandling(win);

    // Override DVUI's default SDL metadata ("DVUI App Example") so the macOS
    // app menu reads "About fizzy" / "Hide fizzy" / "Quit fizzy" and process
    // listings show the real product name + version. `build_opts.app_version`
    // is a non-sentinel slice, so allocate a null-terminated copy for SDL.
    const version_z = std.fmt.allocPrintSentinel(allocator, "{s}", .{build_opts.app_version}, 0) catch "0.0.0";
    fizzy.backend.setSdlAppMetadata("fizzy", version_z, "com.foxnne.fizzy");

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

    update_notify.startLaunchCheck(dvui.io, fizzy.editor.settings.debug_simulate_update_available);

    // From here on the monitor's pump timer may drive frames during macOS
    // window animations.
    fizzy.backend.macosLaunchComplete();

    // Chrome and geometry are settled — reveal the window (created hidden).
    fizzy.backend.showWindow(win);
}

// Run as app is shutting down before dvui.Window.deinit()
pub fn AppDeinit() void {
    // Persist the current windowed frame while the window still exists. No-op off macOS.
    fizzy.backend.saveWindowGeometry(fizzy.app.window);
    // Persist `.fizproject` while `editor.host` and `editor.folder` are still live.
    pixelart.State.persistProject(fizzy.editor.pixelart_state);
    fizzy.editor.deinit() catch unreachable;
    // Pixel-art teardown (persists the .fizproject, frees tools/palettes/pack jobs).
    // After the editor so any editor teardown that still reads pixel-art state runs first.
    fizzy.editor.pixelart_state.deinit(fizzy.app.allocator);
    fizzy.app.allocator.destroy(fizzy.editor.pixelart_state);
    // Tear down the singleton listener after the editor so any callback
    // currently in flight finishes before we free state it touches.
    singleton.deinit();
}

// Run each frame to do normal UI
pub fn AppFrame() !dvui.App.Result {
    singleton.drainPending();
    return try fizzy.editor.tick();
}
