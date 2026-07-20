/// Discrete tab widths shown as a dropdown in the shell settings pane.
pub const TabSize = enum(u8) {
    @"2" = 2,
    @"4" = 4,
    @"8" = 8,
};

insert_spaces_on_tab: bool = true,
tab_size: TabSize = .@"4",
/// When true, `saveDocument` reformats the document (via the active `LanguageSupport.format`
/// provider for its extension, if any) immediately before writing it to disk.
format_on_save: bool = false,
