const std = @import("std");
const builtin = @import("builtin");
const fizzy = @import("../fizzy.zig");
const dvui = @import("dvui");
const App = fizzy.App;
const Editor = fizzy.Editor;

const SidebarView = fizzy.sdk.SidebarView;
const PluginStore = @import("PluginStore.zig");

pub const Sidebar = @This();

/// Persisted scroll position for the plugin-icon rail (retained across frames).
var scroll_info: dvui.ScrollInfo = .{};

/// Shell built-in views pinned to the bottom of the rail (always visible). Everything else —
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

pub fn draw(_: Sidebar) !Action {
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

        for (fizzy.editor.host.sidebar_views.items, 0..) |*view, i| {
            if (view.hidden or isPinned(view.id)) continue;
            const a = try drawOption(view, i, 20);
            if (a != .none) ret = a;
        }

        const voff = scroll.si.offset(.vertical);
        const vmax = scroll.si.scrollMax(.vertical);
        scroll.deinit();

        const cs = pane.data().contentRectScale();
        if (voff > 0.5) fizzy.dvui.drawEdgeShadow(cs, .top, .{});
        if (voff < vmax - 0.5) fizzy.dvui.drawEdgeShadow(cs, .bottom, .{});

        pane.deinit();
    }

    // Plugin store + Settings: pinned to the bottom of the rail, always visible.
    {
        var bottom = dvui.box(@src(), .{ .dir = .vertical }, .{
            .gravity_y = 1.0,
            .background = false,
        });
        defer bottom.deinit();

        for (fizzy.editor.host.sidebar_views.items, 0..) |*view, i| {
            if (view.hidden or !isPinned(view.id)) continue;
            const a = try drawOption(view, i, 20);
            if (a != .none) ret = a;
        }
    }

    return ret;
}

fn drawOption(view: *const SidebarView, index: usize, size: f32) !Action {
    const selected = fizzy.editor.host.isActiveSidebarView(view.id);
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
        const strip_h = (fizzy.editor.settings.titlebar_top_buffer + fizzy.editor.settings.titlebar_height) * dvui.windowNaturalScale();
        if (r.y < strip_h) fizzy.backend.pushTitleBarInteractiveRect(r);
    }

    const color: dvui.Color = if (selected) theme.color(.highlight, .fill) else if (bw.hovered()) theme.color(.window, .text) else theme.color(.window, .fill);

    dvui.icon(
        @src(),
        view.id,
        view.icon,
        .{ .fill_color = color },
        .{
            .id_extra = index,
            .min_size_content = .{ .h = size },
        },
    );

    if (bw.clicked()) {
        // Tapping the icon for the view that's already showing toggles the explorer
        // closed (same effect as the floating collapse button). We *report* the intent
        // here; Editor.zig invokes `peekClose` / `open` after `editor.explorer.paned` has
        // been recreated for this frame. Doing the call directly here would dereference
        // last frame's freed paned widget and crash on wasm.
        const explorer_visible = fizzy.editor.explorer.peek_open or !fizzy.editor.explorer.closed;
        if (selected and explorer_visible) {
            ret = .close;
        } else {
            fizzy.editor.host.setActiveSidebarView(view.id);
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
            .color_fill = dvui.themeGet().color(.window, .fill),
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
            tl2.deinit();
        }
    }

    return ret;
}
