//! Dylib entry for the workbench plugin — canonical shape: one `exportEntry` wired to
//! `src/plugin.zig` (see `src/plugins/root.zig`).
const sdk = @import("sdk");

comptime {
    sdk.dylib.exportEntry(@import("src/plugin.zig"));
}
