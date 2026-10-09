//! The caption buttons fizzy draws where its window has no title bar of its own (Windows,
//! Linux): minimize, maximize or restore, close, over the top-right corner of the content. Each
//! in its own desktop's style — Windows 11's flush cells with the red close, GNOME's round
//! buttons — and every glyph drawn as those desktops draw theirs: lines a whole number of pixels
//! thick on the pixel grid, sharp at any scale, rather than an icon scaled into the cell.
//!
//! The rects go to the backend's title-bar hints either way. On Windows its `WM_NCHITTEST`
//! answers the caption-button codes for them — snap layouts on maximize, the OS's own click —
//! and reports the hovered one; on Linux the hit test leaves them to the app, which hovers and
//! clicks them here.
const std = @import("std");
const builtin = @import("builtin");
const dvui = @import("dvui");
const fizzy = @import("../fizzy.zig");
const Constants = @import("Constants.zig");

const Button = fizzy.backend.TitleBarButton;

pub const Style = enum { windows, gnome };
pub const style: Style = if (builtin.os.tag == .linux) .gnome else .windows;

/// Draws the buttons in the top-right corner of `frame`, the window's frame within it (inside the
/// margin for its shadow on Linux). `corner_radius`: the window's own where fizzy rounds it
/// (Linux, windowed) — a cell in the corner follows it.
pub fn draw(frame: dvui.Rect, corner_radius: ?f32) void {
    switch (style) {
        .windows => drawWindows(frame, corner_radius),
        .gnome => drawGnome(frame),
    }
}

/// Windows 11: three 46-point cells flush with the top-right corner, a hover fill across the
/// cell, red under the close. 10-point glyphs, one pixel thick at 100%.
fn drawWindows(frame: dvui.Rect, corner_radius: ?f32) void {
    const cell_w: f32 = 46;
    const cell_h = Constants.titlebar_height;
    const theme = dvui.themeGet();

    var fw: dvui.FloatingWidget = undefined;
    fw.init(@src(), .{ .mouse_events = true }, .{
        .rect = .{ .x = frame.x + frame.w - cell_w * 3, .y = frame.y, .w = cell_w * 3, .h = cell_h },
    });
    defer fw.deinit();
    var row = dvui.box(@src(), .{ .dir = .horizontal }, .{ .expand = .both });
    defer row.deinit();

    const hovered = fizzy.backend.getHoveredTitleBarButton();
    const hover_fill = theme.color(.control, .fill_hover).lighten(if (theme.dark) 3 else -3);
    const close_red = dvui.Color{ .r = 232, .g = 17, .b = 35, .a = 255 };
    const maximized = fizzy.backend.isMaximized(dvui.currentWindow());
    for ([_]Button{ .minimize, .maximize, .close }) |button| {
        const hover = hovered == button;
        const close = button == .close;
        var b = dvui.box(@src(), .{ .dir = .horizontal }, .{
            .role = .button,
            .label = .{ .text = nameOf(button, maximized) },
            .id_extra = @intFromEnum(button),
            .min_size_content = .{ .w = cell_w, .h = cell_h },
            .expand = .vertical,
            .background = hover,
            .color_fill = .{ .color = if (close) close_red.opacity(0.5) else hover_fill },
            .corners = if (close and corner_radius != null) .{ .tr = .round(corner_radius.?) } else null,
        });
        defer b.deinit();
        const rs = b.data().borderRectScale();
        fizzy.backend.setTitleBarCaptionButtonRect(button, rs.r);
        const color = if (close and hover) dvui.Color{ .r = 255, .g = 255, .b = 255, .a = 255 } else theme.color(.control, .text);
        drawGlyph(glyphFor(button, maximized), rs, 10, color);
    }
}

/// GNOME (Adwaita): 24-point round buttons, a faint disc of the text colour under each that
/// deepens on hover and press, centred in the title strip.
fn drawGnome(frame: dvui.Rect) void {
    const d: f32 = 24;
    const gap: f32 = 8;
    const right: f32 = 10;
    const w = d * 3 + gap * 2;
    const theme = dvui.themeGet();
    const text = theme.color(.control, .text);
    // Centred in the whole title strip, top buffer and all, as GNOME centres them in its header bar.
    const y = (Constants.titlebar_top_buffer + Constants.titlebar_height - d) / 2;

    var fw: dvui.FloatingWidget = undefined;
    fw.init(@src(), .{ .mouse_events = true }, .{
        .rect = .{ .x = frame.x + frame.w - right - w, .y = frame.y + y, .w = w, .h = d },
    });
    defer fw.deinit();
    var row = dvui.box(@src(), .{ .dir = .horizontal }, .{ .expand = .both });
    defer row.deinit();

    const maximized = fizzy.backend.isMaximized(dvui.currentWindow());
    for ([_]Button{ .minimize, .maximize, .close }, 0..) |button, i| {
        var b = dvui.box(@src(), .{ .dir = .horizontal }, .{
            .role = .button,
            .label = .{ .text = nameOf(button, maximized) },
            .id_extra = @intFromEnum(button),
            .min_size_content = .{ .w = d, .h = d },
            .margin = .{ .x = if (i == 0) 0 else gap },
        });
        defer b.deinit();
        // The border rect: the cell without its margin (the gap before it).
        const rs = b.data().borderRectScale();
        fizzy.backend.setTitleBarCaptionButtonRect(button, rs.r);
        clickThrough(b.data(), button);
        const pressed = dvui.captured(b.data().id);
        const hover = rs.r.contains(dvui.currentWindow().mouse_pt);
        // A rect rounded all the way: an arc's seam leaves a speck in the fringe.
        rs.r.fill(.round(rs.r.w / 2), .{
            .color = .{ .color = text.opacity(if (pressed) 0.3 else if (hover) 0.15 else 0.1) },
            .fade = 1.0,
        });
        drawGlyph(glyphFor(button, maximized), rs, 10, text);
    }
}

/// Where the app takes the click (Linux): the button does what the desktop's would.
fn clickThrough(wd: *dvui.WidgetData, button: Button) void {
    if (dvui.clicked(wd, .{ .hover_cursor = null })) fizzy.backend.performTitleBarButton(dvui.currentWindow(), button);
}

const Glyph = enum { minimize, maximize, restore, close };

/// What a screen reader or a script calls the button: its glyph is drawn, never written.
fn nameOf(button: Button, maximized: bool) []const u8 {
    return switch (glyphFor(button, maximized)) {
        .minimize => "Minimize",
        .maximize => "Maximize",
        .restore => "Restore",
        .close => "Close Window",
    };
}

fn glyphFor(button: Button, maximized: bool) Glyph {
    return switch (button) {
        .minimize => .minimize,
        .maximize => if (maximized) .restore else .maximize,
        .close => .close,
    };
}

/// `glyph`, `size` points square, centred in `rs`: its straight lines are filled rects a point
/// (a whole number of pixels, at least one) thick on the pixel grid; the close's diagonals are
/// anti-aliased strokes carrying the same ink (measured against the minimize line).
fn drawGlyph(glyph: Glyph, rs: dvui.RectScale, size: f32, color: dvui.Color) void {
    const t = @max(1, @round(rs.s));
    const n = @round(size * rs.s);
    const x = @round(rs.r.x + (rs.r.w - n) / 2);
    const y = @round(rs.r.y + (rs.r.h - n) / 2);
    switch (glyph) {
        .minimize => fillPx(x, y + @round((n - t) / 2), n, t, color),
        .maximize => outlinePx(x, y, n, n, t, color),
        .restore => {
            // The front square at the bottom-left, whole; of the one behind it, up and right by
            // a fifth, only its top and right edges show.
            const o = @max(t + 1, @round(n / 5));
            const m = n - o;
            outlinePx(x, y + o, m, m, t, color);
            fillPx(x + o, y, m, t, color);
            fillPx(x + n - t, y, t, m, color);
        },
        .close => {
            var a: dvui.Path.Builder = .init(dvui.currentWindow().arena());
            a.addPoint(.{ .x = x, .y = y });
            a.addPoint(.{ .x = x + n, .y = y + n });
            a.build().stroke(.{ .thickness = t, .fade = t / 2, .color = .{ .color = color } });
            var b: dvui.Path.Builder = .init(dvui.currentWindow().arena());
            b.addPoint(.{ .x = x + n, .y = y });
            b.addPoint(.{ .x = x, .y = y + n });
            b.build().stroke(.{ .thickness = t, .fade = t / 2, .color = .{ .color = color } });
        },
    }
}

fn fillPx(x: f32, y: f32, w: f32, h: f32, color: dvui.Color) void {
    (dvui.Rect.Physical{ .x = x, .y = y, .w = w, .h = h }).fill(.all(0), .{ .color = .{ .color = color } });
}

fn outlinePx(x: f32, y: f32, w: f32, h: f32, t: f32, color: dvui.Color) void {
    fillPx(x, y, w, t, color);
    fillPx(x, y + h - t, w, t, color);
    fillPx(x, y + t, t, h - 2 * t, color);
    fillPx(x + w - t, y + t, t, h - 2 * t, color);
}
