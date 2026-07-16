//! Dylib entry for the text plugin — identical in shape to the canonical third-party
//! `src/plugins/root.zig`: one `exportEntry` call wired to `src/plugin.zig`.
const std = @import("std");
const sdk = @import("sdk");

pub const std_options: std.Options = sdk.dylib.stdOptions(@import("src/plugin.zig"));

comptime {
    sdk.dylib.exportEntry(@import("src/plugin.zig"));
}
