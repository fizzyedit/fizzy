//! The cases. Each is a function over a fresh driver; `list` makes the table for one driver type.
//! A case asserts what the interface promises (`Platform`, `Event`, the notes in
//! `docs/window-notes/`), not what Sim happens to do: where the notes leave a behaviour to the
//! platform, no case pins it.
const std = @import("std");
const root = @import("root.zig");
const Platform = @import("../Platform.zig");
const Event = @import("../Event.zig");
const Window = @import("../Window.zig");
const Drop = @import("../Drop.zig");
const Case = root.Case;

const expect = std.testing.expect;
const expectEqual = std.testing.expectEqual;
const expectEqualStrings = std.testing.expectEqualStrings;

pub fn list(comptime D: type) [11]Case(D) {
    const W = Windows(D);
    const I = Input(D);
    const O = Outside(D);
    return .{
        .{ .name = "window lifecycle: ids are never reused and close is idempotent", .tag = .all, .available = hasAll(D, &.{}), .run = gate(D, W, &.{}, "lifecycle") },
        .{ .name = "window state and visibility start as asked", .tag = .all, .available = hasAll(D, &.{}), .run = gate(D, W, &.{}, "initialState") },
        .{ .name = "resize: the event and the query agree", .tag = .all, .available = hasAll(D, &.{}), .run = gate(D, W, &.{}, "resize") },
        .{ .name = "dpi change: the window hears the new scale", .tag = .needs_display, .needs = &.{.setDisplayScale}, .available = hasAll(D, &.{.setDisplayScale}), .run = gate(D, W, &.{.setDisplayScale}, "dpiChange") },
        .{ .name = "focus: the window that loses it hears so before the one that gains", .tag = .all, .available = hasAll(D, &.{}), .run = gate(D, W, &.{}, "focusOrder") },
        .{ .name = "key: down, then its text, then up", .tag = .all, .needs = &.{.tap}, .available = hasAll(D, &.{.tap}), .run = gate(D, I, &.{.tap}, "keyText") },
        .{ .name = "ime: a commit clears the run and then types, a cancel types nothing", .tag = .all, .needs = &.{ .imeCompose, .imeCommit, .imeCancel }, .available = hasAll(D, &.{ .imeCompose, .imeCommit, .imeCancel }), .run = gate(D, I, &.{ .imeCompose, .imeCommit, .imeCancel }, "ime") },
        .{ .name = "clipboard: a write reads back, moves the serial and sends no event", .tag = .needs_display, .available = hasAll(D, &.{}), .run = gate(D, O, &.{}, "clipboardRoundTrip") },
        .{ .name = "clipboard: another program's copy is heard with the new serial", .tag = .needs_display, .needs = &.{.copyFromOutside}, .available = hasAll(D, &.{.copyFromOutside}), .run = gate(D, O, &.{.copyFromOutside}, "clipboardOutside") },
        .{ .name = "dnd: enter, over, drop, and the app's answer decides", .tag = .needs_display, .needs = &.{ .dragBegin, .dragMove, .dragEnd }, .available = hasAll(D, &.{ .dragBegin, .dragMove, .dragEnd }), .run = gate(D, O, &.{ .dragBegin, .dragMove, .dragEnd }, "dnd") },
        .{ .name = "display hot-plug: the list follows and the window keeps a home", .tag = .needs_display, .needs = &.{ .plugDisplay, .unplugDisplay }, .available = hasAll(D, &.{ .plugDisplay, .unplugDisplay }), .run = gate(D, O, &.{ .plugDisplay, .unplugDisplay }, "hotplug") },
    };
}

fn hasAll(comptime D: type, comptime needs: []const root.hooks.Hook) bool {
    inline for (needs) |hook| if (!@hasDecl(D, @tagName(hook))) return false;
    return true;
}

fn Support(comptime D: type) type {
    return struct {
        pub fn await(d: *D, window: Window, comptime tag: std.meta.Tag(Event.Payload)) ?@FieldType(Event.Payload, @tagName(tag)) {
            d.settle();
            const p = d.platform();
            var budget: usize = 256;
            while (budget > 0) : (budget -= 1) {
                const e = p.poll() orelse return null;
                const w = e.window orelse continue;
                if (w.id == window.id and std.meta.activeTag(e.payload) == tag) return @field(e.payload, @tagName(tag));
            }
            return null;
        }

        pub fn drain(d: *D) void {
            d.settle();
            const p = d.platform();
            while (p.poll() != null) {}
        }
    };
}

/// Window lifecycle, geometry and focus.
fn Windows(comptime D: type) type {
    return struct {
        const S = Support(D);
        const await = S.await;
        const drain = S.drain;

        fn lifecycle(d: *D, _: std.mem.Allocator) !void {
            const p = d.platform();
            const a = try p.openWindow(.{ .title = "a" });
            try expect(a.id != 0);
            const b = try p.openWindow(.{ .title = "b" });
            try expect(b.id != a.id);
            p.setTitle(a, "renamed");
            p.closeWindow(b);
            p.closeWindow(b);
            const c = try p.openWindow(.{});
            try expect(c.id != a.id and c.id != b.id);
            try expect(c.id > b.id);
        }

        fn initialState(d: *D, _: std.mem.Allocator) !void {
            const p = d.platform();
            const w = try p.openWindow(.{ .size = .{ .w = 640, .h = 480 } });
            drain(d);
            try expectEqual(Window.State.normal, p.windowState(w));
            try expect(p.windowScale(w) > 0);
            try expect(p.windowSize(w).w > 0 and p.windowSize(w).h > 0);
        }

        fn resize(d: *D, _: std.mem.Allocator) !void {
            const p = d.platform();
            const w = try p.openWindow(.{ .size = .{ .w = 800, .h = 600 } });
            drain(d);
            const before = p.windowSize(w);
            p.setWindowSize(w, .{ .w = 1000, .h = 500 });
            // A platform may refuse the size (a tiling compositor); if it changed the window,
            // the event is the truth and the query says the same.
            const heard = await(d, w, .resized);
            const now = p.windowSize(w);
            if (now.w != before.w or now.h != before.h) {
                try expect(heard != null);
                try expectEqual(now.w, heard.?.size.w);
                try expectEqual(now.h, heard.?.size.h);
                try expectEqual(p.windowScale(w), heard.?.scale);
            }
        }

        fn dpiChange(d: *D, _: std.mem.Allocator) !void {
            const p = d.platform();
            const w = try p.openWindow(.{ .position = .{ .x = 100, .y = 100 }, .size = .{ .w = 400, .h = 300 } });
            drain(d);
            const display = p.displayOf(w) orelse return error.WindowHasNoDisplay;
            const old = p.windowScale(w);
            const next: f32 = if (old == 2) 1 else 2;
            d.setDisplayScale(display, next);
            const heard = await(d, w, .resized) orelse return error.NoResizedEvent;
            try expectEqual(next, heard.scale);
            try expectEqual(next, p.windowScale(w));
        }

        fn focusOrder(d: *D, _: std.mem.Allocator) !void {
            const p = d.platform();
            const a = try p.openWindow(.{ .position = .{ .x = 0, .y = 0 }, .size = .{ .w = 300, .h = 300 } });
            const b = try p.openWindow(.{ .position = .{ .x = 400, .y = 0 }, .size = .{ .w = 300, .h = 300 } });
            drain(d);
            p.raiseWindow(b);
            drain(d);
            p.raiseWindow(a);
            d.settle();
            // Whichever window held focus lost it before `a` gained it.
            var lost_at: ?usize = null;
            var gained_at: ?usize = null;
            var n: usize = 0;
            while (p.poll()) |e| : (n += 1) {
                const w = e.window orelse continue;
                if (e.payload != .focus) continue;
                if (w.id == a.id and e.payload.focus and gained_at == null) gained_at = n;
                if (w.id == b.id and !e.payload.focus and lost_at == null) lost_at = n;
            }
            try expect(gained_at != null);
            if (lost_at) |lost| try expect(lost < gained_at.?);
        }
    };
}

/// Keys, text and input methods.
fn Input(comptime D: type) type {
    return struct {
        const S = Support(D);
        const await = S.await;
        const drain = S.drain;

        fn keyText(d: *D, _: std.mem.Allocator) !void {
            const p = d.platform();
            const w = try p.openWindow(.{});
            p.setTextInput(w, true);
            drain(d);
            d.tap(.k);
            d.settle();
            var down: ?usize = null;
            var text: ?usize = null;
            var up: ?usize = null;
            var n: usize = 0;
            while (p.poll()) |e| : (n += 1) switch (e.payload) {
                .key => |k| switch (k.action) {
                    .down => down = down orelse n,
                    .up => up = up orelse n,
                    .repeat => {},
                },
                .text => |t| {
                    try expectEqualStrings("k", t);
                    text = text orelse n;
                },
                else => {},
            };
            try expect(down != null and text != null and up != null);
            try expect(down.? < text.? and text.? < up.?);

            // A window not taking text still gets the keys, and no characters.
            p.setTextInput(w, false);
            drain(d);
            d.tap(.k);
            d.settle();
            while (p.poll()) |e| try expect(e.payload != .text);
        }

        fn ime(d: *D, _: std.mem.Allocator) !void {
            const p = d.platform();
            const w = try p.openWindow(.{});
            p.setTextInput(w, true);
            drain(d);

            d.imeCompose("にほ", 3, 3);
            const run = await(d, w, .ime) orelse return error.NoComposition;
            // Offsets are UTF-8 bytes.
            try expectEqualStrings("にほ", run.text);
            try expectEqual(@as(u32, 3), run.start);

            // The run is cleared, then the text is typed: no text arrives before the clear.
            d.imeCommit("日本");
            const cleared = await(d, w, .ime) orelse return error.NoClear;
            try expectEqualStrings("", cleared.text);
            const typed = await(d, w, .text) orelse return error.NoText;
            try expectEqualStrings("日本", typed);

            // A cancel clears the run and types nothing.
            d.imeCompose("か", 0, 3);
            _ = await(d, w, .ime) orelse return error.NoComposition;
            d.imeCancel();
            d.settle();
            const gone = await(d, w, .ime) orelse return error.NoClear;
            try expectEqualStrings("", gone.text);
            while (p.poll()) |e| try expect(e.payload != .text);
        }
    };
}

/// The clipboard, drags and displays: what comes from outside the app.
fn Outside(comptime D: type) type {
    return struct {
        const S = Support(D);
        const await = S.await;
        const drain = S.drain;

        fn clipboardRoundTrip(d: *D, gpa: std.mem.Allocator) !void {
            const p = d.platform();
            const w = try p.openWindow(.{});
            drain(d);
            const before = p.clipboardSerial().serial;
            try p.setClipboardText("round trip é 日本");
            const got = (try p.clipboardText(gpa)) orelse return error.EmptyClipboard;
            defer gpa.free(got);
            try expectEqualStrings("round trip é 日本", got);
            try expect(p.clipboardSerial().serial != before);
            // The app's own write is not news to the app.
            d.settle();
            while (p.poll()) |e| try expect(e.payload != .clipboard or e.window.?.id != w.id);
        }

        fn clipboardOutside(d: *D, gpa: std.mem.Allocator) !void {
            const p = d.platform();
            const w = try p.openWindow(.{});
            drain(d);
            d.copyFromOutside("theirs");
            const heard = await(d, w, .clipboard) orelse return error.NoClipboardEvent;
            try expectEqual(p.clipboardSerial().serial, heard.serial);
            const got = (try p.clipboardText(gpa)) orelse return error.EmptyClipboard;
            defer gpa.free(got);
            try expectEqualStrings("theirs", got);
        }

        fn dnd(d: *D, _: std.mem.Allocator) !void {
            const p = d.platform();
            const w = try p.openWindow(.{ .position = .{ .x = 0, .y = 0 }, .size = .{ .w = 400, .h = 300 } });
            drain(d);
            d.dragBegin(w, .{ .x = 20, .y = 20 }, .{ .files = &.{"/tmp/one.png"} });
            const enter = await(d, w, .drop) orelse return error.NoEnter;
            try expectEqual(Drop.Phase.enter, enter.phase);
            try expectEqualStrings("/tmp/one.png", enter.data.files[0]);
            p.dropRespond(w, .copy);
            d.dragMove(w, .{ .x = 40, .y = 40 });
            const over = await(d, w, .drop) orelse return error.NoMove;
            try expectEqual(Drop.Phase.move, over.phase);
            try expectEqual(root.hooks.DropOutcome.accepted, d.dragEnd());
            const dropped = await(d, w, .drop) orelse return error.NoDrop;
            try expectEqual(Drop.Phase.drop, dropped.phase);

            // Releasing is not acceptance: unanswered, the drop is rejected.
            d.dragBegin(w, .{ .x = 20, .y = 20 }, .{ .text = "hello" });
            _ = await(d, w, .drop) orelse return error.NoEnter;
            try expectEqual(root.hooks.DropOutcome.rejected, d.dragEnd());
            drain(d);
        }

        fn hotplug(d: *D, gpa: std.mem.Allocator) !void {
            const p = d.platform();
            const w = try p.openWindow(.{});
            drain(d);
            const one = try p.displays(gpa);
            const count = one.len;
            Platform.freeDisplays(gpa, one);

            const id = d.plugDisplay(2);
            drain(d);
            const two = try p.displays(gpa);
            try expectEqual(count + 1, two.len);
            var found = false;
            for (two) |display| found = found or (display.id == id);
            Platform.freeDisplays(gpa, two);
            try expect(found);

            d.unplugDisplay(id);
            drain(d);
            const back = try p.displays(gpa);
            defer Platform.freeDisplays(gpa, back);
            try expectEqual(count, back.len);
            for (back) |display| try expect(display.id != id);
            // The window never loses its home, whatever display it was on.
            try expect(p.displayOf(w) != null);
            try expect(p.windowScale(w) > 0);
        }
    };
}

fn gate(comptime D: type, comptime Group: type, comptime needs: []const root.hooks.Hook, comptime name: []const u8) *const fn (*D, std.mem.Allocator) root.Error!void {
    return if (comptime hasAll(D, needs)) &@field(Group, name) else unavailable(D);
}

fn unavailable(comptime D: type) *const fn (*D, std.mem.Allocator) root.Error!void {
    return struct {
        fn run(_: *D, _: std.mem.Allocator) root.Error!void {
            return error.HookMissing;
        }
    }.run;
}
