//! The dashboard's demo, a hand-written ZON tape (`docs/AUTOMATION.md`): the Needs-you carousel
//! cycled with its buttons, forward past the last card (which wraps) and back. It aims at the
//! buttons' anchors (`dashboard.next`, `dashboard.prev`), so it plays at any window size, over
//! whatever cards the app's provider has: with the demo provider, three.
pub const name = "dashboard";
pub const title = "The dashboard";

pub const tape =
    \\.{
    \\    .name = "dashboard",
    \\    .title = "The dashboard",
    \\    .keyframes = .{.{ .root = "demo://dashboard" }},
    \\    .chapters = .{.{ .at = 0, .title = "Needs you" }},
    \\    .captions = .{
    \\        .{ .at = 300, .ms = 3200, .title = "Needs you", .text = "One card at a time, whole. Next slides the following one in.", .place = .middle },
    \\        .{ .at = 7100, .ms = 3000, .text = "Past the last card it wraps, and previous goes back.", .place = .middle },
    \\    },
    \\    .ops = .{
    \\        .{ .at = 0, .do = .{ .keyframe = 0 } },
    \\        .{ .at = 0, .do = .{ .wait = .{ .until = .idle } } },
    \\        .{ .at = 0, .do = .{ .command = .{ .id = "dashboard.show" } } },
    \\        .{ .at = 0, .do = .{ .wait = .{ .until = .{ .shown = "dashboard.next" } } } },
    \\        .{ .at = 1200, .ms = 900, .do = .{ .move = .{ .tag = "dashboard.next" } } },
    \\        .{ .at = 2160, .do = .{ .press = .left } },
    \\        .{ .at = 2270, .do = .{ .release = .left } },
    \\        .{ .at = 3200, .ms = 900, .do = .{ .move = .{ .tag = "dashboard.next" } } },
    \\        .{ .at = 4160, .do = .{ .press = .left } },
    \\        .{ .at = 4270, .do = .{ .release = .left } },
    \\        .{ .at = 5200, .ms = 900, .do = .{ .move = .{ .tag = "dashboard.next" } } },
    \\        .{ .at = 6160, .do = .{ .press = .left } },
    \\        .{ .at = 6270, .do = .{ .release = .left } },
    \\        .{ .at = 7200, .ms = 900, .do = .{ .move = .{ .tag = "dashboard.prev" } } },
    \\        .{ .at = 8160, .do = .{ .press = .left } },
    \\        .{ .at = 8270, .do = .{ .release = .left } },
    \\        .{ .at = 9200, .ms = 900, .do = .{ .move = .{ .tag = "dashboard.prev" } } },
    \\        .{ .at = 10160, .do = .{ .press = .left } },
    \\        .{ .at = 10270, .do = .{ .release = .left } },
    \\    },
    \\}
;
