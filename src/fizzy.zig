const std = @import("std");

/// Shared infrastructure module (gfx, math, fs, platform, paths, the generic
/// dvui hub + widgets). Consumed by fizzy and plugins.
pub const core = @import("core");

pub const version: std.SemanticVersion = .{
    .major = 0,
    .minor = 2,
    .patch = 0,
};

// Other helpers and namespaces
pub const fs = core.fs;
pub const image = core.image;
pub const perf = core.perf;
pub const hitch = core.hitch;
pub const water_surface = core.water_surface;
pub const math = core.math;

pub const Entry = @import("Entry.zig");
pub const Editor = @import("editor/Editor.zig");
pub const Explorer = @import("editor/explorer/Explorer.zig");
pub const Fling = core.Fling;
//pub const Popups = @import("editor/popups/Popups.zig");
pub const Sidebar = @import("editor/Sidebar.zig");
pub const OutputLog = @import("editor/OutputLog.zig");

// The process-wide entry / application-state instances.
//
// Phase 2 of the fizzy-as-a-library work replaced the public mutable globals with accessors.
// Editor-scoped logic now takes an explicit `*Editor` (and reaches the allocator through
// `editor.gpa`); what remains behind these accessors is code that genuinely has no place to
// receive one:
//
//   * OS / dvui callbacks invoked with no context pointer — native file-dialog callbacks
//     (`backend_native.zig`), `Editor.saveAsDialogCallback`, `singleton_native.dispatchPath`,
//     the update-notify install hook.
//   * `Entry.zig` itself, which owns the instance.
//
// Threading a context through those is a separate change (each needs a userdata slot on the
// callback), tracked as the residual of Phase 2. Everything else should take `*Editor`.
var entry_instance: *Entry = undefined;
var editor_instance: *Editor = undefined;

pub fn entry() *Entry {
    return entry_instance;
}

pub fn editor() *Editor {
    return editor_instance;
}

pub fn setInstances(a: *Entry, e: *Editor) void {
    entry_instance = a;
    editor_instance = e;
}

/// Runtime platform detection (`isMacOS()` etc.) that's accurate on wasm web
/// builds, where `builtin.os.tag` is always `.freestanding`.
pub const platform = core.platform;

/// Application layout: regions, splits, tabs and the keyword vocabulary. See
/// src/editor/layout/layout.zig.
pub const layout = @import("editor/layout.zig");

/// Plugin SDK surface
pub const sdk = @import("fizzy_sdk");

/// Custom dvui stuff
pub const dvui = core.dvui;

/// Custom backend stuff. Split per-arch: native uses SDL3 + objc + win32; web (and
/// headless integration tests, which wire dvui's `testing` backend onto a native
/// target) get the no-op stub layer (no window chrome, no native dialogs, no native
/// menu bar). Zig only semantically analyzes the chosen branch, so the wasm build
/// never sees the SDL3 / objc / win32 imports inside `backend/backend_native.zig`,
/// and `@import("backend")` (the dvui backend module) is never touched on wasm,
/// where no module by that name is even wired in.
pub const backend = if (@import("builtin").target.cpu.arch == .wasm32)
    @import("backend/backend_web.zig")
else if (@hasDecl(@import("backend"), "c"))
    @import("backend/backend_native.zig")
else
    @import("backend/backend_web.zig");

pub const paths = core.paths;

/// Returns a `std.process.Environ` populated from the libc `environ` global.
/// Used to bridge APIs (like `known-folders.getPath`) that require an
/// `Environ.Map` constructed from the parent process's environment.
pub fn processEnviron() std.process.Environ {
    if (comptime @import("builtin").target.cpu.arch == .wasm32) {
        const empty: [:null]const ?[*:0]const u8 = &.{};
        return .{ .block = .{ .slice = empty } };
    }
    if (@import("builtin").os.tag == .windows) {
        return .{ .block = .global };
    }
    var n: usize = 0;
    while (std.c.environ[n] != null) : (n += 1) {}
    const slice: [:null]const ?[*:0]const u8 = @as([*:null]const ?[*:0]const u8, @ptrCast(std.c.environ))[0..n :null];
    return .{ .block = .{ .slice = slice } };
}
