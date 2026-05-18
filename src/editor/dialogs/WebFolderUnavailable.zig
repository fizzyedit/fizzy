//! Shown when the user tries to open a project folder in the browser build.

const std = @import("std");
const dvui = @import("dvui");
const fizzy = @import("../../fizzy.zig");

pub fn request() void {
    if (active(dvui.currentWindow())) return;
    var mutex = fizzy.dvui.dialog(@src(), .{
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
        const df = dvui.dataGet(null, d.id, "_displayFn", fizzy.dvui.DisplayFn) orelse continue;
        if (df == dialog) return true;
    }
    return false;
}

fn dialogButton(src: std.builtin.SourceLocation, label_text: []const u8) bool {
    const opts: dvui.Options = .{
        .tab_index = 1,
        .style = .control,
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
    var outer = dvui.box(@src(), .{ .dir = .vertical }, .{ .expand = .both, .padding = .all(12) });
    defer outer.deinit();

    dvui.labelNoFmt(
        @src(),
        "The file explorer is not available in the browser.\n\nUse Open Files to load .fiz, .png, or .jpg images from your device.",
        .{},
        .{ .color_text = dvui.themeGet().color(.window, .text), .margin = .{ .h = 12 } },
    );

    var row = dvui.box(@src(), .{ .dir = .horizontal }, .{ .gravity_x = 0.5 });
    defer row.deinit();

    if (dialogButton(@src(), "Cancel")) {
        fizzy.dvui.closeFloatingDialogAnchored();
    }

    return true;
}

pub fn callAfter(_: dvui.Id, _: dvui.enums.DialogResponse) anyerror!void {}
