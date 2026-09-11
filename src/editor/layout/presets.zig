//! The shipped layout presets, and the dispatcher that runs the selected one.
//!
//! A preset is **meant to be copied**, on dvui's methodology for widgets: an app picks one as-is
//! and writes no layout code at all, or copies the closest one into its own source and edits it.
//! Each is ordinary code over the public `Layout` API, so copying is editing rather than forking.
//! An app that already has its own file passes `-Dapp-layout=` and this dispatcher calls that
//! instead of a shipped preset — fizzy does not take the file back as a fourth shape.
const fizzy = @import("../../fizzy.zig");
const dvui = @import("dvui");
const build_opts = @import("build_opts");
const Layout = @import("app").layout.Layout;

pub const ide = @import("presets/ide.zig");
pub const minimal = @import("presets/minimal.zig");
pub const studio = @import("presets/studio.zig");

/// Run the app-supplied shape when the consumer passed `-Dapp-layout=`, otherwise the
/// shipped preset `-Dlayout=` selected. An outside package brings its own file; fizzy
/// does not ship that file as a fourth preset.
pub fn run(editor: *fizzy.Editor, layout: *Layout) !dvui.App.Result {
    if (comptime build_opts.has_app_layout) {
        return @import("app_layout").layout(layout);
    }
    return switch (build_opts.layout) {
        .ide => ide.layout(editor, layout),
        .minimal => minimal.layout(editor, layout),
        .studio => studio.layout(editor, layout),
    };
}
