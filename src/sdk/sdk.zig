//! Fizzy plugin SDK — the surface a plugin module depends on.
//!
//! Phase 0 of the modular-editor plan: type definitions + registries only.
//! Nothing routes through these yet; the shell still drives pixel art directly.
//! Subsequent phases move file management, the workspace/tabs system, and the
//! pixel-art editor behind this boundary, ending with runtime dylib loading.
pub const Host = @import("Host.zig");
pub const Plugin = @import("Plugin.zig");
pub const DocHandle = @import("DocHandle.zig");

/// Shell region contribution types (sidebar / bottom / center / menu / settings).
pub const regions = @import("regions.zig");
pub const SidebarView = regions.SidebarView;
pub const BottomView = regions.BottomView;
pub const CenterProvider = regions.CenterProvider;
pub const MenuContribution = regions.MenuContribution;
pub const SettingsSection = regions.SettingsSection;

/// Shell-provided read/utility surface plugins reach through the `Host`
/// (arena, folder, shared settings, dirty-marking).
pub const ShellApi = @import("ShellApi.zig");
