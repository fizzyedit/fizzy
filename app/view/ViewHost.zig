//! What shows one view of the app's frame: a surface the frame's part for it is shown on, as an
//! app's main window shows all of it and a float's own OS window its band of it
//! (`plans/EMBEDDED_EDITOR_PLAN.md`, "One interface for every window"). The app draws every view
//! into the one `dvui.Window` and asks its host, through this seam, where the view lies, what the
//! surface is made of and whether it is going away; the host shows it as the frame ends. Hosts are
//! the app's to implement: a local one is a window of its own, drawn in-process with no IPC; a view
//! shown by another process over the control socket is one more, on the same calls.
//!
//! Input reaches dvui from the backend, as before, and the cursor and text-input place go back to
//! it from `dvui.Window.end`: a host that is not a window of this backend's takes them there
//! (`dvui.Window.cursor_requested`, `text_input_rect`) when it is added.
const std = @import("std");
const dvui = @import("dvui");

const ViewHost = @This();

ptr: *anyopaque,
vtable: *const VTable,

/// How much of the desktop a host's surface covers, for what is drawn under the frame to be as
/// see-through as the surface may be: opaque while it covers the desktop.
pub const Space = struct {
    /// Zoomed or full screen: nothing behind it shows.
    covers: bool = false,
    /// Moving itself into a full-screen Space, which the OS shows as pictures of it: opaque at once.
    entering: bool = false,
    /// How far into full screen it is while it moves into or out of it; null otherwise.
    fullness: ?f32 = null,
};

pub const VTable = struct {
    /// Before the frame draws anything: where the host moved or resized its surface since the
    /// last frame, as the part of the frame it now shows (physical), for the view to follow; null
    /// when it did not.
    begin: *const fn (ptr: *anyopaque) ?dvui.Rect.Physical,
    /// After the frame has drawn: its part of the frame shown on its surface.
    end: *const fn (ptr: *anyopaque) void,
    /// The part of the frame its surface shows, physical pixels; its size is the surface's.
    surface: *const fn (ptr: *anyopaque) dvui.Rect.Physical,
    space: *const fn (ptr: *anyopaque) Space,
    /// The colour under the frame at `opacity`, `fill` over the material where the host makes its
    /// surface of one; null where it makes none and the app draws its own base.
    material_base: *const fn (ptr: *anyopaque, fill: dvui.Color, opacity: f32) ?dvui.Color,
    /// Whether the person asked the host to close it (its close button, CmdW), read each frame. A
    /// host whose close is the app's quit (a main window, which dvui's app runner closes) says
    /// false.
    close_requested: *const fn (ptr: *anyopaque) bool,
};

pub fn begin(self: ViewHost) ?dvui.Rect.Physical {
    return self.vtable.begin(self.ptr);
}

pub fn end(self: ViewHost) void {
    self.vtable.end(self.ptr);
}

pub fn surface(self: ViewHost) dvui.Rect.Physical {
    return self.vtable.surface(self.ptr);
}

pub fn space(self: ViewHost) Space {
    return self.vtable.space(self.ptr);
}

pub fn materialBase(self: ViewHost, fill: dvui.Color, opacity: f32) ?dvui.Color {
    return self.vtable.material_base(self.ptr, fill, opacity);
}

pub fn closeRequested(self: ViewHost) bool {
    return self.vtable.close_requested(self.ptr);
}

/// A host's vtable from a type's methods of the same names: `T.begin(*T)`, `T.end(*T)`, ... .
pub fn vtableOf(comptime T: type) *const VTable {
    const S = struct {
        fn self(ptr: *anyopaque) *T {
            return @ptrCast(@alignCast(ptr));
        }
        fn beginFn(ptr: *anyopaque) ?dvui.Rect.Physical {
            return T.begin(self(ptr));
        }
        fn endFn(ptr: *anyopaque) void {
            T.end(self(ptr));
        }
        fn surfaceFn(ptr: *anyopaque) dvui.Rect.Physical {
            return T.surface(self(ptr));
        }
        fn spaceFn(ptr: *anyopaque) Space {
            return T.space(self(ptr));
        }
        fn materialBaseFn(ptr: *anyopaque, fill: dvui.Color, opacity: f32) ?dvui.Color {
            return T.materialBase(self(ptr), fill, opacity);
        }
        fn closeRequestedFn(ptr: *anyopaque) bool {
            return T.closeRequested(self(ptr));
        }
        const vtable: VTable = .{
            .begin = beginFn,
            .end = endFn,
            .surface = surfaceFn,
            .space = spaceFn,
            .material_base = materialBaseFn,
            .close_requested = closeRequestedFn,
        };
    };
    return &S.vtable;
}

test "a host's calls reach its own methods" {
    const Fake = struct {
        begun: u32 = 0,
        ended: u32 = 0,
        moved: ?dvui.Rect.Physical = .{ .x = 1, .y = 2, .w = 30, .h = 40 },
        fn begin(f: *@This()) ?dvui.Rect.Physical {
            f.begun += 1;
            defer f.moved = null;
            return f.moved;
        }
        fn end(f: *@This()) void {
            f.ended += 1;
        }
        fn surface(_: *@This()) dvui.Rect.Physical {
            return .{ .w = 800, .h = 600 };
        }
        fn space(_: *@This()) Space {
            return .{ .covers = true, .fullness = 0.5 };
        }
        fn materialBase(_: *@This(), fill: dvui.Color, opacity: f32) ?dvui.Color {
            return if (opacity < 1) fill else null;
        }
        fn closeRequested(f: *@This()) bool {
            return f.ended > 0;
        }
    };
    var fake: Fake = .{};
    const host: ViewHost = .{ .ptr = &fake, .vtable = vtableOf(Fake) };
    try std.testing.expectEqual(@as(f32, 30), host.begin().?.w);
    try std.testing.expect(host.begin() == null);
    try std.testing.expect(!host.closeRequested());
    host.end();
    try std.testing.expect(host.closeRequested());
    try std.testing.expectEqual(@as(u32, 2), fake.begun);
    try std.testing.expectEqual(@as(f32, 600), host.surface().h);
    try std.testing.expect(host.space().covers);
    try std.testing.expectEqual(@as(?f32, 0.5), host.space().fullness);
    const red: dvui.Color = .{ .r = 255, .g = 0, .b = 0, .a = 255 };
    try std.testing.expect(host.materialBase(red, 1) == null);
    try std.testing.expectEqual(red, host.materialBase(red, 0.5).?);
}
