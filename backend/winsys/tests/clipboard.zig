const std = @import("std");
const t = @import("root.zig");
const Sim = @import("../Sim.zig");

test "the app's own write moves the serial without an event, another program's sends one" {
    var sim = Sim.init(std.testing.allocator, .{});
    defer sim.deinit();
    const p = sim.platform();
    const a = std.testing.allocator;
    const w = try p.openWindow(.{});
    t.drain(p);

    try std.testing.expect(try p.clipboardText(a) == null);
    const before = p.clipboardSerial().serial;
    try p.setClipboardText("mine");
    try std.testing.expect(p.clipboardSerial().serial != before);
    try t.expectIdle(p);

    sim.copyFromOutside("theirs");
    const heard = try t.expectNext(p, w, .clipboard);
    try std.testing.expectEqual(p.clipboardSerial().serial, heard.serial);
    const got = (try p.clipboardText(a)).?;
    defer a.free(got);
    try std.testing.expectEqualStrings("theirs", got);
}
