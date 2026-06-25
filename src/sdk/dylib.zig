//! Runtime dynamic-library contract for Fizzy plugins.
//!
//! Host and plugin each compile their own copy of `dvui` + `sdk` + `core`; the host injects
//! its live dvui context into the plugin image (see `dvui_context.zig`). Cross-boundary
//! vtables use normal Zig layouts pinned to the same Fizzy/SDK build. Only the `dlopen` entry
//! symbols below use C calling convention.
//!
//! **Compatibility:** a structural `abi_fingerprint` is the hard memory-safety gate; human-
//! readable `sdk_version` (see `version.zig`) tells authors when to rebuild. See
//! `docs/PLUGINS.md` § Compatibility.
const std = @import("std");
const dvui = @import("dvui");
const proxy_bridge = @import("proxy_bridge");
const fingerprint = @import("fingerprint.zig");
const dvui_context = @import("dvui_context.zig");
const runtime = @import("runtime.zig");
const version = @import("version.zig");
const manifest_mod = @import("manifest.zig");

const Host = @import("Host.zig");
const Plugin = @import("Plugin.zig");
const DocHandle = @import("DocHandle.zig");
const EditorAPI = @import("EditorAPI.zig");
const regions = @import("regions.zig");
const workbench_service = @import("services/workbench.zig");

pub const PluginManifest = manifest_mod.PluginManifest;

/// C ABI — host loader injects host-owned pointers into the plugin image before `register`.
///
/// `gpa` is always the app allocator. `arg_b`/`arg_c` are two generic injection slots whose
/// meaning is defined by the receiving plugin's `set_globals` (they are *not* fixed roles).
/// The conventions in this tree:
///   - third-party (`exportEntry`): `arg_b` = the `*Host`, `arg_c` = unused (a plugin owns its state)
///   - workbench / code: `arg_b` = `*Host`, `arg_c` = the plugin's own state
///   - pixi: `arg_b` = the plugin's `*State`, `arg_c` = `*Packer` (historical; takes no host here)
pub const SetGlobalsFn = *const fn (
    gpa: ?*const anyopaque,
    arg_b: ?*anyopaque,
    arg_c: ?*anyopaque,
) callconv(.c) void;

/// C ABI — host loader pushes its render bridge into the plugin's proxy backend.
pub const SetRenderBridgeFn = *const fn (?*const proxy_bridge.RenderBridge) callconv(.c) void;

/// C ABI — `fizzy_plugin_register`.
pub const RegisterFn = *const fn (?*Host) callconv(.c) u32;

/// C ABI — `fizzy_plugin_abi_fingerprint`; the loader rejects any value != `abi_fingerprint`.
pub const GetAbiFingerprintFn = *const fn () callconv(.c) u64;

pub const VersionTriplet = extern struct {
    major: u32,
    minor: u32,
    patch: u32,
};

/// C ABI — returns SDK version this plugin was built against.
pub const GetSdkVersionFn = *const fn () callconv(.c) VersionTriplet;

/// C ABI — returns the plugin's declared minimum host SDK version.
pub const GetMinSdkVersionFn = *const fn () callconv(.c) VersionTriplet;

/// C ABI — returns the plugin's own release version.
pub const GetPluginVersionFn = *const fn () callconv(.c) VersionTriplet;

/// C ABI — returns the plugin's stable id (NUL-terminated).
pub const GetPluginIdFn = *const fn () callconv(.c) [*:0]const u8;

/// dvui data/handle types that cross the boundary by value or through the render bridge.
const dvui_boundary_types = .{
    dvui.Window,
    dvui.Debug,
    dvui.Vertex,
    dvui.Vertex.Index,
    dvui.Texture,
    dvui.TextureTarget,
    dvui.Rect.Physical,
    dvui.Id,
};

/// SDK types whose full structure is part of the contract.
const sdk_boundary_types = .{
    Host,
    Plugin,
    Plugin.VTable,
    DocHandle,
    EditorAPI,
    EditorAPI.VTable,
    regions.SidebarView,
    regions.BottomView,
    regions.CenterProvider,
    regions.MenuContribution,
    regions.MenuSectionContribution,
    regions.SettingsSection,
    regions.Command,
    Host.FileRowFillColor,
    proxy_bridge.RenderBridge,
    workbench_service.Api,
    workbench_service.Api.VTable,
    VersionTriplet,
};

const entry_symbol_types = .{
    RegisterFn,
    SetGlobalsFn,
    SetRenderBridgeFn,
    GetAbiFingerprintFn,
    GetSdkVersionFn,
    GetMinSdkVersionFn,
    GetPluginVersionFn,
    GetPluginIdFn,
    dvui_context.SetContextFn,
};

pub const abi_fingerprint: u64 = blk: {
    @setEvalBranchQuota(1_000_000);
    var h = fingerprint.seed;
    h = fingerprint.hashAll(h, dvui_boundary_types, 0);
    h = fingerprint.hashAll(h, sdk_boundary_types, 6);
    h = fingerprint.hashAll(h, entry_symbol_types, 3);
    break :blk h;
};

pub const symbol_register: [:0]const u8 = "fizzy_plugin_register";
pub const symbol_set_dvui_context: [:0]const u8 = "fizzy_plugin_set_dvui_context";
pub const symbol_set_render_bridge: [:0]const u8 = "fizzy_plugin_set_render_bridge";
pub const symbol_set_globals: [:0]const u8 = "fizzy_plugin_set_globals";
pub const symbol_abi_fingerprint: [:0]const u8 = "fizzy_plugin_abi_fingerprint";
pub const symbol_sdk_version: [:0]const u8 = "fizzy_plugin_sdk_version";
pub const symbol_min_sdk_version: [:0]const u8 = "fizzy_plugin_min_sdk_version";
pub const symbol_plugin_version: [:0]const u8 = "fizzy_plugin_version";
pub const symbol_plugin_id: [:0]const u8 = "fizzy_plugin_id";

pub const RegisterStatus = enum(u32) {
    ok = 0,
    err_register = 1,
    err_null_host = 2,
    err_abi_mismatch = 3,
    err_sdk_version = 4,
};

pub fn fingerprintMatches(plugin_fp: u64) bool {
    return plugin_fp == abi_fingerprint;
}

pub fn tripletFromSemver(v: std.SemanticVersion) VersionTriplet {
    return .{
        .major = @intCast(v.major),
        .minor = @intCast(v.minor),
        .patch = @intCast(v.patch),
    };
}

pub fn semverFromTriplet(t: VersionTriplet) std.SemanticVersion {
    return .{ .major = t.major, .minor = t.minor, .patch = t.patch };
}

/// Emit version/id C exports for a built-in dylib that does not use `exportEntry`.
pub fn exportManifestSymbols(comptime manifest: PluginManifest) void {
    const IdEntry = struct {
        const id_z = manifest.id ++ "\x00";
        fn pluginId() callconv(.c) [*:0]const u8 {
            return id_z;
        }
    };
    const ManifestEntry = struct {
        fn sdkVersion() callconv(.c) VersionTriplet {
            return tripletFromSemver(version.sdk_version);
        }
        fn minSdkVersion() callconv(.c) VersionTriplet {
            return tripletFromSemver(manifest.min_sdk_version);
        }
        fn pluginVersion() callconv(.c) VersionTriplet {
            return tripletFromSemver(manifest.version);
        }
    };
    @export(&IdEntry.pluginId, .{ .name = symbol_plugin_id });
    @export(&ManifestEntry.sdkVersion, .{ .name = symbol_sdk_version });
    @export(&ManifestEntry.minSdkVersion, .{ .name = symbol_min_sdk_version });
    @export(&ManifestEntry.pluginVersion, .{ .name = symbol_plugin_version });
}

/// Emit the C entry symbols every plugin dylib must export, wired to the plugin's
/// own `register` and `manifest`.
///
/// `plugin_mod` must expose:
///   - `pub fn register(*Host) !void`
///   - `pub const manifest: PluginManifest`
pub fn exportEntry(comptime plugin_mod: type) void {
    comptime {
        if (@hasDecl(plugin_mod, "manifest") == false) {
            @compileError("plugin module must declare `pub const manifest: sdk.PluginManifest`");
        }
    }
    const manifest = plugin_mod.manifest;
    const IdEntry = struct {
        const id_z = manifest.id ++ "\x00";
        fn pluginId() callconv(.c) [*:0]const u8 {
            return id_z;
        }
    };

    const Entry = struct {
        fn abiFingerprint() callconv(.c) u64 {
            return abi_fingerprint;
        }
        fn sdkVersion() callconv(.c) VersionTriplet {
            return tripletFromSemver(version.sdk_version);
        }
        fn minSdkVersion() callconv(.c) VersionTriplet {
            return tripletFromSemver(manifest.min_sdk_version);
        }
        fn pluginVersion() callconv(.c) VersionTriplet {
            return tripletFromSemver(manifest.version);
        }
        fn register(host: ?*Host) callconv(.c) u32 {
            if (host == null) return @intFromEnum(RegisterStatus.err_null_host);
            if (!version.sdkVersionSatisfies(version.sdk_version, manifest.min_sdk_version)) {
                return @intFromEnum(RegisterStatus.err_sdk_version);
            }
            plugin_mod.register(host.?) catch return @intFromEnum(RegisterStatus.err_register);
            return @intFromEnum(RegisterStatus.ok);
        }
        fn setDvuiContext(
            window: ?*dvui.Window,
            io: ?*anyopaque,
            ft2lib: ?*anyopaque,
            debug: ?*dvui.Debug,
        ) callconv(.c) void {
            dvui_context.inject(window, io, ft2lib, debug);
        }
        fn setRenderBridge(bridge: ?*const proxy_bridge.RenderBridge) callconv(.c) void {
            proxy_bridge.setBridge(bridge);
        }
        fn setGlobals(gpa: ?*const anyopaque, host: ?*anyopaque, state: ?*anyopaque) callconv(.c) void {
            runtime.installRuntime(
                if (gpa) |p| @ptrCast(@alignCast(p)) else null,
                if (host) |p| @ptrCast(@alignCast(p)) else null,
                state,
            );
        }
    };
    @export(&Entry.abiFingerprint, .{ .name = symbol_abi_fingerprint });
    @export(&Entry.sdkVersion, .{ .name = symbol_sdk_version });
    @export(&Entry.minSdkVersion, .{ .name = symbol_min_sdk_version });
    @export(&Entry.pluginVersion, .{ .name = symbol_plugin_version });
    @export(&IdEntry.pluginId, .{ .name = symbol_plugin_id });
    @export(&Entry.register, .{ .name = symbol_register });
    @export(&Entry.setDvuiContext, .{ .name = symbol_set_dvui_context });
    @export(&Entry.setRenderBridge, .{ .name = symbol_set_render_bridge });
    @export(&Entry.setGlobals, .{ .name = symbol_set_globals });
}

test "abi fingerprint is non-zero and self-consistent" {
    try std.testing.expect(abi_fingerprint != fingerprint.seed);
    try std.testing.expect(abi_fingerprint != 0);
    try std.testing.expect(fingerprintMatches(abi_fingerprint));
    try std.testing.expect(!fingerprintMatches(abi_fingerprint +% 1));
}
