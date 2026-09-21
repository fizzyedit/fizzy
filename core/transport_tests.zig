//! Root for the standalone `fizzy-native-transport-tests` module: `NativeTransport.zig` reaches
//! `vfs/` by relative import, so the module's root has to sit at `core/` for that path to be
//! inside it. Nothing else lives here.
test {
    _ = @import("transport/NativeTransport.zig");
    _ = @import("vfs/vfs.zig");
    _ = @import("LocalFs.zig");
}
