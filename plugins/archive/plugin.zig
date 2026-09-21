//! The archive plugin: a `.zip` opens as a mounted folder. The tab that opens is the mount's
//! handle — its name, whether it has unsaved changes, and a way to take the archive back —
//! while the files inside are browsed, opened, edited, created and deleted in the explorer
//! exactly like a folder on disk, because to the host they are one (`Host.mount`).
//!
//! Saving the tab packs the tree back into an archive: to the original file natively, as a
//! download on the web. Closing the tab unmounts. That is the whole plugin — the archive
//! format lives in `core.vfs.zip`, the tree in `core.vfs.Mem`, the mounting in the host.
const std = @import("std");
const builtin = @import("builtin");
const sdk = @import("fizzy_sdk");
const dvui = @import("dvui");
const core = @import("core");
const State = @import("src/State.zig");
const Document = @import("src/Document.zig");
const DocHandle = sdk.DocHandle;

/// Injected at build time from `plugin.zig.zon`.
pub const plugin_options = @import("fizzy_plugin_options");
pub const plugin_id = plugin_options.id;

var plugin: sdk.Plugin = .{
    .state = undefined,
    .vtable = &vtable,
    .id = plugin_id,
    .display_name = plugin_options.name,
};

const vtable: sdk.Plugin.VTable = .{
    .deinit = deinit,
    .fileTypes = fileTypes,
    .documentStackSize = documentStackSize,
    .documentStackAlign = documentStackAlign,
    .loadDocument = loadDocument,
    .loadDocumentFromBytes = loadDocumentFromBytes,
    .documentIdFromBuffer = documentIdFromBuffer,
    .setDocumentGroupingOnBuffer = setDocumentGroupingOnBuffer,
    .deinitDocumentBuffer = deinitDocumentBuffer,
    .registerOpenDocument = registerOpenDocument,
    .documentPtr = documentPtr,
    .documentByPath = documentByPath,
    .unregisterDocument = unregisterDocument,
    .documentGrouping = documentGrouping,
    .setDocumentGrouping = setDocumentGrouping,
    .documentPath = documentPath,
    .setDocumentPath = setDocumentPath,
    .documentHasNativeExtension = documentHasNativeExtension,
    .documentHasRecognizedSaveExtension = documentHasRecognizedSaveExtension,
    .documentDefaultSaveAsFilename = documentDefaultSaveAsFilename,
    .drawDocument = drawDocument,
    .infobarEntries = infobarEntries,
    .closeDocument = closeDocument,
    .isDirty = isDirty,
    .saveDocument = saveDocument,
    .saveDocumentAs = saveDocumentAs,
    .documentBytes = documentBytes,
    .documentWritten = documentWritten,
};

comptime {
    sdk.Plugin.assertEditorVTable(vtable);
}

pub fn register(host: *sdk.Host) !void {
    const gpa = host.allocator;
    const st = try gpa.create(State);
    errdefer gpa.destroy(st);
    st.* = .{};
    plugin.state = @ptrCast(st);

    try host.registerPlugin(&plugin);
    try host.registerFileKind(.{ .owner = &plugin, .kind = fileKind });
}

pub fn pluginPtr() *sdk.Plugin {
    return &plugin;
}

fn deinit(state: *anyopaque) void {
    const st: *State = @ptrCast(@alignCast(state));
    const gpa = sdk.allocator();
    st.deinit(gpa);
    gpa.destroy(st);
}

const extensions = [_][]const u8{".zip"};

fn fileTypes(_: *anyopaque) []const []const u8 {
    return &extensions;
}

fn fileKind(_: ?*anyopaque, ext: []const u8) ?[]const u8 {
    return if (std.ascii.eqlIgnoreCase(ext, ".zip")) "archive" else null;
}

fn documentStackSize(_: *anyopaque) usize {
    return @sizeOf(Document);
}
fn documentStackAlign(_: *anyopaque) usize {
    return @alignOf(Document);
}
fn loadDocument(_: *anyopaque, path: []const u8, out_doc: *anyopaque) anyerror!void {
    try sdk.document.loadPathInto(Document, path, docBuf(out_doc));
}
fn loadDocumentFromBytes(_: *anyopaque, path: []const u8, bytes: []const u8, out_doc: *anyopaque) anyerror!void {
    try sdk.document.loadBytesInto(Document, path, bytes, docBuf(out_doc));
}
fn documentIdFromBuffer(_: *anyopaque, doc: *anyopaque) u64 {
    return docBuf(doc).id;
}
fn setDocumentGroupingOnBuffer(_: *anyopaque, doc: *anyopaque, grouping: u64) void {
    docBuf(doc).grouping = grouping;
}
fn deinitDocumentBuffer(_: *anyopaque, doc: *anyopaque) void {
    docBuf(doc).deinit();
}

/// The document becomes an open one here — and its tree becomes a mount at the same moment,
/// so the explorer shows it as soon as the tab exists.
fn registerOpenDocument(state: *anyopaque, file: *anyopaque) anyerror!*anyopaque {
    const st: *State = @ptrCast(@alignCast(state));
    const doc = docBuf(file);
    try st.docs.put(sdk.allocator(), doc.id, doc.*);
    const stable = st.docs.getPtr(doc.id).?;
    stable.mount() catch |err| dvui.log.err("archive: could not mount {s}: {t}", .{ stable.prefix, err });
    // The archive becomes the open root — there is one, and opening anything replaces it.
    // Closing this tab unmounts, which closes the root again.
    if (stable.mounted) {
        sdk.host().setProjectFolder(stable.prefix) catch |err| dvui.log.err("archive: could not open {s}: {t}", .{ stable.prefix, err });
    }
    return stable;
}
fn documentPtr(state: *anyopaque, id: u64) ?*anyopaque {
    const st: *State = @ptrCast(@alignCast(state));
    return st.docById(id);
}
fn documentByPath(state: *anyopaque, path: []const u8) ?*anyopaque {
    const st: *State = @ptrCast(@alignCast(state));
    return st.docByPath(path);
}
fn unregisterDocument(state: *anyopaque, id: u64) void {
    const st: *State = @ptrCast(@alignCast(state));
    _ = st.docs.swapRemove(id);
}

fn documentGrouping(_: *anyopaque, handle: DocHandle) u64 {
    return (docFrom(handle) orelse return 0).grouping;
}
fn setDocumentGrouping(_: *anyopaque, handle: DocHandle, grouping: u64) void {
    (docFrom(handle) orelse return).grouping = grouping;
}
fn documentPath(_: *anyopaque, handle: DocHandle) []const u8 {
    return (docFrom(handle) orelse return "").path;
}
fn setDocumentPath(_: *anyopaque, handle: DocHandle, path: []const u8) anyerror!void {
    const doc = docFrom(handle) orelse return error.DocumentNotFound;
    const gpa = sdk.allocator();
    const new_path = try gpa.dupe(u8, path);
    gpa.free(doc.path);
    doc.path = new_path;
}
fn documentHasNativeExtension(_: *anyopaque, _: DocHandle) bool {
    return true;
}
fn documentHasRecognizedSaveExtension(_: *anyopaque, handle: DocHandle) bool {
    const doc = docFrom(handle) orelse return false;
    return std.ascii.eqlIgnoreCase(std.fs.path.extension(doc.path), ".zip");
}
fn documentDefaultSaveAsFilename(_: *anyopaque, handle: DocHandle, allocator: std.mem.Allocator) anyerror![]const u8 {
    const doc = docFrom(handle) orelse return error.DocumentNotFound;
    return allocator.dupe(u8, std.fs.path.basename(doc.path));
}

fn drawDocument(_: *anyopaque, handle: DocHandle) anyerror!void {
    const doc = docFrom(handle) orelse return;
    var box = dvui.box(@src(), .{ .dir = .vertical }, .{ .expand = .both, .padding = dvui.Rect.all(24), .background = false });
    defer box.deinit();

    const arena = sdk.host().arena();
    dvui.labelNoFmt(@src(), std.fs.path.basename(doc.path), .{}, .{ .font = dvui.Font.theme(.title) });
    var files: usize = 0;
    for (doc.mem.nodes.values()) |n| {
        if (n.kind == .file) files += 1;
    }
    const line = std.fmt.allocPrint(arena, "Open as {s} — {d} file{s}. Browse and edit it in the explorer; closing this tab closes it.", .{
        doc.prefix, files, if (files == 1) "" else "s",
    }) catch "";
    dvui.labelNoFmt(@src(), line, .{}, .{});
    dvui.labelNoFmt(@src(), if (doc.isDirty())
        "Changed since it was opened. Save this tab to write the archive back" ++ (if (builtin.target.cpu.arch == .wasm32) " as a download." else ".")
    else
        "Unchanged.", .{}, .{ .color_text = .{ .color = dvui.themeGet().color(.control, .text) } });
}

fn infobarEntries(_: *anyopaque, active_doc: ?DocHandle) []const sdk.infobar.Entry {
    const handle = active_doc orelse return &.{};
    if (handle.owner != &plugin) return &.{};
    const doc = docFrom(handle) orelse return &.{};
    const arena = sdk.host().arena();
    const entries = arena.alloc(sdk.infobar.Entry, 1) catch return &.{};
    entries[0] = .{ .icon = dvui.entypo.archive, .text = doc.prefix };
    return entries;
}

fn closeDocument(_: *anyopaque, handle: DocHandle) void {
    (docFrom(handle) orelse return).deinit();
}
fn isDirty(_: *anyopaque, handle: DocHandle) bool {
    return (docFrom(handle) orelse return false).isDirty();
}

/// Native: pack and write back to the archive's own path.
fn saveDocument(_: *anyopaque, handle: DocHandle) anyerror!void {
    const doc = docFrom(handle) orelse return error.DocumentNotFound;
    if (comptime builtin.target.cpu.arch == .wasm32) return error.Unsupported;
    const gpa = sdk.allocator();
    const bytes = try doc.pack(gpa);
    defer gpa.free(bytes);
    try std.Io.Dir.cwd().writeFile(dvui.io, .{ .sub_path = doc.path, .data = bytes });
    doc.markClean();
}
fn saveDocumentAs(state: *anyopaque, handle: DocHandle, path: []const u8, _: *dvui.Window) anyerror!void {
    try setDocumentPath(state, handle, path);
    try saveDocument(state, handle);
}
/// The storage-agnostic half: the host writes these (a web download, another mount).
fn documentBytes(_: *anyopaque, handle: DocHandle, allocator: std.mem.Allocator) anyerror![]u8 {
    const doc = docFrom(handle) orelse return error.DocumentNotFound;
    return doc.pack(allocator);
}
fn documentWritten(state: *anyopaque, handle: DocHandle, path: []const u8) anyerror!void {
    const doc = docFrom(handle) orelse return error.DocumentNotFound;
    if (!std.mem.eql(u8, path, doc.path)) try setDocumentPath(state, handle, path);
    doc.markClean();
}

fn docBuf(buf: *anyopaque) *Document {
    return @ptrCast(@alignCast(buf));
}
fn docFrom(handle: DocHandle) ?*Document {
    const st: *State = @ptrCast(@alignCast(plugin.state));
    return st.docById(handle.id);
}
