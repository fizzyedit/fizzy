//! `<img>` extraction from the raw-HTML nodes md4c hands back untouched.
//!
//! GitHub-flavoured READMEs routinely wrap their hero image in HTML (`<p align="center"><img …>`),
//! which CommonMark preserves verbatim as an HTML block rather than as an `IMAGE` node — so a
//! preview that only walks `![alt](url)` shows the markup and none of the pictures.
//!
//! Deliberately a tag scanner, not an HTML parser. It reads exactly what a markdown preview can
//! act on: the image, the size it asks for, and the alignment its wrapper asks for — a hero image
//! wrapped in `<p align="center">` is centered in every renderer that matters, so dropping the
//! wrapper wholesale left it visibly left-hung. Everything else about the markup is discarded.
//! Kept free of dvui and the parser so it stays directly unit-testable.
const std = @import("std");

/// An `<img>`'s requested size. HTML allows both `width="240"` (CSS pixels) and `width="25%"`.
/// READMEs lean on the percentage form to scale a hero/logo down (pixi's `width="25%"`); the
/// renderer resolves the fraction against the image's *intrinsic* size so the result stays
/// constant as the pane resizes, rather than against the containing block (CSS `%` width).
pub const Dim = union(enum) {
    px: f32,
    /// 0–1, already divided by 100. Applied to the image's natural width/height at draw time.
    fraction: f32,
};

/// Horizontal placement asked for by the image or by the block wrapping it.
pub const Align = enum { left, center, right };

/// One `<img>` worth of what a preview can act on.
pub const Image = struct {
    src: []u8,
    width: ?Dim = null,
    height: ?Dim = null,
    /// From the `<img>`'s own `align`, else the innermost enclosing block that set one
    /// (`<p align="center">`, `<div align="right">`, `<center>`). Null means "no opinion".
    alignment: ?Align = null,
};

/// Tags whose `align` attribute (or, for `<center>`, whose mere presence) an enclosed image
/// inherits. Anything else is transparent for alignment purposes.
fn alignScopeOf(name: []const u8) bool {
    if (std.ascii.eqlIgnoreCase(name, "p")) return true;
    if (std.ascii.eqlIgnoreCase(name, "div")) return true;
    if (std.ascii.eqlIgnoreCase(name, "center")) return true;
    if (name.len == 2 and (name[0] == 'h' or name[0] == 'H') and name[1] >= '1' and name[1] <= '6') return true;
    return false;
}

fn parseAlign(raw: ?[]const u8) ?Align {
    const text = std.mem.trim(u8, raw orelse return null, " \t\r\n");
    if (std.ascii.eqlIgnoreCase(text, "center")) return .center;
    if (std.ascii.eqlIgnoreCase(text, "left")) return .left;
    if (std.ascii.eqlIgnoreCase(text, "right")) return .right;
    return null;
}

/// Every `<img>` in `html`, in document order (allocator-owned, as is the outer slice). Null when
/// there is no usable `<img>` — callers use that to fall back to showing the raw markup.
pub fn collect(html: []const u8, gpa: std.mem.Allocator) ?[]Image {
    var images: std.ArrayList(Image) = .empty;
    errdefer {
        for (images.items) |img| gpa.free(img.src);
        images.deinit(gpa);
    }

    // Alignment is inherited from the innermost enclosing block that set one, so scoped tags
    // push/pop as they open and close. Depth is bounded — a README that nests deeper than this
    // simply stops inheriting, which is a cosmetic loss, not a wrong render.
    var align_stack: [16]?Align = @splat(null);
    var depth: usize = 0;

    var i: usize = 0;
    while (std.mem.indexOfScalarPos(u8, html, i, '<')) |start| {
        i = start + 1;
        const closing = i < html.len and html[i] == '/';
        if (closing) i += 1;

        const name_start = i;
        while (i < html.len and std.ascii.isAlphanumeric(html[i])) i += 1;
        const name = html[name_start..i];
        if (name.len == 0) continue;

        const end = std.mem.indexOfScalarPos(u8, html, i, '>') orelse html.len;
        const attrs = html[i..end];
        const self_closing = std.mem.endsWith(u8, std.mem.trimEnd(u8, attrs, " \t\r\n"), "/");
        i = end;

        if (std.ascii.eqlIgnoreCase(name, "img")) {
            if (closing) continue;
            const src = attrValue(attrs, "src") orelse continue;
            const trimmed = std.mem.trim(u8, src, " \t\r\n");
            if (trimmed.len == 0) continue;

            var inherited: ?Align = null;
            var d = depth;
            while (d > 0) : (d -= 1) {
                if (align_stack[d - 1]) |a| {
                    inherited = a;
                    break;
                }
            }

            const owned = gpa.dupe(u8, trimmed) catch continue;
            images.append(gpa, .{
                .src = owned,
                .width = parseDim(attrValue(attrs, "width")),
                .height = parseDim(attrValue(attrs, "height")),
                .alignment = parseAlign(attrValue(attrs, "align")) orelse inherited,
            }) catch {
                gpa.free(owned);
                continue;
            };
            continue;
        }

        if (!alignScopeOf(name)) continue;
        if (closing) {
            if (depth > 0) depth -= 1;
        } else if (!self_closing and depth < align_stack.len) {
            align_stack[depth] = if (std.ascii.eqlIgnoreCase(name, "center"))
                .center
            else
                parseAlign(attrValue(attrs, "align"));
            depth += 1;
        }
    }

    if (images.items.len == 0) {
        images.deinit(gpa);
        return null;
    }
    return images.toOwnedSlice(gpa) catch {
        for (images.items) |img| gpa.free(img.src);
        images.deinit(gpa);
        return null;
    };
}

/// Free what `collect` returned.
pub fn free(images: []Image, gpa: std.mem.Allocator) void {
    for (images) |img| gpa.free(img.src);
    gpa.free(images);
}

/// `"240"` / `"240px"` → pixels, `"25%"` → fraction. Null for anything else (`auto`, garbage,
/// or a non-positive number), which means "no constraint from the markup".
fn parseDim(raw: ?[]const u8) ?Dim {
    const text = std.mem.trim(u8, raw orelse return null, " \t\r\n");
    if (text.len == 0) return null;

    if (text[text.len - 1] == '%') {
        const n = std.fmt.parseFloat(f32, std.mem.trim(u8, text[0 .. text.len - 1], " \t")) catch return null;
        if (!(n > 0)) return null;
        return .{ .fraction = n / 100 };
    }
    const num = if (std.ascii.endsWithIgnoreCase(text, "px")) text[0 .. text.len - 2] else text;
    const n = std.fmt.parseFloat(f32, std.mem.trim(u8, num, " \t")) catch return null;
    if (!(n > 0)) return null;
    return .{ .px = n };
}

/// Value of `name="…"` / `name='…'` / bare `name=value` within one tag's attribute text
/// (everything after the tag name, up to but excluding `>`). Case-insensitive on the name.
fn attrValue(tag: []const u8, name: []const u8) ?[]const u8 {
    var i: usize = 0;
    while (i < tag.len) {
        while (i < tag.len and (std.ascii.isWhitespace(tag[i]) or tag[i] == '/')) i += 1;
        const name_start = i;
        while (i < tag.len and !std.ascii.isWhitespace(tag[i]) and tag[i] != '=' and tag[i] != '/') i += 1;
        const attr_name = tag[name_start..i];
        if (attr_name.len == 0 and i >= tag.len) break;

        const after_name = i;
        while (i < tag.len and std.ascii.isWhitespace(tag[i])) i += 1;
        if (i >= tag.len or tag[i] != '=') {
            // Valueless attribute (`loading`, `disabled`, …). Resume right after the name so a
            // following `src=` on the same tag is still seen.
            i = @max(after_name, name_start + 1);
            continue;
        }
        i += 1; // '='
        while (i < tag.len and std.ascii.isWhitespace(tag[i])) i += 1;
        if (i >= tag.len) return null;

        var value: []const u8 = undefined;
        if (tag[i] == '"' or tag[i] == '\'') {
            const quote = tag[i];
            i += 1;
            const value_start = i;
            const value_end = std.mem.indexOfScalarPos(u8, tag, i, quote) orelse tag.len;
            value = tag[value_start..value_end];
            i = @min(value_end + 1, tag.len);
        } else {
            const value_start = i;
            while (i < tag.len and !std.ascii.isWhitespace(tag[i])) i += 1;
            value = tag[value_start..i];
        }
        if (std.ascii.eqlIgnoreCase(attr_name, name)) return value;
    }
    return null;
}

const testing = std.testing;

fn expectUrls(html: []const u8, expected: []const []const u8) !void {
    const got = collect(html, testing.allocator);
    if (expected.len == 0) {
        try testing.expect(got == null);
        return;
    }
    const images = got orelse return error.TestExpectedImages;
    defer free(images, testing.allocator);
    try testing.expectEqual(expected.len, images.len);
    for (expected, images) |want, have| try testing.expectEqualStrings(want, have.src);
}

fn firstImage(html: []const u8) !Image {
    const images = collect(html, testing.allocator) orelse return error.TestExpectedImages;
    defer free(images, testing.allocator);
    return .{
        .src = "",
        .width = images[0].width,
        .height = images[0].height,
        .alignment = images[0].alignment,
    };
}

test "pulls src out of a centered hero image block" {
    try expectUrls(
        \\<p align="center">
        \\  <img width="25%" src="https://example.com/hero.png">
        \\</p>
    , &.{"https://example.com/hero.png"});
}

test "handles single quotes, bare values and attribute order" {
    try expectUrls("<img src='a.png'>", &.{"a.png"});
    try expectUrls("<img src=b.png alt=x>", &.{"b.png"});
    try expectUrls("<img alt=\"x\" width=\"10\" src=\"c.png\" />", &.{"c.png"});
}

test "skips a valueless attribute before src" {
    try expectUrls("<img loading src=\"d.png\">", &.{"d.png"});
}

test "collects every image in document order" {
    try expectUrls(
        "<div><img src=\"1.png\"><img src=\"2.png\"></div>",
        &.{ "1.png", "2.png" },
    );
}

test "ignores non-img tags, srcless imgs and empty srcs" {
    try expectUrls("<p>no images here</p>", &.{});
    try expectUrls("<image src=\"x.png\">", &.{});
    try expectUrls("<img alt=\"broken\">", &.{});
    try expectUrls("<img src=\"   \">", &.{});
}

test "reads the requested width as a percentage or a pixel count" {
    try testing.expectEqual(Dim{ .fraction = 0.25 }, (try firstImage("<img width=\"25%\" src=\"a.png\">")).width.?);
    try testing.expectEqual(Dim{ .px = 240 }, (try firstImage("<img src=\"a.png\" width=\"240\">")).width.?);
    try testing.expectEqual(Dim{ .px = 240 }, (try firstImage("<img src=\"a.png\" width=\"240px\">")).width.?);
    try testing.expectEqual(Dim{ .px = 80 }, (try firstImage("<img src=\"a.png\" height=80>")).height.?);
}

test "an absent, non-numeric or non-positive size is no constraint" {
    try testing.expect((try firstImage("<img src=\"a.png\">")).width == null);
    try testing.expect((try firstImage("<img src=\"a.png\" width=\"auto\">")).width == null);
    try testing.expect((try firstImage("<img src=\"a.png\" width=\"0\">")).width == null);
    try testing.expect((try firstImage("<img src=\"a.png\" width=\"-10\">")).width == null);
}

test "an image inherits alignment from the block wrapping it" {
    try testing.expectEqual(Align.center, (try firstImage(
        \\<p align="center">
        \\  <img src="a.png">
        \\</p>
    )).alignment.?);
    try testing.expectEqual(Align.right, (try firstImage("<div align=\"right\"><img src=\"a.png\"></div>")).alignment.?);
    try testing.expectEqual(Align.center, (try firstImage("<center><img src=\"a.png\"></center>")).alignment.?);
    try testing.expectEqual(Align.left, (try firstImage("<p align=\"center\"><img align=\"left\" src=\"a.png\"></p>")).alignment.?);
}

test "alignment does not leak past the block that set it" {
    const images = collect(
        "<p align=\"center\"><img src=\"1.png\"></p><img src=\"2.png\">",
        testing.allocator,
    ) orelse return error.TestExpectedImages;
    defer free(images, testing.allocator);
    try testing.expectEqual(@as(usize, 2), images.len);
    try testing.expectEqual(Align.center, images[0].alignment.?);
    try testing.expect(images[1].alignment == null);
}

test "an unaligned wrapper leaves the image with no opinion" {
    try testing.expect((try firstImage("<p><img src=\"a.png\"></p>")).alignment == null);
    try testing.expect((try firstImage("<img src=\"a.png\">")).alignment == null);
}

test "unterminated tag does not run off the end" {
    try expectUrls("<img src=\"e.png\"", &.{"e.png"});
    try expectUrls("<img src=", &.{});
}
