//! Windows composition spike (docs/WINDOWS_LINUX_GLASS_PLAN.md, "Order of work" step 5). See
//! README.md for what each mode asks and how to read what it shows.
//!
//! An SDL window made transparent and claimed for SDL_GPU on D3D12, so fizzyedit/SDL presents it
//! through a topmost DirectComposition target, as fizzy's windows are. Under that, on the same
//! window, a Windows.UI.Composition target that is not topmost, holding one sprite: the host
//! backdrop (a blur of what is behind the window), cut to a moving shape. The app draws the
//! shape's rim in its own present; the blur is a composition property; how the two line up is the
//! point.
const std = @import("std");
const builtin = @import("builtin");
const c = @import("sdl3-c");
const win32 = @import("win32");
const winrt = @import("winrt.zig");
const comp = @import("comp.zig");
const geometry = @import("geometry.zig");
const surface = @import("surface.zig");
const effect = @import("effect.zig");
const Overlay = @import("overlay.zig");
const u = @import("user32.zig");

comptime {
    if (builtin.os.tag != .windows) @compileError("the composition spike is Windows only: -Dtarget=x86_64-windows-gnu or aarch64-windows-gnu");
}

pub const std_options: std.Options = .{ .log_level = .info };
const log = std.log.scoped(.spike);

const Mode = enum {
    /// The backdrop over the whole window: does the tree show under SDL's target at all (spike 1)?
    full,
    /// A rounded-rect clip, its edges set each frame: the cheap case, a card or tab.
    rect,
    /// A Direct2D path rebuilt each frame (pill ∪ circle) as a geometric clip (spike 2).
    path,
    /// The backdrop masked through an effect graph by a swapchain the app presents (spike 3).
    mask,
    /// As `path`, with the app's picture hosted in this tree instead of SDL's target: spike 1's
    /// fallback, should the two targets not share the window.
    hosted,
};

const Timing = enum {
    /// Composition properties set, then the present: as Avalonia does.
    before,
    /// Set, then the thread's messages dispatched (the DispatcherQueue commits), then the present.
    pump,
    /// The present, then the properties: one frame behind on purpose, for comparison.
    after,
};

const State = struct {
    mode: Mode = .path,
    timing: Timing = .pump,
    merged: bool = true,
    use_backdrop: bool = true,
    translucent: bool = false,
    paused: bool = false,
    /// Pixels a second the pill travels, at a constant speed between its turns, so that an offset
    /// between the rim and the glass divides by the pixels a frame into frames.
    speed: f32 = 600,
    /// How far it has travelled, and the circle's angle.
    travel: f32 = 0,
    phase: f32 = 0,
    overlay_variant: ?Overlay.Variant = null,
    /// SDL_GPU's frames in flight (SDL's default is 2): how far the present trails its submit.
    frames_in_flight: u32 = 2,
    /// The composition side gets the shape from this many frames ago, to land with the present.
    clip_delay: u32 = 0,
};

fn envEnum(comptime E: type, name: [*:0]const u8) ?E {
    const v = std.c.getenv(name) orelse return null;
    return std.meta.stringToEnum(E, std.mem.span(v));
}

fn envNumber(name: [*:0]const u8) ?f32 {
    const v = std.c.getenv(name) orelse return null;
    return std.fmt.parseFloat(f32, std.mem.span(v)) catch null;
}

pub fn main() !void {
    var st: State = .{};
    if (envEnum(Mode, "SPIKE_MODE")) |m| st.mode = m;
    if (envEnum(Timing, "SPIKE_TIMING")) |t| st.timing = t;
    if (envEnum(Overlay.Variant, "SPIKE_OVERLAY")) |v| st.overlay_variant = v;
    if (envNumber("SPIKE_SPEED")) |v| st.speed = v;
    if (std.c.getenv("SPIKE_SINGLE") != null) st.merged = false;
    if (envNumber("SPIKE_FRAMES_IN_FLIGHT")) |v| st.frames_in_flight = @intFromFloat(v);
    if (envNumber("SPIKE_CLIP_DELAY")) |v| st.clip_delay = @intFromFloat(v);
    st.translucent = std.c.getenv("SPIKE_TRANSLUCENT") != null;
    if (std.c.getenv("SPIKE_COLOR") != null) st.use_backdrop = false;
    const run_seconds = envNumber("SPIKE_SECONDS");

    const queue_controller = try winrt.initThread();
    _ = queue_controller;

    // SDL3 is DPI aware: pixel sizes below (`SDL_GetWindowSizeInPixels`, the swapchain's) are the
    // units composition's desktop target uses too.
    if (!c.SDL_Init(c.SDL_INIT_VIDEO)) return sdlError("SDL_Init");
    const window = c.SDL_CreateWindow("fizzy composition spike", 1000, 640, c.SDL_WINDOW_TRANSPARENT | c.SDL_WINDOW_HIGH_PIXEL_DENSITY) orelse return sdlError("SDL_CreateWindow");
    const hwnd: u.HWND = @ptrCast(c.SDL_GetPointerProperty(c.SDL_GetWindowProperties(window), c.SDL_PROP_WINDOW_WIN32_HWND_POINTER, null) orelse return error.NoHwnd);
    const gpu = c.SDL_CreateGPUDevice(c.SDL_GPU_SHADERFORMAT_DXIL, false, "direct3d12") orelse return sdlError("SDL_CreateGPUDevice");
    if (!c.SDL_ClaimWindowForGPUDevice(gpu, window)) return sdlError("SDL_ClaimWindowForGPUDevice");
    if (!c.SDL_SetGPUAllowedFramesInFlight(gpu, st.frames_in_flight)) return sdlError("SDL_SetGPUAllowedFramesInFlight");
    // SDL's present mode: VSYNC (fizzy's), or MAILBOX / IMMEDIATE where the swapchain supports them.
    if (std.c.getenv("SPIKE_PRESENT")) |v| {
        const name = std.mem.span(v);
        const mode: c.SDL_GPUPresentMode = if (std.mem.eql(u8, name, "mailbox")) c.SDL_GPU_PRESENTMODE_MAILBOX else if (std.mem.eql(u8, name, "immediate")) c.SDL_GPU_PRESENTMODE_IMMEDIATE else c.SDL_GPU_PRESENTMODE_VSYNC;
        log.info("present mode {s}: supported {}, set {}", .{ name, c.SDL_WindowSupportsGPUPresentMode(gpu, window, mode), c.SDL_SetGPUSwapchainParameters(gpu, window, c.SDL_GPU_SWAPCHAINCOMPOSITION_SDR, mode) });
    }
    if (st.translucent) {
        _ = c.SDL_SetWindowOpacity(window, 0.6);
        log.info("spike 4b: SDL_SetWindowOpacity(0.6) -> ex style 0x{x}", .{@as(u32, @truncate(@as(usize, @bitCast(u.GetWindowLongPtrW(hwnd, u.GWL_EXSTYLE)))))});
    }
    log.info("SDL_GPU driver {s}; window transparent, claimed (fizzyedit/SDL presents it through a topmost DirectComposition target)", .{std.mem.span(c.SDL_GetGPUDeviceDriver(gpu))});

    // No DWM system backdrop (the host backdrop is the only material), and permission for it.
    const none: u32 = u.DWMSBT_NONE;
    const yes: u.BOOL = 1;
    log.info("DWM: SYSTEMBACKDROP_TYPE none hr=0x{x}, USE_HOSTBACKDROPBRUSH hr=0x{x}", .{
        @as(u32, @bitCast(u.DwmSetWindowAttribute(hwnd, u.DWMWA_SYSTEMBACKDROP_TYPE, &none, 4))),
        @as(u32, @bitCast(u.DwmSetWindowAttribute(hwnd, u.DWMWA_USE_HOSTBACKDROPBRUSH, &yes, 4))),
    });

    const red = try solidTexture(gpu, .{ 230, 40, 40, 255 });
    const yellow = try solidTexture(gpu, .{ 240, 200, 40, 255 });
    const green = try solidTexture(gpu, .{ 40, 220, 80, 255 });

    // ---- the composition tree under SDL's ----
    const cmp = try comp.Comp.init();
    const tgt = try cmp.desktopTarget(hwnd, false);
    log.info("spike 1: DesktopWindowTarget made on SDL's window, IsTopmost = {} (SDL's DirectComposition target is the topmost one)", .{tgt.topmost});
    const root = try cmp.container();
    try winrt.put(?*anyopaque, tgt.target, winrt.slots.ICompositionTarget.put_Root, root.visual, "put_Root");
    const glass = try cmp.sprite();
    try cmp.insertTop(root.children, glass.visual);
    const backdrop = cmp.hostBackdrop() catch |e| blk: {
        log.err("no host backdrop brush ({s}): a colour stands in", .{@errorName(e)});
        break :blk null;
    };
    const colour = try cmp.colorBrush(.{ .a = 255, .r = 60, .g = 140, .b = 230 });
    const rect_clip = try cmp.rectClip();
    const path_clip = try cmp.pathClip();
    const path_factory = try winrt.factory("Windows.UI.Composition.CompositionPath", &winrt.IID_ICompositionPathFactory);

    const g2 = try surface.Gpu.init();
    log.info("Direct2D/D3D11 for the presented masks and rims: {s}", .{if (g2.warp) "WARP" else "hardware"});

    var w_px: c_int = 0;
    var h_px: c_int = 0;
    _ = c.SDL_GetWindowSizeInPixels(window, &w_px, &h_px);
    const W: f32 = @floatFromInt(w_px);
    const H: f32 = @floatFromInt(h_px);
    try cmp.setSize(glass.visual, W, H);

    // Spike 3 and the hosted picture, made when first asked for.
    var mask: ?Mask = null;
    var hosted: ?Hosted = null;
    var overlay: ?Overlay = null;
    defer if (overlay) |*o| o.close();

    var applied: ?Mode = null;
    var applied_brush: ?bool = null;
    var last_ns = c.SDL_GetTicksNS();
    const start_ns = last_ns;
    var stats: Stats = .{ .since = last_ns };
    var drag_motion: u32 = 0;
    var history: [8]geometry.Shape = undefined;
    var history_at: usize = 0;

    main: while (true) {
        var ev: c.SDL_Event = undefined;
        while (c.SDL_PollEvent(&ev)) switch (ev.type) {
            c.SDL_EVENT_QUIT => break :main,
            c.SDL_EVENT_KEY_DOWN => switch (ev.key.key) {
                c.SDLK_ESCAPE => break :main,
                c.SDLK_1 => st.mode = .full,
                c.SDLK_2 => st.mode = .rect,
                c.SDLK_3 => st.mode = .path,
                c.SDLK_4 => st.mode = .mask,
                c.SDLK_5 => st.mode = .hosted,
                c.SDLK_M => st.merged = !st.merged,
                c.SDLK_F => {
                    st.frames_in_flight = st.frames_in_flight % 3 + 1;
                    _ = c.SDL_SetGPUAllowedFramesInFlight(gpu, st.frames_in_flight);
                },
                c.SDLK_D => st.clip_delay = (st.clip_delay + 1) % 4,
                c.SDLK_T => st.timing = @enumFromInt((@intFromEnum(st.timing) + 1) % 3),
                c.SDLK_B => st.use_backdrop = !st.use_backdrop,
                c.SDLK_SPACE => st.paused = !st.paused,
                c.SDLK_UP => st.speed *= 1.5,
                c.SDLK_DOWN => st.speed /= 1.5,
                c.SDLK_O => {
                    // Spike 4b: SDL makes the window layered for this.
                    st.translucent = !st.translucent;
                    _ = c.SDL_SetWindowOpacity(window, if (st.translucent) 0.6 else 1.0);
                    log.info("spike 4b: SDL_SetWindowOpacity({d}) -> ex style 0x{x}", .{ @as(f32, if (st.translucent) 0.6 else 1.0), @as(u32, @truncate(@as(usize, @bitCast(u.GetWindowLongPtrW(hwnd, u.GWL_EXSTYLE))))) });
                },
                c.SDLK_V => {
                    if (overlay) |*o| o.close();
                    overlay = null;
                    st.overlay_variant = Overlay.Variant.next(st.overlay_variant);
                },
                else => {},
            },
            c.SDL_EVENT_MOUSE_BUTTON_DOWN => log.info("click reached the spike window at {d:.0},{d:.0}", .{ ev.button.x, ev.button.y }),
            c.SDL_EVENT_MOUSE_BUTTON_UP => if (drag_motion > 0) {
                log.info("drag ended: the spike window saw {d} motion events while held", .{drag_motion});
                drag_motion = 0;
            },
            c.SDL_EVENT_MOUSE_MOTION => if (ev.motion.state != 0) {
                drag_motion += 1;
            },
            else => {},
        };
        if (run_seconds) |secs| if (@as(f32, @floatFromInt(c.SDL_GetTicksNS() - start_ns)) / 1e9 > secs) break :main;

        // The overlay, opened for the variant asked.
        if (overlay == null) if (st.overlay_variant) |v| {
            overlay = Overlay.open(&cmp, &g2, v) catch |e| blk: {
                log.err("overlay {s}: {s}", .{ @tagName(v), @errorName(e) });
                st.overlay_variant = null;
                break :blk null;
            };
        };
        if (overlay) |*o| if (try o.update(&cmp)) |hit| log.info("overlay {s}: a click at the pointer goes to {s}", .{ @tagName(o.variant), hit });

        const now = c.SDL_GetTicksNS();
        const dt: f32 = @as(f32, @floatFromInt(now - last_ns)) / 1e9;
        last_ns = now;
        if (!st.paused) {
            st.travel += dt * st.speed;
            st.phase += dt * 2.6;
        }
        const shape = shapeAt(st, W, H);
        // The composition side's shape, `clip_delay` frames old.
        history[history_at % history.len] = shape;
        const clip_shape = history[(history_at + history.len - @min(st.clip_delay, history_at)) % history.len];
        history_at += 1;

        // Brush and clip kind, when the mode or brush changes.
        if (applied != st.mode or applied_brush != st.use_backdrop) {
            const brush = if (st.use_backdrop) (backdrop orelse colour) else colour;
            switch (st.mode) {
                .mask => {
                    if (mask == null) mask = Mask.init(&cmp, &g2, w_px, h_px, brush) catch |e| blk: {
                        log.err("spike 3: {s}", .{@errorName(e)});
                        break :blk null;
                    };
                    if (mask) |*m| {
                        try m.setSource(brush);
                        try winrt.put(?*anyopaque, glass.sprite, winrt.slots.ISpriteVisual.put_Brush, m.brush, "put_Brush (effect)");
                    }
                    try winrt.put(?*anyopaque, glass.visual, winrt.slots.IVisual.put_Clip, null, "put_Clip none");
                },
                else => {
                    try winrt.put(?*anyopaque, glass.sprite, winrt.slots.ISpriteVisual.put_Brush, brush, "put_Brush");
                    const clip: ?*anyopaque = switch (st.mode) {
                        .full => null,
                        .rect => rect_clip.clip,
                        .path, .hosted => path_clip.clip,
                        .mask => unreachable,
                    };
                    try winrt.put(?*anyopaque, glass.visual, winrt.slots.IVisual.put_Clip, clip, "put_Clip");
                },
            }
            if (st.mode == .hosted and hosted == null) hosted = try Hosted.init(&cmp, &g2, root.children, w_px, h_px);
            if (hosted) |*hs| try winrt.put(u8, hs.visual, winrt.slots.IVisual.put_IsVisible, @intFromBool(st.mode == .hosted), "put_IsVisible");
            log.info("mode {s}, brush {s}", .{ @tagName(st.mode), if (st.use_backdrop and backdrop != null) "host backdrop" else "colour" });
            applied = st.mode;
            applied_brush = st.use_backdrop;
        }

        // The app's own frame: SDL draws the rim (nothing in `hosted`, where the hosted picture does).
        const cmd = c.SDL_AcquireGPUCommandBuffer(gpu) orelse return sdlError("SDL_AcquireGPUCommandBuffer");
        var tex: ?*c.SDL_GPUTexture = null;
        var tw: u32 = 0;
        var th: u32 = 0;
        if (!c.SDL_WaitAndAcquireGPUSwapchainTexture(cmd, window, &tex, &tw, &th)) return sdlError("SDL_WaitAndAcquireGPUSwapchainTexture");
        target_w = @floatFromInt(tw);
        target_h = @floatFromInt(th);
        if (tex) |t| {
            clear(cmd, t);
            if (st.mode != .hosted and st.mode != .full) {
                box(cmd, t, red, shape.pill, 2);
                // Which way the pill is going: a mark inside the box at its leading end, for
                // telling a glass that trails the rim from one that leads it.
                const lead_x = if (movingRight(st, W)) shape.pill.right - 14 else shape.pill.left + 6;
                blit(cmd, t, green, lead_x, (shape.pill.top + shape.pill.bottom) / 2 - 4, 8, 8);
                if (st.merged and st.mode != .rect) box(cmd, t, yellow, circleBox(shape), 2);
            }
        }

        if (st.timing != .after) try applyShape(st, &cmp, clip_shape, shape, rect_clip, path_clip, path_factory, &g2, &mask, &hosted);
        if (st.timing == .pump) stats.pumped += u.pump();
        const t0 = c.SDL_GetTicksNS();
        if (!c.SDL_SubmitGPUCommandBuffer(cmd)) return sdlError("SDL_SubmitGPUCommandBuffer");
        stats.submit_ns += c.SDL_GetTicksNS() - t0;
        if (st.timing == .after) try applyShape(st, &cmp, clip_shape, shape, rect_clip, path_clip, path_factory, &g2, &mask, &hosted);

        stats.frames += 1;
        if (now - stats.since >= std.time.ns_per_s) {
            var title: [200]u8 = undefined;
            const fps = @as(f32, @floatFromInt(stats.frames)) * 1e9 / @as(f32, @floatFromInt(now - stats.since));
            const text = std.fmt.bufPrintZ(&title, "spike {s} | timing {s} | in flight {d} | clip delay {d} | {d:.0} fps | {d:.0} px/s | opacity {s} | overlay {s}", .{
                @tagName(st.mode), @tagName(st.timing), st.frames_in_flight, st.clip_delay, fps, st.speed, if (st.translucent) "0.6" else "1", if (st.overlay_variant) |v| @tagName(v) else "off",
            }) catch "spike";
            _ = c.SDL_SetWindowTitle(window, text.ptr);
            log.info("{s} | submit {d:.2} ms avg | {d} messages pumped | geometry: GetGeometry {d}, TryGetGeometryUsingFactory {d}", .{
                text, @as(f32, @floatFromInt(stats.submit_ns)) / 1e6 / @as(f32, @floatFromInt(stats.frames)), stats.pumped, geometry.get_geometry_calls, geometry.try_factory_calls,
            });
            stats = .{ .since = now };
        }
    }
    c.SDL_ReleaseWindowFromGPUDevice(gpu, window);
    c.SDL_DestroyGPUDevice(gpu);
    c.SDL_DestroyWindow(window);
    c.SDL_Quit();
}

const Stats = struct { since: u64, frames: u32 = 0, submit_ns: u64 = 0, pumped: u32 = 0 };

/// Where the glass is at the state's phase: a pill sweeping side to side, a circle orbiting it.
fn shapeAt(st: State, W: f32, H: f32) geometry.Shape {
    const pw: f32 = 300;
    const ph: f32 = 96;
    // Back and forth across the window at a constant speed.
    const span = W - pw - 400;
    const along = @mod(st.travel, 2 * span);
    const cx = 200 + pw / 2 + (if (along < span) along else 2 * span - along);
    const cy = H / 2;
    return .{
        .pill = .{ .left = cx - pw / 2, .top = cy - ph / 2, .right = cx + pw / 2, .bottom = cy + ph / 2 },
        .circle = .{ .x = cx + 150 * @cos(st.phase), .y = cy + 110 * @sin(st.phase) },
        .radius = 46,
        .merged = st.merged,
    };
}

fn movingRight(st: State, W: f32) bool {
    const span = W - 300 - 400;
    return @mod(st.travel, 2 * span) < span;
}

fn circleBox(s: geometry.Shape) @TypeOf(s.pill) {
    return .{ .left = s.circle.x - s.radius, .top = s.circle.y - s.radius, .right = s.circle.x + s.radius, .bottom = s.circle.y + s.radius };
}

/// The composition side of a frame: the clip or mask for `shape` (`clip_delay` frames old), and
/// in `hosted` the app's rim for `now`, the frame's own shape.
fn applyShape(st: State, cmp: *const comp.Comp, shape: geometry.Shape, now: geometry.Shape, rect_clip: comp.Comp.RectClip, path_clip: comp.Comp.PathClip, path_factory: winrt.Obj, g2: *const surface.Gpu, mask: *?Mask, hosted: *?Hosted) !void {
    switch (st.mode) {
        .full => {},
        .rect => {
            const p = shape.pill;
            try cmp.setRectClip(rect_clip.rect, p.left, p.top, p.right, p.bottom, (p.bottom - p.top) / 2);
        },
        .path, .hosted => {
            const geom = try geometry.build(g2.d2dFactory(), shape);
            const src = try geometry.Source.create(geom, g2.d2dFactory());
            defer winrt.release(src.object());
            var path: ?*anyopaque = null;
            try winrt.check(winrt.method(*const fn (winrt.Obj, winrt.Obj, *?*anyopaque) callconv(.winapi) winrt.HRESULT, path_factory, winrt.slots.ICompositionPathFactory.Create)(path_factory, src.object(), &path), "CompositionPath.Create");
            defer winrt.release(path.?);
            try winrt.put(winrt.Obj, path_clip.path_geometry, winrt.slots.ICompositionPathGeometry.put_Path, path.?, "put_Path");
            if (st.mode == .hosted) if (hosted.*) |*hs| try hs.draw(g2, now);
        },
        .mask => if (mask.*) |*m| {
            const geom = try geometry.build(g2.d2dFactory(), shape);
            defer _ = geom.IUnknown.Release();
            try m.surface.draw(&.{.{ .fill = geom }});
        },
    }
}

/// Spike 3: an effect brush, the backdrop masked by a swapchain the app presents.
const Mask = struct {
    surface: surface.Surface,
    brush: winrt.Obj,
    effect_brush: winrt.Obj,

    fn init(cmp: *const comp.Comp, g2: *const surface.Gpu, w: c_int, h: c_int, source: winrt.Obj) !Mask {
        const params = try winrt.factory("Windows.UI.Composition.CompositionEffectSourceParameter", &winrt.IID_ICompositionEffectSourceParameterFactory);
        const backdrop_param = try sourceParameter(params, try winrt.hstring("backdrop"));
        const mask_param = try sourceParameter(params, try winrt.hstring("mask"));

        // D2D AlphaMask (input 0 masked by input 1's alpha); else Composite, SourceIn. Each effect
        // takes a reference to its sources.
        winrt.addRef(backdrop_param);
        winrt.addRef(mask_param);
        var made = tryEffect(cmp, win32.graphics.direct2d.CLSID_D2D1AlphaMask, &.{ backdrop_param, mask_param }, &.{}, "AlphaMask");
        if (made == null) {
            const statics = try winrt.factory("Windows.Foundation.PropertyValue", &winrt.IID_IPropertyValueStatics);
            var boxed: ?*anyopaque = null;
            try winrt.check(winrt.method(*const fn (winrt.Obj, u32, *?*anyopaque) callconv(.winapi) winrt.HRESULT, statics, winrt.slots.IPropertyValueStatics.CreateUInt32)(statics, 2, &boxed), "PropertyValue.CreateUInt32");
            const mode = try winrt.qi(boxed.?, &winrt.IID_IPropertyValue, "QI IPropertyValue");
            winrt.addRef(backdrop_param);
            winrt.addRef(mask_param);
            made = tryEffect(cmp, win32.graphics.direct2d.CLSID_D2D1Composite, &.{ mask_param, backdrop_param }, &.{mode}, "Composite SourceIn");
        }
        const factory = made orelse return error.NoEffect;
        const effect_brush = try winrt.get(factory, winrt.slots.ICompositionEffectFactory.CreateBrush, "CompositionEffectFactory.CreateBrush");

        var s = try surface.Surface.init(g2, @intCast(w), @intCast(h));
        const empty = try geometry.build(g2.d2dFactory(), .{ .pill = .{ .left = 0, .top = 0, .right = 1, .bottom = 1 }, .circle = .{ .x = 0, .y = 0 }, .radius = 0, .merged = false });
        defer _ = empty.IUnknown.Release();
        try s.draw(&.{.{ .fill = empty }});
        const mask_brush = try cmp.swapchainBrush(s.unknown());
        try setParam(effect_brush, "mask", mask_brush);
        try setParam(effect_brush, "backdrop", source);
        log.info("spike 3: effect brush made, the mask a composition surface over a swapchain the app presents", .{});
        return .{ .surface = s, .brush = try winrt.qi(effect_brush, &winrt.IID_ICompositionBrush, "QI ICompositionBrush (effect)"), .effect_brush = effect_brush };
    }

    fn setSource(m: *Mask, source: winrt.Obj) !void {
        try setParam(m.effect_brush, "backdrop", source);
    }

    fn setParam(effect_brush: winrt.Obj, comptime name: []const u8, brush: winrt.Obj) !void {
        try winrt.check(winrt.method(*const fn (winrt.Obj, winrt.HSTRING, winrt.Obj) callconv(.winapi) winrt.HRESULT, effect_brush, winrt.slots.ICompositionEffectBrush.SetSourceParameter)(effect_brush, try winrt.hstring(name), brush), "SetSourceParameter " ++ name);
    }

    fn sourceParameter(params: winrt.Obj, name: winrt.HSTRING) !winrt.Obj {
        var p: ?*anyopaque = null;
        try winrt.check(winrt.method(*const fn (winrt.Obj, winrt.HSTRING, *?*anyopaque) callconv(.winapi) winrt.HRESULT, params, winrt.slots.ICompositionEffectSourceParameterFactory.Create)(params, name, &p), "CompositionEffectSourceParameter.Create");
        return winrt.qi(p.?, &winrt.IID_IGraphicsEffectSource, "QI IGraphicsEffectSource");
    }

    /// An effect factory for the effect, or null with why logged.
    fn tryEffect(cmp: *const comp.Comp, id: winrt.Guid, sources: []const winrt.Obj, props: []const winrt.Obj, what: []const u8) ?winrt.Obj {
        const e = effect.Effect.create(id, sources, props) catch return null;
        defer winrt.release(e.object());
        var factory: ?*anyopaque = null;
        const hr = winrt.method(*const fn (winrt.Obj, winrt.Obj, *?*anyopaque) callconv(.winapi) winrt.HRESULT, cmp.c1, winrt.slots.ICompositor.CreateEffectFactory)(cmp.c1, e.object(), &factory);
        if (hr < 0) {
            log.err("spike 3: CreateEffectFactory({s}) failed, HRESULT 0x{x:0>8}", .{ what, @as(u32, @bitCast(hr)) });
            return null;
        }
        var status: i32 = 0;
        _ = winrt.method(*const fn (winrt.Obj, *i32) callconv(.winapi) winrt.HRESULT, factory.?, winrt.slots.ICompositionEffectFactory.get_LoadStatus)(factory.?, &status);
        var ext: i32 = 0;
        _ = winrt.method(*const fn (winrt.Obj, *i32) callconv(.winapi) winrt.HRESULT, factory.?, winrt.slots.ICompositionEffectFactory.get_ExtendedError)(factory.?, &ext);
        log.info("spike 3: CreateEffectFactory({s}) ok, LoadStatus {d} (0 = success), ExtendedError 0x{x:0>8}", .{ what, status, @as(u32, @bitCast(ext)) });
        return factory;
    }
};

/// Spike 1's fallback: the app's picture (the rim) a swapchain in this tree, above the glass.
const Hosted = struct {
    surface: surface.Surface,
    visual: winrt.Obj,

    fn init(cmp: *const comp.Comp, g2: *const surface.Gpu, children: winrt.Obj, w: c_int, h: c_int) !Hosted {
        const s = try surface.Surface.init(g2, @intCast(w), @intCast(h));
        const sp = try cmp.sprite();
        try winrt.put(?*anyopaque, sp.sprite, winrt.slots.ISpriteVisual.put_Brush, try cmp.swapchainBrush(s.unknown()), "put_Brush (hosted)");
        try cmp.setSize(sp.visual, @floatFromInt(w), @floatFromInt(h));
        try cmp.insertTop(children, sp.visual);
        return .{ .surface = s, .visual = sp.visual };
    }

    fn draw(hs: *Hosted, g2: *const surface.Gpu, shape: geometry.Shape) !void {
        const geom = try geometry.build(g2.d2dFactory(), shape);
        defer _ = geom.IUnknown.Release();
        try hs.surface.draw(&.{.{ .stroke = .{ .geometry = geom, .width = 3, .color = .{ .r = 0.9, .g = 0.15, .b = 0.15, .a = 1 } } }});
    }
};

// ---- SDL_GPU: a clear and solid boxes by blit, no shaders ------------------------------------

fn sdlError(what: []const u8) error{Sdl} {
    log.err("{s}: {s}", .{ what, c.SDL_GetError() });
    return error.Sdl;
}

fn solidTexture(gpu: *c.SDL_GPUDevice, rgba: [4]u8) !*c.SDL_GPUTexture {
    var info = std.mem.zeroes(c.SDL_GPUTextureCreateInfo);
    info.type = c.SDL_GPU_TEXTURETYPE_2D;
    info.format = c.SDL_GPU_TEXTUREFORMAT_R8G8B8A8_UNORM;
    info.usage = c.SDL_GPU_TEXTUREUSAGE_SAMPLER;
    info.width = 1;
    info.height = 1;
    info.layer_count_or_depth = 1;
    info.num_levels = 1;
    const tex = c.SDL_CreateGPUTexture(gpu, &info) orelse return sdlError("SDL_CreateGPUTexture");
    var tbi = std.mem.zeroes(c.SDL_GPUTransferBufferCreateInfo);
    tbi.usage = c.SDL_GPU_TRANSFERBUFFERUSAGE_UPLOAD;
    tbi.size = 4;
    const tb = c.SDL_CreateGPUTransferBuffer(gpu, &tbi) orelse return sdlError("SDL_CreateGPUTransferBuffer");
    defer c.SDL_ReleaseGPUTransferBuffer(gpu, tb);
    const p: [*]u8 = @ptrCast(c.SDL_MapGPUTransferBuffer(gpu, tb, false) orelse return sdlError("SDL_MapGPUTransferBuffer"));
    @memcpy(p[0..4], &rgba);
    c.SDL_UnmapGPUTransferBuffer(gpu, tb);
    const cmd = c.SDL_AcquireGPUCommandBuffer(gpu) orelse return sdlError("SDL_AcquireGPUCommandBuffer");
    const copy = c.SDL_BeginGPUCopyPass(cmd);
    var src = std.mem.zeroes(c.SDL_GPUTextureTransferInfo);
    src.transfer_buffer = tb;
    var dst = std.mem.zeroes(c.SDL_GPUTextureRegion);
    dst.texture = tex;
    dst.w = 1;
    dst.h = 1;
    dst.d = 1;
    c.SDL_UploadToGPUTexture(copy, &src, &dst, false);
    c.SDL_EndGPUCopyPass(copy);
    if (!c.SDL_SubmitGPUCommandBuffer(cmd)) return sdlError("SDL_SubmitGPUCommandBuffer");
    return tex;
}

fn clear(cmd: *c.SDL_GPUCommandBuffer, target: *c.SDL_GPUTexture) void {
    var ct = std.mem.zeroes(c.SDL_GPUColorTargetInfo);
    ct.texture = target;
    ct.load_op = c.SDL_GPU_LOADOP_CLEAR;
    ct.store_op = c.SDL_GPU_STOREOP_STORE;
    const pass = c.SDL_BeginGPURenderPass(cmd, &ct, 1, null);
    c.SDL_EndGPURenderPass(pass);
}

/// The swapchain texture's size this frame, which blits stay inside.
var target_w: f32 = 0;
var target_h: f32 = 0;

fn blit(cmd: *c.SDL_GPUCommandBuffer, target: *c.SDL_GPUTexture, src: *c.SDL_GPUTexture, x: f32, y: f32, w_in: f32, h_in: f32) void {
    const w = @min(w_in, target_w - x);
    const h = @min(h_in, target_h - y);
    if (w <= 0 or h <= 0 or x + w <= 0 or y + h <= 0) return;
    var info = std.mem.zeroes(c.SDL_GPUBlitInfo);
    info.source.texture = src;
    info.source.w = 1;
    info.source.h = 1;
    const x0 = @max(x, 0);
    const y0 = @max(y, 0);
    info.destination.texture = target;
    info.destination.x = @intFromFloat(@round(x0));
    info.destination.y = @intFromFloat(@round(y0));
    info.destination.w = @intFromFloat(@round(w - (x0 - x)));
    info.destination.h = @intFromFloat(@round(h - (y0 - y)));
    info.load_op = c.SDL_GPU_LOADOP_LOAD;
    info.filter = c.SDL_GPU_FILTER_NEAREST;
    c.SDL_BlitGPUTexture(cmd, &info);
}

/// A rectangle's outline, `t` pixels, just outside it.
fn box(cmd: *c.SDL_GPUCommandBuffer, target: *c.SDL_GPUTexture, src: *c.SDL_GPUTexture, r: anytype, t: f32) void {
    blit(cmd, target, src, r.left - t, r.top - t, r.right - r.left + 2 * t, t);
    blit(cmd, target, src, r.left - t, r.bottom, r.right - r.left + 2 * t, t);
    blit(cmd, target, src, r.left - t, r.top, t, r.bottom - r.top);
    blit(cmd, target, src, r.right, r.top, t, r.bottom - r.top);
}
