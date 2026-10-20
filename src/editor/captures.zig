//! Captures: a stretch of the black box written out, with what the profiler saw over it and what
//! the app was built from (plans/RECORDER_PLAN.md), for a replay to run and a person or an agent to
//! read. A directory under `<config>/captures/`, named by when and why:
//!
//! - `input.bin`: the frames and their events (`tape.events`), exactly as the app was handed them.
//! - `report.zon`: the profiler's report over the stretch: the frame, owners, scopes, the last
//!   30 s, the frames over budget, frame causes and spans, as far as the profiler was recording.
//! - `meta.zon`: the app's version and build, the platform, each plugin's id, version and how it
//!   is in the app, the window, why the capture was made and how much it holds.
//!
//! What it does not hold yet is the state the stretch starts from (plan step 2): until then a
//! capture replays faithfully only from a fresh start.
const std = @import("std");
const builtin = @import("builtin");
const dvui = @import("dvui");
const fizzy = @import("../fizzy.zig");
const Editor = @import("Editor.zig");

pub const Written = struct {
    path: []const u8,
    frames: u64,
    seconds: u32,
};

/// Write the last `seconds` of the run as a capture, made because of `why` ("asked", "hitch").
/// Its directory's path, in the frame's arena.
pub fn write(editor: *Editor, seconds: u32, why: []const u8) !Written {
    if (comptime builtin.target.cpu.arch == .wasm32) return error.NoFileSystem;
    const arena = dvui.currentWindow().arena();
    const io = dvui.io;
    const cwd = std.Io.Dir.cwd();

    // `<when>-<why>`, the reason kept to letters, digits and dashes.
    var why_buf: [32]u8 = undefined;
    var n: usize = 0;
    for (why) |c| {
        if (n == why_buf.len) break;
        why_buf[n] = if (std.ascii.isAlphanumeric(c)) std.ascii.toLower(c) else '-';
        n += 1;
    }
    const name = try arena.print("{d}-{s}", .{ std.Io.Clock.real.now(io).toSeconds(), if (n == 0) "asked" else why_buf[0..n] });
    const dir = try std.fs.path.join(arena, &.{ editor.app.config_folder, "captures", name });
    try cwd.createDirPath(io, dir);

    var input: std.Io.Writer.Allocating = .init(arena);
    const frames = try editor.black_box.writeLast(&input.writer, seconds);
    try cwd.writeFile(io, .{ .sub_path = try std.fs.path.join(arena, &.{ dir, "input.bin" }), .data = input.written() });

    var report: std.Io.Writer.Allocating = .init(arena);
    if (fizzy.core.profile.current()) |p| {
        try fizzy.core.profile.report(p, &report.writer, .{
            .over_ms = @as(u32, @min(seconds, 30)) * 1000,
            .hitches = 16,
            .spans = 24,
            .causes = 8,
        });
    } else try report.writer.writeAll(".{}\n");
    try cwd.writeFile(io, .{ .sub_path = try std.fs.path.join(arena, &.{ dir, "report.zon" }), .data = report.written() });

    var meta: std.Io.Writer.Allocating = .init(arena);
    try writeMeta(editor, &meta.writer, arena, why, seconds, frames);
    try cwd.writeFile(io, .{ .sub_path = try std.fs.path.join(arena, &.{ dir, "meta.zon" }), .data = meta.written() });

    dvui.log.info("capture: {d} frames ({d} s asked) written to {s}", .{ frames, seconds, dir });
    return .{ .path = dir, .frames = frames, .seconds = seconds };
}

fn writeMeta(editor: *Editor, w: *std.Io.Writer, arena: std.mem.Allocator, why: []const u8, seconds: u32, frames: u64) !void {
    const Plugin = struct { id: []const u8, version: std.SemanticVersion, link: []const u8 };
    var plugins: std.ArrayList(Plugin) = .empty;
    if (editor.app.host.getServiceTyped(fizzy.sdk.services.plugins.Api)) |svc| {
        for (svc.list(arena) catch &.{}) |info| try plugins.append(arena, .{ .id = info.id, .version = info.version, .link = @tagName(info.link) });
    }
    const px = dvui.windowRectPixels();
    try std.zon.stringify.serialize(.{
        .why = why,
        .seconds = seconds,
        .frames = frames,
        .fizzy = .{ .version = fizzy.version, .optimize = @tagName(builtin.mode), .os = @tagName(builtin.target.os.tag), .arch = @tagName(builtin.target.cpu.arch) },
        .window = .{ .w = px.w, .h = px.h, .scale = dvui.windowNaturalScale() },
        .plugins = plugins.items,
    }, .{}, w);
    try w.writeByte('\n');
}
