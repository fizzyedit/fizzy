const std = @import("std");

/// App-side re-export of the plugin build API (lives in `sdk/`). Plugins should depend on
/// the `sdk/` package directly — see CLAUDE.md — not this root package.
///
/// Reached through the dependency rather than by path (`sdk/plugin_sdk.zig`): the app consumes
/// `sdk/` as a package so the two can share one dvui pin, and a file may belong to only one module,
/// so claiming these for the root's build module would make that impossible.
pub const plugin = @import("fizzy_sdk").plugin;

pub fn build(b: *std.Build) !void {
    const windows_msvc_libc_opt = b.option([]const u8, "windows-msvc-libc", "zig libc manifest for *-windows-msvc when cross-compiling; forwarded by packageall for Windows children") orelse null;
    const fetch_msvc_opt = b.option(bool, "fetch-msvc", "If *-windows-msvc libc is missing under .velopack-msvc/, run msvcup-setup first (downloads MSVC+SDK; requires network). Defaults to true on Windows hosts targeting *-windows-msvc.") orelse null;

    const macos_sign_app_identity = b.option([]const u8, "macos-sign-app", "macOS codesign identity for the app bundle (e.g. 'Developer ID Application: NAME (TEAMID)')") orelse
        b.graph.environ_map.get("FIZZY_MACOS_SIGN_APP");
    const macos_sign_install_identity = b.option([]const u8, "macos-sign-installer", "macOS codesign identity for the installer pkg (e.g. 'Developer ID Installer: NAME (TEAMID)')") orelse
        b.graph.environ_map.get("FIZZY_MACOS_SIGN_INSTALLER");
    const macos_notary_profile = b.option([]const u8, "macos-notary-profile", "notarytool keychain profile name (run `xcrun notarytool store-credentials <name>` first)") orelse
        b.graph.environ_map.get("FIZZY_MACOS_NOTARY_PROFILE");

    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    try @import("build/app.zig").build(b, target, optimize, .{
        .windows_msvc_libc_opt = windows_msvc_libc_opt,
        .fetch_msvc_opt = fetch_msvc_opt,
        .macos_sign_app_identity = macos_sign_app_identity,
        .macos_sign_install_identity = macos_sign_install_identity,
        .macos_notary_profile = macos_notary_profile,
    });
}
