//! Growing glass keeps one capture: the library's own growing glass passes its final size as
//! reach (`BlurBackdrop.Pane.reach`), so each new bucket size never makes new render targets.
const std = @import("std");
const dvui = @import("dvui");
const glass = @import("../glass.zig");
const backend = @import("glass");
const widgets = @import("../widgets.zig");
const Glass = @import("Glass.zig");
const Spring = @import("../Spring.zig");
const expect = std.testing.expect;

var grow_from: ?dvui.Rect.Natural = null;
var id: dvui.Id = .zero;
var moving = false;

fn glassFrame() void {
    const scale = dvui.windowNaturalScale();
    var g = Glass.init(@src(), .{ .morph = .{ .from = .{ .x = 700, .y = 20, .w = 40, .h = 40 } } }, .{
        .rect = (dvui.Rect.Physical{ .x = 140, .y = 60, .w = 600, .h = 800 }).scale(1 / scale, dvui.Rect),
        .corners = .round(24 / scale),
        .margin = .{},
        .padding = .{},
    });
    g.install();
    id = g.data().id;
    moving = if (dvui.dataGet(null, id, "_morph", glass.Morph)) |m| m.center.moving or m.size.moving else false;
    g.deinit();
}

fn menuFrame() void {
    var menu = widgets.floatingMenu(@src(), .{ .grow_from = grow_from, .frost = .{} }, .{ .corners = .round(12) });
    id = menu.wd.id;
    moving = menu.revealing;
    for (0..14) |i| {
        var row = widgets.menuItem(@src(), .{}, .{ .id_extra = i, .min_size_content = .{ .w = 260, .h = 28 } });
        row.deinit();
    }
    menu.deinit();
}

/// Capture size changes from the first moving frame until rest.
fn captureChanges(comptime draw: fn () void) !usize {
    var t = try dvui.testing.init(.{ .window_size = .{ .w = 900, .h = 900 } });
    defer t.deinit();
    backend.LiquidField.readyInTest(true);
    moving = false;
    var last: ?dvui.Size = null;
    var changes: usize = 0;
    var moved: usize = 0;
    for (0..400) |_| {
        backend.motion.publish(1, 0.5, false, false, 1);
        draw();
        const cw = dvui.currentWindow();
        _ = try cw.end(.{});
        try cw.begin(cw.frame_time_ns + 8 * std.time.ns_per_ms);
        if (moving) moved += 1;
        if (moved == 0) continue;
        if (dvui.dataGet(null, id, "_frost_cap", dvui.Size)) |cap| if (cap.w > 0) {
            if (last) |prev| {
                if (!std.meta.eql(prev, cap)) changes += 1;
            }
            last = cap;
        };
        if (!moving) break;
    } else return error.WidgetDidNotSettle;
    try expect(last != null);
    try expect(moved > 10);
    return changes;
}

test "a Glass growing out of its source keeps one capture" {
    try std.testing.expectEqual(0, try captureChanges(glassFrame));
}

test "a frosted menu growing out of its button keeps one capture" {
    grow_from = .{ .x = 20, .y = 20, .w = 40, .h = 24 };
    try std.testing.expectEqual(0, try captureChanges(menuFrame));
}

test "a frosted menu sliding open keeps one capture" {
    grow_from = null;
    try std.testing.expectEqual(0, try captureChanges(menuFrame));
}

test "a spring's swing is its step response's peak" {
    var t = try dvui.testing.init(.{});
    defer t.deinit();
    backend.motion.publish(1, 0.5, false, false, 1);
    try std.testing.expectApproxEqAbs(@as(f32, 0.163), Spring.swing(.{ .playful_damping = 0.5 }), 0.005);
    backend.motion.publish(0.5, 0.5, false, false, 1);
    try std.testing.expectEqual(@as(f32, 0), Spring.swing(.{ .playful_damping = 0.5 }));
}
