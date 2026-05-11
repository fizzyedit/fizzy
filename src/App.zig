const std = @import("std");
const builtin = @import("builtin");
const dvui = @import("dvui");
const build_opts = @import("build_opts");

const assets = @import("assets");

const icon = assets.files.@"icon.png";

const pixi = @import("pixi.zig");
const auto_update = @import("auto_update.zig");

const App = @This();
const Editor = pixi.Editor;
const Packer = pixi.Packer;
//const Assets = pixi.Assets;

// App fields
allocator: std.mem.Allocator = undefined,

//delta_time: f32 = 0.0,

root_path: [:0]const u8 = undefined,
should_close: bool = false,
window: *dvui.Window = undefined,

var gpa: std.heap.DebugAllocator(.{}) = .init;

// To be a dvui App:
// * declare "dvui_app"
// * expose the backend's main function
// * use the backend's log function
pub const dvui_app: dvui.App = .{
    .config = .{
        .options = .{
            .size = .{ .w = 1200.0, .h = 800.0 },
            .min_size = .{ .w = 640.0, .h = 480.0 },
            .title = "Pixi",
            .icon = icon,
            .transparent = if (builtin.os.tag == .macos or builtin.os.tag == .windows) true else false,
            // macOS: Cancel-leading dialog/footer order; other platforms: OK-leading (matches dialog header close vs icon).
            .window_init_options = .{
                .button_order = if (builtin.os.tag.isDarwin()) .cancel_ok else .ok_cancel,
            },
        },
    },
    .frameFn = AppFrame,
    .initFn = AppInit,
    .deinitFn = AppDeinit,
};

pub fn main(main_init: std.process.Init) !u8 {
    std.log.info("Pixi version {s}", .{build_opts.app_version});

    if (comptime auto_update.impl) {
        auto_update.appRunHook();

        // Two update paths:
        //   - PIXI_AUTOUPDATE_URL (env var): plain HTTP feed URL or local directory.
        //     Used for local end-to-end testing against a `vpk pack` output dir
        //     without round-tripping through GitHub.
        //   - Default: GitHub Releases on the repo baked in at build time
        //     (`-Drepo-url`, defaults to https://github.com/foxnne/pixi). The C
        //     API picks the asset for the channel that was set at pack time
        //     (`<arch>-<os>`, matching zig-out / `vpk pack --channel`).
        if (std.c.getenv("PIXI_AUTOUPDATE_URL")) |raw| {
            const update_url = std.mem.span(raw);
            if (update_url.len > 0) {
                try auto_update.checkAndMaybeApplyAtStartup(main_init.io, std.heap.page_allocator);
            }
        } else if (build_opts.app_repo_url.len > 0) {
            try auto_update.checkAndMaybeApplyAtStartup(main_init.io, std.heap.page_allocator);
        }
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
    const allocator = gpa.allocator();

    // Run from the directory where the executable is located so relative assets can be found.
    var buffer: [1024]u8 = undefined;
    const exe_dir_len = std.process.executableDirPath(dvui.io, buffer[0..]) catch 0;
    const path: []const u8 = if (exe_dir_len > 0) buffer[0..exe_dir_len] else ".";
    {
        var path_buf: [std.posix.PATH_MAX]u8 = undefined;
        if (path.len < path_buf.len) {
            @memcpy(path_buf[0..path.len], path);
            path_buf[path.len] = 0;
            _ = std.posix.system.chdir(@ptrCast(&path_buf));
        }
    }

    pixi.app = try allocator.create(App);
    pixi.app.* = .{
        .allocator = allocator,
        .window = win,
        .root_path = allocator.dupeZ(u8, path) catch ".",
    };

    pixi.editor = try allocator.create(Editor);
    pixi.editor.* = Editor.init(pixi.app) catch unreachable;

    pixi.packer = try allocator.create(Packer);
    pixi.packer.* = Packer.init(allocator) catch unreachable;

    pixi.backend.setupMacOSMenuBar();
}

// Run as app is shutting down before dvui.Window.deinit()
pub fn AppDeinit() void {
    pixi.editor.deinit() catch unreachable;
}

// Run each frame to do normal UI
pub fn AppFrame() !dvui.App.Result {
    return try pixi.editor.tick();
}
