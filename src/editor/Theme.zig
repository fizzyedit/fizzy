const std = @import("std");
const builtin = @import("builtin");

const fizzy = @import("../fizzy.zig");

const Entry = fizzy.Entry;
const Color = fizzy.core.math.Color;

const Theme = @This();

background: Color = Color.initBytes(34, 35, 42, 255),
foreground: Color = Color.initBytes(42, 44, 54, 255),
text: Color = Color.initBytes(230, 175, 137, 255),
text_secondary: Color = Color.initBytes(159, 159, 176, 255),
text_background: Color = Color.initBytes(97, 97, 106, 255),

text_blue: Color = Color.initBytes(110, 150, 200, 255),
text_orange: Color = Color.initBytes(183, 113, 96, 255),
text_yellow: Color = Color.initBytes(214, 199, 130, 255),
text_red: Color = Color.initBytes(206, 120, 105, 255),

highlight_primary: Color = Color.initBytes(47, 179, 135, 255),
hover_primary: Color = Color.initBytes(76, 148, 123, 255),

highlight_secondary: Color = Color.initBytes(76, 48, 67, 255),
hover_secondary: Color = Color.initBytes(105, 50, 68, 255),

checkerboard_primary: Color = Color.initBytes(150, 150, 150, 255),
checkerboard_secondary: Color = Color.initBytes(100, 100, 100, 255),

modal_dim: Color = Color.initBytes(0, 0, 0, 48),

pub fn save(theme: Theme, path: [:0]const u8) !void {
    var handle = try std.fs.cwd().createFile(path, .{});
    defer handle.close();

    const out_stream = handle.writer();
    const options = std.json.StringifyOptions{};

    try std.json.stringify(theme, options, out_stream);
}
