//! dvui's button with a minimum touch hit area independent of its drawn and layout rectangles.
const std = @import("std");
const dvui = @import("dvui");
const form_factor = @import("../form_factor.zig");
const Button = @This();

inner: dvui.ButtonWidget,

pub const InitOptions = dvui.ButtonWidget.InitOptions;

/// Install a button using dvui interaction and layout options; pair with `deinit`.
/// Call during a frame, then process events before drawing its background and children.
pub fn init(self: *Button, src: std.builtin.SourceLocation, init_opts: InitOptions, opts: dvui.Options) void {
    self.inner.init(src, init_opts, opts);
}

/// The physical click rectangle, centred on the border and never smaller than it.
pub fn hitRect(self: *Button) dvui.Rect.Physical {
    const rs = self.data().borderRectScale();
    var rect = rs.r;
    if (dvui.pointerKind() == .touch) {
        const minimum = form_factor.min_hit * rs.s;
        const w = @max(rect.w, minimum);
        const h = @max(rect.h, minimum);
        rect.x -= (w - rect.w) / 2;
        rect.y -= (h - rect.h) / 2;
        rect.w = w;
        rect.h = h;
    }
    return rect;
}

/// Consume this frame's clicks using the touch hit rectangle; call once before drawing.
pub fn processEvents(self: *Button) void {
    // TODO(touch-target arbitration): choose the nearest border before consuming overlapping
    // targets; processing order wins today, including over a neighbour's border. Resolve before
    // migrating tightly packed toolbars.
    self.inner.click = dvui.clicked(self.data(), .{
        .rect = self.hitRect(),
        .hovered = &self.inner.hover,
        .touch_drag = self.inner.init_options.touch_drag,
    });
}

/// Test an event against dvui's widget event routing, without consuming it.
pub fn matchEvent(self: *Button, e: *dvui.Event) bool {
    return self.inner.matchEvent(e);
}

/// Update hover state using dvui's border rectangle.
pub fn processHover(self: *Button) void {
    self.inner.processHover();
}

/// Draw the styled border and background without expanding them to the touch target.
pub fn drawBackground(self: *Button) void {
    self.inner.drawBackground();
}

/// Draw the keyboard focus indicator after drawing the button's children.
pub fn drawFocus(self: *Button) void {
    self.inner.drawFocus();
}

/// The current dvui style, including hover and press state, for styling children.
pub fn style(self: *Button) dvui.Options {
    return self.inner.style();
}

/// Whether this button owns keyboard focus in the current window.
pub fn focused(self: *Button) bool {
    return self.inner.focused();
}

/// Whether this frame's event processing marked the button hovered.
pub fn hovered(self: *Button) bool {
    return self.inner.hovered();
}

/// Whether this button currently holds pointer capture.
pub fn pressed(self: *Button) bool {
    return self.inner.pressed();
}

/// Whether event processing activated the button this frame.
pub fn clicked(self: *Button) bool {
    return self.inner.clicked();
}

/// The inner dvui widget and its layout vtable, valid until `deinit`.
pub fn widget(self: *Button) dvui.Widget {
    return self.inner.widget();
}

/// Borrow the inner widget data; valid until `deinit`.
pub fn data(self: *Button) *dvui.WidgetData {
    return self.inner.data();
}

/// Delegate child placement to the inner widget using dvui layout coordinates.
pub fn rectFor(self: *Button, id: dvui.Id, min_size: dvui.Size, e: dvui.Options.Expand, g: dvui.Options.Gravity) dvui.Rect {
    return self.inner.rectFor(id, min_size, e, g);
}

/// Convert a local rectangle to physical screen coordinates using the inner widget.
pub fn screenRectScale(self: *Button, rect: dvui.Rect) dvui.RectScale {
    return self.inner.screenRectScale(rect);
}

/// Report a child's minimum size to the inner widget's layout.
pub fn minSizeForChild(self: *Button, size: dvui.Size) void {
    self.inner.minSizeForChild(size);
}

/// Finish layout and restore the parent; releases a dvui-allocated widget if applicable.
pub fn deinit(self: *Button) void {
    self.inner.deinit();
}

test "touch clicks six points outside a 32 point border without changing its drawn rect" {
    const Frame = struct {
        // The test callback writes these on the testing window's thread.
        var border: dvui.Rect.Physical = .{};
        // The test callback writes this on the testing window's thread.
        var click: bool = false;

        fn draw() !dvui.App.Result {
            var button: Button = undefined;
            button.init(@src(), .{}, .{
                .rect = .{ .x = 50, .y = 50, .w = 32, .h = 32 },
                .margin = dvui.Rect.all(0),
            });
            defer button.deinit();
            button.processEvents();
            button.drawBackground();
            border = button.data().borderRectScale().r;
            click = button.clicked();
            return .ok;
        }
    };
    var t = try dvui.testing.init(.{ .window_size = .{ .w = 200, .h = 200 } });
    defer t.deinit();
    try dvui.testing.settle(Frame.draw);
    const original = Frame.border;
    const cw = dvui.currentWindow();
    const scale = cw.natural_scale;
    const point: dvui.Point.Physical = .{ .x = original.x - 6 * scale, .y = original.center().y };
    const norm: dvui.Point = .{ .x = point.x / (200 * scale), .y = point.y / (200 * scale) };
    _ = try cw.addEventPointer(.{ .button = .touch0, .action = .press, .xynorm = norm });
    _ = try dvui.testing.step(Frame.draw);
    _ = try cw.addEventPointer(.{ .button = .touch0, .action = .release, .xynorm = norm });
    _ = try dvui.testing.step(Frame.draw);
    try std.testing.expectEqual(.touch, dvui.pointerKind());
    try std.testing.expect(Frame.click);
    try std.testing.expectEqual(original, Frame.border);

    _ = try cw.addEventMouseMotion(.{ .pt = point });
    _ = try cw.addEventMouseButton(.left, .press);
    _ = try dvui.testing.step(Frame.draw);
    _ = try cw.addEventMouseButton(.left, .release);
    _ = try dvui.testing.step(Frame.draw);
    try std.testing.expectEqual(.mouse, dvui.pointerKind());
    try std.testing.expect(!Frame.click);
    try std.testing.expectEqual(original, Frame.border);
}

test "button verbs draw and accept a touch outside their borders" {
    const widgets = @import("../widgets.zig");
    const Frame = struct {
        // The draw callback writes the click results on the testing window's thread.
        var clicks: [3]bool = .{ false, false, false };

        fn draw() !dvui.App.Result {
            const opts: dvui.Options = .{ .rect = .{ .x = 50, .y = 50, .w = 32, .h = 32 }, .margin = dvui.Rect.all(0) };
            clicks[0] = widgets.button(@src(), "Label", .{}, opts);
            clicks[1] = widgets.buttonIcon(@src(), "Icon", dvui.entypo.cross, .{}, .{}, opts.override(.{ .rect = .{ .x = 50, .y = 100, .w = 32, .h = 32 } }));
            clicks[2] = widgets.buttonLabelAndIcon(@src(), .{ .label = "Both", .tvg_bytes = dvui.entypo.cross }, opts.override(.{ .rect = .{ .x = 50, .y = 150, .w = 32, .h = 32 } }));
            return .ok;
        }
    };
    var t = try dvui.testing.init(.{ .window_size = .{ .w = 200, .h = 200 } });
    defer t.deinit();
    try dvui.testing.settle(Frame.draw);
    const cw = dvui.currentWindow();
    for (0..3) |i| {
        // Six points left of each border, at its vertical centre.
        const norm: dvui.Point = .{ .x = 44.0 / 200.0, .y = (66.0 + 50.0 * @as(f32, @floatFromInt(i))) / 200.0 };
        _ = try cw.addEventPointer(.{ .button = .touch0, .action = .press, .xynorm = norm });
        _ = try dvui.testing.step(Frame.draw);
        _ = try cw.addEventPointer(.{ .button = .touch0, .action = .release, .xynorm = norm });
        _ = try dvui.testing.step(Frame.draw);
        for (Frame.clicks, 0..) |activated, j| try std.testing.expectEqual(i == j, activated);
    }
}
