//! Draws fizzy's built-in "Output" bottom panel: a scrolling, color-coded view of
//! everything captured in `OutputLog`, with a vertical tab strip on the left to filter by
//! source scope ("All" plus one tab per plugin/scope seen so far). Registered with
//! `owner = null` in `Editor.zig`, same as the Settings sidebar view.

const std = @import("std");
const dvui = @import("dvui");
const OutputLog = @import("OutputLog.zig");

/// Persisted across frames so we can auto-scroll and detect newly-arrived lines.
var scroll_info: dvui.ScrollInfo = .{};
var follow = true;
var last_seen_count: usize = 0;

/// Selected tab, persisted as a bounded copy rather than a slice into `OutputLog`'s ring
/// buffer — a scope string there can be freed on eviction or plugin unload between frames.
/// Zero length means the "All" tab.
var selected_scope_buf: [64]u8 = undefined;
var selected_scope_len: usize = 0;

fn selectedScope() ?[]const u8 {
    return if (selected_scope_len == 0) null else selected_scope_buf[0..selected_scope_len];
}

fn selectScope(name: []const u8) void {
    const n = @min(name.len, selected_scope_buf.len);
    @memcpy(selected_scope_buf[0..n], name[0..n]);
    selected_scope_len = n;
}

pub fn draw(_: ?*anyopaque) anyerror!dvui.App.Result {
    var hbox = dvui.box(@src(), .{ .dir = .horizontal }, .{ .expand = .both });
    defer hbox.deinit();

    // Snapshot into the frame arena rather than holding `OutputLog`'s lock across the draw
    // below: that draw resolves the theme's mono font (see `mono` below), and some themes'
    // fonts fail to resolve, which logs a warning — reentering `OutputLog.append` on this
    // same thread. Holding the lock that long turns that into a self-deadlock (the log's
    // spinlock is not reentrant), so we copy what we need and unlock before drawing anything.
    const arena = dvui.currentWindow().arena();
    const lines: []const OutputLog.Line = blk: {
        OutputLog.lock();
        defer OutputLog.unlock();
        const src = OutputLog.items();
        const copy = arena.alloc(OutputLog.Line, src.len) catch break :blk &.{};
        for (src, copy) |s, *d| {
            d.* = .{
                .level = s.level,
                .scope = arena.dupe(u8, s.scope) catch "",
                .text = arena.dupe(u8, s.text) catch "",
            };
        }
        break :blk copy;
    };

    // Distinct scopes seen so far, in first-seen order — small (one per active plugin), so a
    // linear scan per line is cheap.
    var scopes: std.ArrayListUnmanaged([]const u8) = .empty;
    for (lines) |line| {
        var seen = false;
        for (scopes.items) |s| {
            if (std.mem.eql(u8, s, line.scope)) {
                seen = true;
                break;
            }
        }
        if (!seen) scopes.append(arena, line.scope) catch {};
    }

    drawTabStrip(scopes.items);

    const selected = selectedScope();

    var vbox = dvui.box(@src(), .{ .dir = .vertical }, .{ .expand = .both });
    defer vbox.deinit();

    if (follow and lines.len != last_seen_count) {
        scroll_info.scrollToFraction(.vertical, 1.0);
    }
    last_seen_count = lines.len;

    var scroll = dvui.scrollArea(@src(), .{ .scroll_info = &scroll_info }, .{ .expand = .both, .background = false });

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

    var shown: usize = 0;
    for (lines) |line| {
        if (selected) |s| {
            if (!std.mem.eql(u8, s, line.scope)) continue;
        }
        if (shown > 0) tl.addText("\n", mono);
        shown += 1;
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
    return .ok;
}

/// Narrow vertical strip of tab buttons: "All" first, then one per distinct scope in
/// `scopes` (first-seen order). Mirrors the workbench tab bar's selected/unselected
/// convention — `.window` colors for the active tab, `.control` for the rest.
fn drawTabStrip(scopes: []const []const u8) void {
    var strip = dvui.box(@src(), .{ .dir = .vertical }, .{
        .expand = .vertical,
        .min_size_content = .{ .w = 120 },
        .background = false,
        .gravity_x = 1.0,
        .color_fill = dvui.themeGet().color(.control, .fill),
    });
    defer strip.deinit();

    drawTab(@src(), "All", 0, selected_scope_len == 0);
    for (scopes, 1..) |scope, i| {
        drawTab(@src(), scope, i, selectedScope() != null and std.mem.eql(u8, selectedScope().?, scope));
    }
}

fn drawTab(src: std.builtin.SourceLocation, label: []const u8, id_extra: usize, selected: bool) void {
    const clicked = dvui.button(src, label, .{}, .{
        .id_extra = id_extra,
        .expand = .horizontal,
        .margin = .{ .x = 2, .y = 1 },
        .color_fill = if (selected) null else .transparent,
        .style = if (selected) .highlight else null,
        .padding = .all(1),
    });
    if (clicked) {
        if (id_extra == 0) {
            selected_scope_len = 0;
        } else {
            selectScope(label);
        }
    }
}

fn levelColor(level: std.log.Level) dvui.Color {
    return switch (level) {
        .err => .{ .r = 0xe0, .g = 0x6c, .b = 0x75 }, // red
        .warn => .{ .r = 0xd1, .g = 0x9a, .b = 0x66 }, // orange
        .info => .{ .r = 0xe5, .g = 0xc0, .b = 0x7b }, // yellow
        .debug => .{ .r = 0xc6, .g = 0x78, .b = 0xdd }, // purple
    };
}
