//! A browser OAuth round trip for any provider, on the wasm build: open the provider's
//! authorization URL in a popup, and get back whatever query/fragment it redirected to
//! `oauth-callback.html` with. Google's implicit flow, Dropbox's, anyone's — the page never
//! learns which; the plugin that started it parses the result.
//!
//! The redirect target is `<page origin>/oauth-callback.html` (`callbackUrl`), a page fizzy
//! ships beside `index.html` whose only job is to post its own location back to the opener and
//! close. The plugin registers that exact URL with its provider.
//!
//! One round trip at a time per page: the exports are global, so the state is too.
const std = @import("std");
const builtin = @import("builtin");

comptime {
    if (builtin.target.cpu.arch != .wasm32) {
        @compileError("WebOAuth is wasm-only; gate the import with `arch == .wasm32`");
    }
}

const wasm = struct {
    extern "fizzy" fn fizzy_web_oauth_open(url_ptr: [*]const u8, url_len: usize) void;
    extern "fizzy" fn fizzy_web_oauth_open_page(html_ptr: [*]const u8, html_len: usize, hash_ptr: [*]const u8, hash_len: usize) void;
    /// Writes the callback URL into `buf`; returns the length it needs (may exceed `len`).
    extern "fizzy" fn fizzy_web_oauth_callback_url(buf: [*]u8, len: usize) usize;
};

/// `result` is the callback page's `location.search ++ location.hash` (owned by the callee,
/// allocated with the allocator given to `begin`), or null when the popup closed without
/// arriving there (dismissed, blocked, an error page).
pub const DoneFn = *const fn (ctx: ?*anyopaque, result: ?[]u8) void;

const Pending = struct {
    allocator: std.mem.Allocator,
    cb: DoneFn,
    ctx: ?*anyopaque,
    /// Set by the JS side: the result, or null-with-`arrived` for a failure.
    result: ?[]u8 = null,
    arrived: bool = false,
};

var pending: ?Pending = null;

pub fn begin(allocator: std.mem.Allocator, url: []const u8, cb: DoneFn, ctx: ?*anyopaque) error{Busy}!void {
    if (pending != null) return error.Busy;
    pending = .{ .allocator = allocator, .cb = cb, .ctx = ctx };
    wasm.fizzy_web_oauth_open(url.ptr, url.len);
}

/// The same round trip through a page the caller carries (`html`, a whole document) rather
/// than one served beside the app: the page opens from a same-origin blob URL with `hash` as
/// its fragment, and posts `{ fizzyOAuth }` to the opener like `oauth-callback.html` does.
/// How a plugin loaded at runtime brings its own picker — nothing of it needs serving.
pub fn beginPage(allocator: std.mem.Allocator, html: []const u8, hash: []const u8, cb: DoneFn, ctx: ?*anyopaque) error{Busy}!void {
    if (pending != null) return error.Busy;
    pending = .{ .allocator = allocator, .cb = cb, .ctx = ctx };
    wasm.fizzy_web_oauth_open_page(html.ptr, html.len, hash.ptr, hash.len);
}

pub fn cancel() void {
    if (pending) |p| {
        if (p.result) |r| p.allocator.free(r);
    }
    pending = null;
}

/// Deliver a finished round trip, on this thread.
pub fn pump() void {
    const p = pending orelse return;
    if (!p.arrived) return;
    pending = null;
    p.cb(p.ctx, p.result);
}

/// `<origin>/oauth-callback.html`. Caller owns.
pub fn callbackUrl(allocator: std.mem.Allocator) ![]u8 {
    var buf: [512]u8 = undefined;
    const n = wasm.fizzy_web_oauth_callback_url(&buf, buf.len);
    if (n > buf.len) return error.NameTooLong;
    return allocator.dupe(u8, buf[0..n]);
}

/// The URL of another page shipped beside the app — a plugin's own (`plugins/<id>/<file>`,
/// copied from the plugin's `web/` directory by fizzy's web build) — for `begin`: the same
/// popup round trip, with that page posting the result. Caller owns.
pub fn pageUrl(allocator: std.mem.Allocator, rel: []const u8) ![]u8 {
    var buf: [512]u8 = undefined;
    const n = wasm.fizzy_web_oauth_callback_url(&buf, buf.len);
    if (n > buf.len) return error.NameTooLong;
    const base = buf[0..n];
    const dir = base[0 .. (std.mem.lastIndexOfScalar(u8, base, '/') orelse return error.InvalidUrl) + 1];
    return std.mem.concat(allocator, u8, &.{ dir, rel });
}

comptime {
    _ = &FizzyWebOAuthAlloc;
    _ = &FizzyWebOAuthResult;
    _ = &FizzyWebOAuthFailed;
}

export fn FizzyWebOAuthAlloc(len: usize) usize {
    const p = &(pending orelse return 0);
    const buf = p.allocator.alloc(u8, len) catch return 0;
    return @intFromPtr(buf.ptr);
}

export fn FizzyWebOAuthResult(ptr: usize, len: usize) void {
    const p = &(pending orelse return);
    p.result = @as([*]u8, @ptrFromInt(ptr))[0..len];
    p.arrived = true;
}

export fn FizzyWebOAuthFailed() void {
    const p = &(pending orelse return);
    p.arrived = true;
}
