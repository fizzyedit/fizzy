const std = @import("std");
const fizzy = @import("../fizzy.zig");

const Self = @This();

primary: [4]u8 = .{ 255, 255, 255, 255 },
secondary: [4]u8 = .{ 0, 0, 0, 255 },
height: u8 = 0,
palette: ?fizzy.Internal.Palette = null,
file_tree_palette: ?fizzy.Internal.Palette = null,
