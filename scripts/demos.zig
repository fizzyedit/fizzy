//! `zig build demos`: every tape fizzy hosts, in the binary form, deflated, for a page to fetch.
//! The bundled demos (`src/editor/demos/catalog.zig`) are built from their scripts, and each
//! hand-written tape (`docs/demos/*.zon`) is read and written again. Beside them, `index.json`
//! says what each one is, for a page that lists them:
//!
//! ```json
//! [{"name":"tour","title":"A Tour of Fizzy","file":"tour.tape","ms":69449,"live":false}, …]
//! ```
//!
//! `zig build web` puts them in `zig-out/web/demos/`, so each copy of the app on the site serves
//! the tapes built from its own commit (`?demo=demos/tour.tape`). A bundled demo plays without
//! fetching anything (`?demo=tour`); its tape is for a player that is not this build of fizzy.
//!
//! Each tape is read back from the bytes written and must be the tape it was, and is checked as
//! the app checks one (`Tape.Check`): its chords in the keymap's spelling. A tape with steps is
//! refused, since only the app knows which plugins' steps it applies (`Demo.stepsCheck`).
//!
//! Usage: demos <out dir> <tape.zon>...
const std = @import("std");
const tape = @import("tape");
const catalog = @import("demos");

const Tape = tape.Tape;

const check: Tape.Check = .{ .key = struct {
    fn ok(spelled: []const u8) bool {
        _ = tape.chord.parseKeys(spelled, .other) catch return false;
        return true;
    }
}.ok };

const Row = struct { name: []const u8, title: []const u8, file: []const u8, ms: u32, live: bool };

pub fn main(init: std.process.Init) !void {
    const arena = init.arena.allocator();
    const gpa = init.gpa;
    const io = init.io;
    const args = try init.minimal.args.toSlice(arena);
    if (args.len < 2) {
        std.debug.print("usage: demos <out dir> <tape.zon>...\n", .{});
        std.process.exit(2);
    }
    const cwd = std.Io.Dir.cwd();
    try cwd.createDirPath(io, args[1]);
    var out = try cwd.openDir(io, args[1], .{});
    defer out.close(io);

    var rows: std.ArrayList(Row) = .empty;
    for (&catalog.entries) |e| {
        var script: tape.Script = .init(gpa, e.name, e.title);
        script.check = check;
        e.build(&script) catch |err| {
            script.deinit();
            return fail("demo '{s}' did not build: {t}", .{ e.name, err });
        };
        var owned = try script.finish();
        defer owned.deinit();
        try rows.append(arena, try emit(arena, gpa, io, out, rows.items, e.name, owned.tape, false));
    }
    for (args[2..]) |path| {
        const bytes = try cwd.readFileAlloc(io, path, arena, .limited(64 << 20));
        var live = false;
        var owned = Tape.load(gpa, bytes, check) catch |err| switch (err) {
            // A live tape plays on the app as it is, as `Demo.playTape` takes one.
            error.NoKeyframeAtStart => blk: {
                live = true;
                var c = check;
                c.live = true;
                break :blk Tape.load(gpa, bytes, c) catch |e| return fail("{s}: {t}", .{ path, e });
            },
            else => return fail("{s}: {t}", .{ path, err }),
        };
        defer owned.deinit();
        const name = std.fs.path.stem(path);
        try rows.append(arena, try emit(arena, gpa, io, out, rows.items, name, owned.tape, live));
    }

    var index: std.Io.Writer.Allocating = .init(arena);
    try std.json.Stringify.value(rows.items, .{ .whitespace = .indent_2 }, &index.writer);
    try index.writer.writeByte('\n');
    try out.writeFile(io, .{ .sub_path = "index.json", .data = index.written() });
}

/// Write `t` as `<name>.tape` in `out`, having read it back from those bytes. The row is `arena`'s:
/// the tape goes before the index is written.
fn emit(arena: std.mem.Allocator, gpa: std.mem.Allocator, io: std.Io, out: std.Io.Dir, rows: []const Row, name: []const u8, t: Tape, live: bool) !Row {
    for (rows) |r| if (std.mem.eql(u8, r.name, name)) return fail("two tapes are named '{s}'", .{name});
    var bytes: std.Io.Writer.Allocating = .init(arena);
    try tape.binary.write(gpa, t, &bytes.writer, .{ .deflate = true });
    var c = check;
    c.live = live;
    var back = tape.binary.read(gpa, bytes.written(), c) catch |err| return fail("{s}: its tape does not read back: {t}", .{ name, err });
    defer back.deinit();
    if (back.tape.ops.len != t.ops.len or back.tape.duration() != t.duration())
        return fail("{s}: its tape reads back as another", .{name});
    const file = try std.fmt.allocPrint(arena, "{s}.tape", .{name});
    try out.writeFile(io, .{ .sub_path = file, .data = bytes.written() });
    return .{ .name = try arena.dupe(u8, name), .title = try arena.dupe(u8, t.title), .file = file, .ms = t.duration(), .live = live };
}

fn fail(comptime fmt: []const u8, args: anytype) error{DemoFailed} {
    std.debug.print("demos: " ++ fmt ++ "\n", args);
    return error.DemoFailed;
}
