//! Experimental region-based shell (plan Phase 1). Selected with `-Dnew-shell`.
//!
//! `-Dshell=` picks which layout function runs. All three load the same plugins; only the
//! layout differs, which is the point — see `minimal.zig` and `studio.zig`.
//!
//! These are **shipped shapes, meant to be copied**, on dvui's model for widgets: an app either
//! picks one as-is and writes no layout code at all, or copies the one closest to what it wants
//! into its own source and edits it. Each is ordinary code over the public `Frame` API — a
//! couple of dozen lines — so copying is editing, not forking.
const build_opts = @import("build_opts");
const dvui = @import("dvui");
const fizzy = @import("../../fizzy.zig");

pub const Frame = @import("Frame.zig");
pub const layout_split = @import("split.zig");
pub const widgets = @import("widgets.zig");

pub const ide = @import("ide.zig");
pub const minimal = @import("minimal.zig");
pub const studio = @import("studio.zig");

/// Run the selected app layout.
pub fn layout(editor: *fizzy.Editor, f: *Frame) !dvui.App.Result {
    return switch (build_opts.shell) {
        .ide => ide.layout(editor, f),
        .minimal => minimal.layout(editor, f),
        .studio => studio.layout(editor, f),
    };
}
