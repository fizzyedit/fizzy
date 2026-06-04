const std = @import("std");
const builtin = @import("builtin");

const fizzy = @import("../fizzy.zig");
const dvui = @import("dvui");

pub const Keybinds = @This();

pub fn register() !void {
    const window = dvui.currentWindow();

    // Runtime mac detection — `builtin.os.tag.isDarwin()` is `false` for
    // wasm32-freestanding, so macOS web users would otherwise get the Windows
    // (Ctrl) bindings. `fizzy.platform.isMacOS()` reads DVUI's `navigator.platform`-
    // derived choice on web and uses `os.tag` on native.
    if (fizzy.platform.isMacOS()) {
        try window.keybinds.putNoClobber(window.gpa, "open_folder", .{ .key = .f, .command = true });
        try window.keybinds.putNoClobber(window.gpa, "new_file", .{ .key = .n, .command = true });
        try window.keybinds.putNoClobber(window.gpa, "open_files", .{ .key = .o, .command = true });
        try window.keybinds.putNoClobber(window.gpa, "undo", .{ .key = .z, .command = true, .shift = false });
        try window.keybinds.putNoClobber(window.gpa, "redo", .{ .key = .z, .command = true, .shift = true });
        try window.keybinds.putNoClobber(window.gpa, "zoom", .{ .command = true });
        try window.keybinds.putNoClobber(window.gpa, "save", .{ .command = true, .key = .s });
        try window.keybinds.putNoClobber(window.gpa, "save_as", .{ .command = true, .shift = true, .key = .s });
        try window.keybinds.putNoClobber(window.gpa, "save_all", .{ .command = true, .alt = true, .key = .s });
        try window.keybinds.putNoClobber(window.gpa, "sample", .{ .control = true });
        try window.keybinds.putNoClobber(window.gpa, "transform", .{ .command = true, .key = .t });
        try window.keybinds.putNoClobber(window.gpa, "grid_layout", .{ .command = true, .key = .g });
        try window.keybinds.putNoClobber(window.gpa, "explorer", .{ .command = true, .key = .e });
        try window.keybinds.putNoClobber(window.gpa, "workspace", .{ .command = true, .key = .w });
        try window.keybinds.putNoClobber(window.gpa, "export", .{ .command = true, .key = .p });
        try window.keybinds.putNoClobber(window.gpa, "delete_selection_contents", .{ .key = .backspace });
    } else {
        try window.keybinds.putNoClobber(window.gpa, "open_folder", .{ .key = .f, .control = true });
        try window.keybinds.putNoClobber(window.gpa, "new_file", .{ .key = .n, .control = true });
        try window.keybinds.putNoClobber(window.gpa, "open_files", .{ .key = .o, .control = true });
        try window.keybinds.putNoClobber(window.gpa, "undo", .{ .key = .z, .control = true, .shift = false });
        try window.keybinds.putNoClobber(window.gpa, "redo", .{ .key = .z, .control = true, .shift = true });
        try window.keybinds.putNoClobber(window.gpa, "zoom", .{ .control = true });
        try window.keybinds.putNoClobber(window.gpa, "save", .{ .control = true, .key = .s });
        try window.keybinds.putNoClobber(window.gpa, "save_as", .{ .control = true, .shift = true, .key = .s });
        try window.keybinds.putNoClobber(window.gpa, "save_all", .{ .control = true, .alt = true, .key = .s });
        try window.keybinds.putNoClobber(window.gpa, "sample", .{ .alt = true });
        try window.keybinds.putNoClobber(window.gpa, "transform", .{ .control = true, .key = .t });
        try window.keybinds.putNoClobber(window.gpa, "grid_layout", .{ .control = true, .key = .g });
        try window.keybinds.putNoClobber(window.gpa, "explorer", .{ .control = true, .key = .e });
        try window.keybinds.putNoClobber(window.gpa, "workspace", .{ .control = true, .key = .w });
        try window.keybinds.putNoClobber(window.gpa, "export", .{ .control = true, .key = .p });
        try window.keybinds.putNoClobber(window.gpa, "delete_selection_contents", .{ .key = .delete });
    }

    try window.keybinds.putNoClobber(window.gpa, "shift", .{ .shift = true });
    try window.keybinds.putNoClobber(window.gpa, "increase_stroke_size", .{ .key = .right_bracket });
    try window.keybinds.putNoClobber(window.gpa, "decrease_stroke_size", .{ .key = .left_bracket });

    try window.keybinds.putNoClobber(window.gpa, "quick_tools", .{ .key = .space });

    try window.keybinds.putNoClobber(window.gpa, "pencil", .{ .key = .d, .command = false, .control = false, .alt = false, .shift = false });
    try window.keybinds.putNoClobber(window.gpa, "eraser", .{ .key = .e, .command = false, .control = false, .alt = false, .shift = false });
    try window.keybinds.putNoClobber(window.gpa, "bucket", .{ .key = .b, .command = false, .control = false, .alt = false, .shift = false });
    try window.keybinds.putNoClobber(window.gpa, "selection", .{ .key = .s, .command = false, .control = false, .alt = false, .shift = false });
    try window.keybinds.putNoClobber(window.gpa, "pointer", .{ .key = .escape });

    try window.keybinds.putNoClobber(window.gpa, "up", .{ .key = .up });
    try window.keybinds.putNoClobber(window.gpa, "down", .{ .key = .down });
    try window.keybinds.putNoClobber(window.gpa, "left", .{ .key = .left });
    try window.keybinds.putNoClobber(window.gpa, "right", .{ .key = .right });

    try window.keybinds.putNoClobber(window.gpa, "cancel", .{ .key = .escape });
}

// These keybinds are available regardless of the currently focused widget.
// Any binds that need to be consumed by a specific widget do not need to trigger here.
pub fn tick() !void {
    for (dvui.events()) |e| {
        if (e.handled) continue;

        switch (e.evt) {
            .key => |ke| {
                // macOS: NSMenu key equivalents already call `FizzyNativeMenuAction` (see Editor.flushQueuedNativeMenuActions).
                // SDL still delivers the same key events, so handling them here too would run the action twice.
                if (builtin.os.tag != .macos) {
                    if (ke.matchBind("open_folder") and ke.action == .down) {
                        if (try dvui.dialogNativeFolderSelect(dvui.currentWindow().arena(), .{
                            .title = "Open Project Folder",
                        })) |folder| {
                            try fizzy.editor.setProjectFolder(folder);
                        }
                    }

                    if (ke.matchBind("open_files") and ke.action == .down) {
                        if (try dvui.dialogNativeFileOpenMultiple(
                            dvui.currentWindow().arena(),
                            .{ .title = "Open Files...", .filter_description = ".fiz, .pixi, .png, .jpg, .jpeg", .filters = &.{ "*.fiz", "*.pixi", "*.png", "*.jpg", "*.jpeg" } },
                        )) |files| {
                            for (files) |file| {
                                _ = fizzy.editor.openFilePath(file, fizzy.editor.open_workspace_grouping) catch {
                                    std.log.err("Failed to open file: {s}", .{file});
                                };
                            }
                        }
                    }
                }

                if (ke.matchBind("quick_tools")) {
                    const rm = &fizzy.editor.tools.radial_menu;
                    switch (ke.action) {
                        .down => {
                            const mp = dvui.currentWindow().mouse_pt;
                            rm.mouse_position = mp;
                            rm.center = mp;
                            rm.opened_by_press = false;
                            rm.suppress_next_pointer_release = false;
                            rm.outside_click_press_p = null;
                            rm.visible = true;
                        },
                        .repeat => rm.visible = true,
                        .up => rm.close(),
                    }
                    // If we include a refresh here, the underlying gui has a chance to reset the cursor
                    dvui.refresh(null, @src(), dvui.currentWindow().data().id);
                }

                if (ke.matchBind("increase_stroke_size") and (ke.action == .down or ke.action == .repeat)) {
                    if (fizzy.editor.tools.current != .selection or fizzy.editor.tools.selection_mode == .pixel) {
                        if (fizzy.editor.tools.stroke_size < fizzy.Editor.Tools.max_brush_size - 1)
                            fizzy.editor.tools.stroke_size += 1;

                        fizzy.editor.tools.setStrokeSize(fizzy.editor.tools.stroke_size);
                    }
                }

                if (ke.matchBind("save_as") and ke.action == .down) {
                    fizzy.editor.requestSaveAs();
                }

                if (ke.matchBind("save_all") and ke.action == .down) {
                    fizzy.editor.saveAll() catch {
                        std.log.err("Failed to save all", .{});
                    };
                }

                if (ke.matchBind("export") and ke.action == .down) {
                    // Create a generic dialog that contains typical okay and cancel buttons and header
                    // The displayFn will be called during the drawing of the dialog, prior to ok and cancel buttons
                    var mutex = fizzy.dvui.dialog(@src(), .{
                        .displayFn = fizzy.Editor.Dialogs.Export.dialog,
                        .callafterFn = fizzy.Editor.Dialogs.Export.callAfter,
                        .title = "Export...",
                        .ok_label = "Export",
                        .cancel_label = "Cancel",
                        .resizeable = false,
                        .modal = false,
                        .header_kind = .info,
                        .default = .ok,
                    });
                    mutex.mutex.unlock(dvui.io);
                }

                if (ke.matchBind("decrease_stroke_size") and (ke.action == .down or ke.action == .repeat)) {
                    if (fizzy.editor.tools.current != .selection or fizzy.editor.tools.selection_mode == .pixel) {
                        if (fizzy.editor.tools.stroke_size > 1)
                            fizzy.editor.tools.stroke_size -= 1;

                        fizzy.editor.tools.setStrokeSize(fizzy.editor.tools.stroke_size);
                    }
                }

                if (ke.matchBind("delete_selection_contents")) {
                    if (ke.action == .down) {
                        fizzy.editor.deleteSelectedContents();
                    }
                }

                if (builtin.os.tag != .macos) {
                    if (ke.matchBind("explorer") and ke.action == .down) {
                        if (fizzy.editor.explorer.closed) {
                            fizzy.editor.explorer.open();
                        } else {
                            fizzy.editor.explorer.close();
                        }
                    }
                }

                if (ke.matchBind("activate") and ke.action == .down) {
                    fizzy.editor.accept() catch {
                        std.log.err("Failed to accept", .{});
                    };
                }

                if (ke.matchBind("cancel") and ke.action == .down) {
                    fizzy.editor.cancel() catch {
                        std.log.err("Failed to cancel", .{});
                    };
                }

                if (builtin.os.tag != .macos) {
                    if (ke.matchBind("undo") and (ke.action == .down or ke.action == .repeat)) {
                        fizzy.editor.undo() catch {
                            std.log.err("Failed to undo", .{});
                        };
                    }

                    if (ke.matchBind("copy") and ke.action == .down) {
                        fizzy.editor.copy() catch {
                            std.log.err("Failed to copy", .{});
                        };
                    }

                    if (ke.matchBind("paste") and ke.action == .down) {
                        fizzy.editor.paste() catch {
                            std.log.err("Failed to paste", .{});
                        };
                    }

                    if (ke.matchBind("redo") and (ke.action == .down or ke.action == .repeat)) {
                        fizzy.editor.redo() catch {
                            std.log.err("Failed to redo", .{});
                        };
                    }

                    if (ke.matchBind("save") and ke.action == .down) {
                        fizzy.editor.save() catch {
                            std.log.err("Failed to save", .{});
                        };
                    }

                    if (ke.matchBind("new_file") and ke.action == .down) {
                        fizzy.editor.requestNewFileDialog();
                    }

                    if (ke.matchBind("transform") and ke.action == .down) {
                        fizzy.editor.transform() catch {
                            std.log.err("Failed to transform", .{});
                        };
                    }

                    if (ke.matchBind("grid_layout") and ke.action == .down) {
                        if (fizzy.editor.activeFile() != null) {
                            fizzy.editor.requestGridLayoutDialog();
                        }
                    }
                }

                if (ke.matchBind("pencil") and ke.action == .down) {
                    fizzy.editor.tools.set(.pencil);
                }
                if (ke.matchBind("eraser") and ke.action == .down) {
                    fizzy.editor.tools.set(.eraser);
                }
                if (ke.matchBind("bucket") and ke.action == .down) {
                    fizzy.editor.tools.set(.bucket);
                }
                if (ke.matchBind("pointer") and ke.action == .down) {
                    fizzy.editor.tools.set(.pointer);
                }
                if (ke.matchBind("selection") and ke.action == .down) {
                    fizzy.editor.tools.set(.selection);
                }
            },
            else => {},
        }
    }
}
