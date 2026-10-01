//! Markdown plugin state — caches parsed preview state keyed by fizzy document id, plus
//! persisted settings.
const std = @import("std");
const sdk = @import("fizzy_sdk");
const Preview = @import("markdown.zig").Preview;
const Settings = @import("Settings.zig");
const supermd = @import("md/supermd.zig");

const State = @This();

previews: std.AutoArrayHashMapUnmanaged(u64, Preview) = .empty,
/// For each `.smd` preview, the markdown its source was last rewritten to (`md/supermd.zig`),
/// kept until the source changes so the rewrite is not redone every frame.
supermd_rewrites: std.AutoArrayHashMapUnmanaged(u64, Rewrite) = .empty,
/// Persisted via `Host.loadPluginSettings`/`storePluginSettings` — see `Settings.zig`.
settings: Settings = .{},

pub const Schema = sdk.settings.Schema(Settings);

const Rewrite = struct {
    source_hash: u64,
    markdown: []u8,
};

pub fn destroy(self: *State, gpa: std.mem.Allocator) void {
    for (self.previews.values()) |*p| p.deinit();
    self.previews.deinit(gpa);
    for (self.supermd_rewrites.values()) |r| gpa.free(r.markdown);
    self.supermd_rewrites.deinit(gpa);
}

/// What the preview of document `id` should parse: SuperMD rewritten into markdown, unless the
/// user asked to see it raw. Falls back to `bytes` themselves if the rewrite cannot be made.
pub fn superMdAsMarkdown(self: *State, gpa: std.mem.Allocator, id: u64, bytes: []const u8) []const u8 {
    if (self.settings.supermd_preview.get() == .raw) return bytes;
    const hash = std.hash.XxHash3.hash(0, bytes);
    const gop = self.supermd_rewrites.getOrPut(gpa, id) catch return bytes;
    if (gop.found_existing) {
        if (gop.value_ptr.source_hash == hash) return gop.value_ptr.markdown;
        gpa.free(gop.value_ptr.markdown);
    }
    const markdown = supermd.toMarkdown(gpa, bytes) catch {
        self.supermd_rewrites.swapRemoveAt(gop.index);
        return bytes;
    };
    gop.value_ptr.* = .{ .source_hash = hash, .markdown = markdown };
    return markdown;
}

pub fn previewFor(self: *State, gpa: std.mem.Allocator, id: u64) *Preview {
    const gop = self.previews.getOrPut(gpa, id) catch @panic("OOM");
    if (!gop.found_existing) gop.value_ptr.* = .{};
    return gop.value_ptr;
}

pub fn registerSettings(self: *State, host: *sdk.Host, plugin: *sdk.Plugin) !void {
    try Schema.register(host, plugin, .{
        .title = "Markdown",
        .value = &self.settings,
    });
}

pub fn defaultView(self: *const State) sdk.services.markdown.Api.DefaultView {
    return switch (self.settings.default_md_view.get()) {
        .raw => .raw,
        .split => .split,
        .preview => .preview,
    };
}

pub fn setDefaultView(self: *State, view: sdk.services.markdown.Api.DefaultView) void {
    const setting: Settings.DefaultMdView = switch (view) {
        .raw => .raw,
        .split => .split,
        .preview => .preview,
    };
    if (self.settings.default_md_view.get() == setting) return;
    self.settings.default_md_view.set(setting);
    Schema.store(sdk.host(), "markdown", self.settings);
}
