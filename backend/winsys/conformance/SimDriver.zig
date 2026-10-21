//! `Sim` as the conformance suite's driver: the reference the suite is first proved against.
const std = @import("std");
const Sim = @import("../Sim.zig");
const Platform = @import("../Platform.zig");
const Event = @import("../Event.zig");
const Window = @import("../Window.zig");
const Drop = @import("../Drop.zig");
const geometry = @import("../geometry.zig");
const hooks = @import("hooks.zig");

const SimDriver = @This();

pub const os: ?std.Target.Os.Tag = null;
pub const has_display = true;

sim: Sim,

pub fn init(gpa: std.mem.Allocator) !SimDriver {
    return .{ .sim = Sim.init(gpa, .{}) };
}

pub fn deinit(d: *SimDriver) void {
    d.sim.deinit();
}

pub fn platform(d: *SimDriver) Platform {
    return d.sim.platform();
}

pub fn settle(d: *SimDriver) void {
    d.sim.advance(50 * std.time.ns_per_ms);
}

pub fn tap(d: *SimDriver, code: Event.Code) void {
    d.sim.tap(code);
}

pub fn imeCompose(d: *SimDriver, text: []const u8, start: u32, len: u32) void {
    d.sim.imeCompose(text, start, len);
}

pub fn imeCommit(d: *SimDriver, text: []const u8) void {
    d.sim.imeCommit(text);
}

pub fn imeCancel(d: *SimDriver) void {
    d.sim.imeCancel();
}

pub fn copyFromOutside(d: *SimDriver, text: []const u8) void {
    d.sim.copyFromOutside(text);
}

pub fn dragBegin(d: *SimDriver, window: Window, at: geometry.Point, data: Drop.Data) void {
    d.sim.movePointer(d.sim.desktopPoint(window, at));
    d.sim.dragBegin(data);
}

pub fn dragMove(d: *SimDriver, window: Window, at: geometry.Point) void {
    d.sim.movePointer(d.sim.desktopPoint(window, at));
}

pub fn dragEnd(d: *SimDriver) hooks.DropOutcome {
    return switch (d.sim.dragRelease()) {
        .accepted => .accepted,
        .rejected => .rejected,
        .outside => .outside,
    };
}

pub fn plugDisplay(d: *SimDriver, scale: f32) u64 {
    return d.sim.addDisplay(.{ .bounds = .{ .x = 1920, .y = 0, .w = 1280, .h = 800 }, .scale = scale });
}

pub fn unplugDisplay(d: *SimDriver, id: u64) void {
    d.sim.removeDisplay(id);
}

pub fn setDisplayScale(d: *SimDriver, id: u64, scale: f32) void {
    d.sim.setDisplayScale(id, scale);
}
