//! The markdown AST the preview renders, built from md4c's push parser.
//!
//! md4c reports a document as a stream of enter/leave events, but the renderer
//! needs random access — walk children, look at a parent, cache a measurement
//! against a node across frames — so this rebuilds a tree from that stream into
//! an arena freed as one block.
//!
//! Three things it does that md4c leaves to the application:
//!
//!   * **Source spans.** md4c reports no line or column for anything. What it
//!     does give is text runs whose pointers fall inside the input buffer, so
//!     every node records the byte span its text covers, and a block's span is
//!     the union of its children's. Spans are what the height table and the
//!     scroll anchor key off, and what tells `[[A]]` from `\[\[A]]` (see
//!     `wikilink_scan.zig`) — a byte range is a strictly better answer than the
//!     line/column pair cmark used to hand us.
//!   * **Entities.** `&amp;` arrives as a verbatim `.entity` run; `md4zig.entity`
//!     resolves it so the literal holds what the reader should see.
//!   * **Text coalescing.** md4c splits a run at every escape and entity. They
//!     are merged back into one `.text` node, so a paragraph of prose is one
//!     node rather than a dozen.
//!   * **Tight list items.** md4c puts a tight item's inlines directly under
//!     the item (cmark wrapped them in a paragraph). The renderer only draws
//!     blocks under an item, so those inlines are wrapped here.

const std = @import("std");
const md4zig = @import("md4zig");

pub const NodeType = enum {
    // Blocks.
    document,
    block_quote,
    list,
    item,
    code_block,
    html_block,
    paragraph,
    heading,
    thematic_break,
    table,
    /// A header row. md4c models the header as a `thead` wrapper around an
    /// ordinary row; the wrapper is flattened away and the row marked instead.
    table_header,
    table_row,
    table_cell,
    footnote_definition,

    // Inlines.
    text,
    softbreak,
    linebreak,
    code,
    html_inline,
    emph,
    strong,
    strikethrough,
    link,
    image,
    footnote_reference,
};

pub const ListKind = enum { ul, ol };

/// One node. Allocated in the tree's arena and never individually freed.
pub const Data = struct {
    type: NodeType,
    parent: ?*Data = null,
    first_child: ?*Data = null,
    last_child: ?*Data = null,
    next: ?*Data = null,

    /// Byte span of the source this node covers, as `[start, end)`. `end == 0`
    /// means "not known" — a node whose subtree produced no text run that could
    /// be located in the input (a bare `---`, an empty list item). Callers must
    /// treat that as "no answer" rather than as an empty span at offset 0.
    start: u32 = 0,
    end: u32 = 0,

    /// `.text`, `.code`, `.html_block`, `.html_inline`: the text to draw, with
    /// entities resolved. Empty for every other type.
    literal: []const u8 = "",
    /// `.link`, `.image`: the destination.
    url: []const u8 = "",
    /// `.code_block`: the fence info string, e.g. `zig` in ```` ```zig ````.
    info: []const u8 = "",
    /// `.heading`: 1-6.
    heading_level: u8 = 0,
    /// `.list`.
    list_kind: ListKind = .ul,
    /// `.list`: the first number of an ordered list.
    list_start: u32 = 1,
    /// `.item`: came from `- [ ]` / `- [x]`.
    is_task: bool = false,
    /// `.item`: the box is ticked. Only meaningful when `is_task`.
    task_checked: bool = false,

    fn hasSpan(self: *const Data) bool {
        return self.end > self.start;
    }
};

/// Byte offset of the start of each source line. Built once per parse (`render_ast.scanNode`),
/// so a node's byte offset can be turned into the line number the scroll anchor is keyed by.
pub const LineIndex = struct {
    /// `starts[i]` is the offset of line `i + 1`. Always begins with 0.
    starts: []const u32,

    pub fn build(gpa: std.mem.Allocator, source: []const u8) !LineIndex {
        var starts: std.ArrayList(u32) = .empty;
        errdefer starts.deinit(gpa);
        try starts.append(gpa, 0);
        for (source, 0..) |b, i| {
            if (b == '\n') try starts.append(gpa, @intCast(i + 1));
        }
        return .{ .starts = try starts.toOwnedSlice(gpa) };
    }

    pub fn deinit(self: *LineIndex, gpa: std.mem.Allocator) void {
        gpa.free(self.starts);
        self.* = .{ .starts = &.{} };
    }

    /// 0-based line number containing `offset`.
    pub fn lineOf(self: LineIndex, offset: u32) u32 {
        const at = std.sort.upperBound(u32, self.starts, offset, struct {
            fn order(key: u32, mid: u32) std.math.Order {
                return std.math.order(key, mid);
            }
        }.order);
        return @intCast(at -| 1);
    }

};

/// A cursor over `Data`. Copied freely; the tree owns the storage.
pub const Node = struct {
    n: *Data,

    pub fn nodeType(self: Node) NodeType {
        return self.n.type;
    }

    pub fn firstChild(self: Node) ?Node {
        return .{ .n = self.n.first_child orelse return null };
    }

    pub fn nextSibling(self: Node) ?Node {
        return .{ .n = self.n.next orelse return null };
    }

    pub fn parent(self: Node) ?Node {
        return .{ .n = self.n.parent orelse return null };
    }

    /// Null rather than empty for a node that carries no text, so callers can
    /// keep the `if (node.literal()) |lit|` shape they had under cmark.
    pub fn literal(self: Node) ?[]const u8 {
        return if (self.n.literal.len == 0) null else self.n.literal;
    }

    pub fn linkUrl(self: Node) ?[]const u8 {
        return if (self.n.url.len == 0) null else self.n.url;
    }

    pub fn fenceInfo(self: Node) ?[]const u8 {
        return if (self.n.info.len == 0) null else self.n.info;
    }

    pub fn headingLevel(self: Node) u8 {
        return self.n.heading_level;
    }

    pub fn listKind(self: Node) ListKind {
        return self.n.list_kind;
    }

    pub fn listStart(self: Node) u32 {
        return self.n.list_start;
    }

    pub fn isTaskListItem(self: Node) bool {
        return self.n.is_task;
    }

    pub fn taskListItemChecked(self: Node) bool {
        return self.n.task_checked;
    }

    /// The source bytes this node covers, or null when its span is unknown.
    pub fn sourceSpan(self: Node, source: []const u8) ?[]const u8 {
        if (!self.n.hasSpan() or self.n.end > source.len) return null;
        return source[self.n.start..self.n.end];
    }

    /// Byte offset of the first source character this node covers. Only
    /// meaningful when `sourceSpan` is non-null.
    pub fn startOffset(self: Node) u32 {
        return self.n.start;
    }

    /// Byte offset one past the last source character this node covers.
    pub fn endOffset(self: Node) u32 {
        return self.n.end;
    }
};

/// A parsed document plus the arena holding it. `deinit` frees every node at
/// once; individual nodes are never freed.
pub const Tree = struct {
    arena: std.heap.ArenaAllocator,
    root: *Data,

    pub fn node(self: *Tree) Node {
        return .{ .n = self.root };
    }
};

/// Parses `source` into a tree allocated from `gpa`. Returns null only on OOM or
/// if md4c aborts, which it does only when a callback fails.
///
/// The tree borrows `source`: literals point into the arena, but source spans
/// index `source` itself, so it must outlive the tree.
pub fn parse(gpa: std.mem.Allocator, source: []const u8) ?*Tree {
    const tree = gpa.create(Tree) catch return null;
    tree.* = .{ .arena = .init(gpa), .root = undefined };
    errdefer {
        tree.arena.deinit();
        gpa.destroy(tree);
    }

    var builder: Builder = .{
        .arena = tree.arena.allocator(),
        .source = source,
    };
    const root = builder.arena.create(Data) catch {
        tree.arena.deinit();
        gpa.destroy(tree);
        return null;
    };
    root.* = .{ .type = .document };
    builder.current = root;
    tree.root = root;

    var parser = md4zig.MD4CParser(Builder).init(.{ .flags = flags });
    parser.parse(&builder, source) catch {
        tree.arena.deinit();
        gpa.destroy(tree);
        return null;
    };
    builder.closeText();
    return tree;
}

pub fn destroy(gpa: std.mem.Allocator, tree: *Tree) void {
    tree.arena.deinit();
    gpa.destroy(tree);
}

/// GitHub's feature set, minus the two md4c extensions that would change how an
/// ordinary document reads: `underline` steals `_emphasis_`, and `wikilinks`
/// would parse `[[A]]` itself, which `wikilink_scan.zig` must do instead because
/// it is the only layer that can tell a real link from an escaped one.
const flags: md4zig.Flags = blk: {
    var f: md4zig.Flags = .github;
    f.underline = false;
    f.wikilinks = false;
    break :blk f;
};

/// Turns md4c's event stream into the tree. One instance per parse.
const Builder = struct {
    arena: std.mem.Allocator,
    source: []const u8,
    current: *Data = undefined,

    /// The node currently accumulating into `text_buf`. md4c splits a run at
    /// every escape and entity, so consecutive runs of the same kind merge into
    /// one node instead of one node each.
    open: ?*Data = null,
    text_buf: std.ArrayList(u8) = .empty,

    /// Depth of `thead` wrappers we are inside, so a `tr` knows to become a
    /// `.table_header`. md4c wraps header rows; cmark-gfm marked them instead,
    /// and the renderer wants the flat shape.
    in_thead: u32 = 0,

    const Error = error{OutOfMemory};

    fn append(self: *Builder, node_type: NodeType) Error!*Data {
        const node = try self.arena.create(Data);
        node.* = .{ .type = node_type, .parent = self.current };
        if (self.current.last_child) |last| {
            last.next = node;
        } else {
            self.current.first_child = node;
        }
        self.current.last_child = node;
        return node;
    }

    /// Widens every ancestor's span to cover `[start, end)`, so a block's span
    /// is the union of the text its subtree produced.
    fn cover(self: *Builder, start: u32, end: u32) void {
        var at: ?*Data = self.current;
        while (at) |node| : (at = node.parent) {
            if (!node.hasSpan()) {
                node.start = start;
                node.end = end;
                continue;
            }
            node.start = @min(node.start, start);
            node.end = @max(node.end, end);
        }
    }

    /// Byte range of a text run inside `source`, or null when md4c handed us a
    /// buffer of its own (it substitutes static strings for some runs) — in
    /// which case there is no source position to record.
    ///
    /// A backslash escape arrives as a one-character run pointing at the escaped
    /// character, so the span is widened back over the backslash. Without that,
    /// `\[\[A]]` and `[[A]]` have identical spans as well as identical literals
    /// and `wikilink_scan.zig` has nothing left to tell them apart by.
    fn spanOf(self: *Builder, run: md4zig.Text) ?struct { u32, u32 } {
        const base = @intFromPtr(self.source.ptr);
        const at = @intFromPtr(run.text.ptr);
        if (at < base or at + run.text.len > base + self.source.len) return null;

        var start: u32 = @intCast(at - base);
        const end: u32 = @intCast(at - base + run.text.len);
        const escapable = run.text_type == .normal and run.text.len == 1 and
            std.ascii.isAscii(run.text[0]) and !std.ascii.isAlphanumeric(run.text[0]) and
            !std.ascii.isWhitespace(run.text[0]);
        if (escapable and start > 0 and self.source[start - 1] == '\\') start -= 1;
        return .{ start, end };
    }

    /// Finishes the open node, if any, moving its buffer into the arena.
    fn closeText(self: *Builder) void {
        const node = self.open orelse return;
        self.open = null;
        node.literal = self.text_buf.toOwnedSlice(self.arena) catch "";
    }

    pub fn enterBlock(self: *Builder, block: md4zig.BlockInfo) Error!void {
        self.closeText();
        const node: *Data = switch (block) {
            // The document node already exists; md4c's footnote section is a
            // wrapper cmark-gfm had no equivalent for, so both are transparent
            // and their children attach to whatever contains them.
            .doc, .footnote_def_section => return,
            // md4c wraps header rows in `thead`; flatten it and mark the rows.
            .thead => {
                self.in_thead += 1;
                return;
            },
            .tbody => return,
            .quote => try self.append(.block_quote),
            .hr => try self.append(.thematic_break),
            .p => try self.append(.paragraph),
            .html => try self.append(.html_block),
            .table => try self.append(.table),
            .tr => try self.append(if (self.in_thead > 0) .table_header else .table_row),
            .th, .td => try self.append(.table_cell),
            .footnote_def => try self.append(.footnote_definition),
            // Not enabled in `flags`, but md4c can still report a blank-line
            // block; nothing renders it, so it gets no node.
            .blank, .admonition => return,
            .ul => try self.append(.list),
            .ol => |d| blk: {
                const node = try self.append(.list);
                node.list_kind = .ol;
                node.list_start = @intCast(d.start);
                break :blk node;
            },
            .li => |d| blk: {
                const node = try self.append(.item);
                node.is_task = d.is_task;
                node.task_checked = d.is_task and (d.task_mark | 0x20) == 'x';
                break :blk node;
            },
            .h => |d| blk: {
                const node = try self.append(.heading);
                node.heading_level = @intCast(d.level);
                break :blk node;
            },
            .code => |d| blk: {
                const node = try self.append(.code_block);
                // The whole info string, as cmark's `fenceInfo` gave it —
                // `code_language.zig` takes the language off the front itself.
                node.info = try self.arena.dupe(u8, d.info.all());
                break :blk node;
            },
        };
        self.current = node;
    }

    pub fn leaveBlock(self: *Builder, block: md4zig.BlockInfo) Error!void {
        self.closeText();
        switch (block) {
            .doc, .footnote_def_section, .tbody, .blank, .admonition => return,
            .thead => {
                self.in_thead -= 1;
                return;
            },
            .li => {
                try self.wrapTightItemInlines(self.current);
                self.current = self.current.parent orelse self.current;
            },
            else => self.current = self.current.parent orelse self.current,
        }
    }

    fn isInline(t: NodeType) bool {
        return switch (t) {
            .text, .softbreak, .linebreak, .code, .html_inline, .emph, .strong, .strikethrough, .link, .image, .footnote_reference => true,
            else => false,
        };
    }

    fn appendChild(parent: *Data, child: *Data) void {
        child.parent = parent;
        child.next = null;
        if (parent.last_child) |last| {
            last.next = child;
        } else {
            parent.first_child = child;
        }
        parent.last_child = child;
    }

    fn coverFromChildren(node: *Data) void {
        var c = node.first_child;
        while (c) |ch| : (c = ch.next) {
            if (!ch.hasSpan()) continue;
            if (!node.hasSpan()) {
                node.start = ch.start;
                node.end = ch.end;
            } else {
                node.start = @min(node.start, ch.start);
                node.end = @max(node.end, ch.end);
            }
        }
    }

    /// md4c emits no `p` for a tight list item. Consecutive inlines become a
    /// paragraph so the renderer (which only draws blocks under an item) sees
    /// the same shape cmark used to give us. Nested lists and other blocks stay
    /// siblings of that paragraph.
    fn wrapTightItemInlines(self: *Builder, item: *Data) Error!void {
        var child = item.first_child;
        item.first_child = null;
        item.last_child = null;

        var para: ?*Data = null;
        while (child) |c| {
            const next = c.next;
            c.next = null;
            if (isInline(c.type)) {
                if (para == null) {
                    const p = try self.arena.create(Data);
                    p.* = .{ .type = .paragraph, .parent = item };
                    appendChild(item, p);
                    para = p;
                }
                appendChild(para.?, c);
            } else {
                if (para) |p| coverFromChildren(p);
                para = null;
                appendChild(item, c);
            }
            child = next;
        }
        if (para) |p| coverFromChildren(p);
    }

    pub fn enterSpan(self: *Builder, span: md4zig.SpanInfo) Error!void {
        self.closeText();
        const node: *Data = switch (span) {
            .em => try self.append(.emph),
            .strong => try self.append(.strong),
            .del => try self.append(.strikethrough),
            .code => try self.append(.code),
            .a => |d| blk: {
                const node = try self.append(.link);
                node.url = try self.arena.dupe(u8, d.href.all());
                break :blk node;
            },
            .img => |d| blk: {
                const node = try self.append(.image);
                node.url = try self.arena.dupe(u8, d.src.all());
                break :blk node;
            },
            .footnote_ref => try self.append(.footnote_reference),
            // Extensions `flags` leaves off, plus wikilinks, which
            // `wikilink_scan.zig` owns. Nothing renders them; their text still
            // flows into the enclosing node.
            .ins, .latexmath, .latexmath_display, .wikilink, .u, .spoiler, .superscript, .subscript, .mark => return,
        };
        self.current = node;
    }

    pub fn leaveSpan(self: *Builder, span: md4zig.SpanInfo) Error!void {
        self.closeText();
        switch (span) {
            .ins, .latexmath, .latexmath_display, .wikilink, .u, .spoiler, .superscript, .subscript, .mark => return,
            else => self.current = self.current.parent orelse self.current,
        }
    }

    /// Which node a run's text belongs on. Verbatim runs land on the node md4c
    /// has already opened — a fenced block, an inline code span and a raw HTML
    /// block all hold their own text — while inline raw HTML has no md4c span of
    /// its own and so gets a node here, as does ordinary prose.
    fn openFor(self: *Builder, run: md4zig.Text) Error!*Data {
        const want: NodeType = switch (run.text_type) {
            .code => if (self.current.type == .code_block) .code_block else .code,
            .html => if (self.current.type == .html_block) .html_block else .html_inline,
            else => .text,
        };
        // Raw HTML inline can interrupt a run of prose with no enter/leave event
        // between them, so a change of kind has to close what is open.
        if (self.open) |node| {
            if (node.type == want) return node;
            self.closeText();
        }
        const node = switch (want) {
            .code_block, .code, .html_block => self.current,
            else => try self.append(want),
        };
        self.open = node;
        return node;
    }

    pub fn textCallback(self: *Builder, run: md4zig.Text) Error!void {
        switch (run.text_type) {
            // A break is its own node and ends whatever text preceded it.
            .br, .softbar => {
                self.closeText();
                const node = try self.append(if (run.text_type == .br) .linebreak else .softbreak);
                if (self.spanOf(run)) |span| {
                    node.start, node.end = span;
                    self.cover(span[0], span[1]);
                }
                return;
            },
            // `latexmathspans` is off, so this cannot arrive; ignore it rather
            // than grow a node type nothing renders.
            .latex => return,
            else => {},
        }

        const node = try self.openFor(run);
        switch (run.text_type) {
            .nullchar => try self.text_buf.appendSlice(self.arena, "\u{FFFD}"),
            .entity => {
                var buf: [md4zig.entity.max_decoded_len]u8 = undefined;
                // An entity md4c's table does not know renders verbatim, which
                // is what CommonMark requires.
                const decoded = md4zig.entity.decode(run.text, &buf);
                try self.text_buf.appendSlice(self.arena, if (decoded) |n| buf[0..n] else run.text);
            },
            else => try self.text_buf.appendSlice(self.arena, run.text),
        }

        if (self.spanOf(run)) |span| {
            node.start = if (node.hasSpan()) @min(node.start, span[0]) else span[0];
            node.end = @max(node.end, span[1]);
            self.cover(span[0], span[1]);
        }
    }
};

const testing = std.testing;

/// Renders the tree as `type[literal]{children}`, which makes both the shape and
/// the coalescing visible in one expectation.
fn dump(node: Node, out: *std.ArrayList(u8), gpa: std.mem.Allocator) !void {
    try out.print(gpa, "{s}", .{@tagName(node.nodeType())});
    if (node.literal()) |lit| try out.print(gpa, "[{s}]", .{lit});
    var child = node.firstChild();
    if (child == null) return;
    try out.appendSlice(gpa, "{");
    while (child) |c| : (child = c.nextSibling()) try dump(c, out, gpa);
    try out.appendSlice(gpa, "}");
}

fn expectTree(source: []const u8, expected: []const u8) !void {
    const gpa = testing.allocator;
    const tree = parse(gpa, source) orelse return error.ParseFailed;
    defer destroy(gpa, tree);
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(gpa);
    try dump(tree.node(), &out, gpa);
    try testing.expectEqualStrings(expected, out.items);
}

test "blocks and inlines" {
    try expectTree("# Hi\n\nHow are *you*!", "document{heading{text[Hi]}paragraph{text[How are ]emph{text[you]}text[!]}}");
}

test "a paragraph split by an escape is still one text node" {
    // md4c reports `\[` as its own run; cmark consolidated those, and the
    // renderer (and `wikilink_scan`) still expect one node per run of prose.
    try expectTree("a \\[b\\] c", "document{paragraph{text[a [b] c]}}");
}

test "entities are resolved into the literal" {
    try expectTree("a &amp; b &#65;", "document{paragraph{text[a & b A]}}");
}

test "an unknown entity stays verbatim" {
    try expectTree("&nope;", "document{paragraph{text[&nope;]}}");
}

test "code and raw html hold their own text" {
    try expectTree("```zig\nx\n```", "document{code_block[x\n]}");
    try expectTree("a `b` c", "document{paragraph{text[a ]code[b]text[ c]}}");
    try expectTree("<div>\nx\n</div>", "document{html_block[<div>\nx\n</div>\n]}");
}

test "inline html interrupting prose closes the text node" {
    try expectTree("a <b> c", "document{paragraph{text[a ]html_inline[<b>]text[ c]}}");
}

test "the thead wrapper is flattened onto the header row" {
    try expectTree(
        "|a|\n|-|\n|b|\n",
        "document{table{table_header{table_cell{text[a]}}table_row{table_cell{text[b]}}}}",
    );
}

test "tight list items wrap their inlines in a paragraph" {
    // md4c does not emit a `p` for a tight item (cmark did). The renderer only
    // draws blocks under an item, so the builder has to restore that shape.
    try expectTree("- a\n- b\n", "document{list{item{paragraph{text[a]}}item{paragraph{text[b]}}}}");
    try expectTree("- hello *world*", "document{list{item{paragraph{text[hello ]emph{text[world]}}}}}");
}

test "a loose list is already wrapped, so wrapping is a no-op" {
    try expectTree("- a\n\n- b\n", "document{list{item{paragraph{text[a]}}item{paragraph{text[b]}}}}");
}

test "a nested tight list stays a sibling of the item's paragraph" {
    try expectTree(
        "- outer\n  - inner\n",
        "document{list{item{paragraph{text[outer]}list{item{paragraph{text[inner]}}}}}}",
    );
}

test "task list items carry their checkbox" {
    const gpa = testing.allocator;
    const tree = parse(gpa, "- [x] done\n- [ ] todo\n") orelse return error.ParseFailed;
    defer destroy(gpa, tree);
    const list = tree.node().firstChild().?;
    const first = list.firstChild().?;
    const second = first.nextSibling().?;
    try testing.expect(first.isTaskListItem() and first.taskListItemChecked());
    try testing.expect(second.isTaskListItem() and !second.taskListItemChecked());
    try testing.expectEqualStrings("done", first.firstChild().?.firstChild().?.literal().?);
    try testing.expectEqualStrings("todo", second.firstChild().?.firstChild().?.literal().?);
}

test "source spans cover the bytes a node came from, escapes included" {
    const gpa = testing.allocator;
    const source = "intro\n\nsee \\[\\[A]] here\n";
    const tree = parse(gpa, source) orelse return error.ParseFailed;
    defer destroy(gpa, tree);

    const second = tree.node().firstChild().?.nextSibling().?;
    try testing.expectEqualStrings("see \\[\\[A]] here", second.sourceSpan(source).?);
    // The literal has the escapes applied, so it differs from the span it came
    // from — which is the whole reason `wikilink_scan` needs both.
    try testing.expectEqualStrings("see [[A]] here", second.firstChild().?.literal().?);
}

test "a block with no locatable text reports no span" {
    const gpa = testing.allocator;
    const tree = parse(gpa, "---\n") orelse return error.ParseFailed;
    defer destroy(gpa, tree);
    try testing.expectEqual(@as(?[]const u8, null), tree.node().firstChild().?.sourceSpan("---\n"));
}
