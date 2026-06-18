//! Pixel-art plugin runtime state (Phase 4 Stage B/D).
//!
//! Owns the pixel-art-specific editor state that used to live as top-level fields
//! on `src/editor/Editor.zig`: the active tools, color/palette state, the open
//! project's pack config, the sprite clipboard, and the background pack-job queue.
//!
//! Each plugin has a `State.zig` holding its live state. The shell still reaches
//! this through `fizzy.pixelart` during migration; plugin code uses `Globals.state`.
const std = @import("std");
const builtin = @import("builtin");
const dvui = @import("dvui");
const assets = @import("assets");
const sdk = @import("sdk");
const Colors = @import("Colors.zig");
const Project = @import("Project.zig");
const Tools = @import("Tools.zig");
const PackJob = @import("PackJob.zig");
const ToolsPane = @import("explorer/tools.zig");
const SpritesPane = @import("explorer/sprites.zig");
const SpritesPanel = @import("panel/sprites.zig");
const Palette = @import("internal/Palette.zig");
pub const Settings = @import("Settings.zig");
pub const Docs = @import("Docs.zig");

const State = @This();

/// A floating sprite cut/copied from the canvas, pasted relative to `offset`.
pub const SpriteClipboard = struct {
    source: dvui.ImageSource,
    offset: dvui.Point,
};

/// The shell host (service locator + per-plugin settings store). Set in `init`.
host: *sdk.Host,

/// Open pixel-art documents (shell `open_files` holds matching `DocHandle`s).
docs: Docs = .{},

/// Pixel-art editing preferences, loaded from the host's per-plugin settings store.
settings: Settings = .{},

tools: Tools,
colors: Colors = .{},

/// Explorer sidebar panes (lifted off the shell `Explorer` in Phase 4 Stage C). The "tools"
/// view (layers + palette) and the "sprites" view (animations/frames) are pixel-art-specific
/// UI state; the shell only routes the registered sidebar view's `draw` to them.
tools_pane: ToolsPane = .{},
sprites_pane: SpritesPane = .{},

/// Sprites cover-flow bottom panel (scroll/fly state; was `editor.panel.sprites`).
sprites_panel: SpritesPanel = .{},

/// Whether the palette pane is pinned open in the tools sidebar (pixel-art UI state).
pinned_palettes: bool = false,
/// Split ratio between the layers list and the palette in the tools sidebar.
layers_ratio: f32 = 0.5,

/// The open project's `.fizproject` pack config, or null when no project folder is open.
project: ?Project = null,

sprite_clipboard: ?SpriteClipboard = null,

/// Background project-pack jobs. Each `Editor.startPackProject` cancels any predecessors and
/// pushes a new job; only the newest job's result is installed. Cancelled jobs are still kept
/// here until their worker observes the flag and publishes `done`, at which point
/// `Editor.processPackJob` reaps them. This way rapid Pack-Project clicks coalesce: only the
/// most recent request produces a visible atlas update.
pack_jobs: std.ArrayListUnmanaged(*PackJob) = .empty,

pub fn init(allocator: std.mem.Allocator, host: *sdk.Host) !State {
    var st: State = .{
        .host = host,
        .settings = Settings.load(host),
        .tools = try .init(allocator),
    };
    st.colors.file_tree_palette = Palette.loadFromBytes(allocator, "fizzy.hex", assets.files.palettes.@"fizzy.hex") catch null;
    st.colors.palette = Palette.loadFromBytes(allocator, "fizzy.hex", assets.files.palettes.@"fizzy.hex") catch null;
    return st;
}

/// Write `.fizproject` while the shell `host` and project folder are still live.
/// Called from `AppDeinit` before `editor.deinit`.
pub fn persistProject(st: *State) void {
    if (comptime builtin.target.cpu.arch == .wasm32) return;
    if (st.project) |*project| {
        project.save() catch {
            dvui.log.err("Failed to save project file", .{});
        };
    }
}

pub fn deinit(st: *State, allocator: std.mem.Allocator) void {
    for (st.pack_jobs.items) |job| {
        // Detached workers still reference each job. Signal cancellation and leak the structs
        // on hard quit — better than a use-after-free if a worker hasn't yet observed it.
        job.cancelled.store(true, .monotonic);
    }
    st.pack_jobs.deinit(allocator);

    if (st.colors.palette) |*palette| palette.deinit();
    if (st.colors.file_tree_palette) |*palette| palette.deinit();

    if (st.project) |*project| {
        project.deinit(allocator);
    }

    st.tools.deinit(allocator);
    st.docs.deinit(allocator);
}
