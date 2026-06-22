//! Shared "W x H unit" label row for New File / Export dialogs.
const std = @import("std");
const dvui = @import("dvui");

pub fn drawDimensionsLabel(src: std.builtin.SourceLocation, width: u32, height: u32, font: dvui.Font, unit: []const u8, opts: dvui.Options) void {
    var hbox = dvui.box(src, .{ .dir = .horizontal }, opts);
    defer hbox.deinit();

    dvui.label(
        src,
        "{d}",
        .{width},
        .{
            .font = font,
            .margin = .{ .x = 1, .w = 1 },
            .padding = .all(0),
            .gravity_y = 1.0,
            .id_extra = 1,
        },
    );

    dvui.label(
        src,
        "{s}",
        .{unit},
        .{
            .font = dvui.Font.theme(.body).withSize(font.size - 1.0),
            .margin = .{ .x = 1, .w = 1 },
            .padding = .all(0),
            .gravity_y = 0.5,
            .id_extra = 2,
        },
    );

    dvui.label(
        src,
        "x",
        .{},
        .{
            .font = dvui.Font.theme(.body).withSize(font.size - 1.0),
            .margin = .{ .x = 1, .w = 1 },
            .padding = .all(0),
            .gravity_y = 0.5,
            .id_extra = 3,
        },
    );

    dvui.label(
        src,
        "{d}",
        .{height},
        .{
            .font = font,
            .margin = .{ .x = 1, .w = 1 },
            .padding = .all(0),
            .gravity_y = 0.5,
            .id_extra = 4,
        },
    );

    dvui.label(
        src,
        "{s}",
        .{unit},
        .{
            .font = dvui.Font.theme(.body).withSize(font.size - 1.0),
            .margin = .{ .x = 1, .w = 1 },
            .padding = .all(0),
            .gravity_y = 0.5,
            .id_extra = 5,
        },
    );
}
