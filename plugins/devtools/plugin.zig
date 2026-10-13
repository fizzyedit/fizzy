//! Devtools: where the app's time goes, for a person and an agent alike (plans/DASHBOARD_PLAN.md).
//!
//! One surface, the dashboard (`devtools.dashboard`), a tab in the bottom panel by default and
//! wherever the person drags it after: the frame, the scopes by plugin or as a tree, the last
//! 30 s, the frames over budget, where a frame went as a pie, and the plugins themselves. It is
//! drawn from what any plugin can reach (`core.profile`, `core.viz`, the `plugins` service), which
//! is the point of it being a plugin: an app on fizzy bundles it or leaves it out.
//!
//! The profiler records while the dashboard is on screen (`beginFrame` lets it go the frame
//! after it stops being drawn), so a closed dashboard costs nothing.
//!
//! Commands: `devtools.show` reveals the dashboard wherever it lives; `devtools.stats` answers
//! its numbers as ZON (the profiler's report and the plugins), which is how an agent reads it.
const std = @import("std");
const sdk = @import("fizzy_sdk");
const dvui = @import("dvui");
const core = @import("core");
const Dashboard = @import("src/Dashboard.zig");

/// Injected at build time from `plugin.zig.zon`.
pub const plugin_options = @import("fizzy_plugin_options");
pub const plugin_id = plugin_options.id;

pub const dashboard_id = "devtools.dashboard";

var plugin: sdk.Plugin = .{
    .state = undefined,
    .vtable = &vtable,
    .id = plugin_id,
    .display_name = plugin_options.name,
};

const vtable: sdk.Plugin.VTable = .{
    .beginFrame = beginFrame,
};

var host_ptr: ?*sdk.Host = null;

pub fn register(host: *sdk.Host) !void {
    host_ptr = host;
    plugin.state = @ptrCast(host);
    try host.registerPlugin(&plugin);
    try host.registerSurface(.{
        .id = dashboard_id,
        .owner = &plugin,
        .title = "Devtools",
        .icon = .{ .tvg = dvui.entypo.gauge },
        .keywords = sdk.keywords.ide.panel,
        // Its own scroll area: a short panel scrolls it rather than squeezing the table.
        .scrolls_itself = true,
        .draw = drawDashboard,
    });
    try host.registerCommand(.{
        .id = sdk.Plugin.commandId(plugin_id, "show"),
        .owner = &plugin,
        .title = "Show Profiler",
        .run = cmdShow,
        .icon = dvui.entypo.gauge,
    });
    try host.registerCommand(.{
        .id = sdk.Plugin.commandId(plugin_id, "stats"),
        .owner = &plugin,
        .title = "Profiler Stats",
        // Its answer is ZON for an agent; a person has the dashboard.
        .visibility = .internal,
        .params = Stats.params,
        .runWith = Stats.bind(cmdStats),
    });
}

fn drawDashboard(_: ?*anyopaque) anyerror!dvui.App.Result {
    const host = host_ptr orelse return .ok;
    Dashboard.draw(host);
    return .ok;
}

/// The profiler records while the dashboard was drawn last frame; the frame after it stops being
/// drawn (its tab not selected, its panel shut, the plugin turned off), it stops.
fn beginFrame(_: *anyopaque) void {
    Dashboard.frameBegin();
}

/// "Show Profiler": the dashboard, wherever it lives, its place opened if it was shut.
fn cmdShow(state: *anyopaque) anyerror!void {
    const host: *sdk.Host = @ptrCast(@alignCast(state));
    _ = host.revealSurface(dashboard_id);
}

const Stats = sdk.Command.Params(struct {
    over_ms: sdk.Command.Arg(u32, .{ .description = "Also the costliest scopes over this many milliseconds (at most 30000); 0 leaves them out." }) = .init(30_000),
    top: sdk.Command.Arg(u32, .{ .description = "How many scopes the costliest and each hitch list." }) = .init(10),
    hitches: sdk.Command.Arg(u32, .{ .description = "The newest this many frames over budget, each with its costliest scopes." }) = .init(3),
    spans: sdk.Command.Arg(u32, .{ .description = "The spans kept, summed by name: at most this many names." }) = .init(10),
    causes: sdk.Command.Arg(u32, .{ .description = "Why the frames happened, with at most this many places that asked for them." }) = .init(8),
});

/// The dashboard's numbers as ZON: `.plugins` (the `plugins` service's list) and `.profile`
/// (`core.profile.report`: the frame, owners, scopes, and what the arguments ask for). The
/// profiler holds numbers only while it records: while the dashboard is on screen, or for as long
/// as someone asked (`core.profile.want`, an agent's profile step).
fn cmdStats(state: *anyopaque, args: Stats.Args, call: *sdk.Command.Call) anyerror!void {
    const host: *sdk.Host = @ptrCast(@alignCast(state));
    var out: std.Io.Writer.Allocating = .init(call.arena);
    const w = &out.writer;
    try w.writeAll(".{\n.plugins = ");
    try Dashboard.writePlugins(host, call.arena, w);
    try w.writeAll(",\n.profile = ");
    const p = core.profile.current() orelse return call.fail("the profiler is not running", .{});
    try core.profile.report(p, w, .{
        .over_ms = args.over_ms,
        .top = args.top,
        .hitches = args.hitches,
        .spans = args.spans,
        .causes = args.causes,
    });
    try w.writeAll("}\n");
    call.result = out.written();
}
