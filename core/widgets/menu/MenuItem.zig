//! A menu row, fizzy's copy of dvui's. See `FloatingMenu`'s header for why the chain is copied.
//!
//! What is different: the row is painted from `core.dialogs` — the one description of a floating
//! surface and its rows, which the command palette, the dialogs and the flyouts also read — and
//! it is painted for the *pointer*, not for focus.
//!
//! dvui fills a row whenever it is hovered **or** focused, and a menu leaves focus on the row the
//! pointer last crossed. Two rows were lit at once: a solid block behind the pointer and a fade
//! ahead of it, plus the accent focus ring hopping between them. Here the fill follows
//! `hover_t` alone, from the hover colour at zero alpha to the hover colour, so the fade is in
//! alpha and nothing is painted where the pointer is not.
const std = @import("std");
const dvui = @import("dvui");
const Menu = @import("Menu.zig");

const Event = dvui.Event;
const Options = dvui.Options;
const Rect = dvui.Rect;
const RectScale = dvui.RectScale;
const CornerRect = dvui.CornerRect;
const Size = dvui.Size;
const Widget = dvui.Widget;
const WidgetData = dvui.WidgetData;
const AccessKit = dvui.AccessKit;

/// The parent menu of this item
const menu = Menu.current;

const MenuItem = @This();

pub var defaults: Options = .{
    .name = "Menu Item",
    .role = .menu_item,
    .corners = .default,
    .padding = Rect.all(6),
    .style = .control,
};

pub const InitOptions = struct {
    submenu: bool = false,
    highlight_only: bool = false,
    focus_as_outline: bool = false,
};

wd: WidgetData,
highlight: bool = false,
init_opts: InitOptions,
activated: bool = false,
show_active: bool = false,
mouse_over: bool = false,
hover_t: f32 = 0,

/// It's expected to call this when `self` is `undefined`
pub fn init(self: *MenuItem, src: std.builtin.SourceLocation, init_opts: InitOptions, opts: Options) void {
    const options = defaults.override(opts);
    const wd = WidgetData.init(src, .{}, options);

    self.* = .{
        .wd = wd,
        .init_opts = init_opts,
    };

    self.data().register();

    dvui.tabIndexSet(self.data().id, self.data().options.tab_index, self.data().rectScale().r);

    if (self.init_opts.submenu) menu().?.submenu_menuItem_this_frame = true;

    self.data().borderAndBackground(.{});

    dvui.parentSet(self.widget());
    if (self.data().accesskit_node()) |ak_node| {
        AccessKit.nodeAddAction(ak_node, AccessKit.Action.focus);
        AccessKit.nodeAddAction(ak_node, AccessKit.Action.click);
    }
}

pub fn drawBackground(self: *MenuItem) void {
    self.hover_t = dvui.hoverFade(self.data().id, self.highlight);

    var focused: bool = self.data().id == dvui.focusedWidgetId();

    if (self.data().id == dvui.focusedWidgetIdInCurrentSubwindow()) {
        menu().?.focused_menuItem_this_frame = true;
    }

    if (focused and menu().?.mouse_over and !self.mouse_over and (menu().?.submenus_activated or menu().?.floating())) {
        // our menu got a mouse over but we didn't even though we were focused
        focused = false;
        dvui.focusWidget(menu().?.group.data().id, null, null);
    }

    if (focused or ((self.data().id == dvui.focusedWidgetIdInCurrentSubwindow()) and self.highlight)) {
        if (!self.init_opts.submenu or !menu().?.submenus_activated) {
            if (!self.init_opts.highlight_only) {
                if (self.init_opts.focus_as_outline) {
                    self.show_active = true;
                } else if (menu().?.mouse_mode and !menu().?.mouse_over) {
                    // following mouse but it's outside the menu
                } else {
                    self.show_active = true;
                }
            }
        }
    }

    if (self.data().visible()) {
        const rs = self.data().backgroundRectScale();
        // Finalized before scaling, as `WidgetData.init` would have: an unresolved corner draws
        // square whatever radius it names.
        const cr = self.data().options.cornersGet().finalize(self.data().options.themeGet())
            .scale(rs.s, CornerRect.Physical);

        // The row's own style answers what a hover looks like — `Theme.color(style, .fill_hover)`,
        // which dvui derives from the style's fill when a theme does not name one. Nothing is
        // hardcoded here, so a theme gets the final say and every surface that reads the same
        // style (the palette, the flyouts) moves with it.
        //
        // `hover_t` is the only input, except that the title of an open submenu holds at full
        // strength: it is the one row that should stay lit while the pointer is away from it.
        const t: f32 = if (self.highlight) 1.0 else self.hover_t;
        if (t > 0) {
            const hover = self.data().options.color(.fill_hover).toColor();
            rs.r.fill(cr, .{ .color = .{ .color = hover.opacity(t) }, .fade = 1.0 });
        }
    }
}

/// Returns an `Options` struct with color/style overrides for the hover and press state
pub fn style(self: *MenuItem) Options {
    var opts: Options = self.data().options.styleOnly();
    if (self.show_active and !self.init_opts.focus_as_outline) {
        const rest_fill = opts.color(.fill);
        opts.style = .highlight;
        const active_fill = opts.color_fill_hover orelse opts.color(.fill);
        const active_text = opts.color_text_hover orelse opts.color(.text_hover);
        if (self.highlight) {
            opts.color_fill = rest_fill.lerp(active_fill, self.hover_t);
            opts.color_text = active_text;
        } else {
            opts.color_fill = active_fill;
            opts.color_text = active_text;
        }
    } else if (self.hover_t > 0) {
        // mouse is over us (or just left us)
        opts.color_fill = opts.color(.fill).lerp(opts.color_fill_hover orelse opts.color(.fill_hover), self.hover_t);
        opts.color_text = opts.color(.text).lerp(opts.color_text_hover orelse opts.color(.text_hover), self.hover_t);
    }

    return opts;
}

pub fn matchEvent(self: *MenuItem, e: *Event) bool {
    return dvui.eventMatchSimple(e, self.data());
}

pub fn processEvents(self: *MenuItem) void {
    const evts = dvui.events();
    for (evts) |*e| {
        if (!self.matchEvent(e))
            continue;

        self.processEvent(e);
    }
}

pub fn activeRect(self: *const MenuItem) ?Rect.Natural {
    var act = false;
    if (self.init_opts.submenu) {
        if (menu().?.submenus_activated and (self.data().id == dvui.focusedWidgetIdInCurrentSubwindow())) {
            act = true;
        }
    } else if (self.activated) {
        act = true;
    }

    if (act) {
        return self.data().backgroundRectScale().r.toNatural();
    } else {
        return null;
    }
}

pub fn widget(self: *MenuItem) Widget {
    return Widget.init(self, data, rectFor, screenRectScale, minSizeForChild);
}

pub fn data(self: *const MenuItem) *WidgetData {
    return self.wd.validate();
}

pub fn rectFor(self: *MenuItem, id: dvui.Id, min_size: Size, e: Options.Expand, g: Options.Gravity) Rect {
    _ = id;
    return dvui.placeIn(self.data().contentRect().justSize(), min_size, e, g);
}

pub fn screenRectScale(self: *MenuItem, rect: Rect) RectScale {
    return self.data().contentRectScale().rectToRectScale(rect);
}

pub fn minSizeForChild(self: *MenuItem, s: Size) void {
    self.data().minSizeMax(self.data().options.padSize(s));
}

pub fn processEvent(self: *MenuItem, e: *Event) void {
    switch (e.evt) {
        .mouse => |me| {
            if (me.action == .focus) {
                e.handle(@src(), self.data());
                dvui.focusWidget(self.data().id, null, e.num);
            } else if (me.action == .press and me.button.pointer()) {
                // This works differently than normal (like buttons) where we
                // captureMouse on press, to support the mouse
                // click-open-drag-select-release-activate pattern for menus
                // and dropdowns.  However, we still need to do the capture
                // pattern for touch.
                //
                // This is how dropdowns are triggered.
                e.handle(@src(), self.data());
                if (self.init_opts.submenu) {
                    dvui.dataRemove(null, menu().?.data().id, "_submenus_activating");
                    if (!menu().?.floating() and !menu().?.submenus_activated) {
                        // If not floating, then we are toggling focus-on-hover, set a bit
                        dvui.dataSet(null, menu().?.data().id, "_submenus_activating", {});
                    }
                    menu().?.submenus_activated = true;
                }

                if (me.button.touch()) {
                    // with touch we have to capture otherwise any motion will
                    // cause scroll to capture
                    dvui.captureMouse(self.data(), e.num);
                    dvui.dragPreStart(me.button, me.p, .{});
                }
            } else if (me.action == .release) {
                e.handle(@src(), self.data());
                if (self.init_opts.submenu) {
                    // Only non floating menus can toggle focus-on-hover
                    if (!menu().?.floating() and dvui.dataGet(null, menu().?.data().id, "_submenus_activating", void) == null) {
                        // Toggle the submenu closed
                        menu().?.submenus_activated = false;
                        dvui.refresh(null, @src(), self.data().id);
                    }
                } else if (self.data().id == dvui.focusedWidgetIdInCurrentSubwindow()) {
                    self.activated = true;
                    dvui.refresh(null, @src(), self.data().id);
                }

                if (dvui.captured(self.data().id)) {
                    // should only happen with touch
                    dvui.captureMouse(null, e.num);
                }
                dvui.dragEnd();
            } else if (me.action == .motion and me.button.touch()) {
                if (dvui.captured(self.data().id)) {
                    if (dvui.dragging(me.p, null)) |_| {
                        // if we overcame the drag threshold, then that
                        // means the person probably didn't want to touch
                        // this, maybe they were trying to scroll
                        dvui.captureMouse(null, e.num);
                        dvui.dragEnd();
                    }
                }
            } else if (me.action == .position) {
                // We get a .position mouse event every frame.  If we
                // focus the menu item under the mouse even if it's not
                // moving then it breaks keyboard navigation.
                if (dvui.mouseTotalMotion().nonZero()) {
                    if (menu().?.focused_menuItem or menu().?.submenus_activated) {
                        // we shouldn't have gotten this event if the motion
                        // was towards a submenu (caught in Menu)
                        dvui.focusSubwindow(null, null); // focuses the window we are in
                        dvui.focusWidget(self.data().id, null, null);

                        if (self.init_opts.submenu and menu().?.floating()) {
                            menu().?.submenus_activated = true;
                        }
                    }
                }

                if (menu().?.mouse_mode) {
                    self.mouse_over = true;
                    dvui.cursorSet(.arrow);
                    self.highlight = true;
                }
            }
        },
        .key => |ke| {
            if (ke.action == .down and ke.matchBind("activate")) {
                e.handle(@src(), self.data());
                if (self.init_opts.submenu) {
                    menu().?.submenus_activated = true;
                } else {
                    self.activated = true;
                    dvui.refresh(null, @src(), self.data().id);
                }
            } else if (ke.code == .right and ke.action == .down) {
                if (self.init_opts.submenu and menu().?.init_opts.dir == .vertical) {
                    e.handle(@src(), self.data());
                    menu().?.submenus_activated = true;
                }
            } else if (ke.code == .down and ke.action == .down) {
                if (self.init_opts.submenu and menu().?.init_opts.dir == .horizontal) {
                    e.handle(@src(), self.data());
                    menu().?.submenus_activated = true;
                }
            }
        },
        else => {},
    }
}

pub fn deinit(self: *MenuItem) void {
    defer if (dvui.widgetIsAllocated(self)) dvui.widgetFree(self);
    defer self.* = undefined;
    self.data().minSizeSetAndRefresh();
    self.data().minSizeReportToParent();
    dvui.parentReset(self.data().id, self.data().parent);
}

test {
    @import("std").testing.refAllDecls(@This());
}

test "menuItem click sets last_focused_id_this_frame" {
    var t = try dvui.testing.init(.{});
    defer t.deinit();

    const fns = struct {
        var last_focused_id_set: ?dvui.Id = null;

        fn frame() !dvui.App.Result {
            var m = dvui.menu(@src(), .vertical, .{ .padding = .all(10), .tag = "menu" });
            defer m.deinit();

            const last_focused = dvui.lastFocusedIdInFrame();

            if (dvui.menuItemLabel(@src(), "item 1", .{}, .{ .tag = "item 1" })) |_| {
                dvui.focusWidget(m.data().id, null, null);
            }
            _ = dvui.menuItemLabel(@src(), "item 2", .{}, .{ .tag = "item 2" });

            last_focused_id_set = dvui.lastFocusedIdInFrameSince(last_focused);

            return .ok;
        }
    };

    try dvui.testing.settle(fns.frame);

    // clicking on item 2 should tell us that it got focus this frame
    try dvui.testing.moveTo("item 2");
    try dvui.testing.click(.left);
    _ = try dvui.testing.step(fns.frame);
    try std.testing.expect(fns.last_focused_id_set == dvui.tagGet("item 2").?.id);
    try dvui.testing.expectFocused("item 2");

    // clicking on item 1 should tell us that menu got focus this frame
    try dvui.testing.moveTo("item 1");
    try dvui.testing.click(.left);
    _ = try dvui.testing.step(fns.frame);
    try std.testing.expect(fns.last_focused_id_set == dvui.tagGet("menu").?.id);
    try dvui.testing.expectFocused("menu");
}
