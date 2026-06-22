const std = @import("std");
const markdown = @import("../markdown.zig");
const sdk = markdown.sdk;
const dvui = markdown.dvui;
const State = markdown.State;

const plugin_options = @import("fizzy_plugin_options");

pub const manifest = sdk.PluginManifest{
    .id = "markdown",
    .name = "Markdown",
    .version = plugin_options.version,
};

var plugin: sdk.Plugin = .{
    .state = undefined,
    .vtable = &vtable,
    .id = "markdown",
    .display_name = "Markdown",
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
    markdown.drawPreviewForDocument(gop.value_ptr, sdk.language.previewDocumentPath(), bytes, gpa, .{
        .io = dvui.io,
        .id_extra = id_extra,
    });
}

fn svcRender(ctx: *anyopaque, bytes: []const u8, gpa: std.mem.Allocator, opts: sdk.services.markdown.Api.RenderOptions) !void {
    const st: *State = @ptrCast(@alignCast(ctx));
    const preview = st.previewFor(gpa, opts.id_extra);
    markdown.drawPreview(preview, bytes, gpa, .{
        .io = dvui.io,
        .image_base_dir = opts.image_base_dir,
        .id_extra = opts.id_extra,
    });
}

comptime {
    sdk.Plugin.assertUtilityVTable(vtable);
}
