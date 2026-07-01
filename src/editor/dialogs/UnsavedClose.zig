const std = @import("std");
const fizzy = @import("../../fizzy.zig");
const dvui = @import("dvui");

pub fn request(file_id: u64) void {
    var mutex = fizzy.dvui.dialog(@src(), .{
        .displayFn = dialog,
        .callafterFn = callAfter,
        .title = "Unsaved changes",
        .ok_label = "",
        .cancel_label = "",
        .resizeable = false,
        .default = .cancel,
        .hide_footer = true,
        .max_size = .{ .w = 520, .h = 280 },
        .header_kind = .warning,
    });
    dvui.dataSet(null, mutex.id, "_unsaved_file_id", file_id);
    mutex.mutex.unlock(dvui.io);
}

fn fileBasename(file_id: u64) []const u8 {
    const doc = fizzy.editor.docById(file_id) orelse return "?";
    return std.fs.path.basename(fizzy.editor.docPath(doc));
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
    const file_id = dvui.dataGet(null, id, "_unsaved_file_id", u64) orelse return false;
    const name = fileBasename(file_id);

    var outer = dvui.box(@src(), .{ .dir = .vertical }, .{ .expand = .both, .padding = .all(8) });
    defer outer.deinit();

    dvui.label(
        @src(),
        "Save changes to \"{s}\" before closing?",
        .{name},
        .{ .font = dvui.Font.theme(.body) },
    );

    _ = dvui.spacer(@src(), .{ .min_size_content = .{ .w = 8, .h = 16 } });

    var row = dvui.box(@src(), .{ .dir = .horizontal }, .{ .expand = .horizontal });
    defer row.deinit();

    var btn_row = dvui.box(@src(), .{ .dir = .horizontal }, .{ .expand = .none, .gravity_x = 0.5 });
    defer btn_row.deinit();

    if (dialogButton(@src(), "Close", .control, 1, 0)) {
        try onDiscard(file_id);
    }
    _ = dvui.spacer(@src(), .{ .min_size_content = .{ .w = 10, .h = 1 } });
    if (dialogButton(@src(), "Save and Close", .highlight, 2, 1)) {
        try onSaveAndClose(file_id);
    }
    _ = dvui.spacer(@src(), .{ .min_size_content = .{ .w = 10, .h = 1 } });
    if (dialogButton(@src(), "Cancel", .control, 3, 2)) {
        onCancel();
    }

    return true;
}

fn onDiscard(file_id: u64) !void {
    try fizzy.editor.rawCloseFileID(file_id);
    fizzy.dvui.closeFloatingDialogAnchored();
}

fn onCancel() void {
    fizzy.dvui.closeFloatingDialogAnchored();
}

fn beginSaveAndClose(doc: fizzy.sdk.DocHandle, file_id: u64) !void {
    if (doc.owner.isDocumentSaving(doc)) return;
    if (comptime @import("builtin").target.cpu.arch == .wasm32) {
        const idx = fizzy.editor.open_files.getIndex(file_id) orelse return;
        fizzy.editor.setActiveFile(idx);
        fizzy.editor.pending_close_file_id = file_id;
        fizzy.editor.requestWebSaveDialog(.save);
        return;
    }
    try doc.owner.saveDocumentAsync(doc);
    try fizzy.editor.pending_close_after_save.put(fizzy.app.allocator, file_id, {});
}

fn onSaveAndClose(file_id: u64) !void {
    const doc = fizzy.editor.docById(file_id) orelse return;
    if (!doc.owner.documentHasRecognizedSaveExtension(doc)) {
        const idx = fizzy.editor.open_files.getIndex(file_id) orelse return;
        fizzy.editor.setActiveFile(idx);
        fizzy.editor.pending_close_file_id = file_id;
        fizzy.dvui.closeFloatingDialogAnchored();
        fizzy.editor.requestSaveAs();
        return;
    }
    if (doc.owner.saveNeedsConfirmation(doc)) {
        fizzy.dvui.closeFloatingDialogAnchored();
        doc.owner.requestSaveConfirmation(doc, .save_and_close, false);
        return;
    }
    try beginSaveAndClose(doc, file_id);
    fizzy.dvui.closeFloatingDialogAnchored();
}

pub fn callAfter(_: dvui.Id, _: dvui.enums.DialogResponse) !void {}
