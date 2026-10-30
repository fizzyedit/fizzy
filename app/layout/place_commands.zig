//! What a place's menu does to the place (`Picker`'s header): split it, clear it, put it back
//! to the layout's default, delete it. Each is a command, so the palette, a keymap, a tape or an
//! agent reaches it as the menu's button does - the button runs the command.
//!
//! A command only asks: it writes `Picker.request`, and the picker carries the request out in
//! its next draw, where the live `Layout` is. A command may run outside a frame (a control
//! server's call), when there is no `Layout` to split a place with.
const std = @import("std");
const sdk = @import("fizzy_sdk");
const icons = @import("icons");

const State = @import("State.zig");
const Picker = @import("Picker.zig");

/// The commands' owner is a pseudo-plugin, as fizzy's own commands have one (never in
/// `host.plugins`, so no hook fires on it): `Picker.commands_owner`, its state the layout state it
/// is part of.
pub const vtable: sdk.Plugin.VTable = .{};

const PlaceArg = sdk.Command.Params(struct {
    place: sdk.Command.Arg([]const u8, .{ .description = "The place, by name (\"Panel\", \"Main/r1\"). Empty: the place whose menu is open." }) = .init(""),
});

pub const Command = struct {
    id: []const u8,
    title: []const u8,
    action: Picker.Action,
    icon: []const u8,
};

/// Every place command, in the order the menu draws its buttons.
pub const all = [_]Command{
    .{ .id = "layout.place.splitRight", .title = "Place: Split Right", .action = .split_right, .icon = icons.tvg.lucide.@"columns-2" },
    .{ .id = "layout.place.splitDown", .title = "Place: Split Down", .action = .split_down, .icon = icons.tvg.lucide.@"rows-2" },
    .{ .id = "layout.place.split", .title = "Place: Split", .action = .split, .icon = icons.tvg.lucide.@"square-split-horizontal" },
    .{ .id = "layout.place.adaptive", .title = "Place: Split Follows the Room", .action = .adaptive, .icon = icons.tvg.lucide.@"rotate-cw-square" },
    .{ .id = "layout.place.clear", .title = "Place: Clear", .action = .clear, .icon = icons.tvg.lucide.eraser },
    .{ .id = "layout.place.reset", .title = "Place: Reset to the Layout's Default", .action = .reset, .icon = icons.tvg.lucide.@"rotate-ccw" },
    .{ .id = "layout.place.delete", .title = "Place: Delete", .action = .delete, .icon = icons.tvg.lucide.@"trash-2" },
};

/// What `action` is called where a person reads it: its command's title.
pub fn title(action: Picker.Action) []const u8 {
    inline for (all) |c| if (c.action == action) return c.title;
    unreachable;
}

/// Register the place commands against `state`, which must outlive them: call it once the
/// application's layout state is at its final address.
pub fn register(host: *sdk.Host, state: *State) !void {
    const owner = &state.picker.commands_owner;
    owner.state = state;
    inline for (all) |c| {
        try host.registerCommand(.{
            .id = c.id,
            .owner = owner,
            .title = c.title,
            .icon = c.icon,
            .params = PlaceArg.params,
            .runWith = PlaceArg.bind(struct {
                fn run(s: *anyopaque, args: PlaceArg.Args, call: *sdk.Command.Call) anyerror!void {
                    return ask(@ptrCast(@alignCast(s)), c.action, args.place, call);
                }
            }.run),
        });
    }
}

fn ask(state: *State, action: Picker.Action, given: []const u8, call: *sdk.Command.Call) !void {
    const picker = &state.picker;
    const name = if (given.len > 0) given else if (picker.is_open) picker.region else return call.fail("no place's menu is open: name the place", .{});
    const known = for (state.regions.items) |r| {
        if (std.mem.eql(u8, r.name, name)) break true;
    } else false;
    if (!known) return call.fail("no place named '{s}'", .{name});
    if (!Picker.allows(state, name, action)) return call.fail("{s} does not apply to '{s}'", .{ title(action), name });
    if (!picker.ask(action, name)) return call.fail("the place name is too long, or too many place commands are waiting", .{});
}
