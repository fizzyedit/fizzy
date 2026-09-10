//! Tree-sitter syntax highlighting via the Host `LanguageSupport` registry.
const std = @import("std");
const sdk = @import("fizzy_sdk");

pub fn treeSitterOption(path: []const u8) ?sdk.language.TreeSitterHighlight {
    const ext = std.fs.path.extension(path);
    return sdk.host().treeSitterHighlightFor(ext);
}
