/// Discrete tab widths shown as a dropdown in the shell settings pane.
pub const TabSize = enum(u8) {
    @"2" = 2,
    @"4" = 4,
    @"8" = 8,
};

insert_spaces_on_tab: bool = true,
tab_size: TabSize = .@"4",
/// Typing `{`, `(`, `[`, or a quote also inserts its closer (and typing the closer steps over
/// it, Backspace between an empty pair removes both, and typing an opener with text selected
/// wraps it) — VSCode's `editor.autoClosingBrackets`, exposed for the same reason it is there:
/// it's the one baseline editing nicety a sizable minority actively dislikes.
auto_close_brackets: bool = true,
/// When true, `saveDocument` reformats the document (via the active `LanguageSupport.format`
/// provider for its extension, if any) immediately before writing it to disk.
format_on_save: bool = false,
