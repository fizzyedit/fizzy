const std = @import("std");
const builtin = @import("builtin");
const fizzy = @import("../fizzy.zig");
const dvui = @import("dvui");
const Constants = @import("Constants.zig");
const Entry = fizzy.Entry;
const Editor = fizzy.Editor;

const SidebarView = fizzy.sdk.SidebarView;
const PluginStore = @import("app").store.Store;
const Accounts = @import("Accounts.zig");
const Layout = @import("app").layout.Layout;

pub const Sidebar = @This();

/// Persisted scroll position for the plugin-icon rail (retained across frames).
var scroll_info: dvui.ScrollInfo = .{};

/// Fizzy built-in views pinned to the bottom of the rail (always visible). Everything else —
/// the plugin-contributed views — scrolls above them in registration (load) order.
fn isPinned(id: []const u8) bool {
    return std.mem.eql(u8, id, PluginStore.view_id) or
        std.mem.eql(u8, id, Editor.view_settings);
}

pub fn init() !Sidebar {
    return .{};
}

pub fn deinit() void {
    // TODO: Free memory
}

/// What the sidebar wants Editor.zig to do this frame. We defer the call out to Editor
/// because the sidebar runs *before* `editor.explorer.paned` is re-created for this
/// frame — dereferencing `explorer.paned` (e.g. via `peekClose`/`open`) from inside the
/// sidebar click handler would touch last frame's freed widget, which on wasm32 trips
/// "reached unreachable code".
pub const Action = enum { none, open, close };

/// `f` is the layout frame: the rail lists whatever currently *matches* the keywords its
/// region accepts, rather than every surface in `host.surfaces`. That is what
/// makes a user's keyword override actually move an icon out of (or into) this rail.
pub fn draw(_: Sidebar, editor: *Editor, f: *Layout, keywords: []const []const u8) !Action {
    const vbox = dvui.box(@src(), .{ .dir = .vertical }, .{
        .expand = .vertical,
        .background = false,
        .min_size_content = .{ .w = 40, .h = 100 },
    });
    defer vbox.deinit();

    var ret: Action = .none;

    // Plugin-contributed views scroll in a bounded area (load order). When more icons exist than
    // fit, an edge shadow hints at the hidden ones — matching the scroll-shadow used elsewhere.
    {
        const pane = dvui.box(@src(), .{ .dir = .vertical }, .{
            .expand = .both,
            .background = false,
        });

        var scroll = dvui.scrollArea(@src(), .{
            .scroll_info = &scroll_info,
            .horizontal_bar = .hide,
            .vertical_bar = .hide,
        }, .{
            .expand = .both,
            .background = false,
        });

        for (f.matching(keywords), 0..) |surface, i| {
            if (isPinned(surface.id)) continue;
            const a = try drawOption(editor, f, keywords, surface, i, 20);
            if (a != .none) ret = a;
        }

        const si = scroll.si.*;
        scroll.deinit();

        fizzy.core.draw.drawScrollEdgeShadows(pane.data().contentRectScale(), null, &si, .{});

        pane.deinit();
    }

    // Plugin store + Settings: pinned to the bottom of the rail, always visible.
    {
        var bottom = dvui.box(@src(), .{ .dir = .vertical }, .{
            .gravity_y = 1.0,
            .background = false,
        });
        defer bottom.deinit();

        // The account disc, when anything can be signed in to; then plugin-drawn items (a
        // badge, a status light); then fizzy's own two.
        if (editor.app.host.account_providers.items.len != 0) try Accounts.drawRailDisc(editor, 20);
        for (editor.app.host.rail_items.items, 0..) |item, i| {
            if (item.hidden) continue;
            var slot = dvui.box(@src(), .{ .dir = .vertical }, .{ .id_extra = i, .background = false, .min_size_content = .{ .h = 20 } });
            defer slot.deinit();
            item.draw(item.ctx, 20) catch |err| dvui.log.err("rail item '{s}' failed to draw: {t}", .{ item.id, err });
        }

        for (f.matching(keywords), 0..) |surface, i| {
            if (!isPinned(surface.id)) continue;
            const a = try drawOption(editor, f, keywords, surface, i, 20);
            if (a != .none) ret = a;
        }
    }

    return ret;
}

fn drawOption(
    editor: *Editor,
    f: *Layout,
    keywords: []const []const u8,
    view: *Layout.Surface,
    index: usize,
    size: f32,
) !Action {
    const selected = f.isSelected(keywords, view);
    var ret: Action = .none;

    const theme = dvui.themeGet();

    var bw: dvui.ButtonWidget = undefined;

    bw.init(@src(), .{}, .{
        .id_extra = index,
        .min_size_content = .{ .h = size },
    });
    defer bw.deinit();
    bw.processEvents();

    // Register the button as interactive in the title bar so clicks reach DVUI even when the
    // button overlaps the top drag strip on Windows. Only the topmost sidebar button(s) actually
    // sit inside the strip — anything below is registered harmlessly (no overlap with drag rect).
    if (builtin.os.tag == .windows) {
        const r = bw.data().rectScale().r;
        const strip_h = (Constants.titlebar_top_buffer + Constants.titlebar_height) * dvui.windowNaturalScale();
        if (r.y < strip_h) fizzy.backend.pushTitleBarInteractiveRect(r);
    }

    // Only the store view can carry one; nothing else in the rail has a pending-decision notion.
    const undecided_count: usize = if (std.mem.eql(u8, view.id, PluginStore.view_id))
        editor.app.undecidedPluginCount()
    else
        0;

    const color: dvui.Color = if (selected) theme.color(.highlight, .fill) else if (bw.hovered()) theme.color(.window, .text) else theme.color(.window, .fill);

    // Apply both fill and stroke: Entypo glyphs are fill-based, Lucide (and most
    // plugin icons) are stroke-based. Setting only one leaves the other at DVUI's
    // default white — which is how a stroke icon looks "full white" in the rail.
    fizzy.core.icon.icon(
        @src(),
        view.id,
        // A surface's icon is format-tagged and optional; the rail draws tvg. A surface with a
        // png or no icon simply gets no glyph here rather than the rail refusing to list it.
        switch (view.icon orelse .none) {
            .tvg => |bytes| bytes,
            else => dvui.entypo.dot_single,
        },
        .{ .fill_color = .{ .color = color }, .stroke_color = .{ .color = color } },
        .{
            .id_extra = index,
            .min_size_content = .{ .h = size },
        },
    );

    // Attention badge, same idiom (and colour) as the infobar's app-update dot: a plugin build
    // is sitting in `plugins/` waiting for the user to say whether to load it, and the card that
    // offers it is inside this very view. Purely condition-driven — it disappears when the last
    // undecided build is loaded, switched off, or removed, not when the tab is merely opened.
    if (undecided_count > 0) {
        const brs = bw.data().rectScale();
        const r = 4 * brs.s;
        // Anchored to the *glyph's* top-right corner, not the rail cell's: the cell is twice the
        // icon's height, so a corner-anchored dot would float well clear of the icon it marks.
        const center = r: {
            const c = brs.r.center();
            break :r dvui.Point.Physical{ .x = c.x + size / 2 * brs.s, .y = c.y - size / 2 * brs.s };
        };
        var dot = dvui.Rect.Physical.fromPoint(center).toSize(.{ .w = 2 * r, .h = 2 * r });
        dot.x -= r;
        dot.y -= r;
        dot.fill(dvui.CornerRect.Physical.round(r), .{
            .color = .{ .color = theme.color(.highlight, .fill) },
            .fade = 0,
        });
    }

    if (bw.clicked()) {
        // Tapping the icon for the view that's already showing toggles the explorer
        // closed (same effect as the floating collapse button). We *report* the intent
        // here; Editor.zig invokes `peekClose` / `open` after `editor.explorer.paned` has
        // been recreated for this frame. Doing the call directly here would dereference
        // last frame's freed paned widget and crash on wasm.
        // The region, not `explorer.closed`: on a narrow window the explorer is folded away by
        // the layout without anyone having closed it, and a tap there means "show me", not
        // "hide it again".
        const explorer_visible = if (editor.regionFor(fizzy.sdk.keywords.ide.sidebar)) |r|
            !r.isClosed() and !r.isFolded()
        else
            !editor.explorer.closed;
        if (selected and explorer_visible) {
            ret = .close;
        } else {
            f.select(keywords, view);
            ret = .open;
        }
        dvui.refresh(null, @src(), null);
    }

    if (!selected) {
        var tooltip: dvui.FloatingTooltipWidget = undefined;
        tooltip.init(@src(), .{
            .active_rect = bw.data().rectScale().r,
            .delay = 350_000,
        }, .{
            .id_extra = index,
            .color_fill = .{ .color = dvui.themeGet().color(.window, .fill) },
            .border = dvui.Rect.all(0),
            .box_shadow = .{
                .color = .black,
                .shrink = 0,
                .corners = dvui.CornerRect.all(8),
                .offset = .{ .x = 0, .y = 2 },
                .fade = 4,
                .alpha = 0.2,
            },
        });
        defer tooltip.deinit();

        if (tooltip.shown()) {
            var animator = dvui.animate(@src(), .{
                .kind = .alpha,
                .duration = 350_000,
            }, .{
                .expand = .both,
            });
            defer animator.deinit();

            var vbox2 = dvui.box(@src(), .{ .dir = .vertical }, dvui.FloatingTooltipWidget.defaults.override(.{
                .background = false,
                .expand = .both,
                .border = dvui.Rect.all(0),
            }));
            defer vbox2.deinit();

            var tl2 = dvui.textLayout(@src(), .{}, .{
                .background = false,
                .padding = dvui.Rect.all(4),
            });
            const tip = std.ascii.allocUpperString(dvui.currentWindow().arena(), view.title) catch view.title;
            tl2.format("{s}", .{tip}, .{
                .font = dvui.Font.theme(.heading),
            });
            // Say what the dot means — a bare badge on a 20px rail icon is otherwise a riddle.
            if (undecided_count > 0) {
                tl2.format("\n{d} plugin{s} ready to load", .{
                    undecided_count,
                    if (undecided_count == 1) "" else "s",
                }, .{});
            }
            tl2.deinit();
        }
    }

    return ret;
}
