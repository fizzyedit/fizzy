//! Markdown plugin state — caches parsed preview state keyed by fizzy document id, plus
//! persisted settings.
const std = @import("std");
const sdk = @import("fizzy_sdk");
const Preview = @import("markdown.zig").Preview;
const Settings = @import("Settings.zig");

pub const State = struct {
    previews: std.AutoArrayHashMapUnmanaged(u64, Preview) = .empty,
    /// Persisted via `Host.loadPluginSettings`/`storePluginSettings` — see `Settings.zig`.
    settings: Settings = .{},

    const Schema = sdk.settings.Schema(Settings);

    pub fn destroy(self: *State, gpa: std.mem.Allocator) void {
        for (self.previews.values()) |*p| p.deinit();
        self.previews.deinit(gpa);
    }

    pub fn previewFor(self: *State, gpa: std.mem.Allocator, id: u64) *Preview {
        const gop = self.previews.getOrPut(gpa, id) catch @panic("OOM");
        if (!gop.found_existing) gop.value_ptr.* = .{};
        return gop.value_ptr;
    }

    pub fn loadSettings(self: *State, host: *sdk.Host) void {
        Schema.load(host, "markdown", &self.settings);
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
};
