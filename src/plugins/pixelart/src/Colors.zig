const std = @import("std");
const pixelart = @import("../pixelart.zig");
const Globals = pixelart.Globals;

const Self = @This();

primary: [4]u8 = .{ 255, 255, 255, 255 },
secondary: [4]u8 = .{ 0, 0, 0, 255 },
height: u8 = 0,
palette: ?pixelart.internal.Palette = null,
file_tree_palette: ?pixelart.internal.Palette = null,
