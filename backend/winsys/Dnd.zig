//! Drag and drop *from outside the app*: files or text dragged over a window from another
//! program. A drag between fizzy's own windows is not this; that is the app's (`ViewDrag`) and
//! only borrows pointer events.
//!
//! The OS runs one visit per entry: `enter`, any number of `move`s, then `leave` or `drop`.
//! Leaving and coming back is a new visit. Releasing is not acceptance: a drop can still fail to
//! transfer, which the app learns by `Platform.dndRespond` having said `reject`, or by no data.
//! Observed per platform in `docs/window-notes/dnd.md`.
const geometry = @import("geometry.zig");

const Dnd = @This();

phase: Phase,
/// Where the pointer is in the window, physical pixels. Zero on `leave`.
at: geometry.Point = .{},
/// Present on `enter`, `move` and `drop`; `.unsupported` on `leave`.
data: Data = .unsupported,

pub const Phase = enum { enter, move, leave, drop };

/// What the app tells the OS it will do with the data at the current point, so the cursor shows
/// it. Answered after every `enter` and `move`; the OS keeps the last answer until the next.
pub const Response = enum { reject, copy };

/// What is being dragged. Slices are valid until the next `Platform.poll`; copy what must
/// outlive that.
pub const Data = union(enum) {
    /// A kind this interface does not read; a `drop` of it should be rejected.
    unsupported,
    /// Absolute paths, UTF-8, in drag order.
    files: []const []const u8,
    text: []const u8,
};
