const std = @import("std");
const fizzy = @import("../fizzy.zig");
const dvui = @import("dvui");

const palette_parse = @import("palette_parse.zig");

pub const Palette = @This();

name: []const u8,
colors: [][4]u8,

pub fn getDVUIColor(self: *Palette, id: usize) dvui.Color {
    const new_id = id % self.colors.len;
    return .{ .r = self.colors[new_id][0], .g = self.colors[new_id][1], .b = self.colors[new_id][2], .a = self.colors[new_id][3] };
}

pub fn loadFromFile(allocator: std.mem.Allocator, file: []const u8) !Palette {
    const ext = std.fs.path.extension(file);

    if (std.mem.eql(u8, ext, ".hex")) {
        if (fizzy.fs.read(fizzy.app.allocator, dvui.io, file) catch null) |read| {
            defer fizzy.app.allocator.free(read);

            return loadFromBytes(allocator, std.fs.path.basename(file), read);
        }
    }
    return error.WrongFileType;
}

pub fn loadFromBytes(allocator: std.mem.Allocator, name: []const u8, bytes: []const u8) !Palette {
    const colors = palette_parse.parseHexBytes(allocator, bytes) catch |err| {
        switch (err) {
            error.InvalidHexLine => {
                dvui.log.err("Failed to parse palette: invalid hex line", .{});
                return error.FailedToParseColor;
            },
            error.OutOfMemory => return error.OutOfMemory,
        }
    };

    return .{
        .name = try allocator.dupe(u8, name),
        .colors = colors,
    };
}

pub fn deinit(self: *Palette) void {
    fizzy.app.allocator.free(self.name);
    fizzy.app.allocator.free(self.colors);
}
