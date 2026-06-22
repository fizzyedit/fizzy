//! Tree-sitter syntax highlighting for the code editor.
//!
//! Capture names in `queries/zig.scm` mirror vscode-zig / Feppz! TextMate scopes.
//! Colors match the Feppz! theme as shown in VS Code/Cursor.
const std = @import("std");
const code = @import("../code.zig");
const dvui = code.dvui;
const wdvui = code.core.dvui;

const SyntaxHighlight = @This();

pub const Language = enum {
    plain,
    zig,
    zon,
    json,
    atlas,

    pub fn fromPath(path: []const u8) Language {
        const ext = std.fs.path.extension(path);
        if (std.ascii.eqlIgnoreCase(ext, ".zig")) return .zig;
        if (std.ascii.eqlIgnoreCase(ext, ".zon")) return .zon;
        if (std.ascii.eqlIgnoreCase(ext, ".json")) return .json;
        if (std.ascii.eqlIgnoreCase(ext, ".atlas")) return .atlas;
        return .plain;
    }
};

/// Editor token colors. More specific capture names must appear later in each slice.
pub const Theme = struct {
    text: dvui.Color,
    line_number: dvui.Color,
    zig_highlights: []const wdvui.TextEntryWidget.SyntaxHighlight,
    json_highlights: []const wdvui.TextEntryWidget.SyntaxHighlight,
};

fn rgb(r: u8, g: u8, b: u8) dvui.Color {
    return .{ .r = r, .g = g, .b = b, .a = 255 };
}

fn hi(name: []const u8, color: dvui.Color) wdvui.TextEntryWidget.SyntaxHighlight {
    return .{ .name = name, .opts = .{ .color_text = color } };
}

// Feppz palette (from Feppz!-color-theme.json + vscode-zig scopes)
const fn_green = rgb(0x4d, 0xa5, 0x86);
const type_orange = rgb(0xd8, 0x8e, 0x79);
const var_yellow = rgb(0xd9, 0xc6, 0x79);
const kw_brown = rgb(0x61, 0x53, 0x53); // keyword.default.zig — const, var
const kw_decl = rgb(0x87, 0x65, 0x60); // pub, fn, struct, storage
const kw_pink = rgb(0xce, 0xa4, 0x7f); // if, for, return, orelse, error, …

pub const feppz: Theme = .{
    .text = rgb(0xdd, 0xdc, 0xd3),
    .line_number = rgb(0x58, 0x58, 0x5f),
    .zig_highlights = &feppz_zig_highlights,
    .json_highlights = &feppz_json_highlights,
};

pub const default_theme = feppz;

const feppz_zig_highlights = [_]wdvui.TextEntryWidget.SyntaxHighlight{
    hi("feppz.comment", rgb(0x57, 0x5b, 0x65)),
    hi("feppz.comment.documentation", rgb(0x7a, 0x7a, 0x78)),

    hi("feppz.punctuation", rgb(0x9c, 0x9d, 0x9d)),
    hi("feppz.punctuation.round", rgb(0x85, 0x87, 0x8a)),
    hi("feppz.punctuation.square", rgb(0x72, 0x75, 0x7b)),
    hi("feppz.punctuation.curly", rgb(0x63, 0x67, 0x6f)),
    hi("feppz.punctuation.accessor", rgb(0x9c, 0x9d, 0x9d)),

    hi("feppz.operator", rgb(0xb9, 0xb9, 0xb5)),

    hi("feppz.string", rgb(0x60, 0xc0, 0xd2)),
    hi("feppz.string.character", rgb(0x60, 0xd2, 0xbe)),
    hi("feppz.string.escape", rgb(0x58, 0x8e, 0x9a)),
    hi("feppz.number", rgb(0x60, 0x9a, 0xd2)),
    hi("feppz.number.float", rgb(0x60, 0x9a, 0xd2)),

    // Variables, namespace path segments (std.mem), struct fields
    hi("feppz.variable", var_yellow),
    hi("feppz.variable.definition", var_yellow),
    hi("feppz.variable.namespace", var_yellow),
    hi("feppz.variable.module", var_yellow),
    hi("feppz.variable.member", var_yellow),
    hi("feppz.variable.enum_member", rgb(0x53, 0x5c, 0x90)),
    hi("feppz.variable.builtin", rgb(0x6a, 0x66, 0x56)),
    hi("feppz.constant", rgb(0x60, 0x74, 0xd2)),
    hi("feppz.label", rgb(0xc8, 0xc8, 0xc8)),

    hi("feppz.entity.name.function", fn_green),
    hi("feppz.support.function.builtin", fn_green),

    // Types: PascalCase names, primitives (u32), anyopaque, …
    hi("feppz.entity.name.type", type_orange),
    hi("feppz.keyword.type", type_orange),

    // Declaration keywords — brown/tan
    hi("feppz.keyword.default", kw_brown),
    hi("feppz.storage.type.function", kw_decl),
    hi("feppz.keyword.structure", kw_decl),
    hi("feppz.keyword.storage", kw_decl),

    // Control flow — pink (return, if, for, orelse, error, …)
    hi("feppz.keyword.control.flow", kw_pink),

    hi("feppz.keyword.constant.default", rgb(0x53, 0x5c, 0x90)),
    hi("feppz.keyword.constant.bool", rgb(0x53, 0x5c, 0x90)),
};

const feppz_json_highlights = [_]wdvui.TextEntryWidget.SyntaxHighlight{
    hi("feppz.comment", rgb(0x57, 0x5b, 0x65)),
    hi("feppz.number", rgb(0x60, 0x9a, 0xd2)),
    hi("feppz.constant", rgb(0x60, 0x74, 0xd2)),
    hi("feppz.string", rgb(0x60, 0xc0, 0xd2)),
    hi("feppz.string.escape", rgb(0x58, 0x8e, 0x9a)),
    hi("feppz.keyword.constant.default", rgb(0x53, 0x5c, 0x90)),
    hi("feppz.string.special.key", rgb(0xb6, 0x77, 0x6b)),
};

const zig_queries = @embedFile("../queries/zig.scm");
const json_queries = @embedFile("../queries/json.scm");

const TreeSitter = if (dvui.useTreeSitter) struct {
    extern fn tree_sitter_zig() callconv(.c) *dvui.c.TSLanguage;
    extern fn tree_sitter_json() callconv(.c) *dvui.c.TSLanguage;

    fn option(
        language: *dvui.c.TSLanguage,
        queries: []const u8,
        highlights: []const wdvui.TextEntryWidget.SyntaxHighlight,
    ) wdvui.TextEntryWidget.InitOptions.TreeSitterOption {
        return .{
            .language = language,
            .queries = queries,
            .highlights = highlights,
        };
    }
} else struct {};

pub fn treeSitterOption(
    path: []const u8,
    theme: Theme,
) ?wdvui.TextEntryWidget.InitOptions.TreeSitterOption {
    if (!dvui.useTreeSitter) return null;
    return switch (Language.fromPath(path)) {
        .zig, .zon => TreeSitter.option(
            TreeSitter.tree_sitter_zig(),
            zig_queries,
            theme.zig_highlights,
        ),
        .json, .atlas => TreeSitter.option(
            TreeSitter.tree_sitter_json(),
            json_queries,
            theme.json_highlights,
        ),
        .plain => null,
    };
}
