//! A named, invocable action a plugin registers with the Host. Fizzy, menus, and keybindings
//! trigger it by `id` via `Host.runCommand(id)` **without knowing what it does** — this is how a
//! plugin contributes its own features (atlas pack, raster transform, a grid-layout dialog, …)
//! without the SDK or fizzy naming them. Ids are plugin-namespaced (`"pixi.packProject"`).
//! The owner resolves any context it needs (active doc, selection, …) inside `run`; fizzy passes
//! only the owner's opaque state.
const Plugin = @import("Plugin.zig");

const Command = @This();

id: []const u8,
owner: ?*Plugin = null,
/// User-facing label (menus / future command palette).
title: []const u8,
/// Invoke the command. `state` is the owning plugin's opaque state (`owner.state`).
run: *const fn (state: *anyopaque) anyerror!void,
/// Optional enabled-state query — e.g. grey out while busy or with no active document.
/// Absent = always enabled.
isEnabled: ?*const fn (state: *anyopaque) bool = null,
/// Optional TVG icon bytes (e.g. `icons.tvg.lucide.save`) shown ahead of this command's label
/// wherever fizzy draws a row for it: the in-app dvui menu (a fizzy-owned `CommandItem`'s row,
/// or a plugin's `menus.SectionContribution` row via `Host.drawMenuItem`) and the command
/// palette. Absent draws no icon, not a placeholder glyph.
icon: ?[]const u8 = null,
