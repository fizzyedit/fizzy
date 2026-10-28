//! Save-as for the browser build: pick a download filename. For the document's own Save / Save
//! As, `Editor.processPendingSaveAs` then encodes and downloads it; for a plugin's export
//! (`host.showSaveDialog`), the name goes straight back to that plugin's callback, which writes
//! its own bytes — the open document is never touched.

const std = @import("std");
const dvui = @import("dvui");
const fizzy = @import("../../fizzy.zig");
const WebFileIo = @import("../WebFileIo.zig");

var default_name_storage: ?[]u8 = null;

/// What the open dialog is for; one dialog at a time (`active`), so one of each is enough.
var current_kind: Kind = .save;
/// `.export_to` only: whom to hand the chosen name to — exactly once, null on cancel.
var export_callback: ?*const fn (?[][:0]const u8) void = null;
/// `.export_to` only: the caller's filter patterns joined with `;` (`"png;jpg;jpeg"`), so a
/// name typed without its extension still downloads as the type the caller is about to write.
var export_patterns_storage: ?[]u8 = null;

pub const Kind = enum {
    save,
    save_as,
    /// A plugin's own save dialog (`host.showSaveDialog`), not the document's.
    export_to,

    fn dialogTitle(self: Kind) []const u8 {
        return switch (self) {
            .save => "Save",
            .save_as => "Save As",
            .export_to => "Export",
        };
    }
};

/// The document's Save / Save As: the confirmed name lands in `WebFileIo.pending_save_filename`.
pub fn request(default_filename: []const u8, kind: Kind) void {
    std.debug.assert(kind != .export_to);
    _ = open(default_filename, kind);
}

/// The web stand-in for a native save panel: `cb` gets the one confirmed name, or null when the
/// user backs out (or another save dialog is already up), exactly as SDL delivers it natively.
pub fn requestExport(
    cb: *const fn (?[][:0]const u8) void,
    filters: []const fizzy.backend.DialogFileFilter,
    default_filename: []const u8,
) void {
    const gpa = fizzy.entry().allocator;
    var patterns: std.ArrayList(u8) = .empty;
    for (filters) |f| {
        if (patterns.items.len > 0) patterns.append(gpa, ';') catch break;
        patterns.appendSlice(gpa, std.mem.span(f.pattern)) catch break;
    }
    const owned_patterns = patterns.toOwnedSlice(gpa) catch {
        patterns.deinit(gpa);
        cb(null);
        return;
    };
    if (!open(default_filename, .export_to)) {
        gpa.free(owned_patterns);
        cb(null);
        return;
    }
    export_callback = cb;
    if (export_patterns_storage) |old| gpa.free(old);
    export_patterns_storage = owned_patterns;
}

fn open(default_filename: []const u8, kind: Kind) bool {
    if (active(dvui.currentWindow())) return false;
    if (default_name_storage) |old| {
        fizzy.entry().allocator.free(old);
        default_name_storage = null;
    }
    default_name_storage = fizzy.entry().allocator.dupe(u8, default_filename) catch {
        dvui.log.err("Web Save As: out of memory", .{});
        return false;
    };
    current_kind = kind;
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
    return true;
}

pub fn active(win: *dvui.Window) bool {
    var it = win.dialogs.iterator(null);
    while (it.next()) |d| {
        const df = dvui.dataGet(null, d.id, "_displayFn", fizzy.core.dialogs.DisplayFn) orelse continue;
        if (df == dialog) return true;
    }
    return false;
}

pub fn dialog(id: dvui.Id) fizzy.core.dialogs.Error!bool {
    var outer = dvui.box(@src(), .{ .dir = .vertical }, .{ .expand = .both, .padding = .all(12) });
    defer outer.deinit();

    dvui.labelNoFmt(
        @src(),
        "Files download to your browser's download folder.",
        .{},
        .{ .color_text = .{ .color = dvui.themeGet().color(.control, .text) }, .margin = .{ .h = 8 } },
    );

    const placeholder = if (current_kind == .export_to) "filename" else "filename.fiz";
    const te = dvui.textEntry(@src(), .{ .placeholder = placeholder }, .{ .expand = .horizontal });
    defer fizzy.core.widgets.textEntryDeinit(te);
    _ = fizzy.core.widgets.textEntryMenu(te);

    if (dvui.firstFrame(te.data().id)) {
        if (default_name_storage) |def| te.textSet(def, false);
    }

    const name = te.getText();
    dvui.dataSetSlice(null, id, "_save_as_name", name);
    return name.len > 0;
}

pub fn callAfter(id: dvui.Id, response: dvui.enums.DialogResponse) fizzy.core.dialogs.Error!void {
    const name = dvui.dataGetSlice(null, id, "_save_as_name", []const u8) orelse "";
    defer {
        if (default_name_storage) |old| {
            fizzy.entry().allocator.free(old);
            default_name_storage = null;
        }
    }

    if (current_kind == .export_to) return exportCallAfter(name, response);

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

/// Runs the caller's callback right here, inside the frame — where the native backend's
/// `pollPendingDialogResult` delivers it too — so it can encode and download on the spot.
/// Deliberately nothing of `pending_save_filename`: this is not the document's save.
fn exportCallAfter(name: []const u8, response: dvui.enums.DialogResponse) void {
    const gpa = fizzy.entry().allocator;
    const cb = export_callback orelse return;
    export_callback = null;
    const patterns = export_patterns_storage orelse "";
    defer {
        if (export_patterns_storage) |p| gpa.free(p);
        export_patterns_storage = null;
    }

    if (response != .ok or name.len == 0) return cb(null);

    const path = exportFileName(gpa, name, patterns) catch {
        dvui.log.err("Web Export: out of memory", .{});
        return cb(null);
    };
    defer gpa.free(path);
    var paths = [_][:0]const u8{path};
    cb(&paths);
}

/// `name` as typed when its extension is one of `patterns` (or they accept anything); otherwise
/// the first pattern appended, so `anim` exports as `anim.gif`. Appended, never swapped in: a
/// dot the user typed is theirs.
fn exportFileName(gpa: std.mem.Allocator, name: []const u8, patterns: []const u8) ![:0]u8 {
    const ext = std.fs.path.extension(name);
    const typed = if (ext.len > 1) ext[1..] else "";
    var first: []const u8 = "";
    var it = std.mem.tokenizeScalar(u8, patterns, ';');
    while (it.next()) |pattern| {
        if (std.mem.eql(u8, pattern, "*")) return gpa.dupeSentinel(u8, name, 0);
        if (typed.len > 0 and std.ascii.eqlIgnoreCase(pattern, typed)) return gpa.dupeSentinel(u8, name, 0);
        if (first.len == 0) first = pattern;
    }
    if (first.len == 0) return gpa.dupeSentinel(u8, name, 0);
    return gpa.printSentinel("{s}.{s}", .{ name, first }, 0);
}
