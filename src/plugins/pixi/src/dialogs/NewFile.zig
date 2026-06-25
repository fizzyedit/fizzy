const std = @import("std");
const dvui = @import("dvui");

const DimensionsLabel = @import("dimensions_label.zig");
const pixi_mod = @import("../../pixi.zig");
const runtime = @import("../runtime.zig");

pub var mode: enum(usize) {
    single,
    grid,
} = .single;

pub var columns: u32 = 1;
pub var rows: u32 = 1;
pub var column_width: u32 = 32;
pub var row_height: u32 = 32;

pub const max_size: [2]u32 = .{ 4096, 4096 };
pub const min_size: [2]u32 = .{ 1, 1 };

/// Open the "New File" dimensions dialog. When `parent_path` is set the new document is created
/// on disk inside that folder (explorer-initiated); otherwise an in-memory `untitled-n` is made.
/// `id_extra` disambiguates dialogs launched from distinct explorer rows.
pub fn request(parent_path: ?[]const u8, id_extra: usize) void {
    var mutex = pixi_mod.core.dvui.dialog(@src(), .{
        .displayFn = dialog,
        .callafterFn = callAfter,
        .title = "New File...",
        .ok_label = "Create",
        .cancel_label = "Cancel",
        .resizeable = false,
        .header_kind = .info,
        .default = .ok,
        .id_extra = id_extra,
    });
    // `dataSetSlice` copies the bytes into dvui's per-widget store, so the borrowed slice
    // only needs to be valid for this call.
    if (parent_path) |p| dvui.dataSetSlice(null, mutex.id, "_parent_path", p);
    mutex.mutex.unlock(dvui.io);
}

pub fn dialog(id: dvui.Id) anyerror!bool {
    const entry_font = dvui.Font.theme(.mono);

    // Touch explorer target path every frame so dvui does not drop it at Window.end before OK.
    _ = dvui.dataGetSlice(null, id, "_parent_path", []u8);

    var outer_box = dvui.box(@src(), .{ .dir = .vertical }, .{ .expand = .both });
    defer outer_box.deinit();

    {
        var valid: bool = true;

        var unique_id = id.update(if (mode == .single) "single" else "grid");

        {
            const hbox = dvui.box(@src(), .{ .dir = .horizontal, .equal_space = true }, .{ .expand = .horizontal, .corner_radius = .all(100000), .margin = .all(4) });
            defer hbox.deinit();

            for (0..2) |i| {
                const color = if (i == @intFromEnum(mode)) dvui.themeGet().color(.window, .fill).lighten(-4) else dvui.themeGet().color(.control, .fill);
                const button_opts: dvui.Options = .{
                    .padding = .all(6),
                    .margin = .{ .y = 2, .h = 4 },
                    .corner_radius = if (i == 0) .{ .x = 100000, .h = 100000 } else .{ .y = 100000, .w = 100000 },
                    .expand = .horizontal,
                    .color_fill = color,
                    .color_fill_hover = if (i == @intFromEnum(mode)) color else null,
                    .id_extra = i,
                    .box_shadow = if (i != @intFromEnum(mode)) .{
                        .color = .black,
                        .offset = .{ .x = 0.0, .y = 2.0 },
                        .fade = 7.0,
                        .alpha = 0.2,
                        .corner_radius = if (i == 0) .{ .x = 100000, .h = 100000 } else .{ .y = 100000, .w = 100000 },
                    } else null,
                };

                var button: dvui.ButtonWidget = undefined;
                button.init(@src(), .{}, button_opts);
                defer button.deinit();

                if (i != @intFromEnum(mode)) {
                    button.processEvents();
                }

                button.drawBackground();

                if (i == 0) {
                    dvui.labelNoFmt(@src(), "Single", .{}, button_opts.strip().override(button.style()).override(.{
                        .gravity_x = 0.5,
                        .gravity_y = 0.5,
                        .color_text = if (i == @intFromEnum(mode)) dvui.themeGet().color(.window, .text) else dvui.themeGet().color(.control, .text),
                    }));
                    if (button.clicked()) {
                        mode = .single;
                        _ = dvui.dataSet(null, id, "_id_extra", id.update("single_tile").asUsize());
                    }
                } else {
                    dvui.labelNoFmt(@src(), "Grid", .{}, button_opts.strip().override(button.style()).override(.{
                        .gravity_x = 0.5,
                        .gravity_y = 0.5,
                        .color_text = if (i == @intFromEnum(mode)) dvui.themeGet().color(.window, .text) else dvui.themeGet().color(.control, .text),
                    }));
                    if (button.clicked()) {
                        mode = .grid;
                        _ = dvui.dataSet(null, id, "_id_extra", id.update("grid").asUsize());
                    }
                }
            }
        }

        {
            var hbox = dvui.box(@src(), .{ .dir = .horizontal }, .{ .expand = .horizontal });
            defer hbox.deinit();

            {
                dvui.label(@src(), "{s}", .{if (mode == .single) "Width (x):" else "Column Width (x):"}, .{ .gravity_y = 0.5, .gravity_x = 0.0 });
                const result = dvui.textEntryNumber(@src(), u32, .{ .min = min_size[0], .max = max_size[0], .value = &column_width, .show_min_max = true }, .{
                    .box_shadow = .{ .color = .black, .alpha = 0.25, .offset = .{ .x = -4, .y = 4 }, .fade = 8 },
                    .label = .{ .label_widget = .prev },
                    .gravity_x = 1.0,
                    .id_extra = unique_id.asUsize(),
                    .font = entry_font,
                });
                if (result.value == .Valid) {
                    column_width = result.value.Valid;
                } else {
                    valid = false;
                }
            }
        }

        {
            var hbox = dvui.box(@src(), .{ .dir = .horizontal }, .{ .expand = .horizontal });
            defer hbox.deinit();

            {
                dvui.label(@src(), "{s}", .{if (mode == .single) "Height (y):" else "Row Height (y):"}, .{ .gravity_y = 0.5, .gravity_x = 0.0 });
                const result = dvui.textEntryNumber(@src(), u32, .{ .min = min_size[1], .max = max_size[1], .value = &row_height, .show_min_max = true }, .{
                    .box_shadow = .{ .color = .black, .alpha = 0.25, .offset = .{ .x = -4, .y = 4 }, .fade = 8 },
                    .label = .{ .label_widget = .prev },
                    .gravity_x = 1.0,
                    .id_extra = unique_id.asUsize(),
                    .font = entry_font,
                });
                if (result.value == .Valid) {
                    row_height = result.value.Valid;
                } else {
                    valid = false;
                }
            }
        }

        if (mode == .grid) {
            {
                {
                    var hbox = dvui.box(@src(), .{ .dir = .horizontal }, .{ .expand = .both });
                    defer hbox.deinit();

                    dvui.label(@src(), "Columns (x):", .{}, .{ .gravity_y = 0.5 });
                    const result = dvui.textEntryNumber(@src(), u32, .{ .min = 1, .max = @divTrunc(max_size[0], column_width), .value = &columns, .show_min_max = true }, .{
                        .box_shadow = .{ .color = .black, .alpha = 0.25, .offset = .{ .x = -4, .y = 4 }, .fade = 8 },
                        .label = .{ .label_widget = .prev },
                        .gravity_x = 1.0,
                        .id_extra = unique_id.asUsize(),
                        .font = entry_font,
                    });
                    if (result.value == .Valid) {
                        columns = result.value.Valid;
                    } else {
                        valid = false;
                    }
                }
                {
                    var hbox = dvui.box(@src(), .{ .dir = .horizontal }, .{ .expand = .both });
                    defer hbox.deinit();
                    dvui.label(@src(), "Rows (y):", .{}, .{ .gravity_y = 0.5 });
                    const result = dvui.textEntryNumber(@src(), u32, .{ .min = 1, .max = @divTrunc(max_size[1], row_height), .value = &rows, .show_min_max = true }, .{
                        .box_shadow = .{ .color = .black, .alpha = 0.25, .offset = .{ .x = -4, .y = 4 }, .fade = 8 },
                        .label = .{ .label_widget = .prev },
                        .gravity_x = 1.0,
                        .id_extra = unique_id.asUsize(),
                        .font = entry_font,
                    });
                    if (result.value == .Valid) {
                        rows = result.value.Valid;
                    } else {
                        valid = false;
                    }
                }
            }
        }
        _ = dvui.spacer(@src(), .{ .min_size_content = .{ .w = 10, .h = 10 } });

        const width = column_width * (if (mode == .single) 1 else columns);
        const height = row_height * (if (mode == .single) 1 else rows);

        DimensionsLabel.drawDimensionsLabel(@src(), width, height, entry_font, "px", .{ .gravity_x = 0.5 });

        return valid;
    }

    return false;
}

pub fn callAfter(id: dvui.Id, response: dvui.enums.DialogResponse) anyerror!void {
    const parent_path = dvui.dataGetSlice(null, id, "_parent_path", []u8);

    switch (response) {
        .ok => {
            if (parent_path) |parent| {
                const new_path = try std.fs.path.join(runtime.allocator(), &.{ parent, "untitled.fiz" });
                defer runtime.allocator().free(new_path);

                const doc = try runtime.state().host.createDocument(new_path, .{
                    .column_width = column_width,
                    .row_height = row_height,
                    .columns = if (mode == .single) 1 else columns,
                    .rows = if (mode == .single) 1 else rows,
                });
                const file = runtime.state().docs.fileFrom(doc);

                // Save synchronously so the tree's directory scan sees the new file on the next draw
                // (saveAsync would finish later and the fly-to / rename row would never match).
                file.saveAsync() catch {
                    dvui.log.err("Failed to save file: {s}", .{new_path});
                    return error.FailedToSaveFile;
                };

                try runtime.state().host.setExplorerNewFilePath(file.path);
                dvui.refresh(null, @src(), dvui.currentWindow().data().id);
            } else {
                const new_path = try runtime.state().host.allocUntitledPath();
                defer runtime.allocator().free(new_path);
                _ = try runtime.state().host.createDocument(new_path, .{
                    .column_width = column_width,
                    .row_height = row_height,
                    .columns = if (mode == .single) 1 else columns,
                    .rows = if (mode == .single) 1 else rows,
                });
            }
        },
        .cancel => {},
        else => {},
    }
}
