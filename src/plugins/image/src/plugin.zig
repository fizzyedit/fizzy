//! The image viewer plugin: read-only PNG/JPG/JPEG tabs with zoom/pan. Registration + document vtable.
const std = @import("std");
const internal = @import("../image.zig");
const sdk = internal.sdk;
const dvui = internal.dvui;
const State = internal.State;
const Document = internal.Document;
const ImageView = internal.ImageView;
const DocHandle = sdk.DocHandle;

const plugin_options = @import("fizzy_plugin_options");

pub const manifest = sdk.PluginManifest{
    .id = "image",
    .name = "Image",
    .version = plugin_options.version,
};

var plugin: sdk.Plugin = .{
    .state = undefined,
    .vtable = &vtable,
    .id = "image",
    .display_name = "Image",
};

const vtable: sdk.Plugin.VTable = .{
    .deinit = deinit,
    .fileTypePriority = fileTypePriority,
    .documentStackSize = documentStackSize,
    .documentStackAlign = documentStackAlign,
    .loadDocument = loadDocument,
    .loadDocumentFromBytes = loadDocumentFromBytes,
    .documentIdFromBuffer = documentIdFromBuffer,
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
    .closeDocument = closeDocument,
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
    try host.registerFileIcon(.{ .owner = &plugin, .draw = drawFileIcon });
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

fn isFlatImageExtension(ext: []const u8) bool {
    return std.ascii.eqlIgnoreCase(ext, ".png") or
        std.ascii.eqlIgnoreCase(ext, ".jpg") or
        std.ascii.eqlIgnoreCase(ext, ".jpeg");
}

fn fileTypePriority(_: *anyopaque, ext: []const u8) ?u8 {
    if (!isFlatImageExtension(ext)) return null;
    return 99;
}

fn drawFileIcon(_: ?*anyopaque, ext: []const u8, _: []const u8, color: dvui.Color) bool {
    if (!isFlatImageExtension(ext)) return false;
    dvui.icon(@src(), "ImageFileIcon", dvui.entypo.image, .{ .stroke_color = color, .fill_color = color }, .{
        .gravity_y = 0.5,
        .padding = dvui.Rect.all(3),
        .background = false,
    });
    return true;
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

fn closeDocument(_: *anyopaque, handle: DocHandle) void {
    (docFrom(handle) orelse return).deinit();
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
