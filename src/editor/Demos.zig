//! The `demos` service (`sdk.services.demos`): every demo fizzy can play, and playing one. Fizzy's
//! own (`Demo.catalog`) first, then each a plugin registered (`Host.registerDemo`).
//!
//! The list is built when it is first asked for and again only once the host's demos change
//! (`Host.demos_generation`): each bundled script is built once to read its length and chapters,
//! and each plugin's tape is loaded as a demo would be, so one that would not play (a live tape,
//! a step no plugin applies, a name fizzy already has) is left out with a warning rather than
//! listed and then refused.
const Demos = @This();

const std = @import("std");
const dvui = @import("dvui");
const fizzy = @import("../fizzy.zig");
const sdk = fizzy.sdk;
const automation = @import("app").automation;
const Editor = @import("Editor.zig");
const Demo = @import("Demo.zig");

const Api = sdk.services.demos.Api;

editor: *Editor,
/// The value registered (`Host.registerService`), pointing back here.
api: Api = undefined,
/// Holds `infos` and every string and chapter list in them, until the next build.
arena: std.heap.ArenaAllocator,
infos: std.ArrayListUnmanaged(Api.Info) = .empty,
/// The host's demos generation `infos` was built for; null: never built.
built_for: ?u32 = null,
/// What `play` last started, while it is the tape loaded: its name (gpa), and the tape's ops,
/// which no other load shares, to tell it from a tape loaded another way since.
playing: ?struct { name: []u8, ops: [*]const automation.Tape.Op } = null,

/// Inert until `init`: nothing listed, and `deinit` has nothing to free.
pub const detached: Demos = .{ .editor = undefined, .arena = .init(std.heap.page_allocator) };

pub fn init(editor: *Editor) Demos {
    return .{ .editor = editor, .arena = .init(editor.app.gpa) };
}

/// Fill in `api`. `self` must not move afterwards (it is the service's context).
pub fn bind(self: *Demos) void {
    self.api = .{ .ctx = self, .vtable = &vtable };
}

pub fn deinit(self: *Demos) void {
    self.forgetPlaying();
    self.arena.deinit();
}

const vtable: Api.VTable = .{
    .list = list,
    .play = play,
    .current = current,
    .generation = generation,
};

fn from(ctx: *anyopaque) *Demos {
    return @ptrCast(@alignCast(ctx));
}

fn generation(ctx: *anyopaque) u32 {
    return from(ctx).editor.app.host.demos_generation;
}

fn list(ctx: *anyopaque) []const Api.Info {
    const self = from(ctx);
    if (self.built_for != self.editor.app.host.demos_generation) self.build();
    return self.infos.items;
}

fn build(self: *Demos) void {
    _ = self.arena.reset(.retain_capacity);
    self.infos = .empty;
    self.built_for = self.editor.app.host.demos_generation;
    const gpa = self.editor.app.gpa;
    for (&Demo.catalog.entries) |*e| {
        var script: automation.Script = .init(gpa, e.name, e.title);
        script.check = automation.Input.check;
        e.build(&script) catch |err| {
            script.deinit();
            dvui.log.warn("demos: '{s}' did not build: {t}", .{ e.name, err });
            continue;
        };
        var owned = script.finish() catch |err| {
            dvui.log.warn("demos: '{s}' did not build: {t}", .{ e.name, err });
            continue;
        };
        defer owned.deinit();
        self.add(e.name, e.title, owned.tape, .bundled) catch return;
    }
    for (self.editor.app.host.demos.items) |d| {
        if (self.find(d.name) != null) {
            dvui.log.warn("demos: a plugin's demo is named '{s}', as one fizzy has: it is left out", .{d.name});
            continue;
        }
        var owned = Demo.loadDemoTape(gpa, d.tape) catch |err| {
            dvui.log.warn("demos: '{s}' does not play as a demo: {t}", .{ d.name, err });
            continue;
        };
        defer owned.deinit();
        self.add(d.name, d.title, owned.tape, .plugin) catch return;
    }
}

fn add(self: *Demos, name: []const u8, title: []const u8, tape: automation.Tape, origin: Api.Origin) !void {
    const a = self.arena.allocator();
    const chapters = try a.alloc(Api.Chapter, tape.chapters.len);
    for (tape.chapters, chapters) |c, *out| out.* = .{ .at = c.at, .title = try a.dupe(u8, c.title) };
    try self.infos.append(a, .{
        .name = try a.dupe(u8, name),
        .title = try a.dupe(u8, title),
        .ms = tape.duration(),
        .chapters = chapters,
        .origin = origin,
    });
}

fn find(self: *const Demos, name: []const u8) ?*const Api.Info {
    for (self.infos.items) |*i| if (std.mem.eql(u8, i.name, name)) return i;
    return null;
}

fn play(ctx: *anyopaque, name: []const u8, at_ms: u32) Api.Play {
    const self = from(ctx);
    _ = list(ctx);
    const info = self.find(name) orelse return .unknown;
    const demo = &self.editor.demo;
    const ready = demo.startable();
    if (ready != .started) return ready;
    switch (info.origin) {
        .bundled => demo.play(info.name) catch return .unknown,
        .plugin => {
            const d = for (self.editor.app.host.demos.items) |d| {
                if (std.mem.eql(u8, d.name, info.name)) break d;
            } else return .unknown;
            demo.playTape(d.tape) catch return .unknown;
        },
        // Fetched when played: the web's hosted guides (fizzyedit/plans#30, step 3).
        .hosted => return .unknown,
    }
    const tape = demo.player.tape() orelse return .unknown;
    self.forgetPlaying();
    if (self.editor.app.gpa.dupe(u8, info.name)) |n| {
        self.playing = .{ .name = n, .ops = tape.ops.ptr };
    } else |_| {}
    if (at_ms > 0) demo.player.seek(@floatFromInt(at_ms));
    return .started;
}

fn current(ctx: *anyopaque) ?[]const u8 {
    const self = from(ctx);
    const p = self.playing orelse return null;
    const tape = self.editor.demo.player.tape() orelse {
        self.forgetPlaying();
        return null;
    };
    if (tape.ops.ptr != p.ops) {
        self.forgetPlaying();
        return null;
    }
    return p.name;
}

fn forgetPlaying(self: *Demos) void {
    const p = self.playing orelse return;
    self.editor.app.gpa.free(p.name);
    self.playing = null;
}
