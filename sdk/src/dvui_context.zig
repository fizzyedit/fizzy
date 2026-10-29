//! Wire a loaded plugin dylib's dvui globals to the host's live state.
//!
//! Host and plugin each compile their own `dvui` copy; before plugin draw/tick the host
//! calls the plugin's `fizzy_plugin_set_dvui_context` export (see `dylib.zig`).
const dvui = @import("dvui");

/// C ABI setter type shared by host loader and plugin dylib export.
pub const SetContextFn = *const fn (
    window: ?*dvui.Window,
    io: ?*anyopaque,
    ft2lib: ?*anyopaque,
    debug: ?*dvui.Debug,
) callconv(.c) void;

/// Set this compilation unit's dvui globals from host-owned pointers.
pub fn inject(
    window: ?*dvui.Window,
    io: ?*anyopaque,
    ft2lib: ?*anyopaque,
    debug: ?*dvui.Debug,
) void {
    if (window) |w| dvui.current_window = w;
    if (io) |i| {
        const io_ptr: *@TypeOf(dvui.io) = @ptrCast(@alignCast(i));
        dvui.io = io_ptr.*;
    }
    if (comptime dvui.useFreeType) {
        if (ft2lib) |ft| {
            const ft_ptr: *@TypeOf(dvui.ft2lib) = @ptrCast(@alignCast(ft));
            dvui.ft2lib = ft_ptr.*;
        }
    }
    if (debug) |d| dvui.debug = d.*;
    if (window != null) {
        applyDragThreshold();
        // This image's dvui animates, or does not, as the host's does (`core.motion.publish`).
        @import("core").motion.apply();
        // This image's threads record spans into the host's (`core.profile.span`).
        @import("core").profile.adopt();
    }
}

/// dvui's own default, for the mouse.
pub const mouse_drag_threshold: f32 = 3;

/// Where the host records whether input is touch, in the shared window's data — every dylib's
/// copy of dvui has its own `Dragging.threshold`, and this is how they agree on it.
const input_id: dvui.Id = @fromBackingInt(@intCast(0x6669_7a7a_795f_7463)); // "fizzy_tc"
const input_key = "_touch_input";

/// Host only, once a frame before anything handles input: note whether the pointer is a finger
/// (the latest pointer press or motion was touch) and set this image's drag threshold to match.
/// Plugin images pick it up in `inject`, which the host calls before they draw.
pub fn syncTouchInput() void {
    var touch = dvui.dataGet(null, input_id, input_key, bool) orelse false;
    for (dvui.events()) |e| {
        if (e.evt != .mouse) continue;
        const me = e.evt.mouse;
        switch (me.action) {
            .press, .motion => {
                if (me.button.touch()) touch = true else if (me.button.pointer() or me.action == .motion) touch = false;
            },
            else => {},
        }
    }
    dvui.dataSet(null, input_id, input_key, touch);
    applyDragThreshold();
}

fn applyDragThreshold() void {
    const touch = dvui.dataGet(null, input_id, input_key, bool) orelse false;
    dvui.Dragging.threshold = if (touch) @import("core").TouchHold.slop_pt else mouse_drag_threshold;
}

/// Push the host exe's current dvui state into a loaded plugin image.
pub fn syncHostIntoPlugin(setter: SetContextFn) void {
    setter(
        dvui.current_window,
        @ptrCast(&dvui.io),
        if (comptime dvui.useFreeType) @ptrCast(&dvui.ft2lib) else null,
        &dvui.debug,
    );
}

const std = @import("std");

test "touch presses use the shared slop and mouse presses restore three points" {
    var t = try dvui.testing.init(.{});
    defer t.deinit();
    const previous = dvui.Dragging.threshold;
    defer dvui.Dragging.threshold = previous;
    _ = try t.window.addEventPointer(.{ .button = .touch0, .action = .press, .xynorm = .{ .x = 0.1, .y = 0.1 } });
    syncTouchInput();
    try std.testing.expectEqual(@import("core").TouchHold.slop_pt, dvui.Dragging.threshold);
    _ = try t.window.addEventMouseButton(.left, .press);
    syncTouchInput();
    try std.testing.expectEqual(@as(f32, 3), dvui.Dragging.threshold);
}

fn touchButtonFrame() !dvui.App.Result {
    syncTouchInput();
    const clicked = dvui.button(@src(), "Touch target", .{}, .{ .min_size_content = .{ .w = 200, .h = 100 } });
    dvui.dataSet(null, input_id, "test_clicked", clicked);
    return .ok;
}

test "a touch button clicks after twelve points of drift but not sixteen" {
    var t = try dvui.testing.init(.{ .window_size = .{ .w = 300, .h = 200 } });
    defer t.deinit();
    const previous = dvui.Dragging.threshold;
    defer dvui.Dragging.threshold = previous;
    try dvui.testing.settle(touchButtonFrame);
    for ([_]f32{ 12, 16 }) |drift| {
        _ = try t.window.addEventPointer(.{ .button = .touch0, .action = .press, .xynorm = .{ .x = 0.1, .y = 0.1 } });
        _ = try dvui.testing.step(touchButtonFrame);
        const moved_x = 0.1 + drift / 300;
        _ = try t.window.addEventPointer(.{ .button = .touch0, .action = .{ .motion = .{ .x = drift * t.window.natural_scale, .y = 0 } }, .xynorm = .{ .x = moved_x, .y = 0.1 } });
        _ = try dvui.testing.step(touchButtonFrame);
        _ = try t.window.addEventPointer(.{ .button = .touch0, .action = .release, .xynorm = .{ .x = moved_x, .y = 0.1 } });
        _ = try dvui.testing.step(touchButtonFrame);
        try std.testing.expectEqual(drift == 12, dvui.dataGet(null, input_id, "test_clicked", bool).?);
    }
}
