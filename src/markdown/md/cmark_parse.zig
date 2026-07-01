const std = @import("std");

pub const c = @cImport({
    @cInclude("cmark_headers.h");
});

/// Declared in `src/registry.h` (not all public headers re-export it).
pub extern fn cmark_list_syntax_extensions(mem: *c.cmark_mem) ?*c.cmark_llist;

pub const Node = struct {
    n: *c.cmark_node,

    pub fn firstChild(n: Node) ?Node {
        const ptr = c.cmark_node_first_child(n.n) orelse return null;
        return .{ .n = ptr };
    }

    pub fn nextSibling(n: Node) ?Node {
        const ptr = c.cmark_node_next(n.n) orelse return null;
        return .{ .n = ptr };
    }

    pub fn nodeType(n: Node) c.cmark_node_type {
        return c.cmark_node_get_type(n.n);
    }

    pub fn typeString(n: Node) [:0]const u8 {
        const s = c.cmark_node_get_type_string(n.n) orelse return "";
        return std.mem.span(s);
    }

    pub fn literal(n: Node) ?[:0]const u8 {
        const ptr = c.cmark_node_get_literal(n.n) orelse return null;
        return std.mem.span(ptr);
    }

    pub fn linkUrl(n: Node) ?[:0]const u8 {
        const ptr = c.cmark_node_get_url(n.n) orelse return null;
        return std.mem.span(ptr);
    }

    pub fn linkTitle(n: Node) ?[:0]const u8 {
        const ptr = c.cmark_node_get_title(n.n) orelse return null;
        const s = std.mem.span(ptr);
        if (s.len == 0) return null;
        return s;
    }

    pub fn fenceInfo(n: Node) ?[:0]const u8 {
        const ptr = c.cmark_node_get_fence_info(n.n) orelse return null;
        return std.mem.span(ptr);
    }

    pub fn headingLevel(n: Node) i32 {
        return c.cmark_node_get_heading_level(n.n);
    }

    pub const ListKind = enum { ul, ol };

    pub fn listKind(n: Node) ListKind {
        return switch (c.cmark_node_get_list_type(n.n)) {
            c.CMARK_BULLET_LIST => .ul,
            c.CMARK_ORDERED_LIST => .ol,
            else => .ul,
        };
    }

    pub fn listStart(n: Node) i32 {
        return c.cmark_node_get_list_start(n.n);
    }

    pub fn tableRowIsHeader(n: Node) bool {
        return c.cmark_gfm_extensions_get_table_row_is_header(n.n) != 0;
    }

    pub fn taskListItemChecked(n: Node) bool {
        return c.cmark_gfm_extensions_get_tasklist_item_checked(n.n);
    }
};

pub const CMarkAst = struct {
    root: Node,
    extensions: ?*c.cmark_llist,
};

pub fn parseMarkdown(src: []const u8) ?CMarkAst {
    const extensions = blk: {
        c.cmark_gfm_core_extensions_ensure_registered();
        break :blk cmark_list_syntax_extensions(c.cmark_get_arena_mem_allocator());
    };

    const options = c.CMARK_OPT_DEFAULT | c.CMARK_OPT_SAFE | c.CMARK_OPT_SMART | c.CMARK_OPT_FOOTNOTES;
    const parser = c.cmark_parser_new(options) orelse return null;
    defer c.cmark_parser_free(parser);

    _ = c.cmark_parser_attach_syntax_extension(parser, c.cmark_find_syntax_extension("table"));
    _ = c.cmark_parser_attach_syntax_extension(parser, c.cmark_find_syntax_extension("strikethrough"));
    _ = c.cmark_parser_attach_syntax_extension(parser, c.cmark_find_syntax_extension("tasklist"));
    _ = c.cmark_parser_attach_syntax_extension(parser, c.cmark_find_syntax_extension("autolink"));

    c.cmark_parser_feed(parser, src.ptr, @intCast(src.len));
    const root_ptr = c.cmark_parser_finish(parser) orelse return null;
    return .{
        .root = .{ .n = root_ptr },
        .extensions = extensions,
    };
}

pub fn freeCachedRoot(ptr: ?*anyopaque) void {
    if (ptr) |p| {
        const n: *c.cmark_node = @ptrCast(@alignCast(p));
        c.cmark_node_free(n);
    }
}
