//! Dylib entry for the code plugin — identical in shape to the canonical third-party
//! `src/plugins/root.zig`: one `exportEntry` call wired to `src/plugin.zig`.
const sdk = @import("sdk");

comptime {
    sdk.dylib.exportEntry(@import("src/plugin.zig"));
}
