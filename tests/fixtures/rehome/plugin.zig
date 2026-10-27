//! A plugin proving nested framework identity and C build inputs survive rehoming.
const std = @import("std");
const sdk = @import("fizzy_sdk");
const dvui = @import("dvui");
const child = @import("child");

pub const plugin_id = "rehome_fixture";
pub const plugin_options = struct {
    pub const manifest_zon = ".{ .id = \"rehome_fixture\", .name = \"Rehome fixture\", .version = \"0.0.0\", .min_sdk_version = \"0.0.0\" }";
};

comptime {
    if (child.Window != dvui.Window) @compileError("nested dvui was not rehomed");
    if (child != @import("same_child")) @compileError("shared child was copied twice");
}

pub fn register(_: *sdk.Host) !void {
    if (child.value() != 42) return error.MissingCInputs;
}

test "nested module retains C sources, include paths and macros" {
    try std.testing.expectEqual(@as(c_int, 42), child.value());
}
