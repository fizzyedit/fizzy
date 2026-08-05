const std = @import("std");
const sdk = @import("fizzy_sdk");
const dvui = @import("dvui");
const State = @import("src/State.zig").State;
const md = @import("src/markdown.zig");

/// Re-exported for fizzy's own use of the preview renderer outside this plugin's own
/// vtable/service surface (e.g. `src/editor/readme.zig` rendering a fetched plugin README) —
/// see `docs/PLUGIN_MANIFEST_PLAN.md`'s "static module root" decision.
pub const Preview = md.Preview;
pub const drawPreview = md.drawPreview;
pub const drawPreviewForDocument = md.drawPreviewForDocument;
/// Tears down preview state shared by every `Preview` (the remote-image cache and its worker
/// threads). Fizzy's own copy of this module has no plugin lifecycle to hang it on, so
/// `src/editor/readme.zig` calls it directly; this plugin's `deinit` does the same for the
/// dylib copy's separate globals.
pub const deinitShared = md.deinitShared;
/// Exposed for `zig build bench-markdown` only (`tests/bench/bench_markdown.zig`), which reads
/// `render_ast.stats` after a frame. Nothing in the app reaches through here.
pub const render_ast = @import("src/md/render_ast.zig");

/// Injected at build time from `plugin.zig.zon` (see `static/integration.zig` /
/// `src/plugins/shared/build/helpers.zig`'s `pluginOptions`) — one source of truth for
/// identity, not duplicated as string literals here.
pub const plugin_options = @import("fizzy_plugin_options");

/// This plugin's stable id — the single source of truth other modules (e.g. fizzy's
/// `Editor.isBundledPluginId`) read instead of retyping the string. Distinct from
/// `language_support.id` below, which happens to share the string but names the *language*
/// this plugin's `LanguageSupport` provider handles, not the plugin itself.
pub const plugin_id = plugin_options.id;

var plugin: sdk.Plugin = .{
    .state = undefined,
    .vtable = &vtable,
    .id = plugin_id,
    .display_name = plugin_options.name,
};

const vtable: sdk.Plugin.VTable = .{
    .deinit = deinit,
};

var plugin_state: State = .{};

const language_support: sdk.LanguageSupport = .{
    .id = "markdown",
    .owner = &plugin,
    .vtable = &language_vtable,
};

const language_vtable: sdk.LanguageSupport.VTable = .{
    .supportsPreview = supportsPreview,
    .previewPane = previewPane,
    .previewReveal = previewReveal,
};

var markdown_api: sdk.services.markdown.Api = .{
    .ctx = @ptrCast(&plugin_state),
    .vtable = &markdown_service_vtable,
};

const markdown_service_vtable: sdk.services.markdown.Api.VTable = .{
    .render = svcRender,
    .defaultView = svcDefaultView,
    .setDefaultView = svcSetDefaultView,
};

pub fn register(host: *sdk.Host) !void {
    render_ast.initDiagFromEnv();
    plugin.state = @ptrCast(&plugin_state);
    plugin_state.loadSettings(host);
    try host.registerPlugin(&plugin);
    try plugin_state.registerSettings(host, &plugin);
    try host.registerLanguageSupport(language_support);
    try host.registerService("markdown", &markdown_api, &plugin);
}

fn deinit(state: *anyopaque) void {
    const st: *State = @ptrCast(@alignCast(state));
    st.destroy(sdk.allocator());
    // Joins the remote-image fetch threads — they must not outlive this dylib.
    md.deinitShared();
}

fn supportsPreview(_: *anyopaque, ext: []const u8) bool {
    return std.ascii.eqlIgnoreCase(ext, ".md") or std.ascii.eqlIgnoreCase(ext, ".markdown");
}

/// Remember the reveal against this pane's own preview state. The pane may never have been
/// drawn for `id_extra` — `previewFor` creates it either way, and the entry is what the very
/// next `previewPane` call picks up.
fn previewReveal(state: *anyopaque, ext: []const u8, path: []const u8, line: u32, id_extra: u64) void {
    _ = ext;
    _ = path;
    const st: *State = @ptrCast(@alignCast(state));
    st.previewFor(sdk.allocator(), id_extra).revealLine(line);
}

fn previewPane(state: *anyopaque, ext: []const u8, path: []const u8, bytes: []const u8, id_extra: u64, gpa: std.mem.Allocator) !void {
    _ = ext;
    const st: *State = @ptrCast(@alignCast(state));
    const gop = st.previews.getOrPut(gpa, id_extra) catch return error.OutOfMemory;
    if (!gop.found_existing) gop.value_ptr.* = .{};
    md.drawPreviewForDocument(gop.value_ptr, path, bytes, gpa, .{
        .io = dvui.io,
        .id_extra = id_extra,
        // Transparent, same as the store's README pane: the document tab already paints the
        // pane behind this, and the preview's own `.content` fill read as a visibly different
        // panel sitting beside the editor rather than the other half of one document.
        .background = false,
        // This preview owns the full pane, so nothing else insets it: without a margin of its
        // own the prose runs straight into the sash on one side and the pane edge on the other.
        // Extra at the top clears the raw|split|preview pill, which floats over the content.
        .content_padding = .{ .x = 20, .y = 16, .w = 20, .h = 16 },
    });
    // `drawPreviewForDocument` fills in `document_path` from `path` — that's what enables
    // `[[wikilinks]]` here but not in the store's README pane, which has no local file.
}

fn svcRender(ctx: *anyopaque, bytes: []const u8, gpa: std.mem.Allocator, opts: sdk.services.markdown.Api.RenderOptions) !void {
    const st: *State = @ptrCast(@alignCast(ctx));
    const preview = st.previewFor(gpa, opts.id_extra);
    md.drawPreview(preview, bytes, gpa, .{
        .io = dvui.io,
        .image_base_dir = opts.image_base_dir,
        .id_extra = opts.id_extra,
    });
}

fn svcDefaultView(ctx: *anyopaque) sdk.services.markdown.Api.DefaultView {
    const st: *State = @ptrCast(@alignCast(ctx));
    return st.defaultView();
}

fn svcSetDefaultView(ctx: *anyopaque, view: sdk.services.markdown.Api.DefaultView) void {
    const st: *State = @ptrCast(@alignCast(ctx));
    st.setDefaultView(view);
}

comptime {
    sdk.Plugin.assertUtilityVTable(vtable);
}
