const std = @import("std");
const fizzy = @import("../../fizzy.zig");
const dvui = @import("dvui");

/// When `pending_mode == .save_and_close`, resume `Editor.advanceSaveAllQuit` after flat save.
pub var pending_from_save_all_quit: bool = false;

pub var pending_mode: Mode = .editor_save;

pub const Mode = enum {
    editor_save,
    save_and_close,
};

pub fn request(file_id: u64, mode: Mode) void {
    pending_mode = mode;
    if (mode == .editor_save) {
        pending_from_save_all_quit = false;
    }
    var mutex = fizzy.dvui.dialog(@src(), .{
        .displayFn = dialog,
        .callafterFn = callAfter,
        .title = "Save as .fiz or current extension?",
        .ok_label = "",
        .cancel_label = "",
        .resizeable = false,
        .default = .cancel,
        .hide_footer = true,
        .max_size = .{ .w = 520, .h = 300 },
        .header_kind = .warning,
    });
    dvui.dataSet(null, mutex.id, "_flat_raster_file_id", file_id);
    mutex.mutex.unlock(dvui.io);
}

fn fileRef(file_id: u64) ?*fizzy.Internal.File {
    return fizzy.editor.open_files.getPtr(file_id);
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
    const file_id = dvui.dataGet(null, id, "_flat_raster_file_id", u64) orelse return false;
    const file = fileRef(file_id) orelse return false;

    const ext_raw = std.fs.path.extension(file.path);
    const ext_disp = blk: {
        var buf: [32]u8 = undefined;
        if (ext_raw.len > buf.len) break :blk ext_raw;
        break :blk std.ascii.lowerString(&buf, ext_raw);
    };

    const bold_hi = dvui.Font.theme(.body).withWeight(.bold);
    const hi_fill = dvui.themeGet().color(.highlight, .fill);

    var outer = dvui.box(@src(), .{ .dir = .vertical }, .{ .expand = .both, .padding = .all(8) });
    defer outer.deinit();

    {
        var tl = dvui.textLayout(@src(), .{}, .{
            .expand = .horizontal,
            .background = false,
        });
        tl.addText("File contains data only compatible with the ", .{ .font = dvui.Font.theme(.body) });
        tl.addText(".fiz", .{ .font = bold_hi, .color_text = hi_fill });
        tl.addText(" extension. Would you like to save a copy of your file as a ", .{ .font = dvui.Font.theme(.body) });
        tl.addText(".fiz", .{ .font = bold_hi, .color_text = hi_fill });
        tl.format(" extension or proceed saving as a {s}?", .{ext_disp}, .{ .font = dvui.Font.theme(.body) });
        tl.deinit();
    }

    _ = dvui.spacer(@src(), .{ .min_size_content = .{ .w = 8, .h = 16 } });

    var row = dvui.box(@src(), .{ .dir = .horizontal }, .{ .expand = .horizontal });
    defer row.deinit();

    var btn_row = dvui.box(@src(), .{ .dir = .horizontal }, .{ .expand = .none, .gravity_x = 0.5 });
    defer btn_row.deinit();

    if (dialogButton(@src(), ".fiz", .highlight, 1, 0)) {
        try onChooseFizzy(file_id);
    }
    _ = dvui.spacer(@src(), .{ .min_size_content = .{ .w = 10, .h = 1 } });
    if (dialogButton(@src(), ext_disp, .control, 2, 1)) {
        try onChooseFlatRaster(file_id);
    }
    _ = dvui.spacer(@src(), .{ .min_size_content = .{ .w = 10, .h = 1 } });
    if (dialogButton(@src(), "Cancel", .control, 3, 2)) {
        onCancel();
    }

    return true;
}

fn onChooseFizzy(file_id: u64) !void {
    const idx = fizzy.editor.open_files.getIndex(file_id) orelse return;
    fizzy.editor.setActiveFile(idx);
    if (pending_mode == .save_and_close) {
        fizzy.editor.pending_close_file_id = file_id;
    }
    fizzy.dvui.closeFloatingDialogAnchored();
    fizzy.editor.requestSaveAs();
}

fn onChooseFlatRaster(file_id: u64) !void {
    const f = fileRef(file_id) orelse return;
    switch (pending_mode) {
        .editor_save => {
            try f.saveAsync();
            fizzy.dvui.closeFloatingDialogAnchored();
        },
        .save_and_close => {
            // Kick off async; close happens once the worker settles (see
            // Editor.tickPendingSaveCloses / advanceSaveAllQuit). When this dialog
            // was reached from save-all quit, route the close through the quit
            // walker's in-flight set so it gates pending_app_close correctly;
            // otherwise this is a single-doc save-and-close.
            f.saveAsync() catch |err| {
                dvui.log.err("Save failed: {s}", .{@errorName(err)});
                if (pending_from_save_all_quit) fizzy.editor.abortSaveAllQuit();
                return;
            };
            if (pending_from_save_all_quit) {
                fizzy.editor.quit_saves_in_flight.put(fizzy.app.allocator, file_id, {}) catch |err| {
                    dvui.log.err("Save all quit track: {s}", .{@errorName(err)});
                    fizzy.editor.abortSaveAllQuit();
                    return;
                };
                fizzy.editor.pending_quit_continue = true;
            } else {
                try fizzy.editor.pending_close_after_save.put(fizzy.app.allocator, file_id, {});
            }
            fizzy.dvui.closeFloatingDialogAnchored();
        },
    }
}

fn onCancel() void {
    if (pending_mode == .save_and_close and pending_from_save_all_quit) {
        fizzy.editor.abortSaveAllQuit();
    }
    fizzy.dvui.closeFloatingDialogAnchored();
}

pub fn callAfter(_: dvui.Id, response: dvui.enums.DialogResponse) !void {
    switch (response) {
        .cancel => {
            if (pending_mode == .save_and_close and pending_from_save_all_quit) {
                fizzy.editor.abortSaveAllQuit();
            }
        },
        else => {},
    }
}
