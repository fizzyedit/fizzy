//! Emit `sdk-meta.json` for store CI — wired by `fizzy.plugin.install`.
//!
//! Values come from the same pinned fizzy SDK module the plugin links (same optimize-mode
//! safety class → same `abi_fingerprint` as the dylib) plus identity from `plugin.zig.zon`
//! (injected as build options). No dlopen — works for every target, including Windows and
//! cross-compiles. The build passes the output path via `addOutputFileArg`.
const std = @import("std");
const sdk = @import("fizzy_sdk");
const meta = @import("plugin_meta");

pub fn main(main_init: std.process.Init) !void {
    const arena = main_init.arena.allocator();
    const args = try main_init.minimal.args.toSlice(arena);
    if (args.len < 2) {
        std.debug.print("usage: plugin_sdk_meta <out.json>\n", .{});
        std.process.exit(2);
    }

    const v = sdk.version.sdk_version;
    const min = meta.min_sdk_version;
    const min_str: []const u8 = if (min.len > 0)
        min
    else
        try std.fmt.allocPrint(arena, "{d}.{d}.{d}", .{ v.major, v.minor, v.patch });

    const payload = try std.fmt.allocPrint(arena,
        \\{{
        \\  "id": "{s}",
        \\  "version": "{s}",
        \\  "abi_fingerprint": "0x{x}",
        \\  "fizzy_sdk_version": "{d}.{d}.{d}",
        \\  "min_sdk_version": "{s}"
        \\}}
        \\
    , .{
        meta.id,
        meta.version,
        sdk.dylib.abi_fingerprint,
        v.major,
        v.minor,
        v.patch,
        min_str,
    });

    try std.Io.Dir.cwd().writeFile(main_init.io, .{ .sub_path = args[1], .data = payload });
}
