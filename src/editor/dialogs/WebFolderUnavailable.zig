//! Shown when the user tries to open a project folder in the browser build.

const std = @import("std");
const dvui = @import("dvui");
const fizzy = @import("../../fizzy.zig");

pub fn request() void {
    if (active(dvui.currentWindow())) return;
    var mutex = fizzy.core.dialogs.dialog(@src(), .{
        .displayFn = dialog,
        .callafterFn = callAfter,
        .title = "Open Folder",
        .ok_label = "",
        .cancel_label = "",
        .resizeable = false,
        .default = .cancel,
        .hide_footer = true,
        .header_kind = .info,
    });
    mutex.mutex.unlock(dvui.io);
}

pub fn active(win: *dvui.Window) bool {
    var it = win.dialogs.iterator(null);
    while (it.next()) |d| {
        const df = dvui.dataGet(null, d.id, "_displayFn", fizzy.core.dialogs.DisplayFn) orelse continue;
        if (df == dialog) return true;
    }
    return false;
}

pub fn dialog(id: dvui.Id) fizzy.core.dialogs.Error!bool {
    var outer = dvui.box(@src(), .{ .dir = .vertical }, .{ .expand = .both, .padding = .all(12) });
    defer outer.deinit();

    dvui.labelNoFmt(
        @src(),
        "The file explorer is not available in the browser.\n\nUse Open Files to load files from your device.",
        .{},
        .{ .color_text = .{ .color = dvui.themeGet().color(.window, .text) }, .margin = .{ .h = 12 } },
    );

    var row = dvui.box(@src(), .{ .dir = .horizontal }, .{ .gravity_x = 0.5 });
    defer row.deinit();

    if (fizzy.core.dialogs.bodyButton(@src(), id, "Cancel", .control, 1, 0)) {
        fizzy.core.dialogs.closeFloatingDialogAnchored();
    }

    return true;
}

pub fn callAfter(_: dvui.Id, _: dvui.enums.DialogResponse) fizzy.core.dialogs.Error!void {}
