//! Save-as for the browser build: pick a download filename, then `Editor.processPendingSaveAs` encodes and downloads.

const std = @import("std");
const dvui = @import("dvui");
const fizzy = @import("../../fizzy.zig");
const WebFileIo = @import("../WebFileIo.zig");

var default_name_storage: ?[]u8 = null;

pub const Kind = enum {
    save,
    save_as,

    fn dialogTitle(self: Kind) []const u8 {
        return switch (self) {
            .save => "Save",
            .save_as => "Save As",
        };
    }
};

pub fn request(default_filename: []const u8, kind: Kind) void {
    if (active(dvui.currentWindow())) return;
    if (default_name_storage) |old| {
        fizzy.entry().allocator.free(old);
        default_name_storage = null;
    }
    default_name_storage = fizzy.entry().allocator.dupe(u8, default_filename) catch {
        dvui.log.err("Web Save As: out of memory", .{});
        return;
    };
    var mutex = fizzy.core.dialogs.dialog(@src(), .{
        .displayFn = dialog,
        .callafterFn = callAfter,
        .title = kind.dialogTitle(),
        .ok_label = "Download",
        .cancel_label = "Cancel",
        .resizeable = false,
        .default = .ok,
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

pub fn dialog(id: dvui.Id) anyerror!bool {
    var outer = dvui.box(@src(), .{ .dir = .vertical }, .{ .expand = .both, .padding = .all(12) });
    defer outer.deinit();

    dvui.labelNoFmt(
        @src(),
        "Files download to your browser's download folder.",
        .{},
        .{ .color_text = .{ .color = dvui.themeGet().color(.control, .text) }, .margin = .{ .h = 8 } },
    );

    const te = dvui.textEntry(@src(), .{ .placeholder = "filename.fiz" }, .{ .expand = .horizontal });
    defer te.deinit();

    if (dvui.firstFrame(te.data().id)) {
        if (default_name_storage) |def| te.textSet(def, false);
    }

    const name = te.getText();
    dvui.dataSetSlice(null, id, "_save_as_name", name);
    return name.len > 0;
}

pub fn callAfter(id: dvui.Id, response: dvui.enums.DialogResponse) anyerror!void {
    const name = dvui.dataGetSlice(null, id, "_save_as_name", []const u8) orelse "";
    defer {
        if (default_name_storage) |old| {
            fizzy.entry().allocator.free(old);
            default_name_storage = null;
        }
    }

    if (response != .ok or name.len == 0) {
        if (response == .cancel) {
            fizzy.editor().cancelPendingSaveDialog();
        }
        return;
    }

    const owned = fizzy.entry().allocator.dupe(u8, name) catch {
        dvui.log.err("Web Save As: out of memory", .{});
        return;
    };
    if (WebFileIo.pending_save_filename) |old| fizzy.entry().allocator.free(old);
    WebFileIo.pending_save_filename = owned;
}
