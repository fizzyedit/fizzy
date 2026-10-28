//! The on-screen keyboard, as the app lays out around it. The web backend writes how far the
//! keyboard covers the window (`platform.keyboard_inset`) and the canvas keeps its size, so
//! nothing clears and re-lays out when it opens: the root takes the inset off the bottom of its
//! rect (`inset`), and a focused field scrolls itself above it (`scrollIntoView`).
const std = @import("std");
const dvui = @import("dvui");
const platform = @import("platform.zig");
const Spring = @import("Spring.zig");
const ScrollArea = @import("widgets/ScrollArea.zig");

/// Quick and without overshoot: the layout follows the keyboard, it does not bounce on it.
const tune: Spring.Tune = .{ .hz = 8, .playful_damping = 1 };
const max_step_s: f32 = 0.05;
const spring_key = "_keyboard_inset";

/// The bottom inset to lay out with this frame, in points: the keyboard's, followed by a spring so
/// the layout slides with it (reduce-motion snaps). Call once per frame, from the root, and give
/// the result to its bottom padding. 0 when there is no keyboard.
pub fn inset() f32 {
    const win = dvui.currentWindow();
    const spring = dvui.dataGetPtrDefault(null, win.data().id, spring_key, Spring, .{});
    // Spring stores an unscaled pair; here its coordinates are logical layout points.
    if (spring.step(.{ .y = platform.keyboard_inset }, @min(dvui.secondsSinceLastFrame(), max_step_s), tune)) dvui.refresh(null, @src(), win.data().id);
    return spring.pos.y;
}

/// The inset the root laid out with this frame, 0 before it has asked.
fn laidOut() f32 {
    const spring = dvui.dataGetPtr(null, dvui.currentWindow().data().id, spring_key, Spring) orelse return 0;
    return spring.pos.y;
}

/// What was true when the field last scrolled itself in. `again` is frames still owed: the area
/// clamps a scroll to the content it measured last frame, so one that comes with the content's
/// growth lands a frame short, and is asked for again.
const Seen = struct { inset: f32 = 0, h: f32 = 0, focused: bool = false, again: u8 = 0 };

/// Scroll the enclosing scroll area to show the field `wd` once it has been laid out, when it has
/// just gained focus, the inset moved, or it grew a line. Otherwise leaves the scroll alone, so a
/// person who scrolled away is not pulled back every frame.
pub fn scrollIntoView(wd: *dvui.WidgetData, focused: bool) void {
    const seen = dvui.dataGetPtrDefault(null, wd.id, "_keyboard_seen", Seen, .{});
    var now: Seen = .{ .inset = laidOut(), .h = wd.rect.h, .focused = focused, .again = seen.again -| 1 };
    defer seen.* = now;
    if (!focused) return;
    if (!seen.focused or seen.inset != now.inset or seen.h != now.h) now.again = 2;
    if (now.again == 0) return;
    dvui.scrollTo(.{ .screen_rect = wd.borderRectScale().r });
}

/// Written by the field test on the test UI thread.
var t_lines: f32 = 1;
/// Written by fieldFrame on the test UI thread.
var t_field_bottom: f32 = 0;

fn fieldFrame() !dvui.App.Result {
    var root = dvui.box(@src(), .{}, .{ .expand = .both, .padding = .{ .h = inset() } });
    defer root.deinit();
    var scroll = ScrollArea.init(@src(), .{ .horizontal = .none, .vertical_bar = .hide }, .{ .expand = .both });
    defer scroll.deinit();
    _ = dvui.spacer(@src(), .{ .min_size_content = .{ .w = 100, .h = 1000 } });
    const field = dvui.textEntry(@src(), .{ .multiline = true }, .{ .min_size_content = .{ .w = 100, .h = 20 * t_lines } });
    dvui.focusWidget(field.data().id, null, null);
    _ = @import("widgets.zig").textEntryMenu(field);
    const r = field.data().borderRectScale();
    t_field_bottom = (r.r.y + r.r.h) / r.s;
    @import("widgets.zig").textEntryDeinit(field);
    return .ok;
}

test "a focused field ends above the keyboard, and stays there when it grows" {
    var t = try dvui.testing.init(.{ .window_size = .{ .w = 300, .h = 400 } });
    defer t.deinit();
    defer platform.keyboard_inset = 0;
    t_lines = 1;
    // Laid out once first, so the area knows its content when the keyboard opens.
    try dvui.testing.settle(fieldFrame);
    platform.keyboard_inset = 200;
    try dvui.testing.settle(fieldFrame);
    try std.testing.expect(t_field_bottom <= 400 - 200 + 0.5);
    try std.testing.expect(t_field_bottom > 400 - 200 - 60);
    t_lines = 4;
    try dvui.testing.settle(fieldFrame);
    try std.testing.expect(t_field_bottom <= 400 - 200 + 0.5);
    try std.testing.expect(t_field_bottom > 400 - 200 - 60);
}

/// Written by rootFrame on the test UI thread.
var t_root_h: f32 = 0;

fn rootFrame() !dvui.App.Result {
    var root = dvui.box(@src(), .{}, .{ .expand = .both, .padding = .{ .h = inset() } });
    defer root.deinit();
    t_root_h = root.data().contentRect().h;
    return .ok;
}

test "no keyboard leaves the root's rect as it was" {
    var t = try dvui.testing.init(.{ .window_size = .{ .w = 300, .h = 400 } });
    defer t.deinit();
    platform.keyboard_inset = 0;
    try dvui.testing.settle(rootFrame);
    try std.testing.expectEqual(@as(f32, 400), t_root_h);
    platform.keyboard_inset = 150;
    defer platform.keyboard_inset = 0;
    try dvui.testing.settle(rootFrame);
    try std.testing.expectEqual(@as(f32, 250), t_root_h);
}
