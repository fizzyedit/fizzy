//! Everything that makes a fizzy-based application *this* application rather than fizzy: the
//! window title, bundle id, config folder, registry URL, theme names, exe name — one record an
//! app built on fizzy fills in, instead of literals scattered through the tree.
//!
//! Values arrive from the build (`build_opts`) so the same record is available at comptime for
//! the build graph and at runtime for the editor.
const std = @import("std");
const build_opts = @import("build_opts");

const AppInfo = @This();

/// Short lowercase identifier. The executable name, the Velopack packId, and — unless
/// `config_dir` overrides it — the on-disk config directory.
name: []const u8,

/// Human-facing name: window title, About dialog, installer title.
display_name: []const u8,

/// Reverse-DNS application identifier (`com.foxnne.fizzy`). macOS bundle id, SDL app metadata,
/// Linux desktop file.
bundle_id: []const u8,

/// Config directory name under the platform config root. Defaults to `name`; separate because
/// fizzy's is lowercase `fizzy` while its display name is `Fizzy`, and because an app may want
/// to keep a legacy directory name after a rename.
config_dir: []const u8,

/// Semantic version string, as baked by the build.
version: []const u8,

/// Update feed. Empty disables the "check for updates" affordance rather than failing.
repo_url: []const u8,
repo_url_fallback: []const u8,

/// Plugin registry catalog endpoint. An app that ships its own store points this at its own
/// registry; empty means "no store".
registry_url: []const u8,

/// The one instance, from build options.
pub const current: AppInfo = .{
    .name = build_opts.app_name,
    .display_name = build_opts.app_display_name,
    .bundle_id = build_opts.app_bundle_id,
    .config_dir = build_opts.app_config_dir,
    .version = build_opts.app_version,
    .repo_url = build_opts.app_repo_url,
    .repo_url_fallback = build_opts.app_repo_url_fallback,
    .registry_url = build_opts.app_registry_url,
};

/// Null-terminated forms, for the C APIs that need them (SDL metadata, window title).
pub const display_name_z: [:0]const u8 = build_opts.app_display_name ++ "";

/// The macOS app menu's first item. AppKit creates that item itself rather than from fizzy's
/// menu model, so the title is written straight into the `NSMenuItem` and has to be built here
/// where the terminator survives concatenation.
pub const about_title_z: [:0]const u8 = "About " ++ build_opts.app_display_name ++ "";
pub const bundle_id_z: [:0]const u8 = build_opts.app_bundle_id ++ "";
pub const version_z: [:0]const u8 = build_opts.app_version ++ "";
