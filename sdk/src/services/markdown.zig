//! Markdown inter-plugin service — SDK-facing definition of the `"markdown"` service.
//!
//! The markdown plugin registers an instance via `host.registerService` in its own
//! `register()`. Plugin code uses `host.getServiceTyped(markdown.Api)` to render a
//! markdown-shaped byte slice (CommonMark+GFM via md4c) into the current dvui parent
//! without importing the markdown plugin directly. The service is missing when the
//! plugin is disabled, so callers treat that as a normal case and fall back.
const std = @import("std");

pub const Api = struct {
    /// Bump whenever this struct's layout changes: `getServiceTyped` refuses a provider whose
    /// version differs rather than reinterpreting one shape as another across `dlopen`.
    pub const service_version: u32 = 2;
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

    pub const InlineOptions = struct {
        /// The width the blocks lay out at. A caller that wants its box to hug short text (a chat
        /// bubble) measures the text and passes the smaller of that and its limit.
        width: f32,
        image_base_dir: []const u8 = ".",
        /// What keeps this render's parse and layout apart from every other, and what
        /// `release` names. One per thing rendered (a message), stable across frames.
        id_extra: u64 = 0,
    };

    pub const VTable = struct {
        render: *const fn (ctx: *anyopaque, bytes: []const u8, gpa: std.mem.Allocator, opts: RenderOptions) anyerror!void,
        renderInline: *const fn (ctx: *anyopaque, bytes: []const u8, gpa: std.mem.Allocator, opts: InlineOptions) anyerror!void,
        release: *const fn (ctx: *anyopaque, id_extra: u64) void,
        defaultView: *const fn (ctx: *anyopaque) DefaultView,
        setDefaultView: *const fn (ctx: *anyopaque, view: DefaultView) void,
    };

    /// Render `bytes` as read-only markdown (own scroll area — don't nest inside another) into
    /// the current dvui parent.
    pub fn render(self: Api, bytes: []const u8, gpa: std.mem.Allocator, opts: RenderOptions) !void {
        return self.vtable.render(self.ctx, bytes, gpa, opts);
    }

    /// Render `bytes` into the current dvui parent with no scroll area of its own, as tall as it
    /// needs at `opts.width`: inside a chat message, a hover, anything that already scrolls. The
    /// parse and the blocks' heights are kept per `opts.id_extra` until `release`.
    pub fn renderInline(self: Api, bytes: []const u8, gpa: std.mem.Allocator, opts: InlineOptions) !void {
        return self.vtable.renderInline(self.ctx, bytes, gpa, opts);
    }

    /// Forget what was kept for `id_extra`'s render (a message deleted, a chat closed).
    pub fn release(self: Api, id_extra: u64) void {
        self.vtable.release(self.ctx, id_extra);
    }

    pub fn defaultView(self: Api) DefaultView {
        return self.vtable.defaultView(self.ctx);
    }

    pub fn setDefaultView(self: Api, view: DefaultView) void {
        self.vtable.setDefaultView(self.ctx, view);
    }
};
