const std = @import("std");
const builtin = @import("builtin");

const fizzy = @import("../fizzy.zig");
const dvui = @import("dvui");

pub const Keybinds = @This();

/// Register the shell's own global / navigation / region binds. File-management
/// binds and pixel-art editing binds are contributed by the workbench and
/// pixel-art plugins (their `contributeKeybinds`), which `Editor.postInit` invokes
/// after the plugins register. This runs during `Editor.init`, before postInit, so
/// the shell binds land first; the split is disjoint, so no `putNoClobber` clashes.
///
/// Runtime mac detection — `builtin.os.tag.isDarwin()` is `false` for
/// wasm32-freestanding, so macOS web users would otherwise get the Windows (Ctrl)
/// bindings. `fizzy.platform.isMacOS()` reads DVUI's `navigator.platform`-derived
/// choice on web and uses `os.tag` on native.
pub fn register() !void {
    const window = dvui.currentWindow();

    // Region toggles (explorer / workspace) are platform-dependent.
    if (fizzy.platform.isMacOS()) {
        try window.keybinds.putNoClobber(window.gpa, "explorer", .{ .command = true, .key = .e });
        try window.keybinds.putNoClobber(window.gpa, "workspace", .{ .command = true, .key = .w });
    } else {
        try window.keybinds.putNoClobber(window.gpa, "explorer", .{ .control = true, .key = .e });
        try window.keybinds.putNoClobber(window.gpa, "workspace", .{ .control = true, .key = .w });
    }

    try window.keybinds.putNoClobber(window.gpa, "shift", .{ .shift = true });

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
                                _ = fizzy.editor.openFilePath(file, fizzy.editor.currentGroupingID()) catch {
                                    std.log.err("Failed to open file: {s}", .{file});
                                };
                            }
                        }
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
                        if (fizzy.editor.activeDoc() != null) {
                            fizzy.editor.requestGridLayoutDialog();
                        }
                    }
                }
            },
            else => {},
        }
    }
}
