//! Markdown inter-plugin service — SDK-facing definition of the `"markdown"` service.
//!
//! The markdown plugin registers an instance via `host.registerService` in its own
//! `register()`. Plugin code uses `host.getServiceTyped(markdown.Api)` to render a
//! markdown-shaped byte slice (CommonMark+GFM via `cmark-gfm`) into the current dvui parent
//! without importing the markdown plugin directly. Native-only — absent on web builds (see
//! `markdown.zig`'s own doc comment: it links libc + a C library), so callers must treat a
//! missing service as a normal, expected case and fall back to their own rendering.
const std = @import("std");

pub const Api = struct {
    pub const service_name = "markdown";

    ctx: *anyopaque,
    vtable: *const VTable,

    pub const RenderOptions = struct {
        /// Base dir for resolving relative `![alt](path)` image links.
        image_base_dir: []const u8 = ".",
        /// Seed for widget ids + the preview-state cache key, so multiple concurrent renders
        /// (e.g. more than one hover tooltip) don't collide.
        id_extra: u64 = 0,
    };

    pub const VTable = struct {
        render: *const fn (ctx: *anyopaque, bytes: []const u8, gpa: std.mem.Allocator, opts: RenderOptions) anyerror!void,
    };

    /// Render `bytes` as read-only markdown (own scroll area — don't nest inside another) into
    /// the current dvui parent.
    pub fn render(self: Api, bytes: []const u8, gpa: std.mem.Allocator, opts: RenderOptions) !void {
        return self.vtable.render(self.ctx, bytes, gpa, opts);
    }
};
