//! A table of live numbers: name columns, fixed-decimal numbers in the monospace font, and share
//! bars. Drawn straight to the screen, a cell a run of text or a filled rect, and only the rows in
//! view: no cell is a widget. A table redrawn every frame (a profiler's, a dashboard's) costs its
//! text and nothing else, where a grid of a label per cell was ~100 widgets a frame for twenty
//! rows, and the costliest thing on a dashboard.
//!
//!     var t: viz.Table = .init(@src(), &columns, .{ .rows = rows.len }, .{});
//!     defer t.deinit();
//!     for (rows[t.first..t.last], t.first..) |r, i| {
//!         t.text(i, 0, r.name, .{});
//!         t.number(i, 1, r.ms);
//!         t.bar(i, 2, viz.scale.fraction(r.ms, total), .{});
//!     }
//!
//! Column widths come from the columns: a number column is as wide as its title or three digits
//! and its decimals, a bar column its bar, a text column its own width, or a share of what the
//! others leave, and never narrower than the widest text it drew last frame. Nothing is squeezed
//! past reading: where the columns need more than the place has, the table scrolls sideways, as
//! it scrolls down past the rows in view, its header pinned to the top. A sortable table answers
//! which column the person sorted by, and which way (`sort`); the caller orders its rows by it.
const Table = @This();

const std = @import("std");
const dvui = @import("dvui");
const viz = @import("viz.zig");

outer: *dvui.BoxWidget,
scroll: *dvui.ScrollAreaWidget,
body: *dvui.BoxWidget,
columns: []const Column,
/// The rows in view, `first` up to but not including `last`, within the rows the table has.
first: usize,
last: usize,
/// The column the person sorted by and which way, in a sortable table they have sorted.
sort: ?Sort,
opts: Options,
/// Each column's left edge and width, in physical pixels; the first row's top, a row's height,
/// the header's top (the view's top) and height, and the scale.
xs: [max_columns]f32 = @splat(0),
ws: [max_columns]f32 = @splat(0),
top: f32,
row_h: f32,
header_y: f32,
header_h: f32,
s: f32,
id: dvui.Id,
/// Each column's widest text drawn this frame (natural pixels): next frame, the column is at
/// least this wide.
widest: [max_columns]f32 = @splat(0),
/// The width the columns need to be read whole (natural pixels): for a layout that gives the
/// table that much and the rest to what is beside it.
needed: f32 = 0,

pub const Column = struct {
    title: []const u8,
    kind: Kind = .number,
    /// A number column's decimals, fixed so a changing number keeps its width.
    decimals: u8 = 3,
    /// A bar column's bar.
    bar_w: f32 = 140,
    /// A text column's width (natural pixels); null shares what the other columns leave. Either
    /// way, never narrower than its widest text.
    w: ?f32 = null,

    pub const Kind = enum { text, number, bar };
};

pub const Sort = struct {
    col: usize,
    descending: bool,
};

pub const Options = struct {
    rows: usize,
    /// Each column's title sorts by it when clicked, and again the other way.
    sortable: bool = false,
    /// Ask the place for the width the columns need, so they are all in sight and what is beside
    /// the table takes what is left; otherwise take the width given and scroll sideways past it.
    claim_width: bool = false,
};

/// How strongly the header strip and every other row are shaded: the theme's text colour, faint,
/// so the shade reads in light and dark alike.
const header_shade: f32 = 0.08;
const row_shade: f32 = 0.04;
/// Space either side of a cell's content, natural pixels.
const pad: f32 = 8;
/// Columns past this many are not drawn.
pub const max_columns = 16;

pub fn init(src: std.builtin.SourceLocation, columns: []const Column, opts: Options, wopts: dvui.Options) Table {
    const defaults: dvui.Options = .{ .name = "viz.Table", .expand = .both, .background = false };
    const body_font = dvui.Font.theme(.body);
    const mono = dvui.Font.theme(.mono);
    const outer = dvui.box(src, .{ .dir = .vertical }, defaults.override(wopts));
    const id = outer.data().id;
    // The scroll state is the table's own, its content's size stated rather than measured
    // (`given`): a scroll area left to measure reports its whole content as its least size, and a
    // table of forty rows asked its place for all forty rows' height.
    const si = dvui.dataGetPtrDefault(null, id, "si", dvui.ScrollInfo, .{ .vertical = .given, .horizontal = .given });
    const view = si.viewport;

    // The widths: fixed columns first, the rest shared by the text columns without one, each at
    // least as wide as its title and, for text, the widest it drew last frame.
    const columns_used = columns[0..@min(columns.len, max_columns)];
    const widest: [max_columns]f32 = dvui.dataGet(null, id, "widest", [max_columns]f32) orelse @splat(0);
    var natural: [max_columns]f32 = @splat(0);
    var fixed: f32 = 0;
    var shares: f32 = 0;
    for (columns_used, natural[0..columns_used.len], 0..) |c, *w, i| {
        const title_w = body_font.textSize(c.title).w + 12;
        w.* = switch (c.kind) {
            .number => blk: {
                const digits = "000.000000000";
                const n = 3 + @as(usize, if (c.decimals > 0) 1 + @min(c.decimals, 9) else 0);
                break :blk @max(title_w, mono.textSize(digits[0..n]).w) + 2 * pad;
            },
            .bar => @max(title_w, c.bar_w) + 2 * pad,
            .text => @max(c.w orelse 0, @max(title_w, widest[i]) + 2 * pad),
        };
        if (c.kind == .text and c.w == null) shares += 1 else fixed += w.*;
    }
    var least: f32 = 0;
    for (columns_used, natural[0..columns_used.len]) |c, w| {
        if (c.kind == .text and c.w == null) least += w;
    }
    // The text columns share what the view leaves, never less than they need.
    const share = @max(0, view.w - fixed) / @max(shares, 1);
    var total: f32 = 0;
    for (columns_used, natural[0..columns_used.len]) |c, *w| {
        if (c.kind == .text and c.w == null) w.* = @max(w.*, share);
        total += w.*;
    }

    const header_h = body_font.textHeight() + 6;
    const row_h = body_font.textHeight() + 4;
    const rows_f: f32 = @floatFromInt(opts.rows);
    si.virtual_size = .{ .w = @max(total, view.w), .h = header_h + row_h * rows_f };
    // The width the columns need, asked of the place when the caller wants them all in sight.
    if (opts.claim_width) {
        var claim = dvui.box(@src(), .{}, .{ .min_size_content = .{ .w = fixed + least, .h = 0 } });
        claim.deinit();
    }
    // Bars over the rows, not beside them: one appearing must not change the columns' room.
    const scroll = dvui.scrollArea(@src(), .{ .scroll_info = si, .horizontal_bar = .auto_overlay, .vertical_bar = .auto_overlay }, .{ .expand = .both, .background = false, .min_size_content = .{ .w = 80, .h = 60 } });
    const body = dvui.box(@src(), .{}, .{ .expand = .both, .min_size_content = .{ .w = @max(total, view.w), .h = header_h + row_h * rows_f } });
    const rs = body.data().contentRectScale();

    // The rows in view, below the header pinned over the view's top.
    const first: usize = @min(opts.rows, @as(usize, @intFromFloat(@max(0, @floor(view.y / row_h)))));
    const last: usize = @min(opts.rows, @as(usize, @intFromFloat(@max(0, @ceil((view.y + view.h - header_h) / row_h)))));
    var self: Table = .{
        .needed = fixed + least,
        .outer = outer,
        .scroll = scroll,
        .body = body,
        .columns = columns_used,
        .first = first,
        .last = last,
        .sort = if (opts.sortable) dvui.dataGet(null, id, "sort", Sort) else null,
        .opts = opts,
        .top = rs.r.y + header_h * rs.s,
        .row_h = row_h * rs.s,
        .header_y = rs.r.y + view.y * rs.s,
        .header_h = header_h * rs.s,
        .s = rs.s,
        .id = id,
    };
    var x = rs.r.x;
    for (natural[0..columns_used.len], 0..) |w, i| {
        self.xs[i] = x;
        self.ws[i] = w * rs.s;
        x += w * rs.s;
    }
    // Every other row shaded, across, so a row reads without a rule.
    const width = @max(rs.r.w, total * rs.s);
    const shade = dvui.themeGet().color(.control, .text).opacity(row_shade);
    var row = first;
    while (row < last) : (row += 1) {
        if (row % 2 == 0) continue;
        const r: dvui.Rect.Physical = .{ .x = rs.r.x, .y = self.top + @as(f32, @floatFromInt(row)) * self.row_h, .w = width, .h = self.row_h };
        r.fill(.all(5 * rs.s), .{ .color = .{ .color = shade }, .fade = 1 });
    }
    return self;
}

/// The header, drawn last so it sits over the rows scrolled under it, then the table closed.
pub fn deinit(self: *Table) void {
    self.drawHeader();
    // Columns only grow while the table is up: rows coming and going (a hovered frame's scopes, a
    // scroll) must not resize them under the pointer.
    const kept: [max_columns]f32 = dvui.dataGet(null, self.id, "widest", [max_columns]f32) orelse @splat(0);
    var grown = self.widest;
    for (&grown, kept) |*w, k| w.* = @max(w.*, k);
    dvui.dataSet(null, self.id, "widest", grown);
    if (self.sort) |so| dvui.dataSet(null, self.id, "sort", so);
    self.body.deinit();
    self.scroll.deinit();
    self.outer.deinit();
}

fn drawHeader(self: *Table) void {
    const s = self.s;
    const body_font = dvui.Font.theme(.body);
    const n = self.columns.len;
    if (n == 0) return;
    const strip: dvui.Rect.Physical = .{ .x = self.xs[0], .y = self.header_y, .w = self.xs[n - 1] + self.ws[n - 1] - self.xs[0], .h = self.header_h };
    // Opaque under its tint, so the rows scrolled beneath it do not show through.
    strip.fill(.all(5 * s), .{ .color = .{ .color = dvui.themeGet().color(.window, .fill) }, .fade = 1 });
    strip.fill(.all(5 * s), .{ .color = .{ .color = dvui.themeGet().color(.control, .text).opacity(header_shade) }, .fade = 1 });
    const dim = dvui.themeGet().color(.control, .text).opacity(0.6);
    const arena = dvui.currentWindow().arena();
    for (self.columns, 0..) |c, col| {
        var title = c.title;
        if (self.sort) |so| if (so.col == col) {
            title = std.fmt.allocPrint(arena, "{s} {s}", .{ c.title, if (so.descending) "↓" else "↑" }) catch c.title;
        };
        const size = body_font.textSize(title).scale(s, dvui.Size.Physical);
        const x = if (c.kind == .number) self.xs[col] + self.ws[col] - pad * s - size.w else self.xs[col] + pad * s;
        dvui.renderText(.{ .font = body_font, .text = title, .rs = .{ .r = .{ .x = x, .y = self.header_y + (self.header_h - size.h) / 2, .w = size.w, .h = size.h }, .s = s }, .color = dim }) catch {};
        // A click on a title sorts by its column, and a second the other way.
        if (self.opts.sortable) for (dvui.events()) |*e| {
            if (e.evt != .mouse or e.handled) continue;
            const me = e.evt.mouse;
            if (me.action != .press or !me.button.pointer()) continue;
            if (me.p.x < self.xs[col] or me.p.x >= self.xs[col] + self.ws[col] or me.p.y < self.header_y or me.p.y >= self.header_y + self.header_h) continue;
            e.handle(@src(), self.body.data());
            self.sort = .{ .col = col, .descending = if (self.sort) |so| (so.col != col or !so.descending) else true };
        };
    }
}

pub const TextOptions = struct {
    /// Nesting depth: a call tree's child sits under its parent.
    indent: u8 = 0,
    strong: bool = false,
};

/// The rect of row `row`'s cell in column `col`, inside its padding.
fn cell(self: *const Table, row: usize, col: usize) dvui.Rect.Physical {
    return .{
        .x = self.xs[col] + pad * self.s,
        .y = self.top + @as(f32, @floatFromInt(row)) * self.row_h,
        .w = @max(0, self.ws[col] - 2 * pad * self.s),
        .h = self.row_h,
    };
}

pub fn text(self: *Table, row: usize, col: usize, t: []const u8, opts: TextOptions) void {
    if (col >= self.columns.len) return;
    var f = dvui.Font.theme(.body);
    if (opts.strong) f.weight = .bold;
    var r = self.cell(row, col);
    const indent = @as(f32, @floatFromInt(opts.indent)) * 16;
    r.x += indent * self.s;
    r.w = @max(0, r.w - indent * self.s);
    const full_w = f.textSize(t).w;
    self.widest[col] = @max(self.widest[col], full_w + indent);
    // Cut only on the frame a column first meets a longer text; the next, it is wide enough.
    const shown = if (full_w * self.s <= r.w) t else viz.fit(dvui.currentWindow().arena(), f, t, r.w / self.s);
    const size = f.textSize(shown).scale(self.s, dvui.Size.Physical);
    dvui.renderText(.{ .font = f, .text = shown, .rs = .{ .r = .{ .x = r.x, .y = r.y + (r.h - size.h) / 2, .w = size.w, .h = size.h }, .s = self.s }, .color = dvui.themeGet().color(.control, .text) }) catch {};
}

/// `v` with the column's decimals, right-aligned; an empty cell for null.
pub fn number(self: *Table, row: usize, col: usize, v: ?f64) void {
    if (col >= self.columns.len) return;
    const x = v orelse return;
    var buf: [48]u8 = undefined;
    const t = std.fmt.bufPrint(&buf, "{[v]d:.[p]}", .{ .v = x, .p = self.columns[col].decimals }) catch "?";
    const mono = dvui.Font.theme(.mono);
    const r = self.cell(row, col);
    const size = mono.textSize(t).scale(self.s, dvui.Size.Physical);
    dvui.renderText(.{ .font = mono, .text = t, .rs = .{ .r = .{ .x = r.x + r.w - size.w, .y = r.y + (r.h - size.h) / 2, .w = size.w, .h = size.h }, .s = self.s }, .color = dvui.themeGet().color(.control, .text) }) catch {};
}

/// A share bar, filled from the cell's left edge so bars compare by their length.
pub fn bar(self: *Table, row: usize, col: usize, fraction: f32, opts: viz.BarOptions) void {
    if (col >= self.columns.len) return;
    const r = self.cell(row, col);
    const h = 10 * self.s;
    var b: dvui.Rect.Physical = .{ .x = r.x, .y = r.y + (r.h - h) / 2, .w = @min(r.w, self.columns[col].bar_w * self.s) * std.math.clamp(fraction, 0, 1), .h = h };
    if (b.w < 1) return;
    const c = opts.color orelse dvui.themeGet().color(.highlight, .fill);
    b.fill(.all(2 * self.s), .{ .color = .{ .color = c.opacity(if (opts.strong) 1 else 0.75) }, .fade = 1 });
}
