//! Draws fizzy's built-in "Output" bottom panel: a scrolling, color-coded view of
//! everything captured in `OutputLog`, with a vertical tab strip on the left to filter by
//! source scope ("All" plus one tab per plugin/scope seen so far). Registered with
//! `owner = null` in `Editor.zig`, same as the Settings sidebar view.

const std = @import("std");
const dvui = @import("dvui");
const OutputLog = @import("OutputLog.zig");

/// Persisted across frames so we can auto-scroll and detect newly-arrived lines.
var scroll_info: dvui.ScrollInfo = .{ .horizontal = .auto };
var follow = true;
/// One line's height as the text layout measured it last frame. Zero until measured, which
/// lays every line out once so there is something to measure.
/// Height of one log row. Taken from the mono font each frame, never measured off the laid-out
/// text: a measurement is a frame behind and was divided by a line count that changes as the
/// viewport moves, so the estimate drifted, the spacers changed height, the viewport clamped,
/// the visible range moved, and the panel oscillated for as long as the log overflowed it.
var line_pitch: f32 = 0;

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
    //
    // Only the lines in the viewport are copied and laid out. The log only grows, and laying
    // out every line of it each frame — for the fifteen that fit — was a frame cost that grew
    // with the session. Lines are one row each (`break_lines = false`, the panel scrolls
    // sideways instead), so a line's row is its index times `line_pitch` and the lines above
    // and below the viewport are two spacers of their height.
    const arena = dvui.currentWindow().arena();
    const selected = selectedScope();
    line_pitch = dvui.Font.theme(.mono).lineHeight();
    var scopes: std.ArrayListUnmanaged([]const u8) = .empty;
    var shown_total: usize = 0;
    var lines: []OutputLog.Line = &.{};
    var first: usize = 0;
    {
        OutputLog.lock();
        defer OutputLog.unlock();
        const src = OutputLog.items();
        // Distinct scopes seen so far, in first-seen order — small (one per active plugin), so
        // a linear scan per line is cheap. Counted here too: the range below needs the total.
        const shown_idx = arena.alloc(u32, src.len) catch return .ok;
        for (src, 0..) |line, i| {
            var seen = false;
            for (scopes.items) |sc| {
                if (std.mem.eql(u8, sc, line.scope)) {
                    seen = true;
                    break;
                }
            }
            if (!seen) scopes.append(arena, arena.dupe(u8, line.scope) catch "") catch {};
            if (selected) |sel| {
                if (!std.mem.eql(u8, sel, line.scope)) continue;
            }
            if (shown_total < shown_idx.len) shown_idx[shown_total] = @intCast(i);
            shown_total += 1;
        }
        var end: usize = shown_total;
        if (line_pitch > 0 and scroll_info.viewport.h > 0) {
            // Following the tail: the viewport is about to be at the bottom, so cut the
            // range there rather than where last frame's offset was.
            const vp_y = if (follow)
                @max(0, @as(f32, @floatFromInt(shown_total)) * line_pitch - scroll_info.viewport.h)
            else
                scroll_info.viewport.y;
            first = @min(shown_total, @as(usize, @intFromFloat(@max(0, @floor(vp_y / line_pitch)))));
            end = @min(shown_total, @as(usize, @intFromFloat(@ceil((vp_y + scroll_info.viewport.h) / line_pitch) + 1)));
        }
        lines = arena.alloc(OutputLog.Line, end - first) catch &.{};
        for (lines, first..) |*d, k| {
            const line = src[shown_idx[k]];
            d.* = .{
                .level = line.level,
                .scope = "",
                .text = arena.dupe(u8, line.text) catch "",
            };
        }
    }

    drawTabStrip(scopes.items);

    var vbox = dvui.box(@src(), .{ .dir = .vertical }, .{ .expand = .both });
    defer vbox.deinit();

    // Held at the bottom every frame while following, not only when a line arrives: the first
    // frames lay the log out before its size is known, and a scroll asked for then lands at 0.
    if (follow) scroll_info.scrollToFraction(.vertical, 1.0);
    const asked_y = scroll_info.viewport.y;

    var scroll = dvui.scrollArea(@src(), .{ .scroll_info = &scroll_info }, .{ .expand = .both, .background = false });
    if (first > 0) {
        _ = dvui.spacer(@src(), .{ .min_size_content = .{ .h = @as(f32, @floatFromInt(first)) * line_pitch }, .expand = .horizontal });
    }

    const mono: dvui.Options = .{ .font = dvui.Font.theme(.mono) };
    const message_color: dvui.Options = .{ .color_text = .{ .color = dvui.themeGet().color(.window, .text).opacity(0.6) } };

    // One shared `TextLayoutWidget` for every line (not one per line): dvui's text
    // selection is per-widget, so a single widget is what lets a click-drag span multiple
    // lines instead of stopping dead at each line's own boundary.
    var tl = dvui.textLayout(@src(), .{ .break_lines = false }, .{
        .expand = .horizontal,
        .background = false,
        .margin = .{},
        .padding = .{},
    });

    var shown: usize = 0;
    for (lines) |line| {
        if (shown > 0) tl.addText("\n", mono);
        shown += 1;
        // Only the "level(scope): " prefix gets the level color — the message stays the
        // default text color, so a long line doesn't read as one solid block of red/purple.
        if (std.mem.indexOf(u8, line.text, ": ")) |idx| {
            tl.addText(line.text[0 .. idx + 2], mono.override(.{ .color_text = .{ .color = levelColor(line.level) } }));
            tl.addText(line.text[idx + 2 ..], mono.override(message_color));
        } else {
            tl.addText(line.text, mono.override(.{ .color_text = .{ .color = levelColor(line.level).opacity(0.6) } }));
        }
    }

    tl.deinit();
    const after = shown_total - first - lines.len;
    if (after > 0) {
        _ = dvui.spacer(@src(), .{ .min_size_content = .{ .h = @as(f32, @floatFromInt(after)) * line_pitch }, .expand = .horizontal });
    }
    scroll.deinit();

    // Following breaks only when the user scrolls up from where it was put — a viewport that
    // ended the frame above `asked_y` was moved by a wheel or a bar drag, not by the log
    // growing under it. It re-arms once the viewport is back at the bottom (whether the user
    // scrolled back down themselves, or nothing ever pushed it away).
    if (follow) {
        if (scroll_info.viewport.y + 1.0 < asked_y) follow = false;
    } else {
        follow = scroll_info.offsetFromMax(.vertical) < 1.0;
    }
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
        .color_fill = .{ .color = dvui.themeGet().color(.control, .fill) },
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
