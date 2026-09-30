//! A plugin's store page, as a document.
//!
//! A page is a document. Opening one is `openFile` on a path under this module's
//! mount, so everything a document already has comes for free: a tab, a split, focus, close,
//! restore, and as many open at once as the user opens. Nothing in the app knows a store page is
//! special; the tab strip is the workbench's, the markdown under the header is the bundled
//! renderer's, and this file is a document owner like any editor plugin.
//!
//! The mount is what makes that possible without a new host API: `DocumentIo` opens any path a
//! mount claims by reading its bytes, on the desktop and in the browser alike. So the page's
//! "file" is one line — the plugin's id — and everything else is looked up from the catalog at
//! draw time, where it is anyway (a plugin installs, updates, or goes away while its page is
//! open, and the page should say so without being reloaded).
const std = @import("std");
const dvui = @import("dvui");
const sdk = @import("fizzy_sdk");
const core = @import("core");
const readme = @import("readme.zig");

const DocHandle = sdk.DocHandle;

/// The one place the page's file extension is spelled. Deliberately unlikely to collide with
/// anything a user has on disk: this is fizzy's own, and a `.md` here would fight the markdown
/// plugin for ownership of every README in the world.
pub const extension = ".fizzyplugin";

/// The mount every page lives under. A page's path is `store://pages/<display name><extension>`,
/// so the tab shows the plugin's name — a tab strip is a row of file names, and "Google Drive"
/// is what that plugin is called.
///
/// Scheme *and* authority, with no trailing slash, because that is what a mount prefix is here:
/// `FileTable.pathOnMount` asks that the rest of the path start with `/`, so a bare `store://`
/// matched nothing and every page fell through to the disk — "Failed to open file" for a file
/// that was right there in memory. `gdrive://<account>` has the same shape for the same reason.
pub const mount_prefix = "store://pages";

pub const plugin_id = "fizzy.store";

/// What the store gives this module so a page can draw itself without importing `PluginStore`
/// (which imports this file). One vtable, filled in at registration — the same `{ctx, vtable}`
/// seam the app uses everywhere it needs to name fizzy from underneath.
pub const PageDraw = struct {
    /// Draw the header for `plugin_id`: title, version, publisher, and the page's controls.
    /// Returns false when the store has never heard of this id, which is a page worth saying
    /// "gone" on rather than drawing blank.
    header: *const fn (plugin_id: []const u8) bool,
    /// Where this plugin's README lives: the repo URL and the path within it. Null when the
    /// store cannot say, which shows the "no README" state rather than fetching nothing.
    source: *const fn (plugin_id: []const u8) ?Source,
    /// What this plugin is called, for the tab. Null when the store has never heard of it, and
    /// then the tab falls back to the file name — which is the id, and still says something.
    title: *const fn (plugin_id: []const u8) ?[]const u8,
    /// Draw the page's tab strip with `tab` selected; returns the tab after any click. Drawn by
    /// the store because it is the store's styling, chosen per page because the tab is a
    /// property of the page you are looking at, not of the app.
    tabs: *const fn (tab: u8) u8,
    /// Draw the body of a tab that is not the README.
    otherTab: *const fn (tab: u8) void,
};

/// The README tab, by the index the store's tab strip gives it.
pub const readme_tab: u8 = 0;

pub const Source = struct {
    repo: []const u8,
    subpath: []const u8,
};

var page_draw: ?PageDraw = null;

/// One open page.
pub const Document = struct {
    id: u64,
    path: []u8,
    grouping: u64 = 0,
    /// The plugin this page is about, read from the mounted file's single line.
    plugin: []u8,
    /// Created on the first draw rather than at load: the catalog answers where a README lives,
    /// and a page can be restored from a saved layout before the catalog has been fetched.
    readme: ?readme.Readme = null,
    readme_started: bool = false,
    /// Which of the page's tabs is showing.
    tab: u8 = readme_tab,

    pub fn fromBytes(path: []const u8, bytes: []const u8) !Document {
        const gpa = sdk.allocator();
        const trimmed = std.mem.trim(u8, bytes, " \r\n\t");
        if (trimmed.len == 0) return error.InvalidFile;
        const plugin_copy = try gpa.dupe(u8, trimmed);
        errdefer gpa.free(plugin_copy);
        const path_copy = try gpa.dupe(u8, path);
        return .{
            .id = std.hash.Wyhash.hash(0, path),
            .path = path_copy,
            .plugin = plugin_copy,
        };
    }

    pub fn deinit(self: *Document) void {
        const gpa = sdk.allocator();
        if (self.readme) |*r| r.deinit();
        gpa.free(self.path);
        gpa.free(self.plugin);
        self.* = undefined;
    }
};

const State = struct {
    docs: std.AutoArrayHashMapUnmanaged(u64, Document) = .empty,
    mounted: bool = false,
    /// What the pages' filesystem has answered and not yet delivered — see `pages_fs`.
    answers: ?core.vfs.Deferred = null,
};

var state: State = .{};

pub var plugin: sdk.Plugin = .{
    .state = @ptrCast(&state),
    .vtable = &vtable,
    .id = plugin_id,
    .display_name = "Plugin Store",
    // Fizzy's own: a document owner so pages can be tabs, not something in the store's lists.
    .internal = true,
};

const vtable: sdk.Plugin.VTable = .{
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
    .documentTitle = documentTitle,
    .drawDocument = drawDocument,
    .closeDocument = closeDocument,
    .isDirty = isDirty,
    .saveDocument = saveDocument,
};

comptime {
    sdk.Plugin.assertEditorVTable(vtable);
}

/// Register the page owner and mount the filesystem its pages live on. Called by the store,
/// which is the only thing that opens one.
pub fn register(host: *sdk.Host, draw: PageDraw) !void {
    page_draw = draw;
    try host.registerPlugin(&plugin);
    state.answers = .init(host.allocator);
    try host.mount(mount_prefix, pages_fs);
    state.mounted = true;
}

pub fn deinit() void {
    for (state.docs.values()) |*doc| doc.deinit();
    state.docs.deinit(sdk.allocator());
    if (state.answers) |*a| a.deinit();
    state.answers = null;
    state.mounted = false;
}

/// Open (or focus) the store page for `plugin_id`, titled `title`. The path is the title, so a
/// page's tab reads as the plugin's name.
pub fn open(host: *sdk.Host, id: []const u8, grouping: u64) !void {
    if (!state.mounted) return;
    const gpa = host.allocator;

    // Already open: focus it rather than opening a second tab for the same plugin.
    for (state.docs.values()) |*doc| {
        if (std.mem.eql(u8, doc.plugin, id)) return focus(host, doc.*);
    }

    const path = try pathFor(gpa, id);
    defer gpa.free(path);
    // `.preview`: the page takes the tab of whatever preview is in that pane, so clicking down
    // a list of plugins reads them one after another in place.
    _ = try host.openFile(.{ .path = path, .grouping = grouping, .mode = .preview });
}

/// A page's address: the plugin's id, not its name. The path is what a saved layout stores and
/// reopens from, so it has to be the stable thing — and the tab still reads "Google Drive",
/// because `documentTitle` answers that separately.
fn pathFor(gpa: std.mem.Allocator, id: []const u8) ![]u8 {
    return std.fmt.allocPrint(gpa, "{s}/{s}{s}", .{ mount_prefix, id, extension });
}

/// The plugin id a page path is about: its basename without the extension.
fn pluginOfPath(path: []const u8) ?[]const u8 {
    const base = std.fs.path.basename(path);
    if (!std.mem.endsWith(u8, base, extension)) return null;
    const id = base[0 .. base.len - extension.len];
    return if (id.len == 0) null else id;
}

/// Bring an already-open page to the front.
fn focus(host: *sdk.Host, doc: Document) !void {
    _ = try host.openFile(.{ .path = doc.path, .grouping = doc.grouping });
}

// ---- the pages' filesystem -------------------------------------------------------------------
//
// There is nothing behind it. A page's whole content is the plugin id in its own path, so this
// answers a read by parsing the path it was asked about — which is what makes a page restorable
// from a saved layout with no state at all. A `Mem` filled in as pages opened could not: on the
// next run the layout asks for `store://pages/pixi.fizzyplugin` before anything has opened one,
// the file is not there, and the tab is dropped with "NotFound".

const pages_fs: core.vfs.Fs = .{ .ptr = undefined, .vtable = &fs_vtable };

const fs_vtable: core.vfs.Fs.VTable = .of(.{
    .listDir = fsListDir,
    .stat = fsStat,
    .readFile = fsReadFile,
    .writeFile = fsWrite,
    .createFile = fsCreateOrRemove,
    .mkdir = fsCreateOrRemove,
    .rename = fsRename,
    .remove = fsCreateOrRemove,
    .cancel = fsCancel,
    .pump = fsPump,
});

/// Every answer is known on the spot, and still arrives from `pump`, as `Fs` promises: the
/// open that asked has to have its bookkeeping in place — the loading tab the page lands in —
/// before the page exists.
fn answers() *core.vfs.Deferred {
    return &state.answers.?;
}

fn fsListDir(_: *anyopaque, allocator: std.mem.Allocator, _: []const u8, cb: core.vfs.ListDirFn, ctx: ?*anyopaque) core.vfs.Error!core.vfs.Job {
    // Not browsable: a page exists because someone asked for it by id, and a listing of every
    // plugin that *could* have one is the store's job, in the store.
    return answers().list(allocator, cb, ctx, &.{});
}

fn fsStat(_: *anyopaque, path: []const u8, cb: core.vfs.StatFn, ctx: ?*anyopaque) core.vfs.Error!core.vfs.Job {
    const id = pluginOfPath(path) orelse return answers().stat(cb, ctx, error.NotFound);
    return answers().stat(cb, ctx, .{ .kind = .file, .size = id.len, .modified_ms = 0 });
}

fn fsReadFile(_: *anyopaque, allocator: std.mem.Allocator, path: []const u8, cb: core.vfs.ReadFn, ctx: ?*anyopaque) core.vfs.Error!core.vfs.Job {
    const id = pluginOfPath(path) orelse return answers().read(allocator, cb, ctx, error.NotFound);
    const bytes = allocator.dupe(u8, id) catch return answers().read(allocator, cb, ctx, error.OutOfMemory);
    return answers().read(allocator, cb, ctx, .{ .bytes = bytes, .modified_ms = 0 });
}

/// Read-only: a page is a view of the store. Every mutation answers `Unsupported` rather than
/// pretending, so a "save" here fails loudly instead of quietly doing nothing.
fn fsWrite(_: *anyopaque, _: []const u8, _: []const u8, _: core.vfs.WriteOptions, cb: core.vfs.DoneFn, ctx: ?*anyopaque) core.vfs.Error!core.vfs.Job {
    return answers().done(cb, ctx, error.Unsupported);
}

fn fsCreateOrRemove(_: *anyopaque, _: []const u8, cb: core.vfs.DoneFn, ctx: ?*anyopaque) core.vfs.Error!core.vfs.Job {
    return answers().done(cb, ctx, error.Unsupported);
}

fn fsRename(_: *anyopaque, _: []const u8, _: []const u8, cb: core.vfs.DoneFn, ctx: ?*anyopaque) core.vfs.Error!core.vfs.Job {
    return answers().done(cb, ctx, error.Unsupported);
}

fn fsCancel(_: *anyopaque, job: core.vfs.Job) void {
    answers().cancel(job);
}

fn fsPump(_: *anyopaque) void {
    answers().pump();
}

// ---- the document vtable ---------------------------------------------------------------------

fn fileTypes(_: *anyopaque) []const []const u8 {
    return &.{extension};
}

fn documentStackSize(_: *anyopaque) usize {
    return @sizeOf(Document);
}
fn documentStackAlign(_: *anyopaque) usize {
    return @alignOf(Document);
}
fn loadDocument(_: *anyopaque, path: []const u8, out_doc: *anyopaque) anyerror!void {
    // Never reached in practice — every page lives on the mount, so `DocumentIo` reads the bytes
    // and calls `loadDocumentFromBytes`. Kept because the vtable requires it and because a page
    // path could be restored from a layout after the mount is gone.
    _ = path;
    _ = out_doc;
    return error.Unsupported;
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

fn registerOpenDocument(_: *anyopaque, file: *anyopaque) anyerror!*anyopaque {
    const doc = docBuf(file);
    try state.docs.put(sdk.allocator(), doc.id, doc.*);
    return state.docs.getPtr(doc.id).?;
}
fn documentPtr(_: *anyopaque, id: u64) ?*anyopaque {
    return state.docs.getPtr(id);
}
fn documentByPath(_: *anyopaque, path: []const u8) ?*anyopaque {
    for (state.docs.values()) |*doc| {
        if (std.mem.eql(u8, doc.path, path)) return doc;
    }
    return null;
}
fn unregisterDocument(_: *anyopaque, id: u64) void {
    _ = state.docs.swapRemove(id);
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

/// Never: a page is a view of the store, not an edit of anything.
fn isDirty(_: *anyopaque, _: DocHandle) bool {
    return false;
}
fn saveDocument(_: *anyopaque, _: DocHandle) anyerror!void {}

fn closeDocument(_: *anyopaque, handle: DocHandle) void {
    const doc = docFrom(handle) orelse return;
    doc.deinit();
    _ = state.docs.swapRemove(handle.id);
}

/// "Google Drive", not "drive.fizzyplugin". The path is the id because a saved layout reopens
/// from it; what the tab says is a different question, and this is where it is answered.
fn documentTitle(_: *anyopaque, handle: DocHandle) ?[]const u8 {
    const doc = docFrom(handle) orelse return null;
    const draw = page_draw orelse return null;
    return draw.title(doc.plugin);
}

fn drawDocument(_: *anyopaque, handle: DocHandle) anyerror!void {
    const doc = docFrom(handle) orelse return;

    var page = dvui.box(@src(), .{ .dir = .vertical }, .{ .expand = .both, .background = false });
    defer page.deinit();

    const draw = page_draw orelse return;
    // The header answers "is this plugin still a thing the store knows about" — a page can
    // outlive the plugin it is about (uninstalled, or a registry that no longer lists it).
    if (!draw.header(doc.plugin)) {
        dvui.labelNoFmt(@src(), "The store no longer has this plugin.", .{}, .{
            .expand = .both,
            .gravity_x = 0.5,
            .gravity_y = 0.5,
            .color_text = .{ .color = dvui.themeGet().color(.window, .text).opacity(0.7) },
        });
        return;
    }

    doc.tab = draw.tabs(doc.tab);
    if (doc.tab != readme_tab) {
        draw.otherTab(doc.tab);
        return;
    }

    if (doc.readme == null and !doc.readme_started) {
        if (draw.source(doc.plugin)) |src| {
            doc.readme = readme.Readme.init(doc.plugin, src.repo, src.subpath);
            if (doc.readme) |*r| r.start();
            doc.readme_started = true;
        }
    }
    var body = dvui.box(@src(), .{ .dir = .vertical }, .{ .expand = .both, .padding = .all(16) });
    defer body.deinit();
    if (doc.readme) |*r| r.draw() else placeholderText("No README for this plugin.");
}

fn placeholderText(text: []const u8) void {
    dvui.labelNoFmt(@src(), text, .{}, .{
        .expand = .both,
        .gravity_x = 0.5,
        .gravity_y = 0.5,
        .color_text = .{ .color = dvui.themeGet().color(.window, .text).opacity(0.7) },
    });
}

fn docBuf(ptr: *anyopaque) *Document {
    return @ptrCast(@alignCast(ptr));
}

/// The handle carries the pointer this module returned from `registerOpenDocument`, so trust it
/// — but only after checking the id is one of ours, since a handle for another owner's document
/// would otherwise be reinterpreted as a page.
fn docFrom(handle: DocHandle) ?*Document {
    return state.docs.getPtr(handle.id);
}
