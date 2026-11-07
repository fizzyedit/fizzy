//! The demos this application ships with. Fizzy the shell knows how to play a demo and lists
//! whatever is registered at startup; this is Fizzy's own app's list, registered by `Entry` when
//! `AppInfo.is_fizzy`. An app built on fizzy has no list of its own yet: it adds a demo through a
//! plugin, which registers a tape with `Host.registerDemo` (the app-side hook is the `TODO(seam)`
//! in `Entry.AppInit`).
//!
//! Each entry is a script (`tape.Script`) built when it is played, so it reads the keymap and
//! window it plays in rather than the ones it was written against. A row with a `menu_title` also
//! gets a Help row (`fizzy.demo.<name>`); every entry gets a palette command, `FIZZY_DEMO=<name>`
//! natively and `?demo=<name>` on the web. What a script can aim at is in `docs/AUTOMATION.md`.
//!
//! They need nothing but `tape`, so `zig build demos` builds them on the host too, into the tapes
//! the site's copies of the app serve beside themselves (`scripts/demos.zig`).
const Script = @import("tape").Script;

pub const Entry = struct {
    /// Stable id: the command's suffix, the web's `?demo=`, the mount `demo://<name>`.
    name: []const u8,
    title: []const u8,
    // lint-allow(anyerror): the one `Script.finish` error surface, shared by every app demo.
    build: *const fn (s: *Script) anyerror!void,
    /// Help row title, when the demo is the app's tour. Left out: palette only.
    menu_title: ?[:0]const u8 = null,
    /// SF Symbol name for the Help row's macOS item.
    menu_symbol: ?[:0]const u8 = null,
};

pub const entries = [_]Entry{
    .{
        .name = "tour",
        .title = "A Tour of Fizzy",
        .build = @import("demos/tour.zig").build,
        .menu_title = "Take the Tour",
        .menu_symbol = "play.circle",
    },
    .{
        .name = "markdown",
        .title = "Markdown, Previewed as You Type",
        .build = @import("demos/markdown.zig").build,
    },
};

/// The anchor names and helpers a script aims at (`docs/AUTOMATION.md`), re-exported beside the
/// entries so an app demo script can use the same names.
pub const anchors = @import("demos/catalog.zig");
