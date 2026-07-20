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
const settings_mod = @import("settings.zig");

const Host = @import("Host.zig");
const Plugin = @import("Plugin.zig");
const DocHandle = @import("DocHandle.zig");
const EditorAPI = @import("EditorAPI.zig");
const regions = @import("regions.zig");
const language_mod = @import("language.zig");
const workbench_service = @import("services/workbench.zig");
const markdown_service = @import("services/markdown.zig");

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

/// C ABI — `fizzy_plugin_manifest_zon`; returns the plugin's embedded `plugin.zig.zon` source
/// (NUL-terminated), for the loader's tamper check (byte-compare against the on-disk sidecar)
/// and self-heal (regenerate a missing sidecar from this embedded copy). The generated dylib
/// root (`plugin_sdk.create` / `helpers.addDylib`) threads the real zon text through via the
/// build-injected `fizzy_plugin_options` module — see `exportEntry` below.
pub const GetManifestZonFn = *const fn () callconv(.c) [*:0]const u8;

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
    // `SettingsSchema.fields` is a slice (a *data* pointer `hashType` deliberately never
    // follows — see the comment above `HoverResult` et al.), so `Setting` needs its own explicit
    // entry too, the same lesson `CompletionItem`/`CompletionKind` learned: without it, a
    // `Setting` shape change would silently change the real cross-plugin `Host.settings_schemas`
    // layout without moving this fingerprint at all. `Setting.kind` (the per-type `IntKind`/
    // `FloatKind`/`EnumKind` union) is reached by value, not by pointer, so it's walked for free —
    // no separate entry needed for it.
    settings_mod.SettingsSchema,
    settings_mod.Setting,
    // `Schema.access` is a pointer `hashType` never follows — same lesson as `Setting`.
    settings_mod.Access,
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
    GetManifestZonFn,
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
pub const symbol_manifest_zon: [:0]const u8 = "fizzy_plugin_manifest_zon";

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

/// `std.Options` that routes every `std.log`/`dvui.log` call in this dylib's whole compilation
/// unit — the plugin's own code *and* anything statically compiled into it, dvui's own internal
/// logging included — to the shell's Output panel, tagged with the plugin's own id. Still calls
/// dvui's default sink too, so `zig build run` terminal output is unaffected.
///
/// A dylib has its own private `std.log` binding (see `Client.Config.log`'s doc comment for why
/// that means `dvui.log.warn` alone never reaches the host), so without this, everything a
/// plugin logs is invisible outside its own stderr — exactly what made zls's hover hang silent
/// until `Client.zig` grew explicit forwarding for its own logging. This is that same fix, but
/// generic: any plugin can opt in for its *entire* compilation unit with one `root.zig` line,
/// no per-call-site changes.
///
/// One id per plugin (not the raw log scope) because `dvui.log` is always scoped `.dvui`
/// regardless of which plugin dylib calls it — using the scope as-is would merge every plugin's
/// dvui-originated logging into one shared tab, defeating the point of per-plugin filtering.
///
/// `id` is the plugin's stable id (`opts.id` from the build-injected `fizzy_plugin_options`
/// module — see `plugin_sdk.generatedDylibRoot` / `helpers.generatedDylibRoot`), not a whole
/// plugin module: the generated dylib root is the only place that calls this, and it only ever
/// needs the id string, not the author's `plugin.zig` namespace.
///
/// Opt in from the generated root:
///   pub const std_options: std.Options = sdk.dylib.stdOptions(opts.id);
pub fn stdOptions(comptime id: []const u8) std.Options {
    const Impl = struct {
        fn logFn(comptime level: std.log.Level, comptime scope: @EnumLiteral(), comptime format: []const u8, args: anytype) void {
            dvui.App.logFn(level, scope, format, args);
            const msg = std.fmt.allocPrint(runtime.allocator(), format, args) catch return;
            defer runtime.allocator().free(msg);
            runtime.host().logLine(level, id, msg);
        }
    };
    return .{ .logFn = Impl.logFn };
}

/// Identity passed to `exportEntry` — built-injected from `plugin.zig.zon` (see `readManifest`
/// in `plugin_sdk.zig` / `helpers.zig`), never author-supplied `Zig` source. `version`/
/// `min_sdk_version` are typed `SemanticVersion` (not strings) because the generated dylib root
/// receives them as already-parsed `fizzy_plugin_options` build options.
pub const Identity = struct {
    id: []const u8,
    name: []const u8,
    version: std.SemanticVersion,
    min_sdk_version: std.SemanticVersion,
};

/// Emit the C entry symbols every plugin dylib must export, wired to `plugin_mod.register` and
/// the build-injected `identity`/`manifest_zon`. Called only from the generated dylib root
/// (`plugin_sdk.create` / `helpers.addDylib`) — never directly by an author's `plugin.zig`,
/// which carries no C-ABI export boilerplate. `plugin_mod` must expose
/// `pub fn register(*Host) !void` at its top level.
pub fn exportEntry(comptime plugin_mod: type, comptime identity: Identity, comptime manifest_zon: [:0]const u8) void {
    const IdEntry = struct {
        const id_z = identity.id ++ "\x00";
        const name_z = identity.name ++ "\x00";
        fn pluginId() callconv(.c) [*:0]const u8 {
            return id_z;
        }
        fn pluginName() callconv(.c) [*:0]const u8 {
            return name_z;
        }
        fn manifestZon() callconv(.c) [*:0]const u8 {
            return manifest_zon;
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
            return tripletFromSemver(identity.min_sdk_version);
        }
        fn pluginVersion() callconv(.c) VersionTriplet {
            return tripletFromSemver(identity.version);
        }
        fn register(host: ?*Host) callconv(.c) u32 {
            if (host == null) return @intFromEnum(RegisterStatus.err_null_host);
            if (!version.sdkVersionSatisfies(version.sdk_version, identity.min_sdk_version)) {
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
    @export(&IdEntry.manifestZon, .{ .name = symbol_manifest_zon });
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
