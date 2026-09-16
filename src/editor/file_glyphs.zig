//! Fizzy's kind → glyph table.
//!
//! Plugins declare what *kind* a file is (`Host.FileKind` — "image", "source", …); this decides
//! what that looks like *in fizzy*. A different app built on fizzy ships a different table, or
//! none, without any plugin changing.
//!
//! It lives in exactly one place on purpose. The file tree and the tab bar are drawn by entirely
//! separate code — different files, and in the tree's case a different plugin — and they have to
//! show the same file the same way, which they do because they read the same table.
const std = @import("std");
const dvui = @import("dvui");

/// The glyph for a declared kind, or null to fall back to the caller's generic icon.
pub fn glyphFor(kind: []const u8) ?[]const u8 {
    const table = .{
        .{ "image", dvui.entypo.image },
        .{ "source", dvui.entypo.code },
        .{ "text", dvui.entypo.document },
        .{ "markdown", dvui.entypo.text_document },
        .{ "archive", dvui.entypo.box },
        .{ "audio", dvui.entypo.note },
        .{ "video", dvui.entypo.video },
    };
    inline for (table) |entry| {
        if (std.mem.eql(u8, kind, entry[0])) return entry[1];
    }
    return null;
}
