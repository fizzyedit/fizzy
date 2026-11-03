//! A dvui button with a centred 44-point touch target; layout and drawing retain their size.
const std = @import("std");
const dvui = @import("dvui");
const form_factor = @import("../form_factor.zig");

const Event = dvui.Event;
const Options = dvui.Options;
const Rect = dvui.Rect;
const RectScale = dvui.RectScale;
const Size = dvui.Size;
const Widget = dvui.Widget;
const WidgetData = dvui.WidgetData;

const Button = @This();

wd: WidgetData,
init_options: InitOptions,
hover: bool = false,
focus: bool = false,
click: bool = false,

pub const InitOptions = dvui.ButtonWidget.InitOptions;

/// Initializes an undefined button and makes it the current parent.
pub fn init(self: *Button, src: std.lang.SourceLocation, init_options: InitOptions, opts: Options) void {
    var options = dvui.ButtonWidget.defaults.override(opts);
    if (init_options.grayed) {
        options.color_text = .{ .color = dvui.Color.average(options.color(.text).toColor(), options.color(.fill).toColor()) };
    }
    self.* = .{
        .wd = .init(src, .{}, options),
        .init_options = init_options,
    };
    self.data().register();
    dvui.parentSet(self.widget());

    dvui.tabIndexSet(self.data().id, self.data().options.tab_index, self.data().rectScale().r);

    if (self.data().accesskit_node()) |ak_node| {
        dvui.AccessKit.nodeAddAction(ak_node, dvui.AccessKit.Action.focus);
        dvui.AccessKit.nodeAddAction(ak_node, dvui.AccessKit.Action.click);
    }
}

pub fn matchEvent(self: *Button, e: *Event) bool {
    return dvui.eventMatch(e, .{ .id = self.data().id, .r = self.hitRect() });
}

pub fn processEvents(self: *Button) void {
    self.click = dvui.clicked(self.data(), .{ .rect = self.hitRect(), .hovered = &self.hover, .touch_drag = self.init_options.touch_drag });
}

fn hitRect(self: *Button) Rect.Physical {
    const rs = self.data().borderRectScale();
    var r = rs.r;
    if (dvui.pointerKind() == .touch) {
        const w = @max(r.w, form_factor.min_hit * rs.s);
        const h = @max(r.h, form_factor.min_hit * rs.s);
        r.x -= (w - r.w) / 2;
        r.y -= (h - r.h) / 2;
        r.w = w;
        r.h = h;
    }
    return r;
}

pub fn processHover(self: *Button) void {
    for (dvui.events()) |*e| {
        if (!dvui.eventMatchSimple(e, self.data())) continue;

        if (e.evt == .mouse and e.evt.mouse.action == .position) {
            self.hover = true;
        }
    }
}

pub fn drawBackground(self: *Button) void {
    const style_opt = self.style();
    var npask: Options.NinepatchAsk = .fill;
    if (dvui.captured(self.data().id)) {
        npask = .press;
    } else if (self.hover) {
        npask = .hover;
    }
    self.data().borderAndBackground(.{
        .fill_color = style_opt.color_fill,
        .ninepatch = self.data().options.ninepatch(npask),
    });
}

pub fn drawFocus(self: *Button) void {
    if (self.init_options.draw_focus and self.focused()) {
        self.data().focusBorder();
    }
}

/// Returns style overrides for the hover and press state.
pub fn style(self: *Button) Options {
    var opts = self.data().options.styleOnly();
    const t = dvui.hoverFade(self.data().id, self.hover);
    if (dvui.captured(self.data().id)) {
        opts.color_fill = self.data().options.color(.fill_press);
        opts.color_text = self.data().options.color(.text_press);
    } else if (t > 0) {
        opts.color_fill = self.data().options.color(.fill).lerp(self.data().options.color(.fill_hover), t);
        opts.color_text = self.data().options.color(.text).lerp(self.data().options.color(.text_hover), t);
    }
    return opts;
}

pub fn focused(self: *Button) bool {
    return self.data().id == dvui.focusedWidgetId();
}

pub fn hovered(self: *Button) bool {
    return self.hover;
}

pub fn pressed(self: *Button) bool {
    return dvui.captured(self.data().id);
}

pub fn clicked(self: *Button) bool {
    return self.click;
}

pub fn widget(self: *Button) Widget {
    return Widget.init(self, data, rectFor, screenRectScale, minSizeForChild);
}

pub fn data(self: *Button) *WidgetData {
    return self.wd.validate();
}

pub fn rectFor(self: *Button, id: dvui.Id, min_size: Size, e: Options.Expand, g: Options.Gravity) Rect {
    _ = id;
    return dvui.placeIn(self.data().contentRect().justSize(), min_size, e, g);
}

pub fn screenRectScale(self: *Button, rect: Rect) RectScale {
    return self.data().contentRectScale().rectToRectScale(rect);
}

pub fn minSizeForChild(self: *Button, s: Size) void {
    self.data().minSizeMax(self.data().options.padSize(s));
}

pub fn deinit(self: *Button) void {
    defer if (dvui.widgetIsAllocated(self)) dvui.widgetFree(self);
    defer self.* = undefined;
    self.data().minSizeSetAndRefresh();
    self.data().minSizeReportToParent();
    dvui.parentReset(self.data().id, self.data().parent);
}

// The headless frame records the button on the test runner thread.
var test_click = false;
var test_rect: dvui.Rect.Physical = .{};
// The clipping test toggles this on the test runner thread.
var test_clip = false;

fn testFrame() !dvui.App.Result {
    var bw: Button = undefined;
    bw.init(@src(), .{}, .{ .rect = .{ .x = 50, .y = 50, .w = 20, .h = 20 }, .margin = .all(0), .padding = .all(0) });
    defer bw.deinit();
    const clip = dvui.clipGet();
    if (test_clip) dvui.clipSet(bw.data().borderRectScale().r);
    defer dvui.clipSet(clip);
    bw.processEvents();
    test_click = bw.clicked();
    test_rect = bw.data().borderRectScale().r;
    bw.drawBackground();
    return .ok;
}

fn testPointer(button: dvui.enums.Button, action: dvui.Event.Mouse.Action, x: f32) !void {
    _ = try dvui.currentWindow().addEventPointer(.{ .button = button, .action = action, .xynorm = .{ .x = x / 200, .y = 0.3 } });
}

fn testStep() !void {
    _ = try testFrame();
    const win = dvui.currentWindow();
    _ = try win.end(.{});
    try win.begin(win.frame_time_ns + 16 * std.time.ns_per_ms);
}

test "a touch hits the centred 44 point target without growing the button" {
    var t = try dvui.testing.init(.{ .window_size = .{ .w = 200, .h = 200 } });
    defer t.deinit();
    try dvui.testing.settle(testFrame);
    try testPointer(.touch0, .press, 39);
    try testPointer(.touch0, .release, 39);
    try testStep();
    try std.testing.expect(test_click);
    try std.testing.expectEqual((dvui.Rect{ .x = 50, .y = 50, .w = 20, .h = 20 }).scale(dvui.windowNaturalScale(), dvui.Rect.Physical), test_rect);
    try testPointer(.touch0, .press, 37);
    try testPointer(.touch0, .release, 37);
    try testStep();
    try std.testing.expect(!test_click);
}

test "a mouse still needs to hit the drawn button" {
    var t = try dvui.testing.init(.{ .window_size = .{ .w = 200, .h = 200 } });
    defer t.deinit();
    try dvui.testing.settle(testFrame);
    try testPointer(.left, .press, 39);
    try testPointer(.left, .release, 39);
    try testStep();
    try std.testing.expect(!test_click);
    try testPointer(.left, .press, 60);
    try testPointer(.left, .release, 60);
    try testStep();
    try std.testing.expect(test_click);
}

test "a touch drag from the expanded target cancels the click" {
    var t = try dvui.testing.init(.{ .window_size = .{ .w = 200, .h = 200 } });
    defer t.deinit();
    try dvui.testing.settle(testFrame);
    try testPointer(.touch0, .press, 39);
    try testStep();
    _ = try dvui.currentWindow().addEventTouchMotion(.touch0, 0.4, 0.3, 0.205, 0);
    try testStep();
    try testPointer(.touch0, .release, 60);
    try testStep();
    try std.testing.expect(!test_click);
}

test "the expanded touch target respects the clip" {
    var t = try dvui.testing.init(.{ .window_size = .{ .w = 200, .h = 200 } });
    defer t.deinit();
    test_clip = true;
    defer test_clip = false;
    try dvui.testing.settle(testFrame);
    try testPointer(.touch0, .press, 39);
    try testPointer(.touch0, .release, 39);
    try testStep();
    try std.testing.expect(!test_click);
}
