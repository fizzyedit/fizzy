//! The markdown plugin's user settings. Each field is a self-describing `sdk.settings.Value`
//! cell — see `sdk.settings` for the cell/schema contract.
const sdk = @import("fizzy_sdk");
const settings = sdk.settings;

/// How newly opened markdown documents start in the text editor's preview pane.
pub const DefaultMdView = enum {
    raw,
    split,
    preview,
};

/// How a Zine site's `.smd` files preview — see `md/supermd.zig`.
pub const SuperMdPreview = enum {
    rendered,
    raw,
};

default_md_view: settings.Value(DefaultMdView, .{
    .name = "Markdown Default View",
    .description = "How newly opened markdown documents start: editor only (Raw), editor and " ++
        "preview side by side (Split), or preview only. Clicking Raw, Split, or Preview on a " ++
        "document also updates this.",
}) = .init(.split),

supermd_preview: settings.Value(SuperMdPreview, .{
    .name = "SuperMD Preview",
    .description = "How .smd files (Zine's SuperMD) preview. Rendered shows each directive as " ++
        "what it stands for — a link, an image, a section's heading — and the frontmatter as a " ++
        "code block. Raw previews the file as plain markdown.",
}) = .init(.rendered),
