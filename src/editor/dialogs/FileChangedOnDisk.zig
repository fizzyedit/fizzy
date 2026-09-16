//! Shown when the user tries to save a dirty document whose on-disk contents have
//! changed since it was opened / last saved / last reloaded. Offers overwrite,
//! discard (reload from disk), or cancel.
const std = @import("std");
const fizzy = @import("../../fizzy.zig");
const dvui = @import("dvui");

pub fn request(file_id: u64) void {
    var mutex = fizzy.core.dialogs.dialog(@src(), .{
        .displayFn = dialog,
        .callafterFn = callAfter,
        .title = "File changed on disk",
        .ok_label = "",
        .cancel_label = "",
        .resizeable = false,
        .default = .cancel,
        .hide_footer = true,
        .max_size = .{ .w = 520, .h = 280 },
        .header_kind = .warning,
    });
    dvui.dataSet(null, mutex.id, "_file_changed_id", file_id);
    mutex.mutex.unlock(dvui.io);
}

fn fileBasename(file_id: u64) []const u8 {
    const doc = fizzy.editor().app.docById(file_id) orelse return "?";
    return std.fs.path.basename(doc.owner.documentPath(doc));
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

pub fn dialog(id: dvui.Id) anyerror!bool {
    const file_id = dvui.dataGet(null, id, "_file_changed_id", u64) orelse return false;
    const name = fileBasename(file_id);

    var outer = dvui.box(@src(), .{ .dir = .vertical }, .{ .expand = .both, .padding = .all(8) });
    defer outer.deinit();

    const message = std.fmt.allocPrint(
        dvui.currentWindow().arena(),
        "\"{s}\" has a newer version on disk. Overwrite with your edits, or discard them and reload?",
        .{name},
    ) catch name;

    var tl = dvui.textLayout(@src(), .{}, .{ .expand = .horizontal, .background = false });
    tl.addText(message, .{ .font = dvui.Font.theme(.body) });
    tl.deinit();

    _ = dvui.spacer(@src(), .{ .min_size_content = .{ .w = 8, .h = 16 } });

    var row = dvui.box(@src(), .{ .dir = .horizontal }, .{ .expand = .horizontal });
    defer row.deinit();

    var btn_row = dvui.box(@src(), .{ .dir = .horizontal }, .{ .expand = .none, .gravity_x = 0.5 });
    defer btn_row.deinit();

    if (dialogButton(@src(), "Overwrite", .highlight, 1, 0)) {
        try onOverwrite(file_id);
    }
    _ = dvui.spacer(@src(), .{ .min_size_content = .{ .w = 10, .h = 1 } });
    if (dialogButton(@src(), "Discard Changes", .control, 2, 1)) {
        onDiscard(file_id);
    }
    _ = dvui.spacer(@src(), .{ .min_size_content = .{ .w = 10, .h = 1 } });
    if (dialogButton(@src(), "Cancel", .control, 3, 2)) {
        onCancel();
    }

    return true;
}

fn onOverwrite(file_id: u64) !void {
    const doc = fizzy.editor().app.docById(file_id) orelse {
        fizzy.core.dialogs.closeFloatingDialogAnchored();
        return;
    };
    fizzy.core.dialogs.closeFloatingDialogAnchored();
    // Clear conflict and write; `noteSaved` refreshes the baseline after success.
    if (fizzy.editor().document_watcher) |*w| w.markPendingBaseline(file_id);
    doc.owner.saveDocument(doc) catch |err| {
        // Save failed — keep treating disk as conflicting so the next save re-prompts.
        if (fizzy.editor().document_watcher) |*w| w.restoreDiskConflict(file_id);
        return err;
    };
    if (fizzy.editor().document_watcher) |*w| w.noteSaved(file_id);
}

fn onDiscard(file_id: u64) void {
    const doc = fizzy.editor().app.docById(file_id) orelse {
        fizzy.core.dialogs.closeFloatingDialogAnchored();
        return;
    };
    if (fizzy.editor().document_watcher) |*w| w.discardToDisk(doc);
    fizzy.core.dialogs.closeFloatingDialogAnchored();
}

fn onCancel() void {
    fizzy.core.dialogs.closeFloatingDialogAnchored();
}

pub fn callAfter(_: dvui.Id, _: dvui.enums.DialogResponse) !void {}
