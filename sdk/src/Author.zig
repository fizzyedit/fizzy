//! Who made a change to a document: the person, an agent, a tape, or nobody known
//! (`plans/SHARED_HISTORY_PLAN.md`). The host keeps a step's author by the step's id
//! (`Host.recordStep`); owners never store one.
const std = @import("std");
const Author = @This();

kind: Kind,
/// Which one: the plugin acting, and its own id for the session or connection (the agent
/// plugin's connection, chat's session). Two agents both called "Claude" are two authors.
plugin: []const u8 = "",
session: u64 = 0,
/// As the person reads it: "Claude", "the tour". Display only, never identity.
label: []const u8 = "",

pub const Kind = enum {
    /// Whoever is at the keyboard and pointer. Their steps are never stored: a step with no
    /// author kept is theirs.
    person,
    agent,
    tape,
    /// A step recorded where nobody acts: a missed site, never quietly the person's.
    unattributed,
};

pub const person: Author = .{ .kind = .person };
pub const unattributed: Author = .{ .kind = .unattributed };

/// The same author: kind, plugin and session. The label is not identity.
pub fn same(a: Author, b: Author) bool {
    return a.kind == b.kind and a.session == b.session and std.mem.eql(u8, a.plugin, b.plugin);
}

test "an author is its kind, plugin and session, not its label" {
    const a: Author = .{ .kind = .agent, .plugin = "agent", .session = 1, .label = "Claude" };
    try std.testing.expect(a.same(.{ .kind = .agent, .plugin = "agent", .session = 1, .label = "An agent" }));
    try std.testing.expect(!a.same(.{ .kind = .agent, .plugin = "agent", .session = 2, .label = "Claude" }));
    try std.testing.expect(!a.same(person));
}
