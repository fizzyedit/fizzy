//! Moving stripes behind separate or joined glass panes, for measuring glass alone.
const std = @import("std");
const dvui = @import("dvui");
const core = @import("core");
const Glass = core.widgets.Glass;

pub const Arm = enum { grid, scene };
pub const Config = struct { arm: Arm, panes: u8 };

/// The benchmark's per-window frame counter and stripe offset live under this id.
pub const data_id = dvui.Id.zero.update("fizzy.glass_bench");

pub fn parse(s: []const u8) ?Config {
    const colon = std.mem.indexOfScalar(u8, s, ':') orelse return null;
    const arm = std.meta.stringToEnum(Arm, s[0..colon]) orelse return null;
    const digits = s[colon + 1 ..];
    if (digits.len == 0) return null;
    for (digits) |c| if (!std.ascii.isDigit(c)) return null;
    const panes = std.fmt.parseInt(u8, digits, 10) catch return null;
    if (panes < 1 or panes > 64) return null;
    return .{ .arm = arm, .panes = panes };
}

pub fn draw(cfg: Config) void {
    dvui.refresh(null, @src(), data_id);
    const frame = dvui.dataGet(null, data_id, "frame", u64) orelse 0;
    dvui.dataSet(null, data_id, "frame", frame +% 1);
    const stripe_height: f32 = 32;
    const offset: f32 = @floatFromInt((frame % 32) * 2);
    dvui.dataSet(null, data_id, "stripe_offset", offset);
    const rs = dvui.parentGet().screenRectScale(.{});
    const window = rs.rectFromPhysical(dvui.windowRectPixels());
    var y = offset - stripe_height * 2;
    var stripe: usize = 0;
    while (y < window.h) : ({
        y += stripe_height;
        stripe += 1;
    }) {
        const rect: dvui.Rect = .{ .x = 0, .y = y, .w = window.w, .h = stripe_height };
        rs.rectToPhysical(rect).fill(.{}, .{ .color = .{ .color = dvui.themeGet().color(if (stripe % 2 == 0) .window else .control, .fill) } });
    }

    const gap: f32 = if (cfg.arm == .scene) 8 else 16;
    const width: f32 = 160;
    const height: f32 = 96;
    const columns: usize = @intFromFloat(@max(1, @floor((window.w - gap) / (width + gap))));
    var layer: core.glass.Layer = .{};
    if (cfg.arm == .scene) layer = core.glass.layer(data_id, .{ .merge = 12 });
    defer layer.end();
    for (0..cfg.panes) |i| {
        const rect: dvui.Rect = .{
            .x = gap + @as(f32, @floatFromInt(i % columns)) * (width + gap),
            .y = gap + @as(f32, @floatFromInt(i / columns)) * (height + gap),
            .w = width,
            .h = height,
        };
        var pane = Glass.init(@src(), if (cfg.arm == .scene) .{ .group = 1 } else .{}, .{
            .id_extra = i,
            .rect = rect,
            .margin = .{},
            .padding = .{},
        });
        pane.install();
        pane.deinit();
    }
}
