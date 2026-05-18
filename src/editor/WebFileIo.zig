//! Browser file open (picker) and save (download) helpers for the wasm build.

const std = @import("std");
const builtin = @import("builtin");
const dvui = @import("dvui");
const fizzy = @import("../fizzy.zig");

const open_accept = ".fiz,.pixi,.png,.jpg,.jpeg,image/png,image/jpeg";

var open_callback: ?*const fn (?[][:0]const u8) void = null;
var open_grouping: u64 = 0;
/// Set when the picker is opened; must match `wasmFileUploadedMultiple` lookup.
var open_picker_id: ?dvui.Id = null;

/// Pending save-as: filename chosen in the web save dialog, consumed by `Editor.processPendingSaveAs`.
pub var pending_save_filename: ?[]u8 = null;

/// Ensures the download name has `ext` (e.g. `.fiz`) so the OS and re-open picker recognize the type.
fn downloadNameWithExtension(allocator: std.mem.Allocator, filename: []const u8, ext: []const u8) ![]const u8 {
    if (std.ascii.eqlIgnoreCase(std.fs.path.extension(filename), ext)) {
        return try allocator.dupe(u8, filename);
    }
    const base = std.fs.path.basename(filename);
    const stem: []const u8 = if (std.mem.lastIndexOf(u8, base, ".")) |i| base[0..i] else base;
    if (stem.len == 0) {
        return try std.fmt.allocPrint(allocator, "download{s}", .{ext});
    }
    return try std.fmt.allocPrint(allocator, "{s}{s}", .{ stem, ext });
}

pub fn downloadBytes(filename: []const u8, data: []const u8) !void {
    try dvui.backend.downloadData(filename, data);
}

pub fn downloadBytesWithExtension(filename: []const u8, ext: []const u8, data: []const u8) !void {
    const name = try downloadNameWithExtension(fizzy.app.allocator, filename, ext);
    defer fizzy.app.allocator.free(name);
    try downloadBytes(name, data);
}

pub fn showOpenFileDialog(
    cb: *const fn (?[][:0]const u8) void,
    _: []const fizzy.backend.DialogFileFilter,
    _: []const u8,
    _: ?[]const u8,
) void {
    if (comptime builtin.target.cpu.arch != .wasm32) return;
    open_callback = cb;
    open_grouping = fizzy.editor.open_workspace_grouping;
    open_picker_id = dvui.Id.extendId(null, @src(), 0);
    dvui.dialogWasmFileOpenMultiple(open_picker_id.?, .{ .accept = open_accept });
}

/// `showSaveFileDialog` on web: there is no useful pre-save dialog to draw —
/// the browser itself prompts for save location (or downloads straight into
/// the user's Downloads folder) when `wasm_download_data` fires. Skip the DVUI
/// `WebSaveAs` dialog entirely and forward the default filename straight to
/// the callback so the editor's save flow proceeds to encoding + download.
pub fn showSaveFileDialog(
    cb: *const fn (?[][:0]const u8) void,
    _: []const fizzy.backend.DialogFileFilter,
    default_filename: []const u8,
    _: ?[]const u8,
) void {
    if (comptime builtin.target.cpu.arch != .wasm32) return;

    const filename_z = fizzy.app.allocator.dupeZ(u8, default_filename) catch {
        dvui.log.err("Save: out of memory preparing filename", .{});
        cb(null);
        return;
    };
    defer fizzy.app.allocator.free(filename_z);

    // Stack slice handed to the synchronous callback. The callback dupes
    // immediately into `editor.pending_save_as_path`, so the underlying buffer
    // doesn't need to outlive this call.
    var paths: [1][:0]const u8 = .{filename_z};
    cb(&paths);
}

/// Poll the wasm file picker once per frame. Loads picked files synchronously.
pub fn pollOpenPicker(editor: *fizzy.Editor) void {
    if (comptime builtin.target.cpu.arch != .wasm32) return;

    const id = open_picker_id orelse return;
    const uploaded = dvui.wasmFileUploadedMultiple(id) orelse return;
    open_picker_id = null;

    for (uploaded) |wasm_file| {
        const bytes = wasm_file.readData(fizzy.app.allocator) catch |err| {
            dvui.log.err("Failed to read uploaded file {s}: {any}", .{ wasm_file.name, err });
            continue;
        };
        defer fizzy.app.allocator.free(bytes);

        const path_owned = fizzy.app.allocator.dupe(u8, wasm_file.name) catch continue;
        if (editor.openFileFromBytes(path_owned, bytes, open_grouping)) |file| {
            editor.open_files.put(fizzy.app.allocator, file.id, file) catch {
                var f = file;
                f.deinit();
                fizzy.app.allocator.free(path_owned);
            };
            if (editor.open_files.getIndex(file.id)) |idx| {
                editor.setActiveFile(idx);
                editor.pending_composite_warmup = true;
            }
        } else |_| {
            fizzy.app.allocator.free(path_owned);
        }
    }

    open_callback = null;
}
