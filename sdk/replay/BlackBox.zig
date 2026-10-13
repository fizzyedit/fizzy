//! The black box: the last minute of what a dvui app was handed, kept frame by frame for almost
//! nothing, and written out on demand as a stretch that replays exactly (plans/RECORDER_PLAN.md).
//!
//! Fed once a frame (`record`), right after the window begins and any player has added its input
//! (the point the player injects at), so what it keeps is exactly what the app's widgets saw: the
//! person's input and any tape's. Each dvui event becomes a fixed record in `tape.events`' rings:
//! pointer motion and buttons where they were, in the window's pixels, wheel ticks, keys down,
//! repeated and up with their modifiers, text as it arrived. Focus and position events are left
//! out: dvui makes them from the others, and a replay's dvui will again. A frame costs a copy of its
//! events (ReleaseFast, measured: 0.5 ns a frame with none, 5 ns with four); the rings are 1.3 MB,
//! made the first time it records.
//!
//! Any dvui app can keep one: dvui and `tape` only. Fizzy writes its stretches as captures
//! (`fizzy.capture`) and replays them (plans/RECORDER_PLAN.md, step 3). A stream that is not dvui's
//! (a game's inputs at its own tick) keeps its own `tape.ring.Ring` beside this one.
const BlackBox = @This();

const std = @import("std");
const dvui = @import("dvui");
const events = @import("tape").events;

ring: ?*events.Ring = null,
/// Recording, or not (a setting): while off nothing is kept, and the rings stay as they were.
on: bool = true,

/// Events past this many in one frame are not kept (a flood of motion from a stuck driver, say).
pub const max_frame_events = 512;

/// Keep this frame's events. Once a frame, after the window begins and before anything reads
/// `dvui.events()`.
pub fn record(self: *BlackBox, gpa: std.mem.Allocator) void {
    if (!self.on) return;
    const ring = self.ring orelse blk: {
        const r = gpa.create(events.Ring) catch return;
        r.* = .{};
        self.ring = r;
        break :blk r;
    };
    var recs: [max_frame_events]events.Event = undefined;
    var payloads: [max_frame_events][]const u8 = undefined;
    var selections: [max_frame_events][16]u8 = undefined;
    var n: usize = 0;
    for (dvui.events()) |*e| {
        if (n == max_frame_events) break;
        recs[n] = toRecord(e) orelse continue;
        payloads[n] = switch (e.evt) {
            .text => |t| switch (t.action) {
                .value => |v| v.txt,
                .selection => |sel| blk: {
                    selections[n] = events.selectionBytes(sel.start, sel.end);
                    break :blk &selections[n];
                },
            },
            else => "",
        };
        n += 1;
    }
    const px = dvui.windowRectPixels();
    ring.appendFrame(.{
        .t_ns = @intCast(dvui.frameTimeNS()),
        .w = @intFromFloat(@max(0, @min(px.w, 65535))),
        .h = @intFromFloat(@max(0, @min(px.h, 65535))),
        .scale = dvui.windowNaturalScale(),
    }, recs[0..n], payloads[0..n]);
}

/// A dvui event as a record, or null for those dvui makes from the others.
fn toRecord(e: *const dvui.Event) ?events.Event {
    return switch (e.evt) {
        .mouse => |me| switch (me.action) {
            .motion => .{ .kind = .motion, .button = @intFromEnum(me.button), .mod = @intFromEnum(me.mod), .x = me.p.x, .y = me.p.y },
            .press => .{ .kind = .press, .button = @intFromEnum(me.button), .mod = @intFromEnum(me.mod), .x = me.p.x, .y = me.p.y },
            .release => .{ .kind = .release, .button = @intFromEnum(me.button), .mod = @intFromEnum(me.mod), .x = me.p.x, .y = me.p.y },
            .wheel_x => |ticks| .{ .kind = .wheel_x, .mod = @intFromEnum(me.mod), .x = ticks },
            .wheel_y => |ticks| .{ .kind = .wheel_y, .mod = @intFromEnum(me.mod), .x = ticks },
            .focus, .position => null,
        },
        .key => |ke| .{
            .kind = switch (ke.action) {
                .down => .key_down,
                .repeat => .key_repeat,
                .up => .key_up,
            },
            .key = @intFromEnum(ke.code),
            .mod = @intFromEnum(ke.mod),
        },
        .text => |t| switch (t.action) {
            .value => |v| .{ .kind = .text, .selected = v.selected },
            .selection => .{ .kind = .text_select },
        },
        .window => |w| .{ .kind = switch (w.action) {
            .close => .window_close,
            .leave => .window_leave,
        } },
        .app => .{ .kind = .app_quit },
    };
}

/// The last `seconds` of the run (all it kept, if less), as `tape.ring` writes a stretch. How many
/// frames went out.
pub fn writeLast(self: *const BlackBox, w: *std.Io.Writer, seconds: u32) !u64 {
    const ring = self.ring orelse {
        try events.Ring.writeEmpty(w);
        return 0;
    };
    return ring.writeLast(w, @as(i64, seconds) * std.time.ns_per_s);
}

pub fn deinit(self: *BlackBox, gpa: std.mem.Allocator) void {
    if (self.ring) |r| gpa.destroy(r);
    self.ring = null;
}
