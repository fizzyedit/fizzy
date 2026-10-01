//! One surface drawn by a shader of the plugin's own (`core.programs`): liquid metaballs
//! orbiting the pointer, the drop on it trailing on a spring (`core.Spring`). The example for UI
//! effects and games — copy this when a plugin wants to draw with its own GPU program.
//!
//! The program is GLSL against fizzy's prelude (`metaballs.glsl`), compiled by the backend the
//! first time it is drawn. Where the backend has no programs `drawRect` returns false and the
//! surface says so instead: always have something to draw in its place.
const std = @import("std");
const sdk = @import("fizzy_sdk");
const dvui = @import("dvui");
const core = @import("core");

pub const plugin_options = @import("fizzy_plugin_options");
pub const plugin_id = plugin_options.id;

var plugin: sdk.Plugin = .{
    .state = undefined,
    .vtable = &vtable,
    .id = plugin_id,
    .display_name = plugin_options.name,
};

const vtable: sdk.Plugin.VTable = .{};

/// Two vec4s of uniforms: time, size and scale; the pointer.
var metaballs: core.programs.Program = .fromGlsl(@embedFile("metaballs.glsl"), .{ .uniform_vec4s = 2 });

/// Where the drop is, following the pointer.
var drop: core.Spring = .{};
var last_ns: i128 = 0;

pub fn register(host: *sdk.Host) !void {
    plugin.state = @ptrCast(&drop);
    try host.registerPlugin(&plugin);
    try host.registerSurface(.{
        .id = "shader.metaballs",
        .owner = &plugin,
        .icon = .{ .tvg = dvui.entypo.drop },
        .title = "Metaballs",
        .keywords = sdk.keywords.ide.main,
        .draw = draw,
    });
}

fn draw(_: ?*anyopaque) anyerror!dvui.App.Result {
    var box = dvui.box(@src(), .{}, .{ .expand = .both });
    defer box.deinit();
    const rs = box.data().contentRectScale();
    const r = rs.r;
    if (r.w < 1 or r.h < 1) return .ok;

    const now = dvui.frameTimeNS();
    const dt: f32 = if (last_ns == 0) 0 else @as(f32, @floatFromInt(now - last_ns)) / std.time.ns_per_s;
    last_ns = now;
    const mouse = dvui.currentWindow().mouse_pt;
    const aim = if (r.contains(mouse)) mouse else r.center();
    _ = drop.step(aim, dt, .{ .hz = 3, .playful_damping = 0.35 });

    const t: f32 = @floatCast(@as(f64, @floatFromInt(@mod(now, 3600 * std.time.ns_per_s))) / std.time.ns_per_s);
    const drawn = core.programs.drawRect(&metaballs, r, .{ .uniforms = &.{
        .{ t, r.w, r.h, rs.s },
        .{ drop.pos.x - r.x, drop.pos.y - r.y, 0, 0 },
    } });
    if (!drawn) {
        dvui.labelNoFmt(@src(), "This backend draws no custom shaders.", .{}, .{ .gravity_x = 0.5, .gravity_y = 0.5 });
    }
    // It moves by itself: keep frames coming while it is on screen.
    dvui.refresh(null, @src(), box.data().id);
    return .ok;
}
