//! Accounts: who the user is signed in as, with which service. A plugin that signs in
//! somewhere — a cloud drive, a forge, a sync service — registers an `Provider`; the host
//! draws the one account disc in the rail and the list it opens, with every provider's
//! accounts in it and a way to sign in to the ones with none. Nothing here names a service.
const std = @import("std");
const dvui = @import("dvui");
const Plugin = @import("Plugin.zig");

/// One signed-in identity, as the provider reports it this frame. Strings are borrowed from
/// the provider (its state, or the frame arena it was given).
pub const Account = struct {
    /// Stable within the provider: what the host hands back to `menu`.
    id: []const u8,
    /// What the user is called there — an email, a handle.
    label: []const u8,
    /// A profile picture, if the provider has one; the disc shows the first account's.
    avatar: ?dvui.ImageSource = null,
};

pub const Provider = struct {
    /// Plugin-namespaced (`drive.google`).
    id: []const u8,
    /// The service's name as shown beside an account: "Google Drive", "GitHub".
    name: []const u8,
    owner: ?*Plugin = null,
    hidden: bool = false,
    ctx: ?*anyopaque = null,
    vtable: *const VTable,

    pub const VTable = struct {
        /// The accounts currently signed in. `arena` is the frame's; the slice and its strings
        /// may live there.
        accounts: *const fn (ctx: ?*anyopaque, arena: std.mem.Allocator) []const Account,
        /// Start a sign-in (a browser, a dialog). Null when the provider cannot add one — a
        /// single-account service already signed in.
        signIn: ?*const fn (ctx: ?*anyopaque) void = null,
        /// Draw the rows of one account's submenu (open, settings, sign out …) with
        /// `Host.drawMenuItem` — never dvui's menu widgets directly: in a dylib those belong
        /// to a dvui copy with no open menu. The host has opened the floating menu already.
        /// Return true when a row was chosen so the host closes the whole menu.
        menu: *const fn (ctx: ?*anyopaque, account_id: []const u8) bool,
    };

    pub fn accounts(self: Provider, arena: std.mem.Allocator) []const Account {
        return self.vtable.accounts(self.ctx, arena);
    }
    pub fn canSignIn(self: Provider) bool {
        return self.vtable.signIn != null;
    }
    pub fn signIn(self: Provider) void {
        if (self.vtable.signIn) |f| f(self.ctx);
    }
    pub fn menu(self: Provider, account_id: []const u8) bool {
        return self.vtable.menu(self.ctx, account_id);
    }
};
