//! The in-app menu bar's order, which isn't registration order.
//!
//! Fizzy registers File/Edit/View/Help after the bundled plugins, and a plugin loaded later
//! lands after Help. The bar is ordered as the native macOS bar is (`platform.menu.setExtras`
//! inserts before Help): fizzy's menus but Help, then every plugin's in registration order, then
//! Help. std-only, so it tests without a window; `Menu.draw` walks it.
//!
//! Fizzy's own menus are the ones drawn by its model renderer, not the ones with no `owner`: a
//! plugin may leave `owner` unset.

const std = @import("std");

/// Walks `menus` (a slice of `MenuContribution`, or anything with its `hidden`, `draw` and `ctx`
/// fields) in bar order, skipping hidden ones. `own_draw` is fizzy's model renderer, and
/// `help_ctx` the `ctx` of fizzy's Help.
pub fn Iterator(comptime T: type) type {
    return struct {
        menus: []T,
        own_draw: @FieldType(T, "draw"),
        help_ctx: ?*anyopaque,
        phase: enum { fizzy, plugins, help } = .fizzy,
        i: usize = 0,

        pub fn next(self: *@This()) ?*T {
            while (true) {
                if (self.i == self.menus.len) {
                    self.i = 0;
                    self.phase = switch (self.phase) {
                        .fizzy => .plugins,
                        .plugins => .help,
                        .help => return null,
                    };
                    continue;
                }
                const menu = &self.menus[self.i];
                self.i += 1;
                if (menu.hidden) continue;
                const own = menu.draw == self.own_draw;
                const help = own and menu.ctx == self.help_ctx;
                const in_phase = switch (self.phase) {
                    .fizzy => own and !help,
                    .plugins => !own,
                    .help => help,
                };
                if (in_phase) return menu;
            }
        }
    };
}

test "fizzy's menus, then plugins' in registration order, then Help" {
    const Draw = *const fn (ctx: ?*anyopaque) anyerror!void;
    const fns = struct {
        fn model(_: ?*anyopaque) anyerror!void {}
        fn plugin(_: ?*anyopaque) anyerror!void {}
    };
    const Owner = struct { id: u8 };
    var owner: Owner = .{ .id = 0 };
    const Menu = struct {
        id: []const u8,
        owner: ?*Owner = null,
        hidden: bool = false,
        ctx: ?*anyopaque = null,
        draw: Draw,
    };
    var file: u8 = 0;
    var view: u8 = 0;
    var help: u8 = 0;
    var menus = [_]Menu{
        .{ .id = "a", .owner = &owner, .draw = &fns.plugin },
        // No owner, yet not fizzy's: still a plugin's.
        .{ .id = "b", .draw = &fns.plugin },
        .{ .id = "hidden", .owner = &owner, .hidden = true, .draw = &fns.plugin },
        .{ .id = "file", .ctx = &file, .draw = &fns.model },
        .{ .id = "view", .ctx = &view, .draw = &fns.model },
        .{ .id = "help", .ctx = &help, .draw = &fns.model },
        // Loaded after fizzy registered its own.
        .{ .id = "c", .owner = &owner, .draw = &fns.plugin },
    };

    var it: Iterator(Menu) = .{ .menus = &menus, .own_draw = &fns.model, .help_ctx = &help };
    const want = [_][]const u8{ "file", "view", "a", "b", "c", "help" };
    for (want) |id| try std.testing.expectEqualStrings(id, it.next().?.id);
    try std.testing.expect(it.next() == null);
}
