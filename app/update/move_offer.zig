//! The offer to move a macOS app into /Applications, made at launch when it runs from anywhere
//! it cannot update: a disk image, Downloads, a translocated mount.
//!
//! The dialog offers Move and Not now. Move copies the bundle there on a thread of its own
//! (`macos_bundle.moveToApplications`), then quits; the new copy opens once this process has
//! exited (`openAtExit`). Not now is remembered against the version
//! (`Recents.move_declined_version`), so the offer comes back with the next one. The launch's
//! update check waits for the answer.
//!
//! Every name in it is the running bundle's own, so an app built on fizzy is offered its own move.

const std = @import("std");
const dvui = @import("dvui");
const core = @import("core");
const AppInfo = @import("../AppInfo.zig");
const Recents = @import("../Recents.zig");
const install_location = @import("install_location.zig");
const macos_bundle = @import("macos_bundle.zig");

/// Where Not now is kept: the app's recents, and how it writes them to disk.
pub const Memory = struct {
    /// Owned by the app; outlives the offer.
    recents: *Recents,
    /// Writes `recents` to disk now, so a Not now survives a crash.
    save: *const fn () void,
};

const Move = enum(u8) { none, running, moved, failed, cancelled };

// All of these are written and read on the GUI thread, except `dest_buf` and `dest_len`, written
// by the move's thread before it publishes `move_state` (release) and read once the GUI thread
// sees it (acquire).
var offered: ?*const macos_bundle.Bundle = null;
var memory: ?Memory = null;
/// Called once, when the offer is answered and the move, if any, is over.
var on_answered: ?*const fn () void = null;
var armed: bool = false;
var move_state: std.atomic.Value(u8) = .init(@backingInt(Move.none));
var dest_buf: [macos_bundle.max_path]u8 = undefined;
var dest_len: usize = 0;
/// Set once a move is done and the app is quitting to open it.
var open_on_exit: bool = false;

/// Whether to make the offer this launch. When true, keeps what it needs until `tick` shows it;
/// `answered` runs once the user has answered and the move, if any, is over.
pub fn wanted(io: std.Io, mem: Memory, answered: *const fn () void) bool {
    if (comptime !macos_bundle.supported) return false;
    const bundle = macos_bundle.current(io) orelse return false;
    if (!install_location.offers(bundle.place, AppInfo.current.version, mem.recents.move_declined_version)) return false;
    offered = bundle;
    memory = mem;
    on_answered = answered;
    return true;
}

/// Shows the dialog, and takes in a finished move. Once a frame, on the GUI thread, inside the
/// frame.
pub fn tick() void {
    if (comptime !macos_bundle.supported) return;
    if (offered != null and !armed) arm();
    switch (@as(Move, @fromBackingInt(move_state.load(.acquire)))) {
        .none, .running => {},
        .moved => {
            move_state.store(@backingInt(Move.none), .monotonic);
            open_on_exit = true;
            dvui.log.info("move to Applications: copied to {s}; quitting to open it there", .{dest_buf[0..dest_len]});
            answer();
            dvui.currentWindow().addEventApp(.{ .action = .quit }) catch |err| {
                dvui.log.err("move to Applications: could not quit: {t}", .{err});
            };
        },
        .failed => {
            move_state.store(@backingInt(Move.none), .monotonic);
            core.dialogs.toast(@src(), .{ .message = "Could not move to Applications; see the log." });
            answer();
        },
        .cancelled => {
            move_state.store(@backingInt(Move.none), .monotonic);
            answer();
        },
    }
}

/// As the app quits: once a move is done, open the new copy after this process has exited. A
/// quit the user called off leaves the new copy to open at the next quit.
pub fn openAtExit(gpa: std.mem.Allocator) void {
    if (comptime !macos_bundle.supported) return;
    if (!open_on_exit) return;
    macos_bundle.openAfterExit(gpa, dest_buf[0..dest_len]) catch |err| {
        std.log.err("move to Applications: could not open {s}: {t}", .{ dest_buf[0..dest_len], err });
    };
}

fn arm() void {
    armed = true;
    var mutex = core.dialogs.dialog(@src(), .{
        .displayFn = dialog,
        .callafterFn = callAfter,
        .title = "Move to Applications?",
        .ok_label = "",
        .cancel_label = "",
        .resizeable = false,
        .default = .cancel,
        .hide_footer = true,
        .max_size = .width(460),
        .header_kind = .info,
    });
    mutex.mutex.unlock(dvui.io);
}

fn dialog(id: dvui.Id) anyerror!bool {
    var outer = dvui.box(@src(), .{ .dir = .vertical }, .{ .expand = .both, .padding = .all(12) });
    defer outer.deinit();

    dvui.label(
        @src(),
        "{s} updates itself only from the Applications folder. Move it there and open it from there?",
        .{AppInfo.current.display_name},
        .{ .color_text = .{ .color = dvui.themeGet().color(.window, .text) }, .margin = .{ .h = 12 } },
    );

    var row = dvui.box(@src(), .{ .dir = .horizontal }, .{ .gravity_x = 0.5 });
    defer row.deinit();

    if (core.dialogs.bodyButton(@src(), id, "Not now", .control, 1, 0)) {
        core.dialogs.closeFloatingDialogAnchored();
        decline();
    }
    _ = dvui.spacer(@src(), .{ .min_size_content = .{ .w = 10, .h = 1 } });
    if (core.dialogs.bodyButton(@src(), id, "Move to Applications", .highlight, 2, 1)) {
        core.dialogs.closeFloatingDialogAnchored();
        startMove();
    }
    return true;
}

/// The header's close is Not now.
fn callAfter(_: dvui.Id, response: dvui.enums.DialogResponse) anyerror!void {
    if (response == .cancel) decline();
}

fn answer() void {
    const f = on_answered orelse return;
    on_answered = null;
    f();
}

fn decline() void {
    if (offered == null) return;
    offered = null;
    if (memory) |mem| remember: {
        const gpa = mem.recents.folders.allocator;
        const copy = gpa.dupe(u8, AppInfo.current.version) catch break :remember;
        if (mem.recents.move_declined_version) |old| gpa.free(old);
        mem.recents.move_declined_version = copy;
        mem.save();
    }
    answer();
}

fn startMove() void {
    const bundle = offered orelse return;
    offered = null;
    const mem = memory orelse return answer();
    move_state.store(@backingInt(Move.running), .monotonic);
    const thread = std.Thread.spawn(.{}, moveThread, .{ mem.recents.folders.allocator, dvui.io, bundle, dvui.currentWindow() }) catch |err| {
        dvui.log.err("move to Applications: {t}", .{err});
        move_state.store(@backingInt(Move.failed), .release);
        return;
    };
    thread.detach();
}

fn moveThread(gpa: std.mem.Allocator, io: std.Io, bundle: *const macos_bundle.Bundle, win: *dvui.Window) void {
    const result: Move = if (macos_bundle.moveToApplications(gpa, io, bundle, &dest_buf)) |dest| moved: {
        dest_len = dest.len;
        break :moved .moved;
    } else |err| switch (err) {
        error.Cancelled => .cancelled,
        else => failed: {
            std.log.err("move to Applications: {t}", .{err});
            break :failed .failed;
        },
    };
    move_state.store(@backingInt(result), .release);
    dvui.refresh(win, @src(), null);
}
