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
const builtin = @import("builtin");
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
const language_mod = @import("language.zig");
const workbench_service = @import("services/workbench.zig");
const markdown_service = @import("services/markdown.zig");

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

/// C ABI — `fizzy_plugin_name`; returns the plugin's user-facing display name (NUL-terminated).
pub const GetPluginNameFn = *const fn () callconv(.c) [*:0]const u8;
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
    language_mod.LanguageSupport,
    language_mod.LanguageSupport.VTable,
    language_mod.TreeSitterHighlight,
    language_mod.HighlightStyle,
    // `HoverResult`/`DefinitionLocation`/`CompletionItem`/`CompletionKind`/`SignatureHelpResult`
    // are only reached from `VTable`'s hooks through a slice or optional (a *data* pointer),
    // which `hashType` deliberately never follows (see its `.pointer` case) — without an
    // explicit entry here, a field added to one of these would silently change the real ABI
    // layout without moving the fingerprint at all. Discovered exactly this way: adding
    // `CompletionItem.kind`/`.detail` didn't trip `test-sdk-version`'s comptime check until
    // these were added.
    language_mod.HoverResult,
    language_mod.DefinitionLocation,
    language_mod.CompletionItem,
    language_mod.CompletionKind,
    language_mod.SignatureHelpResult,
    Host.FileRowFillColor,
    proxy_bridge.RenderBridge,
    workbench_service.Api,
    workbench_service.Api.VTable,
    markdown_service.Api,
    markdown_service.Api.VTable,
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

/// Optimize-mode layout class. `Debug`/`ReleaseSafe` embed a `std.debug.SafetyLock` inside every
/// by-value `std.HashMapUnmanaged` (shifting sibling field offsets); `ReleaseFast`/`ReleaseSmall`
/// zero-size it. A host and plugin in different classes have genuinely incompatible offsets even
/// with an identical boundary shape, so this is folded into `abi_fingerprint` — the one
/// real-layout axis the shape hash deliberately ignores.
const optimize_safety_class: []const u8 = switch (builtin.mode) {
    .Debug, .ReleaseSafe => "safe",
    .ReleaseFast, .ReleaseSmall => "fast",
};

/// Runtime dlopen-time compatibility key, compared live host-vs-plugin (`fingerprintMatches`).
///
/// **Target-invariant by design.** It is the Fizzy-owned boundary *shape*
/// (`sdk_shape_fingerprint` — field names/order, bit-widths, fn signatures; never a byte offset)
/// folded with the optimize-mode `optimize_safety_class`. Two consequences:
///   * every arch/os computes the *same* value, so the plugin store can match one fingerprint per
///     release across all its `os-arch` downloads. Cross-target loads are already impossible (the
///     OS dynamic loader won't `dlopen` a `.so` on macOS, etc.), so folding in per-target byte
///     offsets bought no real safety while breaking multi-platform distribution.
///   * it moves *only* on a genuine boundary-shape change (which also trips the `sdk_version`
///     guard in version.zig) or an optimize-mode-class mismatch. A cosmetic dvui/toolchain update
///     that leaves the boundary shape untouched keeps the same fingerprint, so already-installed
///     plugins keep loading — you only force a rebuild when a plugin genuinely *wouldn't* load.
///
/// **Trade-off it accepts:** it no longer catches pure codegen/padding drift within one
/// `sdk_version` (e.g. a zig-compiler bump that repads an identical field set). zig is pinned per
/// SDK release, so that is a deliberate, coordinated re-release rather than a silent hazard.
pub const abi_fingerprint: u64 = blk: {
    @setEvalBranchQuota(1_000_000);
    break :blk fingerprint.foldString(sdk_shape_fingerprint, optimize_safety_class);
};

/// Target- and optimize-mode-*invariant* hash of the Fizzy-owned boundary's declared shape (see
/// `fingerprint.hashAllShape` for what that means and why). Two jobs:
///   * `version.zig`'s "did you forget to bump `sdk_version`" guard checks it against a single
///     recorded literal — invariant, so that guard needs no per-target table and no
///     cross-compiling to populate; and
///   * `abi_fingerprint` above is this value folded with the optimize-mode class, i.e. the runtime
///     load key *is* the boundary shape plus mode.
/// The shape walk reaches every dvui type that crosses the boundary by value / as a render-bridge
/// fn-pointer param, so a breaking dvui restructure moves this too; a cosmetic dvui bump that
/// leaves the boundary shape untouched does not (see `docs/PLUGINS.md` § Compatibility).
pub const sdk_shape_fingerprint: u64 = blk: {
    @setEvalBranchQuota(1_000_000);
    var h = fingerprint.seed;
    h = fingerprint.hashAllShape(h, sdk_boundary_types, 6);
    h = fingerprint.hashAllShape(h, entry_symbol_types, 3);
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
pub const symbol_plugin_name: [:0]const u8 = "fizzy_plugin_name";

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
        const name_z = manifest.name ++ "\x00";
        fn pluginId() callconv(.c) [*:0]const u8 {
            return id_z;
        }
        fn pluginName() callconv(.c) [*:0]const u8 {
            return name_z;
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
    @export(&IdEntry.pluginName, .{ .name = symbol_plugin_name });
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
        const name_z = manifest.name ++ "\x00";
        fn pluginId() callconv(.c) [*:0]const u8 {
            return id_z;
        }
        fn pluginName() callconv(.c) [*:0]const u8 {
            return name_z;
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
    @export(&IdEntry.pluginName, .{ .name = symbol_plugin_name });
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
