//! Fixed glass workloads for frame and host-work measurements.
const std = @import("std");
const dvui = @import("dvui");
const core = @import("core");

pub const Config = struct {
    panes: u8,
    w: f32,
    h: f32,
    layer: bool = false,
    list: bool = false,
    virtual: bool = false,
};

/// Parses a grid or list workload; reserved layer and virtual arms use the base drawing.
pub fn parse(s: []const u8) ?Config {
    if (std.mem.startsWith(u8, s, "list:")) {
        var parts = std.mem.splitScalar(u8, s[5..], ':');
        const n = std.fmt.parseInt(u8, parts.next() orelse return null, 10) catch return null;
        if (n == 0) return null;
        var cfg: Config = .{ .panes = n, .w = 350, .h = 72, .list = true };
        if (parts.next()) |suffix| {
            if (!std.mem.eql(u8, suffix, "virtual")) return null;
            cfg.virtual = true;
        }
        if (parts.next() != null) return null;
        return cfg;
    }
    var arms = std.mem.splitScalar(u8, s, ':');
    var parts = std.mem.splitScalar(u8, arms.next() orelse return null, 'x');
    const n = std.fmt.parseInt(u8, parts.next() orelse return null, 10) catch return null;
    const w = std.fmt.parseFloat(f32, parts.next() orelse return null) catch return null;
    const h = std.fmt.parseFloat(f32, parts.next() orelse return null) catch return null;
    if (n == 0 or n > 32 or !std.math.isFinite(w) or !std.math.isFinite(h) or w <= 0 or h <= 0 or parts.next() != null) return null;
    var cfg: Config = .{ .panes = n, .w = w, .h = h };
    if (arms.next()) |suffix| {
        if (!std.mem.eql(u8, suffix, "layer")) return null;
        cfg.layer = true;
    }
    if (arms.next() != null) return null;
    return cfg;
}

/// Draws only when a benchmark was selected. The UI thread owns its frame offset.
pub fn draw(config: ?Config) void {
    const cfg = config orelse return;
    core.profile.want(1000);
    dvui.refresh(null, @src(), null);
    const id = dvui.Id.extendId(null, @src(), 0);
    const frame = dvui.dataGet(null, id, "frame", u32) orelse 0;
    dvui.dataSet(null, id, "frame", frame +% 1);
    const scale = dvui.windowNaturalScale();
    const win = dvui.windowRect();
    const offset: f32 = if (cfg.list) 0 else @floatFromInt((frame *% 2) % 64);
    var y: f32 = -64 + offset;
    var stripe: usize = 0;
    while (y < win.h) : ({
        y += 32;
        stripe += 1;
    }) {
        const r: dvui.Rect.Physical = .{ .x = 0, .y = y * scale, .w = win.w * scale, .h = 32 * scale };
        r.fill(.all(0), .{ .color = .{ .color = dvui.themeGet().color(if (stripe % 2 == 0) .window else .control, .fill) } });
    }
    if (cfg.list) {
        const travel = @max(1, @as(f32, @floatFromInt(cfg.panes)) * 84 - win.h);
        const scroll_y = @mod(@as(f32, @floatFromInt(frame)) * 2, travel);
        var scroll = dvui.scrollArea(@src(), .{ .frame_viewport = .{ .x = 0, .y = scroll_y } }, .{ .rect = .{ .x = 0, .y = 0, .w = win.w, .h = win.h }, .background = false });
        defer scroll.deinit();
        for (0..cfg.panes) |i| {
            var card = dvui.box(@src(), .{}, .{ .id_extra = i, .min_size_content = .{ .w = cfg.w, .h = cfg.h }, .margin = .{ .h = 12 }, .gravity_x = 0.5 });
            const rs = card.data().contentRectScale();
            const corners = core.corners.round(core.corners.card);
            core.dialogs.glassShadow(rs.r, corners, rs.s, core.dialogs.surfaceShadow(), 1);
            _ = core.dialogs.frostPane(dvui.Id.extendId(null, @src(), i), rs.r, corners, rs.s);
            dvui.progress(@src(), .{ .percent = @as(f32, @floatFromInt(i)) / @as(f32, @floatFromInt(cfg.panes)) }, .{ .rect = .{ .x = 0, .y = cfg.h - 6, .w = cfg.w, .h = 6 }, .padding = .all(0), .corners = core.corners.all(core.corners.small) });
            card.deinit();
        }
    } else {
        var x: f32 = 0;
        y = 0;
        for (0..cfg.panes) |i| {
            if (x > 0 and x + cfg.w > win.w) {
                x = 0;
                y += cfg.h + 16;
            }
            _ = core.dialogs.frostPane(dvui.Id.extendId(null, @src(), i), .{ .x = x * scale, .y = y * scale, .w = cfg.w * scale, .h = cfg.h * scale }, core.corners.round(core.corners.card), scale);
            x += cfg.w + 16;
        }
    }
}

test "parse" {
    const cfg = parse("12x350x200").?;
    try std.testing.expectEqual(@as(u8, 12), cfg.panes);
    try std.testing.expectEqual(@as(f32, 350), cfg.w);
    try std.testing.expectEqual(@as(f32, 200), cfg.h);
    try std.testing.expect(!cfg.layer);
    try std.testing.expect(parse("12x350x200:layer").?.layer);
    const list = parse("list:200").?;
    try std.testing.expect(list.list and list.panes == 200 and list.w == 350 and list.h == 72);
    try std.testing.expect(parse("list:200:virtual").?.virtual);
    for ([_][]const u8{ "0x1x1", "x", "", "list:0", "list:256", "1xnanx1", "1x1x1:layer:extra" }) |bad| try std.testing.expectEqual(@as(?Config, null), parse(bad));
}
