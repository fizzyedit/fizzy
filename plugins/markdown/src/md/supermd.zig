//! SuperMD — Zine's markdown (https://zine-ssg.io/docs/supermd/) — rewritten into the plain
//! markdown it reads as, before the preview parses it.
//!
//! SuperMD is CommonMark plus two things a markdown parser shows as noise:
//!
//!   - a Ziggy frontmatter between `---` lines, which reads as a rule and a run of `.field = …`
//!     text. It becomes a `ziggy` code fence: still there, plainly set apart.
//!   - directives: Scripty expressions in link position, `[text]($link.url('…'))`,
//!     `[]($section.id('hero'))`, `># [Note]($block.attrs('note'))`. Each becomes what it stands
//!     for — a link, an image, or just its text — and a bare section marker disappears.
//!
//! Every line stays on its line: nothing is inserted or joined. The preview maps source lines to
//! blocks (reveal, scroll sync, `block_heights.zig`), so the rewrite must not move any.
//!
//! std-only, so it tests from the app build like the other pure parts of this plugin.
const std = @import("std");

pub fn isSuperMdPath(path: []const u8) bool {
    return std.ascii.endsWithIgnoreCase(path, ".smd");
}

/// The markdown `source` reads as. Caller owns the result.
pub fn toMarkdown(gpa: std.mem.Allocator, source: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    try out.ensureTotalCapacity(gpa, source.len + 32);

    var lines = std.mem.splitScalar(u8, source, '\n');
    var line_no: usize = 0;
    var in_frontmatter = false;
    var fence: ?Fence = null;
    var first = true;
    while (lines.next()) |raw| : (line_no += 1) {
        if (!first) try out.append(gpa, '\n');
        first = false;
        const line = std.mem.trimEnd(u8, raw, "\r");
        const cr = raw[line.len..];

        if (line_no == 0 and std.mem.eql(u8, line, "---")) {
            in_frontmatter = true;
            try out.appendSlice(gpa, "```ziggy");
            try out.appendSlice(gpa, cr);
            continue;
        }
        if (in_frontmatter) {
            if (std.mem.eql(u8, line, "---")) {
                in_frontmatter = false;
                try out.appendSlice(gpa, "```");
            } else try out.appendSlice(gpa, line);
            try out.appendSlice(gpa, cr);
            continue;
        }

        if (fence) |f| {
            if (f.closes(line)) fence = null;
            try out.appendSlice(gpa, raw);
            continue;
        }
        if (Fence.opens(line)) |f| {
            fence = f;
            try out.appendSlice(gpa, raw);
            continue;
        }

        try rewriteLine(gpa, &out, line);
        try out.appendSlice(gpa, cr);
    }
    return out.toOwnedSlice(gpa);
}

const Fence = struct {
    char: u8,
    len: usize,

    fn opens(line: []const u8) ?Fence {
        const t = std.mem.trimStart(u8, line, " ");
        if (line.len - t.len > 3 or t.len < 3) return null;
        const c = t[0];
        if (c != '`' and c != '~') return null;
        var n: usize = 0;
        while (n < t.len and t[n] == c) n += 1;
        return if (n >= 3) .{ .char = c, .len = n } else null;
    }

    fn closes(f: Fence, line: []const u8) bool {
        const t = std.mem.trim(u8, line, " ");
        if (t.len < f.len) return false;
        for (t) |ch| if (ch != f.char) return false;
        return true;
    }
};

/// Rewrites every directive link on one line, leaving inline code alone.
fn rewriteLine(gpa: std.mem.Allocator, out: *std.ArrayList(u8), line: []const u8) !void {
    var i: usize = 0;
    while (i < line.len) {
        const c = line[i];
        if (c == '\\' and i + 1 < line.len) {
            try out.appendSlice(gpa, line[i .. i + 2]);
            i += 2;
            continue;
        }
        if (c == '`') {
            // An inline code span runs to the next run of as many backticks.
            var n: usize = 0;
            while (i + n < line.len and line[i + n] == '`') n += 1;
            const close = std.mem.indexOfPos(u8, line, i + n, line[i .. i + n]) orelse line.len;
            const end = @min(line.len, close + n);
            try out.appendSlice(gpa, line[i..end]);
            i = end;
            continue;
        }
        if (c == '[') {
            if (try directiveAt(gpa, out, line, i)) |end| {
                i = end;
                continue;
            }
        }
        try out.append(gpa, c);
        i += 1;
    }
}

/// If a `[text]($…)` or `[text](<$…>)` directive starts at `open`, writes what it stands for and
/// returns the index just past it.
fn directiveAt(gpa: std.mem.Allocator, out: *std.ArrayList(u8), line: []const u8, open: usize) !?usize {
    // The link text: brackets nest, backslashes escape.
    var depth: usize = 0;
    var j = open;
    const close = while (j < line.len) : (j += 1) {
        switch (line[j]) {
            '\\' => j += 1,
            '[' => depth += 1,
            ']' => {
                depth -= 1;
                if (depth == 0) break j;
            },
            else => {},
        }
    } else return null;
    const rest = line[close + 1 ..];
    const angled = std.mem.startsWith(u8, rest, "(<$");
    if (!angled and !std.mem.startsWith(u8, rest, "($")) return null;

    const expr_start = close + 1 + @as(usize, if (angled) 2 else 1);
    const expr_end = endOfExpression(line, expr_start, angled) orelse return null;
    const text = line[open + 1 .. close];
    const d = Directive.parse(line[expr_start..expr_end]);
    try d.write(gpa, out, text);
    return expr_end + @as(usize, if (angled) 2 else 1);
}

/// Index of the expression's end: the `)` closing the link, or the `>` before it.
fn endOfExpression(line: []const u8, start: usize, angled: bool) ?usize {
    var depth: usize = 0;
    var quote: ?u8 = null;
    var k = start;
    while (k < line.len) : (k += 1) {
        const ch = line[k];
        if (quote) |q| {
            if (ch == '\\') k += 1 else if (ch == q) quote = null;
            continue;
        }
        switch (ch) {
            '\'', '"' => quote = ch,
            '(' => depth += 1,
            ')' => {
                if (depth == 0) return if (angled) null else k;
                depth -= 1;
            },
            '>' => if (angled and depth == 0 and k + 1 < line.len and line[k + 1] == ')') return k,
            else => {},
        }
    }
    return null;
}

/// The parts of a Scripty directive the preview can show.
const Directive = struct {
    kind: Kind = .other,
    /// The first string argument of each method this directive calls.
    url: ?[]const u8 = null,
    page: ?[]const u8 = null,
    sibling: ?[]const u8 = null,
    asset: ?[]const u8 = null,
    ref: ?[]const u8 = null,
    site: bool = false,

    const Kind = enum { section, block, heading, text, link, image, video, audio, code, other };

    fn parse(expr: []const u8) Directive {
        var d: Directive = .{};
        if (expr.len < 2 or expr[0] != '$') return d;
        var i: usize = 1;
        const name_end = std.mem.indexOfAnyPos(u8, expr, i, ".(") orelse expr.len;
        d.kind = std.meta.stringToEnum(Kind, expr[i..name_end]) orelse .other;
        i = name_end;
        // `.method('arg', …)` calls, in any order.
        while (i < expr.len) {
            if (expr[i] != '.') {
                i += 1;
                continue;
            }
            const m_start = i + 1;
            const m_end = std.mem.indexOfScalarPos(u8, expr, m_start, '(') orelse break;
            const method = expr[m_start..m_end];
            const arg = firstStringArg(expr, m_end);
            i = endOfCall(expr, m_end);
            if (eql(method, "url")) d.url = arg;
            if (eql(method, "page")) d.page = arg;
            if (eql(method, "sibling") or eql(method, "sub")) d.sibling = arg;
            if (eql(method, "asset") or eql(method, "siteAsset") or eql(method, "buildAsset")) d.asset = arg;
            if (eql(method, "ref") or eql(method, "unsafeRef")) d.ref = arg;
            if (eql(method, "site")) d.site = true;
        }
        return d;
    }

    fn write(d: Directive, gpa: std.mem.Allocator, out: *std.ArrayList(u8), text: []const u8) !void {
        switch (d.kind) {
            // Structure, not content: its text (a heading's, a block's title) is all that shows.
            .section, .block, .heading, .text, .other => try out.appendSlice(gpa, text),
            .link => {
                try out.append(gpa, '[');
                try out.appendSlice(gpa, text);
                try out.appendSlice(gpa, "](");
                if (d.url) |u| {
                    try out.appendSlice(gpa, u);
                } else if (d.page) |p| {
                    try out.append(gpa, '/');
                    try out.appendSlice(gpa, p);
                    if (p.len > 0) try out.append(gpa, '/');
                } else if (d.sibling) |s| {
                    try out.appendSlice(gpa, s);
                } else if (d.asset) |a| {
                    try out.appendSlice(gpa, a);
                } else if (d.site) {
                    try out.append(gpa, '/');
                }
                if (d.ref) |r| {
                    try out.append(gpa, '#');
                    try out.appendSlice(gpa, r);
                }
                try out.append(gpa, ')');
            },
            .image => {
                try out.appendSlice(gpa, "![");
                try out.appendSlice(gpa, text);
                try out.appendSlice(gpa, "](");
                try out.appendSlice(gpa, d.url orelse d.asset orelse "");
                try out.append(gpa, ')');
            },
            // No player in the preview: a link to the file, named by its caption if it has one.
            .video, .audio, .code => {
                const target = d.url orelse d.asset orelse "";
                try out.append(gpa, '[');
                try out.appendSlice(gpa, if (text.len > 0) text else target);
                try out.appendSlice(gpa, "](");
                try out.appendSlice(gpa, target);
                try out.append(gpa, ')');
            },
        }
    }
};

fn eql(a: []const u8, b: []const u8) bool {
    return std.mem.eql(u8, a, b);
}

/// The contents of the string literal opening the call at `paren`, if there is one.
fn firstStringArg(expr: []const u8, paren: usize) ?[]const u8 {
    var i = paren + 1;
    while (i < expr.len and expr[i] == ' ') i += 1;
    if (i >= expr.len or (expr[i] != '\'' and expr[i] != '"')) return null;
    const q = expr[i];
    const end = std.mem.indexOfScalarPos(u8, expr, i + 1, q) orelse return null;
    return expr[i + 1 .. end];
}

/// Index just past the `)` closing the call at `paren`.
fn endOfCall(expr: []const u8, paren: usize) usize {
    var depth: usize = 0;
    var quote: ?u8 = null;
    var i = paren;
    while (i < expr.len) : (i += 1) {
        const ch = expr[i];
        if (quote) |q| {
            if (ch == q) quote = null;
            continue;
        }
        switch (ch) {
            '\'', '"' => quote = ch,
            '(' => depth += 1,
            ')' => {
                depth -= 1;
                if (depth == 0) return i + 1;
            },
            else => {},
        }
    }
    return expr.len;
}

fn expectRewrite(source: []const u8, expected: []const u8) !void {
    const got = try toMarkdown(std.testing.allocator, source);
    defer std.testing.allocator.free(got);
    try std.testing.expectEqualStrings(expected, got);
    try std.testing.expectEqual(
        std.mem.count(u8, source, "\n"),
        std.mem.count(u8, got, "\n"),
    );
}

test "the frontmatter becomes a ziggy fence, line for line" {
    try expectRewrite(
        "---\n.title = \"Home\",\n.layout = \"index.shtml\",\n---\n\n# Hi\n",
        "```ziggy\n.title = \"Home\",\n.layout = \"index.shtml\",\n```\n\n# Hi\n",
    );
}

test "a --- that is not the first line is an ordinary rule" {
    try expectRewrite("Hi\n\n---\n", "Hi\n\n---\n");
}

test "a bare section marker disappears; one on a heading leaves the heading" {
    try expectRewrite(
        "[]($section.id('hero'))\n\n# [Hello]($section.id('hello'))\n",
        "\n\n# Hello\n",
    );
}

test "links resolve to where they point" {
    try expectRewrite(
        "[Zine]($link.url('https://zine-ssg.io').new(true)) [Docs]($link.page('docs/supermd').ref('intro')) [Up]($link.ref('top'))",
        "[Zine](https://zine-ssg.io) [Docs](/docs/supermd/#intro) [Up](#top)",
    );
}

test "angle-bracketed directives may hold spaces" {
    try expectRewrite(
        "[a link](<$link.page('foo').title('a link to foo')>)",
        "[a link](/foo/)",
    );
}

test "images, blocks and media" {
    try expectRewrite(
        "[A cat]($image.asset('cat.jpg').id('foo'))\n># [Draft]($block.attrs('note'))\n>[]($block.attrs('actions'))\n[]($video.asset('demo.mp4').loop(true))",
        "![A cat](cat.jpg)\n># Draft\n>\n[demo.mp4](demo.mp4)",
    );
}

test "plain markdown links, code and fences are left as they are" {
    try expectRewrite(
        "[GitHub](https://github.com) and `[x]($link.url('y'))`\n```md\n[]($section.id('a'))\n```\n",
        "[GitHub](https://github.com) and `[x]($link.url('y'))`\n```md\n[]($section.id('a'))\n```\n",
    );
}

test "CRLF line endings survive" {
    try expectRewrite("---\r\n.title = \"x\",\r\n---\r\n[a]($link.ref('b'))\r\n", "```ziggy\r\n.title = \"x\",\r\n```\r\n[a](#b)\r\n");
}
