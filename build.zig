const std = @import("std");

pub const plugin = @import("plugin_sdk.zig");

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

    const plugin_sdk = b.option(
        bool,
        "plugin_sdk",
        "Export core/sdk modules for third-party plugin builds; skips the fizzy app",
    ) orelse false;
    if (plugin_sdk) {
        try plugin.exportModules(b, target, optimize);
        return;
    }

    try @import("build/app.zig").build(b, target, optimize, .{
        .windows_msvc_libc_opt = windows_msvc_libc_opt,
        .fetch_msvc_opt = fetch_msvc_opt,
        .macos_sign_app_identity = macos_sign_app_identity,
        .macos_sign_install_identity = macos_sign_install_identity,
        .macos_notary_profile = macos_notary_profile,
    });
} 
