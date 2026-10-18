//! dvui's `Popup`, rebuilt on this module's menu chain so it can be frosted: a floating menu
//! dismissed by escape or a click outside, driven by an `open_flag`. dvui's builds its floating
//! menu from `dvui.FloatingMenuWidget`, which paints its background inside `init` where no frost
//! can get beneath it (see `FloatingMenu.zig`); this one passes `frost` through.
const std = @import("std");
const dvui = @import("dvui");

const Menu = @import("Menu.zig");
const FloatingMenu = @import("FloatingMenu.zig");
const BlurBackdrop = @import("glass").BlurBackdrop;

const Popup = @This();

pub const InitOptions = struct {
    /// If true, the popup shows. It sets this to false when escape is pressed, a click lands
    /// outside it, or code closes it.
    open_flag: *bool,
    /// Null centres the popup on the active subwindow; otherwise its top left sits here.
    from: ?dvui.Point.Natural = null,
    /// Blur what is behind it, as a dialog does (`FloatingMenu.InitOptions.frost`).
    frost: ?BlurBackdrop.Pane = null,
};

init_opts: InitOptions,
menu: ?Menu = null,
floating: FloatingMenu,

/// Shows the popup and returns it while `open_flag.*` is true; null (and nothing drawn) when not.
pub fn active(self: *Popup, src: std.builtin.SourceLocation, init_opts: InitOptions, opts: dvui.Options) ?*Popup {
    self.* = .{
        .init_opts = init_opts,
        .floating = undefined,
    };

    if (!self.init_opts.open_flag.*) {
        self.deinit();
        return null;
    }

    // An invisible parent menu: the floating menu reports a dismissal by deactivating its
    // parent's submenus, which is how `deinit` knows to clear the flag.
    self.menu = @as(Menu, undefined);
    self.menu.?.init(src, .{ .dir = .horizontal }, .{ .rect = .{} });
    self.menu.?.submenus_activated = true;
    self.floating.init(@src(), .{
        .style = .popup,
        .from = if (init_opts.from) |f| .fromPoint(f) else null,
        .frost = init_opts.frost,
    }, opts);

    return self;
}

pub fn deinit(self: *Popup) void {
    defer if (dvui.widgetIsAllocated(self)) dvui.widgetFree(self);
    defer self.* = undefined;

    if (self.menu) |*m| {
        self.floating.deinit();
        if (m.submenus_activated == false) {
            self.init_opts.open_flag.* = false;
        }
        m.deinit();
    }
}
