//! Markdown inter-plugin service — SDK-facing definition of the `"markdown"` service.
//!
//! The markdown plugin registers an instance via `host.registerService` in its own
//! `register()`. Plugin code uses `host.getServiceTyped(markdown.Api)` to render a
//! markdown-shaped byte slice (CommonMark+GFM via md4c) into the current dvui parent
//! without importing the markdown plugin directly. The service is missing when the
//! plugin is disabled, so callers treat that as a normal case and fall back.
const std = @import("std");

pub const Api = struct {
    pub const service_name = "markdown";

    ctx: *anyopaque,
    vtable: *const VTable,

    /// How newly opened markdown documents start in the text editor's preview pane. Owned by
    /// the markdown plugin's `default_md_view` setting; the text plugin reads/writes it through
    /// this service so it does not have to import markdown.
    pub const DefaultView = enum {
        raw,
        split,
        preview,
    };

    pub const RenderOptions = struct {
        /// Base dir for resolving relative `![alt](path)` image links.
        image_base_dir: []const u8 = ".",
        /// Seed for widget ids + the preview-state cache key, so multiple concurrent renders
        /// (e.g. more than one hover tooltip) don't collide.
        id_extra: u64 = 0,
    };

    pub const VTable = struct {
        render: *const fn (ctx: *anyopaque, bytes: []const u8, gpa: std.mem.Allocator, opts: RenderOptions) anyerror!void,
        defaultView: *const fn (ctx: *anyopaque) DefaultView,
        setDefaultView: *const fn (ctx: *anyopaque, view: DefaultView) void,
    };

    /// Render `bytes` as read-only markdown (own scroll area — don't nest inside another) into
    /// the current dvui parent.
    pub fn render(self: Api, bytes: []const u8, gpa: std.mem.Allocator, opts: RenderOptions) !void {
        return self.vtable.render(self.ctx, bytes, gpa, opts);
    }

    pub fn defaultView(self: Api) DefaultView {
        return self.vtable.defaultView(self.ctx);
    }

    pub fn setDefaultView(self: Api, view: DefaultView) void {
        self.vtable.setDefaultView(self.ctx, view);
    }
};
