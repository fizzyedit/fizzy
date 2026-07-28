//! The text plugin's user settings. Each field is a self-describing `sdk.settings.Value` cell:
//! payload type, default, and the description the shell shows under the setting's name. Read a
//! value with `.get()`.
const sdk = @import("fizzy_sdk");
const settings = sdk.settings;

/// Discrete tab widths shown as a dropdown in the shell settings pane.
pub const TabSize = enum(u8) {
    @"2" = 2,
    @"4" = 4,
    @"8" = 8,
};

insert_spaces_on_tab: settings.Value(bool, .{
    .description = "Insert spaces instead of a tab character when pressing Tab.",
}) = .init(true),

tab_size: settings.Value(TabSize, .{
    .description = "How many columns a tab occupies, and how many spaces one indent level inserts.",
}) = .init(.@"4"),

/// Typing `{`, `(`, `[`, or a quote also inserts its closer (and typing the closer steps over
/// it, Backspace between an empty pair removes both, and typing an opener with text selected
/// wraps it) — VSCode's `editor.autoClosingBrackets`, exposed for the same reason it is there:
/// it's the one baseline editing nicety a sizable minority actively dislikes.
auto_close_brackets: settings.Value(bool, .{
    .description = "Typing an opening bracket or quote also inserts its closer. Typing the " ++
        "closer steps over it, and backspace between an empty pair removes both.",
}) = .init(true),

/// When true, `saveDocument` reformats the document (via the active `LanguageSupport.format`
/// provider for its extension, if any) immediately before writing it to disk.
format_on_save: settings.Value(bool, .{
    .description = "Reformat the document with the language's formatter each time it is saved.",
}) = .init(false),
