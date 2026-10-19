//! The main window as a view host (`app.view.ViewHost`): it shows the whole frame, drawn into a
//! texture of its own and put onto the window as the frame ends (`core.FrameTarget`), and asks the
//! backend about the window's place on the desktop and what it is made of. Its close is the app's
//! quit, which dvui's app runner takes; floats' own windows are the other local hosts (`Popout`).
const dvui = @import("dvui");
const fizzy = @import("../fizzy.zig");
const Editor = @import("Editor.zig");
const ViewHost = @import("app").view.ViewHost;

const MainWindow = @This();

/// The whole frame, drawn into a texture before it reaches the window (`core.FrameTarget`).
frame_target: fizzy.core.FrameTarget = .{},

pub fn host(self: *MainWindow) ViewHost {
    return .{ .ptr = self, .vtable = ViewHost.vtableOf(MainWindow) };
}

/// The frame target bound: everything the frame draws goes into it. The window's size is dvui's,
/// from the backend's own events.
pub fn begin(self: *MainWindow) ?dvui.Rect.Physical {
    const prof = fizzy.core.profile.begin("fizzy", "frame target: begin");
    defer prof.end();
    self.frame_target.begin();
    return null;
}

/// dvui's deferred subwindows replayed into the frame target, and the target onto the window,
/// which the backend presents at `Window.end`.
pub fn end(self: *MainWindow) void {
    const prof = fizzy.core.profile.begin("fizzy", "frame target: onto the window");
    defer prof.end();
    self.frame_target.end();
}

pub fn surface(_: *MainWindow) dvui.Rect.Physical {
    return dvui.windowRectPixels();
}

pub fn space(_: *MainWindow) ViewHost.Space {
    const win = dvui.currentWindow();
    return .{
        .covers = fizzy.backend.coversDesktop(win),
        .entering = fizzy.backend.enteringSpace(win),
        .fullness = fizzy.backend.spaceFullness(win),
    };
}

/// Where the backend makes the window of the window material (macOS: Liquid Glass, vibrancy or
/// none, as a plain dvui app's): its colour over that material at `opacity`, its glass's look the
/// window's at that opacity (`Editor.windowGlassLook`).
pub fn materialBase(_: *MainWindow, fill: dvui.Color, opacity: f32) ?dvui.Color {
    return fizzy.backend.windowMaterialBase(dvui.currentWindow(), fill, opacity, Editor.windowGlassLook(opacity, dvui.windowRect().size()));
}

pub fn closeRequested(_: *MainWindow) bool {
    return false;
}
