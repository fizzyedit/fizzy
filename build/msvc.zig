const std = @import("std");

/// A C translation that some module's root comes from, for a `*-windows-msvc` target: Zig's own
/// `Step.TranslateC`, or a Run of the `translate-c` package's tool, which is how dvui translates
/// its headers on Zig 0.17. Found through the module graph: a module's generated root names the
/// step that makes it, by index, as `std.Build` itself finds it.
const Translation = union(enum) {
    step: *std.Build.Step.TranslateC,
    tool: *std.Build.Step.Run,

    fn ptrBits(t: Translation) u16 {
        return switch (t) {
            .step => |tc| tc.target.result.ptrBitWidth(),
            // `--target=<arch>-windows-msvc`; every MSVC arch but x86 is 64-bit.
            .tool => |run| if (std.mem.startsWith(u8, toolTarget(run).?, "x86-")) 32 else 64,
        };
    }
};

fn msvcTranslations(b: *std.Build, roots: []const *std.Build.Step.Compile) ![]Translation {
    var seen: std.AutoHashMapUnmanaged(*std.Build.Step, void) = .empty;
    var out: std.ArrayList(Translation) = .empty;
    for (roots) |root_compile| {
        const graph = root_compile.root_module.getGraph();
        for (graph.modules) |mod| {
            const root_src = mod.root_source_file orelse continue;
            const gen = switch (root_src) {
                .generated => |g| g,
                else => continue,
            };
            const owner = b.graph.generated_files.items[@backingInt(gen.index)];
            if ((try seen.getOrPut(b.allocator, owner)).found_existing) continue;
            if (owner.cast(std.Build.Step.TranslateC)) |tc| {
                const rt = tc.target.result;
                if (rt.os.tag == .windows and rt.abi == .msvc) try out.append(b.allocator, .{ .step = tc });
            } else if (owner.cast(std.Build.Step.Run)) |run| {
                const target = toolTarget(run) orelse continue;
                if (std.mem.endsWith(u8, target, "-windows-msvc")) try out.append(b.allocator, .{ .tool = run });
            }
        }
    }
    return out.items;
}

/// The `--target=` a Run of the `translate-c` tool was given, or null for any other Run.
fn toolTarget(run: *std.Build.Step.Run) ?[]const u8 {
    if (run.argv.items.len == 0) return null;
    switch (run.argv.items[0]) {
        .artifact => |a| if (!std.mem.eql(u8, a.artifact.name, "translate-c")) return null,
        else => return null,
    }
    for (run.argv.items) |arg| switch (arg) {
        .bytes => |bytes| if (std.mem.startsWith(u8, bytes, "--target=")) return bytes["--target=".len..],
        else => {},
    };
    return null;
}

pub fn applyMsvcTranslateCShim(b: *std.Build, roots: []const *std.Build.Step.Compile) !void {
    const shim = b.path("src/backend/msvc_translatec_shim");
    for (try msvcTranslations(b, roots)) |t| {
        // Pre-define SIZE_MAX so MSVC's stdint.h `#ifndef SIZE_MAX` block — which would
        // otherwise install a `0xff…ui64` literal — skips itself. Belt-and-suspenders
        // to the shim: covers the case where another header includes <stdint.h> through
        // a path that bypasses our shim.
        const size_max = switch (t.ptrBits()) {
            32 => "4294967295U",
            64 => "18446744073709551615ULL",
            else => "UINT_MAX",
        };
        switch (t) {
            .step => |tc| {
                // `-I` searches before `-isystem`, so this shim wins over MSVC's <stdint.h>.
                tc.addIncludePath(shim);
                tc.defineCMacro("SIZE_MAX", size_max);
            },
            // The tool passes what it does not know to the C front end, after its own `--` too.
            .tool => |run| {
                run.addPrefixedDirectoryArg("-I", shim);
                run.addArg(b.fmt("-DSIZE_MAX={s}", .{size_max}));
            },
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
    // `libc_ini_path` is absolute (resolved against the build root).
    b.dependOnFileContents(b.graph.cwdRelativePath(libc_ini_path));
    const data = try std.Io.Dir.cwd().readFileAlloc(b.graph.io, libc_ini_path, b.allocator, .unlimited);

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

    for (try msvcTranslations(b, roots)) |t| switch (t) {
        .step => |tc| {
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
        },
        // The `translate-c` tool takes the libc file itself and finds MSVC's include dirs in
        // it. Its own flag, so it goes before the `--` that hands the rest to the C front end.
        .tool => |run| {
            const libc_arg: std.Build.Step.Run.Arg = .{ .bytes = b.fmt("--libc={s}", .{libc_ini_path}) };
            const dashdash = for (run.argv.items, 0..) |arg, i| switch (arg) {
                .bytes => |bytes| if (std.mem.eql(u8, bytes, "--")) break i,
                else => {},
            } else run.argv.items.len;
            try run.argv.insert(b.graph.arena, dashdash, libc_arg);
        },
    };
}
