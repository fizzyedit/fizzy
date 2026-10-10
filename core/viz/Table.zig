//! A table of live numbers: a name column, fixed-decimal numbers in the monospace font, and
//! share bars, over dvui's grid. Columns fit what they hold every frame, and only the rows in
//! view are built: a scrolled-away row would be widgets, labels and number formatting every
//! frame for nothing.
//!
//!     var t: viz.Table = .init(@src(), &columns, .{ .rows = rows.len }, .{});
//!     defer t.deinit();
//!     for (rows[t.first..t.last], t.first..) |r, i| {
//!         t.text(i, 0, r.name, .{});
//!         t.number(i, 1, r.ms);
//!         t.bar(i, 2, viz.scale.fraction(r.ms, total), .{});
//!     }
//!
//! A sortable table answers which column the person sorted by, and which way (`sort`); the
//! caller orders its rows by it before drawing them.
const Table = @This();

const std = @import("std");
const dvui = @import("dvui");
const viz = @import("viz.zig");

grid: *dvui.GridWidget,
columns: []const Column,
/// The rows in view, `first` up to but not including `last`, within the rows the table has.
first: usize,
last: usize,
/// The column the person sorted by and which way, in a sortable table they have sorted.
sort: ?Sort,
/// How wide a text column's text may be: what the other columns leave of the table's width.
text_max_w: f32,

pub const Column = struct {
    title: []const u8,
    kind: Kind = .number,
    /// A number column's decimals, fixed so a changing number keeps its width.
    decimals: u8 = 3,
    /// A bar column's least width.
    bar_w: f32 = 140,

    pub const Kind = enum {
        /// Takes the width the others leave.
        text,
        number,
        bar,
    };
};

pub const Sort = struct {
    col: usize,
    descending: bool,
};

pub const Options = struct {
    rows: usize,
    /// Each column's title is a button that sorts by it.
    sortable: bool = false,
};

pub fn init(src: std.builtin.SourceLocation, columns: []const Column, opts: Options, wopts: dvui.Options) Table {
    // No border: dvui's grid squares its top corners for a header joined to it, and here the
    // header is a strip of its own (`stripe`), so a border showed square above and round below.
    const defaults: dvui.Options = .{ .name = "viz.Table", .expand = .both, .background = false, .border = .{} };
    const grid = dvui.grid(src, .{ .rows = opts.rows }, defaults.override(wopts));
    // Columns fit to what they hold, every frame: the numbers keep a steady width (fixed
    // decimals, monospace), and names come and go as rows do. The text column takes the rest.
    grid.autoSize(.both);
    const body = dvui.Font.theme(.body);
    const dim = dvui.themeGet().color(.control, .text).opacity(0.6);
    const mono = dvui.Font.theme(.mono);
    for (columns, 0..) |c, col| {
        // At least as wide as its title, and a number column as a number with three digits
        // before its point: the grid fits columns to their body cells, and a long name in the
        // text column would otherwise squeeze the numbers to an ellipsis.
        var min_w = body.textSize(c.title).w;
        if (c.kind == .number) {
            const digits = "000.000000000";
            min_w = @max(min_w, mono.textSize(digits[0 .. 3 + @as(usize, if (c.decimals > 0) 1 + @min(c.decimals, 9) else 0)]).w);
        }
        grid.cellMinSize(col, std.math.maxInt(usize), .{ .w = min_w + 16, .h = 0 });
        const cell = grid.colHeader(.{ .col = col }, stripe(col, columns.len, header_shade).override(.{ .expand = if (c.kind == .text) .horizontal else .none, .padding = .{ .x = 8, .w = 8, .y = 2, .h = 2 } }));
        defer cell.deinit();
        const gravity_x: f32 = if (c.kind == .number) 1 else 0;
        if (opts.sortable) {
            _ = cell.headerSortable(c.title, .{ .font = body, .color_text = .{ .color = dim }, .gravity_x = gravity_x, .padding = .{} });
        } else {
            dvui.labelNoFmt(@src(), c.title, .{}, .{ .font = body, .color_text = .{ .color = dim }, .gravity_x = gravity_x, .padding = .{} });
        }
    }
    // dvui's grid shrinks every column alike once their widths add up to more than it has, so
    // one long name would squeeze the numbers to an ellipsis. A text column's text gets what the
    // others leave (their widths as of last frame) instead, and the name takes the ellipsis.
    var others: f32 = 0;
    var text_cols: f32 = 0;
    for (columns, 0..) |c, col| {
        if (c.kind == .text) text_cols += 1 else if (col < grid.col_widths.len) others += grid.col_widths[col];
    }
    const text_max_w = @max(48, (grid.msi.viewport.w - others) / @max(text_cols, 1) - 16);
    const first, const last = grid.rowsVisible();
    return .{
        .grid = grid,
        .columns = columns,
        .first = @min(first, opts.rows),
        .last = @min(last, opts.rows), // `last` is exclusive
        .text_max_w = text_max_w,
        .sort = if (opts.sortable and grid.sort_dir != .unsorted) .{ .col = grid.sort_col, .descending = grid.sort_dir == .descending } else null,
    };
}

pub fn deinit(self: *Table) void {
    self.grid.deinit();
}

/// How strongly the header strip and every other row are shaded: the theme's text colour, faint,
/// so the shade reads in light and dark alike.
const header_shade: f32 = 0.08;
const row_shade: f32 = 0.04;

/// A cell's part of a shaded strip across the table: filled `shade` of the text colour, its outer
/// corners rounded at the strip's ends — the first column's left, the last column's right — so
/// the cells side by side are one rounded strip.
fn stripe(col: usize, cols: usize, shade: f32) dvui.Options {
    const first = col == 0;
    const last = col + 1 == cols;
    return .{
        .background = true,
        .color_fill = .{ .color = dvui.themeGet().color(.control, .text).opacity(shade) },
        .corners = .{
            .tl = if (first) .default else .square,
            .bl = if (first) .default else .square,
            .tr = if (last) .default else .square,
            .br = if (last) .default else .square,
        },
    };
}

/// Row `row`'s cell in column `col`: every other row shaded, so a row reads across without a rule.
fn rowCell(self: *Table, row: usize, col: usize) dvui.Options {
    if (row % 2 == 0) return .{};
    return stripe(col, self.columns.len, row_shade);
}

pub const TextOptions = struct {
    /// Nesting depth: a call tree's child sits under its parent.
    indent: u8 = 0,
    strong: bool = false,
};

pub fn text(self: *Table, row: usize, col: usize, t: []const u8, opts: TextOptions) void {
    const c = self.grid.cell(.{ .col = col, .row = row }, self.rowCell(row, col).override(.{ .expand = .horizontal, .padding = .{ .x = 8 + @as(f32, @floatFromInt(opts.indent)) * 16, .w = 8 } }));
    defer c.deinit();
    var f = dvui.Font.theme(.body);
    if (opts.strong) f.weight = .bold;
    const indent_w = @as(f32, @floatFromInt(opts.indent)) * 16;
    dvui.labelNoFmt(@src(), t, .{}, .{
        .font = f,
        .color_text = .{ .color = dvui.themeGet().color(.control, .text) },
        .padding = .{},
        .max_size_content = .{ .w = @max(24, self.text_max_w - indent_w), .h = dvui.max_float_safe },
    });
}

/// `v` with the column's decimals, right-aligned; an empty cell for null.
pub fn number(self: *Table, row: usize, col: usize, v: ?f64) void {
    const c = self.grid.cell(.{ .col = col, .row = row }, self.rowCell(row, col).override(.{ .padding = .{ .x = 8, .w = 8 } }));
    defer c.deinit();
    var buf: [48]u8 = undefined;
    const t = if (v) |x| std.fmt.bufPrint(&buf, "{[v]d:.[p]}", .{ .v = x, .p = self.columns[col].decimals }) catch "?" else "";
    dvui.labelNoFmt(@src(), t, .{}, .{ .font = dvui.Font.theme(.mono), .color_text = .{ .color = dvui.themeGet().color(.control, .text) }, .gravity_x = 1, .padding = .{} });
}

pub fn bar(self: *Table, row: usize, col: usize, fraction: f32, opts: viz.BarOptions) void {
    const c = self.grid.cell(.{ .col = col, .row = row }, self.rowCell(row, col).override(.{ .padding = .{ .x = 8, .w = 8 } }));
    defer c.deinit();
    viz.bar(@src(), fraction, opts, .{ .min_size_content = .{ .w = self.columns[col].bar_w, .h = 10 } });
}
