//! The pixel-art editor plugin: registration + draw entry points. Its contributions
//! reach the plugin's state through the `Globals` injection. Registered from
//! `Editor.postInit`.
const std = @import("std");
const builtin = @import("builtin");
const dvui = @import("dvui");
const internal = @import("../pixi.zig");
const sdk = internal.sdk;
const runtime = @import("runtime.zig");
const State = internal.State;
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
const DocLifecycle = @import("doc_lifecycle.zig");
const InfobarStatus = @import("infobar_status.zig");
const GridLayout = @import("dialogs/GridLayout.zig");
const FlatRasterSaveWarning = @import("dialogs/FlatRasterSaveWarning.zig");
const NewFile = @import("dialogs/NewFile.zig");

const DocHandle = sdk.DocHandle;
const Internal = internal.internal;

pub const manifest = sdk.PluginManifest{
    .id = "pixi",
    .name = "pixi",
    .version = .{ .major = 0, .minor = 1, .patch = 0 },
};

/// Stable contribution ids (plugin-namespaced) referenced across modules.
pub const view_tools = "internal.tools";
pub const view_sprites = "internal.sprites";
pub const view_project = "internal.project";
pub const bottom_sprites = "internal.sprites_panel";

var plugin: sdk.Plugin = .{
    .state = undefined,
    .vtable = &vtable,
    .id = "pixi",
    .display_name = "pixi",
};

const vtable: sdk.Plugin.VTable = .{
    .deinit = pluginDeinit,
    .initPlugin = pluginInit,
    .fileTypePriority = fileTypePriority,
    .contributeKeybinds = contributeKeybinds,
    .loadDocument = loadDocument,
    .loadDocumentFromBytes = loadDocumentFromBytes,
    .documentStackSize = documentStackSize,
    .documentStackAlign = documentStackAlign,
    .documentIdFromBuffer = documentIdFromBuffer,
    .deinitDocumentBuffer = deinitDocumentBuffer,
    .setDocumentGroupingOnBuffer = setDocumentGroupingOnBuffer,
    .createDocument = createDocument,
    .isDirty = isDirty,
    .saveDocument = saveDocument,
    .closeDocument = closeDocument,
    .undo = undo,
    .redo = redo,
    .canUndo = canUndo,
    .canRedo = canRedo,
    .registerOpenDocument = registerOpenDocument,
    .documentPtr = documentPtr,
    .documentByPath = documentByPath,
    .unregisterDocument = unregisterDocument,
    .bindDocumentToPane = bindDocumentToPane,
    .documentGrouping = documentGrouping,
    .setDocumentGrouping = setDocumentGrouping,
    .removeCanvasPane = removeCanvasPane,
    .documentPath = documentPath,
    .setDocumentPath = setDocumentPath,
    .documentHasNativeExtension = documentHasNativeExtension,
    .documentHasRecognizedSaveExtension = documentHasRecognizedSaveExtension,
    .showsSaveStatusIndicator = showsSaveStatusIndicator,
    .isDocumentSaving = isDocumentSaving,
    .saveDocumentAsync = saveDocumentAsync,
    .timeSinceSaveCompleteNs = timeSinceSaveCompleteNs,
    .documentDefaultSaveAsFilename = documentDefaultSaveAsFilename,
    .saveDocumentAs = saveDocumentAs,
    .resetDocumentSaveUIState = resetDocumentSaveUIState,
    .requestNewDocumentDialog = requestNewDocumentDialog,
    .drawDocument = drawDocument,
    .drawDocumentInfobar = drawDocumentInfobar,
    // universal per-frame phases (pixel-art does its raster/canvas work inside them)
    .beginFrame = beginFrame,
    .prepareFrame = warmupActiveDocumentComposites,
    .tickKeybinds = tickKeybinds,
    .tickOpenDocuments = tickOpenDocuments,
    .tickActiveDocument = tickActiveDocumentPlayback,
    .drawOverlay = drawOverlay,
    .endFrame = resetDocumentPeekLayers,
    .needsContinuousRepaint = isAnyDocumentActivelyDrawing,
    // folder lifecycle + save protocol
    .onFolderClose = pluginPersistProjectFolder,
    .onFolderOpen = pluginReloadProjectFolder,
    .saveNeedsConfirmation = shouldConfirmFlatRasterSave,
    .requestSaveConfirmation = requestSaveConfirmation,
};

/// A `DocHandle` for one of this plugin's open `*Internal.File`s. Resolved by `doc.id`
/// because `docs.files` may reallocate and stale `doc.ptr` values.
fn docFile(doc: DocHandle) *Internal.File {
    return runtime.state().docs.fileById(doc.id).?;
}

/// Priority for opening `ext` (lower wins). pixi owns its native `.fiz`/`.pixi`
/// and flat-image `.png`/`.jpg`/`.jpeg`; native formats win over flat images when
/// some future plugin also claims an image type.
fn fileTypePriority(_: *anyopaque, ext: []const u8) ?u8 {
    if (Internal.File.isFizzyExtension(ext)) return 0;
    if (Internal.File.isFlatImageExtension(ext)) return 10;
    return null;
}

/// Load `path` into the plugin-owned `*Internal.File` at `out_doc`. Runs on the shell's
/// load worker thread; `File.fromPath` is the pixel-art loader.
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
/// `canvas.id` / `workspace_handle` / `center` before routing here; pixi owns the
/// entire region: rulers, the canvas hbox, the transform/edit/sample overlays, the editing
/// widget, and the sample magnifier. The per-pane ruler/overlay/reorder state + draw helpers
/// live on the pixel-art-owned `CanvasData` (keyed by workbench pane `grouping` on `State`).
fn drawDocument(_: *anyopaque, doc: DocHandle) anyerror!void {
    const file = docFile(doc);
    const chrome = CanvasData.forGrouping(file.editor.grouping);
    const container = dvui.parentGet().data();

    // Grid (column/row) reorder is driven by the rulers and consumed by `FileWidget`; commit
    // the pending reorder and clear the per-frame drag indices after the whole document (incl.
    // the file widget) has drawn. Registered first so they run last.
    defer chrome.columns_drag_index = null;
    defer chrome.rows_drag_index = null;
    defer chrome.processColumnReorder(file);
    defer chrome.processRowReorder(file);

    internal.perf.canvasPaneDrawn();

    if (runtime.state().settings.show_rulers and !dvui.firstFrame(container.id)) {
        defer internal.core.dvui.drawEdgeShadow(container.rectScale(), .top, .{});
        chrome.drawRuler(file, .horizontal);
    }

    var canvas_hbox = dvui.box(@src(), .{ .dir = .horizontal }, .{ .expand = .both });
    defer canvas_hbox.deinit();

    if (runtime.state().settings.show_rulers and !dvui.firstFrame(container.id)) {
        defer internal.core.dvui.drawEdgeShadow(container.rectScale(), .left, .{});
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

    if (runtime.state().host.appliesNativeWindowOpacity()) {
        content_color = if (!runtime.state().host.isMaximized())
            content_color.opacity(runtime.state().host.contentOpacity())
        else
            content_color;
    }

    const show_packed_atlas = if (comptime builtin.target.cpu.arch == .wasm32)
        runtime.packer().atlas != null
    else
        runtime.state().host.folder() != null and runtime.packer().atlas != null;

    var canvas_vbox = sdk.pane_layout.mainCanvasVbox(content_color, show_packed_atlas, pane.grouping);
    defer {
        pane.canvas_rect_physical.* = canvas_vbox.data().contentRectScale().r;
        dvui.toastsShow(canvas_vbox.data().id, canvas_vbox.data().contentRectScale().r.toNatural());
        canvas_vbox.deinit();
    }

    if (show_packed_atlas) {
        const atlas = &runtime.packer().atlas.?;
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
        else if (runtime.state().host.folder() == null)
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

fn drawDocumentInfobar(state: *anyopaque, doc: DocHandle) anyerror!void {
    const st: *State = @ptrCast(@alignCast(state));
    return InfobarStatus.drawDocumentInfobar(st, doc);
}

fn undo(_: *anyopaque, doc: DocHandle) anyerror!void {
    const file = docFile(doc);
    try file.history.undoRedo(file, .undo);
}

fn redo(_: *anyopaque, doc: DocHandle) anyerror!void {
    const file = docFile(doc);
    try file.history.undoRedo(file, .redo);
}

fn canUndo(state: *anyopaque, doc: DocHandle) bool {
    const st: *State = @ptrCast(@alignCast(state));
    return DocBridge.canUndo(st, doc);
}

fn canRedo(state: *anyopaque, doc: DocHandle) bool {
    const st: *State = @ptrCast(@alignCast(state));
    return DocBridge.canRedo(st, doc);
}

pub fn register(host: *sdk.Host) !void {
    plugin.state = @ptrCast(@alignCast(runtime.state()));
    try host.registerPlugin(&plugin);
    try host.registerFileRowFillColor(.{ .color = &fileRowFillColor });
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
        .persistent = true,
    });
    try host.registerSettingsSection(.{
        .id = "internal.settings",
        .owner = &plugin,
        .title = "pixi",
        .draw = PixelArtSettings.draw,
    });

    // Pixel-art's invocable, plugin-specific features. The shell/menus/keybinds trigger these
    // by id via `host.runCommand` without naming them. (Generic active-doc editing verbs like
    // `transform`/`copy`/`paste` are *not* commands — they are `Plugin.VTable` hooks the shell
    // dispatches to the focused document's owner.)
    try host.registerCommand(.{
        .id = "internal.gridLayout",
        .owner = &plugin,
        .title = "Grid Layout…",
        .run = gridLayoutCommand,
    });
    try host.registerCommand(.{
        .id = "internal.packProject",
        .owner = &plugin,
        .title = "Pack Project",
        .run = packProjectCommand,
        .isEnabled = packProjectEnabled,
    });

    // Editing verbs the shell's Edit menu / keybinds dispatch to per active-doc owner
    // (`<owner_id>.<action>`). These are pixel-art's answers; another editor registers its own.
    try host.registerCommand(.{ .id = "internal.copy", .owner = &plugin, .title = "Copy", .run = pluginCopy });
    try host.registerCommand(.{ .id = "internal.paste", .owner = &plugin, .title = "Paste", .run = pluginPaste });
    try host.registerCommand(.{ .id = "internal.transform", .owner = &plugin, .title = "Transform", .run = pluginTransform });
    try host.registerCommand(.{ .id = "internal.acceptEdit", .owner = &plugin, .title = "Accept Edit", .run = pluginAcceptEdit });
    try host.registerCommand(.{ .id = "internal.cancelEdit", .owner = &plugin, .title = "Cancel Edit", .run = pluginCancelEdit });
    try host.registerCommand(.{ .id = "internal.deleteSelection", .owner = &plugin, .title = "Delete Selection", .run = pluginDeleteSelection });
}

/// Stable `*Plugin` for constructing `DocHandle.owner` fields.
pub fn pluginPtr() *sdk.Plugin {
    return &plugin;
}

fn fileRowFillColor(_: ?*anyopaque, color_index: usize) ?dvui.Color {
    if (runtime.state().colors.palette) |*palette| {
        return palette.getDVUIColor(color_index);
    }
    return null;
}

fn drawTools(_: ?*anyopaque) anyerror!void {
    try runtime.state().tools_pane.draw();
}
fn drawSprites(_: ?*anyopaque) anyerror!void {
    try runtime.state().sprites_pane.draw();
}
fn drawProject(_: ?*anyopaque) anyerror!void {
    try internal.explorer.project.draw();
}
fn drawSpritesPanel(_: ?*anyopaque) anyerror!void {
    try runtime.state().sprites_panel.draw();
}

fn tickKeybinds(_: *anyopaque) anyerror!void {
    try KeybindTicks.tick();
}

/// Pixel-art's per-frame overlay: the radial tool menu (processes its hold-to-open input,
/// then draws while visible). Wired to the universal `Plugin.drawOverlay` phase.
fn drawOverlay(_: *anyopaque) anyerror!void {
    RadialMenu.processHoldOpenInput();
    if (RadialMenu.visible()) try RadialMenu.draw();
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
    return DocsRegistry.documentFromId(st, id);
}

fn documentByPath(state: *anyopaque, path: []const u8) ?*anyopaque {
    const st: *State = @ptrCast(@alignCast(state));
    return DocsRegistry.documentFromPath(st, path);
}

fn unregisterDocument(state: *anyopaque, id: u64) void {
    const st: *State = @ptrCast(@alignCast(state));
    DocsRegistry.unregisterDocument(st, id);
}

fn bindDocumentToPane(state: *anyopaque, doc: DocHandle, canvas_id: dvui.Id, workspace_handle: *anyopaque, center: bool) void {
    const st: *State = @ptrCast(@alignCast(state));
    DocBridge.bindDocumentToWorkspace(st, doc, canvas_id, workspace_handle, center);
}

fn documentGrouping(state: *anyopaque, doc: DocHandle) u64 {
    const st: *State = @ptrCast(@alignCast(state));
    return DocBridge.documentGrouping(st, doc);
}

fn setDocumentGrouping(state: *anyopaque, doc: DocHandle, grouping: u64) void {
    const st: *State = @ptrCast(@alignCast(state));
    DocBridge.setDocumentGrouping(st, doc, grouping);
}

fn removeCanvasPane(state: *anyopaque, grouping: u64, allocator: std.mem.Allocator) void {
    const st: *State = @ptrCast(@alignCast(state));
    State.removeCanvasPane(st, allocator, grouping);
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

fn documentHasRecognizedSaveExtension(state: *anyopaque, doc: DocHandle) bool {
    const st: *State = @ptrCast(@alignCast(state));
    return DocBridge.documentHasRecognizedSaveExtension(st, doc);
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

fn pluginDeinit(state: *anyopaque) void {
    const st: *State = @ptrCast(@alignCast(state));
    DocLifecycle.deinitPlugin(st);
}

fn pluginInit(state: *anyopaque) anyerror!void {
    const st: *State = @ptrCast(@alignCast(state));
    return DocLifecycle.initPlugin(st);
}

fn documentStackSize(state: *anyopaque) usize {
    const st: *State = @ptrCast(@alignCast(state));
    return DocLifecycle.sizeOfDocument(st);
}

fn documentStackAlign(state: *anyopaque) usize {
    const st: *State = @ptrCast(@alignCast(state));
    return DocLifecycle.alignOfDocument(st);
}

fn documentIdFromBuffer(state: *anyopaque, doc: *anyopaque) u64 {
    const st: *State = @ptrCast(@alignCast(state));
    return DocLifecycle.documentIdFromBuffer(st, doc);
}

fn deinitDocumentBuffer(state: *anyopaque, doc: *anyopaque) void {
    const st: *State = @ptrCast(@alignCast(state));
    DocLifecycle.deinitDocumentBuffer(st, doc);
}

fn setDocumentGroupingOnBuffer(state: *anyopaque, doc: *anyopaque, grouping: u64) void {
    const st: *State = @ptrCast(@alignCast(state));
    DocLifecycle.setDocumentGroupingOnBuffer(st, doc, grouping);
}

fn createDocument(state: *anyopaque, path: []const u8, grid: sdk.EditorAPI.NewDocGrid, out_doc: *anyopaque) anyerror!void {
    const st: *State = @ptrCast(@alignCast(state));
    return DocLifecycle.createDocument(st, path, grid, out_doc);
}

fn documentDefaultSaveAsFilename(state: *anyopaque, doc: DocHandle, allocator: std.mem.Allocator) anyerror![]const u8 {
    const st: *State = @ptrCast(@alignCast(state));
    return DocLifecycle.documentDefaultSaveAsFilename(st, doc, allocator);
}

fn saveDocumentAs(state: *anyopaque, doc: DocHandle, path: []const u8, window: *dvui.Window) anyerror!void {
    const st: *State = @ptrCast(@alignCast(state));
    return DocLifecycle.saveDocumentAs(st, doc, path, window);
}

fn resetDocumentSaveUIState(state: *anyopaque, doc: DocHandle) void {
    const st: *State = @ptrCast(@alignCast(state));
    DocLifecycle.resetDocumentSaveUIState(st, doc);
}

fn requestNewDocumentDialog(_: *anyopaque, parent_path: ?[]const u8, id_extra: usize) void {
    NewFile.request(parent_path, id_extra);
}

/// Command body for `internal.gridLayout` — opens the grid-layout dialog for the active doc.
fn gridLayoutCommand(_: *anyopaque) anyerror!void {
    const doc = runtime.state().host.activeDoc() orelse return;
    GridLayout.request(doc.id);
}

fn requestSaveConfirmation(_: *anyopaque, doc: DocHandle, mode: sdk.Plugin.SaveConfirmMode, from_save_all_quit: bool) void {
    FlatRasterSaveWarning.request(doc.id, mode, from_save_all_quit);
}

fn beginFrame(state: *anyopaque) void {
    const st: *State = @ptrCast(@alignCast(state));
    // Advance the per-frame render clock used as a composite-cache invalidation key.
    internal.render.frame_index +%= 1;
    // Sweep any in-flight atlas-pack jobs. The shell no longer orchestrates packing — the
    // plugin drives its own background work from this universal per-frame phase.
    PackProject.tick(st);
    if (comptime @import("builtin").target.cpu.arch == .wasm32) PackProject.runWasmWorkers(st);
}

/// Command body for `internal.packProject`.
fn packProjectCommand(state: *anyopaque) anyerror!void {
    const st: *State = @ptrCast(@alignCast(state));
    try PackProject.start(st);
}

/// `internal.packProject` is enabled only when no pack is already in flight.
fn packProjectEnabled(state: *anyopaque) bool {
    const st: *State = @ptrCast(@alignCast(state));
    return !PackProject.isActive(st);
}

fn tickOpenDocuments(state: *anyopaque) bool {
    const st: *State = @ptrCast(@alignCast(state));
    return DocLifecycle.tickOpenDocuments(st);
}

fn tickActiveDocumentPlayback(state: *anyopaque, timer_host_id: dvui.Id) void {
    const st: *State = @ptrCast(@alignCast(state));
    DocLifecycle.tickActiveDocumentPlayback(st, timer_host_id);
}

fn resetDocumentPeekLayers(state: *anyopaque) void {
    const st: *State = @ptrCast(@alignCast(state));
    DocLifecycle.resetDocumentPeekLayers(st);
}

fn warmupActiveDocumentComposites(state: *anyopaque) void {
    const st: *State = @ptrCast(@alignCast(state));
    DocLifecycle.warmupActiveDocumentComposites(st);
}

fn isAnyDocumentActivelyDrawing(state: *anyopaque) bool {
    const st: *State = @ptrCast(@alignCast(state));
    return DocLifecycle.isAnyDocumentActivelyDrawing(st);
}

// Editing-verb command bodies (registered in `register`). `anyerror!void` to match `Command.run`.
fn pluginAcceptEdit(state: *anyopaque) anyerror!void {
    DocLifecycle.acceptEdit(@ptrCast(@alignCast(state)));
}

fn pluginCancelEdit(state: *anyopaque) anyerror!void {
    DocLifecycle.cancelEdit(@ptrCast(@alignCast(state)));
}

fn pluginDeleteSelection(state: *anyopaque) anyerror!void {
    DocLifecycle.deleteSelection(@ptrCast(@alignCast(state)));
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
