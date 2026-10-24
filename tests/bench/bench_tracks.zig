//! `zig build bench-tracks` — what a document's track costs (`app.Tracks`): a step recorded, a
//! frame's top with nothing asked of it and with a checkpoint, a replay, and what a session holds.
//!
//! The owner is a stand-in whose document is a plain buffer: taking its state is a copy, applying
//! a step writes the step's bytes in. So this measures the tracks' own work around an owner's,
//! not text's or pixi's encoding (`plans/RECORDING_PLAN.md`; those are measured where they are
//! built). Prints rather than asserts; compare runs at the same `-Doptimize`.
const std = @import("std");
const sdk = @import("fizzy_sdk");
const Tracks = @import("app").Tracks;

fn nowNs() i96 {
    return std.Io.Clock.boot.now(std.testing.io).nanoseconds;
}

/// The bench's own frame clock: a step every 50 ms of it.
var clock_ns: i128 = 0;
fn clock() i128 {
    return clock_ns;
}

/// A document that is a buffer.
var doc_bytes: []u8 = &.{};

const Owner = struct {
    fn capture(_: *anyopaque, _: sdk.DocHandle, allocator: std.mem.Allocator) anyerror![]u8 {
        return allocator.dupe(u8, doc_bytes);
    }
    fn restore(_: *anyopaque, _: sdk.DocHandle, bytes: []const u8) anyerror!void {
        @memcpy(doc_bytes[0..bytes.len], bytes);
    }
    fn fingerprint(_: *anyopaque, _: sdk.DocHandle) u64 {
        return std.hash.Wyhash.hash(0, doc_bytes);
    }
    fn apply(_: *anyopaque, _: sdk.DocHandle, effect: []const u8, _: []const u8, _: u32) anyerror!void {
        const at = std.mem.readInt(u32, effect[0..4], .little) % (doc_bytes.len - effect.len);
        @memcpy(doc_bytes[at..][0..effect.len], effect);
    }
};

var owner_state: u8 = 0;
const owner_vtable: sdk.Plugin.VTable = .{
    .captureDocumentState = Owner.capture,
    .restoreDocumentState = Owner.restore,
    .documentFingerprint = Owner.fingerprint,
    .applyStep = Owner.apply,
};
var owner: sdk.Plugin = .{ .state = &owner_state, .vtable = &owner_vtable, .id = "bench", .display_name = "Bench", .step_format = 1 };

fn doc(id: u64) sdk.DocHandle {
    return .{ .ptr = &owner_state, .owner = &owner, .id = id };
}

/// Record `n` steps of `size` bytes each (a keystroke's ~24, a stroke's ~200), taking the
/// checkpoints they ask for at the next frame's top as the app does.
fn record(tracks: *Tracks, n: usize, size: usize) void {
    var effect: [4096]u8 = undefined;
    var prng: std.Random.DefaultPrng = .init(0x7ac5);
    prng.random().bytes(&effect);
    const rec = tracks.recorder();
    for (0..n) |i| {
        std.mem.writeInt(u32, effect[0..4], @intCast(i * 7919), .little);
        rec.vtable.step(rec.ctx, 1, .{ .kind = .added, .id = i + 1, .effect = effect[0..size] });
        clock_ns += 50 * std.time.ns_per_ms;
        tracks.tick();
    }
}

fn fresh(doc_size: usize) !Tracks {
    std.testing.allocator.free(doc_bytes);
    doc_bytes = try std.testing.allocator.alloc(u8, doc_size);
    @memset(doc_bytes, 0);
    var tracks: Tracks = .init(std.testing.allocator);
    tracks.clock = clock;
    tracks.on = true;
    tracks.opened(doc(1));
    tracks.tick();
    return tracks;
}

const runs = 5;

test "bench tracks: a step, a frame's top, a replay, what a session holds" {
    defer std.testing.allocator.free(doc_bytes);

    std.debug.print("\n{s:>8} {s:>9} {s:>9} | {s:>9} {s:>11} {s:>11} | {s:>9} {s:>12}\n", .{
        "steps", "step B", "doc KB", "ns/step*", "checkpoints", "held KB", "replay ms", "per step",
    });
    for ([_]struct { n: usize, step: usize, doc: usize }{
        .{ .n = 2_000, .step = 24, .doc = 64 << 10 },
        .{ .n = 2_000, .step = 200, .doc = 256 << 10 },
        .{ .n = 20_000, .step = 200, .doc = 256 << 10 },
        .{ .n = 20_000, .step = 200, .doc = 8 << 20 },
    }) |c| {
        var best_step: i96 = std.math.maxInt(i96);
        var best_replay: i96 = std.math.maxInt(i96);
        var checkpoints: usize = 0;
        var held: usize = 0;
        var replayed: usize = 0;
        for (0..runs) |_| {
            var tracks = try fresh(c.doc);
            defer tracks.deinit();
            const t0 = nowNs();
            record(&tracks, c.n, c.step);
            best_step = @min(best_step, nowNs() - t0);
            const track = tracks.trackOf(1).?;
            checkpoints = track.checkpoints.items.len;
            held = tracks.held;
            // A seek to just before the last checkpoint: the furthest a replay has to go, from the
            // state before it.
            const cps = track.checkpoints.items;
            const to = if (cps.len > 0) cps[cps.len - 1].step - 1 else track.steps.items.len;
            const from_step = if (track.stateBefore(to)) |st| st.step else 0;
            replayed = to - from_step;
            const t1 = nowNs();
            try tracks.replayInto(1, doc(2), to);
            best_replay = @min(best_replay, nowNs() - t1);
        }
        const ns_step = @as(f64, @floatFromInt(best_step)) / @as(f64, @floatFromInt(c.n));
        const replay_ms = @as(f64, @floatFromInt(best_replay)) / std.time.ns_per_ms;
        std.debug.print("{d:>8} {d:>9} {d:>9} | {d:>9.0} {d:>11} {d:>11} | {d:>9.3} {d:>9.0} ns\n", .{
            c.n, c.step, c.doc >> 10, ns_step, checkpoints, held >> 10, replay_ms, replay_ms * std.time.ns_per_ms / @as(f64, @floatFromInt(@max(replayed, 1))),
        });
    }

    // One checkpoint at a frame's top, by the document's size: the copy a frame pays for it.
    for ([_]usize{ 64 << 10, 1 << 20, 8 << 20 }) |size| {
        var best: i96 = std.math.maxInt(i96);
        for (0..runs) |_| {
            var tracks = try fresh(size);
            defer tracks.deinit();
            const rec = tracks.recorder();
            var effect: [8]u8 = @splat(1);
            for (0..Tracks.checkpoint_max_steps) |i| rec.vtable.step(rec.ctx, 1, .{ .kind = .added, .id = i + 1, .effect = &effect });
            std.debug.assert(tracks.due);
            const t0 = nowNs();
            tracks.tick();
            best = @min(best, nowNs() - t0);
        }
        std.debug.print("a checkpoint of a {d} KB document at a frame's top: {d:.3} ms\n", .{ size >> 10, @as(f64, @floatFromInt(best)) / std.time.ns_per_ms });
    }

    // The first small step after a pause, at a frame's top: the stall a checkpoint taken for it
    // costs, by the document's size.
    for ([_]usize{ 1 << 20, 8 << 20, 32 << 20 }) |size| {
        var best: i96 = std.math.maxInt(i96);
        var taken: usize = 0;
        for (0..runs) |_| {
            var tracks = try fresh(size);
            defer tracks.deinit();
            const rec = tracks.recorder();
            var effect: [100]u8 = @splat(1);
            clock_ns += 60 * std.time.ns_per_s;
            rec.vtable.step(rec.ctx, 1, .{ .kind = .added, .id = 1, .effect = &effect });
            const t0 = nowNs();
            tracks.tick();
            best = @min(best, nowNs() - t0);
            taken = tracks.trackOf(1).?.checkpoints.items.len;
        }
        std.debug.print("one small step after a pause, a {d} KB document, a frame's top: {d:.3} ms ({d} checkpoints)\n", .{ size >> 10, @as(f64, @floatFromInt(best)) / std.time.ns_per_ms, taken });
    }

    std.debug.print("* each step with its share of the checkpoints it asks for\n", .{});

    // A frame's top with nothing asked of it: what every frame pays.
    var tracks = try fresh(64 << 10);
    defer tracks.deinit();
    const idle_frames = 1_000_000;
    const t0 = nowNs();
    for (0..idle_frames) |_| tracks.tick();
    const idle_ns = @as(f64, @floatFromInt(nowNs() - t0)) / idle_frames;
    std.debug.print("a frame's top with nothing asked: {d:.2} ns\n", .{idle_ns});
}
