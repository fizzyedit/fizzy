const std = @import("std");

pub fn applyMsvcTranslateCShim(b: *std.Build, roots: []const *std.Build.Step.Compile) !void {
    var seen = std.AutoHashMap(*std.Build.Step.TranslateC, void).init(b.allocator);
    defer seen.deinit();
    for (roots) |root_compile| {
        const graph = root_compile.root_module.getGraph();
        for (graph.modules) |mod| {
            const root_src = mod.root_source_file orelse continue;
            const gen = switch (root_src) {
                .generated => |g| g,
                else => continue,
            };
            const dep_step = gen.file.step;
            if (dep_step.id != .translate_c) continue;
            const tc: *std.Build.Step.TranslateC = @fieldParentPtr("step", dep_step);
            const gop = try seen.getOrPut(tc);
            if (gop.found_existing) continue;
            const rt = tc.target.result;
            if (rt.os.tag != .windows or rt.abi != .msvc) continue;
            // `-I` searches before `-isystem`, so this shim wins over MSVC's <stdint.h>.
            tc.addIncludePath(b.path("src/backend/msvc_translatec_shim"));
            // Pre-define SIZE_MAX so MSVC's stdint.h `#ifndef SIZE_MAX` block — which would
            // otherwise install a `0xff…ui64` literal — skips itself. Belt-and-suspenders
            // to the shim: covers the case where another header includes <stdint.h> through
            // a path that bypasses our shim.
            tc.defineCMacro("SIZE_MAX", switch (rt.ptrBitWidth()) {
                32 => "4294967295U",
                64 => "18446744073709551615ULL",
                else => "UINT_MAX",
            });
        }
    }
}

/// Finds every `Step.TranslateC` reachable from each root compile's Zig module graph and adds
/// MSVC / Windows SDK `-isystem` paths from the zig-libc INI. We walk `Module.getGraph()` (imports)
/// rather than `Step.dependencies`: Zig wires `root_source_file` → `TranslateC` only in
/// `createModuleDependencies`, which runs after `build()` returns, so a step BFS from `Compile`
/// would miss DVUI's `dvui-c` / `sdl3-c` translate steps during Configure.
pub fn applyMsvcIncludesToReachableTranslateC(
    b: *std.Build,
    roots: []const *std.Build.Step.Compile,
    libc_ini_path: []const u8,
) !void {
    // `libc_ini_path` is absolute (resolved via `b.pathFromRoot`), so any Dir works as the base.
    const data = try b.build_root.handle.readFileAlloc(b.graph.io, libc_ini_path, b.allocator, .unlimited);

    var include_dir: ?[]const u8 = null;
    var sys_include_dir: ?[]const u8 = null;
    var line_it = std.mem.splitScalar(u8, data, '\n');
    while (line_it.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \r\t");
        if (std.mem.startsWith(u8, line, "include_dir=")) {
            include_dir = std.mem.trim(u8, line["include_dir=".len..], " \r\t");
        } else if (std.mem.startsWith(u8, line, "sys_include_dir=")) {
            sys_include_dir = std.mem.trim(u8, line["sys_include_dir=".len..], " \r\t");
        }
    }
    if (include_dir == null or sys_include_dir == null) return;

    // `include_dir` points at `.../Windows Kits/10/Include/<ver>/ucrt`. The Windows SDK's
    // um/shared/winrt headers live as siblings of the `ucrt` directory.
    const sdk_inc_root = std.fs.path.dirname(include_dir.?) orelse return;
    const um_dir = try std.fs.path.join(b.allocator, &.{ sdk_inc_root, "um" });
    const shared_dir = try std.fs.path.join(b.allocator, &.{ sdk_inc_root, "shared" });
    const winrt_dir = try std.fs.path.join(b.allocator, &.{ sdk_inc_root, "winrt" });

    var seen_translate_c = std.AutoHashMap(*std.Build.Step.TranslateC, void).init(b.allocator);
    defer seen_translate_c.deinit();

    for (roots) |root_compile| {
        const graph = root_compile.root_module.getGraph();
        for (graph.modules) |mod| {
            const root_src = mod.root_source_file orelse continue;
            const gen = switch (root_src) {
                .generated => |g| g,
                else => continue,
            };
            const dep_step = gen.file.step;
            if (dep_step.id != .translate_c) continue;

            const tc: *std.Build.Step.TranslateC = @fieldParentPtr("step", dep_step);
            const gop = try seen_translate_c.getOrPut(tc);
            if (gop.found_existing) continue;

            const rt = tc.target.result;
            if (rt.os.tag == .windows and rt.abi == .msvc) {
                // `translate-c` has no API to pass `--libc <ini>`, so `-lc` makes Zig
                // auto-detect a system MSVC/SDK install — which fails on a Windows host
                // that has no Visual Studio (we use the .velopack-msvc/ tree instead) with
                // `WindowsSdkNotFound`. Drop `-lc` here: every MSVC/UCRT/SDK include dir is
                // added explicitly below, so the headers still resolve, and the consuming
                // exe links libc itself — the translated bindings don't need their own.
                tc.link_libc = false;
                // Shim + SIZE_MAX define are applied separately by `applyMsvcTranslateCShim`.
                // Order matters: MSVC's own headers first (override Windows SDK declarations
                // when both exist), then UCRT, then the Windows SDK trio.
                tc.addSystemIncludePath(.{ .cwd_relative = sys_include_dir.? });
                tc.addSystemIncludePath(.{ .cwd_relative = include_dir.? });
                tc.addSystemIncludePath(.{ .cwd_relative = um_dir });
                tc.addSystemIncludePath(.{ .cwd_relative = shared_dir });
                tc.addSystemIncludePath(.{ .cwd_relative = winrt_dir });
            }
        }
    }
}
