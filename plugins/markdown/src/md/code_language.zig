//! Mapping a fenced code block's language tag onto a file extension.
//!
//! Markdown fences name a *language* (```zig, ```bash), while every language-support lookup in
//! the app is keyed by *extension* (`Host.treeSitterHighlightFor(".zig")`). Something has to
//! bridge the two, and this is the whole of it.
//!
//! Deliberately std-only so it can be unit-tested without a window, and deliberately dumb: it
//! knows no grammars and owns no highlighting. The markdown plugin bundles no language support
//! of its own — whether a fence highlights depends entirely on whether some plugin claims that
//! extension, so installing the zig plugin is what makes ```zig light up.
//!
//! If this table ever starts feeling like policy that belongs to the language plugins, the fix
//! is a `supportsLanguageTag` hook on `sdk.LanguageSupport` so a plugin declares its own
//! aliases. That is an SDK change, so it waits until the table actually proves limiting.
const std = @import("std");

/// The extension a fence's info string maps to, including the leading dot, or null when the tag
/// is empty or unrecognised. Unrecognised is not an error — it means "draw it as plain text",
/// which is exactly what an unknown language should do.
pub fn extensionForTag(info: []const u8) ?[]const u8 {
    const tag = firstWord(info);
    if (tag.len == 0) return null;
    if (tag.len > max_tag_len) return null;

    // Lower-cased into a small stack buffer: fences are written ```Zig and ```ZIG as readily as
    // ```zig, and the table would otherwise miss both.
    var buf: [max_tag_len]u8 = undefined;
    const lower = std.ascii.lowerString(buf[0..tag.len], tag);

    for (table) |entry| {
        if (std.mem.eql(u8, entry.tag, lower)) return entry.ext;
    }
    return null;
}

/// The tag is the first whitespace-delimited word of the info string. Fences carry more than the
/// language in the wild — ```zig title="build.zig"`, ```js {1,3-4}` — and everything after the
/// first word is somebody else's convention, not ours.
fn firstWord(info: []const u8) []const u8 {
    const trimmed = std.mem.trim(u8, info, " \t\r\n");
    const end = std.mem.indexOfAny(u8, trimmed, " \t{,:") orelse trimmed.len;
    return trimmed[0..end];
}

const max_tag_len = 24;

const Entry = struct { tag: []const u8, ext: []const u8 };

/// Tag → extension. Only aliases that are genuinely common are worth carrying; a tag nobody
/// writes costs a comparison on every code block and buys nothing.
const table = [_]Entry{
    .{ .tag = "zig", .ext = ".zig" },
    .{ .tag = "c", .ext = ".c" },
    .{ .tag = "h", .ext = ".h" },
    .{ .tag = "cpp", .ext = ".cpp" },
    .{ .tag = "c++", .ext = ".cpp" },
    .{ .tag = "cc", .ext = ".cpp" },
    .{ .tag = "objc", .ext = ".m" },
    .{ .tag = "rust", .ext = ".rs" },
    .{ .tag = "rs", .ext = ".rs" },
    .{ .tag = "go", .ext = ".go" },
    .{ .tag = "python", .ext = ".py" },
    .{ .tag = "py", .ext = ".py" },
    .{ .tag = "javascript", .ext = ".js" },
    .{ .tag = "js", .ext = ".js" },
    .{ .tag = "jsx", .ext = ".jsx" },
    .{ .tag = "typescript", .ext = ".ts" },
    .{ .tag = "ts", .ext = ".ts" },
    .{ .tag = "tsx", .ext = ".tsx" },
    .{ .tag = "java", .ext = ".java" },
    .{ .tag = "kotlin", .ext = ".kt" },
    .{ .tag = "kt", .ext = ".kt" },
    .{ .tag = "swift", .ext = ".swift" },
    .{ .tag = "ruby", .ext = ".rb" },
    .{ .tag = "rb", .ext = ".rb" },
    .{ .tag = "php", .ext = ".php" },
    .{ .tag = "lua", .ext = ".lua" },
    .{ .tag = "sh", .ext = ".sh" },
    .{ .tag = "bash", .ext = ".sh" },
    .{ .tag = "zsh", .ext = ".sh" },
    .{ .tag = "shell", .ext = ".sh" },
    .{ .tag = "json", .ext = ".json" },
    .{ .tag = "yaml", .ext = ".yaml" },
    .{ .tag = "yml", .ext = ".yaml" },
    .{ .tag = "toml", .ext = ".toml" },
    .{ .tag = "zon", .ext = ".zon" },
    .{ .tag = "xml", .ext = ".xml" },
    .{ .tag = "html", .ext = ".html" },
    .{ .tag = "css", .ext = ".css" },
    .{ .tag = "sql", .ext = ".sql" },
    .{ .tag = "markdown", .ext = ".md" },
    .{ .tag = "md", .ext = ".md" },
    .{ .tag = "scm", .ext = ".scm" },
};

const testing = std.testing;

test "a plain tag maps to its extension" {
    try testing.expectEqualStrings(".zig", extensionForTag("zig").?);
    try testing.expectEqualStrings(".sh", extensionForTag("bash").?);
    try testing.expectEqualStrings(".cpp", extensionForTag("c++").?);
}

test "tags are matched case-insensitively" {
    try testing.expectEqualStrings(".zig", extensionForTag("Zig").?);
    try testing.expectEqualStrings(".zig", extensionForTag("ZIG").?);
}

test "only the first word of the info string is the language" {
    // Fences carry more than the language in the wild, and the rest is not ours to interpret.
    try testing.expectEqualStrings(".zig", extensionForTag("zig title=\"build.zig\"").?);
    try testing.expectEqualStrings(".js", extensionForTag("js {1,3-4}").?);
    try testing.expectEqualStrings(".zig", extensionForTag("  zig  ").?);
}

test "an empty or unknown tag has no extension" {
    // Not an error: it means "draw it as plain text", which is what an unknown language should do.
    try testing.expect(extensionForTag("") == null);
    try testing.expect(extensionForTag("   ") == null);
    try testing.expect(extensionForTag("brainfuck") == null);
}

test "an absurdly long tag is rejected rather than overflowing the buffer" {
    const long = "a" ** (max_tag_len + 40);
    try testing.expect(extensionForTag(long) == null);
}
