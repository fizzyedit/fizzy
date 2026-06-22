//! Host-side thunks for the dvui proxy render bridge.
//!
//! Loaded plugin dylibs draw through `proxy_bridge.RenderBridge` into the shell's real
//! SDL backend. `ctx` is the host `dvui.Window` pointer (stable for the session).
const std = @import("std");
const dvui = @import("dvui");
const proxy_bridge = @import("proxy_bridge");

pub const SetRenderBridgeFn = *const fn (?*const proxy_bridge.RenderBridge) callconv(.c) void;

var table: proxy_bridge.RenderBridge = undefined;
var table_ready = false;

fn emptyTextureDesc() proxy_bridge.TextureDesc {
    return std.mem.zeroes(proxy_bridge.TextureDesc);
}

fn windowFromCtx(ctx: ?*anyopaque) *dvui.Window {
    return @ptrCast(@alignCast(ctx orelse @panic("render bridge ctx is null")));
}

fn textureFromDesc(desc: *const proxy_bridge.TextureDesc) !dvui.Texture {
    return proxy_bridge.textureFromDesc(desc.*);
}

fn targetFromDesc(desc: *const proxy_bridge.TextureDesc) !dvui.TextureTarget {
    return proxy_bridge.targetFromDesc(desc.*);
}

fn clipFromDesc(has_clip: u8, clip: proxy_bridge.ClipRect) ?dvui.Rect.Physical {
    if (has_clip == 0) return null;
    return .{ .x = clip.x, .y = clip.y, .w = clip.w, .h = clip.h };
}

fn drawClippedTriangles(
    ctx: ?*anyopaque,
    texture: ?*const proxy_bridge.TextureDesc,
    vtx: [*]const dvui.Vertex,
    vtx_len: usize,
    idx: [*]const dvui.Vertex.Index,
    idx_len: usize,
    has_clip: u8,
    clip: proxy_bridge.ClipRect,
) callconv(.c) u8 {
    const win = windowFromCtx(ctx);
    const tex: ?dvui.Texture = if (texture) |desc| textureFromDesc(desc) catch return 0 else null;
    win.backend.drawClippedTriangles(
        tex,
        vtx[0..vtx_len],
        idx[0..idx_len],
        clipFromDesc(has_clip, clip),
    ) catch return 0;
    return 1;
}

fn textureCreate(
    ctx: ?*anyopaque,
    pixels: [*]const u8,
    options: proxy_bridge.CreateOptions,
) callconv(.c) proxy_bridge.TextureDesc {
    const win = windowFromCtx(ctx);
    const created = win.backend.textureCreate(pixels, .{
        .width = options.width,
        .height = options.height,
        .format = @enumFromInt(options.format),
        .interpolation = @enumFromInt(options.interpolation),
        .wrap_u = @enumFromInt(options.wrap_u),
        .wrap_v = @enumFromInt(options.wrap_v),
    }) catch return emptyTextureDesc();
    return proxy_bridge.textureDescFrom(created);
}

fn textureUpdate(
    ctx: ?*anyopaque,
    texture: *const proxy_bridge.TextureDesc,
    pixels: [*]const u8,
) callconv(.c) u8 {
    const win = windowFromCtx(ctx);
    const tex = textureFromDesc(texture) catch return 0;
    win.backend.textureUpdate(tex, pixels) catch return 0;
    return 1;
}

fn textureUpdateSubRect(
    ctx: ?*anyopaque,
    texture: *const proxy_bridge.TextureDesc,
    pixels: [*]const u8,
    x: u32,
    y: u32,
    w: u32,
    h: u32,
) callconv(.c) u8 {
    const win = windowFromCtx(ctx);
    const tex = textureFromDesc(texture) catch return 0;
    win.backend.textureUpdateSubRect(tex, pixels, x, y, w, h) catch return 0;
    return 1;
}

fn textureDestroy(ctx: ?*anyopaque, texture: *const proxy_bridge.TextureDesc) callconv(.c) void {
    const win = windowFromCtx(ctx);
    const tex = textureFromDesc(texture) catch return;
    win.backend.textureDestroy(tex);
}

fn textureCreateTarget(ctx: ?*anyopaque, options: proxy_bridge.CreateOptions) callconv(.c) proxy_bridge.TextureDesc {
    const win = windowFromCtx(ctx);
    const target = win.backend.textureCreateTarget(.{
        .width = options.width,
        .height = options.height,
        .format = @enumFromInt(options.format),
        .interpolation = @enumFromInt(options.interpolation),
        .wrap_u = @enumFromInt(options.wrap_u),
        .wrap_v = @enumFromInt(options.wrap_v),
    }) catch return emptyTextureDesc();
    return proxy_bridge.textureDescFromTarget(target);
}

fn textureReadTarget(ctx: ?*anyopaque, target: *const proxy_bridge.TextureDesc, pixels_out: [*]u8) callconv(.c) u8 {
    const win = windowFromCtx(ctx);
    const tex_target = targetFromDesc(target) catch return 0;
    win.backend.textureReadTarget(tex_target, pixels_out) catch return 0;
    return 1;
}

fn textureDestroyTarget(ctx: ?*anyopaque, target: *const proxy_bridge.TextureDesc) callconv(.c) void {
    const win = windowFromCtx(ctx);
    const tex_target = targetFromDesc(target) catch return;
    win.backend.textureDestroyTarget(tex_target);
}

fn textureClearTarget(ctx: ?*anyopaque, target: *const proxy_bridge.TextureDesc) callconv(.c) void {
    const win = windowFromCtx(ctx);
    const tex_target = targetFromDesc(target) catch return;
    win.backend.textureClearTarget(tex_target);
}

fn textureFromTarget(ctx: ?*anyopaque, target: *const proxy_bridge.TextureDesc) callconv(.c) proxy_bridge.TextureDesc {
    const win = windowFromCtx(ctx);
    const tex_target = targetFromDesc(target) catch return emptyTextureDesc();
    const tex = win.backend.textureFromTarget(tex_target) catch return emptyTextureDesc();
    return proxy_bridge.textureDescFrom(tex);
}

fn textureFromTargetTemp(ctx: ?*anyopaque, target: *const proxy_bridge.TextureDesc) callconv(.c) proxy_bridge.TextureDesc {
    const win = windowFromCtx(ctx);
    const tex_target = targetFromDesc(target) catch return emptyTextureDesc();
    const tex = win.backend.textureFromTargetTemp(tex_target) catch return emptyTextureDesc();
    return proxy_bridge.textureDescFrom(tex);
}

fn renderTarget(ctx: ?*anyopaque, target: ?*const proxy_bridge.TextureDesc) callconv(.c) u8 {
    const win = windowFromCtx(ctx);
    const tex_target: ?dvui.TextureTarget = if (target) |desc| targetFromDesc(desc) catch return 0 else null;
    win.backend.renderTarget(tex_target) catch return 0;
    return 1;
}

fn pixelSize(ctx: ?*anyopaque) callconv(.c) proxy_bridge.SizePair {
    const win = windowFromCtx(ctx);
    const size = win.backend.pixelSize();
    return .{ .w = size.w, .h = size.h };
}

fn windowSize(ctx: ?*anyopaque) callconv(.c) proxy_bridge.SizePair {
    const win = windowFromCtx(ctx);
    const size = win.backend.windowSize();
    return .{ .w = size.w, .h = size.h };
}

fn contentScale(ctx: ?*anyopaque) callconv(.c) f32 {
    const win = windowFromCtx(ctx);
    return win.backend.contentScale();
}

threadlocal var clipboard_scratch: [8192]u8 = undefined;

fn clipboardText(ctx: ?*anyopaque) callconv(.c) proxy_bridge.TextSlice {
    const win = windowFromCtx(ctx);
    const text = win.backend.clipboardText() catch return .{ .ptr = &.{}, .len = 0 };
    const len = @min(text.len, clipboard_scratch.len);
    @memcpy(clipboard_scratch[0..len], text[0..len]);
    return .{ .ptr = clipboard_scratch[0..len].ptr, .len = len };
}

fn clipboardTextSet(ctx: ?*anyopaque, text: [*]const u8, text_len: usize) callconv(.c) u8 {
    const win = windowFromCtx(ctx);
    win.backend.clipboardTextSet(text[0..text_len]) catch return 0;
    return 1;
}

fn openURL(ctx: ?*anyopaque, url: [*]const u8, url_len: usize, new_window: u8) callconv(.c) u8 {
    const win = windowFromCtx(ctx);
    win.backend.openURL(url[0..url_len], new_window != 0) catch return 0;
    return 1;
}

fn setCursor(ctx: ?*anyopaque, cursor: u8) callconv(.c) void {
    const win = windowFromCtx(ctx);
    win.backend.setCursor(@enumFromInt(cursor));
}

fn textInputRect(ctx: ?*anyopaque, has_rect: u8, rect: proxy_bridge.ClipRect) callconv(.c) void {
    const win = windowFromCtx(ctx);
    const natural: ?dvui.Rect.Natural = if (has_rect != 0)
        .{ .x = rect.x, .y = rect.y, .w = rect.w, .h = rect.h }
    else
        null;
    win.backend.textInputRect(natural);
}

fn preferredColorScheme(ctx: ?*anyopaque) callconv(.c) i8 {
    const win = windowFromCtx(ctx);
    const scheme = win.backend.preferredColorScheme();
    if (scheme) |s| {
        return switch (s) {
            .light => 0,
            .dark => 1,
        };
    }
    return -1;
}

fn prefersReducedMotion(ctx: ?*anyopaque) callconv(.c) u8 {
    const win = windowFromCtx(ctx);
    return @intFromBool(win.backend.prefersReducedMotion());
}

/// May be called from a plugin's background thread — forwards to the host's real backend
/// (e.g. SDL) to wake its blocking event-wait loop, same as every other thunk here forwards
/// to `win.backend`, just safe to call cross-thread. A single `backend.refresh()` call is
/// sufficient on its own: it wakes the blocked `SDL_WaitEventTimeout` and produces exactly one
/// composited frame (verified via a plugin drawing a bg-thread-driven on-screen counter,
/// screenshotted before/after several wakes with zero real input — frame count advanced by
/// exactly 1 per wake, content updated every time). An earlier multi-frame follow-up/pump
/// dance existed here to work around what looked like dropped/uncomposited wakes, but that
/// symptom traced back to an unrelated dvui SDL backend bug (a 50ms wait cap that pinned the
/// app at a steady low framerate and confused every earlier observation) — once that was
/// fixed, the follow-up machinery no longer had anything to compensate for.
fn refresh(ctx: ?*anyopaque) callconv(.c) void {
    const win = windowFromCtx(ctx);
    win.backend.refresh();
}

fn ensureTable() void {
    if (table_ready) return;
    table = .{
        .ctx = null,
        .draw_clipped_triangles = drawClippedTriangles,
        .texture_create = textureCreate,
        .texture_update = textureUpdate,
        .texture_update_sub_rect = textureUpdateSubRect,
        .texture_destroy = textureDestroy,
        .texture_create_target = textureCreateTarget,
        .texture_read_target = textureReadTarget,
        .texture_destroy_target = textureDestroyTarget,
        .texture_clear_target = textureClearTarget,
        .texture_from_target = textureFromTarget,
        .texture_from_target_temp = textureFromTargetTemp,
        .render_target = renderTarget,
        .pixel_size = pixelSize,
        .window_size = windowSize,
        .content_scale = contentScale,
        .clipboard_text = clipboardText,
        .clipboard_text_set = clipboardTextSet,
        .open_url = openURL,
        .set_cursor = setCursor,
        .text_input_rect = textInputRect,
        .preferred_color_scheme = preferredColorScheme,
        .prefers_reduced_motion = prefersReducedMotion,
        .refresh = refresh,
    };
    table_ready = true;
}

/// Push the host render bridge table into a loaded plugin dylib (once at load).
pub fn syncHostIntoPlugin(setter: SetRenderBridgeFn) void {
    ensureTable();
    table.ctx = @ptrCast(dvui.current_window);
    setter(&table);
}
