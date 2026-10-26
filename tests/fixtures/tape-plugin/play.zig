//! A plugin's use of `tape` and `replay`: write a demo with `Script`, ship it as bytes, load it and
//! play it. The same file is tested twice: linked into an app (`build/app.zig`, the imports
//! `plugins.staticModule` gives) and built as a plugin dylib (this directory's `build.zig`, the
//! imports `plugin.create` gives), which is how a plugin's one source builds both ways.
const std = @import("std");
const tape = @import("tape");
const replay = @import("replay");

const Played = struct {
    commands: usize = 0,

    fn sink(self: *Played) tape.Sequencer.Sink {
        return .{ .ctx = self, .vtable = &.{
            .locate = locate,
            .moveTo = moveTo,
            .button = button,
            .scroll = scroll,
            .key = key,
            .text = text,
            .command = command,
            .keyframe = keyframe,
            .holds = holds,
            .failed = failed,
        } };
    }
    fn locate(_: *anyopaque, _: tape.Tape.Target) ?tape.Sequencer.Point {
        return null;
    }
    fn moveTo(_: *anyopaque, _: tape.Sequencer.Point) void {}
    fn button(_: *anyopaque, _: tape.Tape.Button, _: bool) void {}
    fn scroll(_: *anyopaque, _: tape.Tape.Scroll) void {}
    fn key(_: *anyopaque, _: []const u8) void {}
    fn text(_: *anyopaque, _: []const u8) void {}
    fn command(ctx: *anyopaque, cmd: tape.Tape.Command) void {
        const self: *Played = @ptrCast(@alignCast(ctx));
        if (std.mem.eql(u8, cmd.id, "fixture.hello")) self.commands += 1;
    }
    fn keyframe(_: *anyopaque, _: *const tape.Tape.Keyframe) void {}
    fn holds(_: *anyopaque, _: tape.Tape.Until) bool {
        return true;
    }
    fn failed(_: *anyopaque, _: tape.Sequencer.Failure) void {}
};

test "a plugin writes a demo, ships it as bytes, and plays it back" {
    const gpa = std.testing.allocator;
    var script: tape.Script = .init(gpa, "fixture", "Fixture");
    errdefer script.deinit();
    try script.keyframe(.{ .root = "demo://fixture" });
    try script.command("fixture.hello");
    var owned = try script.finish();
    defer owned.deinit();

    const bytes = try tape.binary.encode(gpa, owned.tape, .{});
    defer gpa.free(bytes);
    var loaded = try tape.Tape.load(gpa, bytes, .{});
    defer loaded.deinit();

    var played: Played = .{};
    var seq: tape.Sequencer = .init(&loaded.tape);
    var frames: usize = 0;
    while (!seq.done() and frames < 1_000) : (frames += 1) {
        _ = seq.advance(seq.now + 16, 16, played.sink());
    }
    try std.testing.expectEqual(@as(usize, 1), played.commands);
}

test "replay is the module that drives a window with a tape" {
    // The player takes the tape `tape` made: one `Tape` type on both sides of the import.
    try std.testing.expect(@hasDecl(replay.Player, "play"));
}
