//! Fizzy's mobile shape: one full-screen place, a bottom bar, and sheets over it.
//!
//! Chosen by `Editor` in place of `layout.zig` when `Layout.form_factor` is `.mobile` (a coarse
//! pointer on a screen under 600 CSS px); copy it the way `layout.zig` is copied. Nothing here
//! reaches past the public `Layout` API.
//!
//! ```
//! +--------------------------+
//! | title             [cmds] |  top strip
//! |                          |
//! |  Main (ide.main)         |  the one place
//! |  +--------------------+  |
//! |  | Explorer / Panel   |  |  a sheet, over Main while open
//! |  +--------------------+  |
//! | [sidebar surfaces]  [>_] |  bottom bar
//! +--------------------------+
//! ```
//!
//! **A sheet is a resizable region at the foot of a transparent column laid over Main.** Opening
//! and shutting it is `Region.open`/`close`, so it slides on the same curve every split does. The
//! column is declared before Main inside `RenderFrontToBack`: dvui hands an event to the first
//! widget that matches it and paints the last on top, so a tap on a sheet reaches the sheet, and
//! a tap on the scrim beside it dismisses rather than reaching Main under it. A general sheet
//! region with detents is plans#60 step 2; until then this is the one place that spells it out.
//!
//! No menu bar, infobar or floats. The menu bar's job is the command palette behind the top
//! strip's button, since every action is a `Command`.
const std = @import("std");
const dvui = @import("dvui");
const core = @import("core");
const icons = @import("icons");
const fizzy = @import("../fizzy.zig");
const sdk = fizzy.sdk;
const app = @import("app");

const Layout = app.layout.Layout;
const Chooser = Layout.Chooser;

/// The key this shape's regions persist under in `layout.zon` (`Layout.State.shape`), apart from
/// `layout.zig`'s, so mobile's arrangement never overwrites a desktop's.
pub const shape_key = "mobile";

const sidebar = sdk.keywords.ide.sidebar;
const bottom = sdk.keywords.ide.panel;
const main_area = sdk.keywords.ide.main;

/// Names of the places; `layout.zon` remembers an extent under each.
const explorer_name = "Explorer";
const panel_name = "Panel";

/// Points. Tap targets are 44 and up.
const strip_h: f32 = 48;
const bar_h: f32 = 56;
const icon_side: f32 = 22;
/// A sheet opens to this much of the window's height.
const sheet_share: f32 = 0.6;
const place_radius: f32 = 16;
const place_padding: f32 = 8;

pub fn layout(ctx: ?*anyopaque, f: *Layout) !dvui.App.Result {
    const editor: *fizzy.Editor = @ptrCast(@alignCast(ctx.?));
    f.card = placeCard();

    var body = dvui.box(@src(), .{ .dir = .vertical }, .{ .expand = .both });
    defer body.deinit();

    // Sheets start shut in every session: a saved extent says how tall one was left, not that it
    // is open. Seeded before the regions read it, once per time the shape is on screen; the
    // regions write their own extent back when it changes, so nothing here asks for a save.
    if (dvui.dataGet(null, body.data().id, "_seeded", bool) == null) {
        dvui.dataSet(null, body.data().id, "_seeded", true);
        inline for (.{ explorer_name, panel_name }) |name| _ = f.state.setExtent(f.gpa, name, 0);
    }

    topStrip(editor);

    var dismiss = false;
    {
        var stage = dvui.overlay(@src(), .{ .expand = .both, .background = false });
        defer stage.deinit();
        {
            var front: dvui.RenderFrontToBack = undefined;
            front.init();
            defer front.deinit();
            dismiss = try sheets(editor, f);
        }
        var main = try f.region(@src(), .{ .name = "Main", .keywords = main_area, .card = true, .pane_cards = true }, .{ .expand = .both });
        defer main.deinit();
    }
    if (dismiss) shutSheets(editor);

    try bottomBar(editor, f);
    return .ok;
}

/// The title of what is open, and the button for every command.
fn topStrip(editor: *fizzy.Editor) void {
    var strip = dvui.box(@src(), .{ .dir = .horizontal }, .{
        .expand = .horizontal,
        .background = false,
        .min_size_content = .{ .h = strip_h },
        .padding = .{ .x = 16, .w = 4 },
    });
    defer strip.deinit();

    const doc = editor.app.host.activeDoc();
    const title: []const u8 = if (doc) |d|
        d.owner.documentTitle(d) orelse std.fs.path.basename(d.owner.documentPath(d))
    else
        "Fizzy";
    dvui.labelNoFmt(@src(), title, .{}, .{
        .gravity_y = 0.5,
        .font = dvui.Font.theme(.heading),
        .tag = "fizzy.mobile.title",
    });

    _ = dvui.spacer(@src(), .{ .expand = .horizontal });
    if (iconButton(@src(), icons.tvg.lucide.search, "fizzy.mobile.commands")) editor.command_palette.show(.commands);
}

/// Both sheets and the scrim beside them. True when the scrim was tapped.
fn sheets(editor: *fizzy.Editor, f: *Layout) !bool {
    var column = try f.region(@src(), .{ .dir = .vertical }, .{ .expand = .both, .background = false });
    defer column.deinit();

    const showing = sheetOpen(f, sidebar) or sheetOpen(f, bottom);
    var tapped = false;
    {
        var scrim = dvui.box(@src(), .{}, .{
            .expand = .both,
            .background = showing,
            .color_fill = .{ .color = dvui.Color.black.opacity(0.4) },
        });
        defer scrim.deinit();
        // Only while a sheet is up, or the scrim would eat every tap meant for Main.
        if (showing and dvui.clicked(scrim.data(), .{ .hover_cursor = null })) tapped = true;
    }

    const height = dvui.windowRect().h * sheet_share;
    {
        var panel = try f.region(@src(), .{
            .name = panel_name,
            .keywords = bottom,
            .resize = true,
            .card = true,
            .pane_cards = true,
        }, .{ .min_size_content = .{ .h = height }, .expand = .horizontal });
        defer panel.deinit();
    }
    {
        var explorer = try f.region(@src(), .{
            .name = explorer_name,
            .keywords = sidebar,
            .content = .{ .ctx = editor, .draw = explorerPane },
            .resize = true,
            .card = true,
        }, .{ .min_size_content = .{ .h = height }, .expand = .horizontal });
        defer explorer.deinit();
    }
    return tapped;
}

fn explorerPane(ctx: ?*anyopaque, f: *Layout, keywords: []const []const u8) Layout.Region.Error!dvui.App.Result {
    const editor: *fizzy.Editor = @ptrCast(@alignCast(ctx.?));
    return editor.explorer.draw(editor, f, keywords);
}

/// A sheet is up from the frame it starts opening until it has shut: last frame's answer, which
/// is all a scrim needs.
fn sheetOpen(f: *Layout, keywords: []const []const u8) bool {
    const place = f.state.regionFor(keywords) orelse return false;
    return !place.isClosed();
}

fn shutSheets(editor: *fizzy.Editor) void {
    editor.explorer.peekClose(editor);
    if (editor.regionFor(bottom)) |panel| panel.close();
}

/// The rail's surfaces as a bar of icons, and the panel's button at its end. Picking an icon
/// opens the explorer sheet on its view; picking the showing one again shuts the sheet.
fn bottomBar(editor: *fizzy.Editor, f: *Layout) !void {
    var bar = dvui.box(@src(), .{ .dir = .horizontal }, .{
        .expand = .horizontal,
        .min_size_content = .{ .h = bar_h },
        // On the window itself, as the rail is: its icons are drawn for that ground.
        .background = false,
    });
    defer bar.deinit();

    var picked = false;
    var again = false;
    {
        var views = Chooser.init(@src(), f, .{ .keywords = sidebar }, .{
            .dir = .horizontal,
            .outer = .{ .expand = .horizontal, .background = false },
        });
        defer views.deinit();
        for (views.views(), 0..) |view, i| {
            var it = views.item(@src(), view, .{});
            defer it.deinit();
            core.anchor.mark(it.data(), "fizzy.mobile.tab:{s}", .{view.id});
            const color = barColor(it.selected, it.hovered());
            core.icon.icon(@src(), view.id, switch (view.icon orelse .none) {
                .tvg => |bytes| bytes,
                else => dvui.entypo.dot_single,
            }, .{ .fill_color = .{ .color = color }, .stroke_color = .{ .color = color } }, .{
                .id_extra = i,
                .gravity_y = 0.5,
                .min_size_content = .{ .w = icon_side, .h = icon_side },
                .padding = .{ .x = 14, .w = 14, .y = 14, .h = 14 },
            });
        }
        picked = views.picked() != null;
        again = views.reselected() != null;
    }

    if (picked or again) {
        if (again and sheetOpen(f, sidebar)) {
            editor.explorer.peekClose(editor);
        } else {
            editor.explorer.open(editor);
            if (editor.regionFor(bottom)) |panel| panel.close();
        }
    }

    // Only where something draws in the panel.
    if (f.matching(bottom).len > 0) {
        if (iconButton(@src(), icons.tvg.lucide.terminal, "fizzy.mobile.panel")) {
            const open = sheetOpen(f, bottom);
            if (editor.regionFor(bottom)) |panel| {
                if (open) panel.close() else {
                    editor.explorer.peekClose(editor);
                    panel.open();
                }
            }
        }
    }
}

fn barColor(selected: bool, hovered: bool) dvui.Color {
    const theme = dvui.themeGet();
    return if (selected)
        theme.color(.highlight, .fill)
    else if (hovered)
        theme.color(.window, .text)
    else
        theme.color(.window, .fill);
}

/// A square tap target around one icon. True when it was tapped.
fn iconButton(src: std.lang.SourceLocation, tvg: []const u8, comptime anchor: []const u8) bool {
    var button: dvui.ButtonWidget = undefined;
    button.init(src, .{}, .{
        .gravity_y = 0.5,
        .min_size_content = .{ .w = icon_side, .h = icon_side },
        .padding = .all(11),
        .background = false,
    });
    defer button.deinit();
    button.processEvents();
    core.anchor.mark(button.data(), anchor, .{});
    const color = barColor(false, button.hovered());
    core.icon.icon(@src(), anchor, tvg, .{ .fill_color = .{ .color = color }, .stroke_color = .{ .color = color } }, .{
        .gravity_x = 0.5,
        .gravity_y = 0.5,
        .min_size_content = .{ .w = icon_side, .h = icon_side },
    });
    return button.clicked();
}

/// The card a place wears: the window's fill, rounded, with the surface inset in it.
fn placeCard() dvui.Options {
    return .{
        .background = true,
        .color_fill = .{ .color = dvui.themeGet().color(.window, .fill) },
        .corners = dvui.CornerRect.round(core.corners.scaled(place_radius)),
        .padding = .all(place_padding),
    };
}
