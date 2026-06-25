const builtin = @import("builtin");
const std = @import("std");

pub fn build(_: *std.Build) !void {}

pub const Package = struct {
    module: *std.Build.Module,
};

pub fn package(b: *std.Build, _: struct {}) Package {
    const module = b.createModule(.{
        .root_source_file = .{ .cwd_relative = thisDir() ++ "/zip.zig" },
    });
    return .{ .module = module };
}

const wasm_c_flags = [_][]const u8{
    "-fno-sanitize=undefined",
    "-DFIZZY_ZIP_WASM",
    "-DZIP_RAW_ENTRYNAME",
};

pub fn link(exe: *std.Build.Step.Compile) void {
    exe.root_module.link_libc = true;
    exe.root_module.addIncludePath(.{ .cwd_relative = thisDir() ++ "/src" });
    const c_flags = [_][]const u8{"-fno-sanitize=undefined"};
    exe.root_module.addCSourceFile(.{ .file = .{ .cwd_relative = thisDir() ++ "/src/zip.c" }, .flags = &c_flags });
}

/// In-memory zip read/write for wasm32-freestanding (no libc, no filesystem).
/// Uses DVUI's `dvui_c_alloc` via `fizzy_zip_libc.c`.
pub fn linkWasm(exe: *std.Build.Step.Compile) void {
    exe.root_module.addIncludePath(.{ .cwd_relative = thisDir() ++ "/src" });
    exe.root_module.addCSourceFile(.{ .file = .{ .cwd_relative = thisDir() ++ "/fizzy_zip_libc.c" }, .flags = &wasm_c_flags });
    exe.root_module.addCSourceFile(.{ .file = .{ .cwd_relative = thisDir() ++ "/fizzy_zip_strings.c" }, .flags = &wasm_c_flags });
    exe.root_module.addCSourceFile(.{ .file = .{ .cwd_relative = thisDir() ++ "/src/zip.c" }, .flags = &wasm_c_flags });
}

inline fn thisDir() []const u8 {
    return comptime std.fs.path.dirname(@src().file) orelse ".";
}
