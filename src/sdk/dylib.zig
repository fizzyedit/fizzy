//! Runtime dynamic-library contract for Fizzy plugins (Phase 5b).
//!
//! Host and plugin each compile their own copy of `dvui` + `sdk` + `core` (Mechanism B:
//! context injection — see `spikes/shared-globals/README.md`). Cross-boundary vtables use
//! normal Zig layouts pinned to the same Fizzy/SDK build. Only the `dlopen` entry symbols
//! below use C calling convention.
//!
//! **Bump `abi_version` when any of these change:** `Host`, `Plugin`, `DocHandle`,
//! `EditorAPI` layouts, or the semantics/signature of an entry symbol.
pub const abi_version: u32 = 1;

/// `std.DynLib.lookup` names for the host loader (5b.3+).
pub const symbol_abi_version = "fizzy_plugin_abi_version";
pub const symbol_register = "fizzy_plugin_register";
/// Mechanism B — host calls each frame (and once at init) before plugin draw/tick.
pub const symbol_set_dvui_context = "fizzy_plugin_set_dvui_context";
/// Host-owned pixelart `Globals` (allocator, state, packer) injected before `register`.
pub const symbol_set_globals = "fizzy_plugin_set_globals";

/// C ABI — wire plugin-side `Globals` to host-owned pointers (pixelart today).
pub const SetGlobalsFn = *const fn (
    gpa: ?*const anyopaque,
    state: ?*anyopaque,
    packer: ?*anyopaque,
) callconv(.c) void;

/// Returned by `fizzy_plugin_register`. Stable unsigned values for C callers.
pub const RegisterStatus = enum(u32) {
    ok = 0,
    err_register = 1,
    err_null_host = 2,
    /// Reserved for the host loader when `fizzy_plugin_abi_version()` != `abi_version`.
    err_abi_mismatch = 3,
};

pub fn abiMatches(plugin_abi: u32) bool {
    return plugin_abi == abi_version;
}

test "plugin ABI version is locked" {
    const std = @import("std");
    try std.testing.expect(abi_version == 1);
    try std.testing.expect(abiMatches(abi_version));
    try std.testing.expect(!abiMatches(abi_version + 1));
}
