//! A floating menu panel, fizzy's copy of dvui's.
//!
//! **Why a copy.** A frosted surface has to paint in one order — shadow, then the blurred
//! capture, then its own translucent fill — because the frost replaces what is beneath it (see
//! `core.widgets.FloatingWindowWidget.drawFrost`). dvui's floating menu paints its background
//! inside `init`, where nothing outside can get in front of it, so a menu could be translucent
//! or blurred but never both. The rest of the chain came with it: `MenuItem` asks `Menu.current`
//! whether it is inside a floating menu, and that answer lives in a global this file sets — a
//! copy of one widget would have left every menu item behaving like a menubar button.
//!
//! What is different from dvui's, and all that is: the `frost` option and the paint order in
//! `init`, and `Menu`/`MenuItem` beside it drawing rows from `core.dialogs`' one description of
//! a floating surface. Everything else is dvui's, and updates by re-copying.
const std = @import("std");
const dvui = @import("dvui");
const dialogs = @import("../../dialogs.zig");
const BlurBackdrop = @import("../BlurBackdrop.zig");

const Event = dvui.Event;
const Options = dvui.Options;
const Rect = dvui.Rect;
const RectScale = dvui.RectScale;
const Size = dvui.Size;
const Widget = dvui.Widget;
const WidgetData = dvui.WidgetData;
const Menu = @import("Menu.zig");
const ScrollAreaWidget = dvui.ScrollAreaWidget;

const FloatingMenu = @This();

pub const FloatingMenuAvoid = enum {
    none,
    horizontal,
    vertical,

    /// Pick horizontal or vertical based on the direction of the current
    /// parent menu (if any).
    auto,
};

// this lets us maintain a chain of all the nested FloatingMenus without
// forcing the user to manually do it
var current: ?*FloatingMenu = null;

fn currentSet(p: ?*FloatingMenu) ?*FloatingMenu {
    const ret = current;
    current = p;
    return ret;
}

pub fn currentGet() ?*FloatingMenu {
    return current;
}

pub var defaults: Options = .{
    .name = "FloatingMenu",
    .corners = .default,
    .border = Rect.all(1),
    .padding = Rect.all(4),
    .background = true,
    .style = .window,
};

pub const Style = enum {
    /// Arrow keys work like a menu:
    /// * wrap in a focus group
    /// * arrow keys move focus depending on menu direction
    /// * left exits vertical menu
    /// * escape exits menu
    menu,

    /// Arrow keys work like a popup:
    /// * no focus group
    /// * arrow keys move focus normally (tabIndexDirection)
    /// * escape still exits
    /// * clicking outside the menu exits
    popup,
};

pub const InitOptions = struct {
    from: ?Rect.Natural = null,
    avoid: FloatingMenuAvoid = .auto,
    style: Style = .menu,
    /// Blur what is behind the panel, as a dialog does. The tint *is* the fill, so a frosted
    /// menu paints no background of its own. Null draws `opts.color_fill` the ordinary way.
    frost: ?BlurBackdrop.Pane = null,
};

render_ftb: dvui.RenderFrontToBack,
wd: WidgetData,
prev_windowInfo: dvui.subwindowCurrentSetReturn = undefined,
prev_scroll: ?*dvui.ScrollContainerWidget = undefined,
prev_last_focus: dvui.Id,
parent_fmw: ?*FloatingMenu = null,
have_popup_child: bool = false,
prevClip: Rect.Physical,
scale_val: f32,
menu: Menu,
style: Style,
scaler: dvui.ScaleWidget,
scroll: ScrollAreaWidget,

/// It's expected to call this when `self` is `undefined`
pub fn init(self: *FloatingMenu, src: std.builtin.SourceLocation, init_opts: InitOptions, opts: Options) void {
    self.* = .{
        // the widget itself doesn't have any styling, it comes from the
        // embedded Menu
        // passing options.rect will stop WidgetData.init from calling
        // rectFor/minSizeForChild which is important because we are outside
        // normal layout
        .wd = .init(src, .{ .subwindow = true }, .{ .id_extra = opts.id_extra, .rect = .{} }),
        // get scale from parent
        .scale_val = dvui.parentGet().screenRectScale(Rect{}).s / dvui.windowNaturalScale(),

        .render_ftb = undefined,
        .prev_last_focus = undefined,
        .prevClip = undefined,
        .menu = undefined,
        .style = init_opts.style,
        .scaler = undefined,
        .scroll = undefined,
    };

    const options = defaults.override(opts);
    // NOTE: options is really for our embedded ScrollAreaWidget

    const avoid: dvui.PlaceOnScreenAvoid = switch (init_opts.avoid) {
        .none => .none,
        .horizontal => .horizontal,
        .vertical => .vertical,
        .auto => if (Menu.current()) |pm| switch (pm.init_opts.dir) {
            .horizontal => .vertical,
            .vertical => .horizontal,
        } else .none,
    };

    if (init_opts.from) |fr| self.data().rect = Rect.fromPoint(.cast(fr.topLeft()));
    if (dvui.minSizeGet(self.data().id)) |ms| {
        self.data().rect = self.data().rect.toSize(ms);
        if (dvui.dataGet(null, self.data().id, "_check_focus", void) != null) {
            dvui.dataRemove(null, self.data().id, "_check_focus");
            dvui.focusSubwindow(self.data().id, null);
        }
    } else {
        dvui.dataSet(null, self.data().id, "_check_focus", {});

        // need a second frame to fit contents
        dvui.refresh(null, @src(), self.data().id);
    }

    if (init_opts.from) |fr| {
        self.data().rect = .cast(dvui.placeOnScreen(dvui.windowRect(), fr, avoid, .cast(self.data().rect)));
    } else {
        const centering: Rect.Natural = dvui.currentWindow().subwindows.current_rect;
        self.wd.rect.x = centering.x + (centering.w - self.wd.rect.w) / 2;
        self.wd.rect.y = centering.y + (centering.h - self.wd.rect.h) / 2;
        self.wd.rect = .cast(dvui.placeOnScreen(dvui.windowRect(), .{}, .none, .cast(self.data().rect)));
    }

    if (dvui.snapToPixels()) {
        const s = dvui.windowNaturalScale();
        self.wd.rect.x = @round(self.wd.rect.x * s) / s;
        self.wd.rect.y = @round(self.wd.rect.y * s) / s;
    }

    self.data().register();
    dvui.parentSet(self.widget());

    // standard subwindow stuff
    {
        const rs = self.data().rectScale();
        self.render_ftb.initReset();
        self.prev_windowInfo = dvui.subwindowCurrentSet(self.data().id, null);
        dvui.subwindowAdd(self.data().id, self.data().rect, rs.r, self.style == .popup, null, true);
        dvui.captureMouseMaintain(.{ .id = self.data().id, .rect = rs.r, .subwindow_id = self.data().id });
        self.prevClip = dvui.clipGet();
        dvui.clipSet(dvui.windowRectPixels()); // break out of whatever clipping we were in
        self.prev_scroll = dvui.ScrollContainerWidget.scrollSet(null);
    }

    // prevents parents from processing key events if focus is inside the floating window
    self.prev_last_focus = dvui.lastFocusedIdInFrame();

    self.parent_fmw = currentSet(self);

    const rs = self.data().rectScale();
    const evts = dvui.events();
    for (evts) |*e| {
        if (!dvui.eventMatch(e, .{ .id = self.data().id, .r = rs.r }))
            continue;

        if (e.evt == .mouse and e.evt.mouse.action == .focus) {
            // focus but let the focus event propagate to widgets
            dvui.focusSubwindow(self.data().id, e.num);
        }
    }

    self.scaler.init(@src(), .{ .scale = &self.scale_val }, .{ .expand = .both });

    // Shadow, frost, fill — the order a frosted surface needs, and the reason this file exists.
    // The shadow is drawn here rather than left to the scroll area because the frost replaces
    // what is under the panel: a shadow painted after it would lay its black over the glass,
    // where a shadow drawn first survives only outside the panel, which is where it belongs.
    // The fill then goes over the frost as `color_fill`, translucent, so the blur reads through.
    if (init_opts.frost) |frost| {
        const brs = self.data().borderRectScale();
        // Finalized before scaling: a `CornerRect` carries the theme's corner *kind* at a size,
        // and `WidgetData.init` is what normally resolves it. An unresolved corner draws square
        // whatever radius it names — which is exactly how a rounded palette ended up beside a
        // square menu built from the same constant.
        const corners = options.cornersGet().finalize(options.themeGet());
        if (options.box_shadow) |bs| {
            const prect = brs.r.insetAll(brs.s * bs.shrink).offsetPoint(bs.offset.scale(brs.s, dvui.Point.Physical));
            prect.fill(corners.scale(brs.s, dvui.CornerRect.Physical), .{
                .color = .{ .color = bs.color.opacity(bs.alpha) },
                .fade = brs.s * bs.fade,
            });
        }
        BlurBackdrop.frostPane(self.data().id, brs.r, corners, brs.s, frost);
    }

    // we are using scroll to do border/background but floating windows
    // don't have margin, so turn that off
    var scroll_opts = options.override(.{ .margin = .{}, .expand = .both });
    if (init_opts.frost != null) {
        // The shadow is already down; drawing it again from the scroll area would double it.
        scroll_opts.box_shadow = null;
    }
    self.scroll.init(@src(), .{ .horizontal = .none }, scroll_opts);

    if (Menu.current()) |pm| {
        pm.child_popup_rect = rs.r;
    }

    self.menu.init(@src(), .{ .dir = .vertical, .parentSubwindowId = self.prev_windowInfo.id, .keyboard_nav = self.style }, options.strip().override(.{ .role = .none, .expand = .horizontal }));
}

pub fn close(self: *FloatingMenu) void {
    self.menu.close();
}

pub fn widget(self: *FloatingMenu) Widget {
    return Widget.init(self, data, rectFor, screenRectScale, minSizeForChild);
}

pub fn data(self: *FloatingMenu) *WidgetData {
    return self.wd.validate();
}

pub fn rectFor(self: *FloatingMenu, id: dvui.Id, min_size: Size, e: Options.Expand, g: Options.Gravity) Rect {
    _ = id;
    return dvui.placeIn(self.data().contentRect().justSize(), min_size, e, g);
}

pub fn screenRectScale(self: *FloatingMenu, rect: Rect) RectScale {
    return self.data().contentRectScale().rectToRectScale(rect);
}

pub fn minSizeForChild(self: *FloatingMenu, s: Size) void {
    self.data().minSizeMax(self.data().options.padSize(s));
}

pub fn chainFocused(self: *FloatingMenu, self_call: bool) bool {
    if (!self_call) {
        // if we got called by someone else, then we have a popup child
        self.have_popup_child = true;
    }

    var ret: bool = false;

    // we have to call chainFocused on our parent if we have one so we
    // can't return early

    if (self.data().id == dvui.focusedSubwindowId()) {
        // we are focused
        ret = true;
    }

    if (self.parent_fmw) |pp| {
        // we had a parent popup, is that focused
        if (pp.chainFocused(false)) {
            ret = true;
        }
    } else if (self.prev_windowInfo.id == dvui.focusedSubwindowId()) {
        // no parent popup, is our parent window focused
        ret = true;
    }

    return ret;
}

pub fn deinit(self: *FloatingMenu) void {
    defer if (dvui.widgetIsAllocated(self)) dvui.widgetFree(self);
    defer self.* = undefined;

    const evts = dvui.events();
    const rs = self.data().rectScale();
    for (evts) |*e| {
        if (self.style == .popup and e.evt == .mouse and e.evt.mouse.action == .focus and !rs.r.contains(e.evt.mouse.p)) {
            self.menu.close_chain(.unintentional);
            dvui.refresh(null, @src(), self.data().id);
        }

        if (!dvui.eventMatch(e, .{ .id = self.data().id, .r = rs.r }))
            continue;

        if (e.evt == .mouse and e.evt.mouse.action == .focus) {
            // unhandled click, clear focus
            e.handle(@src(), self.data());
            dvui.focusWidget(null, null, null);
        }
    }

    if (!self.have_popup_child and !self.chainFocused(true)) {
        // if a popup chain is open and the user focuses a different window
        // (not the parent of the popups), then we want to close the popups

        // only the last popup can do the check, you can't query the focus
        // status of children, only parents
        self.menu.close_chain(.unintentional);
        dvui.refresh(null, @src(), self.data().id);
    }

    self.menu.deinit();
    self.scroll.deinit();
    self.scaler.deinit();

    // in case no children ever show up, this will provide a visual indication
    // that there is an empty floating menu
    self.data().minSizeMax(self.data().options.padSize(.{ .w = 20, .h = 20 }));

    self.data().minSizeSetAndRefresh();

    // outside normal layout, don't call minSizeForChild or self.data().minSizeReportToParent();

    _ = currentSet(self.parent_fmw);
    dvui.parentReset(self.data().id, self.data().parent);
    dvui.currentWindow().last_focused_id_this_frame = self.prev_last_focus;

    // standard subwindow stuff
    {
        _ = dvui.ScrollContainerWidget.scrollSet(self.prev_scroll);
        _ = dvui.subwindowCurrentSet(self.prev_windowInfo.id, self.prev_windowInfo.rect);
        dvui.clipSet(self.prevClip);
        self.render_ftb.deinit();
    }
}

test {
    @import("std").testing.refAllDecls(@This());
}
