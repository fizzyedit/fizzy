//! dvui's button with a minimum touch hit area independent of its drawn and layout rectangles.
const std = @import("std");
const dvui = @import("dvui");
const form_factor = @import("../form_factor.zig");
const Button = @This();

pub const InitOptions = dvui.ButtonWidget.InitOptions;

inner: dvui.ButtonWidget,

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

pub fn processEvents(self: *Button) void {
    self.inner.click = dvui.clicked(self.data(), .{
        .rect = self.hitRect(),
        .hovered = &self.inner.hover,
        .touch_drag = self.inner.init_options.touch_drag,
    });
}

pub fn matchEvent(self: *Button, e: *dvui.Event) bool {
    return self.inner.matchEvent(e);
}

pub fn processHover(self: *Button) void {
    self.inner.processHover();
}

pub fn drawBackground(self: *Button) void {
    self.inner.drawBackground();
}

pub fn drawFocus(self: *Button) void {
    self.inner.drawFocus();
}

pub fn style(self: *Button) dvui.Options {
    return self.inner.style();
}

pub fn focused(self: *Button) bool {
    return self.inner.focused();
}

pub fn hovered(self: *Button) bool {
    return self.inner.hovered();
}

pub fn pressed(self: *Button) bool {
    return self.inner.pressed();
}

pub fn clicked(self: *Button) bool {
    return self.inner.clicked();
}

pub fn widget(self: *Button) dvui.Widget {
    return self.inner.widget();
}

pub fn data(self: *Button) *dvui.WidgetData {
    return self.inner.data();
}

pub fn rectFor(self: *Button, id: dvui.Id, min_size: dvui.Size, e: dvui.Options.Expand, g: dvui.Options.Gravity) dvui.Rect {
    return self.inner.rectFor(id, min_size, e, g);
}

pub fn screenRectScale(self: *Button, rect: dvui.Rect) dvui.RectScale {
    return self.inner.screenRectScale(rect);
}

pub fn minSizeForChild(self: *Button, size: dvui.Size) void {
    self.inner.minSizeForChild(size);
}

pub fn deinit(self: *Button) void {
    defer if (dvui.widgetIsAllocated(self)) dvui.widgetFree(self);
    self.inner.deinit();
}

test "touch clicks six points outside a 32 point border without changing its drawn rect" {
    const widgets = @import("../widgets.zig");
    _ = &widgets.button;
    _ = &widgets.buttonIcon;
    _ = &widgets.buttonLabelAndIcon;
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
