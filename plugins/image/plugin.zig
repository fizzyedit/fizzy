//! The image viewer plugin: read-only PNG/JPG/JPEG tabs with zoom/pan. Registration + document
//! vtable. Module root — fizzy resolves `@import("image")` to this file when compiled into
//! the app (static embed); the generated dylib root imports it as `plugin_impl`.
const std = @import("std");
const sdk = @import("fizzy_sdk");
const dvui = @import("dvui");
const State = @import("src/State.zig");
const Document = @import("src/Document.zig");
const ImageView = @import("src/ImageView.zig");
const DocHandle = sdk.DocHandle;

/// Injected at build time from `plugin.zig.zon` (see `static/integration.zig` /
/// `plugins/shared/build/helpers.zig`'s `pluginOptions`) — one source of truth for
/// identity, not duplicated as string literals here.
pub const plugin_options = @import("fizzy_plugin_options");

/// This plugin's stable id — the single source of truth other modules (e.g. fizzy's
/// `Editor.isBundledPluginId`) read instead of retyping the string.
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
    .bindDocumentToPane = bindDocumentToPane,
    .documentHasNativeExtension = documentHasNativeExtension,
    .documentHasRecognizedSaveExtension = documentHasRecognizedSaveExtension,
    .drawDocument = drawDocument,
    .infobarEntries = infobarEntries,
    .closeDocument = closeDocument,
    .reloadDocument = reloadDocument,
    .isDirty = isDirty,
    .saveDocument = saveDocument,
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

/// The flat-raster formats this viewer opens. One list, used both for the routing offer
/// (`fileTypes`) and for the file-tree glyph / document checks (`isFlatImageExtension`).
///
/// Exactly what stb_image decodes, no more: a GIF opens as its first frame, and BMP/TGA are
/// the other still formats it reads. Anything listed here that stb could *not* decode would
/// fall through to the text plugin, which opens them as plain text.
const flat_image_extensions = [_][]const u8{ ".png", ".jpg", ".jpeg", ".gif", ".bmp", ".tga" };

fn isFlatImageExtension(ext: []const u8) bool {
    for (flat_image_extensions) |e| {
        if (std.ascii.eqlIgnoreCase(ext, e)) return true;
    }
    return false;
}

fn fileTypes(_: *anyopaque) []const []const u8 {
    return &flat_image_extensions;
}

/// What kind of file this is — not what it looks like. Fizzy maps kinds to glyphs in
/// `editor/file_glyphs.zig`; another app maps them differently, and this plugin neither knows
/// nor cares. Previously this drew `entypo.image` directly, which made a plugin responsible for
/// an app's visual language.
fn fileKind(_: ?*anyopaque, ext: []const u8) ?[]const u8 {
    return if (isFlatImageExtension(ext)) "image" else null;
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
/// Where an "Open to the side" lands. The app decides the grouping *before* the load is handed
/// over and writes it here, on the staging buffer, because the document does not exist as an
/// open document until the load finishes. Missing this hook is silent: the load succeeds, the
/// grouping is dropped, and the image opens in the pane the user was already looking at.
fn setDocumentGroupingOnBuffer(_: *anyopaque, doc: *anyopaque, grouping: u64) void {
    docBuf(doc).grouping = grouping;
}
fn deinitDocumentBuffer(_: *anyopaque, doc: *anyopaque) void {
    docBuf(doc).deinit();
}

fn registerOpenDocument(state: *anyopaque, file: *anyopaque) anyerror!*anyopaque {
    const st: *State = @ptrCast(@alignCast(state));
    const doc = docBuf(file);
    try st.docs.put(sdk.allocator(), doc.id, doc.*);
    return st.docs.getPtr(doc.id).?;
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
fn bindDocumentToPane(_: *anyopaque, handle: DocHandle, canvas_id: dvui.Id, _: *anyopaque, _: bool) void {
    const doc = docFrom(handle) orelse return;
    doc.canvas.id = canvas_id;
}
fn documentHasNativeExtension(_: *anyopaque, _: DocHandle) bool {
    return true;
}
fn documentHasRecognizedSaveExtension(_: *anyopaque, _: DocHandle) bool {
    return true;
}

fn drawDocument(_: *anyopaque, handle: DocHandle) anyerror!void {
    const doc = docFrom(handle) orelse return;
    try ImageView.draw(doc);
}

fn infobarEntries(_: *anyopaque, active_doc: ?DocHandle) []const sdk.infobar.Entry {
    const handle = active_doc orelse return &.{};
    if (handle.owner != &plugin) return &.{};
    const doc = docFrom(handle) orelse return &.{};
    const arena = sdk.host().arena();
    const dim = std.fmt.allocPrint(arena, "{d}×{d} px", .{ doc.width, doc.height }) catch return &.{};
    const name = std.fs.path.basename(doc.path);
    const entries = arena.alloc(sdk.infobar.Entry, 2) catch return &.{};
    entries[0] = .{ .icon = dvui.entypo.image, .text = if (name.len > 0) name else "Untitled" };
    entries[1] = .{ .text = dim };
    return entries;
}

fn closeDocument(_: *anyopaque, handle: DocHandle) void {
    (docFrom(handle) orelse return).deinit();
}
fn reloadDocument(_: *anyopaque, handle: DocHandle) anyerror!void {
    const doc = docFrom(handle) orelse return error.DocumentNotFound;
    try doc.reloadFromDisk();
}
fn isDirty(_: *anyopaque, _: DocHandle) bool {
    return false;
}
fn saveDocument(_: *anyopaque, _: DocHandle) anyerror!void {}

fn docBuf(buf: *anyopaque) *Document {
    return @ptrCast(@alignCast(buf));
}
fn docFrom(handle: DocHandle) ?*Document {
    const st: *State = @ptrCast(@alignCast(plugin.state));
    return st.docById(handle.id);
}
