const sdk = @import("sdk");

comptime {
    sdk.dylib.exportEntry(@import("src/plugin.zig"));
}
