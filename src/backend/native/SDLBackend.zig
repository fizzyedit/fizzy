//! Fizzy's native backend: SDL3 for the window, events and the OS, and an SDL_GPU renderer of
//! fizzy's own (`GpuRenderer`) for drawing — the way fizzy owns its web backend
//! (`src/backend/WebBackend.zig`). Selected with `-Dnative-backend=fizzy` (`build/exe.zig`),
//! linked to dvui in its `custom` mode, so dvui's shape — and the plugin ABI fingerprint — is
//! what it is with dvui's own `sdl3` backend.
//!
//! Started as a copy of the pinned dvui's `src/backends/sdl.zig` (with the fizzy-dev fork's
//! precise targets and stuck-modifier fix). The window, event, macOS-monitor and `dvui.App`
//! entry code is kept as it was there — the event code verbatim, so it can be diffed against
//! upstream — and only SDL3 is supported. What changed is drawing: SDL_Renderer has fixed
//! shaders, and fizzy needs fragment programs of its own (`program_api`); every
//! `drawClippedTriangles`/texture/target call goes to `GpuRenderer`.
const std = @import("std");
const builtin = @import("builtin");
const dvui = @import("dvui");

const GpuRenderer = @import("GpuRenderer.zig");
pub const viewport_map = @import("viewport_map.zig");

/// What an app gets from its window beyond drawing into it: native dialogs, files the OS hands
/// over, trackpad gestures, the window's chrome and state (`src/backend/native/platform`).
pub const platform = @import("platform");

/// SDL3 only. Kept as a constant so the event code below stays a verbatim copy of dvui's
/// `sdl.zig` (its `if (sdl3)` branches are the ones compiled).
const sdl3 = true;

pub const c = @import("sdl3-c");

/// Behaves as dvui's SDL3 backend to dvui (AccessKit's window lookup, and the like).
pub const kind: dvui.enums.Backend = .sdl3;

pub const SDLBackend = @This();
pub const Context = *SDLBackend;

const log = std.log.scoped(.SDLBackend);

/// SDL's main-callbacks entry (`SDL_EnterAppMainCallbacks`) on the platforms whose OS resize
/// loops otherwise stall the frame: what dvui's `sdl3-callbacks` option defaults to.
const use_sdl_callbacks = builtin.target.os.tag == .macos or builtin.target.os.tag == .windows or builtin.target.os.tag == .ios;

// Global io instance assigned to `dvui.io`
io: std.Io,
// allocator that is reset each frame. Passed in via `SDL_Backend.begin`
arena: std.mem.Allocator = undefined,

window: *c.SDL_Window,
/// The drawing half. Heap-allocated so its address is stable while this struct is copied
/// around by value (`initWindow` returns one).
gpu: *GpuRenderer,

/// Optional hook invoked during `Window.begin` just before pixel/window sizes are queried.
/// Useful to sync AppKit window state into SDL (e.g. during Space / zoom animations).
begin_hook: ?*const fn (*SDLBackend) void = null,

touch_mouse_events: bool = false,
log_events: bool = false,
last_pixel_size: dvui.Size.Physical = .{ .w = 800, .h = 600 },
last_window_size: dvui.Size.Natural = .{ .w = 800, .h = 600 },
cursor_last: dvui.enums.Cursor = .arrow,
text_input_rect_last: ?dvui.Rect.Natural = null,
/// The window text input was last started in (`textInputRect`): this one, or a viewport's.
text_input_window: ?*c.SDL_Window = null,
cursor_backing: [cursor_enum_count]?*c.SDL_Cursor = @splat(null),
cursor_backing_tried: [cursor_enum_count]bool = @splat(false),

manage_backend_tracking: dvui.Backend.Common.TrackManageBackend = .{},

ak_should_initialized: bool = dvui.accesskit_enabled,
/// If set to true, the backend owns the window and should free ressources on deinit
we_own_window: bool = false,
/// For multi os windows, allow to destroy window/renderer without quitting SDL
/// Has no effect if `we_own_window == false`
sdl_quit: bool = true,
/// If set to true, the window will be cleared when begin() is called. The renderer clears the
/// window's drawable on its first pass of every frame regardless (a fresh drawable holds
/// nothing worth keeping); this decides only whether a frame that draws nothing to the window
/// still presents a cleared one.
clear_window_on_begin: bool = false,
/// Added to the wall clock by `nanoTime`: how far a demo's silent frames have moved the app's
/// clock on (`app.automation.Player.frames`). Only grows.
clock_ahead_ns: i128 = 0,
/// Last known window rect while not maximized/fullscreen/minimized, tracked
/// from move/resize events
window_geometry: WindowGeometry = .{},
// Set by `initWindow` and `initWindowSecondary` for use by eventual child window.
init_opts_save: ?InitOptions = null,
/// The OS windows besides this one that show part of its frame (`Viewport`).
viewports: [max_viewports]?Viewport = @splat(null),
/// Where a held pointer is read while one is held (`PointerPin`, `heldPoint`).
pointer_pin: PointerPin = .none,
/// macOS: the main window may have come in front of a viewport's window — it took focus, was
/// pressed on, shown or restored — or a viewport's window has just shown: put each viewport's window
/// back over it at the next present (`renderPresent`). Asking AppKit for the order is a trip to the
/// window server — 2 ms a frame on average, 10 at worst, asked every frame — so it is asked only
/// then.
/// The main window has been focused once (`noteMainForward`).
main_focused_once: bool = false,
/// The main window's skin, as last set (`platform.window.setBackground`): each float's own window
/// is skinned so as it opens (`viewportGlass`).
window_skin: ?dvui.Color = null,

const cursor_enum_count = @typeInfo(dvui.enums.Cursor).@"enum".fields.len;

/// The most viewports open at once.
pub const max_viewports = 8;

/// An OS window besides the main one that shows a part of the one frame: a float popped out of
/// the main window (`docs/POPOUT_WINDOWS_PLAN.md`). There stays one `dvui.Window`. The part this
/// window shows is a band of the frame past the main window's edge (`viewport_map`): the app
/// draws the float there, replays its drawing into a target of its own and hands that over
/// (`viewportPresent`), and the pointer over this window goes back to dvui where the window
/// shows it in the frame (`addViewportEvent`). Drawn by the main window's renderer, on its
/// command buffer (`GpuRenderer.presentInto`).
pub const Viewport = struct {
    window: *c.SDL_Window,
    /// Where its band starts in the frame, physical pixels (`viewport_map.band`).
    band: viewport_map.Point,
    /// Where the main window's top left was on the desktop when it opened, and the main window's
    /// pixels per point then: how its band lies on the desktop, for its whole life
    /// (`viewport_map`).
    anchor: viewport_map.Point,
    density: f32,
    /// Where its window was last put, whole points: moved or resized only when that changes.
    screen: viewport_map.ScreenRect,
    /// The part of the frame it shows, physical pixels (`viewport_map.place`).
    frame: viewport_map.Rect,
    /// Created hidden and shown once a frame has been presented into it, so it never shows
    /// empty: `shown` once it is on screen with a frame in it.
    shown: bool = false,
    /// Shown before any frame was in it, where the driver gives a hidden window nothing to draw
    /// into (Vulkan on X11): it is clear, so it shows nothing until its first frame.
    mapped: bool = false,
    /// The OS asked to close it (⌘W, the Window menu): the app takes its float back in.
    close_requested: bool = false,
    /// Its part of the frame, drawn this frame, for `renderPresent` to copy into it.
    pending: ?dvui.TextureTarget = null,
    /// What its float says of a press on it, which SDL's hit test answers the OS from
    /// (`viewportHitTest`): the OS moves and resizes the window itself, as any window.
    hints: viewport_map.Hints = .{},
    /// The OS moved or resized it since the app last asked (`viewportOsPlaced`).
    os_placed: bool = false,
    /// The OS is moving or resizing it under a held press (where there is no move loop to say so:
    /// not Windows), and its size when it began (`viewportOsMoveEnded`).
    os_moving: bool = false,
    os_start: viewport_map.ScreenRect = .{},
    /// When the app last put it somewhere: where placing a window is asynchronous (X11), what the
    /// window says of itself just after is still on its way there, not the OS's doing.
    app_placed_ns: u64 = 0,
    /// Windows: the OS's move/size loop for it (`win32_titlebar.viewportChrome`).
    win32_loop: platform.win32_titlebar.ViewportLoop = .{},
    /// macOS: put somewhere new this frame (`screen`), applied with the frame's picture in one
    /// Core Animation transaction (`renderPresent`).
    frame_pending: bool = false,
    /// A window that only shows (`viewportOpenCarry`): the pointer passes through it, so no held
    /// pointer is read against it, and it is kept above every window by its level, not ordered over
    /// the main one.
    passive: bool = false,
    /// A held pointer over it is read as over what is beneath it — the main window — this frame
    /// (`viewportSeeThrough`): a float's window gone to its ghost while a view is carried out of it.
    see_through: bool = false,
    /// How opaque it is, as last set (`viewportFade`).
    alpha: f32 = 1,
    /// A carry window's shape: the corner radius, points, of its material filling it — negative,
    /// hidden (`viewportCarryShape`) — asked, and as last applied with its picture, at the size it
    /// was applied at.
    carry_radius: f32 = -1,
    carry_radius_shown: f32 = -2,
    carry_size_shown: [2]i32 = .{ 0, 0 },
    /// How opaque it is, asked and as last applied — with its shape, in the same transaction.
    carry_alpha: f32 = 1,
    carry_alpha_shown: f32 = -1,
    /// An overlay (`viewportOpenOverlay`): the OS's glass in it as last asked
    /// (`viewportOverlayGlass`), applied with its picture, in the same transaction.
    overlay: bool = false,
    glass: [max_glass]GlassShape = undefined,
    glass_n: usize = 0,
    glass_spacing: f32 = 0,
    glass_look: GlassLook = .{},
    glass_dirty: bool = false,
    /// A menu's window (`viewportOpenMenu`): placed in the main window's frame, and the pointer
    /// over it read there too, plus `main_offset` — where the menu is drawn in the frame from where
    /// its window lies over the main one: nothing for a menu of the main window's, the way to its
    /// float's band for one opened in a float that is out (`viewportMainOffset`).
    menu: bool = false,
    main_offset: viewport_map.Point = .{ .x = 0, .y = 0 },
    /// To be put over the main window before the frame presents, once (`noteMainForward`).
    over_main: bool = false,
    /// The window it rides on (`viewportOpenMenu`): the main window, for a menu or dialog of the
    /// main window's; a float's, for a dialog opened in it. Made that window's child once shown, so
    /// the OS moves it with it — smoothly through a drag, which the app's frames could only follow
    /// a frame behind — and put somewhere new only when where it lies over that window changes
    /// (`viewportPlaceRiding`): that place as last placed (`ride_key`), and how the part of the
    /// frame it showed then lay from the frame asked (`ride_off`, `ride_size`).
    ride: ?*c.SDL_Window = null,
    ride_key: ?viewport_map.Rect = null,
    ride_off: viewport_map.Point = .{ .x = 0, .y = 0 },
    ride_size: viewport_map.Point = .{ .x = 0, .y = 0 },
    /// A dialog's window (`viewportOpenMenu`): a menu's, but in its window's stacking.
    dialog: bool = false,
};

/// A piece of the OS's glass in an overlay (`viewportOverlayGlass`): a rounded rect, points from the
/// window's top left. As `fizzy_macos_viewport_overlay_glass` reads it.
pub const GlassShape = extern struct {
    x: f64,
    y: f64,
    w: f64,
    h: f64,
    radius: f64,
    lit: f64,
    alpha: f64,
};

/// The most pieces of glass an overlay holds.
pub const max_glass = 48;

/// What an overlay's glass is (`viewportOverlayGlass`): two layers of the same pieces, each its own
/// Liquid Glass variant and style, crossfaded by `over_share`. As
/// `fizzy_macos_viewport_overlay_glass` reads it.
pub const GlassLook = extern struct {
    under_variant: c_long = 2,
    under_style: c_long = 1,
    over_variant: c_long = 2,
    over_style: c_long = 1,
    over_share: f64 = 0,
    /// How much of the glass there is, both layers.
    glass: f64 = 1,
    /// The window's colour under the glass (0…1 each), its opacity the last.
    fill: [4]f64 = .{ 0, 0, 0, 0 },
    /// What a lit piece's colour goes toward, and how far (the last).
    lit_toward: [4]f64 = .{ 1, 1, 1, 0 },
    /// Each piece's clearing bevel (`core.glass_look.band`).
    bevel: f64 = 0,
    bevel_cap: f64 = 0,
    bevel_clear: f64 = 0,
};

pub const InitOptions = struct {
    /// Io backend and dvui should use, will be assigned to dvui.io.
    io: std.Io,
    /// Kept for source compatibility with dvui's backend; unused (SDL3 reads the scale itself).
    environ_map: ?*std.process.Environ.Map = null,
    /// The initial size of the application window
    size: dvui.Size,
    /// Set the minimum size of the window
    min_size: ?dvui.Size = null,
    /// Set the maximum size of the window
    max_size: ?dvui.Size = null,
    vsync: bool,
    /// The application title to display
    title: [:0]const u8,
    /// Organization name for SDL preference paths when `pref_path` is null
    /// (`SDL_GetPrefPath(org, title)`). Defaults to `"dvui"`.
    org: [:0]const u8 = "dvui",
    /// content of a PNG image (or any other format stb_image can load)
    /// tip: use @embedFile
    icon: ?[]const u8 = null,
    /// use when running tests
    hidden: bool = false,
    fullscreen: bool = false,
    transparent: bool = false,
    /// Whether SDL should be initialized. Set this to false for secondary os windows
    sdl_init: bool = true,
    /// Automatically restore the window position and size from the previous
    /// run, and save them when the backend deinits (ignored when
    /// `hidden` is set).  Writes `window_geometry.zon` into `pref_path` when
    /// set, otherwise under `SDL_GetPrefPath(org, title)`.
    persist_window_geometry: bool = true,
    /// Optional folder for app preferences, including `window_geometry.zon`
    /// when `persist_window_geometry` is true.  When null, uses
    /// `SDL_GetPrefPath(org, title)`.
    pref_path: ?[:0]const u8 = null,
};

/// Called with a window's creation properties just before it is made, for an app's own
/// `SDL_PROP_WINDOW_CREATE_*` — set before `initWindow`, as the platform's Linux chrome does
/// (`platform.linux_titlebar.useClientDecorations`).
pub var window_create_hook: ?*const fn (props: c.SDL_PropertiesID) void = null;

/// SDL initialization for the all SDL app, i.e. common for all OS Windows
/// This is expected to be called only once.
pub fn initSDL() !void {
    // use the string version instead of the #define so we compile with SDL < 2.24
    _ = c.SDL_SetHint("SDL_HINT_WINDOWS_DPI_SCALING", "1");

    // makes mac scrolling better
    _ = c.SDL_SetHint(c.SDL_HINT_MAC_SCROLL_MOMENTUM, "1");

    // prevents some bad performance in certain wayland compositors (sway) under some conditions
    if (c.SDL_SetHint(c.SDL_HINT_VIDEO_WAYLAND_PREFER_LIBDECOR, "1") != SDL_SUCCESS) {
        log.err("failed to set libdecor hint", .{});
    }

    try toErr(c.SDL_Init(c.SDL_INIT_VIDEO | c.SDL_INIT_EVENTS), "SDL_Init in initWindow");
}

pub fn initWindow(init_options: InitOptions) !SDLBackend {
    try initSDL();
    const new = try createWindowRenderer(init_options, null);

    var back = init(init_options.io, new.win, new.gpu);
    back.init_opts_save = init_options;
    back.window_geometry = new.saved_geometry orelse .{};

    try configureBackend(&back, init_options);

    return back;
}

pub fn initWindowSecondary(parent: *SDLBackend, child_win_opts: dvui.OsWindowWidget.InitOptions) !SDLBackend {
    const parent_opts = parent.init_opts_save orelse {
        log.err("initWindowSecondary expects parent instance with `init_opts_save` field set (typically by `initWindow`)", .{});
        return dvui.Backend.GenericError.BackendError;
    };
    const new_init_opts: SDLBackend.InitOptions = .{
        .io = parent.io,
        .environ_map = parent_opts.environ_map,

        .size = child_win_opts.size orelse parent_opts.size,
        .min_size = child_win_opts.min_size orelse parent_opts.min_size,
        .max_size = child_win_opts.max_size orelse parent_opts.max_size,
        .vsync = parent_opts.vsync,
        .title = child_win_opts.title orelse parent_opts.title,
        .org = parent_opts.org,
        .icon = child_win_opts.icon orelse parent_opts.icon,
        .hidden = child_win_opts.hidden,
        .fullscreen = child_win_opts.fullscreen,
        .transparent = parent_opts.transparent,
        .sdl_init = false,
        // only the primary window persists its geometry
        .persist_window_geometry = false,
    };
    // Secondary windows share the primary's GPU device: textures are per dvui window, but one
    // device can drive any number of claimed windows.
    const new = try createWindowRenderer(new_init_opts, parent.gpu);

    var back = init(dvui.io, new.win, new.gpu);
    back.init_opts_save = new_init_opts;
    back.window_geometry = new.saved_geometry orelse .{};
    back.sdl_quit = false;
    back.log_events = parent.log_events;

    try configureBackend(&back, new_init_opts);

    return back;
}

fn createWindowRenderer(options: InitOptions, share_device_of: ?*GpuRenderer) !struct {
    win: *c.SDL_Window,
    gpu: *GpuRenderer,
    saved_geometry: ?WindowGeometry,
} {
    var hidden = options.hidden;
    if (dvui.accesskit_enabled and !hidden) {
        // hide the window until we can initialize accesskit in Window.begin
        hidden = true;
    }

    const saved_geometry: ?WindowGeometry = WindowGeometry.load(options);

    const hidden_flag = if (hidden) c.SDL_WINDOW_HIDDEN else 0;
    const fullscreen_flag = if (options.fullscreen) c.SDL_WINDOW_FULLSCREEN else 0;
    // SDL_GPU composites a transparent window's alpha with Metal, Vulkan, and D3D12 through
    // DirectComposition (fizzyedit/SDL; see `GpuRenderer.create` for which driver Windows takes).
    const transparent_flag = if (options.transparent) c.SDL_WINDOW_TRANSPARENT else 0;
    const window: *c.SDL_Window = blk: {
        // Window properties let us apply restored geometry at creation time,
        // so the window appears directly at its previous position/size.
        const props = c.SDL_CreateProperties();
        defer c.SDL_DestroyProperties(props);

        const flags: c.SDL_WindowFlags = @intCast(c.SDL_WINDOW_HIGH_PIXEL_DENSITY | c.SDL_WINDOW_RESIZABLE | transparent_flag | hidden_flag | fullscreen_flag);
        var w: c_int = @as(c_int, @trunc(options.size.w));
        var h: c_int = @as(c_int, @trunc(options.size.h));

        if (saved_geometry) |g| {
            w = g.w;
            h = g.h;
            if (g.posOnADisplay()) {
                try toErr(c.SDL_SetNumberProperty(props, c.SDL_PROP_WINDOW_CREATE_X_NUMBER, g.x), "SDL_SetNumberProperty in initWindow");
                try toErr(c.SDL_SetNumberProperty(props, c.SDL_PROP_WINDOW_CREATE_Y_NUMBER, g.y), "SDL_SetNumberProperty in initWindow");
            }
        }

        try toErr(c.SDL_SetStringProperty(props, c.SDL_PROP_WINDOW_CREATE_TITLE_STRING, options.title), "SDL_SetStringProperty in initWindow");
        try toErr(c.SDL_SetNumberProperty(props, c.SDL_PROP_WINDOW_CREATE_WIDTH_NUMBER, w), "SDL_SetNumberProperty in initWindow");
        try toErr(c.SDL_SetNumberProperty(props, c.SDL_PROP_WINDOW_CREATE_HEIGHT_NUMBER, h), "SDL_SetNumberProperty in initWindow");
        try toErr(c.SDL_SetNumberProperty(props, c.SDL_PROP_WINDOW_CREATE_FLAGS_NUMBER, @intCast(flags)), "SDL_SetNumberProperty in initWindow");

        if (window_create_hook) |hook| hook(props);

        break :blk c.SDL_CreateWindowWithProperties(props) orelse return logErr("SDL_CreateWindowWithProperties in initWindow");
    };

    errdefer c.SDL_DestroyWindow(window);

    // get initial content scale
    var scale: f32 = c.SDL_GetDisplayContentScale(c.SDL_GetDisplayForWindow(window));
    if (scale == 0) {
        log.err("SDL_GetDisplayContentScale returned 0", .{});
        scale = 1.0;
    }
    log.info("SDL3 backend scale {d}", .{scale});

    // adjust window size for content scale
    if (scale != 1.0 and saved_geometry == null) {
        if (builtin.abi.isAndroid()) {
            // log.error fails on Android but SDL_Log will show up in LogCat
            c.SDL_Log("[ERROR] Android doesn't support SDL_SetWindowSize");
        } else {
            _ = c.SDL_SetWindowSize(
                window,
                @as(c_int, @trunc(scale * options.size.w)),
                @as(c_int, @trunc(scale * options.size.h)),
            );
        }
    }

    if (options.min_size) |size| {
        if (builtin.abi.isAndroid()) {
            c.SDL_Log("[ERROR] Android doesn't support SDL_SetWindowMinimumSize");
        } else {
            try toErr(c.SDL_SetWindowMinimumSize(
                window,
                @as(c_int, @trunc(scale * size.w)),
                @as(c_int, @trunc(scale * size.h)),
            ), "SDL_SetWindowMinimumSize in initWindow");
        }
    }

    if (options.max_size) |size| {
        if (builtin.abi.isAndroid()) {
            c.SDL_Log("[ERROR] Android doesn't support SDL_SetWindowMaximumSize");
        } else {
            try toErr(c.SDL_SetWindowMaximumSize(
                window,
                @as(c_int, @trunc(scale * size.w)),
                @as(c_int, @trunc(scale * size.h)),
            ), "SDL_SetWindowMaximumSize in initWindow");
        }
    }

    const gpu = GpuRenderer.create(std.heap.c_allocator, window, .{
        .vsync = options.vsync,
        .share_device_of = share_device_of,
    }) catch |err| {
        log.err("GPU renderer init failed: {any}", .{err});
        return dvui.Backend.GenericError.BackendError;
    };
    errdefer gpu.destroy();

    // do fullscreen/maximize after window creation so the original geometry is saved:
    // position window -> fullscreen -> quit -> restart -> unfullscreen should restore original position
    if (!options.hidden) {
        if (saved_geometry) |g| {
            switch (g.state) {
                .normal => {},
                .maximized => {
                    _ = c.SDL_MaximizeWindow(window);
                },
                .fullscreen => {
                    _ = c.SDL_SetHint(c.SDL_HINT_VIDEO_MAC_FULLSCREEN_MENU_VISIBILITY, "1");
                    _ = c.SDL_SetWindowFullscreen(window, true);
                },
            }
        }
    }

    return .{
        .win = window,
        .gpu = gpu,
        .saved_geometry = saved_geometry,
    };
}

/// Window position/size persisted across runs (see `InitOptions.persist_window_geometry`).
/// Stored as `window_geometry.zon` in `InitOptions.pref_path` or, when that is
/// null, under `SDL_GetPrefPath(org, title)`.
/// x/y/w/h are always the normal (windowed) rect — a window that quit while
/// maximized or fullscreen is restored at its last windowed size/position.
pub const WindowGeometry = struct {
    x: c_int = 0,
    y: c_int = 0,
    w: c_int = 100,
    h: c_int = 100,
    state: State = .normal,

    const State = enum { normal, maximized, fullscreen };

    const Saved = struct {
        x: i32,
        y: i32,
        w: i32,
        h: i32,
        state: State = .normal,
    };

    const zon_file_name = "window_geometry.zon";

    fn filePath(buf: []u8, options: InitOptions) ?[:0]const u8 {
        if (options.pref_path) |dir| {
            if (std.mem.endsWith(u8, dir, std.fs.path.sep_str)) {
                return std.fmt.bufPrintZ(buf, "{s}{s}", .{ dir, zon_file_name }) catch null;
            }
            return std.fmt.bufPrintZ(buf, "{s}{c}{s}", .{ dir, std.fs.path.sep, zon_file_name }) catch null;
        }
        const pref = c.SDL_GetPrefPath(options.org.ptr, options.title.ptr) orelse {
            logErr("SDL_GetPrefPath in WindowGeometry") catch {};
            return null;
        };
        defer c.SDL_free(pref);
        return std.fmt.bufPrintZ(buf, "{s}" ++ zon_file_name, .{std.mem.span(@as([*:0]const u8, @ptrCast(pref)))}) catch null;
    }

    fn fromSaved(saved: Saved) ?WindowGeometry {
        if (saved.w < 1 or saved.h < 1) return null;
        return .{
            .x = std.math.cast(c_int, saved.x) orelse return null,
            .y = std.math.cast(c_int, saved.y) orelse return null,
            .w = std.math.cast(c_int, saved.w) orelse return null,
            .h = std.math.cast(c_int, saved.h) orelse return null,
            .state = saved.state,
        };
    }

    fn toSaved(self: WindowGeometry) Saved {
        return .{
            .x = @intCast(self.x),
            .y = @intCast(self.y),
            .w = @intCast(self.w),
            .h = @intCast(self.h),
            .state = self.state,
        };
    }

    pub fn load(options: InitOptions) ?WindowGeometry {
        if (!options.persist_window_geometry) return null;
        var path_buf: [1024]u8 = undefined;
        const path = filePath(&path_buf, options) orelse return null;
        return loadZon(options.io, path);
    }

    fn loadZon(io: std.Io, path: [:0]const u8) ?WindowGeometry {
        const data = std.Io.Dir.cwd().readFileAlloc(io, path, std.heap.page_allocator, .limited(4096)) catch return null;
        defer std.heap.page_allocator.free(data);
        var nul_buf: [4097]u8 = undefined;
        if (data.len >= nul_buf.len) return null;
        @memcpy(nul_buf[0..data.len], data);
        nul_buf[data.len] = 0;
        const saved = std.zon.parse.fromSlice(
            Saved,
            std.heap.page_allocator,
            nul_buf[0..data.len :0],
            null,
            .{ .ignore_unknown_fields = true },
        ) catch return null;
        return fromSaved(saved);
    }

    fn writeFile(io: std.Io, path: [:0]const u8, g: WindowGeometry) void {
        var aw = std.Io.Writer.Allocating.init(std.heap.page_allocator);
        defer aw.deinit();
        std.zon.stringify.serialize(g.toSaved(), .{}, &aw.writer) catch return;
        const parent = std.fs.path.dirname(path) orelse return;
        std.Io.Dir.createDirAbsolute(io, parent, .default_dir) catch {};
        std.Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = aw.written() }) catch {
            log.err("failed to write window_geometry.zon", .{});
        };
    }

    fn save(back: *SDLBackend) void {
        const opts = back.init_opts_save orelse return;
        var path_buf: [1024]u8 = undefined;
        const path = filePath(&path_buf, opts) orelse return;
        WindowGeometry.writeFile(opts.io, path, back.window_geometry);
    }

    /// True if the window's title bar area would land on a connected display.
    /// Guards against restoring onto a monitor that is no longer attached.
    fn posOnADisplay(self: WindowGeometry) bool {
        var count: c_int = 0;
        const displays = c.SDL_GetDisplays(&count) orelse return false;
        defer c.SDL_free(displays);
        const cx = self.x + @divTrunc(self.w, 2);
        const cy = self.y + 10;
        for (displays[0..@intCast(count)]) |id| {
            var bounds: c.SDL_Rect = undefined;
            if (!c.SDL_GetDisplayUsableBounds(id, &bounds)) continue;
            if (cx >= bounds.x and cx < bounds.x + bounds.w and cy >= bounds.y and cy < bounds.y + bounds.h) return true;
        }
        return false;
    }
};

// Common configuration part for both `initWindow` and `initWindowSecondary`
fn configureBackend(back: *SDLBackend, options: InitOptions) !void {
    var hidden = options.hidden;
    var show_window_in_begin = false;
    if (dvui.accesskit_enabled and !hidden) {
        // hide the window until we can initialize accesskit in Window.begin
        hidden = true;
        show_window_in_begin = true;
    }
    back.ak_should_initialized = show_window_in_begin;
    back.we_own_window = true;
    back.clear_window_on_begin = true;

    if (options.icon) |bytes| {
        if (builtin.abi.isAndroid()) {
            // log.error fails on Android but SDL_Log will show up in LogCat
            c.SDL_Log("[ERROR] Android doesn't support setting a custom icon at runtime");
        } else {
            try back.setIconFromFileContent(bytes);
        }
    }
}

pub fn init(io: std.Io, window: *c.SDL_Window, gpu: *GpuRenderer) SDLBackend {
    dvui.io = io;
    if (builtin.os.tag == .macos) {
        fizzy_native_monitor_install();
        if (cocoaWindow(window)) |nswindow| {
            fizzy_native_disable_titlebar_separator(nswindow);
        }
    }
    return SDLBackend{ .io = io, .window = window, .gpu = gpu };
}

extern "c" fn fizzy_native_monitor_install() void;
extern "c" fn fizzy_native_monitor_last_scroll_precise() c_int;
extern "c" fn fizzy_native_disable_titlebar_separator(nswindow: *anyopaque) void;
extern "c" fn fizzy_native_metal_drawable_size(nswindow: *anyopaque, out_w: *c_int, out_h: *c_int) c_int;
extern "c" fn fizzy_native_in_live_resize(nswindow: *anyopaque) c_int;
extern "c" fn fizzy_native_transaction_begin() void;
extern "c" fn fizzy_native_transaction_commit() void;
extern "c" fn fizzy_native_viewport_set_frame(nswindow: ?*anyopaque, x: f64, y: f64, w: f64, h: f64) void;
extern "c" fn fizzy_native_viewport_transact(nswindow: ?*anyopaque) void;
extern "c" fn fizzy_native_viewport_presented(nswindow: ?*anyopaque) void;
extern "c" fn fizzy_native_live_resize_next_frame(nswindow: *anyopaque, wait_s: f64, since_start_s: f64) void;

fn cocoaWindow(window: *c.SDL_Window) ?*anyopaque {
    if (builtin.os.tag != .macos) return null;
    return c.SDL_GetPointerProperty(c.SDL_GetWindowProperties(window), c.SDL_PROP_WINDOW_COCOA_WINDOW_POINTER, null);
}

/// Whether AppKit's live-resize tracking loop is running for this window, which a frame is then
/// run from inside (`appIterate`).
fn inLiveResize(self: *SDLBackend) bool {
    if (builtin.os.tag == .macos) {
        if (cocoaWindow(self.window)) |nswindow| return fizzy_native_in_live_resize(nswindow) != 0;
    }
    // A popped-out float's window in the OS's move/size loop: SDL runs the frame from the loop's
    // timer, where a wait for events would take the loop's own.
    if (builtin.os.tag == .windows) {
        for (self.viewports) |v| if (v) |vp| if (vp.win32_loop.moving) return true;
    }
    return false;
}

/// Inside a live resize `appIterate` waits for nothing, and a frame comes only when AppKit
/// displays the window: ask it for the next one when dvui wants it (`wait_micros`, from
/// `waitTime`), so an animation keeps the display's rate while no resize step is drawing it
/// (`fizzy_native_live_resize_next_frame` in `macos_monitor.m`).
fn liveResizeNextFrame(self: *SDLBackend, win: *const dvui.Window, wait_micros: u32) void {
    if (comptime builtin.os.tag != .macos) return;
    const nswindow = cocoaWindow(self.window) orelse return;
    const wait_s: f64 = if (wait_micros == std.math.maxInt(u32)) -1 else @as(f64, @floatFromInt(wait_micros)) / std.time.us_per_s;
    const since_start_ns = @max(0, self.nanoTime() - win.frame_time_ns);
    fizzy_native_live_resize_next_frame(nswindow, wait_s, @as(f64, @floatFromInt(since_start_ns)) / std.time.ns_per_s);
}

const SDL_ERROR = bool;
const SDL_SUCCESS: SDL_ERROR = true;
inline fn toErr(res: SDL_ERROR, what: []const u8) !void {
    if (res == SDL_SUCCESS) return;
    return logErr(what);
}

inline fn logErr(what: []const u8) dvui.Backend.GenericError {
    log.err("{s} failed, error={s}", .{ what, c.SDL_GetError() });
    return dvui.Backend.GenericError.BackendError;
}

pub fn setIconFromFileContent(self: *SDLBackend, file_content: []const u8) !void {
    var icon_w: c_int = undefined;
    var icon_h: c_int = undefined;
    var channels_in_file: c_int = undefined;
    const data = dvui.c.stbi_load_from_memory(file_content.ptr, @as(c_int, @intCast(file_content.len)), &icon_w, &icon_h, &channels_in_file, 4);
    if (data == null) {
        log.warn("when setting icon, stbi_load error: {s}", .{dvui.c.stbi_failure_reason()});
        return dvui.StbImageError.stbImageError;
    }
    defer dvui.c.stbi_image_free(data);
    try self.setIconFromABGR8888(data, icon_w, icon_h);
}

pub fn setIconFromABGR8888(self: *SDLBackend, data: [*]const u8, icon_w: c_int, icon_h: c_int) !void {
    const surface = c.SDL_CreateSurfaceFrom(
        icon_w,
        icon_h,
        c.SDL_PIXELFORMAT_ABGR8888,
        @ptrCast(@constCast(data)),
        4 * icon_w,
    ) orelse return logErr("SDL_CreateSurfaceFrom in setIconFromABGR8888");
    defer c.SDL_DestroySurface(surface);

    // `toErr` logs the error for us
    toErr(c.SDL_SetWindowIcon(self.window, surface), "SDL_SetWindowIcon in setIconFromABGR8888") catch {};
}

pub fn accessKitShouldInitialize(self: *SDLBackend) bool {
    return self.ak_should_initialized;
}
pub fn accessKitInitInBegin(self: *SDLBackend) !void {
    std.debug.assert(self.ak_should_initialized);
    try toErr(c.SDL_ShowWindow(self.window), "SDL_ShowWindow in accessKitInitInBegin");
    self.ak_should_initialized = false;
}

/// Return true if interrupted by event
pub fn waitEventTimeout(_: *SDLBackend, timeout_micros: u32) !bool {
    if (timeout_micros == std.math.maxInt(u32)) {
        // wait no timeout
        _ = c.SDL_WaitEvent(null);
        return false;
    }

    if (timeout_micros > 0) {
        // wait with a timeout
        const timeout = @min((timeout_micros + 999) / 1000, std.math.maxInt(c_int));
        const ret = c.SDL_WaitEventTimeout(null, @as(c_int, @intCast(timeout)));

        // TODO: this call to SDL_PollEvent can be removed after resolution of
        // https://github.com/libsdl-org/SDL/issues/6539
        // maintaining this a little longer for people with older SDL versions
        _ = c.SDL_PollEvent(null);

        return ret;
    }

    // don't wait at all
    return false;
}

pub fn cursorShow(_: *SDLBackend, value: ?bool) bool {
    const prev = c.SDL_CursorVisible();
    if (value) |val| {
        if (val) {
            if (!c.SDL_ShowCursor()) {
                logErr("SDL_ShowCursor in cursorShow") catch return false;
            }
        } else {
            if (!c.SDL_HideCursor()) {
                logErr("SDL_HideCursor in cursorShow") catch return false;
            }
        }
    }
    return prev;
}

pub fn native(self: *SDLBackend, _: *dvui.Window) dvui.Window.Native {
    const props = c.SDL_GetWindowProperties(self.window);
    switch (builtin.os.tag) {
        .windows => return .{ .hwnd = c.SDL_GetPointerProperty(props, c.SDL_PROP_WINDOW_WIN32_HWND_POINTER, null) },
        .macos => return .{ .cocoa_window = c.SDL_GetPointerProperty(props, c.SDL_PROP_WINDOW_COCOA_WINDOW_POINTER, null) },
        else => return {},
    }
}

pub fn title(self: *SDLBackend, _: *dvui.Window, new_title: []const u8) void {
    var buf: [300]u8 = @splat(0);
    const c_text: []const u8 = std.fmt.bufPrintSentinel(&buf, "{s}", .{new_title}, 0) catch "title: Error";
    _ = c.SDL_SetWindowTitle(self.window, c_text.ptr);
}

pub fn windowStateSet(self: *SDLBackend, _: *dvui.Window, state: dvui.enums.WindowState) void {
    switch (state) {
        .fullscreen => {
            _ = c.SDL_SetHint(c.SDL_HINT_VIDEO_MAC_FULLSCREEN_MENU_VISIBILITY, "1");
            _ = c.SDL_SetWindowFullscreen(self.window, true);
        },
        .maximize => {
            _ = c.SDL_SetWindowFullscreen(self.window, false);
            _ = c.SDL_MaximizeWindow(self.window);
        },
        .normal => {
            _ = c.SDL_SetWindowFullscreen(self.window, false);
            _ = c.SDL_RestoreWindow(self.window);
        },
    }
}

/// Safe from any thread: pushes an `SDL_EVENT_USER`, which wakes `waitEventTimeout`.
pub fn refresh(_: *SDLBackend) void {
    var ue = std.mem.zeroes(c.SDL_Event);
    ue.type = c.SDL_EVENT_USER;
    toErr(c.SDL_PushEvent(&ue), "SDL_PushEvent in refresh") catch {};
}

/// The main window shown, restored, or first focused — the app activating at launch — over the
/// floats' windows: they are put over it once, before the frame presents (`Viewport.over_main`).
/// Not when it is pressed, or focused again: a float's window stacks as any window does (the user),
/// and one put back over the main window at every press on it left the part under it unworkable.
/// From either way events arrive: polled (`addAllEvents`) or through SDL's callbacks (`appEvent`),
/// which is how fizzy runs on macOS.
fn noteMainForward(self: *SDLBackend, target: ?*c.SDL_Window, event_type: u32) void {
    if (target == null or target != self.window) return;
    const over = switch (event_type) {
        c.SDL_EVENT_WINDOW_SHOWN, c.SDL_EVENT_WINDOW_RESTORED => true,
        c.SDL_EVENT_WINDOW_FOCUS_GAINED => !self.main_focused_once,
        else => false,
    };
    if (event_type == c.SDL_EVENT_WINDOW_FOCUS_GAINED) self.main_focused_once = true;
    if (!over) return;
    for (&self.viewports) |*slot| if (slot.*) |*v| {
        v.over_main = true;
    };
}

pub fn addAllEvents(self: *SDLBackend, win: *dvui.Window) !void {
    var event: c.SDL_Event = undefined;
    while (c.SDL_PollEvent(&event)) {
        const target_sdl_window = getWindowFromEvent(&event);
        self.noteMainForward(target_sdl_window, event.type);
        if (target_sdl_window) |target_win| {
            _ = try self.addEventWinRecursive(&event, win, target_win);
        } else {
            // "global" event are managed by "primary" window
            _ = try self.addEvent(win, event);
        }
    }
}

/// Recursively Iterate `child_os_wins` and try to deliver the event.
///
/// Note that contrary to `addEvent`, this function return true if the event is sent based on the
///  SDL_Window handle (i.e. OS Window dispatch) and doesn't care about subwindows.
fn addEventWinRecursive(self: *SDLBackend, event: *c.SDL_Event, win: *dvui.Window, target_win: *c.SDL_Window) !bool {
    // A held pointer, with a viewport open, goes where it is — whichever of fizzy's windows took
    // the press (`heldPoint`).
    if ((self.window == target_win or self.viewportOf(target_win) != null) and self.heldAcrossWindows(event.*)) {
        const pt = self.heldPoint();
        if (event.type == c.SDL_EVENT_MOUSE_MOTION) return try win.addEventMouseMotion(.{ .pt = pt });
        if (pt.x != win.mouse_pt.x or pt.y != win.mouse_pt.y) _ = try win.addEventMouseMotion(.{ .pt = pt });
        _ = try self.addEvent(win, event.*);
        return true;
    }
    if (self.window == target_win) {
        _ = try self.addEvent(win, event.*);
        return true;
    }
    // A viewport's window feeds the same dvui window as this one (fizzy's own).
    if (self.viewportOf(target_win)) |vp| {
        _ = try self.addViewportEvent(win, vp, event.*);
        return true;
    }
    var child_win_it = win.child_os_wins.iterator();
    // Use next_peek because the fact we had events since last frame
    // doesn't mean the child Os Window will still be used in the upcoming frame, we don't know that yet.
    while (child_win_it.next_peek()) |alive_win| {
        if (try addEventWinRecursive(
            alive_win.value.backend,
            event,
            alive_win.value.dvui_win,
            target_win,
        )) return true;
    }
    return false;
}

// ---------------------------------------------------------------------------------------------
// Viewports (fizzy's own; see `Viewport`)

/// Open a viewport over `at` — physical pixels of the frame as the main window shows it — so its
/// window opens on the desktop exactly over that part of the main window: the place a float
/// popped out of was. Its own part of the frame is `at` moved into its band (`Viewport.frame`).
/// Hidden until a frame is presented into it. Null when it cannot be made, or `max_viewports`
/// are open.
pub fn viewportOpen(self: *SDLBackend, at: viewport_map.Rect, title_text: [:0]const u8) ?*Viewport {
    return self.openViewport(at, title_text, .window);
}

const ViewportKind = enum { window, carry, overlay, menu };

/// A menu in a window of its own (`Popout`'s menus): borderless, kept above every window by its
/// level, in no window list, never made key — the window it opened from keeps the keyboard, and
/// its first click acts. Placed in the main window's frame (`viewportPlaceMain`), the pointer over it
/// read there (`viewportMainOffset`). Its material is the OS's (`viewportLiquidGlass`, vibrancy
/// before macOS 26). macOS.
/// `radius`, points: the menu's corners, which vibrancy is masked to (Liquid Glass takes them from
/// its look each frame). `ride`: the window it moves with (`Viewport.ride`) — none for a menu opened
/// in a float that is out. `dialog`: a dialog's window (`Viewport.dialog`).
pub fn viewportOpenMenu(self: *SDLBackend, at: viewport_map.Rect, radius: f32, ride: Ride, dialog: bool) ?*Viewport {
    if (comptime builtin.os.tag != .macos) return null;
    const vp = self.openViewport(at, "", .menu) orelse return null;
    _ = fizzy_macos_viewport_menu(cocoaWindow(vp.window), cocoaWindow(self.window), platform.window.ns_visual_effect_material, radius, @intFromBool(dialog));
    vp.ride = switch (ride) {
        .none => null,
        .main => self.window,
        .viewport => |parent| parent.window,
    };
    vp.dialog = dialog;
    return vp;
}

/// `vp`'s window just above `other`'s, where it is not already (macOS).
pub fn viewportOrderAbove(_: *SDLBackend, vp: *Viewport, other: *Viewport) void {
    if (comptime builtin.os.tag != .macos) return;
    fizzy_macos_viewport_order_above(cocoaWindow(vp.window), cocoaWindow(other.window));
}

/// `vp`'s window at `other`'s level, just above it (macOS).
pub fn viewportLift(_: *SDLBackend, vp: *Viewport, other: *Viewport) void {
    if (comptime builtin.os.tag != .macos) return;
    fizzy_macos_viewport_lift(cocoaWindow(vp.window), cocoaWindow(other.window));
}

/// `vp`'s window back at a window's own level, after `viewportLift` (macOS).
pub fn viewportSettle(_: *SDLBackend, vp: *Viewport) void {
    if (comptime builtin.os.tag != .macos) return;
    fizzy_macos_viewport_settle(cocoaWindow(vp.window));
}

/// The window a menu's or dialog's window moves with (`viewportOpenMenu`).
pub const Ride = union(enum) {
    none,
    main,
    viewport: *Viewport,
};

/// Whether one of the app's windows has the keyboard: the app is the active one.
pub fn appActive() bool {
    return c.SDL_GetKeyboardFocus() != null;
}

/// Where menu `vp` is drawn in the frame from where its window lies over the main window, physical
/// pixels (`Viewport.main_offset`).
pub fn viewportMainOffset(_: *SDLBackend, vp: *Viewport, offset: viewport_map.Point) void {
    vp.main_offset = offset;
}

/// A window that carries a view past every window of the app's, over the desktop (`Popout`'s carry
/// window): borderless and clear, the pointer passing through it to what is under, kept above every
/// window, in no window list, never focused. macOS. Placed and drawn as any viewport.
pub fn viewportOpenCarry(self: *SDLBackend, at: viewport_map.Rect) ?*Viewport {
    if (comptime builtin.os.tag != .macos) return null;
    return self.openViewport(at, "", .carry);
}

/// A window over a whole display that holds the OS's glass (`viewportOverlayGlass`) — Liquid Glass,
/// its pieces run together where they come close — under the picture drawn into it: a carry window
/// grown to its display, clear but for its glass, the pointer passing through it. macOS 26, where
/// `liquidGlassAvailable`.
pub fn viewportOpenOverlay(self: *SDLBackend, at: viewport_map.Rect) ?*Viewport {
    if (comptime builtin.os.tag != .macos) return null;
    if (!liquidGlassAvailable()) return null;
    return self.openViewport(at, "", .overlay);
}

/// Whether the OS has Liquid Glass to draw (`viewportOpenOverlay`): macOS 26.
pub fn liquidGlassAvailable() bool {
    if (comptime builtin.os.tag != .macos) return false;
    return fizzy_macos_liquid_glass_available() != 0;
}

/// The OS's glass in overlay `vp` (`viewportOpenOverlay`) this frame, applied with its picture: each
/// a rounded rect, points from the window's top left, run together within `spacing` points, as
/// `look`.
pub fn viewportOverlayGlass(_: *SDLBackend, vp: *Viewport, shapes: []const GlassShape, spacing: f32, look: GlassLook) void {
    const n = @min(shapes.len, max_glass);
    // Where the glass merges, its necks swing at the least change of the gap between two pieces —
    // a carried drop's spring settling, a hand's tremor through a held press — and the OS
    // re-forms the merge each time it is handed a change, so a piece still under a pointer held
    // still shimmered at its joins. A piece's place and size go to the OS only once they have
    // moved half a point from what it was last handed; motion that means anything moves more.
    var next: [max_glass]GlassShape = undefined;
    @memcpy(next[0..n], shapes[0..n]);
    if (n == vp.glass_n) for (next[0..n], vp.glass[0..n]) |*to, was| {
        inline for (.{ "x", "y", "w", "h", "radius" }) |f| {
            if (@abs(@field(to.*, f) - @field(was, f)) < glass_still) @field(to.*, f) = @field(was, f);
        }
    };
    if (n == vp.glass_n and spacing == vp.glass_spacing and std.meta.eql(look, vp.glass_look) and
        std.mem.eql(u8, std.mem.sliceAsBytes(vp.glass[0..n]), std.mem.sliceAsBytes(next[0..n]))) return;
    @memcpy(vp.glass[0..n], next[0..n]);
    vp.glass_n = n;
    vp.glass_spacing = spacing;
    vp.glass_look = look;
    vp.glass_dirty = true;
}

/// Points a piece of an overlay's glass moves or grows before the OS is handed it
/// (`viewportOverlayGlass`).
const glass_still: f64 = 0.5;

/// The display the main window is on, in the main window's frame (physical pixels from its top
/// left): what an overlay covers.
pub fn viewportDisplayInMain(self: *SDLBackend) viewport_map.Rect {
    const display = c.SDL_GetDisplayForWindow(self.window);
    var r: c.SDL_Rect = .{};
    if (display == 0 or !c.SDL_GetDisplayBounds(display, &r)) return .{};
    const at = self.mainOnScreen();
    const d = self.density();
    return .{
        .x = (@as(f32, @floatFromInt(r.x)) - at.x) * d,
        .y = (@as(f32, @floatFromInt(r.y)) - at.y) * d,
        .w = @as(f32, @floatFromInt(r.w)) * d,
        .h = @as(f32, @floatFromInt(r.h)) * d,
    };
}

fn openViewport(self: *SDLBackend, at: viewport_map.Rect, title_text: [:0]const u8, role: ViewportKind) ?*Viewport {
    const carry = role != .window;
    const menu = role == .menu;
    if (!viewportsAvailable()) return null;
    const slot = for (self.viewports, 0..) |v, i| {
        if (v == null) break i;
    } else return null;
    const b = viewport_map.band(slot);
    const anchor = self.mainOnScreen();
    const d = self.density();
    const placed = viewport_map.place(b, anchor, d, .{ .x = b.x + at.x, .y = b.y + at.y, .w = at.w, .h = at.h });

    // The first click on a viewport acts, as one on the main window's floats does, rather than
    // only bringing the window forward. SDL's hint is every window's: the main window's first
    // click acts too while a viewport is open (`viewportClose` puts it back).
    _ = c.SDL_SetHint(c.SDL_HINT_MOUSE_FOCUS_CLICKTHROUGH, "1");

    const props = c.SDL_CreateProperties();
    defer c.SDL_DestroyProperties(props);
    // Resizable, for the OS to resize it from its edges and snap or tile it — which only a window
    // it may resize takes part in (`viewportHitTest`).
    // macOS: titled, as the main window is — the OS's traffic lights, shadow, corners and resizing
    // from every edge, its title bar made transparent over the float's own header
    // (`fizzy_macos_viewport_glass`). Elsewhere borderless, framed by the OS (Windows: DWM) or by
    // the float (X11).
    // A carry window is neither: borderless, and not resizable — the app puts it where the view is.
    // A menu's window is a carry window that takes the pointer, never focused: the window it opened
    // from keeps the keyboard, as an OS menu leaves it.
    const frame_flag: c.SDL_WindowFlags = if (builtin.os.tag == .macos and !carry) 0 else c.SDL_WINDOW_BORDERLESS;
    const size_flag: c.SDL_WindowFlags = if (carry) 0 else c.SDL_WINDOW_RESIZABLE;
    const focus_flag: c.SDL_WindowFlags = if (menu) c.SDL_WINDOW_NOT_FOCUSABLE else 0;
    const flags: c.SDL_WindowFlags = c.SDL_WINDOW_HIDDEN | frame_flag | c.SDL_WINDOW_TRANSPARENT | c.SDL_WINDOW_HIGH_PIXEL_DENSITY | size_flag | focus_flag;
    _ = c.SDL_SetStringProperty(props, c.SDL_PROP_WINDOW_CREATE_TITLE_STRING, title_text.ptr);
    _ = c.SDL_SetNumberProperty(props, c.SDL_PROP_WINDOW_CREATE_X_NUMBER, placed.screen.x);
    _ = c.SDL_SetNumberProperty(props, c.SDL_PROP_WINDOW_CREATE_Y_NUMBER, placed.screen.y);
    _ = c.SDL_SetNumberProperty(props, c.SDL_PROP_WINDOW_CREATE_WIDTH_NUMBER, placed.screen.w);
    _ = c.SDL_SetNumberProperty(props, c.SDL_PROP_WINDOW_CREATE_HEIGHT_NUMBER, placed.screen.h);
    _ = c.SDL_SetNumberProperty(props, c.SDL_PROP_WINDOW_CREATE_FLAGS_NUMBER, @intCast(flags));
    const window = c.SDL_CreateWindowWithProperties(props) orelse {
        logErr("SDL_CreateWindowWithProperties (viewport)") catch {};
        return null;
    };
    self.gpu.claimViewport(window) catch {
        c.SDL_DestroyWindow(window);
        return null;
    };
    // Kept over the main window, and hidden and minimized with it: owned by it, on Windows (and
    // transient for it on X11). Without it, a press on the main window — or one the OS took as
    // its own while the viewport was being resized — put the main window over it. Not on macOS,
    // where SDL makes it a child window that moves with its parent, and the windows that left
    // the main one stay where they are when it moves (`docs/POPOUT_WINDOWS_PLAN.md`, decision 2).
    if (comptime builtin.os.tag != .macos) _ = c.SDL_SetWindowParent(window, self.window);
    self.viewports[slot] = .{ .window = window, .band = b, .anchor = anchor, .density = d, .screen = placed.screen, .frame = placed.frame, .passive = carry and !menu, .overlay = role == .overlay, .menu = menu };
    const vp = &self.viewports[slot].?;
    // Dressed by `viewportOpenMenu`, and no hit test: nothing in it moves or resizes it.
    if (menu) return vp;
    if (role == .overlay) {
        if (comptime builtin.os.tag == .macos) fizzy_macos_viewport_overlay(cocoaWindow(window), cocoaWindow(self.window));
        return vp;
    }
    if (carry) {
        if (comptime builtin.os.tag == .macos) fizzy_macos_viewport_carry(cocoaWindow(window), cocoaWindow(self.window), platform.window.ns_visual_effect_material);
        return vp;
    }
    // The slot holds it for the window's life, so SDL may keep the pointer.
    _ = c.SDL_SetWindowHitTest(window, viewportHitTest, vp);
    return vp;
}

/// A carry window's shape this frame: what it carries, filling it, rounded by `radius` physical
/// pixels — its material masked so, and the OS's shadow round it — `alpha` opaque, with its picture
/// (`renderPresent`). Null: hidden, material and shadow and all.
pub fn viewportCarryShape(_: *SDLBackend, vp: *Viewport, radius: ?f32, alpha: f32) void {
    vp.carry_radius = if (radius) |r| @round(r / vp.density) else -1;
    vp.carry_alpha = std.math.clamp(alpha, 0, 1);
}

/// A carry window's Liquid Glass as the lens (the carried view) or as frost (a float's window growing
/// out of it, as its own material is). macOS 26; nothing elsewhere.
pub fn viewportCarryLens(_: *SDLBackend, vp: *Viewport, lens: bool) void {
    if (comptime builtin.os.tag != .macos) return;
    fizzy_macos_viewport_carry_lens(cocoaWindow(vp.window), @intFromBool(lens));
}

/// Points from `vp`'s window's left edge past the OS's own buttons in its title bar: the traffic
/// lights of a titled macOS window, with the margin before them. 0 elsewhere.
pub fn viewportButtonsWidth(_: *SDLBackend, vp: *Viewport) f32 {
    if (comptime builtin.os.tag != .macos) return 0;
    if (vp.passive) return 0;
    return @floatCast(fizzy_macos_window_buttons_width(cocoaWindow(vp.window)));
}

/// The corner radius of a titled window, points: what a float's window is rounded by
/// (`viewportCarryShape` grows the carried glass into it).
pub fn windowCornerRadius(_: *SDLBackend) f32 {
    if (comptime builtin.os.tag != .macos) return 0;
    return @floatCast(fizzy_macos_window_corner_radius());
}

/// Whether `vp`'s window is maximized — zoomed, or in a fullscreen Space of its own — as the main
/// window's is asked (`platform.window.windowMaximized`).
pub fn viewportMaximized(_: *SDLBackend, vp: *const Viewport) bool {
    return platform.window.windowMaximized(vp.window);
}

/// Whether `vp`'s window covers the desktop, or will once the transition it is in ends, as the main
/// window's is asked (`platform.window.windowCovers`).
pub fn viewportCovers(_: *SDLBackend, vp: *const Viewport) bool {
    return platform.window.windowCovers(vp.window);
}

/// Whether `vp`'s window is on its way into a fullscreen Space (`platform.window.windowEnteringSpace`).
pub fn viewportEnteringSpace(_: *SDLBackend, vp: *const Viewport) bool {
    return platform.window.windowEnteringSpace(vp.window);
}

/// A held pointer over `vp`'s window is read as over the main window beneath it while `on`
/// (`heldPoint`): its float gone to its ghost, a view carried out of it aimed at the places under it.
pub fn viewportSeeThrough(_: *SDLBackend, vp: *Viewport, on: bool) void {
    vp.see_through = on;
}

/// `vp`'s window `alpha` opaque, all of it — its material too.
pub fn viewportFade(_: *SDLBackend, vp: *Viewport, alpha: f32) void {
    const a = std.math.clamp(alpha, 0, 1);
    if (a == vp.alpha) return;
    vp.alpha = a;
    _ = c.SDL_SetWindowOpacity(vp.window, a);
}

/// Whether this run can open viewports at all: not on Wayland, where a client cannot put its
/// windows anywhere — a window split out of the main one would open where the compositor likes, and
/// none could follow a drag (`docs/POPOUT_WINDOWS_PLAN.md`). Floats stay in the main window there.
pub fn viewportsAvailable() bool {
    if (comptime builtin.os.tag != .linux) return true;
    const driver = c.SDL_GetCurrentVideoDriver() orelse return false;
    return !std.mem.eql(u8, std.mem.span(driver), "wayland");
}

/// Close a viewport: its window goes, and the slot (and band) with it.
pub fn viewportClose(self: *SDLBackend, vp: *Viewport) void {
    // A pin to it goes with it: it would point at an empty slot.
    switch (self.pointer_pin) {
        .viewport => |p| if (p == vp) {
            self.pointer_pin = .none;
        },
        else => {},
    }
    // What rides on it lets go first (`Viewport.ride`): SDL destroys a window's children with it,
    // and the slot of each still holds its window. The app moves a dialog left behind back over
    // the main window (`Popout`).
    for (&self.viewports) |*slot| {
        if (slot.*) |*other| if (other != vp and other.ride != null and other.ride == vp.window) {
            _ = c.SDL_SetWindowParent(other.window, null);
            other.ride = null;
        };
    }
    for (&self.viewports) |*slot| {
        if (slot.*) |*v| if (v == vp) {
            // Holding the keyboard as it goes — a float that merged back into the main window, or
            // came back on a command, while its window was the one in front — it hands it back to
            // the main window, which the float is in now: without that, the OS left no window of
            // fizzy's focused, and the first press on the main window only brought it forward.
            const had_keyboard = c.SDL_GetWindowFlags(v.window) & c.SDL_WINDOW_INPUT_FOCUS != 0;
            defer if (had_keyboard) {
                _ = c.SDL_RaiseWindow(self.window);
            };
            // The window as SDL made it, for SDL to destroy (`viewportGlass`).
            if (comptime builtin.os.tag == .macos) {
                platform.macos_monitor.unwatch(v.window);
                if (c.SDL_GetPointerProperty(c.SDL_GetWindowProperties(v.window), c.SDL_PROP_WINDOW_COCOA_WINDOW_POINTER, null)) |ns| fizzy_macos_viewport_unglass(ns);
            }
            self.gpu.releaseViewport(v.window);
            c.SDL_DestroyWindow(v.window);
            slot.* = null;
            break;
        };
    }
    for (self.viewports) |v| if (v != null) return;
    _ = c.SDL_ResetHint(c.SDL_HINT_MOUSE_FOCUS_CLICKTHROUGH);
}

/// Move and size `vp`'s window to `to` (whole points), from where it was put last (`was`). On macOS
/// it is put there with this frame's picture of it, in one transaction (`renderPresent`); elsewhere
/// at once, through SDL.
fn placeWindow(vp: *Viewport, to: viewport_map.ScreenRect, was: viewport_map.ScreenRect) void {
    if (std.meta.eql(to, was)) return;
    vp.app_placed_ns = c.SDL_GetTicksNS();
    if (comptime builtin.os.tag == .macos) {
        vp.frame_pending = true;
        return;
    }
    if (to.x != was.x or to.y != was.y) _ = c.SDL_SetWindowPosition(vp.window, to.x, to.y);
    if (to.w != was.w or to.h != was.h) _ = c.SDL_SetWindowSize(vp.window, to.w, to.h);
}

/// Put `vp`'s window where it shows `frame` (physical pixels, in its band), on whole points;
/// returns the part of the frame it then shows (`viewport_map.place`).
pub fn viewportPlace(_: *SDLBackend, vp: *Viewport, frame: viewport_map.Rect) viewport_map.Rect {
    // In a fullscreen Space, or on its way into or out of one, its frame is AppKit's: the float
    // follows the window (`viewportFollowWindow`), never the other way. A window put somewhere in
    // a Space is taken out of it.
    if (comptime builtin.os.tag == .macos) {
        if (platform.macos_monitor.osOwnsFrame(vp.window)) return vp.frame;
    }
    const placed = viewport_map.place(vp.band, vp.anchor, vp.density, frame);
    const was = vp.screen;
    // Through SDL, as two calls: a window dragged by its left or top edge shows moved and not
    // yet sized for a moment, its far edge jumping. Moving it in one `SetWindowPos` behind SDL's
    // back was tried and is worse — SDL never learns the window's new size, so its swapchain stays
    // the old one (the picture cropped in a window grown round it) and its idea of the size goes
    // stale. The real fix is the OS doing the resizing (Phase 4: hit-testing the window's edges as
    // the main window's chrome does), not the app moving the window under it.
    placeWindow(vp, placed.screen, was);
    vp.screen = placed.screen;
    vp.frame = placed.frame;
    return placed.frame;
}

/// Where a held pointer is read, while one is held (`heldPoint`): by the window it is over (a view
/// carried between windows), or pinned to one frame of reference for a window being moved or
/// resized — the main window's, for a float split out of it under the drag, or a viewport's band,
/// for a float out of it — so the drag's coordinates never change under it, wherever the pointer
/// goes.
pub const PointerPin = union(enum) {
    none,
    main,
    viewport: *Viewport,
};

/// Put `vp`'s window where it shows `frame` of the main window's frame — past its edge, for a
/// float split out of it under a drag, still in that frame — on whole points; the part of the
/// frame it then shows.
pub fn viewportPlaceMain(self: *SDLBackend, vp: *Viewport, frame: viewport_map.Rect) viewport_map.Rect {
    const placed = viewport_map.placeMain(self.mainOnScreen(), self.density(), frame);
    const was = vp.screen;
    placeWindow(vp, placed.screen, was);
    vp.screen = placed.screen;
    return placed.frame;
}

/// `viewportPlaceMain` for a window riding on another (`Viewport.ride`), put somewhere new only
/// when `key` — where it lies over that window — changes. Otherwise it is already there: the OS
/// carried it with that window, ahead of the app's idea of where the window is.
pub fn viewportPlaceRiding(self: *SDLBackend, vp: *Viewport, frame: viewport_map.Rect, key: viewport_map.Rect) viewport_map.Rect {
    if (vp.ride != null and vp.mapped) if (vp.ride_key) |k| if (std.meta.eql(k, key))
        return .{ .x = frame.x + vp.ride_off.x, .y = frame.y + vp.ride_off.y, .w = vp.ride_size.x, .h = vp.ride_size.y };
    const shown = self.viewportPlaceMain(vp, frame);
    vp.ride_key = key;
    vp.ride_off = .{ .x = shown.x - frame.x, .y = shown.y - frame.y };
    vp.ride_size = .{ .x = shown.w, .y = shown.h };
    return shown;
}

/// `frame` of the main window's frame, as the same place on the desktop in `vp`'s band: a float
/// split out under a drag, let go out there, settling into its band where it is.
pub fn viewportBandFromMain(self: *SDLBackend, vp: *const Viewport, frame: viewport_map.Rect) viewport_map.Rect {
    const at = viewport_map.screenFromMain(self.mainOnScreen(), self.density(), frame);
    const p = viewport_map.frameFromScreen(vp.band, vp.anchor, vp.density, .{ .x = at.x, .y = at.y });
    return .{ .x = p.x, .y = p.y, .w = frame.w, .h = frame.h };
}

/// Whether `vp`'s window has shown a frame yet: until it has, what it is to show is still drawn
/// in the main window too, so a float splitting out never vanishes for a frame.
pub fn viewportShown(_: *SDLBackend, vp: *const Viewport) bool {
    return vp.shown;
}

/// Pin a held pointer to a frame of reference, or not (`PointerPin`).
pub fn viewportPinPointer(self: *SDLBackend, pin: PointerPin) void {
    self.pointer_pin = pin;
}

/// Where a press on `vp`'s window is the OS's to move or resize it by, from its float this frame:
/// `drag` its header and `keep` its close button, `glass` the float's glass — physical pixels of
/// the frame, in `vp`'s part of it. None (all the app's) while its float is split under a drag,
/// still in the main window's frame. Its edges resize only where SDL lets the OS resize from a
/// hit test (not macOS), and not while the window is maximized.
pub fn viewportHints(_: *SDLBackend, vp: *Viewport, hints: ?struct { drag: viewport_map.Rect, keep: viewport_map.Rect, glass: viewport_map.Rect, edge: f32, app_side: f32, app_corner: f32 }) void {
    const h = hints orelse {
        vp.hints = .{};
        return;
    };
    const d = vp.density;
    const o = vp.frame;
    const win = struct {
        fn of(r: viewport_map.Rect, origin: viewport_map.Rect, per_point: f32) viewport_map.Rect {
            return .{ .x = (r.x - origin.x) / per_point, .y = (r.y - origin.y) / per_point, .w = r.w / per_point, .h = r.h / per_point };
        }
    };
    const maximized = c.SDL_GetWindowFlags(vp.window) & c.SDL_WINDOW_MAXIMIZED != 0;
    vp.hints = .{
        .drag = win.of(h.drag, o, d),
        .keep = win.of(h.keep, o, d),
        .glass = win.of(h.glass, o, d),
        .edge = if (builtin.os.tag == .macos or maximized) 0 else h.edge / d,
        // Where the OS resizes from no edge (macOS), the float's own resize zones stay its own.
        .app_side = if (builtin.os.tag == .macos) h.app_side / d else 0,
        .app_corner = if (builtin.os.tag == .macos) h.app_corner / d else 0,
    };
}

/// Where `vp`'s window now shows in the frame, when the OS moved or resized it since the last
/// ask: where its float goes, to follow it. Null when it has not.
pub fn viewportOsPlaced(_: *SDLBackend, vp: *Viewport) ?viewport_map.Rect {
    if (!vp.os_placed) return null;
    vp.os_placed = false;
    return vp.frame;
}

/// The press the OS took to move or resize `vp`'s window was let go since the last ask; `resized`
/// when the window is no longer the size it was (resized, snapped or maximized), not just moved.
/// Null otherwise — and for a window the OS moved with no press (a keyboard snap).
pub fn viewportOsMoveEnded(_: *SDLBackend, vp: *Viewport) ?struct { resized: bool } {
    if (comptime builtin.os.tag == .windows) {
        if (!vp.win32_loop.ended) return null;
        vp.win32_loop.ended = false;
        return .{ .resized = vp.win32_loop.resized };
    }
    if (!vp.os_moving or c.SDL_GetGlobalMouseState(null, null) != 0) return null;
    vp.os_moving = false;
    return .{ .resized = vp.screen.w != vp.os_start.w or vp.screen.h != vp.os_start.h };
}

/// Hand the drag under way to the OS: from the next message pump it moves `vp`'s window itself,
/// snapping and all, until the button is let go (`win32_titlebar.viewportDragMove`). False where
/// that is not done (not Windows): the app goes on moving the window until the release.
pub fn viewportDragMove(_: *SDLBackend, vp: *Viewport) bool {
    if (comptime builtin.os.tag != .windows) return false;
    const hwnd = c.SDL_GetPointerProperty(c.SDL_GetWindowProperties(vp.window), c.SDL_PROP_WINDOW_WIN32_HWND_POINTER, null) orelse return false;
    platform.win32_titlebar.viewportDragMove(hwnd);
    return true;
}

/// What `vp`'s window is called — its float's title — where the OS lists windows: the taskbar
/// (Windows: a button of its own, `win32_titlebar.viewportChrome`), the Window menu and the Dock's
/// (macOS), the window switcher.
pub fn viewportTitle(_: *SDLBackend, vp: *Viewport, text: []const u8) void {
    var buf: [128]u8 = undefined;
    const z = std.fmt.bufPrintZ(&buf, "{s}", .{text[0..@min(text.len, buf.len - 1)]}) catch return;
    _ = c.SDL_SetWindowTitle(vp.window, z.ptr);
    if (comptime builtin.os.tag == .macos) fizzy_macos_viewport_windows_item(cocoaWindow(vp.window), z.ptr);
}

/// The least the OS may resize `vp`'s window to: `size` physical pixels of the frame, its float's
/// least.
pub fn viewportMinSize(_: *SDLBackend, vp: *Viewport, w: f32, h: f32) void {
    _ = c.SDL_SetWindowMinimumSize(vp.window, @intFromFloat(@ceil(w / vp.density)), @intFromFloat(@ceil(h / vp.density)));
}

extern fn fizzy_macos_viewport_glass(nswindow: ?*anyopaque, main: ?*anyopaque, inset: f64, radius: f64, material: c_long) void;
extern fn fizzy_macos_viewport_dress(nswindow: ?*anyopaque, main: ?*anyopaque) void;
extern fn fizzy_macos_viewport_menu(nswindow: ?*anyopaque, main: ?*anyopaque, material: c_long, radius: f64, dialog: c_int) c_int;
extern fn fizzy_macos_viewport_menu_attached(nswindow: ?*anyopaque) void;
extern fn fizzy_macos_viewport_order_above(nswindow: ?*anyopaque, other: ?*anyopaque) void;
extern fn fizzy_macos_viewport_lift(nswindow: ?*anyopaque, other: ?*anyopaque) void;
extern fn fizzy_macos_viewport_settle(nswindow: ?*anyopaque) void;
extern fn fizzy_macos_viewport_carry(nswindow: ?*anyopaque, main: ?*anyopaque, material: c_long) void;
extern fn fizzy_macos_viewport_carry_shape(nswindow: ?*anyopaque, radius: f64, w: f64, h: f64, alpha: f64) void;
extern fn fizzy_macos_viewport_carry_lens(nswindow: ?*anyopaque, lens: c_int) void;
extern fn fizzy_macos_window_buttons_width(nswindow: ?*anyopaque) f64;
extern fn fizzy_macos_liquid_glass_available() c_int;
extern fn fizzy_macos_viewport_overlay(nswindow: ?*anyopaque, main: ?*anyopaque) void;
extern fn fizzy_macos_viewport_overlay_glass(nswindow: ?*anyopaque, shapes: [*]const GlassShape, n: c_long, spacing: f64, look: *const GlassLook) void;
extern fn fizzy_macos_window_corner_radius() f64;
extern fn fizzy_macos_viewport_unglass(nswindow: ?*anyopaque) void;
extern fn fizzy_macos_viewport_over_main(nswindow: ?*anyopaque, main_nswindow: ?*anyopaque) void;
extern fn fizzy_macos_viewport_windows_item(nswindow: ?*anyopaque, title: [*:0]const u8) void;

/// Give `vp`'s window a material behind the float's glass, so the float's frost reads the desktop
/// through it as it reads the app in the main window, in the app's light or dark (`dark`) as the
/// main window's is. The glass is its rounded rect `inset` physical pixels in from the window's
/// edge, `radius` its corners. True where the platform has one:
///
/// - macOS: the main window's vibrancy behind the glass, the clear margin round it — where the
///   float draws its shadow — left clear.
/// - Windows: the window is the glass (`viewports.os_frame`, `inset` 0), and DWM dresses it as it
///   does the main window — Acrylic, its own rounded corners and shadow
///   (`win32_titlebar.viewportChrome`). False on a Windows without the backdrop.
/// - Elsewhere: none, for now.
pub fn viewportGlass(self: *SDLBackend, vp: *Viewport, inset: f32, radius: f32, dark: bool) bool {
    const props = c.SDL_GetWindowProperties(vp.window);
    switch (comptime builtin.os.tag) {
        .macos => {
            const ns = c.SDL_GetPointerProperty(props, c.SDL_PROP_WINDOW_COCOA_WINDOW_POINTER, null) orelse return false;
            const main_ns = c.SDL_GetPointerProperty(c.SDL_GetWindowProperties(self.window), c.SDL_PROP_WINDOW_COCOA_WINDOW_POINTER, null);
            // Liquid Glass where the OS has it (macOS 26), as the main window; vibrancy before.
            // Dressed as the main window either way: its shadow and outline, no OS animation.
            if (platform.window.liquidGlass(ns))
                fizzy_macos_viewport_dress(ns, main_ns)
            else
                fizzy_macos_viewport_glass(ns, main_ns, inset / vp.density, radius / vp.density, platform.window.ns_visual_effect_material);
            // Skinned as the main window is (`platform.window.skin`).
            if (self.window_skin) |color| platform.window.skin(ns, color, dark);
            // Through Spaces, zooms and live resizes as the main window goes (`macos_monitor`).
            platform.macos_monitor.watch(vp.window);
            return true;
        },
        .windows => {
            const hwnd = c.SDL_GetPointerProperty(props, c.SDL_PROP_WINDOW_WIN32_HWND_POINTER, null) orelse return false;
            const main_hwnd = c.SDL_GetPointerProperty(c.SDL_GetWindowProperties(self.window), c.SDL_PROP_WINDOW_WIN32_HWND_POINTER, null);
            return platform.win32_titlebar.viewportChrome(hwnd, main_hwnd, dark, radius / vp.density, &vp.win32_loop);
        },
        else => return false,
    }
}

/// `vp`'s window's Liquid Glass this frame (`platform.window.liquidGlassLook`). Whether it has any.
pub fn viewportLiquidGlass(_: *SDLBackend, vp: *Viewport, look: platform.window.WindowGlass) bool {
    return platform.window.liquidGlassLook(vp.window, look);
}

/// Where `vp`'s window is now, in the main window's part of the frame: physical pixels from the
/// main window's top left, wherever either window has been moved since it opened.
pub fn viewportInMain(self: *SDLBackend, vp: *const Viewport) viewport_map.Rect {
    // Where it was last put, not SDL's idea of it: on Windows it may have been moved in one step
    // behind SDL's back (`viewportPlace`), and only the app moves it.
    return viewport_map.mainFromScreen(self.mainOnScreen(), self.density(), vp.screen);
}

/// Hand `vp` its part of this frame, drawn into `target`, for `renderPresent` to copy into its
/// window — or nothing, when there is no picture of it this frame (a target let go must not be
/// copied from after the frame destroys it).
pub fn viewportPresent(_: *SDLBackend, vp: *Viewport, target: ?dvui.TextureTarget) void {
    vp.pending = target;
}

fn viewportOf(self: *SDLBackend, window: *c.SDL_Window) ?*Viewport {
    for (&self.viewports) |*slot| {
        if (slot.*) |*v| if (v.window == window) return v;
    }
    return null;
}

/// The main window's top left on the desktop, points.
fn mainOnScreen(self: *SDLBackend) viewport_map.Point {
    var x: c_int = 0;
    var y: c_int = 0;
    _ = c.SDL_GetWindowPosition(self.window, &x, &y);
    return .{ .x = @floatFromInt(x), .y = @floatFromInt(y) };
}

/// The main window's pixels per point: every viewport draws at its scale for now (one
/// `natural_scale`, `docs/POPOUT_WINDOWS_PLAN.md` on DPI).
fn density(self: *SDLBackend) f32 {
    const d = c.SDL_GetWindowPixelDensity(self.window);
    return if (d > 0) d else 1;
}

/// A pointer event while a button is held — or the release that ends the hold — with a viewport
/// open: placed by where the pointer is (`heldPoint`), not by the window the event came from. The
/// OS keeps sending a held pointer to the window that took the press, so a view carried out of a
/// float that is out went on landing in the float's part of the frame over the main window, and
/// one carried from the main window never reached the float's window.
fn heldAcrossWindows(self: *SDLBackend, event: c.SDL_Event) bool {
    switch (event.type) {
        c.SDL_EVENT_MOUSE_MOTION => if (event.motion.which == c.SDL_TOUCH_MOUSEID) return false,
        c.SDL_EVENT_MOUSE_BUTTON_DOWN, c.SDL_EVENT_MOUSE_BUTTON_UP => if (event.button.which == c.SDL_TOUCH_MOUSEID) return false,
        else => return false,
    }
    const any = for (self.viewports) |v| {
        if (v != null) break true;
    } else false;
    if (!any) return false;
    if (event.type == c.SDL_EVENT_MOUSE_BUTTON_UP) return true;
    return c.SDL_GetGlobalMouseState(null, null) != 0;
}

/// Where in the frame the pointer is, by the window of fizzy's it is over on the desktop: a
/// viewport's part of the frame over its window, the main window's own otherwise. Over both — a
/// viewport is kept over the main window — the viewport's.
fn heldPoint(self: *SDLBackend) dvui.Point.Physical {
    var gx: f32 = 0;
    var gy: f32 = 0;
    _ = c.SDL_GetGlobalMouseState(&gx, &gy);
    switch (self.pointer_pin) {
        .none => {},
        .main => {
            const origin = self.mainOnScreen();
            const d = self.density();
            return .{ .x = (gx - origin.x) * d, .y = (gy - origin.y) * d };
        },
        .viewport => |vp| {
            const p = viewport_map.frameFromScreen(vp.band, vp.anchor, vp.density, .{ .x = gx, .y = gy });
            return .{ .x = p.x, .y = p.y };
        },
    }
    for (&self.viewports) |*slot| {
        const vp = if (slot.*) |*v| v else continue;
        if (vp.passive or vp.see_through) continue;
        const s = vp.screen;
        if (gx >= @as(f32, @floatFromInt(s.x)) and gy >= @as(f32, @floatFromInt(s.y)) and
            gx < @as(f32, @floatFromInt(s.x + s.w)) and gy < @as(f32, @floatFromInt(s.y + s.h)))
        {
            return self.viewportPoint(vp);
        }
    }
    const origin = self.mainOnScreen();
    const d = self.density();
    return .{ .x = (gx - origin.x) * d, .y = (gy - origin.y) * d };
}

/// Where in the frame the pointer over `vp`'s window is: where it is on the desktop, through the
/// band (`viewport_map`). From the desktop, not from the event's place in the window plus where
/// the window is now — the window moves under a drag of its left or top edge, or its header, and
/// an event queued before a move read against the window after it put the pointer off by the
/// move: the edge overshot, was pulled back, and overshot again, shaking the window and what it
/// shows. The plan's "while held, the window follows `SDL_GetGlobalMouseState`". Every event of a
/// frame's burst reads the latest place, which is the one that matters.
fn viewportPoint(self: *SDLBackend, vp: *const Viewport) dvui.Point.Physical {
    var gx: f32 = 0;
    var gy: f32 = 0;
    _ = c.SDL_GetGlobalMouseState(&gx, &gy);
    // A menu's window lies over the main window's frame: read there, and on to where the menu is
    // drawn (`Viewport.main_offset`).
    if (vp.menu) {
        const origin = self.mainOnScreen();
        const d = self.density();
        return .{ .x = (gx - origin.x) * d + vp.main_offset.x, .y = (gy - origin.y) * d + vp.main_offset.y };
    }
    const p = viewport_map.frameFromScreen(vp.band, vp.anchor, vp.density, .{ .x = gx, .y = gy });
    return .{ .x = p.x, .y = p.y };
}

/// An event from a viewport's window, for the one dvui window: the pointer goes where the window
/// shows it in the frame, keys go as they are, and a close asked of the window is kept for the
/// app, which takes the float back in (`Viewport.close_requested`).
fn addViewportEvent(self: *SDLBackend, win: *dvui.Window, vp: *Viewport, event: c.SDL_Event) !bool {
    switch (event.type) {
        c.SDL_EVENT_MOUSE_MOTION => {
            if (event.motion.which == c.SDL_TOUCH_MOUSEID and !self.touch_mouse_events) return false;
            return try win.addEventMouseMotion(.{ .pt = self.viewportPoint(vp) });
        },
        c.SDL_EVENT_MOUSE_BUTTON_DOWN, c.SDL_EVENT_MOUSE_BUTTON_UP, c.SDL_EVENT_MOUSE_WHEEL => {
            // dvui presses and scrolls where the pointer last moved, which may have been over
            // another window: it is moved here first.
            const pt = self.viewportPoint(vp);
            if (pt.x != win.mouse_pt.x or pt.y != win.mouse_pt.y) _ = try win.addEventMouseMotion(.{ .pt = pt });
            return try self.addEvent(win, event);
        },
        c.SDL_EVENT_KEY_DOWN, c.SDL_EVENT_KEY_UP, c.SDL_EVENT_TEXT_INPUT, c.SDL_EVENT_TEXT_EDITING => return try self.addEvent(win, event),
        c.SDL_EVENT_WINDOW_MOUSE_LEAVE => {
            try win.addEventWindow(.{ .action = .leave });
            return false;
        },
        c.SDL_EVENT_WINDOW_CLOSE_REQUESTED => {
            vp.close_requested = true;
            return false;
        },
        c.SDL_EVENT_WINDOW_MOVED, c.SDL_EVENT_WINDOW_RESIZED => {
            viewportFollowWindow(vp);
            return false;
        },
        else => return false,
    }
}

/// The OS moved or resized `vp`'s window — dragged by its header or edges, snapped, tiled,
/// maximized — rather than the app putting it there: its part of the frame goes with it, and its
/// float follows (`viewportOsPlaced`).
fn viewportFollowWindow(vp: *Viewport) void {
    var x: c_int = 0;
    var y: c_int = 0;
    var w: c_int = 0;
    var h: c_int = 0;
    _ = c.SDL_GetWindowPosition(vp.window, &x, &y);
    _ = c.SDL_GetWindowSize(vp.window, &w, &h);
    const now: viewport_map.ScreenRect = .{ .x = x, .y = y, .w = w, .h = h };
    // Where the app put it: its own doing, reported back.
    if (std.meta.eql(now, vp.screen)) return;
    // Placing a window is asynchronous on X11: just after the app put it somewhere, what it says
    // of itself is still on its way there.
    if (comptime builtin.os.tag == .linux) {
        if (c.SDL_GetTicksNS() -% vp.app_placed_ns < 250 * std.time.ns_per_ms) return;
    }
    // Under a held press, and no move loop to say when it ends (not Windows): the OS is moving it
    // until the press is let go.
    if (comptime builtin.os.tag != .windows) {
        if (!vp.os_moving and c.SDL_GetGlobalMouseState(null, null) != 0) {
            vp.os_moving = true;
            vp.os_start = vp.screen;
        }
    }
    vp.screen = now;
    vp.frame = viewport_map.frameOfScreen(vp.band, vp.anchor, vp.density, now);
    vp.os_placed = true;
}

/// SDL's hit test for a viewport's window, from what its float said this frame (`viewportHints`):
/// its header moves the window and its edges resize it — the OS's own move and resize, so the
/// window snaps, tiles and maximizes as any window does. SDL on macOS takes only the move (AppKit's
/// window-background drag); the float's own edges resize it there.
fn viewportHitTest(_: ?*c.SDL_Window, area: [*c]const c.SDL_Point, data: ?*anyopaque) callconv(.c) c.SDL_HitTestResult {
    const vp: *const Viewport = @ptrCast(@alignCast(data orelse return c.SDL_HITTEST_NORMAL));
    const p: viewport_map.Point = .{ .x = @floatFromInt(area.*.x), .y = @floatFromInt(area.*.y) };
    return switch (viewport_map.hitTest(vp.hints, p)) {
        .app => c.SDL_HITTEST_NORMAL,
        .drag => c.SDL_HITTEST_DRAGGABLE,
        .top_left => c.SDL_HITTEST_RESIZE_TOPLEFT,
        .top => c.SDL_HITTEST_RESIZE_TOP,
        .top_right => c.SDL_HITTEST_RESIZE_TOPRIGHT,
        .right => c.SDL_HITTEST_RESIZE_RIGHT,
        .bottom_right => c.SDL_HITTEST_RESIZE_BOTTOMRIGHT,
        .bottom => c.SDL_HITTEST_RESIZE_BOTTOM,
        .bottom_left => c.SDL_HITTEST_RESIZE_BOTTOMLEFT,
        .left => c.SDL_HITTEST_RESIZE_LEFT,
    };
}

pub fn setCursor(self: *SDLBackend, cursor: dvui.enums.Cursor) void {
    // NOTE: SDL3's UIKit driver has no system cursors, so SDL_CreateSystemCursor always fails there.
    if (builtin.os.tag == .ios) return;
    if (cursor == self.cursor_last) return;
    defer self.cursor_last = cursor;
    const new_shown_state = if (cursor == .hidden) false else if (self.cursor_last == .hidden) true else null;
    if (new_shown_state) |new_state| {
        if (self.cursorShow(new_state) == new_state) {
            log.err("Cursor shown state was out of sync", .{});
        }
        // Return early if we are hiding
        if (new_state == false) return;
    }

    const enum_int = @intFromEnum(cursor);
    const tried = self.cursor_backing_tried[enum_int];
    if (!tried) {
        self.cursor_backing_tried[enum_int] = true;
        self.cursor_backing[enum_int] = switch (cursor) {
            .arrow => c.SDL_CreateSystemCursor(c.SDL_SYSTEM_CURSOR_DEFAULT),
            .ibeam => c.SDL_CreateSystemCursor(c.SDL_SYSTEM_CURSOR_TEXT),
            .wait => c.SDL_CreateSystemCursor(c.SDL_SYSTEM_CURSOR_WAIT),
            .wait_arrow => c.SDL_CreateSystemCursor(c.SDL_SYSTEM_CURSOR_PROGRESS),
            .crosshair => c.SDL_CreateSystemCursor(c.SDL_SYSTEM_CURSOR_CROSSHAIR),
            .arrow_nw_se => c.SDL_CreateSystemCursor(c.SDL_SYSTEM_CURSOR_NWSE_RESIZE),
            .arrow_ne_sw => c.SDL_CreateSystemCursor(c.SDL_SYSTEM_CURSOR_NESW_RESIZE),
            .arrow_w_e => c.SDL_CreateSystemCursor(c.SDL_SYSTEM_CURSOR_EW_RESIZE),
            .arrow_n_s => c.SDL_CreateSystemCursor(c.SDL_SYSTEM_CURSOR_NS_RESIZE),
            .arrow_all => c.SDL_CreateSystemCursor(c.SDL_SYSTEM_CURSOR_MOVE),
            .bad => c.SDL_CreateSystemCursor(c.SDL_SYSTEM_CURSOR_NOT_ALLOWED),
            .hand => c.SDL_CreateSystemCursor(c.SDL_SYSTEM_CURSOR_POINTER),
            .hidden => unreachable,
        };
    }

    if (self.cursor_backing[enum_int]) |cur| {
        toErr(c.SDL_SetCursor(cur), "SDL_SetCursor in setCursor") catch return;
    } else {
        log.err("setCursor \"{s}\" failed", .{@tagName(cursor)});
        logErr("SDL_CreateSystemCursor in setCursor") catch return;
    }
    self.manage_backend_tracking.check(.setCursor);
}

pub fn textInputRect(self: *SDLBackend, rect: ?dvui.Rect.Natural) void {
    // Typed into whichever window has the keyboard: a viewport's, when one does — its text goes
    // to the one dvui window like its keys (`addViewportEvent`), and its IME sits over its part
    // of the frame.
    const focus = c.SDL_GetKeyboardFocus();
    const vp: ?*Viewport = if (focus) |w| self.viewportOf(w) else null;
    const window = if (vp) |v| v.window else self.window;
    // SDL_StartTextInput unconditionally re-applies text input properties every
    // call, which on iOS tears the hidden UITextField out of the view hierarchy
    // and re-adds it (see UIKit_SetTextInputProperties), thrashing the on-screen
    // keyboard if called every frame. Only call through on an actual change.
    if (std.meta.eql(rect, self.text_input_rect_last) and window == (self.text_input_window orelse self.window)) return;
    if (self.text_input_window) |was| if (was != window and self.viewportOf(was) != null) {
        _ = c.SDL_StopTextInput(was);
    };
    defer self.text_input_rect_last = rect;
    defer self.text_input_window = window;

    if (rect) |rect_frame| {
        var r = rect_frame;
        if (vp) |v| {
            // From the frame into the viewport's window: its band offset, in points.
            const d = c.SDL_GetWindowPixelDensity(v.window);
            r.x -= v.frame.x / (if (d > 0) d else 1);
            r.y -= v.frame.y / (if (d > 0) d else 1);
        }
        // This is the offset from r.x in window coords, supposed to be the
        // location of the cursor I think so that the IME window can be put
        // at the cursor location.  We will use 0 for now, might need to
        // change it (or how we determine rect) if people are using huge
        // text entries).
        const cursor = 0;

        toErr(c.SDL_SetTextInputArea(
            window,
            &c.SDL_Rect{
                .x = @trunc(r.x),
                .y = @trunc(r.y),
                .w = @trunc(r.w),
                .h = @trunc(r.h),
            },
            cursor,
        ), "SDL_SetTextInputArea in textInputRect") catch return;
        toErr(c.SDL_StartTextInput(window), "SDL_StartTextInput in textInputRect") catch return;
    } else {
        toErr(c.SDL_StopTextInput(window), "SDL_StopTextInput in textInputRect") catch return;
    }
    self.manage_backend_tracking.check(.textInputRect);
}

pub fn deinit(self: *SDLBackend) void {
    for (self.cursor_backing) |cursor| {
        if (cursor) |cur| c.SDL_DestroyCursor(cur);
    }

    if (self.we_own_window) {
        if (self.init_opts_save != null and self.init_opts_save.?.persist_window_geometry) {
            self.trackGeometry();
            WindowGeometry.save(self);
        }
        // Viewports are claimed on this window's device: given back before it goes.
        for (&self.viewports) |*slot| {
            if (slot.*) |*v| self.viewportClose(v);
        }
        self.gpu.destroy();
        c.SDL_DestroyWindow(self.window);
        if (self.sdl_quit) {
            c.SDL_Quit();
        }
    }
    self.* = undefined;
}

pub fn renderPresent(self: *SDLBackend) void {
    // macOS: a window put somewhere new this frame goes there in the transaction its picture is
    // presented in, so the two change together (`placeWindow`). Before the pictures are copied
    // into the windows, so a resized window's drawable is already its new size. A window's first
    // picture too, with the window shown and ordered over the main one below: it comes up where its
    // float is, with the picture drawn for it there. Shown on its own, it showed for a composite
    // empty, then with a picture a frame of the drag away from it.
    var transacted: [max_viewports]bool = @splat(false);
    var any = false;
    if (comptime builtin.os.tag == .macos) {
        for (&self.viewports, 0..) |*slot, i| {
            const vp = if (slot.*) |*v| v else continue;
            const first = !vp.shown and vp.pending != null;
            const reshaped = vp.passive and !vp.overlay and (vp.carry_radius != vp.carry_radius_shown or vp.carry_alpha != vp.carry_alpha_shown or vp.carry_size_shown[0] != vp.screen.w or vp.carry_size_shown[1] != vp.screen.h);
            const reglassed = vp.overlay and vp.glass_dirty;
            if (!vp.frame_pending and !first and !reshaped and !reglassed) continue;
            if (!any) fizzy_native_transaction_begin();
            any = true;
            transacted[i] = true;
            const ns = cocoaWindow(vp.window);
            if (vp.frame_pending) {
                vp.frame_pending = false;
                const r = vp.screen;
                fizzy_native_viewport_set_frame(ns, @floatFromInt(r.x), @floatFromInt(r.y), @floatFromInt(r.w), @floatFromInt(r.h));
            } else fizzy_native_viewport_transact(ns);
            if (reshaped) {
                vp.carry_radius_shown = vp.carry_radius;
                vp.carry_alpha_shown = vp.carry_alpha;
                vp.carry_size_shown = .{ vp.screen.w, vp.screen.h };
                fizzy_macos_viewport_carry_shape(ns, vp.carry_radius, @floatFromInt(vp.screen.w), @floatFromInt(vp.screen.h), vp.carry_alpha);
            }
            if (reglassed) {
                vp.glass_dirty = false;
                fizzy_macos_viewport_overlay_glass(ns, &vp.glass, @intCast(vp.glass_n), vp.glass_spacing, &vp.glass_look);
            }
        }
    }
    defer if (comptime builtin.os.tag == .macos) if (any) {
        for (&self.viewports, transacted) |*slot, t| {
            if (!t) continue;
            const vp = if (slot.*) |*v| v else continue;
            fizzy_native_viewport_presented(cocoaWindow(vp.window));
        }
        fizzy_native_transaction_commit();
    };
    // Each viewport's part of the frame goes in with the main window's, one submission for all.
    var first_frame: [max_viewports]bool = @splat(false);
    var map_empty: [max_viewports]bool = @splat(false);
    for (&self.viewports, 0..) |*slot, i| {
        const vp = if (slot.*) |*v| v else continue;
        const target = vp.pending orelse continue;
        vp.pending = null;
        // Nobody sees a minimized or covered window, and Metal can hold a drawable back from one
        // for up to a second: skipped, once it has been shown (it is created hidden, and covered
        // then by its own account).
        if (vp.shown and c.SDL_GetWindowFlags(vp.window) & (c.SDL_WINDOW_MINIMIZED | c.SDL_WINDOW_OCCLUDED) != 0) continue;
        const presented = self.gpu.presentInto(vp.window, target);
        if (vp.shown) continue;
        if (presented) {
            first_frame[i] = true;
        } else if (!vp.mapped) {
            // Nothing to draw into while it is hidden (Vulkan on X11 hands a hidden window no
            // image): shown empty, which is clear, and drawn into from the next frame.
            map_empty[i] = true;
        }
    }
    self.gpu.present(self.clear_window_on_begin);
    // Shown once there is a frame in it (or empty, above). Not made key: the window it came out of
    // keeps the keyboard until the viewport is clicked.
    for (&self.viewports, first_frame, map_empty) |*slot, show, empty| {
        if (!show and !empty) continue;
        const vp = if (slot.*) |*v| v else continue;
        if (!vp.mapped) {
            _ = c.SDL_SetHint(c.SDL_HINT_WINDOW_ACTIVATE_WHEN_SHOWN, "0");
            _ = c.SDL_ShowWindow(vp.window);
            _ = c.SDL_ResetHint(c.SDL_HINT_WINDOW_ACTIVATE_WHEN_SHOWN);
            vp.mapped = true;
            // Riding on its window from here (`Viewport.ride`) — not before it shows: made a child
            // window, AppKit shows it at once, before it has a picture.
            if (comptime builtin.os.tag == .macos) if (vp.ride) |parent| {
                _ = c.SDL_SetWindowParent(vp.window, parent);
                if (!vp.dialog) fizzy_macos_viewport_menu_attached(cocoaWindow(vp.window));
            };
        }
        if (show) vp.shown = true;
        vp.over_main = true;
    }
    // Over the main window as it first shows: SDL showed it below the key window. Once
    // (`noteMainForward`): from there it stacks as any window does.
    if (comptime builtin.os.tag == .macos) {
        const main_ns = cocoaWindow(self.window);
        for (&self.viewports) |*slot| {
            const vp = if (slot.*) |*v| v else continue;
            if (!vp.over_main) continue;
            vp.over_main = false;
            if (!vp.mapped or vp.passive or vp.menu) continue;
            fizzy_macos_viewport_over_main(cocoaWindow(vp.window), main_ns);
        }
    }
    self.manage_backend_tracking.check(.renderPresent);
}

pub fn backend(self: *SDLBackend) dvui.Backend {
    return dvui.Backend.init(self);
}

pub fn nanoTime(self: *SDLBackend) i128 {
    const ret = std.Io.Clock.awake.now(self.io);
    return ret.nanoseconds + self.clock_ahead_ns;
}

pub fn sleep(self: *SDLBackend, ns: u64) void {
    std.Io.Clock.Duration.sleep(.{ .clock = .awake, .raw = .fromNanoseconds(ns) }, self.io) catch {};
}

pub fn clipboardText(self: *SDLBackend) ![]const u8 {
    if (!c.SDL_HasClipboardText()) return &.{};

    const p = c.SDL_GetClipboardText();
    defer c.SDL_free(p); // must free even on error

    const str = std.mem.span(p);
    // Log error, but don't fail the application
    if (str.len == 0) logErr("SDL_GetClipboardText in clipboardText") catch {};

    return try self.arena.dupe(u8, str);
}

pub fn clipboardTextSet(self: *SDLBackend, text: []const u8) !void {
    if (text.len == 0) return;
    const c_text = try self.arena.dupeSentinel(u8, text, 0);
    defer self.arena.free(c_text);
    try toErr(c.SDL_SetClipboardText(c_text.ptr), "SDL_SetClipboardText in clipboardTextSet");
}

/// The X11/Wayland PRIMARY selection (different buffer from clipboard).
pub fn primarySelectionText(self: *SDLBackend) ![]const u8 {
    if (!c.SDL_HasPrimarySelectionText()) return &.{};
    const p = c.SDL_GetPrimarySelectionText();
    defer c.SDL_free(p);
    const str = std.mem.span(p);
    if (str.len == 0) logErr("SDL_GetPrimarySelectionText in primarySelectionText") catch {};
    return try self.arena.dupe(u8, str);
}

pub fn openURL(self: *SDLBackend, url: []const u8, _: bool) !void {
    const c_url = try self.arena.dupeSentinel(u8, url, 0);
    defer self.arena.free(c_url);
    try toErr(c.SDL_OpenURL(c_url.ptr), "SDL_OpenURL in openURL");
}

pub fn preferredColorScheme(_: *SDLBackend) ?dvui.enums.ColorScheme {
    return switch (c.SDL_GetSystemTheme()) {
        c.SDL_SYSTEM_THEME_DARK => .dark,
        c.SDL_SYSTEM_THEME_LIGHT => .light,
        else => null,
    };
}

pub fn prefersReducedMotion(_: *@This()) bool {
    return false;
}

pub fn begin(self: *SDLBackend, arena: std.mem.Allocator) !void {
    self.arena = arena;
    if (self.begin_hook) |hook| hook(self);
    self.gpu.beginFrame();
    self.manage_backend_tracking.reset_begin();
}

/// The window is cleared by the renderer's first window pass of the frame (see
/// `clear_window_on_begin`); nothing to do here.
pub fn clearWindow(_: *SDLBackend) !void {}

pub fn end(_: *SDLBackend) !void {}

/// The window's drawable size. On macOS the swapchain layer's own (what SDL's Metal renderer
/// reported, and what fizzy's AppKit sync keeps current during animations); elsewhere SDL's.
pub fn pixelSize(self: *SDLBackend) dvui.Size.Physical {
    var w: c_int = 0;
    var h: c_int = 0;
    if (builtin.os.tag == .macos) {
        if (cocoaWindow(self.window)) |nswindow| {
            if (fizzy_native_metal_drawable_size(nswindow, &w, &h) != 0) {
                self.last_pixel_size = .{ .w = @floatFromInt(w), .h = @floatFromInt(h) };
                return self.last_pixel_size;
            }
        }
    }
    toErr(c.SDL_GetWindowSizeInPixels(self.window, &w, &h), "SDL_GetWindowSizeInPixels in pixelSize") catch return self.last_pixel_size;
    self.last_pixel_size = .{ .w = @floatFromInt(w), .h = @floatFromInt(h) };
    return self.last_pixel_size;
}

pub fn windowSize(self: *SDLBackend) dvui.Size.Natural {
    var w: i32 = undefined;
    var h: i32 = undefined;
    toErr(c.SDL_GetWindowSize(self.window, &w, &h), "SDL_GetWindowSize in windowSize") catch return self.last_window_size;
    self.last_window_size = .{ .w = @as(f32, @floatFromInt(w)), .h = @as(f32, @floatFromInt(h)) };
    return self.last_window_size;
}

pub fn contentScale(self: *SDLBackend) f32 {
    const display_id = c.SDL_GetDisplayForWindow(self.window);
    const scale = c.SDL_GetDisplayContentScale(display_id);
    if (scale == 0.0) {
        log.err("SDL_GetDisplayContentScale returned 0", .{});
        return 1.0;
    }
    return scale;
}

// ---------------------------------------------------------------------------------------------
// Drawing: all of it is `GpuRenderer`'s.

pub fn drawClippedTriangles(self: *SDLBackend, texture: ?dvui.Texture, vtx: []const dvui.Vertex, idx: []const dvui.Vertex.Index, maybe_clipr: ?dvui.Rect.Physical) !void {
    self.gpu.draw(texture, vtx, idx, maybe_clipr) catch |err| {
        log.err("drawClippedTriangles: {any}", .{err});
        return dvui.Backend.GenericError.BackendError;
    };
}

pub fn textureCreate(self: *SDLBackend, pixels: [*]const u8, options: dvui.Texture.CreateOptions) !dvui.Texture {
    return self.gpu.textureCreate(pixels, options);
}

pub fn textureUpdate(self: *SDLBackend, texture: dvui.Texture, pixels: [*]const u8) !void {
    return self.gpu.textureUpdate(texture, pixels, 0, 0, texture.width, texture.height);
}

pub fn textureUpdateSubRect(self: *SDLBackend, texture: dvui.Texture, pixels: [*]const u8, x: u32, y: u32, w: u32, h: u32) !void {
    return self.gpu.textureUpdate(texture, pixels, x, y, w, h);
}

/// See `dvui.Backend.support_precise_targets`: 16-bit float targets where the GPU can render
/// to and sample them (every SDL_GPU driver can).
pub const support_precise_targets = true;

pub fn textureCreateTarget(self: *SDLBackend, options: dvui.Texture.CreateOptions) !dvui.TextureTarget {
    return self.gpu.textureCreateTarget(options);
}

pub fn textureClearTarget(self: *SDLBackend, texture: dvui.TextureTarget) void {
    self.gpu.textureClearTarget(texture);
}

/// See `dvui.Backend.textureBlend`.
pub fn textureBlend(self: *SDLBackend, texture: dvui.Texture, blend: dvui.Backend.TextureBlend) !void {
    self.gpu.textureBlend(texture, blend);
}

/// Read back a rectangle of the *current* render target as RGBA into `pixels_out`
/// (`rect.w * rect.h * 4` bytes): what has been drawn there so far this frame. A render
/// target only — the window's drawable cannot be read — and a GPU sync, so rare.
pub fn readPixels(self: *SDLBackend, rect: dvui.Rect.Physical, pixels_out: [*]u8) !void {
    return self.gpu.readPixels(rect, pixels_out);
}

pub fn textureReadTarget(self: *SDLBackend, texture: dvui.TextureTarget, pixels_out: [*]u8) !void {
    return self.gpu.textureReadTarget(texture, pixels_out);
}

pub fn textureDestroy(self: *SDLBackend, texture: dvui.Texture) void {
    self.gpu.textureDestroy(texture.ptr);
}

pub fn textureDestroyTarget(self: *SDLBackend, texture: dvui.Texture.Target) void {
    self.gpu.textureDestroy(texture.ptr);
}

// as if we are destroying target and creating a new texture
pub fn textureFromTarget(_: *SDLBackend, target: dvui.TextureTarget) !dvui.Texture {
    return .cast(target);
}

// return is temporary, will not be destroyed
pub fn textureFromTargetTemp(_: *SDLBackend, target: dvui.TextureTarget) !dvui.Texture {
    return .cast(target);
}

pub fn renderTarget(self: *SDLBackend, texture: ?dvui.TextureTarget) !void {
    self.gpu.renderTarget(texture) catch |err| {
        log.err("renderTarget: {any}", .{err});
        return dvui.Backend.GenericError.BackendError;
    };
}

/// Turn vsync on or off for this window, now. Fizzy's macOS live-resize toggle uses it
/// (`backend_native.zig`): a vsync-blocking present inside AppKit's resize loop delays the
/// tracker's next mouse event.
pub fn setVSync(self: *SDLBackend, on: bool) void {
    self.gpu.setVSync(on);
}

pub fn vsync(self: *SDLBackend) bool {
    return self.gpu.vsync;
}

/// `setVSync` for whichever backend drives `window`, from code that has the SDL window but not
/// the backend (an AppKit notification). False when no renderer of this backend owns it.
pub fn setWindowVSync(window: *c.SDL_Window, on: bool) bool {
    const gpu = GpuRenderer.forWindow(window) orelse return false;
    gpu.setVSync(on);
    return true;
}

/// The vsync `setWindowVSync` would change, or null when no renderer of this backend owns it.
pub fn windowVSync(window: *c.SDL_Window) ?bool {
    const gpu = GpuRenderer.forWindow(window) orelse return null;
    return gpu.vsync;
}

/// Custom fragment programs (`core.gfx.programs`): the native half of the API the web backend
/// declares, so code above the backend draws through either the same way.
///
/// Native programs are compiled shaders, not GLSL: `create` (GLSL) returns 0 here, and
/// `createNative` takes the program for each SDL_GPU shader format — Metal source (MSL, entry
/// point `main0`), SPIR-V and DXIL, the device taking the one it runs (built from one HLSL
/// source by shadercross). A program is a fragment shader fed by the default vertex shader:
///
/// * Inputs: the vertex colour (premultiplied, 0…1) and uv, as dvui passed them.
///   MSL: `float4 color [[user(locn0)]]`, `float2 uv [[user(locn1)]]` in the `[[stage_in]]`
///   struct. HLSL: `float4 color : COLOR`, `float2 uv : TEXCOORD0` after `SV_POSITION`, as
///   dvui's `shared.hlsl` declares them. SPIR-V: locations 0 and 1.
/// * Textures: the draw's own texture (white where it has none) at slot 0, `begin`'s
///   `textures` at slots 1 and 2. MSL: `[[texture(n)]]` + `[[sampler(n)]]`. HLSL:
///   `Texture2D tN : register(tN, space2)`, `SamplerState sN : register(sN, space2)`.
///   SPIR-V: descriptor set 2, bindings 0…n (combined image samplers).
/// * Uniforms (when `uniform_vec4s > 0`): one constant buffer holding `float4 data[N]`, N
///   = `uniform_vec4s`. MSL: `constant float4 *data [[buffer(0)]]` (or a struct of the same
///   layout). HLSL: `cbuffer U : register(b0, space3) { float4 data[N]; }`. SPIR-V: set 3,
///   binding 0.
/// * Output: one premultiplied `float4` colour (`[[color(0)]]`, `SV_Target0`).
///
/// Compiling is synchronous: a program is ready (`status` 2) or failed (0) once created.
/// `shaders/program_example.fragment.hlsl` (and its Metal form beside the compiled shaders)
/// is a worked example.
pub const program_api = struct {
    pub const uniform_cap = GpuRenderer.uniform_cap;

    pub fn max_uniform_vec4s() u32 {
        return uniform_cap;
    }

    /// GLSL is the web's; a native program comes through `createNative`.
    pub fn create(glsl: [*]const u8, len: usize, textures: u32, uniform_vec4s: u32) u32 {
        _ = glsl;
        _ = len;
        _ = textures;
        _ = uniform_vec4s;
        return 0;
    }

    /// Compile a program from the source for this device's shader format. 0 when there is
    /// none for it, it fails to compile, or it asks for more than `uniform_cap` vec4s or 2
    /// extra textures.
    pub fn createNative(
        msl: [*]const u8,
        msl_len: usize,
        spv: [*]const u8,
        spv_len: usize,
        dxil: [*]const u8,
        dxil_len: usize,
        textures: u32,
        uniform_vec4s: u32,
    ) u32 {
        const gpu = current() orelse return 0;
        return gpu.programCreate(.{
            .msl = msl[0..msl_len],
            .spirv = spv[0..spv_len],
            .dxil = dxil[0..dxil_len],
        }, textures, uniform_vec4s);
    }

    pub fn status(id: u32) callconv(.c) u8 {
        const gpu = current() orelse return 0;
        return gpu.programStatus(id);
    }

    pub fn begin(id: u32, textures: [*]const ?*anyopaque, n_textures: u32, uniforms: [*]const [4]f32, n_uniforms: u32) callconv(.c) bool {
        const gpu = current() orelse return false;
        return gpu.programBegin(id, textures[0..n_textures], uniforms[0..n_uniforms]);
    }

    pub fn blend(mode: u8) callconv(.c) void {
        const gpu = current() orelse return;
        gpu.programBlend(mode);
    }

    pub fn end() callconv(.c) void {
        const gpu = current() orelse return;
        gpu.programEnd();
    }

    /// The renderer of the window being drawn (programs are called mid-frame), else the
    /// primary one.
    fn current() ?*GpuRenderer {
        if (dvui.current_window) |win| return win.backend.impl.gpu;
        return GpuRenderer.primary();
    }
};

/// Record the window rect on move/resize while the window is in its normal
/// (non-fullscreen/maximized/minimized) state.
fn trackGeometry(self: *SDLBackend) void {
    if (self.init_opts_save) |opts| if (!opts.persist_window_geometry) return;

    const flags = c.SDL_GetWindowFlags(self.window);
    if (flags & c.SDL_WINDOW_MINIMIZED != 0) {
        // don't track
        return;
    }

    if (flags & c.SDL_WINDOW_FULLSCREEN != 0) {
        // only track state
        self.window_geometry.state = .fullscreen;
        return;
    }

    if (flags & c.SDL_WINDOW_MAXIMIZED != 0) {
        // only track state
        self.window_geometry.state = .maximized;
        return;
    }

    var x: c_int = 0;
    var y: c_int = 0;
    var w: c_int = 0;
    var h: c_int = 0;
    if (!c.SDL_GetWindowPosition(self.window, &x, &y)) return;
    if (!c.SDL_GetWindowSize(self.window, &w, &h)) return;
    if (w < 1 or h < 1) return;
    self.window_geometry = .{ .x = x, .y = y, .w = w, .h = h };
}

/// Send an SDL_Event to a dvui.Window
///
/// Return true if the event is to be handled by a subwindow.
///
/// This allows "ontop" application main loop to ignore such events since they
/// are meant for something visually floating on top of the main application.
pub fn addEvent(self: *SDLBackend, win: *dvui.Window, event: c.SDL_Event) !bool {
    switch (event.type) {
        if (sdl3) c.SDL_EVENT_KEY_DOWN else c.SDL_KEYDOWN => {
            const sdl_key: i32 = if (sdl3) @intCast(event.key.key) else event.key.keysym.sym;
            const code = SDL_keysym_to_dvui(@intCast(sdl_key));
            const mod = SDL_keymod_to_dvui(if (sdl3) @intCast(event.key.mod) else event.key.keysym.mod);
            if (self.log_events) {
                log.debug("event KEYDOWN {any} {s} {any} {any}\n", .{ sdl_key, @tagName(code), mod, event.key.repeat });
            }

            return try win.addEventKey(.{
                .code = code,
                .action = if (if (sdl3) event.key.repeat else event.key.repeat != 0) .repeat else .down,
                .mod = mod,
            });
        },
        if (sdl3) c.SDL_EVENT_KEY_UP else c.SDL_KEYUP => {
            const sdl_key: i32 = if (sdl3) @intCast(event.key.key) else event.key.keysym.sym;
            const code = SDL_keysym_to_dvui(@intCast(sdl_key));
            const mod = SDL_keymod_to_dvui(if (sdl3) @intCast(event.key.mod) else event.key.keysym.mod);
            if (self.log_events) {
                log.debug("event KEYUP {any} {s} {any}\n", .{ sdl_key, @tagName(code), mod });
            }

            return try win.addEventKey(.{
                .code = code,
                .action = .up,
                .mod = mod,
            });
        },
        if (sdl3) c.SDL_EVENT_TEXT_INPUT else c.SDL_TEXTINPUT => {
            const txt = std.mem.sliceTo(if (sdl3) event.text.text else &event.text.text, 0);
            if (self.log_events) {
                log.debug("event TEXTINPUT {s}\n", .{txt});
            }

            return try win.addEventText(.{ .text = txt });
        },
        if (sdl3) c.SDL_EVENT_TEXT_EDITING else c.SDL_TEXTEDITING => {
            const strlen: u8 = @intCast(c.SDL_strlen(if (sdl3) event.edit.text else &event.edit.text));
            if (self.log_events) {
                log.debug("event TEXTEDITING {s} start {d} len {d} strlen {d}\n", .{ event.edit.text, event.edit.start, event.edit.length, strlen });
            }
            return try win.addEventText(.{ .text = event.edit.text[0..strlen], .selected = true });
        },
        if (sdl3) c.SDL_EVENT_MOUSE_MOTION else c.SDL_MOUSEMOTION => {
            const touch = event.motion.which == c.SDL_TOUCH_MOUSEID;
            if (self.log_events) {
                var touch_str: []const u8 = " ";
                if (touch) touch_str = " touch ";
                if (touch and !self.touch_mouse_events) touch_str = " touch ignored ";
                log.debug("event{s}MOUSEMOTION {d} {d}\n", .{ touch_str, event.motion.x, event.motion.y });
            }

            if (touch and !self.touch_mouse_events) {
                return false;
            }

            // sdl gives us mouse coords in "window coords" which is kind of
            // like natural coords but ignores content scaling
            const windowW = self.windowSize().w;
            const scale = if (windowW == 0) 1.0 else (self.pixelSize().w / windowW);

            if (sdl3) {
                return try win.addEventMouseMotion(.{
                    .pt = .{
                        .x = event.motion.x * scale,
                        .y = event.motion.y * scale,
                    },
                });
            } else {
                return try win.addEventMouseMotion(.{
                    .pt = .{
                        .x = @as(f32, @floatFromInt(event.motion.x)) * scale,
                        .y = @as(f32, @floatFromInt(event.motion.y)) * scale,
                    },
                });
            }
        },
        if (sdl3) c.SDL_EVENT_MOUSE_BUTTON_DOWN else c.SDL_MOUSEBUTTONDOWN => {
            const touch = event.motion.which == c.SDL_TOUCH_MOUSEID;
            if (self.log_events) {
                var touch_str: []const u8 = " ";
                if (touch) touch_str = " touch ";
                if (touch and !self.touch_mouse_events) touch_str = " touch ignored ";
                log.debug("event{s}MOUSEBUTTONDOWN {d}\n", .{ touch_str, event.button.button });
            }

            if (touch and !self.touch_mouse_events) {
                return false;
            }

            // The live modifier state, not the last key event's: a modifier whose keyup went
            // to another app (cmd-tab, a browser opened for sign-in) would otherwise stick to
            // every click until the next key event.
            win.modifiers = SDL_keymod_to_dvui(@intCast(c.SDL_GetModState()));
            return try win.addEventMouseButton(SDL_mouse_button_to_dvui(event.button.button), .press);
        },
        if (sdl3) c.SDL_EVENT_MOUSE_BUTTON_UP else c.SDL_MOUSEBUTTONUP => {
            const touch = event.motion.which == c.SDL_TOUCH_MOUSEID;
            if (self.log_events) {
                var touch_str: []const u8 = " ";
                if (touch) touch_str = " touch ";
                if (touch and !self.touch_mouse_events) touch_str = " touch ignored ";
                log.debug("event{s}MOUSEBUTTONUP {d}\n", .{ touch_str, event.button.button });
            }

            if (touch and !self.touch_mouse_events) {
                return false;
            }

            win.modifiers = SDL_keymod_to_dvui(@intCast(c.SDL_GetModState()));
            return try win.addEventMouseButton(SDL_mouse_button_to_dvui(event.button.button), .release);
        },
        if (sdl3) c.SDL_EVENT_MOUSE_WHEEL else c.SDL_MOUSEWHEEL => {
            // .precise added in 2.0.18
            const ticks_x = if (sdl3) event.wheel.x else event.wheel.preciseX;
            const ticks_y = if (sdl3) event.wheel.y else event.wheel.preciseY;

            if (self.log_events) {
                log.debug("event MOUSEWHEEL {d} {d} {d} {s}\n", .{ ticks_x, ticks_y, event.wheel.which, if (event.wheel.direction == c.SDL_MOUSEWHEEL_FLIPPED) "flipped" else "normal" });
            }

            // macOS dispatches continuous wheel events at the display refresh rate
            // (AppKit syncs scrollWheel: to CVDisplayLink). SDL3's Cocoa_HandleMouseWheel forwards
            // [event scrollingDeltaY] verbatim, so a 120Hz ProMotion display delivers 2× the wheel
            // events per second of a 60Hz display
            //
            // Normalize by 60/refresh_hz on macOS
            const mac_wheel_scale: f32 = if (sdl3 and builtin.os.tag == .macos) blk: {
                const display = c.SDL_GetDisplayForWindow(self.window);
                if (display == 0) break :blk 1.0;
                const mode = c.SDL_GetCurrentDisplayMode(display) orelse break :blk 1.0;
                const hz = mode.*.refresh_rate;
                if (hz <= 0) break :blk 1.0;
                break :blk 60.0 / hz;
            } else 1.0;

            // On macOS we override the magnitude heuristic with the OS-side flag from
            // the NSEvent monitor (see init / macos_monitor.m). Updates per scroll
            // event so users switching between a trackpad and a mouse mid-session get
            // the right classification immediately.
            var mouse_type: dvui.enums.MouseType = .unknown;

            if (sdl3 and builtin.os.tag == .macos) {
                const v = fizzy_native_monitor_last_scroll_precise();
                if (v >= 0) {
                    mouse_type = if (v != 0) .trackpad else .mouse;
                }
            }

            var ret = false;
            // sdl says x positive means to the right, where as y positive
            // means up, so we negate x so that down and right match
            if (ticks_x != 0) {
                if (mouse_type == .unknown) {
                    const min = win.mouseWheelBatch(.horizontal, ticks_x);
                    mouse_type = if (min == 1.0) .mouse else .trackpad;
                }
                ret = try win.addEventMouseWheel(-ticks_x * dvui.scroll_speed * mac_wheel_scale, .horizontal, mouse_type);
            }
            if (ticks_y != 0) {
                if (mouse_type == .unknown) {
                    const min = win.mouseWheelBatch(.vertical, ticks_y);
                    mouse_type = if (min == 1.0) .mouse else .trackpad;
                }
                ret = try win.addEventMouseWheel(ticks_y * dvui.scroll_speed * mac_wheel_scale, .vertical, mouse_type);
            }
            return ret;
        },
        if (sdl3) c.SDL_EVENT_FINGER_DOWN else c.SDL_FINGERDOWN => {
            if (self.log_events) {
                log.debug("event FINGERDOWN {d} {d} {d}\n", .{ if (sdl3) event.tfinger.fingerID else event.tfinger.fingerId, event.tfinger.x, event.tfinger.y });
            }

            return try win.addEventPointer(.{ .button = .touch0, .action = .press, .xynorm = .{ .x = event.tfinger.x, .y = event.tfinger.y } });
        },
        if (sdl3) c.SDL_EVENT_FINGER_UP else c.SDL_FINGERUP => {
            if (self.log_events) {
                log.debug("event FINGERUP {d} {d} {d}\n", .{ if (sdl3) event.tfinger.fingerID else event.tfinger.fingerId, event.tfinger.x, event.tfinger.y });
            }

            return try win.addEventPointer(.{ .button = .touch0, .action = .release, .xynorm = .{ .x = event.tfinger.x, .y = event.tfinger.y } });
        },
        if (sdl3) c.SDL_EVENT_FINGER_MOTION else c.SDL_FINGERMOTION => {
            if (self.log_events) {
                log.debug("event FINGERMOTION {d} {d} {d} {d} {d}\n", .{ if (sdl3) event.tfinger.fingerID else event.tfinger.fingerId, event.tfinger.x, event.tfinger.y, event.tfinger.dx, event.tfinger.dy });
            }

            return try win.addEventTouchMotion(.touch0, event.tfinger.x, event.tfinger.y, event.tfinger.dx, event.tfinger.dy);
        },
        if (sdl3) c.SDL_EVENT_WINDOW_FOCUS_GAINED else c.SDL_WINDOWEVENT_FOCUS_GAINED => {
            if (self.log_events) {
                log.debug("event FOCUS_GAINED\n", .{});
            }
            if (dvui.accesskit_enabled and builtin.os.tag == .linux) {
                dvui.AccessKit.c.accesskit_unix_adapter_update_window_focus_state(win.accesskit.adapter, true);
            } else if (dvui.accesskit_enabled and builtin.os.tag == .macos) {
                const events = dvui.AccessKit.c.accesskit_macos_subclassing_adapter_update_view_focus_state(win.accesskit.adapter, true);
                if (events) |evts| {
                    dvui.AccessKit.c.accesskit_macos_queued_events_raise(evts);
                }
            }
            return false;
        },
        if (sdl3) c.SDL_EVENT_WINDOW_FOCUS_LOST else c.SDL_WINDOWEVENT_FOCUS_LOST => {
            if (self.log_events) {
                log.debug("event FOCUS_LOST\n", .{});
            }
            if (dvui.accesskit_enabled and builtin.os.tag == .linux) {
                dvui.AccessKit.c.accesskit_unix_adapter_update_window_focus_state(win.accesskit.adapter, false);
            } else if (dvui.accesskit_enabled and builtin.os.tag == .macos) {
                const events = dvui.AccessKit.c.accesskit_macos_subclassing_adapter_update_view_focus_state(win.accesskit.adapter, false);
                if (events) |evts| {
                    dvui.AccessKit.c.accesskit_macos_queued_events_raise(evts);
                }
            }
            return false;
        },
        if (sdl3) c.SDL_EVENT_WINDOW_SHOWN else c.SDL_WINDOWEVENT_SHOWN => {
            if (self.log_events) {
                log.debug("event WINDOW_SHOWN\n", .{});
            }
            if (comptime sdl3) {
                self.trackGeometry();
            }
            if (dvui.accesskit_enabled and builtin.os.tag == .linux) {
                var x: i32, var y: i32 = .{ undefined, undefined };
                _ = c.SDL_GetWindowPosition(win.backend.impl.window, &x, &y);
                var w: i32, var h: i32 = .{ undefined, undefined };
                _ = c.SDL_GetWindowSize(win.backend.impl.window, &w, &h);
                var top: i32, var bot: i32, var left: i32, var right: i32 = .{ undefined, undefined, undefined, undefined };
                _ = c.SDL_GetWindowBordersSize(win.backend.impl.window, &top, &left, &bot, &right);
                const outer_bounds: dvui.AccessKit.Rect = .{ .x0 = @floatFromInt(x - left), .y0 = @floatFromInt(y - top), .x1 = @floatFromInt(x + w + right), .y1 = @floatFromInt(y + h + bot) };
                const inner_bounds: dvui.AccessKit.Rect = .{ .x0 = @floatFromInt(x), .y0 = @floatFromInt(y), .x1 = @floatFromInt(x + w), .y1 = @floatFromInt(y + h) };
                dvui.AccessKit.c.accesskit_unix_adapter_set_root_window_bounds(win.accesskit.adapter.?, outer_bounds, inner_bounds);
            }
            return false;
        },
        if (sdl3) c.SDL_EVENT_WINDOW_MOVED else c.SDL_WINDOWEVENT_MOVED, if (sdl3) c.SDL_EVENT_WINDOW_RESIZED else c.SDL_WINDOWEVENT_RESIZED => {
            if (comptime sdl3) {
                self.trackGeometry();
            }
            return false;
        },
        if (sdl3) c.SDL_EVENT_WINDOW_CLOSE_REQUESTED else c.SDL_WINDOWEVENT_CLOSE => {
            if (self.log_events) {
                log.debug("SDL event window close\n", .{});
            }
            try win.addEventWindow(.{ .action = .close });
            return false;
        },
        if (sdl3) c.SDL_EVENT_QUIT else c.SDL_QUIT => {
            if (self.log_events) {
                log.debug("SDL event quit\n", .{});
            }
            try win.addEventApp(.{ .action = .quit });
            return false;
        },
        if (sdl3) c.SDL_EVENT_DROP_FILE else c.SDL_DROPFILE => {
            if (self.log_events) {
                log.debug("SDL event drop file: {s}\n", .{if (sdl3) event.drop.data else event.drop.file});
            }
            return false;
        },
        if (sdl3) c.SDL_EVENT_WINDOW_MOUSE_LEAVE else c.SDL_WINDOWEVENT_LEAVE => {
            if (self.log_events) {
                log.debug("SDL mouse leave window {}\n", .{event.window.windowID});
            }
            try win.addEventWindow(.{ .action = .leave });
            return false;
        },
        else => {
            if (self.log_events) {
                log.debug("unhandled SDL event type {any}\n", .{event.type});
            }
            return false;
        },
    }
}

pub fn SDL_mouse_button_to_dvui(button: u8) dvui.enums.Button {
    return switch (button) {
        c.SDL_BUTTON_LEFT => .left,
        c.SDL_BUTTON_MIDDLE => .middle,
        c.SDL_BUTTON_RIGHT => .right,
        c.SDL_BUTTON_X1 => .four,
        c.SDL_BUTTON_X2 => .five,
        else => blk: {
            log.debug("SDL_mouse_button_to_dvui.unknown button {d}", .{button});
            break :blk .six;
        },
    };
}

pub fn SDL_keymod_to_dvui(keymod: u16) dvui.enums.Mod {
    if (keymod == if (sdl3) c.SDL_KMOD_NONE else c.KMOD_NONE) return dvui.enums.Mod.none;

    var m: u16 = 0;
    if (keymod & (if (sdl3) c.SDL_KMOD_LSHIFT else c.KMOD_LSHIFT) > 0) m |= @intFromEnum(dvui.enums.Mod.lshift);
    if (keymod & (if (sdl3) c.SDL_KMOD_RSHIFT else c.KMOD_RSHIFT) > 0) m |= @intFromEnum(dvui.enums.Mod.rshift);
    if (keymod & (if (sdl3) c.SDL_KMOD_LCTRL else c.KMOD_LCTRL) > 0) m |= @intFromEnum(dvui.enums.Mod.lcontrol);
    if (keymod & (if (sdl3) c.SDL_KMOD_RCTRL else c.KMOD_RCTRL) > 0) m |= @intFromEnum(dvui.enums.Mod.rcontrol);
    if (keymod & (if (sdl3) c.SDL_KMOD_LALT else c.KMOD_LALT) > 0) m |= @intFromEnum(dvui.enums.Mod.lalt);
    if (keymod & (if (sdl3) c.SDL_KMOD_RALT else c.KMOD_RALT) > 0) m |= @intFromEnum(dvui.enums.Mod.ralt);
    if (keymod & (if (sdl3) c.SDL_KMOD_LGUI else c.KMOD_LGUI) > 0) m |= @intFromEnum(dvui.enums.Mod.lcommand);
    if (keymod & (if (sdl3) c.SDL_KMOD_RGUI else c.KMOD_RGUI) > 0) m |= @intFromEnum(dvui.enums.Mod.rcommand);

    return @as(dvui.enums.Mod, @enumFromInt(m));
}

pub fn SDL_keysym_to_dvui(keysym: i32) dvui.enums.Key {
    return switch (keysym) {
        if (sdl3) c.SDLK_A else c.SDLK_a => .a,
        if (sdl3) c.SDLK_B else c.SDLK_b => .b,
        if (sdl3) c.SDLK_C else c.SDLK_c => .c,
        if (sdl3) c.SDLK_D else c.SDLK_d => .d,
        if (sdl3) c.SDLK_E else c.SDLK_e => .e,
        if (sdl3) c.SDLK_F else c.SDLK_f => .f,
        if (sdl3) c.SDLK_G else c.SDLK_g => .g,
        if (sdl3) c.SDLK_H else c.SDLK_h => .h,
        if (sdl3) c.SDLK_I else c.SDLK_i => .i,
        if (sdl3) c.SDLK_J else c.SDLK_j => .j,
        if (sdl3) c.SDLK_K else c.SDLK_k => .k,
        if (sdl3) c.SDLK_L else c.SDLK_l => .l,
        if (sdl3) c.SDLK_M else c.SDLK_m => .m,
        if (sdl3) c.SDLK_N else c.SDLK_n => .n,
        if (sdl3) c.SDLK_O else c.SDLK_o => .o,
        if (sdl3) c.SDLK_P else c.SDLK_p => .p,
        if (sdl3) c.SDLK_Q else c.SDLK_q => .q,
        if (sdl3) c.SDLK_R else c.SDLK_r => .r,
        if (sdl3) c.SDLK_S else c.SDLK_s => .s,
        if (sdl3) c.SDLK_T else c.SDLK_t => .t,
        if (sdl3) c.SDLK_U else c.SDLK_u => .u,
        if (sdl3) c.SDLK_V else c.SDLK_v => .v,
        if (sdl3) c.SDLK_W else c.SDLK_w => .w,
        if (sdl3) c.SDLK_X else c.SDLK_x => .x,
        if (sdl3) c.SDLK_Y else c.SDLK_y => .y,
        if (sdl3) c.SDLK_Z else c.SDLK_z => .z,

        c.SDLK_0 => .zero,
        c.SDLK_1 => .one,
        c.SDLK_2 => .two,
        c.SDLK_3 => .three,
        c.SDLK_4 => .four,
        c.SDLK_5 => .five,
        c.SDLK_6 => .six,
        c.SDLK_7 => .seven,
        c.SDLK_8 => .eight,
        c.SDLK_9 => .nine,

        c.SDLK_F1 => .f1,
        c.SDLK_F2 => .f2,
        c.SDLK_F3 => .f3,
        c.SDLK_F4 => .f4,
        c.SDLK_F5 => .f5,
        c.SDLK_F6 => .f6,
        c.SDLK_F7 => .f7,
        c.SDLK_F8 => .f8,
        c.SDLK_F9 => .f9,
        c.SDLK_F10 => .f10,
        c.SDLK_F11 => .f11,
        c.SDLK_F12 => .f12,

        c.SDLK_KP_DIVIDE => .kp_divide,
        c.SDLK_KP_MULTIPLY => .kp_multiply,
        c.SDLK_KP_MINUS => .kp_subtract,
        c.SDLK_KP_PLUS => .kp_add,
        c.SDLK_KP_ENTER => .kp_enter,
        c.SDLK_KP_0 => .kp_0,
        c.SDLK_KP_1 => .kp_1,
        c.SDLK_KP_2 => .kp_2,
        c.SDLK_KP_3 => .kp_3,
        c.SDLK_KP_4 => .kp_4,
        c.SDLK_KP_5 => .kp_5,
        c.SDLK_KP_6 => .kp_6,
        c.SDLK_KP_7 => .kp_7,
        c.SDLK_KP_8 => .kp_8,
        c.SDLK_KP_9 => .kp_9,
        c.SDLK_KP_PERIOD => .kp_decimal,

        c.SDLK_RETURN => .enter,
        c.SDLK_ESCAPE => .escape,
        c.SDLK_TAB => .tab,
        c.SDLK_LSHIFT => .left_shift,
        c.SDLK_RSHIFT => .right_shift,
        c.SDLK_LCTRL => .left_control,
        c.SDLK_RCTRL => .right_control,
        c.SDLK_LALT => .left_alt,
        c.SDLK_RALT => .right_alt,
        c.SDLK_LGUI => .left_command,
        c.SDLK_RGUI => .right_command,
        c.SDLK_MENU => .menu,
        c.SDLK_NUMLOCKCLEAR => .num_lock,
        c.SDLK_CAPSLOCK => .caps_lock,
        c.SDLK_PRINTSCREEN => .print,
        c.SDLK_SCROLLLOCK => .scroll_lock,
        c.SDLK_PAUSE => .pause,
        c.SDLK_DELETE => .delete,
        c.SDLK_HOME => .home,
        c.SDLK_END => .end,
        c.SDLK_PAGEUP => .page_up,
        c.SDLK_PAGEDOWN => .page_down,
        c.SDLK_INSERT => .insert,
        c.SDLK_LEFT => .left,
        c.SDLK_RIGHT => .right,
        c.SDLK_UP => .up,
        c.SDLK_DOWN => .down,
        c.SDLK_BACKSPACE => .backspace,
        c.SDLK_SPACE => .space,
        c.SDLK_MINUS => .minus,
        c.SDLK_EQUALS => .equal,
        c.SDLK_LEFTBRACKET => .left_bracket,
        c.SDLK_RIGHTBRACKET => .right_bracket,
        c.SDLK_BACKSLASH => .backslash,
        c.SDLK_SEMICOLON => .semicolon,
        if (sdl3) c.SDLK_APOSTROPHE else c.SDLK_QUOTE => .apostrophe,
        c.SDLK_COMMA => .comma,
        c.SDLK_PERIOD => .period,
        c.SDLK_SLASH => .slash,
        if (sdl3) c.SDLK_GRAVE else c.SDLK_BACKQUOTE => .grave,

        else => blk: {
            log.debug("SDL_keysym_to_dvui unknown keysym {d}", .{keysym});
            break :blk .unknown;
        },
    };
}

fn getWindowFromEvent(event: *c.SDL_Event) ?*c.SDL_Window {
    if (sdl3) return c.SDL_GetWindowFromEvent(event) else return c.SDL_GetWindowFromID(
        switch (event.type) {
            c.SDL_KEYDOWN, c.SDL_KEYUP, c.SDL_TEXTEDITING, c.SDL_TEXTINPUT, c.SDL_KEYMAPCHANGED => event.key.windowID,
            c.SDL_MOUSEMOTION => event.wheel.windowID,
            c.SDL_MOUSEBUTTONDOWN, c.SDL_MOUSEBUTTONUP => event.button.windowID,
            c.SDL_MOUSEWHEEL => event.wheel.windowID,
            c.SDL_WINDOWEVENT => event.window.windowID,
            // Not windowID field, we just return null so it's handled by "primary" window
            c.SDL_QUIT, c.SDL_DISPLAYEVENT => 0,
            else => blk: {
                log.info("SDL2 event type {any} unknown, will deliver to primary window", .{event.type});
                break :blk 0;
            },
        },
    );
}

pub fn getSDLVersion() std.SemanticVersion {
    if (sdl3) {
        const v: u32 = @bitCast(c.SDL_GetVersion());
        return .{
            .major = @divTrunc(v, 1000000),
            .minor = @mod(@divTrunc(v, 1000), 1000),
            .patch = @mod(v, 1000),
        };
    } else {
        var v: c.SDL_version = .{};
        c.SDL_GetVersion(&v);
        return .{
            .major = @intCast(v.major),
            .minor = @intCast(v.minor),
            .patch = @intCast(v.patch),
        };
    }
}

fn sdlLogCallbackCommon(category: c_int, priority: c_int, message: [*c]const u8) void {
    switch (category) {
        c.SDL_LOG_CATEGORY_APPLICATION => sdlLog(.SDL_APPLICATION, priority, message),
        c.SDL_LOG_CATEGORY_ERROR => sdlLog(.SDL_ERROR, priority, message),
        c.SDL_LOG_CATEGORY_ASSERT => sdlLog(.SDL_ASSERT, priority, message),
        c.SDL_LOG_CATEGORY_SYSTEM => sdlLog(.SDL_SYSTEM, priority, message),
        c.SDL_LOG_CATEGORY_AUDIO => sdlLog(.SDL_AUDIO, priority, message),
        c.SDL_LOG_CATEGORY_VIDEO => sdlLog(.SDL_VIDEO, priority, message),
        c.SDL_LOG_CATEGORY_RENDER => sdlLog(.SDL_RENDER, priority, message),
        c.SDL_LOG_CATEGORY_INPUT => sdlLog(.SDL_INPUT, priority, message),
        c.SDL_LOG_CATEGORY_TEST => sdlLog(.SDL_TEST, priority, message),
        // These are the set of reserved categories that don't have fixed names between sdl2 and sdl3.
        // It's simpler to deal with them as a group because there is no easy way to remove a switch case at comptime
        c.SDL_LOG_CATEGORY_TEST + 1...c.SDL_LOG_CATEGORY_CUSTOM - 1 => if (sdl3 and category == c.SDL_LOG_CATEGORY_GPU)
            sdlLog(.SDL_GPU, priority, message)
        else
            sdlLog(.SDL_RESERVED, priority, message),
        // starting from c.SDL_LOG_CATEGORY_CUSTOM any greater values are all custom categories
        else => sdlLog(.SDL_CUSTOM, priority, message),
    }
}

// `SDL_LogOutputFunction`'s priority parameter is `c_int` in some translate-c outputs and `c_uint`
// in others — varies by SDL major version and platform (e.g. SDL2 on Linux is `c_uint`, SDL3 on
// windows-msvc is `c_int`). Derive the parameter type from the actual cimport type so the callback
// signature matches whatever translate-c emitted for this target/version.
const SdlLogPriorityType = blk: {
    const Opt = @typeInfo(c.SDL_LogOutputFunction);
    const FnPtr = if (Opt == .optional) @typeInfo(Opt.optional.child) else Opt;
    const FnT = @typeInfo(FnPtr.pointer.child).@"fn";
    break :blk FnT.params[2].type.?;
};

fn sdlLogCallback(userdata: ?*anyopaque, category: c_int, priority: SdlLogPriorityType, message: [*c]const u8) callconv(.c) void {
    _ = userdata;
    sdlLogCallbackCommon(category, @intCast(priority), message);
}

fn sdlLog(comptime category: @EnumLiteral(), priority: c_int, message: [*c]const u8) void {
    const logger = std.log.scoped(category);
    switch (priority) {
        c.SDL_LOG_PRIORITY_VERBOSE => logger.debug("VERBOSE: {s}", .{message}),
        c.SDL_LOG_PRIORITY_DEBUG => logger.debug("{s}", .{message}),
        c.SDL_LOG_PRIORITY_INFO => logger.info("{s}", .{message}),
        c.SDL_LOG_PRIORITY_WARN => logger.warn("{s}", .{message}),
        c.SDL_LOG_PRIORITY_ERROR => logger.err("{s}", .{message}),
        c.SDL_LOG_PRIORITY_CRITICAL => logger.err("CRITICAL: {s}", .{message}),
        else => if (sdl3 and priority == c.SDL_LOG_PRIORITY_TRACE)
            logger.debug("TRACE: {s}", .{message})
        else
            logger.err("UNKNOWN: {s}", .{message}),
    }
}

/// This set enables the internal logging of SDL based on the level of std.log (and the SDL_... scopes)
pub fn enableSDLLogging() void {
    if (sdl3) {
        c.SDL_SetLogOutputFunction(&sdlLogCallback, null);
    } else {
        c.SDL_LogSetOutputFunction(&sdlLogCallback, null);
    }
    // Set default log level
    const default_log_level: c.SDL_LogPriority = if (std.log.logEnabled(.debug, .SDLBackend))
        c.SDL_LOG_PRIORITY_VERBOSE
    else if (std.log.logEnabled(.info, .SDLBackend))
        c.SDL_LOG_PRIORITY_INFO
    else if (std.log.logEnabled(.warn, .SDLBackend))
        c.SDL_LOG_PRIORITY_WARN
    else
        c.SDL_LOG_PRIORITY_ERROR;
    if (sdl3) c.SDL_SetLogPriorities(default_log_level) else c.SDL_LogSetAllPriority(default_log_level);

    const categories = [_]struct { c_uint, @EnumLiteral() }{
        .{ c.SDL_LOG_CATEGORY_APPLICATION, .SDL_APPLICATION },
        .{ c.SDL_LOG_CATEGORY_ERROR, .SDL_ERROR },
        .{ c.SDL_LOG_CATEGORY_ASSERT, .SDL_ASSERT },
        .{ c.SDL_LOG_CATEGORY_SYSTEM, .SDL_SYSTEM },
        .{ c.SDL_LOG_CATEGORY_AUDIO, .SDL_AUDIO },
        .{ c.SDL_LOG_CATEGORY_VIDEO, .SDL_VIDEO },
        .{ c.SDL_LOG_CATEGORY_RENDER, .SDL_RENDER },
        .{ c.SDL_LOG_CATEGORY_INPUT, .SDL_INPUT },
        .{ c.SDL_LOG_CATEGORY_TEST, .SDL_TEST },
    } ++ (if (!sdl3) .{} else .{
        .{ c.SDL_LOG_CATEGORY_GPU, .SDL_GPU },
    });
    inline for (categories) |category_data| {
        const category, const scope = category_data;
        inline for (std.options.log_scope_levels) |scope_level| {
            if (scope_level.scope == scope) {
                const log_level: c.SDL_LogPriority = switch (scope_level.level) {
                    .debug => c.SDL_LOG_PRIORITY_VERBOSE,
                    .info => c.SDL_LOG_PRIORITY_INFO,
                    .warn => c.SDL_LOG_PRIORITY_WARN,
                    .err => c.SDL_LOG_PRIORITY_ERROR,
                };
                if (sdl3) c.SDL_SetLogPriority(category, log_level) else c.SDL_LogSetPriority(category, log_level);
                break;
            }
        }
    }
}

/// This is what is run if you are using `dvui.App` with this backend.
pub fn main(main_init: std.process.Init) !u8 {
    dvui.App.main_init = main_init;
    const app = dvui.App.get() orelse return error.DvuiAppNotDefined;

    // You can override these by calling this function with your arguments in dvui.App.config.startFn
    if (sdl3)
        _ = c.SDL_SetAppMetadata("DVUI App Example", "0.1", "com.example.dvui.app");

    if (builtin.os.tag == .windows) { // optional
        // on windows graphical apps have no console, so output goes to nowhere - attach it manually. related: https://github.com/ziglang/zig/issues/4196
        dvui.Backend.Common.windowsAttachConsole() catch {};
    }
    enableSDLLogging();

    if (use_sdl_callbacks) {
        // We are using sdl's callbacks to support rendering during OS resizing.
        // NOTE: iOS also needs this — without it, the classic-main path's pre-loop `initFn`
        // paint runs before UIKit lays out the view, landing on a not-yet-valid drawable
        // (black screen). The callback path ticks per CADisplayLink frame, after layout.

        const init_opts = app.config.get();

        appState.gpa = init_opts.gpa orelse main_init.gpa;
        appState.io = init_opts.io orelse main_init.io;

        // For programs that provide their own entry points instead of relying on SDL's main function
        // macro magic, 'SDL_SetMainReady()' should be called before calling 'SDL_Init()'.
        c.SDL_SetMainReady();

        // This is more or less what 'SDL_main.h' does behind the curtains.
        const status = c.SDL_EnterAppMainCallbacks(0, null, appInit, appIterate, appEvent, appQuit);

        return @bitCast(@as(i8, @truncate(status)));
    }

    log.info("version: {f} no callbacks", .{getSDLVersion()});

    const init_opts = app.config.get();

    // init SDL backend (creates and owns OS window)
    var back = try initWindow(.{
        .io = init_opts.io orelse main_init.io,
        .environ_map = main_init.environ_map,
        .size = init_opts.size,
        .min_size = init_opts.min_size,
        .max_size = init_opts.max_size,
        .vsync = init_opts.vsync,
        .title = init_opts.title,
        .org = init_opts.org,
        .icon = init_opts.icon,
        .hidden = init_opts.hidden,
        .transparent = init_opts.transparent,
        .persist_window_geometry = init_opts.persist_window_geometry,
        .pref_path = init_opts.pref_path,
    });
    defer back.deinit();

    if (sdl3) {
        toErr(c.SDL_EnableScreenSaver(), "SDL_EnableScreenSaver in sdl main") catch {};
    } else {
        c.SDL_EnableScreenSaver();
    }

    //// init dvui Window (maps onto a single OS window)
    var win = try dvui.Window.init(@src(), main_init.gpa, back.backend(), init_opts.window_init_options);
    defer win.deinit();

    if (init_opts.window_init_options.open_flag != null)
        dvui.log.warn("`open_flag` option has no effect in dvui App. It is managed internally in that case.", .{});
    var window_open = true;
    win.open_flag = &window_open;

    if (app.initFn) |initFn| {
        try win.begin(win.frame_time_ns);
        try initFn(&win);
        _ = try win.end(.{});
    }
    defer if (app.deinitFn) |deinitFn| deinitFn(&win);

    var interrupted = false;

    main_loop: while (window_open) {
        // beginWait coordinates with waitTime below to run frames only when needed
        const nstime = win.beginWait(interrupted);

        // marks the beginning of a frame for dvui, can call dvui functions after this
        try win.begin(nstime);

        // send all SDL events to dvui for processing
        try back.addAllEvents(&win);

        const res = try app.frameFn();

        const end_micros = try win.end(.{});

        if (res != .ok) break :main_loop;

        const wait_event_micros = win.waitTime(end_micros);
        interrupted = try back.waitEventTimeout(wait_event_micros);
    }

    return 0;
}

/// used when doing sdl callbacks
const CallbackState = struct {
    win: dvui.Window,
    back: SDLBackend,
    gpa: std.mem.Allocator,
    io: std.Io,
    window_open: bool = true,
    interrupted: bool = false,
    have_resize: bool = false,
    no_wait: bool = false,
    // iOS: CADisplayLink calls appIterate every vsync regardless, so we throttle
    // ourselves instead of calling SDL_WaitEventTimeout (which stalls in
    // UITrackingRunLoopMode during a touch, see appIterate).
    ios_next_frame_ns: i128 = 0,
    ios_event_pending: bool = false,
    /// What `appInit` got as far as making, so `appQuit` (which SDL calls after a failed init
    /// too) tears down only that.
    back_made: bool = false,
    win_made: bool = false,
};

/// used when doing sdl callbacks
var appState: CallbackState = .{ .win = undefined, .back = undefined, .gpa = undefined, .io = undefined };

// sdl3 callback
fn appInit(appstate: ?*?*anyopaque, argc: c_int, argv: ?[*:null]?[*:0]u8) callconv(.c) c.SDL_AppResult {
    _ = appstate;
    _ = argc;
    _ = argv;
    //_ = c.SDL_SetAppMetadata("dvui-demo", "0.1", "com.example.dvui-demo");

    const app = dvui.App.get() orelse return error.DvuiAppNotDefined;

    log.info("version: {f} callbacks", .{getSDLVersion()});

    const init_opts = app.config.get();

    // init SDL backend (creates and owns OS window)
    appState.back = initWindow(.{
        .io = appState.io,
        .size = init_opts.size,
        .min_size = init_opts.min_size,
        .max_size = init_opts.max_size,
        .vsync = init_opts.vsync,
        .title = init_opts.title,
        .org = init_opts.org,
        .icon = init_opts.icon,
        .hidden = init_opts.hidden,
        .transparent = init_opts.transparent,
        .persist_window_geometry = init_opts.persist_window_geometry,
        .pref_path = init_opts.pref_path,
    }) catch |err| {
        log.err("initWindow failed: {any}", .{err});
        return c.SDL_APP_FAILURE;
    };
    appState.back_made = true;

    if (sdl3) {
        toErr(c.SDL_EnableScreenSaver(), "SDL_EnableScreenSaver in sdl main") catch {};
    } else {
        c.SDL_EnableScreenSaver();
    }

    //// init dvui Window (maps onto a single OS window)
    appState.win = dvui.Window.init(@src(), appState.gpa, appState.back.backend(), init_opts.window_init_options) catch |err| {
        log.err("dvui.Window.init failed: {any}", .{err});
        return c.SDL_APP_FAILURE;
    };
    appState.win_made = true;
    appState.window_open = true;
    if (init_opts.window_init_options.open_flag != null)
        dvui.log.warn("`open_flag` option has no effect in dvui App. It is managed internally in that case.", .{});
    appState.win.open_flag = &appState.window_open;

    if (app.initFn) |initFn| {
        appState.win.begin(appState.win.frame_time_ns) catch |err| {
            log.err("dvui.Window.begin failed: {any}", .{err});
            return c.SDL_APP_FAILURE;
        };

        initFn(&appState.win) catch |err| {
            log.err("dvui.App.initFn failed: {any}", .{err});
            return c.SDL_APP_FAILURE;
        };

        _ = appState.win.end(.{}) catch |err| {
            log.err("dvui.Window.end failed: {any}", .{err});
            return c.SDL_APP_FAILURE;
        };
    }

    return c.SDL_APP_CONTINUE;
}

// sdl3 callback
// This function runs once at shutdown.
fn appQuit(_: ?*anyopaque, result: c.SDL_AppResult) callconv(.c) void {
    _ = result;

    const app = dvui.App.get() orelse unreachable;
    if (appState.win_made) {
        if (app.deinitFn) |deinitFn| deinitFn(&appState.win);
        appState.win.deinit();
    }
    if (appState.back_made) appState.back.deinit();

    // SDL will clean up the window/renderer for us.
}

// sdl3 callback
// This function runs when a new event (mouse input, keypresses, etc) occurs.
fn appEvent(_: ?*anyopaque, event: ?*c.SDL_Event) callconv(.c) c.SDL_AppResult {
    if (builtin.target.os.tag == .ios) appState.ios_event_pending = true;
    if (event.?.type == c.SDL_EVENT_USER) {
        // SDL3 says this function might be called on whatever thread pushed
        // the event.  Events from SDL itself are always on the main thread.
        // EVENT_USER is what we use from other threads to wake dvui up, so to
        // prevent concurrent access return early.
        return c.SDL_APP_CONTINUE;
    }

    const e = &event.?.*;
    const target_sdl_window = getWindowFromEvent(e);
    appState.back.noteMainForward(target_sdl_window, e.type);
    if (target_sdl_window) |target_win| {
        _ = appState.back.addEventWinRecursive(e, &appState.win, target_win) catch |err| {
            log.err("dvui.Window.addEvent failed: {any}", .{err});
            return c.SDL_APP_FAILURE;
        };
    } else {
        _ = appState.back.addEvent(&appState.win, e.*) catch |err| {
            log.err("dvui.Window.addEvent failed: {any}", .{err});
            return c.SDL_APP_FAILURE;
        };
    }

    switch (event.?.type) {
        c.SDL_EVENT_WINDOW_RESIZED => {
            //std.debug.print("resize {d}x{d}\n", .{e.window.data1, e.window.data2});
            // getting a resize event means we are likely in a callback, so don't call any wait functions
            appState.have_resize = true;
        },
        else => {},
    }

    return c.SDL_APP_CONTINUE;
}

// sdl3 callback
// This function runs once per frame, and is the heart of the program.
fn appIterate(_: ?*anyopaque) callconv(.c) c.SDL_AppResult {
    // iOS: CADisplayLink drives this every vsync no matter what.  Skip doing
    // any work (and presenting) until dvui's own wait time has elapsed, unless
    // a real event came in that needs a prompt response.
    if (builtin.target.os.tag == .ios) {
        if (!appState.ios_event_pending and appState.win.backend.nanoTime() < appState.ios_next_frame_ns) {
            return c.SDL_APP_CONTINUE;
        }
        appState.ios_event_pending = false;
    }

    const trace = live_resize_trace.begin(&appState.back);

    // beginWait coordinates with waitTime below to run frames only when needed
    const nstime = appState.win.beginWait(appState.interrupted or appState.no_wait);

    // marks the beginning of a frame for dvui, can call dvui functions after this
    appState.win.begin(nstime) catch |err| {
        log.err("dvui.Window.begin failed: {any}", .{err});
        return c.SDL_APP_FAILURE;
    };

    const app = dvui.App.get() orelse unreachable;
    var res = app.frameFn() catch |err| {
        log.err("dvui.App.frameFn failed: {any}", .{err});
        return c.SDL_APP_FAILURE;
    };

    live_resize_trace.overlay();

    const end_micros = appState.win.end(.{ .manage_backend = false }) catch |err| {
        log.err("dvui.Window.end failed: {any}", .{err});
        return c.SDL_APP_FAILURE;
    };

    // check if window got quit/close event
    if (!appState.window_open) res = .close;

    appState.back.setCursor(appState.win.cursorRequested());
    appState.back.textInputRect(appState.win.textInputRequested());
    appState.back.renderPresent();

    if (res != .ok) return c.SDL_APP_SUCCESS;

    const wait_event_micros = appState.win.waitTime(end_micros);
    if (trace) |t| live_resize_trace.end(t, &appState.back, wait_event_micros);

    const in_live_resize = appState.back.inLiveResize();
    if (in_live_resize) appState.back.liveResizeNextFrame(&appState.win, wait_event_micros);

    //std.debug.print("waitEventTimeout {d} {} resize {}\n", .{wait_event_micros, gno_wait, ghave_resize});

    // If a resize event happens we are likely in a callback.  If for any
    // reason we are called nested while waiting in the below waitEventTimeout
    // we are in a callback.
    //
    // During a callback we don't want to call SDL_WaitEvent or
    // SDL_WaitEventTimeout.  Otherwise all event handling gets screwed up and
    // either never recovers or recovers after many seconds.
    // A frame inside a macOS live resize is always one: SDL's timer runs it from
    // AppKit's tracking loop while the pointer rests, with no resize event to
    // say so, and a wait there takes the tracking loop's own mouse events.
    // NOTE: on iOS, SDL_WaitEventTimeout stalls in UITrackingRunLoopMode during a
    // touch, so we throttle via ios_next_frame_ns above instead of waiting here.
    if (appState.no_wait or appState.have_resize or in_live_resize or builtin.target.os.tag == .ios) {
        appState.have_resize = false;
        if (builtin.target.os.tag == .ios) {
            appState.ios_next_frame_ns = appState.win.backend.nanoTime() + @as(i128, wait_event_micros) * 1000;
        }
        return c.SDL_APP_CONTINUE;
    }

    appState.no_wait = true;
    appState.interrupted = appState.back.waitEventTimeout(wait_event_micros) catch return c.SDL_APP_FAILURE;
    appState.no_wait = false;

    return c.SDL_APP_CONTINUE;
}

test {
    //std.debug.print("{s} backend test\n", .{if (sdl3) "SDL3" else "SDL2"});
    std.testing.refAllDecls(@This());
}

/// What a frame inside a macOS live resize saw, with `FIZZY_LIVE_RESIZE_TRACE` set
/// (`platform/macos/live_resize_trace.m`, `docs/MACOS_LIVE_RESIZE.md`): one line per frame, and a
/// barcode of the frame's own number and drawable size on every frame, which a screen recording
/// decodes (`scripts/live-resize/`) to tell which frame, drawn for which size, reached the screen
/// at the window's size. `src=display` is a frame SDL drew from AppKit's display of the view,
/// presented with the transaction that resizes the window; `src=timer` one from its timer.
const live_resize_trace = struct {
    extern "c" fn fizzy_live_resize_trace_enabled() c_int;
    extern "c" fn fizzy_live_resize_now() f64;
    extern "c" fn fizzy_live_resize_probe(nswindow: *anyopaque, out: *[8]f64) void;

    var frame_number: u16 = 0;
    var last_start: f64 = 0;
    /// The frame's window rect, kept by `overlay` for `end`, which runs after the frame.
    var frame_rect: dvui.Rect.Physical = .{};

    const Start = struct { t: f64, probe: [8]f64 };

    fn enabled() bool {
        if (comptime builtin.os.tag != .macos) return false;
        return fizzy_live_resize_trace_enabled() != 0;
    }

    fn begin(back: *SDLBackend) ?Start {
        if (comptime builtin.os.tag != .macos) return null;
        if (!enabled()) return null;
        frame_number +%= 1;
        const nswindow = cocoaWindow(back.window) orelse return null;
        var p: [8]f64 = undefined;
        fizzy_live_resize_probe(nswindow, &p);
        if (p[7] == 0) return null;
        return .{ .t = fizzy_live_resize_now(), .probe = p };
    }

    fn end(s: Start, back: *SDLBackend, wait_micros: u32) void {
        if (comptime builtin.os.tag != .macos) return;
        const now = fizzy_live_resize_now();
        const r = frame_rect;
        const p = s.probe;
        std.debug.print("[lr] {d:.6} frame {d} src={s} since={d:.1}ms took={d:.1}ms win={d}x{d} layer={d}x{d} drawable={d}x{d} swap={d}x{d} rect={d}x{d} wait={d}us\n", .{
            s.t,                                   frame_number,
            if (p[6] != 0) "display" else "timer", (s.t - last_start) * 1000,
            (now - s.t) * 1000,                    p[0],
            p[1],                                  p[2],
            p[3],                                  p[4],
            p[5],                                  back.gpu.swapchain_w,
            back.gpu.swapchain_h,                  r.w,
            r.h,                                   wait_micros,
        });
        last_start = s.t;
    }

    /// 50 blocks, 8x16 physical px, from (24, 160): red, 16 bits of frame number, 16 of the
    /// drawable's width, 16 of its height (MSB first, white 1, black 0), red. And 6 px bars on the
    /// left (cyan), right (magenta), top and bottom (yellow) edges, which the layer's gravity keeps
    /// at the window's edges whatever size the frame was drawn for.
    fn overlay() void {
        if (!enabled()) return;
        const r = dvui.windowRectPixels();
        frame_rect = r;
        const bw: f32 = 8;
        const bh: f32 = 16;
        const x0: f32 = 24;
        const y0: f32 = 160;
        const red: dvui.Color = .{ .r = 255, .g = 0, .b = 0 };
        const fields = [3]u16{ frame_number, @intFromFloat(r.w), @intFromFloat(r.h) };
        var i: usize = 0;
        while (i < 50) : (i += 1) {
            const color: dvui.Color = if (i == 0 or i == 49) red else blk: {
                const bit = i - 1;
                const v = fields[bit / 16];
                const on = (v >> @intCast(15 - bit % 16)) & 1 == 1;
                break :blk if (on) .{ .r = 255, .g = 255, .b = 255 } else .{ .r = 0, .g = 0, .b = 0 };
            };
            const rect: dvui.Rect.Physical = .{ .x = x0 + @as(f32, @floatFromInt(i)) * bw, .y = y0, .w = bw, .h = bh };
            rect.fill(.all(0), .{ .color = .{ .color = color } });
        }
        const cyan: dvui.Color = .{ .r = 0, .g = 255, .b = 255 };
        const magenta: dvui.Color = .{ .r = 255, .g = 0, .b = 255 };
        const yellow: dvui.Color = .{ .r = 255, .g = 255, .b = 0 };
        (dvui.Rect.Physical{ .x = 0, .y = 100, .w = 6, .h = r.h - 200 }).fill(.all(0), .{ .color = .{ .color = cyan } });
        (dvui.Rect.Physical{ .x = r.w - 6, .y = 100, .w = 6, .h = r.h - 200 }).fill(.all(0), .{ .color = .{ .color = magenta } });
        (dvui.Rect.Physical{ .x = 200, .y = 0, .w = r.w - 400, .h = 6 }).fill(.all(0), .{ .color = .{ .color = yellow } });
        (dvui.Rect.Physical{ .x = 200, .y = r.h - 6, .w = r.w - 400, .h = 6 }).fill(.all(0), .{ .color = .{ .color = yellow } });
    }
};
