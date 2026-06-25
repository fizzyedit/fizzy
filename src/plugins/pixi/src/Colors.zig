const std = @import("std");
const pixi_mod = @import("../pixi.zig");
const runtime = @import("runtime.zig");

const Self = @This();

primary: [4]u8 = .{ 255, 255, 255, 255 },
secondary: [4]u8 = .{ 0, 0, 0, 255 },
height: u8 = 0,
palette: ?pixi_mod.internal.Palette = null,
file_tree_palette: ?pixi_mod.internal.Palette = null,
