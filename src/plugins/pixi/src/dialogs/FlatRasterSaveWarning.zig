const std = @import("std");
const dvui = @import("dvui");
const pixi_mod = @import("../../pixi.zig");
const runtime = @import("../runtime.zig");

pub const Mode = pixi_mod.sdk.Plugin.SaveConfirmMode;

pub var pending_mode: Mode = .editor_save;

/// Open the flat-raster save confirmation for `file_id`. `from_save_all_quit` (whether this
/// request was issued during the shell's quit walk) is captured per-dialog in a data slot so
/// no externally-mutated module flag has to be reset when the quit walk aborts.
pub fn request(file_id: u64, mode: Mode, from_save_all_quit: bool) void {
    pending_mode = mode;
    var mutex = pixi_mod.core.dvui.dialog(@src(), .{
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
    dvui.dataSet(null, mutex.id, "_flat_raster_from_quit", from_save_all_quit);
    mutex.mutex.unlock(dvui.io);
}

fn fileRef(file_id: u64) ?*pixi_mod.internal.File {
    return runtime.state().docs.fileById(file_id);
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
    const from_quit = dvui.dataGet(null, id, "_flat_raster_from_quit", bool) orelse false;
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
        try onChooseFlatRaster(file_id, from_quit);
    }
    _ = dvui.spacer(@src(), .{ .min_size_content = .{ .w = 10, .h = 1 } });
    if (dialogButton(@src(), "Cancel", .control, 3, 2)) {
        onCancel();
    }

    return true;
}

fn onChooseFizzy(file_id: u64) !void {
    const idx = runtime.state().host.docIndex(file_id) orelse return;
    runtime.state().host.setActiveDocIndex(idx);
    if (pending_mode == .save_and_close) {
        runtime.state().host.setPendingCloseDocId(file_id);
    }
    pixi_mod.core.dvui.closeFloatingDialogAnchored();
    runtime.state().host.requestSaveAs();
}

fn onChooseFlatRaster(file_id: u64, from_save_all_quit: bool) !void {
    const f = fileRef(file_id) orelse return;
    switch (pending_mode) {
        .editor_save => {
            pixi_mod.core.dvui.closeFloatingDialogAnchored();
            if (comptime @import("builtin").target.cpu.arch == .wasm32) {
                const idx = runtime.state().host.docIndex(file_id) orelse return;
                runtime.state().host.setActiveDocIndex(idx);
                runtime.state().host.requestWebSave(.save);
            } else {
                try f.saveAsync();
            }
        },
        .save_and_close => {
            // Kick off async; close happens once the worker settles (see
            // Editor.tickPendingSaveCloses / advanceSaveAllQuit). When this dialog
            // was reached from save-all quit, route the close through the quit
            // walker's in-flight set so it gates pending_app_close correctly;
            // otherwise this is a single-doc save-and-close.
            f.saveAsync() catch |err| {
                dvui.log.err("Save failed: {s}", .{@errorName(err)});
                if (from_save_all_quit) runtime.state().host.abortSaveAllQuit();
                return;
            };
            if (from_save_all_quit) {
                runtime.state().host.trackQuitSaveInFlight(file_id) catch |err| {
                    dvui.log.err("Save all quit track: {s}", .{@errorName(err)});
                    runtime.state().host.abortSaveAllQuit();
                    return;
                };
                runtime.state().host.resumeSaveAllQuit();
            } else {
                try runtime.state().host.queueCloseAfterSave(file_id);
            }
            pixi_mod.core.dvui.closeFloatingDialogAnchored();
        },
    }
}

fn onCancel() void {
    runtime.state().host.cancelPendingSaveDialog();
    pixi_mod.core.dvui.closeFloatingDialogAnchored();
}

pub fn callAfter(_: dvui.Id, response: dvui.enums.DialogResponse) !void {
    switch (response) {
        .cancel => runtime.state().host.cancelPendingSaveDialog(),
        else => {},
    }
}
