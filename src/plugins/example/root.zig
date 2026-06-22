//! Dylib entry for the example plugin — the canonical third-party shape (identical to
//! `src/plugins/root.zig`): one `exportEntry` call wired to `src/plugin.zig`. Copy this verbatim
//! into a new plugin; you never edit it.
const sdk = @import("sdk");

comptime {
    sdk.dylib.exportEntry(@import("src/plugin.zig"));
}
