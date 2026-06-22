//! Draws the shell's built-in "Output" bottom panel: a scrolling, color-coded view of
//! everything captured in `OutputLog`. Registered with `owner = null` in `Editor.zig`,
//! same as the Settings sidebar view.

const std = @import("std");
const dvui = @import("dvui");
const OutputLog = @import("OutputLog.zig");

/// Persisted across frames so we can auto-scroll and detect newly-arrived lines.
var scroll_info: dvui.ScrollInfo = .{};
var follow = true;
var last_seen_count: usize = 0;

pub fn draw(_: ?*anyopaque) anyerror!void {
    var vbox = dvui.box(@src(), .{ .dir = .vertical }, .{ .expand = .both });
    defer vbox.deinit();

    OutputLog.lock();
    defer OutputLog.unlock();
    const lines = OutputLog.items();

    if (follow and lines.len != last_seen_count) {
        scroll_info.scrollToFraction(.vertical, 1.0);
    }
    last_seen_count = lines.len;

    var scroll = dvui.scrollArea(@src(), .{ .scroll_info = &scroll_info }, .{ .expand = .both });

    const mono: dvui.Options = .{ .font = dvui.Font.theme(.mono) };
    const message_color: dvui.Options = .{ .color_text = dvui.themeGet().color(.window, .text).opacity(0.6) };

    // One shared `TextLayoutWidget` for every line (not one per line): dvui's text
    // selection is per-widget, so a single widget is what lets a click-drag span multiple
    // lines instead of stopping dead at each line's own boundary.
    var tl = dvui.textLayout(@src(), .{}, .{
        .expand = .both,
        .background = false,
        .margin = .all(2),
        .padding = .all(0),
    });

    for (lines, 0..) |line, i| {
        if (i > 0) tl.addText("\n", mono);
        // Only the "level(scope): " prefix gets the level color — the message stays the
        // default text color, so a long line doesn't read as one solid block of red/purple.
        if (std.mem.indexOf(u8, line.text, ": ")) |idx| {
            tl.addText(line.text[0 .. idx + 2], mono.override(.{ .color_text = levelColor(line.level) }));
            tl.addText(line.text[idx + 2 ..], mono.override(message_color));
        } else {
            tl.addText(line.text, mono.override(.{ .color_text = levelColor(line.level).opacity(0.6) }));
        }
    }

    tl.deinit();
    scroll.deinit();

    // Re-arm auto-follow only once the viewport is back at the bottom (whether the user
    // scrolled back down themselves, or nothing ever pushed it away). Any other position
    // means the user scrolled up, so leave it be until they return to the bottom.
    follow = scroll_info.offsetFromMax(.vertical) < 1.0;
}

fn levelColor(level: std.log.Level) dvui.Color {
    return switch (level) {
        .err => .{ .r = 0xe0, .g = 0x6c, .b = 0x75 }, // red
        .warn => .{ .r = 0xd1, .g = 0x9a, .b = 0x66 }, // orange
        .info => .{ .r = 0xe5, .g = 0xc0, .b = 0x7b }, // yellow
        .debug => .{ .r = 0xc6, .g = 0x78, .b = 0xdd }, // purple
    };
}
