//! Pixel-art plugin state, lifted off the shell `Editor` (Phase 4 Stage B).
//!
//! Owns the pixel-art-specific editor state that used to live as top-level fields
//! on `src/editor/Editor.zig`: the active tools, color/palette state, the open
//! project's pack config, the sprite clipboard, and the background pack-job queue.
//!
//! Accessed during Stages B–C through the `fizzy.pixelart` global (mirroring the
//! existing `fizzy.packer`). Stage D repoints plugin code at the SDK instead, at
//! which point this struct becomes the plugin's `state` proper rather than a
//! shell-reachable global.
const std = @import("std");
const builtin = @import("builtin");
const fizzy = @import("../../fizzy.zig");
const dvui = @import("dvui");
const assets = @import("assets");

const Colors = @import("Colors.zig");
const Project = @import("Project.zig");
const Tools = @import("Tools.zig");
const PackJob = @import("PackJob.zig");

const PixelArt = @This();

/// A floating sprite cut/copied from the canvas, pasted relative to `offset`.
pub const SpriteClipboard = struct {
    source: dvui.ImageSource,
    offset: dvui.Point,
};

tools: Tools,
colors: Colors = .{},

/// The open project's `.fizproject` pack config, or null when no project folder is open.
project: ?Project = null,

sprite_clipboard: ?SpriteClipboard = null,

/// Background project-pack jobs. Each `Editor.startPackProject` cancels any predecessors and
/// pushes a new job; only the newest job's result is installed. Cancelled jobs are still kept
/// here until their worker observes the flag and publishes `done`, at which point
/// `Editor.processPackJob` reaps them. This way rapid Pack-Project clicks coalesce: only the
/// most recent request produces a visible atlas update.
pack_jobs: std.ArrayListUnmanaged(*PackJob) = .empty,

pub fn init(allocator: std.mem.Allocator) !PixelArt {
    var pa: PixelArt = .{
        .tools = try .init(allocator),
    };
    pa.colors.file_tree_palette = fizzy.Internal.Palette.loadFromBytes(allocator, "fizzy.hex", assets.files.palettes.@"fizzy.hex") catch null;
    pa.colors.palette = fizzy.Internal.Palette.loadFromBytes(allocator, "fizzy.hex", assets.files.palettes.@"fizzy.hex") catch null;
    return pa;
}

pub fn deinit(pa: *PixelArt, allocator: std.mem.Allocator) void {
    for (pa.pack_jobs.items) |job| {
        // Detached workers still reference each job. Signal cancellation and leak the structs
        // on hard quit — better than a use-after-free if a worker hasn't yet observed it.
        job.cancelled.store(true, .monotonic);
    }
    pa.pack_jobs.deinit(allocator);

    if (pa.colors.palette) |*palette| palette.deinit();
    if (pa.colors.file_tree_palette) |*palette| palette.deinit();

    if (pa.project) |*project| {
        // Wasm: skip project.save() — it walks std.Io.Dir.cwd() which pulls in
        // posix.AT (unavailable on freestanding). Browser tabs have no
        // persistent on-disk project anyway.
        if (comptime builtin.target.cpu.arch != .wasm32) {
            project.save() catch {
                dvui.log.err("Failed to save project file", .{});
            };
        }
        project.deinit(allocator);
    }

    pa.tools.deinit(allocator);
}
