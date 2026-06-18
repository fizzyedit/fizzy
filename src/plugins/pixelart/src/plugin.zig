//! The pixel-art editor plugin. Phase 2 thin shim — the pixel-art stack still
//! lives inline under `src/editor/` (Phase 3 relocates it whole behind this
//! plugin). For now its contributions point at the existing draw entry points
//! through the `Globals` injection. Registered from `Editor.postInit`.
const std = @import("std");
const builtin = @import("builtin");
const dvui = @import("dvui");
const pixelart = @import("../pixelart.zig");
const sdk = pixelart.sdk;
const Globals = pixelart.Globals;
const State = pixelart.State;
const CanvasData = @import("CanvasData.zig");
const FileWidget = @import("widgets/FileWidget.zig");
const ImageWidget = @import("widgets/ImageWidget.zig");
const PixelArtSettings = @import("Settings.zig");
const KeybindTicks = @import("keybind_ticks.zig");
const RadialMenu = @import("radial_menu.zig");
const Clipboard = @import("clipboard.zig");
const PackProject = @import("pack_project.zig");
const TransformOp = @import("transform_op.zig");
const DocsRegistry = @import("docs_registry.zig");
const DocBridge = @import("doc_bridge.zig");

const DocHandle = sdk.DocHandle;
const Internal = pixelart.internal;

/// Stable contribution ids (plugin-namespaced) referenced across modules.
pub const view_tools = "pixelart.tools";
pub const view_sprites = "pixelart.sprites";
pub const view_project = "pixelart.project";
pub const bottom_sprites = "pixelart.sprites_panel";

var plugin: sdk.Plugin = .{
    .state = undefined,
    .vtable = &vtable,
    .id = "pixelart",
    .display_name = "Pixel Art",
};

const vtable: sdk.Plugin.VTable = .{
    .fileTypePriority = fileTypePriority,
    .contributeKeybinds = contributeKeybinds,
    .loadDocument = loadDocument,
    .loadDocumentFromBytes = loadDocumentFromBytes,
    .isDirty = isDirty,
    .saveDocument = saveDocument,
    .closeDocument = closeDocument,
    .undo = undo,
    .redo = redo,
    .registerOpenDocument = registerOpenDocument,
    .documentPtr = documentPtr,
    .documentByPath = documentByPath,
    .unregisterDocument = unregisterDocument,
    .bindDocumentToPane = bindDocumentToPane,
    .documentGrouping = documentGrouping,
    .setDocumentGrouping = setDocumentGrouping,
    .documentPath = documentPath,
    .setDocumentPath = setDocumentPath,
    .documentHasNativeExtension = documentHasNativeExtension,
    .showsSaveStatusIndicator = showsSaveStatusIndicator,
    .isDocumentSaving = isDocumentSaving,
    .shouldConfirmFlatRasterSave = shouldConfirmFlatRasterSave,
    .saveDocumentAsync = saveDocumentAsync,
    .timeSinceSaveCompleteNs = timeSinceSaveCompleteNs,
    .drawDocument = drawDocument,
    .tickKeybinds = tickKeybinds,
    .processRadialMenuInput = processRadialMenuInput,
    .radialMenuVisible = radialMenuVisible,
    .drawRadialMenu = drawRadialMenu,
    .transform = pluginTransform,
    .copy = pluginCopy,
    .paste = pluginPaste,
    .startPackProject = pluginStartPackProject,
    .isPackingActive = pluginIsPackingActive,
    .tickPackJobs = pluginTickPackJobs,
    .runPackWorkers = pluginRunPackWorkers,
    .persistProjectFolder = pluginPersistProjectFolder,
    .reloadProjectFolder = pluginReloadProjectFolder,
};

/// A `DocHandle` for one of this plugin's open `*Internal.File`s. Resolved by `doc.id`
/// because `docs.files` may reallocate and stale `doc.ptr` values.
fn docFile(doc: DocHandle) *Internal.File {
    return Globals.state.docs.fileById(doc.id).?;
}

/// Priority for opening `ext` (lower wins). Pixel art owns its native `.fiz`/`.pixi`
/// and flat-image `.png`/`.jpg`/`.jpeg`; native formats win over flat images when
/// some future plugin also claims an image type.
fn fileTypePriority(_: *anyopaque, ext: []const u8) ?u8 {
    if (Internal.File.isFizzyExtension(ext)) return 0;
    if (Internal.File.isFlatImageExtension(ext)) return 10;
    return null;
}

/// Load `path` into the shell-owned `*Internal.File` at `out_doc`. Runs on the shell's
/// load worker thread; `File.fromPath` is the pixel-art loader (still resident in the
/// editor tree, relocated whole into this plugin in Phase 3b/3c).
fn loadDocument(_: *anyopaque, path: []const u8, out_doc: *anyopaque) anyerror!void {
    // Web loads via bytes only (`loadDocumentFromBytes`); the comptime guard keeps the
    // disk-reading `File.fromPath` path (Dir.cwd / posix.AT) out of the wasm binary.
    if (comptime builtin.target.cpu.arch == .wasm32) return error.Unsupported;
    const file = try Internal.File.fromPath(path) orelse return error.InvalidFile;
    @as(*Internal.File, @ptrCast(@alignCast(out_doc))).* = file;
}

/// As `loadDocument`, from in-memory bytes (browser file picker; synchronous).
fn loadDocumentFromBytes(_: *anyopaque, path: []const u8, bytes: []const u8, out_doc: *anyopaque) anyerror!void {
    const file = try Internal.File.fromBytes(path, bytes) orelse return error.InvalidFile;
    @as(*Internal.File, @ptrCast(@alignCast(out_doc))).* = file;
}

fn isDirty(_: *anyopaque, doc: DocHandle) bool {
    return docFile(doc).dirty();
}

/// Persist the document. The shell handles the Save-As / flat-raster / web-download
/// policy before routing here; this just runs the pixel-art async save.
fn saveDocument(_: *anyopaque, doc: DocHandle) anyerror!void {
    try docFile(doc).saveAsync();
}

/// Release the document's resources. The shell removes it from `open_files` and
/// fixes up the active-tab index; this just frees the pixel-art `File`.
fn closeDocument(_: *anyopaque, doc: DocHandle) void {
    docFile(doc).deinit();
}

/// Render the open pixel-art document into the workbench-provided content region (the
/// current dvui parent). The workbench owns only the container + tab/split frame and sets
/// `canvas.id` / `workspace_handle` / `center` before routing here; pixel art owns the
/// entire region: rulers, the canvas hbox, the transform/edit/sample overlays, the editing
/// widget, and the sample magnifier. The per-pane ruler/overlay/reorder state + draw helpers
/// live on the pixel-art-owned `CanvasData` (keyed by workbench pane `grouping` on `State`).
fn drawDocument(_: *anyopaque, doc: DocHandle) anyerror!void {
    const file = docFile(doc);
    const chrome = CanvasData.forGrouping(file.editor.grouping);
    const container = dvui.parentGet().data();

    // Grid (column/row) reorder is driven by the rulers and consumed by `FileWidget`; commit
    // the pending reorder and clear the per-frame drag indices after the whole document (incl.
    // the file widget) has drawn. Registered first so they run last, matching the order the
    // workbench `Workspace.draw` used before this view was relocated here.
    defer chrome.columns_drag_index = null;
    defer chrome.rows_drag_index = null;
    defer chrome.processColumnReorder(file);
    defer chrome.processRowReorder(file);

    pixelart.perf.canvasPaneDrawn();

    if (Globals.state.settings.show_rulers and !dvui.firstFrame(container.id)) {
        defer pixelart.core.dvui.drawEdgeShadow(container.rectScale(), .top, .{});
        chrome.drawRuler(file, .horizontal);
    }

    var canvas_hbox = dvui.box(@src(), .{ .dir = .horizontal }, .{ .expand = .both });
    defer canvas_hbox.deinit();

    if (Globals.state.settings.show_rulers and !dvui.firstFrame(container.id)) {
        defer pixelart.core.dvui.drawEdgeShadow(container.rectScale(), .left, .{});
        chrome.drawRuler(file, .vertical);
    }

    chrome.drawTransformDialog(file, container);
    chrome.drawEditPill(container);
    // Before the file widget so FloatingWidget uses window-scale coords (not canvas zoom).
    chrome.drawSampleButton(container);

    const pane_grouping = container.options.id_extra orelse return;
    if (@as(u64, @intCast(pane_grouping)) != file.editor.grouping) return;

    var file_widget = FileWidget.init(@src(), .{
        .file = file,
        .center = file.editor.center,
    }, .{
        .expand = .both,
        .background = false,
        .color_fill = .transparent,
    });
    defer file_widget.deinit();
    file_widget.processEvents();

    if (dvui.dataGet(null, file.editor.canvas.id, "sample_data_point", dvui.Point)) |data_pt| {
        if (file.editor.canvas.samplePointerInViewport(dvui.currentWindow().mouse_pt)) {
            FileWidget.drawSampleMagnifier(file, data_pt);
        }
    }
}

/// Take over a workspace pane to show the pixel-art packed-atlas preview (the "Project"
/// sidebar view's `draw_workspace`). The workbench owns the pane frame and routes here when
/// `view_project` is the active sidebar view.
fn drawProjectView(_: ?*anyopaque, pane: *sdk.WorkbenchPaneView) anyerror!void {
    var content_color = dvui.themeGet().color(.window, .fill);

    if (Globals.state.host.appliesNativeWindowOpacity()) {
        content_color = if (!Globals.state.host.isMaximized())
            content_color.opacity(Globals.state.host.contentOpacity())
        else
            content_color;
    }

    const show_packed_atlas = if (comptime builtin.target.cpu.arch == .wasm32)
        Globals.packer.atlas != null
    else
        Globals.state.host.folder() != null and Globals.packer.atlas != null;

    var canvas_vbox = sdk.pane_layout.mainCanvasVbox(content_color, show_packed_atlas, pane.grouping);
    defer {
        pane.canvas_rect_physical.* = canvas_vbox.data().contentRectScale().r;
        dvui.toastsShow(canvas_vbox.data().id, canvas_vbox.data().contentRectScale().r.toNatural());
        canvas_vbox.deinit();
    }

    if (show_packed_atlas) {
        const atlas = &Globals.packer.atlas.?;
        var image_widget = ImageWidget.init(@src(), .{
            .source = atlas.source,
            .canvas = &atlas.canvas,
            .grouping = pane.grouping,
        }, .{
            .id_extra = @intCast(pane.grouping),
            .expand = .both,
            .background = false,
            .color_fill = .transparent,
        });
        defer image_widget.deinit();

        image_widget.processEvents();

        if (dvui.dataGet(null, atlas.canvas.id, "sample_data_point", dvui.Point)) |data_pt| {
            if (atlas.canvas.samplePointerInViewport(dvui.currentWindow().mouse_pt)) {
                ImageWidget.drawSampleMagnifier(&atlas.canvas, atlas.source, data_pt);
            }
        }
    } else {
        var box = sdk.pane_layout.emptyStateCard(content_color, pane.grouping);
        defer box.deinit();

        const alpha = dvui.alpha(1.0);
        dvui.alphaSet(1.0);
        defer dvui.alphaSet(alpha);

        const hint: []const u8 = if (comptime builtin.target.cpu.arch == .wasm32)
            "Pack open files to see the preview."
        else if (Globals.state.host.folder() == null)
            "Open a project folder, then pack to see the preview."
        else
            "Pack the project to see the preview.";

        dvui.labelNoFmt(
            @src(),
            hint,
            .{ .align_x = 0.5 },
            .{
                .gravity_x = 0.5,
                .gravity_y = 0.5,
                .color_text = dvui.themeGet().color(.control, .text),
                .font = dvui.Font.theme(.body),
            },
        );
    }
}

fn undo(_: *anyopaque, doc: DocHandle) anyerror!void {
    const file = docFile(doc);
    try file.history.undoRedo(file, .undo);
}

fn redo(_: *anyopaque, doc: DocHandle) anyerror!void {
    const file = docFile(doc);
    try file.history.undoRedo(file, .redo);
}

pub fn register(host: *sdk.Host) !void {
    // Adopt the app-owned pixel-art state as this plugin's `state`. Wire Globals
    // here too so plugin code and the shell share one injection site (App also sets
    // these before State.init, but register re-syncs after postInit ordering).
    plugin.state = @ptrCast(@alignCast(Globals.state));
    try host.registerPlugin(&plugin);
    try host.registerSidebarView(.{
        .id = view_tools,
        .owner = &plugin,
        .icon = dvui.entypo.pencil,
        .title = "Tools",
        .draw = drawTools,
    });
    try host.registerSidebarView(.{
        .id = view_sprites,
        .owner = &plugin,
        .icon = dvui.entypo.grid,
        .title = "Sprites",
        .draw = drawSprites,
    });
    try host.registerSidebarView(.{
        .id = view_project,
        .owner = &plugin,
        .icon = dvui.entypo.box,
        .title = "Project",
        .draw = drawProject,
        .draw_workspace = drawProjectView,
    });
    try host.registerBottomView(.{
        .id = bottom_sprites,
        .owner = &plugin,
        .title = "Sprites",
        .draw = drawSpritesPanel,
    });
    try host.registerSettingsSection(.{
        .id = "pixelart.settings",
        .owner = &plugin,
        .title = "Pixel Art",
        .draw = PixelArtSettings.draw,
    });
}

/// Stable `*Plugin` for constructing `DocHandle.owner` fields.
pub fn pluginPtr() *sdk.Plugin {
    return &plugin;
}

fn drawTools(_: ?*anyopaque) anyerror!void {
    try Globals.state.tools_pane.draw();
}
fn drawSprites(_: ?*anyopaque) anyerror!void {
    try Globals.state.sprites_pane.draw();
}
fn drawProject(_: ?*anyopaque) anyerror!void {
    try pixelart.explorer.project.draw();
}
fn drawSpritesPanel(_: ?*anyopaque) anyerror!void {
    try Globals.state.sprites_panel.draw();
}

fn tickKeybinds(_: *anyopaque) anyerror!void {
    try KeybindTicks.tick();
}

fn processRadialMenuInput(_: *anyopaque) void {
    RadialMenu.processHoldOpenInput();
}

fn radialMenuVisible(_: *anyopaque) bool {
    return RadialMenu.visible();
}

fn drawRadialMenu(_: *anyopaque) anyerror!void {
    try RadialMenu.draw();
}

fn pluginCopy(state: *anyopaque) anyerror!void {
    const st: *State = @ptrCast(@alignCast(state));
    try Clipboard.copy(st);
}

fn pluginTransform(state: *anyopaque) anyerror!void {
    const st: *State = @ptrCast(@alignCast(state));
    try TransformOp.begin(st);
}

fn registerOpenDocument(state: *anyopaque, file: *anyopaque) anyerror!*anyopaque {
    const st: *State = @ptrCast(@alignCast(state));
    const internal_file: *Internal.File = @ptrCast(@alignCast(file));
    const ptr = try DocsRegistry.registerOpenDocument(st, internal_file);
    return ptr;
}

fn documentPtr(state: *anyopaque, id: u64) ?*anyopaque {
    const st: *State = @ptrCast(@alignCast(state));
    return DocsRegistry.documentPtr(st, id);
}

fn documentByPath(state: *anyopaque, path: []const u8) ?*anyopaque {
    const st: *State = @ptrCast(@alignCast(state));
    return DocsRegistry.documentByPath(st, path);
}

fn unregisterDocument(state: *anyopaque, id: u64) void {
    const st: *State = @ptrCast(@alignCast(state));
    DocsRegistry.unregisterDocument(st, id);
}

fn bindDocumentToPane(state: *anyopaque, doc: DocHandle, canvas_id: dvui.Id, workspace_handle: *anyopaque, center: bool) void {
    const st: *State = @ptrCast(@alignCast(state));
    DocBridge.bindDocumentToPane(st, doc, canvas_id, workspace_handle, center);
}

fn documentGrouping(state: *anyopaque, doc: DocHandle) u64 {
    const st: *State = @ptrCast(@alignCast(state));
    return DocBridge.documentGrouping(st, doc);
}

fn setDocumentGrouping(state: *anyopaque, doc: DocHandle, grouping: u64) void {
    const st: *State = @ptrCast(@alignCast(state));
    DocBridge.setDocumentGrouping(st, doc, grouping);
}

fn documentPath(state: *anyopaque, doc: DocHandle) []const u8 {
    const st: *State = @ptrCast(@alignCast(state));
    return DocBridge.documentPath(st, doc);
}

fn setDocumentPath(state: *anyopaque, doc: DocHandle, path: []const u8) anyerror!void {
    const st: *State = @ptrCast(@alignCast(state));
    return DocBridge.setDocumentPath(st, doc, path);
}

fn documentHasNativeExtension(state: *anyopaque, doc: DocHandle) bool {
    const st: *State = @ptrCast(@alignCast(state));
    return DocBridge.documentHasNativeExtension(st, doc);
}

fn showsSaveStatusIndicator(state: *anyopaque, doc: DocHandle) bool {
    const st: *State = @ptrCast(@alignCast(state));
    return DocBridge.showsSaveStatusIndicator(st, doc);
}

fn isDocumentSaving(state: *anyopaque, doc: DocHandle) bool {
    const st: *State = @ptrCast(@alignCast(state));
    return DocBridge.isDocumentSaving(st, doc);
}

fn shouldConfirmFlatRasterSave(state: *anyopaque, doc: DocHandle) bool {
    const st: *State = @ptrCast(@alignCast(state));
    return DocBridge.shouldConfirmFlatRasterSave(st, doc);
}

fn saveDocumentAsync(state: *anyopaque, doc: DocHandle) anyerror!void {
    const st: *State = @ptrCast(@alignCast(state));
    return DocBridge.saveDocumentAsync(st, doc);
}

fn timeSinceSaveCompleteNs(state: *anyopaque, doc: DocHandle) ?i128 {
    const st: *State = @ptrCast(@alignCast(state));
    return DocBridge.timeSinceSaveCompleteNs(st, doc);
}

fn pluginPersistProjectFolder(state: *anyopaque) void {
    const st: *State = @ptrCast(@alignCast(state));
    DocsRegistry.persistProjectFolder(st);
}

fn pluginReloadProjectFolder(state: *anyopaque, allocator: std.mem.Allocator) void {
    const st: *State = @ptrCast(@alignCast(state));
    DocsRegistry.reloadProjectFolder(st, allocator);
}

fn pluginPaste(state: *anyopaque) anyerror!void {
    const st: *State = @ptrCast(@alignCast(state));
    try Clipboard.paste(st);
}

fn pluginStartPackProject(state: *anyopaque) anyerror!void {
    const st: *State = @ptrCast(@alignCast(state));
    try PackProject.start(st);
}

fn pluginIsPackingActive(state: *const anyopaque) bool {
    const st: *const State = @ptrCast(@alignCast(state));
    return PackProject.isActive(st);
}

fn pluginTickPackJobs(state: *anyopaque) void {
    const st: *State = @ptrCast(@alignCast(state));
    PackProject.tick(st);
}

fn pluginRunPackWorkers(state: *anyopaque) void {
    const st: *State = @ptrCast(@alignCast(state));
    PackProject.runWasmWorkers(st);
}

/// Pixel-art editing + tool keybinds.
/// binds in `Keybinds.register`; this fills in the pixel-art half. Platform: see
/// `Keybinds.register` for why `host.isMacOS()` (not `builtin`) is used.
fn contributeKeybinds(state: *anyopaque, win: *dvui.Window) anyerror!void {
    const st: *State = @ptrCast(@alignCast(state));
    if (st.host.isMacOS()) {
        try win.keybinds.putNoClobber(win.gpa, "new_file", .{ .key = .n, .command = true });
        try win.keybinds.putNoClobber(win.gpa, "undo", .{ .key = .z, .command = true, .shift = false });
        try win.keybinds.putNoClobber(win.gpa, "redo", .{ .key = .z, .command = true, .shift = true });
        try win.keybinds.putNoClobber(win.gpa, "zoom", .{ .command = true });
        try win.keybinds.putNoClobber(win.gpa, "sample", .{ .control = true });
        try win.keybinds.putNoClobber(win.gpa, "transform", .{ .command = true, .key = .t });
        try win.keybinds.putNoClobber(win.gpa, "grid_layout", .{ .command = true, .key = .g });
        try win.keybinds.putNoClobber(win.gpa, "export", .{ .command = true, .key = .p });
        try win.keybinds.putNoClobber(win.gpa, "delete_selection_contents", .{ .key = .backspace });
    } else {
        try win.keybinds.putNoClobber(win.gpa, "new_file", .{ .key = .n, .control = true });
        try win.keybinds.putNoClobber(win.gpa, "undo", .{ .key = .z, .control = true, .shift = false });
        try win.keybinds.putNoClobber(win.gpa, "redo", .{ .key = .z, .control = true, .shift = true });
        try win.keybinds.putNoClobber(win.gpa, "zoom", .{ .control = true });
        try win.keybinds.putNoClobber(win.gpa, "sample", .{ .alt = true });
        try win.keybinds.putNoClobber(win.gpa, "transform", .{ .control = true, .key = .t });
        try win.keybinds.putNoClobber(win.gpa, "grid_layout", .{ .control = true, .key = .g });
        try win.keybinds.putNoClobber(win.gpa, "export", .{ .control = true, .key = .p });
        try win.keybinds.putNoClobber(win.gpa, "delete_selection_contents", .{ .key = .delete });
    }

    try win.keybinds.putNoClobber(win.gpa, "increase_stroke_size", .{ .key = .right_bracket });
    try win.keybinds.putNoClobber(win.gpa, "decrease_stroke_size", .{ .key = .left_bracket });
    try win.keybinds.putNoClobber(win.gpa, "quick_tools", .{ .key = .space });

    try win.keybinds.putNoClobber(win.gpa, "pencil", .{ .key = .d, .command = false, .control = false, .alt = false, .shift = false });
    try win.keybinds.putNoClobber(win.gpa, "eraser", .{ .key = .e, .command = false, .control = false, .alt = false, .shift = false });
    try win.keybinds.putNoClobber(win.gpa, "bucket", .{ .key = .b, .command = false, .control = false, .alt = false, .shift = false });
    try win.keybinds.putNoClobber(win.gpa, "selection", .{ .key = .s, .command = false, .control = false, .alt = false, .shift = false });
    try win.keybinds.putNoClobber(win.gpa, "pointer", .{ .key = .escape });
}
