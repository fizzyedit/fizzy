//! Pure keyboard policy resolved from the focused field's hints.
const std = @import("std");
const field_hints = @import("glass").field_hints;

pub const Props = struct {
    kind: enum { text, email, number, url },
    capitalize: enum { none, sentences },
    autocorrect: bool,
    multiline: bool,
};

pub fn props(h: field_hints.Hints) Props {
    return .{
        .kind = switch (h.kind) {
            .text, .code, .search => .text,
            .email => .email,
            .number => .number,
            .url => .url,
        },
        .capitalize = if (h.capitalize orelse (h.kind == .text)) .sentences else .none,
        .autocorrect = h.autocorrect orelse (h.kind == .text),
        .multiline = h.enter == .newline,
    };
}

test "every field kind resolves keyboard policy and enter action" {
    const rows = [_]struct { hint: field_hints.Kind, expected: Props }{
        .{ .hint = .text, .expected = .{ .kind = .text, .capitalize = .sentences, .autocorrect = true, .multiline = true } },
        .{ .hint = .code, .expected = .{ .kind = .text, .capitalize = .none, .autocorrect = false, .multiline = true } },
        .{ .hint = .email, .expected = .{ .kind = .email, .capitalize = .none, .autocorrect = false, .multiline = true } },
        .{ .hint = .number, .expected = .{ .kind = .number, .capitalize = .none, .autocorrect = false, .multiline = true } },
        .{ .hint = .url, .expected = .{ .kind = .url, .capitalize = .none, .autocorrect = false, .multiline = true } },
        .{ .hint = .search, .expected = .{ .kind = .text, .capitalize = .none, .autocorrect = false, .multiline = true } },
    };
    for (rows) |row| {
        for (std.meta.tags(field_hints.Enter)) |enter| {
            var expected = row.expected;
            expected.multiline = enter == .newline;
            try std.testing.expectEqualDeep(expected, props(.{ .kind = row.hint, .enter = enter }));
        }
    }
}

test "explicit correction and capitalization override each kind independently" {
    for (std.meta.tags(field_hints.Kind)) |kind| {
        for ([_]bool{ false, true }) |override| {
            var expected = props(.{ .kind = kind });
            expected.autocorrect = override;
            try std.testing.expectEqualDeep(expected, props(.{ .kind = kind, .autocorrect = override }));
            expected = props(.{ .kind = kind });
            expected.capitalize = if (override) .sentences else .none;
            try std.testing.expectEqualDeep(expected, props(.{ .kind = kind, .capitalize = override }));
        }
    }
}

test "equal hints produce equal properties for the restart guard" {
    const h: field_hints.Hints = .{ .kind = .email, .enter = .done, .capitalize = true, .autocorrect = false };
    const same: field_hints.Hints = .{ .kind = .email, .enter = .done, .capitalize = true, .autocorrect = false };
    try std.testing.expect(std.meta.eql(props(h), props(same)));
    try std.testing.expect(std.meta.eql(props(.{}), props(.{ .autocorrect = true, .capitalize = true })));
    try std.testing.expect(std.meta.eql(props(.{ .kind = .code }), props(.{ .kind = .search })));
    try std.testing.expect(!std.meta.eql(props(h), props(.{})));
}
