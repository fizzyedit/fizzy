const std = @import("std");
const t = @import("root.zig");
const Sim = @import("../Sim.zig");

test "a commit clears the provisional run and then types; a cancel types nothing" {
    var sim = Sim.init(std.testing.allocator, .{});
    defer sim.deinit();
    const p = sim.platform();
    const w = try p.openWindow(.{});
    p.setTextInput(w, true);
    t.drain(p);

    // Offsets are bytes: "に" is three of them.
    sim.imeCompose("にほ", 3, 3);
    const run = try t.expectNext(p, w, .ime);
    try std.testing.expectEqualStrings("にほ", run.text);
    try std.testing.expectEqual(@as(u32, 3), run.start);

    sim.imeCommit("日本");
    try std.testing.expectEqualStrings("", (try t.expectNext(p, w, .ime)).text);
    try std.testing.expectEqualStrings("日本", try t.expectNext(p, w, .text));

    sim.imeCompose("か", 0, 3);
    sim.imeCancel();
    try std.testing.expectEqualStrings("か", (try t.expectNext(p, w, .ime)).text);
    try std.testing.expectEqualStrings("", (try t.expectNext(p, w, .ime)).text);
    try t.expectIdle(p);

    // Sim's own policy, not a finding: losing focus mid-composition cancels it.
    const other = try p.openWindow(.{});
    p.raiseWindow(w);
    t.drain(p);
    sim.imeCompose("か", 0, 3);
    _ = p.poll();
    p.raiseWindow(other);
    try std.testing.expectEqualStrings("", (try t.expectNext(p, w, .ime)).text);
    try std.testing.expect(!(try t.expectNext(p, w, .focus)));
}
