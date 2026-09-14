//! Shown shortly after launch when the plugin store has newer (or repaired) builds of installed
//! plugins and `Settings.plugin_update_mode` is `.prompt` — the default.
//!
//! The list is the store's own card list (`PluginStore.drawPendingUpdateCards`) rather than a
//! second row layout, so a plugin looks the same here as it does in the Plugins tab. Everything
//! else — the rows, their strings, and how an update is actually started — belongs to
//! `PluginStore`; this file is only the window. Downloads keep running if the window is closed
//! mid-flight: closing dismisses the *offer*, not work already started.
const std = @import("std");
const fizzy = @import("../../fizzy.zig");
const dvui = @import("dvui");
const PluginStore = @import("app").store.Store;

/// The list stops growing here and scrolls instead, so a user with a dozen outdated plugins gets
/// a scrollbar rather than a window clipped by the dialog's own `max_size`.
const max_list_h: f32 = 260;

/// Latched once this window has asked to close, so the request is made exactly once.
///
/// `closeFloatingDialogAnchored` computes the close animation's target from the subwindow's
/// *current* rect. Once the animation is running that rect is mid-flight and `inBack`-eased — it
/// overshoots outward before collapsing — so asking again on the next frame retargets the
/// animation at the overshot rect, and the window chases a runaway target off screen instead of
/// shrinking onto itself. Every other dialog calls it once from a click handler; this one closes
/// itself when the last row lands, which is per-frame unless it latches.
var closing = false;

pub fn active(win: *dvui.Window) bool {
    var it = win.dialogs.iterator(null);
    while (it.next()) |d| {
        const df = dvui.dataGet(null, d.id, "_displayFn", fizzy.core.dialogs.DisplayFn) orelse continue;
        if (df == dialog) return true;
    }
    return false;
}

pub fn request() void {
    if (active(dvui.currentWindow())) return;
    closing = false;
    var mutex = fizzy.core.dialogs.dialog(@src(), .{
        .displayFn = dialog,
        .callafterFn = callAfter,
        .title = "Plugin updates",
        .ok_label = "",
        .cancel_label = "",
        .resizeable = false,
        .default = .cancel,
        .hide_footer = true,
        .max_size = .{ .w = 560, .h = 480 },
        .header_kind = .info,
    });
    mutex.mutex.unlock(dvui.io);
}

fn dialogButton(src: std.builtin.SourceLocation, label_text: []const u8, style: dvui.Theme.Style.Name, tab_idx: u16, id_extra: usize) bool {
    const opts: dvui.Options = .{
        .tab_index = tab_idx,
        .style = style,
        .id_extra = id_extra,
        .box_shadow = .{
            .color = .black,
            .alpha = 0.25,
            .offset = .{ .x = -4, .y = 4 },
            .fade = 8,
        },
    };
    var button: dvui.ButtonWidget = undefined;
    button.init(src, .{}, opts);
    defer button.deinit();
    button.processEvents();
    button.drawFocus();
    button.drawBackground();
    dvui.labelNoFmt(src, label_text, .{}, opts.strip().override(button.style()).override(.{ .gravity_x = 0.5, .gravity_y = 0.5 }));
    return button.clicked();
}

pub fn dialog(_: dvui.Id) anyerror!bool {
    const theme = dvui.themeGet();
    const body = dvui.Font.theme(.body);

    const count = PluginStore.pendingUpdates().len;
    // Every offer landed (rows drop themselves as their builds install) or the list was cleared
    // out from under us: nothing left to decide, so the window shows itself out.
    if (count == 0) {
        if (!closing) {
            closing = true;
            fizzy.core.dialogs.closeFloatingDialogAnchored();
        }
        return true;
    }

    var outer = dvui.box(@src(), .{ .dir = .vertical }, .{ .expand = .both, .padding = .all(8) });
    defer outer.deinit();

    const intro = if (count == 1)
        "1 plugin has an update."
    else
        std.fmt.allocPrint(dvui.currentWindow().arena(), "{d} plugins have updates.", .{count}) catch
            "Plugins have updates.";
    dvui.labelNoFmt(@src(), intro, .{}, .{ .font = body, .gravity_x = 0.5 });

    _ = dvui.spacer(@src(), .{ .min_size_content = .{ .w = 8, .h = 8 } });

    // Sized to its content up to `max_list_h`, then scrolls — `.expand = .both` would claim the
    // whole capped window height and leave a two-card list floating in empty space.
    {
        var scroll = dvui.scrollArea(@src(), .{}, .{
            .expand = .horizontal,
            .background = false,
            .max_size_content = .{ .w = std.math.floatMax(f32), .h = max_list_h },
        });
        defer scroll.deinit();
        PluginStore.drawPendingUpdateCards();
    }

    _ = dvui.spacer(@src(), .{ .min_size_content = .{ .w = 8, .h = 8 } });

    // Plugins are native code loaded into Fizzy's own process — an update is new code, not new
    // data. Said plainly, and in the theme's error colour, because this is the one warning on a
    // window whose whole job is to get the user to accept some.
    {
        var tl = dvui.textLayout(@src(), .{}, .{ .expand = .horizontal, .background = false });
        defer tl.deinit();
        tl.addText(
            "Plugins run as native code inside Fizzy, with the same access to your files as Fizzy " ++
                "itself. Only update plugins from authors you trust.",
            .{ .font = body.larger(-1.0), .color_text = .{ .color = theme.color(.err, .fill) } },
        );
    }

    _ = dvui.spacer(@src(), .{ .min_size_content = .{ .w = 8, .h = 16 } });

    // The same centred footer row every other fizzy dialog draws under `hide_footer`, so this
    // window's actions sit exactly where the app's other prompts put theirs.
    var row = dvui.box(@src(), .{ .dir = .horizontal }, .{ .expand = .horizontal });
    defer row.deinit();

    var btn_row = dvui.box(@src(), .{ .dir = .horizontal }, .{ .expand = .none, .gravity_x = 0.5 });
    defer btn_row.deinit();

    // Not "Cancel": the offer goes away for this session, nothing is undone, and anything already
    // downloading finishes.
    if (dialogButton(@src(), "Not now", .control, 1, 0) and !closing) {
        closing = true;
        fizzy.core.dialogs.closeFloatingDialogAnchored();
    }
    if (PluginStore.anyPendingUpdateUnstarted()) {
        _ = dvui.spacer(@src(), .{ .min_size_content = .{ .w = 10, .h = 1 } });
        if (dialogButton(@src(), "Update all", .highlight, 2, 1)) {
            PluginStore.applyAllPendingUpdates();
        }
    }

    return true;
}

pub fn callAfter(_: dvui.Id, _: dvui.enums.DialogResponse) !void {
    PluginStore.dismissPendingUpdates();
}
