const std = @import("std");
const sdk = @import("fizzy_sdk");
const dvui = @import("dvui");
const State = @import("src/State.zig").State;
const md = @import("src/markdown.zig");

/// Re-exported for the shell's own use of the preview renderer outside this plugin's own
/// vtable/service surface (e.g. `src/editor/readme.zig` rendering a fetched plugin README) —
/// see `docs/PLUGIN_MANIFEST_PLAN.md`'s "static module root" decision.
pub const Preview = md.Preview;
pub const drawPreview = md.drawPreview;
pub const drawPreviewForDocument = md.drawPreviewForDocument;

/// Injected at build time from `plugin.zig.zon` (see `static/integration.zig` /
/// `src/plugins/shared/build/helpers.zig`'s `pluginOptions`) — one source of truth for
/// identity, not duplicated as string literals here.
pub const plugin_options = @import("fizzy_plugin_options");

/// This plugin's stable id — the single source of truth other modules (e.g. the shell's
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
};

var markdown_api: sdk.services.markdown.Api = .{
    .ctx = @ptrCast(&plugin_state),
    .vtable = &markdown_service_vtable,
};

const markdown_service_vtable: sdk.services.markdown.Api.VTable = .{
    .render = svcRender,
};

pub fn register(host: *sdk.Host) !void {
    plugin.state = @ptrCast(&plugin_state);
    try host.registerPlugin(&plugin);
    try host.registerLanguageSupport(language_support);
    try host.registerService("markdown", &markdown_api, &plugin);
}

fn deinit(state: *anyopaque) void {
    const st: *State = @ptrCast(@alignCast(state));
    st.destroy(sdk.allocator());
}

fn supportsPreview(_: *anyopaque, ext: []const u8) bool {
    return std.ascii.eqlIgnoreCase(ext, ".md") or std.ascii.eqlIgnoreCase(ext, ".markdown");
}

fn previewPane(state: *anyopaque, ext: []const u8, bytes: []const u8, id_extra: u64, gpa: std.mem.Allocator) !void {
    _ = ext;
    const st: *State = @ptrCast(@alignCast(state));
    const gop = st.previews.getOrPut(gpa, id_extra) catch return error.OutOfMemory;
    if (!gop.found_existing) gop.value_ptr.* = .{};
    md.drawPreviewForDocument(gop.value_ptr, sdk.language.previewDocumentPath(), bytes, gpa, .{
        .io = dvui.io,
        .id_extra = id_extra,
    });
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

comptime {
    sdk.Plugin.assertUtilityVTable(vtable);
}
