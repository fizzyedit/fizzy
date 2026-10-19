//! The guides view's one tree, drawn as the app's other trees are (the file tree, settings): a
//! branch per demo, with its title and length, and folded under it a row per chapter, with its
//! title and where it starts. A chapter row plays the demo from there, the first chapter from the
//! start; a demo with no chapters is a row of its own that plays it. The demo playing has its
//! glyph lit. The service refuses a demo over unsaved work or while a live tape drives, and tells
//! the person why itself.
const std = @import("std");
const sdk = @import("fizzy_sdk");
const dvui = @import("dvui");
const core = @import("core");

const Api = sdk.services.demos.Api;

pub fn draw(service: ?*Api) void {
    var scroll = dvui.scrollArea(@src(), .{ .horizontal = .none, .vertical_bar = .auto_overlay }, .{ .expand = .both, .background = false });
    defer scroll.deinit();

    const api = service orelse return note("This app plays no demos.");
    const demos = api.list();
    if (demos.len == 0) return note("No guides yet.");

    var tree = core.widgets.TreeWidget.tree(@src(), .{ .enable_reordering = false }, .{ .expand = .horizontal, .background = false });
    defer tree.deinit();

    const playing = api.current();
    for (demos, 0..) |d, i| {
        const current = if (playing) |p| std.mem.eql(u8, p, d.name) else false;
        if (d.chapters.len == 0) {
            if (row(tree, i, d.title, d.ms, current, .guide_leaf)) _ = api.play(d.name, 0);
            continue;
        }
        const b = branch(tree, i, d, current);
        defer b.deinit();
        if (b.expander(@src(), .{ .indent = 14 }, .{ .expand = .horizontal })) {
            for (d.chapters, 0..) |c, j| {
                if (row(tree, i * 1000 + j + 1, c.title, c.at, false, .chapter)) _ = api.play(d.name, c.at);
            }
        }
    }
}

fn note(text: []const u8) void {
    dvui.labelNoFmt(@src(), text, .{}, .{ .color_text = .{ .color = dim() }, .padding = .all(6) });
}

/// A demo with chapters: its caret folds them. The first demo starts open, so the view shows how
/// it is used; after that each keeps what the person left it as.
fn branch(tree: *core.widgets.TreeWidget, i: usize, d: Api.Info, current: bool) *core.widgets.TreeWidget.Branch {
    const theme = dvui.themeGet();
    const b = tree.branch(@src(), .{ .expanded = i == 0, .draggable = false }, rowOptions(i));
    core.widgets.treeCaret(@src(), b.expanded, theme.color(.control, .fill));
    glyph(current);
    label(d.title, d.ms, theme.color(.control, .text));
    return b;
}

const Kind = enum { guide_leaf, chapter };

/// A row with no branch under it: a chapter, or a demo with no chapters. True when clicked.
fn row(tree: *core.widgets.TreeWidget, id_extra: usize, title: []const u8, ms: u32, current: bool, kind: Kind) bool {
    const theme = dvui.themeGet();
    const b = tree.branch(@src(), .{ .draggable = false }, rowOptions(id_extra));
    defer b.deinit();
    switch (kind) {
        .guide_leaf => glyph(current),
        .chapter => {
            var slot = core.widgets.treeRowGlyph(@src(), .{ .margin = .{ .w = 2 } });
            defer slot.deinit();
            const color = theme.color(.control, .fill);
            _ = core.icon.icon(@src(), "GuideChapter", dvui.entypo.controller_play, .{ .fill_color = .{ .color = color }, .stroke_color = .{ .color = color } }, core.widgets.treeRowIconOptions(.{}));
        },
    }
    label(title, ms, if (kind == .chapter) dim() else theme.color(.control, .text));
    return b.button.clicked();
}

fn rowOptions(id_extra: usize) dvui.Options {
    const theme = dvui.themeGet();
    return .{
        .id_extra = id_extra,
        .expand = .horizontal,
        .color_fill_hover = .{ .color = theme.color(.control, .fill).opacity(0.5) },
        .color_fill_press = .{ .color = theme.color(.control, .fill_press) },
        .color_fill = .{ .color = core.widgets.hoverRestFill(theme.color(.control, .fill)) },
        .padding = .all(1),
    };
}

/// The demo's glyph, lit while it plays.
fn glyph(current: bool) void {
    const theme = dvui.themeGet();
    var slot = core.widgets.treeRowGlyph(@src(), .{ .margin = .{ .w = 2 } });
    defer slot.deinit();
    const color = if (current) theme.color(.highlight, .fill) else theme.color(.control, .fill);
    _ = core.icon.icon(@src(), "GuideIcon", dvui.entypo.graduation_cap, .{ .fill_color = .{ .color = color }, .stroke_color = .{ .color = color } }, core.widgets.treeRowIconOptions(.{}));
}

/// `title` on the left, `ms` as m:ss on the right: a demo's length, or where a chapter starts. The
/// time first: a box gives its children room in order, so it always fits and a long title is the
/// one cut short.
fn label(title: []const u8, ms: u32, color: dvui.Color) void {
    var buf: [16]u8 = undefined;
    dvui.labelNoFmt(@src(), clock(&buf, ms), .{}, .{ .gravity_x = 1, .gravity_y = 0.5, .margin = .{ .x = 8, .w = 4 }, .color_text = .{ .color = dim() } });
    dvui.labelNoFmt(@src(), title, .{}, .{
        .gravity_y = 0.5,
        .expand = .horizontal,
        .margin = .all(0),
        .padding = .all(3),
        .color_text = .{ .color = color },
    });
}

/// `ms` as m:ss.
fn clock(buf: []u8, ms: u32) []const u8 {
    const s = ms / 1000;
    return std.fmt.bufPrint(buf, "{d}:{d:0>2}", .{ s / 60, s % 60 }) catch "";
}

fn dim() dvui.Color {
    return dvui.themeGet().color(.control, .text).opacity(0.6);
}
